%% Initialise
if ~ismac
    if exist('cedrus','var')
        cedrus.close();
    end

    s=instrfind; %#ok<INSTRF>
    if ~isempty(s)
        fclose(s);
    end
end

clc;        % Clears the Command Window
clear;      % Removes all variables from the workspace
close all;  % Closes all figure windows
sca;        % Clears the screen

experimentRoot = fileparts(mfilename('fullpath'));
if isempty(experimentRoot)
    experimentRoot = pwd;
end
addpath(genpath(experimentRoot));

if ~ismac
    % Begining
    cedrusopen;
end

%% Participant and block info
if ~ismac
    participantInfo = input('Enter your participant number: ', 's');
    blockInfo = input('Enter your block number: ', 's');
else
    participantInfo = '000'; % Test
    blockInfo = '000'; % Test
end

% Initialize timer
experimentStartTime = GetSecs;

if ~ismac
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
% v5: the cue is a (feature, direction) pair and the response is a COLOR, so
% CueFeature/CueDirection are new and CorrectResponse/ParticipantResponse now
% hold 'blue'/'orange' instead of a direction. Cue is kept, still valued
% 'c1'/'c2' (the flock the cue points at), because that is what selects the
% attended SSVEP frequency and what the offline analysis scripts group by.
% ColorRevealTime is the timestamp of the first post-cue frame that actually
% showed any leaf color - with nfBaselineDeltaE = 0 the response is gated on
% neurofeedback success, so reaction time is uninterpretable without it.
csvHeader = ['TrialNumber,TrialStart,C1PointDir,C1MoveDir,C2PointDir,C2MoveDir,Cue,CueFeature,CueDirection,CueOnsetTime,' ...
    'CorrectResponse,ParticipantResponse,Accuracy,ReactionTime,ResponseTimeout,TrialEnd,DroppedFrameCount,ColorRevealTime'];
csvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_leaves_trialdata.csv', sessionTag), csvHeader);

% Per-~100ms NF trace (one row per nfTraceLogIntervalSec), separate file so
% the one-row-per-trial main CSV above stays unchanged in shape.
% v4: NFWindowProportion/NFDrive record the rolling-window statistic that
% actually drives the leaf color now (see NEUROFEEDBACK PARAMETERS below);
% NFValueRaw/NFValueClipped are kept so the underlying raw stream the
% window was computed from stays auditable offline. There's no window-fill
% column because the window is pre-filled with zeros at trial start and so
% is always exactly nfWindowFrames long.
nfTraceCsvHeader = ['TrialNumber,FrameNumber,SampleTime,NFIndexUsed,' ...
    'NFValueRaw,NFValueClipped,NFWindowProportion,NFDrive,PostCueOnset,NFReadOk'];
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
if ismac
    Screen('Preference', 'SkipSyncTests', 1);
end

% Unify key names across different operating systems
KbName('UnifyKeyNames');

% Paraport setup for triggers
if ~ismac
    paraport = serial('COM9','BaudRate',115200,'DataBits',8, 'StopBits', 1, 'Parity', 'none'); %#ok<SERIAL>
    get(paraport);
    fopen(paraport);
    cog_send_triggers(paraport,'reset');
end
if ~exist('paraport','var')
    paraport = [];
end

%% Display colors
grey  = [128 128 128];
black = [0 0 0];
white = [255 255 255];
green = [0 255 0];
red   = [255 0 0];

%% PARAMETERS
% Key mappings (used only when running on mac, where no Cedrus box is present)
% v5: the response is 2-alternative (color), so only left/right are read -
% the up/down arrow keys gamev1-gameNFv4 needed for their 4-direction
% response are gone.
escapeKey = KbName('ESCAPE');
leftKey   = KbName('LeftArrow');
rightKey  = KbName('RightArrow');

% Experiment structure
trialNumberPerBlock = 24; % ideally a multiple of 24 (see directionTrialList
% below) so both the cue and every direction combo land exactly uniform;
% other values (e.g. for a quick test run) still balance as evenly as
% integer counts allow, just not perfectly.
directionSet = {'up', 'down', 'left', 'right'};

