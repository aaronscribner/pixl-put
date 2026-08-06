---
description: Security review (OWASP, secrets, deps, IaC) of current changes
---

Run the security-reviewer agent against the current branch's changes.

Target: {ARGS}  (PR number, branch name, or empty for current branch)

0. **Pre-work — Project Precepts (REQUIRED)**. Perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent.
   - Read `roadmap/product/constitution.md`. Halt if absent.

1. Read `agents/review/security-reviewer.md` for the full protocol.

2. **Resolve target**:
   - If {ARGS} is a PR number: fetch the diff with `gh pr diff {ARGS}` (or `az repos pr show --id {ARGS} --query 'sourceRefName'` for ADO).
   - If {ARGS} is empty: use the current branch diff (`git diff main...HEAD`).
   - If {ARGS} is a branch: `git diff main...{ARGS}`.

3. **Identify feature spec** from the branch name (typically `feature/F-X.Y-slug` or `<NNN>-<slug>`) — locate `roadmap/product/<NNN>-<feature>/`. Read `spec.md` and `plan.md` for threat-model context.

4. **Execute the 5-pass scan** (see agents/review/security-reviewer.md):
   1. Secrets scan (Apple-aware — notarisation credentials, App Store Connect API keys, signing-cert passwords)
   2. Threat surface (macOS-adapted: pasteboard / URL-scheme / AppleScript injection; AX privilege creep; insecure persistence outside Application Support)
   3. Dependency advisories (`swift package show-dependencies` + GitHub Advisory DB join; Sparkle release-notes scan)
   4. Info.plist / Entitlements diff (only if `Info.plist` or `Entitlements.plist` in diff)
   5. Permission-pattern audit (`.claude/settings*.json` not loosened)

5. **Append the Security Verdict block** to `roadmap/product/<NNN>-<feature>/analysis.md`. Use the exact format in the agent file. If `analysis.md` doesn't exist yet, create it with just the verdict block (the architect and code-reviewer will append their own later).

6. **Report verdict**:
   - PASS → report summary and exit.
   - ADVISORY → report findings + advise the next agent (`qa`, `code-reviewer`, or user) on whether to proceed.
   - BLOCKING → report critical findings, list specific fixes, and **halt** — do not open a PR, do not advance the pipeline.

7. **NEVER auto-fix.** This agent only inspects and reports. Fixes are the responsibility of `software-developer` (code-level) or `devops` (pipeline/IaC-level).
