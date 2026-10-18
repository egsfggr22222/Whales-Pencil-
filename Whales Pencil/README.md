# 神笔鲸良（Whale's Pencil）

一块**铺满整个桌面**的透明画布。agent 用任意颜色画，你从托盘取一支红铅笔也能画，**两边都能擦掉对方画的东西**——这样就能靠「指着说」来交流。

不是画在 DSH 窗口里：画布是桌面上的全屏窗口，DSH 也在它下面。

## 两支笔

| | agent | 用户 |
|---|---|---|
| 入口 | `pencil` 工具 | 托盘 **User's Pencil** |
| 颜色 | 任意 | 只有红色（`#FF2020`） |
| 触发 | `action: "draw"` | 左键点托盘 → 拿铅笔 |
| 橡皮擦 | `action: "erase"`（按 id 或矩形） | 作画时**右键拖动** |
| 清除全部 | ✗ **不允许** | 托盘「一键清除」／设置页按钮 |

`agent 不能一键清除`是故意的：清理整块画布等于推翻用户的工作，只有用户能做。agent 想移除自己的东西，用 `erase` 精确点名。

## 用户作画

点托盘（或设置页「拿起铅笔」）后：

- **穿透关闭**：这一层开始接住鼠标，桌面上的点击都落在画布上
- 鼠标**变成铅笔**
- **左键拖动** → 红线
- **右键拖动** → 橡皮擦（擦掉光标下的笔画和文字，agent 的和你的一视同仁）
- **Shift + 右键** → 在原地开一个**文本框**，打字，`Enter` 留下，`Esc` 放弃
- **滚轮** → 调粗细（1–30 px），光标旁显示当前宽度
- **ESC** → 退出作画，穿透恢复，鼠标变回箭头

托盘菜单：拿铅笔 / **呼唤 agent** / 一键清除 / 退出作画 / 退出。

> Windows 11 会把新托盘图标收进溢出区。看不见就点任务栏的 `^` 把它拖出来，或者用设置页那个「拿起铅笔」按钮——两者等价。

## 呼唤 agent

用户没法随时开口，所以托盘给了一个门铃：

1. 点托盘「呼唤 agent」
2. 窗口**抓一张全屏截图**，写到 `~/.dsh/whale-pencil/summon-<时间>.png`
3. 同时写 `summon.json`
4. Host 读到之后，把一条 prompt 投递进**最近用过画笔的那个会话**（`sessionController.prompt`），agent 因而被唤醒并知道去哪看

投递结果写在 `summon-ack.json`，成功是 `{"ok":true}`，失败带 `error`——不静默。

> 这个模型不一定能直接「看」图片。能看的模型会看到截图；不能看的，可以用 `pencil scene` 读笔画与文字，或用像素分析间接判断。

## 托盘为什么要绕一道

托盘图标活在 WinForms 的线程上，窗口活在 WPF 的调度器上。托盘事件里直接改窗口样式会抛跨线程异常，而异常一旦被 `try/catch` 吞掉，就变成**模式改了、样式没改**——表现正是「铅笔拿不起来」。

所以托盘只写一个 `$script:pendingMode`，由窗口自己的 `DispatcherTimer` 在 UI 线程上执行真正的切换。这条路径现在有测试覆盖：切 ink 时 `WS_EX_TRANSPARENT` 消失，切回 idle 时恢复。

## agent 作画

```
pencil { action: "draw",  items: [...] }        // 任意颜色
pencil { action: "erase", ids: ["a3-1"] }       // 精确点名
pencil { action: "erase", rects: [{...}] }      // 按区域，连用户的笔画一起擦
pencil { action: "scene" }                      // 看画板上有什么
pencil { action: "annotate", source: "图.png", items: [...] }
pencil { action: "overlay", overlay: "start" }
```

图元：`rect / ellipse / path / arrow / text / image / pixels`。坐标默认是**桌面物理像素**，`(0,0)` 是屏幕左上角；`unit: "window"` 是屏幕百分比。

## 图片标注

你把图发给我，我画上标注再发回：

```
pencil { action: "annotate", source: "原图.png", items: [{type:"arrow", ...}] }
→ 写出 原图-pencil.png
```

原图不动，结果另存。用 `System.Drawing` 合成，所以不需要 Node 的图像库。

## 为什么这么设计

**两种笔迹分开存。** 不同进程写同一份文件必然打架，所以：

| 文件 | 写者 | 读者 |
|---|---|---|
| `scene.json` | Host（agent） | 窗口 |
| `user.json` | 窗口（用户） | Host |
| `commands.json` | Host | 窗口（agent 擦用户笔画） |
| `clear.txt` | 窗口 | Host（用户清除后同步） |

一个文件只有一个写者，方向永远清晰。

**心跳 + 自报 pid。** 窗口每秒检查 `alive.txt`，超过 6 秒没更新就**自己关掉**——宿主崩了也不会在桌面上留一个永远置顶的透明窗。窗口加载后写 `window.txt` 报自己的 pid，Host 靠它判断存活。

## 三个必须记住的坑

**1. 必须用 `cmd /c start` 启动**

直接 `spawn('powershell.exe')` 拉起的 WPF 窗口和宿主共享窗口站，**秒退且无报错**。`cmd /c start` 让窗口拥有自己的窗口站才能活。代价是拿不到真实 pid，所以才有 `window.txt`。

**2. 高 DPI 缩放要换算**

WPF 用设备无关单位。125% 缩放下 1 单位 = 1.25 物理像素，直接按像素画会放大 25%。窗口加载时用 `GetClientRect ÷ ActualWidth` 量出真实比例，坐标先除掉它。

**3. `pencil.ps1` / `annotate.ps1` 必须纯 ASCII**

Windows PowerShell 5.1 读无 BOM 的 `.ps1` 会用 ANSI 代码页，非 ASCII 会把脚本读坏。所以托盘中文文案是 Host 写进 `labels.json` 再读的，不走命令行、不写在脚本里。

## 结构

| 文件 | 作用 |
|---|---|
| `index.js` | Host：场景、`pencil` 工具、路由、窗口生命周期、图片合成调用 |
| `client.js` | 浏览器：设置页（窗口开关、计数、清除、重启）。**没有页面绘制层** |
| `pencil.ps1` | 桌面窗口 + 托盘：渲染、鼠标作画、右键擦除、滚轮调粗细、ESC 退出 |
| `annotate.ps1` | 图片合成：把图元画到 PNG 上 |

状态目录：`~/.dsh/whale-pencil/`。

## 已知限制

- 只在 **Windows** 上能跑。
- 作画模式会接住整个桌面的鼠标（要画就得这样）；ESC 和托盘的「退出作画」是两个出口。
- 用户只有红色；要换色得由 agent 画，或者后续加调色板。
- 多屏按虚拟屏幕铺满，但坐标原点在主屏左上角。
