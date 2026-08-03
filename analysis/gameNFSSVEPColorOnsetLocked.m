clear;
close all;
clc;

% -------------------------------------------------------------------------
%% Colour-onset-locked SSVEP analysis and evoked/ongoing power spectra - gameNFv6.m
%
% Companion to analysis/gameNFSSVEPCueOnsetLocked.m and
% analysis/gameNFSSVEPResponseLocked.m, sharing their GDF loading,
% preprocessing, trial matching, 28-electrode SSVEP ROI and independent
% evoked/ongoing power spectra. What differs is the locking event: this
% script locks to COLOUR ONSET, the gameNFv6.m-only event where the
% neurofeedback level had been held in the green zone for nfGreenHoldSec and
% the flocks' true colours were revealed (trigger 'success' = 50).
%
% Why that event is the interesting one for gameNFv6.m. The whole trial up
% to colour onset is the participant working the neurofeedback - driving the
% shared grayscale leaf fill from black towards white by lateralising their
% SSVEP towards the cued frequency - and colour onset is the moment that
% work is declared to have succeeded. It is also the moment gameNFv6.m opens
% the response window: no response is accepted before it, and ReactionTime in
% the behavioural CSV is measured from it. So it is simultaneously the
% endpoint of the NF epoch and the zero of the behavioural epoch, and it is
% the only one of the three lockable events whose timing the participant's
% own EEG determined. Locking here should show the cued frequency's log-SNR
% climbing into t = 0 by construction; the question the plots are for is the
% shape and the timing of that climb, and what the non-cued frequency does
% while it happens.
%
% Trials where the reveal was never earned (RevealTimeout = 1 in the CSV,
% ColorOnsetTime = NaN, no trigger 50 in the GDF) have no event to lock to
% and are excluded from the locked plots - plotSsvepLockedToEvent drops them
% on the NaN. They are counted and reported below, and they still contribute
% to the whole-trial evoked/ongoing spectra, which are independent of the
% locking. On a well-tuned nfLevelRatePerUnitNf that exclusion should be a
% minority of trials; if it is most of them, the neurofeedback is too hard
% and the locked plots are being computed on a self-selected subset - the
% printed reveal rate is there to make that impossible to miss.
%
% Cue onset is shown as one dot per contributing trial, relative to colour
% onset, so the length of each trial's NF phase is visible on the plot.
%
% Channel montage: all GDF reads/preprocessing use the 41-channel
% A1-A32+B1-B9 subset. The SSVEP ROI is the 14 right + 14 left electrode
% indices from RT_files/RT_acquisition_8.m, pooled together for both
% tagging frequencies. The independent evoked/ongoing spectra use all 41
% channels except the manual exclusions configured below.
% -------------------------------------------------------------------------

%% Inputs
participantNums = [63];
faDataRoot = '/Volumes/250GBKC/FAData';
% SSVEP tagging frequencies.
freqC1Hz = 19;
freqC2Hz = 23;

% Plotting scope: 'combined', 'individual', or 'both'.
plotMode = 'both';

% Trigger values sent by gameNFv6.m.
trigTrialStart = 20;
trigCueOnset   = 45;
trigColorOnset = 50;   % 'success' - gameNFv6.m's colour-onset/NF-reveal event
trigResponse   = 40;
trigTrialStop  = 30;

% Preprocessing (mirrors the sibling analysis scripts).
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
freqColors        = [0 191 255; 255 140 0] / 255; % same RGB as gameNFv6.m's colorC1/colorC2

% Colour-onset-locked display window. Weighted towards the pre-event side:
% everything the neurofeedback did to earn the reveal is before t = 0, and
% gameNFv6.m's nfRevealTimeoutSec allows up to 10s of it. Cue onset is
% plotted as marker dots, so trials whose NF phase was longer than this
% window simply have no dot rather than being truncated silently.
colorOnsetWindowSec = [-8, 2];

% Save figures as PNGs and their underlying numbers as .mat files under
% analysis/results/. Set false to only display figures.
saveFigures = false;

% Evoked/ongoing power spectrum settings. These spectra are independent of
% colour-onset locking: they pool fixed-length mini-epochs across each whole
% matched trial, matching the sibling analysis scripts.
spectraEpochLenSec = 3;
spectraFpass       = [2 40];
spectraNormMode    = 'rel-mean';
manuallyExcludedSpectraChannels = {'B1'};

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
    error('ssvepColorOnsetLocked:ssvepRoiIndexOutOfRange', ...
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
    'windowCenterTimesSec', {}, 'cueOnsetRelSec', {}, 'colorOnsetRelSec', {}, 'responseRelSec', {}, ...
    'durationSec', {});
commonTargetFs = [];
pooledMiniEpochs = [];
miniEpochParticipant = [];

