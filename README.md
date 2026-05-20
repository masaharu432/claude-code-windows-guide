# Windows + SSH 環境での Claude Code 利用ガイド

- 著者: 清水正晴
- 作成日: 2026-04-30

Windows 上で（あるいは Windows 同士で SSH して）Claude Code を使うときに
ぶつかる課題と、その回避・運用方法をまとめたプロジェクト。

## なぜ Windows で Claude Code を使うのか

Claude Code は対話の大半を **日本語プロンプト** で進めるツールなので、
開発時間のかなりの部分は「IME を叩く時間」になる。ここで使う IME の質が、
そのまま生産性に効いてくる。

Linux ネイティブの IME（Mozc / Fcitx 等）に対し、Windows の IME
（MS-IME / Google 日本語入力 / ATOK 等）は **変換精度・レイテンシ・学習挙動**
の面で実用上優れていて、Claude Code のようにプロンプトを大量に書くワークフローでは
この差が無視できない。「Linux に逃げる」を取りたくないのが出発点。

ところが Windows で Claude Code を素直に動かそうとすると、
**Windows 同梱 ConPTY 起因の日本語入力位置ずれ問題**にぶつかる。
ローカル / リモート Windows への SSH / WSL でそれぞれ挙動が異なり、
回避策もまちまち。本リポジトリは、その整理と実運用での回避策をまとめたもの。

## 扱う論点

| # | テーマ | ドキュメント |
| --- | --- | --- |
| 1 | 日本語入力の位置ずれ問題と対処 | [`ime-shift.md`](./ime-shift.md) |
| 2 | SAMBA でのファイル共有 | [`samba.md`](./samba.md) |
| 3 | tmux の使い方（長時間セッション・複数ペイン） | [`tmux.md`](./tmux.md) |
| 4 | VS Code Remote-SSH ターミナルでの Claude Code 文字化け対処 | [`vscode-terminal.md`](./vscode-terminal.md) |

各ドキュメントの概要：

### 1. 日本語入力の位置ずれ問題（[`ime-shift.md`](./ime-shift.md)）

ローカル Windows で `claude` を直接動かす、または Windows から SSH で
リモート Windows に入って `claude` を動かすと、日本語を IME で打つと
プロンプト上で位置がずれる長年の問題。

- ローカルは **WezTerm Nightly + 専用 `wezterm.lua`**、または
  **VS Code 統合ターミナル + 新 ConPTY DLL** で解決
- リモート Windows へは **VS Code Remote-SSH** 経由が推奨（追加設定不要）
- 経路途中に Windows 同梱 ConPTY が挟まる場合は **WSL 着地** で回避

### 2. SAMBA でのファイル共有（[`samba.md`](./samba.md)）

Windows と Linux（あるいは Windows 同士）でファイル共有するときの設定と、
共有ドライブ上で Claude Code を動かす場合の注意点をまとめている。

**既知の問題**: ユーザーが GUI（エクスプローラーの「ネットワークドライブの
割り当て」）で SAMBA 共有を `D:` 等にマウントしても、**CLI で動く Claude Code
からはそのドライブが認識できない**。Windows のマップドライブはログオン
セッション単位（さらに UAC の昇格状態単位）で管理されるため、ユーザーの
デスクトップセッションでマウントしたドライブは、Claude Code が動く別セッション
（たとえば SSH 経由や `SessionId 0` のサービス文脈）からは見えない。
結果として `Get-PSDrive` にも UNC パスにも現れず、`Get-SmbMapping` では
`Status: Unavailable` として観測される。

対処は OS グローバルなマウントを使うこと。Windows 11 Pro 以上であれば
標準搭載の `New-SmbGlobalMapping`（`SmbShare` モジュール、Microsoft 純正）で
全セッション共通・再起動後も維持されるマウントが作れる。詳細は
[`samba.md`](./samba.md) を参照。

### 3. tmux の使い方（[`tmux.md`](./tmux.md)）

長時間の Claude Code を SSH 越しに走らせるとき、回線が切れてもセッションを
残すための tmux の使い方。Windows / WSL / SSH 先のどこで動かすか、
最低限のキー操作、典型運用パターンをまとめる。

### 4. VS Code Remote-SSH ターミナルでの Claude Code 文字化け対処（[`vscode-terminal.md`](./vscode-terminal.md)）

VS Code 統合ターミナルを Remote-SSH でリモート Windows に繋ぎ、その上で
Claude Code（TUI）を長時間動かすと、ターミナル上の文字（日本語含む、英字も）が
頻繁に崩れる現象への対処。リモート側のロケール/コードページは正しく UTF-8
（実測値で確認）なので原因はサーバー側ではなく、**手元 PC の VS Code
統合ターミナルの GPU 描画パス + Remote-SSH 越しの再描画**が主因。

- 手元 VS Code の `settings.json` に
  `terminal.integrated.gpuAcceleration: "off"` を入れた瞬間、リロードも再起動も
  不要で崩れが止まる（実測で再現しなくなった）
- 併せて `customGlyphs: false` / `rescaleOverlappingGlyphs: false` を
  予防的に入れておく
- 崩れたときの応急処置はリサイズ → `/clear` → `exit` + `claude --resume`

IME 位置ズレ（ConPTY 系）とは別レイヤーの話なので、[`ime-shift.md`](./ime-shift.md)
と併せて参照。

---

## 検証環境

- Claude Code 2.1.123
- VS Code 1.118.1 (user setup) / コミット
  `034f571df509819cc10b0c8129f66ef77a542f0e`
  （2026-04-29 リリース、Electron 39.8.8 / Chromium 142 / Node.js 22.22.1）
- OS: Windows 11 (Windows_NT x64 10.0.26200)
