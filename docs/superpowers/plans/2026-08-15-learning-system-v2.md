# Echo Learning System V2 Implementation Plan

> **Execution note:** Implement the tasks in order on isolated iOS and backend feature branches. Do not run tests, builds, GitHub Actions, or the iOS Simulator; verification is limited to source inspection and Git state as requested by the user.

**Goal:** Replace immediate AI-card generation and simplistic review with editable grounded cards, stateful scheduling, misconception remediation, subject-specific exercises, practice exams, and evidence-based analytics.

**Architecture:** Keep persistence and migrations in `learn.py`, split pure learning behavior into focused backend modules, and expose additive JSON APIs so older clients remain decodable. On iOS, keep wire DTOs in `BackendAPI+Learn.swift`, move each learning workflow into a dedicated SwiftUI view/state owner, and retain `LearnView` as the navigation dashboard.

**Repositories:** iOS work starts from `feature/direct-goodnotes-import`; backend work starts from the pushed `fix/live-note-context` branch so live worksheet context remains included.

---

## Task 1: Isolate the work and add the scheduling data model

**Backend files:**
- Create: `learning_scheduler.py`
- Modify: `learn.py`
- Modify: `server.py`

**iOS files:**
- Modify: `Sources/MossLive/Network/BackendAPI+Learn.swift`

- [ ] Create `feature/learning-system-v2` worktrees/branches for both repositories without changing either existing checkout.
- [ ] Add idempotent migrations for `learning_state`, `difficulty`, `stability`, `scheduled_interval_days`, `last_interval_days`, `last_reviewed_at`, `successful_recalls`, `attempt_uuid`, `confidence`, `response_duration_ms`, `prompt_variant`, `answer_spec_json`, and `subject_mode` while preserving every existing card and attempt.
- [ ] Backfill cards with no attempts to `new`, cards with successful repetition history to `review`, and the remaining reviewed cards to `learning`.
- [ ] Implement pure scheduler inputs/outputs in `learning_scheduler.py`: `ScheduleInput`, `ScheduleResult`, `schedule_review(...)`, `is_due(...)`, and `readiness_evidence(...)`.
- [ ] Make evaluation writes idempotent by rejecting duplicate `attempt_uuid` scheduling mutations while returning the already stored result.
- [ ] Change daily-plan selection to due cards plus a bounded number of new cards, interleaved by subject and concept; add an explicit `include_optional_practice` query for non-due practice.
- [ ] Extend overview JSON with state counts, overdue count, recall evidence, and nullable readiness while leaving existing keys intact.
- [ ] Add matching optional Swift DTO fields so old and new backend payloads both decode.
- [ ] Inspect changed source and Git diff, then commit and immediately push the backend and iOS phase commits.

## Task 2: Add editable generation drafts and saved-card maintenance

**Backend files:**
- Create: `learning_generation.py`
- Modify: `learn.py`
- Modify: `server.py`
- Modify: `common/prompts.py`

**iOS files:**
- Modify: `Sources/MossLive/Network/BackendAPI+Learn.swift`
- Create: `Sources/MossLive/Views/LearnCardDraftPreviewView.swift`
- Create: `Sources/MossLive/Views/LearnCardEditorView.swift`
- Modify: `Sources/MossLive/Views/LearnView.swift`

- [ ] Define `LearnCardDraft` with temporary UUID, concept, subject, question, expected answer, explanation, difficulty, kind, sources, subject mode, answer specification, and prompt variant.
- [ ] Refactor the generation prompt/parser into `learning_generation.py`; preserve transcript and imported-note citations and normalize malformed optional AI fields safely.
- [ ] Make `POST /learn/generate` return drafts when `preview=true`, while preserving the old immediate-save behavior when preview is absent.
- [ ] Add transactional `POST /learn/cards/batch`, authenticated `PATCH /learn/cards/{card_id}`, and `POST /learn/cards/{card_id}/regenerate` endpoints.
- [ ] Ensure single-draft regeneration accepts the current edited draft as context and does not overwrite other drafts.
- [ ] Add iOS API methods `generateLearnDrafts`, `saveLearnDrafts`, `updateLearnCard`, and `regenerateLearnCard`.
- [ ] Replace immediate generation with an editor showing one selected card plus a compact draft list; support edit, difficulty, discard, individual regenerate, retry, and atomic “Karten übernehmen”.
- [ ] Add Edit, Regenerate, and Delete actions to saved concepts and preserve the existing source-opening behavior.
- [ ] Protect unsaved drafts with a discard confirmation when leaving the preview.
- [ ] Inspect changed source and Git diff, then commit and immediately push both repositories.

## Task 3: Add misconception remediation and varied recall prompts

**Backend files:**
- Modify: `learning_generation.py`
- Modify: `learning_scheduler.py`
- Modify: `learn.py`
- Modify: `server.py`
- Modify: `common/prompts.py`

**iOS files:**
- Modify: `Sources/MossLive/Network/BackendAPI+Learn.swift`
- Create: `Sources/MossLive/Views/LearnRemediationView.swift`
- Modify: `Sources/MossLive/Views/LearnReviewView.swift`

- [ ] Define a `LearnRemediation` payload with diagnosis, grounded explanation, best source, hint, control question, expected answer, kind, answer spec, and prompt variant.
- [ ] Extend semantic evaluation so partial, incorrect, and misconception results generate remediation grounded only in the card’s stored transcript/note sources.
- [ ] Persist the attempted prompt variant and transition failed established cards to `relearning`.
- [ ] Add a dedicated idempotent remediation-control endpoint whose successful answer schedules a short interval and whose failure keeps the card in `relearning`.
- [ ] Track recently used variants and choose among definition, explanation, example, counterexample, comparison, error diagnosis, and near transfer without repeating the same wording unnecessarily.
- [ ] Decode remediation on iOS and present diagnosis/source before the control question; do not allow merely viewing the expected answer to advance scheduling.
- [ ] Make retry states retain the user’s typed answer and show a clear backend-unavailable message without optimistic scheduling.
- [ ] Inspect changed source and Git diff, then commit and immediately push both repositories.

