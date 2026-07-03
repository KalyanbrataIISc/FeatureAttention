# Feature Attention Task — "Leaves"

A PsychToolbox/MATLAB experiment combining feature-based attention with
concurrent SSVEP tagging. The participant watches two independently moving
and pointing flocks of leaf-shaped stimuli, gets cued on each trial to one of
two color/rule pairings, and reports a cardinal direction.

Main script: [`gamev1.m`](gamev1.m). Everything experimenter-tunable lives in
its `%% PARAMETERS` block near the top.

## Stimuli

- **Leaves**: round-tailed, pointed shapes (like a raindrop/bullet) — the
  point faces one cardinal direction (up/down/left/right), independent of
  the direction the leaf travels in.
- **Two flocks**, always both on screen at once, sharing the same field
  (no separate regions — leaves from both flocks are intermixed and can
  pass near each other anywhere on screen). Each flock has its own:
  - **pointing direction** (where the leaf shape's tip faces)
  - **moving direction** (where the leaf actually travels)
  - Both are drawn independently at random from `{up, down, left, right}`
    at the start of every trial, and stay fixed for the whole trial.
- **RDK-style appear/disappear**: each leaf has a limited on-screen lifetime
  (`leafLifetimeSec`); when it expires, or the leaf drifts off the edge of
  the field, or it gets too close to another leaf, it is respawned at a
  fresh random position elsewhere. This is what keeps leaves from ever
  visibly overlapping/colliding, while still looking like a continuously
  streaming dot field. See `helperFunctions/updateLeaves.m` and
  `helperFunctions/findValidLeafPosition.m`.
- **Sizing**: all leaf dimensions are multiples of one base parameter,
  `leafSizePx` (see `helperFunctions/createLeafShape.m` for the actual
  geometry). Scale the whole leaf up/down with that one number, or nudge an
  individual dimension via its multiplier (`leafWidthMultiplier`,
  `leafBorderThicknessMultiplier`, `minLeafSeparationMultiplier`).

## The cue and the task rule

Each flock is associated with one of two colors, **c1** and **c2**. The
meaning of each color is fixed for the whole experiment:

- Cue = **c1** → respond with the **pointing direction** of the flock
  currently shown in color c1.
- Cue = **c2** → respond with the **moving direction** of the flock
  currently shown in color c2.

Before cue onset, both flocks are drawn in a single neutral color
(`colorPreCue`, the midpoint of `colorC1`/`colorC2` so it never collides
with either flock's cue color or with the SSVEP border's black/white
flicker extremes). At cue onset, both flocks simultaneously switch to their
real colors (`colorC1`/`colorC2`).

The cue itself is a solid rectangle at screen center (`cueRect`):
before cue onset it's plain black/neutral with no text; from cue onset
through feedback it fills with the cued color and shows the word
**"Pointing"** (cue = c1) or **"Moving"** (cue = c2) so the rule is spelled
out directly, not just color-coded.

## Trial timeline

1. **Trial start** — trigger `trialstart` sent, leaves reset to fresh
   random positions/lifetimes/directions, both flocks drawn in
   `colorPreCue`, cue rectangle black.
2. **Pre-cue foreperiod** — a fixed `preCueConstantSec`, plus a jittered
   extra interval drawn from a truncated exponential distribution
   (`preCueExpMeanSec`, capped at `preCueExpMaxSec`) so the hazard of the
   cue appearing stays as flat as possible over time
   (`helperFunctions/truncatedExpRnd.m`).
3. **Cue onset** — trigger `cueonset` sent; both flocks switch to
   `colorC1`/`colorC2`; the cue rectangle fills with the cued color and
   shows "Pointing"/"Moving"; the response timer resets.
4. **Response window** — up to `responseTimeoutSec` (measured from cue
   onset). A valid response sends trigger `response` and ends the window
   immediately; otherwise it's a timeout.
5. **Feedback** — only shown if a response was given (a timeout skips
   straight to trial end, no feedback text). Green "Correct" / red
   "Incorrect" for `feedbackDurationSec`, drawn above the leaf field. Leaves
   keep moving and the SSVEP border keeps flickering throughout.
6. **Trial end** — trigger `trialstop` sent, the trial row is appended to
   the CSV, then a blank `itiDurationSec` gap before the next trial.

Escaping (ESC key) at any point ends the block after sending `trialstop`
and cleaning up; no CSV row is written for an aborted trial.

## SSVEP tagging

Each flock's leaves have a thick border that flickers in luminance between
`colorBorderLow`/`colorBorderHigh` (default black/white) — flock c1 at
`freqC1Hz` (14 Hz default), flock c2 at `freqC2Hz` (18 Hz default). The
flicker is computed from continuous elapsed time since trial start
(`helperFunctions/computeSsvepBorderColors.m`), independent of the cue and
uninterrupted across the pre-cue/response/feedback phases — it only resets
at the next trial's start. Every leaf in a flock shares the same time base
and frequency, so all leaves in a flock are phase-locked automatically.

## Response input

- **Windows** (`~ismac`): Cedrus button box, XID buttons — Up = 1,
  Right = 5, Left = 3, Down = 6 (Middle = 4 is unused). Also sends triggers
  via `cog_send_triggers` and expects eye tracking + a serial paraport.
- **mac**: arrow keys instead of the Cedrus box, no triggers, no eye
  tracking, `SkipSyncTests` enabled. This is the path for development/testing
  on a laptop without the lab hardware.

See `helperFunctions/getDirectionResponse.m` for the unified 4-direction
response check used on both platforms.

## Triggers

Sent via `cog_send_triggers` (`functions/cog_send_triggers.m`):
`trialstart`, `cueonset`, `response`, `trialstop`.

## CSV output

One file per participant/block in `data/`, named
`p<participant>_b<block>_leaves_trialdata.csv` (a timestamped fallback file
is created instead if a prior run's header doesn't match, so old data is
never silently overwritten). Columns:

```
TrialNumber, TrialStart, C1PointDir, C1MoveDir, C2PointDir, C2MoveDir, Cue,
CueOnsetTime, CorrectResponse, ParticipantResponse, Accuracy, ReactionTime,
ResponseTimeout, TrialEnd
```

## Project layout

- `gamev1.m` — the experiment script (init → participant/block info → CSV
  header → PsychToolbox setup → `%% PARAMETERS` → screen open → trial loop
  → cleanup).
- `functions/` — original experiment scaffolding (Cedrus, triggers, eye
  tracking, elapsed-time helper).
- `helperFunctions/` — task-specific logic for this paradigm (leaf shape,
  motion/collision, SSVEP color computation, response mapping, timing jitter).
  New helper functions belong here, one function per file — this MATLAB
  version doesn't support local functions inside a script.
- `data/` — per-participant/block CSV logs (created on first run).

## Running it

Open and run `gamev1.m` in MATLAB with PsychToolbox installed. On Windows
you'll be prompted for participant number, block number, and whether to run
eye tracking; on mac these default automatically (participant/block `000`,
eye tracking off) so it just launches straight into the task. Press any key
to start the block; ESC exits at any point. All tunable values (timing,
leaf size/speed/count, colors, SSVEP frequencies, cue rectangle) are in the
`%% PARAMETERS` block near the top of `gamev1.m`.

---
**Keeping this file in sync**: whenever `gamev1.m` (or its helper functions)
changes in a way that affects behavior, parameters, timing, triggers, or CSV
columns, update this README to match in the same change. See `CLAUDE.md`.
