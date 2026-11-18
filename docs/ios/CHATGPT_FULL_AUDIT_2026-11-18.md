# MyTime iOS ネイティブ版 — ChatGPT 全面監査・改善要求書（2026-11-18）

> **監査の性質**：GitHub ソースコードの静的監査＋既存テスト報告の照合＋Apple 公式仕様の確認。**Xcode の実行、iPhone 実機操作、画面のピクセル単位の視覚検査はこの環境では未実施**。本書で「確認済み」は該当コードの存在・ロジックに関する確認であり、実機で正常動作した証明ではない。未確認の項目を「合格」としない。
>
> 対象: https://github.com/at5tram98-hash/My-Time / main / 基準 HEAD \`37a072f4ea80a04132dba0cbe6ff7c004120a4fa\`  
> 監査日: 2026-11-18 / 監査者: ChatGPT  
> **本書は実装命令・検収基準であり、修正済みの報告ではない。ユーザー承認なく既存アプリの仕様やデータを削除しない。**

## 0. 結論（重要順）

1. **時刻ヘッダーを廃止**：今日のタイトルを日付／秒付き時刻で交互に入れ替える挙動を撤去。日付は固定。秒数はシステムのステータスバーを改変せず、**アプリ内のセーフエリアに設けた控えめな補助表示**として実装する。Dynamic Island や画面上部操作を妨げない。
2. **Dynamic Island とロック画面を情報設計から再構築**：授業、バイト、朝、清掃、移動、勉強、タスク、チェックポイントを同一の汎用レイアウトで押し込まない。表示種別・時間フェーズ・優先度ごとに「最重要情報」を 1 個定める。
3. **信頼性の P1 を先に修正**：保存エラーの握りつぶし、Live Activity の更新停止・時間切替、App Intent ハンドラ初期化依存、通知の Critical Alert 権限、予定済み Live Activity の古い情報、休憩ルールの境界値。
4. **本当の「全面検証」を追加**：iOS ビルドを CI に導入し、XCUITest、iPhone 実機の時間・通知・ロック状態テストを実施する。GitHub Actions の現行 CI 成功を iOS 品質保証と混同しない。

## 1. 実施した調査と、未実施のこと

