# Live Note Context and Recording Subject Reliability

## Scope

This change corrects three connected recording-screen failures:

1. A document imported during a recording must remain usable by the live AI answer button.
2. Import status must not obscure the AI answer button or other recording controls.
3. The subject picker beside the record button must change the subject while the recording is already running, including across temporary backend or network failures.

No Simulator, automated tests, manual runtime tests, or unrelated validation will be run by the agent. The user will test the result.

## Imported document context

Imported pages with an actual Goodnotes modification timestamp retain their existing time-window behavior. Pages without a trustworthy audio timestamp are lesson-wide context, not content at second zero. The backend therefore includes `unpositioned` notes regardless of the live answer window while continuing to filter positioned pages by the requested time range.

This fixes the issue at the context-selection boundary and avoids resending document text from the iOS app or inventing a false timestamp.

## Import status placement

The incoming-document coordinator remains global because files can arrive on any tab. Its status presentation moves out of the top overlay that can cover toolbar actions. A compact safe-area status row occupies its own layout space and uses shorter text, so it cannot intercept the AI answer button.

Success remains dismissible. Retry remains available for failed imports.

## Subject changes during an active recording

The subject menu remains enabled throughout recording whenever its WebUntis-derived catalogue is available. Selecting a subject updates the visible selection immediately and starts persistence for the active session.

The app keeps the chosen subject instead of rolling back after the first failed request. While the same recording and selection remain active, it retries the backend update every five seconds. A newer manual selection cancels the older retry loop. Reconnection and the arrival of a new session ID also restart persistence for the current selection.

Success confirms the selection and removes its error. Stopping the recording cancels pending persistence.

## Subject error presentation

Subject persistence errors use dedicated state rather than the generic recording banner. The message updates after each attempt, clears immediately after a successful retry, and has a top-right close button. Closing it suppresses repeat presentation for the current selection while background retries continue; choosing another subject permits a new relevant error to appear.

## Backend version requirement

The local backend checkout is four commits behind `origin/main`; those commits contain the authenticated session-subject endpoint and manual-override persistence required by the existing iOS picker. Backend work will be based on current `origin/main` in an isolated worktree so the user's existing line-ending changes and local library data are not touched.

The lesson-wide unpositioned-note context correction will be committed and pushed separately to the backend repository. The iOS UI and retry corrections will be committed and pushed to the existing `feature/direct-goodnotes-import` branch.
