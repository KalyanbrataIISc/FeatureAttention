% gameBreakout  SSVEP-neurofeedback Breakout.
%
% A paddle sits at the bottom of the screen. Its left third is a grating
% flickering at 19 Hz, its right third a grating flickering at 23 Hz, and the
% strip between them does not flicker. Those two gratings are the whole SSVEP
% stimulus, and the lateralisation of the participant's SSVEP response to
% them - read live from nf.txt, written by RT_files/RT_acquisition_8.m - is
% what moves the paddle: 19 Hz dominance drives it left, 23 Hz dominance
% drives it right, at a speed linear in the lateralisation. So attending to
% one side of the paddle steers the paddle toward that side.
%
% A ball bounces around a field with no gravity. The paddle must keep it from
% falling off the bottom; the ball falling ends the trial. One brick at a
% time appears at a random position above the screen midline, and the ball
% breaks it on contact. The first brick, and every brick after one is broken,
% only appears once the ball has bounced off the paddle again - so the
% participant has to keep working the paddle (i.e. keep driving the SSVEP
% lateralisation) between targets, not just park it under a stationary rally.
%
% Physics: no gravity, constant ball speed, and spin. The paddle's own motion
% at the moment of contact both carries the ball sideways and sets its spin;
% the spin then curves the ball's flight (Magnus). See
% breakoutHelperFunctions/collideBallPaddle.m and moveBall.m.
%
% This is an independent script - it shares nf.txt, the Cedrus/trigger/eye
% tracking scaffolding in functions/, and a few generic helpers in
% helperFunctions/ with the leaves task (gamev1.m, gameNF*.m), but changes
% nothing in them. Its own logic lives in breakoutHelperFunctions/.
%
% On mac: no eye tracking, no triggers, SkipSyncTests on, and the arrow keys
% can optionally override the paddle for quick testing without a live NF
% stream. On Windows the full rig runs.

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

% CSV logging (absolute path, header-once). File names carry `breakout` so
% they never collide with the leaves task's `leaves` files in the same folder.
csvBaseDir = fullfile(experimentRoot, 'data');
if ~exist(csvBaseDir, 'dir')
    mkdir(csvBaseDir);
end

% One row per trial (one trial = one ball, spawn to fall).
csvHeader = ['TrialNumber,TrialStart,TrialEnd,TrialDuration,' ...
    'PaddleBounces,WallBounces,BricksBroken,BallFell,DroppedFrameCount'];
csvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_breakout_trialdata.csv', sessionTag), csvHeader);

% Per-~100ms trace of the whole game state (one row per traceLogIntervalSec),
% separate file so the one-row-per-trial main CSV above stays unchanged in
% shape. Everything needed to reconstruct the trial offline is here: the NF
% values actually used, the paddle they drove, and the resulting ball/brick.
traceCsvHeader = ['TrialNumber,FrameNumber,SampleTime,NF19,NF23,NFSigned,NFReadOk,' ...
    'PaddleCenterX,PaddleVxPxPerSec,BallX,BallY,BallVxPxPerSec,BallVyPxPerSec,BallSpin,' ...
    'BrickActive,BrickCenterX,BrickCenterY,BricksBroken'];
traceCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_breakout_trace.csv', sessionTag), traceCsvHeader);

% Dropped/delayed-frame log: one row per frame whose Screen('Flip') missed
% its requested presentation deadline. Same rationale as gameNFv2/v3 - the
% SSVEP flicker phase here is anchored to real VBL timestamps precisely so
% that GPU load cannot silently detune 19/23 Hz, and this file makes the drop
% rate on a given rig measurable rather than inferred from EEG spectra later.
droppedFrameCsvHeader = 'TrialNumber,FrameNumber,VBLTime,MissedBySec';
droppedFrameCsvFile = ensureCsvWithHeader(csvBaseDir, sprintf('%s_breakout_droppedframes.csv', sessionTag), droppedFrameCsvHeader);

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
    sendNumericTrigger(paraport, 0);   % reset line
end
if ~exist('paraport','var')
    paraport = [];
end

%% Display colors
grey  = [128 128 128];
black = [0 0 0];
white = [255 255 255];

%% PARAMETERS
% Everything the experimenter tunes lives in this block. Values below are in
% pixels / seconds / Hz / degrees; convert px to degrees of visual angle for
% your own rig (px/deg = screen_px_per_unit_distance * tan(1 deg)).