## Task 4: Add subject modes and structured answer renderers

**Backend files:**
- Modify: `learning_generation.py`
- Create: `learning_validation.py`
- Modify: `learn.py`
- Modify: `server.py`

**iOS files:**
- Modify: `Sources/MossLive/Network/BackendAPI+Learn.swift`
- Create: `Sources/MossLive/Views/LearnAnswerSpecView.swift`
- Modify: `Sources/MossLive/Views/LearnReviewView.swift`
- Modify: `Sources/MossLive/Views/LearnRemediationView.swift`

- [ ] Resolve `mathematics`, `science`, `language`, `history`, `german`, or `general` from canonical subject metadata with a safe general fallback.
- [ ] Define tagged `LearnAnswerSpec` JSON for text fields, number/unit/tolerance, ordered steps, named cloze blanks, and choice options.
- [ ] Generate subject-appropriate exercise kinds and persist both the mode and answer specification on drafts/cards/attempts.
- [ ] Implement deterministic numeric, unit, cloze, choice, and ordered-step validation in `learning_validation.py`; use semantic AI evaluation only where free-text meaning is required.
- [ ] Add worked-example fading metadata linking complete example, missing-step exercise, and near-transfer exercise; prevent the study-only stage from advancing the scheduler.
- [ ] Implement a reusable SwiftUI renderer and typed answer-value DTO for every answer-spec kind.
- [ ] Use the renderer in normal review and remediation while retaining the existing large text editor for text recall.
- [ ] Inspect changed source and Git diff, then commit and immediately push both repositories.

## Task 5: Expose exams and implement durable practice runs

**Backend files:**
- Create: `learning_exams.py`
- Modify: `learn.py`
- Modify: `server.py`
- Modify: `learning_scheduler.py`

**iOS files:**
- Modify: `Sources/MossLive/Network/BackendAPI+Learn.swift`
- Create: `Sources/MossLive/Views/LearnExamListView.swift`
- Create: `Sources/MossLive/Views/LearnExamEditorView.swift`
- Create: `Sources/MossLive/Views/LearnExamRunView.swift`
- Modify: `Sources/MossLive/Views/LearnView.swift`

- [ ] Extend the existing exam store/API with editable lesson scope, daily minutes, source (`webuntis` or `manual`), and nullable readiness evidence.
- [ ] Add durable exam-run, exam-question, and exam-answer tables with start, pause, resume, autosave, and submission timestamps.
- [ ] Generate a balanced question set across scoped concepts, with point values and a time limit, without exposing hints, sources, or model answers before submission.
- [ ] Add endpoints to create/load/pause/resume an exam run, autosave each answer, and submit once idempotently.
- [ ] Grade structured answers deterministically and free text semantically; return points, per-question feedback, and grouped weak concepts.
- [ ] Move failed exam concepts into learning/relearning and raise their bounded priority in subsequent due plans.
- [ ] Add iOS exam list, manual editor, scope editor, run timer, answer autosave, pause/resume, and results UI.
- [ ] Keep synced exams identifiable and prevent deletion from silently removing the source WebUntis event.
- [ ] Inspect changed source and Git diff, then commit and immediately push both repositories.

## Task 6: Add evidence-based learning analytics

**Backend files:**
- Modify: `learn.py`
- Modify: `server.py`
- Modify: `learning_exams.py`

**iOS files:**
- Modify: `Sources/MossLive/Network/BackendAPI+Learn.swift`
- Create: `Sources/MossLive/Views/LearnAnalyticsView.swift`
- Modify: `Sources/MossLive/Views/LearnView.swift`

- [ ] Add `/learn/analytics` queries for due/overdue, state distribution, recall success by subject and concept, average response-time trend, lapses, repeated misconceptions, 7/30-day activity, and never-successfully-recalled concepts.
- [ ] Compute readiness from successful unaided recalls, coverage, recency, and exam scope; return `status=insufficient_evidence` until minimum evidence thresholds are met.
- [ ] Add nullable trend/readiness DTOs so sparse datasets are represented honestly rather than as zero mastery.
- [ ] Show actionable weaknesses and today’s workload first, then state distribution, recall evidence, response-time/activity trends, and exam readiness.
- [ ] Rename the legacy mastery display to “Erinnerungsstärke” and show “Noch nicht genug Daten” wherever readiness lacks evidence.
- [ ] Keep the dashboard non-punitive: no streak loss, missed-day warning, or competitive comparison.
- [ ] Inspect changed source and Git diff, then commit and immediately push both repositories.

## Task 7: Final compatibility and handoff inspection

**Files:**
- Review every file changed by Tasks 1–6.
- Update: `docs/superpowers/specs/2026-08-15-learning-system-v2-design.md` only if implementation differences require documentation.

- [ ] Confirm through source inspection that existing API keys/endpoints remain available to older iOS builds.
- [ ] Confirm all migrations are additive/idempotent and no existing cards, attempts, exams, sources, or recordings are deleted.
- [ ] Confirm archived-subject changes still reclassify exclusively sourced cards and imported worksheets remain quick-answer context.
- [ ] Inspect both Git diffs for secrets, generated artifacts, unrelated user files, and accidental line-ending rewrites.
- [ ] Confirm both feature branches are clean and their commits are present on the corresponding GitHub remotes.
- [ ] Report the exact branches and commits, plus the explicit fact that no tests, builds, Simulator session, GitHub Action, or IPA generation was run.
