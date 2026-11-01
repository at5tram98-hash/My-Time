# Phase 3 計画と合格条件（2026-11-01）

正本：`docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md` §9 Phase 3 と「Phase 3 実行指示書」。
Phase 2 の扱い：**Phase 2の実装・本番接続は完了。残存する受け入れ検証は継続中**（下記 D）。

## 棚卸し（開始時点 main f70461b）

| 区分 | 場所 | 現状 |
|---|---|---|
| 保存値の絵文字 | `Task.icon` / `Calendar.icon`（`string`、1〜16文字） | 既定値・ピッカーとも絵文字。旧レコード・旧バックアップ・旧移行ファイルにも絵文字が入っている |
| 絵文字の直接表示 | TaskIcon / TaskRow（確認タスク）/ Timeline / FloatingCards / SearchSheet / CalendarScreen（月表示）/ ManagePages / Onboarding / EventEditor・ImportSheet の select | `{task.icon}` 等をそのまま表示 |
| 絵文字・記号の固定表示 | Onboarding ⏱️・✓、ImportSheet 👤👥、TaskDetail ⚑、SearchSheet 📅、TaskIcon「!」、タブの「!」 | 文字をアイコン代わりに使用 |
| 既定値 | `packages/domain` factories（📘、📅🎓💼）、special（📝🎯） | 新規作成時に絵文字を保存 |
| CSS 疑似要素 | `content:` による記号 | なし（確認済み） |
| PWA アイコン | `public/icon.svg` と PNG 4種 | 独自 SVG（絵文字なし）。意匠は維持し、新アイコンと線の考え方を揃える |
| タブバー | `App.tsx` の `nav.tabbar`（文書の流れに置いた不透明に近い帯） | 浮遊形状・選択カプセル・押下反応なし |

## 方針

A. **アイコン体系**：`Icon.tsx` を唯一の SVG 置き場にする（24 グリッド、線 1.8〜1.9、丸端、丸角）。
   ユーザーが選ぶアイコンは `packages/domain/src/icons.ts` の安定 ID（`book`、`calendar` など）と日本語名で定義する。
   - 旧絵文字 → ID の対応表と `resolveItemIcon()` を domain に置く（純粋関数・単体テスト）。
   - 未知値は既定 SVG（`circle`／「その他」）で表示し、**保存値はそのまま残す**（表示時に解決するだけ）。
   - 一括書換え・migration は行わない（schema 変更なし）。ユーザーが再選択した記録だけ新 ID になる。
   - 新規作成の既定値は新 ID。タイトル・メモの絵文字は一切触らない。
B. **Liquid Glass タブバー**：画面下に浮く丸い帯。半透明＋`backdrop-filter`（blur・saturate、`-webkit-` 併記）、細い縁の光、内側ハイライト、影。
   選択中はカプセル（transform で移動）＋太い線＋ラベルの太さ＋`aria-current`。押下は scale のみ。
   非対応時・透明度を下げる設定（`prefers-reduced-transparency`）・コントラストを上げる設定では不透明寄りへ。Reduce Motion では移動なし。
   表示領域はトークン `--tabbar-space` 1 か所で確保し、スクロール領域だけが帯の下へ回り込む。
C. 既存 Phase 3 仕様：ホームの重複・密度、長押し・ジェスチャー・pointercancel、範囲クエリ・可視範囲描画・端の自動スクロール、境界日付、a11y、文言。
D. Phase 2 継続検証：実 Drive の日次ファイル → 隔離した空 DB への実復旧と照合、実アーカイブの保存→復元表示→閲覧終了（隔離環境・本番は off のまま）、2アカウント、本番移行の二重取込防止、Cron/Push 実測。

## 合格条件（要約）

- アプリが表示するアイコンに絵文字・記号グリフが残らない（旧データを表示した画面・ピッカー・空状態・ダークモードを実際に撮影して確認）。
- 旧絵文字値・未知値・旧移行ファイル・旧バックアップを読み込んで SVG 表示でき、保存値が変わらない。再選択で新 ID が保存される。
- タブバー：明暗で素材と選択が分かる、44px 以上、safe area・小型画面・横向き・文字拡大で欠けない、シート・キーボード・トーストと重ならない、Reduce Motion とフォールバックあり。
- `pnpm typecheck / lint / test / build / e2e / e2e:stack` が実測で合格（件数を報告）。
- 本番は `RETENTION_MODE=off` のまま。実機・実復旧が未検証なら「完成」と書かない。
