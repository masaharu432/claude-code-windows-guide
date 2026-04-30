# SAMBA の扱い

- 著者: 清水正晴
- 作成日: 2026-04-30

Windows と Linux（あるいは Windows 同士）でファイル共有するときの SAMBA
まわりの記録。Claude Code から共有先のファイルを直接編集したり、リモートの
作業ディレクトリを Windows 側のエクスプローラから覗いたりする運用を想定。

---

## なぜわざわざ書くのか — Claude Code 特有の落とし穴

Windows でユーザーがエクスプローラーの「ネットワークドライブの割り当て」で
SAMBA 共有を `D:` にマウントしても、**CLI で動く Claude Code からは
そのドライブが認識できない**。`Get-PSDrive` にも UNC パスにも現れず、
`Get-SmbMapping` では `Status: Unavailable` として観測される。

### 原因：ログオンセッション分離

Windows のマップドライブは **ログオンセッション単位**で管理されている
（さらに UAC の昇格状態でも分離される）。同じユーザー名であっても：

- ユーザーが GUI でサインインしているデスクトップセッション（例: `SessionId 1`）
- Claude Code が動くシェル（VS Code 統合ターミナル / SSH 経由 / `SessionId 0` のサービス文脈）

これらは別セッション扱いで、片方でマウントしたドライブはもう片方からは
見えない。SMB 認証情報（資格情報マネージャー）も同様にセッション単位。

### 解決：`New-SmbGlobalMapping`

Windows 標準搭載の `SmbShare` モジュール（Microsoft 純正）が提供する
`New-SmbGlobalMapping` を使うと、**OS グローバルなマウント**が作れる。
これは：

- 全セッションから見える（`SessionId 0` 含む、ユーザーログオン前から有効）
- `-Persistent $true` で再起動後も維持
- 事実上 Linux の `/etc/fstab` + `cifs-utils` 相当

### 制約

- **Windows 11 Pro 以上**（Home はモジュール自体は入っているが要検証）
- **NAS 側が SMB 3.x 対応**であること（Samba 4.0+）。Samba 3.x は SMB2 まで
  しかなく不可
- **管理者権限**で実行する必要あり
- エクスプローラの「PC」配下には**作成直後は表示されない**ことがある（CLI / UNC / ドライブレターでは見える）。コンテナ向け機能のため GUI 統合は弱い。**Windows を再起動すると「PC」配下にも表示されるようになる**（本環境 atom0 + Windows 11 Pro で 2026-04-30 に確認）
- 既知バグ：環境によっては再起動でマッピングが消える報告あり。保険として
  タスクスケジューラ「コンピュータの起動時」起動タスクを併用すると確実。
  ただし本環境（atom0 + Windows 11 Pro）では `-Persistent $true` だけで
  再起動後も `Status: OK` が維持されることを 2026-04-30 に検証済み

---

## 手順（Synology NAS / Windows 11 Pro）

### 0. 事前確認

PowerShell（管理者でなくてもよい）で以下を確認：

```
Get-Module -ListAvailable SmbShare
Get-Command New-SmbGlobalMapping
(Get-CimInstance Win32_OperatingSystem).Caption
Test-NetConnection -ComputerName <NAS名> -Port 445
```

`SmbShare` モジュールが見えて、Pro 以上、TCP 445 が通っていればOK。

### 1. 既存のセッション単位マッピングを除去

GUI で `D:` 等にマップしている場合、衝突を避けるため一旦外す。

```
Get-SmbMapping
Remove-SmbMapping -LocalPath D: -Force -UpdateProfile
```

### 2. 管理者 PowerShell を開く

`New-SmbGlobalMapping` は管理者権限必須。

- スタート → PowerShell を右クリック → **「管理者として実行」**
- または Win+X → 「ターミナル（管理者）」
- SSH 経由の場合は OpenSSH 仕様で **Administrators グループのユーザーは
  自動昇格**するので追加操作不要（`administrators_authorized_keys` 設定済が前提）

昇格しているかは以下で確認：

```
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

`True` が返れば管理者シェル。

### 3. 認証情報を入力してグローバルマウント作成

NAS 名 `atom0`、共有 `windows_shimi`、ユーザー名 `shimi` の例：

```
$cred = Get-Credential -UserName 'atom0\shimi' -Message 'atom0 SMB password'

