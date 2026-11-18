import XCTest

/// 主要な画面の通り道の自動テスト。端末のデータには触れない（起動引数 -inMemory でメモリ上の空のデータ）。
final class MyTimeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory"]
        app.launch()
    }

    /// 4つのタブすべてに移動でき、それぞれの画面が出る
    func testAllTabsReachable() {
        for (tab, title) in [("カレンダー", nil), ("タスク", "タスク"), ("その他", "その他"), ("今日", nil)] as [(String, String?)] {
            let b = app.tabBars.buttons[tab]
            XCTAssertTrue(b.waitForExistence(timeout: 5), "\(tab) のタブ")
            b.tap()
            if let title { XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), "\(title) の画面") }
        }
    }

    /// タスクの一覧の下の入力欄から追加でき、一覧に出る
    func testQuickAddTask() {
        app.tabBars.buttons["タスク"].tap()
        let field = app.textFields["新しいタスク（改行で追加）"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("UIテストのタスク\n")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "UIテストのタスク")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    /// 新規入力で文字を入れてからキャンセルすると、破棄の確認が出る（入力が黙って消えない）
    func testEditorAsksBeforeDiscarding() {
        app.tabBars.buttons["タスク"].tap()
        let add = app.navigationBars.buttons["追加"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let title = app.textFields["タスクのタイトル"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("破棄のテスト")
        app.navigationBars.buttons["キャンセル"].tap()
        let discard = app.buttons["破棄して閉じる"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3), "破棄の確認")
        discard.tap()
        XCTAssertFalse(app.staticTexts["破棄のテスト"].waitForExistence(timeout: 1))
    }

    /// その他 › 自動削除・診断・ロック画面の表示 に2タップ以内で行ける
    func testSettingsReachable() {
        app.tabBars.buttons["その他"].tap()
        for name in ["自動削除", "ロック画面の表示", "種類ごとの設定"] {
            let cell = app.staticTexts[name]
            var tries = 0
            while !cell.isHittable && tries < 6 { app.swipeUp(); tries += 1 }
            XCTAssertTrue(cell.isHittable, name)
            cell.tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3), name)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
}
