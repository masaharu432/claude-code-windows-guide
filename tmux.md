# tmux の使い方（Windows / WSL / SSH 先 / VSCode）

- 著者: 清水正晴
- 作成日: 2026-04-30
- 更新日: 2026-05-01

長時間の Claude Code を SSH 越しに走らせるなら tmux が便利。回線が切れても
セッションが残り、複数ペインで作業を並列化できる。

---

## tmux とは（初心者向け）

**tmux はターミナル多重化ツール (terminal multiplexer)**。1つのターミナル
ウィンドウ／SSH接続の中に、複数の擬似ターミナルを作って切り替える仕組み。

普段のターミナルとの違いを 3 行で：

| 要素 | 普通のターミナル | tmux |
|---|---|---|
| ウィンドウ閉じたら？ | プロセス終了、作業消失 | **セッション残る**。再アタッチで復活 |
| 1画面で複数作業 | タブやウィンドウ複数枚 | 1画面を**ペイン分割**して並べる |
| SSH切断したら？ | リモート側のプロセスも死ぬ | **生き残る**。後で繋ぎ直して続きができる |

特に重要なのが「**SSHが切れても作業が消えない**」点。Claude Codeのように
30分〜数時間走るタスクを投げて、回線切断を気にせず後で結果を回収できる。

### 用語

- **セッション (session)**: tmux の最大単位。複数のウィンドウを束ねた作業空間
- **ウィンドウ (window)**: タブのようなもの。1セッションに複数持てる
- **ペイン (pane)**: 1ウィンドウを分割したエリア。左右や上下に並べられる
- **デタッチ (detach)**: tmuxから抜ける（中身は走り続ける）
- **アタッチ (attach)**: 走っているセッションに繋ぎ直す

```
セッション "claude"
├── ウィンドウ 0 (作業)
│   ├── ペイン 0 ← claude が動いてる
│   └── ペイン 1 ← ログ tail
└── ウィンドウ 1 (調査)
    └── ペイン 0
```

---

## どこで tmux を動かすか

Windows ネイティブには本家 tmux はない。動かす選択肢：

| 場所 | 何を入れる | 向いてる用途 |
|---|---|---|
| SSH接続先のリモートLinux | 本家 tmux (`apt install tmux`) | **一番素直**。リモートで長時間走らせるなら断然これ |
| WSL2 (Ubuntu等) | 本家 tmux | Windowsローカルで使いたいが完全互換が欲しい |
| Windows ネイティブ | **psmux** (Rust製クローン) | WSL/Cygwin 入れたくない人向け、ややβ |
| Git Bash / MSYS2 | tmux パッケージ | あまり推奨しない（不安定） |

**判断指針**:
- リモート Linux に入って Claude Code を走らせる → リモート側に tmux
- ローカル Windows だけで完結する作業 → psmux か WSL の tmux
- Windows 同士で SSH している → 着地先で WSL に入る (`ForceCommand wsl`) のが確実

---

## psmux: Windows ネイティブで tmux 互換

