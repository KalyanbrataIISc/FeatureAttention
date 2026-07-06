%% Initialise 2
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

if ismac
    addpath(genpath('/Users/kalyanbrata/Documents/MATLAB/Kalyanbrata'));
else
    addpath(genpath('D:\Public\Kalyanbrata'));
end

if ~ismac
    %     addpath(genpath('F:\Real-Time\Toolbox/chronux_2_12.v03'));
    %     addpath('F:\Real-Time\Toolbox/fieldtrip-20170817/');
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

% Setting up random number generator for reproducibility
rngSeed = 1234 + str2double(blockInfo);
rng(rngSeed);

% Initialize timer
experimentStartTime = GetSecs;

eyeTracking=input('Eyetracking (1 or 0)?');
%% Info for CSV logging
% Unique session tag
sessionTag = sprintf('p%s_b%s', participantInfo, blockInfo);

% CSV logging (absolute path, header-once)
csvBaseDir = '/Users/kalyanbrata/Documents/MATLAB/Kalyanbrata/data';
if ~ismac
    csvBaseDir = 'D:\Public\Kalyanbrata\data';
end
if ~exist(csvBaseDir, 'dir')
    mkdir(csvBaseDir);
end
csvFile = fullfile(csvBaseDir, sprintf('%s_trialdata.csv', sessionTag));
csvSampleDtSec = 0.1;
csvHeader = ['TrialNumber,PresentationNumber,PresentationStart,PresentationEnd,' ...
    'NF,NF_SSVEP,AxisConfig_0=XisSSVEP_1=XisAlpha,IsValidTrial,TrialSuccessByNF'];
if ~exist(csvFile, 'file')
    fid = fopen(csvFile, 'w');
    fprintf(fid, '%s\n', csvHeader);
    fclose(fid);
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

%% PARAMETERS
% Key mappings
escapeKey   = KbName('ESCAPE');
% Experiment structure
trialNumberPerBlock = 24;

% Timing (all in seconds)
gaborTime           = 1.0;

% Excited Fixation Dot Incentive (inter‑trial performance)
enableExcitedDot     = true;       % master switch
excitedPercentile    = 75;         % reference percentile from prior trial
dotBaseDiameter      = 10;         % px
dotExcitedDiameter   = 10;         % px (larger for visible excited state)
dotBaseColor         = [255 0 0];    % red
dotExcitedColor      = [255 214 0]; % golden
dotSmoothingTauSec   = 0.30;       % seconds smoothing constant

% Post-trial feedback (text only; keep background unchanged)
feedbackDurationSec   = 1.0;           % duration for feedback text (s)
feedbackTextSize      = 64;            % font size for feedback text
feedbackSuccessColor  = [0 255 0];       % green text for success
feedbackFailColor     = [255 0 0];       % red text for fail
feedbackStringFail    = ' ';

% =================== NEUROFEEDBACK PARAMETERS ===================
% ================================================================
% Hemisphere Group (possible: 'left', 'right')
hemisphereGroup = 'right';

% Ring Parameters for Neurofeedback
nfRingRadius = 50;      % Radius of NF ring (pixels)
nfRingThickness = 5;    % Thickness of NF ring (pixels)
nfRingScale = 1.1;      % Visual scale factor for ring rendering
nfRingGrowThickness = 3;% Extra ring thickness when AMI > threshold
nfRingGrowRadius = 4;   % Extra ring radius when AMI > threshold

% NF Visual Parameters (ball + guide)
nfBallDiameter = dotBaseDiameter;    % match fixation size
nfBallBaseColor = dotBaseColor;      % default ball color (red)
nfBallSuccessColor = [0 255 0];      % ball color when at the top
nfStickWidth = 4;                    % px width of guide stick
nfStickColor = [64 64 64];           % guide stick colour

% Trial Duration Parameters (variable trial length)
minTrialLengthSec = 1;    % Minimum allowed trial duration
maxTrialLengthSec = 10;   % Maximum allowed trial duration
nfHoldTimeSec     = 2;    % NF must be >= NFThreshold continuously for this long to end the trial early
nfHoldProportion = 0.6;     % 0..1; proportion of frames above threshold required in the window
nfHoldProportion_SSVEP = nfHoldProportion; %0.6;     % 0..1; proportion of frames above threshold required in the window

