# 指示書 v3 要件台帳（C01〜C35・F1〜F6・R1〜R3・V01〜V14）

ブランチ `uiux-v3`。仕様：`docs/uiux-v3-spec.md`、注釈：`docs/uiux-v3-annotations.csv`。
状態は「実装済」と「検証済」を分けて書く。**検証済**＝自動テスト（Chromium の iPhone 15 Pro 相当と WebKit）またはキャプチャ確認で受入条件を確かめたもの。**iPhone 実機ではどの項目も未検証**。
本番データの変更・Secrets 変更・RETENTION_MODE の変更はしていない（off のまま）。

| ID | 変更ファイル（主なもの） | 変更内容 | 実装 | 検証（証拠） | 外部条件 |
|---|---|---|---|---|---|
| C01 | home/HomeScreen.tsx, home/FloatingCards.tsx, styles/home.css | 通常／コンパクト／カレンダーの3状態。コンパクトは円だけ（36px・操作44px）、文字・枠・線・つまみを描かない。対象なしは高さ0。円の列で生の移動量36px／速度0.65px/msの上スワイプでカレンダー（日付と1日/2日→日/2日を引継ぎ）、下スワイプで一覧へ。初動8pxまでタップ、縦の意図確定時だけキャプチャ。pointercancel は何もしない。通常→コンパクトの1操作でカレンダーへ進まない | 実装済 | 検証済（uiux-v3「C01」2件・phase1 境界ハンドル） | 実機の指追従 |
| C02 | home/HomeScreen.tsx | メニューの1日／2日を削除し「日付を選択」（年月日ホイール）。取消は日付を変えない | 実装済 | 検証済（uiux-v3「C02」閏日） | — |
| C03 | styles/home.css | 見出し17px semibold、件数13px、行60px、タイトル17px、時刻15px tabular、区切りは本文開始位置から。完了行は薄い取り消し線 | 実装済 | キャプチャ確認 | 実機 |
| C04 | components/Identity.tsx, TaskIcon.tsx, TaskRow.tsx | 共通の識別バッジ（タスク＝円、実行赤／確認青、完了でも種別色を維持）。外周＝実績、目盛り＝理想 | 実装済 | 検証済（TaskIcon 単体・phase3 アイコン・キャプチャ） | — |
| C05 | ui/Ring.tsx, styles/editor.css, Identity.tsx | `.ring svg` の全子孫指定を撤廃し、外周 `.ring-arc` だけを重ねる。中央図形は grid 中央 | 実装済 | 検証済（uiux-v3「C05・C25」中心差1px以内） | DPR1/2/3 の実機 |
| C06 | editor/place.tsx（MapPreview）, TaskDetailSheet, InfoSheets | 場所の直下に地図プレビュー（座標ありは OSM タイルの静的地図＋ピン＋マップで開く、座標なしは偽ピンを出さず名称・住所と「マップで開く」） | 実装済 | 一部検証（座標なしの代替表示：uiux-v3「C14…F3」）。座標ありの地図タイル表示は外部通信のため自動テスト外 | 実機・通信 |
| C07 | domain types/contracts/repo, TaskDetailSheet, TasksScreen, EditorSheet | Subtask に plannedStart/plannedEnd/estimateMinutes（任意）。終了だけ・終了≦開始・不正な見積を拒否。親の日時変更時に「一緒に移動／そのまま／キャンセル」を選択。チェック・名前変更・並べ替えで保持 | 実装済 | 検証済（API 往復・バックアップ・不正値拒否、uiux-v3「C07・C08」） | — |
| C08 | TaskDetailSheet（WorkLog） | 実績ログは初期は閉じた1行（件数・>）。作業区間と操作履歴を分け、日付ごと。日跨ぎは両日付 | 実装済 | 検証済（初期は閉じている） | — |
| C09 | EditorSheet（DateTimeRow）, styles/editor.css | 日時行をコンテナ幅で1行／2段に切替。日付・時刻は折り返さず44px | 実装済 | キャプチャ確認（390px） | 320/200%文字の実機 |
| C10 | ui/KindButtons.tsx | 実行（赤）／確認（青）／すべて（中立）の独立ボタン。選択はチェックと面でも示す | 実装済 | 検証済（uiux-v3「C10」色・トラックなし） | — |
| C11 | EditorSheet（種類シート） | 一般タスクの説明を基準文に。実行／確認の補足 | 実装済 | キャプチャ未取得 | — |
| C12 | EditorSheet（種類シート）, InfoSheets | Studio 種類の icon・color でバッジ表示、選択チェックは別列 | 実装済 | キャプチャ未取得 | — |
| C13 | editor/pickers.tsx, styles/editor.css | 円40px・操作44px・間隔8px相当、先頭末尾に選択枠の余白。選ぶと見える範囲へ | 実装済 | キャプチャ確認 | — |
| C14 | editor/place.tsx（PlaceTravelPopup）, EditorSheet | 基本タブに「場所と移動」。場所と移動時間を1シートで編集、完了で両方反映・取消で両方戻す。場所を外すとき移動時間の扱いを選ぶ。出発の目安表示 | 実装済 | 検証済（uiux-v3「C14・C17・F3」） | — |
| C15 | editor/place.tsx | 移動時間はボタン（なし/5/10/15/30/45/60）＋「ほかの時間（分）」。未入力は空欄、「なし分」を出さない | 実装済 | 検証済（同上） | — |
| C16 | editor/place.tsx（usePlaceSearch） | ホーム検索と同じ1行の検索。技術名を主役にしない（帰属表示は結果下）。明示送信のみ・1秒1回・古い応答を捨てる・中断。未検索／検索中／結果／0件／オフライン／失敗を別表示。IME変換中の Enter は送らない | 実装済 | 自動テスト未（外部通信）。状態の描画はコード確認のみ | 実通信 |
| C17 | editor/place.tsx | 「住所を直接入力」（名称・住所のラベル付き）、「この場所を使う」、場所の削除は別行、開閉は共通の動き | 実装済 | 検証済（直接入力で保存） | — |
| C18 | editor/pickers.tsx（NotifyPopup） | 要約チップ→よく使う時刻の複数選択→「カスタム時刻を追加」（日・時間・分のホイール）。権限案内は小さなカードで正しい画面名「通知」 | 実装済 | 検証済（uiux-v3「F1・C18・C23」、uiux-v2 複数通知） | Push 実受信 |
| C19 | editor/inputs.tsx（ChoicePopup）, EditorSheet | カテゴリー・カレンダーは行タップで選択シート（なし・候補・検索） | 実装済 | 一部検証（タグ・カテゴリーのテストで選択画面へ遷移はせず保存のみ確認） | — |
| C20 | editor/inputs.tsx（PriorityButtons） | なし／低（灰）／中（橙）／高（赤）。記号とチェック併用、押下・選択の動き、Reduced Motion で拡大停止 | 実装済 | キャプチャ確認 | — |
| C21 | editor/inputs.tsx（TagInput） | 確定したタグはチップ。Enter・空白・読点で確定、IME変換中は分割しない、重複除去、空欄Backspaceで選択→削除 | 実装済 | 検証済（uiux-v3「C21・C19」） | 実機 IME |
| C22 | home/HomeScreen.tsx | 「島」を廃止し「タスクをコンパクト表示」／「タスク一覧を表示」 | 実装済 | 検証済（uiux-v3「C01」高さ0） | — |
| C23 | EditorSheet | 通知を基本タブへ（オプションから削除）。日時未設定の案内 | 実装済 | 検証済 | — |
| C24 | EditorSheet（リンク・添付） | リンクは3列（アイコン・名前とURL・削除）、http/https の検証。添付は種類・サイズ・状態の行、未ログインはログイン導線。外すのは参照だけ（ドライブのファイルは残す） | 実装済 | 一部（未ログイン表示） | 許可済みテストアカウントでのアップロード実証は外部条件待ち |
| C25 | 同 C05 | 全進捗値で中央図形を同じ位置に | 実装済 | 検証済（0/20/100%） | — |
| C26 | tasks/TaskRow.tsx, tasks/ProgressPanel.tsx | 長押しで行を持ち上げ、近くに浮遊パネル（リング・大きな数字・根拠・バー）。値計算と取消は従来どおり。メニュー「進捗を変更」から同じパネル。Studio 数値は元の項目を更新（manual に保存しない）、サブタスクはチェック一覧、時間は表示のみ | 実装済 | 検証済（phase1-review 長押し進捗、uiux-v3「F2」） | 実機 |
| C27 | editor/pickers.tsx（Wheel, DatePickerPopup） | 年・月・日の3列ホイール（月の日数に追従、要約表示、キーボード操作）。時刻・通知のカスタム・サブタスクも共通ホイール | 実装済 | 検証済（閏日・既存テストの日時入力） | 実機の慣性 |
| C28 | ui/MiniBar.tsx, Timeline.tsx, InlineSearch.tsx | ミニバー・時間軸・検索結果も共通バッジ（予定＝角丸四角、タスク＝円）。ミニバーのリングは実績、理想は目盛り | 実装済 | キャプチャ確認 | — |
| C29 | tasks/TasksScreen.tsx | スマートリスト（今日・近日・すべて・フラグ・完了の件数）、種類ボタン、グループ（カテゴリー／タグ／日付）切替、見出しの開閉、空状態と絞り込み解除。既存操作は維持 | 実装済 | 検証済（uiux-v3「C29」、既存一覧テスト） | — |
| C30 | ui/KindButtons.tsx | 選択中だけ最大（48px・scale）、押下の沈み込み、高さ予約で一覧が跳ねない | 実装済 | 検証済（uiux-v2/3 の切替） | — |
| C31 | domain analysis.ts, analysis/* | 既存5指標＋①完了率推移②実行時間③予定と実績④カテゴリー別⑤曜日×時間帯⑥中断推移。カテゴリー・タグの絞り込みを全指標へ。時刻未設定の件数を明示 | 実装済 | 検証済（ドメイン単体：合計一致・二重計上なし） | — |
| C32 | other/ManagePages.tsx, ui/reorder.ts | 矢印ボタン廃止、右端ハンドルでドラッグ（端の自動スクロール、範囲外・取消は元へ）。キーボード代替 | 実装済 | 検証済（uiux-v3「C32」） | 実機ドラッグ |
| C33 | ManagePages.tsx, studio/StudioPage.tsx | カレンダー追加で一般／授業／アルバイト＋カレンダー用 Studio 種類を選択。なければその場で作成し、作成途中へ戻って選択済み | 実装済 | 検証済（uiux-v3「C33」） | — |
| C34 | styles/components.css, OtherScreen.tsx | inset grouped（左右16px・グループ間26px・行52px・アイコン28px・区切りは本文から）、末尾の余白 | 実装済 | キャプチャ確認 | 200%文字 |
| C35 | OtherScreen.tsx | 外観・文字サイズは詳細画面で選ぶ（プレビュー付き）。一覧からの直接変更をなくした | 実装済 | 検証済（uiux-v3「C35」） | — |
| F1 | TaskDetailSheet, InfoSheets, pickers.notifySummary | extra.notifies を優先（空配列も）、旧データだけ単一値。全件・重複なし・同じ要約 | 実装済 | 検証済 | — |
| F2 | domain resolveProgress, app/progress.ts | 進捗の根拠を一本化（完了→Studio→サブタスク→手動→未入力）。リング・実績欄・パネルが同じ値 | 実装済 | 検証済（単体＋uiux-v3「F2」） | — |
| F3 | TaskDetailSheet | 場所は1か所（新しい値を優先、旧 location は互換表示） | 実装済 | 検証済 | — |
| F4 | KindButtons, DateTimeRow | 狭幅で種別・日付が1文字ずつ折り返さない | 実装済 | 390px はキャプチャ確認。320px は未撮影 | 実機 |
| F5 | components/Sheet.tsx, TaskDetailSheet | シート見出しIDを useId で一意に。呼び出し元の見出しIDと分離 | 実装済 | 検証済（uiux-v3「F5」重複IDなし） | VoiceOver 実機 |
| F6 | ui/ContextMenu.tsx | 長押しプレビューの最低高さを確保（2行が切れない） | 実装済 | 未自動化 | — |
| R1 | TaskDetailSheet, resolveProgress | 親完了時に残件を確認、子は自動完了しない、完了でも残件を表示 | 実装済 | 検証済（uiux-v3「R1」） | — |
| R2 | styles/timeline.css | 狭い列ではタイトル先頭を優先し図形・時刻を省く | 実装済 | 未撮影 | 実機 |
| R3 | HomeScreen.tsx | 境界の aria-valuenow を比率に、上下キーで段階調整、Home でコンパクト。コンパクトではフォーカス可能な見えない境界を残さない | 実装済 | 一部（コンパクトで handle が消えることを検証） | — |
| 追加 | other/DataPages.tsx | 未ログイン時のバックアップ／復元にログイン導線と「まだ何も実行していない」説明 | 実装済 | 未自動化 | — |

## V01〜V14（総合試験）

結果は `docs/uiux-v3-report.md` の「テスト結果」を参照。自動化できない項目（実機の慣性・VoiceOver・ホーム画面 PWA・Push 受信・許可済みテスト Google アカウントでの添付／同期）は**外部条件待ち**として残す。
