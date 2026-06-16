# Choosing a model

This setup talks to an internal LLM endpoint that serves a small menu of models.
They are **not** interchangeable — each has a different sweet spot, and picking
the right one for the task in front of you makes the agent noticeably faster,
cheaper on context, and more accurate.

This page is a short field guide: what each model is good at, how they compare,
and **when to reach for which**.

**About the numbers below.** The benchmark figures are drawn from public vendor
and third-party sources and are here for *relative* orientation only — they may
differ from how each model behaves on our internal deployment. The model list is
maintained by hand and reflects what the internal provider currently serves, so
it can lag a model being added or removed. The **context windows shown are the
values configured for this setup.**

## The models at a glance

| Model | Best for | Architecture | Context | Plugin notes |
| --- | --- | --- | --- | --- |
| **MiniMax-M2.5** | Long, autonomous, multi-file coding and tool-loop work | ~230B MoE, 10B active | 190K | ✅ all plugins |
| **Qwen3.5-122B-A10B** | Hard reasoning, large-context reads, documents, multilingual | 122B MoE (10B active), 256 experts | 262K | ⚠️ **`opencode-workspace` incompatible** — see below |
| **gemma-4-31B-it** | Fast, well-scoped tasks, math/algorithms, anything with an image | 30.7B dense, multimodal | 262K | ✅ all plugins |

## When to reach for which

### MiniMax-M2.5 — the autonomous agent

Reach for it on **sustained, multi-step coding**: cross-file refactors, "make
this failing repo pass," long tool-using loops where the agent has to keep its
footing over many turns. It is purpose-built for agentic work ("designed for the
agent universe") and that shows in the coding numbers. It runs a touch slower per
token than the others, which is the trade for staying coherent over a long
session.

- **SWE-Bench Verified: 80.2%** · Multi-SWE-Bench: 51.3% — the strongest agentic
  coding scores of the three.
- Trained for tool use and web search across 10+ programming languages.
- ~100 tokens/sec; completes long agentic runs at roughly Claude-Opus pace.

### Qwen3.5-122B-A10B — the heavy thinker

Reach for it when the **reasoning** matters more than autonomy: dense analysis,
research-style questions, reading large documents (it ties for the biggest
context here at 262K), structured tool/function calling, and **non-English**
work. It is also the fastest of the three in raw throughput.

- **GPQA Diamond: 86.6** (top reasoning here) · MMMU: 83.9
- **BFCL-V4 function calling: 72.2** — strong structured tool use.
- Document/OCR leader (OCRBench 92.1, OmniDocBench 89.8) and broadly multilingual.
- ~155 tokens/sec.

> ⚠️ **Do not pair Qwen with the `opencode-workspace` plugin.** The extra tools
> and system prompt that plugin injects are rejected by Qwen's upstream, so every
> prompt then fails with
> `AI_APICallError: Failed to communicate with the upstream service`. If your
> workflow depends on that plugin's planning/background-agent delegation, use
> MiniMax or Gemma instead. See the
> [Plugins section of the README](../README.md#plugins) for details.

### gemma-4-31B-it — the fast specialist

The smallest model here, but don't mistake that for weak. It is **excellent on
self-contained, well-scoped problems** — algorithmic puzzles, math, a single
focused function or fix — and it is the **only multimodal** option, so it is the
one to reach for when the task involves an **image**: screenshots, PDFs, diagrams,
UI/chart understanding. It is fast and light. Where it gives ground to MiniMax is
*long autonomous* multi-file agent runs, so prefer it for tasks that fit in a
tight scope.

- **AIME 2026: 89.2%** · **LiveCodeBench v6: 80.0%** — very strong math and
  single-shot competitive-style coding.
- GPQA Diamond: 84.3 — reasoning close to the larger models on knowledge tasks.
- Native function calling, configurable "thinking" mode, vision input, 140+
  languages.

## Switching models

Selecting and switching the active model is handled by **OpenCode itself**, not
by this launcher. In the TUI, run **`/models`** to list what the endpoint
serves and switch between them. For defaults and full details, see the official
OpenCode documentation: <https://opencode.ai/docs/models/>.

## Quick reference

- **Long, autonomous, multi-file coding & tool loops →** MiniMax-M2.5
- **Hard reasoning, huge-context reads, documents, multilingual →** Qwen3.5
  *(unless you need `opencode-workspace`)*
- **Fast well-scoped tasks, math/algorithms, or anything with an image →**
  gemma-4-31B-it
