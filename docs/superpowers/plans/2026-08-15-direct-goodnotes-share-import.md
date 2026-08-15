# Direct Goodnotes Share Import — Implementation Plan

> Constraint: Do not run tests, builds, GitHub Actions, or the iOS Simulator while implementing this feature. The user will test it themselves.

## Goal

Open Echo directly when a supported Goodnotes/Notability/PDF/image document is shared, attach it automatically to an active recording, and otherwise let the user choose a recorded lesson. Support both a normally installed IPA and LiveContainer 3.8.5.

## Task 1: Register Echo as a document destination

**Files:**

- Modify: `project.yml`
- Modify: `Sources/Shared/PendingNoteImports.swift`

Add the `echo` URL scheme, document type declarations for `.goodnotes`, `.note`, PDF, PNG, and JPEG, and imported UTI declarations for the two proprietary filename extensions. This lets LiveContainer offer Echo as a guest app when its share extension receives a supported file.

Extend `PendingNoteImports` so the main application can fall back to its own Application Support directory when an App Group is unavailable. Keep the share extension strict: it must still require the shared App Group because extension-private storage is inaccessible to the main app. Add lookup by stable inbox ID for deep links.

Commit and immediately push these changes.

## Task 2: Centralize local note imports

**Files:**

- Create: `Sources/MossLive/Notes/LessonNoteImportService.swift`
- Modify: `Sources/MossLive/Network/BackendAPI+Notes.swift`
- Modify: `Sources/MossLive/Views/ImportedLessonNotesView.swift`

Create one service that invokes `LocalNoteImporter`, uploads only extracted text and timestamps, and returns combined warnings. Let callers provide the pending item's stable UUID as `import_id`, preventing a retry from creating a second import.

Use this service from the existing manual and pending-import screen so manual file picking and external sharing follow the same privacy and parsing path.

Commit and immediately push these changes.

## Task 3: Route incoming files in the main app

**Files:**

- Create: `Sources/MossLive/Notes/IncomingNoteImportCoordinator.swift`
- Create: `Sources/MossLive/Views/IncomingNoteDestinationView.swift`
- Modify: `Sources/MossLive/MossLiveApp.swift`

Accept both `echo://note-import/<id>` URLs and security-scoped file URLs. Copy file URLs into Echo's durable inbox immediately, which is required before LiveContainer revokes access.

When the app is recording and a server session ID exists, import directly into that session. When recording has begun but the session ID has not arrived yet, retain the item and retry when the model changes. When no recording is active, switch to the Stunden tab and present a lesson picker sorted newest first, showing subject, AI title, and date/time.

Show compact progress, success, and retryable error feedback without interrupting an active recording. Remove the inbox copy only after a successful import.

Commit and immediately push these changes.

## Task 4: Open Echo from the normal share extension

**Files:**

- Modify: `Sources/EchoShareExtension/ShareViewController.swift`
- Modify: `README.md`

After the extension has durably copied the shared document, open `echo://note-import/<id>`. If iOS refuses to open the app, retain the queued document and explain that it remains available in Echo's Unterrichtsnotizen screen.

Document both routes: the embedded Echo share action for normal installs and LiveContainer 3.8.5's own share action for guest apps.

Commit and immediately push these changes.

## Completion constraint

Stop after source and documentation changes are committed and pushed. Do not perform compilation, static checks, automated tests, manual runtime checks, Simulator launches, or IPA generation in this task.
