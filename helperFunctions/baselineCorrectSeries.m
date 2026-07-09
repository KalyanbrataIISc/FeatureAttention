function correctedSeries = baselineCorrectSeries(seriesMat, windowCenterTimesSec, cueOnsetRelSec)
% baselineCorrectSeries  Subtracts, from every row (frequency) of seriesMat,
% that row's own mean over every window centered before cue onset - i.e.
% the trial's whole pre-cue period, from trial start up to that trial's own
% cueOnsetRelSec (variable trial-to-trial, since gameNFv3.m's pre-cue
% foreperiod is preCueConstantSec plus a jittered exponential extra - see
% gameNFv3.m's cueDelaySec). That whole period is guaranteed cue-free (both
% flocks in colorPreCue, cue box blank), so it's a valid baseline regardless
% of length - unlike a fixed-duration window, this uses every pre-cue
% sample actually available for that trial. Independent of how the result
% is later time-locked/aligned (e.g. to cue onset or response by
% alignSeriesToEvent.m).
%
%   seriesMat: numFreqs x nWindows (e.g. from computeTrialSsvepLogSnrSeries.m).
%   windowCenterTimesSec: 1 x nWindows, each window's center time relative
%       to trial start.
%   cueOnsetRelSec: this trial's cue onset time relative to trial start
%       (e.g. from findEventSample.m, converted to the same time base).
%
% Returns correctedSeries, same size as seriesMat.

    baselineMask = windowCenterTimesSec < cueOnsetRelSec;
    if ~any(baselineMask)
        warning('baselineCorrectSeries:noBaselineSamples', ...
            'No spectral windows fell before this trial''s cue onset (%.3gs); returning uncorrected series.', ...
            cueOnsetRelSec);
        correctedSeries = seriesMat;
        return;
    end

    baselineVal = mean(seriesMat(:, baselineMask), 2, 'omitnan');
    correctedSeries = seriesMat - baselineVal;
end
