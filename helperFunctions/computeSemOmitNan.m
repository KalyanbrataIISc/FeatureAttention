function semRow = computeSemOmitNan(trialByTimeMatrix)
% computeSemOmitNan  Standard error of the mean down each column of
% trialByTimeMatrix (rows = trials, columns = time points), ignoring NaNs
% independently per column (so trial-end-locked, NaN-front-padded series
% from alignSeriesToTrialEnd.m contribute at every time point they actually
% have data for). Matches
% analysis/singleParticipantBehaviourOffline.m's computeSemFromTrials:
% NaN wherever fewer than 2 trials have real data at that time point.
%
% Returns semRow: 1 x nTimePoints.

    n = sum(isfinite(trialByTimeMatrix), 1);
    semRow = std(trialByTimeMatrix, 0, 1, 'omitnan') ./ sqrt(max(n, 1));
    semRow(n < 2) = NaN;
end
