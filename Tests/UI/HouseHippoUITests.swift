import XCTest

/// Run on macOS. Each test launches the real app with a fresh offline household.
final class HouseHippoUITests: XCTestCase {
    private var app: XCUIApplication!
    private var testID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
        app = XCUIApplication()
        app.launchEnvironment["HOUSEHIPPO_UI_TEST_ID"] = testID
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["househippo-ui-test-household"].waitForExistence(timeout: 10),
                      "Refusing to interact unless the app confirms an isolated test household.")
    }

    override func tearDownWithError() throws {
        if let app {
            if (testRun?.failureCount ?? 0) > 0 {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Failure screenshot"
                attachment.lifetime = .keepAlways
                add(attachment)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "Accessibility tree"
                tree.lifetime = .keepAlways
                add(tree)
            }
            app.terminate()
        }
    }

    private func navigate(_ title: String) {
        let row = app.outlines.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), title)
        row.click()
    }

    private func fill(_ label: String, with text: String) {
        let field = app.textFields[label].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), label)
        field.click()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    private func recordButton(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func testDashboardCalendarSetupIsViewOnlyAndCloses() {
        navigate("Dashboard")
        XCTAssertTrue(app.staticTexts["Today's calendar"].waitForExistence(timeout: 5))
        app.buttons["Calendars"].click()
        XCTAssertTrue(app.buttons["Connect Apple Calendar"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Choose one calendar for each person. Both appear on the Dashboard, regardless of the selected task profile. Events are view-only.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Add event"].exists)
        XCTAssertFalse(app.buttons["Delete event"].exists)
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(app.buttons["Calendars"].waitForExistence(timeout: 5))
    }

    func testMainSectionsOpenWithoutErrors() {
        for title in ["Tasks", "Waiting For", "Borrowing & Lending", "Last Time", "Inventory", "Things To Pay", "Notes", "Meals", "Dashboard"] {
            navigate(title)
            XCTAssertFalse(app.alerts.firstMatch.exists, title)
        }
    }

    func testGroceryCanBeAddedCheckedAndPersistedAfterRelaunch() {
        navigate("Meals")
        fill("Add groceries", with: "UI test apples")
        app.buttons["Add"].firstMatch.click()
        let check = app.buttons["Check off UI test apples"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.click()
        XCTAssertTrue(app.disclosureTriangles["Checked off (1)"].exists || app.buttons["Clear checked items (1)"].exists)
        app.terminate(); app.launch()
        navigate("Meals")
        XCTAssertTrue(app.buttons["Clear checked items (1)"].waitForExistence(timeout: 5))
    }

    func testWaitingForCreationAndCancel() {
        navigate("Waiting For")
        app.buttons["Add record"].click()
        XCTAssertFalse(app.buttons["Save"].firstMatch.isEnabled)
        fill("Waiting for", with: "UI test repair quote")
        app.buttons["Save"].firstMatch.click()
        XCTAssertTrue(recordButton("UI test repair quote").waitForExistence(timeout: 5))
        app.buttons["Add record"].click()
        fill("Waiting for", with: "Cancelled record")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(recordButton("Cancelled record").exists)
    }

    func testNotebookNotePersistsAfterRelaunch() {
        navigate("Notes")
        app.buttons["New note"].click()
        fill("Title", with: "UI test house note")
        app.buttons["Save"].firstMatch.click()
        XCTAssertTrue(recordButton("UI test house note").waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        navigate("Notes")
        XCTAssertTrue(recordButton("UI test house note").waitForExistence(timeout: 5))
    }

    func testRandomNotePickingPreservesListUntilWholeNoteIsEdited() {
        navigate("Notes")
        app.buttons["New note"].click()
        fill("Title", with: "Drinks to choose")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", "Edit", XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue)).firstMatch.click()
        let editor = app.textViews["Markdown note"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("- Tea\n- Coffee")
        app.buttons["Save"].firstMatch.click()
        let pick = app.buttons["Pick a random item from Drinks to choose"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.click()
        let selection = app.staticTexts["random-note-selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            XCTAssertTrue(["Tea", "Coffee"].contains(selection.value as? String ?? selection.label))
            XCTAssertFalse(app.buttons["Remove"].exists)
            XCTAssertFalse(app.buttons["Delete"].exists)
            XCTAssertFalse(app.buttons["Mark done"].exists)
            app.buttons["Pick again"].click()
        }
        app.buttons["Done"].click()
        app.terminate(); app.launch()
        navigate("Notes")
        recordButton("Drinks to choose").click()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", "Edit", XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue)).firstMatch.click()
        let reopened = app.textViews["Markdown note"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "- Tea\n- Coffee")
        reopened.click()
        reopened.typeKey("a", modifierFlags: .command)
        reopened.typeText("A regular note")
        XCTAssertFalse(app.buttons["Random pick"].exists)
        app.buttons["Save"].firstMatch.click()
        XCTAssertFalse(app.buttons["Pick a random item from Drinks to choose"].exists)
    }

    func testInventoryCollectionCanBeCreated() {
        navigate("Inventory")
        app.menuButtons["Add collection"].click()
        app.menuItems["New collection"].click()
        XCTAssertFalse(app.buttons["Create"].firstMatch.isEnabled)
        fill("Collection name", with: "UI test records")
        app.buttons["Create"].firstMatch.click()
        XCTAssertTrue(recordButton("UI test records").waitForExistence(timeout: 5))
    }

    func testBorrowedItemCanBeCreatedAndReturned() {
        navigate("Borrowing & Lending")
        app.buttons["Add item"].click()
        XCTAssertFalse(app.buttons["Save"].firstMatch.isEnabled)
        fill("Person", with: "UI test neighbor")
        fill("Item", with: "UI test ladder")
        app.buttons["Save"].firstMatch.click()
        let returned = app.buttons["Mark UI test ladder returned"]
        XCTAssertTrue(returned.waitForExistence(timeout: 5))
        returned.click()
        let notice = app.staticTexts["Everything has been returned. Choose Include returned to see the history."]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
    }

    func testLastTimeMarkerCanBeCreatedAndPersisted() {
        navigate("Last Time")
        app.buttons["Add marker"].click()
        XCTAssertFalse(app.buttons["Save"].firstMatch.isEnabled)
        fill("Marker", with: "UI test filter replacement")
        app.buttons["Save"].firstMatch.click()
        XCTAssertTrue(recordButton("UI test filter replacement").waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        navigate("Last Time")
        XCTAssertTrue(recordButton("UI test filter replacement").waitForExistence(timeout: 5))
    }

    func testPaymentRequiresAnAmountAndPersists() {
        navigate("Things To Pay")
        app.buttons["Add payment"].click()
        fill("Payment", with: "UI test lesson")
        XCTAssertFalse(app.buttons["Save"].firstMatch.isEnabled)
        fill("Amount ($)", with: "12.34")
        app.buttons["Save"].firstMatch.click()
        XCTAssertTrue(app.buttons["Mark UI test lesson paid"].waitForExistence(timeout: 5))
        XCTAssertTrue(recordButton("UI test lesson").label.contains("$12.34"))
        app.terminate(); app.launch()
        navigate("Things To Pay")
        XCTAssertTrue(app.buttons["Mark UI test lesson paid"].waitForExistence(timeout: 5))
    }
}
