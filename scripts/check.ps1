<#
.SYNOPSIS
  校验 ~/.machine-tokens 下各供应商令牌是否有效。
.DESCRIPTION
  GitHub：优先调用 gh api user（无 gh 时 REST 回退），报告登录账号。
  PyPI：解码 pypi- 令牌内嵌到期时间（pypi.org 令牌在 base64 payload 中含 ISO 日期）。
  只输出掩码，不打印明文。
  退出码：0=全部有效；1=存在失效；2=存在缺失。
.EXAMPLE
  .\scripts\check.ps1
  .\scripts\check.ps1 -Provider github
  .\scripts\check.ps1 -TokenDir D:\tmp\tokens
#>
[CmdletBinding()]
param(
    [ValidateSet('github','pypi','all')]
    [string]$Provider = 'all',
    [string]$TokenDir = (Join-Path $env:USERPROFILE '.machine-tokens')
)

$script:exit = 0

function Mask-Token([string]$t) {
    if ($t.Length -le 8) { return '****' }
    return $t.Substring(0, 4) + '****' + $t.Substring($t.Length - 4)
}

function Test-GitHub([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host "[github] MISSING $file" -ForegroundColor Red; $script:exit = 2; return }
    $token = (Get-Content -Raw -LiteralPath $file).Trim()
    if (-not $token) { Write-Host '[github] 空文件' -ForegroundColor Red; $script:exit = 1; return }
    $prev = $env:GH_TOKEN
    try {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $env:GH_TOKEN = $token
            $login = gh api user --jq '.login' 2>$null
        } else {
            try {
                $login = (Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers @{ Authorization = "Bearer $token"; 'User-Agent' = 'agent-credentials-skill' } -TimeoutSec 15).login
            } catch {
                $code = $null
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                if ($code -in 401,403) { Write-Host '[github] INVALID（401/403）' -ForegroundColor Red; $script:exit = 1 }
                else { Write-Host "[github] 网络/服务错误，未判定：$($_.Exception.Message)" -ForegroundColor Yellow }
                return
            }
        }
        if ($login) { Write-Host "[github] OK 账号=$login 令牌=$(Mask-Token $token)" -ForegroundColor Green }
        else { Write-Host '[github] INVALID（API 未返回账号）' -ForegroundColor Red; $script:exit = 1 }
    } catch {
        Write-Host "[github] INVALID: $($_.Exception.Message)" -ForegroundColor Red
        $script:exit = 1
    } finally {
        $env:GH_TOKEN = $prev
    }
}

function Test-PyPI([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host "[pypi] MISSING $file" -ForegroundColor Red; $script:exit = 2; return }
    $raw = (Get-Content -Raw -LiteralPath $file).Trim()
    if (-not $raw) { Write-Host '[pypi] 空文件' -ForegroundColor Red; $script:exit = 1; return }
    if ($raw -notlike 'pypi-*') { Write-Host '[pypi] INVALID 前缀（应为 pypi-）' -ForegroundColor Red; $script:exit = 1; return }
    $b64 = $raw.Substring(5).Replace('-','+').Replace('_','/')
    switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } }
    try {
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $m = [regex]::Match($text, '20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z)?')
        if (-not $m.Success) { $m = [regex]::Match($text, '20\d{2}-\d{2}-\d{2}') }
        if ($m.Success) {
            $exp = [datetime]::Parse($m.Value)
            if ($exp -gt (Get-Date)) { Write-Host "[pypi] OK 到期=$($exp.ToString('yyyy-MM-dd')) 令牌=$(Mask-Token $raw)" -ForegroundColor Green }
            else { Write-Host "[pypi] EXPIRED 到期=$($exp.ToString('yyyy-MM-dd'))" -ForegroundColor Red; $script:exit = 1 }
        } else { Write-Host '[pypi] OK 结构可解码（未含到期时间）' -ForegroundColor Green }
    } catch {
        Write-Host "[pypi] 解码失败：$($_.Exception.Message)（请到 PyPI 重新生成令牌）" -ForegroundColor Red
        $script:exit = 1
    }
}

if ($Provider -in 'github','all') { Test-GitHub (Join-Path $TokenDir 'github_token.txt') }
if ($Provider -in 'pypi','all')   { Test-PyPI   (Join-Path $TokenDir 'pypi_token.txt') }
exit $script:exit