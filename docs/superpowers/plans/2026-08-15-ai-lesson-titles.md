# KI-generierte Stundentitel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each recorded lesson's AI-generated topic as its primary title throughout the iOS app while retaining the subject as clearly identifiable context.

**Architecture:** Add one presentation extension for `BackendAPI.LessonInfo` that owns title, subject, metadata, and fallback selection. Existing lesson rows and pickers consume that extension instead of independently selecting `topic`, `title`, `subject`, or a date; the backend protocol remains unchanged.

**Tech Stack:** Swift 6, SwiftUI, XCTest, XcodeGen, SwiftFormat 0.55.5, SwiftLint 0.57.1

## Global Constraints

- A non-empty backend `topic` is always the primary displayed title.
- The subject remains visible or, in compact menus, is appended after the AI title.
- Old servers, old summaries, short recordings, and offline cached lessons retain honest fallbacks.
- No new backend request, API field, database migration, or manual renaming is added.
- Nothing is pushed to GitHub until the user has tested the finished feature and explicitly approves the push.

---

### Task 1: Central lesson presentation metadata

**Files:**
- Create: `Sources/MossLive/Model/LessonPresentation.swift`
- Modify: `Sources/MossLive/Views/SubjectView.swift`
- Modify: `Sources/MossLive/Views/LessonsView.swift`
- Test: `Tests/MossLiveTests/LessonPresentationTests.swift`

**Interfaces:**
- Consumes: `BackendAPI.LessonInfo`, `lessonTopic(from:)`, and `LessonInfo.startedAt`.
- Produces: `LessonInfo.displayTitle: String`, `displaySubject: String?`,
  `compactDisplayTitle: String`, `usesDateDisplayTitle: Bool`, and the existing
  `lessonTopic(from:)` fallback in a model-level source file accessible to every
  view.

- [ ] **Step 1: Write failing presentation-priority tests**

Create JSON-decoded fixtures because `LessonInfo` intentionally owns a custom decoder. Add tests proving:

```swift
XCTAssertEqual(aiLesson.displayTitle, "Ursachen der Revolution")
XCTAssertEqual(aiLesson.displaySubject, "Geschichte")
XCTAssertEqual(aiLesson.compactDisplayTitle, "Ursachen der Revolution · Geschichte")
XCTAssertEqual(oldSummaryLesson.displayTitle, "Ableitung von Polynomfunktionen")
XCTAssertEqual(unsummarizedLesson.displayTitle, "Mathematik")
XCTAssertNil(subjectlessLesson.displaySubject)
XCTAssertTrue(unnamedLesson.usesDateDisplayTitle)
```

Also cover whitespace-only `topic`, a timetable `title` distinct from `subject`, and the final localized-date fallback.

- [ ] **Step 2: Run the focused test target and verify RED**

Run on macOS or the configured iOS build runner:

