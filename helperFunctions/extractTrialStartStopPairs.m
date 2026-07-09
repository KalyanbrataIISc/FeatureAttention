function pairSamples = extractTrialStartStopPairs(eventSamples, eventValues, startCode, stopCode)
% extractTrialStartStopPairs  Scans a chronological STATUS trigger stream
% (as produced by loadConcatenatedGdfRaw.m) for startCode/stopCode pairs
% (gameNFv3.m sends 'trialstart' then 'trialstop' once per trial, including
% aborted trials - see cog_send_triggers.m and gameNFv3.m's trailing
% trigger-value comment block). Pairing is purely sequential: the first
% startCode found opens a pair, the next stopCode after it closes that
% pair, and scanning resumes after that stopCode. This deliberately does
% not assume one pair per behavioural CSV row - an escaped/aborted trial
% still sends both triggers but never gets a CSV row, so the pair count can
% exceed the CSV row count; matchGdfPairsToTrials.m handles that
% reconciliation using each pair's duration.
%
%   eventSamples, eventValues: parallel vectors, in chronological order.
%   startCode, stopCode: numeric trigger values.
%
% Returns pairSamples: Nx2 matrix of [startSample, stopSample], in the same
% sample-index space as eventSamples.

    [eventSamples, sortOrder] = sort(eventSamples(:));
    eventValues = eventValues(sortOrder);

    pairSamples = zeros(0, 2);
    cursor = 1;
    nEvents = numel(eventValues);
    while cursor <= nEvents
        startIdx = find(eventValues(cursor:end) == startCode, 1, 'first');
        if isempty(startIdx)
            break;
        end
        startIdx = cursor + startIdx - 1;

        stopIdx = find(eventValues(startIdx + 1:end) == stopCode, 1, 'first');
        if isempty(stopIdx)
            warning('extractTrialStartStopPairs:unterminatedStart', ...
                'A trial-start trigger at sample %d has no matching trial-stop trigger afterward; ignoring it.', ...
                eventSamples(startIdx));
            break;
        end
        stopIdx = startIdx + stopIdx;

        pairSamples(end + 1, :) = [eventSamples(startIdx), eventSamples(stopIdx)]; %#ok<AGROW>
        cursor = stopIdx + 1;
    end
end