% v6 behavioural summary, accumulated across participants from the CSV
% columns rather than from the GDF triggers (so it covers every logged
% trial, including any that failed to match a GDF pair).
behaviourRevealDelaysSec = [];
behaviourRevealed = [];
behaviourAccuracyRevealed = [];

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
        error('ssvepColorOnsetLocked:targetFsMismatch', ...
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
        error('ssvepColorOnsetLocked:ssvepRoiChannelsMissing', ...
            'Only %d of the %d requested SSVEP ROI channels were found in participant %d''s data.', ...
            nnz(roiMask), numel(ssvepRoiLabels), participantNum);
    end
    fprintf('  SSVEP ROI (%d channels): %s\n', numel(ssvepRoiLabels), strjoin(ssvepRoiLabels, ', '));
    roiSignal = mean(referencedData.trial{1}(roiMask, :), 1);

    spectraMask = ismember(referencedData.label, spectraChannelLabels);
    if nnz(spectraMask) ~= numel(spectraChannelLabels)
        error('ssvepColorOnsetLocked:spectraChannelsMissing', ...
            'Only %d of the %d requested spectra channels were found in participant %d''s data.', ...
            nnz(spectraMask), numel(spectraChannelLabels), participantNum);
    end
    spectraSignal = referencedData.trial{1}(spectraMask, :);
    clear referencedData;

    epochLenSamples = round(spectraEpochLenSec * targetFs);

    trialTable = loadParticipantTrialTable(participantDir, participantNum);
    if ~ismember('ColorOnsetTime', trialTable.Properties.VariableNames)
        error('ssvepColorOnsetLocked:notV6Data', ...
            ['Participant %d''s trialdata CSV has no ColorOnsetTime column, so it was not ' ...
             'recorded with gameNFv6.m. This script is gameNFv6.m-specific; use ' ...
             'gameNFSSVEPCueOnsetLocked.m or gameNFSSVEPResponseLocked.m for earlier variants.'], ...
            participantNum);
    end

    % Behavioural reveal statistics for this participant, straight from the CSV.
    revealedMask = ~isnan(trialTable.ColorOnsetTime);
    behaviourRevealed = [behaviourRevealed; revealedMask]; %#ok<AGROW>
    behaviourRevealDelaysSec = [behaviourRevealDelaysSec; ...
        trialTable.ColorOnsetTime(revealedMask) - trialTable.CueOnsetTime(revealedMask)]; %#ok<AGROW>
    behaviourAccuracyRevealed = [behaviourAccuracyRevealed; trialTable.Accuracy(revealedMask)]; %#ok<AGROW>
    fprintf('  Behaviour: %d/%d trial(s) reached colour onset (%.0f%%), median %.2fs after cue onset.\n', ...
        nnz(revealedMask), height(trialTable), 100 * mean(revealedMask), ...
        median(trialTable.ColorOnsetTime(revealedMask) - trialTable.CueOnsetTime(revealedMask)));

    pairSamples = extractTrialStartStopPairs(eventSamples, eventValues, trigTrialStart, trigTrialStop);
    fprintf('  %d GDF trial-start/stop pair(s) found for %d CSV trial row(s).\n', ...
        size(pairSamples, 1), height(trialTable));
    matched = matchGdfPairsToTrials(pairSamples, rawFs, trialTable, pairMatchToleranceSec);

    nMatched = 0;
    nWithColorOnset = 0;
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
            warning('ssvepColorOnsetLocked:noCueOnset', ...
                'Participant %d, Block %d, Trial %d: no unique cue-onset trigger found; skipped.', ...
                participantNum, matched.Block(rowIdx), matched.TrialNumber(rowIdx));
            continue;
        end
        cueOnsetIdx = rawSampleToResampledIndex(cueOnsetSampleRaw, downsampleFactor);
        cueOnsetRelSec = (cueOnsetIdx - startIdx) / targetFs;

        % Colour onset is legitimately absent on a trial where the reveal
        % was never earned, exactly like the response trigger on a timeout -
        % so this is a silent NaN, not a warning.
        colorOnsetSampleRaw = findEventSample(eventSamples, eventValues, trigColorOnset, ...
            matched.GdfStartSample(rowIdx), matched.GdfStopSample(rowIdx), false);
        if isnan(colorOnsetSampleRaw)
            colorOnsetRelSec = NaN;
        else
            colorOnsetIdx = rawSampleToResampledIndex(colorOnsetSampleRaw, downsampleFactor);
            colorOnsetRelSec = (colorOnsetIdx - startIdx) / targetFs;
            nWithColorOnset = nWithColorOnset + 1;
        end

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
            warning('ssvepColorOnsetLocked:trialTooShort', ...
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
            'colorOnsetRelSec', colorOnsetRelSec, ...
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
    fprintf(['  %d trial(s) contributed an SSVEP series; %d had a colour-onset trigger, ' ...
        '%d had a response trigger.\n'], nMatched, nWithColorOnset, nWithResponse);
    clear roiSignal spectraSignal;
end

if isempty(allTrials)
    error('ssvepColorOnsetLocked:noTrials', 'No trials were successfully matched/processed for any participant.');
end

%% Behavioural summary across everything loaded
fprintf('\n=== Neurofeedback reveal summary (all loaded CSV trials) ===\n');
fprintf('  Reached colour onset: %d/%d trials (%.0f%%).\n', ...
    nnz(behaviourRevealed), numel(behaviourRevealed), 100 * mean(behaviourRevealed));
if ~isempty(behaviourRevealDelaysSec)
    fprintf('  Cue onset -> colour onset: median %.2fs, IQR %.2f-%.2fs, range %.2f-%.2fs.\n', ...
        median(behaviourRevealDelaysSec), prctile(behaviourRevealDelaysSec, 25), ...
        prctile(behaviourRevealDelaysSec, 75), min(behaviourRevealDelaysSec), ...
        max(behaviourRevealDelaysSec));
    fprintf('  Accuracy on revealed trials: %.1f%%.\n', 100 * mean(behaviourAccuracyRevealed));
end
nLockable = sum(arrayfun(@(t) isfinite(t.colorOnsetRelSec), allTrials));
fprintf('  Of the %d EEG-matched trials, %d (%.0f%%) can be locked to colour onset.\n', ...
    numel(allTrials), nLockable, 100 * nLockable / numel(allTrials));
if nLockable < 0.5 * numel(allTrials)
    warning('ssvepColorOnsetLocked:lowRevealRate', ...
        ['Fewer than half the matched trials reached colour onset, so the locked plots below ' ...
         'are computed on a self-selected minority. Consider raising nfLevelRatePerUnitNf (or ' ...
         'lowering nfWhiteTopRelaxation / nfGreenHoldSec) in gameNFv6.m before reading much ' ...
         'into them.']);
end

%% Phase B: colour-onset-locked plots
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
    error('ssvepColorOnsetLocked:badPlotMode', 'plotMode must be ''combined'', ''individual'', or ''both''.');
end

if runCombined
    fprintf('\n=== Combined colour-onset-locked (P%s) ===\n', strjoin(string(participantNums), ', P'));
    plotSsvepLockedToEvent(allTrials, 'colorOnsetRelSec', stepSec, abs(colorOnsetWindowSec(1)), colorOnsetWindowSec(2), ...
        cueCodes, buildCueTitles('colour onset', ''), freqLabels, freqColors, 'colour onset', ...
        resultsDir, saveFigures, 'ssvepColorOnsetLocked_combined', 'cueOnsetRelSec');

    nMiniEpochsCombined = size(pooledMiniEpochs, 3);
    spectraSubtitleCombined = sprintf('n = %d mini-epochs (%gs each) from %d trials, %d participant(s), %d channels', ...
        nMiniEpochsCombined, spectraEpochLenSec, numel(allTrials), numel(participantNums), numel(spectraChannelLabels));
    plotEvokedOngoingSpectra(pooledMiniEpochs, spectraChronuxParamsOngoing, spectraChronuxParamsEvoked, ...
        spectraNormMode, freqsHz, freqLabels, freqColors, 'All participants - ', spectraSubtitleCombined, ...
        resultsDir, saveFigures, 'ssvepColorOnsetLockedSpectra_combined');
end

if runIndividual
    for participantNum = participantNums
        fprintf('\n=== Individual colour-onset-locked: Participant %d ===\n', participantNum);
        participantTrials = allTrials([allTrials.participant] == participantNum);
        if isempty(participantTrials)
            warning('ssvepColorOnsetLocked:noIndividualTrials', ...
                'Participant %d has no matched trials; skipping its individual plots.', participantNum);
            continue;
        end

        scopePrefix = sprintf('P%d, ', participantNum);
        plotSsvepLockedToEvent(participantTrials, 'colorOnsetRelSec', stepSec, abs(colorOnsetWindowSec(1)), colorOnsetWindowSec(2), ...
            cueCodes, buildCueTitles('colour onset', scopePrefix), freqLabels, freqColors, 'colour onset', ...
            resultsDir, saveFigures, sprintf('ssvepColorOnsetLocked_P%d', participantNum), 'cueOnsetRelSec');

        participantMiniEpochs = pooledMiniEpochs(:, :, miniEpochParticipant == participantNum);
        nMiniEpochsThis = size(participantMiniEpochs, 3);
        spectraSubtitleThis = sprintf('n = %d mini-epochs (%gs each) from %d trials, %d channels', ...
            nMiniEpochsThis, spectraEpochLenSec, numel(participantTrials), numel(spectraChannelLabels));
        plotEvokedOngoingSpectra(participantMiniEpochs, spectraChronuxParamsOngoing, spectraChronuxParamsEvoked, ...
            spectraNormMode, freqsHz, freqLabels, freqColors, sprintf('P%d - ', participantNum), spectraSubtitleThis, ...
            resultsDir, saveFigures, sprintf('ssvepColorOnsetLockedSpectra_P%d', participantNum));
    end
end
