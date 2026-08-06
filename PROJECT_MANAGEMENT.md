# MuApps Project Management Contract

This document is the shared project-management instruction for agents working
in this repository. `AGENTS.md` and `CLAUDE.md` are entry points; keep the
detailed workflow here so Codex and Claude follow the same contract.

## Notion workspace

- Root: https://app.notion.com/p/3b318017d4c180af889ee01fb5dcfc7e
- Projects: https://app.notion.com/p/73c7b5630dce47fe951e7c23b8942999
- Specifications: https://app.notion.com/p/e163dc8e4f184ab08c42f9d56bc6e042
- Tasks: https://app.notion.com/p/9c31014192014ea9b4690a4ead4a72be
- Decisions: https://app.notion.com/p/40d2bf3e8c994b80b6f86496b0d117ae
- Operating guide: https://app.notion.com/p/3b318017d4c181529f9df304770e7911
- Default-instruction reference:
  https://app.notion.com/p/3b318017d4c181639e30d0fc430ec037

Do not create a separate database for each App. Use the shared databases and
their Project, Specification, Task, and Decision relations.

## Source contract

The sources have distinct responsibilities:

- Notion records product intent, scope, priority, lifecycle, acceptance
  criteria, decisions, and progress.
- Git specifications record the current implementation contract beside the
  code so behavior and documentation can be reviewed in the same diff.
- Code and tests provide the implemented behavior and verification evidence.

For a user-facing functional change, update the related Notion Specification
and the relevant Git specification in the same work item. The existing
`CLAUDE.md` specification policy still applies.

A bug fix that only restores already documented behavior does not require a
specification rewrite when the documentation remains correct. An internal
refactor normally does not change a product specification, but it does require
a Technical Specification or Decision update when it changes a public
contract, architecture boundary, persistence/sync ownership, or data model.

If code and a specification disagree, report the discrepancy. Do not silently
choose one as truth. Keep the Notion Specification at `Needs Triage` or `Draft`
until intent is confirmed.

## What requires a Task

Create or reuse a Task for material work:

- user-facing features or behavior changes;
- bug fixes that require code changes;
- architecture, persistence, sync, data-model, or integration work;
- research whose result will drive a later decision;
- migrations, releases, operations, or durable documentation work.

Usually do not create a Task for:

- a short answer that completes the request;
- read-only inspection with no requested follow-up;
- typo or formatting changes that do not alter meaning;
- a small disposable local experiment.

For answer-only or diagnosis-only requests, do not mutate Notion unless the
user requested durable tracking or the repository instruction explicitly
requires it. For implementation requests, Task creation and status updates are
part of the authorized project workflow.

## Start-of-work workflow

1. Read `AGENTS.md`, `CLAUDE.md`, this document, the applicable App-level
   instructions, and the relevant Git specification.
2. Confirm the current branch, worktree, dirty diff, and actual code path.
   Preserve unrelated user changes.
3. Search Notion before creating anything. Reuse existing Project,
   Specification, Task, and Decision records when they describe the same work.
4. Ensure the Task has a Project relation. Link a Specification whenever the
   work implements or changes one.
5. Before implementation, record:
   - objective;
   - in-scope and out-of-scope behavior;
   - testable acceptance criteria;
   - verification plan;
   - dependencies, assumptions, and unresolved questions.
6. Set `In Progress` only when work actually starts.

Do not infer product lifecycle, owner, priority, or approval from directory
existence, recent commits, or an apparently complete implementation. Leave
unknown values empty or `Untriaged` and make the missing judgment explicit.

## Task sizing and status

Prefer a single independently verifiable deliverable that takes one to two
days. Split work estimated at more than three to four days before moving it to
`Ready`.

- `Inbox`: scope or acceptance criteria are incomplete.
- `Ready`: dependencies and completion conditions are clear.
- `In Progress`: work is actively happening.
- `Blocked`: work cannot proceed; record the cause, impact, and unblock
  condition.
- `In Review`: implementation is complete from the implementer's perspective
  and awaits code review, QA, or user review.
- `Done`: acceptance criteria, required review, verification, and
  specification synchronization are complete.
- `Cancelled`: intentionally stopped; record why.

Do not use optimistic status. Unverified or partially implemented work is not
`Done`.

## During implementation

- Add progress notes after meaningful milestones, scope changes, or blockers;
  do not stream low-value activity logs.
- Record a Decision when a product, UX, architecture, or process choice has
  durable consequences and meaningful alternatives. Include context, options,
  rationale, trade-offs, consequences, and a revisit trigger.
- Do not create Decisions for local, obvious implementation details.
- Add the pull-request URL to the Task when one exists.
- Continue updating `.tmp/implementation-notes.md` as required by
  `AGENTS.md`. Notion does not replace those session implementation notes.

## Completion workflow

Before reporting completion:

1. Check every acceptance criterion.
2. Record the exact build, test, Simulator, device, or manual review evidence.
   Also state what was not exercised.
3. Re-evaluate whether both the Notion Specification and Git specification
   require updates.
4. Record the result, limitations, remaining work, verification, and PR URL on
   the Task.
5. Set the final status based on evidence, not on code-writing completion.

## Notion safety and failure handling

- Do not delete pages, trash databases, remove properties, or make destructive
  schema changes without an explicit user request.
- Do not create duplicate records to work around a search or relation problem.
- If Notion is unavailable, do not claim it was synchronized. Continue only
  when the repository work is otherwise safe, record the pending sync in
  `.tmp/implementation-notes.md`, and disclose it in the final result.
- Never turn an assumption into a requirement. Label assumptions,
  clarifications, and verification boundaries explicitly.
