# Reliable Reader Page Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the library reader's printed-page field focus on the first tap, use the full keyboard with a Done key, and dismiss reliably when Return or another reader surface is tapped.

**Architecture:** Keep one SwiftUI `TextField` mounted in `PDFReader` instead of swapping a button and field. Put input normalization and printed-to-PDF destination resolution in a tiny value-free model helper so unit tests can cover the rules without rendering SwiftUI; `PDFReader` continues to own focus, temporary text, navigation, and synchronization with the visible PDF page.

**Tech Stack:** Swift 5, SwiftUI, PDFKit, XCTest/XCUITest, XcodeGen, GitHub Actions on Xcode 26.5

## Global Constraints

- Keep the existing German label `Seitennummer` and the existing Liquid Glass capsule position.
- Use the full standard keyboard and expose `Fertig` with `.submitLabel(.done)`.
- Accept at most five decimal digits; invalid, zero, and out-of-range values do not move the book.
- Return and outside taps close the keyboard and restore the actual visible printed page.
- Outside-tap dismissal must not consume page turns, layout-menu actions, or PDF interaction.
- Do not change PDF rendering, printed-page offsets, Book AI, or region selection.
- Verify a Release device build and unsigned IPA before merging to `main`.

---

## File Map

- Create `Sources/MossLive/Model/ReaderPageEntry.swift`: pure normalization and destination resolution for page-entry text.
- Create `Tests/MossLiveTests/ReaderPageEntryTests.swift`: unit coverage for digit filtering, length, printed-page mapping, and invalid input.
- Modify `Sources/MossLive/Views/PDFReader.swift`: stable text field, focus lifecycle, full keyboard, Return action, and non-consuming dismissal calls.
- Modify `Tests/MossLiveUITests/LibraryReaderUITests.swift`: first-tap focus, full-keyboard Done key, Return dismissal, navigation, and PDF-canvas dismissal.

### Task 1: Extract and Test Page-Entry Rules

**Files:**
- Create: `Tests/MossLiveTests/ReaderPageEntryTests.swift`
- Create: `Sources/MossLive/Model/ReaderPageEntry.swift`

**Interfaces:**
- Consumes: `BookPageNumbering.pdfPage(forPrinted:) -> Int?`
- Produces: `ReaderPageEntry.sanitized(_ text: String) -> String`
- Produces: `ReaderPageEntry.destination(for text: String, numbering: BookPageNumbering) -> Int?`
- Produces: `ReaderPageEntry.restoredValue(forPDFPage pdfPage: Int, numbering: BookPageNumbering) -> String`

- [ ] **Step 1: Write the failing unit tests**

Create `Tests/MossLiveTests/ReaderPageEntryTests.swift`:

```swift
@testable import MossLive
import XCTest

final class ReaderPageEntryTests: XCTestCase {
    private let numbering = BookPageNumbering(offset: -4, pageCount: 320)

    func testSanitizingKeepsOnlyFiveDecimalDigits() {
        XCTAssertEqual(ReaderPageEntry.sanitized("a12-3456"), "12345")
        XCTAssertEqual(ReaderPageEntry.sanitized(""), "")
    }

    func testDestinationUsesTheBooksPrintedPageMapping() {
        XCTAssertEqual(
            ReaderPageEntry.destination(for: "12", numbering: numbering),
            16
        )
    }

    func testInvalidOrOutOfRangeInputHasNoDestination() {
        XCTAssertNil(ReaderPageEntry.destination(for: "", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "0", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "317", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "12a", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "123456", numbering: numbering))
    }

    func testRestoredValueReflectsTheActuallyVisiblePrintedPage() {
        XCTAssertEqual(
            ReaderPageEntry.restoredValue(forPDFPage: 16, numbering: numbering),
            "12"
        )
    }
}
```

- [ ] **Step 2: Commit the test, run it, and verify RED**

Commit and push the test without an implementation, then run:

```bash
git add Tests/MossLiveTests/ReaderPageEntryTests.swift
git commit -m "test: define reader page entry rules"
git push -u origin feature/reliable-reader-page-entry
gh workflow run ci.yml --ref feature/reliable-reader-page-entry -f run_unit_tests=true
gh run watch --exit-status
```

Expected: the test target fails to compile because `ReaderPageEntry` does not exist.

- [ ] **Step 3: Implement the minimal pure helper**

Create `Sources/MossLive/Model/ReaderPageEntry.swift`:

```swift
import Foundation

enum ReaderPageEntry {
    static func sanitized(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(5))
    }

    static func destination(
        for text: String,
        numbering: BookPageNumbering
    ) -> Int? {
        guard text == sanitized(text), let printed = Int(text) else { return nil }
        return numbering.pdfPage(forPrinted: printed)
    }

    static func restoredValue(
        forPDFPage pdfPage: Int,
        numbering: BookPageNumbering
    ) -> String {
        numbering.printedLabel(pdfPage)
    }
}
```

- [ ] **Step 4: Commit the helper and verify GREEN**

