# Google ログイン・同期・Drive バックアップを本番で使うための設定手順

Phase 2 のサーバー機能（Google ログイン、端末間同期、毎日22時の Drive バックアップ、30日後の期限処理、期間指定復元、通知）は、
**Cloudflare（アプリと API を同じ URL で配信）** と **Google Cloud（ログインと Drive の権限）** の設定をしてはじめて動きます。
設定するまでは、アプリは今までどおり端末内だけで動きます（「その他」に「サーバー未設定」と表示）。

> 費用：ここで使うものはすべて無料枠の範囲です（Cloudflare Workers Free / D1 Free、Google Cloud は課金設定不要）。
> 有料プランへの切り替えは行いません。
> 秘密値（パスワードのようなもの）は **GitHub のファイルには絶対に書かず**、下の手順どおり Cloudflare / GitHub の「Secrets」に登録します。

所要時間の目安：30〜40分。順番どおりに進めてください。

---

## 1. Cloudflare：アカウントと公開先 URL を決める

1. https://dash.cloudflare.com/sign-up で無料アカウントを作成（作成済みなら不要）。
2. 左メニュー **Workers & Pages** を開き、初回なら `workers.dev` のサブドメイン名を決める（例：`yuki`）。
3. 公開先 URL は次の形になります。メモしておきます（以下 **APP_ORIGIN**）。
   ```
   https://my-time.<サブドメイン>.workers.dev
   ```
4. 右上のアカウント名 → **アカウントのホーム** の URL に出る英数字32文字が **アカウント ID**。メモします。

## 2. Cloudflare：データベース（D1）を作る

1. **Workers & Pages → D1 SQL Database → Create**。
2. 名前は `my-time`、場所は自動のまま作成。
3. 作成後の画面に出る **Database ID**（`xxxxxxxx-xxxx-...`）をメモ（以下 **D1_DATABASE_ID**）。

## 3. Cloudflare：GitHub から公開するための API トークン

1. 右上アイコン → **My Profile → API Tokens → Create Token**。
2. テンプレート **「Edit Cloudflare Workers」** を選び、さらに権限を1行追加：**Account → D1 → Edit**。
3. Account Resources は自分のアカウントだけ、Zone Resources は「All zones」のままで作成。
4. 表示されたトークンを **この画面で一度だけ** コピー（以下 **CLOUDFLARE_API_TOKEN**）。

## 4. Google Cloud：ログインと Drive の権限

1. https://console.cloud.google.com/ で新しいプロジェクトを作成（名前：`My Time`）。
2. **API とサービス → ライブラリ** で **Google Drive API** を検索して「有効にする」。
3. **API とサービス → OAuth 同意画面**（Google Auth Platform）
   - ユーザーの種類：**外部**、アプリ名：`My Time`、サポートメール：自分の Gmail。
   - **データアクセス（スコープ）** に次の4つを追加：
     `openid` / `.../auth/userinfo.email` / `.../auth/userinfo.profile` / `.../auth/drive.file`
     （`drive.file` は「My Time が作ったファイルだけ」を扱う権限で、ドライブ全体は見えません）
   - **対象（テストユーザー）** に自分の Gmail を追加。公開ステータスは **テスト中のまま** で使えます。
     ※テスト中のアプリは Google の仕様で、約7日ごとに再ログインが必要になる場合があります。その場合アプリが「!」で知らせます。
4. **API とサービス → 認証情報 → 認証情報を作成 → OAuth クライアント ID**
   - 種類：**ウェブ アプリケーション**
   - 承認済みのリダイレクト URI：
     ```
     <APP_ORIGIN>/api/auth/callback
     ```
     例：`https://my-time.yuki.workers.dev/api/auth/callback`
   - 作成後の **クライアント ID** と **クライアント シークレット** をメモ。

## 5. 秘密値を作って Cloudflare に登録

パソコンのターミナルで、リポジトリのフォルダーから実行します（Node.js 22 と pnpm が必要）。

