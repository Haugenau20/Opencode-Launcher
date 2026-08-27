# OpenCode Workplace — Presenter Run-Sheet

A back-and-forth demo: you boot the launcher, then hand the room over to the
agent one stage at a time. Two repos on stage — the **launcher** (the front door
your colleagues run on their host) and the **backbone** (the repo that builds the
locked-down image they land in). The demo content ships as a **user layer** on
top of a stock released image, so there is **no custom image to build**.

> One sentence to open with: *"You run one command on your machine; it drops you
> into a sealed box that already knows your tools, your conventions, and what
> it's allowed to touch. Let me show you."*

---

## 0. The story (your through-line)

1. **First-time setup is one command** → `./start.sh <repo>`.
2. **You land in a sealed box** → bundle, house rules, MCP — all baked in.
3. **The box can't misbehave** → git guard + egress wall, watch them trip.
4. **It does real work while you talk** → a plan you approve, then an
   implementation running in the background you dip into.
5. **You customize at the edges, not the core** → this very demo is a user-layer
   add-on, which is the proof.
6. **They can do this themselves** → hand off `/try-it`.

Keep returning to: *launcher = front door, backbone = the box.*

> **Show process, not outcome.** The implementation thread is not there to
> produce good code in twenty minutes — it is there to show the shape of the
> working relationship: you scope, it plans, you amend and approve, it executes,
> you check in. If the code it writes is mediocre, *say so on stage and show
> where you'd intervene* — that is a more honest and more persuasive demo than a
> clean diff. Never let the room think the pitch is "it writes perfect code."

---

## 1. Before the room (pre-flight checklist)

Do this the day before **and** 10 minutes before:

- [ ] **Rehearse the whole thing once, end to end.** Non-negotiable — the live
      MCP fetch and the image pull are the two things most likely to surprise you.
- [ ] **`docker login <registry-host>`** so the image pull doesn't stall on auth.
- [ ] **Set `USER_LAYER_PATH=./demo/onboarding-layer`** in the launcher `.env`.
      That single line is what makes `guide` / `/demo-tour` / `/try-it` appear.
      Confirm with `./start.sh --doctor` — it reports `USER_LAYER_PATH`.
- [ ] **Use a normal released `IMAGE_TAG`** (e.g. `latest` or a pinned version).
      The demo content rides on top via the user layer, not in the image.
- [ ] **Pick a demo repo** with a git remote and something to look at — small and
      uncontroversial. It mounts at `/workspace`. **Stage 6 commits to it**, so
      use a scratch clone, or be ready to clean up (see §4).
- [ ] **Services for the live fetch:** put real **Jira** (and/or Bitbucket)
      creds in `.env` so stages 4 and 5 actually return something. This is the
      "whoa" moment — make sure it works in rehearsal.
- [ ] **Leave `ALLOW_REMOTE_GIT=0`** (the default) so the git guard trips on cue
      in stage 3.
- [ ] **Enable a couple of plugins** so `/plugins` shows ON rows, not all OFF.
- [ ] **Stage the implementation thread.** Pick the repo and cut the throwaway
      branch *now* (`git checkout -b demo/throwaway-<date>`). Have the task
      sentence written down verbatim — you will paste it, not improvise it.
- [ ] **Rehearse that exact task on that exact branch.** You need a feel for how
      long the plan takes and roughly how far it gets. Reset the branch after.
- [ ] **Second instance for the tour.** The tour and the implementation thread
      should not share a session. Give the second one its own `PROJECT_SLUG` and
      `OPENCODE_PORT` so nothing collides — that separation is itself worth
      naming on stage.
- [ ] **If your endpoint is Qwen, leave `opencode-workspace` OUT of
      `ENABLED_PLUGINS`.** The tools and system prompt it injects are rejected by
      Qwen's upstream and *every* prompt then fails with `AI_APICallError`. That
      would end the demo. `superpowers` and `dcp` are safe.
- [ ] **Terminal: big font, dark theme, wide window.** Two windows side by side —
      implementation thread on one, tour on the other — plus a host terminal tab.
