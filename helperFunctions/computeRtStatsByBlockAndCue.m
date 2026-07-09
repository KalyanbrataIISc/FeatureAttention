function stats = computeRtStatsByBlockAndCue(trialTable, cueCodes)
% computeRtStatsByBlockAndCue  Mean +/- SEM reaction time, grouped by Block
% and Cue, from a behavioural trial table (see loadParticipantTrialTable.m).
% Timeout trials (ResponseTimeout==1, no real reaction time) and any
% non-finite ReactionTime are excluded first - matches
% analysis/singleParticipantBehaviourOffline.m's excludeTimeoutRT
% convention. This is purely behavioural (CSV-only): it does not depend on
% GDF trigger matching at all, so a trial can contribute here even if it
% wasn't successfully matched to an EEG epoch.
%
%   trialTable: table with at least Block, Cue, ReactionTime,
%       ResponseTimeout columns (can span multiple participants at once -
%       Block values are just grouped as-is, so pool participants
%       beforehand if you want per-participant-block granularity kept
%       separate, e.g. by offsetting Block numbers, or call this once per
%       participant instead).
%   cueCodes: cellstr of cue codes to break out as separate columns, e.g.
%       {'c1', 'c2'}.
%
% Returns stats with fields:
%   blocks: sorted unique block numbers (numBlocks x 1).
%   meanRt, semRt: numBlocks x numel(cueCodes).
%   n: numBlocks x numel(cueCodes), trial count behind each mean/SEM.

    validMask = trialTable.ResponseTimeout == 0 & isfinite(trialTable.ReactionTime);
    validTrials = trialTable(validMask, :);

    blocks = sort(unique(validTrials.Block));
    numBlocks = numel(blocks);
    numCues = numel(cueCodes);

    meanRt = nan(numBlocks, numCues);
    semRt = nan(numBlocks, numCues);
    n = zeros(numBlocks, numCues);

    for b = 1:numBlocks
        for c = 1:numCues
            groupMask = validTrials.Block == blocks(b) & strcmp(validTrials.Cue, cueCodes{c});
            groupRt = validTrials.ReactionTime(groupMask);
            n(b, c) = numel(groupRt);
            if isempty(groupRt)
                continue;
            end
            meanRt(b, c) = mean(groupRt);
            if numel(groupRt) >= 2
                semRt(b, c) = std(groupRt) / sqrt(numel(groupRt));
            end
        end
    end

    stats = struct('blocks', blocks, 'meanRt', meanRt, 'semRt', semRt, 'n', n);
end
