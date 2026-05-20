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
限らない。期限切れ PAT、空文字列、無効化されたトークン、どれも同じ文言になる。

（なぜ年々こうも壊れやすいかの経緯は本書末尾の「[付録: GitHub 認証の経緯](#付録-github-認証の経緯)」を参照）

## 結論（推奨パス: GCM + device flow）

Windows + SSH リモート経由で作業している前提。手元 PC のブラウザを使う
device flow で完結する。次の 5 ステップ：

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

### 4. repo-local の URL-specific helper があれば外す

ここを **見落とすと GCM が呼ばれない**。次のコマンドで repo-local の
github.com 用 helper を削除：

```powershell
git config --local --unset-all credential.https://github.com.helper
```

そんな設定入れた覚えがなくても、過去に gh CLI や CI スクリプトが書き込んでいる
ことがあるので念のため必ず実行する。

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

---

## それでも直らない時の切り分け手順

「上の 5 ステップを通したのにまだ 401」「上の手順が刺さらない」など、別の要因が
重なっているケースの調べ方。

### A. git config を全 scope で見る

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
helper** が混ざっていたら、それが優先されて GCM が呼ばれない。次節 B を見る。

### B. PAT-from-env 注入ヘルパーが刺さっていないか

ありがちな anti-pattern：

```
local credential.https://github.com.helper=!f() { echo username=x-access-token; echo "password=$GITHUB_PERSONAL_ACCESS_TOKEN"; }; f
```

これは `$GITHUB_PERSONAL_ACCESS_TOKEN` 環境変数を読んで送る仕組み。env に
有効な PAT が入っていれば動くが、env が消えた／PAT が期限切れになった瞬間に
GCM へのフォールバックなしで失敗する。**結論セクションのステップ 4 で消える
のはこれ**。

env 変数が現在何を持っているかも確認：

```powershell
$env:GITHUB_PERSONAL_ACCESS_TOKEN
$env:GITHUB_TOKEN
$env:GH_TOKEN
```

### C. Windows 資格情報マネージャを見る

```powershell
cmdkey /list | Select-String -Pattern 'github' -SimpleMatch
```

`LegacyGeneric:target=git:https://github.com` が見えたら、それは Git が wincred
helper 経由で読む古い形式のエントリ。中身が期限切れ PAT のことが多い。
結論セクションのステップ 3 で消える。

### D. Git Credential Manager がインストールされているか

```powershell
Get-ChildItem 'C:\Program Files\Git' -Recurse -Filter 'git-credential-manager*.exe' -ErrorAction SilentlyContinue
Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter 'git-credential-manager*.exe' -ErrorAction SilentlyContinue
```

両方とも空なら GCM は無い。`credential.helper=manager` だけが設定されている
状態だと、git は「`manager` という helper を呼べ」と解釈するが本体が無いので、
最終的にどこかの古い credential を読んで送り出す挙動になる（その結果が 401）。

## 今回ハマった具体ケース（参考事例）

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
- **直しの第一歩は GCM + device flow を入れる + repo-local URL-specific helper を消す**
- それで直らなければ全 scope の `git config --list --show-scope` で credential
  設定を並べる。特に **URL-specific helper** と **env var helper** が犯人
- Windows + SSH リモート + Claude Code の組合せでは **GCM + device flow** が
  現状ベスト。winget `Git.GCM` で入れ、
  `credential.https://github.com.gitHubAuthModes=device` を入れておく
- repo-local の env-var 注入ヘルパーは env が落ちた瞬間に詰むので使わない
  （あっても外す）

---

## 付録: GitHub 認証の経緯

「なぜこんなに壊れやすくなったか」の背景。直す作業には不要だが、再発防止と
今後の方針判断に役立つ。

### 年表

| 時期 | 変化 |
| --- | --- |
| ~2020 | GitHub アカウントのパスワードをそのまま git push に使えた |
| 2020-11 | パスワード認証廃止を予告 |
| **2021-08-13** | **HTTPS でのパスワード認証を完全廃止**。以降 PAT (Personal Access Token) 必須 |
| 2022〜 | classic PAT に expiration を強く推奨 |
| 2023〜 | fine-grained PAT 登場（最初から expiration 必須・最長 1 年） |
| 現在 | classic PAT も expiration 必須化が進行。device flow による OAuth が推奨パスに |

### 何が起きているか

GitHub は **「永続的に効く秘密情報」を Git 操作から排除する**方向に一貫して
動いている。理由は単純で、PAT 漏洩事故が長年積み上がってきたため：

- GitHub 自身、Travis CI、CircleCI 等で PAT が CI ログや public repo に流出する
  事故が定期的に発生
- 長命 PAT を持ち回るマシン（特に CI / 共有サーバー）で漏洩リスクが累積
- 失効させてもユーザー側に再設定の手間が大きく、結果として「漏れたまま使われる」
  ケースが減らない

対策として GitHub が選んだ方針：

1. **パスワード認証廃止**（2021）— 直接的なクレデンシャル漏洩リスクを潰す
2. **fine-grained PAT の expiration 必須化**（2023）— 漏洩しても自動で死ぬように
3. **OAuth + refresh token への誘導**（現在進行形）— refresh token は短命 access
   token と組み合わせて使う形なので、漏洩時の被害が一過性で済む

GCM はこの「OAuth + refresh token」を Windows 上で透過的にやってくれる純正
クライアント。**「PAT を自分で発行・期限管理せずに、OAuth で済ませる」のが
GitHub 公式の現在の推奨パス**になっている。

### Windows + Git 環境で詰みやすい理由

ここに **Windows 固有の事情**が重なってさらに厄介になる：

- **GCM が同梱されない Git 配布が混在**：Git for Windows 公式 installer は GCM を
  同梱するが、MinGit、Visual Studio バンドル、Chocolatey の minimal 配布などは
  GCM を含まない。それでも `credential.helper=manager` だけは設定されることが
  ある（installer が config だけ書く）
- **Windows 資格情報マネージャに古いエントリが残る**：GitHub の HTTPS 用 PAT を
  入れたことがあるマシンには `LegacyGeneric:target=git:https://github.com` が
  残っており、期限切れになっても自動で消えない
- **env var ベースの helper を CI から持ち込みやすい**：`gh auth login` や CI
  スクリプトが repo-local config に `!f() { ...; }` 系の helper を書き込むことが
  あり、それが残ったまま env が落ちる
- **SSH リモート経由で作業しているとブラウザが使えない**：GCM のデフォルト OAuth
  flow はブラウザ起動だが、SSH リモートではブラウザがないので失敗する。device
  flow を明示的に有効化しないと動かない

これらが「**ある日突然 push できなくなる**」の正体。

## 参考

- GitHub Blog: [Token authentication requirements for Git operations (2021-08-13)](https://github.blog/security/application-security/token-authentication-requirements-for-git-operations/)
- GitHub Docs: [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- Git Credential Manager: [github.com/git-ecosystem/git-credential-manager](https://github.com/git-ecosystem/git-credential-manager)
- GCM Device flow 解説: [GCM Configuration: GitHub-specific options](https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/configuration.md#credentialgithubauthmodes)