% ---- Key mappings ----
% escapeKey quits the block on both platforms. leftKey/rightKey only do
% anything on mac, and only if allowKeyboardPaddleOnMac is true (below).
escapeKey = KbName('ESCAPE');
leftKey   = KbName('LeftArrow');
rightKey  = KbName('RightArrow');

% ---- Experiment structure ----
trialNumberPerBlock = 24;     % one trial = one ball, from spawn to fall

% ---- Timing (seconds; converted to frames once the refresh rate is known) ----
preSpawnDelaySec    = 2.000;  % 'Get ready' screen before the ball spawns. The gratings
% already flicker and the paddle already tracks NF during this window, so the
% SSVEP response has settled by the time the trial (and the trigger) starts.
% Prefer whole seconds here: 19 Hz and 23 Hz both complete an exact whole
% number of cycles per second, so a whole-second lead-in puts both gratings
% back at zero phase just as the trial starts, without ever interrupting the
% flicker (which runs continuously from the start of this window).
maxTrialDurationSec = 120.000; % safety cap: a trial normally ends when the ball
% falls, this only stops a rally from running forever
itiDurationSec      = 1.000;  % blank inter-trial interval (gratings off)
traceLogIntervalSec = 0.100;  % how often the trace CSV samples the game state

% ---- Field ----
fieldMarginPx = 0;  % inset of the playing field from the screen edge; 0 = full screen.
% The left, right and top field edges are walls. The bottom edge is open: the
% ball crossing it is what ends the trial.

% ---- Paddle geometry ----
paddleWidthPx        = 420;   % total width, including both gratings
paddleHeightPx       = 60;    % taller = more grating area = stronger SSVEP drive
paddleBottomMarginPx = 70;    % gap between the paddle's bottom face and the field bottom
paddleBorderPx       = 3;     % outline thickness, keeps the paddle visible at flicker trough

% ---- Paddle SSVEP gratings ----
% The paddle is [ left grating | inert middle | right grating ] across its
% width. With the defaults below the middle strip is
% paddleWidthPx - 2*paddleGratingWidthPx = 140 px wide.
paddleGratingWidthPx = 140;   % width of EACH grating region
gratingBarWidthPx    = 14;    % bar width of the square-wave grating
gratingLeftFreqHz    = 19;    % left grating flicker (drives the paddle LEFT)
gratingRightFreqHz   = 23;    % right grating flicker (drives the paddle RIGHT)

% ---- Ball ----
ballRadiusPx           = 12;
ballSpeedPxPerSec      = 480;  % constant for the whole trial - nothing changes it
ballSpawnGapPx         = 6;    % gap between the ball and the paddle's top face at spawn
ballLaunchMaxAngleDeg  = 30;   % ball launches within +/- this of straight up, at random

% ---- Ball physics: bounce, carry and spin ----
% See breakoutHelperFunctions/collideBallPaddle.m and moveBall.m for the model.
paddleBounceMaxAngleDeg = 60;   % rebound angle from vertical at the very edge of the paddle
paddlePushGain          = 0.35; % how strongly a moving paddle drags the ball sideways
paddleSpinGain          = 0.05; % how much paddle velocity (px/frame) becomes ball spin
magnusGainPerFrame      = 0.02; % how strongly spin curves the flight; 0 disables curving
spinDecayPerFrame       = 0.99; % spin left after one frame of drag (1 = spin never decays)
minVerticalSpeedFraction = 0.15; % floor on |vy| as a fraction of ball speed, so the ball
% can never settle into a purely horizontal path that neither falls nor reaches the paddle

% ---- Bricks ----
% Exactly one brick exists at a time. The first one, and each one after a
% brick is broken, only spawns once the ball has bounced off the paddle
% again. Bricks are confined to the band above the screen midline.
brickWidthPx              = 110;
brickHeightPx             = 34;
brickBorderPx             = 3;
brickRegionTopMarginPx    = 80;  % from the top of the field
brickRegionSideMarginPx   = 60;  % from the left/right of the field
brickRegionBottomMarginPx = 60;  % above the screen midline
brickSpawnBallClearancePx = 40;  % extra clearance (beyond the ball radius) a new brick
% must leave around the ball, so a brick never materialises on top of it
brickSpawnMaxAttempts     = 200; % rejection-sampling attempts for that clearance

