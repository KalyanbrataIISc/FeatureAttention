clear;
% close all;
clc;

% -------------------------------------------------------------------------
%% Single participant offline analysis
% Set one participant and training side, then run the script.
% trainingSide: 0 = left training, 1 = right training
%
% Outputs:
% 1) Participant-level offline plots matching broadbandOffline.m
% 2) Participant-only PS.m-style ongoing/evoked power spectra
% -------------------------------------------------------------------------

%% Inputs
participantNum = 55;
trainingSide   = 0;

% Optional trial exclusions for the offline testing-block analysis.
% Use [block, trial] for specific trials, or [block, 0] for a whole block.
excludedTrials = [];

% Manual bad channels. The offline pipeline defaults to none, while PS.m
% used [12 14 33]. Keep these separate so each pipeline is easy to audit.
offlineManualRemove = [33 34];
psManualRemove      = offlineManualRemove; % [12 14 33];

runPSStyleSpectra = true;
runBehaviourAnalysis = true;
printResultsReport = false;
saveResultsReportJson = false;
resultsFolderName = 'results';

behaviourResult = struct();
ps = struct();
psResult = struct();

thisScript = mfilename('fullpath');
if isempty(thisScript)
    scriptDir = pwd;
else
    scriptDir = fileparts(thisScript);
end
resultsFolder = fullfile(scriptDir, resultsFolderName);
if saveResultsReportJson && ~isfolder(resultsFolder)
    mkdir(resultsFolder);
end

%% Toolboxes
initializeSingleParticipantToolboxes();

%% Offline participant settings
offline = struct();
offline.numBlocks        = 6;
offline.trainingBlockNum = 0;       % separate GDF files were created for training vs testing blocks, so set to 0 to use all blocks in the same file
offline.numTrials        = 24;
offline.channels         = 41;      % EEG channels in the GDF, excluding STATUS
offline.FsRaw            = 4096;
offline.downsampleFactor = 32;      % 4096 / 32 = 128 Hz
offline.Fs               = offline.FsRaw / offline.downsampleFactor;
offline.prepBand         = [2 40];
offline.prepBandOrd      = 4;
offline.useNotch50       = true;
offline.reReferenceAvg   = true;
offline.manualRemove     = offlineManualRemove;
offline.runBroadbandAnalysis = false;
offline.trigStart        = 20;
offline.trigFail         = 30;
offline.trigSucc         = 50;
offline.elecSfp          = 'Biosemi_128_Cartesian_Default.sfp';

offline.spectrumWindowSec = 1;
offline.powerWindowSec    = 2;
offline.stepSec           = 0.1;
offline.windowSeconds     = 2;
offline.initialOffsetSec  = 2;
offline.timelinePoints    = 99;
offline.alphaBand         = [8 12];
offline.ssvepLeftHz       = 29;
offline.ssvepRightHz      = 23;
offline.fpass             = [5 40];
offline.baselineIdx       = 70:79;
offline.timeAxis          = (-(offline.timelinePoints - 1):0) * offline.stepSec;

alphaPairs = [
     5  32;  6  35;  7  36;  8  37;  9  38; 10  39; 11  40; 12  41;
    13  26; 14  27; 15  28; 16  29; 17  30; 18  31
];
offline.alphaLeftCh  = unique(alphaPairs(:, 1));
offline.alphaRightCh = unique(alphaPairs(:, 2));

ssvPairs = [
    28 15; 30 17; 32 5; 36 7; 38 9; 35 6; 37 8; 39 10; 40 11; 41 12;
    26 13; 27 14; 29 16; 31 18
];
offline.ssvLeftCh  = unique(ssvPairs(:, 2));
offline.ssvRightCh = unique(ssvPairs(:, 1));

[offline.bBP, offline.aBP] = butter(4, offline.fpass / (offline.Fs / 2), 'bandpass');

offline.chronuxParams1s          = struct();
offline.chronuxParams1s.Fs       = offline.Fs;
offline.chronuxParams1s.tapers   = [1 1];
offline.chronuxParams1s.pad      = 1;
offline.chronuxParams1s.err      = 0;
offline.chronuxParams1s.trialave = 0;
offline.chronuxParams1s.fpass    = offline.fpass;
offline.chronuxParams2s          = offline.chronuxParams1s;

behaviour = struct();
behaviour.numBlocks             = offline.numBlocks;
behaviour.trainingBlockNum      = offline.trainingBlockNum;
behaviour.analyseTrainingBlocks = false; % false = use b04-b09 testing blocks only
behaviour.numTrials             = offline.numTrials;
behaviour.requireValidTrials    = false; % failed NF trials are marked IsValidTrial = 0
behaviour.excludeTimeoutRT      = true;
behaviour.alphaNFThreshold      = 0.1;
behaviour.ssvepNFThreshold      = -0.001;
behaviour.nfHoldProportion      = 0.6;
behaviour.nfHoldWindowSec       = 2;
behaviour.csvSampleDtSec        = 0.1;
behaviour.conditionLabels       = { ...
    'Lat. Alpha, not SSVEP', ...
    'Lat. SSVEP, not Alpha', ...
    'Not lat.', ...
    'Successful'};

%% Classify trials and run behaviour analysis
if runBehaviourAnalysis
    behaviourResult = processSingleParticipantBehaviour( ...
        participantNum, trainingSide, excludedTrials, behaviour);
    plotSingleParticipantBehaviour(behaviourResult);
end

%% Run offline participant plots
offlineResult = processSingleOfflineParticipant( ...
    participantNum, trainingSide, excludedTrials, offline, false);
offlineResult.conditionCode = 4;
offlineResult.conditionLabel = behaviour.conditionLabels{4};
offlineResult.conditionShortLabel = 'successful';
plotSingleOfflineParticipant(offlineResult, trainingSide, offline);
failedOfflineResult = processSingleOfflineParticipant( ...
    participantNum, trainingSide, excludedTrials, offline, true);
fprintf('Participant %d: Successful trials = %d / %d, Failed trials = %d / %d\n', ...
    participantNum, offlineResult.successfulTrialCount, offlineResult.totalTrialCount, ...
    failedOfflineResult.failedTrialCount, failedOfflineResult.totalTrialCount);

failedClassResults = repmat(emptyOfflineResult(participantNum, offline.timelinePoints), 3, 1);
if runBehaviourAnalysis && behaviourResult.hasClassification
    failedClassResults = splitFailedOfflineResult( ...
        failedOfflineResult, behaviourResult.eegConditionCodes, behaviour.conditionLabels, offline);
    for classIdx = 1:3
        plotSingleOfflineParticipant(failedClassResults(classIdx), trainingSide, offline, ...
            failedClassResults(classIdx).conditionShortLabel);
    end
    plotOfflineConditionComparison( ...
        [failedClassResults; offlineResult], behaviour.conditionLabels, trainingSide, offline);
else
    warning(['Failed-trial subtype EEG plots were not created because trial classification ' ...
        'was unavailable.']);
end

%% Run PS.m-style participant spectra
if runPSStyleSpectra
    ps = struct();
    ps.channels          = 41;
    ps.Fs                = 4096;
    ps.downsampleFactor  = 16;      % PS.m uses 256 Hz
    ps.FsDs              = ps.Fs / ps.downsampleFactor;
    ps.bpFreq            = [2 40];
    ps.bpOrd             = 4;
    ps.useNotch50        = true;
    ps.epochLenSec       = 3;
    ps.removeTrialsIdx   = [];
    ps.reReferenceAvg    = true;
    ps.normMode          = 'rel-mean';
    ps.ssvepLeftHz       = offline.ssvepLeftHz;
    ps.ssvepRightHz      = offline.ssvepRightHz;
    ps.leftChs           = [5 7 9 15 17];
    ps.rightChs          = [28 30 32 36 38];
    ps.manualRemove      = psManualRemove;
    ps.trigStart         = 20;
    ps.trigFail          = 30;
    ps.trigSucc          = 50;
    ps.elecSfp           = 'Biosemi_128_Cartesian_Default.sfp';

    psResult = processSinglePSSpectra(participantNum, ps);
    plotSinglePSSpectra(psResult);
end

if printResultsReport || saveResultsReportJson
    reportName = sprintf('singleParticipantOffline_P%d', participantNum);
    report = buildSingleParticipantOfflineReport( ...
        participantNum, trainingSide, excludedTrials, offline, offlineResult, failedOfflineResult, ...
        runBehaviourAnalysis, behaviour, behaviourResult, runPSStyleSpectra, ps, psResult);
    if printResultsReport
        printAnalysisJsonReport(reportName, report);
    end
    if saveResultsReportJson
        saveAnalysisJsonReport(reportName, report, resultsFolder);
    end
end

% -------------------------------------------------------------------------
%% Offline participant processing
% -------------------------------------------------------------------------
function result = processSingleOfflineParticipant(participantNum, trainingSide, excludedTrials, settings, targetFailed)
sideLabel = ternary(trainingSide == 0, 'Left', 'Right');
fprintf('Processing participant %d (training side: %s)\n', participantNum, sideLabel);

if ~isempty(excludedTrials) && size(excludedTrials, 2) ~= 2
    error('excludedTrials must be an Nx2 matrix [block, trial].');
end

timelinePoints = settings.timelinePoints;
result = emptyOfflineResult(participantNum, timelinePoints);
result.targetFailed = targetFailed;

filename = buildParticipantFilename(participantNum);
if ~isfile(filename)
    error('Participant %d: GDF file not found: %s', participantNum, filename);
end

cfg = [];
cfg.dataset = filename;
cfg.channel = 2:(settings.channels + 1); % exclude STATUS
dat = ft_preprocessing(cfg);

cfg1 = [];
cfg1.demean     = 'yes';
cfg1.resamplefs = settings.Fs;
dat = ft_resampledata(cfg1, dat);

cfg2 = [];
cfg2.bpfilter   = 'yes';
cfg2.bpfreq     = settings.prepBand;
cfg2.bpfiltord  = settings.prepBandOrd;
cfg2.bpfilttype = 'but';
if settings.useNotch50
    cfg2.dftfilter = 'yes';
    cfg2.dftfreq   = 50;
end
dat = ft_preprocessing(cfg2, dat);
dataFilt = dat.trial{1};

