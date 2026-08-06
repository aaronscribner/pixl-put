---
description: TDD Cycle (RED-GREEN-REFACTOR) — Spec-Kit Integrated
scripts:
  sh: scripts/bash/check-implementation-prerequisites.sh --json
  ps: scripts/powershell/check-implementation-prerequisites.ps1 -Json
---

Execute a TDD RED-GREEN-REFACTOR cycle for the current feature. This command assumes a spec and tasks already exist.

Context: {ARGS}

0. **Pre-work — Project Precepts (REQUIRED)**. Before any TDD-cycle step, perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent.
   - Read `roadmap/product/constitution.md`. Halt if absent.

   Carry these three inputs through every sub-agent invocation (RED, QA, GREEN, REFACTOR, validation). Per Precept #1 (Native Swift / macOS Stack), read `agents/stacks/swift.md` first to confirm Apple-framework patterns and the project's documented extension points (`Core/Identity/AppProviders/`, `Core/Spaces/PrivateCGS.swift`). Top-level new abstractions outside these require a Complexity Tracking entry in `plan.md`.

1. Run `{SCRIPT}` from repo root and parse FEATURE_DIR and AVAILABLE_DOCS list. All paths must be absolute.

2. Load implementation context:
   - **REQUIRED**: Read `tasks.md` for the task breakdown
   - **REQUIRED**: Read `spec.md` for acceptance criteria
   - **REQUIRED**: Read `plan.md` for tech stack and architecture
   - **IF EXISTS**: Read `data-model.md`, `contracts/`, `research.md`

3. Load the Swift stack agent: read `agents/stacks/swift.md` for build/test/lint commands, idioms, and patterns. PixPut is a single-stack project; other `agents/stacks/*.md` are not consulted.

4. **RED Phase** — Read `agents/engineering/tdd-developer.md` and follow its process:
   - For each task in `tasks.md` (dependency order):
     a. Write failing test(s) for the task's expected behavior
     b. Run tests — confirm they FAIL
     c. Commit: `test(red): <description>`
   - All acceptance criteria must have corresponding tests

5. **QA Check** — Read `agents/engineering/qa-validator.md` and follow its process:
   - Verify coverage matrix: every acceptance criterion has tests
   - Verify all tests fail for the correct reason
   - If issues found: return to step 4 and fix (max 3 iterations)

6. **GREEN Phase** — Read `agents/engineering/software-developer.md` and follow its GREEN process:
   - For each failing test (dependency order):
     a. Write MINIMAL code to make the test pass
     b. Run ALL tests — no regressions
     c. Commit: `feat(green): <description>`
   - Continue until ALL tests pass

7. **REFACTOR Phase** — Read `agents/engineering/software-developer.md` and follow its REFACTOR process:
   - Identify code smells and improvement opportunities
   - Apply refactorings one at a time
   - After EACH refactoring: run ALL tests (must still pass)
   - Commit: `refactor: <description>`

8. **Validation** — Read `agents/engineering/qa.md` and follow its process:
   - Audit git history for RED-GREEN-REFACTOR discipline
   - Run full test suite, linters, build
   - Verify spec compliance
   - If APPROVED: submit PR
   - If REJECTED: return to step 4 (max 2 iterations)

9. Mark all completed tasks as `[X]` in `tasks.md`.

10. Report final status: tests passing, commits made, PR submitted (if applicable).
