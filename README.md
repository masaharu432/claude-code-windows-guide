# Windows + SSH 環境での Claude Code 利用ガイド

- 著者: 清水正晴
- 作成日: 2026-04-30

Windows 上で（あるいは Windows 同士で SSH して）Claude Code を使うときに
ぶつかる課題と、その回避・運用方法をまとめたプロジェクト。

## 扱う論点

| # | テーマ | ドキュメント |
| --- | --- | --- |
| 1 | 日本語入力の位置ずれ問題と対処 | [`ime-shift.md`](./ime-shift.md) |
| 2 | SAMBA でのファイル共有 | [`samba.md`](./samba.md) |
| 3 | tmux の使い方（長時間セッション・複数ペイン） | [`tmux.md`](./tmux.md) |

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
共有ドライブ上で Claude Code を動かす場合の注意点を記録予定。

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
[`samba.md`](./samba.md) に記録予定。

### 3. tmux の使い方（[`tmux.md`](./tmux.md)）

長時間の Claude Code を SSH 越しに走らせるとき、回線が切れてもセッションを
残すための tmux の使い方。Windows / WSL / SSH 先のどこで動かすか、
最低限のキー操作、典型運用パターンをまとめる。

---

## 検証環境

- Claude Code 2.1.123
- VS Code 1.118.1 (user setup) / コミット
  `034f571df509819cc10b0c8129f66ef77a542f0e`
  （2026-04-29 リリース、Electron 39.8.8 / Chromium 142 / Node.js 22.22.1）
- OS: Windows 11 (Windows_NT x64 10.0.26200)