```bash
pnpm install
node apps/api/scripts/gen-secrets.mjs      # SESSION_SECRET / TOKEN_ENC_KEY / VAPID 鍵を表示（保存はされません）
cd apps/api
npx wrangler login                          # ブラウザで Cloudflare にログイン
npx wrangler secret put GOOGLE_CLIENT_ID     # 手順4のクライアント ID を貼り付け
npx wrangler secret put GOOGLE_CLIENT_SECRET # 手順4のクライアント シークレット
npx wrangler secret put SESSION_SECRET       # gen-secrets の表示値
npx wrangler secret put TOKEN_ENC_KEY
npx wrangler secret put VAPID_PUBLIC_KEY
npx wrangler secret put VAPID_PRIVATE_JWK
npx wrangler secret put VAPID_SUBJECT        # mailto:自分のメールアドレス
```

> 初回の `secret put` で「Worker がまだない」と聞かれたら **Yes**（空の Worker が作られるだけで、まだ公開はされません）。

## 6. GitHub に公開用の値を登録

リポジトリ **at5tram98-hash/My-Time → Settings → Secrets and variables → Actions**

| 種類 | 名前 | 値 |
|---|---|---|
| Secret | `CLOUDFLARE_API_TOKEN` | 手順3 |
| Secret | `CLOUDFLARE_ACCOUNT_ID` | 手順1 |
| Secret | `D1_DATABASE_ID` | 手順2 |
| Variable | `APP_ORIGIN` | 手順1（末尾の `/` なし） |

## 7. 公開（手動・本人の操作でのみ実行）

1. GitHub の **Actions → Deploy to Cloudflare (manual) → Run workflow**。
2. 入力欄に `公開する` と入力して実行。
3. 型チェック・Lint・単体テスト・E2E（Chromium/WebKit）・サーバー連携 E2E にすべて合格した場合だけ、
   D1 にテーブルを作成（追加のみ）→ Workers に公開されます。

## 8. iPhone での確認

1. Safari で APP_ORIGIN を開き、共有 → **ホーム画面に追加**。
2. ホーム画面のアイコンから開き、**その他 → Googleでログイン**。
3. 「その他」の同期が「同期済み」になること、もう1台（PC のブラウザ等）でログインすると同じデータが出ることを確認。
4. **その他 → 通知 → 通知を許可する**（iPhone ではホーム画面に追加したアプリでのみ通知できます）。
5. **その他 → Driveバックアップ → 今すぐバックアップ** を押し、Google ドライブに「My Time Backup」フォルダーとファイルができることを確認。
   以後は毎日 22:00（日本時間）に自動で保存・読み戻し確認されます。

## うまくいかないとき

| 症状 | 確認すること |
|---|---|
| ログインで `redirect_uri_mismatch` | 手順4のリダイレクト URI が APP_ORIGIN と完全一致しているか（https、末尾の `/api/auth/callback`） |
| `access_denied` / 「このアプリはテスト中」 | 手順4-3 のテストユーザーに自分の Gmail を入れたか |
| 「その他」が「サーバー未設定」のまま | 手順5の secret が4つ（GOOGLE_CLIENT_ID / SECRET, SESSION_SECRET, TOKEN_ENC_KEY）入っているか：`npx wrangler secret list` |
| バックアップが「!」で失敗 | ドライブの容量、ログインし直し（権限の取り消し）を確認。失敗した日はデータを一切削除しません |

## 安全のための仕組み（設定不要）

- 期限（30日）が来たデータでも、**その日のバックアップを Drive に保存して読み戻し確認できた日だけ** 削除します。削除前に別ファイル（アーカイブ）にも保存し、読み戻し確認します。
- 期限削除したデータは「その他 → 期間指定の復元」で戻せます。「閲覧を終了」しても Drive のアーカイブは残ります。
- アーカイブと最新の検証済みバックアップは、アプリから削除できません。
- ログイン情報（Google のリフレッシュトークン）はサーバー側で暗号化して保存し、ブラウザには HttpOnly の Cookie だけを渡します。
