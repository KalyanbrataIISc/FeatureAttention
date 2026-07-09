# Repository Guidelines

## Project Structure & Module Organization

This repository is a MATLAB/PsychToolbox feature-attention and SSVEP experiment. Main experiment scripts live at the root: `gamev1.m` for the base task and `gameNF*.m` for neurofeedback variants. Task-specific reusable code belongs in `helperFunctions/`, one function per `.m` file. Lab scaffolding such as Cedrus, eye tracking, and trigger helpers lives in `functions/`. Offline analysis scripts and resources are in `analysis/`, with generated outputs under `analysis/results/`. Runtime trial CSVs are written to `data/`. `RT_files/` and `UnrelatedContextFiles/` are legacy/context scripts; leave them alone unless explicitly targeted.

## Build, Test, and Development Commands

There is no build step. Run scripts from MATLAB with the repository as the working folder.

- `gamev1` runs the base task.
- `gameNFv3` runs the current neurofeedback variant.
- `checkcode gamev1.m helperFunctions/updateLeaves.m` runs MATLAB static analysis on changed files.
- `addpath(genpath(pwd))` can be used in MATLAB before calling helper functions interactively.

PsychToolbox display, keyboard/Cedrus, and trigger behavior require interactive MATLAB; they cannot be fully verified headlessly.

## Coding Style & Naming Conventions

Use MATLAB idioms already present in the repo: 4-space indentation, descriptive `camelCase` names, and one public function per file. Keep script-level tunables in the script `%% PARAMETERS` block. The lab MATLAB version does not support local functions inside scripts, so add new helpers in `helperFunctions/` instead of appending local functions to `gamev1.m` or `gameNF*.m`. Prefer small helpers for pure logic and keep PsychToolbox/Cedrus side effects isolated.

## Testing Guidelines

Run `checkcode` on every changed `.m` file. For pure helper logic, add or run small MATLAB smoke checks that exercise invariants such as timing, collision avoidance, color mapping, and CSV shape. For any change touching `Screen`, `KbCheck`, Cedrus, triggers, or eye tracking, perform a live interactive smoke test when hardware is available; otherwise state that limitation clearly.

## Commit & Pull Request Guidelines

Recent commits use concise imperative summaries such as `Add trigger values documentation...`, `Refactor neurofeedback handling...`, and `Update README...`. Follow that style: start with a verb and describe the behavioral change. PRs should include a short purpose statement, affected scripts/helpers, verification performed, and any hardware or live-test gaps. Link issues when applicable and include screenshots or plots for visual/analysis output changes.

## Documentation & Data Safety

When behavior, parameters, timing, triggers, CSV columns, or trial flow change, update `README.md` in the same change. Do not commit generated participant data from `data/` or bulky analysis outputs unless explicitly required.
