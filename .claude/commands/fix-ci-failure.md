---
description: DevOps triage of a failed Azure Pipelines or GitHub Actions run
---

Triage a failed CI/CD pipeline run via the devops agent.

Target: {ARGS}  (pipeline run URL or run ID)

0. **Pre-work — Project Precepts (REQUIRED)**. Perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent.
   - Read `roadmap/product/constitution.md`. Halt if absent.

1. Read `agents/engineering/devops.md` for the full triage protocol.

2. **Resolve the failed run**:
   - Azure Pipelines URL — extract `<organization>` / `<project>` / `<run-id>`; use `az pipelines runs show --id <run-id>` and `az pipelines runs artifact list --run-id <run-id>`.
   - GitHub Actions URL — extract `<owner>/<repo>/actions/runs/<run-id>`; use `gh run view <run-id> --log-failed`.
   - Bare run ID — assume current repo's pipeline.

3. **Fetch the failed step log**. Locate the first failing step and capture stage / job / step name + the surrounding ~20 lines of output.

4. **Classify** per the devops agent's taxonomy:
   - `test-failure` — return to developer; do not silence the test.
   - `flaky` — propose retry policy.
   - `config-drift` — propose the variable / service-connection / signing-identity / notarisation-credential fix.
   - `code-regression` — return to developer.
   - `pipeline-bug` — propose minimal YAML / shell-script fix.
   - `notarisation-rejection` — read `xcrun notarytool log <submission-id>` and surface the specific binary / Info.plist issue.

5. **Write a triage note** to `roadmap/product/<NNN>-<feature>/devops-triage.md` (locate the spec from the branch that triggered the run). Use the exact format in the agent file. If no matching spec exists (e.g., main-branch scheduled build), write to `devops-triage/<ISO timestamp>.md` at the repo root.

6. **NEVER auto-commit a pipeline fix.** The triage note contains the suggested diff; the user (or a follow-up `software-developer` / `devops` authoring session) decides whether to apply it.

7. **Report**:
   - Classification.
   - Single proposed action.
   - Triage-note path.
   - Whether human approval is required before applying (almost always: yes).
