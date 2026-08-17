% gameNFtemp.m - motion sandbox, NOT an experiment script.
%
% A live preview of the fixed-path ("lane") leaf motion, so its look and its
% parameters can be judged before it goes into a real variant. There are no
% trials, no cue, no neurofeedback, no nf.txt, no CSV, no triggers and no
% eye tracking here - just the leaf field, drawn exactly as gameNFv6.m draws
% it (pure black background, black-to-white SSVEP border flicker), with
% everything adjustable from the keyboard while it runs.
%
% The point of the fixed-path motion: in initLeaves.m/updateLeaves.m a leaf
% is respawned somewhere else whenever its lifetime expires, it leaves the
% field, or it drifts too close to a leaf of the other flock - so leaves
% constantly appear and disappear. Here every leaf instead follows a
% permanent wrapping path, chosen at setup so that no two leaves ever
% overlap; nothing is ever respawned and the on-screen count is constant.
% See initLeafLanes.m for how that is arranged and what it costs.
%
% CONTROLS
%   ESC            quit
%   SPACE          next of the 24 pointing/moving direction combinations
%   M              toggle motion: fixed paths  <->  the classic respawning
%                  behaviour of gameNFv6.m, for a direct A/B comparison
%   UP / DOWN      leaf speed  -/+ 20 px/s
%   RIGHT / LEFT   leaves per flock  +/- 1
%   Z / X          leaf size  -/+ 5 px
%   K / L          clearance margin  -/+ 2 px
%   C              cycle the leaf fill through the neurofeedback states
%                  (black -> mid grey -> near white -> green zone -> revealed)
%   V              verify the current layout over a full motion period and
%                  print the result to the command window
%   H              show/hide the overlay
%
% The overlay's "min clearance" is the smallest gap between any two leaves
% on the current frame, measured as bounding boxes: 0 means touching and
% negative means overlapping. On fixed paths it should never go negative -
% if it does, that is a bug worth reporting, not a tuning problem.

%% Initialise
clc;
close all;
sca;
testing = true; %#ok<*UNRCH> % true = laptop testing; false = experiment-room hardware
clearvars -except testing;

experimentRoot = fileparts(mfilename('fullpath'));
if isempty(experimentRoot)
    experimentRoot = pwd;
end
addpath(genpath(experimentRoot));

PsychDefaultSetup(2);
if testing || ismac
    Screen('Preference', 'SkipSyncTests', 1);
end
KbName('UnifyKeyNames');

%% Display colors
black = [0 0 0];
white = [255 255 255];

%% PARAMETERS
testingStimulusScreenNumber = 2;   % external monitor on the testing laptop

escapeKey = KbName('ESCAPE');
spaceKey  = KbName('space');
leftKey   = KbName('LeftArrow');
rightKey  = KbName('RightArrow');
upKey     = KbName('UpArrow');
downKey   = KbName('DownArrow');
mKey      = KbName('m');
cKey      = KbName('c');
vKey      = KbName('v');
hKey      = KbName('h');
% Letter keys only, deliberately. Under KbName('UnifyKeyNames') the
% punctuation keys are named '[{', ']}', ',<', '.>' rather than the bare
% characters, and that naming differs across platforms - KbName('[') simply
% errors. Letters are safe everywhere. In both pairs below the left-hand key
% decreases and the right-hand key increases.
sizeDownKey   = KbName('z');
sizeUpKey     = KbName('x');
marginDownKey = KbName('k');
marginUpKey   = KbName('l');

% Field size. For flocks moving on perpendicular axes the fixed-path scheme
% needs gcd(fieldWidth, fieldHeight) to comfortably exceed a leaf (see
% initLeafLanes.m), and a raw screen's gcd is a lottery: 1920x1080 gives 120
% and fails every perpendicular combination, while 1920x960 gives 960 and
% works. Rather than hand-tune an inset per monitor, chooseWrapFieldRect.m
% searches for the largest centred field that qualifies - which is why the
% active field is usually a little smaller than the display, and why the
% overlay draws its outline.
%
% The requirement depends on leaf size and margin, so the field is chosen
% afresh whenever those change. Set autoChooseField = false to pin the field
% with the manual insets instead and see the scheme fail for yourself.
autoChooseField = true;
maxFieldShrinkPx = 400;   % how much of each axis chooseWrapFieldRect may give up
manualFieldMarginXPx = 0;
manualFieldMarginYPx = 60;

% Leaf geometry - same multipliers gameNFv6.m uses
leafSizePx = 90;
leafWidthMultiplier           = 0.42;
leafBorderThicknessMultiplier = 0.20;

leafSpeedPxPerSec = 200;
numLeavesPerFlock = 20;

% Extra slack on top of every extent-derived spacing, so leaves are not
% placed just barely touching.
laneClearanceMarginPx = 6;

