---
description: Swift Stack Context
---

Ad-hoc Swift (iOS + macOS) task helper. Use this for one-off tasks outside the TDD pipeline — debugging, build fixes, dependency updates, or exploratory work.

**Note:** During the TDD pipeline, engineering agents load stack context automatically from `agents/stacks/swift.md` based on `plan.md`. You do NOT need to call this command for pipeline work.

Task: {ARGS}

1. Read `agents/stacks/swift.md` for full Swift platform conventions, patterns, and commands.
2. Read the constitution at `.claude/constitution.md` (if it exists).
3. If a feature spec exists for the current branch, read `plan.md` to understand architecture.
4. Read existing Swift source files to match project patterns (naming, structure, style).
5. Execute the task following Swift conventions from the stack agent:
   - Use Swift concurrency (async/await)
   - Follow Apple HIG
   - Use SwiftUI or UIKit as established
   - XCTest or Swift Testing as established
6. After making changes, verify:
   - `swift build` succeeds
   - `swift test` passes
   - `swiftlint` reports no new issues
7. Report what was done and any issues encountered.