- [ ] **Confirm the egress refusal is fast.** In rehearsal, run
      `curl -sS --max-time 5 https://example.com` inside the box and check Squid
      refuses it rather than hanging.

---

## 2. The demo `.env` (launcher checkout)

Pre-stage this as `<launcher>/.env` (fill the real values). Pre-staging is the
low-risk default for a live room; the wizard is the alternative (see below).

```dotenv
# --- required ---
LLM_API_BASE=https://llm.internal.example/v1
LLM_API_KEY=<your bearer token>
IMAGE_REGISTRY=<your.artifactory.example>/opencode-workplace
IMAGE_TAG=latest

# --- the demo content (user layer, no image rebuild) ---
USER_LAYER_PATH=./demo/onboarding-layer

# --- make stages 4 and 5 light up ---
JIRA_BASE_URL=https://jira.internal.example
JIRA_PAT=<jira pat>
BITBUCKET_BASE_URL=https://bitbucket.internal.example
BITBUCKET_USER=<user>
BITBUCKET_PAT=<bitbucket pat>

# --- gates stay at defaults so they trip on cue in stage 3 ---
ALLOW_REMOTE_GIT=0

# --- show some plugins ON in /plugins ---
ENABLED_PLUGINS=superpowers dcp
```

> If you'd rather show the wizard live: delete `.env` first, run `./start.sh
> <repo>`, and let the ncurses editor walk you through it — secrets go into a
> hidden passwordbox, so no key ever reaches the projector. Required fields are
> marked `(REQUIRED)` and it won't finish until they're set. `USER_LAYER_PATH`
> is in the wizard's schema too (listed as *User layer*, optional), so you can
> set it there rather than by hand.

---

## 3. Run of show

Two threads run at once. **Thread A** is a real task on a throwaway branch: it
cooks while you talk and you dip into it. **Thread B** is what you do in the
foreground — slides and the tour — while A works.

| Time | Thread A — the real task | Thread B — foreground |
|---|---|---|
| 0–3 | boot instance A on the demo repo | Act 1: first-time setup, live |
| 3–5 | paste the task, ask for a **plan only** | narrate what you just asked for |
| 5–12 | *planning* | slides |
| 12–15 | come back, **amend one thing**, approve, say implement | the approval beat — this is the money shot |
| 15–25 | *implementing* | Act 2: the tour, in instance B |
| ~20 | `/demo-status` — 20-second dip-in | "let's see where it got to" |
| 25–28 | land it: `/demo-status`, skim the diff, honest verdict | Act 3: customizing |
| 28–30 | — | Act 4: handoff |

Rules for yourself:

- **Never wait for Thread A on stage.** If it is not ready when you arrive,
  say "still going — let's come back" and continue. Dead air is the only real
  failure mode here.
- **Dip in with `/demo-status`, not by scrolling.** One command, fourteen lines,
  no wall of transcript in front of the room.
- **Amend the plan before approving.** Approving as-is teaches the wrong lesson.
  Change one step, out loud, so the room sees who is in charge.

### Thread A — setting the task going · ~2 min

In instance A, on the throwaway branch, paste your prepared sentence and ask for
**a plan only, no code yet**. Something with visible structure and a test story
works best; avoid anything that needs network beyond the allowlist, and avoid
anything whose success is invisible.

Say while it starts: *"I'm not asking it to write anything yet. I want to see
what it thinks the job is before it touches my repo."*

Then leave it and go to slides.

### Thread A — the approval beat · ~3 min

This is the most important three minutes of the demo. Come back, read the plan
on screen, and **change something** — cut a step, reorder two, add a constraint
it missed. Then approve and tell it to implement.

Lines worth having ready:

- *"This is the part people miss. It didn't start typing — it told me what it
  was going to do, and I got to disagree."*
- *"I'm cutting step 4. Not because it's wrong, because it's not what I asked
  for."*
- *"Now it goes. And I'm going to ignore it for ten minutes."*

### Thread A — landing it · ~3 min

Come back with `/demo-status`, then skim the actual diff. Give an honest verdict
in one sentence — good, mediocre, or off-track — and say what you'd do next.

If it went well: *"That's roughly what I'd have written, in the time it took me
to do the last three slides."*

If it went badly: *"This is not what I wanted, and that's worth showing. Here's
the point where I'd stop it and re-scope."* **This is not a failed demo.** A room
that has only seen polished agent demos will trust this one more.

### Act 1 — First-time setup (host terminal) · ~3 min

| You do | You say | They see |
|---|---|---|
| `cd <launcher>` then `./start.sh ~/code/demo-repo` | "One command. It copies `.env.example` to `.env`, pulls the images from Artifactory, and wires them together." | boot logs, image pull |
| *(if showing the wizard)* walk the ncurses fields | "Three things are required — LLM endpoint, key, registry. Everything else is optional. Secrets are hidden." | the whiptail editor |
| let it finish | "Notice the **sha256 digest** it printed — that's a reproducibility and tamper anchor; a tag can move, a digest can't." | `image: …@sha256:…`, then the TUI |
| TUI attaches at `/workspace` | "We're inside the box, rooted at my repo. Exiting here tears the whole stack down — one command in, one command out." | the OpenCode TUI |

> Prompt tag check: point at the `git:ro` tag — "remote git is off by default;
> you'll see why in a moment."

### Act 2 — The tour (`/demo-tour`) · ~10–12 min

**Run this in instance B**, so the implementation thread in A keeps its context
clean and keeps running.

Type **`/demo-tour`** with no argument to get the menu, then call the stages
by number. **Each call runs exactly one stage and stops** — you control pacing,
so talk between them. Each stage prints a breadcrumb (`1 ─ 2 ─ [3] ─ …`), a
one-line `showing`, and a footer naming the next stage by title, so neither you
nor the room has to remember where you are.

| Call | The moment | Your line |
|---|---|---|
| `/demo-tour 1` | It reads the real repo — branch, cleanliness, layout. | "It's grounded in my actual checkout, not guessing." |
| `/demo-tour 2` | Inventory of which internal services are wired up. | "No credentials, no tools. It can't reach what it wasn't given." |
| `/demo-tour 3` | **It tries `git push` and `curl example.com` — both refused, live.** | **The trust beat. Let the refusals sit on screen. Don't talk over them.** |
| `/demo-tour 4 <KEY>` | A real Jira ticket through the guarded skill. | "That's our Jira. Read-only, through a skill that carries our conventions." |
| `/demo-tour 5` | A real merged PR — scope, files, what to review first. | "Real code from Bitbucket, not a pasted diff." |
| `/demo-tour 6` | Branch + commit, both named by the house skills. No push. | "Nobody told it our branch format. It shipped with it." |
| `/demo-tour 7` | The bundle, plus the four host-side extension points. | "And this tour itself came in through the first one." |

> If a stage misbehaves, that's *content*: "See — it refused, and it told us
> exactly why. That's the point." Never paper over it. The tour is instructed to
> print `not available` rather than invent anything.

### Act 3 — Customizing at the edges (host terminal) · ~3 min

Flip to your second host terminal:

```bash
./start.sh --doctor          # PASS/WARN/FAIL health report (paste-safe)
./start.sh --show-allowlist  # the honest egress picture
./start.sh --status          # what's running, the resume command, the digest
```

Then *talk through* (no need to run): `extra-packages.txt` (bake in apt/pip
tools, built on the host's real internet, runtime stays locked),
`extra-allowlist.d/*.conf` (extend egress), `USER_LAYER_PATH` (host-editable
personal skills — *"exactly how this demo got in"*), `ENABLED_PLUGINS`, and
pinning `IMAGE_TAG` to a digest.

> The punchline: *"The shared box stays sealed and identical for everyone; you
> customize at the edges, on your own machine, without a rebuild."*

### Act 4 — Handoff · ~1 min

"Everything you saw, you can redo at your own pace. Inside the TUI, run
**`/try-it`** — it walks you through the launcher commands on your host and the
live moves in here, one checkpoint at a time. And the **`guide`** agent (Tab) is
always there to answer questions."

---

## 4. Cleanup after the demo

Thread A leaves a throwaway branch with real commits on it. That was the point —
delete it:

```bash
git -C <demo repo> checkout main
git -C <demo repo> branch -D demo/throwaway-<date>
```

Stage 6 of the tour separately leaves a branch and one commit in the repo you
mounted for instance B:

```bash
git -C ~/code/demo-repo checkout -   # back to where you started
git -C ~/code/demo-repo branch -D <the demo branch>
git -C ~/code/demo-repo clean -fd    # if the scratch file was left untracked
```

Nothing was pushed — stage 3 established that it can't be.

To pack the demo away entirely: blank `USER_LAYER_PATH` in `.env`. The agent,
the two commands and the whole tour disappear on the next `./start.sh`; the
image and bundle were never touched.

---

## 5. If it breaks (fast recovery)

| Symptom | Likely cause | Say / do |
|---|---|---|
| Pull stalls on `unauthorized`/`denied` | not logged into Artifactory | `docker login <registry-host>`; `--doctor` prints the exact command |
| `permission denied` from Docker | not in `docker` group | `sudo usermod -aG docker $USER && newgrp docker` |
| `/demo-tour` / `guide` not found | user layer not mounted | check `USER_LAYER_PATH` in `.env` and that the files are under it; `--doctor` reports it; re-run `./start.sh` |
| Live Jira fetch returns nothing | creds unset / wrong base URL | pivot: "no creds here, so the tools aren't even loaded — they auto-enable when you add them." That's the security model, not a failure |
| `git push` *succeeds* in stage 3 | `ALLOW_REMOTE_GIT=1` leaked in | set it to `0`, re-run; the prompt should read `git:ro` |
| `curl example.com` hangs | timeout dropped | the tour always uses `--max-time 5`; the refusal is the point |
| Stage runs long / rambles | model ignored the line cap | just call the next stage; don't debug on stage |
| `/demo-tour` repaints its whole body | skill hop failed; body inlined | harmless, keep going — it still runs the stage |
| Thread A not done when you arrive | task bigger than rehearsed | "still going, let's come back" — never wait on stage |
| Thread A went off the rails | unattended agent, real risk | **show it.** "Here's where I'd stop it and re-scope" |
| Every prompt fails `AI_APICallError` | `opencode-workspace` + Qwen | drop it from `ENABLED_PLUGINS`, restart |
| Web UI session opens at `/` | known upstream default | TUI is unaffected; in the web UI click New session → type `/workspace` |

---

## 6. One-screen cheat-sheet

```
# host
cd <launcher>
./start.sh ~/code/demo-repo        # boot + attach TUI (tears down on exit)
./start.sh --persist <repo>        # keep web UI up after you exit
./start.sh --doctor                # health report
./start.sh --show-allowlist        # egress picture
./start.sh --status                # what's running + digest
./start.sh --reconfigure           # edit secrets (wizard)
./start.sh --shell <repo>          # shell into the running container

# inside the TUI
/demo-tour              # the menu
/demo-tour 1 … 7        # one stage per call, you pace it
/demo-tour 4 ABC-123    # stage 4 against a specific ticket
/demo-status            # 14-line snapshot of thread A — the dip-in
/try-it                 # self-paced take-home (they drive)
/plugins                # plugin catalog + ON/OFF
Tab → guide             # the onboarding host agent, any time

# the trust beats — stage 3 runs these live
git push                                   # → blocked by workplace policy
curl -sS --max-time 5 https://example.com  # → refused by Squid
```

---

*Timing: ~28–30 min with both threads; ~17–19 for the tour arc alone. Drop Act 3
to save 3. Tour stages are independent — skip 5 if Bitbucket isn't configured.*

*The two threads are the demo. If you have to cut something, cut tour stages —
not the plan-approve-implement thread.*
