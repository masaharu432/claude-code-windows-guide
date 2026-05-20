# VS Code Remote-SSH ターミナルでの Claude Code 文字化け対処

- 著者: 清水正晴
- 作成日: 2026-05-20
- 検証バージョン:
  - Claude Code 2.1.123
  - VS Code 1.118.1 (user setup)
  - OS（リモート Windows）: Windows 11 Pro 10.0.26200, PowerShell 5.1.26100.8457

## 問題

VS Code の統合ターミナルを **Remote-SSH でリモート Windows に接続**し、その
PowerShell 上で **Claude Code（TUI）** を実行すると、ターミナル上の文字
（日本語含む、英字も）が頻繁に崩れる・グリフが乱れる・部分的にゴミが残る
現象が発生する。長時間 Claude Code を走らせるほど頻度が上がる。

[`ime-shift.md`](./ime-shift.md) 末尾の「余談」で触れている VS Code 統合
ターミナルの長時間セッション系バグ群と同じレイヤーの話で、IME ズレ
（ConPTY 問題）とは別レイヤー。

## 切り分け（サーバー側は原因ではない）

最初に「リモート Windows 側のロケール/エンコーディングがおかしいのでは」を
疑ったが、実測値はいずれも正常で、サーバー側は無罪。

| 項目 | 実測値 | 評価 |
| --- | --- | --- |
| `chcp` | `65001` | OK |
| `[Console]::OutputEncoding` | UTF-8 (CP 65001) | OK |
| `[Console]::InputEncoding` | UTF-8 (CP 65001) | OK |
| `$OutputEncoding` | US-ASCII (CP 20127) | パイプ時のみ影響、表示崩れには無関係 |
| `$env:TERM` | `xterm-256color` | OK |
| `$env:LANG` | `en_US.UTF-8` | OK |
| `$env:LC_ALL` | （空） | 問題なし |
| `$env:TERM_PROGRAM` | `vscode` | クライアント識別 |

つまり **リモート Windows 側のコードページ/ロケールは正しく UTF-8 に揃っており、
表示崩れの主因ではない**。

## 主因（クライアント側 VS Code の描画）

崩れの本体は **手元 PC で動いている VS Code 統合ターミナルのレンダリング
パス（GPU 加速 + カスタムグリフ + Remote-SSH 越しのリサイズ/再描画）**。
TUI を出す Claude Code とこのレンダリングパスの相性が悪く、長時間セッションや
リサイズ契機で文字が破綻する。

関連 issue（出典）:

- [microsoft/vscode#269471](https://github.com/microsoft/vscode/issues/269471)
  — Experimental GPU Acceleration causes rendering glitches
- [microsoft/vscode#163936](https://github.com/microsoft/vscode/issues/163936)
  — Terminal GPU acceleration rendering issues on long sessions（[`ime-shift.md`](./ime-shift.md) 余談でも参照）
- [anthropics/claude-code#59163](https://github.com/anthropics/claude-code/issues/59163)
  — TUI character corruption after long sessions in VS Code integrated terminal
- [anthropics/claude-code#59239](https://github.com/anthropics/claude-code/issues/59239)
  — Terminal display becomes garbled and unreadable after using Claude Code
- [anthropics/claude-code#59915](https://github.com/anthropics/claude-code/issues/59915)
  — Intermittent terminal rendering corruption in VS Code

参考: [VS Code ターミナル外観のドキュメント](https://code.visualstudio.com/docs/terminal/appearance)

## 対策

### A. クライアント側（手元 PC の VS Code ユーザー設定 `settings.json`）

これが本体。`Ctrl+,` → 右上「Open Settings (JSON)」アイコン → 以下を追加：

```json
{
  "terminal.integrated.gpuAcceleration": "off",
  "terminal.integrated.customGlyphs": false,
  "terminal.integrated.rescaleOverlappingGlyphs": false,
  "terminal.integrated.fontFamily": "'Cascadia Code', 'Consolas', 'Courier New', monospace"
}
```

各キーの意味：

- `gpuAcceleration: "off"` — GPU 描画パスを切って Canvas/DOM 描画に落とす。
  vscode#269471 / #163936 の系統で根本的に効く
- `customGlyphs: false` — VS Code が描画する独自グリフ（Powerline/罫線等）を
  無効化し、フォント側のグリフに任せる
- `rescaleOverlappingGlyphs: false` — オーバーラップ検出時のリスケールを切り、
  リスケール処理に起因する乱れを潰す
- `fontFamily` — フォント切替起因のグリフずれを防ぐためフォールバックを固定
  （任意。日本語をよく扱うなら `'BIZ UDGothic'` をフォールバックに足してもよい）

**実測結果（2026-05-20）**: `gpuAcceleration: "off"` を `settings.json` に
書いた瞬間、**VS Code のリロードもウィンドウ再起動も不要**でその場で崩れが
止まり、以降の長時間セッションでも再現しなくなった（保存と同時に描画パスが
切り替わる）。`customGlyphs` / `rescaleOverlappingGlyphs` は予防的に
併用しておく。

### B. サーバー側（このリモート Windows 上）

A だけで実用十分だが、補助的に：

- **Claude Code を最新化**: `claude update`。長セッション中の glyph 崩れに
  関する修正が随時 Claude Code 側にも入っている
- **崩れたら即リカバリ**:
  - ターミナルを 1 回リサイズ（タブを切り出す / ペイン分割で幅変更）して再描画
    を強制する
  - Claude Code 内で `/clear` を打って画面を再構成
  - それでも収まらないなら `/exit` → ターミナル閉じる → 開き直して
    `claude --resume` で復帰。会話履歴は自動保存されているので文脈は失われない

### やってはいけない / 効かないこと

[`CLAUDE.md`](./CLAUDE.md) の env 継承チェーン解説とも関連するが、表示崩れの
リカバリで効かない / 意味がないものを念のため：

- ローカル / リモート側の **Explorer 再起動**（描画パスとは無関係）
- リモート Windows の **ログオフ/ログオン**（SSH セッションに紐づかない）
- **「Developer: Reload Window」** のみ（vscode-server プロセスは生き残るため
  描画パスが切り替わらないことがある — 「完全再起動」が必要）
- **`Terminal: Restart`** のみ（GPU 描画が切り替わるのは VS Code 本体プロセス
  再起動のタイミング）

## まとめ

- リモート Windows 側のロケール/コードページは正しく UTF-8、サーバー側は無罪
- 主因は **クライアント側 VS Code 統合ターミナルの GPU 描画パスと、
  Remote-SSH 越しの再描画/長時間セッションの相性**
- **手元 PC の VS Code `settings.json` で `terminal.integrated.gpuAcceleration: "off"`**
  を入れて VS Code を完全再起動するのが効く（実測で再現しなくなった）
- 併せて `customGlyphs: false` / `rescaleOverlappingGlyphs: false` を予防的に
  入れておく
- 崩れたときの応急処置はリサイズ → `/clear` → `exit` + `claude --resume`
- IME 位置ズレ（ConPTY 系）は別レイヤー。そちらは [`ime-shift.md`](./ime-shift.md) を参照
