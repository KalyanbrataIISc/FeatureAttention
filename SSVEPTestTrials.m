%% SSVEP Test Trials
% A minimal SSVEP task: a circular black/white grating patch flickers
% sinusoidally in contrast at the screen center. A small white disc at its
% center shows a stream of letters, one at a time, changing every
% letterDurationSec; the letter's contrast flickers in exact phase with the
% grating (same frequency, same time base). The participant silently counts
% how many times 'X' appears during the trialDurationSec stream, then
% reports odd/even via Cedrus during the following fixed-length ITI (no
% SSVEP on screen during the ITI). No neurofeedback, no cue, no directions -
% see README.md for how this differs from the leaves task (gamev1.m /
% gameNFv3.m), which this script's setup/Cedrus/trigger scaffolding follows.

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
csvHeader = ['TrialNumber,TrialStart,LetterSequence,NumLetters,XCount,CorrectResponse,' ...
    'ParticipantResponse,Accuracy,ReactionTime,ResponseTimeout,TrialEnd,DroppedFrameCount'];
csvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_ssveptest_trialdata.csv', sessionTag), csvHeader);

% Dropped/delayed-frame log, same rationale and shape as gameNFv3.m's: one
% row per frame during the SSVEP stream whose Screen('Flip') missed its
% requested presentation deadline (only meaningful with real vsync timing,
% so only tracked on ~ismac).
droppedFrameCsvHeader = 'TrialNumber,FrameNumber,VBLTime,MissedBySec';
droppedFrameCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_ssveptest_droppedframes.csv', sessionTag), droppedFrameCsvHeader);

% Cedrus:   Up button       = 1 (unused)
%           Right button    = 5 (Even)
%           Middle button   = 4 (unused)
%           Left button     = 3 (Odd)
%           Down button     = 6 (unused)

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
escapeKey = KbName('ESCAPE');
oddKey    = KbName('LeftArrow');  % Odd  (matches Cedrus Left=3)
evenKey   = KbName('RightArrow'); % Even (matches Cedrus Right=5)

% Experiment structure
trialNumberPerBlock = 20;

% Timing (seconds)
trialDurationSec       = 10.000; % SSVEP grating + letter stream duration
itiDurationSec         = 10.000; % total ITI - always exactly this long, regardless of RT
itiFeedbackDurationSec = 1.000;  % how long 'Correct'/'Incorrect'/'Missed' is shown, inside the ITI
% The response window inside the ITI ends this long before the ITI itself
% does, so there's always exactly itiFeedbackDurationSec left to show
% feedback before the fixed-length ITI runs out.
itiResponseDeadlineSec = itiDurationSec - itiFeedbackDurationSec;

% Letter stream (shown one at a time inside the center disc)
letterDurationSec = 0.800; % how long each letter is shown before switching
letterPool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; % must include 'X'
xCountMin = 2; % lower bound on how many X's appear per trial
xCountMax = 5; % upper bound (both randomized per trial via ssvepTestHelperFunctions/generateLetterSequence.m)

