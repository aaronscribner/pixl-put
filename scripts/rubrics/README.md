# Agent Rubrics

Declarative pass/fail criteria for each agent, evaluated two ways:

- **`self_report`** — the agent grades itself at completion and emits the
  result via `scripts/log-run.sh --rubric '...'` into `specs/<f>/run.jsonl`.
  Cheap signal, biased toward "I did fine."
- **`ground_truth`** — the `rubric-evaluator` agent computes these
  *post-hoc* by joining `run.jsonl` against git history, PR outcomes,
  and incident logs. Honest signal but lags real-time by days/weeks.

These YAML files are the source of truth. The agent files reference them
by ID — edit a criterion here and it propagates to the next agent run
without touching the agent prompt.

## Schema

```yaml
agent: <agent-name>           # matches agents/**/<agent-name>.md
version: <int>                # bump when criteria change so reports can segment
self_report:
  - id: <kebab-case>
    description: <one line for humans>
    type: bool | score-0-5
  ...
ground_truth:
  - id: <kebab-case>
    description: <one line>
    source: <git-log | gh-pr | run-jsonl-pattern | incident-log>
    compute: <one-line pseudocode the evaluator follows>
  ...
```

## Adding a new criterion

1. Edit the relevant `<agent>.yml` here.
2. Bump `version`.
3. If `self_report`, update the agent's "Self-rubric" section in
   `agents/**/<agent>.md` to reference the new ID.
4. If `ground_truth`, update `rubric-evaluator.md`'s ground-truth pass
   to compute the new criterion.
5. Re-run `npx claude-agents` in consumer projects.

## Why YAML, not JSON

Comments. The rubric is the most opinionated part of the factory and
deserves inline explanations for "why this criterion exists."
