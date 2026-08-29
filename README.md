# agent-credentials-skill

机器级凭据技能：用「文件注入」方式管理 GitHub / PyPI 等发布令牌，避免 Codex 会话反复走交互式 `gh auth login` 然后失效、空转。

- 本机所有 Codex 会话通用：令牌放 `~/.machine-tokens/`，会话按需读入环境变量。
- 沙箱友好：不依赖系统钥匙串；凭据失效时按统一流程「注入 → 校验 → 刷新」。
- 可扩展：新供应商按五步法接入（见 [docs/providers.md](docs/providers.md)）。

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

## License

MIT，见 [LICENSE](LICENSE)。
