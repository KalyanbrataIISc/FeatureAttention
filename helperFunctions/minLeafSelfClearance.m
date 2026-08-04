function clearancePx = minLeafSelfClearance(px, py, fieldWidthPx, fieldHeightPx, xExtentPx, yExtentPx)
% minLeafSelfClearance  Smallest axis-aligned bounding-box clearance between
% any two of one flock's leaves, on the wrapped (toroidal) field. Used by
% verifyLeafLanes.m.
%
% Returns max(|dx| - xExtentPx, |dy| - yExtentPx) minimised over all pairs:
% >= 0 means no two leaves in the flock overlap. Both leaves belong to the
% same flock here, so each summed half-extent is just that flock's own full
% extent. Inf when the flock has fewer than two leaves.

    n = numel(px);
    if n < 2
        clearancePx = Inf;
        return;
    end

    dx = abs(bsxfun(@minus, px, px.'));
    dy = abs(bsxfun(@minus, py, py.'));
    dx = min(dx, fieldWidthPx - dx);
    dy = min(dy, fieldHeightPx - dy);

    clearance = max(dx - xExtentPx, dy - yExtentPx);
    clearance(1:n + 1:end) = Inf;   % ignore each leaf against itself
    clearancePx = min(clearance(:));
end
