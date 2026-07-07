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
- **Even spatial density, not just collision-avoidance**: that fresh
  respawn position isn't picked uniformly at random over the whole field -
  plain uniform sampling has nothing stopping several respawns in a row
  from landing in the same already-crowded region, which reads as visible
  clustering/gaps. Instead, the field is divided into a grid sized so each
  cell holds about one leaf on average, and a respawn is drawn from
  whichever cell currently holds the *fewest* leaves (ties broken
  randomly), then jittered within it and checked against
  `minLeafSeparationPx` as before. Since this runs on every respawn (not
  just at trial start), it keeps rebalancing toward whatever's currently
  sparse as leaves drift, so density stays even over time too - measured
  (via a coverage-grid occupancy-std-dev metric, averaged over 15 seeds) to
  meaningfully beat plain uniform-random both at trial start and over 15s
  of simulated respawns. The grid's geometry itself (cell counts/sizes)
  only depends on the field size, `minLeafSeparationPx`, and leaf count -
  none of which change mid-experiment - so both `gamev1.m`/`gameNF.m`
  compute it once via `helperFunctions/computeLeafPlacementGrid.m` right
  after `fieldRect` is known, rather than recomputing it (via `sqrt`/
  `floor`) on every respawn throughout the whole block of trials. See
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

The cue itself is a solid, rounded-corner rectangle at screen center
(`cueRect`, drawn via `helperFunctions/drawRoundedRect.m`): before cue onset
it's plain black/neutral with no text; from cue onset it fills with the
cued color and shows the word **"Pointing"** (cue = c1) or **"Moving"**
(cue = c2) so the rule is spelled out directly, not just color-coded. Once
a response is given, that same word is replaced by the response feedback
("Correct"/"Incorrect", in green/red) inside the same box — feedback is
never shown anywhere else on screen.

## Trial timeline

