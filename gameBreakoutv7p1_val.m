% gameBreakoutv7p1_val  SSVEP-neurofeedback Breakout validation task.
% Validates the control formula by asking participants to move the paddle
% to a specific target region and hold it there for 2 seconds.
% Cued edge-reaching task.

%% Initialise
if ~ismac
    if exist('cedrus','var') && isstruct(cedrus) && isfield(cedrus, 'close')
        try
            cedrus.close();
        catch
        end
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

cedrusAvailable = false;
if ~ismac
    % Begining
    try
        cedrusopen;
        cedrusAvailable = true;
    catch ME
        warning('gameBreakoutv3_WL:cedrusFailed', 'Could not open Cedrus box: %s. Keyboard will be used instead.', ME.message);
        cedrusAvailable = false;
    end
end

%% Participant and block info
if ~ismac
    participantInfo = input('Enter your participant number: ', 's');
    startBlockInput = input('Enter your starting block number (e.g. 1): ', 's');
else
    participantInfo = '000'; % Test
    startBlockInput = '1';   % Test
end

startBlockNum = str2double(startBlockInput);
if isnan(startBlockNum) || startBlockNum < 1
    startBlockNum = 1;
end
blockInfo = sprintf('%02d', startBlockNum); % Initial block string for setup

% Initialize timer
experimentStartTime = GetSecs;

if ~ismac
    eyeTracking = input('Eyetracking (1 or 0)?');
else
    eyeTracking = 0;
end

%% Info for CSV logging
csvBaseDir = fullfile(experimentRoot, 'data');
if ~exist(csvBaseDir, 'dir'), mkdir(csvBaseDir); end

% Buffered CSV writing: logs are held in memory during the block to prevent frame drops
csvHeader = 'TrialNumber,TrialStart,TrialEnd,TrialDuration,TargetDistancePx,TargetSide,Success,Timeout,DroppedFrameCount';
traceCsvHeader = 'TrialNumber,FrameNumber,SampleTime,NF17,NF19,NFSigned,NFReadOk,PaddleCenterX,PaddleVxPxPerSec,TargetEdgeX';
droppedFrameCsvHeader = 'TrialNumber,FrameNumber,VBLTime,MissedBySec';

PsychDefaultSetup(2);
if ismac || ~cedrusAvailable
    Screen('Preference', 'SkipSyncTests', 1);
end

% Unify key names across different operating systems
KbName('UnifyKeyNames');

% Paraport setup for triggers
paraport = [];
if ~ismac
    try
        paraport = serial('COM9','BaudRate',115200,'DataBits',8, 'StopBits', 1, 'Parity', 'none'); %#ok<SERIAL>
        get(paraport);
        fopen(paraport);
        cog_send_triggers(paraport, 'reset');   % reset line
    catch ME
        warning('gameBreakoutv7p1_val:paraportFailed', 'Could not open parallel port COM9: %s. Triggers will not be sent.', ME.message);
        paraport = [];
    end
end

%% Display colors
black      = [0   0   0  ];
white      = [255 255 255 ];
grey       = [128 128 128 ];
bgColor    = [10  12  20  ];
cyanMid    = [30  30  60  ];
cyanBorder = [0   180 220 ];
targetColor= [150 150 150 ]; % Gray for target outline
successCol = [0   255 0   ];
failCol    = [255 0   0   ];
hudColor   = [220 220 255 ];
readyColor = [0   255 200 ];

%% PARAMETERS
escapeKey = KbName('ESCAPE');
leftKey   = KbName('LeftArrow');
rightKey  = KbName('RightArrow');

trialNumberPerBlock = 24;
numBlocks           = 4;

preSpawnDelaySec    = 2.000;
maxTrialDurationSec = 10.000;
itiDurationSec      = 2.000;
traceLogIntervalSec = 0.100;

fieldMarginPx = 0;
paddleWidthPx        = 900;
paddleHeightPx       = 200;
paddleBottomMarginPx = 50;
paddleBorderPx       = 3;

paddleGratingWidthPx = 300;
gratingBarWidthPx    = 14;
gratingLeftFreqHz    = 17;
gratingRightFreqHz   = 19;

targetBorderPx = 5;
edgeLineColor = [200 200 200];
edgeLineThickness = 4;

