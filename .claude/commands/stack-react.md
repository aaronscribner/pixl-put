---
description: React Stack Context
---

Ad-hoc React task helper. Use this for one-off tasks outside the TDD pipeline — debugging, build fixes, dependency updates, or exploratory work.

**Note:** During the TDD pipeline, engineering agents load stack context automatically from `agents/stacks/react.md` based on `plan.md`. You do NOT need to call this command for pipeline work.

Task: {ARGS}

1. Read `agents/stacks/react.md` for full React platform conventions, patterns, and commands.
2. Read the constitution at `.claude/constitution.md` (if it exists).
3. If a feature spec exists for the current branch, read `plan.md` to understand architecture.
4. Read existing React source files to match project patterns (naming, structure, style).
5. Execute the task following React conventions from the stack agent:
   - Functional components with TypeScript
   - Custom hooks for reusable logic
   - React Testing Library for tests
   - Follow react.dev conventions
6. After making changes, verify:
   - `npm run build` succeeds
   - `npm test -- --run` passes
   - `npx tsc --noEmit` reports no type errors
   - `npx eslint .` reports no new issues
7. Report what was done and any issues encountered.
