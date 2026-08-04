% gameNFv7.m - gameNFv6.m with fixed-path leaf motion.
%
% Identical to gameNFv6.m in cue, goal, neurofeedback, timing, triggers and
% CSV output - the centre box still turns colorC1/colorC2 and says
% 'Pointing'/'Moving', the participant still reports that flock's
% pointing/moving direction, and the grayscale integrator, green zone,
% colour reveal and response gating are unchanged. See the NEUROFEEDBACK
% PARAMETERS block for that mechanism.
%
% What changes is how the leaves move. gameNFv6.m used the RDK-style motion
% of initLeaves.m/updateLeaves.m, where a leaf is respawned elsewhere
% whenever its lifetime expires, it leaves the field, or it drifts too close
% to a leaf of the other flock - so leaves continually appear and disappear
% and the on-screen count wobbles. v7 puts every leaf on a permanent
% wrapping path instead, chosen at trial setup so that no two leaves ever
% overlap: nothing respawns, each leaf crosses the field and re-enters from
% the far side, and exactly 2*numLeavesPerFlock leaves are on screen at all
% times. See the FIXED-PATH LEAF MOTION block below, and initLeafLanes.m for
% the construction and its one real constraint on field size.

%% Initialise
clc;        % Clears the Command Window
close all;  % Closes all figure windows
sca;        % Clears the screen
testing = true; %#ok<*UNRCH> % true = laptop testing; false = experiment-room hardware

if ~testing
    if exist('cedrus','var')
        cedrus.close();
    end

    s=instrfind; %#ok<INSTRF>
    if ~isempty(s)
        fclose(s);
    end
end

clearvars -except testing; % Removes old variables but keeps the run-mode selection

experimentRoot = fileparts(mfilename('fullpath'));
if isempty(experimentRoot)
    experimentRoot = pwd;
end
addpath(genpath(experimentRoot));

if ~testing
    % Begining
    cedrusopen;
end

%% Participant and block info
if ~testing
    participantInfo = input('Enter your participant number: ', 's');
    blockInfo = input('Enter your block number: ', 's');
else
    participantInfo = '000'; % Test
    blockInfo = '000'; % Test
end

% Initialize timer
experimentStartTime = GetSecs;

if ~testing
    eyeTracking = input('Eyetracking (1 or 0)?');
else
    eyeTracking = 0;
end

%% Info for CSV logging
% Unique session tag
sessionTag = sprintf('p%s_b%s', participantInfo, blockInfo);

% CSV logging (absolute path, header-once)
csvBaseDir = fullfile(experimentRoot, 'data');
if ~exist(csvBaseDir, 'dir')
    mkdir(csvBaseDir);
end
% v6: three new columns, and one changed meaning.
%   FirstGreenTime  - first moment the NF level entered the green zone this
%                     trial (NaN if it never did). Diagnostic: it separates
%                     "never got near white" from "got there but couldn't
%                     hold it" for a trial that never revealed.
%   ColorOnsetTime  - the moment the flocks' true colours were revealed,
%                     i.e. the green zone had been held for nfGreenHoldSec
%                     (NaN if that never happened). This is the event the
%                     response window opens at and the event ReactionTime is
%                     measured from, so it is needed to interpret either.
%   RevealTimeout   - 1 if the trial ended because colours never appeared
%                     within nfRevealTimeoutSec of cue onset. Distinct from
%                     ResponseTimeout, which now means the colours DID
%                     appear but no response followed within
%                     responseTimeoutSec. The two are mutually exclusive.
% ReactionTime is now measured from colour onset, not cue onset, since no
% response is accepted before then. CueOnsetTime is still logged, so
% time-from-cue is recoverable offline.
csvHeader = ['TrialNumber,TrialStart,C1PointDir,C1MoveDir,C2PointDir,C2MoveDir,Cue,CueOnsetTime,' ...
    'FirstGreenTime,ColorOnsetTime,CorrectResponse,ParticipantResponse,Accuracy,ReactionTime,' ...
    'RevealTimeout,ResponseTimeout,TrialEnd,DroppedFrameCount'];
csvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_leaves_trialdata.csv', sessionTag), csvHeader);

% Per-~100ms NF trace (one row per nfTraceLogIntervalSec), separate file so
% the one-row-per-trial main CSV above stays unchanged in shape.
% v6: v4's NFWindowProportion/NFDrive are gone with the rolling window they
% came from, replaced by the integrator's state (see NEUROFEEDBACK
% PARAMETERS below): NFLevel is the 0-1 grayscale level actually on screen,
% InGreenZone/GreenHoldSec/ColorsRevealed are the reveal state machine.
% NFValueRaw is the value read from nf.txt and NFValueClipped is that value
% clipped to +/-nfValueClipLimit, i.e. exactly what the step was computed
% from - both are kept so the level's trajectory stays reconstructible
% offline from the raw stream alone.
nfTraceCsvHeader = ['TrialNumber,FrameNumber,SampleTime,NFIndexUsed,' ...
    'NFValueRaw,NFValueClipped,NFLevel,InGreenZone,GreenHoldSec,ColorsRevealed,PostCueOnset,NFReadOk'];
nfTraceCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_leaves_nftrace.csv', sessionTag), nfTraceCsvHeader);

% Dropped/delayed-frame log (v2 only): one row per frame whose Screen('Flip')
% missed its requested presentation deadline. See computeSsvepColorsFromTime.m
% for why this is worth tracking - a frame-counter-based SSVEP time base
% silently and permanently detunes the flicker frequency under GPU load,
% while a VBL-timestamp-based one only takes a single bounded phase
% correction per drop. This file lets that drop rate actually be measured
% on a given rig instead of only inferred after the fact from EEG spectra.
droppedFrameCsvHeader = 'TrialNumber,FrameNumber,VBLTime,MissedBySec';
droppedFrameCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_leaves_droppedframes.csv', sessionTag), droppedFrameCsvHeader);

% Cedrus:   Up button       = 1
%           Right button    = 5
%           Middle button   = 4 (unused)
%           Left button     = 3
%           Down button     = 6

% Here we call some default settings for setting up Psychtoolbox
PsychDefaultSetup(2);
if testing || ismac
    Screen('Preference', 'SkipSyncTests', 1);
end

% Unify key names across different operating systems
KbName('UnifyKeyNames');

% Paraport setup for triggers
if ~testing
    paraport = serial('COM9','BaudRate',115200,'DataBits',8, 'StopBits', 1, 'Parity', 'none'); %#ok<SERIAL>
    get(paraport);
    fopen(paraport);
    cog_send_triggers(paraport,'reset');
end
if ~exist('paraport','var')
    paraport = [];
end

%% Display colors
% v6 dropped gameNFv4.m's `grey` from this palette: nothing is drawn in it
% any more now that the background is black and the leaf fill is a
% computed grayscale level rather than an interpolation away from grey.
black = [0 0 0];
white = [255 255 255];
green = [0 255 0];
red   = [255 0 0];

