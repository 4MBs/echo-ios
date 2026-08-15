# Recording Subject and Concept Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent, WebUntis-backed subject selection for complete recordings and archived lessons, plus deletion of individual learning concepts.

**Architecture:** The backend owns validated subject overrides and card deletion, while iOS owns pending recording selection and sends it once a session ID exists. A reusable SwiftUI subject menu consumes the cached WebUntis catalogue in both recording and archive contexts; automatic timetable labelling respects persisted manual overrides.

**Tech Stack:** Python 3.12, FastAPI/Starlette, SQLite, pytest, Swift 6, SwiftUI Observation, Swift Testing/XCTest, Swift Package Manager

## Global Constraints

- A subject change during recording applies to the entire recording and never splits it.
- Manual subject selection always wins over later WebUntis refreshes and finalization.
- Subject choices come from the distinct WebUntis subject catalogue; cached catalogue data is allowed offline.
- Preserve transcript, audio, timestamps, AI topic and AI summary when changing a subject.
- Shared learning cards are not reclassified when only one source lesson changes subject.
- Concept deletion is global and requires confirmation in the concept library.
- All user-facing copy and accessibility labels are German.
- Do not push changes until the user has tested and explicitly approved the push.

---

### Task 1: Persist Manual Session Subject Overrides

**Files:**
- Modify: `backend/src/mosslive/transcribe/store.py`
- Test: `backend/tests/test_store.py`
- Test: `backend/tests/test_timetable_split.py`

**Interfaces:**
- Produces: `set_session_subject(base_dir: Path, session_id: str, subject: str) -> dict | None`
- Produces: `session_has_subject_override(base_dir: Path, session_id: str) -> bool`
- Changes: `label_session(..., respect_subject_override: bool = False) -> None`

- [ ] **Step 1: Write failing store tests**

Add tests that create a session, call `set_session_subject`, assert `subject`, `title`, and `subject_overridden == 1`, then call automatic `label_session(..., respect_subject_override=True)` and assert the manual subject remains. Also assert an unknown session returns `None`.

```python
updated = store.set_session_subject(tmp_path, session_id, "Biologie")
assert updated["subject"] == "Biologie"
assert store.session_has_subject_override(tmp_path, session_id)
store.label_session(tmp_path, session_id, "Mathematik", "Mathematik", respect_subject_override=True)
assert store.get_session(tmp_path, session_id)["subject"] == "Biologie"
```

- [ ] **Step 2: Run tests and verify RED**

Run: `uv run pytest tests/test_store.py tests/test_timetable_split.py -q`
Expected: FAIL because the override APIs and schema column do not exist.

- [ ] **Step 3: Add the migration-safe column and minimal store functions**

Extend the session schema migration with `subject_overridden INTEGER NOT NULL DEFAULT 0`. Implement the two functions, set `title` and `subject` to the selected display name without touching topic, summary, audio or timestamps, and make automatic labelling return without changes when `respect_subject_override` is true and the marker is set.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `uv run pytest tests/test_store.py tests/test_timetable_split.py -q`
Expected: PASS.

- [ ] **Step 5: Commit backend store changes**

```bash
git add src/mosslive/transcribe/store.py tests/test_store.py tests/test_timetable_split.py
git commit -m "feat: persist recording subject overrides"
```

### Task 2: Add Authenticated Session Subject API and Learning Propagation

**Files:**
- Modify: `backend/src/mosslive/learn.py`
- Modify: `backend/src/mosslive/server.py`
- Test: `backend/tests/test_learn.py`
- Test: `backend/tests/test_integration.py`

**Interfaces:**
- Produces: `update_subject_for_session(base_dir: Path, session_id: str, subject: str) -> int`
- Produces: `PATCH /sessions/{session_id}/subject` with JSON `{ "subject": String }`
- Consumes: Task 1 `set_session_subject` and `session_has_subject_override`

- [ ] **Step 1: Write failing propagation and endpoint tests**

Test that one-source cards adopt the new subject, multi-source cards keep their old subject, unauthorized requests return `401`, unknown sessions return `404`, and subjects absent from `timetable.subjects()` return `422`.

