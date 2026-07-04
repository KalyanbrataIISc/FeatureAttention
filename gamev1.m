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
csvFile = fullfile(csvBaseDir, sprintf('%s_leaves_trialdata.csv', sessionTag));
csvHeader = ['TrialNumber,TrialStart,C1PointDir,C1MoveDir,C2PointDir,C2MoveDir,Cue,CueOnsetTime,' ...
    'CorrectResponse,ParticipantResponse,Accuracy,ReactionTime,ResponseTimeout,TrialEnd'];
if ~exist(csvFile, 'file')
    fid = fopen(csvFile, 'w');
    fprintf(fid, '%s\n', csvHeader);
    fclose(fid);
else
    fid = fopen(csvFile, 'r');
    existingCsvHeader = fgetl(fid);
    fclose(fid);
    if ~ischar(existingCsvHeader) || ~strcmp(strtrim(existingCsvHeader), csvHeader)
        csvFile = fullfile(csvBaseDir, sprintf('%s_leaves_trialdata_%s.csv', sessionTag, datestr(now, 'yyyymmdd_HHMMSS')));
        fid = fopen(csvFile, 'w');
        fprintf(fid, '%s\n', csvHeader);
        fclose(fid);
        fprintf('Existing CSV header did not match. Writing this run to %s\n', csvFile);
    end
end

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
escapeKey = KbName('ESCAPE');
leftKey   = KbName('LeftArrow');
rightKey  = KbName('RightArrow');
upKey     = KbName('UpArrow');
downKey   = KbName('DownArrow');

% Experiment structure
trialNumberPerBlock = 20; % keep even so the c1/c2 cue can be balanced 50/50
directionSet = {'up', 'down', 'left', 'right'};
cueList = repmat({'c1', 'c2'}, 1, trialNumberPerBlock / 2);
cueList = cueList(randperm(numel(cueList)));

