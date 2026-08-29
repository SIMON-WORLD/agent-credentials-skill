# agent-credentials-skill

机器级凭据技能：用「文件注入」方式管理 GitHub / PyPI 等发布令牌，避免 Codex 会话反复走交互式 `gh auth login` 然后失效、空转。

- 本机所有 Codex 会话通用：令牌放 `~/.machine-tokens/`，会话按需读入环境变量。
- 沙箱友好：不依赖系统钥匙串；凭据失效时按统一流程「注入 → 校验 → 刷新」。
- 可扩展：新供应商按五步法接入（见 [docs/providers.md](docs/providers.md)）。
- 凭据上下文选择（v0.3）：在诊断之上，按 profile / account / host 确定性选择已授权的逻辑凭据上下文，默认不做全局 `gh auth switch`。

## 为什么用「文件注入」

- Codex 沙箱读不到 Windows keyring，`gh auth status` 经常误报「未登录」。
- 交互式 `gh auth login` 在沙箱里不可用，反复尝试浪费时间。
- 令牌文件只属于当前用户，注入即用；失效时校验/刷新流程清晰。

## 目录与命名规范

| 供应商 | 文件 | 默认环境变量 |
|---|---|---|
| GitHub | `~/.machine-tokens/github_token.txt` | `GH_TOKEN` |
| PyPI | `~/.machine-tokens/pypi_token.txt` | `TWINE_PASSWORD`（用户名 `__token__`） |

> Windows 下 `~` 即 `%USERPROFILE%`；命令里写 `$env:USERPROFILE\.machine-tokens\...`。

## 安装

克隆或下载本仓库后，运行（Windows PowerShell）：

```powershell
cd agent-credentials-skill
.\scripts\install.ps1 -GitHubAccount <你的 GitHub 用户名>
```

脚本会：

1. 把技能模板部署到 `~\.codex\skills\machine-tokens\`（含 `scripts/`）；
2. 创建 `~\.machine-tokens\`；
3. （可选 `-WriteTokens`）让你粘贴令牌写入文件，并设置当前用户 ACL。

已有文件时先备份，`-Force` 强制覆盖。

## 快速上手

```powershell
# 校验令牌是否有效、是否快过期
.\scripts\check.ps1

# 真实终端凭据失效时重注册（GitHub 重注册 gh；PyPI 生成 .pypirc）
.\scripts\refresh.ps1

