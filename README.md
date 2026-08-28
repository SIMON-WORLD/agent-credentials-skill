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

## License

MIT，见 [LICENSE](LICENSE)。