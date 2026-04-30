# 日本語入力の位置ずれ問題への対処

- 著者: 清水正晴
- 作成日: 2026-04-30
- 検証バージョン:
  - Claude Code 2.1.123
  - VS Code 1.118.1 (user setup) / コミット `034f571df509819cc10b0c8129f66ef77a542f0e`
    （2026-04-29 リリース、Electron 39.8.8 / Chromium 142 / Node.js 22.22.1）
  - OS: Windows 11 (Windows_NT x64 10.0.26200)

## 問題

Windows で Claude Code を使う典型は次の 3 パターン：

1. ローカル Windows で直接 Claude Code を動かす
2. ローカル Windows のターミナルから SSH でリモート Windows に入って Claude Code
3. WSL（あるいはリモート Linux）で Claude Code

このうち **(1)(2) では日本語を打つと文字がずれる現象**に悩まされる。
本ドキュメントはその回避策をまとめたもの。背景は末尾の「経緯」を参照。

## こうすれば動く（方針）

パターンごとに、いま実用になる選択肢：

### パターン 1（ローカル Windows）

- **WezTerm Nightly + 専用 config**: WezTerm の Nightly ビルドと、IME・幅判定を
  整えた `wezterm.lua` の組み合わせで、ローカル実行なら日本語入力は正常に通る。
  詳細は **A 節**。
- **VS Code 統合ターミナル + 新しい ConPTY DLL**: VS Code をローカルで起動し、
  `terminal.integrated.windowsUseConptyDll: true` で同梱の新しい ConPTY を有効化。
  統合ターミナルは独立ウィンドウに切り出せる。詳細は **B 節**。

### パターン 2（リモート Windows に SSH）

- **VS Code Remote-SSH 経由**（推奨）: ローカル VS Code の Remote-SSH 拡張で
  リモート Windows に接続するだけ。最近の VS Code は新しい ConPTY DLL を
  既定で使うので、追加設定なしで日本語入力が通る。詳細は **C 節**。
- **WSL に着地させる**: リモート側で WSL を立て、`ForceCommand wsl` を
  `sshd_config` に書く。Linux に着地すれば ConPTY 問題自体を通らない。
  詳細は **D 節**。

### パターン 3（WSL / リモート Linux）

そもそも問題は出ない。長時間セッションを安定化したい場合は別ドキュメント
[`tmux.md`](./tmux.md) を参照。

VS Code 統合ターミナルを独立ウィンドウにする方法：

- ターミナルタブを右クリック → `Move Terminal into New Window`
- もしくは `Ctrl+Shift+P` → `Terminal: Move Terminal into New Window`

---

## 詳細手順

### A. WezTerm Nightly + config でローカルを直す（パターン 1）

ローカル Windows で `Claude Code` を直接動かすケース。Stable の WezTerm では
IME 周りに残っている挙動があり、Nightly で改善されているものが多い。
**Nightly ビルド + 専用 config** の組み合わせで日本語入力は正常になる。

#### A-1. WezTerm Nightly を入れる

- Nightly ビルド: `https://github.com/wezterm/wezterm/releases/tag/nightly`
- Windows 用の `WezTerm-windows-*.zip` または `.exe` インストーラを取得
- Stable と入れ替えるか、`WezTerm-windows-*.zip` を任意のフォルダに展開して
  `wezterm-gui.exe` を直接起動する形でも可

#### A-2. `wezterm.lua` を書く

位置ずれ対策の **本体はたった 2 行**：`config.use_ime = true` と
`config.front_end = 'WebGpu'`。これにフォントフォールバックを足せば再現できる。

`%USERPROFILE%\.wezterm.lua`（= `C:\Users\<あなた>\.wezterm.lua`）に：

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- フォント: 英字は Cascadia Code、日本語は BIZ UDGothic にフォールバック
config.font = wezterm.font_with_fallback {
  'Cascadia Code',
  'BIZ UDGothic',
}
config.font_size = 11.0

-- ▼ 日本語入力の位置ずれを抑える肝（この 2 行）
config.use_ime = true            -- Windows IME を WezTerm 内部で受け付ける
config.front_end = 'WebGpu'      -- IME プリエディット位置ズレを抑える描画バックエンド

-- 既定シェル（PowerShell 7 が入っていれば pwsh、無ければ powershell.exe に）
config.default_prog = { 'pwsh.exe', '-NoLogo' }