%% PARAMETERS
% Display selection
% On the Windows testing laptop, PTB screen 2 is the external Dell monitor.
% The experiment-room path retains its existing highest-screen selection.
testingStimulusScreenNumber = 2;

% Key mappings (used only in testing mode, where no Cedrus box is present)
escapeKey = KbName('ESCAPE');
leftKey   = KbName('LeftArrow');
rightKey  = KbName('RightArrow');
upKey     = KbName('UpArrow');
downKey   = KbName('DownArrow');

% Experiment structure
trialNumberPerBlock = 24; % ideally a multiple of 24 (see directionTrialList
% below) so both the cue and every direction combo land exactly uniform;
% other values (e.g. for a quick test run) still balance as evenly as
% integer counts allow, just not perfectly.
directionSet = {'up', 'down', 'left', 'right'};
numCueC1 = floor(trialNumberPerBlock / 2);
numCueC2 = trialNumberPerBlock - numCueC1;
cueList = [repmat({'c1'}, 1, numCueC1), repmat({'c2'}, 1, numCueC2)];
cueList = cueList(randperm(numel(cueList)));

% v3: flock 1's pointing/moving directions are always different from each
% other, and flock 2 always takes the two leftover directions (also
% different from each other) - one for pointing, one for moving. That
% yields exactly 4*3*2 = 24 distinct (c1PointDir, c1MoveDir, c2PointDir,
% c2MoveDir) combinations; directionCombos enumerates all of them.
directionCombos = cell(24, 4);
comboIdx = 1;
for c1PointIdx = 1:4
    for c1MoveIdx = 1:4
        if c1MoveIdx == c1PointIdx
            continue;
        end
        remainingIdx = setdiff(1:4, [c1PointIdx c1MoveIdx]);
        for swap = 0:1
            c2PointIdx = remainingIdx(1 + swap);
            c2MoveIdx  = remainingIdx(2 - swap);
            directionCombos(comboIdx, :) = directionSet([c1PointIdx c1MoveIdx c2PointIdx c2MoveIdx]);
            comboIdx = comboIdx + 1;
        end
    end
end

% Fill directionTrialList with directionCombos repeated/shuffled one full
% 24-combo cycle at a time, so every combination is used equally often
% (uniform) while the trial order stays random, even for prefixes of the
% block at each 24-trial boundary. If trialNumberPerBlock isn't an exact
% multiple of 24 (e.g. a short test run), the leftover trials get a random
% subset of distinct combos - no combo repeats within that leftover partial
% cycle, so coverage stays as uniform as the trial count allows.
numDirectionCombos = size(directionCombos, 1);
numFullDirectionCycles = floor(trialNumberPerBlock / numDirectionCombos);
numLeftoverDirectionTrials = trialNumberPerBlock - numFullDirectionCycles * numDirectionCombos;
directionTrialList = cell(trialNumberPerBlock, 4);
rowCursor = 1;
for cycle = 1:numFullDirectionCycles
    directionTrialList(rowCursor:rowCursor + numDirectionCombos - 1, :) = ...
        directionCombos(randperm(numDirectionCombos), :);
    rowCursor = rowCursor + numDirectionCombos;
end
if numLeftoverDirectionTrials > 0
    leftoverComboIdx = randperm(numDirectionCombos, numLeftoverDirectionTrials);
    directionTrialList(rowCursor:end, :) = directionCombos(leftoverComboIdx, :);
end

% Timing in seconds, converted to frames after the measured refresh rate is known
preCueConstantSec   = 1.000;  % fixed foreperiod before the hazard-uniform jitter
preCueExpMeanSec    = 3.000;  % mean of the exponential jitter added to the foreperiod
preCueExpMaxSec     = 5.000;  % truncation cap on the exponential jitter (keeps trials bounded)
% v6: the single post-cue window gameNFv4.m had is now split in two, because
% no response is accepted until the neurofeedback has revealed the colours
% (see NEUROFEEDBACK PARAMETERS below). Leaving it as one window would have
% meant a participant who only earned the reveal late in the trial got
% whatever was left of it to actually answer in - i.e. a response deadline
% that silently varied with their own NF performance.
%   nfRevealTimeoutSec - from cue onset, how long they get to earn the
%       reveal. Expires -> trial ends, RevealTimeout = 1, no response.
%   responseTimeoutSec - from COLOUR onset, how long they then get to
%       answer. Expires -> trial ends, ResponseTimeout = 1.
% Worst case a trial therefore runs preCue + both windows + feedback.
nfRevealTimeoutSec  = 10.000; % time from cue onset to earn the colour reveal
responseTimeoutSec  = 4.000;  % response window, timed from colour onset. Back to
% gamev1.m's 4s: gameNFv4.m's 10s was long because the same window had to
% cover the NF work as well, which nfRevealTimeoutSec now covers separately.
feedbackDurationSec = 1.000;  % 'Correct'/'Incorrect' feedback display time
itiDurationSec      = 1.000;  % blank inter-trial interval

% Leaf geometry (pixels - convert to/from degrees of visual angle yourself
% for your rig, e.g. using px/deg = screen_px_per_unit_distance * tan(1 deg)).
% Everything about the leaf's size is a multiple of one base parameter,
% leafSizePx - change that single number to scale the whole leaf up or
% down, or tweak one multiplier below if only that dimension needs to move.
% leafSizePx is now constrained by the fixed-path motion, because the field
% requirement below scales with it. Measured limits, all 24 direction
% combinations placing successfully (see FIXED-PATH LEAF MOTION below):
%
%   display     minRepeatsPerAxis = 2          minRepeatsPerAxis = 1
%   2560x1440   60:60/flock  90:50  120:24     120:56  150:30  180:16
%               150:18       180: IMPOSSIBLE
%   1920x1080   60:60        90:24              90:56   120:20  150:14
%               120+: IMPOSSIBLE                180: only 6/flock
%
% So leafSizePx = 180 does NOT run on a 1440-tall display at
% minRepeatsPerAxis = 2, and the script will say so before the block starts
% rather than failing mid-experiment. Pick the size against the display the
% experiment will actually run on, not just the development one - and note
% that a 1920x1080 experiment room caps this far lower than a 2560x1440
% laptop screen does.
leafSizePx = 140; % base leaf size (= leaf length in px)
leafWidthMultiplier           = 0.42; % leafWidthPx           = leafSizePx * leafWidthMultiplier
leafBorderThicknessMultiplier = 0.20; % leafBorderThicknessPx = leafSizePx * leafBorderThicknessMultiplier

leafLengthPx          = leafSizePx;
leafWidthPx           = leafSizePx * leafWidthMultiplier;
leafBorderThicknessPx = leafSizePx * leafBorderThicknessMultiplier; % extra thickness added per side for the SSVEP border
leafOuterLengthPx     = leafLengthPx + 2 * leafBorderThicknessPx;   % the SSVEP border polygon is the larger of the two drawn per leaf
leafOuterWidthPx      = leafWidthPx + 2 * leafBorderThicknessPx;
leafMaxRadiusPx       = 0.5 * hypot(leafOuterLengthPx, leafOuterWidthPx); % how far a drawn leaf reaches from its centre
leafSpeedPxPerSec     = 200;
numLeavesPerFlock     = 10;

