---
description: "Compact, projector-safe snapshot of what the agent has done on the current task so far — branch, commits, files touched, tests, and what is still open. Read-only. Built for dipping into a long-running implementation in front of an audience without scrolling the transcript."
---

Optional focus (may be empty): $ARGUMENTS

Print a **short status snapshot** of the work in progress on this branch. This is
read for an audience mid-presentation, so it must be scannable in five seconds.

## Rules

1. **Read-only.** Inspect git and the working tree. Change nothing, commit
   nothing, and do not resume or continue the task.
2. **Hard cap 14 lines** of output. Cut detail rather than wrapping.
3. **Never invent.** Anything you cannot determine prints `not available`.
4. **No commentary.** No "great progress", no next-step suggestions unless the
   `open` line needs one clause. The presenter narrates.
5. **Never print secret values.**

## What to gather

- Current branch, and the commit it forked from.
- Commits made on this branch so far: count, and each subject line (most recent
  first, up to 4, `…` if more).
- Files changed versus the fork point: count and `+added / -removed`, then up to
  5 paths.
- Whether the working tree has uncommitted changes (count only).
- If a plan exists for this task — a saved plan from the workspace plugin, or a
  plan/TODO file in the repo — the number of steps and how many are done.
- If the project has an obvious test command that has already been run in this
  session, its last result. Do **not** run tests yourself.

## Output format

```
── status · <branch> ──────────────────────────────

  from      <base branch or short sha>
  commits   <n>
            <subject>
            <subject>
  changed   <n> files, +<added> / -<removed>
            <path>
            <path>
  uncommitted  <n> files
  plan      <done>/<total> steps
  tests     <last known result, or "not run">
  open      <one line: what is in flight right now>

───────────────────────────────────────────────────
```

Omit any row that is genuinely not applicable rather than padding it. If
`$ARGUMENTS` names a focus (e.g. a path or "tests"), keep the shape and
prioritise that row.
