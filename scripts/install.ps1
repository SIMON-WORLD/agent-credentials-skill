<#
.SYNOPSIS
  把 agent-credentials-skill 的技能模板部署到 Codex 技能目录，并初始化令牌目录。
.DESCRIPTION
  默认把 SKILL.md 与 scripts/ 复制到 $HOME\.codex\skills\machine-tokens\；
  创建令牌目录（默认 $env:USERPROFILE\.machine-tokens，可用 -TokenDir 覆盖）；
  -GitHubAccount 指定后会把模板中的 <github-account> 占位符替换为真实账号；
  目标已存在时需 -Force 覆盖（覆盖前先备份）；
  -WriteTokens 交互式写入令牌文件并设置当前用户 ACL。
.EXAMPLE
  .\scripts\install.ps1 -GitHubAccount simon -Force
  .\scripts\install.ps1 -SkillDir D:\tmp\skills\machine-tokens -TokenDir D:\tmp\tokens -Force
#>
[CmdletBinding()]
param(
    [string]$SkillDir = (Join-Path $HOME '.codex\skills\machine-tokens'),
    [string]$TokenDir = (Join-Path $env:USERPROFILE '.machine-tokens'),
    [string]$GitHubAccount = '',
    [switch]$WriteTokens,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$srcSkill = Join-Path $repoRoot 'SKILL.md'
$srcScripts = Join-Path $repoRoot 'scripts'

# 1) 部署技能
if (-not (Test-Path -LiteralPath $srcSkill)) { throw "SKILL.md not found at $srcSkill" }
if (Test-Path -LiteralPath $SkillDir) {
    if (-not $Force) { throw "目标已存在：$SkillDir；加 -Force 覆盖（会先备份）" }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $SkillDir -Destination "$SkillDir.bak-$stamp" -Recurse -Force
    Write-Host "已备份 $SkillDir -> $SkillDir.bak-$stamp"
}
New-Item -ItemType Directory -Force -Path $SkillDir, (Join-Path $SkillDir 'scripts') | Out-Null

if (-not $GitHubAccount) { $GitHubAccount = Read-Host 'GitHub 用户名（用于替换模板占位符，可回车留空）' }
$content = [IO.File]::ReadAllText($srcSkill)
if ($GitHubAccount) { $content = $content.Replace('<github-account>', $GitHubAccount) }
[IO.File]::WriteAllText((Join-Path $SkillDir 'SKILL.md'), $content, (New-Object System.Text.UTF8Encoding($false)))
Copy-Item -LiteralPath (Join-Path $srcScripts 'check.ps1'), (Join-Path $srcScripts 'refresh.ps1') -Destination (Join-Path $SkillDir 'scripts') -Force
Write-Host "技能已部署：$SkillDir"

# 2) 令牌目录
if (-not (Test-Path -LiteralPath $TokenDir)) { New-Item -ItemType Directory -Path $TokenDir -Force | Out-Null }

# 3) 可选写入令牌
if ($WriteTokens) {
    foreach ($name in 'github_token.txt','pypi_token.txt') {
        $file = Join-Path $TokenDir $name
        if (Test-Path -LiteralPath $file) { Write-Host "已存在：$file（跳过）" -ForegroundColor Yellow; continue }
        $v = Read-Host "粘贴 $name 内容（留空跳过）"
        if ($v) {
            [IO.File]::WriteAllText($file, $v.Trim() + "`n", (New-Object System.Text.UTF8Encoding($false)))
            try {
                $acl = Get-Acl -LiteralPath $file
                $acl.SetAccessRuleProtection($true, $false)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME,'FullControl','Allow')
                $acl.AddAccessRule($rule)
                Set-Acl -LiteralPath $file -AclObject $acl
            } catch { Write-Warning "ACL 设置失败（不影响使用）：$($_.Exception.Message)" }
        }
    }
}
Write-Host "安装完成。技能：$SkillDir；令牌目录：$TokenDir" -ForegroundColor Green