% v5: the cue is no longer a color naming a flock - it is a (feature,
% direction) pair, e.g. "MOVING UP", and the participant reports the COLOR
% of the flock it identifies (left button = orange = c2, right = blue = c1).
% Because the direction scheme below makes (c1PointDir, c1MoveDir,
% c2PointDir, c2MoveDir) a permutation of all four directions, exactly four
% cues are possible on any given trial - moving c1MoveDir, moving c2MoveDir,
% pointing c1PointDir, pointing c2PointDir - and each identifies exactly one
% flock. Note that this also means the cued direction alone is already
% unique: the feature word tells the participant which dimension to search
% rather than disambiguating two candidate flocks.
%
% The four cue types are consumed as shuffled 4-trial cycles (same idea as
% directionTrialList's 24-trial cycles below), so all four types - and hence
% both features and both cued flocks/correct colors - occur equally often at
% every 4-trial boundary, not merely across the whole block.
cueTypeFeatures = {'moving', 'moving', 'pointing', 'pointing'};
cueTypeFlocks   = {'c1',     'c2',     'c1',       'c2'};
numCueTypes = numel(cueTypeFeatures);
cueFeatureList = cell(1, trialNumberPerBlock);
cueFlockList   = cell(1, trialNumberPerBlock);
numFullCueCycles = floor(trialNumberPerBlock / numCueTypes);
numLeftoverCueTrials = trialNumberPerBlock - numFullCueCycles * numCueTypes;
cueCursor = 1;
for cueCycle = 1:numFullCueCycles
    cycleOrder = randperm(numCueTypes);
    cueFeatureList(cueCursor:cueCursor + numCueTypes - 1) = cueTypeFeatures(cycleOrder);
    cueFlockList(cueCursor:cueCursor + numCueTypes - 1)   = cueTypeFlocks(cycleOrder);
    cueCursor = cueCursor + numCueTypes;
end
if numLeftoverCueTrials > 0
    leftoverCueIdx = randperm(numCueTypes, numLeftoverCueTrials);
    cueFeatureList(cueCursor:end) = cueTypeFeatures(leftoverCueIdx);
    cueFlockList(cueCursor:end)   = cueTypeFlocks(leftoverCueIdx);
end

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
responseTimeoutSec  = 10.000;  % response window, timed from cue onset - longer than gamev1.m's
% 4s to give the participant time to work with the NF-driven leaf coloring
% (see NEUROFEEDBACK PARAMETERS below) before the window closes.
feedbackDurationSec = 1.000;  % 'Correct'/'Incorrect' feedback display time
itiDurationSec      = 1.000;  % blank inter-trial interval

% Leaf geometry (pixels - convert to/from degrees of visual angle yourself
% for your rig, e.g. using px/deg = screen_px_per_unit_distance * tan(1 deg)).
% Everything about the leaf's size is a multiple of one base parameter,
% leafSizePx - change that single number to scale the whole leaf up or
% down, or tweak one multiplier below if only that dimension needs to move.
fieldMarginPx = 0; % inset from the screen edge - 0 uses the full screen, leaves may clip at the edge

leafSizePx = 90; % base leaf size (= leaf length in px)
leafWidthMultiplier           = 0.42; % leafWidthPx           = leafSizePx * leafWidthMultiplier
leafBorderThicknessMultiplier = 0.20; % leafBorderThicknessPx = leafSizePx * leafBorderThicknessMultiplier
minLeafSeparationMultiplier   = 1.10; % minLeafSeparationPx   = leafSizePx * minLeafSeparationMultiplier

leafLengthPx          = leafSizePx;
leafWidthPx           = leafSizePx * leafWidthMultiplier;
leafBorderThicknessPx = leafSizePx * leafBorderThicknessMultiplier; % extra thickness added per side for the SSVEP border
minLeafSeparationPx   = leafSizePx * minLeafSeparationMultiplier;   % minimum center-to-center distance enforced between any two leaves
leafSpeedPxPerSec     = 200;
leafLifetimeSec       = 1.0; % how long a single leaf stays on screen before it respawns elsewhere
numLeavesPerFlock     = 20;  % density = numLeavesPerFlock / (screen area in px^2).
% Each leaf needs a minLeafSeparationPx clearance bubble around it, so the
% field can only physically fit so many before the placement algorithm
% can no longer find room and starts force-respawning leaves almost every
% frame (looks like leaves rapidly teleporting/flickering, regardless of
% leafSpeedPxPerSec - that's a packing problem, not a speed one). At this
% leaf size, a 1920x1080-ish field stays stable up to ~25/flock and
% starts thrashing past ~30/flock - raise gradually and watch for that
% symptom coming back.

% Cue rectangle (same object throughout the trial: black pre-cue, then dark
% green from cue onset on with the two-line cue - feature above direction,
% e.g. 'MOVING' / 'UP' - written inside it in white, switching to the
% 'Correct'/'Incorrect' feedback text in the same box once a response is
% given).
% v5: the box is deliberately NOT filled with the cued flock's color any
% more - the flock's color is the answer now, so coloring the box would give
% it away. It is a fixed dark green for every trial instead - neutral with
% respect to both flock colors, and a much smaller luminance step from the
% black pre-cue box than a white box would be, which matters for a
% fixation-centred stimulus in an SSVEP recording. The box is also bigger
% than gameNFv4.m's, to fit two lines of text.
cueRectWidthPx       = 280;
cueRectHeightPx      = 120;
cueRectCornerRadiusPx = 20;
cueTextSize          = 32;
colorCueText         = white;
colorCueRectPreCue   = black;
colorCueRectPostCue  = [0 100 0];

% v5 response mapping - fixed for the whole experiment, and spelled out on
% the instructions screen. Cedrus Left (button 3) / left arrow = orange =
% flock c2; Cedrus Right (button 5) / right arrow = blue = flock c1.
responseLabelC1 = 'blue';    % colorC1 (deep sky blue), reported with the RIGHT button
responseLabelC2 = 'orange';  % colorC2 (dark orange), reported with the LEFT button

% Feedback text colors. Lighter than the plain green/red above because the
% feedback is drawn inside the dark green cue box - plain green would be
% near-invisible on it and plain red is low-contrast against it.
colorFeedbackCorrect   = [170 255 170];
colorFeedbackIncorrect = [255 150 150];

% Instructions screen (shown once, before the block starts)
instructionsTextSize = 25;

% Colors
colorC1        = [0 191 255];              % c1 flock/cue color (deep sky blue)
colorC2        = [255 140 0];              % c2 flock/cue color (dark orange)
% SSVEPContrastGap = 150;
% shiftValue = round((255 - 100)/2);
colorBorderLow  = black;  % SSVEP flicker low-luminance border color
colorBorderHigh = round(white/2);  % SSVEP flicker high-luminance border color

% SSVEP tagging frequencies (Hz)
freqC1Hz = 19;
freqC2Hz = 23;

% =================== NEUROFEEDBACK (SSVEP lateralisation) ===================
% The NF stimulus is the leaf fill color itself. Before cue onset, and at
% zero/wrong-direction lateralisation after cue onset, each flock's fill is
% exactly `grey` - the same solid color the background is filled with - so
% the leaf body is indistinguishable from the background (only the
% flickering SSVEP border ring, a separate, larger polygon drawn underneath
% and never touched by any of this, stays visible). From cue onset, fill
% moves from grey toward the flock's own cue color (colorC1/colorC2) in
% proportion to real-time SSVEP power lateralisation favoring this trial's
% cued frequency - i.e. the leaves become more distinctly colored the more
% the participant's SSVEP is lateralised the right way.
%
% v5: that fill color is now also the thing the participant reports, so the
% neurofeedback and the task objective are deliberately the same quantity -
% with nfBaselineDeltaE = 0 (below) there is NO fixed cue-onset reveal, and
% since the two flocks are otherwise identical apart from their directions
% and their 19/23Hz border flicker, the trial simply cannot be answered
% until sustained correct lateralisation has revealed the colors. A trial
% where that never happens ends as a guess or a timeout by design. Raise
% nfBaselineDeltaE above 0 to make the colors faintly visible from cue onset
% instead (a deliberate, subtle glimpse of each flock's true color that the
% live NF then grows on top of), which makes every trial answerable but
% removes that gating.
%
% All of it is driven purely off nf.txt (written externally by
% RT_acquisition_8), through the trailing window described under v4 below.
% nf.txt is re-read fresh every displayed frame (not held between reads),
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

% v4: the leaf fill is NOT driven by the instantaneous NF value. Raw SSVEP
% lateralisation is very flickery on a ~100ms cadence, so mapping it
% directly onto color made the leaves visibly jitter. Instead the color is
% driven by a *sustained-success* statistic over a trailing window:
%
%   1. every displayed frame's NF value goes into a rolling nfWindowSec
%      window, re-zeroed at each trial start;
%   2. nfAboveProportion = fraction of that window strictly above
%      nfValueThreshold - i.e. the proportion of the last nfWindowSec of
%      *time* the participant held a good-enough lateralisation;
%   3. that proportion is thresholded and rescaled: at or below
%      nfProportionThreshold the drive is 0 (leaves stay at the fixed
%      cue-onset reveal), and the remaining top slice
%      [nfProportionThreshold, 1] maps linearly onto drive [0, 1], which
%      is what computeNfLeafColor now receives in place of the raw value.
%
% Sampling per displayed frame rather than once per new nf.txt write is
% deliberate: nf.txt only changes every ~100ms, so consecutive frames
% repeat the same value ~6 times over, which is exactly what makes the
% proportion a proportion of elapsed time rather than of samples - it stays
% correct even when the external process's write cadence jitters.
%
% The trade this buys - smoothness at the cost of latency - is set by these
% three numbers, and the latencies they imply follow directly:
%   first color   = nfProportionThreshold * nfWindowSec       (0.8s here)
%   full color    = nfWindowSec                               (1.0s here)
%   back to grey  = (1 - nfProportionThreshold) * nfWindowSec (0.2s here)
% i.e. success has to be *earned* over most of a window, but is lost again
% quickly - raising nfProportionThreshold sharpens both. Retune here.
%
% nfValueThreshold at 0.001 is deliberately just-above-zero: a sample counts
% as a success if the lateralisation favours the cued frequency *at all*.
% The statistic is therefore effectively a sign test - "what fraction of the
% last nfWindowSec did SSVEP lean the right way" - rather than a test of how
% strongly it leaned. Raise it to demand a minimum magnitude too.
%
% The window starts each trial pre-filled with zeros and is therefore
% always exactly nfWindowFrames long - the proportion's denominator never
% changes. This matters at the start of a trial: a window sized to only
% the samples collected so far would let one lucky above-threshold sample
% on frame 1 read as a proportion of 1.0 and drive full color, and more
% generally would make the statistic wildly noisy until nfWindowSec had
% elapsed. Pre-filled zeros count as below-threshold failures instead, so
% color can only ever appear after a genuinely sustained run of successes
% - a minimum of nfProportionThreshold * nfWindowSec = 0.8s from trial
% start, and the full 1.0s for saturation, no matter how short that trial's
% pre-cue period happens to be.
%
% The window then keeps filling from trial start (not cue onset), so it's
% already carrying real data by the time the color is first shown and
% there's no ramp-up dead time at cue onset. RT_acquisition_8 zeroes
% nf.txt at trial start, so the earliest pre-cue samples read ~0 anyway
% and agree with the pre-filled zeros they replace.
nfWindowSec           = 1.000;  % trailing window the proportion is computed over
nfValueThreshold      = 0.001;    % an NF value must exceed this to count as a success
nfProportionThreshold = 0.80;   % proportion of the window that must be successes before ANY color is revealed

% The fixed cue-onset reveal (and the live-NF reveal growth on top of it)
% is calibrated in CIELAB Delta E - perceived color difference - rather
% than a raw RGB blend fraction: a rig test showed the same blend fraction
% looked clearly more intense for one flock's color than the other's,
% since equal RGB distance is not equal *perceived* distance across
% different hues. See helperFunctions/computeNfLeafColor.m.
% v5 keeps this at 0 on purpose: the leaf color is the response, so any
% fixed reveal here would hand the participant the answer for free and
% un-gate the task from the neurofeedback (see the block above).
nfBaselineDeltaE = 0;  % target CIELAB Delta E for the fixed cue-onset reveal - both flocks match exactly
labGrey = srgb2lab(grey);
labC1   = srgb2lab(colorC1);
labC2   = srgb2lab(colorC2);
maxDeltaEC1 = norm(labC1 - labGrey);  % this flock's total Lab distance from grey to fully-saturated colorC1
maxDeltaEC2 = norm(labC2 - labGrey);  % ditto for colorC2 - deliberately not assumed equal to maxDeltaEC1

%% Initialise the screen
screens = Screen('Screens');
screenNumber = max(screens);

if ~ismac && eyeTracking
    EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
end

[window,windowRect]=Screen('OpenWindow', screenNumber, grey,[], [], [], [], [], [], kPsychGUIWindow);
Screen('ColorRange', window, 255);
Screen('TextSize', window, 40);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

[xCenter, yCenter] = RectCenter(windowRect);
cueRect = [xCenter - cueRectWidthPx / 2, yCenter - cueRectHeightPx / 2, ...
           xCenter + cueRectWidthPx / 2, yCenter + cueRectHeightPx / 2];

Screen('FillRect', window, grey);
drawRoundedRect(window, colorCueRectPreCue, cueRect, cueRectCornerRadiusPx);
Screen('Flip', window);
WaitSecs(1);

% v2: vbl is captured on every platform (not just ~ismac) because the
% SSVEP phase below is now driven from this real measured flip timestamp
% rather than a frame counter - see computeSsvepColorsFromTime.m.
vbl = Screen('Flip', window);

interFrameInterval = Screen('GetFlipInterval', window);
refreshRate = 1 / interFrameInterval;
topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

% Frame-based timing
responseTimeoutFrames = max(1, round(responseTimeoutSec / interFrameInterval));
feedbackFrames = max(1, round(feedbackDurationSec / interFrameInterval));
itiFrames = max(1, round(itiDurationSec / interFrameInterval));
leafLifetimeFrames = max(1, round(leafLifetimeSec / interFrameInterval));
nfTraceLogIntervalFrames = max(1, round(nfTraceLogIntervalSec / interFrameInterval));
nfWindowFrames = max(1, round(nfWindowSec / interFrameInterval));
% Denominator of the proportion->drive rescale, computed once. max(eps, ...)
% keeps a (degenerate) nfProportionThreshold of 1 from dividing by zero -
% it then just means "only a perfect window reveals anything".
nfProportionSpan = max(eps, 1 - nfProportionThreshold);

% Per-frame speed, and the leaf field rect (needs interFrameInterval/windowRect, known only now)
leafSpeedPxPerFrame = leafSpeedPxPerSec * interFrameInterval;

fieldRect = [windowRect(1) + fieldMarginPx, windowRect(2) + fieldMarginPx, ...
             windowRect(3) - fieldMarginPx, windowRect(4) - fieldMarginPx];

%% Block Loop
runBlockLoop = true;
trialNumber = 1;
accuracyByTrial = nan(1, trialNumberPerBlock);
rtByTrial = nan(1, trialNumberPerBlock);
eyeTrackingStopped = ismac || ~eyeTracking;

try
    %% Instructions screen (once, before the block starts), with static example leaves
    demoLeafPointDir = 'right';
    demoInnerShape = createLeafShape(demoLeafPointDir, leafLengthPx, leafWidthPx);
    demoOuterShape = createLeafShape(demoLeafPointDir, leafLengthPx + 2 * leafBorderThicknessPx, leafWidthPx + 2 * leafBorderThicknessPx);

    % v5: the demo leaves illustrate the color -> button mapping, so the
    % orange (c2) example sits on the left and the blue (c1) one on the
    % right, matching the buttons they are reported with.
    demoOffsetX = (windowRect(3) - windowRect(1)) * 0.22;
    demoY = yCenter + 60;
    demoPosC2 = [xCenter - demoOffsetX, demoY];
    demoPosC1 = [xCenter + demoOffsetX, demoY];

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
        'direction and moves in another direction, and all four directions are\n' ...
        'different (up / down / left / right). They change from trial to trial.\n\n' ...
        'Partway through each trial the box at the center names one feature and\n' ...
        'one direction, e.g. "MOVING" above "UP" - meaning the group that is\n' ...
        'moving upward. Find that group and report ITS COLOR with the buttons\n' ...
        'shown below.\n\n' ...
        'The leaves stay blank until your attention on the cued group brings out\n' ...
        'their color, so hold your attention there until the color appears.\n' ...
        'The box will then show whether you were Correct or Incorrect.'];

    Screen('FillRect', window, grey);
    Screen('TextSize', window, instructionsTextSize);
    DrawFormattedText(window, instructionsText, 'center', 'center', black, [], [], [], [], [], instructionsRect);

    Screen('FillPoly', window, black, bsxfun(@plus, demoOuterShape, demoPosC1));
    Screen('FillPoly', window, colorC1, bsxfun(@plus, demoInnerShape, demoPosC1));
    Screen('FillPoly', window, black, bsxfun(@plus, demoOuterShape, demoPosC2));
    Screen('FillPoly', window, colorC2, bsxfun(@plus, demoInnerShape, demoPosC2));

    Screen('TextSize', window, 22);
    DrawFormattedText(window, 'ORANGE\npress the\nLEFT button', 'center', 'center', black, [], [], [], [], [], labelC2Rect);
    DrawFormattedText(window, 'BLUE\npress the\nRIGHT button', 'center', 'center', black, [], [], [], [], [], labelC1Rect);

    Screen('TextSize', window, 28);
    DrawFormattedText(window, 'Press any key or button to begin', 'center', windowRect(4) - 80, black);

    if ~ismac
        vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
        cedrus.waitpress(600);
    else
        vbl = Screen('Flip', window);
        KbWait(-1);
    end

    while runBlockLoop && trialNumber <= trialNumberPerBlock
        if ~ismac && eyeTracking
            calllib('iViewXAPI', 'iV_StartRecording');
        end

        %% Trial setup
        c1PointDir = directionTrialList{trialNumber, 1};
        c1MoveDir  = directionTrialList{trialNumber, 2};
        c2PointDir = directionTrialList{trialNumber, 3};
        c2MoveDir  = directionTrialList{trialNumber, 4};
        % v5: cue = which flock this trial's (feature, direction) pair points
        % at. It is still 'c1'/'c2' - it is what fixes the attended SSVEP
        % frequency (and so nfIndex) exactly as before - but the participant
        % never sees it directly: they see the feature and the direction, and
        % report the color of the flock those identify.
        cueFeature = cueFeatureList{trialNumber};
        cue = cueFlockList{trialNumber};

        if strcmp(cue, 'c1')
            if strcmp(cueFeature, 'moving')
                cueDirection = c1MoveDir;
            else
                cueDirection = c1PointDir;
            end
            correctResponse = responseLabelC1;
            nfIndex = nfIndexC1;
        else
            if strcmp(cueFeature, 'moving')
                cueDirection = c2MoveDir;
            else
                cueDirection = c2PointDir;
            end
            correctResponse = responseLabelC2;
            nfIndex = nfIndexC2;
        end

        % Two lines in the cue box: feature above direction, e.g. 'MOVING' / 'UP'.
        cueText = sprintf('%s\n%s', upper(cueFeature), upper(cueDirection));

        % NF state for this trial (nfIndex above is fixed for the whole
        % trial - predetermined here, before the trial's frame loop starts).
        % nfCurrentValueRaw only ever updates on a successful read (see the
        % frame loop below) - starts at 0 (neutral) same as a real trial
        % start, since RT_acquisition_8 itself zeroes nf.txt at trial start.
        nfCurrentValueRaw = 0;

        % v4: rolling NF window for this trial (see NEUROFEEDBACK PARAMETERS
        % above). Re-zeroed per trial so nothing bleeds across trials, and
        % those starting zeros are themselves the trial's initial window
        % contents - counted as below-threshold failures, never as missing
        % samples, so the proportion is always over a full nfWindowFrames.
        nfWindowBuffer = zeros(1, nfWindowFrames);
        nfWindowCursor = 0;
        nfAboveProportion = 0;
        nfDrive = 0;

        nfTraceFrameNumber = [];
        nfTraceSampleTime = [];
        nfTraceValueRaw = [];
        nfTraceValueClipped = [];
        nfTraceWindowProportion = [];
        nfTraceDrive = [];
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
        flock1OuterShape = createLeafShape(c1PointDir, leafLengthPx + 2 * leafBorderThicknessPx, leafWidthPx + 2 * leafBorderThicknessPx);
        flock2InnerShape = createLeafShape(c2PointDir, leafLengthPx, leafWidthPx);
        flock2OuterShape = createLeafShape(c2PointDir, leafLengthPx + 2 * leafBorderThicknessPx, leafWidthPx + 2 * leafBorderThicknessPx);

        leaves = initLeaves(numLeavesPerFlock, fieldRect, minLeafSeparationPx, leafLifetimeFrames, flock1Velocity, flock2Velocity);

        participantResponse = 'missed';
        reactionTime = NaN;
        accuracy = 0;
        responseTimeout = 0;
        validResponse = false;
        inFeedback = false;
        feedbackFramesRemaining = 0;

        trialStartTime = getElapsedTime(experimentStartTime);
        cueOnsetTime = NaN;
        cueOnsetAbsTime = NaN;  % raw GetSecs companion to cueOnsetTime, see the frame loop
        % v5: timestamp of the first post-cue frame that actually displayed
        % any leaf color (nfDrive > 0). Stays NaN if the participant never
        % sustained the cued lateralisation long enough - in which case they
        % had nothing to report from, so reaction time and accuracy for that
        % trial have to be read against this column.
        colorRevealTime = NaN;

        disp(trialNumber);
        if ~ismac
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
        cueDelaySec = preCueConstantSec + truncatedExpRnd(preCueExpMeanSec, preCueExpMaxSec);
        preCueFrames = max(1, round(cueDelaySec / interFrameInterval));
        cueOnsetFrame = preCueFrames + 1;
        responseDeadlineFrame = preCueFrames + responseTimeoutFrames;
        maxFrames = preCueFrames + responseTimeoutFrames + feedbackFrames;
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

            % v4: push this frame's value into the rolling window and
            % recompute the drive. Done every frame regardless of phase (so
            % the window is already full at cue onset); only the *visual*
            % use of nfDrive below is gated to post-cue. A stale value from
            % a failed read is pushed as-is - it's the value that was on
            % screen for that frame, so counting it is what keeps the
            % proportion a proportion of elapsed time.
            nfWindowCursor = mod(nfWindowCursor, nfWindowFrames) + 1;
            nfWindowBuffer(nfWindowCursor) = nfCurrentValueRaw;
            nfAboveProportion = sum(nfWindowBuffer > nfValueThreshold) / nfWindowFrames;
            nfDrive = max(0, (nfAboveProportion - nfProportionThreshold) / nfProportionSpan);

            % The trace CSV is still only logged every nfTraceLogIntervalFrames
            % (~100ms), since nf.txt itself is only rewritten externally on
            % roughly that cadence - logging every frame would just repeat
            % the same unchanged value several times over for no benefit.
            if mod(currentFrame - 1, nfTraceLogIntervalFrames) == 0
                nfTraceFrameNumber(end+1) = currentFrame; %#ok<SAGROW>
                nfTraceSampleTime(end+1) = getElapsedTime(experimentStartTime); %#ok<SAGROW>
                nfTraceValueRaw(end+1) = nfCurrentValueRaw; %#ok<SAGROW>
                nfTraceValueClipped(end+1) = max(0, min(1, nfCurrentValueRaw)); %#ok<SAGROW>
                nfTraceWindowProportion(end+1) = nfAboveProportion; %#ok<SAGROW>
                nfTraceDrive(end+1) = nfDrive; %#ok<SAGROW>
                nfTraceReadOk(end+1) = nfReadOk; %#ok<SAGROW>
                nfTracePostCue(end+1) = ~isPreCue; %#ok<SAGROW>
            end

            leaves = updateLeaves(leaves, fieldRect, minLeafSeparationPx, leafLifetimeFrames);

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

            Screen('FillRect', window, grey);
            if isPreCue
                drawLeaves(window, leaves, flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
                    grey, grey, flock1BorderColor, flock2BorderColor);
                drawRoundedRect(window, colorCueRectPreCue, cueRect, cueRectCornerRadiusPx);
            else
                % v4: the color is driven by nfDrive - the windowed
                % proportion-above-threshold statistic - not by the raw
                % instantaneous NF value. nfDrive is already in [0, 1], so
                % computeNfLeafColor's own clip is a no-op here.
                flock1FillColor = computeNfLeafColor(labGrey, labC1, maxDeltaEC1, nfDrive, nfBaselineDeltaE);
                flock2FillColor = computeNfLeafColor(labGrey, labC2, maxDeltaEC2, nfDrive, nfBaselineDeltaE);
                drawLeaves(window, leaves, flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
                    flock1FillColor, flock2FillColor, flock1BorderColor, flock2BorderColor);
                % v5: fixed neutral box - it must not carry the cued flock's
                % color, since that color is the answer.
                drawRoundedRect(window, colorCueRectPostCue, cueRect, cueRectCornerRadiusPx);
                Screen('TextSize', window, cueTextSize);
                if inFeedback
                    % Response feedback is shown inside the cue box itself, in
                    % place of the two-line cue text, not as separate text.
                    DrawFormattedText(window, feedbackString, 'center', 'center', feedbackColor, [], [], [], [], [], cueRect);
                else
                    DrawFormattedText(window, cueText, 'center', 'center', colorCueText, [], [], [], [], [], cueRect);
                end
            end

            % v2: missed-frame detection is only meaningful with real vsync
            % timing (~ismac, where SkipSyncTests is off), so it's only
            % tracked there - see droppedFrameCsvFile above.
            if ~ismac
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
                % cueOnsetAbsTime is the raw GetSecs value; cueOnsetTime is
                % the time-since-experiment-start the CSV logs. Both are
                % needed: getColorResponse's mac branch does
                % GetSecs - responseOnsetTime, so passing it the relative
                % value made mac-mode ReactionTime come out as roughly
                % "seconds since boot" rather than a reaction time. Windows
                % was never affected - its RT comes from the Cedrus box's
                % own timer, reset just below. Taken from one GetSecs call
                % so the two timestamps can't disagree.
                cueOnsetAbsTime = GetSecs;
                cueOnsetTime = cueOnsetAbsTime - experimentStartTime;
                if ~ismac
                    cog_send_triggers(paraport, 'cueonset');
                    cedrus.resettimer();
                end
            end

            % v5: stamp the moment the leaves first actually showed color -
            % i.e. the first post-cue frame drawn with nfDrive > 0 - taken
            % after that frame's flip, like cueOnsetTime, so it refers to
            % what was displayed rather than what was queued.
            if ~isPreCue && isnan(colorRevealTime) && nfDrive > 0
                colorRevealTime = getElapsedTime(experimentStartTime);
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
            elseif ~isPreCue
                % v5: 2-alternative color response (left = orange = c2,
                % right = blue = c1) instead of gameNFv4.m's 4-direction one.
                if ~ismac
                    [validResponse, participantResponse, reactionTime] = getColorResponse( ...
                        false, cedrus, leftKey, rightKey, responseLabelC2, responseLabelC1, cueOnsetAbsTime);
                else
                    [validResponse, participantResponse, reactionTime] = getColorResponse( ...
                        true, [], leftKey, rightKey, responseLabelC2, responseLabelC1, cueOnsetAbsTime);
                end

                if validResponse
                    accuracy = strcmp(participantResponse, correctResponse);
                    if ~ismac
                        cog_send_triggers(paraport, 'response');
                    end
                    if accuracy
                        feedbackString = 'Correct';
                        feedbackColor = colorFeedbackCorrect;
                    else
                        feedbackString = 'Incorrect';
                        feedbackColor = colorFeedbackIncorrect;
                    end
                    inFeedback = true;
                    feedbackFramesRemaining = feedbackFrames;
                elseif currentFrame >= responseDeadlineFrame
                    responseTimeout = 1;
                    break;
                end
            end
        end
        if ~runBlockLoop
            if ~ismac
                cog_send_triggers(paraport, 'trialstop');
            end
            break;
        end

        if ~ismac
            cog_send_triggers(paraport, 'trialstop');
        end

        %% Log trial
        trialEndTime = getElapsedTime(experimentStartTime);
        accuracyByTrial(trialNumber) = accuracy;
        rtByTrial(trialNumber) = reactionTime;

        fid = fopen(csvFile, 'a');
        fprintf(fid, '%d,%.6f,%s,%s,%s,%s,%s,%s,%s,%.6f,%s,%s,%d,%.6f,%d,%.6f,%d,%.6f\n', ...
            trialNumber, trialStartTime, c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, ...
            cue, cueFeature, cueDirection, cueOnsetTime, ...
            correctResponse, participantResponse, accuracy, reactionTime, responseTimeout, ...
            trialEndTime, droppedFrameCount, colorRevealTime);
        fclose(fid);

        %% Log NF trace for this trial (one row per ~100ms, per nfTraceLogIntervalSec)
        fid = fopen(nfTraceCsvFile, 'a');
        for r = 1:numel(nfTraceFrameNumber)
            fprintf(fid, '%d,%d,%.6f,%d,%.6f,%.6f,%.6f,%.6f,%d,%d\n', ...
                trialNumber, nfTraceFrameNumber(r), nfTraceSampleTime(r), nfIndex, ...
                nfTraceValueRaw(r), nfTraceValueClipped(r), nfTraceWindowProportion(r), ...
                nfTraceDrive(r), nfTracePostCue(r), nfTraceReadOk(r));
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
            Screen('FillRect', window, grey);
            drawRoundedRect(window, colorCueRectPreCue, cueRect, cueRectCornerRadiusPx);
            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                vbl = Screen('Flip', window);
            end
        end

        if ~ismac && eyeTracking
            calllib('iViewXAPI', 'iV_StopRecording');
        end

        trialNumber = trialNumber + 1;
    end

    if ~ismac && eyeTracking
        EyeTracking(str2double(participantInfo),str2double(blockInfo),'stop');
        eyeTrackingStopped = true;
    end

catch ME
    if ~ismac
        cog_send_triggers(paraport, 'trialstop');
    end
    cleanupExperiment(ismac, eyeTrackingStopped, participantInfo, blockInfo, paraport);
    rethrow(ME);
end

%% Calculate and display block results
validAccuracy = accuracyByTrial(~isnan(accuracyByTrial));
if isempty(validAccuracy)
    meanAccuracy = NaN;
else
    meanAccuracy = mean(validAccuracy);
end

Screen('FillRect', window, grey);
Screen('TextSize', window, 35);
performanceText = sprintf(['TESTING COMPLETED!\n\n' ...
    'ACCURACY: %.2f%%\n\n' ...
    'Press ESCAPE or any button to continue'], 100 * meanAccuracy);
DrawFormattedText(window, performanceText, 'center', 'center', black);
if ~ismac
    vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
else
    Screen('Flip', window);
end

fprintf('%s\n', performanceText);
WaitSecs(1);

waitForEscape = true;
while waitForEscape
    [keyIsDown, ~, keyCode] = KbCheck(-1);
    if ~ismac
        [~, ~, ohhItIsPressed] = cedrus.getpress();
    else
        ohhItIsPressed = 0;
    end

    if (keyIsDown && keyCode(escapeKey)) || ohhItIsPressed
        waitForEscape = false;
    end
    WaitSecs(0.01);
end

cleanupExperiment(ismac, eyeTrackingStopped, participantInfo, blockInfo, paraport);

%% Trigger values sent by this task
% Values are defined in functions/cog_send_triggers.m.
% reset      -> 0
% trialstart -> 20
% cueonset   -> 45
% response   -> 40
% trialstop  -> 30
