/**
 * Whale's Pencil — Host half.
 *
 * The board is a transparent window across the whole desktop. Two hands draw on
 * it, and neither can corrupt the other's work:
 *
 *   - **the agent** paints through the `pencil` tool: any colour, any primitive;
 *   - **the user** takes a red pencil from the tray and draws with the mouse.
 *
 * The two sets of marks live in separate files, because they are written by
 * different processes and only one writer per file keeps them honest:
 *
 *   scene.json    agent marks,  Host writes,  window reads
 *   user.json     user marks,   window writes, Host reads
 *   commands.json Host writes,  window reads   (agent erases user strokes)
 *   clear.txt     window writes, Host reads    (user cleared everything)
 *
 * The window also reports itself through window.txt and watches a heartbeat in
 * alive.txt, so a Host that dies without unwinding still leaves no window on
 * the desktop.
 *
 * @module whale-pencil
 */

import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Route prefix this plugin owns. */
const ROUTE = '/api/whale-pencil'
/** This package's own directory: the two scripts live beside this file. */
const HERE = dirname(fileURLToPath(import.meta.url))
/** The desktop window. */
const PENCIL_SCRIPT = join(HERE, 'pencil.ps1')
/** The image compositor used by `annotate`. */
const ANNOTATE_SCRIPT = join(HERE, 'annotate.ps1')
/** Hostnames a same-machine caller can legitimately use. */
const LOOPBACK_NAMES = new Set(['127.0.0.1', '[::1]', '::1', 'localhost'])
/** A scene is a few thousand primitives at most; a bitmap is the big part. */
const MAX_BODY_BYTES = 24 * 1024 * 1024
/** How long a start may take before it is reported as failed. */
const START_MS = 20000
/** How often the window's pid file is checked while starting. */
const START_POLL_MS = 200
/** How often the Host refreshes the heartbeat the window watches. */
const HEARTBEAT_MS = 1000

/** DSH_HOME, read lazily so a late environment still lands in the right place. */
function homePath(...parts) {
  return join(process.env.DSH_HOME || join(homedir(), '.dsh'), ...parts)
}

/** The files that make up the board. */
const dir = () => homePath('whale-pencil')
const sceneFile = () => join(dir(), 'scene.json')
const userFile = () => join(dir(), 'user.json')
const aliveFile = () => join(dir(), 'alive.txt')
const windowFile = () => join(dir(), 'window.txt')
const commandsFile = () => join(dir(), 'commands.json')
const clearFile = () => join(dir(), 'clear.txt')
const labelsFile = () => join(dir(), 'labels.json')
const summonFile = () => join(dir(), 'summon.json')

/** The scene document: what the agent painted. */
const EMPTY_SCENE = Object.freeze({ enabled: false, unit: 'screen', layers: [] })

let scene = structuredClone(EMPTY_SCENE)
let revision = 0
/** Bumped by every erase command; the window compares it with its own. */
let commandRev = 0
/** Last clear tick observed from the window, so a restart does not clear. */
let lastClear = 0
let ready = Promise.resolve()
let writing = Promise.resolve()
let overlay = { status: 'stopped', pid: 0, error: '' }
let overlayWork = Promise.resolve()
let heartbeat = null
let watcher = null
/** Watches the user's erase record so the Host's scene sheds erased marks. */
let eraseWatcher = null
let summonWatcher = null
let connectionOf = () => undefined
/** The session that most recently used the pencil, so a summon has somewhere to go. */
let sessionId = ''
/**
 * The conversation the user is actually looking at, reported by the Client half.
 *
 * Only the browser knows where the user's attention is; the Host can see tool
 * callers but not the open panel. So the Client claims the board per render and
 * this is the freshest claim.
 */
let activeSession = ''
/** Last summon timestamp already delivered. */
let lastSummon = 0
/** Late-bound `sessionController`, used to turn a summon into a prompt. */
let controllerOf = () => undefined
/** Late-bound `attachments`, used to commit a screenshot without a file. */
let attachmentsOf = () => undefined

// ── values ────────────────────────────────────────────────────────────────────

/** Clamp a number into a range, or undefined when it is not a finite number. */
function num(value, min, max) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return undefined
  return Math.min(max, Math.max(min, value))
}

