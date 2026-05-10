<#
.SYNOPSIS
    PowerShell の $PROFILE に PATH refresh ブロックを冪等に書き込む。

.DESCRIPTION
    sshd の env キャッシュ問題対策。シェル起動時に Registry の
    Machine + User PATH を読み直すブロックを sentinel コメント付きで
    $PROFILE に追記する。再実行しても重複しない。

    sentinel は以下の形式で挿入される:
      # >>> claude-code-windows-guide: ssh-path-refresh >>>
      ...本体...
      # <<< claude-code-windows-guide: ssh-path-refresh <<<

    これを目印に、既に書かれていれば skip、-Force なら除去して再追記する。

.PARAMETER Scope
    どの $PROFILE に書くか。既定は CurrentUserCurrentHost。
      CurrentUserCurrentHost - 自分・現在のホスト ($PROFILE 既定値)
      CurrentUserAllHosts    - 自分・全ホスト (VSCode 内 PS など含む)
      AllUsersCurrentHost    - 全ユーザ・現在のホスト (要管理者)
      AllUsersAllHosts       - 全ユーザ・全ホスト (要管理者)

.PARAMETER Force
    既存ブロックがあっても上書き再追記。

.NOTES
    実行: .\setup-ssh-path.ps1
    確認: . $PROFILE; $env:Path
    解除: $PROFILE を開いて sentinel ペアの間 (含む) を削除
#>

[CmdletBinding()]
param(
    [ValidateSet('CurrentUserCurrentHost','CurrentUserAllHosts','AllUsersCurrentHost','AllUsersAllHosts')]
    [string]$Scope = 'CurrentUserCurrentHost',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

# sentinel - 既存ブロック検出に使う
$beginMark = '# >>> claude-code-windows-guide: ssh-path-refresh >>>'
$endMark   = '# <<< claude-code-windows-guide: ssh-path-refresh <<<'

# 追記する本体 (`$ で $env のリテラル化)
$block = @"
$beginMark
# Registry から Machine + User PATH を再構成
# 理由: sshd は service 起動時の env をキャッシュし、新規 SSH セッションは
#       それを継承する。Registry を更新しても sshd は再読み込みしないので、
#       シェル起動時にここで明示的に取り直す。
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$endMark
"@

# --- 0. profile path 解決 ---
Write-Step '対象 profile 解決'
$profilePath = $PROFILE.$Scope
Write-Host "Scope    : $Scope"
Write-Host "ファイル : $profilePath"

# --- 1. ディレクトリ・ファイル準備 ---
$dir = Split-Path $profilePath -Parent
if (-not (Test-Path $dir)) {
    New-Item -Type Directory -Path $dir -Force | Out-Null
    Write-Host "ディレクトリ作成: $dir"
}
$created = $false
if (-not (Test-Path $profilePath)) {
    New-Item -Type File -Path $profilePath -Force | Out-Null
    Write-Host "新規 profile を作成"
    $created = $true
}

# --- 2. 既存内容読み取り ---
$current = ''
if (-not $created) {
    $current = [System.IO.File]::ReadAllText($profilePath)
    if ($null -eq $current) { $current = '' }
}

# --- 3. 冪等性判定 ---
if ($current.Contains($beginMark) -and -not $Force) {
    Write-Step '結果'
    Write-Host '既に PATH refresh ブロックが書かれている。スキップ。' -ForegroundColor Green
    Write-Host '(更新するには -Force)'
    Write-Host ''
    Write-Host '現在のシェルに即時適用するには:' -ForegroundColor Cyan
    Write-Host "  . `$PROFILE" -ForegroundColor Cyan
    exit 0
}

# --- 4. 既存ブロック除去 (-Force 時) ---
if ($Force -and $current.Contains($beginMark)) {
    Write-Host '既存ブロックを除去 (-Force)'
    $pattern = "(?s)" + [regex]::Escape($beginMark) + ".*?" + [regex]::Escape($endMark) + "\r?\n?"
    $current = [regex]::Replace($current, $pattern, '')
}

# --- 5. 追記 ---
Write-Step '追記'
$body = if ([string]::IsNullOrWhiteSpace($current)) {
    $block + "`r`n"
} else {
    $current.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
}
# UTF-8 BOM で保存 (PS 5.1 と PS 7 双方で安全)
$bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($profilePath, $body, $bom)
Write-Host "書き込み完了: $profilePath"

# --- 6. 検証 ---
Write-Step '検証 (ファイル内容)'
$verified = [System.IO.File]::ReadAllText($profilePath)
if ($verified.Contains($beginMark) -and $verified.Contains($endMark)) {
    Write-Host 'OK: sentinel ペアあり' -ForegroundColor Green
} else {
    Write-Host 'NG: sentinel が見つからない' -ForegroundColor Red
    exit 1
}

# --- 7. 現在のシェルに即時適用 ---
Write-Step '現在のシェルに即時適用 (. $PROFILE 相当)'
. $profilePath
$psmuxOnPath = ($env:Path -split ';') | Where-Object { $_ -like '*psmux*' }
if ($psmuxOnPath) {
    Write-Host "PATH refresh 確認: psmux が見える -> $($psmuxOnPath -join ', ')" -ForegroundColor Green
} else {
    Write-Host '(psmux はまだ PATH に無い。インストール済みでも Registry に未反映の可能性)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '完了。次回シェル起動から $PROFILE が自動的に PATH を refresh します。' -ForegroundColor Green
Write-Host '別シェル/別 SSH セッションで効かせるには新しいシェルを開いてください。'
