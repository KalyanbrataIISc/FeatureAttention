function plotSsvepLockedToEvent(trials, eventFieldName, stepSec, maxPreEventSec, maxPostEventSec, ...
    cueCodes, cueTitles, freqLabels, freqColors, eventLabel, resultsDir, saveFigures, fileTagPrefix, markerEventFieldName)
% plotSsvepLockedToEvent  Computes a shared event-locked timeline from
% trials.(eventFieldName), splits trials by cue, aligns each trial's
% raw series to that event (alignSeriesToEvent.m), averages, zeroes the
% final mean trace to its value at the event time, and plots/saves one
% figure per cue. The trial stack and SEM remain based on the unzeroed raw
% aligned values.
%
% Trials whose trials.(eventFieldName) is NaN (e.g. a timeout trial has no
% response to lock to) are silently excluded from this event's plots -
% they may still appear in a different event's plots (e.g. cue onset).
%
%   trials: struct array (see analysis/ssvepCueOnsetLocked.m's allTrials)
%       with fields participant, block, trialNumber, cue, series,
%       windowCenterTimesSec, durationSec, and the field named by
%       eventFieldName (e.g. 'cueOnsetRelSec' or 'responseRelSec').
%   eventFieldName: name of the field in trials holding each trial's event
%       time relative to trial start (seconds).
%   stepSec: sliding-window step (seconds) - the shared timeline's grid spacing.
%   maxPreEventSec, maxPostEventSec: displayed timeline width on each side
%       of the event.
%   cueCodes: cellstr, e.g. {'c1', 'c2'}.
%   cueTitles: cellstr, one full figure title per cue code.
%   freqLabels: cellstr, one per frequency row in each trial's series.
%   freqColors: numel(freqLabels) x 3 RGB triples in [0, 1].
%   eventLabel: human-readable event name for the x-axis (e.g. 'cue onset'
%       or 'response').
%   resultsDir: folder to save PNG/mat outputs into.
%   saveFigures: true to save; false to only display.
%   fileTagPrefix: filename prefix for saved PNG/mat files (cue code is
%       appended).
%   markerEventFieldName: optional field whose event time is marked as
%       one dot per trial, relative to eventFieldName.

    if nargin < 14
        markerEventFieldName = '';
    end

    validMask = arrayfun(@(t) isfinite(t.(eventFieldName)), trials);
    trials = trials(validMask);
    if isempty(trials)
        warning('plotSsvepLockedToEvent:noValidTrials', ...
            'No trials had a finite %s; skipping %s-locked plots.', eventFieldName, eventLabel);
        return;
    end

    preSamples = max(1, round(maxPreEventSec / stepSec));
    postSamples = max(1, round(maxPostEventSec / stepSec));

    timelinePoints = preSamples + postSamples + 1;
    timeAxisSec = (-preSamples:postSamples) * stepSec;
    xLabelStr = sprintf('Time relative to %s (s)', eventLabel);
    fprintf('\n%s-locked timeline: %d points, %.1fs to %.1fs (0 = %s).\n', ...
        eventLabel, timelinePoints, timeAxisSec(1), timeAxisSec(end), eventLabel);

    nFreqs = numel(freqLabels);
    for cueIdx = 1:numel(cueCodes)
        cueMask = strcmp({trials.cue}, cueCodes{cueIdx});
        cueTrials = trials(cueMask);
        nCueTrials = numel(cueTrials);
        if nCueTrials == 0
            warning('plotSsvepLockedToEvent:noCueTrials', ...
                'No %s trials with a valid %s; skipping.', cueCodes{cueIdx}, eventLabel);
            continue;
        end

        stacked = nan(nCueTrials, timelinePoints, nFreqs);
        for trialIdx = 1:nCueTrials
            aligned = alignSeriesToEvent(cueTrials(trialIdx).series, cueTrials(trialIdx).windowCenterTimesSec, ...
                cueTrials(trialIdx).(eventFieldName), stepSec, preSamples, postSamples);
            stacked(trialIdx, :, :) = aligned.';
        end

        % Diagnostics: how many trials actually reach each timepoint, and
        % an audit trail back to the single most extreme individual
        % trial/timepoint value - see
        % analysis/ssvepCueOnsetLocked.m's original cue-onset-locked
        % diagnostic for why (single-taper, single-window log-SNR
        % estimates are intrinsically noisy trial-to-trial).
        nContrib = sum(isfinite(stacked(:, :, 1)), 1);
        fprintf('  %s cue: trials contributing per timepoint ranges %d-%d (of %d total).\n', ...
            cueCodes{cueIdx}, min(nContrib), max(nContrib), nCueTrials);
        [worstVal, worstLinearIdx] = max(abs(stacked(:)));
        if isfinite(worstVal)
            [worstTrialIdx, worstTimeIdx, worstFreqIdx] = ind2sub(size(stacked), worstLinearIdx);
            fprintf(['  %s cue: most extreme single-trial value is %.2f at t=%.2fs, %s, P%d Block %d Trial %d ' ...
                '(%d trial(s) contributing at that timepoint).\n'], ...
                cueCodes{cueIdx}, stacked(worstTrialIdx, worstTimeIdx, worstFreqIdx), timeAxisSec(worstTimeIdx), ...
                freqLabels{worstFreqIdx}, cueTrials(worstTrialIdx).participant, cueTrials(worstTrialIdx).block, ...
                cueTrials(worstTrialIdx).trialNumber, nContrib(worstTimeIdx));
        end

        meanMat = nan(nFreqs, timelinePoints);
        semMat = nan(nFreqs, timelinePoints);
        for f = 1:nFreqs
            meanMat(f, :) = mean(stacked(:, :, f), 1, 'omitnan');
            semMat(f, :) = computeSemOmitNan(stacked(:, :, f));
        end
        zeroIdx = find(timeAxisSec == 0, 1);
        meanMat = bsxfun(@minus, meanMat, meanMat(:, zeroIdx));

        participantCounts = unique([cueTrials.participant]);
        subtitleStr = sprintf('n = %d trials across %d participant(s) (P%s)', ...
            nCueTrials, numel(participantCounts), strjoin(string(participantCounts), ', P'));
        if isempty(markerEventFieldName)
            markerTimesSec = [];
        else
            markerTimesSec = [cueTrials.(markerEventFieldName)] - [cueTrials.(eventFieldName)];
            markerTimesSec = markerTimesSec(isfinite(markerTimesSec));
        end
        if strcmp(eventLabel, 'cue onset')
            eventNameShort = 'Cue';
        else
            eventNameShort = 'Response';
        end
        if numel(participantCounts) == 1
            figureName = sprintf('P%d %s %s', participantCounts, eventNameShort, cueCodes{cueIdx});
        else
            figureName = sprintf('%s %s', eventNameShort, cueCodes{cueIdx});
        end
        plotSsvepMeanSem(timeAxisSec, meanMat, semMat, freqLabels, freqColors, ...
            cueTitles{cueIdx}, subtitleStr, xLabelStr, figureName, markerTimesSec);

        if saveFigures
            baseName = sprintf('%s_%s', fileTagPrefix, cueCodes{cueIdx});
            exportgraphics(gcf, fullfile(resultsDir, [baseName, '.png']), 'Resolution', 150);
            save(fullfile(resultsDir, [baseName, '.mat']), ...
                'timeAxisSec', 'meanMat', 'semMat', 'freqLabels', 'nCueTrials', 'participantCounts', ...
                'stacked', 'nContrib', 'markerTimesSec');
            close(gcf);
        end
    end
end