% ---- Neurofeedback: nf.txt -> paddle velocity ----
% nf.txt is a 3-element binary double vector [SMI_19gt23, SMI_23gt19,
% sampleCount], continuously overwritten (~every 100 ms) by the external
% real-time acquisition process RT_files/RT_acquisition_8.m. Index 1 is
% positive when 19 Hz SSVEP power exceeds 23 Hz, index 2 when 23 Hz exceeds
% 19 Hz. The signed drive is nf23 - nf19: positive moves the paddle right,
% negative moves it left, and paddle speed is linear in it.
%
% nf.txt is re-read fresh on every displayed frame rather than on a local
% 100 ms timer. The file is only rewritten externally on roughly a 100 ms
% cadence, but polling on our own clock could sit out of phase with that and
% add close to a full cadence period of pure latency for no reason. Reading
% every frame picks up each external rewrite as soon as it lands. A failed
% read (file missing, or caught mid-write by the external process, which
% truncates before rewriting) is an I/O race, not a real zero-lateralisation
% sample, so the last good values are held rather than snapping the paddle to
% a halt. No moving-average window is applied to the live values.
nfFilePath                = fullfile(experimentRoot, 'nf.txt');
nfIndex19                 = 1;    % nf.txt column: positive when 19 Hz > 23 Hz
nfIndex23                 = 2;    % nf.txt column: positive when 23 Hz > 19 Hz
paddleNfGainPxPerSec      = 600;  % paddle speed per unit of (nf23 - nf19)
paddleMaxSpeedPxPerSec    = 600;  % clamp on paddle speed
paddleNfDeadzone          = 0.02; % |nf23 - nf19| below this pins the paddle still

% ---- Mac-only manual paddle override (development/testing) ----
% On mac, holding an arrow key overrides the NF drive for that frame, so the
% physics can be exercised without running simulate_nf.py. Never active on
% the real rig (~ismac), where the paddle is always NF-driven.
allowKeyboardPaddleOnMac    = true;
keyboardPaddleSpeedPxPerSec = 600;

% ---- Colors ----
% The gratings flicker between full contrast (barColorHigh / barColorLow) and
% a uniform gratingMidColor, once per cycle. Setting gratingMidColor to the
% background grey makes the grating fade into a flat grey patch at the trough.
gratingMidColor    = grey;
gratingBarHigh     = white;
gratingBarLow      = black;
paddleBodyColor    = [70 70 70];
paddleBorderColor  = black;
ballColor          = white;
brickColor         = [220 60 60];
brickBorderColor   = black;

% ---- Screen text ----
instructionsTextSize = 25;
readyTextSize        = 40;
showScore            = true;   % live count of bricks broken in the current trial
scoreTextSize        = 24;
scoreTextYPx         = 25;
scoreTextColor       = black;

% ---- Trigger values (sent on ~ismac only) ----
% Sent as raw bytes via helperFunctions/sendNumericTrigger.m rather than
% through functions/cog_send_triggers.m, so this task can define its own
% bounce triggers without touching the shared trigger table the leaves task
% depends on. trialstart/trialstop keep cog_send_triggers' values (20/30) so
% existing trial-segmentation code still finds them; the three bounce
% triggers use 70-72, which that table leaves free.
trialStartTrigger  = 20;
trialStopTrigger   = 30;
wallBounceTrigger  = 70;
paddleBounceTrigger = 71;
brickBounceTrigger = 72;

%% Initialise the screen
screens = Screen('Screens');
screenNumber = max(screens);

% Declared before eye tracking starts so the setup validations below can tear
% the rig down through the same path the catch block uses.
eyeTrackingStopped = ismac || ~eyeTracking;

if ~ismac && eyeTracking
    EyeTracking(str2double(participantInfo),str2double(blockInfo),'start');
end

[window,windowRect]=Screen('OpenWindow', screenNumber, grey,[], [], [], [], [], [], kPsychGUIWindow);
Screen('ColorRange', window, 255);
Screen('TextSize', window, 40);
Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

[xCenter, yCenter] = RectCenter(windowRect);

Screen('FillRect', window, grey);
Screen('Flip', window);
WaitSecs(1);

% vbl is captured on every platform because the SSVEP flicker phase below is
% driven from this real measured flip timestamp, never from a frame counter.
vbl = Screen('Flip', window);

interFrameInterval = Screen('GetFlipInterval', window);

