# What Echo does

## Live transcription

Audio is captured with AVAudioEngine, encoded as Opus, and streamed over a
WebSocket to the backend, which runs Qwen3-ASR on its own GPU. Recognised text
comes back while the teacher is still talking. Nothing is sent anywhere else
unless you press something that asks an AI a question.

The transcript fills the page as it arrives. Everything else — the sidebar, the
record control, the answer note — sits at the edges.

After class, a lesson's transcript menu can explicitly start a higher-quality
second pass from the local 48-kHz safety recording. The upload resumes after a
connection failure and never starts automatically. The live transcript stays
visible until the backend has completed the replacement; if it was manually
edited in the meantime, the new result is saved only as another restorable
version.

The same menu opens the timestamp-preserving transcript editor and a per-subject
vocabulary. Vocabulary can be maintained by hand or, on request, populated from
corrections, timetable names, earlier lessons and matching books in the Echo
library.

### Dead zones don't cost you the lesson

If the network drops mid-lesson, recording continues and the backlog — up to
roughly 100 minutes of audio — is replayed when the connection returns. Nothing
said during an outage is lost.

## It knows your timetable

Connect WebUntis and recordings name themselves: subject, teacher, room. Record
straight through a double period and the recording is cut into one lesson per
period afterwards, so the archive matches the timetable rather than the tape.

## The lesson archive

Stunden is a grid of folders, one per subject, each in its own colour with its
own icon. The folders come from WebUntis rather than from what happens to have
been recorded, so every subject you take has its place from the first launch and
an empty archive still looks like your own timetable. **Sonstige** collects
whatever was recorded while no lesson was running — the holidays, an evening, a
free period — and is the one folder the timetable cannot supply.

Open a folder and the subject's recordings are there, headed by the two figures
a subject adds up to — how long it has been recorded for in total, and how much
of that was this week. Every row leads with **what the lesson was about**: three
or four words, written by the AI as the first line of the summary, on one line
and never two. Under it the date and how long it ran, then the opening of the
summary — so the list reads for what was taught rather than for when. On a wide
window the list is cut in half and set in two columns, still read top to bottom,
newest first. A long press on a row deletes the lesson.

A lesson is three cards: what it was about, the recording, and what was said.
The summary writes itself when the recording ends — the archive is a dozen
lessons of one subject at nearly the same time of day, and being told what each
one covered should not cost a button press per lesson. Transcript and audio both
stay on the server. The recording plays from its own waveform, so the silence
before the lesson started is visible rather than something you drag to find, and
tapping any line of the transcript plays from that moment while the page follows
along.

### Imported notes

Each archived lesson can also import notes authored elsewhere: native Goodnotes
documents, Notability `.note` files with an embedded PDF, PDFs, JPEGs and PNGs.
PDF export is the dependable interchange route for Notability. Echo decodes
searchable text, exact typed objects and Goodnotes' own handwriting index
locally on the iPad. For scans and missing handwriting data, Apple Vision's
accurate on-device text model is used as a conservative fallback. Visual page
coordinates determine reading order. When Goodnotes includes a page-content
timestamp inside the lesson, the imported page links to that point in the
recording. It is labelled as the page's last edit, not presented as an exact
timestamp for every Pencil stroke. Reimporting the same Goodnotes page updates it
through the document's stable internal IDs.

The original Goodnotes/Notability/PDF/image file and all rendered page images
remain on the iPad. Echo sends only the locally extracted text, stable page ID,
optional page timestamp and warnings to the user's own backend; new imports do
not create server-side note attachments.

Echo has no note editor or drawing canvas. Goodnotes and Notability remain the
place where notes are written; Echo only imports, reads and links them.

Echo also installs an iOS Share Extension. A page or document shared from
Goodnotes, Notability or Files is placed in Echo's App Group inbox. Open the
destination lesson, choose **Unterrichtsnotizen**, then tap the queued document
under **Aus dem Teilen-Menü**. The extension never guesses which lesson a file
belongs to and does not upload anything before that explicit choice.

## Chat and the answer note

The chat answers free-form questions about the running recording or any past
lesson. While recording, a sticky note on the page answers "what did they just
say" for the last N seconds. A Home and Lock Screen widget does the same and is
deliberately anonymous-looking, which matters more than it should.

<p align="center">
  <img src="screenshots/chat.png" width="880" alt="The chat screen before the first question, with a context picker above the input field">
</p>

The context picker under the conversation decides what a question is answered
from: nothing, the running recording, or one particular lesson.

## Bibliothek

The schoolbook shelf. PDFs sit in one folder on the server, appear in the app as
a grid of covers, and a book downloads once, into permanent storage, the first
time it is opened. After that it is available offline.

The reader shows a book rather than a document. One page, or a real 2–3 spread,
fills the screen; nothing scrolls; pages turn with a sideways flick. Zooming out
stops when the page reaches its natural size on the display, worked out for each
book from its own page dimensions and the current layout, so no book can shrink
into a stamp in the middle of the screen.

Schoolbooks rarely print page 1 on the first PDF page, so every book learns its
own numbering once: turn to any page whose number you can read, type that number,
and the rest of the book follows. It is remembered per book.

### Seite fragen

**Seite fragen** sits in the reader's control bar beside the page arrows and the
layout switch, only ever inside an open book. On an iPad it opens as an inspector
beside the page; on a phone it is a nonmodal sheet that can collapse while a
cited page is checked. The question goes to the server with the PDF page numbers
currently on screen — the server already has the book, so no page, picture or
text is uploaded. It reads that page there, looks at the rendered image when the
page is a diagram or scan, and may follow the book's own references into nearby
pages. The answer arrives with its book sources attached, named with the printed
numbers, and tapping one turns the reader without throwing the answer away.
Reading a downloaded book stays offline; asking about it needs the server.

Each page or spread has its own short thread. Turning the page switches context
instead of quietly attaching a follow-up to the previous page. The panel uses
the same conversation layout and composer as Chat: questions are free-form, can
be typed or dictated, and answers can be copied or generated again. There are no
preset task, explanation, summary or illustration actions. Sources stay collapsed
until wanted.

For something more precise than the current page, **Bereich markieren** closes
the panel and lets the student draw a rectangle directly on the PDF with a finger
or Apple Pencil. Echo sends only the page number and normalized rectangle
coordinates, not a screenshot. That marked region gets its own thread and remains
outlined while the answer is compared with the book.