return config
```

なぜ効くか：

- `use_ime = false` だと IME が OS 側ウィンドウで浮き、入力位置と表示が大きく
  ずれる。`true` で WezTerm 自身が IME を受けるとプリエディットがインライン
  表示になりズレが消える
- `front_end` の既定（`OpenGL`）でも IME ずれが出やすく、`WebGpu` に変えてから
  安定する。古い GPU で WebGpu が不安定な場合のみ `OpenGL` に戻す
- フォントフォールバックを入れておかないと日本語グリフ幅が揃わず、ターミナル
  上の桁ずれの原因になる

設定を変えたら WezTerm を再起動。`claude` をローカルで直接起動して、
日本語入力でズレが出ないか確認。

> 注: ここで効くのは「ローカル WezTerm 上で `claude.exe` を直接動かす」場合に限る。
> WezTerm から `ssh` でリモート Windows に入った先の `claude` は、経路に
> リモート側の Windows ConPTY が挟まるため、ターミナル側を直しても解消しない
> （実測でも改善せず）。リモート Windows に SSH するパターンでは C 節か D 節を使う。

### B. VS Code 統合ターミナル（ローカル）+ 新 ConPTY（パターン 1 別解）

Nightly を入れたくない / WezTerm を使わない場合の道。

1. ローカルに VS Code Stable を入れる
2. `Ctrl+,` でユーザー設定を開き、`settings.json` に：

   ```json
   {
     "terminal.integrated.windowsUseConptyDll": true,
     "terminal.integrated.gpuAcceleration": "auto",
     "terminal.integrated.defaultProfile.windows": "PowerShell"
   }
   ```

3. **VS Code を完全に再起動**（`Reload Window` だけでは ConPTY DLL が
   差し替わらないことがある）
4. `` Ctrl+` `` でターミナルを開いて `claude`

統合ターミナルは右クリック → `Move Terminal into New Window` で別ウィンドウ化
できるので、WezTerm 風のレイアウトも作れる。

### C. VS Code Remote-SSH で「新 ConPTY」経由にする（パターン 2 推奨）

ローカル Windows に VS Code を入れ、リモート Windows には何も足さずに
Remote-SSH で入って `claude` を起動する。リモート側の挙動は変えないので、
WezTerm からの普通の ssh も並行して使える。

#### C-1. VS Code と Remote-SSH 拡張

- ローカルに VS Code Stable を入れる（`https://code.visualstudio.com/`）
- 拡張機能から `Remote - SSH`（発行元 Microsoft）をインストール

#### C-2. SSH 接続先を登録

`Ctrl+Shift+P` → `Remote-SSH: Open SSH Configuration File...` →
`C:\Users\<あなた>\.ssh\config`：

```ssh
Host my-windows-host
    HostName 192.168.x.x
    User <リモートユーザ名>
    Port 22
    IdentityFile ~/.ssh/id_ed25519
```

#### C-3. 接続

`Ctrl+Shift+P` → `Remote-SSH: Connect to Host...` → `my-windows-host`。
初回はリモート側に `vscode-server` が `~/.vscode-server` 以下に展開される。

#### C-4. ConPTY DLL の確認（多くの場合は不要）

最近の VS Code Stable は、Remote-SSH のリモート Windows に対しても新しい
ConPTY DLL を **既定で使う** ようになっている。実測でも、特にこの設定をせずに
そのまま `claude` を起動して日本語入力が正常に通る。

なので **まずは設定を入れずに C-5 へ進んで、ずれが出たときだけ戻ってくる**
のが順序として正しい。

ずれる場合は、接続した状態で `Ctrl+,` → 「リモート」スコープに切り替え →
`windowsUseConptyDll` で検索して ON。`settings.json` には：

```json
{
  "terminal.integrated.windowsUseConptyDll": true,
  "terminal.integrated.gpuAcceleration": "auto",
  "terminal.integrated.defaultProfile.windows": "PowerShell"
}
```

設定を変えた場合は **VS Code を完全に再起動**する（`Reload Window` だけでは
ConPTY DLL の差し替えが反映されないことがある）。

#### C-5. Claude Code を起動

