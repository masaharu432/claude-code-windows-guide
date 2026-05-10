<#
.SYNOPSIS
    psmux を冪等にアンインストールする。

.DESCRIPTION
    現在 PATH 上の psmux がどの方式でインストールされたかを Source から推定し、
    対応する手順で除去する。Method を明示すれば自動判定をスキップ。

    判定ルール (auto):
      - %LOCALAPPDATA%\psmux\ 配下     -> zip
      - scoop の shims/apps/ 配下      -> scoop
      - %USERPROFILE%\.cargo\bin\ 配下 -> cargo
      - 上記いずれでもない             -> エラー (-Method で明示指定)

    zip 方式時の副作用:
      - %LOCALAPPDATA%\psmux\ ディレクトリ削除
      - User PATH から該当エントリを除去 (他のエントリは触らない)

    再実行可。既に未インストールなら "未インストール" と表示して 0 で終わる。

.PARAMETER Method
    auto | scoop | cargo | zip

.PARAMETER KeepPath
    zip 方式でインストールフォルダだけ消し、User PATH エントリは残す。
#>

[CmdletBinding()]
param(
    [ValidateSet('auto','scoop','cargo','zip')]
    [string]$Method = 'auto',
    [switch]$KeepPath
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Test-Tool($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Sync-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Get-PsmuxCommand {
    return Get-Command psmux -ErrorAction SilentlyContinue
}

function Resolve-MethodFromSource($srcPath) {
    if (-not $srcPath) { return $null }
    $zipDir   = Join-Path $env:LOCALAPPDATA 'psmux'
    $cargoDir = Join-Path $env:USERPROFILE '.cargo\bin'
    if ($srcPath.StartsWith($zipDir, [StringComparison]::OrdinalIgnoreCase))   { return 'zip'   }
    if ($srcPath.StartsWith($cargoDir, [StringComparison]::OrdinalIgnoreCase)) { return 'cargo' }
    if ($srcPath -match '\\scoop\\(shims|apps)\\') { return 'scoop' }
    return $null
}

# --- 0. 現状検出 ---
Write-Step '現状検出'
Sync-PathFromRegistry
$cmd = Get-PsmuxCommand
if (-not $cmd) {
    Write-Host '未インストール (psmux が PATH 上に無い)。何もしない。' -ForegroundColor Green
    # zip方式の残骸ディレクトリだけある場合の後始末
    $zipDir = Join-Path $env:LOCALAPPDATA 'psmux'
    if (Test-Path $zipDir) {
        Write-Host "ただし $zipDir が残っている。削除する。" -ForegroundColor Yellow
        Remove-Item $zipDir -Recurse -Force
        Write-Host "削除完了"
    }
    exit 0
}
Write-Host "現在: $($cmd.Source)"

# --- 1. 方式決定 ---
$selected = $Method
if ($Method -eq 'auto') {
    $selected = Resolve-MethodFromSource $cmd.Source
    if (-not $selected) {
        Write-Host "Source ($($cmd.Source)) から方式を判定できません。-Method で明示してください。" -ForegroundColor Red
        exit 1
    }
}
Write-Step "アンインストール方式: $selected"

# --- 2. 実行 ---
switch ($selected) {
    'scoop' {
        if (-not (Test-Tool scoop)) {
            Write-Host 'scoop が見つからない。-Method zip 等で明示する必要あり。' -ForegroundColor Red
            exit 1
        }
        scoop uninstall psmux
        if ($LASTEXITCODE -ne 0) { throw "scoop uninstall 失敗 (exit $LASTEXITCODE)" }
    }

    'cargo' {
        if (-not (Test-Tool cargo)) {
            Write-Host 'cargo が見つからない。' -ForegroundColor Red
            exit 1
        }
        & cargo uninstall psmux
        if ($LASTEXITCODE -ne 0) { throw "cargo uninstall 失敗 (exit $LASTEXITCODE)" }
    }

    'zip' {
        $dest = Join-Path $env:LOCALAPPDATA 'psmux'
        if (Test-Path $dest) {
            Write-Host "削除: $dest"
            Remove-Item $dest -Recurse -Force
        } else {
            Write-Host "$dest は既に存在しない"
        }

        if (-not $KeepPath) {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $entries  = @(($userPath -split ';') | Where-Object { $_ })
            $kept     = @($entries | Where-Object {
                -not ($_.TrimEnd('\') -ieq $dest.TrimEnd('\'))
            })
            if ($kept.Count -ne $entries.Count) {
                $newPath = ($kept) -join ';'
                [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
                Write-Host "User PATH から $dest を除去"
            } else {
                Write-Host "User PATH に $dest は無し"
            }
            # 当該プロセスの $env:Path も同期
            Sync-PathFromRegistry
        } else {
            Write-Host "User PATH は触らない (-KeepPath)"
        }
    }
}

# --- 3. 検証 ---
Write-Step '検証'
Sync-PathFromRegistry
$after = Get-PsmuxCommand
if ($after) {
    Write-Host "警告: psmux がまだ PATH 上に残っている: $($after.Source)" -ForegroundColor Yellow
    Write-Host '別経路で入った psmux があるかもしれない。Get-Command psmux -All で全候補を確認。' -ForegroundColor Yellow
    exit 1
}
Write-Host "OK: psmux は PATH 上に無い" -ForegroundColor Green
