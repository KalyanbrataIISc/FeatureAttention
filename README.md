# Feature Attention Task — "Leaves"

A PsychToolbox/MATLAB experiment combining feature-based attention with
concurrent SSVEP tagging. The participant watches two independently moving
and pointing flocks of leaf-shaped stimuli, gets cued on each trial to one of
them, and reports a property of the cued flock.

The script to run is [`gameNFv5.m`](gameNFv5.m); everything
experimenter-tunable lives in its `%% PARAMETERS` block near the top. The
sections below build up the task in the order the variants were written —
the base task first, then each variant as a delta on the one before it — so
read [Colour-report variant (`gameNFv5.m`)](#colour-report-variant-gamenfv5m)
for what actually runs today. In particular, from `gameNFv5.m` on the cue is
a **feature + direction** and the response is the cued flock's **colour**,
not a direction.

## Stimuli

- **Leaves**: round-tailed, pointed shapes (like a raindrop/bullet) — the
  point faces one cardinal direction (up/down/left/right), independent of
  the direction the leaf travels in.
- **Two flocks**, always both on screen at once, sharing the same field
  (no separate regions — leaves from both flocks are intermixed and can
  pass near each other anywhere on screen). Each flock has its own:
  - **pointing direction** (where the leaf shape's tip faces)
  - **moving direction** (where the leaf actually travels)
  - Both are fixed for the whole trial, and re-drawn each trial. From
    `gameNFv3.m` on they are no longer four independent random draws:
    flock 1's pointing and moving directions are always **different from
    each other**, and flock 2 takes the **two leftover** directions — one
    for pointing, one for moving. That yields exactly 4×3×2 = 24 distinct
    `(c1Point, c1Move, c2Point, c2Move)` combinations, which are enumerated
    and then consumed one shuffled 24-trial cycle at a time. So the order
    stays random while every combination is used equally often, including
    at each 24-trial boundary. A `trialNumberPerBlock` that isn't a
    multiple of 24 still balances as evenly as integer counts allow (the
    leftover trials draw distinct combos, no repeats within that partial
    cycle). The older `legacy/gamev1.m`/`gameNF.m`/`gameNFv2.m` instead
    drew all four directions independently at random.
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

*(This is the base task's rule, kept by every variant up to `gameNFv4.m`.
`gameNFv5.m` replaces it — see
[Colour-report variant](#colour-report-variant-gamenfv5m).)*

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
`freqC1Hz` (19 Hz default), flock c2 at `freqC2Hz` (23 Hz default). The
flicker is computed from continuous elapsed time since trial start
(`helperFunctions/computeSsvepBorderColors.m`), independent of the cue and
uninterrupted across the pre-cue/response/feedback phases — it only resets
at the next trial's start. Every leaf in a flock shares the same time base
and frequency, so all leaves in a flock are phase-locked automatically.

**The tagging pair is 19/23 Hz** across the whole project — the games, the
Breakout paddle gratings, `RT_files/RT_acquisition_8.m`/`RT_experiment_5.m`
and the offline analyses all use the same two numbers, and `nf.txt`'s two
columns are now `[SMI_19gt23, SMI_23gt19, sampleCount]`. It was 23/29 Hz
before that, and 17/20 Hz before that.

The 4 Hz gap matters for how the online statistic is computed.
`RT_acquisition_8.m` estimates power from a 1 s, 128-sample epoch with
`params.tapers = [1 1]` — 1 Hz bins and a ±1 Hz multitaper half-bandwidth —
and normalises each tag against its two immediately adjacent bins. At
19/23 Hz those references are 18/20 and 22/24 Hz, all well clear of the
other tag's response and of its smoothing kernel, so each tag's noise floor
is genuinely noise. A 2 Hz-spaced pair (e.g. 17/19) would not clear it: the
17 Hz tag's upper reference bin at 18 Hz would sit on the shoulder of the
19 Hz response and vice versa, making each tag's noise floor partly the
other tag and compressing the lateralisation index. Keep at least ~4 Hz of
separation if this pair is ever retuned again, or lengthen the epoch for
finer bins first.

The one place still on the old scheme is `SSVEPTestTrials.m`, whose
`gratingFreqHz` is 20 Hz.

## Response input

- **Windows** (`~ismac`): Cedrus button box, XID buttons — Up = 1,
  Right = 5, Left = 3, Down = 6 (Middle = 4 is unused). Also sends triggers
  via `cog_send_triggers` and expects eye tracking + a serial paraport.
- **mac**: arrow keys instead of the Cedrus box, no triggers, no eye
  tracking, `SkipSyncTests` enabled. This is the path for development/testing
  on a laptop without the lab hardware.

See `helperFunctions/getDirectionResponse.m` for the unified 4-direction
response check used on both platforms. `gameNFv5.m` instead uses a
2-alternative colour response (Cedrus Left/Right only, arrow keys on mac) —
`helperFunctions/getColorResponse.m`.

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

- `gameNFv5.m` — **the current variant, and the script to run.** Same
  structure as every variant below (init → participant/block info → CSV
  header → PsychToolbox setup → `%% PARAMETERS` → screen open → trial loop →
  cleanup) and the same neurofeedback as `gameNFv4.m`, but the cue is a
  feature + direction and the response is the cued flock's colour; see
  [Colour-report variant](#colour-report-variant-gamenfv5m) below.
- `gameNFv4.m` — the previous variant: same neurofeedback, but cued by
  colour and answered with a direction. Leaf color driven by a windowed
  sustained-success statistic; see
  [Windowed-neurofeedback variant](#windowed-neurofeedback-variant-gamenfv4m)
  below.
- `gameNFv3.m` — the variant before that: `gameNFv2.m` plus the
  direction-balancing scheme described under [Stimuli](#stimuli). Identical
  to `gameNFv4.m` except that its leaf color follows the *instantaneous*
  `nf.txt` value.
- `legacy/` — superseded scripts, kept for reference and no longer run:
  `gamev1.m` (the original non-NF task), `gameNF.m` (the first
  neurofeedback variant; see
  [Neurofeedback variant](#neurofeedback-variant-gamenfm) above),
  `gameNFv2.m` (the SSVEP timing-robustness fix; see
  [Timing-hardened variant](#timing-hardened-variant-gamenfv2m) below), and
  `gameBreakout.m`. The sections below describe each of these in the order
  they were built, since every later variant is a copy of the one before it
  — so `gameNFv4.m`'s behavior is the sum of all of them.
- `gameBreakoutv2.m` / `gameBreakoutv3_WL.m` — a different task entirely
  (SSVEP-neurofeedback Breakout), sharing only `nf.txt` and the scaffolding;
  see [Breakout task](#breakout-task-gamebreakoutm) below.
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
  written) by every `gameNF*.m` variant.
- `data/` — per-participant/block CSV logs (created on first run).
- `analysis/ssvepCueOnsetLocked.m` and
  `analysis/ssvepResponseLocked.m` — offline cue-locked and response-locked
  SSVEP analyses. Each script can independently generate combined and/or
  per-participant ongoing (induced) and evoked power spectra in addition to
  its event-locked time-series plots.
- `analysis/online_view.py` — interactive GDF playback viewer with live
  signals, FFT power, FFT phase, selected-channel averages, and automatic
  joining of numbered GDF recording chunks.

## Running it

Open and run `gameNFv5.m` in MATLAB with PsychToolbox installed (earlier
`gameNF*.m` variants and the scripts in `legacy/` are documented below but
are no longer the ones to run). On Windows you'll be prompted for
participant number, block number, and whether to run eye tracking; on mac
these default automatically (participant/block `000`, eye tracking off) so
it just launches straight into the task.

Before the block starts, a one-time instructions screen explains the task
in text and shows two **static** (non-moving) example leaves. In
`gameNFv5.m` those show the colour → button mapping (orange on the left
labeled "press the LEFT button", blue on the right labeled "press the RIGHT
button"); in `gameNFv4.m` and earlier they instead showed the colour → rule
mapping ("use its POINTING direction" / "use its MOVING direction"). Press
any key/button on that screen to begin; ESC exits at any point during the
block. All tunable values (timing, leaf size/speed/count, colors, SSVEP
frequencies, cue rectangle, and the neurofeedback window/thresholds) are in
the `%% PARAMETERS` block near the top of the script.

## GDF playback viewer

Run the viewer from the repository root:

```bash
python analysis/online_view.py
```

Choose the first GDF file in the left sidebar and press **Start / Reload**.
For a recording named `test.gdf`, the viewer automatically discovers and
joins `test_1.gdf`, `test_2.gdf`, and later numbered parts in numeric order.
Selecting any numbered part discovers the same set. Other recordings with
the same prefix but a different stem, such as `test_practice.gdf`, are not
included.

The viewer reads samples on demand instead of loading all 1 GB files into
memory. The sidebar provides playback speed, play/pause, seeking, output
sampling rate, signal history, FFT duration/window/sliding step/bin target,
frequency limits, and a bounded FFT worker count. Shift-click selects a
channel range and Command-click adds or removes individual channels. The
white top plot in the live-signal tab is the time-domain average of the
selected channels; every selected channel then has its own vertically stacked
plot. The FFT power and phase tabs overlay the selected channels and the
white average. **Only show the selected-channel average** hides all individual
channel plots/traces without changing which channels contribute to that
average. Both FFT tabs share editable X limits and have independent
auto/manual Y scaling and Y limits; X scaling can likewise use the selected
limits or the complete 0-to-Nyquist range.

A large sidebar state sign is green from the `trialstart` trigger (20) up to
the `trialstop` trigger (30), and red during ITIs. FFT bin spacing may be made
finer with zero-padding, but the true frequency resolution remains
`1 / FFT duration`.

Python dependencies are `numpy`, `scipy`, `mne`, `pyqtgraph`, `PyQt5`, and
optionally `mlx` for Apple Metal FFTs. GDF loading/resampling and FFT
computation run on separate background workers. On macOS, pyqtgraph uses an
OpenGL viewport with antialiasing disabled, clipped curves, automatic display
downsampling, and thinner pens. The FFT backend can be Auto, Metal GPU (MLX),
or multicore CPU (SciPy). Auto benchmarks a synchronized FFT once and keeps
the faster backend; on the tested M1 Pro the CPU wins for the viewer's small
channel windows, while OpenGL still uses the GPU for the heavier rendering
work. Set `GDF_VIEWER_DISABLE_OPENGL=1` before launch to use software
rendering if a particular macOS/Qt configuration has an OpenGL problem.

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
`[SMI_19gt23, SMI_23gt19, sampleCount]` — the 19Hz-vs-23Hz SSVEP power
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
`c1` (19Hz) uses column 1 (positive when 19Hz > 23Hz), cue `c2` (23Hz) uses
column 2 (positive when 23Hz > 19Hz).

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
protocol from. (This last point is what the current `gameNFv4.m` changes —
see [Windowed-neurofeedback
variant](#windowed-neurofeedback-variant-gamenfv4m) below. Everything else
in this section still describes it.)

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
value (e.g. 19 Hz reading as ~18.6 Hz, 23 Hz as ~22.5 Hz) by an amount that
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

## Windowed-neurofeedback variant (`gameNFv4.m`)

`gameNFv4.m` was the current neurofeedback variant until `gameNFv5.m`
(below) superseded it — an independent copy of `gameNFv3.m` (itself a copy of `gameNFv2.m` with the direction-balancing
scheme described under [Stimuli](#stimuli)), changing only *what statistic
the leaf color is driven by*. Everything else — the CIELAB Delta E color
mapping, the real-time-anchored SSVEP phase, dropped-frame logging, the
`nf.txt` protocol, triggers, trial flow — is unchanged from `gameNFv2.m`.

**The problem.** In every earlier NF variant the leaf fill tracks the
*instantaneous* value read from `nf.txt`. Real-time SSVEP power
lateralisation is very noisy on its ~100ms update cadence, so the leaves
visibly flicker in color, which is both distracting and hard to act on.

**The fix — a windowed sustained-success statistic.** Instead of the raw
value, the color is driven by how much of a trailing window the participant
held a good-enough lateralisation:

1. Every displayed frame's NF value is pushed into a rolling `nfWindowSec`
   ring buffer, re-zeroed at each trial start.
2. `nfAboveProportion` = the fraction of that window strictly above
   `nfValueThreshold`.
3. That proportion is thresholded and rescaled — at or below
   `nfProportionThreshold` the drive is 0, and the top slice
   `[nfProportionThreshold, 1]` maps linearly onto drive `[0, 1]`. This
   drive, not the raw value, is what
   `helperFunctions/computeNfLeafColor.m` receives.

Defaults:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `nfWindowSec` | `1.000` | length of the trailing window |
| `nfValueThreshold` | `0.001` | an NF value must exceed this to count as a success |
| `nfProportionThreshold` | `0.80` | proportion of the window that must be successes before *any* color is revealed |

At `nfValueThreshold = 0.001` — just above zero — a sample counts as a
success whenever the lateralisation favours the cued frequency *at all*, so
the statistic is effectively a sign test ("what fraction of the last second
did SSVEP lean the right way?") rather than a test of how *strongly* it
leaned. Raise it to demand a minimum magnitude as well.

**Latencies follow directly from those two timing numbers:**

```
first color   = nfProportionThreshold * nfWindowSec        -> 0.8s
full color    = nfWindowSec                                -> 1.0s
back to grey  = (1 - nfProportionThreshold) * nfWindowSec  -> 0.2s
```

So success has to be earned across most of a window but is lost again
quickly. Raising `nfProportionThreshold` sharpens both ends at once.

**Sampling per displayed frame, not per `nf.txt` write.** `nf.txt` only
changes every ~100ms, so consecutive frames push the same value ~6 times
over. That is deliberate: it makes the result a proportion of elapsed
*time* rather than of samples, and keeps it correct even when the external
writer's cadence jitters.

**The window is pre-filled with zeros at trial start**, so it is always
exactly `nfWindowFrames` long and the proportion's denominator never
changes. A window sized only to the samples collected so far would let a
single lucky above-threshold sample on frame 1 read as a proportion of 1.0
and drive full color, and would be wildly noisy until `nfWindowSec` had
elapsed. Pre-filled zeros count as ordinary below-threshold failures
instead, so color can only ever appear after a genuinely sustained run of
successes — and the latency from cue onset is identical no matter how short
that trial's pre-cue period happened to be.

The window keeps filling from **trial start**, not cue onset, so it already
carries real data by the time color is first shown and there is no ramp-up
dead time at cue onset. Only the *visual* use of the drive is gated to
post-cue; the buffer updates on every frame regardless of phase.
`RT_acquisition_8.m` zeroes `nf.txt` at trial start, so the earliest pre-cue
samples read ~0 anyway and agree with the pre-filled zeros they replace.
Note that this does mean a genuinely sustained pre-cue lateralisation (a
full `nfWindowSec` of it) will show color immediately at cue onset — that is
real data, not an artifact.

**CSV output differences.** The main per-trial CSV and the dropped-frame CSV
are identical in shape to `gameNFv2.m`'s. The NF trace CSV gains two columns:

```
TrialNumber, FrameNumber, SampleTime, NFIndexUsed, NFValueRaw,
NFValueClipped, NFWindowProportion, NFDrive, PostCueOnset, NFReadOk
```

`NFWindowProportion` is `nfAboveProportion` at that sampled frame and
`NFDrive` is the rescaled `[0, 1]` value actually driving the color;
`NFValueRaw`/`NFValueClipped` are retained so the underlying raw stream the
window was computed from stays auditable offline. There is no window-fill
column because the window is pre-filled and therefore always full.
`NFValueClipped` is now purely diagnostic — it no longer drives anything.

## Colour-report variant (`gameNFv5.m`)

`gameNFv5.m` is the **current** variant and the script to run — an
independent copy of `gameNFv4.m` that leaves the neurofeedback completely
untouched (same windowed sustained-success statistic and its three
parameters, same CIELAB Delta E colour mapping, same `nf.txt` protocol and
per-frame read cadence, same SSVEP tagging, timing, jitter, triggers,
dropped-frame logging and NF-trace CSV) and changes only **what the cue says
and what the participant reports**.

**The cue is a feature + a direction.** Instead of a coloured box saying
"Pointing"/"Moving", the box shows two lines — the feature above the
direction, e.g. `MOVING` / `UP` — meaning *the group that is moving upward*.
Since the direction scheme from `gameNFv3.m` on makes
`(c1PointDir, c1MoveDir, c2PointDir, c2MoveDir)` a permutation of all four
directions, exactly four cues are possible on any trial:

```
moving c1MoveDir     pointing c1PointDir     (both identify flock c1)
moving c2MoveDir     pointing c2PointDir     (both identify flock c2)
```

Each identifies exactly one flock. The four cue types are consumed as
shuffled **4-trial cycles** (the same idea as the 24-trial direction
cycles), so all four types — and therefore both features, both cued flocks
and both correct colours — occur equally often at every 4-trial boundary,
not merely across the whole block. Note that because all four directions are
distinct, the cued direction on its own is already unique: the feature word
tells the participant *which dimension to search*, it does not disambiguate
two candidate flocks.

**The response is the cued flock's colour.** Two alternatives, fixed for the
whole experiment and spelled out on the instructions screen:

```
Cedrus Left (3) / left arrow   = ORANGE = flock c2
Cedrus Right (5) / right arrow = BLUE   = flock c1
```

Cedrus Up/Middle/Down are simply ignored (the response window stays open).
See `helperFunctions/getColorResponse.m`; the label each button maps to is
passed in from `gameNFv5.m`'s `responseLabelC1`/`responseLabelC2`, so the
mapping lives next to the colours it refers to in the `%% PARAMETERS` block.

**The cue box is neutral.** It can no longer be filled with the cued flock's
colour — that colour is the answer. It stays black through the pre-cue
period and the ITI (`colorCueRectPreCue`) and turns **dark green**
(`colorCueRectPostCue`, `[0 100 0]`) with white text at cue onset, and is
bigger than `gameNFv4.m`'s (280×120 px) to fit two lines. Dark green is
neutral with respect to both flock colours and is a far smaller luminance
step up from the black pre-cue box than white would be, which matters for a
box sitting at fixation in an SSVEP recording. Feedback still replaces the
cue text inside that same box, in light green/red (`colorFeedbackCorrect`
`[170 255 170]`, `colorFeedbackIncorrect` `[255 150 150]`) so it stays
readable against the dark green fill.

**The task is deliberately gated on neurofeedback success.** The leaf fill
colour is both the NF signal and the answer, and `nfBaselineDeltaE` stays at
`0`, so there is no fixed cue-onset reveal: the flocks are pure background
grey and differ only in their directions and their 19/23 Hz border flicker
until a sustained correct lateralisation brings the colours out. A trial
where that never happens ends as a guess or a timeout, by design. Two
consequences for analysis: chance is now **50%**, not 25%, and reaction time
is dominated by time-to-reveal rather than by decision time — which is what
the new `ColorRevealTime` column is for. Setting `nfBaselineDeltaE` above 0
makes every trial answerable but removes the gating.

**CSV output differences.** The NF-trace and dropped-frame CSVs are
unchanged. The main per-trial CSV gains `CueFeature`, `CueDirection` and a
trailing `ColorRevealTime`:

```
TrialNumber, TrialStart, C1PointDir, C1MoveDir, C2PointDir, C2MoveDir, Cue,
CueFeature, CueDirection, CueOnsetTime, CorrectResponse, ParticipantResponse,
Accuracy, ReactionTime, ResponseTimeout, TrialEnd, DroppedFrameCount,
ColorRevealTime
```

`CueFeature` is `moving`/`pointing` and `CueDirection` is the cued
`up`/`down`/`left`/`right` — together, the literal cue that was displayed.
`Cue` is **kept**, still valued `c1`/`c2` (the flock the cue points at):
it is what fixes the attended SSVEP frequency and the `nf.txt` column, and
it is what the offline `analysis/` scripts and
`helperFunctions/computeRtStatsByBlockAndCue.m` group by, so they keep
working unchanged. `CorrectResponse`/`ParticipantResponse` now hold
`blue`/`orange` (or `missed`) rather than a direction. `ColorRevealTime` is
the timestamp of the first post-cue frame actually displayed with
`nfDrive > 0`, taken after that frame's flip like `CueOnsetTime`, and is
`NaN` on trials where the colours never appeared.

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
flickering at `gratingLeftFreqHz` (19 Hz) on the left, a **non-flickering**
strip in the middle, and a grating at `gratingRightFreqHz` (23 Hz) on the
right. Those two gratings are the entire SSVEP stimulus. Their flicker is an
on-off sinusoidal contrast envelope — at the peak of each cycle the bars sit at
full black/white contrast, at the trough both collapse to a uniform grey and
the pattern vanishes — so the flicker fundamental is exactly the nominal
frequency (`breakoutHelperFunctions/computeGratingColors.m`). A
contrast-*reversing* grating was deliberately not used: its dominant response
would land at 2f, not at the 19/23 Hz bins the acquisition and the control law
are built around.

**Paddle motion is the neurofeedback.** `nf.txt` is read fresh every displayed
frame (`breakoutHelperFunctions/readNfPair.m`, which reads both columns in one
`fopen`, unlike the leaves task's one-column `readNFValue.m`). 19 Hz dominance
drives the paddle left, 23 Hz dominance drives it right, at a speed **linear**
in `nf23 - nf19`, clamped to `paddleMaxSpeedPxPerSec`, with a `paddleNfDeadzone`
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
   here: 19 and 23 Hz both complete a whole number of cycles per second, so the
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
costs one bounded phase correction instead of permanently detuning 19/23 Hz.

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
TrialNumber, FrameNumber, SampleTime, NF19, NF23, NFSigned, NFReadOk,
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

## SSVEP test task (`SSVEPTestTrials.m`)

A third, independent task — not a variant of the leaves task or Breakout. It
shares only the Cedrus/trigger/eye-tracking scaffolding in `functions/` and a
handful of generic helpers (`ensureCsvWithHeader`, `checkEscape`,
`cleanupExperiment`, `getElapsedTime`). Its own logic lives in
`ssvepTestHelperFunctions/`, one function per file. It has no cue, no
neurofeedback, and no directional response — it exists to test SSVEP tagging
and a letter-counting working-memory load in one simple design.

**Stimulus.** A circular black/white grating patch flickers in place at
screen center: a plain vertical-bar square-wave grating (drawn with
`breakoutHelperFunctions/drawFlickerGrating.m`, the same grating primitive
`gameBreakoutv2.m`'s paddle uses) whose *contrast* is what flickers
sinusoidally at `gratingFreqHz` (20 Hz in the current script — this task was
never moved onto the tagging pair the other tasks use, which is now 19/23 Hz)
between `grey` (0 contrast -
the pattern vanishes into the background) and full black/white (via
`breakoutHelperFunctions/computeGratingColors.m`). The grating is clipped to
a circle by a one-time RGBA aperture-mask texture
(`ssvepTestHelperFunctions/createCircularApertureMask.m`, built once at
setup, not rebuilt per frame) drawn on top of the grating rect each frame -
this keeps the per-frame cost the same as a plain rectangular grating while
still presenting a circular patch. A small static white disc
(`discRadiusPx`) sits at the patch's center; inside it, one letter at a time
is shown, changing every `letterDurationSec`. The letter's own contrast
flickers too, from `discColor` (invisible against the disc) up to
`letterColorPeak`, computed from the *exact same* elapsed-time value and
`gratingFreqHz` as the grating - so the letter and the grating are always in
exact phase, by construction (same formula, same `t`).

As in `gameNFv2.m`/`gameBreakoutv2.m`, this phase is driven from real
`Screen('Flip')` VBL timestamps, not a frame counter, so a dropped frame
costs one bounded phase correction rather than a permanent frequency drift;
dropped frames during the stream are logged the same way (see CSV output
below).

**Letter rules and the task.** Letters are drawn from `letterPool` (A-Z) via
`ssvepTestHelperFunctions/generateLetterSequence.m`: the same letter never
appears on two consecutive draws, and the target letter `X` appears some
random number of times per trial, drawn uniformly from
`[xCountMin, xCountMax]` (2-5 by default, clamped down if the trial is too
short to fit that many X's with no two adjacent). The participant silently
counts the X's during the stream and, once it ends, reports whether their
count was **odd** or **even**.

**Trial timeline.**

1. **SSVEP + letter stream** (`trialDurationSec`, 10s default) - trigger
   `trialstart` is sent right after the flip that shows the very first
   stimulus frame (not before, so the marker lines up with what was actually
   displayed - see `gameBreakoutv2.m`'s ball-spawn trigger for the same
   pattern). The grating and letter flicker continuously for the whole
   phase; no response is collected here.
2. **ITI** (`itiDurationSec`, 10s default, **always** exactly this long
   regardless of RT or feedback timing) - trigger `trialstop` is sent right
   after the stream's last frame. The screen goes blank (no SSVEP at all
   during the ITI). Any Cedrus events queued during the stream are discarded
   and the RT timer reset at ITI onset, so the response window opens clean.
   The participant has until `itiResponseDeadlineSec`
   (`itiDurationSec - itiFeedbackDurationSec`) to respond **Odd** (Cedrus
   Left / mac left arrow) or **Even** (Cedrus Right / mac right arrow) -
   trigger `response` is sent on a valid press. Feedback ('Correct' /
   'Incorrect', or 'Missed' on a timeout) is then shown for
   `itiFeedbackDurationSec`, sized so it always finishes exactly as the fixed
   `itiDurationSec` runs out.

Escaping (ESC key) at any point ends the block after sending `trialstop` (if
the stream had already started) and cleaning up; no CSV row is written for an
aborted trial - same convention as the leaves task.

**Triggers.** Only the subset `gamev1.m` also uses: `trialstart` (20),
`response` (40), `trialstop` (30) - see `functions/cog_send_triggers.m`. No
new trigger codes were added.

**CSV output.** One file per participant/block in `data/`, same
header-mismatch-safe-fallback behavior as the other tasks'.
`p<participant>_b<block>_ssveptest_trialdata.csv`, one row per trial:

```
TrialNumber, TrialStart, LetterSequence, NumLetters, XCount, CorrectResponse,
ParticipantResponse, Accuracy, ReactionTime, ResponseTimeout, TrialEnd,
DroppedFrameCount
```

`LetterSequence` is the literal letter string shown that trial (e.g.
`ABXCDXEFGHIJ`); `XCount` is the ground-truth number of X's in it, and
`CorrectResponse` is `'odd'`/`'even'` from its parity. A second file,
`p<participant>_b<block>_ssveptest_droppedframes.csv`, logs one row per
dropped/delayed frame during the SSVEP stream (same shape as
`gameNFv2.m`'s): `TrialNumber, FrameNumber, VBLTime, MissedBySec`.

**Running it.** Same as the other tasks - participant number, block number,
eye tracking prompt on Windows; defaults (`000`/`000`, eye tracking off) on
mac. All tunable values (timing, letter pool/counts, grating geometry/color,
disc/letter appearance) are in the `%% PARAMETERS` block near the top of
`SSVEPTestTrials.m`.

---
**Keeping this file in sync**: whenever `gameNFv5.m`, `gameNFv4.m`, `gameNFv3.m`,
`gameBreakoutv2.m`, `gameBreakoutv3_WL.m`, `SSVEPTestTrials.m`, anything in
`legacy/` (or their helper functions) changes in a way that affects
behavior, parameters, timing, triggers, or CSV columns, update this README
to match in the same change. See `CLAUDE.md`.
