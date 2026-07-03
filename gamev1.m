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
csvFile = fullfile(csvBaseDir, sprintf('%s_newtask_trialdata.csv', sessionTag));
csvHeader = ['TrialNumber,Condition,TrialStart,FixationOnset,TextOnset,StimOnset,NFOnset,' ...
    'ResponseOnset,FeedbackOnset,TrialEnd,NFMean,NFSuccess,CorrectResponse,' ...
    'ParticipantResponse,Accuracy,ReactionTime,ResponseTimeout'];
if ~exist(csvFile, 'file')
    fid = fopen(csvFile, 'w');
    fprintf(fid, '%s\n', csvHeader);
    fclose(fid);
else
    fid = fopen(csvFile, 'r');
    existingCsvHeader = fgetl(fid);
    fclose(fid);
    if ~ischar(existingCsvHeader) || ~strcmp(strtrim(existingCsvHeader), csvHeader)
        csvFile = fullfile(csvBaseDir, sprintf('%s_newtask_trialdata_%s.csv', sessionTag, datestr(now, 'yyyymmdd_HHMMSS')));
        fid = fopen(csvFile, 'w');
        fprintf(fid, '%s\n', csvHeader);
        fclose(fid);
        fprintf('Existing CSV header did not match. Writing this run to %s\n', csvFile);
    end
end
% postions on the screen
% 255 pix = 6.7 deg eccentricity
% 225 pix = 5.9245 deg eccenricity, subDispix = 2.168215718584939e+03

% Cedrus:   Up button       = 1
%           Middle button   = 4
%           Down button     = 6

% Here we call some default settings for setting up Psychtoolbox
PsychDefaultSetup(2);
if ismac
    Screen('Preference', 'SkipSyncTests', 1);
end
% Screen('Preference', 'SuppressAllWarnings', 1);
% Screen('Preference', 'Verbosity', 0);  % Set to 0 for complete silence on shader compilation

% Unify key names across different operating systems
KbName('UnifyKeyNames');

% Paraport setup for neurofeedback
if ~ismac
    paraport = serial('COM9','BaudRate',115200,'DataBits',8, 'StopBits', 1, 'Parity', 'none'); %#ok<SERIAL>
    get(paraport);
    fopen(paraport);
    cog_send_triggers(paraport,'reset');
end
if ~exist('paraport','var')
    paraport = [];
end

%% PARAMETERS
% Key mappings
escapeKey   = KbName('ESCAPE');
spaceKey    = KbName('space');
leftKey     = KbName('LeftArrow');
rightKey    = KbName('RightArrow');
upKey       = KbName('UpArrow');
downKey     = KbName('DownArrow');

% Experiment structure
trialNumberPerBlock = 12;
conditions = repmat({'A','B'}, 1, trialNumberPerBlock/2);
conditions = conditions(randperm(numel(conditions)));

% Timing in seconds, converted after measured refresh rate is known
fixationDurationSec = 0.500;
textDurationSec = 0.500;
stimDurationSec = 0.800;
nfDurationSec = 2.000;
responseTimeoutSec = 1.500;
feedbackDurationSec = 0.500;
itiDurationSec = 0.500;

% Visual parameters
dotBaseDiameter = 10;
dotBaseColor = [255 0 0];
stimulusRadius = 80;
nfBarWidth = 30;
nfBarHeight = 300;
nfThreshold = 0.50;

% Trigger values for task-specific events. Named core triggers are still
% sent with cog_send_triggers.
trigFixationOnset = 11;
trigTextOnset = 12;
trigStimOnset = 13;
trigNFOnset = 14;
trigResponseWindow = 15;
trigFeedbackOnset = 16;
trigTimeout = 17;

% Neurofeedback input. Expected format: doubles in nf.txt. If the file is
% empty/missing, the scaffold uses 0 so the task can still run.
pathToNF = fullfile(experimentRoot, 'nf.txt');

%% Initialise the screen
screens = Screen('Screens');
screenNumber = max(screens);

grey = [128 128 128];
black = [0 0 0];
white = [255 255 255];
green = [0 255 0];
red = [255 0 0];
blue = [0 80 255];

if ~ismac && eyeTracking
    EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
end

[window,windowRect]=Screen('OpenWindow', screenNumber, grey,[], [], [], [], [], [], kPsychGUIWindow);
Screen('ColorRange', window, 255);
Screen('TextSize', window, 40);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

[xCenter, yCenter] = RectCenter(windowRect);
dotRadius = dotBaseDiameter / 2;
dotRect = [xCenter - dotRadius, yCenter - dotRadius, xCenter + dotRadius, yCenter + dotRadius];

