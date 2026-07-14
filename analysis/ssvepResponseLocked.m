clear;
close all;
clc;

% -------------------------------------------------------------------------
%% Response-locked SSVEP analysis and evoked/ongoing power spectra - gameNFv3.m
%
% This script mirrors analysis/ssvepCueOnsetLocked.m's GDF loading,
% preprocessing, trial matching, 28-electrode SSVEP ROI, and independent
% evoked/ongoing power spectra, but plots the raw adjacent-bin-normalized
% SSVEP log-power series locked to response instead of cue onset.
%
% For each matched trial, the script computes the raw log-SNR time series:
%
%     log(power at target frequency / mean(power at adjacent frequency bins))
%
% separately for 23Hz and 29Hz. No pre-cue baseline subtraction and no
% per-trial cue/response zeroing are applied. The plot helper aligns raw
% trial series to response, averages across trials within each cue, and
% zeroes only the final averaged trace to its own value at response
% (t = 0). Cue onset is shown as one dot per contributing trial, relative
% to the response.
%
% Separately from the response-locked series, sequential 3-second
% mini-epochs spanning each whole matched trial are pooled to compute
% ongoing (induced) and evoked power spectra. These use the same settings
% and 39-channel montage as analysis/ssvepCueOnsetLocked.m, and are made
% for the combined and/or individual scopes selected by plotMode.
%
% Channel montage: all GDF reads/preprocessing use the 41-channel
% A1-A32+B1-B9 subset. The SSVEP ROI is the 14 right + 14 left electrode
% indices from RT_files/RT_acquisition_8.m, pooled together for both
% tagging frequencies. The independent evoked/ongoing spectra use all 41
% channels except the manual exclusions configured below.
% -------------------------------------------------------------------------

%% Inputs
participantNums = [58 59];
faDataRoot = '/Volumes/250GBKC/FAData';
% SSVEP tagging frequencies.
freqC1Hz = 23;
freqC2Hz = 29;

% Plotting scope: 'combined', 'individual', or 'both'.
plotMode = 'both';

% Trigger values sent by gameNFv3.m.
trigTrialStart = 20;
trigCueOnset   = 45;
trigResponse   = 40;
trigTrialStop  = 30;

% Preprocessing (mirrors analysis/ssvepCueOnsetLocked.m).
desiredTargetFs = 256;   % actual achieved rate snaps to an exact integer decimation of the native rate
prepBand        = [1 45];
prepBandOrd     = 4;
useNotch50      = true;

% SSVEP ROI channel indices in the 41-channel GDF EEG order (A1-A32+B1-B9),
% matching RT_files/RT_acquisition_8.m's pnqL1S/pnqL2S. Both tagging
% frequencies are read from the pooled 28-electrode set, not frequency by
% hemisphere.
ssvepRightChannelIdx = [28 30 32 36 38 35 37 39 40 41 26 27 29 31];
ssvepLeftChannelIdx  = [15 17 5 7 9 6 8 10 11 12 13 14 16 18];
ssvepRoiChannelIdx   = [ssvepRightChannelIdx, ssvepLeftChannelIdx];

% Optional manual bad-channel overrides per participant, unioned with the
% automatic detector (see helperFunctions/repairBadChannelsSpline.m).
% Example: manualBadChannels(58) = {'A5', 'B12'};
manualBadChannels = containers.Map('KeyType', 'double', 'ValueType', 'any');

% GDF-pair-to-CSV-row matching tolerance: how close (seconds) a candidate
% trigger pair's duration must be to a CSV row's TrialDurationSec to count
% as a match (see helperFunctions/matchGdfPairsToTrials.m).
pairMatchToleranceSec = 0.2;

% SSVEP sliding-window spectral estimation.
spectrumWindowSec = 1;
stepSec           = 0.1;
freqsHz           = [freqC1Hz, freqC2Hz];
freqLabels        = {sprintf('%g Hz (c1 flock)', freqC1Hz), ...
                     sprintf('%g Hz (c2 flock)', freqC2Hz)};
freqColors        = [0 191 255; 255 140 0] / 255; % same RGB as gameNFv3.m's colorC1/colorC2

% Response-locked display window. Cue onset is plotted as marker dots.
responseWindowSec = [-4, 0.1];

% Save figures as PNGs and their underlying numbers as .mat files under
% analysis/results/. Set false to only display figures.
saveFigures = false;

% Evoked/ongoing power spectrum settings. These spectra are independent of
% response locking: they pool fixed-length mini-epochs across each whole
% matched trial, matching analysis/ssvepCueOnsetLocked.m.
spectraEpochLenSec = 3;
spectraFpass       = [2 40];
spectraNormMode    = 'rel-mean';
manuallyExcludedSpectraChannels = {'B1', 'B2'};