[psmux](https://github.com/psmux/psmux) は Rust 製で、Windows ConPTY を直接
叩いて tmux 互換のコマンド／キーバインドを提供する。`.tmux.conf` も読める。
WSL も Cygwin も不要。

### 本リポジトリの導入スキル

`/psmux-install` を使う（プロジェクトルートで Claude Code 起動が前提）。

```text
/psmux-install add        # 入れる (auto: scoop → cargo)
/psmux-install del        # 消す (Sourceパスから方式自動判定)
/psmux-install add -Force # 同一版でも再インストール
```

中身は `scripts/install-psmux.ps1` / `scripts/uninstall-psmux.ps1` を呼ぶ
だけ。冪等なので何度実行しても安全。

直接スクリプトを呼ぶ場合：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-psmux.ps1
```

### インストール方式（推奨度順）

| 方式 | 推奨度 | 備考 |
|---|---|---|
| **scoop** | ★★★（最推奨） | shims dir が最初から PATH 上にあるので追加設定なし。アンインストールも綺麗。事前に [scoop](https://scoop.sh) を入れる必要あり |
| **cargo** | ★★ | `~/.cargo\bin` が rustup-init 時点で User PATH に入っているので OK。Rust toolchain ([rustup](https://rustup.rs)) が必要 |
| **zip** | ★（非推奨・最終手段） | `%LOCALAPPDATA%\psmux\` に展開＋ User PATH を後付けで書き換え。**既存の VSCode やシェルからは見えない**（親プロセスの環境変数を更新できないため）。VSCode 再起動 か `$env:Path` 手動 refresh が必要 |

`auto` モード（`-Method` 省略時）は **scoop / cargo を順に試し、どちらも無ければエラーで停止**する。zip は意図的に auto から外している（PATH反映問題のため）。**zip を使うなら `-Method zip` を明示**する必要がある。

### zip 方式を使う場合の注意

zip方式インストール後、**VSCode の統合ターミナル / Claude Code の bash / 既に開いている別シェル**からは psmux が見えない。理由は親プロセス（VSCode 本体や別シェルの親）が起動時の PATH をキャッシュしているから。対処：

1. **VSCode を完全終了→再起動**（恒久・推奨）
2. **既存シェルだけ即座に通す**：

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
```

scoop / cargo 方式ならこの問題は起きない。

インストール先は `%LOCALAPPDATA%\psmux\`（zip方式時）。`psmux.exe` /
`pmux.exe` / `tmux.exe` の3バイナリが入り、どれを呼んでも動作は同じ。

### 制約と既知問題

- Windows 10/11 + PowerShell 5.1+
- Claude Code Agent Teams 起動時のパス引用バグ（[issue #42848](https://github.com/anthropics/claude-code/issues/42848)）
- 細かい polish 系バグはまだあるが、日常用途は実用レベル

---

## 最低限おぼえておく操作

`Ctrl+b` がプレフィックス（押してから次のキー）。psmux も同じ。

### セッション

| 操作 | コマンド／キー |
|---|---|
| 新規セッション | `tmux new -s work` |
| デタッチ（抜ける） | `Ctrl+b` → `d` |
| アタッチ（戻る） | `tmux attach -t work` |
| セッション一覧 | `tmux ls` |
| セッション切替 | `Ctrl+b` → `s` |
| セッション削除 | `tmux kill-session -t work` |

### ウィンドウとペイン

| 操作 | キー |
|---|---|
| ペイン縦分割 | `Ctrl+b` → `%` |
| ペイン横分割 | `Ctrl+b` → `"` |
| ペイン移動 | `Ctrl+b` → 矢印キー |
| ペイン閉じる | `Ctrl+b` → `x` |
| ウィンドウ新規 | `Ctrl+b` → `c` |
| ウィンドウ切替 | `Ctrl+b` → `n` (next) / `p` (prev) |
| ウィンドウ番号指定 | `Ctrl+b` → `0`〜`9` |
| ウィンドウ閉じる | `Ctrl+b` → `&` |

### コピーモード（スクロールバック閲覧）

| 操作 | キー |
|---|---|
| コピーモード入る | `Ctrl+b` → `[` |
| 抜ける | `q` |
| 検索 | `/` (前方) / `?` (後方) |

---

## 典型的な運用

### 長尺タスク投げ

```bash
ssh remote
tmux new -s claude
claude
# > "このリポジトリ全部リファクタして"  などと投げる
# Ctrl+b → d でデタッチ。回線切ってOK。
exit  # SSHも切る
```

数時間後：

```bash
ssh remote
tmux attach -t claude
# 続きが見える
```

### 並列作業

```bash
tmux new -s dev
# Ctrl+b → "  (横分割)
# 上ペイン: claude
# 下ペイン: tail -f log
# Ctrl+b → c (新ウィンドウ)
# テストや git 操作はこっちで
```

---

## Claude Code を psmux/tmux で運用する（実例）

主な利用パターンは2つ。**コマンド体系・キーバインド・`.tmux.conf` の書式は完全に同じ**
（psmux は tmux 互換なので、1つ覚えれば両方使える）。違うのは
**「tmuxサーバがどこで走るか」と「何が何を生き残らせるか」**。

### パターン A: ローカル Windows + psmux + Claude Code

開発機が Windows で、Claude Code をローカルで走らせるケース。VSCode 統合ターミナル
の中で psmux を起動し、その中で `claude` を動かす。

```text
[Windows ローカル]
  VSCode 統合ターミナル
   └─ psmux session "claude"
       ├─ pane 0: claude (作業中)
       └─ pane 1: ログ tail / git status
```

実行例（PowerShell でも cmd でも同じ）：

```powershell
psmux new -s claude
claude
# Ctrl+b → "  で横分割
# Ctrl+b → ↓  で下ペインに移動
Get-Content -Wait .claude/logs/latest.log
# Ctrl+b → ↑  で claude 側に戻る
# Ctrl+b → d  でデタッチ
```

別シェル（あるいは VSCode リロード後の新しい統合ターミナル）から戻る：

```powershell
psmux ls           # claude セッションが残ってる
psmux attach -t claude
```

このシナリオでの psmux の効用：
- VSCode のリロード／再起動に**耐える**（VSCode 統合ターミナルは死ぬが、psmux サーバは Windows プロセスとして生き続ける）
- ターミナルウィンドウを閉じても claude は走り続ける
- Windows 再起動には**耐えない**（OS再起動で psmux サーバも消える）
- 1画面で claude + 監視 + git を並べやすい

### パターン B: VSCode Remote-SSH + リモート Linux tmux + Claude Code

開発機が Linux サーバ（社内あるいはクラウド）、ローカル Windows は VSCode で
覗くだけのケース。**psmux は使わない** — リモート Linux 側に普通の tmux を入れる。

```text
[Windows] VSCode --Remote-SSH--> [Linux server]
                                   └─ tmux session "claude"
                                       ├─ pane 0: claude (リモートで作業中)
                                       └─ pane 1: tail -f log
```

実行例（VSCode 統合ターミナルは自動的にリモート側で開いている）：

```bash
tmux new -s claude
claude
# キー操作はパターンAと完全に同じ:
#   Ctrl+b → "    横分割
#   Ctrl+b → 矢印 ペイン移動
#   Ctrl+b → d    デタッチ
```

切断して戻る：

```bash
# VSCode を閉じる、ネットを切る、別マシンに移動する … 何でも OK
ssh server               # 普通の SSH でも入れる
tmux attach -t claude    # 続きから
```

このシナリオの効用：
- VSCode リロード／再起動に**耐える**
- ローカル Windows の再起動にも**耐える**（リモート側で動いているので）
- ネットワーク切断・スリープにも**耐える**（claude はリモートで走り続ける）
- 別マシン（自宅 PC、出先 Mac など）から `ssh + tmux attach` で同じセッションに戻れる

### 同じところ / 違うところ

| 項目 | A: ローカル psmux | B: Remote-SSH + 本家 tmux |
|---|---|---|
| コマンド | `tmux ...` / `psmux ...` 互換 | `tmux ...` |
| キーバインド (`Ctrl+b → ...`) | 同じ | 同じ |
| `.tmux.conf` | 同じ書式 | 同じ書式 |
| Claude Code から見えるファイルシステム | Windows のローカル | リモート Linux |
| `claude` プロセスはどこで走る？ | Windows | リモート Linux |
| VSCode リロードに耐える | ✅ | ✅ |
| ターミナル/SSH 切断に耐える | ✅ | ✅ |
| ローカル PC の再起動に耐える | ❌ | ✅ |
| ネット切断中も処理を進めたい | ❌（PCがネット要らないので関係ない） | ✅ |
| 別 PC から続きをやる | ❌ | ✅ |
| 日本語入力の位置ずれ問題 | 発生**しうる** ([`ime-shift.md`](./ime-shift.md)) | 発生しない |
| インストール手順 | `/psmux-install add` | リモートで `apt install tmux` 等 |

選び方の目安：

- **ローカルで完結する Windows 作業＋ VSCode リロードに耐えたいだけ** → A
- **長時間ジョブをぶん投げて SSH 切る／別マシンから戻る** → B
- **両方併用**もアリ：ローカルで psmux セッションを持ち、その中の 1 ペインから
  Remote-SSH 接続して B パターンを作る — ローカル側の作業も VSCode リロード
  で消えなくなる

### 落とし穴

- パターン A で **`Ctrl+b` が VSCode の標準キーバインド（サイドバートグル）と
  衝突**する。psmux/tmux 内では `Ctrl+b` がプレフィックスとして横取りされる
  ので問題ないが、psmux の外（VSCode の他のターミナルやエディタ）で押すと
  サイドバーが開閉する。違和感があれば `.tmux.conf` で `set -g prefix C-a`
  に変える手もある（GNU screen 流）
- パターン B で**改行コード**: Windows ローカルで作ったファイルを `claude` に
  読ませると CRLF が混じる。`git config core.autocrlf input` 等で対処
- パターン A で **`Ctrl+Shift+V` の貼り付け**: psmux 内ではターミナル側の
  ペースト挙動と psmux のコピーモードが競合する場合あり。psmux 側
  `bind-key ] paste-buffer` を活用するか、VSCode 標準ペーストを使う

---

## VSCode 統合ターミナル＋tmux

VSCode の統合ターミナルは**ただのプロセス起動先**なので、そこで tmux を
起動できる。WezTerm や Mintty のような独立ターミナルエミュレータ系は
VSCode 内では動かない（VSCode 自身がターミナルエミュレータなので）。

統合ターミナル内で動くもの：
- **WSL の tmux**（shell を WSL にする）
- **psmux**（Windows ネイティブ、PATH 通っていれば）
- **SSH 先の tmux**（VSCode 統合ターミナルから普通に `ssh` する）

### Remote-SSH 経由の場合

VSCode の Remote-SSH 拡張で接続している場合、統合ターミナルは自動的に
リモート側で開く。そのまま `tmux new -s work` すれば、リモート Linux の tmux に入れる。

```text
[Windows] VSCode → Remote-SSH → [Linux] tmux new -s claude
                                        └── claude (リモートで動く)
```

ポイント：
- VSCode 側で「ウィンドウを閉じる」「リロードする」と Remote-SSH 接続も
  切れるが、**リモートの tmux セッションは生き残る**
- 再接続して `tmux attach -t claude` で続きから
- 接続が切れている間も Claude Code は動き続ける（→ 長尺リファクタやテスト
  実行に強い）

### 注意：日本語入力との干渉

リモート Windows に SSH して tmux を使う構成は、**ConPTY 起因の日本語入力
位置ずれ問題**を踏みやすい。詳細と回避策は [`ime-shift.md`](./ime-shift.md)
を参照。リモート Linux 着地ならこの問題は発生しない。

---

## VSCode の tmux 関連拡張機能

調査した結果、Marketplace の tmux 系拡張は**2系統に分かれる**。

### A. キーバインド模倣型（実 tmux 不要）

VSCode 標準のターミナル分割機能に tmux 風キーを割り当てるだけ。
**実 tmux は使わない**。

| 拡張 | 内容 |
|---|---|
| [Tmux Keybinding](https://marketplace.visualstudio.com/items?itemName=stephlin.vscode-tmux-keybinding) | `Ctrl+b` プレフィックスで VSCode のターミナル分割／切替／閉じるを操作 |

**使いどころ**: tmux のキー操作に慣れていて、それを VSCode 統合ターミナル
にも持ち込みたい場合。**永続セッション機能はない**（VSCode 標準機能の
範囲なので、VSCodeを閉じれば消える）。

### B. 実 tmux マネージャ型（要 tmux 本体）

実際に動いている tmux サーバに接続し、セッション／ウィンドウ／ペインを
GUI から操作する。

| 拡張 | 内容 |
|---|---|
| [vscode-tmux-manager](https://marketplace.visualstudio.com/items?itemName=ZeroRegister.vscode-tmux-manager) | サイドバーに tmux セッション一覧をツリー表示、ワンクリック attach |
| [Tmux Manager](https://marketplace.visualstudio.com/items?itemName=wangm23456.tmux-manager) | 同上系 |
| [tmuxy](https://marketplace.visualstudio.com/items?itemName=jcsawyer123.tmuxy) | 同上系 |
| [TMUX for VSCode](https://marketplace.visualstudio.com/items?itemName=WilliamFernsV3.tmux-vscode) | 同上系 |
| [TMUX Worktree](https://marketplace.visualstudio.com/items?itemName=kargnas.vscode-tmux-worktree) | git worktree とセッションを連動 |
| [Tmux AI](https://marketplace.visualstudio.com/items?itemName=thuliqilitchi.vscode-tmux-ai) | tmux-ai-cli との連携用 |

**Remote-SSH との関係**: VSCode の拡張機能は接続先ごとにインストール先
（local / remote）が指定できる。リモート Linux で tmux を動かしている場合、
Remote-SSH ホスト側に拡張を入れれば、その tmux サーバを VSCode から操作
できる。**ローカル Windows 側に入れても見えるのはローカル側の tmux**
（≒ psmux）。

### Claude Code 視点での実用度

- **キーバインド型 (A)**: tmux に慣れていれば便利だが、Claude Code の生産性
  には直結しない。Claude Code は VSCode 統合ターミナル機能で十分回せる
- **マネージャ型 (B)**: ある **「リモートで複数 tmux セッションを並行運用」**
  しているなら有用。Sidebar で attach 先を切り替えられるのは作業履歴の
  サルベージに効く

少なくとも個人的に必須ではない。tmux のコマンドラインを直接叩くほうが
速いケースが多い。

---

## .tmux.conf の設定例

（追記予定）

## トラブルシューティング

（追記予定）
