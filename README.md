# My Time

iPhone 15 Pro を主な対象にした、ホーム画面に追加して使う予定・タスク管理 PWA。
正本仕様：[`docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md`](docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md)
現在の段階：**Phase 2（同期・バックアップ・高度な予定/タスク）レビュー待ち** — [`docs/phase2-report.md`](docs/phase2-report.md)
Phase 1：[`docs/phase1-report.md`](docs/phase1-report.md)（合格済み）

Google ログイン・同期・Drive バックアップを本番で使う設定：[`docs/setup-cloudflare-google.md`](docs/setup-cloudflare-google.md)

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
pnpm e2e:stack   # サーバー連携：ローカル Worker + 模擬 Google で 同期・バックアップ・期限削除・復元
pnpm test:api    # API（workerd + D1）
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
apps/api/      Cloudflare Workers（Hono + D1）：OAuth・同期・22時バックアップ・期限処理・復元・通知
tests/e2e/     Playwright（端末内）
tests/stack/   Playwright（ローカル Worker + 模擬 Google）
tests/fake-google/  E2E 用の模擬 Google（OAuth・JWKS・Drive）
```

データはまず端末の IndexedDB に保存され、ログイン中はキューを Cloudflare Workers に送って端末間で同期します。期限削除は「その日のバックアップを Drive に保存して読み戻し確認できた日」だけ行います（[`docs/adr/0002-sync-store.md`](docs/adr/0002-sync-store.md)）。GitHub Pages 版はサーバーがないため端末内のみで動きます。