%% Paths and toolboxes
analysisDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(analysisDir);
addpath(fullfile(repoRoot, 'helperFunctions'));
sfpFile = fullfile(analysisDir, 'Biosemi_128_Cartesian_Default.sfp');
resultsDir = fullfile(analysisDir, 'results');
if saveFigures && ~isfolder(resultsDir)
    mkdir(resultsDir);
end

initializeGdfAnalysisToolboxes();

scalpLabels = [arrayfun(@(n) sprintf('A%d', n), 1:32, 'UniformOutput', false), ...
               arrayfun(@(n) sprintf('B%d', n), 1:9, 'UniformOutput', false)].';
if any(ssvepRoiChannelIdx < 1 | ssvepRoiChannelIdx > numel(scalpLabels))
    error('ssvepResponseLocked:ssvepRoiIndexOutOfRange', ...
        'SSVEP ROI indices must be within the %d-channel scalp label list.', numel(scalpLabels));
end
ssvepRoiLabels = scalpLabels(ssvepRoiChannelIdx);
spectraChannelLabels = setdiff(scalpLabels, manuallyExcludedSpectraChannels, 'stable');

chronuxParams = struct( ...
    'Fs', desiredTargetFs, ... % corrected below to the actual achieved targetFs once known
    'tapers', [1 1], ...
    'pad', 1, ...
    'err', 0, ...
    'trialave', 0, ...
    'fpass', [1 45]);

spectraChronuxParamsOngoing = struct( ...
    'Fs', desiredTargetFs, ... % corrected below
    'tapers', [1 1], ...
    'pad', 1, ...
    'err', 0, ...
    'trialave', 1, ...
    'fpass', spectraFpass);
spectraChronuxParamsEvoked = struct( ...
    'Fs', desiredTargetFs, ... % corrected below
    'tapers', [1 1], ...
    'pad', 0, ...
    'err', 0, ...
    'trialave', 0, ...
    'fpass', spectraFpass);

%% Phase A: per-participant loading/preprocessing, per-trial SSVEP series,
% and pooled mini-epochs for the independent evoked/ongoing spectra
allTrials = struct('participant', {}, 'block', {}, 'trialNumber', {}, 'cue', {}, 'series', {}, ...
    'windowCenterTimesSec', {}, 'cueOnsetRelSec', {}, 'responseRelSec', {}, 'durationSec', {});
commonTargetFs = [];
pooledMiniEpochs = [];
miniEpochParticipant = [];

