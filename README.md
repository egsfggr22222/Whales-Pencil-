# Whale's Pencil

[中文 README](https://github.com/egsfggr22222/Whales-Pencil-/blob/main/Whales%20Pencil/README.md)

A transparent canvas that **covers the entire desktop**. The agent can draw in any color, and you can draw with a red pencil picked up from the tray — **either side can erase what the other has drawn**, so you can communicate by "pointing at things."

It is not drawn inside the DSH window: the canvas is a full-screen window on the desktop, and DSH sits beneath it.

## Two Pencils

| | agent | user |
|---|---|---|
| Entry | `pencil` tool | tray **User's Pencil** |
| Color | any | red only (`#FF2020`) |
| Trigger | `action: "draw"` | left-click tray → pick up pencil |
| Eraser | `action: "erase"` (by id or rect) | **right-drag** while drawing |
| Clear all | ✗ **not allowed** | tray "Clear All" / settings-page button |

`The agent cannot clear everything at once` is intentional: wiping the whole canvas would overturn the user's work, and only the user may do that. If the agent wants to remove its own things, it uses `erase` to name them precisely.

## User Drawing

After clicking the tray (or "Pick Up Pencil" on the settings page):

- **Click-through disabled**: this layer starts catching the mouse, and all desktop clicks land on the canvas
- The mouse **turns into a pencil**
- **Left-drag** → red line
- **Right-drag** → eraser (erases strokes and text under the cursor, the agent's and yours alike)
- **Shift + right-click** → open a **text box** in place, type, `Enter` to keep it, `Esc` to discard
- **Scroll wheel** → adjust thickness (1–30 px), with the current width shown next to the cursor
- **ESC** → exit drawing mode, click-through restored, mouse back to an arrow

Tray menu: Pick Up Pencil / **Summon agent** / Clear All / Exit Drawing / Exit.

> Windows 11 tucks new tray icons into the overflow area. If you can't see it, click `^` on the taskbar and drag it out, or use the "Pick Up Pencil" button on the settings page — the two are equivalent.

## Summoning the Agent

The user can't speak up at any time, so the tray provides a doorbell:

1. Click "Summon agent" in the tray
2. The window **captures a full-screen screenshot** and writes it to `~/.dsh/whale-pencil/summon-<time>.png`
3. It also writes `summon.json`
4. When the Host reads it, it delivers a prompt into **the session that most recently used the pencil** (`sessionController.prompt`), so the agent wakes up and knows where to look

The delivery result is written to `summon-ack.json`; success is `{"ok":true}`, failure carries an `error` — nothing is silent.

> This model may not be able to "see" images directly. Models that can will see the screenshot; those that can't can use `pencil scene` to read strokes and text, or infer indirectly via pixel analysis.

## Why the Tray Takes a Detour

The tray icon lives on the WinForms thread, while the window lives on the WPF dispatcher. Changing window styles directly in a tray event throws a cross-thread exception, and once an exception is swallowed by `try/catch`, it becomes **mode changed, style not changed** — which manifests exactly as "the pencil won't pick up."

So the tray only writes a `$script:pendingMode`, and the window's own `DispatcherTimer` performs the actual switch on the UI thread. This path now has test coverage: switching to ink removes `WS_EX_TRANSPARENT`, and switching back to idle restores it.

## Agent Drawing

```
pencil { action: "draw",  items: [...] }        // any color
pencil { action: "erase", ids: ["a3-1"] }       // name precisely
pencil { action: "erase", rects: [{...}] }      // by region, erasing the user's strokes too
pencil { action: "scene" }                      // see what's on the canvas
pencil { action: "annotate", source: "img.png", items: [...] }
pencil { action: "overlay", overlay: "start" }
```

Primitives: `rect / ellipse / path / arrow / text / image / pixels`. Coordinates default to **desktop physical pixels**, with `(0,0)` at the top-left of the screen; `unit: "window"` uses screen percentages.

## Image Annotation

You send me an image, I draw annotations on it and send it back:

```
pencil { action: "annotate", source: "original.png", items: [{type:"arrow", ...}] }
→ writes original-pencil.png
```

The original is untouched; the result is saved separately. Composition uses `System.Drawing`, so no Node image library is needed.

## Why It's Designed This Way

**The two kinds of strokes are stored separately.** Different processes writing the same file will inevitably conflict, so:

| File | Writer | Reader |
|---|---|---|
| `scene.json` | Host (agent) | window |
| `user.json` | window (user) | Host |
| `commands.json` | Host | window (agent erasing user strokes) |
| `clear.txt` | window | Host (sync after user clears) |

One file, one writer — the direction is always clear.

**Heartbeat + self-reported pid.** The window checks `alive.txt` every second, and **closes itself** if it hasn't been updated for more than 6 seconds — so if the host crashes, it won't leave an always-on-top transparent window on the desktop. After loading, the window writes `window.txt` to report its own pid, and the Host uses that to judge liveness.

## Three Pitfalls You Must Remember

**1. You must launch with `cmd /c start`**

Spawning `powershell.exe` directly makes the WPF window share the host's window station, and it **exits instantly with no error**. `cmd /c start` gives the window its own window station so it can survive. The cost is that you can't get the real pid — hence `window.txt`.

**2. High-DPI scaling must be converted**

WPF uses device-independent units. At 125% scaling, 1 unit = 1.25 physical pixels, so drawing directly in pixels comes out 25% too large. On load, the window measures the real ratio with `GetClientRect ÷ ActualWidth`, and coordinates are divided by it first.

**3. `pencil.ps1` / `annotate.ps1` must be pure ASCII**

Windows PowerShell 5.1 reads BOM-less `.ps1` files using the ANSI code page, and non-ASCII characters corrupt the script. That's why the tray's Chinese labels are written by the Host into `labels.json` and read from there — not passed on the command line, not written in the script.

## Structure

| File | Role |
|---|---|
| `index.js` | Host: scene, `pencil` tool, routing, window lifecycle, image-composition calls |
| `client.js` | Browser: settings page (window toggle, counts, clear, restart). **No page drawing layer** |
| `pencil.ps1` | Desktop window + tray: rendering, mouse drawing, right-click erase, scroll-wheel thickness, ESC exit |
| `annotate.ps1` | Image composition: draw primitives onto a PNG |

State directory: `~/.dsh/whale-pencil/`.

## Known Limitations

- Only runs on **Windows**.
- Drawing mode catches the mouse across the entire desktop (necessary to draw at all); ESC and the tray's "Exit Drawing" are the two ways out.
- The user only has red; changing colors requires the agent to draw, or a palette added later.
- Multi-monitor setups span the virtual screen, but the coordinate origin is the top-left of the primary monitor.