nfFilePath                = fullfile(experimentRoot, 'nf.txt');
nfIndex17                 = 1;
nfIndex19                 = 2;
useCsvSimulation          = false;
nfInputCsvPath            = fullfile(experimentRoot, 'P3_breakout_NSK3_nf.csv');
paddleNfGainPxPerSec      = 600;
paddleMaxSpeedPxPerSec    = 600;
paddleNfDeadzone          = 0.02;

allowKeyboardPaddleOnMac    = true;
keyboardPaddleSpeedPxPerSec = 600;

gratingMidColor        = grey;
gratingLeftBarHigh     = [  0 230 230];
gratingLeftBarLow      = [  0  80  80];
gratingRightBarHigh    = [255 220   0];
gratingRightBarLow     = [100  80   0];
paddleBodyColor    = cyanMid;
paddleBorderColor  = cyanBorder;
backgroundColor    = bgColor;
instructionsTextSize = 30;
readyTextSize        = 40;
hudHeightPx          = 80;

trialStartTrigger  = 'trialstart';
trialStopTrigger   = 'trialstop';

%% Read and stitch CSV for simulation (if enabled)
if useCsvSimulation
    opts = detectImportOptions(nfInputCsvPath);
    csvData = readtable(nfInputCsvPath, opts);
    activeIndices = csvData.cycle_cnt > 0;
    
    if ismember('nf_17_gt_19', csvData.Properties.VariableNames)
        sim_nf_left = csvData.nf_17_gt_19(activeIndices);
        sim_nf_right = csvData.nf_19_gt_17(activeIndices);
    elseif ismember('smi_23_over_29', csvData.Properties.VariableNames)
        sim_nf_left = csvData.smi_23_over_29(activeIndices);
        sim_nf_right = csvData.smi_29_over_23(activeIndices);
    else
        error('CSV does not contain recognized neurofeedback columns (e.g. nf_17_gt_19 or smi_23_over_29).');
    end
    numSimSamples = length(sim_nf_left);
    simSampleIdx = 1;
end

%% Initialise the screen
screens = Screen('Screens');
screenNumber = max(screens);

eyeTrackingStopped = ismac || ~eyeTracking;

if ~ismac && eyeTracking
    EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
end

[window,windowRect]=Screen('OpenWindow', screenNumber, backgroundColor,[], [], [], [], [], [], kPsychGUIWindow);
Screen('ColorRange', window, 255);
Screen('TextSize', window, 40);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

% Load arrow images
[imgL, ~, alphaL] = imread(fullfile(experimentRoot, 'shapes', 'left_arrow.png'));
[imgR, ~, alphaR] = imread(fullfile(experimentRoot, 'shapes', 'right_arrow.png'));
imgL(:,:,4) = alphaL;
imgR(:,:,4) = alphaR;
leftArrowTex = Screen('MakeTexture', window, imgL);
rightArrowTex = Screen('MakeTexture', window, imgR);

[xCenter, yCenter] = RectCenter(windowRect);

screenWidth = windowRect(3) - windowRect(1);
screenHeight = windowRect(4) - windowRect(2);
scaleX = screenWidth / 1920;
scaleY = screenHeight / 1080;
scaleMin = min(scaleX, scaleY);

% Scale sizes and velocities dynamically according to screen resolution
paddleWidthPx               = paddleWidthPx * scaleX;
paddleHeightPx              = paddleHeightPx * scaleY;
paddleBottomMarginPx        = paddleBottomMarginPx * scaleY;
paddleBorderPx              = max(1, round(paddleBorderPx * scaleX));
paddleGratingWidthPx        = paddleGratingWidthPx * scaleX;
gratingBarWidthPx           = max(1, round(gratingBarWidthPx * scaleX));



paddleNfGainPxPerSec        = paddleNfGainPxPerSec * scaleX;
paddleMaxSpeedPxPerSec      = paddleMaxSpeedPxPerSec * scaleX;
keyboardPaddleSpeedPxPerSec = keyboardPaddleSpeedPxPerSec * scaleX;

hudHeightPx                 = hudHeightPx * scaleY;

Screen('FillRect', window, backgroundColor);
Screen('Flip', window);
WaitSecs(1);

