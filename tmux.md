# tmux の使い方（Windows / WSL / SSH 先）

- 著者: 清水正晴
- 作成日: 2026-04-30

長時間の Claude Code を SSH 越しに走らせるなら tmux が便利。回線が切れても
セッションが残り、複数ペインで作業を並列化できる。

## どこで tmux を動かすか

Windows ネイティブには tmux はない。動かすのは：

- **SSH 接続先のリモート Linux** で動かす（一番素直）
- **WSL2 (Ubuntu 等)** の中で動かす
- **Git Bash / MSYS2** にも tmux パッケージはあるが、WSL の方が安定

リモート Windows ホストに対して使いたい場合は、`ForceCommand wsl` ルート
（[`ime-shift.md`](./ime-shift.md) の D 節を参照）と組み合わせると、SSH 着地後
すぐに WSL の tmux に入れる。

## 最低限おぼえておく操作

`Ctrl+b` がプレフィックス（押してから次のキー）。

| 操作 | キー |
| --- | --- |
| 新規セッション | `tmux new -s work` |
| デタッチ（抜ける） | `Ctrl+b` → `d` |
| アタッチ（戻る） | `tmux attach -t work` |
| セッション一覧 | `tmux ls` |
| ペイン縦分割 | `Ctrl+b` → `%` |
| ペイン横分割 | `Ctrl+b` → `"` |
| ペイン移動 | `Ctrl+b` → 矢印キー |
| ウィンドウ新規 | `Ctrl+b` → `c` |
| ウィンドウ切替 | `Ctrl+b` → `n` / `p` |

## 典型的な運用

```bash
tmux new -s claude
claude
# Ctrl+b → d でデタッチ。回線が切れても claude は走り続ける。
tmux attach -t claude
```

長尺タスクを投げて回線切断 → 後で結果を回収、という運用ができる。
VS Code Remote-SSH のターミナル内で tmux を起動しても問題なく動く。

---

<!-- 以下、運用しながら追記していく -->

## .tmux.conf の設定例

（追記予定）

## トラブルシューティング

（追記予定）
