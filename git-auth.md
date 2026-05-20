# Git HTTPS push が急に通らなくなった時の直し方（Windows + Claude Code）

- 著者: 清水正晴
- 作成日: 2026-05-20
- 検証バージョン:
  - Git for Windows 2.49.0
  - Git Credential Manager 2.8.0（winget `Git.GCM`）
  - OS: Windows 11 Pro 10.0.26200
  - SSH リモート経由の VS Code Remote-SSH 環境

## 問題

ある日突然、`git push` がこのエラーで止まる：

```
remote: Invalid username or token. Password authentication is not supported for Git operations.
fatal: Authentication failed for 'https://github.com/<owner>/<repo>.git/'
```

「Password authentication is not supported」とあるが、これは **GitHub が認証失敗
全般に対して同じ文言を返す**ことに注意。「文字通りパスワード送ってる」とは
限らない。実際に多いのは：

- 以前有効だった **PAT が期限切れ**になった
- **Windows 資格情報マネージャに古い PAT** が残っていて、それが送られている
- **環境変数や repo-local config の PAT 注入**が動いていて、その PAT が無効に
  なっている

本ドキュメントは、最後の「env 経由 PAT が古い × Git Credential Manager 未インストール」
の組み合わせで実際にハマったケースの記録と、その直し方をまとめる。

## なぜ GitHub の Git 認証はこう面倒なのか（経緯）

GitHub の HTTPS Git 認証は年々厳しくなっている：

| 時期 | 変化 |
| --- | --- |
| ~2020 | GitHub アカウントのパスワードをそのまま git push に使えた |
| 2020-11 | パスワード認証廃止を予告 |
| **2021-08-13** | **HTTPS でのパスワード認証を完全廃止**。以降 PAT (Personal Access Token) 必須 |
| 2022〜 | classic PAT に expiration を強く推奨 |
| 2023〜 | fine-grained PAT 登場（最初から expiration 必須・最長 1 年） |
| 現在 | classic PAT も expiration 必須化が進行。device flow による OAuth が推奨パスに |

つまり「以前は永続的に動いていた認証情報」が、知らぬ間に **PAT の自動期限切れ**で
止まる、というのが Windows + Git 環境で最も多いトリガーになっている。

## 切り分け手順

「急に push できなくなった」を見たら、上から順に確認する。

### 1. git config を全 scope で見る

```powershell
git config --list --show-scope | Select-String -Pattern 'credential'
```

期待する出力（GCM が正しくセットアップされていれば）：

```
system  credential.helper=manager
global  credential.helper=
global  credential.helper=C:/Users/<user>/AppData/Local/Programs/Git Credential Manager/git-credential-manager.exe
```

ここに **`credential.https://github.com.helper=...`** のような **URL-specific
helper** が混ざっていたら要注意。URL-specific 設定は generic 設定を上書き
するので、GCM が呼ばれずに別経路で credential が決まっている。

特に次のような **PAT-from-env 注入ヘルパー** が repo-local に書かれていることがある：

```
local credential.https://github.com.helper=!f() { echo username=x-access-token; echo "password=$GITHUB_PERSONAL_ACCESS_TOKEN"; }; f
```

これは `$GITHUB_PERSONAL_ACCESS_TOKEN` 環境変数を読んで送る仕組み。env に
有効な PAT が入っていれば動くが、env が消えた／PAT が期限切れになった瞬間に
GCM へのフォールバックなしで失敗する。

### 2. Windows 資格情報マネージャを見る

```powershell
cmdkey /list | Select-String -Pattern 'github' -SimpleMatch
```

`LegacyGeneric:target=git:https://github.com` が見えたら、それは Git が wincred
helper 経由で読む古い形式のエントリ。中身が期限切れ PAT のことが多い。

### 3. Git Credential Manager がインストールされているか

```powershell
Get-ChildItem 'C:\Program Files\Git' -Recurse -Filter 'git-credential-manager*.exe' -ErrorAction SilentlyContinue
Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter 'git-credential-manager*.exe' -ErrorAction SilentlyContinue
```

両方とも空なら GCM は無い。`credential.helper=manager` だけが設定されている
状態だと、git は「`manager` という helper を呼べ」と解釈するが本体が無いので、
最終的にどこかの古い credential を読んで送り出す挙動になる（その結果が 401）。

### 4. 環境変数を見る

```powershell
$env:GITHUB_PERSONAL_ACCESS_TOKEN
$env:GITHUB_TOKEN
$env:GH_TOKEN
```

`gh` CLI や直接 export で設定されていることがある。空 or 古い値だと repo-local
helper と組み合わさってハマる。

## 今回ハマった具体ケース

複数の要因が重なっていた：

1. **GCM がインストールされていない**（Git for Windows 2.49 だが GCM 同梱版を
   入れていない・MinGit を入れた等）。`C:\Program Files\Git` 配下に
   `git-credential-manager.exe` が無かった
2. それでも `system` scope に `credential.helper=manager` が設定されており、
   git は「`manager`」という名前の helper を探そうとして失敗
3. 同時に **repo-local config に PAT-from-env helper が刺さっていた**：

   ```
   local credential.https://github.com.helper=!f() { echo username=x-access-token; echo "password=$GITHUB_PERSONAL_ACCESS_TOKEN"; }; f
   ```

   URL-specific helper なので global / system よりも優先され、GCM 設定があっても
   こちらが先に呼ばれる