% Timing in seconds, converted to frames after the measured refresh rate is known
preCueConstantSec   = 1.000;  % fixed foreperiod before the hazard-uniform jitter
preCueExpMeanSec    = 3.000;  % mean of the exponential jitter added to the foreperiod
preCueExpMaxSec     = 10.000;  % truncation cap on the exponential jitter (keeps trials bounded)
responseTimeoutSec  = 4.000;  % response window, timed from cue onset
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
leafLifetimeSec       = 2.0; % how long a single leaf stays on screen before it respawns elsewhere
numLeavesPerFlock     = 20;  % density = numLeavesPerFlock / (screen area in px^2).
% Each leaf needs a minLeafSeparationPx clearance bubble around it, so the
% field can only physically fit so many before the placement algorithm
% can no longer find room and starts force-respawning leaves almost every
% frame (looks like leaves rapidly teleporting/flickering, regardless of
% leafSpeedPxPerSec - that's a packing problem, not a speed one). At this
% leaf size, a 1920x1080-ish field stays stable up to ~25/flock and
% starts thrashing past ~30/flock - raise gradually and watch for that
% symptom coming back.

% Cue rectangle (same object throughout the trial: neutral/black pre-cue,
% solid colorC1/colorC2 with 'Pointing'/'Moving' written inside from cue onset on)
cueRectWidthPx  = 220;
cueRectHeightPx = 90;
cueTextSize     = 32;
colorCueText    = black;

% Colors
colorC1        = [0 191 255];              % c1 flock/cue color (deep sky blue)
colorC2        = [255 140 0];              % c2 flock/cue color (dark orange)
colorPreCue    = (colorC1 + colorC2) / 2;  % leaf color before cue onset - the
% midpoint of colorC1/colorC2 so it never coincides with either flock's
% post-cue color, and (for two reasonably distinct, saturated colors)
% naturally falls away from pure black/white too, so the full black<->white
% SSVEP border swing stays visible throughout the whole trial.
colorBorderLow  = black;  % SSVEP flicker low-luminance border color
colorBorderHigh = white;  % SSVEP flicker high-luminance border color

% SSVEP tagging frequencies (Hz)
freqC1Hz = 14;
freqC2Hz = 18;

% Feedback text position (pixels above screen center)
feedbackYOffsetPx = 200;

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
feedbackY = yCenter - feedbackYOffsetPx;

Screen('FillRect', window, grey);
Screen('FillRect', window, black, cueRect);
Screen('Flip', window);
WaitSecs(1);

if ~ismac
    vbl = Screen('Flip', window);
end

interFrameInterval = Screen('GetFlipInterval', window);
refreshRate = 1 / interFrameInterval;
topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

% Frame-based timing
responseTimeoutFrames = max(1, round(responseTimeoutSec / interFrameInterval));
feedbackFrames = max(1, round(feedbackDurationSec / interFrameInterval));
itiFrames = max(1, round(itiDurationSec / interFrameInterval));
leafLifetimeFrames = max(1, round(leafLifetimeSec / interFrameInterval));

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
    Screen('TextSize',window, 28);
    DrawFormattedText(window,sprintf('Press Any Key To Begin'),'center','center',black);
    if ~ismac
        vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
        cedrus.waitpress(600);
    else
        Screen('Flip', window);
        KbWait(-1);
    end

    while runBlockLoop && trialNumber <= trialNumberPerBlock
        if ~ismac && eyeTracking
            calllib('iViewXAPI', 'iV_StartRecording');
        end

        %% Trial setup
        c1PointDir = directionSet{randi(4)};
        c1MoveDir  = directionSet{randi(4)};
        c2PointDir = directionSet{randi(4)};
        c2MoveDir  = directionSet{randi(4)};
        cue = cueList{trialNumber};

        if strcmp(cue, 'c1')
            correctResponse = c1PointDir;
        else
            correctResponse = c2MoveDir;
        end

        if strcmp(cue, 'c1')
            cueColor = colorC1;
            cueWord = 'Pointing';
        else
            cueColor = colorC2;
            cueWord = 'Moving';
        end

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
        % currentFrame also doubles as the SSVEP time base - it increments
        % every displayed frame from trial start onward, uninterrupted by
        % whichever phase it's currently in.
        cueDelaySec = preCueConstantSec + truncatedExpRnd(preCueExpMeanSec, preCueExpMaxSec);
        preCueFrames = max(1, round(cueDelaySec / interFrameInterval));
        cueOnsetFrame = preCueFrames + 1;
        responseDeadlineFrame = preCueFrames + responseTimeoutFrames;
        maxFrames = preCueFrames + responseTimeoutFrames + feedbackFrames;

        for currentFrame = 1:maxFrames
            isPreCue = currentFrame < cueOnsetFrame;

            leaves = updateLeaves(leaves, fieldRect, minLeafSeparationPx, leafLifetimeFrames);
            [flock1BorderColor, flock2BorderColor] = computeSsvepBorderColors( ...
                currentFrame, interFrameInterval, freqC1Hz, freqC2Hz, colorBorderLow, colorBorderHigh);

            Screen('FillRect', window, grey);
            if isPreCue
                drawLeaves(window, leaves, flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
                    colorPreCue, colorPreCue, flock1BorderColor, flock2BorderColor);
                Screen('FillRect', window, black, cueRect);
            else
                drawLeaves(window, leaves, flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
                    colorC1, colorC2, flock1BorderColor, flock2BorderColor);
                Screen('FillRect', window, cueColor, cueRect);
                Screen('TextSize', window, cueTextSize);
                DrawFormattedText(window, cueWord, 'center', 'center', colorCueText, [], [], [], [], [], cueRect);
            end
            if inFeedback
                Screen('TextSize', window, 48);
                DrawFormattedText(window, feedbackString, 'center', feedbackY, feedbackColor);
            end

            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                Screen('Flip', window);
            end

            if currentFrame == cueOnsetFrame
                cueOnsetTime = getElapsedTime(experimentStartTime);
                if ~ismac
                    cog_send_triggers(paraport, 'cueonset');
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
            elseif ~isPreCue
                if ~ismac
                    [validResponse, participantResponse, reactionTime] = getDirectionResponse( ...
                        false, cedrus, leftKey, rightKey, upKey, downKey, cueOnsetTime);
                else
                    [validResponse, participantResponse, reactionTime] = getDirectionResponse( ...
                        true, [], leftKey, rightKey, upKey, downKey, cueOnsetTime);
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
        fprintf(fid, '%d,%.6f,%s,%s,%s,%s,%s,%.6f,%s,%s,%d,%.6f,%d,%.6f\n', ...
            trialNumber, trialStartTime, c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, cue, cueOnsetTime, ...
            correctResponse, participantResponse, accuracy, reactionTime, responseTimeout, trialEndTime);
        fclose(fid);

        %% ITI
        for currentFrame = 1:itiFrames
            Screen('FillRect', window, grey);
            Screen('FillRect', window, black, cueRect);
            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                Screen('Flip', window);
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