% NF Parameters
NFThreshold = 0.1;                 % Threshold for NF value (-1 to 1)
NFThreshold_SSVEP = -0.001;           % Threshold for SSVEP NF value (-1 to 1)
NFThreshold_SSVEP_type = 1;        % 0 for absolute threshold, 1 for only upper threshold
nAmiWindow = 3;                    % Moving average window for ring color

% Bundle NF visual parameters for easy passing
nfVisualParams = struct( ...
    'ballDiameter', nfBallDiameter, ...
    'ballBaseColor', nfBallBaseColor, ...
    'ballSuccessColor', nfBallSuccessColor, ...
    'stickWidth', nfStickWidth, ...
    'stickColor', nfStickColor, ...
    'ringScale', nfRingScale, ...
    'ringGrowThickness', nfRingGrowThickness, ...
    'ringGrowRadius', nfRingGrowRadius);

pathToNF = 'D:\Public\Kalyanbrata\nf.txt';
if ismac
    pathToNF = '/Users/kalyanbrata/Documents/MATLAB/Kalyanbrata/nf.txt';
end
%% Initialise the screen
% Get the screen numbers
screens = Screen('Screens');
screenNumber = max(screens);

% Define colours
grey = [128 128 128];
black = [0 0 0];
red = [255 0 0]; % RGB for red fixation dot
if ~ismac
    if eyeTracking
        % Do Eye Calibration
        EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
    end
end
% Open the screen
% [window, windowRect] = PsychImaging('OpenWindow', screenNumber, grey, [], 24, 2);
[window,windowRect]=Screen('OpenWindow', screenNumber, grey,[], [], [], [], [], [], kPsychGUIWindow);
Screen('ColorRange', window, 255);

% Set the text size
Screen('TextSize', window, 40);

% Centre the screen
[xCenter, yCenter] = RectCenter(windowRect);

% Fixation dot parameters
dotRadius   = dotBaseDiameter / 2;
dotRect     = [xCenter - dotRadius, yCenter - dotRadius, xCenter + dotRadius, yCenter + dotRadius];

% Display fixation dot immediately (visible while participant number is entered)
Screen('FillOval', window, red, dotRect);
Screen('Flip', window);
WaitSecs(3);

% vbl setup
if ~ismac
    vbl = Screen('Flip', window); % initial sync flip
end

% Now that we have performed a first synced flip, query the actual refresh interval
interFrameInterval = Screen('GetFlipInterval', window);
refreshRate = 1 / interFrameInterval; % Number of frames per second
% priority level to ensure proper timing
topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

%% SSVEP PARAMETERS

% ---- SSVEP plaid parameters ----
p.window = window;
% Two plaids (left/right) with different temporal counterphase frequencies
p.temporalFreqHzL = 14;     % Hz (left)
p.temporalFreqHzR = 18;     % Hz (right)

% Horizontal eccentricity (center-to-center distance from screen center)
p.eccPx           = 600;    % pixels; left at -eccPx, right at +eccPx

% Spatial
% Independent plaid orientations (deg)
p.thetaDegL       = 0;     % left plaid: components at ±thetaDegL
p.thetaDegR       = 0;     % right plaid: components at ±thetaDegR
p.spatialFreqCpd  = 0.075;      % cycles/degree for each component grating
p.radiusPx        = 500;    % circular aperture radius (px)

% SSVEP parameters
% --- Geometry: one-time sizes & rects
patchDiam = 2*p.radiusPx;
dstRectL  = round(CenterRectOnPoint([0 0 patchDiam patchDiam], xCenter - p.eccPx, yCenter));
dstRectR  = round(CenterRectOnPoint([0 0 patchDiam patchDiam], xCenter + p.eccPx, yCenter));

rings.nRings        = 6;
rings.thicknessPx   = 70;
rings.gapPx         = 70;
rings.maxRadiusPx   = 1000;   % outermost ring radius
% Precompute ring radii (outer at inner) and mid-radii
rings.rOuter = rings.maxRadiusPx - (0:(rings.nRings-1))*(rings.thicknessPx + rings.gapPx);
rings.rInner = rings.rOuter - rings.thicknessPx;
rings.rInner(rings.rInner < 0) = 0;
rings.rMid   = (rings.rOuter + rings.rInner) / 2;

