# Echo Learning System V2 Design

## Objective

Turn Echo's current AI flashcard review into a complete lesson-grounded learning system. The new system must improve card quality before scheduling, adapt repetition to actual recall, remediate misconceptions, use subject-appropriate exercises, and support realistic exam preparation with useful progress evidence.

The work is split into four additive phases. Every stored object remains owned by the user's backend. The iOS app is the interaction layer and keeps only the existing offline read cache.

## Global constraints

- Existing cards and attempts must migrate without being deleted.
- Every generated or evaluated answer remains grounded in recorded lesson transcripts and imported lesson notes.
- Changing an archived lesson's subject updates cards supported exclusively by that lesson; multi-source concepts retain their shared classification.
- No third-party learning service or hosted account is introduced.
- The agent does not run automated tests, manual runtime tests, builds, GitHub Actions, or the iOS Simulator. The user performs runtime verification.
- Backend and iOS changes are committed and pushed in separate, reviewable phases.

## Phase 1 — Card quality and scheduling

### Generation preview

Generating from a lesson no longer immediately commits every AI result. The backend returns `LearnCardDraft` values containing:

- a temporary UUID;
- concept and subject;
- question and expected answer;
- explanation;
- difficulty from 1 through 5;
- proposed exercise kind;
- transcript/note source references.

The iOS preview shows one editable card at a time and a compact list of all drafts. The student can edit the concept, question, expected answer, explanation and difficulty, discard a draft, or regenerate only that draft. “Karten übernehmen” saves the remaining drafts atomically. Leaving the preview asks for confirmation only when unsaved drafts remain.

Saved cards gain authenticated `PATCH` and single-card regeneration operations. The concept library offers Edit, Regenerate and Delete from the existing swipe/context menu.

### Scheduler

Cards receive an explicit learning state:

- `new`: never reviewed;
- `learning`: in the initial acquisition steps;
- `review`: established memory;
- `relearning`: recalled incorrectly after learning;
- `suspended`: excluded until restored.

The scheduler uses semantic evaluation category, response duration, optional confidence, prior stability, difficulty, repetitions and lapses. It keeps the existing fields readable while adding state, scheduled interval, last interval and next due timestamp. Existing cards migrate according to their current repetition history.

The daily plan contains only due cards plus a bounded number of new cards. Non-due cards are available through an explicitly labelled optional practice action and never inflate “heute fällig”. Cards are interleaved across subjects and concepts instead of returning one large subject block.

The overview distinguishes due, new, learning, relearning and review counts. The old mastery value remains decodable for compatibility but the UI presents “Erinnerungsstärke” and “Prüfungsbereitschaft” only when enough review evidence exists.

## Phase 2 — Remediation and transfer

### Misconception flow

An evaluation classified as partial, incorrect or misconception returns a `LearnRemediation` object:

- concise diagnosis of the missing or incorrect idea;
- lesson-grounded explanation;
- the most relevant source;
- one hint;
- a new control question testing the same concept differently;
- its expected answer and exercise kind.

The card enters `relearning`. The review screen shows diagnosis and source first, then requires the control question. A successful control answer schedules the card for the next short interval. Another unsuccessful answer keeps it in relearning and offers the source again. Merely reading the model answer never marks a concept learned.

### Variation

Cards have a stable concept identity but may expose different prompts. Generation and remediation can request definition, explanation, example, counterexample, comparison, error diagnosis or near-transfer variants. Attempt history stores the variant so repeated identical wording can be avoided.

## Phase 3 — Subject-specific modes

The backend resolves a `LearnSubjectMode` from canonical WebUntis subject metadata and the generated concept:

- `mathematics`: numeric/algebraic answer, units, ordered derivation steps, worked example fading and near-transfer problem;
- `science`: process ordering, labels, causal explanation, calculation and units;
- `language`: vocabulary direction, cloze, translation, spelling and short production;
- `history`: chronology, causes/consequences, comparison and source interpretation;
- `german`: argument structure, stylistic device, interpretation and revision;
- `general`: free recall, comparison, example and error diagnosis.

`LearnAnswerSpec` describes the required renderer without hard-coding subjects into Swift:

- `text` with one or multiple fields;
- `number` with optional unit and tolerance;
- `orderedSteps`;
- `cloze` with named blanks;
- `choice` for recognition checks used only as a minority of a session.

The iOS review renderer selects controls from this specification. AI semantic evaluation remains the fallback for free text; numeric and ordered structured answers receive deterministic validation before explanatory AI feedback.

Worked-example fading uses three linked stages: study the complete solution, fill one missing step, then solve a near-transfer problem. Completion of the example alone does not advance the scheduler.

## Phase 4 — Exams and evidence

### Exam management

The existing backend exam model becomes visible in iOS. The app lists WebUntis-synced and manually created exams, with subject, date, included lessons, daily minutes and readiness. Students can create, edit and delete manual exams and adjust the automatically selected lesson scope.

### Practice exams

Starting a practice exam creates a durable `LearnExamRun` with:

- selected exam and lesson scope;
- generated question set balanced across included concepts;
- point values and time limit;
- start, pause and submission timestamps;
- answers, awarded points and feedback.

During an exam, hints, model answers and lesson sources are hidden. Submission grades the complete run, shows points per task and groups weaknesses by concept. Weak concepts return to learning/relearning and are prioritized in subsequent daily plans.

### Analytics

The analytics endpoint reports evidence rather than a single opaque percentage:

- due and overdue counts;
- recall success by subject and concept;
- new/learning/relearning/review distribution;
- average response time trend;
- lapse count and repeated misconceptions;
- seven- and thirty-day review activity;
- exam readiness with an explicit “not enough evidence” state;
- concepts never successfully recalled without help.

The iOS dashboard shows current actionable weaknesses first and historical charts second. No competitive streaks or punitive missed-day messages are added.

## Backend boundaries

The existing `learn.py` store module remains responsible for schema migration, card state, sources, scheduling, attempts, exam scope and analytics queries. Generation/evaluation orchestration remains in `server.py`, but subject-mode prompt construction and structured validation move to focused modules:

- `learning_generation.py` for draft and variant prompts/parsing;
- `learning_scheduler.py` for state transitions and due dates;
- `learning_validation.py` for deterministic answer specifications;
- `learning_exams.py` for durable exam runs and grading.

Endpoints are additive where possible. Existing `/learn/overview`, `/learn/cards`, `/learn/plan`, `/learn/generate` and `/learn/evaluate` remain decodable by older apps.

## iOS boundaries

Wire DTOs remain under `BackendAPI`. Each large flow gets a focused view and observable state owner:

- generation preview/editor;
- daily review and remediation;
- answer-spec renderer;
- exam list/editor;
- exam run;
- learning analytics.

`LearnView` remains the navigation home rather than accumulating these responsibilities itself.

## Error handling and persistence

Draft generation can be retried per card without discarding other edits. Atomic save either commits all selected drafts or none. Review submission is idempotent per attempt UUID so retrying after a timeout cannot reschedule a card twice. Exam answers autosave locally on the backend after every task. Offline iOS caches are read-only snapshots; scheduling mutations clearly report when the backend is unreachable.

## Verification constraint

The implementation will be reviewed through source inspection and Git state only. No compilation, test suite, Simulator session or generated IPA is part of this implementation request. A device IPA is produced only when the user asks for it separately.
