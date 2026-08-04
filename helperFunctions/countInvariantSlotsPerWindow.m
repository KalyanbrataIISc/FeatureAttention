function slotsPerWindow = countInvariantSlotsPerWindow(arcHalfWidthPx, minAlongSpacingPx)
% countInvariantSlotsPerWindow  How many leaves fit inside one repeat of the
% invariant arc used by initLeafLanes.m's phase-locked grid.
%
% Along a lane the usable positions repeat every `invariantModulus` pixels,
% and within each repeat they are confined to an arc of width
% 2*arcHalfWidthPx. This is how many leaves fit in that arc at
% minAlongSpacingPx apart - always at least one, since a leaf can sit at the
% arc's start even when the arc is narrower than the spacing.
%
% Shared by placeLeavesOnInvariantGrid.m, which lays the leaves out, and by
% initLeafLanes.m, which needs the same number beforehand to decide how many
% lanes to use. Keeping it in one place stops the two from disagreeing - and
% they must agree, because the lane count is chosen so that lanes x slots
% comes out close to the number of leaves.

    slotsPerWindow = max(1, floor(2 * arcHalfWidthPx / minAlongSpacingPx) + 1);
end