4. `$GITHUB_PERSONAL_ACCESS_TOKEN` 環境変数が空（または期限切れ）で、
   結果的に空または無効な PAT が送られて GitHub が 401 を返していた

エラーメッセージは「Password authentication is not supported」だが、本当の
原因は「**期限切れ／空の PAT を env helper 経由で送っていた**」だった。

## 修正手順（推奨パス: GCM device flow）

SSH リモート Windows での作業を想定。手元 PC のブラウザを使う device flow で
完結する。

### 1. Git Credential Manager をインストール

winget の正しいパッケージ ID は **`Git.GCM`**（`GitHub.GitCredentialManager` は
別物・存在しない）。

```powershell
winget install --id Git.GCM --accept-source-agreements --accept-package-agreements --silent
```

インストール先は `C:\Users\<user>\AppData\Local\Programs\Git Credential Manager\`。
インストーラが `~/.gitconfig` に絶対パスで helper を登録してくれるので、PATH
追加は不要。

### 2. SSH リモート用に device flow を既定にする

ブラウザを起動できない SSH 環境では、`https://github.com/login/device` に
コードを打ち込む device flow が必要。GCM に github.com 用の auth mode として
device を強制する：

```powershell
git config --global credential.https://github.com.gitHubAuthModes device
```

### 3. 古い credential を削除

```powershell
cmdkey /delete:LegacyGeneric:target=git:https://github.com
```

無くてもエラーにはならない（最初から無ければスキップされる）。

### 4. repo-local の URL-specific helper を消す

ここが今回の **本当の効いた一手**。global の GCM 設定があっても repo-local の
URL-specific helper が優先されるので、それを外す：

```powershell
git config --local --unset-all credential.https://github.com.helper
```

これで `git push` 時の credential lookup は最終的に global の GCM (絶対パス) に
落ちるようになる。

### 5. push してデバイスコード認証

```powershell
git push
```

GCM が起動して次のような表示が出る：

```
Select an authentication method for 'https://github.com/':
  1. Device code (default)

To complete authentication, visit:
  https://github.com/login/device

Enter the following code:
  ABCD-1234
```

このコード（8 文字、英字混じり）を **手元 PC のブラウザで `https://github.com/login/device`** に
入力 → GitHub にログイン → **2FA を聞かれたら Authenticator アプリの 6 桁 TOTP** を
入力 → Git Credential Manager の OAuth 承認画面で Authorize。ターミナルに戻ると
push が走り出す。

> 注: ブラウザ側の 8 文字入力欄と Authenticator アプリの 6 桁数字は **別物**。
> 8 文字はターミナルに出るデバイスコード、6 桁は 2FA。順序は「8 文字 → ログイン → 6 桁」。

### 6. 完了確認

```powershell
git log --oneline origin/main..main
```

何も出なければ push 済み。以降は GCM が refresh token を Windows 資格情報
マネージャに保存しているので、次回からは無確認で push が通る。

## 各認証方式の比較

| 方式 | 設定難度 | 期限管理 | SSH リモートでの相性 | おすすめ度 |
| --- | --- | --- | --- | --- |
| **GCM (device flow)** | winget で 1 発、device flow 用に config 1 行 | refresh token を GCM が更新 | ◎ | ★★★ |
| **PAT 直入力** | PAT 発行 → cmdkey で保存 | 自分で expire 管理 | ○ | ★ |
| **SSH 鍵 + remote SSH URL** | ssh-keygen → 公開鍵を GH に登録 → remote set-url | 鍵を漏らさない限り永続 | ◎ | ★★ |
| **env var helper** | helper script + env var | env と PAT 両方の管理 | △（env を SSH に持ち込む必要） | × |

env var helper は CI / Codespaces のような「短命環境で env から PAT を流し込む」
用途以外では使わない方がよい。今回のように env が消えた瞬間に GCM の救済も
得られず、しかもエラーが misleading になる。

## まとめ

- `Password authentication is not supported` は **PAT が期限切れ / 空 でも同じ文言**
  で返る。額面通り受け取らないこと
- 真の犯人は **`git config --list --show-scope`** で全 scope の `credential.*` を
  並べるのが一番速い。特に **URL-specific helper** と **env var helper** に注目
- Windows + SSH リモート + Claude Code の組合せでは **GCM + device flow** が
  現状ベスト。winget `Git.GCM` で入れ、`credential.https://github.com.gitHubAuthModes=device`
  を入れておく
- repo-local の `credential.https://github.com.helper=!f() { ... }` 系の env-var
  注入ヘルパーは、env が落ちた瞬間に詰むので使わない（あっても外す）
- GitHub の HTTPS 認証は年々厳しく（パスワード廃止、PAT 期限化）なっており、
  「永続的に効く PAT」は実質もう存在しない。OAuth refresh token を握ってくれる
  GCM が今の正解

## 参考

- GitHub Blog: [Token authentication requirements for Git operations (2021-08-13)](https://github.blog/security/application-security/token-authentication-requirements-for-git-operations/)
- GitHub Docs: [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- Git Credential Manager: [github.com/git-ecosystem/git-credential-manager](https://github.com/git-ecosystem/git-credential-manager)
- GCM Device flow 解説: [GCM Configuration: GitHub-specific options](https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/configuration.md#credentialgithubauthmodes)