All phases below run inside a **single continuous per-frame loop** in
`gamev1.m` (not a separate loop per phase) — `currentFrame` is just compared
against pre-computed phase-boundary frame numbers (`cueOnsetFrame`,
`responseDeadlineFrame`) to decide what to draw. This was a deliberate fix:
separate loops per phase meant extra setup work (a second
`cedrus.resettimer()`, per-loop first-frame bookkeeping) landing right on
the pre-cue → post-cue transition, which showed up as a visible stutter.
`currentFrame` also doubles as the SSVEP time base, since it already
increments every displayed frame from trial start onward regardless of
phase.

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
   straight to trial end, no feedback at all). The cue box's word switches
   to green "Correct" / red "Incorrect" for `feedbackDurationSec`, in the
   same box, replacing "Pointing"/"Moving" — no separate feedback text
   elsewhere on screen. Leaves keep moving and the SSVEP border keeps
   flickering throughout.
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
- `gameNF.m` — the neurofeedback variant of the same script; see
  [Neurofeedback variant](#neurofeedback-variant-gamenfm) above.
- `functions/` — original experiment scaffolding (Cedrus, triggers, eye
  tracking, elapsed-time helper).
- `helperFunctions/` — task-specific logic for this paradigm (leaf shape,
  motion/collision, leaf-placement grid precomputation, SSVEP color
  computation, response mapping, timing jitter, the rounded-rect cue box,
  NF file reading/color mapping/lookup-table precomputation, sRGB↔CIELAB
  conversion, CSV header-mismatch-safe file creation). New helper functions
  belong here, one function per file — this MATLAB version doesn't support
  local functions inside a script.
- `nf.txt` — binary NF data file in the project root, continuously
  overwritten by the external real-time acquisition process; read (not
  written) by `gameNF.m`.
- `data/` — per-participant/block CSV logs (created on first run).

## Running it

Open and run `gamev1.m` in MATLAB with PsychToolbox installed. On Windows
you'll be prompted for participant number, block number, and whether to run
eye tracking; on mac these default automatically (participant/block `000`,
eye tracking off) so it just launches straight into the task.

Before the block starts, a one-time instructions screen explains the task
in text and shows two **static** (non-moving) example leaves — one in
`colorC1` labeled "use its POINTING direction", one in `colorC2` labeled
"use its MOVING direction" — so the color/rule mapping is shown concretely
rather than only described. Press any key/button on that screen to begin;
ESC exits at any point during the block. All tunable values (timing, leaf
size/speed/count, colors, SSVEP frequencies, cue rectangle) are in the
`%% PARAMETERS` block near the top of `gamev1.m`.

## Neurofeedback variant (`gameNF.m`)

`gameNF.m` is a second, independent copy of the same task with one addition:
real-time SSVEP neurofeedback (NF) driven by an external real-time EEG
acquisition process. It shares every stimulus/trial-flow detail described
above except for the differences below.

**NF stimulus — leaf fill color.** Before cue onset, and whenever
lateralisation is zero or in the wrong direction after cue onset, each
flock's leaf fill is exactly `grey` — the same solid color the background
is filled with — so the leaf body is indistinguishable from the background
(there is no more separate `colorPreCue` blend). The only thing that stays
visible regardless is the flickering SSVEP border ring: a separate, larger
polygon drawn underneath the fill (see `helperFunctions/drawLeaves.m`) that
this NF logic never touches — modulating it would contaminate the very
SSVEP signal being fed back.

From cue onset, fill moves from `grey` toward the flock's own cue color
(`colorC1`/`colorC2`) in proportion to the participant's real-time SSVEP
power lateralisation in the cue-consistent direction — the leaves become
more distinctly colored the more the participant's brain signal is
lateralised the *correct* way for the current cue.

**Baseline reveal at cue onset.** If fill only ever depended on live NF, a
participant with no lateralisation yet would see both flocks as identical
grey right when the cue appears — no way to tell which flock is which, so
no way to know where to start attending. To avoid that, `nfBaselineDeltaE`
(12 default) is a fixed, immediate reveal applied the instant the cue comes
on, regardless of the live NF value — a deliberately subtle glimpse of each
flock's true color. Live NF then rescales *on top of* that baseline, from
`nfBaselineDeltaE` (nf ≤ 0) up to fully-saturated `colorC1`/`colorC2`
(nf ≥ 1).

**Reveal is calibrated by perceived color difference, not raw RGB.** The
reveal amount (both the fixed baseline and the live-NF growth on top of it)
is driven by CIELAB Delta E — perceived color difference from grey — not a
raw RGB blend fraction. A rig test showed the same blend fraction (e.g.
"15% of the way from grey to the target color, in RGB") looked clearly
more intense for one flock's color than the other's: `colorC1` (deep sky
blue) and `colorC2` (dark orange) are not equally different from grey to
the eye, even though they're a similar RGB distance from it (measured Delta
E from `grey` is ≈50 for `colorC1` vs. ≈85 for `colorC2` with the current
colors — a ~1.7x difference). `helperFunctions/srgb2lab.m` /
`helperFunctions/lab2srgb.m` convert to/from CIELAB (D65, standard
sRGB↔XYZ↔Lab formulas); `gameNF.m` converts `grey`/`colorC1`/`colorC2` once
up front and precomputes each flock's own total Lab distance to grey
(`maxDeltaEC1`, `maxDeltaEC2` — deliberately *not* assumed equal).
`helperFunctions/computeNfLeafColor.m` then targets the *same* Delta E for
both flocks at a given reveal state (`nfBaselineDeltaE` at nf ≤ 0, scaling
up to each flock's own `maxDeltaE` at nf ≥ 1 so both still land exactly on
their true saturated color), converting back to sRGB for `Screen`.

**That CIELAB math is precomputed into a lookup table, not run per frame.**
`computeNfLeafColor.m`'s conversion involves several non-integer
power/exponent calls (gamma decode/encode) - measurably heavier than
`computeSsvepBorderColors.m`'s plain `sin()`, and running it twice per
frame (once per flock) for the whole post-cue period was adding enough
delay before each `Screen('Flip', ...)` to measurably drift the SSVEP
tagging frequency, which breaks phase-locked power spectral analysis on the
recorded EEG. Since the nf→color mapping never depends on anything that
changes mid-experiment (only `nfCurrentValueRaw` itself does, and that's
read fresh from `nf.txt` every frame regardless), `gameNF.m` calls
`helperFunctions/buildNfColorLut.m` once, up front, to precompute the
entire mapping as a 1001-row sRGB table per flock; the frame loop then
calls `helperFunctions/lookupNfColor.m`, which is just a clip and an array
index - no CIELAB math in the per-frame path at all. Quantization at that
resolution is <1 RGB unit versus the direct computation (visually
identical), and the lookup measured ~10x faster in isolation.

