# Pi Desktop

[![CI](https://github.com/FlashingChen/pi-desktop/actions/workflows/ci.yml/badge.svg)](https://github.com/FlashingChen/pi-desktop/actions/workflows/ci.yml)

原生 macOS 桌面客户端，使用 SwiftUI + AppKit，为已安装的原版 [Pi](https://github.com/earendil-works/pi) 提供图形外壳。

Pi Desktop 启动机器上已安装的原版 `pi` 可执行文件；不复制、不修改 Agent、模型实现、工具实现或原生会话。GUI 不直接调用任何模型 API，也不建立第二套对话数据库。

## 环境要求

- macOS 14 或更高版本
- 原版 Pi CLI（实测 1.4.0），以及它使用的 Node 运行时（如通过 npm 安装）
- 首次构建需要 Swift 工具链与网络（拉取锁定的 SwiftTerm 1.20.0）

应用使用登录 Shell 环境查找 `pi` 与运行时，因此支持通过 Homebrew、nvm 或其他 PATH 管理方式安装的 Pi。自动查找失败时，可在设置中选择可执行文件。Pi 的模型凭据由 Pi 自行读取；兼容接口可在 **设置 → 模型** 中配置，OAuth 登录仍在应用内 **Pi CLI** 完成。

## 下载与自动化构建

GitHub Actions 在 Apple Silicon 与 Intel 两种运行器上运行单元测试；推送到 `main` 后还会构建 Release 应用包，可在该次运行的 Artifacts 中下载（保留 7 天）。

打 `v*` 标签会触发发布工作流，为两种架构分别生成 `Pi-Desktop-<版本>-<架构>.zip` 与对应 `.sha256`，并附到 GitHub Release：

```sh
unzip Pi-Desktop-0.1.0-arm64.zip
xattr -dr com.apple.quarantine "Pi Desktop.app"   # 未公证，首次打开前按需执行
open "Pi Desktop.app"
```

构建使用本机临时签名，未经 Developer ID 签名与 Apple 公证，Gatekeeper 可能要求在「系统设置 → 隐私与安全性」中放行。

## 从源码构建

```sh
./scripts/build-app.sh          # Release，产物在 build/Pi Desktop.app
./scripts/build-app.sh debug    # Debug
```

构建完成后可直接双击 `build/Pi Desktop.app`，或复制到 `~/Applications` 后从 Spotlight / Dock 启动，无需预先打开终端。

脚本使用 SwiftPM native 构建系统，避免依赖本机未安装的 Xcode Metal 组件。SwiftTerm 的默认 AppKit 渲染器用于终端；Metal 渲染器不是运行要求。当前打包使用本机临时签名（ad hoc），未做 Developer ID 签名与公证，适合本机使用。

## 使用

1. 打开项目文件夹。Pi 以该文件夹为工作目录，加载原有配置、`AGENTS.md`、Skills、提示词和 Extensions。
2. 左侧以「项目 → 会话」呈现原生 JSONL 会话。切换、续聊、新建和改名均调用 Pi 官方 RPC。
3. 模型与思考档位从 Pi 实时读取。输入 `/` 菜单可发现 Skills、提示词与扩展命令；图片通过 Pi 原生 prompt 图片格式发送。
4. 运行期间可使用 Pi 原有的 Steer / Follow-up 消息队列。停止按钮调用 Pi abort；等待中的文字会返回输入框。
5. `!command` 和 `!!command` 调用 Pi 的 Bash 功能，后者不将结果加入模型上下文。
6. 侧栏可切换 **会话／文件**。文件目录按展开层级加载，支持只读文本预览、显示隐藏文件、在默认应用或 Finder 中打开。会话右键菜单可重命名；Skill 展开内容不会直接成为列表标题。
7. 在模型选择器的齿轮按钮或 **设置 → 模型** 中添加、编辑提供商和模型，配置写入 Pi 原生 `models.json`。保存保留未修改的凭据和其他配置；空闲时点击 **重新加载** 后选择模型。
8. 点击右上角 **Pi CLI**，使用应用内真实 PTY 运行原版交互界面。内置 `/settings`、`/login`、`/tree`、`/fork`、`/resume`、主题、所有 TUI 扩展和 CLI 快捷键均由 Pi 提供。退出原版 Pi（例如空输入时 Ctrl+D）后返回 GUI，由 Pi 恢复该项目最近的原生会话。

快捷键：`⌘O` 打开项目，`⌘N` 新会话，`⌘K` 搜索，`⌘⇧P` 打开 Pi 资源命令，`⌘⇧T` 进入 Pi CLI，`⌘,` 设置。

## 边界

- 应用只在 UserDefaults 中保存项目文件夹引用、最近项目和外壳设置。切换期间未发送的文字和图片仅保存在内存中，不保证退出应用后恢复。不建立聊天数据库，不写入或转换 Pi 会话。
- 打开设置、文件预览或改变窗口焦点不会主动中断 Agent。保存外壳设置不重连，连接参数在下次连接生效；运行期间切换或新建会话会提示等待或手动中止，不自动 abort。当前每个应用实例由一个活动 RPC 会话执行任务。
- 默认读取 `~/.pi/agent/sessions`，遵循 `PI_CODING_AGENT_DIR`、`PI_CODING_AGENT_SESSION_DIR`、用户/项目 `sessionDir`；设置中的自定义目录对应 Pi `--session-dir`。可通过 File → 打开原生会话载入其他位置的 `.jsonl`。
- 使用同一原生文件，可以在 GUI 和外部 CLI 继续对话。请先退出另一端正在使用的同一会话；应用内部会先等 RPC 进程退出，再启动 TUI，避免同时写入。
- Pi 官方 RPC 不支持自定义 TUI 组件、原生交互命令和部分终端 UI 方法。完整功能通过应用内原版 **Pi CLI** 保留。GUI 转发 RPC 支持的扩展选择、确认、输入、编辑、通知、状态和文本组件；不会声称所有终端扩展都能被原生控件替代。
- 不新增权限控制、Plan Mode、Subagents、独立工作流、离线消息重放或会话同步系统。用户原先安装的 Pi 扩展仍按 Pi 自己的行为加载。
- 应用未打包 Pi/Node，也不自动安装或更新它们。它是可独立启动的桌面外壳，不是包含另一套 Agent 的发行版。
- 当前 Markdown 以原生富文本与代码块呈现；复杂 Markdown 表格等仍可能以文本显示。完整终端呈现随时可在 Pi CLI 中使用。

## 测试

```sh
swift test --build-system native
python3 scripts/smoke-real-pi.py
```

单元测试覆盖原生控件悬停进入/离开、禁用控件不亮起、JSONL 分片与 Unicode、请求乱序关联、原生会话只读索引、工作目录隔离、进程退出后重启、扩展取消会话切换时保持当前对话、命令面板渲染与交互回归、大历史解析与启动基准。真实 Pi 冒烟测试在临时目录中验证 RPC、原生 JSONL 续聊/改名、自定义模型发现和扩展 UI，不发起模型请求。

可选的实时目录与启动基准测试默认跳过，按测试文件中的环境变量开启。

## 项目结构

```text
Sources/PiDesktop/     应用源码（RPC、会话索引、视图、输入、终端、交互样式）
Tests/PiDesktopTests/  单元与回归测试
Resources/Info.plist   应用包元数据
scripts/               构建、图标生成、真实 Pi 冒烟测试
DESIGN.md              视觉与交互规范
PRODUCT.md             产品定位与约束
THIRD_PARTY_NOTICES.md 第三方组件与参考声明
```

## 第三方与致谢

Pi Desktop 通过官方 RPC 调用独立安装的 Pi，并在原生终端中嵌入其交互界面；Pi 自身的许可证适用于其分发。终端控件使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）。视觉参考为 [open-claude-ui](https://github.com/Caho1/open-claude-ui)，本实现独立转译其设计取值，不包含其 React 代码或字体、图像等资源。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
