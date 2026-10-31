# My Time — Claude Code Repository Instructions

このリポジトリの正本仕様は `docs/My_Time_Claude_Code_3_Phases_Spec_v1.2.md` です。最初に全体を読み、Phase 1 → Phase 2 → Phase 3 の3段階だけで開発してください。旧Phase 0〜7の分割は使わず、統合仕様書に従ってください。ユーザーの許可なしに本番公開、課金、秘密情報の公開、データ一括削除をしないでください。各フェーズで実際にテストし、結果を報告してください。

最初の作業ではPhase 1を実装します。完了後に変更点・テスト・スクリーンショット・未対応項目を出してレビューを受けてください。説明だけで終わらず、実際のコードと実動する画面を作ってください。Apple純正アプリらしいシンプルで滑らかなUIを最重要品質とします。

## 公開ルール（ユーザー指示 2026-10-31）
各フェーズの完了時に GitHub（at5tram98-hash/My-Time）の main へ push して公開する。push すると `.github/workflows/deploy.yml` がテストに合格したビルドだけを GitHub Pages（https://at5tram98-hash.github.io/My-Time/）へ自動デプロイする。