for participantIdx = 1:numel(participantNums)
    participantNum = participantNums(participantIdx);
    fprintf('\n=== Participant %d ===\n', participantNum);
    participantDir = fullfile(faDataRoot, sprintf('P%d', participantNum));
    gdfFolder = fullfile(participantDir, 'GDF');

    gdfFiles = findParticipantGdfFiles(gdfFolder, participantNum);
    fprintf('  Found %d GDF file(s): %s\n', numel(gdfFiles), strjoin(gdfFiles, ', '));

    [rawData, eventSamples, eventValues, rawFs] = loadConcatenatedGdfRaw(gdfFiles, scalpLabels);
    fprintf('  Loaded %.1f sec of continuous data at %g Hz (native).\n', ...
        size(rawData.trial{1}, 2) / rawFs, rawFs);

    [prepData, downsampleFactor, targetFs] = preprocessContinuousEeg( ...
        rawData, desiredTargetFs, prepBand, prepBandOrd, useNotch50);
    clear rawData;

    if isempty(commonTargetFs)
        commonTargetFs = targetFs;
    elseif targetFs ~= commonTargetFs
        error('ssvepResponseLocked:targetFsMismatch', ...
            ['Participant %d resampled to %g Hz, but earlier participant(s) used %g Hz - all ' ...
             'participants must share one sampling rate before their trial series can be pooled ' ...
             'onto a common time/frequency axis.'], participantNum, targetFs, commonTargetFs);
    end
    chronuxParams.Fs = targetFs;
    spectraChronuxParamsOngoing.Fs = targetFs;
    spectraChronuxParamsEvoked.Fs = targetFs;

    if isKey(manualBadChannels, participantNum)
        manualBad = manualBadChannels(participantNum);
    else
        manualBad = {};
    end
    [repairedData, removedLabels] = repairBadChannelsSpline(prepData, sfpFile, manualBad);
    clear prepData;
    fprintf('  Repaired channel(s): %s\n', strjoin(removedLabels, ', '));

    cfgRef = [];
    cfgRef.reref = 'yes';
    cfgRef.refmethod = 'avg';
    cfgRef.refchannel = 'all';
    referencedData = ft_preprocessing(cfgRef, repairedData);
    clear repairedData;

    roiMask = ismember(referencedData.label, ssvepRoiLabels);
    if nnz(roiMask) ~= numel(ssvepRoiLabels)
        error('ssvepResponseLocked:ssvepRoiChannelsMissing', ...
            'Only %d of the %d requested SSVEP ROI channels were found in participant %d''s data.', ...
            nnz(roiMask), numel(ssvepRoiLabels), participantNum);
    end
    fprintf('  SSVEP ROI (%d channels): %s\n', numel(ssvepRoiLabels), strjoin(ssvepRoiLabels, ', '));
    roiSignal = mean(referencedData.trial{1}(roiMask, :), 1);

    spectraMask = ismember(referencedData.label, spectraChannelLabels);
    if nnz(spectraMask) ~= numel(spectraChannelLabels)
        error('ssvepResponseLocked:spectraChannelsMissing', ...
            'Only %d of the %d requested spectra channels were found in participant %d''s data.', ...
            nnz(spectraMask), numel(spectraChannelLabels), participantNum);
    end
    spectraSignal = referencedData.trial{1}(spectraMask, :);
    clear referencedData;

    epochLenSamples = round(spectraEpochLenSec * targetFs);

    trialTable = loadParticipantTrialTable(participantDir, participantNum);
    pairSamples = extractTrialStartStopPairs(eventSamples, eventValues, trigTrialStart, trigTrialStop);
    fprintf('  %d GDF trial-start/stop pair(s) found for %d CSV trial row(s).\n', ...
        size(pairSamples, 1), height(trialTable));
    matched = matchGdfPairsToTrials(pairSamples, rawFs, trialTable, pairMatchToleranceSec);

    nMatched = 0;
    nWithResponse = 0;
    for rowIdx = 1:height(matched)
        if isnan(matched.GdfStartSample(rowIdx))
            continue;
        end
        startIdx = max(1, rawSampleToResampledIndex(matched.GdfStartSample(rowIdx), downsampleFactor));
        stopIdx = min(numel(roiSignal), rawSampleToResampledIndex(matched.GdfStopSample(rowIdx), downsampleFactor));
        if stopIdx <= startIdx
            continue;
        end

        cueOnsetSampleRaw = findEventSample(eventSamples, eventValues, trigCueOnset, ...
            matched.GdfStartSample(rowIdx), matched.GdfStopSample(rowIdx), true);
        if isnan(cueOnsetSampleRaw)
            warning('ssvepResponseLocked:noCueOnset', ...
                'Participant %d, Block %d, Trial %d: no unique cue-onset trigger found; skipped.', ...
                participantNum, matched.Block(rowIdx), matched.TrialNumber(rowIdx));
            continue;
        end
        cueOnsetIdx = rawSampleToResampledIndex(cueOnsetSampleRaw, downsampleFactor);
        cueOnsetRelSec = (cueOnsetIdx - startIdx) / targetFs;

        responseSampleRaw = findEventSample(eventSamples, eventValues, trigResponse, ...
            matched.GdfStartSample(rowIdx), matched.GdfStopSample(rowIdx), false);
        if isnan(responseSampleRaw)
            responseRelSec = NaN;
        else
            responseIdx = rawSampleToResampledIndex(responseSampleRaw, downsampleFactor);
            responseRelSec = (responseIdx - startIdx) / targetFs;
            nWithResponse = nWithResponse + 1;
        end

        trialSignal = roiSignal(startIdx:stopIdx);
        [seriesMat, windowCenterTimesSec] = computeTrialSsvepLogSnrSeries( ...
            trialSignal, targetFs, freqsHz, spectrumWindowSec, stepSec, chronuxParams);
        if isempty(seriesMat)
            warning('ssvepResponseLocked:trialTooShort', ...
                'Participant %d, Block %d, Trial %d: shorter than one %gs window; skipped.', ...
                participantNum, matched.Block(rowIdx), matched.TrialNumber(rowIdx), spectrumWindowSec);
            continue;
        end

        thisTrial = struct( ...
            'participant', participantNum, ...
            'block', matched.Block(rowIdx), ...
            'trialNumber', matched.TrialNumber(rowIdx), ...
            'cue', matched.Cue{rowIdx}, ...
            'series', seriesMat, ...
            'windowCenterTimesSec', windowCenterTimesSec, ...
            'cueOnsetRelSec', cueOnsetRelSec, ...
            'responseRelSec', responseRelSec, ...
            'durationSec', numel(trialSignal) / targetFs);
        allTrials(end + 1) = thisTrial; %#ok<SAGROW>
        nMatched = nMatched + 1;

        trialSpectraData = spectraSignal(:, startIdx:stopIdx);
        theseEpochs = extractMiniEpochs(trialSpectraData, epochLenSamples);
        pooledMiniEpochs = cat(3, pooledMiniEpochs, theseEpochs);
        miniEpochParticipant = [miniEpochParticipant, ...
            repmat(participantNum, 1, size(theseEpochs, 3))]; %#ok<AGROW>
    end
    fprintf('  %d trial(s) contributed an SSVEP series; %d had a response trigger.\n', nMatched, nWithResponse);
    clear roiSignal spectraSignal;
