# ChatGPT・TimeTree連携

My Time の **その他 → ChatGPT・TimeTree連携** を開きます。ChatGPT に見せる予定・タスク・チェックポイントを選び、期間を指定して JSON を書き出します。時刻未定のタスクも対象です。ChatGPT に添付すると、内容を確認したり、編集・削除したい項目を ID で指定したりできます。新規追加や TimeTree からのコピーだけなら、My Time 側の書き出しは不要です。

ChatGPT が作った JSON を同じ画面で選ぶか貼り付け、プレビューで日時・編集内容・削除対象を確認してから「変更を反映」を押します。クラウド同期は使いません。既存の「データの移行」は独立した機能です。

## ChatGPT で My Time を編集する

添付ファイル `my-time-snapshot.json` にあるデータのうち、依頼された項目だけを対象にします。次の形式で JSON ファイルを返します。

```json
{
  "format": "my-time-changes-v1",
  "changes": [
    {
      "action": "edit",
      "kind": "task",
      "id": "書き出しにあるID",
      "revision": "書き出しにあるrevision",
      "fields": { "title": "授業の資料を確認", "notes": "第5回まで" }
    },
    {
      "action": "add",
      "kind": "event",
      "id": "86f44a1a-59fe-4dd7-820a-2ff2be1d652b",
      "fields": {
        "title": "図書館で勉強",
        "start": 1795158000000,
        "end": 1795161600000,
        "timeZone": "Asia/Tokyo"
      }
    }
  ]
}
```

- `action` は `add`、`edit`、`delete`。追加は項目ごとに新しい UUID を生成します。編集と削除は書き出しの `id` と `revision` をそのまま指定します。削除には `fields` を付けません。
- 開始・終了・確認時刻は UNIX ミリ秒です。終日予定は現地時刻の午前0時で、終了は最終日の翌日の午前0時です。予定を追加するときはタイトル・開始・終了、チェックポイントを追加するときはタイトル・時刻が必要です。
- 予定またはチェックポイントの繰り返し全体を編集・削除すると明示された場合は、変更項目と同じ階層に `"wholeSeries": true` を付けます。指定回だけの変更は My Time の詳細画面で行います。
- 1ファイルにつき500件・2MBまでです。書き出したあとに対象が端末側で変わった場合は、書き出し直します。

| `kind` | 追加・編集できる `fields` |
|---|---|
| `event` | `title`、`notes`、`calendarId`、`start`、`end`、`timeZone`、`allDay`、`place`、`color` |
| `task` | `title`、`notes`、`calendarId`、`plannedStart`、`plannedEnd`、`timeZone`、`location`、`estimateMinutes`、`checkAt`。追加時のみ `kind` に `do`（実行）または `check`（確認） |
| `checkpoint` | `title`、`notes`、`at`、`alarm`、`notifyBefore`、`repeat`（`daily`、`weekdays`、`weekly`、`null`） |

`calendarId` を指定する場合は、書き出しの `calendars` にある ID を使います。既定のカレンダー ID は `cal-general`（自分）と `cal-mio`（みお）です。

## TimeTree から予定をコピーする

ChatGPT で「TimeTree Companion から［期間・カレンダー］の予定を取得して、My Time のコピー用 JSON ファイルを作成して」と頼みます。返却された予定のオブジェクトをそのまま `events` に入れます。

```json
{
  "format": "my-time-timetree-v1",
  "events": [
    {
      "id": "example-event",
      "calendarId": "example-calendar",
      "calendarName": "共有",
      "title": "図書館へ行く",
      "start": "2026-11-21T13:00:00+09:00",
      "end": "2026-11-21T14:00:00+09:00",
      "timezone": "Asia/Tokyo",
      "allDay": false,
      "participants": ["自分", "同伴者"],
      "owners": ["self", "mio"]
    }
  ]
}
```

ChatGPT は取得できた日時・参加者・メモ・場所・ラベルを維持し、情報が欠けている場合はその旨を伝えます。繰り返し予定は、取得できた各回が個別の My Time 予定になります。My Time は元のカレンダー ID と予定 ID で重複を判定します。みおだけの予定は「みお」に、共同予定は「自分」に入ります。コピー先を明示された場合は各予定に `myTimeCalendarId` を追加します。

## ChatGPT Workとの自動連携

My Timeの「その他 → ChatGPT・TimeTree連携」で、一度だけ使うセットアップコードを入力します。接続先は My Time 専用の同期サーバーです。ファイルの書き出しは不要です。

ChatGPTのWeb版で「プラグイン → ＋ → カスタムMCPサーバーを追加」を開き、名前を「My Time」、URLを `https://mytime-chatgpt.at5tram98.workers.dev/mcp`、認証をOAuthにします。クライアント登録方式を選べる場合はクライアントIDメタデータ文書（CIMD）を選びます。作成した個人用プラグインをインストール後、Workで `@My Time` を指定してください。認証画面では、iPhoneの「ChatGPT接続コードを発行」で作った10分間有効なコードを貼り付けます。

- 予定・タスク・チェックポイントは、My Timeを開いている間に自動送信します。予定の範囲は過去30日から先90日です。端末を開いていない間は最後に送信した時点の情報が表示されます。ChatGPTには最終同期時刻と対象期間も返します。
- 変更依頼は「ChatGPTの編集依頼」に届きます。内容を確認して反映または却下すると、ChatGPTから処理結果を確認できます。
- 「連携を解除」で、専用サーバー上のコピー、依頼および接続情報を消去できます。再接続には、新しいセットアップコードが必要です。

### サーバーの運用

自動連携APIは、既存のMy Time Web APIから独立したCloudflare Workerです。設定は `apps/api/chatgpt/wrangler.toml`、データベースのDDLは同じフォルダの `schema.sql` にあります。

初回または連携解除後の端末登録には、32バイトのランダム値をパディングなしのBase64URLにしたセットアップコードを発行します。専用D1の `enrollment` にコードのSHA-256をBase64URLにした値と、有効期限（UNIXミリ秒）を格納します。生のコードはリポジトリやログに保存せず、利用者本人にだけ渡します。登録に成功した時点でコードは消費されます。