# 技能内标准用法：注入后直接操作
$env:GH_TOKEN = (Get-Content -Raw "$env:USERPROFILE\.machine-tokens\github_token.txt").Trim()
gh auth status
```

## 脚本与退出码

| 脚本 | 用途 | 退出码 |
|---|---|---|
| `install.ps1` | 部署技能 + 初始化令牌目录 | 0 成功 |
| `check.ps1` | 逐供应商校验令牌 | 0 全部有效 / 1 存在失效 / 2 存在缺失 |
| `refresh.ps1` | 重注册 gh / 生成 `.pypirc` | 0 成功 |

通用参数：`-TokenDir` 覆盖令牌目录；`-Force` 覆盖前先备份；`-Provider` 可选 `github` / `pypi` / `all`。

## 安全须知

- 真实令牌绝不入库：`.gitignore` 已忽略 `.machine-tokens/`、`*_token.txt`、`.pypirc`。
- 不要在对话/回复里打印令牌明文；脚本只输出掩码。
- 令牌文件放用户私有目录，不要放进项目目录或同步盘。
- 传输令牌走安全通道（U 盘、私有网盘），不要通过聊天/邮件/公共仓库。

## 扩展新供应商

见 [docs/providers.md](docs/providers.md)（五步法：命名 → 注入 → 校验 → 刷新 → 示例）。

## 双 GitHub 账号

见 [examples/dual-github-accounts.md](examples/dual-github-accounts.md)。

## v0.2 — Agent Credential Diagnosis

定位：**Portable credential context for AI agents.** 核心行为规则：**Never re-authenticate before diagnosis.**

生命周期：`Discover → Diagnose → Resolve → Verify → Recover`（v0.2 实现 Discover / Diagnose / Resolve；Verify / Recover 为后续执行层）。

架构分层：

- **Skill / policy layer**：`SKILL.md` 与策略规则（诊断先于重认证、交互认证最后手段）
- **Provider adapters**：`scripts/providers/*.ps1`（发现、认证状态探测、传输探测，输出归一化观察）
- **Diagnosis core**：`scripts/core/diagnosis.ps1`（供应商中立分类器，只消费观察）
- **Resolution policy**：`scripts/core/resolution.ps1`（只推荐、不执行；交互认证仅作为最后手段）
- **Result assembler**：`scripts/core/result.ps1`（组装为公共 `Diagnosis Result v0.2`）
- **Future broker/execution layer**：执行恢复动作（未实现）
- **Plugin/distribution layer**：各生态包装（未实现）

`doctor` 用法（参考 CLI，仅诊断、不认证、不执行恢复）：

```powershell
.\scripts\doctor.ps1 -Provider github          # 人类可读摘要
.\scripts\doctor.ps1 -Provider github -Json    # Diagnosis Result v0.2 JSON
.\scripts\doctor.ps1 -Provider npm             # 参考适配器（实验性）
```

当前支持状况（如实）：

- **GitHub**：完整 doctor 链路（发现 + 认证状态探测 + 传输探测 + 诊断 + 策略 + 组装）。
- **npm**：v0.2 参考/实验适配器（仅发现），用于证明契约的通用性；GitHub 为完整实现。
- **PowerShell 是参考实现**，不是协议要求；契约（schema/注册表/失败分类）语言中立。
- **已知限制**：传输超时/通用传输失败暂无专用诊断码（保守返回 code=null）；Verify/Recover 与 broker 执行层未实现；交互认证永不自动触发。

## v0.3 — Agent Credential Context

定位一句话：**Diagnosis v0.2 告诉 Agent「凭据怎么了」；Credential Context v0.3 决定「这次操作该用哪个已授权的逻辑凭据上下文」。**

v0.3 在 v0.2 诊断之上新增「引用 → Profile → Context」选择层，仍然**按引用不按值**（credentials by reference, not by value），并且默认不做全局 `gh auth switch`。

核心概念：

- **CredentialReference**：一条凭据的逻辑引用（`provider` / `sourceType` / `reference` / 可选 `account` / `profile` / `host`），永远不携带原始凭据值。
- **CredentialProfile**：稳定逻辑档案（如 `personal` / `work`），只选择引用、不含秘密；`account != profile != host`。
- **CredentialContext**：一次操作解析出的上下文（provider / operation / requested/selected profile / expected account/host / availableReferences / selectedReference）。
- **Project binding**：可选的项目/仓库 → provider/profile 绑定，只存逻辑引用，缺省完全向后兼容。
- **确定性 / fail-closed 选择**：同输入同结果；歧义绝不静默选错账号/profile；显式约束绝不被悄悄放宽。
- **进程作用域执行边界**：`execution.ps1` 为参考实现——执行时才解析原始值、只注入子进程环境、父/全局认证状态不变。
- **GitHub 多账号**：同一 host 多个账号各自独立成引用；`active` 只是元数据，不是选择权。
- **npm 第二提供商证明**：同一套通用 resolver / binding 对 GitHub 与 npm 无 provider 分支。

用户用法（选择/解析上下文，**不会自动执行任何子命令**）：

```powershell
# 提供安全引用（JSON 字符串），解析 GitHub 上下文
.\scripts\context.ps1 -Provider github -ReferencesJson '[...]'

# profile / account / host 收窄
.\scripts\context.ps1 -Provider github -Profile personal -ReferencesJson '[...]'
.\scripts\context.ps1 -Provider github -Account alice -HostName github.com -ReferencesJson '[...]'

# npm 上下文选择
.\scripts\context.ps1 -Provider npm -Profile personal -ReferencesJson '[...]'

# 项目绑定概念：绑定产出 requestedProfile / expectedHost，再走同一通用 resolver
.\scripts\context.ps1 -Provider npm -Project pkg/npm-lib -BindingsJson '[{"project":"pkg/npm-lib","provider":"npm","profile":"personal"}]' -ReferencesJson '[...]'

# 机器可读输出（仅消毒逻辑元数据，不声称是 v0.2 Diagnosis Result）
.\scripts\context.ps1 -Provider github -ReferencesJson '[...]' -Json
```

要点澄清：

- `scripts/context.ps1` **只解析/选择上下文**，不自动执行子命令；真正注入执行走 `scripts/core/execution.ps1`（参考进程作用域边界）。
- **原始凭据的解析责任在调用方/执行层**，context 层只接触逻辑引用。
- v0.3 **不是秘密保险库**：不加密、不托管、不轮换原始令牌。
- 当前架构/版本：**v0.3.0**；v0.1 / v0.2 行为保持向后兼容。

## v0.4 — Credential Broker（当前版本 v0.4.0）

完整生命周期：`Discover → Diagnose → Resolve Context → Build Execution Plan → Execute Scoped → Verify → Recover`。

分层边界：

- **v0.2 Diagnosis Result**：回答「凭据怎么了 / 凭据能力是否健康」，不执行恢复。
- **v0.3 Credential Context**：回答「应使用哪个已授权的逻辑凭据上下文」。
- **v0.4 Credential Broker**：回答「执行是否被允许」；当显式请求时，通过进程作用域边界委托执行。

v0.4 公共模型（Credential ExecutionPlan，`schema/credential-plan.schema.json`，contractVersion=0.4.0）：

- gate 状态恰为 `ready | blocked | needs_decision`。
- 凭据按逻辑引用、永不按值。
- `needs_decision` 不可执行；歧义 fail-closed。
- `INTERACTIVE_AUTH` / `reauthRequired` 绝不自动触发认证。

Broker CLI（`scripts/broker.ps1`）：

- **默认（无 `-Execute`）**：仅计划——`诊断摘要 → 绑定/上下文 → ExecutionPlan → 人类可读或 `-Json` 输出`；不做 raw 凭据查找、不启动子进程。
- **显式 `-Execute`**：使用本次调用构建的确切 ExecutionPlan；要求调用方提供可执行文件、逻辑引用 resolver、目标环境变量名等；仅当 gate 真正为 `ready` 才执行；委托给进程作用域执行；父/全局认证状态不变。

示例（参数名与实现一致）：

```powershell
# 仅计划
.\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"}]'
# 机器可读计划
.\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"}]' -Json
# 显式执行（仅当计划 ready；resolver 由调用方提供并只收到逻辑引用）
.\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"}]' -Execute -Executable 'git' -EnvironmentVariable 'GH_TOKEN' -CredentialResolver { param($r) <返回原始值> }
```

安全模型：

- Broker **不是秘密保险库**；不持久化/缓存 raw 凭据。
- raw 凭据解析仅发生在执行边界，经调用方提供的 resolver。
- raw 凭据绝不出现在 ExecutionPlan 或 Broker 结果中。
- 无默认 `gh auth switch` / `login`、`npm login` 或全局凭据变更。
- `blocked` / `needs_decision` 路径不解析 raw 凭据、不启动子进程。

> 当前架构/版本：**v0.4.0**（Credential Broker / ExecutionPlan）；v0.1 / v0.2 / v0.3 行为保持向后兼容。（v0.3.0 历史 tag/Release 仍指向 main=7ff474f。）

## License

MIT，见 [LICENSE](LICENSE)。
