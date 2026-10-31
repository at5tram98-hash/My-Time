# My Time 実装計画（3フェーズ）

正本：`docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md`。フェーズは Phase 1 / 2 / 3 のみ。

## 調査結果（着手時）
- 既存の My Time リポジトリはなし → 新規 `my-time` をローカルに作成（GitHub リモートの作成・公開はユーザーが実施）。
- 既存の別アプリ TodayTime（公開中）は変更しない。

## Phase 1｜アプリ本体を動かす（今回）
| 項目 | 実装場所 | 受け入れ条件（自動テスト） |
|---|---|---|
| 土台 | pnpm workspace, `apps/web`(React+TS strict+Vite+PWA), `packages/domain`, `packages/contracts`(Zod), CI | typecheck / lint / test / build / E2E が成功 |
| 5タブ AppShell | `apps/web/src/app` | 5タブ切替、日付はホーム上部の1箇所 |
| ホーム上下分割 | `features/home` | ハンドルはドラッグのみで拡張、タップでは拡張しない、浮遊カードが残る、スクロールでハンドルが動かない |
| カレンダー基礎 | `features/timeline`, `features/calendar` | 1/2日・拡張時1〜7日・日/2日/週/月、赤線は今日の列のみ、15分スナップ移動 |
| タスク・予定 CRUD | `features/tasks`, `features/calendar`, `data/repo.ts` | 作成→編集→再起動で残る、左端日付のタスクだけ表示 |
| 進捗ジェスチャー | `features/tasks/TaskRow.tsx` | 長押し＋横スライドで実績、ドラッグなし長押しは記録しない、100%は確認、サブタスク親は無効 |
| 実行計算 | `packages/domain` | 理想進捗、実績からのみETA、遅延は描画延長のみで予定を動かさない |
| 永続化 | Dexie (`data/db.ts`) + 操作ログ + 未同期キュー | リロード・オフライン起動で復元、自動削除は無効 |

## Phase 2｜残りの全機能を接続する（レビュー後）
カレンダー/タスク高度機能、授業・アルバイト、分析、設定・初回セットアップ、Google 認証、Workers+D1 同期（`outbox` を送信）、Drive 日次バックアップ・復元・期限削除（データ保護ゲート合格後のみ有効化）、通知、TimeTree/テキスト取込。

## Phase 3｜iOS品質に仕上げる
実機 iPhone 15 Pro での操作感調整、性能（可視範囲描画）、アクセシビリティ、例外・復旧・E2E の網羅、文言統一。