%% Derived variables (computed after refreshRate)
% Convert timing parameters (seconds) to frame counts based on measured refresh rate
% Frame-based thresholds for variable trial-length logic (no wall-clock control)
framesMinTrial  = max(0, ceil(minTrialLengthSec / interFrameInterval));
framesMaxTrial  = max(1, floor(maxTrialLengthSec / interFrameInterval));
framesNFHold    = max(1, ceil(nfHoldTimeSec / interFrameInterval));

% Frames for post-trial feedback text
framesFeedback = getNumFrames(refreshRate, feedbackDurationSec);


%% Block Loop

% Trial outcomes
successfulTrials = 0;

% Moving-average parameters for ring color
NFBuffer = zeros(1, nAmiWindow);  % preallocate buffer to fixed size
NFBufferCount = 0;     % number of valid entries in buffer
NFBufferIdx = 1;       % current index for circular buffer

% Moving average parameters for SSVEP NF
NFBuffer_SSVEP = zeros(1, nAmiWindow);  % preallocate buffer to fixed size
NFBufferCount_SSVEP = 0;     % number of valid entries in buffer
NFBufferIdx_SSVEP = 1;       % current index for circular buffer
% ================================================================

% =================== AXIS CONFIGURATION (BALANCED RANDOMIZATION) ===================
% Create balanced randomized axis assignments for the entire block
% axisConfig = 0: X-axis = SSVEP, Y-axis = Alpha (default)
% axisConfig = 1: X-axis = Alpha, Y-axis = SSVEP (swapped)
halfTrials = floor(trialNumberPerBlock / 2);
axisConfigs = [zeros(1, halfTrials), ones(1, trialNumberPerBlock - halfTrials)];
axisConfigs = axisConfigs(randperm(length(axisConfigs))); % Randomize order
% ================================================================

runBlockLoop = true;
trialNumber = 1;

%% SSVEP plaid vars
sizeOfPlaid = p.radiusPx;

bgc = 0.5; %changes the gray patterns
sscntrast = 1; %changes the gray patterns

gabortex = CreateProceduralSquareWaveGrating(window, sizeOfPlaid, sizeOfPlaid, [bgc bgc bgc 0], ...
    sizeOfPlaid/2, sscntrast);