%% Derived values (need interFrameInterval / windowRect, known only now)
% Frame-based timing
preSpawnFrames         = max(1, round(preSpawnDelaySec / interFrameInterval));
maxTrialFrames         = max(1, round(maxTrialDurationSec / interFrameInterval));
itiFrames              = max(1, round(itiDurationSec / interFrameInterval));
traceLogIntervalFrames = max(1, round(traceLogIntervalSec / interFrameInterval));

% Per-frame speeds and radian angles
ballSpeedPxPerFrame     = ballSpeedPxPerSec * interFrameInterval;
ballLaunchMaxAngleRad   = ballLaunchMaxAngleDeg * pi / 180;
paddleBounceMaxAngleRad = paddleBounceMaxAngleDeg * pi / 180;

% Playing field. Left/right/top are walls; the bottom is open.
fieldLeft   = windowRect(1) + fieldMarginPx;
fieldTop    = windowRect(2) + fieldMarginPx;
fieldRight  = windowRect(3) - fieldMarginPx;
fieldBottom = windowRect(4) - fieldMarginPx;

% Paddle: fixed vertically, slides horizontally between these center bounds.
paddleBottom     = fieldBottom - paddleBottomMarginPx;
paddleTop        = paddleBottom - paddleHeightPx;
paddleMinCenterX = fieldLeft  + paddleWidthPx / 2 + paddleBorderPx;
paddleMaxCenterX = fieldRight - paddleWidthPx / 2 - paddleBorderPx;

% Brick region: the band above the screen midline.
brickRegionRect = [fieldLeft  + brickRegionSideMarginPx, fieldTop + brickRegionTopMarginPx, ...
                   fieldRight - brickRegionSideMarginPx, yCenter  - brickRegionBottomMarginPx];

%% Validate the parameter block against the geometry it just produced.
% Every one of these would otherwise be a silent, block-long distortion of the
% stimulus rather than an obvious failure, so they are checked once, up front,
% and torn down through the same path as any other error.
%
% The two tunneling bounds exist because collisions are resolved at discrete
% frame positions: a ball that moves far enough in a single frame can step
% clean over a surface without ever overlapping it, passing through the paddle
% or a brick. These are the exact per-frame steps at which that starts to
% happen for a ball approaching a face head-on. Both hold with a wide margin at
% the default ballSpeedPxPerSec and only bite if it is raised several-fold -
% raise paddleHeightPx / the brick size / ballRadiusPx alongside it rather than
% deleting the check.
maxSafeStepPastPaddle = paddleHeightPx + ballRadiusPx;
maxSafeStepPastBrick  = min(brickWidthPx, brickHeightPx) + 2 * ballRadiusPx;

setupError = '';
if 2 * paddleGratingWidthPx >= paddleWidthPx
    setupError = sprintf(['The two %dpx gratings leave no inert middle strip in a %dpx ' ...
        'paddle. Lower paddleGratingWidthPx or raise paddleWidthPx.'], ...
        paddleGratingWidthPx, paddleWidthPx);
elseif paddleMinCenterX > paddleMaxCenterX
    setupError = sprintf('Paddle (%dpx wide + %dpx border) is wider than the playing field.', ...
        paddleWidthPx, paddleBorderPx);
elseif brickWidthPx > (brickRegionRect(3) - brickRegionRect(1)) || ...
        brickHeightPx > (brickRegionRect(4) - brickRegionRect(2))
    setupError = sprintf('A %dx%dpx brick does not fit in the %.0fx%.0fpx brick region.', ...
        brickWidthPx, brickHeightPx, ...
        brickRegionRect(3) - brickRegionRect(1), brickRegionRect(4) - brickRegionRect(2));
elseif ballSpeedPxPerFrame > maxSafeStepPastPaddle
    setupError = sprintf(['ballSpeedPxPerSec=%g is %.1f px/frame at this refresh rate, past the ' ...
        '%.1f px/frame at which the ball starts passing through the paddle.'], ...
        ballSpeedPxPerSec, ballSpeedPxPerFrame, maxSafeStepPastPaddle);
elseif ballSpeedPxPerFrame > maxSafeStepPastBrick
    setupError = sprintf(['ballSpeedPxPerSec=%g is %.1f px/frame at this refresh rate, past the ' ...
        '%.1f px/frame at which the ball starts passing through a brick.'], ...
        ballSpeedPxPerSec, ballSpeedPxPerFrame, maxSafeStepPastBrick);
end
if ~isempty(setupError)
    cleanupExperiment(ismac, eyeTrackingStopped, participantInfo, blockInfo, paraport);
    error('gameBreakout:badParameters', '%s', setupError);