vbl = Screen('Flip', window);
interFrameInterval = Screen('GetFlipInterval', window);

%% Derived values
preSpawnFrames         = max(1, round(preSpawnDelaySec / interFrameInterval));
maxTrialFrames         = max(1, round(maxTrialDurationSec / interFrameInterval));
itiFrames              = max(1, round(itiDurationSec / interFrameInterval));
traceLogIntervalFrames = max(1, round(traceLogIntervalSec / interFrameInterval));

fieldLeft   = windowRect(1) + fieldMarginPx;
fieldTop    = windowRect(2) + fieldMarginPx + hudHeightPx;
fieldRight  = windowRect(3) - fieldMarginPx;
fieldBottom = windowRect(4) - fieldMarginPx;

paddleBottom     = fieldBottom - paddleBottomMarginPx;
paddleTop        = paddleBottom - paddleHeightPx;
paddleMinCenterX = fieldLeft  + paddleWidthPx / 2 + paddleBorderPx;
paddleMaxCenterX = fieldRight - paddleWidthPx / 2 - paddleBorderPx;

setupError = '';
if 2 * paddleGratingWidthPx >= paddleWidthPx
    setupError = 'Gratings overlap or leave no middle strip.';
elseif paddleMinCenterX > paddleMaxCenterX
    setupError = 'Paddle is wider than the playing field.';
end
if ~isempty(setupError)
    cleanupExperiment(ismac, eyeTrackingStopped, participantInfo, blockInfo, paraport);
    error('gameBreakoutv6p1_val:badParameters', '%s', setupError);
end

topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

numTraceColumns = 10;
traceRowFormat = '%d,%d,%.6f,%.6f,%.6f,%.6f,%d,%.3f,%.3f,%.3f\n';

%% Multi-Block Outer Loop
userQuit = false;

