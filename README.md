# Whale's Pencil

[中文 README](https://github.com/egsfggr22222/Whales-Pencil-/blob/main/Whales%20Pencil/README.md)

A transparent canvas that **covers the entire desktop**. The agent can draw in any color, and you can draw with a red pencil picked up from the floating ball — **either side can erase what the other has drawn**, so you can communicate by "pointing at things."

It is not drawn inside the DSH window: the canvas is a full-screen window on the desktop, and DSH sits beneath it.

## Four Interface Elements

| Element | What it is | When it appears |
|---|---|---|
| **Floating ball** | A 52×52 red-and-black ball. Double-click to open the canvas, right-click for the menu | Always on screen, draggable anywhere |
| **Canvas** | A full-screen transparent layer for drawing, writing, erasing | Double-click the ball to enter, `Esc` to leave |
| **Dynamic island** | A status capsule at the top centre of the screen | Appears while the agent works, disappears when it finishes |
| **Menus** | 2 items on the ball, 4 on the canvas | Right-click |

## The Floating Ball

**Double left-click** → open the canvas (the ball hides)
**Single left-click** → nothing (guards against accidents)
**Drag** → move it anywhere; native OS dragging, fully responsive
**Right-click** → menu: `Summon agent` / `Clear all`

The ball can be dragged to a screen edge and will hang off it, but never further than 16 px — it cannot be dragged out of reach.

> The ball is a **separate window**, not painted on the canvas. The canvas is click-through while idle, so anything painted on it could not be clicked.

## Canvas Controls

| Action | Effect |
|---|---|
| **Left-drag** | Draw a red line |
| **Shift + left-click** | Eraser (erases strokes and text under the cursor) |
| **Right-click** | Open the menu (**does not erase**) |
| **Scroll wheel** | Adjust thickness (1–30 px), with the width shown next to the cursor |
| **Esc** | Leave the canvas; the ball returns |

Canvas menu (4 items):

```
Text box
─────────
Summon agent
Clear all
─────────
Exit drawing
```

**"Text box" opens its input at the right-click position**, not in a fixed corner.

## Text Is a Copyable Container

Text is not a picture; it is a real text container. **The user's text and the agent's text behave identically**:

| Action | Effect |
|---|---|
| Hover | Cursor becomes an I-beam |
| Drag | **Selects character by character** |
| Double-click | Selects a word |
| `Ctrl + A` | Select all |
| **`Ctrl + C`** | **Copies to the system clipboard** |

The boxes are read-only `TextBox` controls, so selection and copying are native Windows behaviour.

## Entering Text

Right-click → "Text box" → an input appears where you clicked:

- **Enter** → new line (genuinely multi-line)
- **Click outside the box** → commit
- **Esc** → cancel

On commit it becomes a red text label and is written to `user.json` for the agent to read.

## Dynamic Island

A translucent capsule at the **top centre of the screen** showing what the agent is doing:

| State | Shows | Dot colour |
|---|---|---|
| Thinking | `Thinking 5s` | Grey-blue |
| Reading | `Reading eye 3s` | Cyan |
| Calling a tool | `Calling pencil 12s` | Green |
| Idle | **Disappears entirely** | — |

**A red stop button sits on its right** → clicking it aborts the agent's task and the island vanishes immediately.

The island is a **separate window** so it can be clicked (the canvas itself is click-through).

## Summoning the Agent

Right-click the ball (or the canvas menu) → "Summon agent":

1. The window **captures a full-screen screenshot** and delivers it to the model through the attachment service
2. It also writes `summon.json`
3. When the Host reads it, it delivers a prompt into **the session that most recently used the pencil**
4. The agent wakes up with the screenshot attached

The delivery result is written to `summon-ack.json`; success is `{"ok":true}`, failure carries an `error` — nothing is silent.

## Agent Drawing

```
pencil { action: "draw",  items: [...] }        // any color
pencil { action: "erase", ids: ["a3-1"] }       // name precisely
pencil { action: "erase", rects: [{...}] }      // by region
pencil { action: "scene" }                      // see what's on the canvas
pencil { action: "annotate", source: "img.png", items: [...] }
pencil { action: "overlay", overlay: "start" }
```

Primitives: `rect / ellipse / path / arrow / text / image / pixels`. Coordinates default to **desktop physical pixels**, with `(0,0)` at the top-left of the screen; `unit: "window"` uses screen percentages.

**The agent cannot clear everything at once** — wiping the whole canvas would overturn the user's work, and only the user may do that. If the agent wants to remove its own things, it uses `erase` to name them precisely.

## Image Annotation

```
pencil { action: "annotate", source: "original.png", items: [{type:"arrow", ...}] }
→ writes Processed image/original-pencil-20261019135723.png
```

The original is untouched; the result is saved separately. All output goes into the `Processed image` folder.

## Why It's Designed This Way

### Three Separate Windows

| Window | Purpose | Clicks |
|---|---|---|
| Canvas | Drawing | Only while drawing; click-through otherwise |
| Floating ball | Entry point | Always |
| Dynamic island | Status | Always (stop button) |

**They must be separate.** The canvas is `WS_EX_TRANSPARENT` (click-through) while idle, so a button painted on it could never be clicked. This is a trap that was hit three times.

### File Channels

The two processes communicate through files, one writer per file:

| File | Writer | Reader |
|---|---|---|
| `scene.json` | Host (agent) | window |
| `user.json` | window (user) | Host |
| `commands.json` | Host | window |
| `clear.txt` | window | Host |
| `stop.txt` | window (stop button) | Host |
| `status.json` | Host | window (dynamic island) |

**Why the stop button uses a file instead of HTTP**: the DSH web service only admits requests carrying a live session. The board window is a separate process with no session, so an HTTP request comes back 401.

### Heartbeat

The window checks `alive.txt` every second and **closes itself** if it hasn't been updated for more than 6 seconds — so if the host crashes, it won't leave an always-on-top transparent window on the desktop.

## Five Pitfalls You Must Remember

**1. You must launch with `cmd /c start`**

Spawning `powershell.exe` directly makes the WPF window share the host's window station, and it **exits instantly with no error**.

**2. High-DPI scaling must be converted**

WPF uses device-independent units. At 125% scaling, drawing directly in physical pixels comes out 25% too large.

**3. `pencil.ps1` must be pure ASCII**

Windows PowerShell 5.1 reads BOM-less `.ps1` files using the ANSI code page. Chinese labels go through `labels.json`.

**4. PowerShell comments must not contain backticks**

A backtick is an escape character; inside a comment it still breaks parsing, and the reported error points somewhere far away.

**5. A borderless window cannot be dragged with `DragMove()`**

`DragMove()` needs a caption or a resize frame. A `WindowStyle = 'None'` window has neither, so it **fails silently**. Use `ReleaseCapture()` + `SendMessage(WM_SYSCOMMAND, SC_MOVE)` instead.

## Structure

| File | Role |
|---|---|
| `index.js` | Host: scene, `pencil` tool, routing, window lifecycle, dynamic-island state |
| `client.js` | Browser: settings page |
| `pencil.ps1` | Desktop window: canvas + floating ball + dynamic island |
| `annotate.ps1` | Image composition |
| `locate.ps1` | Locate the plugin directory |
| `skills/` | The `pencil-board` and `pencil-summon` skill documents |

State directory: `~/.dsh/whale-pencil/`

## Known Limitations

- Only runs on **Windows**.
- Drawing mode catches the mouse across the entire desktop (necessary to draw at all).
- The user only has red; changing colors requires the agent to draw.
- Multi-monitor setups span the virtual screen, but the coordinate origin is the top-left of the primary monitor.
- Text selection is driven manually by the board (because the canvas owns the mouse). It is character-accurate but not a full text box: no drag-and-drop, no context menu.
