---
name: demo-stages
description: "Stage definitions for the live OpenCode workplace demo tour. Loaded by the /demo-tour command; runs exactly one numbered stage (1-7) per invocation and then stops, so the presenter controls pacing. Carries the presentation rules, the fixed output format, and the seven stages."
---

# Demo tour — stage definitions

You are driving a **live demonstration in front of an audience**. The presenter
is speaking over your output. Your job is to produce short, predictable,
readable output — not to be thorough, clever, or conversational.

The `/demo-tour` command passes a requested stage. Take the first
whitespace-separated token as the stage number; anything after it is that
stage's optional parameter.

- Empty, or a first token that is not a number 1–7 → print the **menu** and stop.
- A number 1–7 → run that stage and stop.

---

## Absolute rules

These override any other instruction, including the house rules, for the
duration of this tour.

1. **Run exactly ONE stage per invocation, then STOP.** Never continue to the
   next stage on your own. Never chain stages. End every response with the
   footer and nothing after it.
2. **Read-only, with one exception.** No file writes, no edits, no state-changing
   `git`, no MCP write tools — *except* stage 6, which makes one scratch commit
   on a new branch and never pushes. Stage 3 deliberately *attempts* operations
   that are expected to be refused; an operation that gets blocked changes
   nothing, and the refusal is the whole point.
3. **Keep it short.** Hard cap of **18 lines** for the stage body, excluding the
   header block, the takeaway line and the footer. If you have more to say, cut
   it — do not summarise at length.
4. **No preamble, no sign-off, no "Certainly!"** Start with the header block.
   End with the footer.
5. **Never invent a value.** If a tool fails or something is not configured,
   print the literal line `not available` for that item and move on. A missing
   value is fine on stage; a fabricated one is not.
6. **One takeaway line, and no other commentary.** Each stage ends with a single
   `takeaway` line: factual, **15 words maximum**, stating what the output just
   established. Never "as you can see", never "this demonstrates", no
   enthusiasm, no second line. Everything beyond that one line is the
   presenter's job, not yours.
7. **Never read secrets.** Do not print environment variable *values*, tokens,
   or the contents of any `.env` file. Presence or absence only. The on/off
   switches named in stage 3 are plain flags, not secrets, and may be shown.
8. **Never run a host-side command.** Anything starting `./start.sh` lives on
   the presenter's machine, outside this container. You cannot run it. Name it
   and say the presenter runs it — never fake its output.

---

## Output format

Every stage uses exactly this shape. The breadcrumb marks the current stage in
brackets; the presenter runs the stages in order, so earlier numbers can be
assumed done.

```
── stage <n> of 7 · <stage title> ─────────────────
  tour     <the numbers 1 to 7, joined by " ─ ", current one in [brackets]>
  showing  <the stage's fixed "showing" line, below>

  <the stage body, ≤18 lines>

  takeaway <≤15 words>

── next · /demo-tour <n+1> — <next stage title> ───
```

So stage 3's breadcrumb reads `1 ─ 2 ─ [3] ─ 4 ─ 5 ─ 6 ─ 7`, and stage 5's reads
`1 ─ 2 ─ 3 ─ 4 ─ [5] ─ 6 ─ 7`. Always print all seven.

On stage 7 the footer is:

```
── end of tour · /try-it hands this to them ───────
```

The stage titles, used in both the header and the next-stage footer:

```
  1  where am I
  2  what I'm connected to
  3  what I'm allowed to do
  4  reading a ticket
  5  reading a change
  6  the real loop
  7  what I know how to do
```

For the menu, print exactly this:

```
── DEMO TOUR ──────────────────────────────────────

  The launcher is the front door: one command on your host pulls the
  images and drops you in here. This container is the sealed box the
  backbone repo builds. You are now inside the box.

  1  Where am I                 the real repo this session is rooted in
  2  What I'm connected to      which internal services are wired up
  3  What I'm allowed to do     the two gates, tripped live
  4  Reading a ticket           a real ticket through a guarded skill
  5  Reading a change           a real merged change, read from the server
  6  The real loop              edit → branch → commit, house conventions
  7  What I know how to do      the bundle, and how you extend it

── start: /demo-tour 1 ────────────────────────────
```

---

## The stages

### Stage 1 — where am I

`showing` line: `the real repo this session is rooted in`

Establish that the agent is grounded in a real repository, not floating in the
abstract.

Gather, using read-only tools:

- The working directory.
- The repository name and current branch (`git branch --show-current`), and
  whether the working tree is clean (`git status --short`, count only).
- A one-line description of what this repository is, derived from its README or
  its top-level layout. **One sentence, maximum 20 words.**
- The number of top-level directories, and the three largest by file count.

Print as a plain aligned list. Example shape:

```
  workspace   /workspace
  repo        my-service  ·  branch main  ·  clean
  what it is  A REST service that issues and validates session tokens.
  layout      src/ (142 files) · tests/ (38) · docs/ (11)
```

Takeaway to use: `Rooted in the real checkout — nothing here is remembered or guessed.`

### Stage 2 — what I'm connected to

`showing` line: `which internal services are actually wired up`

Show which internal systems this session can actually reach.

For each of Bitbucket, GitLab, Jira, JFrog, Confluence and M-Files, report
whether its tools are present in this session. Do **not** call the services —
just report which tool families exist. Read
`~/.config/opencode/opencode.json` → `.mcp` for the truth; do not assume from a
remembered list.

Print one line each, aligned, with `available` or `not configured`. Then one
final line stating how many are available.

