# Repository Guidelines

## Project Structure & Module Organization

This repository is a MATLAB/PsychToolbox feature-attention and SSVEP experiment. Main experiment scripts live at the root: `gamev1.m` for the base task and `gameNF*.m` for neurofeedback variants. Task-specific reusable code belongs in `helperFunctions/`, one function per `.m` file. Lab scaffolding such as Cedrus, eye tracking, and trigger helpers lives in `functions/`. Offline analysis scripts and resources are in `analysis/`, with generated outputs under `analysis/results/`. Runtime trial CSVs are written to `data/`. `RT_files/` and `UnrelatedContextFiles/` are legacy/context scripts; leave them alone unless explicitly targeted.

## Build, Test, and Development Commands

There is no build step. Run scripts from MATLAB with the repository as the working folder.

- `gameNFv5` runs the current variant: same windowed neurofeedback as `gameNFv4`, but the cue is a feature + direction (e.g. "MOVING UP") and the participant reports the cued flock's colour with two buttons (left = orange = c2, right = blue = c1). See `README.md`.
- `gameNFv4` runs the previous variant, cued by colour and answered with a direction, with the leaf color driven by a windowed sustained-success statistic over `nf.txt` rather than by its instantaneous value (`nfWindowSec`/`nfValueThreshold`/`nfProportionThreshold` in its `%% PARAMETERS` block).
- `gameNFv3` runs the variant before that, identical to `gameNFv4` except that the leaf color follows the instantaneous `nf.txt` value.
- `legacy/gamev1.m` is the original base task, superseded and no longer run.
- `checkcode gameNFv5.m helperFunctions/updateLeaves.m` runs MATLAB static analysis on changed files.
- `addpath(genpath(pwd))` can be used in MATLAB before calling helper functions interactively.

PsychToolbox display, keyboard/Cedrus, and trigger behavior require interactive MATLAB; they cannot be fully verified headlessly.

## Coding Style & Naming Conventions

Use MATLAB idioms already present in the repo: 4-space indentation, descriptive `camelCase` names, and one public function per file. Keep script-level tunables in the script `%% PARAMETERS` block. The lab MATLAB version does not support local functions inside scripts, so add new helpers in `helperFunctions/` instead of appending local functions to `gameNF*.m` or any other experiment script. Prefer small helpers for pure logic and keep PsychToolbox/Cedrus side effects isolated.

## Testing Guidelines

Run `checkcode` on every changed `.m` file. For pure helper logic, add or run small MATLAB smoke checks that exercise invariants such as timing, collision avoidance, color mapping, and CSV shape. For any change touching `Screen`, `KbCheck`, Cedrus, triggers, or eye tracking, perform a live interactive smoke test when hardware is available; otherwise state that limitation clearly.

## Commit & Pull Request Guidelines

Recent commits use concise imperative summaries such as `Add trigger values documentation...`, `Refactor neurofeedback handling...`, and `Update README...`. Follow that style: start with a verb and describe the behavioral change. PRs should include a short purpose statement, affected scripts/helpers, verification performed, and any hardware or live-test gaps. Link issues when applicable and include screenshots or plots for visual/analysis output changes.

## Documentation & Data Safety

When behavior, parameters, timing, triggers, CSV columns, or trial flow change, update `README.md` in the same change. Do not commit generated participant data from `data/` or bulky analysis outputs unless explicitly required.
