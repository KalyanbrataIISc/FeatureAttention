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
`freqC1Hz` (23 Hz default), flock c2 at `freqC2Hz` (29 Hz default). The
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
- `gameNFv2.m` — a further, independent copy of `gameNF.m` with a
  timing-robustness fix for the SSVEP flicker; see
  [Timing-hardened variant](#timing-hardened-variant-gamenfv2m) below.
- `gameBreakout.m` — a different task entirely (SSVEP-neurofeedback Breakout),
  sharing only `nf.txt` and the scaffolding; see
  [Breakout task](#breakout-task-gamebreakoutm) below.
- `functions/` — original experiment scaffolding (Cedrus, triggers, eye
  tracking, elapsed-time helper).
- `helperFunctions/` — task-specific logic for this paradigm (leaf shape,
  motion/collision, SSVEP color computation, response mapping, timing jitter,
  the rounded-rect cue box, NF file reading/color mapping, sRGB↔CIELAB
  conversion, CSV header-mismatch-safe file creation). New helper functions
  belong here, one function per file — this MATLAB version doesn't support
  local functions inside a script.
- `breakoutHelperFunctions/` — the same, but for `gameBreakout.m` only (ball
  physics, collisions, brick spawning, paddle NF control, grating drawing).
- `nf.txt` — binary NF data file in the project root, continuously
  overwritten by the external real-time acquisition process; read (not
  written) by `gameNF.m`.
- `data/` — per-participant/block CSV logs (created on first run).
- `analysis/ssvepCueOnsetLocked.m` and
  `analysis/ssvepResponseLocked.m` — offline cue-locked and response-locked
  SSVEP analyses. Each script can independently generate combined and/or
  per-participant ongoing (induced) and evoked power spectra in addition to
  its event-locked time-series plots.

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

**Data source — `nf.txt`.** An external real-time acquisition process
(`RT_files/RT_acquisition_8.m`, run separately from this repo's
PsychToolbox side) continuously overwrites `nf.txt` (in the project root,
`nfFilePath` in `gameNF.m`) with a 3-element binary double vector:
`[SMI_23gt29, SMI_29gt23, sampleCount]` — the 23Hz-vs-29Hz SSVEP power
separation, computed from the pooled 28-electrode SSVEP ROI for both
frequencies. In the 41-channel GDF EEG order (`A1-A32+B1-B9`), that ROI is
the 14 right-electrode indices `[28 30 32 36 38 35 37 39 40 41 26 27 29 31]`
plus the 14 left-electrode indices `[15 17 5 7 9 6 8 10 11 12 13 14 16 18]`.
`helperFunctions/readNFValue.m` reads a single indexed value from this
file (returning `0`, i.e. neutral, if the file is missing or caught
mid-write by the external process). (Previously 5 elements, with an
AMI/alpha-lateralisation pair at indices 1/2 that this task never read —
that alpha feedback has since been disabled on the acquisition side, so
the SMI pair moved down to indices 1/2 and `sampleCount` to index 3.)

**Which column, and when it's decided.** Which of the two SMI columns is
"correct" depends on the trial's cue and never changes mid-trial, so it's
decided once at trial setup (before the trial's frame loop starts): cue
`c1` (23Hz) uses column 1 (positive when 23Hz > 29Hz), cue `c2` (29Hz) uses
column 2 (positive when 29Hz > 23Hz).

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
`RT_files/RT_acquisition_8.m` is the real writer of `nf.txt`. For
local/mac testing, [`simulate_nf.py`](simulate_nf.py) writes randomized
values into `nf.txt` in the same 3-double binary format, at the same
~101.6ms cadence RT_acquisition_8.m uses (13 samples at its 128Hz EEG rate) -
each of the 3 values does its own bounded random walk rather than jumping
independently every write, so the leaf-color modulation in `gameNF.m`
responds the way it would to a real, smoothly-drifting SSVEP signal. Run
`python3 simulate_nf.py --path nf.txt` (from the repo root) alongside
`gameNF.m` to exercise the NF path without hardware; it does not know about
trial boundaries and just free-runs continuously.

## Timing-hardened variant (`gameNFv2.m`)

`gameNFv2.m` is a further, independent copy of `gameNF.m` — identical in every
respect above except for how the SSVEP flicker's timing is generated. It
exists to fix a specific failure mode: under GPU load (e.g. a rig with heavy
concurrent rendering/processing), `Screen('Flip')` can miss its requested
vsync and present a frame late. In `gamev1.m`/`gameNF.m`, the flicker's phase
is `(currentFrame - 1) * interFrameInterval` — a loop counter times a fixed
*nominal* refresh interval (`helperFunctions/computeSsvepBorderColors.m`).
That counter has no feedback from real elapsed time: every dropped frame
makes the code's phase clock fall further behind the wall clock, and the
error only accumulates for the rest of the trial. In practice this shows up
as the flicker's *measured* frequency drifting visibly below its nominal
value (e.g. 23 Hz reading as ~22.5 Hz, 29 Hz as ~28.3 Hz) by an amount that
tracks how much load the GPU is under - which will degrade SSVEP phase
locking and power in any later analysis.

**Fix - real-time-anchored phase.** `gameNFv2.m` computes the flicker phase
from the *actual measured* `Screen('Flip')` VBL timestamp each frame, not
from the frame counter (`helperFunctions/computeSsvepColorsFromTime.m`). Each
frame predicts its own display time as `lastRealVbl + interFrameInterval`,
where `lastRealVbl` is the true timestamp `Screen('Flip')` returned for the
previous frame. If that previous flip was delayed, the prediction - and thus
the phase - shifts to match reality on the very next frame, so a dropped
frame costs at most one bounded, local phase correction instead of a
permanent, growing frequency error. `trialSsvepT0` (the real flip timestamp
right before each trial's frame loop starts) is the trial's `t = 0` reference,
matching the original's per-trial phase reset.

**Fix - dropped-frame detection and logging.** `gameNFv2.m` also captures
`Screen('Flip')`'s `missed` output every frame (unused/discarded in
`gamev1.m`/`gameNF.m`) and logs every frame that missed its deadline, so GPU
overload is a measurable, quantifiable thing rather than only inferred after
the fact from EEG spectra. This is only tracked on `~ismac` (the real rig),
since mac dev/test runs have `SkipSyncTests` enabled and unreliable flip
timing to begin with.

**CSV output differences from `gameNF.m`.** The main per-trial CSV gets one
extra trailing column, `DroppedFrameCount` (count of frames in that trial
that missed their flip deadline):

```
TrialNumber, TrialStart, C1PointDir, C1MoveDir, C2PointDir, C2MoveDir, Cue,
CueOnsetTime, CorrectResponse, ParticipantResponse, Accuracy, ReactionTime,
ResponseTimeout, TrialEnd, DroppedFrameCount
```

A third CSV, `p<participant>_b<block>_leaves_droppedframes.csv`, logs one row
per dropped/delayed frame (typically empty or near-empty on a healthy rig):

```
TrialNumber, FrameNumber, VBLTime, MissedBySec
```

`MissedBySec` is `Screen('Flip')`'s own estimate (seconds) of how far past
its requested deadline the flip actually landed.

## Breakout task (`gameBreakout.m`)

`gameBreakout.m` is **not** a variant of the leaves task. It is a separate
SSVEP-neurofeedback experiment that happens to share `nf.txt`, the
Cedrus/trigger/eye-tracking scaffolding in `functions/`, and a handful of
generic helpers (`ensureCsvWithHeader`, `sendNumericTrigger`, `checkEscape`,
`cleanupExperiment`, `getElapsedTime`). It changes nothing in the leaves
scripts or their helpers. Its own logic lives in `breakoutHelperFunctions/`,
one function per file.

**The paddle is the stimulus and the effector.** A wide paddle sits near the
bottom of the screen, split across its width into three regions: a grating
flickering at `gratingLeftFreqHz` (23 Hz) on the left, a **non-flickering**
strip in the middle, and a grating at `gratingRightFreqHz` (29 Hz) on the
right. Those two gratings are the entire SSVEP stimulus. Their flicker is an
on-off sinusoidal contrast envelope — at the peak of each cycle the bars sit at
full black/white contrast, at the trough both collapse to a uniform grey and
the pattern vanishes — so the flicker fundamental is exactly the nominal
frequency (`breakoutHelperFunctions/computeGratingColors.m`). A
contrast-*reversing* grating was deliberately not used: its dominant response
would land at 2f, not at the 23/29 Hz bins the acquisition and the control law
are built around.

**Paddle motion is the neurofeedback.** `nf.txt` is read fresh every displayed
frame (`breakoutHelperFunctions/readNfPair.m`, which reads both columns in one
`fopen`, unlike the leaves task's one-column `readNFValue.m`). 23 Hz dominance
drives the paddle left, 29 Hz dominance drives it right, at a speed **linear**
in `nf29 - nf23`, clamped to `paddleMaxSpeedPxPerSec`, with a `paddleNfDeadzone`
that pins near-neutral lateralisation to a standstill
(`computePaddleVelocityFromNf.m`). So attending to one side of the paddle
steers the paddle to that side. A failed read (file caught mid-write) holds the
last good values rather than snapping the paddle to a halt.

**Physics: no gravity, constant speed, real spin.** Ball speed is renormalized
to `ballSpeedPxPerSec` every frame, so nothing — not spin, not the paddle —
ever changes *how fast* the ball moves, only where it goes. A paddle bounce has
three ingredients (`collideBallPaddle.m`): where on the paddle the ball lands
sets the rebound angle from vertical (up to `paddleBounceMaxAngleDeg`); the
paddle's own sideways motion drags the ball along with it (`paddlePushGain`);
and that same motion sets the ball's **spin** (`paddleSpinGain`), which then
curves the ball's later flight via a Magnus term (`magnusGainPerFrame` in
`moveBall.m`) before decaying (`spinDecayPerFrame`). Walls and bricks are
frictionless mirrors — only the paddle imparts spin, so the one coupling of
interest (NF → paddle → ball) is never contaminated by incidental contacts.
`minVerticalSpeedFraction` floors `|vy|` so repeated curvature can't settle the
ball into a purely horizontal path that neither falls nor reaches the paddle.

**One brick at a time, gated by paddle bounces.** A brick appears at a random
position in the band above the screen midline, and one contact breaks it. The
**first** brick, and every brick after one is broken, only spawns once the ball
has bounced off the paddle *again* — a paddle bounce arms the spawn, breaking a
brick disarms it. So the participant must keep working the paddle (i.e. keep
driving the lateralisation) between targets. A new brick is rejection-sampled
away from the ball's current position (`brickSpawnBallClearancePx`) so it never
materialises on top of it.

**Trial timeline.** Each trial is one ball, spawn to fall.

1. **Get ready** (`preSpawnDelaySec`) — no ball, no trigger, no logging, but
   the gratings already flicker and the paddle already tracks NF, so the SSVEP
   response has settled by the time the trial starts. Prefer whole seconds
   here: 23 and 29 Hz both complete a whole number of cycles per second, so the
   flicker is back at zero phase exactly at ball spawn.
2. **Ball spawn = trial start** — trigger `trialstart`, ball launched upward
   from the paddle at a random angle within `±ballLaunchMaxAngleDeg`.
3. **Rally** — triggers on every wall bounce, paddle bounce and brick bounce.
4. **Trial end** — trigger `trialstop` when the ball has fully cleared the open
   bottom edge (or at the `maxTrialDurationSec` safety cap). Then a blank
   `itiDurationSec`, gratings off.

The flicker's phase is one continuous time base spanning the get-ready phase
and the trial. It is deliberately **not** re-anchored at ball spawn: the
gratings are on screen across that boundary, so resetting the phase there would
step the sinusoid discontinuously and evoke a transient at exactly the
`trialstart` trigger. As in `gameNFv2.m`, that phase is computed from measured
`Screen('Flip')` VBL timestamps rather than a frame counter, so a dropped frame
costs one bounded phase correction instead of permanently detuning 23/29 Hz.

**Triggers.** Sent as raw bytes via `helperFunctions/sendNumericTrigger.m`, with
the values set in the `%% PARAMETERS` block, so this task can define its own
bounce triggers without touching the shared trigger table in
`functions/cog_send_triggers.m` that the leaves task depends on.
`trialstart`/`trialstop` keep that table's values so existing trial
segmentation still finds them:

```
trialstart 20   trialstop 30   wallbounce 70   paddlebounce 71   brickbounce 72
```

Every trigger is sent immediately **after** the `Screen('Flip')` that displays
the event it marks, never before — so a bounce trigger lands on the refresh
that actually showed the ball rebounding, not up to one frame early.

**Setup validation.** The parameter block is checked once against the geometry
it produces, and the script tears down and errors rather than running a block
with a silently wrong stimulus: the gratings must leave an inert middle strip,
the paddle must fit the field, the brick must fit its region, and the ball's
per-frame step must stay below the point at which it would tunnel through the
paddle (`paddleHeightPx + ballRadiusPx`) or through a brick
(`min(brickWidthPx, brickHeightPx) + 2*ballRadiusPx`). Collisions are resolved
at discrete frame positions, so those two bounds are real; both hold with a
wide margin at the default `ballSpeedPxPerSec`.

**CSV output.** Three files in `data/`, all with the same
header-mismatch-safe-fallback behavior as the leaves task's. One row per trial
in `p<participant>_b<block>_breakout_trialdata.csv`:

```
TrialNumber, TrialStart, TrialEnd, TrialDuration, PaddleBounces, WallBounces,
BricksBroken, BallFell, DroppedFrameCount
```

`BallFell` is 0 for a trial that ended on the `maxTrialDurationSec` cap instead
of the ball falling. A `~100ms` trace of the whole game state (sampled every
`traceLogIntervalSec`, since `nf.txt` is only rewritten externally on about
that cadence) in `p<participant>_b<block>_breakout_trace.csv`:

```
TrialNumber, FrameNumber, SampleTime, NF23, NF29, NFSigned, NFReadOk,
PaddleCenterX, PaddleVxPxPerSec, BallX, BallY, BallVxPxPerSec, BallVyPxPerSec,
BallSpin, BrickActive, BrickCenterX, BrickCenterY, BricksBroken
```

`NFReadOk` is 0 on a frame whose `nf.txt` read lost the race with the external
writer (the NF values on that row are the last good ones, held). `BrickCenterX`
/`BrickCenterY` are `NaN` while no brick is on screen. And one row per
dropped/delayed frame in `p<participant>_b<block>_breakout_droppedframes.csv`,
same shape as `gameNFv2.m`'s.

**Running it.** Same as the leaves task. On mac, `allowKeyboardPaddleOnMac`
(default true) lets the arrow keys override the NF drive frame-by-frame, so the
physics can be exercised without a live NF stream; on the real rig the paddle
is always NF-driven. Otherwise run `python3 simulate_nf.py --path nf.txt`
alongside it, exactly as for `gameNF*.m`.

---
**Keeping this file in sync**: whenever `gamev1.m`, `gameNF.m`, `gameNFv2.m`,
`gameBreakout.m` (or their helper functions) changes in a way that affects
behavior, parameters, timing, triggers, or CSV columns, update this README to
match in the same change. See `CLAUDE.md`.
