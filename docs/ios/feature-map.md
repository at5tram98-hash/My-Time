# Web 版 ↔ iOS 版 機能対応表

状態：✅ 実装済み（コード作成。Xcode でのビルド・動作は未検証） / 🧪 実装済み＋自動テストで確認 / ⏳ 未実装 / ➖ 対象外

## 画面・操作

| Web 版の機能 | Web の場所 | iOS 版 | 状態 |
|---|---|---|---|
| 4つのタブ（今日・カレンダー・タスク・振り返り） | App.tsx | `RootView`（TabView） | ✅ |
| 今日：今やること1枚（実行中／次／出発／予定中／空き） | features/home | `NowCard`（`nextAction`） | ✅（計算は 🧪） |
| 今日：状況チップ（未割当・今日のタスク・余白） | features/home | `StatusChip` | ✅ |
| 今日：左右レーン（予定／タスク）と幅の切り替え | features/home | `DayTimeline(mainFraction:)` | ✅ |
| 赤い現在線・現在時刻へスクロール | timeline | `DayTimeline` | ✅ |
| 長押し→上下で15分刻みの移動・取り消し | timeline | `TimelineBlock` | ✅（繰り返しの1回だけの移動は ⏳） |
| 横スワイプで日付変更・日付選択 | home | `TodayView` | ✅ |
| ピンチで時間の間隔を拡大縮小 | timeline | `MagnifyGesture` | ✅ |
| タスク詳細：開始・停止・再開・完了・取り消し | tasks | `TaskDetailView` | ✅（状態遷移は 🧪） |
| 実績の手入力（サブタスクなし） | tasks | Slider | ✅（🧪） |
| サブタスクの追加・完了・削除 | tasks | `TaskDetailView` | ✅（🧪） |
| 確認タスク（チェック） | tasks | `TaskRow` | ✅（🧪） |
| 予定詳細・繰り返しの「この回のみ／すべて」削除 | calendar | `EventDetailView` | ✅（🧪） |
| 追加・編集（予定／タスク、種類 S01〜S25、締切、見積、繰り返し、場所、アイコン） | editor | `EditorView` | ✅（種類別の専用項目は ⏳） |
| タスク一覧・スマートリスト・検索・スワイプ操作 | tasks / search | `TasksScreen` | ✅ |
| 未割当・空き時間へ入れる | plan | `InboxView` | ✅（簡易版。Web の計画の支援全体は ⏳） |
| カレンダー：月＋日の時刻軸・終日予定 | calendar | `CalendarScreen` | ✅（2日・週・月の一覧表示は ⏳） |
| 振り返り：作業時間・完了数・余白のグラフ | analysis | `ReviewScreen`（Swift Charts） | ✅ |
| 設定：外観（システム／ライト／ダーク） | other | `SettingsView` | ✅ |
| 端末間の移行（書き出し・読み込み・確認） | settings | `SettingsView` / `ImportConfirmView` | ✅（形式は 🧪） |
| 取り消し付きの知らせ | toast | `ToastView` | ✅ |
| 文章で追加（自然文の解析） | quickadd | — | ⏳ |
| 計画の支援（提案・自動配置・依存関係） | plan | — | ⏳ |
| 課題・テスト対策・Studio（科目・授業） | studio / spec | 表示のみ（種類・締切） | ⏳ |
| 勤務先・給与の見込み | spec | 予定詳細で給与見込みを表示 | ✅（勤務先の編集は ⏳） |
| 予定の通知・出発リマインダー | sw / notifications | — | ⏳（UserNotifications で実装予定） |
| ICS 書き出し | repo | — | ⏳ |
| 操作履歴の画面・まとめて取り消し | history | — | ⏳（履歴自体は Web と同じ形で記録 🧪） |
| オンボーディング | onboarding | — | ⏳（既定カレンダーは自動作成 🧪） |
| クラウド同期・Google ログイン・Drive バックアップ | api / accounts | outbox に記録のみ | ⏳ |
| ChatGPT 連携 | — | — | ➖（今回の対象外） |

## データ・ロジック（MyTimeCore）

| Web（packages/domain ほか） | iOS（MyTimeCore） | 状態 |
|---|---|---|
| canonicalJson / SHA-256 | `JSONValue.canonical` / `SHA256` | 🧪（Web のファイルと1バイトも違わない） |
| 予定・タスク・サブタスク・カレンダー・勤務先・科目ほかの型 | `Models.swift`（未知の項目も保持） | 🧪 |
| 進捗（理想・実績）・遅れ・終了見込み・作業時間 | `Domain.swift` | 🧪 |
| タスクの状態機械 | `applyTaskAction` | 🧪 |
| 繰り返しの展開・例外 | `expandEvent` / `expandAll` | 🧪 |
| 1日の配置（重なりの列分け） | `layoutDay` | 🧪 |
| 今やること・余白の割合 | `Planner.swift` | 🧪 |
| 専門の種類 25（名前・グループ・色） | `Spec.swift`（アイコンは SF Symbols） | 🧪 |
| 端末間の移行（書き出し・検証・追加のみの取り込み） | `Transfer.swift` | 🧪（双方向） |
| operationLog / outbox | `Repository` | 🧪 |