/** A CSS colour we are willing to paint. */
function color(value, fallback) {
  if (typeof value !== 'string') return fallback
  const text = value.trim()
  if (text === '' || text.length > 64) return fallback
  if (/^#[0-9a-fA-F]{3,8}$/u.test(text)) return text
  if (/^rgba?\([\d\s.,%]+\)$/u.test(text)) return text
  if (/^[a-zA-Z]+$/u.test(text)) return text
  return fallback
}

/** A point list, clamped to a sane length. */
function points(value) {
  if (!Array.isArray(value)) return null
  const out = []
  for (const entry of value.slice(0, 8000)) {
    const x = num(entry?.x ?? entry?.[0], -1e6, 1e6)
    const y = num(entry?.y ?? entry?.[1], -1e6, 1e6)
    if (x === undefined || y === undefined) continue
    out.push([Math.round(x * 100) / 100, Math.round(y * 100) / 100])
  }
  return out.length === 0 ? null : out
}

/** A stable id for one primitive, so erasing can name exactly what it removes. */
function makeId(value, index) {
  if (typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/u.test(value)) return value
  return `a${revision}-${index}`
}

/** One primitive, or null when it carries nothing drawable. */
function sanitizeItem(value, index = 0) {
  if (value === null || typeof value !== 'object') return null
  const type = typeof value.type === 'string' ? value.type : ''
  const id = makeId(value.id, index)
  switch (type) {
    case 'rect': {
      const x = num(value.x, -1e6, 1e6)
      const y = num(value.y, -1e6, 1e6)
      const w = num(value.w ?? value.width, -1e6, 1e6)
      const h = num(value.h ?? value.height, -1e6, 1e6)
      if ([x, y, w, h].some((part) => part === undefined)) return null
      return {
        id, type, x, y, w, h,
        stroke: color(value.stroke, '#00E5FF'),
        fill: color(value.fill, 'rgba(0,229,255,0.10)'),
        width: num(value.width ?? 3, 0, 64) ?? 3,
        radius: num(value.radius, 0, 400) ?? 8,
      }
    }
    case 'ellipse': {
      const x = num(value.x, -1e6, 1e6)
      const y = num(value.y, -1e6, 1e6)
      const w = num(value.w ?? value.width, -1e6, 1e6)
      const h = num(value.h ?? value.height, -1e6, 1e6)
      if ([x, y, w, h].some((part) => part === undefined)) return null
      return {
        id, type, x, y, w, h,
        stroke: color(value.stroke, '#00E5FF'),
        fill: color(value.fill, 'rgba(0,229,255,0.10)'),
        width: num(value.width ?? 3, 0, 64) ?? 3,
      }
    }
    case 'path': {
      const list = points(value.points)
      if (list === null) return null
      return { id, type, points: list, stroke: color(value.stroke, '#FF3B30'), width: num(value.width ?? 4, 0.5, 64) ?? 4 }
    }
    case 'arrow': {
      const x1 = num(value.x1, -1e6, 1e6)
      const y1 = num(value.y1, -1e6, 1e6)
      const x2 = num(value.x2, -1e6, 1e6)
      const y2 = num(value.y2, -1e6, 1e6)
      if ([x1, y1, x2, y2].some((part) => part === undefined)) return null
      return {
        id, type, x1, y1, x2, y2,
        stroke: color(value.stroke, '#FFD400'),
        width: num(value.width ?? 4, 0.5, 64) ?? 4,
        head: num(value.head ?? 18, 2, 200) ?? 18,
      }
    }
    case 'text': {
      const x = num(value.x, -1e6, 1e6)
      const y = num(value.y, -1e6, 1e6)
      if (x === undefined || y === undefined) return null
      const text = typeof value.text === 'string' ? value.text.slice(0, 4000) : ''
      if (text === '') return null
      return {
        id, type, x, y, text,
        size: num(value.size ?? 18, 6, 400) ?? 18,
        color: color(value.color, '#FFFFFF'),
        align: value.align === 'center' || value.align === 'right' ? value.align : 'left',
        weight: value.weight === 'bold' ? 'bold' : 'normal',
      }
    }
    case 'image': {
      const src = typeof value.src === 'string' ? value.src : ''
      if (!src.startsWith('data:image/') || src.length > 20 * 1024 * 1024) return null
      return {
        id, type,
        x: num(value.x ?? 0, -1e6, 1e6) ?? 0,
        y: num(value.y ?? 0, -1e6, 1e6) ?? 0,
        w: num(value.w ?? value.width, 0, 1e6) ?? 0,
        h: num(value.h ?? value.height, 0, 1e6) ?? 0,
        src,
        alpha: num(value.alpha ?? 1, 0, 1) ?? 1,
      }
    }
    case 'pixels': {
      const data = typeof value.data === 'string' ? value.data : ''
      const w = num(value.w, 1, 4096)
      const h = num(value.h, 1, 4096)
      if (data === '' || w === undefined || h === undefined) return null
      if (data.length > 16 * 1024 * 1024) return null
      return {
        id, type,
        x: num(value.x ?? 0, -1e6, 1e6) ?? 0,
        y: num(value.y ?? 0, -1e6, 1e6) ?? 0,
        w: Math.round(w), h: Math.round(h), data,
      }
    }
    default:
      return null
  }
}

/** A bounding box for one primitive, used by rectangular erase. */
function boxOf(item) {
  switch (item.type) {
    case 'rect':
    case 'ellipse':
    case 'image':
    case 'pixels':
      return { x: item.x, y: item.y, w: item.w, h: item.h }
    case 'text':
      return { x: item.x, y: item.y, w: Math.max(120, item.text.length * item.size * 0.7), h: item.size * 1.6 }
    case 'arrow':
      return {
        x: Math.min(item.x1, item.x2),
        y: Math.min(item.y1, item.y2),
        w: Math.abs(item.x2 - item.x1),
        h: Math.abs(item.y2 - item.y1),
      }
    case 'path': {
      const xs = item.points.map((p) => p[0])
      const ys = item.points.map((p) => p[1])
      const x = Math.min(...xs)
      const y = Math.min(...ys)
      return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y }
    }
    default:
      return null
  }
}

/** Whether two boxes overlap. */
function overlaps(a, b) {
  return !(a.x + a.w < b.x || a.x > b.x + b.w || a.y + a.h < b.y || a.y > b.y + b.h)
}

// ── persistence ───────────────────────────────────────────────────────────────

async function writeAtomic(file, body) {
  await mkdir(dirname(file), { recursive: true })
  const temp = `${file}.${process.pid}.tmp`
  await writeFile(temp, body, 'utf8')
  await rename(temp, file)
}

async function readFileOrNull(file) {
  try {
    return await readFile(file, 'utf8')
  } catch {
    return null
  }
}

/** Persist the agent's scene and hand the same bytes to the window. */
function saveScene() {
  const body = JSON.stringify({ ...scene, revision }, null, 2) + '\n'
  writing = writing.then(() => writeAtomic(sceneFile(), body)).catch(() => {})
  return writing
}