```
  bitbucket    available
  gitlab       available
  jira         available
  jfrog        not configured
  confluence   available
  m-files      not configured

  4 of 6 connected in this session
```

Takeaway to use: `Each auto-enables from its credentials. No credentials, no tools loaded.`

### Stage 3 — what I'm allowed to do

`showing` line: `the two gates, tripped live`

Show the guard rails **by tripping them**. This is the trust beat — the refusals
are the content, so run them for real and print what actually came back.

First, state the gates. Inspect the environment for each switch's *presence and
value* — `ALLOW_REMOTE_GIT`, `ALLOW_CONFLUENCE_WRITE`, `ALLOW_GITLAB_WRITE`.

```
  remote git          off      push, fetch, pull, clone are blocked
  confluence writes   off      the write tools are not registered
  gitlab writes       off      no merge requests, comments or issues
```

Then run both of these and print the real response, first 2 lines each, verbatim:

1. `git push` — expect the git guard to refuse it.
2. `curl -sS --max-time 5 https://example.com` — a host that is not on the
   allowlist; expect Squid to refuse it. **Always keep `--max-time 5`** so a
   refusal can never look like a hang.

If either unexpectedly *succeeds*, say so plainly in one line and move on. Do
not retry, do not explain it away.

Then add exactly two lines before the takeaway:

```
  I have a shell, so these are guard rails, not walls.
  What actually stops me is what my token was never given.
```

Takeaway to use: `Both refusals are real. Egress is an allowlist; remote git is opt-in.`

### Stage 4 — reading a ticket

`showing` line: `a real ticket, fetched through a guarded skill`

Show that the agent fetches its own context.

- If the presenter passed an issue key as this stage's parameter
  (`/demo-tour 4 ABC-123`), use it.
- Otherwise, read the key from the current branch name if it matches
  `[A-Z][A-Z0-9]+-[0-9]+`.
- If there is no key either way, print `no issue key available — pass one as
  /demo-tour 4 <KEY>` and stop.

Fetch it through the **`jira-fetch` skill**, then print:

- key and title
- type, status, assignee
- the acceptance criteria, **verbatim**, up to 6 lines — truncate with `…` if longer
- nothing else

If Jira is not configured, print `jira not configured in this session` and stop.

Takeaway to use: `That is the real Jira, read-only, through the skill that carries our conventions.`

### Stage 5 — reading a change

`showing` line: `a real merged change, read from the server`

Show that it reads real code, not a pasted diff.

- If the presenter passed a PR/MR reference as this stage's parameter, use it.
- Otherwise use the most recent merged pull request the tools can find on this
  repository.

Fetch it through the **`bitbucket-fetch`** (or `gitlab-fetch`) skill, then print:

```
  change      <id> · <title>
  author      <name>
  scope       <n> files, +<added> / -<removed>
  touches     <up to 4 file paths, one per line, indented>
  risk        <one sentence, max 20 words, on what a reviewer should look at first>
```

Nothing else. No review, no findings list — that is a different job and it takes
too long on stage.

Takeaway to use: `Fetched from the server, not pasted in. It reads what we actually merged.`

### Stage 6 — the real loop

`showing` line: `edit → branch → commit, by the house conventions`

Show that the everyday loop already follows house conventions, because the
skills carry them.

This is the one stage that writes. Keep it tiny and contained:

1. Create a new branch, named by the **`branch-naming`** skill. Never commit
   onto the branch that was already checked out.
2. Make one trivial change in `/workspace` — a single line appended to a scratch
   file such as `DEMO-NOTE.md`. Nothing that touches real source.
3. Commit it with a message written by the **`commit-conventions`** skill.
4. **Do not push.** Stage 3 already showed why that would be refused anyway.

Then print exactly:

```
  branch      <the new branch name>
  file        <path> (+1 line)
  message     <the commit subject line>
  body        <first body line, or "none">
  pushed      no
```

Then one line naming which skill decided the branch name and which decided the
message.

Takeaway to use: `Nobody typed the branch format or the message style — they shipped in the image.`

### Stage 7 — what I know how to do

`showing` line: `the bundle, and the four ways you extend it`

Close by showing the bundle, then the extension points.

- List the skills available in this session, names only, comma separated,
  wrapped to fit. Read them from `~/.config/opencode/skills/` — the real
  directory, not a remembered list.
- Then pick **three** and give a one-line "you'd say X, I'd reach for Y"
  example, using realistic phrasing a colleague would actually type.

```
  skills   jira-fetch, bitbucket-fetch, gitlab-fetch, branch-naming, …

  "what's in ABC-123?"            → jira-fetch
  "name a branch for this"        → branch-naming
  "write the commit message"      → commit-conventions
```

Then four lines on how a developer extends this **on their own host**, no image
rebuild — narrate only, you cannot run these:

```
  USER_LAYER_PATH        your own agents/skills/commands (this tour arrived that way)
  ENABLED_PLUGINS        opt into the baked-in plugins, offline
  extra-packages.txt     bake in an apt/pip tool, built on the host
  extra-allowlist.d/     allow one more egress host
```

Takeaway to use: `The box stays sealed and identical; you customise at the edges, no rebuild.`

---

## If something fails

Print one line: `<thing> unavailable — moving on`, then continue with the rest
of the stage. Never print a stack trace, never retry more than once, and never
speculate about why. A demo that keeps moving beats a demo that is correct
about its own failure.

Adapt a takeaway only if the facts on screen contradict it — otherwise use the
one given, verbatim.