% ===================== v7: FIXED-PATH LEAF MOTION ==========================
% gameNFv6.m and every variant before it moved the leaves like an RDK:
% initLeaves.m/updateLeaves.m respawned a leaf somewhere else whenever its
% lifetime expired, it left the field, or it drifted within
% minLeafSeparationPx of a leaf of the other flock. Leaves therefore
% appeared and disappeared constantly, and the on-screen count wobbled.
%
% v7 instead puts every leaf on a permanent wrapping path, chosen at trial
% setup so that no two leaves ever overlap for the whole trial (see
% initLeafLanes.m for the construction). Nothing is respawned, nothing
% expires, each leaf simply crosses the field and re-enters from the far
% side, and the count on screen is exactly 2*numLeavesPerFlock at all times.
% leafLifetimeSec, minLeafSeparationMultiplier and fieldMarginPx are gone -
% none of them means anything now.
%
% The one real constraint: when the two flocks move on perpendicular axes,
% the scheme needs gcd(fieldWidth, fieldHeight) to comfortably exceed a
% leaf, and a raw screen's gcd is a lottery. chooseWrapFieldRect.m therefore
% picks the largest centred sub-rectangle of the display that qualifies, so
% the leaf field is usually a little smaller than the screen. That
% requirement grows with leaf size, so a large leafSizePx can make the whole
% scheme impossible on a given display - which is checked once, before the
% block starts, rather than being discovered mid-experiment (see the
% validation just after the screen is opened).
laneClearanceMarginPx  = 6;    % slack added to every extent-derived spacing
maxFieldShrinkPx       = 400;  % how much of each axis chooseWrapFieldRect may give up
minRepeatsPerAxis      = 2;    % path repeats per axis; 2+ keeps the leaves evenly spread
verifyLeafPathsAtSetup = true; % simulate a full motion period per direction combo before the block

% Cue rectangle (same object throughout the trial: neutral pre-cue, solid
% colorC1/colorC2 with 'Pointing'/'Moving' written inside from cue onset on,
% switching to the 'Correct'/'Incorrect' feedback text - in the same box -
% once a response is given)
cueRectWidthPx       = 220;
cueRectHeightPx      = 90;
cueRectCornerRadiusPx = 20;
cueTextSize          = 32;
colorCueText         = black;
% v6: gameNFv4.m's pre-cue box was black on a grey background; on v6's black
% background that box would be invisible, so it gets its own dim grey. Kept
% dim deliberately - it sits at fixation for the whole pre-cue period, and a
% bright box there is a large luminance step into cue onset in an SSVEP
% recording.
colorCueRectPreCue   = [64 64 64];

% Instructions screen (shown once, before the block starts)
instructionsTextSize = 25;

% Colors
% v6: the whole display sits on pure black now, not grey, and the SSVEP
% border flickers the full black-to-white range rather than black to
% mid-grey. Combined with a leaf fill that starts at pure black (= the
% background), a leaf at the start of a trial reads as nothing but its own
% flickering outline.
backgroundColor = black;
colorC1        = [0 191 255];              % c1 flock/cue color (deep sky blue)
colorC2        = [255 140 0];              % c2 flock/cue color (dark orange)
colorBorderLow  = black;  % SSVEP flicker low-luminance border color
colorBorderHigh = white;  % SSVEP flicker high-luminance border color

% SSVEP tagging frequencies (Hz)
freqC1Hz = 19;
freqC2Hz = 23;

% =================== NEUROFEEDBACK (SSVEP lateralisation) ===================
% The NF stimulus is the leaf fill color itself. Before cue onset, and at
% zero level after cue onset, that fill is exactly `backgroundColor` (pure
% black) - the same solid color the background is filled with - so the leaf
% body is indistinguishable from the background and only the flickering
% SSVEP border ring (a separate, larger polygon drawn underneath and never
% touched by any of this) stays visible. From cue onset the fill is a
% grayscale level the NF drives up and down; see the v6 block further down
% for the mechanism, and note that the flocks' true colors (colorC1 /
% colorC2) are NOT what the NF interpolates towards any more - they appear
% all at once, as a reward, and are then fixed for the rest of the trial.
%
% All of it is driven purely off nf.txt (written externally by
% RT_acquisition_8). nf.txt is re-read fresh every displayed frame (not held between reads),
% since it's only the file's own external rewrite that happens on a ~100ms
% cadence - reading on our own fixed 100ms clock could be out of phase with
% that and add up to ~100ms of pure latency for no reason.
%
% nf.txt is a 3-element double vector [SMI_19gt23, SMI_23gt19,
% sampleCount] - the 19Hz-vs-23Hz SSVEP power separation this task's NF
% reflects, now computed from all electrodes for both frequencies (see
% RT_acquisition_8.m). Previously 5 elements with an AMI/alpha
% lateralisation pair at indices 1/2 - that alpha-based feedback was never
% read here and has since been dropped on the acquisition side, so the SMI
% pair shifted down to indices 1/2 and sampleCount to index 3.
% Which of the two SMI columns is "correct" for a trial depends on that
% trial's cue and is fixed once at trial setup (before the trial's frame
% loop starts), since the cue itself never changes mid-trial.
nfFilePath          = fullfile(experimentRoot, 'nf.txt');
nfTraceLogIntervalSec = 0.100;  % NF trace CSV is still logged only this often (not every frame) to keep the file a sane size
nfIndexC1           = 1;      % nf.txt column: positive when 19Hz (c1) SSVEP power exceeds 23Hz
nfIndexC2           = 2;      % nf.txt column: positive when 23Hz (c2) SSVEP power exceeds 19Hz

