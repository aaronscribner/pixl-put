---
description: Electron Stack Context
---

Ad-hoc Electron desktop task helper. Use this for one-off tasks outside the TDD pipeline — debugging, build fixes, dependency updates, or exploratory work.

**Note:** During the TDD pipeline, engineering agents load stack context automatically from `agents/stacks/electron.md` based on `plan.md`. You do NOT need to call this command for pipeline work.

Task: {ARGS}

1. Read `agents/stacks/electron.md` for full Electron platform conventions, patterns, and commands.
2. Read the constitution at `.claude/constitution.md` (if it exists).
3. If a feature spec exists for the current branch, read `plan.md` to understand architecture.
4. Read existing Electron source files to match project patterns (naming, structure, style).
5. Execute the task following Electron conventions from the stack agent:
   - Strict process separation (main/preload/renderer)
   - contextBridge for IPC
   - Security checklist compliance
   - Type-safe IPC channels
6. After making changes, verify:
   - `npm run build` succeeds
   - `npm test` passes
   - Security checklist items maintained
   - `npx eslint .` reports no new issues
7. Report what was done and any issues encountered.