/** What the window already knows about the user's strokes. */
async function readUser() {
  const raw = await readFileOrNull(userFile())
  if (raw === null) return { revision: 0, strokes: [], texts: [], hidden: [] }
  try {
    const parsed = JSON.parse(raw)
    return {
      revision: Number.isFinite(parsed?.revision) ? parsed.revision : 0,
      strokes: Array.isArray(parsed?.strokes) ? parsed.strokes : [],
      texts: Array.isArray(parsed?.texts) ? parsed.texts : [],
      hidden: Array.isArray(parsed?.hidden) ? parsed.hidden : [],
    }
  } catch {
    return { revision: 0, strokes: [], texts: [], hidden: [] }
  }
}

/** Send one erase instruction to the window. */
function sendCommand(erase) {
  commandRev += 1
  const body = JSON.stringify({ rev: commandRev, erase }, null, 2) + '\n'
  return writeAtomic(commandsFile(), body).catch(() => {})
}

/**
 * Drop whatever the user erased from the Host's own scene.
 *
 * The window hides erased marks in its own list, but that list dies with the
 * process: close the board, reopen it, and every erased mark would come back
 * because `scene.json` still holds it. So the Host folds the user's hidden ids
 * into the scene before the window is launched, and the marks are gone for good.
 */
async function pruneErased() {
  const user = await readUser()
  if (user.hidden.length === 0) return
  const hidden = new Set(user.hidden)
  const kept = scene.layers.filter((item) => !hidden.has(item.id))
  if (kept.length === scene.layers.length) return
  scene = { ...scene, layers: kept }
  revision += 1
  await saveScene()
}

/**
 * Arm or disarm the user's pencil from the Host side.
 *
 * The tray is the user's normal door, but a tray icon can be hidden in the
 * Windows overflow area, so the settings page offers the same switch.
 */
function sendMode(mode) {
  commandRev += 1
  const body = JSON.stringify({ rev: commandRev, mode }, null, 2) + '\n'
  return writeAtomic(commandsFile(), body).catch(() => {})
}

// ── the heartbeat and the clear watcher ───────────────────────────────────────

function startHeartbeat() {
  if (heartbeat !== null) return
  const beat = () => { void writeAtomic(aliveFile(), String(Date.now())).catch(() => {}) }
  beat()
  heartbeat = setInterval(beat, HEARTBEAT_MS)
  if (typeof heartbeat.unref === 'function') heartbeat.unref()
}

function stopHeartbeat() {
  if (heartbeat === null) return
  clearInterval(heartbeat)
  heartbeat = null
}

/**
 * The user's "clear everything" must also clear the agent's marks, and the
 * agent's marks are Host-owned: the window can only announce that it happened.
 */
function startClearWatcher() {
  if (watcher !== null) return
  watcher = setInterval(async () => {
    const raw = await readFileOrNull(clearFile())
    if (raw === null) return
    const tick = Number.parseInt(raw.trim(), 10)
    if (!Number.isInteger(tick) || tick <= lastClear) return
    lastClear = tick
    scene = { ...scene, layers: [] }
    revision += 1
    await saveScene()
    // The window already dropped its own marks; clearing its record too keeps a
    // later erase from pruning ids that no longer exist.
    await rm(userFile(), { force: true }).catch(() => {})
  }, 700)
  if (typeof watcher.unref === 'function') watcher.unref()
}

function stopClearWatcher() {
  if (watcher === null) return
  clearInterval(watcher)
  watcher = null
}

/**
 * Keep the Host's scene free of marks the user erased while the board is open.
 *
 * `pruneErased` runs before every launch, but a long-lived board would keep
 * erased marks in `scene.json` until the next restart. This watches the
 * window's own record so the file matches what the user sees, and so the agent's
 * `scene` read does not offer marks that are no longer there.
 */
function startEraseWatcher() {
  if (eraseWatcher !== null) return
  let lastHidden = ''
  eraseWatcher = setInterval(async () => {
    const user = await readUser()
    const key = user.hidden.join(',')
    if (key === lastHidden) return
    lastHidden = key
    if (user.hidden.length === 0) return
    await pruneErased()
  }, 900)
  if (typeof eraseWatcher.unref === 'function') eraseWatcher.unref()
}

function stopEraseWatcher() {
  if (eraseWatcher === null) return
  clearInterval(eraseWatcher)
  eraseWatcher = null
}

// ── summon ────────────────────────────────────────────────────────────────────

/**
 * The user has no way to start a turn by speaking, so the tray lends them one:
 * the window captures the screen and this delivers it to the Session the user is
 * looking at.
 *
 * The target is whichever conversation reported itself active last: the Client
 * half claims the board whenever a chat is on screen, so `activeSession` follows
 * the user rather than whichever session happened to call a tool most recently.
 * The screenshot never touches disk. It is committed through the attachment
 * service and admitted into the prompt as an image, which is also what makes it
 * visible to a model that accepts images.
 */
async function deliverSummon(record) {
  const controller = controllerOf()
  if (controller === undefined || typeof controller.prompt !== 'function') return

  const id = activeSession !== '' ? activeSession : sessionId
  if (id === '') {
    await noteSummon({ at: record?.at, ok: false, error: 'no-active-session' })
    return
  }

  const shot = await captureScreen()
  if (shot === null) {
    await noteSummon({ at: record?.at, ok: false, sessionId: id, error: 'capture-failed' })
    return
  }

  const content = [{
    type: 'text',
    text: [
      '【托盘呼唤】用户在画板上按了「呼唤 agent」，截了一张屏幕贴在下面。',
      '',
      '画板上的红线和红字都是用户画的、用户打的，那就是用户在跟你说话：',
      '圈住一块 = 「这个」，箭头 = 「那个方向」，红字 = 他的问题。',
      '所以看完之后**也要在画板上画回去**，不能只在对话里回：',
      '先 pencil scene 读他的笔画和文字坐标，再用 pencil draw 在他指的地方写字、画框、画箭头。',
      '你的笔迹不要用红色，免得和用户的混在一起。',
    ].join('\n'),
  }]

  const attachments = attachmentsOf()
  if (attachments !== undefined) {
    try {
      content.push({
        type: 'image',
        mediaType: 'image/png',
        data: Buffer.from(shot).toString('base64'),
        name: 'screen.png',
      })
    } catch {
      // Falling through sends the text alone; the user is told by the ack.
    }
  }

  try {
    await controller.prompt({
      requestId: `whale-pencil-summon-${Date.now()}`,
      sessionId: id,
      mode: 'queue',
      content,
    }, new AbortController().signal)
    await noteSummon({ at: record?.at, ok: true, sessionId: id, image: content.length > 1 })
  } catch (error) {
    // A session that cannot accept the prompt leaves the request unread; say so
    // instead of failing silently, so the reason is inspectable.
    await noteSummon({
      at: record?.at,
      ok: false,
      sessionId: id,
      error: String(error?.message ?? error).slice(0, 300),
    })
  }
}