[sensAutoBad, ~, badTimePoints] = my_nt_find_bad_channels( ...
    dataFilt(1:settings.channels, :)', 0.33, 4, [], 4);
if numel(sensAutoBad) > 15
    [~, idx] = sort(badTimePoints, 'descend');
    sensAutoBad = sort(idx(1:15));
end
sensorsToRemove = unique([sensAutoBad(:).' settings.manualRemove(:).']);
result.sensorsToRemove = sensorsToRemove;
fprintf('  Bad/removed channels: %s\n', mat2str(sensorsToRemove));

datRep = dat;
if ~isempty(sensorsToRemove)
    cfgN = [];
    cfgN.method  = 'triangulation';
    cfgN.elec    = ft_read_sens(settings.elecSfp);
    cfgN.channel = dat.label(1:settings.channels);
    neighbours   = ft_prepare_neighbours(cfgN);

    cfgR = [];
    cfgR.badchannel = dat.label(sensorsToRemove);
    cfgR.neighbours = neighbours;
    cfgR.elec       = ft_read_sens(settings.elecSfp);
    cfgR.method     = 'spline';
    cfgR.senstype   = 'eeg';
    datRep = ft_channelrepair(cfgR, dat);
end

if settings.reReferenceAvg
    cfgRef = [];
    cfgRef.reref      = 'yes';
    cfgRef.refmethod  = 'avg';
    cfgRef.refchannel = 1:settings.channels;
    datRep = ft_preprocessing(cfgRef, datRep);
end
dataCont = double(datRep.trial{1});

events = ft_read_event(filename);
events = events(strcmp({events.type}, 'STATUS'));
vals = [events.value];
samp = [events.sample];

alphaSum   = zeros(2, timelinePoints);
alphaSumSq = zeros(2, timelinePoints);
alphaCount = zeros(2, timelinePoints);
ssvSum     = zeros(2, timelinePoints);
ssvSumSq   = zeros(2, timelinePoints);
ssvCount   = zeros(2, timelinePoints);
bbSum      = zeros(2, timelinePoints);
bbSumSq    = zeros(2, timelinePoints);
bbCount    = zeros(2, timelinePoints);
bbNASum    = zeros(2, timelinePoints);
bbNASumSq  = zeros(2, timelinePoints);
bbNACount  = zeros(2, timelinePoints);
spectLeftSum    = [];
spectLeftCount  = [];
spectRightSum   = [];
spectRightCount = [];

alphaInitTrials = [];
alphaFinalTrials = [];
ssvInitTrials = [];
ssvFinalTrials = [];
trialBlocks = [];
trialNumbers = [];
alphaTrialSeries = [];
ssvTrialSeries = [];
powerInitLeftTrials = [];
powerInitRightTrials = [];
powerFinalLeftTrials = [];
powerFinalRightTrials = [];

ipsiSSVCh   = ternary(trainingSide == 0, settings.ssvLeftCh, settings.ssvRightCh);
contraSSVCh = ternary(trainingSide == 0, settings.ssvRightCh, settings.ssvLeftCh);

nWin = round(settings.spectrumWindowSec * settings.Fs);
nStep = round(settings.stepSec * settings.Fs);
powerWin = round(settings.powerWindowSec * settings.Fs);
trialCounter = 0;
usedTrialCount = 0;

for k = 1:numel(vals)
    if vals(k) ~= settings.trigStart
        continue;
    end

    j = k + 1;
    while j <= numel(vals) && ~ismember(vals(j), [settings.trigSucc, settings.trigFail])
        j = j + 1;
    end
    if j > numel(vals)
        continue;
    end

    trialCounter = trialCounter + 1;
    blockNum = ceil(trialCounter / settings.numTrials);
    trialNum = trialCounter - (blockNum - 1) * settings.numTrials;
    if blockNum > settings.numBlocks
        break;
    end
    if blockNum <= settings.trainingBlockNum
        continue;
    end
    if isTrialExcluded(excludedTrials, blockNum, trialNum)
        fprintf('  Skipping excluded trial: Block %d, Trial %d\n', blockNum, trialNum);
        continue;
    end
    result.totalTrialCount = result.totalTrialCount + 1;
    isFailedTrial = vals(j) == settings.trigFail;
    if isFailedTrial
        result.failedTrialCount = result.failedTrialCount + 1;
    else
        result.successfulTrialCount = result.successfulTrialCount + 1;
    end
    if isFailedTrial ~= targetFailed
        continue;
    end

    begDs = rawToDownsampledSample(samp(k), settings.downsampleFactor);
    endDs = rawToDownsampledSample(samp(j), settings.downsampleFactor);
    begDs = max(1, begDs);
    endDs = min(size(dataCont, 2), endDs);
    if endDs - begDs + 1 < nWin
        continue;
    end

    trialData = dataCont(:, begDs:endDs);
    windowEnds = fliplr(size(trialData, 2):-nStep:nWin);
    nTime = numel(windowEnds);
    if nTime == 0
        continue;
    end
    usedTrialCount = usedTrialCount + 1;

    alphaSeries = nan(2, nTime);
    ssvSeries   = nan(2, nTime);
    bbSeries    = nan(2, nTime);
    bbNASeries  = nan(2, nTime);
    spectLeftSeries = [];
    spectRightSeries = [];

    alphaMask = [];
    idxSsvepLeft = [];
    idxSsvepRight = [];

    for tp = 1:nTime
        endIdx = windowEnds(tp);
        segment = trialData(:, endIdx - nWin + 1:endIdx);
        segment = prepareWindowSegment(segment, settings.bBP, settings.aBP);
        [psd, freqs] = mtspectrumc(segment.', settings.chronuxParams1s);

        if isempty(alphaMask)
            alphaMask = freqs >= settings.alphaBand(1) & freqs <= settings.alphaBand(2);
            [~, idxSsvepLeft] = min(abs(freqs - settings.ssvepLeftHz));
            [~, idxSsvepRight] = min(abs(freqs - settings.ssvepRightHz));
            result.spectFreqs = freqs;
        end

        alphaLeft  = mean(psd(alphaMask, settings.alphaLeftCh), 'all', 'omitnan');
        alphaRight = mean(psd(alphaMask, settings.alphaRightCh), 'all', 'omitnan');
        ssvLeft  = mean(psd(idxSsvepLeft, settings.ssvLeftCh) ./ ...
            mean(psd([idxSsvepLeft - 1, idxSsvepLeft + 1], settings.ssvLeftCh), 1), 'all', 'omitnan');
        ssvRight = mean(psd(idxSsvepRight, settings.ssvRightCh) ./ ...
            mean(psd([idxSsvepRight - 1, idxSsvepRight + 1], settings.ssvRightCh), 1), 'all', 'omitnan');
        % ssvLeft  = mean(psd(idxSsvepLeft, settings.ssvLeftCh) ./ ...
        %     mean(psd(~alphaMask, settings.ssvLeftCh), 1), 'all', 'omitnan');
        % ssvRight = mean(psd(idxSsvepRight, settings.ssvRightCh) ./ ...
        %     mean(psd(~alphaMask, settings.ssvRightCh), 1), 'all', 'omitnan');

        if trainingSide == 0
            alphaSeries(:, tp) = log([alphaLeft; alphaRight]);
            ssvSeries(:, tp)   = log([ssvLeft; ssvRight]);
        else
            alphaSeries(:, tp) = log([alphaRight; alphaLeft]);
            ssvSeries(:, tp)   = log([ssvRight; ssvLeft]);
        end

        if settings.runBroadbandAnalysis
            bbSeries(:, tp) = [log(mean(psd(:, ipsiSSVCh), 'all', 'omitnan')); ...
                               log(mean(psd(:, contraSSVCh), 'all', 'omitnan'))];
            bbNASeries(:, tp) = [log(mean(psd(~alphaMask, ipsiSSVCh), 'all', 'omitnan')); ...
                                 log(mean(psd(~alphaMask, contraSSVCh), 'all', 'omitnan'))];
        end

        spLeft = log(mean(psd(:, settings.ssvLeftCh), 2, 'omitnan'));
        spRight = log(mean(psd(:, settings.ssvRightCh), 2, 'omitnan'));
        if isempty(spectLeftSeries)
            spectLeftSeries = nan(numel(spLeft), nTime);
            spectRightSeries = nan(numel(spRight), nTime);
        end
        spectLeftSeries(:, tp) = spLeft;
        spectRightSeries(:, tp) = spRight;
    end

    nUse = min(nTime, timelinePoints);
    idx = (timelinePoints - nUse + 1):timelinePoints;

    [alphaSum, alphaSumSq, alphaCount] = addTrialSeries(alphaSum, alphaSumSq, alphaCount, ...
        alphaSeries(:, end - nUse + 1:end), idx);
    [ssvSum, ssvSumSq, ssvCount] = addTrialSeries(ssvSum, ssvSumSq, ssvCount, ...
        ssvSeries(:, end - nUse + 1:end), idx);
    if settings.runBroadbandAnalysis
        [bbSum, bbSumSq, bbCount] = addTrialSeries(bbSum, bbSumSq, bbCount, ...
            bbSeries(:, end - nUse + 1:end), idx);
        [bbNASum, bbNASumSq, bbNACount] = addTrialSeries(bbNASum, bbNASumSq, bbNACount, ...
            bbNASeries(:, end - nUse + 1:end), idx);
    end

    if ~isempty(spectLeftSeries)
        spLeftSeg = spectLeftSeries(:, end - nUse + 1:end);
        spRightSeg = spectRightSeries(:, end - nUse + 1:end);
        if isempty(spectLeftSum)
            nFreq = size(spLeftSeg, 1);
            spectLeftSum    = zeros(nFreq, timelinePoints);
            spectLeftCount  = zeros(nFreq, timelinePoints);
            spectRightSum   = zeros(nFreq, timelinePoints);
            spectRightCount = zeros(nFreq, timelinePoints);
        end
        [spectLeftSum, spectLeftCount] = addSpectralTrial(spectLeftSum, spectLeftCount, spLeftSeg, idx);
        [spectRightSum, spectRightCount] = addSpectralTrial(spectRightSum, spectRightCount, spRightSeg, idx);
    end

    winSamples = min(round(settings.windowSeconds / settings.stepSec), nTime);
    initialOffsetSamples = round(settings.initialOffsetSec / settings.stepSec);
    initEndIdx = max(1, nTime - initialOffsetSamples);
    initStartIdx = max(1, initEndIdx - winSamples + 1);

    alphaInitTrials(end + 1, :) = mean(alphaSeries(:, initStartIdx:initEndIdx), 2, 'omitnan').'; %#ok<AGROW>
    alphaFinalTrials(end + 1, :) = mean(alphaSeries(:, end - winSamples + 1:end), 2, 'omitnan').'; %#ok<AGROW>
    ssvInitTrials(end + 1, :) = mean(ssvSeries(:, initStartIdx:initEndIdx), 2, 'omitnan').'; %#ok<AGROW>
    ssvFinalTrials(end + 1, :) = mean(ssvSeries(:, end - winSamples + 1:end), 2, 'omitnan').'; %#ok<AGROW>
    trialBlocks(end + 1, 1) = blockNum; %#ok<AGROW>
    trialNumbers(end + 1, 1) = trialNum; %#ok<AGROW>
    alphaTrialSeries(end + 1, :, :) = nan(1, 2, timelinePoints); %#ok<AGROW>
    ssvTrialSeries(end + 1, :, :) = nan(1, 2, timelinePoints); %#ok<AGROW>
    alphaTrialSeries(end, :, idx) = reshape( ...
        alphaSeries(:, end - nUse + 1:end), 1, 2, nUse);
    ssvTrialSeries(end, :, idx) = reshape( ...
        ssvSeries(:, end - nUse + 1:end), 1, 2, nUse);

    if size(trialData, 2) >= powerWin
        [psdPower, powerFreqs] = computeWindowSpectrum(trialData(:, end - powerWin + 1:end), settings);
        result.powerFreqs = powerFreqs;
        powerFinalLeftTrials(end + 1, :) = mean(psdPower(:, settings.ssvLeftCh), 2, 'omitnan').'; %#ok<AGROW>
        powerFinalRightTrials(end + 1, :) = mean(psdPower(:, settings.ssvRightCh), 2, 'omitnan').'; %#ok<AGROW>
    end

    if size(trialData, 2) >= 2 * powerWin
        [psdPower, powerFreqs] = computeWindowSpectrum( ...
            trialData(:, end - 2 * powerWin + 1:end - powerWin), settings);
        result.powerFreqs = powerFreqs;
        powerInitLeftTrials(end + 1, :) = mean(psdPower(:, settings.ssvLeftCh), 2, 'omitnan').'; %#ok<AGROW>
        powerInitRightTrials(end + 1, :) = mean(psdPower(:, settings.ssvRightCh), 2, 'omitnan').'; %#ok<AGROW>
    end
end

outcomeLabel = ternary(targetFailed, 'failed', 'successful');
fprintf('  Used %d %s testing trial(s).\n', usedTrialCount, outcomeLabel);
result.usedTrialCount = usedTrialCount;
if usedTrialCount == 0
    warning('No %s testing trials were available for participant %d.', outcomeLabel, participantNum);
    return;
end

alphaMu = alphaSum ./ max(alphaCount, 1);
alphaMu(alphaCount == 0) = NaN;
ssvMu = ssvSum ./ max(ssvCount, 1);
ssvMu(ssvCount == 0) = NaN;
if settings.runBroadbandAnalysis
    bbMu = bbSum ./ max(bbCount, 1);
    bbMu(bbCount == 0) = NaN;
    bbNAMu = bbNASum ./ max(bbNACount, 1);
    bbNAMu(bbNACount == 0) = NaN;
end

result.alphaMuBc = alphaMu - nanmean(alphaMu(:, settings.baselineIdx), 2);
result.alphaSemBc = computeSemFromSums(alphaSum, alphaSumSq, alphaCount);
result.ssvMuBc = ssvMu - nanmean(ssvMu(:, settings.baselineIdx), 2);
result.ssvSemBc = computeSemFromSums(ssvSum, ssvSumSq, ssvCount);
if settings.runBroadbandAnalysis
    result.bbMuBc = bbMu - nanmean(bbMu(:, settings.baselineIdx), 2);
    result.bbSemBc = computeSemFromSums(bbSum, bbSumSq, bbCount);
    result.bbNAMuBc = bbNAMu - nanmean(bbNAMu(:, settings.baselineIdx), 2);
    result.bbNASemBc = computeSemFromSums(bbNASum, bbNASumSq, bbNACount);
end

if ~isempty(spectLeftSum)
    spectLeftMu = spectLeftSum ./ max(spectLeftCount, 1);
    spectRightMu = spectRightSum ./ max(spectRightCount, 1);
    spectLeftMu(spectLeftCount == 0) = NaN;
    spectRightMu(spectRightCount == 0) = NaN;
    result.spectLeftTs = spectLeftMu - nanmean(spectLeftMu(:, settings.baselineIdx), 2);
    result.spectRightTs = spectRightMu - nanmean(spectRightMu(:, settings.baselineIdx), 2);
end

if ~isempty(alphaInitTrials)
    muInitAlpha = mean(alphaInitTrials, 1, 'omitnan');
    deltaAlpha = muInitAlpha(2) - muInitAlpha(1);
    result.alphaFinalCorrTrials = [alphaFinalTrials(:, 1), alphaFinalTrials(:, 2) - deltaAlpha];
end

if ~isempty(ssvInitTrials)
    muInitSSV = mean(ssvInitTrials, 1, 'omitnan');
    deltaSSV = muInitSSV(2) - muInitSSV(1);
    result.ssvFinalCorrTrials = [ssvFinalTrials(:, 1), ssvFinalTrials(:, 2) - deltaSSV];
end

result.trialBlocks = trialBlocks;
result.trialNumbers = trialNumbers;
result.alphaTrialSeries = alphaTrialSeries;
result.ssvTrialSeries = ssvTrialSeries;
result.alphaInitTrials = alphaInitTrials;
result.alphaFinalTrials = alphaFinalTrials;
result.ssvInitTrials = ssvInitTrials;
result.ssvFinalTrials = ssvFinalTrials;

if ~isempty(powerInitLeftTrials)
    result.powerInitLeft = mean(powerInitLeftTrials, 1, 'omitnan');
    result.powerInitLeftSem = computeSemFromTrials(powerInitLeftTrials);
    result.powerInitRight = mean(powerInitRightTrials, 1, 'omitnan');
    result.powerInitRightSem = computeSemFromTrials(powerInitRightTrials);
end
if ~isempty(powerFinalLeftTrials)
    result.powerFinalLeft = mean(powerFinalLeftTrials, 1, 'omitnan');
    result.powerFinalLeftSem = computeSemFromTrials(powerFinalLeftTrials);
    result.powerFinalRight = mean(powerFinalRightTrials, 1, 'omitnan');
    result.powerFinalRightSem = computeSemFromTrials(powerFinalRightTrials);
end
end

function result = emptyOfflineResult(participantNum, timelinePoints)
result = struct( ...
    'participantNum', participantNum, ...
    'targetFailed', false, ...
    'conditionCode', NaN, ...
    'conditionLabel', '', ...
    'conditionShortLabel', '', ...
    'totalTrialCount', 0, ...
    'successfulTrialCount', 0, ...
    'failedTrialCount', 0, ...
    'usedTrialCount', 0, ...
    'sensorsToRemove', [], ...
    'spectFreqs', [], ...
    'alphaMuBc', nan(2, timelinePoints), ...
    'alphaSemBc', nan(2, timelinePoints), ...
    'ssvMuBc', nan(2, timelinePoints), ...
    'ssvSemBc', nan(2, timelinePoints), ...
    'bbMuBc', nan(2, timelinePoints), ...
    'bbSemBc', nan(2, timelinePoints), ...
    'bbNAMuBc', nan(2, timelinePoints), ...
    'bbNASemBc', nan(2, timelinePoints), ...
    'spectLeftTs', [], ...
    'spectRightTs', [], ...
    'alphaFinalCorrTrials', [], ...
    'ssvFinalCorrTrials', [], ...
    'trialBlocks', [], ...
    'trialNumbers', [], ...
    'alphaTrialSeries', [], ...
    'ssvTrialSeries', [], ...
    'alphaInitTrials', [], ...
    'alphaFinalTrials', [], ...
    'ssvInitTrials', [], ...
    'ssvFinalTrials', [], ...
    'powerFreqs', [], ...
    'powerInitLeft', [], ...
    'powerInitLeftSem', [], ...
    'powerInitRight', [], ...
    'powerInitRightSem', [], ...
    'powerFinalLeft', [], ...
    'powerFinalLeftSem', [], ...
    'powerFinalRight', [], ...
    'powerFinalRightSem', []);
end

function classResults = splitFailedOfflineResult(failedResult, conditionCodes, conditionLabels, settings)
shortLabels = {'failed_alpha_only', 'failed_ssvep_only', 'failed_not_lateralized'};
classResults = repmat(emptyOfflineResult(failedResult.participantNum, settings.timelinePoints), 3, 1);

nTrials = numel(failedResult.trialBlocks);
trialCodes = nan(nTrials, 1);
for trialIdx = 1:nTrials
    blockNum = failedResult.trialBlocks(trialIdx);
    trialNum = failedResult.trialNumbers(trialIdx);
    if blockNum >= 1 && blockNum <= size(conditionCodes, 1) && ...
            trialNum >= 1 && trialNum <= size(conditionCodes, 2)
        trialCodes(trialIdx) = conditionCodes(blockNum, trialNum);
    end
end

for classIdx = 1:3
    trialMask = trialCodes == classIdx;
    result = emptyOfflineResult(failedResult.participantNum, settings.timelinePoints);
    result.targetFailed = true;
    result.conditionCode = classIdx;
    result.conditionLabel = conditionLabels{classIdx};
    result.conditionShortLabel = shortLabels{classIdx};
    result.totalTrialCount = failedResult.totalTrialCount;
    result.failedTrialCount = nnz(trialMask);
    result.successfulTrialCount = failedResult.successfulTrialCount;
    result.usedTrialCount = nnz(trialMask);
    result.sensorsToRemove = failedResult.sensorsToRemove;
    result.spectFreqs = failedResult.spectFreqs;

    result.trialBlocks = failedResult.trialBlocks(trialMask);
    result.trialNumbers = failedResult.trialNumbers(trialMask);
    result.alphaTrialSeries = failedResult.alphaTrialSeries(trialMask, :, :);
    result.ssvTrialSeries = failedResult.ssvTrialSeries(trialMask, :, :);
    result.alphaInitTrials = failedResult.alphaInitTrials(trialMask, :);
    result.alphaFinalTrials = failedResult.alphaFinalTrials(trialMask, :);
    result.ssvInitTrials = failedResult.ssvInitTrials(trialMask, :);
    result.ssvFinalTrials = failedResult.ssvFinalTrials(trialMask, :);

    [result.alphaMuBc, result.alphaSemBc] = summarizeOfflineTrialSeries( ...
        result.alphaTrialSeries, settings.baselineIdx, settings.timelinePoints);
    [result.ssvMuBc, result.ssvSemBc] = summarizeOfflineTrialSeries( ...
        result.ssvTrialSeries, settings.baselineIdx, settings.timelinePoints);
    result.alphaFinalCorrTrials = baselineCorrectFinalPairs( ...
        result.alphaInitTrials, result.alphaFinalTrials);
    result.ssvFinalCorrTrials = baselineCorrectFinalPairs( ...
        result.ssvInitTrials, result.ssvFinalTrials);

    fprintf('  Failed class %-24s: %d trial(s)\n', conditionLabels{classIdx}, nnz(trialMask));
    classResults(classIdx) = result;
end

unclassifiedMask = ~isfinite(trialCodes);
if any(unclassifiedMask)
    missingPairs = [failedResult.trialBlocks(unclassifiedMask), failedResult.trialNumbers(unclassifiedMask)];
    warning('%d failed EEG trial(s) had no matching behavioural class: %s', ...
        nnz(unclassifiedMask), mat2str(missingPairs));
end
end

function [muBc, semVals] = summarizeOfflineTrialSeries(trialSeries, baselineIdx, timelinePoints)
muBc = nan(2, timelinePoints);
semVals = nan(2, timelinePoints);
if isempty(trialSeries)
    return;
end

nTrials = size(trialSeries, 1);
series = reshape(trialSeries, nTrials, 2, timelinePoints);
for sideIdx = 1:2
    sideSeries = reshape(series(:, sideIdx, :), nTrials, timelinePoints);
    muVals = mean(sideSeries, 1, 'omitnan');
    muBc(sideIdx, :) = muVals - mean(muVals(baselineIdx), 'omitnan');
    semVals(sideIdx, :) = computeSemFromTrials(sideSeries);
end
end

function correctedPairs = baselineCorrectFinalPairs(initialPairs, finalPairs)
correctedPairs = [];
if isempty(initialPairs) || isempty(finalPairs)
    return;
end
baselineDifference = mean(initialPairs(:, 2) - initialPairs(:, 1), 'omitnan');
correctedPairs = [finalPairs(:, 1), finalPairs(:, 2) - baselineDifference];
end

% -------------------------------------------------------------------------
%% Behaviour processing
% -------------------------------------------------------------------------
function result = processSingleParticipantBehaviour(participantNum, trainingSide, excludedTrials, settings)
fprintf('Processing participant %d behaviour\n', participantNum);

if ~isempty(excludedTrials) && size(excludedTrials, 2) ~= 2
    error('excludedTrials must be an Nx2 matrix [block, trial].');
end

result = emptyBehaviourResult(participantNum, settings.numBlocks, settings.numTrials);
result.trainingSide = trainingSide;
result.analyseTrainingBlocks = settings.analyseTrainingBlocks;
result.conditionLabels = settings.conditionLabels;

participantDir = buildParticipantFolder(participantNum);
result.participantDir = participantDir;
csvFiles = dir(fullfile(participantDir, sprintf('p%d_b*_trialdata.csv', participantNum)));
if isempty(csvFiles)
    warning('Participant %d: no behaviour CSV files found under %s', participantNum, participantDir);
    return;
end

csvBlockNumbers = arrayfun(@(f) parseBehaviourBlockNumber(f.name), csvFiles);
validFiles = isfinite(csvBlockNumbers);
csvFiles = csvFiles(validFiles);
csvBlockNumbers = csvBlockNumbers(validFiles);
[csvBlockNumbers, sortIdx] = sort(csvBlockNumbers);
csvFiles = csvFiles(sortIdx);
if numel(csvFiles) > settings.numBlocks
    keepIdx = (numel(csvFiles) - settings.numBlocks + 1):numel(csvFiles);
    csvFiles = csvFiles(keepIdx);
    csvBlockNumbers = csvBlockNumbers(keepIdx);
end
result.csvBlockNumbers = csvBlockNumbers;

accuracyTrialsByBlock = cell(settings.numBlocks, 2, 4);
rtTrialsByBlock = cell(settings.numBlocks, 2, 4);
bothCriteriaFailed = [];

for fileIdx = 1:numel(csvFiles)
    analysisBlockNum = fileIdx;
    csvPath = fullfile(csvFiles(fileIdx).folder, csvFiles(fileIdx).name);
    T = readtable(csvPath, 'VariableNamingRule', 'preserve');
    if isempty(T)
        continue;
    end

    trialIdx = numericBehaviourColumn(T, {'trialIdx', 'TrialNumber'}, csvPath, true);
    trialSuccess = numericBehaviourColumn(T, {'trialSuccess', 'TrialSuccessByNF'}, csvPath, true);
    cueSide = stringBehaviourColumn(T, {'cueSide'}, csvPath, true);
    accuracy = numericBehaviourColumn(T, {'accuracy'}, csvPath, true);
    reactionTime = numericBehaviourColumn(T, {'reactionTime'}, csvPath, true);
    responseTimeout = numericBehaviourColumn(T, {'responseTimeout'}, csvPath, false);
    isValidTrial = numericBehaviourColumn(T, {'IsValidTrial'}, csvPath, false);
    alphaNF = numericBehaviourColumn(T, {'NF'}, csvPath, false);
    ssvepNF = numericBehaviourColumn(T, {'NF_SSVEP'}, csvPath, false);

    uniqueTrials = unique(trialIdx(isfinite(trialIdx)), 'stable');
    for uniqueTrialIdx = 1:numel(uniqueTrials)
        trialNum = uniqueTrials(uniqueTrialIdx);
        if trialNum < 1 || trialNum > settings.numTrials || ...
                isTrialExcluded(excludedTrials, analysisBlockNum, trialNum)
            continue;
        end

        trialRows = trialIdx == trialNum;
        if settings.requireValidTrials && ~isempty(isValidTrial) && ...
                firstFiniteValue(isValidTrial(trialRows)) == 0
            continue;
        end

        successValue = firstFiniteValue(trialSuccess(trialRows));
        isSuccess = isfinite(successValue) && successValue ~= 0;
        alphaProportion = NaN;
        ssvepProportion = NaN;
        if isSuccess
            conditionCode = 4;
        elseif ~isempty(alphaNF) && ~isempty(ssvepNF)
            [conditionCode, alphaProportion, ssvepProportion, metBoth] = ...
                classifyFailedTrial(alphaNF(trialRows), ssvepNF(trialRows), settings);
            if metBoth
                bothCriteriaFailed(end + 1, :) = [analysisBlockNum, trialNum]; %#ok<AGROW>
            end
        else
            conditionCode = 3;
        end

        result.eegConditionCodes(analysisBlockNum, trialNum) = conditionCode;
        result.alphaHoldProportion(analysisBlockNum, trialNum) = alphaProportion;
        result.ssvepHoldProportion(analysisBlockNum, trialNum) = ssvepProportion;

        trialCue = firstNonmissingString(cueSide(trialRows));
        if isIpsiCue(trialCue, trainingSide)
            sideIdx = 1;
        elseif isContraCue(trialCue, trainingSide)
            sideIdx = 2;
        else
            warning('Unknown cue side for analysis block %d, trial %d in %s.', ...
                analysisBlockNum, trialNum, csvPath);
            continue;
        end

        result.trialCounts(analysisBlockNum, sideIdx, conditionCode) = ...
            result.trialCounts(analysisBlockNum, sideIdx, conditionCode) + 1;

        trialAccuracy = firstFiniteValue(accuracy(trialRows));
        if isfinite(trialAccuracy)
            accuracyTrialsByBlock{analysisBlockNum, sideIdx, conditionCode}(end + 1, 1) = ...
                trialAccuracy * 100;
        end

        trialRT = firstFiniteValue(reactionTime(trialRows));
        trialTimeout = NaN;
        if ~isempty(responseTimeout)
            trialTimeout = firstFiniteValue(responseTimeout(trialRows));
        end
        includeRT = isfinite(trialRT);
        if settings.excludeTimeoutRT && isfinite(trialTimeout)
            includeRT = includeRT && trialTimeout == 0;
        end
        if includeRT
            rtTrialsByBlock{analysisBlockNum, sideIdx, conditionCode}(end + 1, 1) = trialRT;
        end
    end
end

for blockNum = 1:settings.numBlocks
    for sideIdx = 1:2
        for conditionCode = 1:4
            accVals = accuracyTrialsByBlock{blockNum, sideIdx, conditionCode};
            rtVals = rtTrialsByBlock{blockNum, sideIdx, conditionCode};
            if ~isempty(accVals)
                result.accuracyBlockMeans(blockNum, sideIdx, conditionCode) = ...
                    mean(accVals, 'omitnan');
                result.accuracyTrialValues{sideIdx, conditionCode} = ...
                    [result.accuracyTrialValues{sideIdx, conditionCode}; accVals];
            end
            if ~isempty(rtVals)
                result.rtBlockMeans(blockNum, sideIdx, conditionCode) = mean(rtVals, 'omitnan');
                result.rtTrialValues{sideIdx, conditionCode} = ...
                    [result.rtTrialValues{sideIdx, conditionCode}; rtVals];
            end
        end
    end
end

[result.accuracyMean, result.accuracySem, result.accuracyNBlocks] = ...
    summarizeBlockMetric(result.accuracyBlockMeans);
[result.rtMean, result.rtSem, result.rtNBlocks] = ...
    summarizeBlockMetric(result.rtBlockMeans);
result.hasData = hasFiniteData(result.accuracyBlockMeans) || hasFiniteData(result.rtBlockMeans);
result.hasClassification = any(isfinite(result.eegConditionCodes(:)));
result.bothCriteriaFailedTrials = bothCriteriaFailed;
result.accuracyPairwise = computeBehaviourPairwise(result.accuracyBlockMeans);
result.rtPairwise = computeBehaviourPairwise(result.rtBlockMeans);

conditionCounts = squeeze(sum(sum(result.trialCounts, 1), 2));
fprintf('  Trial conditions [Alpha-only, SSVEP-only, Not-lat, Successful]: %s\n', ...
    mat2str(conditionCounts(:).'));
if ~isempty(bothCriteriaFailed)
    warning(['%d failed trial(s) met both final hold criteria and were assigned to Not lat. ' ...
        'for auditability: %s'], size(bothCriteriaFailed, 1), mat2str(bothCriteriaFailed));
end
printBehaviourPairwise('Accuracy', result.accuracyPairwise, settings.conditionLabels);
printBehaviourPairwise('Reaction time', result.rtPairwise, settings.conditionLabels);
end

function result = emptyBehaviourResult(participantNum, numBlocks, numTrials)
result = struct( ...
    'participantNum', participantNum, ...
    'participantDir', '', ...
    'trainingSide', NaN, ...
    'analyseTrainingBlocks', false, ...
    'hasData', false, ...
    'hasClassification', false, ...
    'sideLabels', {{'Ipsi', 'Contra'}}, ...
    'conditionLabels', {{}}, ...
    'csvBlockNumbers', [], ...
    'eegConditionCodes', nan(numBlocks, numTrials), ...
    'alphaHoldProportion', nan(numBlocks, numTrials), ...
    'ssvepHoldProportion', nan(numBlocks, numTrials), ...
    'bothCriteriaFailedTrials', [], ...
    'accuracyBlockMeans', nan(numBlocks, 2, 4), ...
    'rtBlockMeans', nan(numBlocks, 2, 4), ...
    'trialCounts', zeros(numBlocks, 2, 4), ...
    'accuracyTrialValues', {cell(2, 4)}, ...
    'rtTrialValues', {cell(2, 4)}, ...
    'accuracyMean', nan(2, 4), ...
    'accuracySem', nan(2, 4), ...
    'accuracyNBlocks', zeros(2, 4), ...
    'rtMean', nan(2, 4), ...
    'rtSem', nan(2, 4), ...
    'rtNBlocks', zeros(2, 4), ...
    'accuracyPairwise', struct([]), ...
    'rtPairwise', struct([]));
end

function [meanVals, semVals, nBlocks] = summarizeBlockMetric(blockVals)
nBlocks = squeeze(sum(isfinite(blockVals), 1));
meanVals = squeeze(mean(blockVals, 1, 'omitnan'));
flatVals = reshape(blockVals, size(blockVals, 1), []);
semVals = reshape(computeSemFromTrials(flatVals), size(meanVals));
end

function [conditionCode, alphaProportion, ssvepProportion, metBoth] = ...
        classifyFailedTrial(alphaNF, ssvepNF, settings)
validSamples = isfinite(alphaNF) & isfinite(ssvepNF);
alphaNF = alphaNF(validSamples);
ssvepNF = ssvepNF(validSamples);
windowSamples = max(1, round(settings.nfHoldWindowSec / settings.csvSampleDtSec));

alphaProportion = finalHoldProportion(alphaNF >= settings.alphaNFThreshold, windowSamples);
ssvepProportion = finalHoldProportion(ssvepNF < settings.ssvepNFThreshold, windowSamples);
alphaLateralized = alphaProportion >= settings.nfHoldProportion;
ssvepLateralized = ssvepProportion >= settings.nfHoldProportion;
metBoth = alphaLateralized && ssvepLateralized;

if alphaLateralized && ~ssvepLateralized
    conditionCode = 1;
elseif ssvepLateralized && ~alphaLateralized
    conditionCode = 2;
else
    conditionCode = 3;
end
end

function proportion = finalHoldProportion(hitMask, windowSamples)
if isempty(hitMask)
    proportion = NaN;
    return;
end
nUse = min(numel(hitMask), windowSamples);
proportion = sum(hitMask(end - nUse + 1:end)) / windowSamples;
end

function value = firstFiniteValue(values)
value = NaN;
idx = find(isfinite(values), 1, 'first');
if ~isempty(idx)
    value = values(idx);
end
end

function value = firstNonmissingString(values)
value = "";
values = string(values);
idx = find(~ismissing(values) & strlength(strtrim(values)) > 0, 1, 'first');
if ~isempty(idx)
    value = lower(strtrim(values(idx)));
end
end

function comparisons = computeBehaviourPairwise(blockValues)
pairs = nchoosek(1:4, 2);
comparisons = repmat(struct( ...
    'pairs', pairs, ...
    'rawP', nan(size(pairs, 1), 1), ...
    'holmP', nan(size(pairs, 1), 1), ...
    'nBlocksPerCondition', zeros(1, 4), ...
    'nPairedBlocks', zeros(size(pairs, 1), 1)), 2, 1);

for sideIdx = 1:2
    pVals = nan(size(pairs, 1), 1);
    sideBlockValues = reshape(blockValues(:, sideIdx, :), size(blockValues, 1), 4);
    comparisons(sideIdx).nBlocksPerCondition = sum(isfinite(sideBlockValues), 1);
    for pairIdx = 1:size(pairs, 1)
        valsA = sideBlockValues(:, pairs(pairIdx, 1));
        valsB = sideBlockValues(:, pairs(pairIdx, 2));
        pairedMask = isfinite(valsA) & isfinite(valsB);
        comparisons(sideIdx).nPairedBlocks(pairIdx) = nnz(pairedMask);
        if nnz(pairedMask) >= 2
            pVals(pairIdx) = signrank(valsA(pairedMask), valsB(pairedMask));
        end
    end
    comparisons(sideIdx).rawP = pVals;
    comparisons(sideIdx).holmP = holmAdjustPValues(pVals);
end
end

function adjustedP = holmAdjustPValues(pVals)
adjustedP = nan(size(pVals));
validIdx = find(isfinite(pVals));
if isempty(validIdx)
    return;
end
[sortedP, order] = sort(pVals(validIdx));
m = numel(sortedP);
adjustedSorted = zeros(m, 1);
runningMax = 0;
for idx = 1:m
    runningMax = max(runningMax, (m - idx + 1) * sortedP(idx));
    adjustedSorted(idx) = min(runningMax, 1);
end
adjustedP(validIdx(order)) = adjustedSorted;
end

function printBehaviourPairwise(metricLabel, comparisons, conditionLabels)
sideLabels = {'Ipsi', 'Contra'};
sideOrder = [2 1]; % report contra first, then ipsi
fprintf('  %s paired block comparisons (signrank, Holm-adjusted p):\n', metricLabel);
for displayIdx = 1:2
    sideIdx = sideOrder(displayIdx);
    fprintf('    %s:', sideLabels{sideIdx});
    printedAny = false;
    for pairIdx = 1:size(comparisons(sideIdx).pairs, 1)
        pVal = comparisons(sideIdx).holmP(pairIdx);
        if ~isfinite(pVal)
            continue;
        end
        pair = comparisons(sideIdx).pairs(pairIdx, :);
        fprintf(' %s vs %s = %.4g (n=%d blocks);', ...
            conditionLabels{pair(1)}, conditionLabels{pair(2)}, pVal, ...
            comparisons(sideIdx).nPairedBlocks(pairIdx));
        printedAny = true;
    end
    if ~printedAny
        fprintf(' insufficient data');
    end
    fprintf('\n');
end
end


% -------------------------------------------------------------------------
%% PS.m-style participant spectra
% -------------------------------------------------------------------------
function result = processSinglePSSpectra(participantNum, settings)
fprintf('Processing participant %d for PS-style spectra\n', participantNum);

filename = buildParticipantFilename(participantNum);
if ~isfile(filename)
    error('Participant %d: GDF file not found: %s', participantNum, filename);
end

cfg = [];
cfg.dataset = filename;
cfg.channel = 2:(settings.channels + 1);
dat = ft_preprocessing(cfg);

cfg1 = [];
cfg1.demean = 'yes';
cfg1.resamplefs = settings.FsDs;
dat = ft_resampledata(cfg1, dat);

cfg2 = [];
cfg2.bpfilter = 'yes';
cfg2.bpfreq = settings.bpFreq;
cfg2.bpfiltord = settings.bpOrd;
cfg2.bpfilttype = 'but';
if settings.useNotch50
    cfg2.dftfilter = 'yes';
    cfg2.dftfreq = 50;
end
dat = ft_preprocessing(cfg2, dat);
dataFilt = dat.trial{1};

[sensAutoBad, ~, badTimePoints] = my_nt_find_bad_channels( ...
    dataFilt(1:settings.channels, :)', 0.33, 4, [], 4);
if numel(sensAutoBad) > 15
    [~, idx] = sort(badTimePoints, 'descend');
    sensAutoBad = sort(idx(1:15));
end
sensorsToRemove = unique([sensAutoBad(:).' settings.manualRemove(:).']);
fprintf('  PS bad/removed channels: %s\n', mat2str(sensorsToRemove));

cfgTr = [];
cfgTr.dataset = filename;
cfgTr.trialdef.eventtype = 'STATUS';

cfgTr.trialdef.eventvalue = {settings.trigStart};
trStart = ft_definetrial(cfgTr);

cfgTr.trialdef.eventvalue = {settings.trigSucc};
trSucc = ft_definetrial(cfgTr);

cfgTr.trialdef.eventvalue = {settings.trigFail};
trFail = ft_definetrial(cfgTr);

trStart.trl(:, 2) = sort([trSucc.trl(:, 2); trFail.trl(:, 2)]);
trStart.trl = round(trStart.trl ./ settings.downsampleFactor);

if ~isempty(settings.removeTrialsIdx)
    keep = setdiff(1:size(trStart.trl, 1), settings.removeTrialsIdx);
    trStart.trl = trStart.trl(keep, :);
end

datAll = ft_redefinetrial(trStart, dat);

datRep = datAll;
if ~isempty(sensorsToRemove)
    cfgN = [];
    cfgN.method = 'triangulation';
    cfgN.elec = ft_read_sens(settings.elecSfp);
    cfgN.channel = datAll.label(1:settings.channels);
    neighbours = ft_prepare_neighbours(cfgN);

    cfgR = [];
    cfgR.badchannel = datAll.label(sensorsToRemove);
    cfgR.neighbours = neighbours;
    cfgR.elec = ft_read_sens(settings.elecSfp);
    cfgR.method = 'spline';
    cfgR.senstype = 'eeg';
    datRep = ft_channelrepair(cfgR, datAll);
end

if settings.reReferenceAvg
    cfgRef = [];
    cfgRef.reref = 'yes';
    cfgRef.refmethod = 'avg';
    cfgRef.refchannel = 1:settings.channels;
    datRep = ft_preprocessing(cfgRef, datRep);
end

chUse = setdiff(1:settings.channels, sensorsToRemove);
if isempty(chUse)
    error('All channels removed. Check psManualRemove.');
end
leftUse = intersect(settings.leftChs, chUse);
rightUse = intersect(settings.rightChs, chUse);

tWin = round(settings.epochLenSec * settings.FsDs);
epochCount = 1;
allEpochs = [];
for tr = 1:numel(datRep.trial)
    x = datRep.trial{tr};
    startIdx = 1;
    while true
        stopIdx = startIdx + tWin - 1;
        if stopIdx > size(x, 2)
            break;
        end
        block = x(1:settings.channels, startIdx:stopIdx);
        block = block - mean(block, 2);
        allEpochs(:, :, epochCount) = block; %#ok<AGROW>
        epochCount = epochCount + 1;
        startIdx = stopIdx + 1;
    end
end
if isempty(allEpochs)
    error('No PS mini-epochs extracted. Check trial markers or epoch_len_s.');
end

params = [];
params.Fs = settings.FsDs;
params.fpass = [2 40];
params.pad = 1;
params.trialave = 1;
params.tapers = [1 1];

SInduced = [];
for kk = 1:numel(chUse)
    ch = chUse(kk);
    xCh = squeeze(allEpochs(ch, :, :));
    if isvector(xCh)
        xCh = xCh(:);
    end
    [sCh, fOngoing] = mtspectrumc(xCh, params);
    if kk == 1
        SInduced = zeros(numel(chUse), numel(sCh));
    end
    SInduced(kk, :) = sCh(:).';
end
SInduced = normalizeSpectrum(SInduced, settings.normMode);

trEvoked = squeeze(nanmean(allEpochs, 3));
paramsEv = params;
paramsEv.pad = 0;
paramsEv.trialave = 0;

SEvoked = [];
for kk = 1:numel(chUse)
    ch = chUse(kk);
    x = trEvoked(ch, :).';
    [sCh, fEvoked] = mtspectrumc(x, paramsEv);
    if kk == 1
        SEvoked = zeros(numel(chUse), numel(sCh));
    end
    SEvoked(kk, :) = sCh(:).';
end
SEvoked = normalizeSpectrum(SEvoked, settings.normMode);

result = struct();
result.participantNum = participantNum;
result.sensorsToRemove = sensorsToRemove;
result.channelsUsed = chUse;
result.leftChannelsUsed = leftUse;
result.rightChannelsUsed = rightUse;
result.ssvepLeftHz = settings.ssvepLeftHz;
result.ssvepRightHz = settings.ssvepRightHz;
result.miniEpochCount = size(allEpochs, 3);
result.fOngoing = fOngoing(:).';
result.fEvoked = fEvoked(:).';
result.inducedChMean = mean(SInduced, 1);
result.inducedLMean = roiMean(SInduced, chUse, leftUse, fOngoing);
result.inducedRMean = roiMean(SInduced, chUse, rightUse, fOngoing);
result.evokedChMean = mean(SEvoked, 1);
result.evokedLMean = roiMean(SEvoked, chUse, leftUse, fEvoked);
result.evokedRMean = roiMean(SEvoked, chUse, rightUse, fEvoked);
end

% -------------------------------------------------------------------------
%% Plotting
% -------------------------------------------------------------------------
function plotSingleOfflineParticipant(result, trainingSide, settings, outcomeLabel)
co = get(groot, 'defaultAxesColorOrder');
colIpsi = co(1, :);
colContra = co(2, :);
sideLabel = ternary(trainingSide == 0, 'left training', 'right training');
p = result.participantNum;
if nargin < 4
    outcomeLabel = '';
end
suffix = '';
titlePrefix = '';
if ~isempty(outcomeLabel)
    suffix = ['_' outcomeLabel];
    if ~isempty(result.conditionLabel)
        titlePrefix = [result.conditionLabel ' '];
    else
        titlePrefix = [outcomeLabel ' '];
    end
end

if hasFiniteData(result.alphaMuBc)
    createTimeSeriesFigure(sprintf('P%d_alpha%s_time_series', p, suffix), p, ...
        [titlePrefix 'alpha'], 'Alpha power (log scale, a.u.)', result.alphaMuBc, ...
        result.alphaSemBc, settings.timeAxis, colIpsi, colContra, sideLabel);
end
if hasValidPairs(result.alphaFinalCorrTrials)
    createBoxFigure(sprintf('P%d_alpha%s_final_box', p, suffix), p, ...
        [titlePrefix 'Alpha power'], 'Alpha power (log scale)', result.alphaFinalCorrTrials, ...
        colIpsi, colContra);
end

if hasFiniteData(result.ssvMuBc)
    createTimeSeriesFigure(sprintf('P%d_ssvep%s_time_series', p, suffix), p, ...
        [titlePrefix 'SSVEP'], 'SSVEP power (log scale, a.u.)', result.ssvMuBc, ...
        result.ssvSemBc, settings.timeAxis, colIpsi, colContra, sideLabel);
end
if hasValidPairs(result.ssvFinalCorrTrials)
    createBoxFigure(sprintf('P%d_ssvep%s_final_box', p, suffix), p, ...
        [titlePrefix 'SSVEP power'], 'SSVEP power (log scale)', result.ssvFinalCorrTrials, ...
        colIpsi, colContra);
end

if hasFiniteData(result.bbMuBc)
    createTimeSeriesFigure(sprintf('P%d_broadband%s_time_series', p, suffix), p, ...
        [titlePrefix 'broadband power (5-40 Hz)'], ...
        'Broadband power (5-40 Hz, log \DeltaBaseline)', result.bbMuBc, ...
        result.bbSemBc, settings.timeAxis, colIpsi, colContra, sideLabel);
end

if hasFiniteData(result.bbNAMuBc)
    createTimeSeriesFigure(sprintf('P%d_broadband_no_alpha%s_time_series', p, suffix), p, ...
        [titlePrefix 'broadband excl. alpha'], ...
        'Broadband power (5-8 + 12-40 Hz, log \DeltaBaseline)', result.bbNAMuBc, ...
        result.bbNASemBc, settings.timeAxis, colIpsi, colContra, sideLabel);
end

if isempty(outcomeLabel) && ~isempty(result.spectFreqs) && ...
        (hasFiniteData(result.spectLeftTs) || hasFiniteData(result.spectRightTs))
    createSpectralFigure(sprintf('P%d_spectral_time_series', p), p, ...
        result.spectFreqs, result.spectLeftTs, result.spectRightTs, ...
        settings.timeAxis, settings.alphaBand, settings.ssvepLeftHz, ...
        settings.ssvepRightHz, sideLabel);
end

if isempty(outcomeLabel) && ~isempty(result.powerFreqs) && ...
        (hasFiniteData(result.powerInitLeft) || hasFiniteData(result.powerInitRight) || ...
         hasFiniteData(result.powerFinalLeft) || hasFiniteData(result.powerFinalRight))
    createOfflinePowerFigure(sprintf('P%d_power_spectrum', p), p, ...
        result.powerFreqs, result.powerInitLeft, result.powerInitRight, ...
        result.powerFinalLeft, result.powerFinalRight, result.powerInitLeftSem, ...
        result.powerInitRightSem, result.powerFinalLeftSem, result.powerFinalRightSem, ...
        settings.alphaBand, settings.ssvepLeftHz, settings.ssvepRightHz, sideLabel);
end
end

function createTimeSeriesFigure(figName, participantNum, metricName, yLabelText, ...
    muVals, semVals, timeAxis, colIpsi, colContra, sideLabel)
figure('Color', 'w', 'Name', figName, 'NumberTitle', 'off'); hold on; grid on;
plotMeanSem(timeAxis, muVals(2, :), semVals(2, :), colContra, 'Contra SEM', 'Contra mean');
plotMeanSem(timeAxis, muVals(1, :), semVals(1, :), colIpsi, 'Ipsi SEM', 'Ipsi mean');
xline(0, 'k:', 'LineWidth', 1, 'HandleVisibility', 'off');
xlim([-3 0]);
xlabel('Time to trial end (s)');
ylabel(yLabelText);
legend('show', 'Location', 'best');
title(sprintf('Participant %d: End-locked %s (contra vs ipsi, %s)', ...
    participantNum, metricName, sideLabel));
end

function createBoxFigure(figName, participantNum, metricTitle, yLabelText, ...
    pairedVals, colIpsi, colContra)
validPairs = isfinite(pairedVals(:, 1)) & isfinite(pairedVals(:, 2));
pairedVals = pairedVals(validPairs, :);
nPairs = size(pairedVals, 1);

figure('Color', 'w', 'Name', figName, 'NumberTitle', 'off'); hold on; grid on;
boxchart(ones(nPairs, 1), pairedVals(:, 2), 'BoxFaceColor', colContra, ...
    'WhiskerLineColor', colContra, 'MarkerStyle', 'none', 'BoxWidth', 0.5, ...
    'DisplayName', 'Contra');
boxchart(2 * ones(nPairs, 1), pairedVals(:, 1), 'BoxFaceColor', colIpsi, ...
    'WhiskerLineColor', colIpsi, 'MarkerStyle', 'none', 'BoxWidth', 0.5, ...
    'DisplayName', 'Ipsi');
for trialIdx = 1:nPairs
    plot([1, 2], pairedVals(trialIdx, [2 1]), '-', 'Color', [0.45 0.45 0.45], ...
        'LineWidth', 0.8, 'HandleVisibility', 'off');
end
scatter(ones(nPairs, 1), pairedVals(:, 2), 28, repmat(colContra, nPairs, 1), ...
    'filled', 'HandleVisibility', 'off');
scatter(2 * ones(nPairs, 1), pairedVals(:, 1), 28, repmat(colIpsi, nPairs, 1), ...
    'filled', 'HandleVisibility', 'off');
set(gca, 'XTick', [1 2], 'XTickLabel', {'Contra', 'Ipsi'});
legend('show', 'Location', 'best');
ylabel(yLabelText);
title(sprintf('Participant %d: %s - Final (last 2 s)', participantNum, metricTitle));

if nPairs > 1
    pVal = signrank(pairedVals(:, 1), pairedVals(:, 2));
    if pVal < 0.05
        yl = ylim; ySpan = yl(2) - yl(1);
        yBr = yl(2) + 0.05 * ySpan;
        plot([1, 1, 2, 2], [yBr - 0.02 * ySpan, yBr, yBr, yBr - 0.02 * ySpan], ...
            'k-', 'LineWidth', 1.2, 'HandleVisibility', 'off');
        text(1.5, yBr + 0.02 * ySpan, '*', 'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'bottom', 'FontSize', 18);
        ylim([yl(1), yBr + 0.08 * ySpan]);
    end
end
end

function plotOfflineConditionComparison(conditionResults, conditionLabels, trainingSide, settings)
if isempty(conditionResults)
    return;
end

participantNum = conditionResults(1).participantNum;
sideLabel = ternary(trainingSide == 0, 'left training', 'right training');
createConditionTimeSeriesFigure( ...
    sprintf('P%d_alpha_condition_time_series', participantNum), participantNum, ...
    'Alpha', 'Alpha power (log \DeltaBaseline)', conditionResults, ...
    conditionLabels, settings.timeAxis, sideLabel);
createConditionTimeSeriesFigure( ...
    sprintf('P%d_ssvep_condition_time_series', participantNum), participantNum, ...
    'SSVEP', 'SSVEP power (log \DeltaBaseline)', conditionResults, ...
    conditionLabels, settings.timeAxis, sideLabel);
createConditionLateralizationBoxFigure( ...
    sprintf('P%d_alpha_condition_lateralization_box', participantNum), participantNum, ...
    'Alpha', 'Final alpha power (log power)', conditionResults, ...
    conditionLabels, 'alpha');
createConditionLateralizationBoxFigure( ...
    sprintf('P%d_ssvep_condition_lateralization_box', participantNum), participantNum, ...
    'SSVEP', 'Final SSVEP power (log ratio)', conditionResults, ...
    conditionLabels, 'ssvep');
end

function createConditionTimeSeriesFigure(figName, participantNum, metricName, yLabelText, ...
    conditionResults, conditionLabels, timeAxis, sideLabel)
co = get(groot, 'defaultAxesColorOrder');
colIpsi = co(1, :);
colContra = co(2, :);

figure('Color', 'w', 'Name', figName, 'NumberTitle', 'off');
for conditionIdx = 1:numel(conditionResults)
    subplot(2, 2, conditionIdx); hold on; grid on;
    if strcmpi(metricName, 'Alpha')
        muVals = conditionResults(conditionIdx).alphaMuBc;
        semVals = conditionResults(conditionIdx).alphaSemBc;
    else
        muVals = conditionResults(conditionIdx).ssvMuBc;
        semVals = conditionResults(conditionIdx).ssvSemBc;
    end
    if hasFiniteData(muVals)
        plotMeanSem(timeAxis, muVals(2, :), semVals(2, :), ...
            colContra, 'Contra SEM', 'Contra mean');
        plotMeanSem(timeAxis, muVals(1, :), semVals(1, :), ...
            colIpsi, 'Ipsi SEM', 'Ipsi mean');
    end
    xline(0, 'k:', 'HandleVisibility', 'off');
    xlim([-3 0]);
    xlabel('Time to trial end (s)');
    ylabel(yLabelText);
    title(sprintf('%s (n = %d)', conditionLabels{conditionIdx}, ...
        conditionResults(conditionIdx).usedTrialCount));
    if conditionIdx == 1
        legend('show', 'Location', 'best');
    end
end
sgtitle(sprintf('Participant %d (%s): %s by trial condition', ...
    participantNum, sideLabel, metricName));
end

function createConditionLateralizationBoxFigure(figName, participantNum, metricName, ...
    yLabelText, conditionResults, conditionLabels, metricCode)
co = get(groot, 'defaultAxesColorOrder');
colIpsi = co(1, :);
colContra = co(2, :);
allScores = cell(1, numel(conditionResults));
groupOffset = 0.18;
legendAssigned = false;

figure('Color', 'w', 'Name', figName, 'NumberTitle', 'off'); hold on; grid on;
for conditionIdx = 1:numel(conditionResults)
    if strcmp(metricCode, 'alpha')
        pairedVals = conditionResults(conditionIdx).alphaFinalCorrTrials;
    else
        pairedVals = conditionResults(conditionIdx).ssvFinalCorrTrials;
    end
    validPairs = ~isempty(pairedVals) && size(pairedVals, 2) >= 2;
    if validPairs
        validPairs = isfinite(pairedVals(:, 1)) & isfinite(pairedVals(:, 2));
        pairedVals = pairedVals(validPairs, :);
    else
        pairedVals = zeros(0, 2);
    end
    scores = pairedVals(:, 2) - pairedVals(:, 1); % always contra - ipsi
    allScores{conditionIdx} = scores;
    if isempty(pairedVals)
        continue;
    end
    nPairs = size(pairedVals, 1);
    xContra = conditionIdx - groupOffset;
    xIpsi = conditionIdx + groupOffset;
    contraBox = boxchart(xContra * ones(nPairs, 1), pairedVals(:, 2), ...
        'BoxFaceColor', colContra, 'WhiskerLineColor', colContra, ...
        'MarkerStyle', 'none', 'BoxWidth', 0.28);
    ipsiBox = boxchart(xIpsi * ones(nPairs, 1), pairedVals(:, 1), ...
        'BoxFaceColor', colIpsi, 'WhiskerLineColor', colIpsi, ...
        'MarkerStyle', 'none', 'BoxWidth', 0.28);
    if ~legendAssigned
        contraBox.DisplayName = 'Contra';
        ipsiBox.DisplayName = 'Ipsi';
        legendAssigned = true;
    else
        contraBox.HandleVisibility = 'off';
        ipsiBox.HandleVisibility = 'off';
    end
    for trialIdx = 1:nPairs
        plot([xContra xIpsi], pairedVals(trialIdx, [2 1]), '-', ...
            'Color', [0.65 0.65 0.65], 'LineWidth', 0.7, ...
            'HandleVisibility', 'off');
    end
    jitter = deterministicJitter(nPairs, 0.08);
    scatter(xContra + jitter, pairedVals(:, 2), 24, colContra, ...
        'filled', 'MarkerFaceAlpha', 0.55, 'MarkerEdgeColor', 'none', ...
        'HandleVisibility', 'off');
    scatter(xIpsi + jitter, pairedVals(:, 1), 24, colIpsi, ...
        'filled', 'MarkerFaceAlpha', 0.55, 'MarkerEdgeColor', 'none', ...
        'HandleVisibility', 'off');
end
set(gca, 'XTick', 1:numel(conditionResults), 'XTickLabel', conditionLabels);
xtickangle(20);
xlim([0.5, numel(conditionResults) + 0.5]);
ylabel(yLabelText);
legend('show', 'Location', 'best');
title(sprintf('Participant %d: Final %s by trial condition (contra left, ipsi right)', ...
    participantNum, metricName));

comparisons = computeOneWayPairwise(allScores);
fprintf('  %s final contra-minus-ipsi pairwise ranksum comparisons (Holm-adjusted p):\n', metricName);
for pairIdx = 1:size(comparisons.pairs, 1)
    if isfinite(comparisons.holmP(pairIdx))
        pair = comparisons.pairs(pairIdx, :);
        fprintf('    %s vs %s = %.4g\n', conditionLabels{pair(1)}, ...
            conditionLabels{pair(2)}, comparisons.holmP(pairIdx));
    end
end
end

function comparisons = computeOneWayPairwise(valuesByCondition)
nConditions = numel(valuesByCondition);
pairs = nchoosek(1:nConditions, 2);
pVals = nan(size(pairs, 1), 1);
for pairIdx = 1:size(pairs, 1)
    valsA = valuesByCondition{pairs(pairIdx, 1)};
    valsB = valuesByCondition{pairs(pairIdx, 2)};
    if ~isempty(valsA) && ~isempty(valsB)
        pVals(pairIdx) = ranksum(valsA, valsB);
    end
end
comparisons = struct('pairs', pairs, 'rawP', pVals, 'holmP', holmAdjustPValues(pVals));
end

function createSpectralFigure(figName, participantNum, spectFreqs, spectLeftTs, ...
    spectRightTs, timeAxis, alphaBand, ssvepLeftHz, ssvepRightHz, sideLabel)
figure('Color', 'w', 'Name', figName, 'NumberTitle', 'off');
panels = {spectLeftTs, spectRightTs};
panelTitles = {sprintf('Left hemisphere (%g Hz stim)', ssvepLeftHz), ...
               sprintf('Right hemisphere (%g Hz stim)', ssvepRightHz)};

allVals = [];
for panelIdx = 1:2
    d = panels{panelIdx};
    if ~isempty(d)
        allVals = [allVals; d(isfinite(d(:)))]; %#ok<AGROW>
    end
end
cLim = [-1 1];
if numel(allVals) > 1
    cLim = [prctile(allVals, 2), prctile(allVals, 98)];
end

for panelIdx = 1:2
    subplot(1, 2, panelIdx);
    d = panels{panelIdx};
    if isempty(d) || ~any(isfinite(d(:)))
        axis off; title(panelTitles{panelIdx}); continue;
    end
    imagesc(timeAxis, spectFreqs, d);
    set(gca, 'YDir', 'normal'); colormap(gca, 'turbo'); clim(cLim);
    cb = colorbar; cb.Label.String = '\DeltaPower (log, BC)';
    xlabel('Time to trial end (s)');
    ylabel('Frequency (Hz)');
    title(panelTitles{panelIdx});
    xlim([-3 0]);
    yline(alphaBand(1), 'w--', 'LineWidth', 1.2);
    yline(alphaBand(2), 'w--', 'LineWidth', 1.2);
    yline(ssvepLeftHz, 'w:', 'LineWidth', 1.2);
    yline(ssvepRightHz, 'w:', 'LineWidth', 1.2);
end
sgtitle(sprintf('Participant %d (%s): Spectral time series (5-40 Hz, \\DeltaBaseline)', ...
    participantNum, sideLabel));
end

function createOfflinePowerFigure(figName, participantNum, powerFreqs, powerInitLeft, ...
    powerInitRight, powerFinalLeft, powerFinalRight, powerInitLeftSem, ...
    powerInitRightSem, powerFinalLeftSem, powerFinalRightSem, alphaBand, ...
    ssvepLeftHz, ssvepRightHz, sideLabel)
figure('Color', 'w', 'Name', figName, 'NumberTitle', 'off');
fRow = powerFreqs(:).';
colLeft = [0.20 0.50 0.90];
colRight = [0.90 0.30 0.20];
titles = {'Initial (-4 to -2 s)', 'Final (-2 to 0 s)'};
leftData = {powerInitLeft, powerFinalLeft};
rightData = {powerInitRight, powerFinalRight};
leftSem = {powerInitLeftSem, powerFinalLeftSem};
rightSem = {powerInitRightSem, powerFinalRightSem};
axPower = gobjects(2, 1);

for winIdx = 1:2
    axPower(winIdx) = subplot(1, 2, winIdx); hold on; grid on;
    plotMeanSem(fRow, leftData{winIdx}, leftSem{winIdx}, colLeft, '', 'Left hemisphere');
    plotMeanSem(fRow, rightData{winIdx}, rightSem{winIdx}, colRight, '', 'Right hemisphere');
    xline(alphaBand(1), 'k--', 'LineWidth', 1, 'HandleVisibility', 'off');
    xline(alphaBand(2), 'k--', 'LineWidth', 1, 'HandleVisibility', 'off');
    xline(ssvepLeftHz, 'k:', 'LineWidth', 1.5, 'HandleVisibility', 'off');
    xline(ssvepRightHz, 'k:', 'LineWidth', 1.5, 'HandleVisibility', 'off');
    xlabel('Frequency (Hz)');
    ylabel('Power (a.u.)');
    legend('Location', 'best');
    title(titles{winIdx});
    xlim([fRow(1) fRow(end)]);
end

validAx = axPower(isgraphics(axPower));
if ~isempty(validAx)
    yLims = arrayfun(@(ax) ylim(ax), validAx, 'UniformOutput', false);
    yLims = vertcat(yLims{:});
    set(validAx, 'YLim', [min(yLims(:, 1)), max(yLims(:, 2))]);
end
sgtitle(sprintf(['Participant %d (%s): Power spectrum: left vs right hemisphere ' ...
    '(raw linear power, true 2 s windows)'], participantNum, sideLabel));
end

function plotSingleParticipantBehaviour(result)
if ~result.hasData
    fprintf('Participant %d: no behaviour data to plot.\n', result.participantNum);
    return;
end

createBehaviourBoxFigure(sprintf('P%d_behaviour_accuracy', result.participantNum), ...
    result.participantNum, 'Behaviour accuracy', 'Accuracy (%)', ...
    result.accuracyBlockMeans, result.conditionLabels, [0 100]);

createBehaviourBoxFigure(sprintf('P%d_behaviour_reaction_time', result.participantNum), ...
    result.participantNum, 'Behaviour reaction time', 'Reaction time (s)', ...
    result.rtBlockMeans, result.conditionLabels, []);
end

function createBehaviourBoxFigure(figName, participantNum, metricTitle, yLabelText, ...
    blockValues, conditionLabels, yLimits)
if ~hasFiniteData(blockValues)
    return;
end

conditionColors = lines(numel(conditionLabels));
sideLabels = {'Ipsi cue', 'Contra cue'};
sideOrder = [2 1]; % contra is always the left panel
figure('Color', 'w', 'Name', figName, 'NumberTitle', 'off');
for displayIdx = 1:2
    sideIdx = sideOrder(displayIdx);
    subplot(1, 2, displayIdx); hold on; grid on;
    for conditionIdx = 1:numel(conditionLabels)
        vals = blockValues(:, sideIdx, conditionIdx);
        vals = vals(isfinite(vals));
        if isempty(vals)
            continue;
        end
        boxchart(conditionIdx * ones(numel(vals), 1), vals, ...
            'BoxFaceColor', conditionColors(conditionIdx, :), ...
            'WhiskerLineColor', conditionColors(conditionIdx, :), ...
            'MarkerStyle', 'none', 'BoxWidth', 0.55);
        xJitter = conditionIdx + deterministicJitter(numel(vals), 0.10);
        scatter(xJitter, vals, 26, conditionColors(conditionIdx, :), ...
            'filled', 'MarkerFaceAlpha', 0.55, 'MarkerEdgeColor', 'none');
    end
    set(gca, 'XTick', 1:numel(conditionLabels), 'XTickLabel', conditionLabels);
    xtickangle(20);
    xlim([0.5, numel(conditionLabels) + 0.5]);
    ylabel(yLabelText);
    title(sprintf('%s (points = block means)', sideLabels{sideIdx}));
    if ~isempty(yLimits)
        ylim(yLimits);
    end
end
sgtitle(sprintf('Participant %d: %s by failed subtype and success', ...
    participantNum, metricTitle));
end

function offsets = deterministicJitter(nPoints, width)
if nPoints <= 1
    offsets = zeros(nPoints, 1);
else
    offsets = linspace(-width / 2, width / 2, nPoints).';
end
end

function plotSinglePSSpectra(result)
p = result.participantNum;
colLeft = [0.18 0.45 0.80];
colRight = [0.80 0.20 0.20];

figure('Color', 'w', 'Name', sprintf('P%d_PS_ongoing_mean_channels', p), ...
    'NumberTitle', 'off');
plot(result.fOngoing, result.inducedChMean, 'LineWidth', 1.6); hold on; grid on;
xline(8, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xline(12, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xlim([2 40]);
xlabel('Frequency (Hz)'); ylabel('Power');
title(sprintf('Participant %d - PS ongoing (per-epoch PSD -> avg across epochs)', p));
set(gca, 'FontSize', 12, 'LineWidth', 1.2);

figure('Color', 'w', 'Name', sprintf('P%d_PS_ongoing_left_right', p), ...
    'NumberTitle', 'off');
plot(result.fOngoing, result.inducedLMean, 'Color', colLeft, 'LineWidth', 1.8); hold on; grid on;
plot(result.fOngoing, result.inducedRMean, 'Color', colRight, 'LineWidth', 1.8);
xline(8, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xline(12, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xlim([2 40]);
legend({'Left-electrodes', 'Right-electrodes'}, 'Location', 'northeast');
xlabel('Frequency (Hz)'); ylabel('Power');
title(sprintf('Participant %d - PS ongoing spectrum (Left vs Right)', p));
set(gca, 'FontSize', 12, 'LineWidth', 1.2);

figure('Color', 'w', 'Name', sprintf('P%d_PS_evoked_mean_channels', p), ...
    'NumberTitle', 'off');
plot(result.fEvoked, result.evokedChMean, 'LineWidth', 1.6); hold on; grid on;
xline(result.ssvepRightHz, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xline(result.ssvepLeftHz, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xlim([2 40]);
xlabel('Frequency (Hz)'); ylabel('Power');
title(sprintf('Participant %d - PS evoked (time-avg -> PSD)', p));
set(gca, 'FontSize', 12, 'LineWidth', 1.2);

figure('Color', 'w', 'Name', sprintf('P%d_PS_evoked_left_right', p), ...
    'NumberTitle', 'off');
plot(result.fEvoked, result.evokedLMean, 'Color', colLeft, 'LineWidth', 1.8); hold on; grid on;
plot(result.fEvoked, result.evokedRMean, 'Color', colRight, 'LineWidth', 1.8);
xline(result.ssvepRightHz, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xline(result.ssvepLeftHz, ':', 'LineWidth', 2, 'Color', [0.2 0.2 0.2]);
xlim([2 40]);
legend({'Left-electrodes', 'Right-electrodes'}, 'Location', 'northeast');
xlabel('Frequency (Hz)'); ylabel('Power');
title(sprintf('Participant %d - PS evoked spectrum (Left vs Right)', p));
set(gca, 'FontSize', 12, 'LineWidth', 1.2);
end

% -------------------------------------------------------------------------
%% Shared helpers
% -------------------------------------------------------------------------
function [sumVals, sumSqVals, countVals] = addTrialSeries(sumVals, sumSqVals, countVals, segment, idx)
valid = isfinite(segment);
segment(~valid) = 0;
sumVals(:, idx) = sumVals(:, idx) + segment;
sumSqVals(:, idx) = sumSqVals(:, idx) + segment .^ 2;
countVals(:, idx) = countVals(:, idx) + valid;
end

function [sumVals, countVals] = addSpectralTrial(sumVals, countVals, segment, idx)
valid = isfinite(segment);
segment(~valid) = 0;
sumVals(:, idx) = sumVals(:, idx) + segment;
countVals(:, idx) = countVals(:, idx) + valid;
end

function semVals = computeSemFromSums(sumVals, sumSqVals, countVals)
semVals = nan(size(sumVals));
valid = countVals > 1;
if ~any(valid(:))
    return;
end
varVals = nan(size(sumVals));
varVals(valid) = (sumSqVals(valid) - (sumVals(valid) .^ 2) ./ countVals(valid)) ./ ...
    (countVals(valid) - 1);
varVals(valid) = max(varVals(valid), 0);
semVals(valid) = sqrt(varVals(valid)) ./ sqrt(countVals(valid));
end

function semVals = computeSemFromTrials(trialValues)
if isempty(trialValues)
    semVals = [];
    return;
end
n = sum(isfinite(trialValues), 1);
semVals = std(trialValues, 0, 1, 'omitnan') ./ sqrt(max(n, 1));
semVals(n < 2) = NaN;
semVals = semVals(:).';
end

function segment = prepareWindowSegment(segment, bBP, aBP)
for ch = 1:size(segment, 1)
    s = segment(ch, :);
    if any(~isfinite(s))
        m = mean(s, 'omitnan');
        s(~isfinite(s)) = m;
        segment(ch, :) = s;
    end
end
segment = segment - mean(segment, 2, 'omitnan');
segment = detrend(segment.', 'linear').';
segment = filtfilt(bBP, aBP, segment.').';
segment = segment - mean(segment, 1, 'omitnan');
end

function [psd, freqs] = computeWindowSpectrum(segment, settings)
segment = prepareWindowSegment(segment, settings.bBP, settings.aBP);
[psd, freqs] = mtspectrumc(segment.', settings.chronuxParams2s);
end

function plotMeanSem(xVals, meanVals, semVals, colorVal, semLabel, meanLabel)
if isempty(meanVals) || ~any(isfinite(meanVals(:)))
    return;
end
xVals = xVals(:).';
meanVals = meanVals(:).';
if isempty(semVals)
    semVals = nan(size(meanVals));
end
semVals = semVals(:).';

maskSem = isfinite(xVals) & isfinite(meanVals) & isfinite(semVals);
if nnz(maskSem) > 1
    x = xVals(maskSem);
    y = meanVals(maskSem);
    e = semVals(maskSem);
    h = fill([x fliplr(x)], [y - e fliplr(y + e)], colorVal, ...
        'FaceAlpha', 0.2, 'EdgeColor', 'none');
    if isempty(semLabel)
        set(h, 'HandleVisibility', 'off');
    else
        set(h, 'DisplayName', semLabel);
    end
end

maskMean = isfinite(xVals) & isfinite(meanVals);
plot(xVals(maskMean), meanVals(maskMean), 'Color', colorVal, ...
    'LineWidth', 2, 'DisplayName', meanLabel);
end

function SNorm = normalizeSpectrum(S, mode)
switch mode
    case 'none'
        SNorm = S;
    case 'rel-mean'
        SNorm = S ./ nanmean(S, 2);
    case 'db-abs'
        SNorm = 10 * log10(S);
    case 'db-relmean'
        SNorm = 10 * log10(S ./ nanmean(S, 2));
    otherwise
        error('Unknown normMode "%s".', mode);
end
end

function m = roiMean(S, chUse, roiChannels, freqs)
if isempty(roiChannels)
    m = nan(size(freqs));
    return;
end
m = mean(S(ismember(chUse, roiChannels), :), 1);
end

function tf = isTrialExcluded(excludedTrials, blockNum, trialNum)
tf = false;
if isempty(excludedTrials)
    return;
end
tf = any(excludedTrials(:, 1) == blockNum & excludedTrials(:, 2) == 0) || ...
     any(excludedTrials(:, 1) == blockNum & excludedTrials(:, 2) == trialNum);
end

function col = numericBehaviourColumn(T, candidates, filename, required)
rawCol = behaviourColumn(T, candidates, filename, required);
if isempty(rawCol)
    col = [];
    return;
end

if isnumeric(rawCol) || islogical(rawCol)
    col = double(rawCol);
else
    col = str2double(string(rawCol));
end
col = col(:);
end

function col = stringBehaviourColumn(T, candidates, filename, required)
rawCol = behaviourColumn(T, candidates, filename, required);
if isempty(rawCol)
    col = strings(0, 1);
    return;
end
col = lower(strtrim(string(rawCol(:))));
end

function col = behaviourColumn(T, candidates, filename, required)
if ischar(candidates)
    candidates = {candidates};
end

col = [];
varNames = T.Properties.VariableNames;
for candidateIdx = 1:numel(candidates)
    matchIdx = find(strcmpi(varNames, candidates{candidateIdx}), 1);
    if ~isempty(matchIdx)
        col = T.(varNames{matchIdx});
        return;
    end
end

if required
    error('Required behaviour column missing in %s. Expected one of: %s', ...
        filename, strjoin(candidates, ', '));
end
end

function tf = isIpsiCue(cueSide, trainingSide)
if trainingSide == 0
    tf = cueSide == "left";
else
    tf = cueSide == "right";
end
end

function tf = isContraCue(cueSide, trainingSide)
if trainingSide == 0
    tf = cueSide == "right";
else
    tf = cueSide == "left";
end
end

function blockNum = parseBehaviourBlockNumber(fileName)
tok = regexp(fileName, '_b(\d+)_trialdata\.csv$', 'tokens', 'once');
if isempty(tok)
    blockNum = NaN;
else
    blockNum = str2double(tok{1});
end
end

function dsSample = rawToDownsampledSample(rawSample, downsampleFactor)
dsSample = round((rawSample - 1) / downsampleFactor) + 1;
end

function participantDir = buildParticipantFolder(participantNum)
if participantNum < 35
    participantDir = sprintf('/Volumes/250GBKC/CogLab/Training/Participant%d', participantNum);
else
    participantDir = sprintf('/Volumes/250GBKC/CogLab/Testing/Participant%d', participantNum);
end
end

function filename = buildParticipantFilename(participantNum)
if participantNum < 28
    filename = sprintf('/Volumes/250GBKC/CogLab/Training/Participant%d/GDF/P%d_testing.gdf', ...
        participantNum, participantNum);
elseif participantNum < 35
    filename = sprintf('/Volumes/250GBKC/CogLab/Training/Participant%d/GDF/P%dexp.gdf', ...
        participantNum, participantNum);
elseif participantNum == 40
    filename = sprintf('/Volumes/250GBKC/CogLab/Testing/Participant%d/GDF/P%d.gdf', ...
        participantNum, participantNum);
else
    filename = sprintf('/Volumes/250GBKC/CogLab/Testing/Participant%d/GDF/P%dexp.gdf', ...
        participantNum, participantNum);
end
end

function initializeSingleParticipantToolboxes()
addpath(genpath('/Users/kalyanbrata/Local/chronux_2_12'));
addpath('/Users/kalyanbrata/Local/fieldtrip-20230613');
ft_defaults;
addpath(genpath('/Users/kalyanbrata/Local/NoiseTools'));
end

function tf = hasFiniteData(dataVals)
tf = ~isempty(dataVals) && any(isfinite(dataVals(:)));
end

function tf = hasValidPairs(pairVals)
tf = ~isempty(pairVals) && size(pairVals, 2) >= 2 && ...
    any(isfinite(pairVals(:, 1)) & isfinite(pairVals(:, 2)));
end

function report = buildSingleParticipantOfflineReport(participantNum, trainingSide, excludedTrials, ...
    offline, offlineResult, failedOfflineResult, runBehaviourAnalysis, behaviour, behaviourResult, ...
    runPSStyleSpectra, ps, psResult)
co = get(groot, 'defaultAxesColorOrder');
colIpsi = co(1, :);
colContra = co(2, :);
sideLabel = ternary(trainingSide == 0, 'left training', 'right training');

report = struct();
report.reportType = 'plot_recreation_data';
report.script = 'singleParticipantOffline';
report.generatedAtLocal = datestr(now, 'yyyy-mm-ddTHH:MM:SS');
report.nanEncodingNote = 'JSON encoders may emit NaN and Inf as null depending on MATLAB version; those entries are missing plot samples.';
report.participant = struct( ...
    'id', participantNum, ...
    'trainingSideCode', trainingSide, ...
    'trainingSideLabel', sideLabel, ...
    'excludedTrials', excludedTrials);
report.methodology = singleParticipantOfflineMethodology(offline, runBehaviourAnalysis, behaviour, runPSStyleSpectra, ps);
report.settings = struct( ...
    'offline', offline, ...
    'behaviourEnabled', runBehaviourAnalysis, ...
    'behaviour', behaviour, ...
    'psStyleEnabled', runPSStyleSpectra, ...
    'psStyle', ps);
report.plotStyle = struct( ...
    'timeSeriesXLim', [-3 0], ...
    'trialEndXLine', 0, ...
    'ipsiColor', colIpsi, ...
    'contraColor', colContra, ...
    'leftHemisphereColor', [0.20 0.50 0.90], ...
    'rightHemisphereColor', [0.90 0.30 0.20], ...
    'meanLineWidth', 2, ...
    'semFaceAlpha', 0.2, ...
    'boxWidth', 0.5);

report.resultAudit = struct( ...
    'successfulOffline', compactSingleOfflineAudit(offlineResult), ...
    'failedOffline', compactSingleOfflineAudit(failedOfflineResult), ...
    'behaviour', compactBehaviourAudit(behaviourResult), ...
    'psStyleSpectra', psResult);

plots = struct();
plots.offline_successful = makeSingleOfflineOutcomeReport(offlineResult, '', trainingSide, offline, colIpsi, colContra);
plots.offline_failed = makeSingleOfflineOutcomeReport(failedOfflineResult, 'failed', trainingSide, offline, colIpsi, colContra);
plots.behaviour = makeSingleBehaviourReport(behaviourResult);
plots.ps_style_spectra = makeSinglePSReport(psResult);
report.plots = plots;
end

function methodology = singleParticipantOfflineMethodology(offline, runBehaviourAnalysis, behaviour, runPSStyleSpectra, ps)
methodology = struct();
methodology.offlinePipeline = { ...
    'Read raw continuous GDF EEG channels 2:(channels+1), excluding STATUS.', ...
    'Demean and resample from FsRaw to Fs.', ...
    'Apply FieldTrip Butterworth preprocessing bandpass prepBand with prepBandOrd; optionally add 50 Hz DFT notch.', ...
    'Detect bad channels with my_nt_find_bad_channels(data'', 0.33, 4, [], 4), cap automatic removals to the 15 worst bad-time channels, merge with offlineManualRemove.', ...
    'Repair removed channels with FieldTrip spline interpolation using triangulation neighbours and Biosemi_128_Cartesian_Default.sfp.', ...
    'Average rereference across EEG channels when reReferenceAvg is true.', ...
    'Find trials from STATUS trigStart followed by trigSucc or trigFail; apply manual exclusions.', ...
    'Compute end-locked sliding-window spectra using spectrumWindowSec and stepSec; keep last timelinePoints windows.', ...
    'Each spectrum window is demeaned by channel, linearly detrended, zero-phase filtered with the analysis fpass Butterworth filter, then sample-average referenced before Chronux mtspectrumc.', ...
    'Alpha is mean PSD over alphaBand and alpha ROI channels; SSVEP is target-bin PSD divided by the mean of adjacent frequency bins for the relevant ROI.', ...
        'Internal rows are [ipsi; contra] relative to training side; all comparison plots display contra first (left) and ipsi second (right).', ...
    'Time-series plots subtract the mean over baselineIdx from each row.', ...
    'Final box plots use last windowSeconds before trial end and subtract the initial contra-ipsi offset from contra values.', ...
    'Power spectrum plots use raw linear PSD from true powerWindowSec segments: initial is -4 to -2 s, final is -2 to 0 s.'};
methodology.offlineSettingsEcho = struct( ...
    'FsRaw', offline.FsRaw, ...
    'Fs', offline.Fs, ...
    'downsampleFactor', offline.downsampleFactor, ...
    'baselineIdx', offline.baselineIdx, ...
    'timeAxisDefinition', 'timeAxis = (-(timelinePoints - 1):0) * stepSec', ...
    'alphaBand', offline.alphaBand, ...
    'ssvepLeftHz', offline.ssvepLeftHz, ...
    'ssvepRightHz', offline.ssvepRightHz, ...
    'runBroadbandAnalysis', offline.runBroadbandAnalysis);
methodology.behaviourEnabled = runBehaviourAnalysis;
if runBehaviourAnalysis
    methodology.behaviourPipeline = { ...
        'Read the final numBlocks trialdata CSV files, sorted by filename block number, and map them in order to EEG blocks 1:numBlocks.', ...
        'Apply manual trial exclusions and optional IsValidTrial filtering.', ...
        'Successful trials retain the CSV success code. Failed trials are classified from the final online-NF hold window.', ...
        'Alpha is on-target when NF >= alphaNFThreshold; SSVEP is on-target when NF_SSVEP < ssvepNFThreshold.', ...
        'The final-window hit proportion is compared with nfHoldProportion. Failed trials are Alpha-only, SSVEP-only, or Not lat.; anomalous both-on-target failures are flagged and assigned to Not lat.', ...
        'Group behaviour by cue side relative to training side and the four trial conditions.', ...
        'Accuracy is multiplied by 100; RT omits NaN and responseTimeout trials when excludeTimeoutRT is true.', ...
        'Trials are averaged within block, cue side, and condition before plotting or inference.', ...
        'Box plots show block means for all four conditions. Pairwise signrank tests use blocks containing both conditions and are Holm-adjusted within ipsi and contra cue sides.'};
    methodology.behaviourSettingsEcho = behaviour;
end
methodology.psStyleEnabled = runPSStyleSpectra;
if runPSStyleSpectra
    methodology.psStylePipeline = { ...
        'Read raw GDF, resample to FsDs, bandpass bpFreq, optionally 50 Hz notch, repair/rereference channels.', ...
        'Redefine trials from trigStart to trigSucc/trigFail end markers.', ...
        'Split each trial into non-overlapping epochLenSec mini-epochs.', ...
        'Ongoing spectra are Chronux PSDs per mini-epoch averaged across epochs with params tapers [1 1], pad 1, trialave 1, fpass [2 40].', ...
        'Evoked spectra are Chronux PSDs of the trial-average waveform with pad 0 and trialave 0.', ...
        'Spectra are normalized by normMode; left/right plots average configured leftChs/rightChs that remain after channel removal.'};
    methodology.psStyleSettingsEcho = ps;
end
end

function audit = compactSingleOfflineAudit(result)
if isempty(fieldnames(result))
    audit = struct();
    return;
end
audit = struct( ...
    'participantNum', result.participantNum, ...
    'targetFailed', result.targetFailed, ...
    'totalTrialCount', result.totalTrialCount, ...
    'successfulTrialCount', result.successfulTrialCount, ...
    'failedTrialCount', result.failedTrialCount, ...
    'usedTrialCount', result.usedTrialCount, ...
    'sensorsToRemove', result.sensorsToRemove, ...
    'alphaFinalCorrTrialCount', size(result.alphaFinalCorrTrials, 1), ...
    'ssvFinalCorrTrialCount', size(result.ssvFinalCorrTrials, 1), ...
    'spectFreqCount', numel(result.spectFreqs), ...
    'powerFreqCount', numel(result.powerFreqs), ...
    'hasBroadbandAnalysis', hasFiniteData(result.bbMuBc), ...
    'hasSpectralTimeSeries', hasFiniteData(result.spectLeftTs) || hasFiniteData(result.spectRightTs), ...
    'hasPowerSpectrum', hasFiniteData(result.powerInitLeft) || hasFiniteData(result.powerFinalLeft));
end

function audit = compactBehaviourAudit(result)
if isempty(fieldnames(result))
    audit = struct();
    return;
end
audit = struct( ...
    'participantNum', result.participantNum, ...
    'hasData', result.hasData, ...
    'hasClassification', result.hasClassification, ...
    'participantDir', result.participantDir, ...
    'trainingSide', result.trainingSide, ...
    'analyseTrainingBlocks', result.analyseTrainingBlocks, ...
    'conditionLabels', {result.conditionLabels}, ...
    'csvBlockNumbers', result.csvBlockNumbers, ...
    'trialCounts', result.trialCounts, ...
    'bothCriteriaFailedTrials', result.bothCriteriaFailedTrials, ...
    'accuracyMean', result.accuracyMean, ...
    'accuracySem', result.accuracySem, ...
    'accuracyNBlocks', result.accuracyNBlocks, ...
    'rtMean', result.rtMean, ...
    'rtSem', result.rtSem, ...
    'rtNBlocks', result.rtNBlocks);
end

function outcomeReport = makeSingleOfflineOutcomeReport(result, outcomeLabel, trainingSide, settings, colIpsi, colContra)
if isempty(outcomeLabel)
    suffix = '';
    titlePrefix = '';
else
    suffix = ['_' outcomeLabel];
    titlePrefix = [outcomeLabel ' '];
end
p = result.participantNum;
sideLabel = ternary(trainingSide == 0, 'left training', 'right training');
outcomeReport = struct();
outcomeReport.resultAudit = compactSingleOfflineAudit(result);
outcomeReport.rowLabels = {'Ipsi', 'Contra'};
outcomeReport.plots = struct();
outcomeReport.plots.alpha_time_series = makeSingleTimeSeriesReport( ...
    sprintf('P%d_alpha%s_time_series', p, suffix), ...
    sprintf('Participant %d: End-locked %salpha (contra vs ipsi, %s)', p, titlePrefix, sideLabel), ...
    'Alpha power (log scale, a.u.)', settings.timeAxis, result.alphaMuBc, result.alphaSemBc);
outcomeReport.plots.alpha_final_box = makeSingleBoxReport( ...
    sprintf('P%d_alpha%s_final_box', p, suffix), ...
    sprintf('Participant %d: %sAlpha power - Final (last 2 s)', p, titlePrefix), ...
    'Alpha power (log scale)', result.alphaFinalCorrTrials, colIpsi, colContra);
outcomeReport.plots.ssvep_time_series = makeSingleTimeSeriesReport( ...
    sprintf('P%d_ssvep%s_time_series', p, suffix), ...
    sprintf('Participant %d: End-locked %sSSVEP (contra vs ipsi, %s)', p, titlePrefix, sideLabel), ...
    'SSVEP power (log scale, a.u.)', settings.timeAxis, result.ssvMuBc, result.ssvSemBc);
outcomeReport.plots.ssvep_final_box = makeSingleBoxReport( ...
    sprintf('P%d_ssvep%s_final_box', p, suffix), ...
    sprintf('Participant %d: %sSSVEP power - Final (last 2 s)', p, titlePrefix), ...
    'SSVEP power (log scale)', result.ssvFinalCorrTrials, colIpsi, colContra);
outcomeReport.plots.broadband_time_series = makeSingleTimeSeriesReport( ...
    sprintf('P%d_broadband%s_time_series', p, suffix), ...
    sprintf('Participant %d: End-locked %sbroadband power (5-40 Hz) (contra vs ipsi, %s)', p, titlePrefix, sideLabel), ...
    'Broadband power (5-40 Hz, log DeltaBaseline)', settings.timeAxis, result.bbMuBc, result.bbSemBc);
outcomeReport.plots.broadband_no_alpha_time_series = makeSingleTimeSeriesReport( ...
    sprintf('P%d_broadband_no_alpha%s_time_series', p, suffix), ...
    sprintf('Participant %d: End-locked %sbroadband excl. alpha (contra vs ipsi, %s)', p, titlePrefix, sideLabel), ...
    'Broadband power (5-8 + 12-40 Hz, log DeltaBaseline)', settings.timeAxis, result.bbNAMuBc, result.bbNASemBc);

if isempty(outcomeLabel)
    outcomeReport.plots.spectral_time_series = makeSingleSpectralReport(result, settings, sideLabel);
    outcomeReport.plots.power_spectrum = makeSinglePowerReport(result, settings, sideLabel);
end
end

function plotReport = makeSingleTimeSeriesReport(figName, titleText, yLabelText, timeAxis, muVals, semVals)
plotReport = struct();
plotReport.figureName = figName;
plotReport.plotType = 'mean_sem_time_series';
plotReport.title = titleText;
plotReport.xLabel = 'Time to trial end (s)';
plotReport.yLabel = yLabelText;
plotReport.xLim = [-3 0];
plotReport.rowLabels = {'Ipsi', 'Contra'};
plotReport.hasFiniteData = hasFiniteData(muVals);
plotReport.omittedData = struct( ...
    'reason', 'Time-series arrays are omitted to keep the JSON report compact.', ...
    'timePointCount', numel(timeAxis), ...
    'meanSize', size(muVals), ...
    'semSize', size(semVals));
plotReport.method = 'Internal rows remain [ipsi, contra], but plots and legends show contra first and ipsi second; xline at 0 marks trial end.';
end

function plotReport = makeSingleBoxReport(figName, titleText, yLabelText, pairedVals, colIpsi, colContra)
validPairs = false(size(pairedVals, 1), 1);
if ~isempty(pairedVals) && size(pairedVals, 2) >= 2
    validPairs = isfinite(pairedVals(:, 1)) & isfinite(pairedVals(:, 2));
end
plotReport = struct();
plotReport.figureName = figName;
plotReport.plotType = 'paired_trial_boxchart';
plotReport.title = titleText;
plotReport.xTick = [1 2];
plotReport.xTickLabel = {'Contra', 'Ipsi'};
plotReport.yLabel = yLabelText;
plotReport.colors = struct('ipsi', colIpsi, 'contra', colContra);
plotReport.data = struct( ...
    'allPairedValues', pairedVals, ...
    'validPairedValues', pairedVals(validPairs, :), ...
    'displayedValuesContraThenIpsi', pairedVals(validPairs, [2 1]), ...
    'validTrialIndices', find(validPairs));
plotReport.statistics = struct( ...
    'signrankContraVsIpsiP', signrankPairsOrNaN(pairedVals), ...
    'nValidPairs', nnz(validPairs));
plotReport.method = 'Contra is always x=1 (left) and ipsi is x=2 (right), with paired trial lines and colored scatter; significance uses paired signrank.';
end

function plotReport = makeSingleSpectralReport(result, settings, sideLabel)
plotReport = struct();
plotReport.figureName = sprintf('P%d_spectral_time_series', result.participantNum);
plotReport.plotType = 'imagesc_1x2_spectral_time_series';
plotReport.title = sprintf('Participant %d (%s): Spectral time series (5-40 Hz, DeltaBaseline)', ...
    result.participantNum, sideLabel);
plotReport.xLim = [-3 0];
plotReport.xLabel = 'Time to trial end (s)';
plotReport.yLabel = 'Frequency (Hz)';
plotReport.colorbarLabel = 'DeltaPower (log, BC)';
plotReport.colormap = 'turbo';
plotReport.alphaBandLines = settings.alphaBand;
plotReport.ssvepLinesHz = [settings.ssvepLeftHz settings.ssvepRightHz];
plotReport.panels = struct( ...
    'leftHemisphere', struct('title', sprintf('Left hemisphere (%g Hz stim)', settings.ssvepLeftHz), 'omittedData', 'Panel spectral matrix omitted.'), ...
    'rightHemisphere', struct('title', sprintf('Right hemisphere (%g Hz stim)', settings.ssvepRightHz), 'omittedData', 'Panel spectral matrix omitted.'));
plotReport.colorLimits = 'omitted_with_spectral_time_series_data';
plotReport.omittedData = struct( ...
    'reason', 'Spectral time-series matrices are omitted to keep the JSON report compact.', ...
    'timePointCount', numel(settings.timeAxis), ...
    'frequencyCount', numel(result.spectFreqs), ...
    'leftMatrixSize', size(result.spectLeftTs), ...
    'rightMatrixSize', size(result.spectRightTs));
plotReport.method = 'imagesc(timeAxis, spectFreqs, baseline-corrected log spectral matrix), YDir normal, shared clim from finite 2nd and 98th percentiles across both panels.';
end

function plotReport = makeSinglePowerReport(result, settings, sideLabel)
plotReport = struct();
plotReport.figureName = sprintf('P%d_power_spectrum', result.participantNum);
plotReport.plotType = 'mean_sem_power_spectrum_1x2';
plotReport.title = sprintf('Participant %d (%s): Power spectrum: left vs right hemisphere (raw linear power, true 2 s windows)', ...
    result.participantNum, sideLabel);
plotReport.x = result.powerFreqs;
if isempty(result.powerFreqs)
    plotReport.xLim = [];
else
    plotReport.xLim = [result.powerFreqs(1) result.powerFreqs(end)];
end
plotReport.xLabel = 'Frequency (Hz)';
plotReport.yLabel = 'Power (a.u.)';
plotReport.alphaBandLines = settings.alphaBand;
plotReport.ssvepLinesHz = [settings.ssvepLeftHz settings.ssvepRightHz];
plotReport.leftHemisphereColor = [0.20 0.50 0.90];
plotReport.rightHemisphereColor = [0.90 0.30 0.20];
plotReport.panels = struct( ...
    'initial', struct( ...
        'title', 'Initial (-4 to -2 s)', ...
        'leftMean', result.powerInitLeft, ...
        'leftSem', result.powerInitLeftSem, ...
        'rightMean', result.powerInitRight, ...
        'rightSem', result.powerInitRightSem), ...
    'final', struct( ...
        'title', 'Final (-2 to 0 s)', ...
        'leftMean', result.powerFinalLeft, ...
        'leftSem', result.powerFinalLeftSem, ...
        'rightMean', result.powerFinalRight, ...
        'rightSem', result.powerFinalRightSem));
plotReport.method = 'Plot left and right raw linear power means with SEM shading for initial and final windows; share y-limits across the two subplots.';
end

function plotReport = makeSingleBehaviourReport(result)
plotReport = struct();
if isempty(fieldnames(result))
    plotReport.enabled = false;
    return;
end
plotReport.enabled = true;
plotReport.figureNames = { ...
    sprintf('P%d_behaviour_accuracy', result.participantNum), ...
    sprintf('P%d_behaviour_reaction_time', result.participantNum)};
plotReport.plotType = 'block_mean_boxcharts_by_cue_side';
plotReport.sideLabels = result.sideLabels;
plotReport.conditionLabels = result.conditionLabels;
plotReport.accuracy = struct( ...
    'title', sprintf('Participant %d: Behaviour accuracy', result.participantNum), ...
    'yLabel', 'Accuracy (%)', ...
    'yLimits', [0 100], ...
    'mean', result.accuracyMean, ...
    'sem', result.accuracySem, ...
    'blockMeans', result.accuracyBlockMeans, ...
    'trialValues', {result.accuracyTrialValues}, ...
    'nBlocks', result.accuracyNBlocks, ...
    'pairwiseBlockSignrank', result.accuracyPairwise, ...
    'trialCounts', result.trialCounts);
plotReport.reactionTime = struct( ...
    'title', sprintf('Participant %d: Behaviour reaction time', result.participantNum), ...
    'yLabel', 'Reaction time (s)', ...
    'yLimits', [], ...
    'mean', result.rtMean, ...
    'sem', result.rtSem, ...
    'blockMeans', result.rtBlockMeans, ...
    'trialValues', {result.rtTrialValues}, ...
    'nBlocks', result.rtNBlocks, ...
    'pairwiseBlockSignrank', result.rtPairwise, ...
    'trialCounts', result.trialCounts);
plotReport.method = 'The left panel is always contra cue and the right panel is ipsi cue. Each boxchart and point cloud contains block means; paired signrank tests use shared blocks and are Holm-adjusted.';
end

function plotReport = makeSinglePSReport(result)
plotReport = struct();
if isempty(fieldnames(result))
    plotReport.enabled = false;
    return;
end
plotReport.enabled = true;
plotReport.plotType = 'line_spectra';
plotReport.result = result;
plotReport.plots = struct( ...
    'ongoingMeanChannels', struct( ...
        'figureName', sprintf('P%d_PS_ongoing_mean_channels', result.participantNum), ...
        'x', result.fOngoing, ...
        'y', result.inducedChMean, ...
        'xLim', [2 40], ...
        'xLines', [8 12], ...
        'title', sprintf('Participant %d - PS ongoing (per-epoch PSD -> avg across epochs)', result.participantNum)), ...
    'ongoingLeftRight', struct( ...
        'figureName', sprintf('P%d_PS_ongoing_left_right', result.participantNum), ...
        'x', result.fOngoing, ...
        'leftY', result.inducedLMean, ...
        'rightY', result.inducedRMean, ...
        'xLim', [2 40], ...
        'xLines', [8 12], ...
        'legend', {{'Left-electrodes', 'Right-electrodes'}}, ...
        'title', sprintf('Participant %d - PS ongoing spectrum (Left vs Right)', result.participantNum)), ...
    'evokedMeanChannels', struct( ...
        'figureName', sprintf('P%d_PS_evoked_mean_channels', result.participantNum), ...
        'x', result.fEvoked, ...
        'y', result.evokedChMean, ...
        'xLim', [2 40], ...
        'xLines', [result.ssvepRightHz result.ssvepLeftHz], ...
        'title', sprintf('Participant %d - PS evoked (time-avg -> PSD)', result.participantNum)), ...
    'evokedLeftRight', struct( ...
        'figureName', sprintf('P%d_PS_evoked_left_right', result.participantNum), ...
        'x', result.fEvoked, ...
        'leftY', result.evokedLMean, ...
        'rightY', result.evokedRMean, ...
        'xLim', [2 40], ...
        'xLines', [result.ssvepRightHz result.ssvepLeftHz], ...
        'legend', {{'Left-electrodes', 'Right-electrodes'}}, ...
        'title', sprintf('Participant %d - PS evoked spectrum (Left vs Right)', result.participantNum)));
plotReport.method = 'Each PS figure uses plot() lines with grid on, xlim [2 40], and vertical reference lines at alpha or SSVEP frequencies.';
end

function cLim = spectralColorLimits(panelData)
allVals = [];
for idx = 1:numel(panelData)
    d = panelData{idx};
    if ~isempty(d)
        allVals = [allVals; d(isfinite(d(:)))];%#ok<AGROW>
    end
end
cLim = [-1 1];
if numel(allVals) > 1
    cLim = [prctile(allVals, 2), prctile(allVals, 98)];
end
end

function pVal = signrankPairsOrNaN(pairedVals)
pVal = NaN;
if isempty(pairedVals) || size(pairedVals, 2) < 2
    return;
end
validPairs = isfinite(pairedVals(:, 1)) & isfinite(pairedVals(:, 2));
if nnz(validPairs) > 1
    pVal = signrank(pairedVals(validPairs, 1), pairedVals(validPairs, 2));
end
end

function printAnalysisJsonReport(reportName, report)
fprintf('\n===== BEGIN_RESULTS_REPORT_JSON: %s =====\n', reportName);
try
    reportJson = jsonencode(report, 'PrettyPrint', true);
catch
    reportJson = jsonencode(report);
end
fprintf('%s\n', reportJson);
fprintf('===== END_RESULTS_REPORT_JSON: %s =====\n', reportName);
end

function saveAnalysisJsonReport(reportName, report, resultsFolder)
try
    reportJson = jsonencode(report, 'PrettyPrint', true);
catch
    reportJson = jsonencode(report);
end
if ~isfolder(resultsFolder)
    mkdir(resultsFolder);
end
fileName = sprintf('%s_results_report.json', sanitizeReportFileName(reportName));
filePath = fullfile(resultsFolder, fileName);
fid = fopen(filePath, 'w');
if fid == -1
    warning('Could not open results report file for writing: %s', filePath);
    return;
end
cleanupObj = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', reportJson);
clear cleanupObj;
fprintf('Saved results report JSON to %s\n', filePath);
end

function out = sanitizeReportFileName(in)
out = regexprep(strtrim(in), '\s+', '_');
out = regexprep(out, '[^A-Za-z0-9_-]', '');
if isempty(out)
    out = 'results_report';
end
end

function out = ternary(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
