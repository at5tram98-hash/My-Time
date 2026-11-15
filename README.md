# My Time

iPhone 15 Pro を主な対象にした、ホーム画面に追加して使う予定・タスク管理 PWA。
正本仕様：[`docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md`](docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md)
現在の段階：**大幅改善（2026-11 再設計）レビュー待ち** — [`docs/redesign-2026-11-report.md`](docs/redesign-2026-11-report.md)、設計と50案：[`docs/My_Time_iOS_UI_Claude_45plus_Proposal.md`](docs/My_Time_iOS_UI_Claude_45plus_Proposal.md)
これまで：Phase 1 [`docs/phase1-report.md`](docs/phase1-report.md)・Phase 2 [`docs/phase2-report.md`](docs/phase2-report.md)・Phase 3 [`docs/phase3-report.md`](docs/phase3-report.md)

画面：下部タブは **今日・カレンダー・タスク・振り返り** の4つ＋右の丸い「追加」。設定は各画面右上の歯車。
今日は1日だけで、左＝時間の決まった予定、右＝細かなタスクのレーン。追加は文章で書くと候補に分かれる（端末内で読み取り、外部には送らない）。

Google ログイン・同期・Drive バックアップを本番で使う設定：[`docs/setup-cloudflare-google.md`](docs/setup-cloudflare-google.md)

## iOS 版（SwiftUI ネイティブ・開発中）

`ios/` に Xcode プロジェクトがあります（WebView ではなく SwiftUI＋SwiftData）。Web 版とは「端末間の移行ファイル」でデータをやり取りできます。
iPhone への入れ方・移行計画・機能対応表・未対応の一覧は [docs/ios/README.md](docs/ios/README.md) を見てください。

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
  features/    home（今日）/ calendar / tasks / timeline / analysis（振り返り）/ other（設定）/ search
               quickadd（文章で追加）/ plan（気づいたこと・未割当・延期・振り返り）/ spec（専門の種類）
  components/  シート・アラート・メニュー・トグル・アイコン
  gestures/    横スワイプ（日付）・ジェスチャーの排他制御
  data/        Dexie（IndexedDB）と唯一の書き込み口 repo.ts
  styles/      デザイントークン（ライト/ダーク）と画面別CSS
packages/
  domain/      純粋関数：状態機械・理想/実績進捗・ETA・遅延・配置・重複
               spec（専門の種類 S01〜S25）・planner（空き時間・検知・案・振り返り）・nlparse（文章の読み取り）
  contracts/   Zod スキーマ（保存・将来の同期で入力検証）
apps/api/      Cloudflare Workers（Hono + D1）：OAuth・同期・22時バックアップ・期限処理・復元・通知
tests/e2e/     Playwright（端末内）
tests/stack/   Playwright（ローカル Worker + 模擬 Google）
tests/fake-google/  E2E 用の模擬 Google（OAuth・JWKS・Drive）
```

データはまず端末の IndexedDB に保存され、ログイン中はキューを Cloudflare Workers に送って端末間で同期します。期限削除は「その日のバックアップを Drive に保存して読み戻し確認できた日」だけ行います（[`docs/adr/0002-sync-store.md`](docs/adr/0002-sync-store.md)）。GitHub Pages 版はサーバーがないため端末内のみで動きます。
