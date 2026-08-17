clear;
close all;
clc;

% -------------------------------------------------------------------------
%% SSVEP analysis (cue-onset-locked SSVEP, evoked/ongoing power spectra,
% reaction time) - gameNFv3.m
%
% For each participant's continuous EEG recording, this script:
%   1) Loads and concatenates that participant's GDF file(s) - some
%      recordings are auto-split by the acquisition software purely on a
%      byte-size cap, unrelated to behavioural block boundaries, so all
%      split files for one participant are treated as one continuous
%      session (see helperFunctions/findParticipantGdfFiles.m).
%   2) Reads, filters, bad-channel-repairs, and re-references only this
%      lab's long-standing 41-channel montage (A1-A32 + B1-B9 - see
%      "Channel montage" below), not the full 128-channel cap - the same
%      channel scope analysis/singleParticipantBehaviourOffline.m uses for
%      everything (its settings.channels=41 is precisely "the first 41
%      non-STATUS channels in GDF file order"), not just its final spectra
%      selection. This also cuts GDF read/preprocessing time and memory by
%      about 3x versus reading the full 128 channels.
%   3) Matches each GDF trial-start/trial-stop trigger pair to its
%      behavioural CSV row by duration, not raw position, since an
%      escaped/aborted trial sends triggers but writes no CSV row (see
%      helperFunctions/matchGdfPairsToTrials.m) - this matters here: this
%      lab's pilot recordings contain more trigger pairs than the 72 real
%      trials per participant, almost certainly from test/practice runs
%      recorded before or between the 3 real blocks.
%   4) For each matched trial, locates that trial's own cue-onset trigger
%      and (if a response was given - a timeout has none) response trigger
%      (helperFunctions/findEventSample.m), computes a sliding-window
%      adjacent-bin-normalized raw log-power time series (log-SNR) at 19Hz
%      and 23Hz over the same 28 SSVEP electrodes used by
%      RT_files/RT_acquisition_8.m (Chronux multitaper). Each raw trial
%      series is then time-locked to cue onset
%      (helperFunctions/alignSeriesToEvent.m), with NaN-padding on
%      whichever side a given trial doesn't reach; only the final averaged
%      trace is zeroed to its own cue-onset value. Valid response triggers
%      are plotted as one dot per trial at their response time relative to
%      cue onset.
%   5) Averages across matched trials, split by cue (c1 vs c2 - see "What
%      c1/c2 mean" below), and plots 19Hz vs 23Hz mean +/- SEM against time
%      relative to cue onset.
%   6) Separately, pools sequential 3-second mini-epochs (whole trial) over
%      the same 41-channel montage minus B1/B2 (see "Channel montage"
%      below) to compute one ongoing (induced) and one evoked power
%      spectrum, the same way
%      analysis/singleParticipantBehaviourOffline.m's processSinglePSSpectra
%      does, except pooled across all trials/cues rather than split by
%      condition (per your call), and averaged across this flat montage
%      rather than a left/right ROI split (this task's two SSVEP-tagged
%      flocks are spatially intermixed on screen, not lateralized, so a
%      left/right split doesn't apply here).
%   7) Separately, plots mean +/- SEM reaction time as a grouped bar chart
%      (one group per block, one bar per cue within the group) - purely
%      behavioural (CSV-only), independent of GDF trigger matching, so a
%      trial contributes here even if step 3 couldn't match it to an EEG
%      epoch.
%   8) All of the above run once pooling every requested participant
%      together (plotMode 'combined'), and/or once per participant
%      separately (plotMode 'individual') - see plotMode below.
%
% What c1/c2 mean (see README.md's "The cue and the task rule"):
%   - Flock 1 is always shown in colorC1 and its SSVEP border always
%     flickers at freqC1Hz (19Hz). Cue = c1 means: attend flock 1 and
%     report its POINTING direction.
%   - Flock 2 is always shown in colorC2 and its SSVEP border always
%     flickers at freqC2Hz (23Hz). Cue = c2 means: attend flock 2 and
%     report its MOVING direction.
%   If attention modulates steady-state SSVEP power at the attended
%   flock's tagged frequency, c1-cue trials should show relatively more
%   19Hz (vs 23Hz) power after cue onset, and c2-cue trials the reverse.
%
% Channel montage: A1-A32 plus B1-B9 is this lab's long-standing
% 41-channel subset (analysis/singleParticipantBehaviourOffline.m's
% settings.channels=41 is precisely "the first 41 non-STATUS channels in
% GDF file order", i.e. A1-A32+B1-B9). Everything in this script - reading,
% filtering, bad-channel detection/repair, re-referencing, SSVEP ROI
% selection, and the evoked/ongoing spectra - operates within this same
% 41-channel scope (not the full 128-channel cap). The cue-locked SSVEP
% series uses the 14 right + 14 left SSVEP electrode pairs from
% RT_files/RT_acquisition_8.m, pooled together for both frequencies. B1 and
% B2 are further manually excluded (leaving 39 channels) from the
% evoked/ongoing spectra specifically, for participants 58 and 59
% specifically - adjust manuallyExcludedSpectraChannels below if that stops
% being true for later participants.
% -------------------------------------------------------------------------

%% Inputs
participantNums = [58 59];
faDataRoot = '/Volumes/250GBKC/FAData';
% SSVEP tagging frequencies.
freqC1Hz = 19;
freqC2Hz = 23;

% Plotting scope: 'combined' pools every participant in participantNums
% together for one set of plots; 'individual' produces one full set of
% plots per participant; 'both' does both (default, since it costs nothing
% extra - the expensive GDF loading/preprocessing happens once regardless
% of how many plot variants are produced from it afterward).
plotMode = 'both';

% Trigger values sent by gameNFv3.m (see functions/cog_send_triggers.m and
% the trigger-value comment block at the end of gameNFv3.m). 'response' is
% only sent if a valid response was given - a timeout sends none.
trigTrialStart = 20;
trigCueOnset   = 45;
trigResponse   = 40;
trigTrialStop  = 30;

% Preprocessing (mirrors analysis/singleParticipantBehaviourOffline.m).
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

% SSVEP sliding-window spectral estimation (mirrors the reference
% pipeline's 1s window / 0.1s step / Chronux tapers=[1 1]).
spectrumWindowSec = 1;
stepSec           = 0.1;
freqsHz           = [freqC1Hz, freqC2Hz];
freqLabels        = {sprintf('%g Hz (c1 flock)', freqC1Hz), ...
                     sprintf('%g Hz (c2 flock)', freqC2Hz)};
freqColors        = [0 191 255; 255 140 0] / 255; % same RGB as gameNFv3.m's colorC1/colorC2

% Event-locked display windows.
cueWindowSec = [-2, 3];

% Save figures as PNGs and their underlying numbers as .mat files under
% analysis/results/. Set false to only display figures.
saveFigures = false;

% Evoked/ongoing power spectrum settings - one combined spectrum per plot
% scope (see plotMode), pooling every matched trial's cue, mini-epoched
% over the whole trial (pre-cue through feedback), matching
% analysis/singleParticipantBehaviourOffline.m's processSinglePSSpectra
% method as closely as possible.
spectraEpochLenSec = 3;
spectraFpass       = [2 40];
spectraNormMode     = 'rel-mean';
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
    error('ssvepCueOnsetLocked:ssvepRoiIndexOutOfRange', ...
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
% pooled mini-epochs for the evoked/ongoing spectra, and behavioural
% trial tables for the reaction-time bars.
allTrials = struct('participant', {}, 'block', {}, 'trialNumber', {}, 'cue', {}, 'series', {}, ...
    'windowCenterTimesSec', {}, 'cueOnsetRelSec', {}, 'responseRelSec', {}, 'durationSec', {});
commonTargetFs = [];
pooledMiniEpochs = [];
miniEpochParticipant = [];
allTrialTablesCell = cell(numel(participantNums), 1);

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
        error('ssvepCueOnsetLocked:targetFsMismatch', ...
            ['Participant %d resampled to %g Hz, but earlier participant(s) used %g Hz - all ' ...
             'participants must share one sampling rate before their trial series can be pooled ' ...
             'onto a common time/frequency axis. Native recording rates differ; adjust ' ...
             'desiredTargetFs or process this participant separately.'], participantNum, targetFs, commonTargetFs);
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
        error('ssvepCueOnsetLocked:ssvepRoiChannelsMissing', ...
            'Only %d of the %d requested SSVEP ROI channels were found in participant %d''s data.', ...
            nnz(roiMask), numel(ssvepRoiLabels), participantNum);
    end
    fprintf('  SSVEP ROI (%d channels): %s\n', numel(ssvepRoiLabels), strjoin(ssvepRoiLabels, ', '));
    roiSignal = mean(referencedData.trial{1}(roiMask, :), 1);

    spectraMask = ismember(referencedData.label, spectraChannelLabels);
    if nnz(spectraMask) ~= numel(spectraChannelLabels)
        error('ssvepCueOnsetLocked:spectraChannelsMissing', ...
            'Only %d of the %d requested spectra channels were found in participant %d''s data.', ...
            nnz(spectraMask), numel(spectraChannelLabels), participantNum);
    end
    spectraSignal = referencedData.trial{1}(spectraMask, :);
    clear referencedData;

    epochLenSamples = round(spectraEpochLenSec * targetFs);

    trialTable = loadParticipantTrialTable(participantDir, participantNum);
    allTrialTablesCell{participantIdx} = trialTable;
    pairSamples = extractTrialStartStopPairs(eventSamples, eventValues, trigTrialStart, trigTrialStop);
    fprintf('  %d GDF trial-start/stop pair(s) found for %d CSV trial row(s).\n', ...
        size(pairSamples, 1), height(trialTable));
    matched = matchGdfPairsToTrials(pairSamples, rawFs, trialTable, pairMatchToleranceSec);

    nMatched = 0;
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
            warning('ssvepCueOnsetLocked:noCueOnset', ...
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
        end

        trialSignal = roiSignal(startIdx:stopIdx);
        [seriesMat, windowCenterTimesSec] = computeTrialSsvepLogSnrSeries( ...
            trialSignal, targetFs, freqsHz, spectrumWindowSec, stepSec, chronuxParams);
        if isempty(seriesMat)
            warning('ssvepCueOnsetLocked:trialTooShort', ...
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
        miniEpochParticipant = [miniEpochParticipant, repmat(participantNum, 1, size(theseEpochs, 3))]; %#ok<AGROW>
    end
    fprintf('  %d trial(s) contributed an SSVEP series.\n', nMatched);
    clear roiSignal spectraSignal;
end

if isempty(allTrials)
    error('ssvepCueOnsetLocked:noTrials', 'No trials were successfully matched/processed for any participant.');
end
allTrialTables = vertcat(allTrialTablesCell{:});

%% Phase B: title/label builders shared by combined and individual scopes
cueCodes = {'c1', 'c2'};
cueDescriptions = { ...
    'c1 cue (attend flock 1, report its POINTING direction)', ...
    'c2 cue (attend flock 2, report its MOVING direction)'};
buildCueTitles = @(eventLabelCap, scopePrefix) cellfun( ...
    @(d) sprintf('SSVEP time series locked to %s - %s%s', eventLabelCap, scopePrefix, d), ...
    cueDescriptions, 'UniformOutput', false);
rtCueLabels = {'c1 cue', 'c2 cue'};

runCombined = ismember(plotMode, {'combined', 'both'});
runIndividual = ismember(plotMode, {'individual', 'both'});
if ~runCombined && ~runIndividual
    error('ssvepCueOnsetLocked:badPlotMode', 'plotMode must be ''combined'', ''individual'', or ''both''.');
end

%% Phase C: combined (all participants pooled) plots
if runCombined
    fprintf('\n=== Combined (P%s) ===\n', strjoin(string(participantNums), ', P'));

    plotSsvepLockedToEvent(allTrials, 'cueOnsetRelSec', stepSec, abs(cueWindowSec(1)), cueWindowSec(2), ...
        cueCodes, buildCueTitles('cue onset', ''), freqLabels, freqColors, 'cue onset', ...
        resultsDir, saveFigures, 'ssvepCueOnsetLocked_combined', 'responseRelSec');

    nMiniEpochsCombined = size(pooledMiniEpochs, 3);
    spectraSubtitleCombined = sprintf('n = %d mini-epochs (%gs each) from %d trials, %d participant(s), %d channels', ...
        nMiniEpochsCombined, spectraEpochLenSec, numel(allTrials), numel(participantNums), numel(spectraChannelLabels));
    plotEvokedOngoingSpectra(pooledMiniEpochs, spectraChronuxParamsOngoing, spectraChronuxParamsEvoked, ...
        spectraNormMode, freqsHz, freqLabels, freqColors, 'All participants - ', spectraSubtitleCombined, ...
        resultsDir, saveFigures, 'ssvepSpectra_combined');

    rtStatsCombined = computeRtStatsByBlockAndCue(allTrialTables, cueCodes);
    plotRtBarsByBlock(rtStatsCombined, rtCueLabels, freqColors, 'Reaction time by block - all participants', ...
        sprintf('P%s', strjoin(string(participantNums), ', P')), 'All RT');
    if saveFigures
        exportgraphics(gcf, fullfile(resultsDir, 'ssvepReactionTime_combined.png'), 'Resolution', 150);
        save(fullfile(resultsDir, 'ssvepReactionTime_combined.mat'), 'rtStatsCombined', 'rtCueLabels');
        close(gcf);
    end
end

%% Phase D: individual (per-participant) plots
if runIndividual
    for participantNum = participantNums
        fprintf('\n=== Individual: Participant %d ===\n', participantNum);
        participantTrials = allTrials([allTrials.participant] == participantNum);
        if isempty(participantTrials)
            warning('ssvepCueOnsetLocked:noIndividualTrials', ...
                'Participant %d has no matched trials; skipping its individual plots.', participantNum);
            continue;
        end

        scopePrefix = sprintf('P%d, ', participantNum);
        plotSsvepLockedToEvent(participantTrials, 'cueOnsetRelSec', stepSec, abs(cueWindowSec(1)), cueWindowSec(2), ...
            cueCodes, buildCueTitles('cue onset', scopePrefix), freqLabels, freqColors, 'cue onset', ...
            resultsDir, saveFigures, sprintf('ssvepCueOnsetLocked_P%d', participantNum), 'responseRelSec');

        participantMiniEpochs = pooledMiniEpochs(:, :, miniEpochParticipant == participantNum);
        nMiniEpochsThis = size(participantMiniEpochs, 3);
        spectraSubtitleThis = sprintf('n = %d mini-epochs (%gs each) from %d trials, %d channels', ...
            nMiniEpochsThis, spectraEpochLenSec, numel(participantTrials), numel(spectraChannelLabels));
        plotEvokedOngoingSpectra(participantMiniEpochs, spectraChronuxParamsOngoing, spectraChronuxParamsEvoked, ...
            spectraNormMode, freqsHz, freqLabels, freqColors, sprintf('P%d - ', participantNum), spectraSubtitleThis, ...
            resultsDir, saveFigures, sprintf('ssvepSpectra_P%d', participantNum));

        participantTrialTable = allTrialTables(allTrialTables.Participant == participantNum, :);
        rtStatsThis = computeRtStatsByBlockAndCue(participantTrialTable, cueCodes);
        plotRtBarsByBlock(rtStatsThis, rtCueLabels, freqColors, ...
            sprintf('Reaction time by block - Participant %d', participantNum), sprintf('P%d', participantNum), ...
            sprintf('P%d RT', participantNum));
        if saveFigures
            baseName = sprintf('ssvepReactionTime_P%d', participantNum);
            exportgraphics(gcf, fullfile(resultsDir, [baseName, '.png']), 'Resolution', 150);
            save(fullfile(resultsDir, [baseName, '.mat']), 'rtStatsThis', 'rtCueLabels');
            close(gcf);
        end
    end
end
