# MoShot

轻量 macOS 截图标注工具。给没有飞书 / 微信的机器一块顺手的截图能力：框选即标注，回车进剪贴板，⌘S 存文件，P 贴图钉在屏幕上。

原生 AppKit 实现，单份 Swift 源码，不依赖 Xcode 工程、不依赖任何第三方库，`./build.sh` 一条命令出 `.app`。

```
⌥⇧A  框选截图  →  工具条标注  →  Enter 复制 / ⌘S 保存 / P 贴图
```

## 为什么做

飞书、微信自带的截图很好用，但只在你装了它们、并且登录着的时候好用。CI 机器、干净的开发机、跳板机、临时虚拟机通常没有这些 app，系统自带的 ⇧⌘4 又只能截不能标。MoShot 补的就是这个缺口：一个约 350 KB 的菜单栏小工具，双击就能用。

## 功能

| 能力 | 说明 |
| --- | --- |
| 区域截图 | 全屏遮罩 + 拖拽框选，实时显示尺寸；选区可拖动、八个手柄可缩放 |
| 全屏截图 | 菜单栏「全屏截图」，直接进入标注 |
| 矩形 / 椭圆 | 描边，三档线宽 |
| 箭头 | 实心箭头，长度自适应线宽 |
| 画笔 / 荧光笔 | 手绘线条，荧光笔半透明加粗 |
| 马赛克 | 框选区域像素化，适合打码敏感信息 |
| 文字 | 就地输入，回车落字 |
| 序号 | 自动递增编号标记 |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z，也支持 Delete 删除最后一条 |
| 复制 | Enter 或 ⌘C，PNG 进剪贴板 |
| 保存 | ⌘S，默认存到 `~/Downloads/MoShot-<时间戳>.png` |
| 贴图 | P，无边框置顶窗口，可拖动、滚轮缩放、双击关闭、右键复制/保存 |
| 提取文字 | 系统 Vision OCR，中文 + 英文，结果进剪贴板并弹窗可编辑 |
| 多屏 | 每块屏幕独立遮罩，鼠标所在屏获得焦点 |
| 菜单栏常驻 | 无 Dock 图标，不打断工作流 |

## 安装

### 从源码构建（推荐）

需要 macOS 14+ 与 Xcode 命令行工具（`xcode-select --install`）。

```bash
git clone https://github.com/29206394/moshot.git
cd moshot
./build.sh            # 产物在 build/MoShot.app
open build/MoShot.app
```

也可以把 `build/MoShot.app` 拖进 `/Applications`。

### 从 Release 下载

下载 `MoShot.app.zip` 解压后放入 `/Applications`。因为没做 Apple 公证，首次打开需要放行：

```bash
xattr -dr com.apple.quarantine /Applications/MoShot.app
open /Applications/MoShot.app
```

## 首次使用：屏幕录制权限

macOS 不允许任何 app 在未授权时读取屏幕内容。

1. 启动 MoShot，按 `⌥⇧A`
2. 系统弹出「MoShot 想要录制此电脑的屏幕」→ 点「允许」
3. 直接继续截图

如果没弹窗或点过拒绝，到「系统设置 › 隐私与安全性 › 屏幕录制」里勾选 MoShot，然后重新发起截图。

> 用 `./build.sh` 重新构建后，ad-hoc 签名会变，系统可能要求重新勾选一次。稳定使用就别反复重建。

## 快捷键

| 操作 | 按键 |
| --- | --- |
| 触发截图 | `⌥⇧A`（默认，可改） |
| 取消 | `Esc` |
| 复制并退出 | `Enter` / `⌘C` |
| 保存文件 | `⌘S` |
| 贴图 | `P` |
| 撤销 / 重做 | `⌘Z` / `⇧⌘Z` |
| 删除最后一个标注 | `Delete` |
| 切换工具 | `1`–`9`（选择、矩形、椭圆、箭头、画笔、荧光笔、马赛克、文字、序号） |
| 微调选区 | 拖拽选区内部移动，拖拽手柄缩放 |

### 改热键

默认用 `⌥⇧A`，是为了避开飞书和微信占用的 `⌘⇧A`。如果你机器上没装它们，可以改回去：

```bash
defaults write com.moxian.moshot hotkey "cmd+shift+A"
# 重启 MoShot 生效
```

支持 `cmd` / `opt` / `ctrl` / `shift` 组合，也认 `⌘⌥⌃⇧` 符号，例如 `"ctrl+opt+S"`。

## 命令行

无 GUI 模式，方便集成进脚本或 CI：

```bash
MoShot --capture out.png     # 抓主屏存 PNG
MoShot --selftest            # 18 项内置自检（渲染/裁剪/马赛克/编码/剪贴板/OCR）
MoShot --diagnose            # 打印屏幕、权限、热键、状态栏就绪状态
MoShot --version
```

`--selftest` 全部离线跑，不弹窗、不抢焦点，首次 OCR 用例会花约 30 秒加载 Vision 模型。

## 实现要点

```
Sources/
├── main.swift            入口 + CLI（capture / selftest / simulate / diagnose）
├── AppDelegate.swift     菜单栏与生命周期
├── HotKey.swift          Carbon 全局热键 + 配置解析
├── ScreenCapture.swift   ScreenCaptureKit 抓屏，失败回退系统 screencapture
├── OverlayView.swift     遮罩、框选、手柄、标注交互、导出
├── OverlayController.swift  多屏窗口编排、复制/保存/贴图/OCR 调度
├── ToolbarView.swift     浮动工具条（自绘图标、色板、线宽）
├── Support.swift         标注模型、渲染器、像素化、导出
├── PinWindow.swift       贴图窗口
└── SelfTest.swift        内置自检
```

几个实现选择：

- **抓屏**：`CGDisplayCreateImage` 在 macOS 15 被标记 obsoleted，改用 `SCScreenshotManager`。没有权限时回退到 `/usr/sbin/screencapture -D <displayID>`，保证老系统或异常路径也能出图。
- **坐标**：遮罩视图 `isFlipped = true`，鼠标坐标即「原点左上、y 向下」，与 `CGImage` 像素坐标一致，裁切时只需乘 `backingScaleFactor`，不用做 y 翻转。导出时图像段用 y-up 绘制、标注段翻成 y-down，两段各自 `saveGState`，避免整图倒置。
- **热键**：Carbon `RegisterEventHotKey`，不需要辅助功能权限。注意它无法抢占已被其他 app 用 CGEventTap 截走的组合键——飞书就是这么占着 `⌘⇧A` 的，所以默认避开。
- **马赛克**：降采样再最近邻放大，纯 CoreGraphics，不走 CoreImage，结果稳定可测。
- **贴图**：`NSWindow.level = .floating` + `isMovableByWindowBackground`，双击关闭。

## 已知限制

- 选区限制在单块屏幕内，不支持跨屏框选。
- 贴图窗口不随原窗口联动（不做「截图跟随」）。
- OCR 首次调用约 30 秒（Vision 模型冷加载），之后是秒级。
- 没有做代码签名与公证，分发需要手动放行 quarantine。
- 只在 macOS 14 / 15 / 26 上测过。

## License

MIT
