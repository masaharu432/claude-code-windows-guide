<#
.SYNOPSIS
    psmux (Rust製ネイティブWindows tmuxクローン) を冪等にインストールする。

.DESCRIPTION
    既存インストールを検出し、目標バージョンと一致すれば何もしない。
    異なる/未インストールの場合のみ install を走らせる。

    インストール方式 (auto):
      1. scoop  - 入っていれば優先 (アンインストールが綺麗)
      2. cargo  - rustup があれば fallback
      どちらも無ければエラーで停止。-Method zip を明示指定すれば最終手段で zip。

    zip が auto から外れている理由:
      User PATH への追記が「親プロセスの env」に伝播しないため、
      既に開いている VSCode / シェルからは新シェルを開くまで psmux が見えない。
      scoop / cargo は最初から既存 PATH 配下にバイナリを置くので問題なし。

    再実行しても破壊的副作用なし。-Force で同一バージョンでも再インストール。

.PARAMETER Method
    auto | scoop | cargo | zip

.PARAMETER Version
    'latest' (default) または '3.3.4' のような具体バージョン

.PARAMETER Force
    既に目標バージョンが入っていても再インストールする

.NOTES
    実行: .\install-psmux.ps1
    削除:
      scoop : scoop uninstall psmux
      cargo : cargo uninstall psmux
      zip   : Remove-Item $env:LOCALAPPDATA\psmux -Recurse -Force
              + User PATH から %LOCALAPPDATA%\psmux を手動で外す
#>