Commit and push the helper, then dispatch `ci.yml` with `run_unit_tests=true` again:

```bash
git add Sources/MossLive/Model/ReaderPageEntry.swift
git commit -m "feat: validate reader page entry"
git push
gh workflow run ci.yml --ref feature/reliable-reader-page-entry -f run_unit_tests=true
gh run watch --exit-status
```

Expected: all `ReaderPageEntryTests` pass and the Release device build succeeds.

### Task 2: Make the Page Field Stable and Dismissible

**Files:**
- Modify: `Sources/MossLive/Views/PDFReader.swift:44-118`
- Modify: `Sources/MossLive/Views/PDFReader.swift:368-528`

**Interfaces:**
- Consumes: `ReaderPageEntry.sanitized(_:)` and `ReaderPageEntry.destination(for:numbering:)`
- Produces: `PDFReader.endPageEntry()`, which removes focus and synchronizes `typedPage` with `printedLabel(currentPage)`
- Produces: one always-mounted text field with accessibility identifier/label `Seitennummer`

- [ ] **Step 1: Write the failing first-tap UI expectation**

In `testShelfReaderNavigationLayoutPageJumpAndRename`, resolve the stable field immediately after opening the reader, capture its initial value, and use that value instead of querying the removed page-indicator button when checking the first arrow turn:

```swift
let pageField = app.textFields["Seitennummer"]
XCTAssertTrue(
    pageField.waitForExistence(timeout: 3),
    "The mounted page field is unavailable before the first tap"
)
let initialPage = pageField.value as? String
tap(app.buttons["Nächste Seite"])
let turned = XCTNSPredicateExpectation(
    predicate: NSPredicate(format: "value != %@", initialPage ?? "1"),
    object: pageField
)
XCTAssertEqual(
    XCTWaiter.wait(for: [turned], timeout: 5),
    .completed,
    "The page never turned"
)
```

At the existing page-jump section, replace the conditional page-button opening sequence with a direct single tap on that same field:

```swift
tap(pageField)
XCTAssertTrue(
    app.keyboards.firstMatch.waitForExistence(timeout: 3),
    "A single tap did not focus the page field"
)
XCTAssertTrue(
    app.keyboards.buttons["Fertig"].waitForExistence(timeout: 3),
    "The page field still uses the number pad without a Done key"
)
```

Do not yet alter `PDFReader`. Commit and push the UI-test-only change, then run:

```bash
git add Tests/MossLiveUITests/LibraryReaderUITests.swift
git commit -m "test: require stable reader page field"
git push
gh workflow run ui-tests.yml --ref feature/reliable-reader-page-entry -f test_class=LibraryReaderUITests
gh run watch --exit-status
```

Expected: failure at `The mounted page field is unavailable before the first tap`, proving the current button/conditional-field behavior.

- [ ] **Step 2: Replace conditional state with one focus lifecycle**

In `PDFReader`, delete `askingForPage` and `openedAt`, initialize the stable display text, and keep `pageFieldFocused`:

```swift
@State private var typedPage = "1"
@FocusState private var pageFieldFocused: Bool
```

Replace the `askingForPage`, focus, and duplicate keyboard-hide observers with:

```swift
.onChange(of: pageFieldFocused) { _, focused in
    if focused {
        typedPage = ""
    } else {
        synchronizePageEntry()
    }
}
.onChange(of: currentPage) {
    guard !pageFieldFocused else { return }
    synchronizePageEntry()
}
.onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
    endPageEntry()
}
```

Add these methods next to `printedLabel(_:)`:

```swift
private func synchronizePageEntry() {
    typedPage = ReaderPageEntry.restoredValue(
        forPDFPage: currentPage,
        numbering: numbering
    )
}

private func endPageEntry() {
    pageFieldFocused = false
    synchronizePageEntry()
}
```

- [ ] **Step 3: Replace the button/conditional field pair with one mounted field**

Delete `pageIndicator` and replace `pageJump` with:

```swift
private var pageJump: some View {
    HStack(spacing: 4) {
        TextField(printedLabel(currentPage), text: $typedPage)
            .multilineTextAlignment(.trailing)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .frame(width: 36)
            .keyboardType(.default)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($pageFieldFocused)
            .onSubmit(endPageEntry)
            .accessibilityLabel("Seitennummer")
            .accessibilityValue(printedLabel(currentPage))

        Text("/ \(printedLast)")
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 42, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .glassEffect(.regular.interactive(), in: Capsule())
    .onChange(of: typedPage) { _, text in
        let digits = ReaderPageEntry.sanitized(text)
        if digits != text {
            typedPage = digits
            return
        }
        guard pageFieldFocused,
              let pdfPage = ReaderPageEntry.destination(for: digits, numbering: numbering),
              pdfPage != currentPage
        else { return }
        proxy.go(toPage: pdfPage)
    }
}
```

In `pageControls`, render `pageJump` unconditionally. Make both arrow actions call `endPageEntry()` before `proxy.step(_:)`, and remove the animation keyed to `askingForPage`.