end

if isempty(allTrials)
    error('ssvepResponseLocked:noTrials', 'No trials were successfully matched/processed for any participant.');
end

%% Phase B: response-locked plots
cueCodes = {'c1', 'c2'};
cueDescriptions = { ...
    'c1 cue (attend flock 1, report its POINTING direction)', ...
    'c2 cue (attend flock 2, report its MOVING direction)'};
buildCueTitles = @(eventLabelCap, scopePrefix) cellfun( ...
    @(d) sprintf('SSVEP time series locked to %s - %s%s', eventLabelCap, scopePrefix, d), ...
    cueDescriptions, 'UniformOutput', false);

runCombined = ismember(plotMode, {'combined', 'both'});
runIndividual = ismember(plotMode, {'individual', 'both'});
if ~runCombined && ~runIndividual
    error('ssvepResponseLocked:badPlotMode', 'plotMode must be ''combined'', ''individual'', or ''both''.');
end

if runCombined
    fprintf('\n=== Combined response-locked (P%s) ===\n', strjoin(string(participantNums), ', P'));
    plotSsvepLockedToEvent(allTrials, 'responseRelSec', stepSec, abs(responseWindowSec(1)), responseWindowSec(2), ...
        cueCodes, buildCueTitles('response', ''), freqLabels, freqColors, 'response', ...
        resultsDir, saveFigures, 'ssvepResponseLocked_combined', 'cueOnsetRelSec');

    nMiniEpochsCombined = size(pooledMiniEpochs, 3);
    spectraSubtitleCombined = sprintf('n = %d mini-epochs (%gs each) from %d trials, %d participant(s), %d channels', ...
        nMiniEpochsCombined, spectraEpochLenSec, numel(allTrials), numel(participantNums), numel(spectraChannelLabels));
    plotEvokedOngoingSpectra(pooledMiniEpochs, spectraChronuxParamsOngoing, spectraChronuxParamsEvoked, ...
        spectraNormMode, freqsHz, freqLabels, freqColors, 'All participants - ', spectraSubtitleCombined, ...
        resultsDir, saveFigures, 'ssvepResponseLockedSpectra_combined');
end

if runIndividual
    for participantNum = participantNums
        fprintf('\n=== Individual response-locked: Participant %d ===\n', participantNum);
        participantTrials = allTrials([allTrials.participant] == participantNum);
        if isempty(participantTrials)
            warning('ssvepResponseLocked:noIndividualTrials', ...
                'Participant %d has no matched trials; skipping its individual plots.', participantNum);
            continue;
        end

        scopePrefix = sprintf('P%d, ', participantNum);
        plotSsvepLockedToEvent(participantTrials, 'responseRelSec', stepSec, abs(responseWindowSec(1)), responseWindowSec(2), ...
            cueCodes, buildCueTitles('response', scopePrefix), freqLabels, freqColors, 'response', ...
            resultsDir, saveFigures, sprintf('ssvepResponseLocked_P%d', participantNum), 'cueOnsetRelSec');

        participantMiniEpochs = pooledMiniEpochs(:, :, miniEpochParticipant == participantNum);
        nMiniEpochsThis = size(participantMiniEpochs, 3);
        spectraSubtitleThis = sprintf('n = %d mini-epochs (%gs each) from %d trials, %d channels', ...
            nMiniEpochsThis, spectraEpochLenSec, numel(participantTrials), numel(spectraChannelLabels));
        plotEvokedOngoingSpectra(participantMiniEpochs, spectraChronuxParamsOngoing, spectraChronuxParamsEvoked, ...
            spectraNormMode, freqsHz, freqLabels, freqColors, sprintf('P%d - ', participantNum), spectraSubtitleThis, ...
            resultsDir, saveFigures, sprintf('ssvepResponseLockedSpectra_P%d', participantNum));
    end
end