[CmdletBinding()]
param(
    [ValidateSet('auto','scoop','cargo','zip')]
    [string]$Method = 'auto',
    [string]$Version = 'latest',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Test-Tool($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# 過去のインストールが別シェルで User PATH に追加されている場合、
# このプロセスの $env:Path にはまだ反映されていない。Registry から再構成して、
# 既存版検出フェーズで取りこぼさないようにする。
function Sync-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Get-InstalledVersion {
    $cmd = Get-Command psmux -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $out = & $cmd.Source -V 2>&1 | Out-String
        if ($out -match '(\d+\.\d+\.\d+)') { return $matches[1] }
    } catch {}
    return 'unknown'
}

function Get-LatestVersion {
    try {
        $headers = @{ 'User-Agent' = 'install-psmux-script' }
        $r = Invoke-RestMethod 'https://api.github.com/repos/psmux/psmux/releases/latest' -Headers $headers
        return ($r.tag_name -replace '^v','')
    } catch {
        Write-Host "GitHub API取得失敗: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Get-WindowsAssetUrl($tag) {
    $headers = @{ 'User-Agent' = 'install-psmux-script' }
    $r = Invoke-RestMethod "https://api.github.com/repos/psmux/psmux/releases/tags/$tag" -Headers $headers
    $asset = $r.assets | Where-Object {
        $_.name -match 'windows' -and $_.name -match '(x86_64|x64|amd64)' -and $_.name -like '*.zip'
    } | Select-Object -First 1
    if (-not $asset) { return $null }
    return $asset.browser_download_url
}

# --- 0. 既存版検出 ---
Write-Step '既存インストール検出'
Sync-PathFromRegistry
$current = Get-InstalledVersion
if ($current) {
    $src = (Get-Command psmux).Source
    Write-Host "現在: psmux $current  ($src)"
} else {
    Write-Host '未インストール'
}

# --- 1. 目標バージョン解決 ---
Write-Step '目標バージョン解決'
$target = $Version
if ($Version -eq 'latest') {
    $target = Get-LatestVersion
    if (-not $target) {
        if ($current) {
            Write-Host '最新版取得不可。既存版のまま終了。' -ForegroundColor Yellow
            exit 0
        } else {
            Write-Host '最新版取得不可かつ未インストール。-Version で明示指定してください。' -ForegroundColor Red
            exit 1
        }
    }
}
Write-Host "目標: psmux $target"

# --- 2. 冪等性判定 ---
if ($current -and $current -eq $target -and -not $Force) {
    Write-Step '結果'
    Write-Host "既に $target がインストール済み。スキップ。" -ForegroundColor Green
    Write-Host "(再インストールするには -Force)"
    exit 0
}

# --- 3. 方法選択 ---
# zip 方式は親プロセスの PATH に反映されない問題があるため auto では選ばない。
# scoop / cargo どちらも無い場合は明示要求してエラーで止める (-Method zip)。
$selected = $Method
if ($Method -eq 'auto') {
    if (Test-Tool scoop)      { $selected = 'scoop' }
    elseif (Test-Tool cargo)  { $selected = 'cargo' }
    else {
        Write-Host ''
        Write-Host 'scoop も cargo も見つかりません。auto では zip にフォールバックしません。' -ForegroundColor Red
        Write-Host '理由: zip方式は User PATH を後付けで書き換えるので、' -ForegroundColor Yellow
        Write-Host '      既に開いている VSCode/シェルからは新シェルを開くまで反映されない。' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '推奨: scoop を入れる (https://scoop.sh) → このスクリプトを再実行' -ForegroundColor Cyan
        Write-Host '別解: cargo を入れる (https://rustup.rs)  → 再実行' -ForegroundColor Cyan
        Write-Host '最終手段: -Method zip を明示指定して実行 (PATH反映の挙動を承知の上で)' -ForegroundColor Cyan
        exit 1
    }
}
Write-Step "インストール方式: $selected"

# --- 4. 実行 ---
switch ($selected) {
    'scoop' {
        if (-not (Test-Tool scoop)) {
            Write-Host 'scoop が無い。https://scoop.sh から入れるか -Method cargo/zip を指定。' -ForegroundColor Red
            exit 1
        }
        $alreadyMatched = $false
        if ($current -and -not $Force) { $alreadyMatched = $true }
        if ($alreadyMatched) {
            scoop update psmux
        } else {
            $list = scoop list psmux 6>&1 | Out-String
            if ($list -match 'psmux') {
                if ($Force) { scoop uninstall psmux | Out-Null }
                else        { scoop update psmux; break }
            }
            try {
                scoop install psmux
            } catch {
                Write-Host '' -ForegroundColor Yellow
                Write-Host 'scoop の main bucket に psmux が無い場合、適切な bucket を追加してください:' -ForegroundColor Yellow
                Write-Host '  scoop bucket add extras' -ForegroundColor Yellow
                Write-Host '別方式で入れたいなら -Method cargo か -Method zip を指定。' -ForegroundColor Yellow
                throw
            }
        }
    }

    'cargo' {
        if (-not (Test-Tool cargo)) {
            Write-Host 'cargo が無い。https://rustup.rs から Rust toolchain を入れてください。' -ForegroundColor Red
            exit 1
        }
        $cargoArgs = @('install', 'psmux')
        if ($Version -ne 'latest') { $cargoArgs += @('--version', $target) }
        if ($Force -or $current)   { $cargoArgs += '--force' }
        & cargo @cargoArgs
        if ($LASTEXITCODE -ne 0) { throw "cargo install 失敗 (exit $LASTEXITCODE)" }

        # cargo bin が PATH にあるか確認
        $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
        if (Test-Path $cargoBin) {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if ($userPath -notlike "*$cargoBin*") {
                Write-Host "警告: $cargoBin が User PATH にありません。rustup-init で正しく設定されたか確認を。" -ForegroundColor Yellow
            }
            if ($env:Path -notlike "*$cargoBin*") { $env:Path = "$env:Path;$cargoBin" }
        }
    }

    'zip' {
        $tag = "v$target"
        $url = Get-WindowsAssetUrl $tag
        if (-not $url) {
            Write-Host "$tag の Windows x86_64 zip が見つかりません。" -ForegroundColor Red
            Write-Host "  https://github.com/psmux/psmux/releases/tag/$tag を手動確認してください。"
            exit 1
        }
        $dest = Join-Path $env:LOCALAPPDATA 'psmux'
        $tmp  = Join-Path $env:TEMP "psmux-$target.zip"

        Write-Host "ダウンロード: $url"
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

        # 旧バイナリだけ消す (設定ファイル等は別管理なのでこのスクリプトでは触らない)
        if (Test-Path $dest) {
            Get-ChildItem $dest -Filter *.exe | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Expand-Archive -Path $tmp -DestinationPath $dest -Force
        Remove-Item $tmp -Force

        # User PATH に追記 (重複は避ける)
        # @(...) で必ず配列化。単一要素のとき + が文字列連結になり PATH を壊す事故防止。
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries  = @(($userPath -split ';') | Where-Object { $_ })
        if ($entries -notcontains $dest) {
            $newPath = (@($entries) + @($dest)) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Host "User PATH に追加: $dest"
        } else {
            Write-Host "User PATH は既に $dest を含む"
        }
        # 当該プロセスにも反映 (新シェルなしで検証できるように)
        if ($env:Path -notlike "*$dest*") { $env:Path = "$env:Path;$dest" }
    }
}

# --- 5. 検証 ---
Write-Step '検証'
# Get-Command のキャッシュをクリアしてから再取得
Get-Command psmux -ErrorAction SilentlyContinue | Out-Null
$after = Get-InstalledVersion
if (-not $after) {
    Write-Host 'psmux が PATH に見えません。' -ForegroundColor Red
    Write-Host '新しい PowerShell を開いて再度 psmux -V で確認してください。' -ForegroundColor Yellow
    Write-Host '(scoop/cargo/zip いずれも初回は新シェル必須なケースあり)' -ForegroundColor Yellow
    exit 1
}
if ($after -eq $target) {
    Write-Host "OK: psmux $after  ($((Get-Command psmux).Source))" -ForegroundColor Green
} else {
    Write-Host "警告: 目標 $target / 実際 $after" -ForegroundColor Yellow
    Write-Host '別経路で入った旧/別バージョンが PATH 上で優先されている可能性。' -ForegroundColor Yellow
    Write-Host '  Get-Command psmux -All  で全候補を確認してください。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "完了。'tmux ls' / 'tmux new -s work' 等そのまま使えます。" -ForegroundColor Green
Write-Host "Claude Code との既知の干渉: https://github.com/anthropics/claude-code/issues/42848"

if ($selected -eq 'zip') {
    Write-Host ''
    Write-Host '!!! zip方式の注意 !!!' -ForegroundColor Yellow
    Write-Host '  既に開いている VSCode / 別シェルからは psmux が見えません。' -ForegroundColor Yellow
    Write-Host '  以下のいずれかを実行:' -ForegroundColor Yellow
    Write-Host '    (1) VSCode を完全終了して再起動 (恒久・推奨)' -ForegroundColor Yellow
    Write-Host '    (2) 既存シェルで以下を貼り付け (そのシェルのみ反映):' -ForegroundColor Yellow
    Write-Host '        $env:Path = [Environment]::GetEnvironmentVariable(''Path'',''Machine'') + '';'' + [Environment]::GetEnvironmentVariable(''Path'',''User'')' -ForegroundColor Yellow
    Write-Host '  scoop / cargo 経由で入れ直すと PATH 引き継ぎ問題は起きません。' -ForegroundColor Yellow
}