Screen('FillRect', window, grey);
Screen('FillOval', window, dotBaseColor, dotRect);
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
fixationFrames = max(1, round(fixationDurationSec / interFrameInterval));
textFrames = max(1, round(textDurationSec / interFrameInterval));
stimFrames = max(1, round(stimDurationSec / interFrameInterval));
nfFrames = max(1, round(nfDurationSec / interFrameInterval));
responseTimeoutFrames = max(1, round(responseTimeoutSec / interFrameInterval));
feedbackFrames = max(1, round(feedbackDurationSec / interFrameInterval));
itiFrames = max(1, round(itiDurationSec / interFrameInterval));

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
        condition = conditions{trialNumber};
        if strcmp(condition, 'A')
            correctResponse = 'left';
            stimColor = blue;
        else
            correctResponse = 'right';
            stimColor = white;
        end

        participantResponse = 'missed';
        reactionTime = NaN;
        accuracy = 0;
        responseTimeout = 1;
        nfValues = nan(1, nfFrames);
        nfSuccess = 0;

        trialStartTime = getElapsedTime(experimentStartTime);
        fixationOnsetTime = NaN;
        textOnsetTime = NaN;
        stimOnsetTime = NaN;
        nfOnsetTime = NaN;
        responseOnsetTime = NaN;
        feedbackOnsetTime = NaN;
        trialStopSent = false;

        disp(trialNumber);
        if ~ismac
            cog_send_triggers(paraport, 'trialstart');
        end

        %% Fixation
        for currentFrame = 1:fixationFrames
            Screen('FillRect', window, grey);
            Screen('FillOval', window, dotBaseColor, dotRect);

            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                if currentFrame == 1
                    fixationOnsetTime = getElapsedTime(experimentStartTime);
                    sendNumericTrigger(paraport, trigFixationOnset);
                end
            else
                Screen('Flip', window);
                if currentFrame == 1
                    fixationOnsetTime = getElapsedTime(experimentStartTime);
                end
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end
        if ~runBlockLoop
            if ~ismac && ~trialStopSent
                cog_send_triggers(paraport, 'trialstop');
                trialStopSent = true;
            end
            break;
        end

        %% Text
        for currentFrame = 1:textFrames
            Screen('FillRect', window, grey);
            Screen('TextSize', window, 48);
            DrawFormattedText(window, 'TEST', 'center', 'center', black);
            Screen('FillOval', window, dotBaseColor, dotRect);

            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                if currentFrame == 1
                    textOnsetTime = getElapsedTime(experimentStartTime);
                    sendNumericTrigger(paraport, trigTextOnset);
                end
            else
                Screen('Flip', window);
                if currentFrame == 1
                    textOnsetTime = getElapsedTime(experimentStartTime);
                end
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end
        if ~runBlockLoop
            if ~ismac && ~trialStopSent
                cog_send_triggers(paraport, 'trialstop');
                trialStopSent = true;
            end
            break;
        end

        %% Stimulus
        stimulusRect = CenterRectOnPoint([0 0 stimulusRadius*2 stimulusRadius*2], xCenter, yCenter);
        for currentFrame = 1:stimFrames
            Screen('FillRect', window, grey);
            Screen('FillOval', window, stimColor, stimulusRect);
            Screen('FillOval', window, dotBaseColor, dotRect);

            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                if currentFrame == 1
                    stimOnsetTime = getElapsedTime(experimentStartTime);
                    sendNumericTrigger(paraport, trigStimOnset);
                end
            else
                Screen('Flip', window);
                if currentFrame == 1
                    stimOnsetTime = getElapsedTime(experimentStartTime);
                end
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end
        if ~runBlockLoop
            if ~ismac && ~trialStopSent
                cog_send_triggers(paraport, 'trialstop');
                trialStopSent = true;
            end
            break;
        end

        %% Neurofeedback
        for currentFrame = 1:nfFrames
            NF = readNFValue(pathToNF);
            nfValues(currentFrame) = NF;
            nfDisplay = min(max(NF, 0), 1);
            nfSuccess = nanMean(nfValues(1:currentFrame)) >= nfThreshold;

            nfBaseRect = CenterRectOnPoint([0 0 nfBarWidth nfBarHeight], xCenter, yCenter);
            nfFillHeight = nfBarHeight * nfDisplay;
            nfFillRect = [nfBaseRect(1), nfBaseRect(4) - nfFillHeight, nfBaseRect(3), nfBaseRect(4)];
            nfThresholdY = nfBaseRect(4) - nfBarHeight * nfThreshold;

            Screen('FillRect', window, grey);
            Screen('FrameRect', window, black, nfBaseRect, 3);
            Screen('FillRect', window, green, nfFillRect);
            Screen('DrawLine', window, red, nfBaseRect(1) - 20, nfThresholdY, nfBaseRect(3) + 20, nfThresholdY, 3);
            Screen('FillOval', window, dotBaseColor, dotRect);

            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                if currentFrame == 1
                    nfOnsetTime = getElapsedTime(experimentStartTime);
                    sendNumericTrigger(paraport, trigNFOnset);
                end
            else
                Screen('Flip', window);
                if currentFrame == 1
                    nfOnsetTime = getElapsedTime(experimentStartTime);
                end
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end
        if ~runBlockLoop
            if ~ismac && ~trialStopSent
                cog_send_triggers(paraport, 'trialstop');
                trialStopSent = true;
            end
            break;
        end

        %% Response
        if ~ismac
            cedrus.resettimer();
        end

        for currentFrame = 1:responseTimeoutFrames
            Screen('FillRect', window, grey);
            Screen('TextSize', window, 32);
            DrawFormattedText(window, 'Respond', 'center', yCenter - 80, black);
            Screen('FillOval', window, dotBaseColor, dotRect);

            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                if currentFrame == 1
                    responseOnsetTime = getElapsedTime(experimentStartTime);
                    cedrus.resettimer();
                    sendNumericTrigger(paraport, trigResponseWindow);
                end
            else
                Screen('Flip', window);
                if currentFrame == 1
                    responseOnsetTime = getElapsedTime(experimentStartTime);
                end
            end

            if ~ismac
                [validResponse, participantResponse, reactionTime] = getParticipantResponse( ...
                    false, cedrus, leftKey, rightKey, upKey, downKey, spaceKey, responseOnsetTime);
            else
                [validResponse, participantResponse, reactionTime] = getParticipantResponse( ...
                    true, [], leftKey, rightKey, upKey, downKey, spaceKey, responseOnsetTime);
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end

            if validResponse
                responseTimeout = 0;
                accuracy = strcmp(participantResponse, correctResponse);
                if ~ismac
                    cog_send_triggers(paraport, 'response');
                end
                break;
            end
        end
        if ~runBlockLoop
            if ~ismac && ~trialStopSent
                cog_send_triggers(paraport, 'trialstop');
                trialStopSent = true;
            end
            break;
        end

        if responseTimeout && ~ismac
            sendNumericTrigger(paraport, trigTimeout);
        end

        %% Feedback
        if accuracy
            feedbackString = 'CORRECT';
            feedbackColor = green;
        elseif responseTimeout
            feedbackString = 'TOO SLOW';
            feedbackColor = red;
        else
            feedbackString = 'INCORRECT';
            feedbackColor = red;
        end

        for currentFrame = 1:feedbackFrames
            Screen('FillRect', window, grey);
            Screen('TextSize', window, 48);
            DrawFormattedText(window, feedbackString, 'center', 'center', feedbackColor);
            Screen('FillOval', window, dotBaseColor, dotRect);

            if ~ismac
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                if currentFrame == 1
                    feedbackOnsetTime = getElapsedTime(experimentStartTime);
                    sendNumericTrigger(paraport, trigFeedbackOnset);
                end
            else
                Screen('Flip', window);
                if currentFrame == 1
                    feedbackOnsetTime = getElapsedTime(experimentStartTime);
                end
            end
        end

        if ~ismac
            if nfSuccess && accuracy
                cog_send_triggers(paraport, 'success');
            else
                cog_send_triggers(paraport, 'failure');
            end
            cog_send_triggers(paraport, 'trialstop');
            trialStopSent = true;
        end

        %% Log trial
        trialEndTime = getElapsedTime(experimentStartTime);
        nfMean = nanMean(nfValues);
        accuracyByTrial(trialNumber) = accuracy;
        rtByTrial(trialNumber) = reactionTime;

        fid = fopen(csvFile, 'a');
        fprintf(fid, '%d,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%s,%s,%d,%.6f,%d\n', ...
            trialNumber, condition, trialStartTime, fixationOnsetTime, textOnsetTime, stimOnsetTime, nfOnsetTime, ...
            responseOnsetTime, feedbackOnsetTime, trialEndTime, nfMean, nfSuccess, correctResponse, ...
            participantResponse, accuracy, reactionTime, responseTimeout);
        fclose(fid);

        %% ITI
        for currentFrame = 1:itiFrames
            Screen('FillRect', window, grey);
            Screen('FillOval', window, dotBaseColor, dotRect);
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
    vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval); %#ok<NASGU>
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

