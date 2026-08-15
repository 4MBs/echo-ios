# Live Note Context and Recording Subject Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep imported worksheets available to live AI answers, prevent import status from covering controls, and make the recording subject picker persist changes reliably during an active recording.

**Architecture:** The backend treats notes without an audio timestamp as lesson-wide context and supplies the already-existing subject-update endpoint from current `origin/main`. The iOS app presents import status in layout space and owns a cancellable retry loop for the active recording's manually selected subject.

**Tech Stack:** Python/FastAPI/SQLite backend, Swift 5/SwiftUI/Observation iOS app, Git worktrees.

## Global Constraints

- Do not run automated tests, manual runtime tests, builds, GitHub Actions, or the iOS Simulator.
- Preserve the user's dirty backend checkout and its `library/` directory.
- Commit and immediately push every completed change.
- Backend changes start from current `origin/main`; iOS changes stay on `feature/direct-goodnotes-import`.

---

### Task 1: Include lesson-wide imported notes in live answers

**Files:**

- Modify in isolated backend worktree: `src/mosslive/transcribe/store.py`

**Interfaces:**

- Consumes: `lesson_notes_context(base_dir, session_id, start_seconds:, end_seconds:, max_chars:) -> str`
- Produces: identical interface with `timing_source == "unpositioned"` exempt from time-window filtering.

- [ ] **Step 1: Create an isolated backend worktree from `origin/main`**

Use the repository's existing `.worktrees/` directory after confirming it is ignored. Create branch `fix/live-note-context` from `origin/main`. Do not modify, stash, reset, or clean the existing backend checkout.

- [ ] **Step 2: Correct context selection at the source**

Change the note loop to time-filter only positioned notes:

```python
for note in notes:
    offset = float(note["offset_seconds"])
    positioned = note["timing_source"] != "unpositioned"
    if positioned and start_seconds is not None and offset < start_seconds:
        continue
    if positioned and end_seconds is not None and offset > end_seconds:
        continue
```

Do not change storage offsets, prompt text, or the timestamp labels.

- [ ] **Step 3: Commit and push**

```bash
git add src/mosslive/transcribe/store.py
git commit -m "fix: keep unpositioned notes in live context"
git push -u origin fix/live-note-context
```

### Task 2: Persist subject changes throughout an active recording

**Files:**

- Modify: `Sources/MossLive/Model/AppModel.swift`
- Modify: `Sources/MossLive/Model/RecordingSubjectSelection.swift`

**Interfaces:**

- Produces: `recordingSubjectError: String?`
- Produces: `dismissRecordingSubjectError()`
- Produces: one cancellable retry task that retries every five seconds for the current session and subject.

- [ ] **Step 1: Add dedicated subject persistence state**

Add observable UI state for the error, a private persistence task, and a suppression flag for a manually dismissed error. Keep `bannerMessage` for unrelated recording notices.

- [ ] **Step 2: Keep a manual selection optimistic**

Do not call `RecordingSubjectSelection.rollBack()` after a failed request. A tap during recording must remain visible immediately. A new selection cancels the previous task, clears the old error and its dismissal flag, and starts persistence for the current `sessionId`.

- [ ] **Step 3: Retry the active selection**

Replace the one-shot persistence task with a loop whose invariants are:

```swift
while !Task.isCancelled,
      recordingStartedAt != nil,
      self.sessionId == sessionID,
      recordingSubjectSelection.selected == subject {
    do {
        _ = try await api.updateLessonSubject(sessionId: sessionID, subject: subject.name)
        recordingSubjectSelection.confirm(subject)
        recordingSubjectError = nil
        return
    } catch {
        if !subjectErrorWasDismissed {
            recordingSubjectError = "Das Fach konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(5))
    }
}
```

Session acknowledgement restarts persistence for the selected subject. Stopping the recording cancels the task and clears persistence UI state.

- [ ] **Step 4: Add manual dismissal**

`dismissRecordingSubjectError()` clears the visible error and suppresses it for the current selection while retries continue silently. Choosing a different subject resets suppression.

- [ ] **Step 5: Commit and push**

```bash
git add Sources/MossLive/Model/AppModel.swift Sources/MossLive/Model/RecordingSubjectSelection.swift
git commit -m "fix: persist subject changes during recording"
git push
```

### Task 3: Make recording notices non-blocking and dismissible

**Files:**

- Modify: `Sources/MossLive/Views/ContentView.swift`
- Modify: `Sources/MossLive/MossLiveApp.swift`

**Interfaces:**

- Consumes: `AppModel.recordingSubjectError`
- Consumes: `AppModel.dismissRecordingSubjectError()`
- Produces: compact import status occupying safe-area layout space instead of overlaying the toolbar.

- [ ] **Step 1: Present the dedicated subject error**

Include `recordingSubjectError` in `LiveView.hasNotices`. Render it as a red `NoticeBanner` with a close action.

- [ ] **Step 2: Add an optional top-right close control to `NoticeBanner`**

Extend the view with `var dismiss: (() -> Void)?`. When present, reserve trailing space and place an `xmark` button at the banner's top-right corner with accessibility label `Hinweis schließen`.

- [ ] **Step 3: Move incoming-file feedback out of the toolbar overlay**

Replace `MainTabView`'s `.overlay(alignment: .top)` status presentation with a compact `.safeAreaInset(edge: .bottom)` row. Constrain the banner width, reduce padding and line count, and retain retry/dismiss buttons. Because it consumes layout space, it must not intercept the recording toolbar or KI-Antwort control.

- [ ] **Step 4: Commit and push**

```bash
git add Sources/MossLive/Views/ContentView.swift Sources/MossLive/MossLiveApp.swift
git commit -m "fix: keep recording notices clear of controls"
git push
```

## Completion

Inspect only repository status and upstream divergence to confirm that intended files are committed and pushed. Do not compile or execute either application.
