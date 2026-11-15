# Cross Review Kit

作成側の会話履歴を渡さず、別プロセスの Codex CLI にレビューさせる最小構成です。対象は試験項目、ソースコード、設計書のいずれでもよく、レビュー指示自体は業務固有の内容を持ちません。

## 前提

- Windows PowerShell 5.1
- Codex CLI 0.167.2（`codex --version` で確認）
- モデル `gpt-6.1-sol`
- 既存の `codex login`。スクリプトに API キーは置きません
- Windows サンドボックス実装 `mxc`。読み取り拒否を強制できない実装へはフォールバックしません

外部ライブラリ、exe、常駐サーバーは使いません。

## ファイル

| パス | 役割 |
| --- | --- |
| `review.ps1` | コピー、アクセス制御の確認、Codex 実行、結果の検証 |
| `fixtures/spec.md` | 根拠資料。汎用的な記録項目の仕様 |
| `fixtures/test-items.md` | レビュー対象。仕様との不整合を意図的に含む試験項目 |
| `fixtures/criteria.md` | レビュー基準。網羅、整合、参照、判定可能性、境界 |
| `review-result.json` | 下記の検証実行で保存した結果 |

## 実行方法

リポジトリのルートで実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review.ps1 `
  -Target .\fixtures\test-items.md `
  -Evidence .\fixtures\spec.md `
  -Criteria .\fixtures\criteria.md `
  -Output .\review-result.json
```

| 引数 | 意味 |
| --- | --- |
| `-Target` | レビュー対象。ファイルまたはディレクトリ |
| `-Evidence` | 根拠資料。複数指定できる。省略時は空 |
| `-Criteria` | レビュー基準のファイルまたはディレクトリ |
| `-Output` | 結果 JSON のパス。既定は `review-result.json` |
| `-Model` | 既定は `gpt-6.1-sol` |
| `-SelfTest` | モデルを呼ばず、結果の分類だけを確認する |

`-Evidence` を繰り返すか、カンマ区切りで複数渡せます。指定したパスだけを一時ワークスペースへコピーします。

`-Output` は正規化した絶対パスで比較します。対象・根拠資料・レビュー基準のいずれかと同じファイル、またはそれらがディレクトリのときその内部へは書きません。比較に使うパスは、入力確認や CLI 確認の前に元の引数から取ります。書き込む直前に必ず確認し、危険な場合も、安全性を確認できない場合も、失敗 JSON を含め書きません。終了コードは 2 です。

終了コードは次のとおりです。

| コード | 意味 |
| --- | --- |
| 0 | `status` が `completed`。指摘 0 件も成功 |
| 1 | レビュー不能、アクセス制御の不合格、CLI の異常終了、JSON 不正、元ファイルの変更 |
| 2 | 出力先が入力資料と重なる、入力不足、`codex` 不在などの準備失敗 |

## 処理の流れ

1. 対象、根拠資料、基準のハッシュを記録する。
2. 一時ディレクトリを作り、指定ファイルだけを `target/`、`evidence/`、`criteria/` へコピーする。
3. Codex の権限プロファイルでファイルアクセスを確認する。ここで失敗した場合、レビューは実行しない。
4. 新しい非対話の `codex exec` を実行する。作成側の会話は渡さない。
5. 終了コードと最終メッセージの JSON を検証する。
6. 元ファイルのハッシュが変わっていないことを確認する。
7. 一時ワークスペースを削除し、結果を `-Output` へ書く。

レビュープロセスには `--ephemeral`、`--ignore-user-config`、`--ignore-rules` を付けます。セッションは保存せず、利用者の `config.toml` と execpolicy の `.rules` も読みません。認証だけ既存の Codex CLI ログインを使います。承認待ちで止まらないよう `approval_policy` は `never` です。

## ファイルアクセス制御

一時ディレクトリへのコピーは、渡すファイルを絞るための手順です。セキュリティ境界には使いません。

境界は Codex の権限プロファイル `cross-review` です。Windows の MXC サンドボックスに、次を適用します。

- `:root`、`:tmpdir`、`:slash_tmp` は `deny`
- `:minimal` だけ、コマンド実行に必要な基盤パスとして `read`
- 一時ワークスペースの絶対パスだけを `read` で開き直す
- コマンドのネットワークは無効
- レガシーな `--sandbox read-only` は使わない。この指定はディスク全体を読める古いモードであり、権限プロファイルを無効にするため

Codex CLI 0.167.2 の `codex sandbox` には `--ignore-user-config` と `--ignore-rules` がありません。アクセス検証は、空の `CODEX_HOME`（ユーザー設定もユーザールールも無い）と `--include-managed-config` を使い、本番の `codex exec` と同じ `-c` 権限プロファイルを渡します。`--include-managed-config` は、`exec` が既定で読む managed requirements を検証側でも外さないためです。

実行前に、その条件で `codex sandbox` を三回呼びます。

- ワークスペース内の確認用ファイルは読める
- ワークスペースの隣に置いた確認用ファイルは、OS 上では読めるがサンドボックスでは拒否される
- ワークスペース内への書き込みは拒否される

一つでも崩れた場合、`status` は `failed`、`error.type` は `access_control` になり、モデルは呼びません。

## 結果の形

照合できたときは `findings` が配列です。指摘が無いときは空配列です。レビュー不能と実行失敗は `findings` が `null` で、`status` と `error.type` で区別します。

```json
{
  "status": "completed",
  "findings": []
}
```

```json
{
  "status": "not_reviewable",
  "findings": null,
  "error": { "type": "review_impossible", "message": "要求が無く照合できない" }
}
```

```json
{
  "status": "failed",
  "findings": null,
  "error": { "type": "cli_exit", "message": "...", "exit_code": 1 }
}
```

モデルへ渡すスキーマは `completed` と `not_reviewable` を区別します。`not_reviewable` は、資料を読めない場合と、判断に必要な要求や対象の記載が無く照合できない場合です。ラッパーは理由を `error.message` に残し、`findings` を `null` にします。CLI の終了コードが 0 でも、モデルが `not_reviewable` なら完了にはしません。終了コードが 0 でない場合は、モデルが完了と書いていても `cli_exit` です。

`error.type` は `review_impossible`、`access_control`、`cli_exit`、`invalid_json`、`source_modified`、`setup` のいずれかです。モデルが `reason` に `null` を返した場合、完了時は空の理由、レビュー不能時は理由不足のメッセージとして扱います。

各指摘は `severity`（`critical`、`major`、`minor`、`info`）、`location`、`description`、`evidence`、`suggestion` を持ちます。

分類だけを確認するには、次を実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review.ps1 -SelfTest
```