end

% Raised only once the parameters are known good, so a failed validation never
% leaves MATLAB stuck at realtime priority.
topPriorityLevel = MaxPriority(window);
Priority(topPriorityLevel);

% Trace CSV row layout, matching traceCsvHeader above.
numTraceColumns = 18;
traceRowFormat = '%d,%d,%.6f,%.6f,%.6f,%.6f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.6f,%d,%.3f,%.3f,%d\n';

%% Block Loop
runBlockLoop = true;
trialNumber = 1;
bricksBrokenByTrial = zeros(1, trialNumberPerBlock);
trialDurationByTrial = nan(1, trialNumberPerBlock);

try
    %% Instructions screen (once, before the block starts)
    instructionsRect = [windowRect(1) + 80, windowRect(2) + 60, windowRect(3) - 80, windowRect(4) - 140];
    instructionsText = [ ...
        'INSTRUCTIONS\n\n' ...
        'A paddle sits at the bottom of the screen. Keep the ball from falling\n' ...
        'off the bottom - if it falls, the trial ends.\n\n' ...
        'You do not move the paddle with your hands. The paddle has a flickering\n' ...
        'pattern on its LEFT side and another on its RIGHT side. Attending to the\n' ...
        'LEFT pattern moves the paddle LEFT; attending to the RIGHT pattern moves\n' ...
        'it RIGHT. The harder you attend to one side, the faster it moves that way.\n\n' ...
        'A brick appears above the middle of the screen. Bounce the ball into it\n' ...
        'to break it. The next brick only appears after the ball has bounced off\n' ...
        'the paddle again.\n\n' ...
        'Where the ball lands on the paddle, and how the paddle is moving when it\n' ...
        'lands, both change where the ball goes next.'];

    Screen('FillRect', window, grey);
    Screen('TextSize', window, instructionsTextSize);
    DrawFormattedText(window, instructionsText, 'center', 'center', black, [], [], [], [], [], instructionsRect);
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

        %% Trial setup (the ball does not exist yet, so the trial has not started)
        disp(trialNumber);
        paddleCenterX = xCenter;

        % NF values are only overwritten on a successful read, so they start
        % at 0 (neutral) exactly as at a real trial start - RT_acquisition_8
        % itself zeroes nf.txt at trial start.
        nf19 = 0;
        nf23 = 0;

        bricksBroken  = 0;
        paddleBounces = 0;
        wallBounces   = 0;

        % One brick at a time, gated on paddle bounces. paddleBounceReady is
        % armed by a paddle bounce and consumed by a brick spawn; breaking a
        % brick disarms it again, so the *next* brick needs a *fresh* paddle
        % bounce after the break, not one that happened before it.
        brickActive = false;
        brickRect = [NaN NaN NaN NaN];
        paddleBounceReady = false;

        droppedFrameCount = 0;
        droppedFrameNumber = [];
        droppedFrameVblTime = [];
        droppedFrameMissedBySec = [];

        traceRows = zeros(0, numTraceColumns);

        %% 'Get ready' phase: gratings flicker and the paddle already tracks NF,
        % but there is no ball, no trigger and no logging yet. This lets the
        % SSVEP response settle before the trial proper begins, so the paddle
        % is already under control at ball spawn.
        %
        % flickerT0 is the flicker's t = 0 and it spans BOTH this phase and the
        % trial loop below. It must not be re-anchored at ball spawn: the
        % gratings are continuously on screen across that boundary, so resetting
        % the phase there would step the sinusoid discontinuously and evoke a
        % transient at exactly the trialstart trigger - contaminating the very
        % SSVEP this task measures. The gratings only ever start from zero phase
        % at the start of this phase, after the blank ITI has switched them off.
        flickerT0 = vbl;
        for readyFrame = 1:preSpawnFrames
            [newNf19, newNf23, nfReadOk] = readNfPair(nfFilePath, nfIndex19, nfIndex23);
            if nfReadOk
                nf19 = newNf19;
                nf23 = newNf23;
            end

            paddleVxPxPerFrame = computePaddleVelocityFromNf(nf19, nf23, ...
                paddleNfGainPxPerSec, paddleMaxSpeedPxPerSec, paddleNfDeadzone, interFrameInterval);
            if ismac && allowKeyboardPaddleOnMac
                [keyIsDown, ~, keyCode] = KbCheck(-1);
                if keyIsDown && keyCode(leftKey)
                    paddleVxPxPerFrame = -keyboardPaddleSpeedPxPerSec * interFrameInterval;
                elseif keyIsDown && keyCode(rightKey)
                    paddleVxPxPerFrame = keyboardPaddleSpeedPxPerSec * interFrameInterval;
                end
            end
            paddleCenterX = max(paddleMinCenterX, min(paddleMaxCenterX, paddleCenterX + paddleVxPxPerFrame));
            paddleRect = [paddleCenterX - paddleWidthPx / 2, paddleTop, ...
                          paddleCenterX + paddleWidthPx / 2, paddleBottom];

            ssvepTPredicted = (vbl - flickerT0) + interFrameInterval;
            [leftBarColorA, leftBarColorB]   = computeGratingColors(ssvepTPredicted, gratingLeftFreqHz,  gratingMidColor, gratingBarHigh, gratingBarLow);
            [rightBarColorA, rightBarColorB] = computeGratingColors(ssvepTPredicted, gratingRightFreqHz, gratingMidColor, gratingBarHigh, gratingBarLow);

            Screen('FillRect', window, grey);
            drawPaddle(window, paddleRect, paddleGratingWidthPx, gratingBarWidthPx, ...
                leftBarColorA, leftBarColorB, rightBarColorA, rightBarColorB, ...
                paddleBodyColor, paddleBorderColor, paddleBorderPx);
            Screen('TextSize', window, readyTextSize);
            DrawFormattedText(window, 'Get ready', 'center', yCenter, black);

            if ~ismac
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
            % No trialstart was ever sent, so no trialstop is owed.
            break;
        end

        %% Trial start = ball spawn
        % Every trigger in the frame loop below - trialstart included - is sent
        % immediately *after* the Screen('Flip') that puts the corresponding
        % event on screen, never before it. Sending on the frame the event is
        % computed would put the trigger up to one refresh ahead of the display
        % the participant actually saw. This is the same post-flip pattern
        % gameNFv3.m uses for its `cueonset` trigger. So trialstart marks the
        % first frame on which the ball is visible.
        ball = initBall(paddleCenterX, paddleTop - ballRadiusPx - ballSpawnGapPx, ...
            ballSpeedPxPerFrame, ballLaunchMaxAngleRad, ballRadiusPx);

        trialStartTime = NaN;
        ballFell = false;

        for currentFrame = 1:maxTrialFrames
            %% Neurofeedback -> paddle velocity
            [newNf19, newNf23, nfReadOk] = readNfPair(nfFilePath, nfIndex19, nfIndex23);
            if nfReadOk
                nf19 = newNf19;
                nf23 = newNf23;
            end

            paddleVxPxPerFrame = computePaddleVelocityFromNf(nf19, nf23, ...
                paddleNfGainPxPerSec, paddleMaxSpeedPxPerSec, paddleNfDeadzone, interFrameInterval);
            if ismac && allowKeyboardPaddleOnMac
                [keyIsDown, ~, keyCode] = KbCheck(-1);
                if keyIsDown && keyCode(leftKey)
                    paddleVxPxPerFrame = -keyboardPaddleSpeedPxPerSec * interFrameInterval;
                elseif keyIsDown && keyCode(rightKey)
                    paddleVxPxPerFrame = keyboardPaddleSpeedPxPerSec * interFrameInterval;
                end
            end

            % Clamping the *position* means paddleVxPxPerFrame can overstate
            % the paddle's real motion at the field edges. That is deliberate:
            % the value below is also what gets handed to the bounce as the
            % paddle's carry/spin, and a paddle pressed hard against the wall
            % should still impart that push. Change here if you want the edge
            % to kill the carry too.
            paddleCenterX = max(paddleMinCenterX, min(paddleMaxCenterX, paddleCenterX + paddleVxPxPerFrame));
            paddleRect = [paddleCenterX - paddleWidthPx / 2, paddleTop, ...
                          paddleCenterX + paddleWidthPx / 2, paddleBottom];

            %% Ball physics, then collisions in order: walls, paddle, brick.
            % Each collision only sets a flag here; the triggers are sent after
            % this frame's flip, alongside the display of the bounce itself.
            ball = moveBall(ball, ballSpeedPxPerFrame, magnusGainPerFrame, spinDecayPerFrame, minVerticalSpeedFraction);

            [ball, hitWall] = collideBallWalls(ball, fieldLeft, fieldRight, fieldTop);
            if hitWall
                wallBounces = wallBounces + 1;
            end

            [ball, hitPaddle] = collideBallPaddle(ball, paddleRect, paddleVxPxPerFrame, ...
                ballSpeedPxPerFrame, paddleBounceMaxAngleRad, paddlePushGain, paddleSpinGain);
            if hitPaddle
                paddleBounces = paddleBounces + 1;
                paddleBounceReady = true;   % arms the next brick spawn
            end

            hitBrick = false;
            if brickActive
                [ball, hitBrick] = collideBallBrick(ball, brickRect);
                if hitBrick
                    brickActive = false;
                    brickRect = [NaN NaN NaN NaN];
                    bricksBroken = bricksBroken + 1;
                    paddleBounceReady = false;   % the next brick needs a fresh paddle bounce
                end
            end

            % Spawn the next brick only once the ball has bounced off the
            % paddle since the last brick left the screen. On the very first
            % pass this is what holds the first brick back until the ball has
            % been returned once.
            if ~brickActive && paddleBounceReady
                brickRect = spawnBrick(brickRegionRect, brickWidthPx, brickHeightPx, ...
                    ball.x, ball.y, ballRadiusPx + brickSpawnBallClearancePx, brickSpawnMaxAttempts);
                brickActive = true;
                paddleBounceReady = false;
            end

            %% SSVEP flicker for this frame, phased off the measured VBL clock
            % Each frame predicts its own display time as (last real VBL + one
            % refresh). vbl holds the ACTUAL measured timestamp of the previous
            % flip, so a flip delayed by GPU load shifts the prediction - and
            % the phase - to match reality on the very next frame, instead of
            % letting a frame-counter clock silently detune 19/23 Hz for the
            % rest of the trial. flickerT0 was set before the 'Get ready' phase,
            % so the sinusoid runs unbroken into this loop.
            ssvepTPredicted = (vbl - flickerT0) + interFrameInterval;
            [leftBarColorA, leftBarColorB]   = computeGratingColors(ssvepTPredicted, gratingLeftFreqHz,  gratingMidColor, gratingBarHigh, gratingBarLow);
            [rightBarColorA, rightBarColorB] = computeGratingColors(ssvepTPredicted, gratingRightFreqHz, gratingMidColor, gratingBarHigh, gratingBarLow);

            %% Draw
            Screen('FillRect', window, grey);
            if brickActive
                Screen('FillRect', window, brickBorderColor, ...
                    [brickRect(1) - brickBorderPx, brickRect(2) - brickBorderPx, ...
                     brickRect(3) + brickBorderPx, brickRect(4) + brickBorderPx]);
                Screen('FillRect', window, brickColor, brickRect);
            end
            drawPaddle(window, paddleRect, paddleGratingWidthPx, gratingBarWidthPx, ...
                leftBarColorA, leftBarColorB, rightBarColorA, rightBarColorB, ...
                paddleBodyColor, paddleBorderColor, paddleBorderPx);
            Screen('FillOval', window, ballColor, ...
                [ball.x - ball.radius, ball.y - ball.radius, ball.x + ball.radius, ball.y + ball.radius]);
            if showScore
                Screen('TextSize', window, scoreTextSize);
                DrawFormattedText(window, sprintf('%d', bricksBroken), 'center', scoreTextYPx, scoreTextColor);
            end

            % Missed-frame detection is only meaningful with real vsync timing
            % (~ismac, where SkipSyncTests is off), so it is only tracked there.
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

            %% Triggers, sent on the display time of the event they mark
            % (see the note above the frame loop). trialstart goes out on the
            % first frame the ball is visible; a bounce goes out on the frame
            % that shows the ball already rebounded / the brick already gone.
            if currentFrame == 1
                if ~ismac
                    sendNumericTrigger(paraport, trialStartTrigger);
                end
                trialStartTime = getElapsedTime(experimentStartTime);
            end
            if ~ismac
                if hitWall
                    sendNumericTrigger(paraport, wallBounceTrigger);
                end
                if hitPaddle
                    sendNumericTrigger(paraport, paddleBounceTrigger);
                end
                if hitBrick
                    sendNumericTrigger(paraport, brickBounceTrigger);
                end
            end

            %% Trace log (every traceLogIntervalFrames, ~100ms)
            % nf.txt is read every frame, but it is only rewritten externally
            % on a ~100ms cadence, so logging every frame would just repeat
            % the same unchanged value several times over.
            if mod(currentFrame - 1, traceLogIntervalFrames) == 0
                if brickActive
                    brickCenterX = (brickRect(1) + brickRect(3)) / 2;
                    brickCenterY = (brickRect(2) + brickRect(4)) / 2;
                else
                    brickCenterX = NaN;
                    brickCenterY = NaN;
                end
                traceRows(end+1, :) = [trialNumber, currentFrame, getElapsedTime(experimentStartTime), ...
                    nf19, nf23, nf23 - nf19, nfReadOk, ...
                    paddleCenterX, paddleVxPxPerFrame / interFrameInterval, ...
                    ball.x, ball.y, ball.vx / interFrameInterval, ball.vy / interFrameInterval, ball.spin, ...
                    brickActive, brickCenterX, brickCenterY, bricksBroken]; %#ok<SAGROW>
            end

            %% Trial end: the paddle missed and the ball has fully cleared the
            % open bottom edge of the field. Checked after the flip, so the
            % trialstop trigger below lands on the first display time at which
            % the ball is entirely gone.
            if ball.y - ball.radius > fieldBottom
                ballFell = true;
                break;
            end

            if checkEscape(escapeKey)
                runBlockLoop = false;
                break;
            end
        end

        %% Trial end
        if ~ismac
            sendNumericTrigger(paraport, trialStopTrigger);
        end
        trialEndTime = getElapsedTime(experimentStartTime);
        if ~runBlockLoop
            % Aborted mid-trial: trialstop is sent, but no row is written.
            break;
        end

        bricksBrokenByTrial(trialNumber) = bricksBroken;
        trialDurationByTrial(trialNumber) = trialEndTime - trialStartTime;

        %% Log trial
        fid = fopen(csvFile, 'a');
        fprintf(fid, '%d,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d\n', ...
            trialNumber, trialStartTime, trialEndTime, trialEndTime - trialStartTime, ...
            paddleBounces, wallBounces, bricksBroken, ballFell, droppedFrameCount);
        fclose(fid);

        %% Log the ~100ms game-state trace for this trial
        fid = fopen(traceCsvFile, 'a');
        for r = 1:size(traceRows, 1)
            fprintf(fid, traceRowFormat, traceRows(r, :));
        end
        fclose(fid);

        %% Log dropped frames for this trial (usually empty)
        fid = fopen(droppedFrameCsvFile, 'a');
        for r = 1:numel(droppedFrameNumber)
            fprintf(fid, '%d,%d,%.6f,%.6f\n', ...
                trialNumber, droppedFrameNumber(r), droppedFrameVblTime(r), droppedFrameMissedBySec(r));
        end
        fclose(fid);

        %% ITI - blank, gratings off, so the SSVEP drive stops between trials
        for itiFrame = 1:itiFrames
            Screen('FillRect', window, grey);
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
        sendNumericTrigger(paraport, trialStopTrigger);
    end
    cleanupExperiment(ismac, eyeTrackingStopped, participantInfo, blockInfo, paraport);
    rethrow(ME);
