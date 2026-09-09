# Twig

一个只保留日常操作的 macOS 原生 Git 工具。SwiftUI 界面，系统 Git，无第三方依赖。

## 启动

需要 macOS 14 或更新版本，以及已安装的 Git（Xcode Command Line Tools 提供）。

```sh
./scripts/build-app.sh
open dist/Twig.app
```

可以把生成的 `dist/Twig.app` 拖入“应用程序”文件夹。构建需要 Xcode 或包含 Swift 的 Command Line Tools；产物针对当前 Mac 的处理器架构，并使用本地临时签名。对外分发还需要开发者签名与公证。

开发时可以用 Xcode 打开 `Package.swift`，选择 Twig 运行；也可以运行 `swift run`。

## 功能

- 左侧工作区导航包含 Commit 与 Stash。Commit 提供文件改动、源文件预览和提交操作；Stash 左侧从上到下显示暂存记录、所选记录的目录树文件和操作按钮，右侧显示文件差异。新建暂存仍从 Commit 的暂存按钮进入。

- 打开本地仓库、克隆 HTTPS / SSH 仓库、最近打开的 8 个仓库。
- 文件区分为“改动的文件”和“非版本控制文件”，各自按紧凑目录树显示，支持逐文件勾选及目录选择。
- 非版本控制文件右键支持“添加到 Git”，加入暂存区后移至“改动的文件”分组，不自动提交。
- 文件区上方提供图标工具栏：刷新本地状态、回滚、Git Stash 暂存、全部展开、全部折叠。回滚先确认文件清单，新增文件移入废纸篓；暂存需要填写说明。
- 源文件视图保留完整上下文，展示原始 / 当前行号；新增行绿色高亮，删除行原位以红色显示，打开时定位第一处改动，并可在标题栏跳转上一处 / 下一处改动。行号栏固定，横向仅滚动代码。
- 勾选文件、填写说明、提交。默认不勾选文件；提交所选文件的**全部当前内容**，保留其他文件已有的暂存内容。首版不支持按行提交。
- 提交说明上方的历史图标可选取当前分支最近 15 次提交的完整说明（含正文），填入输入框。
- 支持“提交并推送”，确认后先提交所选文件再推送当前分支；推送失败时保留本地提交并提示单独重试推送。
- 顶部“获取”用于获取远程状态；另提供仅快进拉取、推送。计数基于上次 fetch；点击刷新图标获取最新远程状态。
- 分支选择紧邻项目名称右侧，分为本地分支和远程分支，按 `/` 组织为目录式子菜单。支持创建本地分支，选择远程分支时切换到已有跟踪分支或创建同名本地跟踪分支。未提交改动如果会被覆盖，Git 会阻止切换。
- 回滚、推送、拉取、携带未提交改动切换分支均需确认；回滚执行前重新核对仓库、HEAD 与文件状态。
- 底部状态栏已移除；耗时操作在顶部显示进度。保留 Finder / 终端入口。
- 明暗外观跟随系统，常用键盘快捷键。

## 操作约定

- 使用系统 Git 配置、凭据助手和 SSH agent。先在终端配置 `user.name`、`user.email` 与远程凭据。本工具不存储密码，也不提供交互式身份验证。
- 拉取不会自动创建合并提交或自动 stash。分支分叉、冲突及进行中的 merge / rebase / cherry-pick / revert 需要在终端处理。
- 首次推送优先使用 `origin`，只有一个其他远程时使用该远程；建立同名上游分支。已有关联时仅推送当前分支到它的上游。
- 游离 HEAD 下可新建分支；在关联分支之前不允许提交或同步。
- 提交失败时 Git 可能已经暂存所选文件；界面会重新读取实际状态，修复原因后重试即可。
- 工作区比较以 HEAD 为基准，没有文本改动时仍显示源文件。超过 2 MB 的源文件不预览，超过 20,000 行时明确提示截断；二进制与非 UTF-8 文件不提供文本预览。
- 外部编辑完成后回到应用会刷新本地状态，也可按 ⌘R 手动刷新。
- Git Stash 仅保存所选文件，包含所选未跟踪文件。可在 Stash 菜单恢复，包括索引状态；存在普通未提交改动时仍允许恢复，由 Git 判断能否安全合并。当前已有冲突或进行中的 Git 操作时禁止恢复。恢复失败或发生冲突时记录保留，工作区可能已恢复部分文件，需手动处理。首次提交之前不可新建 Stash。
- 不支持高级 Git 操作、远程管理、子模块内部管理、PR / Issue 或账号平台集成。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 打开仓库 | ⌘O |
| 克隆仓库 | ⇧⌘O |
| 刷新本地状态 | ⌘R |
| 获取远程状态 | ⇧⌘R |
| 提交所选文件 | ⌘Return |

## 目录

- `Sources/GitStride/GitService.swift`：Git 命令执行、状态解析及仓库操作。
- `Sources/GitStride/RepositoryModel.swift`：界面状态和异步操作协调。
- `Sources/GitStride/ContentView.swift`：仓库界面、文件分区和操作弹窗。
- `Sources/GitStride/ChangeTreeView.swift`：目录树与逐文件选择。
- `Sources/GitStride/BranchMenuItems.swift`：本地 / 远程分支模型与分组菜单。
- `Sources/GitStride/SourcePreview.swift`：目录树模型与完整源文件差异解析。
- `Sources/GitStride/SourceFileView.swift`：源文件标题栏、增删计数与改动跳转。
- `Sources/GitStride/SourceCodeScrollView.swift`：AppKit 代码滚动视图与固定行号栏。
- `Sources/GitStride/StashModels.swift`：Stash 记录与文件模型。
- `Sources/GitStride/StashWorkspaceView.swift`：Stash 列表、文件预览和操作入口。
- `Sources/GitStride/FileActionSheet.swift`：回滚清单确认、暂存说明与操作确认模型。
- `Sources/GitStride/GitStrideApp.swift`：应用入口与菜单。
- `scripts/build-app.sh`：Release 构建、图标生成和 `.app` 打包。

按项目要求不编写测试代码。构建和原生界面检查不依赖测试框架。
