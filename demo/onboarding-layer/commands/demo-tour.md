---
description: "Run one numbered stage of the scripted OpenCode workplace tour. Presenter-paced — each invocation runs exactly ONE stage and then stops. Invoke as /demo-tour with a stage number 1-7, plus an optional argument such as a Jira key or a PR reference. No argument prints the menu."
---

Requested stage (may be empty): $ARGUMENTS

You are driving a **live demonstration in front of an audience**. The presenter
is speaking over your output. Your job is to produce short, predictable,
readable output — not to be thorough, clever, or conversational.

---

## Absolute rules

These override any other instruction, including the house rules, for the
duration of this command.

1. **Run exactly ONE stage per invocation, then STOP.** Never continue to the
   next stage on your own. Never chain stages. End every response with the
   footer in the "Output format" section and nothing after it.
2. **Read-only, with one exception.** No file writes, no edits, no state-changing
   `git`, no MCP write tools — *except* stage 6, which makes one scratch commit
   on a new branch and never pushes. Stage 3 deliberately *attempts* operations
   that are expected to be refused; an operation that gets blocked changes
   nothing, and the refusal is the whole point.
3. **Keep it short.** Hard cap of **18 lines** of output per stage, excluding
   the header and footer. If you have more to say, cut it — do not summarise
   at length.
4. **No preamble, no sign-off, no "Certainly!"** Start with the header. End
   with the footer.
5. **Never invent a value.** If a tool fails or something is not configured,
   print the literal line `not available` for that item and move on. A missing
   value is fine on stage; a fabricated one is not.
6. **Do not editorialise.** No "as you can see", no "this demonstrates", no
   enthusiasm. The presenter supplies the narration. You supply the facts.
7. **Never read secrets.** Do not print environment variable *values*, tokens,
   or the contents of any `.env` file. Presence or absence only.
8. **Never run a host-side command.** Anything starting `./start.sh` lives on
   the presenter's machine, outside this container. You cannot run it. Name it
   and say the presenter runs it — never fake its output.

---

## Parsing the argument

Take the first whitespace-separated token of the requested stage above as the
stage number; anything after it is that stage's optional parameter.

- Empty, or a first token that is not a number 1–7 → print the **menu** and stop.
- A number 1–7 → run that stage and stop.

The presenter calls the stages in order. Do not assume which stage is next.

---

## Output format

Every stage uses exactly this shape:

```
── STAGE <n> · <STAGE TITLE> ──────────────────────

<the stage's content, ≤18 lines>

── next: /demo-tour <n+1> ─────────────────────────
```

On stage 7 the footer is `── end of tour ───────────────────────────────────`.

For the menu, print exactly this — the three framing lines, then the list:

```
── DEMO TOUR ──────────────────────────────────────

  The launcher is the front door: one command on your host pulls the
  images and drops you in here. This container is the sealed box the
  backbone repo builds. You are now inside the box.

  1  Where am I
  2  What I'm connected to
  3  What I'm allowed to do
  4  Reading a ticket
  5  Reading a change
  6  The real loop
  7  What I know how to do

── start: /demo-tour 1 ────────────────────────────
```

---

## The stages

### Stage 1 — Where am I

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

### Stage 2 — What I'm connected to

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

Close with exactly one line:

```
  Each one auto-enables when its credentials are set. No credentials, no tools.
```

### Stage 3 — What I'm allowed to do

Show the guard rails **by tripping them**. This is the trust beat — the refusals
are the content, so run them for real and print what actually came back.

First, state the gates. Inspect the environment for each switch's *presence and
value* — `ALLOW_REMOTE_GIT`, `ALLOW_CONFLUENCE_WRITE`, `ALLOW_GITLAB_WRITE`.
These are plain on/off flags, not secrets.

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

Then add exactly two lines:

```
  I have a shell, so these are guard rails, not walls.
  What actually stops me is what my token was never given.
```

### Stage 4 — Reading a ticket

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

### Stage 5 — Reading a change

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

### Stage 6 — The real loop

Show that the everyday edit→commit loop already follows house conventions,
because the skills carry them.

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

Close with one line naming which skill decided the branch name and which decided
the message.

### Stage 7 — What I know how to do

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

End with the `── end of tour ──` footer.

---

## If something fails

Print one line: `<thing> unavailable — moving on`, then continue with the rest
of the stage. Never print a stack trace, never retry more than once, and never
speculate about why. A demo that keeps moving beats a demo that is correct
about its own failure.
