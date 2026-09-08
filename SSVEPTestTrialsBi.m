%% Bilateral SSVEP Test Trials
% Two circular grating patches flicker simultaneously: 16 Hz on the left
% and 20 Hz on the right. Each patch contains an independent letter stream.
% A central arrow cues the stream whose X-count the participant must report,
% followed by a central fixation cross throughout the SSVEP period.

%% Initialise
clc;        % Clears the Command Window
close all;  % Closes all figure windows
sca;        % Clears the screen
testing = true; %#ok<*UNRCH> % true = laptop testing; false = experiment-room hardware

if ~testing
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
csvHeader = ['TrialNumber,CueSide,TrialStartTrigger,TrialStart,LeftLetterSequence,' ...
    'RightLetterSequence,NumLetters,LeftXCount,RightXCount,CuedXCount,CorrectResponse,' ...
    'ParticipantResponse,Accuracy,ReactionTime,ResponseTimeout,TrialEnd,DroppedFrameCount'];
csvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_ssveptestbi_trialdata.csv', sessionTag), csvHeader);

% Dropped/delayed-frame log, same rationale and shape as gameNFv3.m's: one
% row per frame during the SSVEP stream whose Screen('Flip') missed its
% requested presentation deadline (only meaningful with real vsync timing,
% so only tracked outside testing mode).
droppedFrameCsvHeader = 'TrialNumber,FrameNumber,VBLTime,MissedBySec';
droppedFrameCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_ssveptestbi_droppedframes.csv', sessionTag), droppedFrameCsvHeader);

% Here we call some default settings for setting up Psychtoolbox
PsychDefaultSetup(2);
if testing || ismac
    Screen('Preference', 'SkipSyncTests', 1);
end

% Unify key names across different operating systems
KbName('UnifyKeyNames');

% UDP trigger reset (bci_send_triggers sends to localhost:5007 in both modes)
bci_send_triggers('reset');

%% Display colors
grey  = [128 128 128];
black = [0 0 0];
white = [255 255 255];
green = [0 255 0];
red   = [255 0 0];

%% PARAMETERS
% Keyboard response mappings (used in both testing and experiment modes)
escapeKey = KbName('ESCAPE');
oddKey    = KbName('LeftArrow');  % Odd
evenKey   = KbName('RightArrow'); % Even

% Experiment structure
trialNumberPerBlock = 20;

% Timing (seconds)
cueDurationSec         = 1.000;  % central left/right arrow before SSVEP onset
trialDurationSec       = 10.000; % bilateral SSVEP + letter streams duration
itiDurationSec         = 10.000; % total ITI - always exactly this long, regardless of RT
itiFeedbackDurationSec = 1.000;  % how long 'Correct'/'Incorrect'/'Missed' is shown, inside the ITI
% The response window inside the ITI ends this long before the ITI itself
% does, so there's always exactly itiFeedbackDurationSec left to show
% feedback before the fixed-length ITI runs out.
itiResponseDeadlineSec = itiDurationSec - itiFeedbackDurationSec;

% Letter streams (one independent sequence inside each patch)
letterDurationSec = 0.800; % how long each letter is shown before switching
letterPool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; % must include 'X'
xCountMin = 2; % lower bound on how many X's appear per trial
xCountMax = 5; % upper bound (both randomized per trial via ssvepTestHelperFunctions/generateLetterSequence.m)

