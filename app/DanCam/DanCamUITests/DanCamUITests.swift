//
//  DanCamUITests.swift
//  DanCamUITests
//
//  Created by dan on 6/24/26.
//

import XCTest

final class DanCamUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testTopLevelTabsAndDebugNavigation() throws {
        let app = XCUIApplication()
        app.launch()

        let tabs = app.tabBars.buttons
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs.element(boundBy: 0).label, "Home")
        XCTAssertEqual(tabs.element(boundBy: 1).label, "Debug")
        XCTAssertEqual(tabs.element(boundBy: 2).label, "Settings")
        XCTAssertTrue(tabs["Home"].isSelected)
        XCTAssertFalse(app.buttons["Status detail"].exists)

        tabs["Debug"].tap()

        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
