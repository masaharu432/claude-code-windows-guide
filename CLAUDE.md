# claude-code-windows-guide — プロジェクト前提

## 作業環境

このリポジトリは **SSH リモートホスト上の Windows マシン**（`D:\shimi\Develop\mytools\claude-code-windows-guide`）にある。ユーザーは別マシンから VSCode Remote-SSH 等でこのホストに接続して作業している。Claude Code およびその全ツール呼び出しは**このリモート Windows ホスト上**で実行される。

プロジェクトの主題そのものが「Windows + SSH + Claude Code」の運用ガイドなので、ユーザーはこれを dogfooding している。

## env / PATH トラブル時の判断指針

env や PATH の不整合（特に installer 系スクリプトを走らせた直後に新しいバイナリが見えない問題）でアドバイスする際、**ローカル GUI セッション前提の手段を提案しない**こと。

env 継承チェーンはこう：

```
sshd → user shell → vscode-server → 統合ターミナル PowerShell → claude.exe → tools
```

Explorer.exe / ローカル VSCode の "再起動" は**このチェーンと無関係**。`WM_SETTINGCHANGE` の broadcast も既存の vscode-server プロセスには届かない。

### 効くもの / 効かないもの

| 操作 | 効果 |
|---|---|
| Remote-SSH 切断 → 再接続 (File → Close Remote Connection → 再 Connect) | ✅ 新しい vscode-server が立ち、env を取り直す |
| 当該シェルだけ手動 refresh: `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')` | ✅ そのシェルのみ |
| ローカル PC 側の VSCode を完全終了 → 再起動（Remote-SSH も切れて再接続するなら） | ✅ |
| ローカル PC 側の Explorer 再起動 | ❌ 別マシンなので無関係 |
| リモート Windows 側の Explorer 再起動 | ❌ env チェーンに含まれない |
| リモート Windows のログオフ/ログオン | ❌ SSH セッションに紐づかない |
| 「Developer: Reload Window」 | ❌ vscode-server プロセスは生き残る |
| 「Terminal: Restart」 | ❌ 親（vscode-server）の env を継承 |

### Claude Code 自体の env

走行中の `claude.exe` の `$env:Path` は**プロセス起動時に固定**。後から書き換える方法はない。Claude Code 内のツール（Bash/PowerShell）から新しいバイナリを呼びたければ、`/exit` → Remote-SSH 再接続 → `claude --resume` で復帰させる。会話履歴は自動保存されているので文脈は失われない。

## installer 設計の指針

このプロジェクト配下のスクリプト（`scripts/install-*.ps1`）を作る／改修する際：

- **scoop / cargo を優先**。これらは shims dir / `~/.cargo\bin` が SSH セッション開始時に既に PATH 上にあるので、後付け PATH 書き換え問題を踏まない
- **zip 方式のような「User PATH を後付けで書き換える」手段は最終手段にする**。auto モードで暗黙にフォールバックさせない
- インストール後に「Remote-SSH 再接続が必要」を明示する

参考: `scripts/install-psmux.ps1` がこの方針で実装済み（zip は auto から除外）。

## ドキュメントスタイル

`README.md` `tmux.md` `samba.md` `ime-shift.md` の既存スタイルに揃える：

- 見出しに著者・作成日・必要なら更新日
- 日本語ベース、コードブロックは英語コマンド
- スクリプトは `scripts/` 配下、SKILL は `.claude/skills/<name>/SKILL.md`
- PowerShell スクリプトは **UTF-8 BOM 付き**で保存（PS 5.1 が日本語を Shift-JIS と誤認識して構文エラーになる問題を回避）
- スクリプトは `Write-Step` ヘルパー、`$ErrorActionPreference = 'Stop'`、コメントベースヘルプを含める