/** Record the delivery outcome where the window can show it. */
async function noteSummon(result) {
  await writeAtomic(join(dir(), 'summon-ack.json'), JSON.stringify(result)).catch(() => {})
}

/**
 * Grab the whole desktop as PNG bytes.
 *
 * Runs in its own PowerShell because System.Drawing is already on Windows and
 * Node has no screen capture. The bytes come back over a pipe written to a temp
 * file that is removed immediately: the point is that no screenshot survives.
 */
async function captureScreen() {
  const frame = join(tmpdir(), `whale-pencil-${process.pid}-${Date.now()}.png`)
  try {
    await new Promise((resolve, reject) => {
      const child = spawn('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
        '-Command',
        'Add-Type -AssemblyName System.Windows.Forms,System.Drawing;' +
        '$b=[System.Windows.Forms.SystemInformation]::VirtualScreen;' +
        '$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height;' +
        '$g=[System.Drawing.Graphics]::FromImage($bmp);' +
        '$g.CopyFromScreen($b.X,$b.Y,0,0,$bmp.Size);' +
        `$bmp.Save('${frame.replaceAll("'", "''")}',[System.Drawing.Imaging.ImageFormat]::Png);` +
        '$g.Dispose();$bmp.Dispose()',
      ], { windowsHide: true, stdio: 'ignore' })
      const timer = setTimeout(() => {
        try { child.kill() } catch { /* gone */ }
        reject(new Error('capture timed out'))
      }, 20000)
      child.once('error', (error) => { clearTimeout(timer); reject(error) })
      child.once('exit', (code) => {
        clearTimeout(timer)
        if (code === 0) resolve()
        else reject(new Error(`capture exited ${code}`))
      })
    })
    return await readFile(frame)
  } catch {
    return null
  } finally {
    await rm(frame, { force: true }).catch(() => {})
  }
}

function startSummonWatcher() {
  if (summonWatcher !== null) return
  summonWatcher = setInterval(async () => {
    const raw = await readFileOrNull(summonFile())
    if (raw === null) return
    let record
    try {
      record = JSON.parse(raw)
    } catch {
      return
    }
    const at = Number(record?.at ?? 0)
    if (!Number.isFinite(at) || at <= lastSummon) return
    lastSummon = at
    await deliverSummon(record)
  }, 800)
  if (typeof summonWatcher.unref === 'function') summonWatcher.unref()
}

function stopSummonWatcher() {
  if (summonWatcher === null) return
  clearInterval(summonWatcher)
  summonWatcher = null
}

// ── the desktop window ────────────────────────────────────────────────────────

async function publishedPid() {
  const raw = await readFileOrNull(windowFile())
  if (raw === null) return 0
  const pid = Number.parseInt(raw.trim(), 10)
  return Number.isInteger(pid) && pid > 0 ? pid : 0
}

function alivePid(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

/**
 * Whether the board is really on screen.
 *
 * The in-memory status alone is not evidence: a window can die between ticks
 * (a reload, a crash, a stale launch) and leave `status: 'running'` pointing at
 * nothing, which reads as "drawn" while the desktop stays empty. So the pid file
 * the window publishes is the authority, and a dead pid takes the stale state
 * with it.
 */
async function overlayRunning() {
  const pid = await publishedPid()
  if (pid <= 0) {
    if (overlay.status === 'running') overlay = { status: 'stopped', pid: 0, error: '' }
    return false
  }
  if (!alivePid(pid)) {
    await rm(windowFile(), { force: true }).catch(() => {})
    overlay = { status: 'stopped', pid: 0, error: '' }
    return false
  }
  if (overlay.status !== 'running' || overlay.pid !== pid) overlay = { status: 'running', pid, error: '' }
  return true
}

/**
 * Make sure the board exists, starting it when it does not.
 *
 * Every path that touches the scene calls this first: painting into a file no
 * window is watching looks like success and shows the user nothing.
 */
async function ensureOverlay() {
  if (await overlayRunning()) return true
  await startOverlay()
  return await overlayRunning()
}

/** The tray and the board in one process, launched so it keeps its own station. */
function startOverlay() {
  overlayWork = overlayWork.then(async () => {
    if (await overlayRunning()) return
    if (process.platform !== 'win32') {
      overlay = { status: 'error', pid: 0, error: 'unsupported-platform' }
      return
    }
    overlay = { status: 'starting', pid: 0, error: '' }
    await mkdir(dir(), { recursive: true })
    // An erase the user made before this window existed must not come back: the
    // scene handed to a fresh window is the scene minus everything already gone.
    await pruneErased()
    await writeAtomic(labelsFile(), JSON.stringify({
      pencil: '拿铅笔',
      call: '呼唤 agent',
      clear: '一键清除',
      exitDraw: '退出作画',
      quit: '退出',
      trayTitle: "User's Pencil",
      widthSuffix: 'px',
    }, null, 2))
    await writeAtomic(sceneFile(), JSON.stringify({ ...scene, revision }, null, 2) + '\n')
    await rm(windowFile(), { force: true }).catch(() => {})
    startHeartbeat()
    startClearWatcher()
    startEraseWatcher()
    startSummonWatcher()

    // `cmd /c start` is not decoration: a PowerShell started directly by the
    // Host shares its window station, and the WPF window is torn down with it.
    const launcher = spawn('cmd.exe', [
      '/c', 'start', '""', '/min',
      'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
      '-File', PENCIL_SCRIPT,
      '-Scene', sceneFile(),
      '-Users', userFile(),
      '-Alive', aliveFile(),
      '-Window', windowFile(),
      '-Commands', commandsFile(),
      '-ClearSignal', clearFile(),
      '-Labels', labelsFile(),
    ], { windowsHide: true, stdio: 'ignore', detached: true })
    launcher.once('error', (error) => {
      stopHeartbeat()
      overlay = { status: 'error', pid: 0, error: String(error?.message ?? error) }
    })
    launcher.unref()

    const deadline = Date.now() + START_MS
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, START_POLL_MS))
      const pid = await publishedPid()
      if (pid > 0) {
        overlay = { status: 'running', pid, error: '' }
        return
      }
    }
    stopHeartbeat()
    overlay = { status: 'error', pid: 0, error: 'start-timeout' }
  }).catch((error) => {
    stopHeartbeat()
    overlay = { status: 'error', pid: 0, error: String(error?.message ?? error) }
  })
  return overlayWork.then(() => overlay)
}

