---
description: Angular Stack Context
---

Ad-hoc Angular task helper. Use this for one-off tasks outside the TDD pipeline — debugging, build fixes, dependency updates, or exploratory work.

**Note:** During the TDD pipeline, engineering agents load stack context automatically from `agents/stacks/angular.md` based on `plan.md`. You do NOT need to call this command for pipeline work.

Task: {ARGS}

1. Read `agents/stacks/angular.md` for full Angular platform conventions, patterns, and commands.
2. Read the constitution at `.claude/constitution.md` (if it exists).
3. If a feature spec exists for the current branch, read `plan.md` to understand architecture.
4. Read existing Angular source files to match project patterns (naming, structure, style).
5. Execute the task following Angular conventions from the stack agent:
   - Standalone components (no NgModules for new code)
   - Angular signals for reactive state
   - New control flow syntax (@if, @for, @switch)
   - inject() function for DI
6. After making changes, verify:
   - `ng build` succeeds
   - `ng test --watch=false` passes
   - `npx eslint .` reports no new issues
7. Report what was done and any issues encountered.
