---
name: machine-tokens
description: 本机 GitHub / PyPI 等发布令牌与连接方法（Windows）。任何需要 git push、gh 操作、PR 合并、GitHub Release、PyPI 发布（twine）的任务，开始前必须先读本技能；遇到 401 Unauthorized、认证失败、无权限、推送被拒绝、gh auth status 报 "The token in default is invalid" 或 "Failed to log in"、keyring 不可用时，直接按本技能注入本机令牌文件，不要执行交互式 gh auth login，不要反复尝试其它登录方式。
---

# Machine Tokens（本机发布凭据）

本技能管理本机所有 Codex 会话通用的发布凭据（GitHub / PyPI 等）。令牌存放在用户私有目录 `.machine-tokens`，按供应商一个文件：

- GitHub: `$env:USERPROFILE\.machine-tokens\github_token.txt`（账号：`<github-account>`，全部仓库、含 workflow 权限）
- PyPI: `$env:USERPROFILE\.machine-tokens\pypi_token.txt`（发布项目）

> 非 Windows 平台目录为 `~/.machine-tokens/`，把命令里的 `$env:USERPROFILE` 换成 `$HOME`。

## 使用时机（必读）

- 任何涉及 GitHub / PyPI 的操作（git push、gh 系列命令、PR、Release、twine 发布）开始前，先读本技能。
- `gh auth status` 报 `The token in default is invalid` 或 `Failed to log in`，表示 gh 自身保存的凭据不可用，不是“未登录”；不要执行交互式 `gh auth login`，不要反复测试其它认证方式。
- Codex 沙箱通常读不到系统钥匙串（keyring），因此**沙箱内所有 gh/git 操作一律先注入本机令牌**（见下），再用 `gh auth status` / push 验证。
- 涉及 GitHub 操作时，优先用注入方式；仅在真实终端需要修复 gh 登录态时才重新注册。

安全规则：

- 不要在回复里打印令牌明文，不要提交到仓库。
- 只读文件内容用于构造命令，不要复制到聊天正文。
- 令牌文件只放在用户私有目录（`.machine-tokens`），不要放进项目目录或同步盘。

## 通用模式（注入 → 校验 → 刷新）

1. **注入**：把对应令牌读入环境变量，后续 `gh` / `twine` 命令直接可用。
2. **校验**：运行 `scripts/check.ps1`（本技能随附），确认令牌有效与到期时间。
3. **刷新**：真实终端凭据失效时，运行 `scripts/refresh.ps1` 重新注册（GitHub 重注册 gh；PyPI 生成 `.pypirc`）。

## GitHub

注入令牌：

```powershell
$env:GH_TOKEN = (Get-Content -Raw -LiteralPath "$env:USERPROFILE\.machine-tokens\github_token.txt").Trim()
```

之后 `gh auth status`、`gh api`、`gh pr`、`gh release` 等直接可用。若 gh 报缓存/权限错误：

```powershell
$env:XDG_CACHE_HOME = '<当前任务目录>\04_tmp\gh-cache'
```

git push（Codex 沙箱读不到 keyring 时）：

```powershell
$token = (Get-Content -Raw -LiteralPath "$env:USERPROFILE\.machine-tokens\github_token.txt").Trim()
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
$env:GIT_TERMINAL_PROMPT = '0'
$env:GH_TOKEN = $token
git -c credential.helper= -c credential.https://github.com.helper= -c http.sslBackend=openssl -c http.sslVerify=false -c http.version=HTTP/1.1 -c "http.extraHeader=Authorization: Basic $basic" push origin main
```

- 若报 `detected dubious ownership`，在同一条命令中加 `-c safe.directory='<仓库绝对路径>'`。
- 网络偶发 EOF 属于临时抖动，重试即可。