```bash
xcodegen generate
xcodebuild test -project MossLive.xcodeproj -scheme MossLive \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:MossLiveTests/LessonPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because the new presentation properties do not exist.

- [ ] **Step 3: Implement the smallest central presentation extension**

Move `LessonTopic`, `lessonTopic(from:)`, and its parsing constants/helpers out of `SubjectView.swift` into `LessonPresentation.swift` without changing parsing behavior. Add an extension equivalent to:

```swift
extension BackendAPI.LessonInfo {
    var displayTitle: String {
        if let topic = nonEmpty(topic) { return topic }
        if let derived = lessonTopic(from: summaryExcerpt)?.headline { return derived }
        if let title = nonEmpty(title) { return title }
        if let subject = nonEmpty(subject) { return subject }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var displaySubject: String? {
        nonEmpty(subject) ?? nonEmpty(title)
    }

    var compactDisplayTitle: String {
        guard let displaySubject, displaySubject != displayTitle else { return displayTitle }
        return "\(displayTitle) · \(displaySubject)"
    }

    var usesDateDisplayTitle: Bool {
        nonEmpty(topic) == nil && lessonTopic(from: summaryExcerpt) == nil
            && nonEmpty(title) == nil && nonEmpty(subject) == nil
    }
}
```

Keep whitespace normalization private to this file. Preserve the current one-line topic length, abbreviation handling, and derived-summary detail behavior.

- [ ] **Step 4: Route subject-board rows and archive search through the shared rule**

In `SubjectLessonRow`, replace its duplicate `topic`/derived/date branching with
`info.displayTitle` and `info.usesDateDisplayTitle`, while retaining the current
excerpt detail and dated-fallback layout. Extend `LessonInfo.matches(_:)` so
`topic`, `summaryExcerpt`, and `displayTitle` are searchable alongside subject,
teacher, room, and timetable title.

- [ ] **Step 5: Run presentation and existing subject-board tests and verify GREEN**

```bash
xcodebuild test -project MossLive.xcodeproj -scheme MossLive \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:MossLiveTests/LessonPresentationTests \
  -only-testing:MossLiveTests/LessonTopicTests CODE_SIGNING_ALLOWED=NO
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit locally**

```bash
git add Sources/MossLive/Model/LessonPresentation.swift \
  Sources/MossLive/Views/SubjectView.swift Sources/MossLive/Views/LessonsView.swift \
  Tests/MossLiveTests/LessonPresentationTests.swift
git commit -m "feat: centralize AI lesson titles"
```

Do not push.

---

### Task 2: Apply AI titles to every recorded-lesson picker

**Files:**
- Modify: `Sources/MossLive/Views/ChatView.swift`
- Modify: `Sources/MossLive/Views/LearnView.swift`
- Modify: `Sources/MossLive/Views/LearnReviewView.swift`
- Modify: `Sources/MossLive/Testing/UITestRuntime.swift`
- Modify: `Tests/MossLiveUITests/LessonsUITests.swift`
- Test: `Tests/MossLiveTests/LessonPresentationTests.swift`

**Interfaces:**
- Consumes: `LessonInfo.displayTitle`, `displaySubject`, and `compactDisplayTitle` from Task 1.
- Produces: consistent AI-title-first labels in chat context selection, Learn lesson selection, and source presentation where lesson list metadata is available.

- [ ] **Step 1: Add failing picker UI assertions**

Extend `LessonsUITests` and the existing Learn picker UI test with assertions that
`"Ursache und Wirkung"` is visible and announced before `"Physik"`. Add a
`LessonPresentationTests` assertion that the compact label does not repeat an
identical fallback subject.

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
xcodebuild test -project MossLive.xcodeproj -scheme MossLive \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:MossLiveUITests/LessonsUITests \
  -only-testing:MossLiveUITests/LearnUITests CODE_SIGNING_ALLOWED=NO
```

Expected: the new picker assertion fails because at least one picker still
shows its old timetable title instead of the fixture's AI title.

- [ ] **Step 3: Update the Chat lesson-context menu**

Remove `ChatView.title(for:)`. Use `lesson.compactDisplayTitle` for both the menu button and `ChatStore.Context.lesson` title so conversation context reads `KI-Titel · Fach` and never falls back directly to the old timetable label while a topic exists.

- [ ] **Step 4: Update the Learn lesson picker**

Render `lesson.displayTitle` in `.headline`. Render `lesson.displaySubject` first in the secondary line, followed by the abbreviated date so both subject and recording identity remain visible. Combine the row for accessibility so VoiceOver announces title before subject.

- [ ] **Step 5: Keep Learn source labels honest**

Do not invent a topic from `LessonDetail`, whose wire model has no separate `topic`. Preserve the backend-provided `LearnSource.lessonTitle`; where a matching cached `LessonInfo` is available, pass its `displayTitle` and `displaySubject` into the source row. Otherwise retain `source.lessonTitle ?? detail.title ?? "Unterrichtsstunde"` as the compatibility fallback.

- [ ] **Step 6: Strengthen deterministic UI fixtures and assertions**

Ensure `UITestRuntime.allSessions` contains a lesson with
`topic = "Ursache und Wirkung"` and `subject = "Physik"`. Keep the new
`LessonsUITests` and `LearnUITests` assertions from Step 1 unchanged as the
end-to-end acceptance checks.

- [ ] **Step 7: Run focused unit and UI tests and verify GREEN**

```bash
xcodebuild test -project MossLive.xcodeproj -scheme MossLive \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:MossLiveTests/LessonPresentationTests \
  -only-testing:MossLiveUITests/LessonsUITests CODE_SIGNING_ALLOWED=NO
```

Expected: all selected tests pass and UI assertions find both the AI title and subject.

- [ ] **Step 8: Commit locally**

```bash
git add Sources/MossLive/Views/ChatView.swift Sources/MossLive/Views/LearnView.swift \
  Sources/MossLive/Views/LearnReviewView.swift Sources/MossLive/Testing/UITestRuntime.swift \
  Tests/MossLiveTests/LessonPresentationTests.swift Tests/MossLiveUITests/LessonsUITests.swift
git commit -m "feat: show AI titles across lesson pickers"
```

Do not push.

---

### Task 3: Full local verification and user test handoff

**Files:**
- Modify only files required to fix failures caused by Tasks 1–2.

**Interfaces:**
- Consumes: all implementation and tests from Tasks 1–2.
- Produces: a locally committed, linted feature ready for the user's device test; no remote changes.

- [ ] **Step 1: Verify SwiftFormat**

```bash
docker run --rm -v "$PWD:/work" ghcr.io/nicklockwood/swiftformat:0.55.5 \
  /work/Sources /work/Tests --lint
```

Expected: `0/… files require formatting` and exit code 0. If formatting is required, run the same image without `--lint`, inspect the diff, and rerun lint.

- [ ] **Step 2: Verify SwiftLint**

```bash
docker run --rm -v "$PWD:/repo" -w /repo ghcr.io/realm/swiftlint:0.57.1 \
  swiftlint --strict
```

Expected: no errors and exit code 0.

- [ ] **Step 3: Run the complete unit-test suite**

```bash
xcodegen generate
xcodebuild test -project MossLive.xcodeproj -scheme MossLive \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:MossLiveTests CODE_SIGNING_ALLOWED=NO
```

Expected: all unit tests pass with zero failures.

- [ ] **Step 4: Build the complete app**

```bash
xcodebuild build -project MossLive.xcodeproj -scheme MossLive \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Inspect final scope and commit verification fixes locally**

```bash
git diff --check
git status --short
git diff --stat origin/main...HEAD
```

Commit only necessary verification fixes with:

```bash
git add Sources/MossLive Tests/MossLiveTests Tests/MossLiveUITests
git commit -m "test: verify AI lesson title presentation"
```

- [ ] **Step 6: Hand off for user testing without pushing**

Report the exact local commits, test/build evidence, affected screens, and device-test steps. Wait for explicit user approval before `git push origin main`.