`` Ctrl+` `` でターミナルを開いて：

```powershell
cd C:\path\to\project
claude
```

ローカル WezTerm の `use_ime` 系設定は VS Code には無関係（VS Code は自前で
IME を扱う）。

### D. WSL に逃がす（パターン 2 → パターン 3 化）

リモート Windows に WSL2 を入れて、SSH ログインを WSL に着地させる：

```text
# C:\ProgramData\ssh\sshd_config の末尾
ForceCommand wsl
```

`Restart-Service sshd` してから、WSL 内で `npm i -g @anthropic-ai/claude-code`。
これで経路から Windows 同梱 ConPTY が完全に外れる。WezTerm 側は
`use_ime = true` / `front_end = "WebGpu"` のままでよい。

長時間セッションを併用したい場合は [`tmux.md`](./tmux.md) を参照。

---

## まとめ

- パターン 1 では **WezTerm Nightly + 設定** か **VS Code 統合ターミナル + 新 ConPTY**
- パターン 2 でいま現実的に効く手は **VS Code Remote-SSH 経由**
  （最近の VS Code は新 ConPTY DLL を既定で使うので追加設定不要、ずれたときだけ
  `windowsUseConptyDll: true` を入れる）
- リモート Windows でも **WSL に着地** させれば ConPTY 問題自体を回避できる
- WezTerm から ssh でリモート Windows に入って `claude` を動かす経路は、
  PowerShell の UTF-8 化や OpenSSH 更新を組み合わせても日本語入力ズレは
  解消しなかった（実測）。この経路は採らない

---

## 経緯

ズレの正体を整理しておく。

問題の根は **Windows 同梱の ConPTY**（疑似コンソール層、`CreatePseudoConsole`
API + `OpenConsole.exe`）の CJK 文字幅処理にある。最初は「ターミナル側の
問題」と思われていた（cmd / PowerShell / Windows Terminal / VS Code 統合
ターミナル）が、調べると ConPTY を経由する経路では同じズレが残ることが分かり、
ターミナルの差し替えだけでは直りきらないことが見えてきた。

これがあるので過去は WezTerm 一択だった、という整理をしがちだが、それは半分
正しくて半分違う：

- **ローカルで `claude.exe` を直接動かす場合**（パターン 1）は、WezTerm が
  自前で IME と幅判定を握っているので、Nightly + 適切な config なら入力は
  正常になる
- **WezTerm から `ssh` で他ホストに入った先の `claude`**（パターン 2）は、
  経路の途中に **リモート側の Windows ConPTY** が挟まるため、WezTerm を
  使ってもズレが残る — ターミナルを変えるだけでは足りない（実測でも、
  PowerShell の UTF-8 化や Win32-OpenSSH 更新を組み合わせても解消しなかった）

最近この状況が改善しているのは、**ConPTY が新しい経路を選べるようになった**
からで、Claude Code 側のバージョンで直ったわけではない。具体的には
**VS Code が新しい ConPTY DLL を同梱**し、`terminal.integrated.windowsUseConptyDll`
設定で OS 同梱版より新しいものを使えるようになった（ローカルでも Remote-SSH
経由でも有効）。

> 注: 元の議論ログには **Claude Code 自体の具体的なバージョン番号は登場しない**。
> 問題は Claude Code 側ではなく、その下を通る ConPTY 側にある、というのが
> ログの結論。本書の「検証バージョン」欄に書いた Claude Code 2.1.123 は
> あくまで本書執筆時に動作確認した版。

### 余談: VS Code を長時間つけっぱなしにすると別の症状が出る

ConPTY 由来の IME ズレとは別件で、**VS Code を長時間（数日単位）起動しっぱなしに
すると、統合ターミナルで英字すら文字化けし、ターミナルからの**
**コピペが効かなくなる** 現象を 2026-04-30 に観測した。プロファイル無効化や
`chcp` などの設定変更では直らず、**VS Code を再起動すると一発で直った**。
症状・再現条件・「設定変更では直らず再起動で直る」という挙動が、以下の
よく知られた VS Code 統合ターミナルの長時間セッション系バグ群と一致する：

- **GPU アクセラレーションの描画破綻**: 長時間起動でカーソルブロックや空白が
  ターミナル上にランダムに散らばり、文字が読めなくなる。回避策は
  `terminal.integrated.gpuAcceleration: "off"` か、`Ctrl +` / `Ctrl -` で
  ズーム切替して再描画。— [microsoft/vscode#163936](https://github.com/microsoft/vscode/issues/163936)
- **Shell Integration の OSC レース**: 長いコマンドや Python デバッガ実行時、
  Shell Integration が注入する OSC エスケープシーケンスが競合して文字化け
  文字列が出る。— [microsoft/vscode#281461](https://github.com/microsoft/vscode/issues/281461)
- **ターミナルプロセスのメモリリーク**: フォーカスリスナーやイベントハンドラが
  解放されず溜まり、長時間使うと挙動が破綻。コピペ崩壊と相性がよい。
  2025 年後半に修正 PR が連発で入っている (
  [#276962](https://github.com/microsoft/vscode/pull/276962),
  [#279088](https://github.com/microsoft/vscode/pull/279088),
  [#279167](https://github.com/microsoft/vscode/pull/279167),
  [#279172](https://github.com/microsoft/vscode/pull/279172) )。
  詳細は Bruce Dawson の調査記事 [Finding a VS Code Memory Leak](https://randomascii.wordpress.com/2025/10/09/finding-a-vs-code-memory-leak/) が参考になる。
- **1024 バイト境界のマルチライン破損**: 複数行コマンドがちょうど 1024 バイト目で
  壊れて引用符が閉じなくなる別系統のバグ。— [microsoft/vscode#296955](https://github.com/microsoft/vscode/issues/296955)

対処順としては「`Ctrl +` / `Ctrl -` で再描画 → ダメなら VS Code 再起動 → 頻発する
なら GPU acceleration を off / VS Code を最新に上げる」で実用十分。本書の本題
（IME ズレ = ConPTY 問題）とは別レイヤーの話だが、Windows + VS Code 統合
ターミナルで日本語作業をしていると両方を同時に踏みやすいので注記しておく。
