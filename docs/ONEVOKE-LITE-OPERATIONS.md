# Onevoke Lite 项目全流程操作手册

本文按个人开发的实际顺序说明 Onevoke Lite: 项目安装, 规则接入, 初始化, 记任务, 启动 Agent, 测试, QA, Git 集成, 看板完成, 升级与排障.

Lite 的目标是保持一条短路径:

```text
Inbox -> Todo -> Doing -> Done
            |
            v
       Executor -> 验证 -> S: 直接集成
                          M/L: 一次 QA -> 集成
```

日常角色只有 Executor 和 QA Reviewer. 两者都从 Codex 或 Claude 中选择. PM, CSA, Hacker 默认关闭, Classic 模式仍保留完整兼容能力.

## 1. 先选择安装作用域

| 方式 | 适合场景 | 配置和规则位置 | 调用方式 |
|---|---|---|---|
| 项目安装, 推荐 | 每个项目独立配置和规则, 不污染其他项目 | `<主 worktree>/.onevoke/` | 始终用项目内绝对命令 |
| 全局安装 | 多个项目共用同一配置 | `~/.config/onevoke`, `~/.agents`, `~/.local/bin` | 命令根已在 PATH 后可直接调用 |

本文以项目安装为主. 项目安装不会读取或修改 HOME 下的全局 Onevoke 安装, 也不会修改 PATH.