**Data source — `nf.txt`.** An external real-time acquisition process
(`RT_acquisition_7`, outside this repo) continuously overwrites
`nf.txt` (in the project root, `nfFilePath` in `gameNF.m`) with a 5-element
binary double vector: `[AMI_dir1, AMI_dir2, SMI_14gt18, SMI_18gt14,
sampleCount]`. Only the SMI pair (indices 3/4) is used — the 14Hz-vs-18Hz
SSVEP power separation. `helperFunctions/readNFValue.m` reads a single
indexed value from this file (returning `0`, i.e. neutral, if the file is
missing or caught mid-write by the external process).

**Which column, and when it's decided.** Which of the two SMI columns is
"correct" depends on the trial's cue and never changes mid-trial, so it's
decided once at trial setup (before the trial's frame loop starts): cue
`c1` (14Hz) uses column 3 (positive when 14Hz > 18Hz), cue `c2` (18Hz) uses
column 4 (positive when 18Hz > 14Hz).

**Read cadence vs. visual gating.** `nf.txt` is re-read fresh every
displayed frame, starting at trial start (frame 1) — continuing through the
response and feedback phases — regardless of trial phase. It is *not* held
between reads on a fixed local clock: the file is only rewritten externally
on roughly a 100ms cadence, but reading on our own fixed timer could be out
of phase with that and add close to a full extra cadence-period of pure
latency for no reason — reading every frame instead means each external
rewrite is picked up as soon as it lands. Only the *visual effect* is
gated: pre-cue frames always render plain `grey` with no NF influence at
all (not even the baseline reveal), so no cue-consistent information leaks
before cue onset. No moving-average window is applied to the live NF
value, unlike the neurofeedback experiment this borrows the `nf.txt`
protocol from.

**Response window.** `responseTimeoutSec` is 10s (vs. 4s in `gamev1.m`), to
give the participant more time to work with the NF-driven coloring before
the window closes.

**CSV output.** In addition to the same per-trial CSV as `gamev1.m`
(`p<participant>_b<block>_leaves_trialdata.csv`), `gameNF.m` also writes a
second, NF trace file, `p<participant>_b<block>_leaves_nftrace.csv`. This is
sampled only every `nfTraceLogIntervalSec` (~100ms default, `nfTraceLogIntervalFrames`
in frames) even though `nf.txt` itself is read every frame — logging every
frame would just repeat the same externally-unchanged value several times
over for no benefit:

```
TrialNumber, FrameNumber, SampleTime, NFIndexUsed, NFValueRaw,
NFValueClipped, PostCueOnset
```

`NFValueRaw` is the raw value read from `nf.txt` at that sampled frame
(unclipped, can be outside `[0, 1]` or even outside `[-1, 1]`);
`NFValueClipped` is that value's `[0, 1]` clip (see
`helperFunctions/computeNfLeafColor.m` for how it maps to a Delta E, and
then a color); `PostCueOnset` (0/1) marks whether that sample occurred
after cue onset (i.e. whether it was actually visible) or during the
pre-cue phase (read, logged, but not shown). Both of `gameNF.m`'s CSV files
get the same header-mismatch-safe-fallback behavior as `gamev1.m`'s main
CSV, via the shared `helperFunctions/ensureCsvWithHeader.m` (`gamev1.m`
itself still does this inline, unchanged).

**Testing without real EEG hardware.** In the experiment room (Windows),
`RT_acquisition_7` (outside this repo) is the real writer of `nf.txt`. For
local/mac testing, [`simulate_nf.py`](simulate_nf.py) writes randomized
values into `nf.txt` in the same 5-double binary format, at the same
~101.6ms cadence RT_acquisition_7 uses (13 samples at its 128Hz EEG rate) -
each of the 5 values does its own bounded random walk rather than jumping
independently every write, so the leaf-color modulation in `gameNF.m`
responds the way it would to a real, smoothly-drifting SSVEP signal. Run
`python3 simulate_nf.py --path nf.txt` (from the repo root) alongside
`gameNF.m` to exercise the NF path without hardware; it does not know about
trial boundaries and just free-runs continuously.

---
**Keeping this file in sync**: whenever `gamev1.m`, `gameNF.m` (or their
helper functions) changes in a way that affects behavior, parameters,
timing, triggers, or CSV columns, update this README to match in the same
change. See `CLAUDE.md`.
