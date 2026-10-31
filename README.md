# My Time

iPhone 15 Pro を主な対象にした、ホーム画面に追加して使う予定・タスク管理 PWA。
正本仕様：[`docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md`](docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md)
現在の段階：**Phase 1（アプリ本体・端末内保存）再レビュー待ち** — [`docs/phase1-report.md`](docs/phase1-report.md)・差し戻し対応 [`docs/phase1-review-fixes.md`](docs/phase1-review-fixes.md)

## 起動

```bash
pnpm install
pnpm dev            # http://localhost:5173（同じWi-FiのiPhoneからは表示されるIPで開く）
pnpm build && pnpm preview   # 本番ビルドの確認（http://localhost:4173）
```

公開URL：https://at5tram98-hash.github.io/My-Time/ （main への push で自動デプロイ。各フェーズ完了時に更新）
iPhone では Safari で開き、共有メニュー →「ホーム画面に追加」。

## 検証コマンド

```bash
pnpm typecheck   # TypeScript strict
pnpm lint        # ESLint
pnpm test        # Vitest（ドメイン計算・永続化・コンポーネント）
pnpm build
pnpm exec playwright install chromium webkit   # 初回のみ
pnpm e2e         # Playwright：iPhone 15 Pro サイズ（Chromium モバイル + WebKit）
```

`tests/e2e/screens.spec.ts` は `docs/screenshots/` にレビュー用の画面を保存します。

## 構成

```
apps/web/src/
  app/         タブ・状態プロバイダ・シート管理
  features/    home / calendar / tasks / timeline / analysis / other / search
  components/  シート・アラート・メニュー・トグル・アイコン
  gestures/    横スワイプ（日付）・ジェスチャーの排他制御
  data/        Dexie（IndexedDB）と唯一の書き込み口 repo.ts
  styles/      デザイントークン（ライト/ダーク）と画面別CSS
packages/
  domain/      純粋関数：状態機械・理想/実績進捗・ETA・遅延・配置・重複
  contracts/   Zod スキーマ（保存・将来の同期で入力検証）
tests/e2e/     Playwright
```

データはこの端末の IndexedDB だけに保存されます。操作ごとに「本体・操作ログ・未同期キュー」を1トランザクションで書き、Phase 2 でキューを Cloudflare Workers に送ります。自動削除は無効です。