% Classic-motion parameters, used only in the 'classic' comparison mode
leafLifetimeSec             = 1.0;
minLeafSeparationMultiplier = 1.10;

% SSVEP tagging
freqC1Hz = 19;
freqC2Hz = 23;
colorBorderLow  = black;
colorBorderHigh = white;

% Flock colours, shown in the 'revealed' fill state
colorC1 = [0 191 255];
colorC2 = [255 140 0];

% Neurofeedback fill states to preview (see gameNFv6.m). The green-zone
% colour is built the same way gameNFv6.m builds it.
nfGreenTintStrength = 0.30;
colorNfGreenZone = round([255 * (1 - nfGreenTintStrength), 255, 255 * (1 - nfGreenTintStrength)]);
fillStateNames = {'black (level 0)', 'mid grey (level 0.5)', 'near white (level 0.95)', ...
    'green zone', 'colours revealed'};

overlayTextSize = 20;
overlayVisible = true;

%% Direction combinations - the same 24 gameNFv6.m enumerates
directionSet = {'up', 'down', 'left', 'right'};
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

%% Open the screen
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

[window, windowRect] = Screen('OpenWindow', screenNumber, black);
Screen('ColorRange', window, 255);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');
interFrameInterval = Screen('GetFlipInterval', window);
Priority(MaxPriority(window));

fprintf('Window is %dx%d (PTB screen %d).\n', ...
    windowRect(3) - windowRect(1), windowRect(4) - windowRect(2), screenNumber);

%% Live state
comboIndex = 1;
motionMode = 'lanes';      % 'lanes' or 'classic'
fillStateIndex = 1;
needsRebuild = true;
keyWasDown = false;
frameCounter = 0;
t0 = GetSecs;
vbl = Screen('Flip', window);

