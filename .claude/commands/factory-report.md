---
description: Generate a factory-coaching report on demand from run.jsonl + ground truth
---

Run the `rubric-evaluator` agent against the run-telemetry window.

Target: {ARGS}   (optional `--since <Nd|Nw>`; default: 7d)

0. **Pre-work — Project Precepts (REQUIRED)**. Perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent.
   - Read `roadmap/product/constitution.md`. Halt if absent.

1. Read `agents/engineering/rubric-evaluator.md` for the full protocol.

2. **Resolve the window**:
   - If {ARGS} contains `--since <Nd|Nw>` → pass it through.
   - Default → `--since 7d`.

3. **Verify substrate**:
   - Ensure `scripts/rubric.mjs` is present and executable.
   - Ensure `scripts/rubrics/` contains the per-agent YAMLs (run `node scripts/rubric.mjs validate` to confirm).
   - If either is missing, halt: "Run `npx claude-agents` to install the rubric substrate."

4. **Run the deterministic aggregator first**:
   ```bash
   node scripts/rubric.mjs aggregate --since 7d > /tmp/rubric-raw.json
   node scripts/rubric.mjs by-agent --since 7d > /tmp/rubric-by-agent.json
   ```
   These outputs are the factual baseline for the report. Every later claim must cite a row from them.

5. **Execute the rubric-evaluator agent's 5-pass process** (Raw stats → Ground-truth join → Factory-level metrics → Diagnose drift → Coaching report).

6. **Write the report** to `roadmap/agent-coaching/<YYYY-MM-DD>.md` (on-demand reports use date stamps; the scheduled weekly run uses ISO week stamps `<YYYY-WW>.md`).

7. **Self-rubric + log**:
   ```bash
   scripts/log-run.sh roadmap/agent-coaching rubric-evaluator on-demand OK \
     --rubric '{"raw-stats-cited":true,"every-claim-traces":true,"no-agent-file-edits":true,"trend-window-checked":true}'
   ```

8. **Report** to the user:
   - Report path.
   - Headline: how many agents are drifting (self-report >> ground-truth).
   - Top 1–3 recommended human actions, each linking to the agent-file section.

9. **NEVER edit agent files.** This command is report-only. Recommended actions are surfaced for human review; the human (or a follow-up session) edits agent prompts and bumps the install-package version.
