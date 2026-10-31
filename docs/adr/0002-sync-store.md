# ADR 0002：同期の保存形式とデータ保護ゲート

- 状態：採用（Phase 2）
- 日付：2026-10-31

## 背景
端末（Dexie / IndexedDB）を正とするオフライン優先のアプリで、複数端末の同期、毎日22時の Drive バックアップ、
30日後の期限削除、期間指定復元を、データを失わずに実現する必要がある。

## 決定
1. **サーバーは汎用の `records` 表**（user_id, entity, id, version, data, deleted, delete_reason, server_seq, restored_session_id）。
   エンティティごとの表を作らず、検証は共有の Zod スキーマ（`packages/contracts`）で行う。項目追加でマイグレーション不要。
2. **送信は opId による冪等**。`sync_receipts` に結果を保存し、再送には同じ結果を返す。
3. **競合は version（楽観ロック）**。baseVersion が古い場合は `updatedAt` が新しい方を採用し、古い側には `conflict` と最新の記録を返す。
4. **受信（pull）は server_seq のカーソル**。未送信の変更がある記録は受信で上書きしない。
5. **期限削除はゲート付き**：その日の日次バックアップが「Drive へ保存 → ダウンロード → ハッシュ・件数一致」で検証済みのときだけ、
   対象をアーカイブとして別保存・検証してから、`version = ?` 条件付きで論理削除（reason=purge）する。`purge_ledger` に記録。
   繰り返し予定は親を消さず、該当回に `archived` 例外を付ける。
6. **復元は restoration_session 単位**。閲覧中の記録には `restored_session_id` を付けて期限処理の対象外にし、
   「閲覧を終了」で reason=restore-end として外す。Drive のファイルは消さない。
7. Workers は UTC で動くため、すべての入口で `applyUserZone`（Asia/Tokyo）を呼び、日付判定をユーザーの時間帯で行う。

## 結果
- API テスト（workerd + 実 D1）とサーバー連携 E2E（ローカル Worker + 模擬 Google、Chromium/WebKit）で、
  「バックアップ失敗日は削除しない」「読み戻し不一致は成功扱いしない」「同日再実行は冪等」「復元中は再削除しない」「閲覧終了後も Drive に残る」を確認済み。
- 汎用表のため SQL での集計は不便（分析は端末側で計算するので問題なし）。
