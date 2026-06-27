import XCTest

final class JournalSettingsTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "app.muukii.journal")
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testOpenSettingsAndDumpHierarchy() throws {
        // Wait for app to load
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        sleep(3)
        
        print("APP STATE: \(app.state.rawValue)")
        print("\n=== INITIAL HIERARCHY ===\n\(app.debugDescription)")
        
        // Screenshot initial
        let initialShot = app.screenshot()
        let initialAttach = XCTAttachment(screenshot: initialShot)
        initialAttach.name = "initial"
        initialAttach.lifetime = .keepAlways
        add(initialAttach)
        
        // Look for gear button by various means
        var foundGear = false
        
        // Try by SF Symbol name
        for identifier in ["gearshape", "gear", "Settings"] {
            let btn = app.buttons[identifier]
            if btn.exists {
                print("Found gear button with identifier: \(identifier) at \(btn.frame)")
                btn.tap()
                foundGear = true
                break
            }
        }
        
        if !foundGear {
            // Print all interactive elements
            print("\n=== ALL BUTTONS ===")
            for btn in app.buttons.allElementsBoundByIndex {
                print("  Button: '\(btn.label)' id='\(btn.identifier)' frame=\(btn.frame) exists=\(btn.exists)")
            }
            print("\n=== ALL TOOLBAR BUTTONS ===")
            for btn in app.toolbars.buttons.allElementsBoundByIndex {
                print("  Toolbar button: '\(btn.label)' id='\(btn.identifier)' frame=\(btn.frame)")
            }
            print("\n=== NAVIGATION BARS ===")
            for nb in app.navigationBars.allElementsBoundByIndex {
                print("  NavBar: '\(nb.label)' frame=\(nb.frame)")
                for btn in nb.buttons.allElementsBoundByIndex {
                    print("    NavBar button: '\(btn.label)' id='\(btn.identifier)' frame=\(btn.frame)")
                }
            }
            XCTFail("Could not find gear/settings button")
            return
        }
        
        sleep(2)
        
        print("\n=== SETTINGS HIERARCHY ===\n\(app.debugDescription)")
        
        // Screenshot settings
        let settingsShot = app.screenshot()
        let settingsAttach = XCTAttachment(screenshot: settingsShot)
        settingsAttach.name = "settings"
        settingsAttach.lifetime = .keepAlways
        add(settingsAttach)
        
        // Find iCloud section
        let icloudHeader = app.staticTexts["iCloud Sync"]
        if icloudHeader.exists {
            print("Found iCloud Sync section header at: \(icloudHeader.frame)")
        }
        
        // Find all static texts in the settings view
        print("\n=== SETTINGS STATIC TEXTS ===")
        for text in app.staticTexts.allElementsBoundByIndex {
            if text.frame.origin.y > 50 {
                print("  Text: '\(text.label)' frame=\(text.frame)")
            }
        }
        
        // Find all cells/rows
        print("\n=== SETTINGS CELLS ===")
        for cell in app.cells.allElementsBoundByIndex {
            print("  Cell: '\(cell.label)' frame=\(cell.frame)")
        }
    }
}
