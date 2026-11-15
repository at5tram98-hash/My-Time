# iOS ネイティブ版 移行計画

## 1. 方針

- **WebView・Capacitor は使わない。** 画面はすべて SwiftUI。保存は SwiftData。
- **Web 版を失わない。** Web 版のコード・本番デプロイ（`main` → GitHub Pages）には手を入れない。iOS 版は開発ブランチで進め、`main` への統合はユーザーの許可を得てから。
- **データの正本は「Web 版と同じ JSON」。** iOS 版は記録を Web 版と同じ形の JSON のまま保存し、iOS が知らない項目（将来の追加項目など）も消さずに持ち続ける。これで Web ↔ iOS の往復でデータが欠けない。
- **ロジックは UI から分ける。** 計算（進捗・遅れ・繰り返し展開・配置・状態遷移・移行ファイル）は `MyTimeCore`（Swift Package）にまとめ、Web 版の TypeScript と同じ結果になることをテストで確かめる。

## 2. 構成

| 層 | Web 版 | iOS 版 |
|---|---|---|
| 画面 | React（apps/web/src/features） | SwiftUI（ios/MyTime/Features） |
| 状態 | React hooks + Dexie liveQuery | `AppModel`（@Observable）。書き込み後に読み直す |
| 保存 | IndexedDB（Dexie） | SwiftData：`StoredRecord`（種類＋ID → JSON）、操作履歴、送信待ち、設定 |
| 計算 | packages/domain | MyTimeCore（Domain / Planner / Spec） |
| 検証 | packages/contracts（Zod） | Repository の保存前チェック（タイトル必須・終了＞開始など）＋移行ファイルの検証 |
| 同期 | outbox → Cloudflare Workers | outbox を Web 版と同じ形でためる（送信は未実装） |

### データ互換の要点

- 記録は `raw`（読み込んだ JSON そのもの）に、iOS が理解する項目だけを上書きして保存する（`raw.merging(knownJSON)`）。
- `null` と「項目なし」を区別して保つ。時刻は epoch ミリ秒の数値。
- 移行ファイルのチェックサムは Web 版 `canonicalJson()` と同じ規則（キーを UTF-16 順、JS の数値表記）で計算する。
- 変更のたびに Web 版と同じ形の `operationLog` と `outbox` を書く → 将来の同期でそのまま送れる。
- 取り込みは追加のみ・同じ ID で内容が違えば中止・受領記録で2回目は何もしない（Web 版と同じ）。

## 3. 段階

| 段階 | 内容 | 状態 |
|---|---|---|
| 0 | 既存コードの調査・機能の対応表 | 完了（[feature-map.md](feature-map.md)） |
| 1 | 共通ロジック MyTimeCore と Web との相互テスト | 完了（Swift 19 件・Web 側 2 件） |
| 2 | Xcode プロジェクト、SwiftData 保存、今日の画面（左右レーン・今やること・ドラッグ移動） | ビルド・シミュレーターで確認済み（ドラッグ移動は未操作） |
| 3 | 詳細・編集・タスク一覧・カレンダー・振り返り・設定（移行ファイル） | 画面の表示を確認済み（移行ファイルの読み書きは未操作） |
| 4 | Mac で実ビルド・シミュレーター確認・UI テスト・スクリーンショット | ビルド・主な画面の確認・スクリーンショットは完了。UI テスト・実機は未着手 |
| 5 | 残りの機能の移植（文章で追加、計画の支援、課題、Studio、通知、検索、複数日表示 など） | 未着手 |
| 6 | 同期（Cloudflare Workers と同じ API）・Google ログイン・バックアップ | 未着手（秘密情報・本番に関わるため、着手前に確認） |
| 7 | `main` への統合・配布方法の決定 | ユーザーの許可待ち |

## 4. UI の考え方（Apple 純正アプリらしさ）

- 標準の `TabView`・`NavigationStack`・シート・`List`・`Form`・`Menu`・`confirmationDialog`・`searchable`・`swipeActions` を使い、独自の部品は最小にする。
- iOS 26 SDK でビルドするとタブバー・ツールバー・シートは自動で Liquid Glass。独自のカード（今やること・知らせ）は `glassEffect`、iOS 17〜25 では `regularMaterial`。
- アイコンは SF Symbols。Web 版のアイコン ID・旧版の絵文字は表示時だけ読み替え、保存値は変えない。
- 触覚：開始・完了（成功）、長押しで持ち上げ（中）、15分ごとの移動（選択）。
- ダークモード・Dynamic Type・VoiceOver（ラベル・カスタム操作「15分早める／遅らせる」）・視差効果を減らす設定に対応。
