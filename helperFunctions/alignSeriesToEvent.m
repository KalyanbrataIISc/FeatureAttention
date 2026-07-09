function aligned = alignSeriesToEvent(seriesMat, windowCenterTimesSec, eventRelSec, stepSec, preSamples, postSamples)
% alignSeriesToEvent  Places one trial's time series onto a fixed-length
% array locked to an arbitrary within-trial reference event (e.g. cue
% onset or response - the caller decides which by what it passes as
% eventRelSec): column (preSamples + 1) is the event (t=0), earlier
% columns are before it, later columns are after it. Each window is placed
% at the array column nearest its own time relative to the event
% (windowCenterTimesSec - eventRelSec); windows landing outside
% [-preSamples, postSamples] - i.e. a trial whose before/after span is
% longer than the shared array on that side - are dropped. Columns no
% trial reaches stay NaN, so averaging trials of different lengths
% (jittered pre-cue foreperiod, variable response time) via
% mean(...,'omitnan') only includes trials that actually have data at each
% time point - the same fixed-array/NaN-pad convention
% analysis/singleParticipantBehaviourOffline.m uses for its own
% time-locked averaging, just anchored at a within-trial event instead of
% at one end.
%
%   seriesMat: numFreqs x nWindows.
%   windowCenterTimesSec: 1 x nWindows, relative to trial start.
%   eventRelSec: this trial's reference event time relative to trial start
%       (e.g. cueOnsetRelSec or responseRelSec).
%   stepSec: the sliding-window step (seconds) - the shared array's grid spacing.
%   preSamples, postSamples: shared array width on each side of the event.
%
% Returns aligned: numFreqs x (preSamples + postSamples + 1).

    numFreqs = size(seriesMat, 1);
    timelinePoints = preSamples + postSamples + 1;
    aligned = nan(numFreqs, timelinePoints);

    relTimesSec = windowCenterTimesSec - eventRelSec;
    destIdx = round(relTimesSec / stepSec) + preSamples + 1;
    validMask = destIdx >= 1 & destIdx <= timelinePoints;
    aligned(:, destIdx(validMask)) = seriesMat(:, validMask);
end