## 検証結果

最初の検証は 2026-11-12 に、Codex CLI 0.167.2 と `gpt-6.1-sol` でサンプルの試験項目をレビューしたものです。終了コードは 0、所要時間は約 61 秒です。`review-result.json` はそのときの結果であり、今回のスキーマ変更では上書きしていません。したがって、このファイルには `not_reviewable` は含まれません。

`review-result.json` の要点:

| 項目 | 結果 |
| --- | --- |
| `status` | `completed` |
| `findings` | 12 件 |
| ワークスペース内の読み取り | 許可された |
| ワークスペース外の読み取り | 拒否された。同じファイルは OS 上では読めた |
| ワークスペースへの書き込み | 拒否された |
| 元ファイル | 変更なし（`sources_unchanged: true`） |
| 一時ワークスペース | 削除済み（`workspace_deleted: true`） |

フィクスチャに入れた不備と、結果での扱い:

| 仕込み | 結果での位置 |
| --- | --- |
| T2: `id=0` を成功と期待（R1 は 1 以上） | `critical` |
| T4: 21 文字の `name` を成功と期待（R2 は 20 文字以下） | `critical` |
| T5: `archived` を成功と期待（R3 に無い値） | `critical` |
| T8: 作成後の `id` 変更を成功と期待（R6 は変更不可） | `critical` |
| T2 と T9 が、同じ条件で成功と失敗に分かれている | `major` |
| T3: 期待結果が空 | `major` |
| T6: 存在しない R9 を参照 | `major` |
| R1 の重複、R2 の空白、R3 の許可値、R4 の超過、R5 の確認が無い | `major` |

T1（`id=1` の成功）と T7（`note` 100 文字の成功）は、仕様に合う期待結果としては指摘されていません。T7 は、上限超過と省略の確認が無いことの根拠として参照されています。

### 今回の修正の確認

サンプルの `review-result.json`、`fixtures/spec.md`、`fixtures/test-items.md` は変更していません。確認用の入力は一時ディレクトリの使い捨てのファイルです。`review.ps1 -SelfTest` は成功しています。

| 確認 | 結果 |
| --- | --- |
| 出力先が入力ファイルと同じ（表記を正規化） | 終了コード 2。ファイルの内容とハッシュは元のまま。失敗 JSON は書かれない |
| 出力先が入力ディレクトリの内部 | 終了コード 2。出力ファイルは作成されない |
| 基準ファイルが無く、出力先が存在する対象と同じ | 終了コード 2。対象の内容とハッシュは元のまま。失敗 JSON は書かれない。別パスへの準備失敗 JSON は書かれる |
| レビュー不能（要求も試験項目も無い使い捨ての資料） | 終了コード 1。`status` は `not_reviewable`、`findings` は `null`、理由は要求と試験項目が無いこと |
| 指摘 0 件（要求と期待結果が一致する使い捨ての資料） | 終了コード 0。`status` は `completed`、`findings` は `[]` |
| 指摘あり（`id=0` の成功期待が R1 と矛盾する使い捨ての資料） | 終了コード 0。`completed` で critical 1 件 |
| アクセス検証の失敗でモデルを呼ばないこと | 終了コード 1。`error.type` は `access_control`、`findings` は `null`。`exec` は呼ばれない |
| 揃えた権限プロファイルでの読み取り拒否と書き込み拒否 | 上記のモデル実行で、ワークスペース内は読め、隣のファイルは拒否され、書き込みも拒否された |

アクセス検証の失敗は、読み取りを拒否する代替 `codex` を PATH の先頭に置いて確認しました。MXC 自体を壊した確認ではありません。本番と同じ `-c` プロファイルでの拒否は、モデルを呼んだ実行の `access_control` で確認しています。

## 制限

- 再レビューと、複数プロバイダーへの振り分けは行いません。
- 読み取り拒否は MXC で確認しています。MXC を使えない環境ではレビューを開始しません。
- `:minimal` はコマンド実行に必要な基盤パスを読むため、ディスク上のすべてのパスを拒否するわけではありません。
- 権限プロファイルは Codex の beta 機能です。
- 指摘の内容はモデルの判断です。件数 0 の `completed` は、実行失敗やレビュー不能とは別の結果です。
- `codex sandbox` は `--ignore-user-config` と `--ignore-rules` を受け取れません。検証側は空の `CODEX_HOME` でユーザー設定とユーザールールを外します。この一時ホームが Temp 配下だと、PATH エイリアスを作らないという警告が出ることがあります。ファイルの拒否確認は、その警告が出ても成立しています。
- ファイルを OS 権限で読めなくした場合のレビュー不能は、モデル実行では確認していません。確認したレビュー不能は、要求と試験項目が無い資料です。
- 矛盾が弱い使い捨ての資料では、モデルが指摘 0 件を返すことがありました。矛盾を明示した資料では 1 件の指摘を返しました。