%% TRIAL
try
    while runBlockLoop && trialNumber <= trialNumberPerBlock
        if ~ismac && eyeTracking
            calllib('iViewXAPI', 'iV_StartRecording'); % Start Eye Data Recording
        end
        %% Trial setup
        % SSVEP
        t=1/refreshRate:1/refreshRate:maxTrialLengthSec;
        sine_stimuli_L=sin(pi*p.temporalFreqHzL*t).^2;
        sine_stimuli_R=sin(pi*p.temporalFreqHzR*t).^2;
        
        if trialNumber==1
            Screen('TextSize',window, 28);
            DrawFormattedText(window,sprintf('Press Any Key To Begin'),'center','center',black);
            if ~ismac
                % Keep frame timing in sync with VBL
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                Screen('Flip', window);
            end
            
            if ~ismac
                [b, t] = cedrus.waitpress(600);
            else
                KbWait(-1);
            end
            
            Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');
        end
        
        %% =================== NEUROFEEDBACK TRIAL SETUP ===================
        % Get axis configuration for this trial
        % 0 = X-axis is SSVEP, Y-axis is Alpha (default)
        % 1 = X-axis is Alpha, Y-axis is SSVEP (swapped)
        currentAxisConfig = axisConfigs(trialNumber);
        
        % Per-trial sampling/init for CSV streaming
        trialStartTime = getElapsedTime(experimentStartTime);
        nextSampleTime = trialStartTime;
        presentationStartTimes = [];
        presentationEndTimes = [];
        samples_trialNumber = [];
        samples_presentationNumber = [];
        samples_presentationStart = [];
        samples_NF = [];
        samples_NF_SSVEP = [];
        samples_AxisConfig = [];  % Store axis configuration (0 or 1)
        
        % Frame-based logging and timing state
        trialFrameCount = 0;                 % counts frames since trial start
        
        %% Trial loop (presentations until ended by NF hold or max frames)
        ended = false;
        
        runLoop = true;
        i = 0;  % presentation counter this trial
        
        % Excited dot per‑trial state
        trialEarlyEndedByNF = false; % true if NF condition ended the trial
        trialEndedByMaxTime = false; % true if max duration cap ended the trial
        trialNF = [];
        trialNF_SSVEP = [];
        % Proportion-based hold sliding window (frame-based)
        nfWindowSize = framesNFHold;          % window length in frames derived from nfHoldTimeSec
        nfWinCount   = 0;                     % number of valid samples currently in window (<= nfWindowSize)
        nfWinSum     = 0;                     % running sum of hits where ringNF >= NFThreshold
        nfWinBuf     = false(1, nfWindowSize);% circular buffer of hits
        nfWinIdx     = 1;                     % next position to overwrite
        refP = NFThreshold;                   % first trial uses NFThreshold as baseline
        
        % SSVEP proportion-based hold sliding window (frame-based)
        nfWindowSize_SSVEP = framesNFHold;          % window length in frames derived from nfHoldTimeSec
        nfWinCount_SSVEP   = 0;                     % number of valid samples currently in window (<= nfWindowSize)
        nfWinSum_SSVEP     = 0;                     % running sum of hits where valNF_SSVEP >= NFThreshold
        nfWinBuf_SSVEP     = false(1, nfWindowSize_SSVEP);% circular buffer of hits
        nfWinIdx_SSVEP     = 1;                     % next position to overwrite
        
        % Send trialstart trigger (guarded for non-mac)
        disp(trialNumber);
        if ~ismac
            cog_send_triggers(paraport, 'trialstart');
        end
        while ~ended && runLoop
            i = i + 1;
            % Presentation start time (scalar)
            presentationStartTime = getElapsedTime(experimentStartTime);
            presentationStartTimes(i) = presentationStartTime; %#ok
            
            numFrames = getNumFrames(refreshRate, gaborTime);
            
            % =================== NEUROFEEDBACK PRESENTATION SETUP ===================
            NF = 0;
            NF_SSVEP = 0;
            for j = 1:numFrames
                currentTime = getElapsedTime(experimentStartTime);
                fid = fopen(pathToNF,'r');
                temp = fread(fid,'double');
                fclose(fid);
                
                if ~isempty(temp) && strcmp(hemisphereGroup, 'left')
                    NF = temp(1); % increase alpha in left hemisphere
                    NF_SSVEP = temp(3); % decrease attention (SSVEP) in left hemisphere
                elseif ~isempty(temp) && strcmp(hemisphereGroup, 'right')
                    NF = temp(2); % increase alpha in right hemisphere
                    NF_SSVEP = temp(4); % decrease attention (SSVEP) in right hemisphere
                end
                
                % Store NF for this frame (trial-scoped only)
                trialNF(end+1) = NF; %#ok<SAGROW>
                trialNF_SSVEP(end+1) = NF_SSVEP; %#ok<SAGROW>
                
                % Increment per-trial frame counter (frame-based timing)
                trialFrameCount = trialFrameCount + 1;
                
                % Update moving-average buffer and compute averaged NF
                NFBuffer(NFBufferIdx) = NF;
                NFBufferIdx = mod(NFBufferIdx, nAmiWindow) + 1;
                NFBufferCount = min(NFBufferCount + 1, nAmiWindow);
                ringNF = mean(NFBuffer(1:NFBufferCount));  % use average of valid samples
                
                NFBuffer_SSVEP(NFBufferIdx_SSVEP) = NF_SSVEP;
                NFBufferIdx_SSVEP = mod(NFBufferIdx_SSVEP, nAmiWindow) + 1;
                NFBufferCount_SSVEP = min(NFBufferCount_SSVEP + 1, nAmiWindow);
                valNF_SSVEP = mean(NFBuffer_SSVEP(1:NFBufferCount_SSVEP)); % use average of valid samples %%%%%% IMPORTANT
                if NFThreshold_SSVEP_type == 0
                    % Absolute thresholding
                    valNF_SSVEP = abs(valNF_SSVEP);
                end
                %             if valNF_SSVEP < 0
                %                 valNF_SSVEP = 0;
                %             end
                
                % Sample trial data at fixed interval (CSV at 0.1 s)
                if currentTime >= nextSampleTime
                    samples_trialNumber(end+1) = trialNumber; %#ok<SAGROW>
                    samples_presentationNumber(end+1) = i; %#ok<SAGROW>
                    samples_presentationStart(end+1) = presentationStartTime; %#ok<SAGROW>
                    samples_NF(end+1) = NF; %#ok<SAGROW>
                    samples_NF_SSVEP(end+1) = NF_SSVEP; %#ok<SAGROW>
                    samples_AxisConfig(end+1) = currentAxisConfig; %#ok<SAGROW>
                    nextSampleTime = nextSampleTime + csvSampleDtSec;
                end
                
                % Update sliding window for proportion-based NF hold (use smoothed NF: ringNF)
                % Alpha criterion: count frames where alpha NF >= threshold
                nfHit = (ringNF >= NFThreshold);
                oldHit = nfWinBuf(nfWinIdx);
                nfWinBuf(nfWinIdx) = nfHit;
                if nfWinCount < nfWindowSize
                    nfWinCount = nfWinCount + 1;
                    nfWinSum   = nfWinSum + nfHit;
                else
                    nfWinSum   = nfWinSum + nfHit - oldHit;
                end
                nfWinIdx = mod(nfWinIdx, nfWindowSize) + 1;
                
                % SSVEP criterion: count frames where SSVEP NF < threshold (good control)
                nfHit_SSVEP = (valNF_SSVEP < NFThreshold_SSVEP);
                oldHit_SSVEP = nfWinBuf_SSVEP(nfWinIdx_SSVEP);
                nfWinBuf_SSVEP(nfWinIdx_SSVEP) = nfHit_SSVEP;
                if nfWinCount_SSVEP < nfWindowSize_SSVEP
                    nfWinCount_SSVEP = nfWinCount_SSVEP + 1;
                    nfWinSum_SSVEP   = nfWinSum_SSVEP + nfHit_SSVEP;
                else
                    nfWinSum_SSVEP   = nfWinSum_SSVEP + nfHit_SSVEP - oldHit_SSVEP;
                end
                nfWinIdx_SSVEP = mod(nfWinIdx_SSVEP, nfWindowSize_SSVEP) + 1;
                
                % --- Variable trial-length termination checks (frame-based) ---
                % Success requires BOTH conditions to be met simultaneously:
                % 1. Alpha proportion >= nfHoldProportion (e.g., 60% of frames above alpha threshold)
                % 2. SSVEP proportion >= nfHoldProportion_SSVEP (e.g., 80% of frames below SSVEP threshold)
                if (trialFrameCount >= framesMinTrial) && (nfWinCount == nfWindowSize) && (nfWinCount_SSVEP == nfWindowSize_SSVEP)
                    alphaProportion = nfWinSum / nfWindowSize;
                    ssvepProportion = nfWinSum_SSVEP / nfWindowSize_SSVEP;
                    
                    if (alphaProportion >= nfHoldProportion) && (ssvepProportion >= nfHoldProportion_SSVEP)
                        trialEarlyEndedByNF = true;
                        ended = true;
                    end
                end
                
                % Hard stop at maximum trial length (failed trial)
                if ~ended && (trialFrameCount >= framesMaxTrial)
                    trialEndedByMaxTime = true;
                    ended = true;
                end
                % --- end variable trial-length checks ---
                
                % If ended, stop this presentation immediately
                if ended
                    break;
                end
                
                % ================================================================
                % Calculate base proportions for each metric
                % Alpha proportion: proportion of frames where alpha >= threshold
                if nfWinCount > 0
                    alphaProportion = min(max((nfWinSum / nfWindowSize), 0), 1);
                else
                    alphaProportion = 0;
                end
                % SSVEP proportion: proportion of frames where SSVEP < threshold
                if nfWinCount_SSVEP > 0
                    ssvepProportion = min(max((nfWinSum_SSVEP / nfWindowSize_SSVEP), 0), 1);
                else
                    ssvepProportion = 0;
                end
                
                % Apply axis swapping based on current trial configuration
                if currentAxisConfig == 0
                    % Default: X = SSVEP, Y = Alpha
                    displayX = ssvepProportion;
                    displayY = alphaProportion;
                    holdThresholdX = nfHoldProportion_SSVEP;  % X-axis threshold
                    holdThresholdY = nfHoldProportion;         % Y-axis threshold
                else
                    % Swapped: X = Alpha, Y = SSVEP
                    displayX = alphaProportion;
                    displayY = ssvepProportion;
                    holdThresholdX = nfHoldProportion;         % X-axis threshold (now Alpha)
                    holdThresholdY = nfHoldProportion_SSVEP;   % Y-axis threshold (now SSVEP)
                end
                
                % Check for key presses every frame
                [keyIsDown, ~, keyCode] = KbCheck(-1);
                
                % =================== NEUROFEEDBACK VISUAL DISPLAY ===================
                % Show NF visual with swapped coordinates AND swapped thresholds
                showNFVisual2DGoalField(window, xCenter, yCenter, nfRingRadius, nfRingThickness, NFThreshold, NFThreshold_SSVEP,...
                    ringNF, valNF_SSVEP, displayY, displayX, holdThresholdY, holdThresholdX, nfVisualParams);
                
                % SSVEP
                currentFrame = j+(i-1)*numFrames;
                modulatorL = sine_stimuli_L(currentFrame);
                modulatorR = sine_stimuli_R(currentFrame);
                genPlaidArcs;
                
                % ================================================================
                if keyIsDown && keyCode(escapeKey)
                    runBlockLoop = false;
                    runLoop = false;
                    break;
                end
                
                % (No colored feedback oval during response)
                if ~ismac
                    % Keep frame timing in sync with VBL
                    [vbl, ~, ~, miss(trialNumber,currentFrame)] = Screen('Flip', window,...
                        vbl + 0.5 * interFrameInterval); %#ok
                else
                    Screen('Flip', window);
                end
            end
            
            % =================== NEUROFEEDBACK PRESENTATION END ===================
            % ================================================================
            % Record end time for this presentation
            presentationEndTimes(i) = getElapsedTime(experimentStartTime); %#ok
        end
        
        % Ensure dot returns to base state before trial end
        currentDotDiameter = dotBaseDiameter;
        currentDotColor    = dotBaseColor;
        baseRadius = dotBaseDiameter / 2;
        dotRect = [xCenter - baseRadius, yCenter - baseRadius, xCenter + baseRadius, yCenter + baseRadius];
        
        % =================== NEUROFEEDBACK TRIAL END ===================
        if ~ismac
            if trialEarlyEndedByNF
                cog_send_triggers(paraport, 'success');
            end
            cog_send_triggers(paraport, 'trialstop');
            
        end
        
        if trialEarlyEndedByNF
            successfulTrials = successfulTrials + 1;
            fprintf('SUCCESS: %d\n', successfulTrials);
        end
        % ================================================================
        % ---- Append per-trial samples to CSV (header already written) ----
        if ended && exist('csvFile', 'var')
            isValidTrial = ~trialEndedByMaxTime;
            if ~isempty(samples_trialNumber)
                numSamples = numel(samples_trialNumber);
                samplePresentationEnd = nan(1, numSamples);
                for k = 1:numSamples
                    idx = samples_presentationNumber(k);
                    if idx >= 1 && idx <= numel(presentationEndTimes)
                        samplePresentationEnd(k) = presentationEndTimes(idx);
                    end
                end
                fid = fopen(csvFile, 'a');
                for r = 1:numSamples
                    fprintf(fid, '%d,%d,%.6f,%.6f,%.6f,%.6f,%d,%d,%d\n', ...
                        samples_trialNumber(r), ...
                        samples_presentationNumber(r), ...
                        samples_presentationStart(r), ...
                        samplePresentationEnd(r), ...
                        samples_NF(r), ...
                        samples_NF_SSVEP(r), ...
                        samples_AxisConfig(r), ...
                        isValidTrial, ...
                        trialEarlyEndedByNF);
                end
                fclose(fid);
            end
        end
        
        % Clear large per-trial arrays to reduce memory usage
        clear trialNF t sine_stimuli_L sine_stimuli_R presentationStartTimes presentationEndTimes samples_trialNumber samples_presentationNumber samples_presentationStart samplePresentationEnd samples_NF nextSampleTime trialStartTime;
        
        % Break out of trial if escape was pressed
        if ~runBlockLoop
            break;
        end
        
        % ---- Post-trial feedback (text only; background unchanged) ----
        % Choose text and color based on outcome
        if trialEarlyEndedByNF
            fbColor  = feedbackSuccessColor;
            fbString = 'SUCCESS';
        else
            fbColor  = feedbackFailColor;
            fbString = feedbackStringFail;
        end
        
        % Draw feedback text for a fixed number of frames (frame-based timing)
        Screen('TextSize', window, feedbackTextSize);
        for fb = 1:framesFeedback
            % keep same grey background and fixation dot
            Screen('FillRect', window, grey);
            if trialEarlyEndedByNF
                % windowRect(4) is the bottom; subtracting 100 pixels moves it up slightly
                DrawFormattedText(window, fbString, 'center', windowRect(4) - 300, fbColor);
                % Lock ball near goal zone for success duration (0.9, 0.9 to avoid sudden pop to top)
                % Apply correct threshold ordering based on axis configuration
                if currentAxisConfig == 0
                    feedbackHoldY = nfHoldProportion;
                    feedbackHoldX = nfHoldProportion_SSVEP;
                else
                    feedbackHoldY = nfHoldProportion_SSVEP;
                    feedbackHoldX = nfHoldProportion;
                end
                showNFVisual2DGoalField(window, xCenter, yCenter, nfRingRadius, nfRingThickness, NFThreshold, NFThreshold_SSVEP, ringNF, valNF_SSVEP,...
                    0.9, 0.9, feedbackHoldY, feedbackHoldX, nfVisualParams);
            else
                % reset dot to base each frame for ITI-consistent look
                baseRadius = dotBaseDiameter / 2;
                dotRect = [xCenter - baseRadius, yCenter - baseRadius, xCenter + baseRadius, yCenter + baseRadius];
                Screen('FillOval', window, red, dotRect);
                DrawFormattedText(window, fbString, 'center', 'center', fbColor);
            end
            if ~ismac
                % Keep frame timing in sync with VBL
                vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
            else
                Screen('Flip', window);
            end
        end
        
        %% Display grey screen
        Screen('FillRect', window, grey);
        % Reset dot to base for inter‑trial grey screen
        baseRadius = dotBaseDiameter / 2;
        dotRect = [xCenter - baseRadius, yCenter - baseRadius, xCenter + baseRadius, yCenter + baseRadius];
        Screen('FillOval', window, red, dotRect);
        if ~ismac
            % Keep frame timing in sync with VBL
            vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
        else
            Screen('Flip', window);
        end
        WaitSecs(1);
        
        trialNumber = trialNumber + 1;
        if ~ismac && eyeTracking
            calllib('iViewXAPI', 'iV_StopRecording'); % Stop Eye Data Recording
        end
    end
    
    if ~ismac && eyeTracking
        % Stop eye tracking and save the data
        EyeTracking(str2double(participantInfo),str2double(blockInfo),'stop');
    end
    
