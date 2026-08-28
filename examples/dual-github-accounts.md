# 双 GitHub 账号

同一台机器管理两个 GitHub 账号时，每个账号一个令牌文件：

- 默认账号：`~/.machine-tokens/github_token.txt`
- 第二账号：`~/.machine-tokens/github_token_<alias>.txt`（如 `github_token_work.txt`）

## 按命令切换（gh）

```powershell
# 账号 A（默认文件）
$env:GH_TOKEN = (Get-Content -Raw "$env:USERPROFILE\.machine-tokens\github_token.txt").Trim()
gh api user --jq '.login'

# 账号 B
$env:GH_TOKEN = (Get-Content -Raw "$env:USERPROFILE\.machine-tokens\github_token_work.txt").Trim()
gh api user --jq '.login'
```

每次命令前注入对应令牌即可；gh 只认当前环境变量。

## 按仓库固定账号（git push）

Windows credential helper 默认只记住一组 github.com 凭据，容易串号。对每个仓库用对应的令牌显式推送：

```powershell
# 仓库 A 推送到账号 A
$token = (Get-Content -Raw "$env:USERPROFILE\.machine-tokens\github_token.txt").Trim()
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
$env:GIT_TERMINAL_PROMPT = '0'
$env:GH_TOKEN = $token
git -c credential.helper= -c "http.extraHeader=Authorization: Basic $basic" push origin main

# 仓库 B 推送到账号 B：把 token 文件换成 github_token_work.txt，重复上面的命令
```

真实终端也可用 `gh auth login` 登录两个账号后用 `gh auth switch` 切换（Codex 沙箱内不适用）。

## 注意

- 双账号文件同样遵守安全规则：不进仓库、不打印明文、不放同步盘。
- `scripts/check.ps1` 默认只校验 `github_token.txt`；第二账号文件可用 `-TokenDir` 指向临时目录单独校验，或自行扩展脚本。