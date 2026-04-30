<#
.SYNOPSIS
    atom0 (Synology NAS) の SMB 共有 windows_shimi を D: にグローバルマウントする。

.DESCRIPTION
    Windows のセッション分離問題を回避するため、New-SmbGlobalMapping を使って
    OS グローバルなマウントを作成する。Claude Code が動く別セッション
    （SessionId 0 等）からも見える状態にする。

    管理者権限で実行する必要がある。Windows 11 Pro 以上、SMB 3.x 対応
    NAS（Samba 4.0+）であること。

.NOTES
    実行: .\mount-atom0.ps1
    解除: Remove-SmbGlobalMapping -LocalPath D: -Force
#>

[CmdletBinding()]
param(
    [string]$RemotePath = '\\atom0\windows_shimi',
    [string]$LocalPath  = 'D:',
    [string]$UserName   = 'shimi'
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

# --- 0. 管理者チェック ---
Write-Step '管理者権限チェック'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '管理者シェルで実行してください (PowerShell を「管理者として実行」または OpenSSH の administrators 経由)' -ForegroundColor Red
    exit 1
}
Write-Host 'OK (管理者)'

# --- 1. 疎通確認 ---
$server = ([Uri]"file://$RemotePath").Host
Write-Step "疎通確認: $server : 445"
$tcp = Test-NetConnection -ComputerName $server -Port 445 -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) {
    Write-Host "445/tcp に到達できません ($server)" -ForegroundColor Red
    exit 1
}
Write-Host "OK ($($tcp.RemoteAddress))"

# --- 2. 既存セッション単位マッピングを除去 ---
Write-Step "既存マッピングの掃除 ($LocalPath)"
$existing = Get-SmbMapping -LocalPath $LocalPath -ErrorAction SilentlyContinue
if ($existing) {
    Remove-SmbMapping -LocalPath $LocalPath -Force -UpdateProfile -ErrorAction SilentlyContinue
    Write-Host '旧マッピング削除'
}
$existingGlobal = Get-SmbGlobalMapping -LocalPath $LocalPath -ErrorAction SilentlyContinue
if ($existingGlobal) {
    Remove-SmbGlobalMapping -LocalPath $LocalPath -Force -ErrorAction SilentlyContinue
    Write-Host '旧グローバルマッピング削除'
}

# --- 3. 認証情報 (コンソール入力, GUI 不要) ---
Write-Step '認証情報入力'
$inputUser = Read-Host "ユーザー名 [$UserName]"
if (-not [string]::IsNullOrWhiteSpace($inputUser)) { $UserName = $inputUser }
$securePass = Read-Host "パスワード ($UserName @ $server)" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential($UserName, $securePass)

# --- 4. グローバルマウント作成 ---
Write-Step "グローバルマウント作成: $LocalPath  ->  $RemotePath"
New-SmbGlobalMapping -LocalPath $LocalPath -RemotePath $RemotePath -Credential $cred -Persistent $true | Out-Null

# --- 5. 結果確認 ---
Write-Step '結果'
Get-SmbGlobalMapping -LocalPath $LocalPath | Format-List Status, LocalPath, RemotePath, Persistent
Get-SmbConnection | Where-Object ServerName -eq $server | Format-List ServerName, ShareName, Dialect, Encrypted, Signed

Write-Step '中身サンプル (上位 5 件)'
Get-ChildItem $LocalPath\ -ErrorAction SilentlyContinue | Select-Object -First 5 Name, Length, LastWriteTime

Write-Host ''
Write-Host '完了。Claude Code 側から Get-SmbGlobalMapping で見えるはず。' -ForegroundColor Green
