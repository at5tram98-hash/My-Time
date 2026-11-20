# My Time iOS（SwiftUI ネイティブ版）


[ChatGPT・TimeTree連携とファイル形式](chatgpt-timetree.md)
Web 版（React/PWA）と同じデータ・同じ考え方で動く、SwiftUI で書いた iPhone アプリです。WebView やラッパーは使っていません。
Web 版はこれまでどおり使え、本番（GitHub Pages）は変更していません。iOS 版は開発ブランチ `claude/clever-hamilton-8azv05` にあります。

| 文書 | 内容 |
|---|---|
| [migration-plan.md](migration-plan.md) | 移行計画（構成・データ互換・段階） |
| [feature-map.md](feature-map.md) | Web 版 ↔ iOS 版の機能対応表 |
| [status.md](status.md) | ビルド・テスト結果、未対応・課題の一覧 |

## フォルダ構成

```
ios/
  MyTime.xcodeproj            Xcode プロジェクト（ターゲット MyTime、スキーム MyTime）
  Config/Base.xcconfig        署名・Bundle ID の共通設定（個人の値は Local.xcconfig）
  MyTime/
    App/MyTimeApp.swift       起動・SwiftData の保存先
    Data/                     SwiftData ストア（Web 版と同じ JSON をそのまま保存）・画面共通の状態
    Design/                   色・Liquid Glass・進捗リングなどの部品
    Features/                 今日・カレンダー・タスク・振り返り・詳細・編集・設定
  Packages/MyTimeCore/        UI を持たない共通ロジック（Swift Package。Linux でもテスト可能）
```

## iPhone に入れる手順（無料の Apple Account / Personal Team）

必要なもの：Mac、Xcode 16 以降（Liquid Glass を使うには Xcode 26 以降）、iOS 17 以降の iPhone、USB ケーブル。

1. Xcode を開き、**Settings › Accounts** で自分の Apple Account を追加する（無料で可）。「Personal Team」が表示される。
2. `ios/Config/Local.xcconfig` を作り、次の2行を書く（このファイルは Git に入らない）。
   ```
   DEVELOPMENT_TEAM = あなたのTeam ID（10文字）
   MYTIME_BUNDLE_ID = com.あなたの名前.mytime
   ```
   Team ID は Xcode の Accounts 画面、またはターゲットの Signing & Capabilities で Team を選ぶと表示される。Bundle ID は世界で一意にする。
   （Local.xcconfig を作らず、Signing & Capabilities で Team を直接選んでもよい。）
3. `ios/MyTime.xcodeproj` を開く。スキーム **MyTime** を選び、まずシミュレーター（iPhone 16 など）で ⌘R。
4. iPhone を USB でつなぎ、iPhone の **設定 › プライバシーとセキュリティ › デベロッパモード** をオンにする（再起動あり）。
5. 実行先を自分の iPhone にして ⌘R。初回は iPhone の **設定 › 一般 › VPN とデバイス管理** で自分の開発者 App を「信頼」する。
6. 無料の Personal Team ではプロビジョニングの期限が **7日** です。期限が切れたら Xcode からもう一度 ⌘R で入れ直す（データは残る）。

Debug / Release：スキームの Run は Debug、**Product › Archive** は Release でビルドされる。Personal Team では App Store・TestFlight には出せない（有料の Apple Developer Program が必要。課金はしていない）。

## Web 版とのデータのやり取り

- Web 版：**設定 › 端末間の移行 › 書き出す** で `.json` を作り、AirDrop・ファイル App などで iPhone へ。
- iOS 版：**設定 › 移行ファイルを読み込む** で選び、件数を確認して「追加する」。
- 逆向き（iOS → Web）も同じ形式。読み込みは追加だけで、既存データを消したり上書きしたりしない。同じファイルを2回読んでも増えない。
- 形式は `my-time-device-transfer` v1（SHA-256 による改ざん検出つき）。互換性は両側の自動テストで確認している（[status.md](status.md)）。

## テスト

```bash
# 共通ロジック（Mac でも Linux でも）
cd ios/Packages/MyTimeCore && swift test

# Web 版側の互換テスト（リポジトリのルートで）
npm test
```
