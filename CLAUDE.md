# FeatureAttention project conventions

This is a PsychToolbox/MATLAB cognitive science experiment (the "Leaves"
feature-attention + SSVEP task). See `README.md` for the full task
description — read it before making changes so edits stay consistent with
the documented design.

## Keep README.md in sync

**Whenever `gamev1.m` or any file in `helperFunctions/`/`functions/` changes
in a way that affects behavior, parameters, timing, triggers, CSV columns,
or the trial flow, update `README.md` in the same change.** Do not leave
this for a later pass. This includes parameter renames, new/removed
triggers, changed CSV columns, changed trial phases, and changed defaults
worth calling out (e.g. "leaves are now full-screen, no aperture").

## MATLAB version constraint

This lab's MATLAB version does not support local functions inside a script.
Any new helper function must be its own file in `helperFunctions/` (one
function per file), not defined inline in `gamev1.m`.

## Verifying changes

There's no PsychToolbox-capable headless test environment here. Verify
changes with:
- `checkcode` (MATLAB's static analyzer) on every changed/new `.m` file.
- Where feasible, a real functional smoke test of pure-logic helpers (no
  `Screen`/Cedrus/`KbCheck` calls) — e.g. simulate `initLeaves`/`updateLeaves`
  over many frames and check the collision/lifetime/timing invariants
  actually hold, not just that the code parses.
- A live interactive run (on mac: arrow keys, `eyeTracking=0`) is the only
  way to check anything touching `Screen`, Cedrus, or `KbCheck` — flag this
  limitation rather than claiming it's verified.

Don't run redundant/extra verification passes the user didn't ask for once
the above has already passed for a given change.