end

%% Calculate and display block results
completedTrials = ~isnan(trialDurationByTrial);
if any(completedTrials)
    totalBricksBroken = sum(bricksBrokenByTrial(completedTrials));
    meanTrialDuration = mean(trialDurationByTrial(completedTrials));
else
    totalBricksBroken = 0;
    meanTrialDuration = NaN;
end

Screen('FillRect', window, grey);
Screen('TextSize', window, 35);
performanceText = sprintf(['TESTING COMPLETED!\n\n' ...
    'BRICKS BROKEN: %d\n' ...
    'MEAN TIME BALL KEPT UP: %.2f s\n\n' ...
    'Press ESCAPE or any button to continue'], totalBricksBroken, meanTrialDuration);
DrawFormattedText(window, performanceText, 'center', 'center', black);
if ~ismac
    Screen('Flip', window, vbl + 0.5 * interFrameInterval);
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
% Sent as raw bytes via helperFunctions/sendNumericTrigger.m (see the trigger
% block in %% PARAMETERS). Values 20/30 match functions/cog_send_triggers.m's
% trialstart/trialstop; 70-72 are values that table leaves free.
% reset        -> 0   (once, at paraport open)
% trialstart   -> 20  (ball spawn)
% trialstop    -> 30  (ball falls past the bottom edge, or block aborted)
% wallbounce   -> 70  (left, right or top wall)
% paddlebounce -> 71
% brickbounce  -> 72  (brick broken)
