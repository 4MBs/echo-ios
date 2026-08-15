# Reliable Reader Page Entry Design

## Goal

The book reader's page-number control opens reliably on the first tap, uses the full system keyboard, and closes predictably through Return or a tap elsewhere in the reader.

## Root Cause

The current control conditionally replaces a page indicator button with a `TextField`. It requests focus in the same state transition that inserts the field. SwiftUI can process that focus request before the new field is mounted, leaving an unfocused field and forcing repeated taps. The configured `.numberPad` also has no Return key, while outside-tap dismissal currently depends mainly on gestures inside the PDF view.

## Interaction Design

The page control becomes one stable `TextField` that remains mounted for the lifetime of the reader. When it is not focused, it displays the book's current printed page number and retains the existing glass control appearance. A single tap focuses the already-mounted field, clears the displayed value for replacement, and opens the full standard keyboard.

Input is filtered to at most five decimal digits even though the full keyboard is visible. Every valid page number navigates using the existing printed-page-to-PDF-page mapping. Empty, nonnumeric, zero, or out-of-range input never moves the book.

The keyboard Return key uses the `done` submit label. Pressing Return commits the latest valid page, removes focus, closes the keyboard, and restores the field to the actual visible printed page number.

Tapping outside the page field also ends editing. This includes the PDF canvas, empty control-bar background, previous/next arrows, page-layout menu, and other reader controls. Outside-tap handling must not consume the original tap: a page turn or menu action still occurs while the keyboard closes. Tapping within the field does not dismiss it immediately.

When editing ends for any reason—including interactive keyboard dismissal—the temporary input is discarded and the control reflects the page that is actually visible.

## State Boundaries

`PDFReader` continues to own the input string and `FocusState`. One focused-state transition prepares the input; one shared `endPageEntry()` function clears focus and synchronizes the displayed number. Reader buttons call that function before their existing actions.

`BookPDFView` keeps its non-cancelling tap and pan recognizers and resigns the current first responder on canvas interaction. `PDFReader` observes focus loss as the single source of truth for restoring its value, avoiding duplicated keyboard notification state machines.

The stable field removes the separate `askingForPage` and `openedAt` states. No changes are made to page rendering, printed-page offsets, Book AI, or region selection.

## Accessibility

The control retains the German accessibility label `Seitennummer` and exposes the current printed page as its value. Its hit target and position remain stable when focus changes. The full keyboard uses a visible `Fertig` Return action through `.submitLabel(.done)`.

## Testing

Unit-level state tests cover numeric filtering, valid printed-page mapping, invalid input, and restoration to the visible page after editing ends.

The reader UI test taps the page field once and verifies that it becomes keyboard-focused, types a destination, presses Return, and verifies navigation plus keyboard dismissal. A second case reopens the field, taps the PDF canvas, and verifies dismissal without requiring another tap. Existing page-turn, layout, region-selection, and numbering tests remain part of regression verification.

The final GitHub verification must compile the Release configuration and produce an unsigned IPA before the change is merged to `main`.
