<#
.SYNOPSIS
    SMB 共有を `New-SmbGlobalMapping` で OS グローバルにマウントする冪等スクリプト。

.DESCRIPTION
    Windows のセッション分離問題を回避するために、`New-SmbGlobalMapping`
    （`SmbShare` モジュール）でグローバルマッピングを作る。全セッション
    （SessionId 0 のサービス含む）から見えるようになる。

    詳しい背景は samba.md を参照。ここでは samba.md の手順をスクリプト化して
    再利用できる形にしている。

    冪等性:
      - 同じ LocalPath に同じ RemotePath が既にマップされていれば skip
      - 別の RemotePath がマップされていれば -Force 無しではエラー
      - -Force 指定時は既存マッピングを削除してから作り直す

    認証:
      - -Credential 未指定なら Get-Credential を呼ぶ (CredUI ダイアログ)
      - 既知の落とし穴: SSH 経由の SessionId 0 から呼ぶとダイアログが
        対話デスクトップ側 (SessionId N) に出る。samba.md の警告を参照
      - ユーザー名は必ず `<host>\<user>` 形式 (例: `atom0\shimi`)。
        単なる `shimi` だと System Error 1312 で失敗する

.PARAMETER LocalPath
    マウント先ドライブレター (例: 'E:')。コロン必須。

.PARAMETER RemotePath
    SMB 共有 UNC パス (例: '\\atom0\windows_home')。

.PARAMETER UserName
    認証ユーザー名。必ず `<host>\<user>` 形式 (例: 'atom0\shimi')。
    省略時は Get-Credential のダイアログで入力。

.PARAMETER Credential
    事前に作成済みの PSCredential。指定時は Get-Credential を呼ばない。

.PARAMETER Persistent
    再起動後もマッピングを維持する。既定 $true。

.PARAMETER Force
    既存マッピングを削除してから作り直す。

.EXAMPLE
    .\mount-smb-global.ps1 -LocalPath E: -RemotePath \\atom0\windows_home -UserName atom0\shimi

.EXAMPLE
    # スクリプト外で credential を作ってから渡す (ダイアログ位置を制御したい場合):
    $cred = Get-Credential -UserName 'atom0\shimi'
    .\mount-smb-global.ps1 -LocalPath E: -RemotePath \\atom0\windows_home -Credential $cred

.NOTES
    管理者 PowerShell で実行すること。
    解除: Remove-SmbGlobalMapping -LocalPath E: -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$LocalPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^\\\\[^\\]+\\.+')]
    [string]$RemotePath,

    [string]$UserName,

    [System.Management.Automation.PSCredential]$Credential,

    [bool]$Persistent = $true,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        Write-Host '管理者 PowerShell で実行してください (New-SmbGlobalMapping は要管理者権限)。' -ForegroundColor Red
        exit 1
    }
}

function Get-ServerFromUnc($unc) {
    if ($unc -match '^\\\\([^\\]+)\\') { return $matches[1] }
    return $null
}

# --- 0. 前提チェック ---
Write-Step '前提チェック'
Assert-Admin
if (-not (Get-Command New-SmbGlobalMapping -ErrorAction SilentlyContinue)) {
    Write-Host 'New-SmbGlobalMapping が見つかりません。Windows 11 Pro 以上か確認してください。' -ForegroundColor Red
    exit 1
}

$server = Get-ServerFromUnc $RemotePath
Write-Host "Server: $server"
Write-Host "Share : $RemotePath"
Write-Host "Local : $LocalPath"

# --- 1. 疎通確認 ---
Write-Step "疎通確認 ($server:445)"
$reachable = Test-NetConnection -ComputerName $server -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $reachable) {
    Write-Host "TCP 445 が通りません。ファイアウォール / VLAN / SMB 無効化を疑ってください。" -ForegroundColor Red
    exit 1
}
Write-Host 'OK' -ForegroundColor Green

# --- 2. 既存マッピング検査 ---
Write-Step '既存マッピング検査'
$existingGlobal = Get-SmbGlobalMapping -LocalPath $LocalPath -ErrorAction SilentlyContinue
$existingSession = Get-SmbMapping -LocalPath $LocalPath -ErrorAction SilentlyContinue