% SSVEP grating patches (centred in the left and right screen halves;
% black/white vertical-bar
% grating whose CONTRAST flickers sinusoidally between grey (0 contrast,
% pattern invisible) and full black/white, via
% breakoutHelperFunctions/computeGratingColors.m - same formula as
% gameBreakoutv2.m's paddle gratings. The patch is clipped to a circle by
% a one-time aperture mask texture (see createCircularApertureMask.m
% below), not by a texture rebuilt every frame.
leftGratingFreqHz     = 16;   % left patch contrast-flicker frequency (Hz)
rightGratingFreqHz    = 20;   % right patch contrast-flicker frequency (Hz)
gratingPatchRadiusPx  = 300;  % radius of the circular grating patch
gratingBarWidthPx     = 20;   % width of each grating bar
gratingMidColor       = grey; % contrast trough - must match the background so the patch vanishes, not just dims
gratingBarHigh        = white;
gratingBarLow         = black;
apertureEdgeSoftnessPx = 2;   % width of the mask's alpha ramp at the circle edge, to avoid a hard-aliased boundary

% Patch-centre discs + letters. Each letter's contrast flickers from discColor
% (invisible against the disc) up to letterColorPeak, driven by the exact
% same time base and frequency as its surrounding grating.
discRadiusPx    = 45;    % must stay smaller than gratingPatchRadiusPx
discColor       = white;
letterColorPeak = black;
letterTextSize  = 48;

% Central fixation and pre-trial cue
fixationHalfSizePx = 8;
fixationLineWidthPx = 2;
cueArrowLengthPx = 80;
cueArrowHeadPx = 24;
cueArrowLineWidthPx = 5;

% Feedback ('Correct' / 'Incorrect' / 'Missed'), shown during the ITI
feedbackTextSize = 40;

% Instructions screen (shown once, before the block starts)
instructionsTextSize = 26;

%% Initialise the screen
screens = Screen('Screens');
screenNumber = max(screens);

if ~testing && eyeTracking
    EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
end

[window,windowRect]=Screen('OpenWindow', screenNumber, grey,[], [], [], [], [], [], kPsychGUIWindow);
Screen('ColorRange', window, 255);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

[xCenter, yCenter] = RectCenter(windowRect);
screenWidthPx = RectWidth(windowRect);
leftPatchCenterX = xCenter - screenWidthPx / 4;
rightPatchCenterX = xCenter + screenWidthPx / 4;
gratingPatchDiameterPx = gratingPatchRadiusPx * 2;
leftGratingPatchRect = [leftPatchCenterX - gratingPatchRadiusPx, yCenter - gratingPatchRadiusPx, ...
                        leftPatchCenterX + gratingPatchRadiusPx, yCenter + gratingPatchRadiusPx];
rightGratingPatchRect = [rightPatchCenterX - gratingPatchRadiusPx, yCenter - gratingPatchRadiusPx, ...
                         rightPatchCenterX + gratingPatchRadiusPx, yCenter + gratingPatchRadiusPx];
leftDiscRect = [leftPatchCenterX - discRadiusPx, yCenter - discRadiusPx, ...
                leftPatchCenterX + discRadiusPx, yCenter + discRadiusPx];
rightDiscRect = [rightPatchCenterX - discRadiusPx, yCenter - discRadiusPx, ...
                 rightPatchCenterX + discRadiusPx, yCenter + discRadiusPx];

assert(discRadiusPx < gratingPatchRadiusPx, 'discRadiusPx must be smaller than gratingPatchRadiusPx.');
assert(leftGratingPatchRect(1) >= windowRect(1) && rightGratingPatchRect(3) <= windowRect(3), ...
    'The bilateral patches do not fit horizontally. Reduce gratingPatchRadiusPx.');
assert(leftGratingPatchRect(2) >= windowRect(2) && leftGratingPatchRect(4) <= windowRect(4), ...
    'The bilateral patches do not fit vertically. Reduce gratingPatchRadiusPx.');
assert(leftGratingPatchRect(3) < rightGratingPatchRect(1), ...
    'The bilateral patches overlap. Reduce gratingPatchRadiusPx.');

apertureMaskTexture = createCircularApertureMask(window, gratingPatchDiameterPx, gratingPatchRadiusPx, grey, apertureEdgeSoftnessPx);

Screen('FillRect', window, grey);
Screen('Flip', window);
WaitSecs(1);

Screen('Flip', window);

interFrameInterval = Screen('GetFlipInterval', window);
topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

% Frame-based timing
trialFrames = max(1, round(trialDurationSec / interFrameInterval));
cueFrames = max(1, round(cueDurationSec / interFrameInterval));
itiFrames = max(1, round(itiDurationSec / interFrameInterval));
itiResponseDeadlineFrames = max(1, round(itiResponseDeadlineSec / interFrameInterval));
feedbackFrames = max(1, round(itiFeedbackDurationSec / interFrameInterval));
letterFrames = max(1, round(letterDurationSec / interFrameInterval));
numLettersPerTrial = max(1, floor(trialFrames / letterFrames));

%% Block Loop
runBlockLoop = true;
trialNumber = 1;
accuracyByTrial = nan(1, trialNumberPerBlock);
rtByTrial = nan(1, trialNumberPerBlock);
eyeTrackingStopped = testing || ~eyeTracking;

% Balance cue sides within a block (one side has one extra trial if odd).
isLeftTrialByTrial = repmat([true false], 1, ceil(trialNumberPerBlock / 2));
isLeftTrialByTrial = isLeftTrialByTrial(1:trialNumberPerBlock);
isLeftTrialByTrial = isLeftTrialByTrial(randperm(trialNumberPerBlock));

try
    %% Instructions screen (once, before the block starts)
    instructionsText = sprintf([ ...
        'INSTRUCTIONS\n\n' ...
        'Two patches will flicker at the same time, each with its own letters.\n' ...
        'Before each trial, an arrow will cue the LEFT or RIGHT patch.\n\n' ...
        'Keep looking at the central fixation cross and silently count how many\n' ...
        'times X appears in the CUED patch during the %d-second stream.\n\n' ...
        'When the patches disappear, report whether the cued X count was ODD or EVEN:\n' ...
        'LEFT button/arrow = Odd          RIGHT button/arrow = Even\n\n' ...
        'You will then see whether you were Correct or Incorrect.\n\n' ...
        'Press any key or button to begin'], round(trialDurationSec));

    Screen('FillRect', window, grey);
    Screen('TextSize', window, instructionsTextSize);
    DrawFormattedText(window, instructionsText, 'center', 'center', black);

    vbl = Screen('Flip', window);
    KbWait(-1);

    while runBlockLoop && trialNumber <= trialNumberPerBlock
        if ~testing && eyeTracking
            calllib('iViewXAPI', 'iV_StartRecording');
        end

        %% Trial setup
        [leftTrialLetters, leftXCount] = generateLetterSequence(numLettersPerTrial, letterPool, xCountMin, xCountMax);
        [rightTrialLetters, rightXCount] = generateLetterSequence(numLettersPerTrial, letterPool, xCountMin, xCountMax);
        isLeftTrial = isLeftTrialByTrial(trialNumber);
        if isLeftTrial
            cueSide = 'left';
            trialStartTrigger = 20;
            cuedXCount = leftXCount;
        else
            cueSide = 'right';
            trialStartTrigger = 21;
            cuedXCount = rightXCount;
        end
        if mod(cuedXCount, 2) == 0
            correctResponse = 'even';
        else
            correctResponse = 'odd';
        end

        trialStartTime = NaN;

        % Dropped-frame log for this trial (see droppedFrameCsvFile above)
        droppedFrameCount = 0;
        droppedFrameNumber = [];
        droppedFrameVblTime = [];
        droppedFrameMissedBySec = [];

        disp(trialNumber);

        %% Pre-trial spatial cue
        for currentFrame = 1:cueFrames
            Screen('FillRect', window, grey);
            drawCueArrow(window, xCenter, yCenter, isLeftTrial, black, ...
                cueArrowLengthPx, cueArrowHeadPx, cueArrowLineWidthPx);
            if ~testing
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                vbl = Screen('Flip', window);
            end
            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end
        if ~runBlockLoop
            break;
        end

        %% Bilateral SSVEP gratings + independent letter streams
        Screen('TextSize', window, letterTextSize);
        trialSsvepT0 = vbl;

        for currentFrame = 1:trialFrames
            letterIndex = min(numLettersPerTrial, floor((currentFrame - 1) / letterFrames) + 1);
            currentLeftLetter = leftTrialLetters(letterIndex);
            currentRightLetter = rightTrialLetters(letterIndex);

            % Predicted display time for this frame, from the last real
            % flip timestamp, not currentFrame*interFrameInterval - a
            % dropped frame costs one bounded phase correction here rather
            % than a permanent, growing frequency error (see
            % computeGratingColors.m / gameNFv3.m's
            % computeSsvepColorsFromTime.m for the full rationale).
            ssvepTPredicted = (vbl - trialSsvepT0) + interFrameInterval;
            [leftBarColorA, leftBarColorB] = computeGratingColors(ssvepTPredicted, leftGratingFreqHz, gratingMidColor, gratingBarHigh, gratingBarLow);
            [rightBarColorA, rightBarColorB] = computeGratingColors(ssvepTPredicted, rightGratingFreqHz, gratingMidColor, gratingBarHigh, gratingBarLow);

            % Same t and same frequency as the grating above, so the
            % letter's contrast flickers in exact phase with it.
            leftContrastEnvelope = 0.5 + 0.5 * sin(2 * pi * leftGratingFreqHz * ssvepTPredicted);
            rightContrastEnvelope = 0.5 + 0.5 * sin(2 * pi * rightGratingFreqHz * ssvepTPredicted);
            leftLetterColor = discColor + leftContrastEnvelope * (letterColorPeak - discColor);
            rightLetterColor = discColor + rightContrastEnvelope * (letterColorPeak - discColor);

            Screen('FillRect', window, grey);
            drawFlickerGrating(window, leftGratingPatchRect, leftBarColorA, leftBarColorB, gratingBarWidthPx);
            drawFlickerGrating(window, rightGratingPatchRect, rightBarColorA, rightBarColorB, gratingBarWidthPx);
            Screen('DrawTexture', window, apertureMaskTexture, [], leftGratingPatchRect);
            Screen('DrawTexture', window, apertureMaskTexture, [], rightGratingPatchRect);
            Screen('FillOval', window, discColor, leftDiscRect);
            Screen('FillOval', window, discColor, rightDiscRect);
            DrawFormattedText(window, currentLeftLetter, 'center', 'center', leftLetterColor, [], [], [], [], [], leftDiscRect);
            DrawFormattedText(window, currentRightLetter, 'center', 'center', rightLetterColor, [], [], [], [], [], rightDiscRect);
            Screen('DrawLines', window, [-fixationHalfSizePx fixationHalfSizePx 0 0; ...
                0 0 -fixationHalfSizePx fixationHalfSizePx], fixationLineWidthPx, black, [xCenter yCenter]);

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

            if currentFrame == 1
                % Sent right after the flip that actually put the first
                % stimulus frame on screen, not before - see gameBreakoutv2.m.
                trialStartTime = getElapsedTime(experimentStartTime);
                if isLeftTrial
                    bci_send_triggers('trialstart_left');
                else
                    bci_send_triggers('trialstart_right');
                end
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end

        bci_send_triggers('trialstop');
        if ~runBlockLoop
            break;
        end

        %% ITI: blank (no SSVEP), response collection, feedback - always itiDurationSec long
        itiResponseOnsetTime = GetSecs;

        validResponse = false;
        participantResponse = 'missed';
        reactionTime = NaN;
        responseTimeout = 0;
        accuracy = 0;
        inFeedback = false;
        feedbackFramesRemaining = 0;

        Screen('TextSize', window, feedbackTextSize);
        for currentFrame = 1:itiFrames
            Screen('FillRect', window, grey);
            if inFeedback
                DrawFormattedText(window, feedbackString, 'center', 'center', feedbackColor);
            end

            if ~testing
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                vbl = Screen('Flip', window);
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end

            if inFeedback
                feedbackFramesRemaining = feedbackFramesRemaining - 1;
                if feedbackFramesRemaining <= 0
                    inFeedback = false; % feedback shown; stay blank for the rest of the fixed-length ITI
                end
            elseif ~validResponse
                [validResponse, participantResponse, reactionTime] = getEvenOddResponse( ...
                    true, [], oddKey, evenKey, itiResponseOnsetTime);

                if validResponse
                    accuracy = strcmp(participantResponse, correctResponse);
                    bci_send_triggers('response');
                    if accuracy
                        feedbackString = 'Correct';
                        feedbackColor = green;
                    else
                        feedbackString = 'Incorrect';
                        feedbackColor = red;
                    end
                    inFeedback = true;
                    feedbackFramesRemaining = feedbackFrames;
                elseif currentFrame >= itiResponseDeadlineFrames
                    responseTimeout = 1;
                    feedbackString = 'Missed';
                    feedbackColor = red;
                    inFeedback = true;
                    feedbackFramesRemaining = feedbackFrames;
                end
            end
        end
        if ~runBlockLoop
            break;
        end

        %% Log trial
        trialEndTime = getElapsedTime(experimentStartTime);
        accuracyByTrial(trialNumber) = accuracy;
        rtByTrial(trialNumber) = reactionTime;

        fid = fopen(csvFile, 'a');
        fprintf(fid, '%d,%s,%d,%.6f,%s,%s,%d,%d,%d,%d,%s,%s,%d,%.6f,%d,%.6f,%d\n', ...
            trialNumber, cueSide, trialStartTrigger, trialStartTime, leftTrialLetters, rightTrialLetters, ...
            numLettersPerTrial, leftXCount, rightXCount, cuedXCount, correctResponse, participantResponse, ...
            accuracy, reactionTime, responseTimeout, trialEndTime, droppedFrameCount);
        fclose(fid);

        fid = fopen(droppedFrameCsvFile, 'a');
        for r = 1:numel(droppedFrameNumber)
            fprintf(fid, '%d,%d,%.6f,%.6f\n', ...
                trialNumber, droppedFrameNumber(r), droppedFrameVblTime(r), droppedFrameMissedBySec(r));
        end
        fclose(fid);

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
    bci_send_triggers('trialstop');
    cleanupExperiment(testing, eyeTrackingStopped, participantInfo, blockInfo, []);
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

    if keyIsDown && keyCode(escapeKey)
        waitForEscape = false;
    end
    WaitSecs(0.01);
end

cleanupExperiment(testing, eyeTrackingStopped, participantInfo, blockInfo, []);

%% Trigger values sent by this task
% Values are defined in functions/bci_send_triggers.m and sent by UDP.
% reset      -> 0
% trialstart_left  -> 20  (first bilateral SSVEP frame of a left-cued trial)
% trialstart_right -> 21  (first bilateral SSVEP frame of a right-cued trial)
% response   -> 40  (sent when a valid odd/even response is detected during the ITI)
% trialstop  -> 30  (sent right after the SSVEP/letter stream's last frame)