function stopOverlay() {
  overlayWork = overlayWork.then(async () => {
    stopHeartbeat()
    stopClearWatcher()
    stopEraseWatcher()
    stopSummonWatcher()
    const pid = overlay.pid > 0 ? overlay.pid : await publishedPid()
    const deadline = Date.now() + 4000
    while (Date.now() < deadline) {
      if (pid <= 0 || !alivePid(pid)) break
      await new Promise((resolve) => setTimeout(resolve, 150))
    }
    if (pid > 0 && alivePid(pid)) {
      try { process.kill(pid) } catch { /* nothing left */ }
    }
    overlay = { status: 'stopped', pid: 0, error: '' }
    await rm(aliveFile(), { force: true }).catch(() => {})
    await rm(windowFile(), { force: true }).catch(() => {})
  }).catch(() => {})
  return overlayWork.then(() => overlay)
}

function overlayView() {
  return { status: overlay.status, error: overlay.error, pid: overlay.pid, revision }
}

// ── annotate ──────────────────────────────────────────────────────────────────

/**
 * Composite marks onto an image and write a new PNG.
 *
 * Runs as a separate PowerShell: System.Drawing is already part of Windows, so
 * this needs no image library in Node, and the source file is never touched.
 * The spec travels as a file rather than on stdin, because a pipe is the wrong
 * channel for non-ASCII text.
 */
async function annotate(source, items, output, unit) {
  const spec = JSON.stringify({ source, output, unit: unit === 'window' ? 'window' : 'screen', items }, null, 2)
  const specFile = join(dir(), `annotate-${process.pid}-${Date.now()}.json`)
  await writeAtomic(specFile, spec)
  try {
    return await new Promise((resolve, reject) => {
      const child = spawn('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', ANNOTATE_SCRIPT,
        '-Spec', specFile,
      ], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
      let out = ''
      let err = ''
      const timer = setTimeout(() => {
        try { child.kill() } catch { /* gone */ }
        reject(new Error('annotate timed out'))
      }, 60000)
      child.stdout.on('data', (d) => { out += d })
      child.stderr.on('data', (d) => { err += d })
      child.once('error', (error) => { clearTimeout(timer); reject(error) })
      child.once('exit', (code) => {
        clearTimeout(timer)
        if (code === 0) resolve(out.trim())
        else reject(new Error((err || out || `annotate exited ${code}`).slice(0, 600)))
      })
    })
  } finally {
    await rm(specFile, { force: true }).catch(() => {})
  }
}

// ── skills ────────────────────────────────────────────────────────────────────

/**
 * The two skills that explain the board to a fresh agent.
 *
 * Their bodies live beside this file so they can change without touching logic,
 * and are read once at startup: a skill that cannot be read is skipped rather
 * than failing the plugin.
 */
const SKILLS = [
  {
    name: 'pencil-board',
    description: 'How to read and answer the shared desktop board: red marks are the user, so reply by drawing back.',
    whenToUse: 'Before drawing on the board, reading it, or whenever red marks appear on screen.',
    path: join(HERE, 'skills', 'pencil-board.md'),
  },
  {
    name: 'pencil-summon',
    description: 'What a tray summon means and what to do with the screen it sends: read the board first, then answer on it.',
    whenToUse: 'When a message arrives with 【托盘呼唤】 and a screenshot.',
    path: join(HERE, 'skills', 'pencil-summon.md'),
  },
].map((skill) => {
  let content = ''
  try {
    content = readFileSync(skill.path, 'utf8')
  } catch {
    content = ''
  }
  return { ...skill, content }
}).filter((skill) => skill.content !== '')

// ── the tool ──────────────────────────────────────────────────────────────────

