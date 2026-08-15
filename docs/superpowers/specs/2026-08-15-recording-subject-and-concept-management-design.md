# Recording Subject and Concept Management Design

## Goal

Echo lets the user choose and correct the subject of a recording at any time, while still using WebUntis for a useful default. The same subject catalogue is available for archived lessons. Individual learning concepts can be removed from the Learn tab.

## Recording Subject Selection

The recording area shows a compact subject menu directly to the left of the record button. Its options are the distinct subjects returned by the existing WebUntis subject catalogue endpoint. Duplicate subjects are collapsed using their stable subject identity, and the displayed names follow the existing timetable presentation.

When the recording screen becomes ready for a new recording, the app preselects the subject of the current WebUntis lesson when that subject exists in the catalogue. If there is no current lesson, it keeps the user's most recently selected catalogue subject. If neither value exists, the control shows that no subject has been selected and requires a choice before recording starts. A temporary WebUntis or network failure may use the locally cached subject catalogue.

The user can change the subject before or during recording. Once the user has chosen a subject manually for the pending or active recording, later timetable refreshes do not replace it. A change made during recording applies retroactively to the entire recording; it does not split the recording and does not create a second lesson.

## Persistent Subject Override

The backend provides one authenticated session-subject update operation that works for active and archived sessions. It validates the requested subject against the WebUntis-derived subject catalogue and stores an explicit manual-override marker with the session.

For an active recording, the iOS app sends the selected subject as soon as the server has assigned a session ID. If the user changes the selection afterward, the app sends another update. A choice made before the session ID arrives is queued in app state and applied after the WebSocket hello acknowledgement.

Automatic timetable labelling at recording finalization respects the manual-override marker and cannot overwrite the selected subject. The recording keeps its transcript, AI topic, AI summary, audio and timestamps. Its lesson title is regenerated or presented using the corrected subject and existing AI topic rules; changing the subject does not discard the AI-generated content title.

If persistence fails, the selector remains on the last confirmed value and the app shows an error. The user can retry the selection. The UI must not claim that an unconfirmed subject was saved.

## Archived Lesson Subject Editing

Every recorded lesson's three-dot context menu in the Hours tab gains a `Fach ändern` action. It opens the same WebUntis-derived subject catalogue used by the recording control. Saving calls the shared backend subject-update operation and refreshes the lesson lists.

After a successful change, the lesson disappears from the old subject folder and appears in the new one. Existing learning cards sourced only from that lesson adopt the corrected subject. Cards shared by multiple source lessons retain their existing subject classification so that changing one source cannot silently reclassify unrelated material.

## Learning Concept Deletion

Each concept in the Learn tab's concept library gains a destructive `Konzept löschen` action. The app asks for confirmation before deletion. Confirming calls a new authenticated endpoint that deletes the selected card and its source mappings and review history atomically, then refreshes the Learn overview and lists.

Deletion is global for that concept card, including concepts with multiple lesson sources. The confirmation text makes this explicit. This version does not add deletion controls inside an active review session; deletion is performed from the concept library.

## Backend Boundaries

The transcript store owns session subject metadata and the manual-override flag. Timetable finalization asks the store whether a manual override exists before applying automatic labels. The learning store owns card deletion and the narrowly scoped propagation of archived lesson subject changes.

Both mutation endpoints require the existing authentication mechanism. They return `404` for unknown identifiers, `422` for invalid or unavailable catalogue subjects, and a successful representation of the changed resource on completion.

## iOS State and UI Boundaries

`AppModel` owns the pending/active recording subject because it spans the recording screen, WebSocket connection lifecycle and backend persistence. A focused reusable SwiftUI subject picker renders the catalogue for both the recording area and archived-lesson editing. The existing timetable store remains responsible only for current/next lesson polling and does not overwrite manual recording state.

The Learn view owns its selected deletion target and confirmation presentation. Network request construction stays in `BackendAPI` extensions, not in SwiftUI view bodies.

All new controls receive German accessibility labels and stable UI-test identifiers.

## Testing

Backend tests cover subject validation, active and archived updates, manual override survival through timetable finalization, lesson movement metadata, single-source learning-card propagation, shared-card preservation, authenticated access, missing sessions and atomic concept deletion.

iOS unit tests cover automatic current-lesson selection, fallback to the last manual choice, manual-selection precedence over timetable refresh, queued persistence before a session ID and rollback after an update failure. UI tests cover the picker beside the record button, subject changes during recording, `Fach ändern` in an archived lesson menu and confirmed concept deletion.

The final verification runs the complete backend test suite, iOS unit tests, Swift formatting checks and a release-compatible iOS build. No changes are pushed to GitHub until the user has tested and explicitly approves the push.
