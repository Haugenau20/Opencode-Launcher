# Run-sheet — live workflow demo (Teams, online)

**The shape:** one real task on a throwaway branch, start to finish, narrated.
No scripted tour. The agent works while you talk; you dip in when it has
something to show.

> Opening line: *"I'm going to give it a real piece of work, and we'll watch how
> that actually goes — including the parts that aren't magic."*

**Show process, not outcome.** You are not demonstrating that it writes good
code in twenty minutes. You are demonstrating the working relationship: you
scope, it plans, you push back, it executes, you check. If what it writes is
mediocre, **say so on the call and show where you'd intervene.** A room that has
only seen polished agent demos will trust yours more for it.

---

## 1. The Teams setup

This is a screen-share demo, so the mechanics matter more than usual.

- **Share the monitor you've pre-arranged, and leave it arranged.** Dragging
  windows onto the shared screen mid-call is a visible scramble. Decide now what
  lives on the shared monitor and put it there before you join.
- **Your other monitor is your dashboard** — the agent's window, so you can see
  when the plan is ready without the room watching you look.
- **Consider sharing the web UI instead of the TUI.** Same sessions, same state,
  but it survives video compression far better than a terminal: bigger text,
  real scrollback, no font rendering artefacts. `http://localhost:${OPENCODE_PORT}`.
  Caveat: on a **new session** the web UI defaults its working directory to `/`
  — click New session and type `/workspace`. (The TUI doesn't have this issue,
  so if you'd rather not risk it, TUI with a large font is fine.)
- **Font size: bigger than feels right.** 18–22pt. Test it properly — join your
  own call from your phone and see whether you can actually read it.
- **Dead air is much worse online.** You cannot read the room, so never wait in
  silence. If the agent isn't ready, keep talking or move on.
- **If the call is recorded,** say so at the start and warn that there are
  deliberate gaps where the agent works — otherwise the recording looks broken.

---

## 2. Before the call

- [ ] **Cut the throwaway branch now.** `git checkout -b demo/throwaway-<date>`
- [ ] **Write the task sentence down verbatim.** You will paste it, not
      improvise it. Better still: use a **real Jira ticket** and let it fetch
      the ticket itself — that shows the internal integrations for free.
- [ ] **Rehearse that exact task on that exact branch once.** You need a feel for
      how long the plan takes and roughly how far it gets. Reset afterwards.
- [ ] **Pick a task with visible structure** — a small feature with a test story,
      in a language the room knows. Nothing needing network beyond the allowlist.
      Nothing whose success is invisible.
- [ ] **Leave `ALLOW_REMOTE_GIT=0`** so the push refusal lands on cue (§4, beat 4).
- [ ] **`docker login <registry-host>`** so the image pull doesn't stall.
- [ ] **If your endpoint is Qwen, leave `opencode-workspace` OUT of
      `ENABLED_PLUGINS`.** The tools and system prompt it injects are rejected by
      Qwen's upstream and *every* prompt then fails with `AI_APICallError` — that
      ends the demo, not just the plugin. `superpowers` and `dcp` are safe.
- [ ] **Windows pre-arranged, font sized, share tested.**

Minimal `.env`:

```dotenv
LLM_API_BASE=https://llm.internal.example/v1
LLM_API_KEY=<token>
IMAGE_REGISTRY=<your.artifactory.example>/opencode-workplace
IMAGE_TAG=latest

JIRA_BASE_URL=https://jira.internal.example
JIRA_PAT=<pat>

ALLOW_REMOTE_GIT=0
ENABLED_PLUGINS=superpowers dcp

# only if you want /demo-status and the optional tour available
USER_LAYER_PATH=./demo/onboarding-layer
```

---

## 3. Run of show

| Time | Shared screen | What you're doing |
|---|---|---|
| 0–3 | host terminal → `./start.sh <repo>` | boot it live; the one-command story |
| 3–5 | the agent | paste the task, ask for **a plan only** |
| 5–7 | the agent, still | let them watch it think, and talk over it |
| 7–12 | slides | context, architecture, what this is |
| 12–16 | the plan | **amend one step, then approve** — the money shot |
| 16–25 | slides / Q&A | it implements; you seed questions |
| ~20 | `/demo-status` | 20-second dip-in |
| 25–28 | the diff | honest verdict |
| 28–30 | `git push` → refused | the trust beat |
| 30–33 | slides | how they'd get it, `/try-it`, questions |

Rules for yourself:

- **Never wait on it.** "Still going — let's come back to that" and move on.
- **Dip in with `/demo-status`, not by scrolling.** A long transcript on a
  compressed screen share is unreadable, and scrolling looks like flailing.
- **Amend the plan before approving.** Approving as-is teaches the wrong lesson.

---

## 4. The four beats that matter

Everything else is filler. If you only land these, the demo worked.

### Beat 1 — Scoping (~2 min)

Paste the task (or the ticket key) and ask for **a plan, no code yet**.

> *"I'm not asking it to write anything. I want to see what it thinks the job is
> before it touches my repo."*

If you used a ticket key, point out what just happened: it fetched the ticket
itself, through a read-only integration, without you pasting anything.

### Beat 2 — The amendment (~3 min) · **the money shot**

Come back to the plan. Read it on screen. **Change something** — cut a step,
reorder two, add a constraint it missed. Then approve.

> *"This is the part people miss. It didn't start typing — it told me what it
> was going to do, and I got to disagree."*
> *"I'm cutting step 4. Not because it's wrong — because it's not what I asked
> for."*
> *"Now it goes. And I'm going to ignore it for ten minutes."*

This is the beat that says *you are in charge*. Protect it. If you're short on
time, cut slides, not this.

### Beat 3 — The verdict (~3 min)

`/demo-status`, then skim the real diff. One honest sentence.

- Went well: *"That's roughly what I'd have written, in the time it took me to
  do three slides."*
- Went badly: *"This isn't what I wanted, and that's worth showing you. Here's
  where I'd stop it and re-scope."* **Not a failed demo.** This is the most
  credible thing you can put on screen.

Point at the branch name and commit message: nobody told it the house format.
It shipped with it.

### Beat 4 — The refusal (~2 min) · **the trust beat**

Now that there's real work on the branch, try to ship it:

```
git push
curl -sS --max-time 5 https://example.com
```

Both refused — remote git is opt-in, egress is an allowlist. Keep the
`--max-time 5` so a refusal can never look like a hang.

> *"It has a shell. These are guard rails, not walls — what actually stops it is
> what the token was never given. But nothing leaves this box by accident."*

This lands far harder here, interrupting real work, than it would have as a
scripted step.

---

## 5. Filling the wait

You have two gaps (~5 min and ~9 min). Plan them now.

- **First 60–90 seconds of each gap: leave the agent on screen and talk over
  it.** Watching it work is genuinely interesting, and it's ambient proof. After
  ~90 seconds it becomes noise — then switch to slides.
- **Seed questions; don't ask for them.** "Any questions?" gets silence on
  Teams. Named, specific prompts work: *"Anders — what would you point this at
  in your team first?"* / *"What's the thing that would stop you trusting this?"*
- **Good gap material:** where the egress allowlist comes from and who controls
  it; why the image is pinned by digest; what happens when someone wants a tool
  that isn't in it; how you'd onboard a new starter.

---

## 6. If it breaks

| Symptom | Say / do |
|---|---|
| Plan not ready when you arrive | "still going, let's come back" — never wait |
| It went off the rails | **show it.** "Here's where I'd stop it and re-scope" |
| It finished way early | good — go deeper on the diff, or start a second task |
| Live Jira fetch returns nothing | "no creds in this one, so the tools aren't even loaded — that's the security model, not a failure" |
| `git push` *succeeds* | `ALLOW_REMOTE_GIT=1` leaked in; prompt should read `git:ro` |
| `curl example.com` hangs | you dropped `--max-time 5` |
| Every prompt fails `AI_APICallError` | `opencode-workspace` + Qwen — drop it, restart |
| Web UI session opens at `/` | New session → type `/workspace` |
| Pull stalls on `unauthorized` | `docker login <registry-host>` |

---

## 7. Cheat-sheet

```
# host
./start.sh ~/code/demo-repo        # boot + attach (tears down on exit)
./start.sh --persist <repo>        # keep the web UI up
./start.sh --doctor                # health report
./start.sh --status                # what's running + image digest
./start.sh --shell <repo>          # shell into the running container

# in the session
/demo-status            # 14-line snapshot — the dip-in
/try-it                 # hand this to them at the end
/plugins                # what's baked in and what's on

# beat 4
git push                                   # → blocked by workplace policy
curl -sS --max-time 5 https://example.com  # → refused by Squid
```

---

## 8. Cleanup

```bash
git -C <demo repo> checkout main
git -C <demo repo> branch -D demo/throwaway-<date>
```

Nothing was pushed — beat 4 established that it can't be.

---

## Appendix — the scripted tour, if you ever want it

`/demo-tour 1…7` still exists in this user layer: seven presenter-paced stages
(where am I, what I'm connected to, the gates, a ticket, a change, the loop, the
bundle). It was built for an in-person room where pauses between stages get
filled by the audience.

**It is not recommended for an online call** — press-button-see-output paces
badly over video, and the two beats worth keeping from it (the gates, the
service inventory) are folded into §4 above.

It costs nothing to leave in place. If you never type `/demo-tour`, it isn't
there. `/demo-status` is independent of it and worth keeping either way.