const TOOL_DESCRIPTION = [
  "神笔鲸良 (Whale's Pencil): draw on the desktop, above every program, in any colour.",
  'The user watches the screen, so what you paint is visible immediately and stays',
  'until erased. The pointer passes through the marks, so they never block a click.',
  '',
  'Read red as the user. Red strokes and red text on the board are what the user',
  'drew and typed with the tray pencil, so treat them as the user talking to you:',
  'answer by drawing back, not only in chat. A circled area means "this", an arrow',
  'means "that way", red text is their question. Your own marks are never red.',
  '',
  'Marks only reach the screen through the board window. `draw` checks that window',
  'and starts it when it is down, and every result carries `onScreen`: false means',
  'the marks exist but nobody can see them, so say so instead of claiming success.',
  '',
  'Actions:',
  '  draw      append primitives (see `items`); brings the board up if needed',
  '  erase     remove marks: `ids` names agent primitives, `rects` removes anything',
  '            whose box overlaps, including strokes the user drew',
  '  scene     read the board: your primitives, the user\'s strokes and texts',
  '  annotate  composite marks onto an image file and return a new PNG path',
  '  overlay   start or stop the desktop window ("start" | "stop")',
  '',
  'Primitives (screen = desktop pixels, the default; window = percent of screen):',
  '  {type:"rect", x,y,w,h, stroke, fill, width, radius}',
  '  {type:"ellipse", x,y,w,h, stroke, fill, width}',
  '  {type:"path", points:[[x,y],...], stroke, width}   freehand stroke',
  '  {type:"arrow", x1,y1,x2,y2, stroke, width, head}',
  '  {type:"text", x,y, text, size, color, align, weight}',
  '  {type:"image", x,y,w,h, src:"data:image/png;base64,..."}',
  '  {type:"pixels", x,y,w,h, data:"<base64 RGBA>"}      every pixel chosen by you',
  '',
  'Use `annotate` when the user sends an image and wants it back with your marks:',
  'it renders onto the picture itself instead of the screen.',
].join('\n')

function registerPencilTool(ctx) {
  const registry = typeof ctx.get === 'function' ? ctx.get('tools') : ctx.tools
  if (registry === undefined || typeof registry.register !== 'function') return

  ctx.effect(() => registry.register({
    name: 'pencil',
    description: TOOL_DESCRIPTION,
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        action: {
          type: 'string',
          enum: ['draw', 'erase', 'scene', 'annotate', 'overlay'],
          description: 'draw, erase, read the board, annotate an image, or start/stop the window.',
        },
        items: {
          type: 'array',
          description: 'Primitives to append (draw) or to stamp onto an image (annotate).',
          items: { type: 'object', additionalProperties: true },
        },
        ids: {
          type: 'array',
          description: 'Primitive ids to erase.',
          items: { type: 'string' },
        },
        rects: {
          type: 'array',
          description: 'Erase anything overlapping these screen rectangles: [{x,y,w,h}].',
          items: { type: 'object', additionalProperties: true },
        },
        unit: {
          type: 'string',
          enum: ['screen', 'window'],
          description: 'Coordinate unit. Defaults to screen (desktop pixels).',
        },
        source: {
          type: 'string',
          description: 'For annotate: the image file to draw on.',
        },
        output: {
          type: 'string',
          description: 'For annotate: where to write the new PNG. Defaults beside the source.',
        },
        overlay: {
          type: 'string',
          enum: ['start', 'stop'],
          description: 'For action overlay: start or stop the desktop window.',
        },
      },
      required: ['action'],
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          revision: { type: 'integer' },
          agentMarks: { type: 'integer' },
          userStrokes: { type: 'integer' },
          userTexts: { type: 'integer' },
          overlay: { type: 'string' },
          onScreen: { type: 'boolean' },
          output: { type: 'string' },
          layers: { type: 'array', items: { type: 'object', additionalProperties: true } },
          strokes: { type: 'array', items: { type: 'object', additionalProperties: true } },
          texts: { type: 'array', items: { type: 'object', additionalProperties: true } },
          hidden: { type: 'array', items: { type: 'string' } },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.output !== undefined && value.output !== ''
          ? `pencil: wrote ${value.output}`
          : `pencil: ${value.agentMarks} agent mark(s), ${value.userStrokes} user stroke(s), ${value.userTexts ?? 0} user text(s), ${value.onScreen === false ? 'NOT ON SCREEN — the board window is down' : 'on screen'}.`,
      }],
    },
    async execute(args, exec) {
      await ready
      // Remember who asked, so a tray summon knows which session to wake.
      const caller = exec?.agent?.id
      if (typeof caller === 'string' && caller !== '') sessionId = caller
      const action = typeof args?.action === 'string' ? args.action : ''
      const summary = async () => {
        const user = await readUser()
        return {
          revision,
          agentMarks: scene.layers.length,
          userStrokes: user.strokes.length,
          userTexts: user.texts.length,
          overlay: overlay.status,
          // Marks live in a file until a live window renders them; this is the
          // difference between "I painted" and "the user can see it".
          onScreen: await overlayRunning(),
        }
      }

      if (action === 'scene') {
        const user = await readUser()
        return {
          ...(await summary()),
          unit: scene.unit,
          layers: scene.layers,
          // What the user drew and typed, in the same units as the scene.
          strokes: user.strokes.map((s) => ({ id: s.id, width: s.width, points: s.points })),
          texts: user.texts,
          hidden: user.hidden,
        }
      }

      if (action === 'overlay') {
        if (args?.overlay === 'stop') await stopOverlay()
        else if (args?.overlay === 'start') await startOverlay()
        else throw new Error('overlay needs `overlay: "start"` or `"stop"`')
        return summary()
      }

      if (action === 'annotate') {
        const source = typeof args?.source === 'string' ? args.source : ''
        if (source === '') throw new Error('annotate needs `source` (an image file path)')
        const items = (Array.isArray(args?.items) ? args.items : []).map(sanitizeItem).filter(Boolean)
        if (items.length === 0) throw new Error('annotate needs at least one drawable primitive in `items`')
        const output = typeof args?.output === 'string' && args.output !== ''
          ? args.output
          : source.replace(/(\.[A-Za-z0-9]+)?$/u, '') + '-pencil.png'
        const written = await annotate(source, items, output, args?.unit)
        return { ...(await summary()), output: written }
      }

      if (action === 'erase') {
        const ids = Array.isArray(args?.ids) ? args.ids.map(String) : []
        const rects = (Array.isArray(args?.rects) ? args.rects : [])
          .map((r) => ({
            x: num(r?.x, -1e6, 1e6),
            y: num(r?.y, -1e6, 1e6),
            w: num(r?.w ?? r?.width, 0, 1e6),
            h: num(r?.h ?? r?.height, 0, 1e6),
          }))
          .filter((r) => r.x !== undefined && r.y !== undefined && r.w !== undefined && r.h !== undefined)
        if (ids.length === 0 && rects.length === 0) throw new Error('erase needs `ids` or `rects`')

        const before = scene.layers.length
        const kept = scene.layers.filter((item) => {
          if (ids.includes(item.id)) return false
          const box = boxOf(item)
          return !(box !== null && rects.some((r) => overlaps(box, r)))
        })
        if (kept.length !== before) {
          scene = { ...scene, layers: kept }
          revision += 1
          await saveScene()
        }
        // The user's strokes belong to the window; it applies the same erase.
        await sendCommand({ ids, rects })
        return summary()
      }

      if (action !== 'draw') throw new Error(`unknown pencil action ${JSON.stringify(action)}`)

      const raw = Array.isArray(args?.items) ? args.items : []
      const added = raw.map(sanitizeItem).filter((item) => item !== null)
      if (added.length === 0) throw new Error('draw needs at least one drawable primitive in `items`')
      if (args?.unit === 'screen' || args?.unit === 'window') scene = { ...scene, unit: args.unit }
      scene = { ...scene, enabled: true, layers: [...scene.layers, ...added].slice(-4000) }
      revision += 1
      await saveScene()
      // Paint only means "on screen" once a live window owns the scene file.
      await ensureOverlay()
      return summary()
    },
  }), 'whale-pencil: pencil tool')
}