```python
response = client.patch(
    f"/sessions/{session_id}/subject",
    headers=auth,
    json={"subject": "Biologie"},
)
assert response.status_code == 200
assert response.json()["session"]["subject"] == "Biologie"
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `uv run pytest tests/test_learn.py tests/test_integration.py -q`
Expected: FAIL with missing function/route.

- [ ] **Step 3: Implement catalogue validation and propagation**

Normalize the requested value only for comparison, resolve it to the catalogue's canonical display name, call `set_session_subject`, and update cards only when their `concept_sources` count is exactly one. Change finalization to call `label_session(..., respect_subject_override=True)` and prevent timetable splitting when the parent session has a manual override.

- [ ] **Step 4: Run focused and regression tests**

Run: `uv run pytest tests/test_learn.py tests/test_integration.py tests/test_timetable_split.py -q`
Expected: PASS.

- [ ] **Step 5: Commit backend API changes**

```bash
git add src/mosslive/learn.py src/mosslive/server.py tests/test_learn.py tests/test_integration.py tests/test_timetable_split.py
git commit -m "feat: update lesson subjects through api"
```

### Task 3: Delete Individual Learning Concepts

**Files:**
- Modify: `backend/src/mosslive/learn.py`
- Modify: `backend/src/mosslive/server.py`
- Test: `backend/tests/test_learn.py`
- Test: `backend/tests/test_integration.py`

**Interfaces:**
- Produces: `delete_card(base_dir: Path, card_id: str) -> bool`
- Produces: `DELETE /learn/cards/{card_id}` returning `{ "ok": true }`

- [ ] **Step 1: Write failing atomic deletion tests**

Create a card with multiple sources and attempts, delete it, and assert the card, all `concept_sources`, and all `attempts` rows are gone. Test `401` and `404` endpoint responses.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `uv run pytest tests/test_learn.py tests/test_integration.py -q`
Expected: FAIL because deletion is not implemented.

- [ ] **Step 3: Implement transactional card deletion**

Within one SQLite transaction, verify the card exists, delete its attempts and source mappings, then delete the card. Expose it behind the existing authorization check.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `uv run pytest tests/test_learn.py tests/test_integration.py -q`
Expected: PASS.

- [ ] **Step 5: Commit backend concept deletion**

```bash
git add src/mosslive/learn.py src/mosslive/server.py tests/test_learn.py tests/test_integration.py
git commit -m "feat: delete individual learning concepts"
```

### Task 4: Add iOS API and Recording Subject State

**Files:**
- Create: `ios/Sources/MossLive/Network/BackendAPI+LessonSubject.swift`
- Create: `ios/Sources/MossLive/Model/RecordingSubjectSelection.swift`
- Modify: `ios/Sources/MossLive/Network/BackendAPI+Learn.swift`
- Modify: `ios/Sources/MossLive/Model/AppModel.swift`
- Test: `ios/Tests/MossLiveTests/RecordingSubjectSelectionTests.swift`
- Test: `ios/Tests/MossLiveTests/BackendAPITests.swift`

**Interfaces:**
- Produces: `BackendAPI.updateLessonSubject(sessionId:subject:) async throws -> LessonInfo`
- Produces: `BackendAPI.deleteLearnCard(id:) async throws`
- Produces: `RecordingSubjectSelection` with `catalogue`, `selected`, `confirmed`, `isManual`, and session-ID-aware persistence

- [ ] **Step 1: Write failing model and request tests**

Cover current-Untis preselection, last-choice fallback, manual precedence, deduplication, queued update until `sessionId` arrives, and rollback/banner state after a failed request.

```swift
selection.refresh(catalogue: subjects, current: biologyLesson)
#expect(selection.selected?.name == "Biologie")
selection.choose(math)
selection.refresh(catalogue: subjects, current: biologyLesson)
#expect(selection.selected?.name == "Mathematik")
```

- [ ] **Step 2: Run iOS tests and verify RED**

Run from `ios` on macOS: `xcodebuild test -project MossLive.xcodeproj -scheme MossLive -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:MossLiveTests/RecordingSubjectSelectionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL because the selection model and API functions do not exist.

- [ ] **Step 3: Implement minimal state and API clients**

Keep request creation in the API extensions. Load live subjects with `OfflineCache.Key.timetableSubjects`, fall back to cached data, persist the last selected stable subject key, and call the subject endpoint from `AppModel` after hello acknowledgement and on later changes.

- [ ] **Step 4: Run tests and verify GREEN**

