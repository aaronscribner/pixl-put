---
description: Convert a production signal (stack trace, incident, log pattern) into a draft spec
---

Run the telemetry-feedback agent against a production signal.

Target: {ARGS}  (pasted signal, telemetry URL, or empty to prompt the user)

0. **Pre-work — Project Precepts (REQUIRED)**. Perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent.
   - Read `roadmap/product/constitution.md`. Halt if absent.

   Project constitution §IV (no telemetry / no cloud sync) means there is **no production telemetry pipeline for PixPut**. This command operates only on user-pasted signals (crash reports, log excerpts) or links to Apple Feedback Assistant reports. Do not propose adding analytics / crash reporters / backend services — that's a constitution violation.

1. Read `agents/engineering/telemetry-feedback.md` for the full protocol.

2. **Resolve the signal**:
   - If {ARGS} contains a stack trace / log excerpt / incident text → use it directly.
   - If {ARGS} is an Apple Feedback Assistant URL or Sparkle GitHub issue URL → fetch it.
   - If {ARGS} is empty → prompt the user for one of: pasted crash report (`.crash` content), pasted log excerpt, or Feedback Assistant / Sparkle issue URL.

3. **Triage**: categorise as bug / reliability / performance / security / knowledge-gap. If security, **escalate immediately to `/security-review`** and stop.

4. **Locate the suspected area**: grep for unique strings from the signal — Swift type names, error messages, function names, file paths. If the origin is outside this repo (an Apple framework bug, a Sparkle issue, a macOS regression), file an upstream-bug note under `roadmap/product/upstream-bugs/<area>-<slug>.md` linking to the Feedback Assistant report (FB-NNNNNNN) or Sparkle issue, then stop.

5. **Check for duplicates**:
   - `grep -l "<unique-error-string>" roadmap/product/`
   - Scan `roadmap/product/draft-*/spec.md` for prior drafts on the same area.
   - If a duplicate is found, append to that draft's "Additional occurrences" log rather than creating a new one.

6. **Draft the spec** at `roadmap/product/draft-<short-slug>/spec.md` using the template in the agent file. Mark every assumption `[NEEDS CLARIFICATION]`.

7. **Report**:
   - Draft path.
   - Category.
   - Count of `[NEEDS CLARIFICATION]` markers.
   - One-sentence recommendation: promote (number and `/orchestrate`), merge with existing draft, or discard.

8. **NEVER promote a draft to a real spec.** Promotion is a human decision and requires a `/specify`-equivalent step or manual `git mv`.