% SSVEP grating patch (centered on screen; black/white vertical-bar
% grating whose CONTRAST flickers sinusoidally between grey (0 contrast,
% pattern invisible) and full black/white, via
% breakoutHelperFunctions/computeGratingColors.m - same formula as
% gameBreakoutv2.m's paddle gratings. The patch is clipped to a circle by
% a one-time aperture mask texture (see createCircularApertureMask.m
% below), not by a texture rebuilt every frame.
gratingFreqHz         = 20;   % contrast-flicker frequency (Hz)
gratingPatchRadiusPx  = 300;  % radius of the circular grating patch
gratingBarWidthPx     = 20;   % width of each grating bar
gratingMidColor       = grey; % contrast trough - must match the background so the patch vanishes, not just dims
gratingBarHigh        = white;
gratingBarLow         = black;
apertureEdgeSoftnessPx = 2;   % width of the mask's alpha ramp at the circle edge, to avoid a hard-aliased boundary

% Center disc + letter. The letter's contrast flickers from discColor
% (invisible against the disc) up to letterColorPeak, driven by the exact
% same time base and frequency as the grating above - see the trial loop,
% where both are computed from the same ssvepTPredicted/gratingFreqHz.
discRadiusPx    = 45;    % must stay smaller than gratingPatchRadiusPx
discColor       = white;
letterColorPeak = black;
letterTextSize  = 48;

% Feedback ('Correct' / 'Incorrect' / 'Missed'), shown during the ITI
feedbackTextSize = 40;

% Instructions screen (shown once, before the block starts)
instructionsTextSize = 26;

%% Initialise the screen
screens = Screen('Screens');
screenNumber = max(screens);

if ~ismac && eyeTracking
    EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
end

[window,windowRect]=Screen('OpenWindow', screenNumber, grey,[], [], [], [], [], [], kPsychGUIWindow);
Screen('ColorRange', window, 255);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

[xCenter, yCenter] = RectCenter(windowRect);
gratingPatchDiameterPx = gratingPatchRadiusPx * 2;
gratingPatchRect = [xCenter - gratingPatchRadiusPx, yCenter - gratingPatchRadiusPx, ...
                     xCenter + gratingPatchRadiusPx, yCenter + gratingPatchRadiusPx];
discRect = [xCenter - discRadiusPx, yCenter - discRadiusPx, ...
            xCenter + discRadiusPx, yCenter + discRadiusPx];

assert(discRadiusPx < gratingPatchRadiusPx, 'discRadiusPx must be smaller than gratingPatchRadiusPx.');

apertureMaskTexture = createCircularApertureMask(window, gratingPatchDiameterPx, gratingPatchRadiusPx, grey, apertureEdgeSoftnessPx);

Screen('FillRect', window, grey);
Screen('Flip', window);
WaitSecs(1);

% vbl is captured here because the SSVEP phase below is driven from real
% flip timestamps, not a frame counter - see computeGratingColors.m /
% gameNFv3.m's computeSsvepColorsFromTime.m for why.
vbl = Screen('Flip', window);

interFrameInterval = Screen('GetFlipInterval', window);
topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

% Frame-based timing
trialFrames = max(1, round(trialDurationSec / interFrameInterval));
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
eyeTrackingStopped = ismac || ~eyeTracking;

try
    %% Instructions screen (once, before the block starts)
    instructionsText = sprintf([ ...
        'INSTRUCTIONS\n\n' ...
        'Watch the flickering patch at the center of the screen. A letter will\n' ...
        'appear inside the white disc and keep changing for %d seconds.\n\n' ...
        'Silently count how many times the letter X appears.\n\n' ...
        'When the patch disappears, report whether your X count was ODD or EVEN:\n' ...
        'LEFT button/arrow = Odd          RIGHT button/arrow = Even\n\n' ...
        'You will then see whether you were Correct or Incorrect.\n\n' ...
        'Press any key or button to begin'], round(trialDurationSec));

    Screen('FillRect', window, grey);
    Screen('TextSize', window, instructionsTextSize);
    DrawFormattedText(window, instructionsText, 'center', 'center', black);

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
        [trialLetters, xCount] = generateLetterSequence(numLettersPerTrial, letterPool, xCountMin, xCountMax);
        if mod(xCount, 2) == 0
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

        %% SSVEP grating + letter stream
        Screen('TextSize', window, letterTextSize);
        trialSsvepT0 = vbl;

        for currentFrame = 1:trialFrames
            letterIndex = min(numLettersPerTrial, floor((currentFrame - 1) / letterFrames) + 1);
            currentLetter = trialLetters(letterIndex);

            % Predicted display time for this frame, from the last real
            % flip timestamp, not currentFrame*interFrameInterval - a
            % dropped frame costs one bounded phase correction here rather
            % than a permanent, growing frequency error (see
            % computeGratingColors.m / gameNFv3.m's
            % computeSsvepColorsFromTime.m for the full rationale).
            ssvepTPredicted = (vbl - trialSsvepT0) + interFrameInterval;
            [barColorA, barColorB] = computeGratingColors(ssvepTPredicted, gratingFreqHz, gratingMidColor, gratingBarHigh, gratingBarLow);

            % Same t and same frequency as the grating above, so the
            % letter's contrast flickers in exact phase with it.
            contrastEnvelope = 0.5 + 0.5 * sin(2 * pi * gratingFreqHz * ssvepTPredicted);
            letterColor = discColor + contrastEnvelope * (letterColorPeak - discColor);

            Screen('FillRect', window, grey);
            drawFlickerGrating(window, gratingPatchRect, barColorA, barColorB, gratingBarWidthPx);
            Screen('DrawTexture', window, apertureMaskTexture, [], gratingPatchRect);
            Screen('FillOval', window, discColor, discRect);
            DrawFormattedText(window, currentLetter, 'center', 'center', letterColor, [], [], [], [], [], discRect);

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

            if currentFrame == 1
                % Sent right after the flip that actually put the first
                % stimulus frame on screen, not before - see gameBreakoutv2.m.
                trialStartTime = getElapsedTime(experimentStartTime);
                if ~ismac
                    cog_send_triggers(paraport, 'trialstart');
                end
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end

        if ~ismac
            cog_send_triggers(paraport, 'trialstop');
        end
        if ~runBlockLoop
            break;
        end

        %% ITI: blank (no SSVEP), response collection, feedback - always itiDurationSec long
        if ~ismac
            % Discards any stray Cedrus presses queued during the SSVEP
            % stream and zeroes the RT timer, so the response window's RT
            % is measured from ITI onset, not contaminated by earlier events.
            cedrus.resettimer();
        end
        itiResponseOnsetTime = getElapsedTime(experimentStartTime);

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

            if ~ismac
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
                if ~ismac
                    [validResponse, participantResponse, reactionTime] = getEvenOddResponse( ...
                        false, cedrus, oddKey, evenKey, itiResponseOnsetTime);
                else
                    [validResponse, participantResponse, reactionTime] = getEvenOddResponse( ...
                        true, [], oddKey, evenKey, itiResponseOnsetTime);
                end

                if validResponse
                    accuracy = strcmp(participantResponse, correctResponse);
                    if ~ismac
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
        fprintf(fid, '%d,%.6f,%s,%d,%d,%s,%s,%d,%.6f,%d,%.6f,%d\n', ...
            trialNumber, trialStartTime, trialLetters, numLettersPerTrial, xCount, correctResponse, ...
            participantResponse, accuracy, reactionTime, responseTimeout, trialEndTime, droppedFrameCount);
        fclose(fid);

        fid = fopen(droppedFrameCsvFile, 'a');
        for r = 1:numel(droppedFrameNumber)
            fprintf(fid, '%d,%d,%.6f,%.6f\n', ...
                trialNumber, droppedFrameNumber(r), droppedFrameVblTime(r), droppedFrameMissedBySec(r));
        end
        fclose(fid);

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
% Values are defined in functions/cog_send_triggers.m (same subset gamev1.m uses).
% reset      -> 0
% trialstart -> 20  (sent right after the flip that shows the first SSVEP/letter frame)
% response   -> 40  (sent when a valid odd/even response is detected during the ITI)
% trialstop  -> 30  (sent right after the SSVEP/letter stream's last frame)