// ── routes ────────────────────────────────────────────────────────────────────

function send(res, status, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  })
  res.end(body)
}

async function readJsonBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > MAX_BODY_BYTES) throw new Error('body too large')
    chunks.push(chunk)
  }
  const text = Buffer.concat(chunks).toString('utf8').trim()
  if (text === '') return {}
  const parsed = JSON.parse(text)
  return parsed !== null && typeof parsed === 'object' ? parsed : {}
}

async function view() {
  const user = await readUser()
  return {
    enabled: scene.enabled,
    unit: scene.unit,
    layers: scene.layers,
    revision,
    userStrokes: user.strokes.length,
    userTexts: user.texts.length,
    ...overlayView(),
    platform: process.platform,
  }
}

async function route(req, res) {
  await ready
  const rejection = rejectionFor(req)
  if (rejection !== undefined) {
    return send(res, rejection, { error: rejection === 403 ? 'forbidden' : 'unauthorized' })
  }
  const url = new URL(req.url ?? '/', 'http://localhost')
  const path = url.pathname.slice(ROUTE.length).replace(/\/+$/u, '') || '/'
  const method = String(req.method ?? 'GET').toUpperCase()

  try {
    if (method === 'GET' && (path === '/' || path === '/state' || path === '/scene')) {
      return send(res, 200, { ...(await view()), activeSession })
    }
    // The Client half owns the answer to "which conversation is the user in":
    // it renders inside that conversation and posts its id here.
    if (method === 'POST' && path === '/active-session') {
      const body = await readJsonBody(req)
      const id = typeof body.sessionId === 'string' ? body.sessionId.slice(0, 120) : ''
      if (id !== '') activeSession = id
      return send(res, 200, { ok: true, activeSession })
    }
    if (method === 'POST' && path === '/draw') {
      const body = await readJsonBody(req)
      const raw = Array.isArray(body.items) ? body.items : [body]
      const added = raw.map(sanitizeItem).filter((item) => item !== null)
      if (added.length === 0) return send(res, 400, { error: 'nothing drawable' })
      if (body.unit === 'screen' || body.unit === 'window') scene = { ...scene, unit: body.unit }
      scene = { ...scene, enabled: true, layers: [...scene.layers, ...added].slice(-4000) }
      revision += 1
      await saveScene()
      await ensureOverlay()
      return send(res, 200, await view())
    }
    if (method === 'POST' && path === '/overlay/start') {
      await startOverlay()
      return send(res, 200, await view())
    }
    if (method === 'POST' && path === '/overlay/stop') {
      await stopOverlay()
      return send(res, 200, await view())
    }
    // The settings page speaks for the user, who may clear; the agent's tool
    // deliberately has no such action.
    if (method === 'POST' && path === '/clear') {
      scene = { ...scene, layers: [] }
      revision += 1
      await saveScene()
      await sendClearSignal()
      return send(res, 200, await view())
    }
    // Take or drop the pencil without going through the tray icon.
    if (method === 'POST' && path === '/mode') {
      const body = await readJsonBody(req)
      const mode = body.mode === 'ink' ? 'ink' : 'idle'
      await ensureOverlay()
      await sendMode(mode)
      return send(res, 200, await view())
    }
    return send(res, 404, { error: 'not found' })
  } catch (error) {
    return send(res, 400, { error: String(error?.message ?? error).slice(0, 300) })
  }
}

/**
 * The user cleared from the settings page: drop the agent's marks and tell the
 * window to drop the user's, through the same signal its tray menu writes.
 */
async function sendClearSignal() {
  const tick = Date.now()
  lastClear = tick
  await writeAtomic(clearFile(), String(tick)).catch(() => {})
  await rm(userFile(), { force: true }).catch(() => {})
}

