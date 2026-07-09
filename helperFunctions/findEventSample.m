function eventSample = findEventSample(eventSamples, eventValues, eventCode, trialStartSample, trialStopSample, warnIfMissing)
% findEventSample  Finds the single trigger sample matching eventCode
% strictly between a trial's matched start and stop samples (see
% matchGdfPairsToTrials.m), in the same native-sample-rate space as
% eventSamples. gameNFv3.m sends 'cueonset' unconditionally on every trial,
% but 'response' only if a valid response was given (a timeout sends none)
% - see the trigger-value comment block at the end of gameNFv3.m - so
% whether zero matches is worth a warning depends on which trigger this is
% being used for.
%
%   warnIfMissing: true to warn when zero matches are found (e.g.
%       cue-onset, which should always be present); false to silently
%       return NaN in that case (e.g. response, which is legitimately
%       absent on a timeout trial). Finding more than one match always
%       warns regardless, since that's unexpected for either trigger.
%
% Returns NaN if zero or more than one candidate is found.

    candidateMask = eventValues == eventCode & eventSamples > trialStartSample & eventSamples < trialStopSample;
    candidates = eventSamples(candidateMask);
    if isscalar(candidates)
        eventSample = candidates;
        return;
    end

    if numel(candidates) > 1 || warnIfMissing
        warning('findEventSample:unexpectedCount', ...
            'Expected exactly one trigger (code %d) between samples %d and %d, found %d.', ...
            eventCode, trialStartSample, trialStopSample, numel(candidates));
    end
    eventSample = NaN;
end