try
    while true
        %% (Re)build the leaf field whenever a parameter changed
        if needsRebuild
            needsRebuild = false;

            c1PointDir = directionCombos{comboIndex, 1};
            c1MoveDir  = directionCombos{comboIndex, 2};
            c2PointDir = directionCombos{comboIndex, 3};
            c2MoveDir  = directionCombos{comboIndex, 4};

            leafLengthPx = leafSizePx;
            leafWidthPx = leafSizePx * leafWidthMultiplier;
            leafBorderThicknessPx = leafSizePx * leafBorderThicknessMultiplier;
            outerLengthPx = leafLengthPx + 2 * leafBorderThicknessPx;
            outerWidthPx = leafWidthPx + 2 * leafBorderThicknessPx;
            maxLeafRadiusPx = 0.5 * hypot(outerLengthPx, outerWidthPx);

            flock1InnerShape = createLeafShape(c1PointDir, leafLengthPx, leafWidthPx);
            flock1OuterShape = createLeafShape(c1PointDir, outerLengthPx, outerWidthPx);
            flock2InnerShape = createLeafShape(c2PointDir, leafLengthPx, leafWidthPx);
            flock2OuterShape = createLeafShape(c2PointDir, outerLengthPx, outerWidthPx);

            [xExtent1, yExtent1] = leafExtentsForDirection(c1PointDir, outerLengthPx, outerWidthPx);
            [xExtent2, yExtent2] = leafExtentsForDirection(c2PointDir, outerLengthPx, outerWidthPx);

            % Pick the field before placing anything. The requirement is the
            % same for all 24 direction combinations - a leaf's two extents
            % are the outer length and width in one order or the other, so
            % xExtent + yExtent is the same whichever way it points and the
            % directions cancel out (see chooseWrapFieldRect.m). That means
            % the field only has to change when leaf size or margin does.
            requiredGcdPx = ceil(2 * (outerLengthPx + outerWidthPx + 2 * laneClearanceMarginPx)) + 1;
            if autoChooseField
                [fieldRect, fieldInfo] = chooseWrapFieldRect(windowRect, requiredGcdPx, maxFieldShrinkPx);
                if ~fieldInfo.feasible
                    fieldRect = [windowRect(1) + manualFieldMarginXPx, windowRect(2) + manualFieldMarginYPx, ...
                                 windowRect(3) - manualFieldMarginXPx, windowRect(4) - manualFieldMarginYPx];
                end
            else
                fieldRect = [windowRect(1) + manualFieldMarginXPx, windowRect(2) + manualFieldMarginYPx, ...
                             windowRect(3) - manualFieldMarginXPx, windowRect(4) - manualFieldMarginYPx];
                fieldInfo = struct('feasible', true, 'message', 'manual field', ...
                    'achievedGcdPx', gcd(round(fieldRect(3) - fieldRect(1)), ...
                                         round(fieldRect(4) - fieldRect(2))), ...
                    'lostWidthPx', 2 * manualFieldMarginXPx, 'lostHeightPx', 2 * manualFieldMarginYPx);
            end

            leafSpeedPxPerFrame = leafSpeedPxPerSec * interFrameInterval;
            leafLifetimeFrames = max(1, round(leafLifetimeSec / interFrameInterval));
            minLeafSeparationPx = leafSizePx * minLeafSeparationMultiplier;

            % effectiveMotion is what actually runs this frame, which is not
            % always what was asked for: initLeafLanes cannot place leaves
            % at every combination of size/count/field, and when it can't it
            % returns them unplaced. Rather than show a heap of leaves in
            % the corner - the least informative possible response while
            % somebody is deliberately pushing the parameters to find the
            % limit - fall back to the classic field and say so on the
            % overlay. The limit itself is the interesting readout.
            usedFallback = false;
            if strcmp(motionMode, 'lanes')
                [leaves, laneInfo] = initLeafLanes(numLeavesPerFlock, fieldRect, ...
                    outerLengthPx, outerWidthPx, c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, ...
                    leafSpeedPxPerFrame, laneClearanceMarginPx);
                usedFallback = ~laneInfo.feasible;
            else
                laneInfo = struct('feasible', true, 'message', '', 'mode', 'classic respawning', ...
                    'nLanes1', 0, 'nLanes2', 0, 'invariantModulus', NaN, 'invariantClearancePx', NaN);
            end

            if ~strcmp(motionMode, 'lanes') || usedFallback
                flock1Velocity = directionToVector(c1MoveDir) * leafSpeedPxPerFrame;
                flock2Velocity = directionToVector(c2MoveDir) * leafSpeedPxPerFrame;
                leaves = initLeaves(numLeavesPerFlock, fieldRect, minLeafSeparationPx, ...
                    leafLifetimeFrames, flock1Velocity, flock2Velocity);
                effectiveMotion = 'classic';
            else
                effectiveMotion = 'lanes';
            end

            fprintf('[%s -> %s] %s/%s vs %s/%s | %s | field: %s | feasible=%d %s\n', motionMode, ...
                effectiveMotion, c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, laneInfo.mode, ...
                fieldInfo.message, laneInfo.feasible, laneInfo.message);
        end

        %% Advance
        if strcmp(effectiveMotion, 'lanes')
            leaves = updateLeafLanes(leaves, fieldRect);
        else
            leaves = updateLeaves(leaves, fieldRect, minLeafSeparationPx, leafLifetimeFrames);
        end
        frameCounter = frameCounter + 1;

        %% Live worst-case clearance between the two flocks, this frame
        idx1 = leaves.flockID == 1;
        idx2 = leaves.flockID == 2;
        dxNow = abs(bsxfun(@minus, leaves.x(idx1), leaves.x(idx2).'));
        dyNow = abs(bsxfun(@minus, leaves.y(idx1), leaves.y(idx2).'));
        if strcmp(effectiveMotion, 'lanes')
            dxNow = min(dxNow, (fieldRect(3) - fieldRect(1)) - dxNow);
            dyNow = min(dyNow, (fieldRect(4) - fieldRect(2)) - dyNow);
        end
        liveClearance = min(min(max(dxNow - (xExtent1 + xExtent2) / 2, ...
                                    dyNow - (yExtent1 + yExtent2) / 2)));

        %% Fill colour for the previewed neurofeedback state
        switch fillStateIndex
            case 1
                fill1 = black;                       fill2 = black;
            case 2
                fill1 = [128 128 128];               fill2 = [128 128 128];
            case 3
                fill1 = round([242 242 242]);        fill2 = round([242 242 242]);
            case 4
                fill1 = colorNfGreenZone;            fill2 = colorNfGreenZone;
            otherwise
                fill1 = colorC1;                     fill2 = colorC2;
        end

        %% Draw
        elapsed = GetSecs - t0;
        [border1, border2] = computeSsvepColorsFromTime(elapsed, freqC1Hz, freqC2Hz, ...
            colorBorderLow, colorBorderHigh);

        Screen('FillRect', window, black);
        if strcmp(effectiveMotion, 'lanes')
            drawLeavesWrapped(window, leaves, fieldRect, maxLeafRadiusPx, ...
                flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
                fill1, fill2, border1, border2);
        else
            drawLeaves(window, leaves, flock1InnerShape, flock1OuterShape, ...
                flock2InnerShape, flock2OuterShape, fill1, fill2, border1, border2);
        end

        if overlayVisible
            % Outline the active field. It is usually a little smaller than
            % the display (chooseWrapFieldRect.m gives up whatever it must
            % to get a workable gcd), and without this the leaves would just
            % look like they mysteriously stop short of the edges.
            Screen('FrameRect', window, [60 60 0], fieldRect, 2);

            if laneInfo.feasible
                feasibleStr = 'yes';
            else
                feasibleStr = ['NO - ' laneInfo.message];
            end
            if usedFallback
                motionStr = sprintf('%s -> FELL BACK TO CLASSIC', motionMode);
            else
                motionStr = motionMode;
            end
            overlayText = sprintf([ ...
                'motion: %s (%s)   [M to toggle]\n' ...
                'combo %d/24:  c1 points %s, moves %s   |   c2 points %s, moves %s   [SPACE]\n' ...
                'speed %d px/s [UP/DOWN]   leaves/flock %d [RIGHT/LEFT]   leaf size %d px [Z/X]   margin %d px [K/L]\n' ...
                'field %dx%d, gcd %d (need >%d)   lanes %d/%d   workable: %s\n' ...
                'fill state: %s   [C]\n' ...
                'min clearance now: %+.1f px   (negative = overlapping)   [V to verify a full period]'], ...
                motionStr, laneInfo.mode, ...
                comboIndex, c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, ...
                round(leafSpeedPxPerSec), numLeavesPerFlock, round(leafSizePx), round(laneClearanceMarginPx), ...
                round(fieldRect(3) - fieldRect(1)), round(fieldRect(4) - fieldRect(2)), ...
                gcd(round(fieldRect(3) - fieldRect(1)), round(fieldRect(4) - fieldRect(2))), ...
                requiredGcdPx, laneInfo.nLanes1, laneInfo.nLanes2, feasibleStr, ...
                fillStateNames{fillStateIndex}, liveClearance);
            Screen('TextSize', window, overlayTextSize);
            DrawFormattedText(window, overlayText, 20, 30, [255 255 0]);
        end

        vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);

        %% Keys (act once per press, not once per frame held)
        [keyIsDown, ~, keyCode] = KbCheck(-1);
        if keyIsDown && ~keyWasDown
            if keyCode(escapeKey)
                break;
            elseif keyCode(spaceKey)
                comboIndex = mod(comboIndex, size(directionCombos, 1)) + 1;
                needsRebuild = true;
            elseif keyCode(mKey)
                if strcmp(motionMode, 'lanes')
                    motionMode = 'classic';
                else
                    motionMode = 'lanes';
                end
                needsRebuild = true;
            elseif keyCode(upKey)
                leafSpeedPxPerSec = max(20, leafSpeedPxPerSec - 20);
                needsRebuild = true;
            elseif keyCode(downKey)
                leafSpeedPxPerSec = leafSpeedPxPerSec + 20;
                needsRebuild = true;
            elseif keyCode(rightKey)
                numLeavesPerFlock = numLeavesPerFlock + 1;
                needsRebuild = true;
            elseif keyCode(leftKey)
                numLeavesPerFlock = max(1, numLeavesPerFlock - 1);
                needsRebuild = true;
            elseif keyCode(sizeUpKey)
                leafSizePx = leafSizePx + 5;
                needsRebuild = true;
            elseif keyCode(sizeDownKey)
                leafSizePx = max(20, leafSizePx - 5);
                needsRebuild = true;
            elseif keyCode(marginUpKey)
                laneClearanceMarginPx = laneClearanceMarginPx + 2;
                needsRebuild = true;
            elseif keyCode(marginDownKey)
                laneClearanceMarginPx = max(0, laneClearanceMarginPx - 2);
                needsRebuild = true;
            elseif keyCode(cKey)
                fillStateIndex = mod(fillStateIndex, numel(fillStateNames)) + 1;
            elseif keyCode(hKey)
                overlayVisible = ~overlayVisible;
            elseif keyCode(vKey)
                if strcmp(effectiveMotion, 'lanes')
                    report = verifyLeafLanes(leaves, fieldRect, xExtent1, yExtent1, ...
                        xExtent2, yExtent2, 40000);
                    fprintf(['VERIFY %s/%s vs %s/%s: %d frames (full period reached: %d), ' ...
                        'cross-flock %.2f px, within-flock %.2f px, collision-free: %d\n'], ...
                        c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, report.framesSimulated, ...
                        report.covered, report.minCrossFlockClearancePx, ...
                        report.minWithinFlockClearancePx, report.collisionFree);
                elseif usedFallback
                    fprintf(['VERIFY skipped: the lane scheme is not workable at these ' ...
                        'parameters, so the classic field is being shown. %s\n'], laneInfo.message);
                else
                    fprintf('VERIFY only applies to fixed-path motion (press M first).\n');
                end
            end
        end
        keyWasDown = keyIsDown;
    end

catch ME
    Priority(0);
    sca;
    rethrow(ME);
end

Priority(0);
sca;
fprintf('\ngameNFtemp finished after %d frames (%.1fs).\n', frameCounter, GetSecs - t0);
