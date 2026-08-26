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
4. **You customize at the edges, not the core** → this very demo is a user-layer
   add-on, which is the proof.
5. **They can do this themselves** → hand off `/try-it`.

Keep returning to: *launcher = front door, backbone = the box.*

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
- [ ] **Terminal: big font, dark theme, wide window.** Have a second host
      terminal tab open for the host-side commands in Act 3.
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

Type **`/demo-tour`** with no argument to get the menu, then call the stages
by number. **Each call runs exactly one stage and stops** — you control pacing,
so talk between them.

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

Stage 6 leaves a branch and one commit in your demo repo:

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
/try-it                 # self-paced take-home (they drive)
/plugins                # plugin catalog + ON/OFF
Tab → guide             # the onboarding host agent, any time

# the trust beats — stage 3 runs these live
git push                                   # → blocked by workplace policy
curl -sS --max-time 5 https://example.com  # → refused by Squid
```

---

*Timing: ~17–19 min for the full arc; drop Act 3 to land in ~14. Stages are
independent — skip 5 if Bitbucket isn't configured.*