Run from `ios` on macOS: `xcodebuild test -project MossLive.xcodeproj -scheme MossLive -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:MossLiveTests/RecordingSubjectSelectionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 5: Commit iOS state/API changes locally**

```bash
git add Sources/MossLive/Network Sources/MossLive/Model Tests/MossLiveTests
git commit -m "feat: manage recording subject selection"
```

### Task 5: Add Recording and Archived Lesson Subject UI

**Files:**
- Create: `ios/Sources/MossLive/Views/LessonSubjectPicker.swift`
- Modify: `ios/Sources/MossLive/Views/ContentView.swift`
- Modify: `ios/Sources/MossLive/Views/SubjectView.swift`
- Modify: `ios/Sources/MossLive/Testing/UITestRuntime.swift`
- Modify: `ios/Tests/MossLiveUITests/MossLiveUITests.swift`

**Interfaces:**
- Produces: reusable `LessonSubjectPicker(subjects:selection:label:)`
- Consumes: Task 4 recording selection and subject update API

- [ ] **Step 1: Write failing UI tests**

Assert a `recording-subject-picker` exists left of `record-button`, remains enabled in the recording fixture, exposes catalogue subjects, and that an archived lesson's menu contains `Fach ändern`.

- [ ] **Step 2: Run UI tests and verify RED**

Run from `ios` on macOS: `xcodebuild test -project MossLive.xcodeproj -scheme MossLiveUITests -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:MossLiveUITests/MossLiveUITests/testRecordingSubjectSelection -only-testing:MossLiveUITests/MossLiveUITests/testArchivedLessonSubjectChange CODE_SIGNING_ALLOWED=NO`
Expected: FAIL because the controls do not exist.

- [ ] **Step 3: Implement the reusable picker and both presentations**

Use a compact `Menu` beside the 108-point record control. Use item-driven sheet state for archived editing, show persistence progress, disable only while that exact update is being sent, and refresh/archive-move only after confirmed success.

- [ ] **Step 4: Build and run UI tests**

Run from `ios` on macOS: `xcodebuild build -project MossLive.xcodeproj -scheme MossLive -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`, then repeat the focused `xcodebuild test` command from Step 2.
Expected: build and tests PASS.

- [ ] **Step 5: Commit iOS subject UI locally**

```bash
git add Sources/MossLive/Views Sources/MossLive/Testing Tests/MossLiveUITests
git commit -m "feat: add lesson subject controls"
```

### Task 6: Add Learn Concept Deletion UI

**Files:**
- Modify: `ios/Sources/MossLive/Views/LearnView.swift`
- Modify: `ios/Sources/MossLive/Testing/UITestRuntime.swift`
- Modify: `ios/Tests/MossLiveUITests/MossLiveUITests.swift`

**Interfaces:**
- Consumes: Task 4 `BackendAPI.deleteLearnCard(id:)`

- [ ] **Step 1: Write failing UI test**

Open `Gelernte Konzepte`, invoke the destructive action, assert the German global-deletion warning, confirm it, and assert the concept disappears while another remains.

- [ ] **Step 2: Run the focused UI test and verify RED**

Run from `ios` on macOS: `xcodebuild test -project MossLive.xcodeproj -scheme MossLiveUITests -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:MossLiveUITests/MossLiveUITests/testLearnConceptDeletion CODE_SIGNING_ALLOWED=NO`
Expected: FAIL because no delete action exists.

- [ ] **Step 3: Implement confirmation and refresh**

Add swipe and context-menu actions that set one optional card as the deletion target. Present a single confirmation dialog, call the API, remove the card only after success, refresh overview/cards, and show a retryable error on failure.

- [ ] **Step 4: Run build and UI tests**

Run from `ios` on macOS: `xcodebuild build -project MossLive.xcodeproj -scheme MossLive -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`, then repeat the focused `xcodebuild test` command from Step 2.
Expected: PASS.

- [ ] **Step 5: Commit iOS deletion UI locally**

```bash
git add Sources/MossLive/Views/LearnView.swift Sources/MossLive/Testing/UITestRuntime.swift Tests/MossLiveUITests/MossLiveUITests.swift
git commit -m "feat: remove learning concepts"
```

### Task 7: Full Verification and User Test Handoff

**Files:**
- Modify only if verification exposes a tested defect.

**Interfaces:**
- Verifies every interface produced by Tasks 1–6.

- [ ] **Step 1: Run backend verification**

Run: `uv run pytest -q` from `backend`.
Expected: all tests PASS.

- [ ] **Step 2: Run iOS unit and formatting verification**

Run from `ios` on macOS: `xcodebuild test -project MossLive.xcodeproj -scheme MossLive -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO`. Run formatting on any Docker host: `docker run --rm -v "$PWD:/work" ghcr.io/nicklockwood/swiftformat:0.55.5 /work/Sources /work/Tests --lint`.
Expected: all tests and formatting checks PASS.

- [ ] **Step 3: Run release-compatible iOS build and UI suite**

Run from `ios` on macOS: `xcodebuild build -project MossLive.xcodeproj -scheme MossLive -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/dd -clonedSourcePackagesDirPath .spm-packages CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`. Then run: `xcodebuild test -project MossLive.xcodeproj -scheme MossLiveUITests -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -clonedSourcePackagesDirPath .spm-packages -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 600 CODE_SIGNING_ALLOWED=NO`.
Expected: build and tests PASS.

- [ ] **Step 4: Inspect repository scope**

Run: `git -C backend status --short` and `git -C ios status --short --branch`.
Expected: only intentional commits/known pre-existing backend working-tree changes; no generated artifacts staged.

- [ ] **Step 5: Hand off without pushing**

Report exact test results, changed commits and manual test steps. Wait for explicit user approval before any `git push`.