for blockIdx = 1:numBlocks
    if userQuit, break; end

    currentBlockNum = startBlockNum + blockIdx - 1;
    blockInfo = sprintf('%02d', currentBlockNum);
    sessionTag = sprintf('p%s_b%s', participantInfo, blockInfo);

    csvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_breakoutval_trialdata.csv', sessionTag), csvHeader);
    traceCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_breakoutval_trace.csv', sessionTag), traceCsvHeader);
    droppedFrameCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_breakoutval_droppedframes.csv', sessionTag), droppedFrameCsvHeader);

    runBlockLoop = true;
    trialNumber = 1;

    % Buffers for CSV logging (write at end of block)
    blockTrialRows = [];
    blockTraceRows = [];
    blockDroppedFrameRows = [];

    try
        %% Instructions screen
        instructionsText = [ ...
            'INSTRUCTIONS\n\n' ...
            'You must move the paddle to exactly match the gray target outline.\n' ...
            'Once inside, the target will expand slightly. Hold the paddle\n' ...
            'inside this expanded target for 2 continuous seconds to win.\n\n' ...
            'If you slip out completely, you must realign carefully again.'];
        Screen('FillRect', window, backgroundColor);
        Screen('TextSize', window, instructionsTextSize);
        DrawFormattedText(window, instructionsText, 'center', 'center', hudColor, [], [], [], [], [], []);
        Screen('TextSize', window, 28);
        promptText = sprintf('Press SPACEBAR or any Cedrus button to begin Block %d of %d', blockIdx, numBlocks);
        DrawFormattedText(window, promptText, 'center', windowRect(4) - 80 * scaleY, readyColor);
        vbl = Screen('Flip', window);
        WaitSecs(0.5);

        spaceKey = KbName('space');
        waitForStart = true;
        while waitForStart
            [keyIsDown, ~, keyCode] = KbCheck(-1);
            if ~ismac && cedrusAvailable, [~, ~, ohhItIsPressed] = cedrus.getpress(); else, ohhItIsPressed = 0; end
            if (keyIsDown && (keyCode(spaceKey) || keyCode(escapeKey))) || ohhItIsPressed
                if keyIsDown && keyCode(escapeKey), userQuit = true; end
                waitForStart = false;
            end
            WaitSecs(0.01);
        end
        if userQuit, break; end

        while runBlockLoop && trialNumber <= trialNumberPerBlock
            if ~ismac && eyeTracking, calllib('iViewXAPI', 'iV_StartRecording'); end
            disp(['Trial: ', num2str(trialNumber)]);

            % Setup target edges and cue
            paddleCenterX = xCenter;
            targetSide = sign(randn); if targetSide==0, targetSide=1; end
            targetDistPx = (fieldRight - xCenter); % Dist to edge
            
            % Edge lines
            targetLeftLineX = fieldLeft + 20;
            targetRightLineX = fieldRight - 20;
            
            if targetSide == -1
                targetEdgeX = targetLeftLineX;
                activeArrowTex = leftArrowTex;
            else
                targetEdgeX = targetRightLineX;
                activeArrowTex = rightArrowTex;
            end
            arrowWidthPx = 400 * scaleX; arrowHeightPx = 200 * scaleY;
            destRectArrow = CenterRectOnPointd([0 0 arrowWidthPx arrowHeightPx], xCenter, yCenter);

            nf17 = 0; nf19 = 0;
            droppedFrameCount = 0; droppedFrameNumber = []; droppedFrameVblTime = []; droppedFrameMissedBySec = [];
            traceRows = zeros(maxTrialFrames, numTraceColumns);
            traceIdx = 0;

            for readyFrame = 1:preSpawnFrames
                % Same prep loop, just center paddle and draw
                % [...] omitted for brevity in python string, just draw paddle at center
                paddleRect = [paddleCenterX - paddleWidthPx / 2, paddleTop, paddleCenterX + paddleWidthPx / 2, paddleBottom];
                ssvepTPredicted = (readyFrame - 1) * interFrameInterval;
                [leftBarColorA, leftBarColorB] = computeGratingColors(ssvepTPredicted, gratingLeftFreqHz, gratingMidColor, gratingLeftBarHigh, gratingLeftBarLow);
                [rightBarColorA, rightBarColorB] = computeGratingColors(ssvepTPredicted, gratingRightFreqHz, gratingMidColor, gratingRightBarHigh, gratingRightBarLow);
                Screen('FillRect', window, backgroundColor);
                Screen('DrawLine', window, edgeLineColor, targetLeftLineX, fieldTop, targetLeftLineX, fieldBottom, edgeLineThickness);
                Screen('DrawLine', window, edgeLineColor, targetRightLineX, fieldTop, targetRightLineX, fieldBottom, edgeLineThickness);
                Screen('DrawTexture', window, activeArrowTex, [], destRectArrow);
                drawPaddle(window, paddleRect, paddleGratingWidthPx, gratingBarWidthPx, leftBarColorA, leftBarColorB, rightBarColorA, rightBarColorB, paddleBodyColor, paddleBorderColor, paddleBorderPx);
                if ~ismac, vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval); else, vbl = Screen('Flip', window); end
                if checkEscape(escapeKey), userQuit = true; runBlockLoop = false; break; end
            end
            if userQuit || ~runBlockLoop, break; end

            trialStartTime = NaN;
            trialSsvepT0 = vbl; % Reference time for real SSVEP phase
            
            success = false;
            timeout = false;

            for currentFrame = 1:maxTrialFrames
                if useCsvSimulation
                    if simSampleIdx <= numSimSamples, nf17=sim_nf_left(simSampleIdx); nf19=sim_nf_right(simSampleIdx); simSampleIdx=simSampleIdx+1; end
                    nfReadOk = true;
                else
                    [newNf17, newNf19, nfReadOk] = readNfPair(nfFilePath, nfIndex17, nfIndex19);
                    if nfReadOk, nf17=newNf17; nf19=newNf19; end
                end

                paddleVxPxPerFrame = computePaddleVelocityFromNf(nf17, nf19, paddleNfGainPxPerSec, paddleMaxSpeedPxPerSec, paddleNfDeadzone, interFrameInterval);
                if allowKeyboardPaddleOnMac
                    [keyIsDown, ~, keyCode] = KbCheck(-1);
                    if keyIsDown && keyCode(leftKey), paddleVxPxPerFrame = -keyboardPaddleSpeedPxPerSec * interFrameInterval; end
                    if keyIsDown && keyCode(rightKey), paddleVxPxPerFrame = keyboardPaddleSpeedPxPerSec * interFrameInterval; end
                end
                paddleCenterX = max(paddleMinCenterX, min(paddleMaxCenterX, paddleCenterX + paddleVxPxPerFrame));
                paddleRect = [paddleCenterX - paddleWidthPx/2, paddleTop, paddleCenterX + paddleWidthPx/2, paddleBottom];

                % Edge collision logic
                if targetSide == -1
                    if paddleRect(1) <= targetLeftLineX
                        success = true; break;
                    elseif paddleRect(3) >= targetRightLineX
                        success = false; break; % Hit wrong edge
                    end
                else
                    if paddleRect(3) >= targetRightLineX
                        success = true; break;
                    elseif paddleRect(1) <= targetLeftLineX
                        success = false; break; % Hit wrong edge
                    end
                end

                % Draw
                Screen('FillRect', window, backgroundColor);
                % Draw edges and cue
                Screen('DrawLine', window, edgeLineColor, targetLeftLineX, fieldTop, targetLeftLineX, fieldBottom, edgeLineThickness);
                Screen('DrawLine', window, edgeLineColor, targetRightLineX, fieldTop, targetRightLineX, fieldBottom, edgeLineThickness);
                Screen('DrawTexture', window, activeArrowTex, [], destRectArrow);
                % SSVEP phase based on real elapsed time from vbl
                ssvepTPredicted = (vbl - trialSsvepT0) + interFrameInterval;
                [leftBarColorA, leftBarColorB] = computeGratingColors(ssvepTPredicted, gratingLeftFreqHz, gratingMidColor, gratingLeftBarHigh, gratingLeftBarLow);
                [rightBarColorA, rightBarColorB] = computeGratingColors(ssvepTPredicted, gratingRightFreqHz, gratingMidColor, gratingRightBarHigh, gratingRightBarLow);
                drawPaddle(window, paddleRect, paddleGratingWidthPx, gratingBarWidthPx, leftBarColorA, leftBarColorB, rightBarColorA, rightBarColorB, paddleBodyColor, paddleBorderColor, paddleBorderPx);

                % HUD
                hudText = sprintf('TRIAL %d/%d', trialNumber, trialNumberPerBlock);
                DrawFormattedText(window, hudText, 'left', 'center', hudColor, [], [], [], [], [], [windowRect(1) + 30, windowRect(2), windowRect(3), fieldTop]);
                
                timeLeftSec = max(0, maxTrialDurationSec - (currentFrame - 1) * interFrameInterval);
                if timeLeftSec <= 5.0
                    timeColor = failCol; % Red
                else
                    timeColor = hudColor;
                end
                timeText = sprintf('TIME: %.1fs', timeLeftSec);
                DrawFormattedText(window, timeText, 'right', 'center', timeColor, [], [], [], [], [], [0, windowRect(2), windowRect(3) - 30, fieldTop]);


                if ~ismac
                    [vbl, ~, ~, missed] = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
                    if missed > 0
                        droppedFrameCount = droppedFrameCount + 1;
                        droppedFrameNumber(end+1) = currentFrame; droppedFrameVblTime(end+1) = vbl; droppedFrameMissedBySec(end+1) = missed;
                    end
                else
                    vbl = Screen('Flip', window);
                end

                if currentFrame == 1
                    if ~ismac && ~isempty(paraport), cog_send_triggers(paraport, trialStartTrigger); end
                    trialStartTime = getElapsedTime(experimentStartTime);
                end

                if mod(currentFrame - 1, traceLogIntervalFrames) == 0
                    traceIdx = traceIdx + 1;
                    traceRows(traceIdx, :) = [trialNumber, currentFrame, getElapsedTime(experimentStartTime), nf17, nf19, nf19 - nf17, nfReadOk, paddleCenterX, paddleVxPxPerFrame/interFrameInterval, targetEdgeX];
                end

                if currentFrame == maxTrialFrames, timeout = true; end
                if checkEscape(escapeKey), userQuit = true; runBlockLoop = false; break; end
            end

            if ~ismac && ~isempty(paraport), cog_send_triggers(paraport, trialStopTrigger); end
            trialEndTime = getElapsedTime(experimentStartTime);
            if userQuit || ~runBlockLoop, break; end

            % Buffer trial data
            blockTrialRows = [blockTrialRows; [trialNumber, trialStartTime, trialEndTime, trialEndTime - trialStartTime, targetDistPx, targetSide, success, timeout, droppedFrameCount]];
            blockTraceRows = [blockTraceRows; traceRows(1:traceIdx, :)];
            for r = 1:numel(droppedFrameNumber)
                blockDroppedFrameRows = [blockDroppedFrameRows; [trialNumber, droppedFrameNumber(r), droppedFrameVblTime(r), droppedFrameMissedBySec(r)]];
            end

            %% ITI & Feedback
            if success
                fbText = sprintf('Trial %d: SUCCESS!', trialNumber);
                fbCol = successCol;
            else
                fbText = sprintf('Trial %d: TIMEOUT!', trialNumber);
                fbCol = failCol;
            end

            for itiFrame = 1:itiFrames
                Screen('FillRect', window, backgroundColor);
                DrawFormattedText(window, fbText, 'center', 'center', fbCol);
                if ~ismac, vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval); else, vbl = Screen('Flip', window); end
                if checkEscape(escapeKey), userQuit = true; runBlockLoop = false; break; end
            end
            if ~ismac && eyeTracking, calllib('iViewXAPI', 'iV_StopRecording'); end
            trialNumber = trialNumber + 1;
        end

        % Write buffered CSVs at end of block
        if ~isempty(blockTrialRows)
            fid = fopen(csvFile, 'a');
            for r = 1:size(blockTrialRows,1), fprintf(fid, '%d,%.6f,%.6f,%.6f,%.3f,%d,%d,%d,%d\n', blockTrialRows(r,:)); end
            fclose(fid);
        end
        if ~isempty(blockTraceRows)
            fid = fopen(traceCsvFile, 'a');
            for r = 1:size(blockTraceRows,1), fprintf(fid, traceRowFormat, blockTraceRows(r,:)); end
            fclose(fid);
        end
        if ~isempty(blockDroppedFrameRows)
            fid = fopen(droppedFrameCsvFile, 'a');
            for r = 1:size(blockDroppedFrameRows,1), fprintf(fid, '%d,%d,%.6f,%.6f\n', blockDroppedFrameRows(r,:)); end
            fclose(fid);
        end

        if ~ismac && eyeTracking
            EyeTracking(str2double(participantInfo),str2double(blockInfo),'stop');
            eyeTrackingStopped = true;
        end
    catch ME
        if ~ismac && ~isempty(paraport), cog_send_triggers(paraport, trialStopTrigger); end
        cleanupExperiment(ismac, eyeTrackingStopped, participantInfo, blockInfo, paraport);
        rethrow(ME);
    end

    Screen('FillRect', window, backgroundColor);
    Screen('TextSize', window, 35);
    if blockIdx < numBlocks, nextPrompt = 'Press SPACEBAR or any button on Cedrus for Next Block'; else, nextPrompt = 'Press SPACEBAR or any button on Cedrus to Finish'; end
    if ~isempty(blockTrialRows)
        successRate = 100 * sum(blockTrialRows(:,7)) / size(blockTrialRows,1);
    else
        successRate = 0;
    end
    performanceText = sprintf('BLOCK %d of %d COMPLETE\n\nSUCCESS RATE: %.1f%%\n\n%s', blockIdx, numBlocks, successRate, nextPrompt);
    DrawFormattedText(window, performanceText, 'center', 'center', hudColor);
    if ~ismac, vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval); else, vbl = Screen('Flip', window); end

    WaitSecs(1);
    spaceKey = KbName('space');
    waitForContinue = true;
    while waitForContinue
        [keyIsDown, ~, keyCode] = KbCheck(-1);
        if ~ismac && cedrusAvailable, [~, ~, ohhItIsPressed] = cedrus.getpress(); else, ohhItIsPressed = 0; end
        if (keyIsDown && (keyCode(escapeKey) || keyCode(spaceKey))) || ohhItIsPressed
            if keyIsDown && keyCode(escapeKey), userQuit = true; end
            waitForContinue = false;
        end
        WaitSecs(0.01);
    end
end % end multi-block loop

cleanupExperiment(ismac, eyeTrackingStopped, participantInfo, blockInfo, paraport);