- [ ] **Step 4: Add non-consuming outside-tap dismissal**

Make the control-bar background tappable without covering its controls:

```swift
.background {
    Color.black
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: endPageEntry)
}
```

Attach a simultaneous tap to `modeToggle` so its menu still opens while editing ends:

```swift
.simultaneousGesture(TapGesture().onEnded { endPageEntry() })
```

Keep `BookPDFView.readerInteractionBegan(_:)` and `tappedOutsideSelection(_:)` unchanged: their non-cancelling PDF pan/tap callbacks resign the first responder, and the `pageFieldFocused` observer restores the actual visible page.

- [ ] **Step 5: Run static checks before remote compilation**

```bash
rg -n "askingForPage|openedAt|keyboardType\(\.numberPad\)" Sources/MossLive/Views/PDFReader.swift
git diff --check
```

Expected: no `askingForPage` or `openedAt`; `.numberPad` remains only in the separate printed-numbering editor, not in `pageJump`; `git diff --check` prints nothing.

- [ ] **Step 6: Commit and verify unit/build GREEN**

```bash
git add Sources/MossLive/Views/PDFReader.swift
git commit -m "fix: stabilize reader page entry"
git push
gh workflow run ci.yml --ref feature/reliable-reader-page-entry -f run_unit_tests=true
gh run watch --exit-status
```

Expected: unit tests pass, Release device compilation passes, and CI uploads `MossLive-unsigned.ipa`.

### Task 3: Verify Return and Outside-Tap Behavior End to End

**Files:**
- Modify: `Tests/MossLiveUITests/LibraryReaderUITests.swift:5-67`

**Interfaces:**
- Consumes: mounted `Seitennummer` field, `Fertig` keyboard key, PDF canvas dismissal, and printed-page accessibility value
- Produces: regression coverage for one-tap focus, Return dismissal, page navigation, and outside-tap dismissal

- [ ] **Step 1: Complete the Return-path UI assertions**

After the first-tap assertions from Task 2, enter and submit page 5:

```swift
pageField.typeText("5")
tap(app.keyboards.buttons["Fertig"])
XCTAssertTrue(
    app.keyboards.firstMatch.waitForNonExistence(timeout: 3),
    "Return did not close the keyboard"
)
let atFive = XCTNSPredicateExpectation(
    predicate: NSPredicate(format: "value == '5'"),
    object: pageField
)
XCTAssertEqual(
    XCTWaiter.wait(for: [atFive], timeout: 5),
    .completed,
    "The page jump never arrived at printed page 5"
)
```

This replaces the old assertion that searched for a page-indicator button, because the control is now always a text field.

- [ ] **Step 2: Add the outside-tap dismissal assertion**

Immediately after the page-5 screenshot, reopen the same field and tap the PDF canvas:

```swift
tap(pageField)
XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
XCTAssertTrue(
    app.keyboards.firstMatch.waitForNonExistence(timeout: 3),
    "Tapping the PDF did not close the keyboard"
)
XCTAssertEqual(pageField.value as? String, "5")
```

Keep the existing rename, page-numbering, Book AI, offline, layout, and gesture assertions unchanged.

- [ ] **Step 3: Run the focused iPad UI suite**

```bash
git add Tests/MossLiveUITests/LibraryReaderUITests.swift
git commit -m "test: cover reliable reader page editing"
git push
gh workflow run ui-tests.yml --ref feature/reliable-reader-page-entry -f test_class=LibraryReaderUITests
gh run watch --exit-status
```

Expected: every `LibraryReaderUITests` test passes on the iPad simulator, including first-tap focus, `Fertig`, Return dismissal, page 5, canvas dismissal, layout switching, renaming, and region gestures.

- [ ] **Step 4: Run final Release/IPA verification**

Dispatch `ci.yml` one final time with unit tests enabled, wait for success, and download its unsigned IPA:

```bash
gh workflow run ci.yml --ref feature/reliable-reader-page-entry -f run_unit_tests=true
gh run watch --exit-status
reader_run_id=$(gh run list --workflow ci.yml --branch feature/reliable-reader-page-entry --status success --limit 1 --json databaseId --jq '.[0].databaseId')
reader_run_number=$(gh run view "$reader_run_id" --json number --jq '.number')
gh run download "$reader_run_id" --name "MossLive-unsigned-ipa-$reader_run_number" --dir ../artifacts/reader-page-entry
sha256sum ../artifacts/reader-page-entry/MossLive-unsigned.ipa
```

Record the exact workflow run URL, run number, artifact path, and SHA-256 in the handoff. Do not merge to `main` until the user has tested and explicitly approves the push/merge.

- [ ] **Step 5: Review the final diff and commit history**

```bash
git diff origin/main...HEAD --check
git status --short --branch
git log --oneline origin/main..HEAD
```

Expected: no whitespace errors, a clean feature branch, and only the design, plan, input helper/tests, `PDFReader`, and `LibraryReaderUITests` commits.