Codex 会先读取全局 `~/.codex/AGENTS.md`, 再从项目根到当前目录逐层读取适用的 `AGENTS.md`; 更靠近目标文件的规则优先. 因此 Onevoke 项目安装把接入点放在主 worktree 根目录. 机制说明见 [Codex 官方 AGENTS.md 文档](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

## 2. 准备环境

必须具备:

- Python 3.
- Git, 且目标目录是 Git 仓库.
- Codex CLI 或 Claude Code 至少一个.
- POSIX 使用 `install.sh`; 原生 Windows 使用 PowerShell 和 `install.ps1`.

POSIX 若选择 `tmux` 或 `tmux-session` launcher, 还要安装 tmux. 不使用 tmux 时可选 `foreground`. Windows 可选 `console` 或 `foreground`.

## 3. 安装到项目

先取得 Onevoke 源码, 再从 Onevoke 源码目录运行安装器. `<项目绝对路径>` 可以是目标项目主 worktree, 也可以是它的任一已登记 worktree; 安装器会统一定位主 worktree.

POSIX:

```sh
./install.sh --project <项目绝对路径>
```

原生 Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 --project <项目绝对路径>
```

成功后项目布局如下:

```text
<项目根>/
├── .onevoke/
│   ├── bin/                 Onevoke, kb, kanban, review 和记忆合并入口
│   ├── rules/               Onevoke 规则分册
│   ├── share/               Web 看板资源
│   └── config.json          首次配置后生成
├── AGENTS.md                Codex/Grok 项目规则入口
└── kanban/                  首次初始化后生成的本机看板数据
```

安装器总是在本仓库的 `.git/info/exclude` 中加入 `/.onevoke/`; 自动创建根 `AGENTS.md` 时再加入 `/AGENTS.md`. 它不会修改共享的 `.gitignore`.

### 3.1 项目 `AGENTS.md` 如何处理

- 根目录没有 `AGENTS.md`: POSIX 自动创建指向 `.onevoke/rules/ONEVOKE-AGENTS.md` 的相对符号链接; Windows 优先创建硬链接并回落到符号链接. 自动入口只在本仓库本地忽略, 不会进入提交.
- 根目录已有 `AGENTS.md`: 安装器原样保留, 不把它加入 exclude, 也不改正文. 在已有文件加入下面这条项目规则:

```md
- 开始任务前必须读取并遵守 `.onevoke/rules/ONEVOKE-AGENTS.md`.
```

这条引用必须是正文中的正向指令. 注释, 代码块, `不要读取` 或 `已废弃` 之类否定语句不会通过 `onevoke doctor`.

Claude 项目规则入口是项目根 `CLAUDE.md`. 使用 Claude 且已有该文件时, 加入项目规则入口的导入; 可使用安装器输出的绝对规则路径:

```md
@<项目绝对路径>/.onevoke/rules/ONEVOKE-AGENTS.md
```

## 4. 首次配置

项目模式禁止用 PATH 中可能存在的全局同名命令. 以下 POSIX 变量只用于缩短示例, 值必须是目标项目的绝对路径:

```sh
PROJECT_ROOT="<项目绝对路径>"
ONEVOKE_BIN="$PROJECT_ROOT/.onevoke/bin"
cd "$PROJECT_ROOT"
"$ONEVOKE_BIN/onevoke" welcome
```

Windows PowerShell:

```powershell
$ProjectRoot = "<项目绝对路径>"
& "$ProjectRoot\.onevoke\bin\onevoke.cmd" welcome
```

Lite 推荐配置:

- 工作流: `Lite`.
- Executor: `codex` 或 `claude`.
- QA Reviewer: 与 Executor 相同即可; 想减少同源盲点时可选另一个.
- 审核环节: `PM=skip CSA=skip Hacker=skip QA=auto`.
- POSIX launcher: 已使用 tmux 选 `tmux`; 想自动维护独立 session 选 `tmux-session`; 当前终端等待执行选 `foreground`.
- Windows launcher: 日常后台独立窗口选 `console`; 当前窗口等待选 `foreground`.
- MemSearch: 可选. 需要跨任务回忆历史决策时启用; 不需要时关闭不会影响看板, Review 或 Git 流程.

直接回车保存当前配置. 输入 `q` 退出且不保存. 以后重新打开配置菜单:

```sh
"$ONEVOKE_BIN/onevoke" welcome --reset
```

核验配置和接入状态:

```sh
"$ONEVOKE_BIN/onevoke" mode
"$ONEVOKE_BIN/onevoke" config
"$ONEVOKE_BIN/onevoke" doctor
```

`doctor` 应显示项目安装模式, 项目规则入口, 项目命令路径, Agent 能力和当前配置. 若它仍报告 `~/.codex/AGENTS.md`, 通常是误用了全局 `onevoke`; 改用项目 `.onevoke/bin/onevoke` 的绝对入口.

## 5. 初始化看板

在目标项目首次执行:

```sh
cd "$PROJECT_ROOT"
"$ONEVOKE_BIN/kb" init "$PROJECT_ROOT"
"$ONEVOKE_BIN/kanban" check
```

初始化会在主 worktree 创建唯一的 `kanban/` 数据目录和底层 6 个状态目录, 并仅在本仓库的 `.git/info/exclude` 中忽略 `/kanban/`. 所有任务 worktree 共用主 worktree 这一份看板, 不复制数据.

Lite 对外只显示 4 个状态:

| Lite | 底层兼容状态 | 含义 |
|---|---|---|
| Inbox | `backlog` | 先记录, 还未承诺执行 |
| Todo | `todo` | 契约完整, 等待领取 |
| Doing | `working` | 实现, 验证, Review 或集成中 |
| Done | `done` | 验证和适用集成都完成 |

`archived` 和 `trash` 仍保留给 Classic 和历史管理, `kb list/web/tui` 默认不显示它们.

## 6. 日常用法

### 6.1 只记录一个想法

```sh
"$ONEVOKE_BIN/kb" add "研究 ClickHouse 分组优化"
```

默认创建 S 卡并进入 Inbox. 中文标题会自动得到可用 task ID, 同日重名自动追加序号.

指定规模和类型:

```sh
"$ONEVOKE_BIN/kb" add --size M --type feature "增加批量导入接口"
"$ONEVOKE_BIN/kb" add --size L --type feature "重构 IP 定位流水线"
```

类型可选 `feature`, `bug`, `chore`, `research`.

### 6.2 立即交给 Agent

新任务直接创建, 领取并启动:

```sh
"$ONEVOKE_BIN/kb" do "修复登录重试"
```

领取已有 Inbox 或 Todo 卡:

```sh
"$ONEVOKE_BIN/kb" do <task-id>
```

指定本次 Agent, launcher 或隔离策略:

```sh
"$ONEVOKE_BIN/kb" do --size M --agent codex --launcher tmux-session "增加导出接口"
"$ONEVOKE_BIN/kb" do --size L --worktree required "重构数据迁移模块"
```

`kb do` 合并 `add -> pick -> start`. 启动成功后卡片进入 Doing. 启动准备失败时, 新建 worktree 和卡片状态会尽量原子回滚; 卡片保留在 Todo 供排查或重试.

### 6.3 查看任务

```sh
"$ONEVOKE_BIN/kb" list
"$ONEVOKE_BIN/kb" list inbox
"$ONEVOKE_BIN/kb" list doing
"$ONEVOKE_BIN/kb" show <task-id>
"$ONEVOKE_BIN/kanban" check
```

手机竖屏终端可用:

```sh
"$ONEVOKE_BIN/kb" list --mobile
```

### 6.4 Web 和 TUI

Web 看板:

```sh
"$ONEVOKE_BIN/kb" web --open
```

默认地址是 `http://127.0.0.1:8080`. 端口占用时可加 `--port 8081`.

终端看板:

```sh
"$ONEVOKE_BIN/kb" tui
"$ONEVOKE_BIN/kb" tui --single
```

Lite Web/TUI 与 `kb list` 一样只展示 Inbox, Todo, Doing, Done. Web 和 TUI 都是只读界面; 创建, 领取和迁移仍通过命令完成. Windows Python 没有可用 `curses` 时使用 Web 看板.

## 7. S, M, L 如何选择

| 规模 | 典型任务 | 任务卡 | Review | 默认 Git/worktree |
|---|---|---|---|---|
| S | SQL, 小函数, 小 Bug, 脚本微调 | 单文件轻量卡 | 跳过 | 安全时使用当前分支 |
| M | 新接口, 跨文件功能, 算法调整 | 单文件轻量卡 | 一次 QA | 可选, `auto` 先尝试安全当前树 |
| L | 新系统, 大重构, 跨模块迁移 | 目录卡和强制 `spec.md` | 一次 QA | 强制独立 worktree |

规模不是测试强度的替代品. S 虽然默认不 Review, 仍必须运行与改动相称的测试和静态检查.

L 卡的 `spec.md` 是权威任务契约, 至少写清目标, 预期成果, 验收条件和不在本轮范围. S/M 使用轻量卡; 不强迫先写完整 Spec.

## 8. worktree 策略

`kb start` 和 `kb do` 支持:

- `--worktree auto`: 默认. S/M 先使用当前工作树; 当前树必须干净, 不能是 detached HEAD, 也不能位于 `main/master`. 不安全时自动创建任务 worktree. L 等同 `required`.
- `--worktree current`: 强制当前工作树并执行上述安全检查. L 拒绝此选项.
- `--worktree required`: 创建或复用 `<主 worktree>/worktrees/<task-id>/` 及同名任务分支.

有 `origin` 时, 自动创建 worktree 会先同步并基于 `origin/develop`; 没有 `origin` 时基于本地 `develop`. 缺少所需 `develop` 时停止并报告, 不猜测其他分支.

实用选择:

- 当前正在 `develop`, 工作树干净, 只有一个小任务: S/M 用 `auto`.
- 当前有未提交改动, 任务要并行, 或需要隔离危险操作: 用 `required`.
- 大型任务: 使用 L, 让系统强制隔离.

## 9. 执行, 验证和 QA

Agent 启动后会读取项目 `AGENTS.md`, Onevoke 入口和任务卡, 再执行以下闭环:

1. 核对任务目标和不在本轮范围.
2. 实现最小完整改动.
3. 运行与风险相称的测试, 静态检查和格式检查.
4. 提交任务改动, 保持 worktree 干净.
5. S 默认跳过 Review; M/L 运行一次 QA.
6. 处理 QA 中经主 Agent 核实成立的 blocking, high, medium 问题, 然后重跑 QA.
7. 集成到 `develop`, 合并 MemSearch 记忆, 清理任务 worktree/分支, 最后把卡片迁到 Done.

Lite 默认审核策略:

```text
PM=skip CSA=skip Hacker=skip QA=auto
```

项目规则或当前用户指令可以提高审核级别. `review_stages.<role>=required` 会越过规模默认值. 需要明确强制某个被 Lite 跳过的角色时, Agent 通过 `onevoke review --force ...` 进入统一门禁; 不要绕过 Onevoke 直接调用 Reviewer CLI.

## 10. Git 集成和完成条件

Onevoke 固定使用 `main + develop`:

- `develop` 是日常集成分支.
- `main` 是稳定分支.
- 看板任务验证和必要 QA 通过后默认 fast-forward 集成到 `develop`, 不等待额外验收.
- `main` 只从 `develop` 前进, 必须由用户明确要求发布或合入.
- `main` 和 `develop` 永不 force-push, 集成不得产生 merge commit.

任务处于 Doing 时, 可能正在实现, 测试, QA, rebase, push 或清理; 不能因为代码写完就提前改成 Done. 只有以下步骤全部完成后才能进入 Done:

- 实现完成.
- 验证通过并记录结果.
- 需要的 QA 已通过.
- 任务提交已进入 `develop`, 或项目明确使用其他获准集成流程.
- MemSearch 记忆合并成功或确认没有来源记忆.
- 任务 worktree 和临时分支按规则清理完成.

需要发布稳定分支时, 对 Agent 明确说:

```text
请将当前已验证的 develop fast-forward 合入 main, 推送 develop 和 main, 然后运行安装器更新本机 Onevoke.
```

## 11. 切换回 Classic

查看或切换模式:

```sh
"$ONEVOKE_BIN/onevoke" mode
"$ONEVOKE_BIN/onevoke" mode classic
"$ONEVOKE_BIN/onevoke" mode lite
```

Classic 继续使用底层 6 状态, 完整 `kanban` 命令和 PM/CSA/Hacker/QA 角色. 旧配置没有 `workflow_mode` 字段时按 Classic 解释, 不会静默改成 Lite.

## 12. 升级项目安装

在 Onevoke 源码仓库同步新版本后, 对目标项目重新运行同一个 `--project` 命令即可. 安装器会更新项目 `.onevoke/bin`, `.onevoke/rules` 和 `.onevoke/share`, 保留项目配置, 看板数据和已有根 `AGENTS.md`.

升级后检查:

```sh
"$ONEVOKE_BIN/onevoke" doctor
"$ONEVOKE_BIN/onevoke" config
"$ONEVOKE_BIN/kanban" check
"$ONEVOKE_BIN/kb" list
```

## 13. 常见问题

### 13.1 仍提示未发现 `~/.codex/AGENTS.md`

当前调用的是全局 Onevoke. 项目模式必须使用 `<项目根>/.onevoke/bin/onevoke` 的绝对入口. 运行绝对入口后, 提示应指向项目根 `AGENTS.md`.

### 13.2 提示项目 `AGENTS.md` 未接入

确认项目根文件是自动链接, 或已有正文包含这条正向指令:

```md
- 开始任务前必须读取并遵守 `.onevoke/rules/ONEVOKE-AGENTS.md`.
```

然后重新运行项目绝对入口的 `onevoke doctor`.

### 13.3 tmux 已安装但不在 session

launcher 选择 `tmux` 时, 启动命令本身必须位于 tmux session 内. 不想先进入 tmux 时改用 `tmux-session`; 想在当前终端等待 Agent 时改用 `foreground`.

### 13.4 `auto` 没用当前分支

当前树可能位于 `main/master`, 处于 detached HEAD, 或包含未提交/未跟踪改动. `auto` 会为保护现有工作自动隔离. 先查看 Git 状态, 不要用清理命令丢弃用户改动.

### 13.5 L 任务无法启动

L 必须创建独立 worktree. 有远端时需要可同步的 `origin/develop`; 仅本地时需要本地 `develop`. 先修复分支基线或网络问题, 再用原 task ID 重试.

### 13.6 Web 端口占用

```sh
"$ONEVOKE_BIN/kb" web --port 8081 --open
```

### 13.7 MemSearch 未启用

不影响任务完成. 集成后的记忆合并命令在没有 `.memsearch/memory` 时是成功的空操作. 只有需要跨任务检索历史决策时才安装和启用 MemSearch.

## 14. 安全卸载项目副本

项目安装不提供自动删除命令. 卸载前先确认目标是具体项目的 `.onevoke/`, 不是 HOME, 工作区根或其他共享目录.

1. 若项目根 `AGENTS.md` 是安装器创建且仍指向 `.onevoke/rules/ONEVOKE-AGENTS.md`, 先移除该入口. 已有或已自行编辑的 `AGENTS.md` 保留, 只删除其中的 Onevoke 引用.
2. 将该项目的 `.onevoke/` 移到系统废纸篓, 保留恢复机会.
3. 从该仓库 `.git/info/exclude` 移除 `/.onevoke/`; 仅在自动入口已删除时再移除 `/AGENTS.md`.
4. `kanban/` 是任务历史, 不随程序卸载自动删除. 只有确认不再需要且已备份时才单独处理.

## 15. 最短命令清单

```sh
# 首次
"$ONEVOKE_BIN/onevoke" welcome
"$ONEVOKE_BIN/kb" init "$PROJECT_ROOT"
"$ONEVOKE_BIN/onevoke" doctor

# 日常
"$ONEVOKE_BIN/kb" add "记录想法"
"$ONEVOKE_BIN/kb" do "立即执行一个 S 任务"
"$ONEVOKE_BIN/kb" do --size M "执行一个需要 QA 的任务"
"$ONEVOKE_BIN/kb" do --size L --worktree required "执行大型任务"
"$ONEVOKE_BIN/kb" list
"$ONEVOKE_BIN/kb" web --open

# 诊断
"$ONEVOKE_BIN/onevoke" config
"$ONEVOKE_BIN/onevoke" doctor
"$ONEVOKE_BIN/kanban" check
```