### 実施
- GitHub のリポジトリ構成（計 586 エントリ）・最新 commit・branch・Actions の状態を取得。
- \`ios/MyTime.xcodeproj\`、\`ios/MyTime/App/MyTimeApp.swift\`、\`RootView.swift\`、\`TodayView.swift\`、\`DayTimeline.swift\`、主要な Calendar / Tasks / Editor / Detail / Plan / More / Settings / Morning / Cleaning / Work 画面をコード確認。
- \`LiveActivityCoordinator.swift\`、\`MyTimeLiveActivity.swift\`、\`MyTimeActivity.swift\`、\`Notifications.swift\`、\`TaskAlarms.swift\`、\`LifeStore.swift\`、\`SwiftDataStore.swift\`、\`Payroll.swift\`、\`Repository.swift\`、\`Life.swift\`、テストファイルを重点確認。
- \`docs/ios/README.md\`、\`status.md\`、\`life-support-report.md\`、\`feature-map.md\`、既存 CI 設定と照合。
- Apple 公式 HIG（Status bars、Live Activities）、ActivityKit、App Intents、Critical Alerts 権限を照合。

### 未実施／制約
- この環境に Xcode / iOS Simulator / 接続された iPhone がない。\`xcodebuild\`、実機のロック・バックグラウンド・アラーム検証、スクリーンショットのピクセル比較は実行していない。
- Swift 単体テスト「60 件成功」はリポジトリの **11/18 実装報告に書かれた結果**。監査者が再実行したテスト結果ではない。
- 11/18 main に対する GitHub Actions CI は成功しているが、\`.github/workflows/ci.yml\` は Ubuntu 上で Web/TS のチェックを行っており、iOS ビルドや XCUITest は含まない。
- UI の自動計測、操作の成功率、クラッシュ率、バッテリー計測は未取得。品質を百分率で「達成」と判定しない。

## 2. 監査指摘一覧

重大度: **P0=データ破壊・即時停止級 / P1=リリース前必須 / P2=強い改善要求 / P3=継続改善**。状態は「コード上で事実」「リスク推定」「未検証」を分ける。

| ID | 優先 | 判定 | 対象 | 問題・根拠 | 対応 |
|---|---|---|---|---|---|
| A01 | P1 | コード確認 | \`TodayView.swift\` DateClockTitle（約543-581行） | \`TimelineView(by:1)\` で毎秒評価し、\`(sec / 5)%2\` で 5 秒ごとに日付／秒時計を交替。表示の意味が安定せず、ツールバーを再描画する。 | 日付固定、時計切替廃止、補助秒数表示を別ビュー化 |
| A02 | P1 | 仕様制約 | iOS ステータスバー | 他社アプリはシステム時計の下に秒を直接埋め込めない。画面外や Dynamic Island 直下への無理な overlay は回避。 | safeAreaInset を使う専用アプリ UI として実装 |
| A03 | P1 | コード確認 | \`SwiftDataStore.swift\` \`saveIfNeeded\`（約152-154行） | トランザクション外の \`context.save()\` が \`try?\` で黙殺される。設定などの保存失敗をユーザーが検知できない。 | エラー伝播できる API と失敗時の rollback／明示アラート、故障注入テスト |
| A04 | P1 | コード確認 | \`RootView.swift\` LiveActionRouter 設定／\`MyTimeActivity.swift\` \`perform()\` | Intent は \`static handler\` の有無に依存し、handler が未設定なら操作なしで \`.result()\` を返す。アプリがバックグラウンド起動したとき UI の \`.task\` に依存しない永続データ操作に改める。 | Intent 自体が保存コンテナを開き、トランザクションで更新し結果を通知。コールドスタート試験 |
| A05 | P1 | コード確認＋動作未検証 | \`LiveActivityCoordinator.swift\` \`reconcile\`（約62-100行） | Live Activity を編集／開始／終了するとき前面中は 1 分照合、閉じている間は更新なし。バイト開始前に予約した \`status\` が開始後も「開始まで」のまま残り得る。 | 状態遷移を設計し、時間駆動表示と許可されたバックグラウンド更新／プッシュ等を組み合わせる |
| A06 | P1 | コード確認 | \`LiveActivityCoordinator.swift\` 予約 | 今後 12 時間の候補のうち最大 2 件のみを先行予約。長期間アプリ未起動／候補 3 件以上／予定変更で開始漏れ、古い予約の可能性。 | OS 制限・同時数を考慮した予約戦略、定期照合機会、通知フォールバック、実機シナリオで検証 |
| A07 | P1 | コード確認 | \`Notifications.swift\` 約142行 | 権限のない環境でも \`.defaultCritical\` を使用。\`requestAuthorization\` は通常通知権限のみ、Critical Alerts の entitlement が見当たらない。 | Critical を廃止して \`.default\`＋適切な \`.timeSensitive\` に変更。真の目覚ましは AlarmKit。通知失敗をログ |
| A08 | P1 | コード確認 | \`TaskAlarms.swift\`, \`Notifications.swift\` | \`try?\` による AlarmKit／通知スケジュール失敗の握りつぶし。認可済でも予約失敗したときフォールバックが欠落し得る。 | 予約成否を保持・可視化し、再試行、代替通知へ移行 |
| A09 | P1 | コード確認 | \`AutoCleanup.swift\` | アーカイブ・完全削除を \`model.perform\` 中に \`try?\` で実施。個別保存の失敗を握りつぶしたまま「完了」にできる。 | 全件成功／ロールバック、削除対象プレビュー、失敗時保存、Undo／復元の試験 |
| A10 | P1 | 境界値リスク（仕様要確認） | \`Payroll.swift\`、\`WorkplaceViews.swift\` 休憩 | 休憩条件は \`scheduled > overMinutes\`（「○時間を超えたら」）で厳密に >。就業規則が「4時間**以上**」「6.5時間**以上**」の場合、ちょうど境界の勤務は誤計算になる。 | 「以上／超」選択を明示するか、勤務先規定に合わせ \`>=\` を指定できるようにする。境界テスト |
| A11 | P2 | コード確認 | \`MyTimeLiveActivity.swift\` compact（約48-65行） | 左 64pt に \`headline ?? title\`、右 52pt に秒カウントダウンを押し込む。長い名前・秒付き時間が切れやすい。 | 種類別 compact・minimal の専用表示、短い値と適応表示 |
| A12 | P2 | コード確認 | \`LiveActivityCoordinator.swift\` バイト候補 | 勤務先住所を \`headline\` に使用しているため、compact の先頭に長い住所が出ることがある。 | compact は勤務先略称／状態、住所は拡張表示の補助項目に限定 |
| A13 | P2 | コード確認 | \`MyTimeLiveActivity.swift\` expanded/LockScreen | title、detail、headline、残時間を汎用配置。授業の「教室」とバイトの「出勤まで」を同じ情報優先順位で表している。 | 各種類の最重要情報、余白、文字サイズ、コントラストを個別設計 |
| A14 | P2 | コード確認 | \`RootView.swift\` シェイク Undo | 直前の操作の取り消しが原則「端末を振る」経路のみ。操作の発見性・VoiceOver とアクセシビリティに弱い。 | 保存／削除後の軽い Undo UI と履歴からの復元を提供。シェイクは補助 |
| A15 | P1 | 未検証 | \`.github/workflows/ci.yml\`／\`docs/ios/*\` | 現行 CI は iOS をコンパイルしない。UI テスト（XCUITest）未作成。実機・通知・ロック状態の品質保証がない。 | macOS xcodebuild CI と XCUITest と物理端末検収を整備 |
| A16 | P2 | コード確認 | iOS/Web の連携 | クラウド自動同期／Google ログイン／Drive バックアップは iOS 実装未完（手動 JSON 移行が中心）。 | 既存データの安全を最優先し、移行往復・重複・障害復旧のテスト後に別 PR |
| A17 | P2 | リスク（未確認） | \`apps/api/.dev.vars.e2e\` | 公開リポジトリにテスト用 env ファイルが追跡されている。SECRET 名の値が含まれるが、実運用鍵かテストダミーかは未判定。 | 設定値の用途を確認。実鍵なら失効・ローテーション、履歴確認。値を監査文書に転載しない |
| A18 | P2 | 未検証 | 全画面共通 | 大きな文字／VoiceOver／Reduce Motion／ダークモード／iPhone サイズ差／ランドスケープ／表示ズームの実測証明なし。 | アクセシビリティとスクリーンショット差分の実証を実施 |

> **判定上の注意**：A04/A05/A06/A08 等は障害の発生を実機で確定したのではなく、実装が依存する条件と起こり得る問題を指摘したもの。A10 は現在の実装自体は UI の「超」と一致しているが、勤務先の「以上」規則を入力できないという仕様不適合リスク。

## 3. 依頼された時計の全面再設計

### 3.1 廃止
- 今日画面の \`DateClockTitle\` で日付と \`HH:mm:ss\` を自動交替させる機能を**完全撤去**。
- 日付／曜日が変わる、中央タイトルの幅を変える、時計がスライドする演出は禁止。
- 現在の \`TimelineView(.periodic(by:1))\` をナビゲーションバーのタイトルから外す。曜日・日付を常時固定表示。

### 3.2 新しい秒数表示の採用仕様
- **Apple が描画するステータスバーの時間・Wi‑Fi・バッテリーは一切改変しない。**
- 画面上端の **セーフエリア内／ステータスバー直下**に \`00–59\` の小さい補助秒数を置く。「時計の下に秒がある」印象になるよう視覚的に左寄せ、純正のステータスバーに上書きするふりをしない。
- 秒数は \`monospacedDigit\`、\`caption2\` 程度、低めだが十分なコントラスト。装飾を最小にし、タップを受ける領域は最低 44pt、非操作表示ならタップ領域不要。
- 今日・カレンダー・タスクなど全画面で位置を統一。ただしシートや全画面の入力中、キーボード表示時、スクロールで上部が縮む際の挙動を明文化。
- Dynamic Island 機種／ない機種／表示ズーム／横画面を個別設計。\`safeAreaInset(edge:.top)\` または安全な専用レイアウトを利用し、**他アプリやホーム画面のステータスバーには表示できない**ことを設定説明に明記。
- 秒数の更新は **アプリが見えているときだけ**。差分のない上部コンテナや全画面を毎秒再計算しない。軽量な \`TimelineView\` を独立させ、境界 59→00 と日付跨ぎを検証。電池消費と VoiceOver の読み上げ連発を防ぐ。
- 設定に「秒数を表示」トグル（既定 ON 可）を追加。Reduce Motion では数字のアニメーションを止め、画面読み上げは一秒ごとに自動発話させない。
- **代替案**：狭い端末では時間の横の小さな \`:SS\`、またはヘッダー内のミニ時計。ステータスバーに重ならないことが最優先。

### 3.3 受け入れ条件
T-CLK-01 日付が固定され 5 秒ごとに変わらない。
T-CLK-02 秒数は 1 秒刻みで正確／59→00／23:59:59→翌日。
T-CLK-03 画面上部の追加・検索・戻るが押せる。時刻部分がジャンプしない。
T-CLK-04 ステータスバー・Dynamic Island の表示と重ならない。
T-CLK-05 VoiceOver と Dynamic Type と Reduce Motion で正しく使える。
T-CLK-06 非表示・バックグラウンド中に余計な秒ループが走らない。
T-CLK-07 非対応端末で崩れない。

## 4. Dynamic Island / Live Activities — 全面的な再設計仕様

### 4.1 統一原則
- **一瞥で分かる情報は 1 つ**：何の用事か（最短のラベル）、次に必要な値（教室・出勤まで・次の手順・残り数）、状態の3要素を最大とする。
- **Minimal**: 1つの SF Symbol／進捗リングなど（直径約28ptに収まる場合も想定）。文字の羅列は禁止。
- **Compact**: 左＝意味のある短い識別子（授業なら教室、バイトなら GU など）／右＝短い時間・進捗。住所全文や長いタイトルを表示しない。
- **Expanded**: 1行目ラベル、2行目に最大の重要情報、3行目に日時と補足。必要な操作だけ配置。ボタンは使用可能状態・結果・エラーを明示。
- **Lock Screen**: Dynamic Islandより広いが、最重要情報は最大文字、詳細は1段下。透過背景で文字が読めなくならない配色と暗色検証。
- 種別ごとにテンプレートを分ける。文字切れ時の省略優先順位を定義。秒単位より**分単位**を基本（直前1分など例外のみ秒表示）。
- 色だけに意味を依存させない（文字「開始前」「勤務中」「終了」等、SF Symbol と併用）。
- OS がどの Live Activity を Dynamic Island に表示するか最終判断する。アプリが強制表示できるとの誤表示はしない。

### 4.2 種類別の情報優先順位

| 種類 | Compact Leading | Compact Trailing | Expanded 最上位 | 補足・アクション |
|---|---|---|---|---|
| 次の授業 | \`5302\` 等の教室（無ければ 🎓相当の SF Symbol） | \`8分\` など開始まで | **5号館302 / 教室** を最大表示 | 授業名・開始終了・小テストあり・詳細へ |
| バイト | GU 等の短い勤務先名 | \`15分\`→\`勤務中\` または終了まで | **18:30 出勤／勤務中** | 終了時刻・勤務場所は必要なときのみ |
| 朝の準備 | 太陽アイコン＋現在工程の略名 | \`3/11\` | **現在の工程名** | 前へ／スキップ／完了、どの処理も保存を保証 |
| 清掃 | 清掃アイコン | \`3/8\` | **いまの清掃箇所** | Yes/No/対象外の判断はアプリ詳細で、Live Activity は概要優先 |
| 移動・出発 | 出発アイコン | \`あと5分\` | **出発時刻・行先** | 移動時間の根拠がなければ時刻を捏造しない |
| 勉強 | 本アイコン＋略称 | 経過／残り時間 | **科目・進捗** | 一時停止／続きの学習へ |
| 実行中タスク | 実行アイコン | 経過／進捗 | **タスク名** | 完了など、実際に操作が通るボタンのみ |
| チェックポイント | 旗アイコン | \`あと10分\` | **名前・時刻** | 終了時刻超過の古い表示を残し続けない |

### 4.3 表示の状態機械
- \`scheduled\`（予約）→\`before\`（開始前）→\`active\`（進行中）→\`ended\`（完了）→\`dismissed\`（OS上の表示終了）を管理。
- 時刻の経過で変わるものは \`countdownTo\` 等の **システム時間表示を活用**するが、**静的なラベルとステータスは自動変化しない**。更新できない場面では将来の勤務中を「開始まで」と断言しないテキストにするなど、誤解を招かない既定表示へフォールバック。
- スケジュール済み候補は \`ActivityState.pending\` と \`.active\` を区別して扱い、重複起動／復活／停止漏れを避ける。
- 無効化／予定削除／休講／時刻変更／勤務先変更／端末日時変更／タイムゾーン変更／権限の変化を再照合。
- スケジュール開始は OS の許容範囲と限界数を守り、アプリ未起動期間が長いときも「必ず表示」と保証しない。見落とし回避の通知とアプリ内表示を併用。
- \`try?\` による失敗の黙殺をやめ、Live Activity の作成・更新・終了・通知のエラーを診断ログに保存。個人情報をログに載せない。
- Live Activity は最長時間・同時数・端末優先表示の OS 制約に従う。ユーザーに「必ず出る」と説明しない。
- OS のロック状態・低電力モード・他社 Live Activity との競合・端末再起動を含めて確認する。

### 4.4 App Intents
- \`MorningStepIntent.perform\` が nil ハンドラを黙認しない。
- 本処理は起動中の画面メモリ依存にせず、OS がアプリのプロセスをバックグラウンド起動しても永続ストアを開いて実行できる設計にする。
- 操作は冪等（連打で 2 工程進まない）、成功したときだけ UI の進捗を更新。失敗した場合は「完了」と表示しない。
- アプリからの進捗変更と Live Activity ボタンからの変更の整合性をテストする。

### 4.5 受け入れテスト
- LA-01 授業60分前：教室・科目・残り時間が正しい。
- LA-02 教室番号の変更・授業削除・休講で表示が反映／終了する。
- LA-03 予定開始直前／開始直後／終了後のラベルが矛盾しない。
- LA-04 勤務開始15分前に出て、開始後は「勤務中」、終業で終了する。
- LA-05 アプリ完全終了後にも自動表示・時刻切替が期待範囲で動くかを実機で記録。
- LA-06 予約範囲外、3件以上、別アプリ競合、許可拒否を確認。
- LA-07 朝の完了／スキップ／戻るをロック画面から押し、アプリと保存値が一致する。アプリ未起動でも。
- LA-08 清掃の状態変更が実行中表示へ反映される。
- LA-09 Minimal / Compact / Expanded / Lock Screen の4表示が全種類で読める。
- LA-10 長い科目名／住所／最小・最大文字／VoiceOver／ダークモードで文字切れ・操作不能なし。
- LA-11 Dynamic Island 非搭載機ではロック画面の表示に破綻なし。
- LA-12 省電力・OS再起動・複数 Live Activity・開始間際の変更を確認。
- LA-13 停止／終了処理失敗時に古いデータや重複を残さない。
- LA-14 ディープリンクは実在する該当画面を開く（削除後は安全な代替画面）。

## 5. その他の UI / UX 総点検指示

| 領域 | 観点 | 合格条件 |
|---|---|---|
| Today | 現在線・3レーン・長押し・ズーム・タップ | ドラッグとタップが衝突せず、時間が勝手に変わらない／遅れが正しく見える |
| Calendar 日 | 終日・予定重複・空白の長押し | 15分単位の作成・編集・移動・取り消しが操作可能 |
| Calendar 週／月 | スクロール・日付変更・選択日 | Todayとの日付整合、ピンチ時に画面が飛ばない |
| Tasks | 進捗・開始・停止・完了・スワイプ | 1タップ目から反応、確認／実績／作業時間に不整合なし |
| Editor | 予定／タスク／専用項目／繰り返し | 保存・戻る・キャンセルが安全、複雑な繰り返し既存データは失われない |
| Detail | 予定／タスク／イベントリンク | 詳細→編集→保存→詳細への復帰、重複操作なし |
| Plan Assist | 提案・重なり・移動余裕 | 承認前に一切保存しない、提案ごとの影響を説明 |
| Quick Add | 曖昧な日本語・予定／タスク | 不確かな時刻を勝手に確定しない、確認できる |
| Morning / Cleaning | 長押し・並べ替え・途中保存 | 中断・終了・再開後も正しい工程と履歴 |
| Work / Payroll | 休憩・時給・割増・交通費・締め日 | 境界分数・日跨ぎ・同一勤務先の複数シフトが正確 |
| Settings | 移行・通知・自動削除 | 元データ保持、二度取り込みで重複なし、削除は復元期限を説明 |
| More / Studio | 各画面の到達性・戻る | 行き止まり・重複シート・押せないボタンなし |
| 全体 | Liquid Glass・アクセシビリティ | Dynamic Type、VoiceOver、Reduce Motion、44pt目標、ライト/ダーク、操作状態の区別 |
| 全体 | パフォーマンス | 秒数のみの更新で不要な画面再描画をしない、スクロール性能と電池消費を計測 |

## 6. データ安全・通知・計算の検証手順

1. **保存エラー注入**：SwiftData \`context.save\` の失敗をテストダブルで起こし、UI は「保存成功」を表示せず、直前の確定済みデータを保つ。
2. **削除・自動削除**：保存失敗が1件でもあれば一括操作を不完全成功にしない。復元可能な30日・完全削除・再起動後を確認。
3. **移行**：Web → iOS → Web の往復で未知項目／繰り返し予定／授業／勤務先／ios 独自設定を保持。同じ移行ファイル2回で件数が変わらない。
4. **給与**：勤務時間 3:59 / 4:00 / 4:01、6:29 / 6:30 / 6:31、6:59 / 7:00 / 7:01、7:59 / 8:00 / 8:01 を検証。**「以上」か「超」かを勤務先別に設定**。夜勤・割増重複・日跨ぎ・端数・交通費・月末・15日締め・翌月支給も確認。
5. **通知**：許可／拒否／一度拒否からの再許可／集中モード／サイレント／時差／機内モード／起動後7日超／通知上限近傍／AlarmKit 権限あり・なし。権限がない機能を「必ず鳴る」と表示しない。
6. **競合**：朝のアラームとタスクアラームの同時刻、授業と移動とバイトの同時刻、同一イベントへの反復操作、再起動直後を確認。
7. **監査ログ**：永続保存失敗、通知失敗、ActivityKit エラーのみ機密を含めず記録し、ユーザーに診断結果を確認できるようにする。
8. **復旧**：Xcode 再インストール、無料署名の期限切れ、アプリ更新後の保存データ、設定読込失敗時の一時メモリ起動とユーザー警告を検証。

## 7. 実施順序・コード変更指示（Claude Code / 実装担当用）

### Phase A：リリースブロッカー（先に実装）
A01 \`ios/MyTime/Data/SwiftDataStore.swift\`、\`AppModel.swift\`、\`Repository.swift\`：保存エラーの伝播とロールバック。
A02 \`ios/MyTime/Data/Notifications.swift\`、\`TaskAlarms.swift\`：Critical音の権限整合・失敗時の代替。
A03 \`ios/Shared/MyTimeActivity.swift\`、\`LiveActivityCoordinator.swift\`、\`RootView.swift\`：Intent を永続操作へ。時間状態・予約失敗の扱いを整理。
A04 \`ios/MyTime/Data/AutoCleanup.swift\`：アーカイブ処理での握りつぶしを排除。
A05 \`ios/Packages/MyTimeCore/Sources/MyTimeCore/Payroll.swift\`、\`WorkplaceViews.swift\`：休憩境界の「以上」対応を追加。

### Phase B：ユーザーが求める見た目の抜本改修
B01 \`ios/MyTime/Features/Today/TodayView.swift\`：\`DateClockTitle\` の日付/時刻交替撤去。
B02 \`ios/MyTime/Design/\`：\`StatusSecondsAccessory\`（仮）を追加、セーフエリア内で位置・可視状態・アクセシビリティを制御。
B03 \`ios/MyTimeWidgets/MyTimeLiveActivity.swift\`：8種の表示パターン、各4表示、フォント／優先順位／色／ボタンを再設計。
B04 \`ios/MyTime/Data/LiveActivityCoordinator.swift\`：それぞれに短縮表示テキストを生成し、Compact に住所を渡さない。次状態を考慮した描画。
B05 \`ios/MyTime/Features/Settings/SpecSettingsViews.swift\`：表示プレビュー、権限状態、表示開始分数、診断を整理。

### Phase C：テスト・検証
C01 macOS Runner 用の Xcode build/test を **別の新規ワークフロー**に追加。既存 Web CI を壊さない。
C02 XCUITest：4タブ＋主要遷移＋Today 編集＋Tasks＋各設定、Launch Arguments で固定データと固定時刻を注入。
C03 Widget プレビュー／スクリーンショット検証（8種類×4状態×ライト/ダーク）、文字切れ自動検出と目視確認。
C04 実機でのバックグラウンド／ロック／授業とバイトの境界／アラーム許可。
C05 テスト結果に「実機機種・iOS・実行日・成功失敗・スクリーンショット/ログ」を残す。

### Pull Request 運用・安全策
- 変更は **main 直書きではなく別ブランチ＋PR**、旧Web/PWAの動作は維持。
- 公開リポジトリにログイン情報や秘密鍵・個人のカレンダー実データをコミットしない。
- 最初にテスト、次に最小変更、最後にビジュアル調整の順。失敗したら修正・再実行。
- 「全部合格」と報告するには **Swift単体テスト、iOSビルド、XCUITest、実機検証、アクセシビリティ** の証拠が必要。未実行は未実行と記す。

## 8. 出荷判定ゲート（報告テンプレート）

| ゲート | 目標 | 現時点 |
|---|---|---|
| G1 Swift ロジックテスト | 全件成功・監査者または CI 再実行ログ | 実装報告60件成功、再実行なし |
| G2 iOS Debug/Release build | 2構成とも成功・macOS CI | 実装報告 Simulator build 成功、CI 未導入 |
| G3 XCUITest | 主要導線100%・全件成功 | 未作成 |
| G4 Dynamic Island 32 UI（8種×4表示） | 文字切れなし／各サイズと端末 | 未実証 |
| G5 実機 Clock/LA/Alarm | コールドスタート・ロック・境界・通知の証拠 | 未実証 |
| G6 データ安全 | 保存失敗・復旧・移行往復・完全削除と Undo | 一部ロジックテストあり、E2E 未実証 |
| G7 Accessibility | VoiceOver・最大文字・Reduce Motion・ダーク | 未実証 |
| G8 Web 回帰 | TypeScript／Web CI の緑維持 | 11/18 GitHub Actions CI 成功 |

**総合判定：構成・多機能化は進んでいるが、「実機まで含む全面検証完了／一般配布可能」との認定は保留。P1対策と証跡のある検収を先行する。**

## 9. 参照先（一次情報）

- Apple Status Bars HIG: https://developer.apple.com/design/human-interface-guidelines/status-bars
- Apple Live Activities HIG: https://developer.apple.com/design/human-interface-guidelines/live-activities
- Apple ActivityKit live data: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Apple App Intents widgets: https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- Apple Critical Alerts entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts
- ソース: \`ios/MyTime/Features/Today/TodayView.swift\`、\`ios/MyTimeWidgets/MyTimeLiveActivity.swift\`、\`ios/MyTime/Data/LiveActivityCoordinator.swift\`、\`ios/MyTime/Data/SwiftDataStore.swift\`、\`ios/MyTime/Data/Notifications.swift\`、\`ios/MyTime/Data/AutoCleanup.swift\`、\`ios/Shared/MyTimeActivity.swift\`、\`ios/Packages/MyTimeCore/Sources/MyTimeCore/Payroll.swift\`、\`.github/workflows/ci.yml\`。
- 開発報告: \`docs/ios/life-support-report.md\`、\`docs/ios/status.md\`。

---
**追記ルール**：担当者は各 ID の「修正前現象→根本原因→変更箇所→テスト証跡→未対応」をこの文書の下に追記する。推測を「完了」扱いしない。表示を変える際はユーザーの承認した情報設計を保持する。
