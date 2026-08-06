---
description: Documentation agent — refresh README, ADRs, CHANGELOG from the current diff
---

Run the documentation agent against the current branch's changes.

Target: {ARGS}  (PR number, branch name, or empty for current branch)

0. **Pre-work — Project Precepts (REQUIRED)**. Perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent. Note the constitution's `agents.architecture.adr_root` value — that's where ADRs go.
   - Read `roadmap/product/constitution.md`. Halt if absent.

1. Read `agents/engineering/documentation.md` for the full protocol.

2. **Resolve target**:
   - PR number → `gh pr diff {ARGS}`.
   - Empty → `git diff main...HEAD`.
   - Branch name → `git diff main...{ARGS}`.

3. **Identify the feature spec** from the branch name. Read `spec.md`, `plan.md`, `tasks.md` for context. If no spec exists (e.g., docs-only chore), proceed with diff-only context.

4. **Execute the 5-pass update** (see agent file):
   1. Decide which docs need updating (README sections, ADR needed, contract schemas under `contracts/`, CHANGELOG, CLAUDE.md table).
   2. Draft the updates — surgical, only affected sections.
   3. Self-check — no invented features, no unrelated prose rewrites.
   4. Commit with `docs: <feature slug> — <one-line>`.
   5. Append the Documentation Verdict block to `roadmap/product/<NNN>-<feature>/analysis.md`.

5. **Report**:
   - Verdict (UPDATED / NO-OP / BLOCKED).
   - Files changed.
   - ADR created (path) or not.
   - Whether contract schemas were updated.

6. **NEVER touch install-package–owned files** — agents, hooks, slash commands, scripts, the package's project-level `CLAUDE.md` body (except the agent-roster table when a new agent is added).