% ---------------------------- v6: the integrator ---------------------------
% gameNFv4.m mapped a windowed sustained-success statistic onto a CIELAB
% interpolation between grey and each flock's own color. v6 replaces that
% whole path (nfWindowSec / nfValueThreshold / nfProportionThreshold,
% computeNfLeafColor, srgb2lab and the Delta E calibration are all gone)
% with a single accumulated grayscale level, nfLevel, in [0, 1]:
%
%     nfLevel <- clip(nfLevel + nfLevelStepPerUnitNfPerFrame * nfValue, 0, 1)
%
% applied once per displayed frame, where nfValue is this frame's nf.txt
% reading clipped to +/-nfValueClipLimit. So a positive NF steps the leaves
% whiter and a negative one steps them blacker, by an amount proportional to
% its magnitude; at pure black or pure white the level simply stops moving
% in that direction, but is immediately free to move back the other way.
%
% Both flocks share one level and therefore render identically. That is
% forced by the signal: nf.txt gives one signed number per frame (the
% lateralisation towards *this trial's cued* frequency, see nfIndexC1/C2
% below), not a per-flock quantity. Note the consequence - until the reveal
% the two flocks are visually indistinguishable, so the participant cannot
% pick which one to attend by looking; they can only tell they are attending
% the right one because the level climbs. That was already true of
% gameNFv4.m as configured (its nfBaselineDeltaE was 0, so its leaves also
% started identical), but v6 makes it structural.
%
% Smoothing comes for free here, which is why v6 can drop v4's window: the
% integrator IS a low-pass filter. A single unlucky ~100ms sample moves the
% level by at most nfLevelRatePerUnitNf * 0.1 and is undone by the next good
% one, instead of jumping the color the way the instantaneous mapping in
% gameNFv3.m did. The cost is that the level is a running total, so it has
% memory: it can sit high for a moment on borrowed credit from earlier in
% the trial. Raise nfLevelRatePerUnitNf for a more responsive, twitchier
% display; lower it for a smoother, more sluggish one.
%
% The rate is specified per SECOND and converted to a per-frame step below,
% once the real refresh rate is known - the same convention every other
% timing constant in this script follows. Specifying the step per flip
% directly would silently make the NF dynamics faster or slower on a rig
% with a different refresh rate.
%
% The level integrates from CUE ONSET only, not from trial start: before the
% cue there is nothing to attend to, so any pre-cue accumulation would be
% noise pre-charging the display. It is reset to 0 at the start of every
% trial, so the black->white distance is the same on every trial.
nfLevelRatePerUnitNf = 0.500;  % level units per second at |NF| = 1, i.e. 1.0 -> pure black to pure white in 1s of sustained NF = 1
nfValueClipLimit     = 1.000;  % NF magnitude is clipped here before stepping (nf.txt's SMI values are ~[-1, 1])

% ------------------------- v6: green zone and reveal ------------------------
% The top nfWhiteTopRelaxation of the level is the "green zone". While
% nfLevel is in it the leaves render as one fixed green-tinted white
% (colorNfGreenZone) instead of the plain grayscale - fixed, i.e. it does
% not keep tracking nfLevel within the zone, so entering it reads as a
% discrete state change rather than as more of the same ramp. The level
% itself keeps integrating underneath, so it can and does fall back out.
%
% Holding the green zone continuously for nfGreenHoldSec reveals the flocks'
% true colors (colorC1 / colorC2, at full saturation), which is what the
% participant needs to answer the trial. The hold is continuous, not
% cumulative: dropping out of the zone resets it to zero and the hold has to
% be earned again from scratch. Once the reveal happens it is LATCHED for
% the rest of the trial - the colors never fade back out, whatever the NF
% does afterwards - both because the participant needs a stable stimulus to
% answer against, and because the response window opens at that moment (see
% nfRevealTimeoutSec / responseTimeoutSec above).
nfWhiteTopRelaxation = 0.05;   % green zone = the top 5% of the level, i.e. nfLevel >= 0.95
nfGreenHoldSec       = 1.500;  % continuous time in the green zone required to reveal the colors
nfGreenTintStrength  = 0.30;   % how green the green-zone white is: fraction the R and B channels are pulled down by
colorNfGreenZone     = round([255 * (1 - nfGreenTintStrength), 255, 255 * (1 - nfGreenTintStrength)]);

%% Initialise the screen
screens = Screen('Screens');
if testing && ispc
    if ~ismember(testingStimulusScreenNumber, screens)
        error('Configured testing screen %d is unavailable. PTB screens: %s', ...
            testingStimulusScreenNumber, mat2str(screens));
    end
    screenNumber = testingStimulusScreenNumber;
else
    screenNumber = max(screens);
end

if ~testing && eyeTracking
    EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
end

[window, windowRect] = Screen('OpenWindow', screenNumber, backgroundColor);
Screen('ColorRange', window, 255);
Screen('TextSize', window, 40);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

[xCenter, yCenter] = RectCenter(windowRect);
cueRect = [xCenter - cueRectWidthPx / 2, yCenter - cueRectHeightPx / 2, ...
           xCenter + cueRectWidthPx / 2, yCenter + cueRectHeightPx / 2];

Screen('FillRect', window, backgroundColor);
drawRoundedRect(window, colorCueRectPreCue, cueRect, cueRectCornerRadiusPx);
Screen('Flip', window);
WaitSecs(1);

% v2: vbl is captured in both run modes because the
% SSVEP phase below is now driven from this real measured flip timestamp
% rather than a frame counter - see computeSsvepColorsFromTime.m.
vbl = Screen('Flip', window);

interFrameInterval = Screen('GetFlipInterval', window);
refreshRate = 1 / interFrameInterval;
topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

% Frame-based timing
nfRevealTimeoutFrames = max(1, round(nfRevealTimeoutSec / interFrameInterval));
responseTimeoutFrames = max(1, round(responseTimeoutSec / interFrameInterval));
feedbackFrames = max(1, round(feedbackDurationSec / interFrameInterval));
itiFrames = max(1, round(itiDurationSec / interFrameInterval));
nfTraceLogIntervalFrames = max(1, round(nfTraceLogIntervalSec / interFrameInterval));
nfGreenHoldFrames = max(1, round(nfGreenHoldSec / interFrameInterval));

% v6 integrator constants, derived once the real refresh rate is known (see
% the NEUROFEEDBACK PARAMETERS block for why the rate is specified per
% second rather than per flip).
nfLevelStepPerUnitNfPerFrame = nfLevelRatePerUnitNf * interFrameInterval;
nfGreenThreshold = 1 - nfWhiteTopRelaxation;

% Per-frame speed, and the leaf field rect (needs interFrameInterval/windowRect, known only now)
leafSpeedPxPerFrame = leafSpeedPxPerSec * interFrameInterval;

% v7: choose the leaf field, then prove the whole block can actually run on
% it BEFORE the first trial. Every direction combination is placed (and
% optionally simulated over a full motion period) up front, so an
% unworkable leaf size or count fails here - at the console, with a
% diagnosis - instead of halfway through a participant's block. The per-trial
% lane jitter cannot affect this: it only rotates a lane's leaves within the
% arc they are already confined to, so it changes neither the within-lane
% spacing nor the cross-flock separation the guarantee rests on.
requiredFieldGcdPx = ceil(2 * (leafOuterLengthPx + leafOuterWidthPx + 2 * laneClearanceMarginPx)) + 1;
[fieldRect, fieldInfo] = chooseWrapFieldRect(windowRect, requiredFieldGcdPx, ...
    maxFieldShrinkPx, minRepeatsPerAxis);
if ~fieldInfo.feasible
    sca;
    error('gameNFv7:noWorkableField', ...
        ['Fixed-path motion needs a leaf field whose width and height share a factor of %d px ' ...
         '(which grows with leafSizePx = %g). %s\n' ...
         'Reduce leafSizePx, or set minRepeatsPerAxis = 1 to accept a coarser field.'], ...
        requiredFieldGcdPx, leafSizePx, fieldInfo.message);
end
fprintf('Leaf field: %s\n', fieldInfo.message);

worstPathClearancePx = Inf;
for comboCheckIdx = 1:size(directionCombos, 1)
    [checkLeaves, checkInfo] = initLeafLanes(numLeavesPerFlock, fieldRect, ...
        leafOuterLengthPx, leafOuterWidthPx, ...
        directionCombos{comboCheckIdx, 1}, directionCombos{comboCheckIdx, 2}, ...
        directionCombos{comboCheckIdx, 3}, directionCombos{comboCheckIdx, 4}, ...
        leafSpeedPxPerSec * interFrameInterval, laneClearanceMarginPx);
    if ~checkInfo.feasible
        sca;
        error('gameNFv7:unplaceableLeaves', ...
            ['Direction combination %d (%s/%s vs %s/%s) cannot be placed on the %dx%d field: %s\n' ...
             'Reduce numLeavesPerFlock (currently %d) or leafSizePx (currently %g).'], ...
            comboCheckIdx, directionCombos{comboCheckIdx, :}, ...
            round(fieldRect(3) - fieldRect(1)), round(fieldRect(4) - fieldRect(2)), ...
            checkInfo.message, numLeavesPerFlock, leafSizePx);
    end
    if verifyLeafPathsAtSetup
        [checkXExtent1, checkYExtent1] = leafExtentsForDirection( ...
            directionCombos{comboCheckIdx, 1}, leafOuterLengthPx, leafOuterWidthPx);
        [checkXExtent2, checkYExtent2] = leafExtentsForDirection( ...
            directionCombos{comboCheckIdx, 3}, leafOuterLengthPx, leafOuterWidthPx);
        checkReport = verifyLeafLanes(checkLeaves, fieldRect, checkXExtent1, checkYExtent1, ...
            checkXExtent2, checkYExtent2, 40000);
        worstPathClearancePx = min([worstPathClearancePx, ...
            checkReport.minCrossFlockClearancePx, checkReport.minWithinFlockClearancePx]);
        if ~checkReport.collisionFree
            sca;
            error('gameNFv7:leafPathsCollide', ...
                ['Direction combination %d (%s/%s vs %s/%s) overlaps by %.1f px during its ' ...
                 'motion period. This is a bug in the path construction, not a setting - ' ...
                 'please report it.'], comboCheckIdx, directionCombos{comboCheckIdx, :}, ...
                -checkReport.minCrossFlockClearancePx);
        end
    end
end
if verifyLeafPathsAtSetup
    fprintf('Leaf paths verified over a full motion period for all %d direction combinations; worst clearance %.1f px.\n', ...
        size(directionCombos, 1), worstPathClearancePx);
end

%% Block Loop
runBlockLoop = true;
trialNumber = 1;
accuracyByTrial = nan(1, trialNumberPerBlock);
rtByTrial = nan(1, trialNumberPerBlock);
eyeTrackingStopped = testing || ~eyeTracking;

try
    %% Instructions screen (once, before the block starts), with static example leaves
    demoLeafPointDir = 'right';
    demoInnerShape = createLeafShape(demoLeafPointDir, leafLengthPx, leafWidthPx);
    demoOuterShape = createLeafShape(demoLeafPointDir, leafOuterLengthPx, leafOuterWidthPx);

    demoOffsetX = (windowRect(3) - windowRect(1)) * 0.22;
    demoY = yCenter + 60;
    demoPosC1 = [xCenter - demoOffsetX, demoY];
    demoPosC2 = [xCenter + demoOffsetX, demoY];

    labelWidthPx = 320;
    labelHeightPx = 90;
    labelC1Rect = [demoPosC1(1) - labelWidthPx / 2, demoPosC1(2) + 70, ...
                   demoPosC1(1) + labelWidthPx / 2, demoPosC1(2) + 70 + labelHeightPx];
    labelC2Rect = [demoPosC2(1) - labelWidthPx / 2, demoPosC2(2) + 70, ...
                   demoPosC2(1) + labelWidthPx / 2, demoPosC2(2) + 70 + labelHeightPx];

    instructionsRect = [windowRect(1) + 80, windowRect(2) + 40, windowRect(3) - 80, yCenter - 40];
    instructionsText = [ ...
        'INSTRUCTIONS\n\n' ...
        'Two groups of leaves move around the screen. Each group points in one\n' ...
        'direction and moves in another direction (up / down / left / right) -\n' ...
        'independently, and both can change from trial to trial.\n\n' ...
        'At first only the flickering leaf outlines are visible. Partway through\n' ...
        'each trial the box at the center turns a color and shows "Pointing" or\n' ...
        '"Moving" - see the two examples below for what each color means.\n\n' ...
        'Concentrating on the group the box asks about makes the leaves brighten,\n' ...
        'from black towards white. Once they are nearly white they turn green:\n' ...
        'hold them green and their true colors appear.\n\n' ...
        'Only then can you answer, with the direction buttons - buttons pressed\n' ...
        'before the colors appear do nothing. The box will then show whether you\n' ...
        'were Correct or Incorrect.'];

    % v6: black background, so the instructions text is white and the demo
    % leaves get a white outline standing in for their flickering SSVEP
    % border (gameNFv4.m drew that outline black against its grey screen).
    Screen('FillRect', window, backgroundColor);
    Screen('TextSize', window, instructionsTextSize);
    DrawFormattedText(window, instructionsText, 'center', 'center', white, [], [], [], [], [], instructionsRect);

    Screen('FillPoly', window, colorBorderHigh, bsxfun(@plus, demoOuterShape, demoPosC1));
    Screen('FillPoly', window, colorC1, bsxfun(@plus, demoInnerShape, demoPosC1));
    Screen('FillPoly', window, colorBorderHigh, bsxfun(@plus, demoOuterShape, demoPosC2));
    Screen('FillPoly', window, colorC2, bsxfun(@plus, demoInnerShape, demoPosC2));

    Screen('TextSize', window, 22);
    DrawFormattedText(window, 'This color ->\nuse its POINTING\ndirection', 'center', 'center', white, [], [], [], [], [], labelC1Rect);
    DrawFormattedText(window, 'This color ->\nuse its MOVING\ndirection', 'center', 'center', white, [], [], [], [], [], labelC2Rect);

    Screen('TextSize', window, 28);
    DrawFormattedText(window, 'Press any key or button to begin', 'center', windowRect(4) - 80, white);

    if ~testing
        vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
        cedrus.waitpress(600);
    else
        vbl = Screen('Flip', window);
        KbWait(-1);
    end

    while runBlockLoop && trialNumber <= trialNumberPerBlock
        if ~testing && eyeTracking
            calllib('iViewXAPI', 'iV_StartRecording');
        end

        %% Trial setup
        c1PointDir = directionTrialList{trialNumber, 1};
        c1MoveDir  = directionTrialList{trialNumber, 2};
        c2PointDir = directionTrialList{trialNumber, 3};
        c2MoveDir  = directionTrialList{trialNumber, 4};
        cue = cueList{trialNumber};

        if strcmp(cue, 'c1')
            correctResponse = c1PointDir;
        else
            correctResponse = c2MoveDir;
        end

        if strcmp(cue, 'c1')
            cueColor = colorC1;
            cueWord = 'Pointing';
            nfIndex = nfIndexC1;
        else
            cueColor = colorC2;
            cueWord = 'Moving';
            nfIndex = nfIndexC2;
        end

        % NF state for this trial (nfIndex above is fixed for the whole
        % trial - predetermined here, before the trial's frame loop starts).
        % nfCurrentValueRaw only ever updates on a successful read (see the
        % frame loop below) - starts at 0 (neutral) same as a real trial
        % start, since RT_acquisition_8 itself zeroes nf.txt at trial start.
        nfCurrentValueRaw = 0;

        % v6: integrator and reveal state for this trial (see NEUROFEEDBACK
        % PARAMETERS above). All re-zeroed per trial so nothing bleeds
        % across trials - in particular nfLevel always starts at pure black,
        % so the distance to the green zone is identical on every trial.
        % (nfValueClipped and inGreenZone are deliberately not seeded here -
        % both are recomputed from scratch on every frame before anything
        % reads them, unlike nfLevel/greenHoldFrames/colorsRevealed, which
        % carry state forward from frame to frame and so must start defined.)
        nfLevel = 0;
        greenHoldFrames = 0;
        colorsRevealed = false;
        % Frame numbers the two NF events happened on, NaN until they do.
        % They're recorded here rather than timestamped inline because the
        % timestamp/trigger has to be taken after the Screen('Flip') that
        % actually PRESENTS the change, the same way cue onset is handled.
        firstGreenFrame = NaN;
        colorOnsetFrame = NaN;
        responseDeadlineFrame = NaN;  % only known once the colours are revealed

        nfTraceFrameNumber = [];
        nfTraceSampleTime = [];
        nfTraceValueRaw = [];
        nfTraceValueClipped = [];
        nfTraceLevel = [];
        nfTraceInGreenZone = [];
        nfTraceGreenHoldSec = [];
        nfTraceColorsRevealed = [];
        nfTracePostCue = [];
        nfTraceReadOk = [];

        % v2: dropped-frame log for this trial (see droppedFrameCsvFile above)
        droppedFrameCount = 0;
        droppedFrameNumber = [];
        droppedFrameVblTime = [];
        droppedFrameMissedBySec = [];

        flock1Velocity = directionToVector(c1MoveDir) * leafSpeedPxPerFrame;
        flock2Velocity = directionToVector(c2MoveDir) * leafSpeedPxPerFrame;

        flock1InnerShape = createLeafShape(c1PointDir, leafLengthPx, leafWidthPx);
        flock1OuterShape = createLeafShape(c1PointDir, leafOuterLengthPx, leafOuterWidthPx);
        flock2InnerShape = createLeafShape(c2PointDir, leafLengthPx, leafWidthPx);
        flock2OuterShape = createLeafShape(c2PointDir, leafOuterLengthPx, leafOuterWidthPx);

        % v7: fixed wrapping paths instead of respawning dots. Re-placed each
        % trial because the paths depend on this trial's move directions, and
        % re-jittered so successive trials are not pixel-identical layouts.
        % Feasibility was already proven for every direction combination
        % before the block started, so this cannot fail here.
        leaves = initLeafLanes(numLeavesPerFlock, fieldRect, leafOuterLengthPx, leafOuterWidthPx, ...
            c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, ...
            leafSpeedPxPerSec * interFrameInterval, laneClearanceMarginPx);

        participantResponse = 'missed';
        reactionTime = NaN;
        accuracy = 0;
        revealTimeout = 0;
        responseTimeout = 0;
        validResponse = false;
        inFeedback = false;
        feedbackFramesRemaining = 0;

        trialStartTime = getElapsedTime(experimentStartTime);
        cueOnsetTime = NaN;
        % v6: NaN unless the NF actually got there this trial (see the main
        % CSV header comment near the top for what each one means).
        firstGreenTime = NaN;
        colorOnsetTime = NaN;
        colorOnsetAbsTime = NaN;  % raw GetSecs companion to colorOnsetTime, see the frame loop

        disp(trialNumber);
        if ~testing
            cog_send_triggers(paraport, 'trialstart');
        end

        %% Single continuous trial loop: pre-cue -> cue onset/response -> feedback.
        % One uninterrupted per-frame loop for the whole trial, rather than a
        % separate loop per phase - each loop boundary previously added its own
        % setup cost (an extra cedrus.resettimer(), per-loop first-frame
        % bookkeeping) right at the visually critical pre-cue/post-cue
        % transition, which showed up as a stutter. Phases are now just a
        % comparison of currentFrame against pre-computed boundary frame
        % numbers, so colors/text swap on the right iteration of one loop.
        % v2: the SSVEP time base is no longer currentFrame itself - it's
        % real elapsed time since trial start, measured from actual
        % Screen('Flip') VBL timestamps (see computeSsvepColorsFromTime.m).
        % trialSsvepT0 is the last real flip timestamp before this trial's
        % loop starts (the previous trial's final ITI flip, or the
        % instructions-screen flip for trial 1); t=0 for this trial is
        % defined relative to that moment.
        % v6: the post-cue budget is now two windows end to end, not one -
        % nfRevealTimeoutFrames to earn the colour reveal and then
        % responseTimeoutFrames from that reveal to answer. maxFrames sizes
        % the loop for the worst case (a reveal earned on the very last
        % frame of the first window); the trial breaks out well before that
        % in every other case. responseDeadlineFrame can't be computed here
        % - it hangs off colorOnsetFrame, which the participant determines -
        % so it's filled in when the reveal actually latches.
        cueDelaySec = preCueConstantSec + truncatedExpRnd(preCueExpMeanSec, preCueExpMaxSec);
        preCueFrames = max(1, round(cueDelaySec / interFrameInterval));
        cueOnsetFrame = preCueFrames + 1;
        revealDeadlineFrame = preCueFrames + nfRevealTimeoutFrames;
        maxFrames = preCueFrames + nfRevealTimeoutFrames + responseTimeoutFrames + feedbackFrames;
        trialSsvepT0 = vbl;

        for currentFrame = 1:maxFrames
            isPreCue = currentFrame < cueOnsetFrame;

            % NF stream starts at trial start (frame 1) and re-reads nf.txt
            % fresh every displayed frame, regardless of trial phase - only
            % its visual effect (below) is gated to post-cue. A failed read
            % (file momentarily missing, or caught mid-write by the
            % external process truncating it before rewriting - see
            % readNFValue.m) is an I/O race, not a real sample, so
            % nfCurrentValueRaw is simply left at whatever it already was
            % and the trial proceeds to the next flip on that stale value,
            % rather than snapping to a spurious 0/neutral reading.
            [newNfValueRaw, nfReadOk] = readNFValue(nfFilePath, nfIndex);
            if nfReadOk
                nfCurrentValueRaw = newNfValueRaw;
            end

            % v6: step the integrator by this frame's NF value, then run the
            % green-zone/reveal state machine off the resulting level (see
            % NEUROFEEDBACK PARAMETERS above). A stale value from a failed
            % read is stepped by as-is - it's the value that was on screen
            % for that frame, so integrating it is what keeps the level a
            % function of elapsed time rather than of successful reads.
            nfValueClipped = max(-nfValueClipLimit, min(nfValueClipLimit, nfCurrentValueRaw));
            if ~isPreCue
                nfLevel = max(0, min(1, nfLevel + nfLevelStepPerUnitNfPerFrame * nfValueClipped));
            end
            inGreenZone = ~isPreCue && nfLevel >= nfGreenThreshold;

            if inGreenZone && isnan(firstGreenFrame)
                firstGreenFrame = currentFrame;
            end
            if ~colorsRevealed
                if inGreenZone
                    % Continuous hold: this counter only ever advances on
                    % consecutive in-zone frames, and any frame out of the
                    % zone below sends it straight back to zero.
                    greenHoldFrames = greenHoldFrames + 1;
                    if greenHoldFrames >= nfGreenHoldFrames
                        colorsRevealed = true;
                        colorOnsetFrame = currentFrame;
                        responseDeadlineFrame = colorOnsetFrame + responseTimeoutFrames;
                    end
                else
                    greenHoldFrames = 0;
                end
            end

            % The trace CSV is still only logged every nfTraceLogIntervalFrames
            % (~100ms), since nf.txt itself is only rewritten externally on
            % roughly that cadence - logging every frame would just repeat
            % the same unchanged value several times over for no benefit.
            % The level moves every frame, but it's a deterministic function
            % of the logged raw stream and the parameters, so it stays
            % reconstructible at full frame resolution offline.
            if mod(currentFrame - 1, nfTraceLogIntervalFrames) == 0
                nfTraceFrameNumber(end+1) = currentFrame; %#ok<SAGROW>
                nfTraceSampleTime(end+1) = getElapsedTime(experimentStartTime); %#ok<SAGROW>
                nfTraceValueRaw(end+1) = nfCurrentValueRaw; %#ok<SAGROW>
                nfTraceValueClipped(end+1) = nfValueClipped; %#ok<SAGROW>
                nfTraceLevel(end+1) = nfLevel; %#ok<SAGROW>
                nfTraceInGreenZone(end+1) = inGreenZone; %#ok<SAGROW>
                nfTraceGreenHoldSec(end+1) = greenHoldFrames * interFrameInterval; %#ok<SAGROW>
                nfTraceColorsRevealed(end+1) = colorsRevealed; %#ok<SAGROW>
                nfTraceReadOk(end+1) = nfReadOk; %#ok<SAGROW>
                nfTracePostCue(end+1) = ~isPreCue; %#ok<SAGROW>
            end

            leaves = updateLeafLanes(leaves, fieldRect);

            % v2: predict the real time this frame will actually be
            % displayed at (last real flip + one nominal refresh) instead
            % of assuming currentFrame*interFrameInterval elapsed. vbl here
            % still holds the ACTUAL measured timestamp of the previous
            % flip, so if that previous flip was delayed by GPU load, the
            % prediction - and thus the phase - shifts to match reality
            % instead of silently falling behind.
            ssvepTPredicted = (vbl - trialSsvepT0) + interFrameInterval;
            [flock1BorderColor, flock2BorderColor] = computeSsvepColorsFromTime( ...
                ssvepTPredicted, freqC1Hz, freqC2Hz, colorBorderLow, colorBorderHigh);

            Screen('FillRect', window, backgroundColor);
            if isPreCue
                % v7: drawLeavesWrapped, not drawLeaves - a leaf straddling
                % an edge has to be painted on both sides, or it would blink
                % out at one edge and reappear at the other, which is the
                % very behaviour the fixed paths exist to remove.
                drawLeavesWrapped(window, leaves, fieldRect, leafMaxRadiusPx, ...
                    flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
                    backgroundColor, backgroundColor, flock1BorderColor, flock2BorderColor);
                drawRoundedRect(window, colorCueRectPreCue, cueRect, cueRectCornerRadiusPx);
            else
                % v6: three mutually exclusive fill states, in priority
                % order - revealed (latched, both flocks at their own true
                % color), in the green zone (one fixed green-white for
                % both), or the plain shared grayscale the integrator is
                % currently at. Only the last of these tracks nfLevel.
                if colorsRevealed
                    flock1FillColor = colorC1;
                    flock2FillColor = colorC2;
                elseif inGreenZone
                    flock1FillColor = colorNfGreenZone;
                    flock2FillColor = colorNfGreenZone;
                else
                    nfGrayValue = round(255 * nfLevel);
                    flock1FillColor = [nfGrayValue, nfGrayValue, nfGrayValue];
                    flock2FillColor = flock1FillColor;
                end
                drawLeavesWrapped(window, leaves, fieldRect, leafMaxRadiusPx, ...
                    flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
                    flock1FillColor, flock2FillColor, flock1BorderColor, flock2BorderColor);
                drawRoundedRect(window, cueColor, cueRect, cueRectCornerRadiusPx);
                Screen('TextSize', window, cueTextSize);
                if inFeedback
                    % Response feedback is shown inside the cue box itself, in
                    % place of the 'Pointing'/'Moving' word, not as separate text.
                    DrawFormattedText(window, feedbackString, 'center', 'center', feedbackColor, [], [], [], [], [], cueRect);
                else
                    DrawFormattedText(window, cueWord, 'center', 'center', colorCueText, [], [], [], [], [], cueRect);
                end
            end

            % v2: missed-frame detection is only meaningful with real vsync
            % timing (experiment mode, where SkipSyncTests is off), so it's only
            % tracked there - see droppedFrameCsvFile above.
            if ~testing
                [vbl, ~, ~, missed] = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                if missed > 0
                    droppedFrameCount = droppedFrameCount + 1;
                    droppedFrameNumber(end+1) = currentFrame; %#ok<SAGROW>
                    droppedFrameVblTime(end+1) = vbl; %#ok<SAGROW>
                    droppedFrameMissedBySec(end+1) = missed; %#ok<SAGROW>
                end
            else
                vbl = Screen('Flip', window);
            end

            if currentFrame == cueOnsetFrame
                cueOnsetTime = getElapsedTime(experimentStartTime);
                if ~testing
                    cog_send_triggers(paraport, 'cueonset');
                    cedrus.resettimer();
                end
            end

            % v6: both NF events are timestamped here, immediately after the
            % flip that first PRESENTED them, exactly like cue onset above -
            % not where the state machine set them, which is one flip early.
            if currentFrame == firstGreenFrame
                firstGreenTime = getElapsedTime(experimentStartTime);
            end
            if currentFrame == colorOnsetFrame
                % Two timestamps for the one event, deliberately: the CSV
                % wants time-since-experiment-start (as every other logged
                % time is), but getDirectionResponse's testing branch does
                % GetSecs - responseOnsetTime and so needs the raw absolute
                % GetSecs value. Passing the relative one there - which is
                % what gameNFv4.m/gameNFv5.m do with cueOnsetTime - makes
                % their testing-mode ReactionTime come out as roughly
                % "seconds since boot" instead of a reaction time. Taken
                % from one GetSecs call so the two can't disagree.
                colorOnsetAbsTime = GetSecs;
                colorOnsetTime = colorOnsetAbsTime - experimentStartTime;
                if ~testing
                    % Colour onset is the event everything downstream locks
                    % to (see analysis/gameNFSSVEPColorOnsetLocked.m), so it
                    % gets its own trigger. 'success' (50) is reused rather
                    % than adding a code, since this task never sends it
                    % otherwise and it is exactly what the event means here.
                    cog_send_triggers(paraport, 'success');
                    % Doubles as the response timer origin AND a queue
                    % flush: resettimer discards any button events already
                    % on the Cedrus stack, so presses made during the NF
                    % phase - which are not valid responses - can't be
                    % dequeued as an instant "response" on the next frame.
                    cedrus.resettimer();
                end
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end

            if inFeedback
                feedbackFramesRemaining = feedbackFramesRemaining - 1;
                if feedbackFramesRemaining <= 0
                    break;
                end
            elseif colorsRevealed
                % v6: responses are only read once the colours are out -
                % before that the participant has nothing to answer from, so
                % anything pressed is a guess and is deliberately ignored.
                % reactionTime is therefore measured from colour onset, not
                % cue onset (the Cedrus timer was reset there too).
                if ~testing
                    [validResponse, participantResponse, reactionTime] = getDirectionResponse( ...
                        false, cedrus, leftKey, rightKey, upKey, downKey, colorOnsetAbsTime);
                else
                    [validResponse, participantResponse, reactionTime] = getDirectionResponse( ...
                        true, [], leftKey, rightKey, upKey, downKey, colorOnsetAbsTime);
                end

                if validResponse
                    accuracy = strcmp(participantResponse, correctResponse);
                    if ~testing
                        cog_send_triggers(paraport, 'response');
                    end
                    if accuracy
                        feedbackString = 'Correct';
                        feedbackColor = green;
                    else
                        feedbackString = 'Incorrect';
                        feedbackColor = red;
                    end
                    inFeedback = true;
                    feedbackFramesRemaining = feedbackFrames;
                elseif currentFrame >= responseDeadlineFrame
                    responseTimeout = 1;
                    break;
                end
            elseif ~isPreCue && currentFrame >= revealDeadlineFrame
                % Ran out of time to earn the reveal: the trial ends with no
                % response at all, which is a different failure from a
                % response window that opened and then expired.
                revealTimeout = 1;
                break;
            end
        end
        if ~runBlockLoop
            if ~testing
                cog_send_triggers(paraport, 'trialstop');
            end
            break;
        end

        if ~testing
            cog_send_triggers(paraport, 'trialstop');
        end

        %% Log trial
        trialEndTime = getElapsedTime(experimentStartTime);
        accuracyByTrial(trialNumber) = accuracy;
        rtByTrial(trialNumber) = reactionTime;

        fid = fopen(csvFile, 'a');
        fprintf(fid, '%d,%.6f,%s,%s,%s,%s,%s,%.6f,%.6f,%.6f,%s,%s,%d,%.6f,%d,%d,%.6f,%d\n', ...
            trialNumber, trialStartTime, c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, cue, cueOnsetTime, ...
            firstGreenTime, colorOnsetTime, correctResponse, participantResponse, accuracy, reactionTime, ...
            revealTimeout, responseTimeout, trialEndTime, droppedFrameCount);
        fclose(fid);

        %% Log NF trace for this trial (one row per ~100ms, per nfTraceLogIntervalSec)
        fid = fopen(nfTraceCsvFile, 'a');
        for r = 1:numel(nfTraceFrameNumber)
            fprintf(fid, '%d,%d,%.6f,%d,%.6f,%.6f,%.6f,%d,%.6f,%d,%d,%d\n', ...
                trialNumber, nfTraceFrameNumber(r), nfTraceSampleTime(r), nfIndex, ...
                nfTraceValueRaw(r), nfTraceValueClipped(r), nfTraceLevel(r), ...
                nfTraceInGreenZone(r), nfTraceGreenHoldSec(r), nfTraceColorsRevealed(r), ...
                nfTracePostCue(r), nfTraceReadOk(r));
        end
        fclose(fid);

        %% Log dropped frames for this trial (v2 only; usually empty)
        fid = fopen(droppedFrameCsvFile, 'a');
        for r = 1:numel(droppedFrameNumber)
            fprintf(fid, '%d,%d,%.6f,%.6f\n', ...
                trialNumber, droppedFrameNumber(r), droppedFrameVblTime(r), droppedFrameMissedBySec(r));
        end
        fclose(fid);

        %% ITI
        for currentFrame = 1:itiFrames
            Screen('FillRect', window, backgroundColor);
            drawRoundedRect(window, colorCueRectPreCue, cueRect, cueRectCornerRadiusPx);
            if ~testing
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                vbl = Screen('Flip', window);
            end
        end

        if ~testing && eyeTracking
            calllib('iViewXAPI', 'iV_StopRecording');
        end

        trialNumber = trialNumber + 1;
    end

    if ~testing && eyeTracking
        EyeTracking(str2double(participantInfo),str2double(blockInfo),'stop');
        eyeTrackingStopped = true;
    end

catch ME
    if ~testing
        cog_send_triggers(paraport, 'trialstop');
    end
    cleanupExperiment(testing, eyeTrackingStopped, participantInfo, blockInfo, paraport);
    rethrow(ME);
end

%% Calculate and display block results
validAccuracy = accuracyByTrial(~isnan(accuracyByTrial));
if isempty(validAccuracy)
    meanAccuracy = NaN;
else
    meanAccuracy = mean(validAccuracy);
end

Screen('FillRect', window, backgroundColor);
Screen('TextSize', window, 35);
performanceText = sprintf(['TESTING COMPLETED!\n\n' ...
    'ACCURACY: %.2f%%\n\n' ...
    'Press ESCAPE or any button to continue'], 100 * meanAccuracy);
DrawFormattedText(window, performanceText, 'center', 'center', white);
if ~testing
    vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
else
    Screen('Flip', window);
end

fprintf('%s\n', performanceText);
WaitSecs(1);

waitForEscape = true;
while waitForEscape
    [keyIsDown, ~, keyCode] = KbCheck(-1);
    if ~testing
        [~, ~, ohhItIsPressed] = cedrus.getpress();
    else
        ohhItIsPressed = 0;
    end

    if (keyIsDown && keyCode(escapeKey)) || ohhItIsPressed
        waitForEscape = false;
    end
    WaitSecs(0.01);
end

cleanupExperiment(testing, eyeTrackingStopped, participantInfo, blockInfo, paraport);

%% Trigger values sent by this task
% Values are defined in functions/cog_send_triggers.m.
% reset      -> 0
% trialstart -> 20
% cueonset   -> 45
% success    -> 50   (v6 only: colour onset - the NF reveal, and the moment
%                     the response window opens. Sent at most once per
%                     trial, and not at all on a trial that never revealed.)
% response   -> 40
% trialstop  -> 30