catch ME
    % If an error happens mid-trial, ensure a single stop is emitted
    if ~ismac
        cog_send_triggers(paraport, 'trialstop');
    end
    rethrow(ME);
end
%% Calculate and display block results
totalTrials = max(trialNumber - 1, 0);
if totalTrials > 0
    nfSuccessRate = (successfulTrials / totalTrials) * 100;  % percent
else
    nfSuccessRate = 0;
end

% Display the result on screen
Screen('FillRect', window, grey);
Screen('TextSize', window, 35);

performanceText = sprintf(['TESTING COMPLETED!\n\n' ...
    'SCORE: %.1f%%%\n\n' ...
    'Press ESCAPE or any button to continue'], nfSuccessRate);

% Display the text in the center of the screen
DrawFormattedText(window, performanceText, 'center', 'center', black);
if ~ismac
    % Keep frame timing in sync with VBL
    vbl = Screen('Flip', window, vbl + 0.5 * interFrameInterval);
else
    Screen('Flip', window);
end

fprintf('%s\n', performanceText);
WaitSecs(1);

% Wait for escape key to be pressed
waitForEscape = true;
while waitForEscape
    [keyIsDown, ~, keyCode] = KbCheck(-1);
    if ~ismac
        [button, time, ohhItIsPressed] = cedrus.getpress();
    else
        ohhItIsPressed = 0;
    end
    if (keyIsDown && keyCode(escapeKey)) || ohhItIsPressed
        waitForEscape = false;
    end
    WaitSecs(0.01); % Small delay to prevent excessive CPU usage
end

sca;