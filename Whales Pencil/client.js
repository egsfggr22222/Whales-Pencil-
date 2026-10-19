/**
 * whale-pencil — browser half: the settings page only.
 *
 * There is deliberately no drawing layer in the page. The board is the desktop
 * window, which already covers the whole screen including this window, so a
 * second renderer here would paint the same marks twice. The page exists to
 * switch the window on and off, read the counters, and clear up.
 */
window.__ModuleLoader__.load({
  id: 'whale-pencil',
  factory(require) {
    const React = require('react')
    const { createElement: h, useEffect, useState } = React

    /** Locale namespace these strings register under. */
    const NS = 'settings.whalePencil'
    /** Route prefix the Host half serves. */
    const ROUTE = (() => {
      try {
        return new URL('api/whale-pencil', document.baseURI).pathname
      } catch {
        return '/api/whale-pencil'
      }
    })()
    /** Poll cadence for the Host document. */
    const POLL_MS = 900
    /** How often an open conversation re-asserts that it is the active one. */
    const ACTIVE_CLAIM_MS = 4000

    const DICT = {
      zh: {
        'meta.title': '神笔鲸良',
        'meta.description': '铺满桌面的透明画布：agent 用任意颜色画，用户从托盘取一支红铅笔，两边都能擦掉对方画的东西。',
        nav: '神笔鲸良',
        'page.title': '神笔鲸良',
        'page.description': '即 Whale\'s Pencil：一块覆盖整个桌面的透明画布。agent 和用户共用它 —— 谁画的都能被对方擦掉。',
        'section.board': '画布',
        'window.title': '桌面窗口',
        'window.hint': '一个全屏透明窗口，托盘里会出现 User\'s Pencil。点托盘左键拿铅笔；作画时左键画红线、右键当橡皮擦、滚轮调粗细、ESC 退出。',
        'window.starting': '正在启动…',
        'window.running': '运行中',
        'window.stopped': '已关闭',
        'window.error': '启动失败：{message}',
        'section.stats': '画布内容',
        'stats.agent': 'agent 画的图元',
        'stats.user': '用户画的笔画',
        'stats.agentHint': 'agent 用 pencil 工具画的，任意颜色。',
        'stats.userHint': '你在桌面上用铅笔画的，红色。',
        'section.actions': '操作',
        'action.pencil': '拿铅笔',
        'action.pencilHint': '等于点托盘里的「拿铅笔」：关闭穿透、鼠标变铅笔。ESC 或「放下铅笔」退出。',
        'action.pencilOn': '拿起铅笔',
        'action.pencilOff': '放下铅笔',
        'action.clear': '一键清除',
        'action.clearHint': '清掉画布上的所有内容：agent 的和你的。托盘菜单里也有这一项。',
        'action.restart': '重启桌面窗口',
        'action.restartHint': '窗口卡住或托盘图标不见了时用这个。',
        'page.offline': '未连上插件后端：读不到画布内容。',
        'page.saved': '状态自动同步',
        'tray.note': '托盘菜单：拿铅笔 / 一键清除 / 退出作画 / 退出',
      },
      en: {
        'meta.title': '神笔鲸良',
        'meta.description': 'A transparent canvas across the desktop: the agent paints in any colour, the user takes a red pencil from the tray, and either can erase what the other drew.',
        nav: '神笔鲸良',
        'page.title': '神笔鲸良',
        'page.description': 'Whale\'s Pencil: a transparent canvas covering the whole desktop, shared by the agent and the user — each can erase what the other drew.',
        'section.board': 'Board',
        'window.title': 'Desktop window',
        'window.hint': 'A full-screen transparent window; User\'s Pencil appears in the tray. Left-click the tray for the pencil: left draws red, right erases, the wheel sets thickness, ESC leaves draw mode.',
        'window.starting': 'Starting…',
        'window.running': 'Running',
        'window.stopped': 'Stopped',
        'window.error': 'Failed to start: {message}',
        'section.stats': 'On the board',
        'stats.agent': 'Agent marks',
        'stats.user': 'Your strokes',
        'stats.agentHint': 'Painted with the pencil tool, in any colour.',
        'stats.userHint': 'Drawn by you on the desktop, in red.',
        'section.actions': 'Actions',
        'action.pencil': 'Take the pencil',
        'action.pencilHint': 'Same as the tray entry: turns off click-through and turns the pointer into a pencil. ESC or Drop leaves draw mode.',
        'action.pencilOn': 'Take the pencil',
        'action.pencilOff': 'Drop the pencil',
        'action.clear': 'Clear everything',
        'action.clearHint': 'Removes every mark, yours and the agent\'s. Also in the tray menu.',
        'action.restart': 'Restart the window',
        'action.restartHint': 'Use this when the window is stuck or the tray icon vanished.',
        'page.offline': 'Plugin backend unreachable: the board cannot be read.',
        'page.saved': 'State syncs automatically',
        'tray.note': 'Tray menu: take the pencil / clear everything / stop drawing / quit',
      },
    }

    /** Fallback translator for a section rendered without the shell's own `t`. */
    let boundT = (key) => key

    const store = {
      view: { enabled: false, revision: 0, userStrokes: 0, layers: [], status: 'stopped', error: '' },
      status: 'loading',
    }
    const listeners = new Set()

    function publish(patch) {
      Object.assign(store, patch)
      for (const listener of [...listeners]) {
        try { listener() } catch { /* a broken subscriber must not stop the others */ }
      }
    }

    async function request(path, options) {
      const { timeout = 15000, ...rest } = options ?? {}
      const controller = new AbortController()
      const timer = setTimeout(() => controller.abort(), timeout)
      try {
        const response = await fetch(`${ROUTE}${path}`, { redirect: 'error', ...rest, signal: controller.signal })
        const text = await response.text()
        const payload = text === '' ? {} : JSON.parse(text)
        if (!response.ok) throw new Error(String(payload?.error ?? `HTTP ${response.status}`))
        return payload
      } finally {
        clearTimeout(timer)
      }
    }

    function adopt(payload) {
      publish({
        view: {
          enabled: payload?.enabled === true,
          revision: Number.isFinite(payload?.revision) ? payload.revision : 0,
          userStrokes: Number.isFinite(payload?.userStrokes) ? payload.userStrokes : 0,
          layers: Array.isArray(payload?.layers) ? payload.layers : [],
          status: typeof payload?.status === 'string' ? payload.status : 'stopped',
          error: typeof payload?.error === 'string' ? payload.error : '',
        },
        status: 'ready',
      })
    }

    async function refresh() {
      try {
        adopt(await request('/state'))
      } catch {
        publish({ status: 'error' })
      }
    }

    function Switch(props) {
      return h('button', {
        type: 'button',
        className: 'wp_switch',
        role: 'switch',
        'aria-checked': props.checked === true ? 'true' : 'false',
        'aria-label': props.label,
        disabled: props.disabled === true,
        onClick: props.onChange,
      }, h('i'))
    }

    function Row(props) {
      return h('div', { className: 'wp_row' },
        h('div', { className: 'wp_rowText' },
          h('div', { className: 'wp_rowTitle' }, props.title),
          h('div', { className: 'wp_rowHint' }, props.hint)),
        props.control)
    }

    function SettingsPage(props) {
      const t = typeof props.t === 'function' ? props.t : boundT
      const [snapshot, setSnapshot] = useState({ ...store, view: store.view })

      useEffect(() => {
        const listener = () => setSnapshot({ ...store, view: store.view })
        listeners.add(listener)
        listener()
        return () => { listeners.delete(listener) }
      }, [])

      useEffect(() => {
        void refresh()
        const timer = setInterval(() => {
          if (document.visibilityState === 'hidden') return
          void refresh()
        }, POLL_MS)
        return () => clearInterval(timer)
      }, [])

      const status = snapshot.view.status
      const error = snapshot.view.error
      const busy = status === 'starting'
      const statusText = status === 'running'
        ? t('window.running')
        : status === 'starting'
          ? t('window.starting')
          : status === 'error'
            ? t('window.error').replace('{message}', error === '' ? '?' : error)
            : t('window.stopped')

      const call = async (path, body) => {
        try {
          adopt(await request(path, {
            method: 'POST',
            headers: body === undefined ? undefined : { 'content-type': 'application/json' },
            body: body === undefined ? undefined : JSON.stringify(body),
            timeout: 30000,
          }))
        } catch {
          void refresh()
        }
      }

      return h('div', { className: 'wp_root' },
        h('header', { className: 'wp_head' },
          h('h2', { className: 'wp_title' }, t('page.title')),
          h('p', { className: 'wp_desc' }, t('page.description'))),

        h('div', { className: 'wp_section' }, t('section.board')),
        h(Row, {
          title: t('window.title'),
          hint: status === 'error' ? statusText : t('window.hint'),
          control: h('div', { className: 'wp_controls' },
            h('span', { className: 'wp_status' + (status === 'error' ? ' wp_status_error' : '') }, statusText),
            h(Switch, {
              checked: status === 'running' || busy,
              disabled: busy,
              label: t('window.title'),
              onChange: () => void call(status === 'running' ? '/overlay/stop' : '/overlay/start'),
            })),
        }),

        h('div', { className: 'wp_section' }, t('section.stats')),
        h(Row, {
          title: t('stats.agent'),
          hint: t('stats.agentHint'),
          control: h('span', { className: 'wp_count' }, String(snapshot.view.layers.length)),
        }),
        h(Row, {
          title: t('stats.user'),
          hint: t('stats.userHint'),
          control: h('span', { className: 'wp_count' }, String(snapshot.view.userStrokes)),
        }),

        h('div', { className: 'wp_section' }, t('section.actions')),
        h(Row, {
          title: t('action.pencil'),
          hint: t('action.pencilHint'),
          control: h('div', { className: 'wp_controls' },
            h('button', {
              type: 'button',
              className: 'wp_btn',
              onClick: () => void call('/mode', { mode: 'ink' }),
            }, t('action.pencilOn')),
            h('button', {
              type: 'button',
              className: 'wp_btn',
              onClick: () => void call('/mode', { mode: 'idle' }),
            }, t('action.pencilOff'))),
        }),
        h(Row, {
          title: t('action.clear'),
          hint: t('action.clearHint'),
          control: h('button', {
            type: 'button',
            className: 'wp_btn',
            onClick: () => void call('/clear'),
          }, t('action.clear')),
        }),
        h(Row, {
          title: t('action.restart'),
          hint: t('action.restartHint'),
          control: h('button', {
            type: 'button',
            className: 'wp_btn',
            onClick: () => void call('/overlay/stop').then(() => call('/overlay/start')),
          }, t('action.restart')),
        }),

        h('footer', { className: 'wp_footer' },
          h('span', { className: 'wp_note' }, t('tray.note')),
          snapshot.status === 'error'
            ? h('span', { className: 'wp_note wp_note_error' }, t('page.offline'))
            : h('span', { className: 'wp_note' }, t('page.saved'))))
    }

    const CSS = `
.wp_root{display:flex;flex-direction:column;color:var(--dsw-alias-label-primary)}
.wp_head{padding:2px 0 14px}
.wp_title{margin:0 0 6px;font-size:16px;font-weight:600;line-height:24px;letter-spacing:-.1px}
.wp_desc{margin:0;font-size:13px;line-height:20px;color:var(--dsw-alias-label-secondary)}
.wp_section{padding:18px 0 6px;font-size:12px;font-weight:600;letter-spacing:.02em;color:var(--dsw-alias-label-tertiary)}
.wp_row{display:flex;align-items:center;gap:24px;padding:12px 0;border-top:1px solid var(--dsw-alias-border-l1)}
.wp_rowText{flex:1;min-width:0}
.wp_rowTitle{font-size:14px;font-weight:500;line-height:22px}
.wp_rowHint{margin-top:2px;font-size:12px;line-height:18px;color:var(--dsw-alias-label-tertiary)}
.wp_controls{display:flex;align-items:center;gap:10px;flex:none}
.wp_status{font-size:12px;line-height:18px;color:var(--dsw-alias-label-tertiary);max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.wp_status_error{color:var(--dsw-alias-state-error-primary)}
.wp_count{font-size:13px;line-height:18px;color:var(--dsw-alias-label-secondary);font-variant-numeric:tabular-nums;min-width:32px;text-align:right}
.wp_btn{font:inherit;font-size:12px;line-height:18px;padding:6px 12px;border-radius:8px;border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);cursor:pointer;white-space:nowrap}
.wp_btn:hover{filter:brightness(1.06)}
.wp_note{font-size:12px;line-height:18px;color:var(--dsw-alias-label-tertiary);margin:0}
.wp_note_error{color:var(--dsw-alias-state-error-primary)}
.wp_footer{display:flex;align-items:center;gap:10px;padding-top:16px;border-top:1px solid var(--dsw-alias-border-l1);flex-wrap:wrap}
.wp_switch{display:inline-flex;align-items:center;cursor:pointer;user-select:none;-webkit-tap-highlight-color:transparent;background:0 0;border:0;padding:0;flex:none}
.wp_switch i{width:36px;height:20px;border-radius:999px;background:var(--dsw-alias-bg-layer-1);border:1px solid var(--dsw-alias-border-l2);box-shadow:inset 0 1px 3px rgb(0 0 0 / 8%);position:relative;transition:background .2s ease,border-color .2s ease;flex:none}
.wp_switch i::after{content:"";position:absolute;top:2px;left:2px;width:14px;height:14px;border-radius:50%;background:var(--dsw-alias-label-secondary);box-shadow:0 1px 3px rgb(0 0 0 / 22%);transition:transform .26s cubic-bezier(.34,1.3,.64,1),background .2s ease}
.wp_switch[aria-checked="true"] i{background:var(--dsw-alias-state-business-primary);border-color:color-mix(in srgb,var(--dsw-alias-state-business-primary) 85%,#000)}
.wp_switch[aria-checked="true"] i::after{transform:translateX(16px);background:#fff}
.wp_switch:disabled{opacity:.5;cursor:default}
`

    function apply(ctx) {
      const t = ctx.locale.bind(NS)
      boundT = t
      ctx.effect(() => ctx.locale.register(NS, { zh: DICT.zh, en: DICT.en }), 'whale-pencil: dictionaries')
      ctx.effect(() => {
        const style = document.createElement('style')
        style.setAttribute('data-plugin', 'whale-pencil')
        style.textContent = CSS
        document.head.appendChild(style)
        return () => style.remove()
      }, 'whale-pencil: styles')

      void refresh()

      ctx.slots.inject('settings.section', () => ctx.slots.register({
        name: 'settings.section',
        id: 'whale-pencil',
        order: 45,
        label: () => t('nav'),
        locale: NS,
      }, (props) => h(SettingsPage, { ...props, t: typeof props?.t === 'function' ? props.t : t })))

      // The Host cannot see which conversation the user is looking at, so this
      // seat reports it: the slot is session-scoped, so its `sessionId` prop is
      // the open chat. The component renders nothing; its only job is the claim.
      ctx.slots.inject('conversation.input.left', () => ctx.slots.register({
        name: 'conversation.input.left',
        id: 'whale-pencil-active',
        order: 900,
      }, (props) => {
        const { sessionId } = props ?? {}
        useEffect(() => {
          if (typeof sessionId !== 'string' || sessionId === '') return undefined
          let cancelled = false
          const claim = () => {
            if (cancelled) return
            void fetch(`${ROUTE}/active-session`, {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ sessionId }),
              redirect: 'error',
            }).catch(() => {})
          }
          claim()
          // Re-claim while this conversation stays mounted: the Host keeps the
          // most recent claim, so being the last to speak is being the active one.
          const timer = setInterval(claim, ACTIVE_CLAIM_MS)
          return () => {
            cancelled = true
            clearInterval(timer)
          }
        }, [sessionId])
        return null
      }))
    }

    return { inject: ['slots', 'locale'], apply }
  },
})
