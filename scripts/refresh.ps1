<#
.SYNOPSIS
  真实终端凭据失效时，用令牌文件重新注册 GitHub / PyPI。
.DESCRIPTION
  github：备份 hosts.yml → gh auth login --with-token → gh auth setup-git → gh auth status。
  pypi：备份现有 .pypirc → 用令牌文件生成 %USERPROFILE%\.pypirc（username=__token__）。
  只读令牌文件，不打印明文；覆盖 .pypirc 需 -Force；github 刷新始终先备份。
.EXAMPLE
  .\scripts\refresh.ps1 -Provider github
  .\scripts\refresh.ps1 -Provider all -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('github','pypi','all')]
    [string]$Provider = 'all',
    [string]$TokenDir = (Join-Path $env:USERPROFILE '.machine-tokens'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

function Invoke-GitHubRefresh {
    $tokenFile = Join-Path $TokenDir 'github_token.txt'
    if (-not (Test-Path -LiteralPath $tokenFile)) { Write-Error "缺少 $tokenFile"; return }
    $token = (Get-Content -Raw -LiteralPath $tokenFile).Trim()
    $hosts = Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'
    if (Test-Path -LiteralPath $hosts) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $hosts -Destination "$hosts.bak-$stamp" -Force
        Write-Host "已备份 $hosts -> $hosts.bak-$stamp"
    }
    $token | gh auth login --with-token -h github.com -p https
    if ($LASTEXITCODE -ne 0) { throw 'gh auth login 失败' }
    gh auth setup-git
    gh auth status
    if ($LASTEXITCODE -ne 0) { throw 'gh auth status 未通过' }
    Write-Host '[refresh] GitHub 重注册完成' -ForegroundColor Green
}

function Invoke-PyPIRefresh {
    $tokenFile = Join-Path $TokenDir 'pypi_token.txt'
    if (-not (Test-Path -LiteralPath $tokenFile)) { Write-Error "缺少 $tokenFile"; return }
    $token = (Get-Content -Raw -LiteralPath $tokenFile).Trim()
    $pypirc = Join-Path $env:USERPROFILE '.pypirc'
    if (Test-Path -LiteralPath $pypirc) {
        if (-not $Force) { Write-Warning "$pypirc 已存在；加 -Force 覆盖（先备份）"; return }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $pypirc -Destination "$pypirc.bak-$stamp" -Force
        Write-Host "已备份 $pypirc -> $pypirc.bak-$stamp"
    }
    $content = "[distutils]`nindex-servers =`n    pypi`n`n[pypi]`nrepository = https://upload.pypi.org/legacy/`nusername = __token__`npassword = $token`n"
    [IO.File]::WriteAllText($pypirc, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[refresh] PyPI .pypirc 已生成（$pypirc；内含令牌明文，请限制访问权限）" -ForegroundColor Green
}

if ($Provider -in 'github','all') { Invoke-GitHubRefresh }
if ($Provider -in 'pypi','all')   { Invoke-PyPIRefresh }
Write-Host '[refresh] 完成' -ForegroundColor Green