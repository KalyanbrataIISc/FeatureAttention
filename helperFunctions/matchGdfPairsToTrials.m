function matchedTable = matchGdfPairsToTrials(pairSamples, rawFs, trialTable, toleranceSec)
% matchGdfPairsToTrials  Aligns GDF trial-start/trial-stop trigger pairs
% (extractTrialStartStopPairs.m) to rows of a participant's concatenated
% behavioural trial table (loadParticipantTrialTable.m), sequentially,
% using each candidate pair's recorded duration as a check against the
% CSV's own TrialDurationSec. A pure positional match (Nth pair = Nth CSV
% row) is not safe on its own: gameNFv3.m sends trialstart/trialstop for an
% escaped/aborted trial too, but writes no CSV row for it (see README.md's
% trial-timeline section), which would silently shift every later trial out
% of alignment. Instead this greedily advances through both lists, only
% consuming a CSV row when the next GDF pair's duration matches it within
% toleranceSec; a GDF pair that doesn't match the current CSV row's
% duration is assumed to be exactly one such unlogged aborted trial and is
% skipped on its own.
%
% Returns trialTable with three columns added:
%   GdfStartSample, GdfStopSample - native-sample-rate indices from
%       pairSamples for the matched pair (NaN if this CSV row could not be
%       matched).
%   GdfDurationSec - the matched pair's own duration, for audit alongside
%       TrialDurationSec.
% Emits a warning naming any CSV row(s) left unmatched, and any leftover
% unmatched GDF pairs, rather than failing silently.

    nTrials = height(trialTable);
    gdfStartSample = nan(nTrials, 1);
    gdfStopSample = nan(nTrials, 1);
    gdfDurationSec = nan(nTrials, 1);

    pairDurationSec = (pairSamples(:, 2) - pairSamples(:, 1)) / rawFs;
    nPairs = size(pairSamples, 1);

    trialIdx = 1;
    pairIdx = 1;
    skippedPairIdx = [];
    while trialIdx <= nTrials && pairIdx <= nPairs
        csvDurationSec = trialTable.TrialDurationSec(trialIdx);
        if abs(pairDurationSec(pairIdx) - csvDurationSec) <= toleranceSec
            gdfStartSample(trialIdx) = pairSamples(pairIdx, 1);
            gdfStopSample(trialIdx) = pairSamples(pairIdx, 2);
            gdfDurationSec(trialIdx) = pairDurationSec(pairIdx);
            trialIdx = trialIdx + 1;
            pairIdx = pairIdx + 1;
        else
            skippedPairIdx(end + 1) = pairIdx; %#ok<AGROW>
            pairIdx = pairIdx + 1;
        end
    end

    if ~isempty(skippedPairIdx)
        warning('matchGdfPairsToTrials:skippedGdfPairs', ...
            ['%d GDF trial-start/stop pair(s) did not match the next expected CSV trial ' ...
             'duration (within %.3gs) and were treated as unlogged/aborted trials: pair index(es) %s.'], ...
            numel(skippedPairIdx), toleranceSec, mat2str(skippedPairIdx));
    end
    unmatchedTrials = find(isnan(gdfStartSample));
    if ~isempty(unmatchedTrials)
        warning('matchGdfPairsToTrials:unmatchedCsvTrials', ...
            ['%d CSV trial row(s) could not be matched to a GDF trigger pair (ran out of GDF ' ...
             'pairs, or durations never lined up): Block/TrialNumber %s. These trials are excluded ' ...
             'from the EEG analysis.'], numel(unmatchedTrials), ...
            mat2str([trialTable.Block(unmatchedTrials), trialTable.TrialNumber(unmatchedTrials)]));
    end

    matchedTable = trialTable;
    matchedTable.GdfStartSample = gdfStartSample;
    matchedTable.GdfStopSample = gdfStopSample;
    matchedTable.GdfDurationSec = gdfDurationSec;
end