gh 登录态失效时（真实终端，重新注册，先备份）：

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item "$env:APPDATA\GitHub CLI\hosts.yml" "$env:APPDATA\GitHub CLI\hosts.yml.bak-$stamp" -Force
$token = (Get-Content -Raw -LiteralPath "$env:USERPROFILE\.machine-tokens\github_token.txt").Trim()
$token | gh auth login --with-token -h github.com -p https
gh auth setup-git
gh auth status
```

## PyPI

twine 发布前注入（推荐，避免明文落盘）：

```powershell
$env:TWINE_USERNAME = '__token__'
$env:TWINE_PASSWORD = (Get-Content -Raw -LiteralPath "$env:USERPROFILE\.machine-tokens\pypi_token.txt").Trim()
twine upload dist/*
```

或运行 `scripts/refresh.ps1 -Provider pypi -Force` 生成 `%USERPROFILE%\.pypirc`（`[pypi] username = __token__`，密码读令牌文件，先备份）。PyPI 令牌以 `pypi-` 开头，内含到期时间，可用 `scripts/check.ps1` 解码查看到期日。

## 扩展新供应商

新供应商（npm、Hugging Face、Docker Hub 等）按 `docs/providers.md` 五步法扩展：令牌文件命名 → 注入命令 → 校验 API → 刷新命令 → 示例。

## 排查提示

- 401/403：确认令牌文件存在、未过期；GitHub 需要 repo + workflow 权限，PyPI 需要 upload 权限。
- 其他会话无需用户提示：遇到上述场景应先读本技能并按本技能处理，而不是走 gh auth login 交互流程。
## v0.2 Diagnosis（诊断先行）

**核心规则：Never re-authenticate before diagnosis.**

遇到认证失败时，先运行诊断而不是立即重新登录：

```powershell
# 仓库内（agent-credentials-skill）运行诊断 CLI
.\scripts\doctor.ps1 -Provider github
.\scripts\doctor.ps1 -Provider github -Json
```

- 诊断只回答「证据支持什么结论」，不执行恢复、不触发交互认证。
- `gh auth status` 是证据不是判决；失败可能源于 keyring 可见性、网络、工具或作用域。
- 交互认证仅作为最后手段，且需要诊断 + 非交互路径穷尽 + 用户同意。
- 本技能继续管理 `.machine-tokens` 文件注入（v0.1，向后兼容）；v0.2 在其上增加诊断层。

## v0.3 Credential Context（凭据上下文）

完整工作流：`Discover → Diagnose → Resolve Context → Execute Scoped → Verify → Recover`。

- v0.2 Diagnosis 回答「凭据怎么了」；v0.3 Credential Context 回答「这次操作该用哪个已授权的逻辑凭据上下文」。
- **按引用不按值**：context 层、绑定、公共输出只携带逻辑引用（`env/GH_TOKEN`、`cli/<host>/<account>`、`config/<registry>/<account>`、`connector/...`），原始值只在进程作用域执行边界内、执行时才解析。

Agent 必须遵守的规则：

1. **Never re-authenticate before diagnosis**（诊断先于重认证，v0.2 规则延续）。
2. **绝不因为某个凭据引用存在就选它**（never select the first reference merely because it exists）；选择必须确定性、可复现。
3. **显式 profile / account / host 约束绝不被悄悄放宽**；缺元数据的引用不能算作匹配。
4. **歧义引用 → fail closed**：多个等价候选且无规则区分时，不选任何引用，交由策略/人工升级。
5. **项目绑定是可选的**：无绑定时保持 v0.1 / v0.2 行为；绑定只存逻辑引用，不含秘密。
6. **active GitHub 账号只是元数据**，不是自动选择依据；选择权在通用 resolver。
7. **优先进程作用域凭据效果**：`scripts/core/execution.ps1` 只在子进程环境注入，父/全局认证状态不变；避免全局 `gh auth switch`。
8. **原始秘密永不进入公共 Diagnosis Result / Credential Context / Agent 可见输出**。

用法（选择/解析上下文，不自动执行子命令）：

```powershell
# 仓库内运行（v0.3.0）
.\scripts\context.ps1 -Provider github -ReferencesJson '[...]'
.\scripts\context.ps1 -Provider github -Profile personal -ReferencesJson '[...]'
.\scripts\context.ps1 -Provider npm -Profile personal -ReferencesJson '[...]'
.\scripts\context.ps1 -Provider github -ReferencesJson '[...]' -Json
```

- `scripts/context.ps1` 只解析/选择上下文；真正执行注入用 `scripts/core/execution.ps1`（参考进程作用域边界）。
- v0.3 不是秘密保险库；原始凭据解析是调用方/执行层责任。
- v0.1 `.machine-tokens` 文件注入、v0.2 doctor 诊断层全部保持向后兼容。

## v0.4 Credential Broker（当前版本 v0.4.0）

Agent 必须遵守的规则：

1. **执行前总是先构建/检查计划**（build & inspect plan before execution）。
2. **绝不执行非 ready 计划**。
3. **绝不把 blocked / needs_decision 重新解释为 ready**。
4. **计划中的确切所选逻辑引用就是执行权威**。
5. **计划创建后不做第二次凭据选择**。
6. **raw 凭据 resolver 回调是执行边界的责任**（Broker 只传逻辑引用）。
7. **默认仅计划（plan-only）**；`-Execute` 是显式 opt-in。
8. **无自动重认证 / 恢复**；`INTERACTIVE_AUTH`/`reauthRequired` 只是决策标记，不触发认证。
9. **保持 v0.1 / v0.2 / v0.3 兼容语义**。

Broker 用法（`scripts/broker.ps1`）：

```powershell
# 仅计划（默认）
.\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[...]'
# 机器可读
.\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[...]' -Json
# 显式执行（仅 ready；resolver 调用方提供）
.\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[...]' -Execute -Executable 'git' -EnvironmentVariable 'GH_TOKEN' -CredentialResolver { param($r) <原始值> }
```

- Broker 不持久化/缓存/解析 raw 凭据；raw 值仅瞬时存在于执行边界子进程作用域。
- 无默认 `gh auth switch` / `login`、`npm login` 或全局认证变更。
- 当前架构/版本：**v0.4.0**（Credential Broker / ExecutionPlan）；v0.1 / v0.2 / v0.3 行为保持向后兼容。

## v0.5 Credential Resolver（引用 → 运行时私有凭据）

Agent 必须遵守的规则：

1. **计划所选引用就是权威**：resolver 只解析计划里那一条逻辑 `CredentialReference`，绝不二次选账号/profile/引用，绝不回退、不放宽约束。
2. **raw 凭据是运行时私有的**：`CredentialMaterial` 只瞬态存在于执行边界，绝不序列化/记录/持久化/缓存，也绝不出现在任何公共结果。
3. **resolver 选择 ≠ 凭据选择**：能力匹配是纯函数（`Select-AgentCredentialResolver`），fail-closed；零匹配/多匹配/不兼容一律拒绝，绝不按数组顺序取默认。
4. **PowerShell 是参考实现，不是协议**：`[scriptblock]` resolver 与 `scripts/core/execution.ps1` 只是运行时绑定；协议运行时中立，未来可用其他语言实现而不改公共契约。
5. **resolver 不自动认证**：`INTERACTIVE_AUTH`/`reauthRequired` 仍是决策标记，不触发认证。
6. **provider 适配器 ≠ resolver 实现**：`scripts/providers/*` 发现/适配；resolver 是「把引用解析成私有凭据」的能力。
7. **`.machine-tokens` 只是参考存储约定**，不是协议要求；可移植 resolver 不得假设固定文件路径。

公共契约：`schema/credential-resolver.schema.json`（`0.5.0`，只含 `ResolverDescriptor` / `ResolverOutcome`，不含 raw `CredentialMaterial`）、`scripts/validate-resolver.ps1`、`fixtures/v0.5/...`、`scripts/core/resolver.ps1`（纯匹配 + 运行时私有参考绑定）。

Broker 可选 resolver 能力门禁（向后兼容；不传 descriptor 仍走原有回调）：

```powershell
.\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[...]' -ResolverDescriptorsJson '[...]' -Execute -Executable 'git' -EnvironmentVariable 'GH_TOKEN' -CredentialResolver { param($r) <原始值> }
```