New-SmbGlobalMapping -LocalPath D: -RemotePath '\\atom0\windows_shimi' -Credential $cred -Persistent $true
```

`Get-Credential` のダイアログでパスワードを入力。`-Persistent $true` で
再起動後も復活する。

> **重要**: ユーザー名は **必ず `<ホスト>\<ユーザー>` 形式**（例: `atom0\shimi`）で
> 渡すこと。`shimi` 単体だと `Windows System Error 1312` (指定された
> ログオンセッションは存在しません) で失敗する。`New-SmbGlobalMapping` は
> 全ユーザーから見えるグローバルマッピングを作るため double hop の認証を行い、
> その際に**認証先ホスト情報がユーザー名に含まれていないとログオンセッションを
> 確立できない**（[Microsoft Learn 公式トラブルシューティング](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-storage/files/connectivity/files-troubleshoot-smb-connectivity)
> より）。`net use` や `New-SmbMapping` は現ユーザーの文脈でしか動かないので
> ホスト指定無しでも通るが、`New-SmbGlobalMapping` は別物と覚えておく。

> **注意（実測 2026-04-30）**: `Get-Credential` は Windows 標準の **GUI 資格情報
> ダイアログ（CredUI）** を出す。さらに重要なのは、`Read-Host -AsSecureString`
> で `PSCredential` を自前で組み立てて渡しても、**`New-SmbGlobalMapping` の内部で
> SMB スタックが認証するタイミングで OS が CredUI を出してくることがある**
> （実測でそうなった）。つまり「コンソール入力でダイアログを完全に回避する」
> ことは `New-SmbGlobalMapping` に対しては期待できない。
>
> 結論として：
>
> - **GUI ダイアログが出るのは前提**として運用設計するのが安全
> - **ローカル / RDP / コンソールセッション**（デスクトップが見える環境）で
>   実行するのが基本
> - SSH 経由で実行する場合は、ダイアログがリモートのデスクトップ側に出るので
>   **RDP で同じユーザーに繋いでおいてダイアログを操作する**運用にする
> - 完全に非対話で動かしたい場合は、後述のとおり**タスクスケジューラに
>   SYSTEM 権限のタスクを仕込む**のが正攻法（資格情報は事前にタスク側に保存）
>
> VS Code 統合ターミナルから実行した場合、ダイアログが本体ウィンドウの裏に
> 潜ることがある。タスクバーや Alt+Tab で「Windows セキュリティ」が出て
> いないか確認すること。

### 4. 結果確認

```
Get-SmbGlobalMapping | Format-List Status, LocalPath, RemotePath

Get-SmbConnection | Where-Object ServerName -eq 'atom0' | Format-List ServerName, ShareName, Dialect, Encrypted, Signed

Get-ChildItem D:\ | Select-Object -First 5 Name, Length, LastWriteTime
```

期待値：

- `Status: OK`
- `Dialect: 3.1.1`（または `3.0.2`）
- ファイル一覧が出る

> **メモ**: `Get-SmbGlobalMapping` の出力には `Persistent` プロパティは
> 露出しない（`MSFT_SmbGlobalMapping` の仕様）。`-Persistent $true` で
> 作っても標準出力では確認不可。永続性は **Windows 再起動後にもう一度
> `Get-SmbGlobalMapping` を叩いて `Status: OK` が残っているか**で
> 間接的に確認する。

### 5. Claude Code から見えるか検証

Claude Code が動いている別セッション（例: `SessionId 0` のサービス文脈）で：

```
Get-SmbGlobalMapping
Get-PSDrive -PSProvider FileSystem
Get-ChildItem D:\
```

`D:` が見えてファイル一覧が取れれば成功。`Get-SmbMapping` ではなく
`Get-SmbGlobalMapping` で照会するのがポイント（前者はセッション単位）。

### 6. 解除したいとき

```
Remove-SmbGlobalMapping -LocalPath D: -Force
```

---

## トラブルシューティング

| 症状 | 原因 / 対処 |
| --- | --- |
| `Windows System Error 1312` / 指定されたログオンセッションは存在しません | **ユーザー名にホスト情報が無い**のが原因。`shimi` ではなく `atom0\shimi` のように `<ホスト>\<ユーザー>` 形式で渡す。`New-SmbGlobalMapping` は double hop 認証なのでホスト解決にユーザー名のドメイン部分が必須。出典: [Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-storage/files/connectivity/files-troubleshoot-smb-connectivity) |
| `The user name or password is incorrect` | NAS 側のユーザー名/パスを再確認。Synology は DSM のユーザー |
| `Network path was not found` | `Test-NetConnection <NAS> -Port 445` で疎通確認。ファイアウォール / VLAN / SMB 無効化を疑う |
| `Access is denied` | 管理者 PowerShell で実行しているか。`IsInRole(Administrator)` で確認 |
| `The local device name is already in use` | 既存マッピングと衝突。`Remove-SmbGlobalMapping -LocalPath D: -Force` してから再試行 |
| 再起動するとマッピングが消える | 既知バグ。タスクスケジューラ「コンピュータの起動時」起動タスクで `New-SmbGlobalMapping` を再実行する保険を仕込む |
| `Get-SmbMapping` で `Status: Unavailable` が出る | これはセッション単位の旧マッピングの残骸。`Remove-SmbMapping` で消すか無視してよい |
| エクスプローラの「PC」に出てこない | `New-SmbGlobalMapping` の仕様。CLI / `D:\` 直アクセスは可能 |

---

## 参考

- [New-SmbGlobalMapping (SmbShare) | Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/smbshare/new-smbglobalmapping)
- [How To Mount And Persist An Azure File Share With Windows - Charbel Nemnom](https://charbelnemnom.com/mount-and-persist-azure-file-share-with-windows/)
- [OpenSSH Server Configuration for Windows | Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
- [SMB3 kernel status - SambaWiki](https://wiki.samba.org/index.php/SMB3_kernel_status)（Samba ↔ SMB バージョン対応）