if ($existingGlobal) {
    if ($existingGlobal.RemotePath -ieq $RemotePath) {
        if ($Force) {
            Write-Host "$LocalPath は既に $RemotePath にマップ済み。-Force 指定のため削除して作り直し。" -ForegroundColor Yellow
            Remove-SmbGlobalMapping -LocalPath $LocalPath -Force | Out-Null
        } else {
            Write-Host "$LocalPath は既に $RemotePath にマップ済み (Status: $($existingGlobal.Status))。スキップ。" -ForegroundColor Green
            Write-Host "(再マウントするには -Force)"
            exit 0
        }
    } else {
        if ($Force) {
            Write-Host "$LocalPath は別共有 ($($existingGlobal.RemotePath)) にマップ済み。-Force 指定のため削除。" -ForegroundColor Yellow
            Remove-SmbGlobalMapping -LocalPath $LocalPath -Force | Out-Null
        } else {
            Write-Host "$LocalPath は別共有 ($($existingGlobal.RemotePath)) にマップ済み。-Force を付けて再実行してください。" -ForegroundColor Red
            exit 1
        }
    }
} elseif ($existingSession) {
    Write-Host "$LocalPath にセッション単位マッピング ($($existingSession.RemotePath)) があります。グローバルと衝突するので削除します。" -ForegroundColor Yellow
    Remove-SmbMapping -LocalPath $LocalPath -Force -UpdateProfile -ErrorAction SilentlyContinue
} else {
    Write-Host "$LocalPath は未使用。"
}

# --- 3. 認証情報 ---
Write-Step '認証情報'
if (-not $Credential) {
    if (-not $UserName) {
        $UserName = Read-Host "ユーザー名 (<host>\<user> 形式、例: $server\shimi)"
    }
    if ($UserName -notmatch '\\') {
        Write-Host "ユーザー名は <host>\<user> 形式である必要があります (例: $server\shimi)。" -ForegroundColor Red
        Write-Host "理由: New-SmbGlobalMapping は double hop 認証なのでホスト指定必須。" -ForegroundColor Yellow
        Write-Host "回避しないと System Error 1312 (指定されたログオンセッションは存在しません) になる。" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Get-Credential 呼び出し (UserName=$UserName)..."
    Write-Host "注意: SessionId 0 (SSH) から実行している場合、ダイアログは対話セッション側に出ます。" -ForegroundColor Yellow
    $Credential = Get-Credential -UserName $UserName -Message "$RemotePath への接続パスワード"
}

# --- 4. グローバルマッピング作成 ---
Write-Step 'New-SmbGlobalMapping 実行'
$mapArgs = @{
    LocalPath  = $LocalPath
    RemotePath = $RemotePath
    Credential = $Credential
    Persistent = $Persistent
}
$mapping = New-SmbGlobalMapping @mapArgs
Write-Host "作成: $($mapping.LocalPath) -> $($mapping.RemotePath)  (Status: $($mapping.Status))" -ForegroundColor Green

# --- 5. 検証 ---
Write-Step '検証'
$after = Get-SmbGlobalMapping -LocalPath $LocalPath -ErrorAction SilentlyContinue
if (-not $after) {
    Write-Host 'マッピングが見えません。' -ForegroundColor Red
    exit 1
}
Write-Host "Status     : $($after.Status)"
Write-Host "LocalPath  : $($after.LocalPath)"
Write-Host "RemotePath : $($after.RemotePath)"

$conn = Get-SmbConnection -ServerName $server -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
    Write-Host "Dialect    : $($conn.Dialect)"
    Write-Host "Encrypted  : $($conn.Encrypted)"
    Write-Host "Signed     : $($conn.Signed)"
}

try {
    $first = Get-ChildItem $LocalPath\ -ErrorAction Stop | Select-Object -First 3 Name
    Write-Host ''
    Write-Host '先頭エントリ:'
    $first | ForEach-Object { Write-Host "  $($_.Name)" }
} catch {
    Write-Host "ファイル列挙失敗: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '完了。' -ForegroundColor Green
Write-Host "解除: Remove-SmbGlobalMapping -LocalPath $LocalPath -Force"
Write-Host '永続性は再起動後に Get-SmbGlobalMapping で Status: OK が残るかで確認可能 (samba.md 参照)。'
