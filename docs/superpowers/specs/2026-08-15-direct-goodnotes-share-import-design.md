# Direct Goodnotes Share Import

## Goal

Let a student share a native Goodnotes document, Notability document, PDF, or image to Echo without manually switching apps and reopening Echo's file picker. A shared document joins the active recording automatically. If no recording is active, Echo opens a lesson picker and imports into the selected lesson.

## Supported environments

The same feature supports two installation modes:

- A normally installed Echo IPA exposes the existing Echo Share Extension in the system share sheet.
- Echo running as a guest in LiveContainer 3.8.5 receives the file through LiveContainer's own share extension and file-opening handoff. Echo must not depend on its embedded Share Extension or an App Group for this path.

The accepted source formats are `.goodnotes`, `.note`, `.pdf`, `.png`, `.jpg`, and `.jpeg`. Echo declares these document types in its application metadata so LiveContainer recognizes Echo as a compatible destination. Existing manual import remains available.

## Architecture

### One import coordinator

A main-app `IncomingNoteImportCoordinator` owns every external note import. Both the existing App Group inbox and incoming file URLs feed this coordinator. The manual file importer also delegates to it, so parsing, routing, retries, status, and cleanup have one implementation.

The coordinator immediately copies every incoming file into an Echo-owned inbox. It uses the App Group inbox when a normal Share Extension has already copied the file there and an application-support inbox for files handed to the main app by LiveContainer. Security-scoped access is held only for the duration of that copy. The original temporary URL is never retained.

### Normal installation

The Share Extension accepts one supported document per share operation, copies it to `PendingNoteImports`, and requests that iOS open an `echo://note-import/<id>` URL. The main app consumes the referenced inbox item. If iOS refuses the open request, the extension reports that the file is safely queued; the existing pending-import badge remains the fallback.

### LiveContainer 3.8.5

The user shares the document to LiveContainer and chooses Echo. LiveContainer launches Echo with the shared file URL. Echo registers the supported document types and handles the URL at app and scene activation. The coordinator copies the file into Echo's own container before LiveContainer's temporary access ends.

No LiveContainer-specific SDK or private filesystem path is introduced. The integration relies only on LiveContainer 3.8.5's documented file-to-guest-app handoff and standard iOS document-opening metadata.

## Routing

The route is decided only after the file is durable:

1. If `AppModel.phase` is recording and `sessionId` exists, import into that session immediately.
2. If recording has started but the server acknowledgement has not supplied `sessionId` yet, retain the item and resume automatically when the ID appears.
3. If no recording is active, navigate to the lessons area and present a destination picker.

The picker lists existing lessons newest first and shows subject, AI-generated title, date, and time. Selecting a lesson starts the import immediately; the user never sees another file picker. Cancelling the picker leaves the item queued rather than deleting it.

## Import processing

The coordinator reuses `LocalNoteImporter` for native Goodnotes, Notability, PDF, and image processing. Extraction remains local on the device. It calls the existing `BackendAPI.importLessonNotes` endpoint with only extracted page text, stable page identifiers, optional page timestamps, and warnings.

The backend already stores these pages against the selected session and includes imported lesson notes in AI context. No new backend endpoint or file upload is required.

Each inbox item has a stable import identifier. A successful import removes the inbox item. Retrying a queued item reuses the same identifier so repeated activation or reopening cannot create duplicate note pages.

## User experience

During a recording, Echo opens and displays a compact nonblocking status:

- `“<filename>” wird zu dieser Aufnahme hinzugefügt …`
- `Notizen wurden als KI-Kontext hinzugefügt` on success.
- A retry action on failure while retaining the queued document.

Importing must not pause, stop, or otherwise interfere with audio capture.

Without a recording, Echo opens directly to `Stunde für Import auswählen`. Choosing a lesson shows import progress and then the lesson's imported-notes screen. A server outage or extraction error leaves the original inbox item available for retry and presents a localized error.

## File recognition and safety

Echo declares imported uniform type identifiers for native `.goodnotes` and `.note` files and system document roles for PDF and images. Runtime validation still checks filename extension and actual readable content; metadata alone is not trusted.

The existing archive size, entry-count, path traversal, and extraction limits remain authoritative. Unsupported, empty, renamed, or damaged files fail with a localized explanation and remain recoverable until the user discards them.

## Privacy

The original document and rendered images stay on the iPad. Echo sends only the locally extracted text and metadata already accepted by the backend. Sharing a file never uploads it before a target recording or lesson has been determined.

## Verification constraint

At the user's explicit request, the agent performs no automated tests, simulator runs, or manual runtime tests for this feature. The user will verify the resulting IPA on the physical device with Goodnotes and LiveContainer 3.8.5.