export function apply(ctx) {
  connectionOf = () => (typeof ctx.get === 'function' ? ctx.get('connection') : undefined)
  ready = (async () => {
    const raw = await readFileOrNull(sceneFile())
    if (raw !== null) {
      try {
        const parsed = JSON.parse(raw)
        scene = {
          enabled: parsed?.enabled === true,
          unit: parsed?.unit === 'window' ? 'window' : 'screen',
          layers: Array.isArray(parsed?.layers)
            ? parsed.layers.map((item, index) => sanitizeItem(item, index)).filter(Boolean)
            : [],
        }
        revision = Number.isFinite(parsed?.revision) ? parsed.revision : 1
      } catch {
        scene = structuredClone(EMPTY_SCENE)
      }
    }
    // A clear that happened before this process started must not replay.
    const clearRaw = await readFileOrNull(clearFile())
    if (clearRaw !== null) {
      const tick = Number.parseInt(clearRaw.trim(), 10)
      if (Number.isInteger(tick)) lastClear = tick
    }
  })()

  ctx.inject(['webServer'], (scoped) => {
    scoped.effect(
      () => scoped.webServer.register({ kind: 'prefix', path: ROUTE, handler: route }),
      'whale-pencil: routes',
    )
  })

  ctx.inject(['tools'], (scoped) => {
    registerPencilTool(scoped)
  })

  // The board only works if both hands keep talking. A standing reminder makes
  // that true even before the first tool call, and keeps the red=user rule from
  // living only inside the tool definition.
  ctx.inject(['systemPrompt'], (scoped) => {
    scoped.effect(() => scoped.systemPrompt.section({
      name: 'whale-pencil',
      order: 640,
      text: [
        '## 神笔鲸良 (Whale\'s Pencil)',
        '',
        'The desktop may carry a shared drawing board (tool `pencil`). Read red as the user:',
        'red strokes and red text are what the user drew and typed with the tray pencil,',
        'so they are the user talking to you — a circled area means "this", an arrow means',
        '"that way", red text is their question or their answer.',
        '',
        'Answer by drawing back, not only in chat. When the user points at something on',
        'screen, put your reply where they are looking: a `text` mark, a box, an arrow.',
        'Your own marks are never red, so the two hands never get confused.',
      ].join('\n'),
    }), 'whale-pencil: prompt section')
  })

  // A summon becomes a prompt in the session that last used the pencil.
  ctx.inject(['sessionController'], (scoped) => {
    controllerOf = () => scoped.sessionController
    ctx.effect(() => {
      startSummonWatcher()
      return () => stopSummonWatcher()
    }, 'whale-pencil: summon watcher')
  })

  // Two skills carry the part of the contract a tool description cannot: what
  // the board means, and what to do when the user rings the bell. They load on
  // demand, so their length costs nothing until a board session asks for them.
  ctx.inject(['skills'], (scoped) => {
    for (const entry of SKILLS) {
      scoped.effect(() => scoped.skills.register({
        ...entry,
        source: 'custom',
        provider: 'whale-pencil',
        invocation: { modelInvocable: true, userInvocable: true },
      }), `whale-pencil: skill ${entry.name}`)
    }
  })

  // Screenshots ride the attachment service into the prompt, so no capture is
  // ever written to disk and an image-capable model receives real pixels.
  ctx.inject(['attachments'], (scoped) => {
    attachmentsOf = () => scoped.attachments
  })

  // The tray icon is the user's door into the board: it appears with the plugin.
  // Only a window this instance started is shut down here; killing whatever the
  // pid file names would fight a newer instance during a reload.
  ctx.effect(() => () => {
    const own = overlay.pid
    stopHeartbeat()
    stopClearWatcher()
    stopEraseWatcher()
    stopSummonWatcher()
    overlay = { status: 'stopped', pid: 0, error: '' }
    if (own > 0 && alivePid(own)) {
      try { process.kill(own) } catch { /* already gone */ }
    }
  }, 'whale-pencil: teardown')

  void (async () => {
    await ready
    // A reload runs the previous instance's teardown first; give it room before
    // claiming the tray, or the two windows race for it.
    await new Promise((resolve) => setTimeout(resolve, 800))
    if (overlay.status === 'running') return
    await startOverlay()
  })()
}

// ── the trust fence ───────────────────────────────────────────────────────────

function rejectionFor(req) {
  const connection = connectionOf()
  const admit = connection?.admit
  if (typeof admit === 'function') {
    try {
      const admission = admit.call(connection, req)
      const status = admission && typeof admission === 'object' ? admission.rejection : undefined
      return status
    } catch {
      return 503
    }
  }
  return structuralReason(req) === undefined ? undefined : 403
}

function structuralReason(req) {
  const host = authorityOf(req?.headers?.host, 'http')
  if (host === null || !LOOPBACK_NAMES.has(host.hostname)) return 'host-not-loopback'
  if (String(req?.headers?.['sec-fetch-site'] ?? '').toLowerCase() === 'cross-site') return 'cross-site'
  for (const header of ['origin', 'referer']) {
    const raw = req?.headers?.[header]
    if (typeof raw !== 'string' || raw.trim() === '') continue
    const authority = authorityOf(raw.trim())
    if (authority === null) return `${header}-invalid`
    if (authority.scheme !== host.scheme || authority.hostname !== host.hostname || authority.port !== host.port) {
      return `${header}-mismatch`
    }
  }
  return undefined
}

function authorityOf(value, defaultScheme) {
  if (typeof value !== 'string' || value.trim() === '') return null
  let url
  try {
    url = new URL(value.includes('://') ? value.trim() : `${defaultScheme ?? 'http'}://${value.trim()}`)
  } catch {
    return null
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null
  const port = url.port === '' ? (url.protocol === 'https:' ? '443' : '80') : url.port
  return { scheme: url.protocol.replace(':', ''), hostname: url.hostname.toLowerCase(), port }
}
