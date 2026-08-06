---
description: Strict PR Review (Spec-Kit Integrated)
---

Execute a strict, multi-pass pull request review following the Reviewer agent protocol.

Target: {ARGS}

0. **Pre-work — Project Precepts (REQUIRED)**. Before reviewing, perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent.
   - Read `roadmap/product/constitution.md`. Halt if absent.

   These inputs feed the reviewer's Pass 1 (correctness vs spec) and Pass 3 (design alignment with Swift idioms + project constitution). Per Precept #1 (Native Swift / macOS Stack), flag any new top-level abstraction outside documented extension points (`Core/Identity/AppProviders/`, `Core/Spaces/PrivateCGS.swift`) without a Complexity Tracking entry in `plan.md` as a critical finding. Per project constitution §VI, any private CG symbol outside `PrivateCGS.swift` is a critical finding. Per §IV, any new outbound network call (other than Sparkle's appcast) is a critical finding.

1. Read the constitution at `.claude/constitution.md` (if it exists) for project principles.

2. **Identify the PR**:
   - If {ARGS} is a PR number: use `gh pr view {ARGS}`
   - If {ARGS} is empty: use `gh pr view` for the current branch's PR
   - If no PR exists: report error and suggest creating one

3. **Gather context**:
   - Read `agents/review/code-reviewer.md` for full review protocol
   - Get the PR diff: `gh pr diff`
   - Get the PR details: `gh pr view --json title,body,baseRefName,headRefName,files`
   - Identify the feature spec directory from the branch name
   - Read `spec.md`, `plan.md`, `tasks.md` if they exist for this feature

4. **Execute the 6-pass review** (Rule of Six — matches agents/review/code-reviewer.md):

   **Pass 1: Correctness & Spec Compliance**
   - Does the code implement what the spec requires?
   - Are all acceptance criteria met?
   - Edge cases handled?

   **Pass 2: Security (macOS-informed)**
   - Pasteboard / URL-scheme / AppleScript injection checks
   - AX / Automation permission state checked before privileged calls
   - No off-device network calls except Sparkle appcast (project constitution §IV)
   - Sparkle EdDSA verification + HTTPS feed (project constitution §VI)

   **Pass 3: Design & Architecture**
   - Follows patterns from plan.md + the C4 components in roadmap/arch/c4/
   - No unnecessary abstractions
   - Dependencies flow App → MenuBar/Settings → Core → Infra — never reverse
   - New WindowIdentityProviders live in Core/Identity/AppProviders/
   - Private CG symbols stay in Core/Spaces/PrivateCGS.swift

   **Pass 4: Code Quality (Swift)**
   - async/await preferred over completion handlers in new code
   - Value types preferred over reference types where identity isn't needed
   - swiftlint clean; no new // swiftlint:disable without justification
   - Clear naming, small functions, no dead code

   **Pass 5: Tests**
   - XCTest patterns per agents/stacks/swift.md
   - Tests verify behavior not implementation
   - AX / CGS / persistence mocked at the seam
   - Performance budget assertions present where the spec requires them

   **Pass 6: Performance (project constitution §VII)**
   - Capture ≤ 500ms / 100 windows; restore ≤ 2s / 50 windows
   - Idle CPU ≤ 0.1% averaged over 5 min
   - Resident memory ≤ 30 MB steady state
   - AX calls serialised on the AX dispatch queue

5. **Compile review** with line-specific comments:
   - Critical issues (must fix)
   - Suggestions (should consider)
   - Nits (optional polish)
   - What's done well (positive reinforcement)

6. **Submit review** via `gh pr review`:
   - If critical issues: `gh pr review --request-changes --body "..."`
   - If no critical issues: `gh pr review --approve --body "..."`
   - NEVER auto-merge

7. Report the review verdict and key findings to the user.
