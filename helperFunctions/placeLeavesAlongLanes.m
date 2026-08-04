function [alongPos, crossPos, ok, message] = placeLeavesAlongLanes(numLeaves, laneCentres, alongSize, minAlongSpacingPx)
% placeLeavesAlongLanes  Distributes numLeaves over the given lanes for the
% interleaved-lane case in initLeafLanes.m, where a flock's along-lane phase
% is completely free (the two flocks are kept apart by using disjoint lane
% sets, not by timing).
%
% Leaves are spread as evenly as the counts allow - lanes differ by at most
% one leaf - and within a lane they are placed at equal spacing with a
% random phase offset per lane. The offset only rotates a lane's leaves
% along their shared path, which cannot affect any separation (every leaf in
% a flock moves identically, so within-flock geometry is frozen, and
% different lanes never meet), but it stops the field from looking like a
% rigid rectangular grid.
%
% alongPos/crossPos are returned relative to the field origin; the caller
% maps them onto x/y according to which axis the flock travels along.

    alongPos = zeros(numLeaves, 1);
    crossPos = zeros(numLeaves, 1);
    ok = true;
    message = '';

    nLanes = numel(laneCentres);
    if nLanes < 1
        ok = false;
        message = 'No lanes available for this flock.';
        return;
    end

    % Lane l takes leaves l, l+nLanes, l+2*nLanes, ... so counts differ by
    % at most one and every lane is used before any lane is doubled up.
    laneOf = mod((0:numLeaves - 1)', nLanes) + 1;
    countPerLane = accumarray(laneOf, 1, [nLanes, 1]);
    maxPerLane = max(countPerLane);

    capacityPerLane = floor(alongSize / minAlongSpacingPx);
    if maxPerLane > capacityPerLane
        ok = false;
        message = sprintf(['Need %d leaves in one lane but only %d fit along %.0fpx at %.0fpx ' ...
            'spacing. Use fewer leaves per flock, smaller leaves, or a longer field.'], ...
            maxPerLane, capacityPerLane, alongSize, minAlongSpacingPx);
        return;
    end

    laneOffset = rand(nLanes, 1) * alongSize;
    placedInLane = zeros(nLanes, 1);
    for i = 1:numLeaves
        l = laneOf(i);
        placedInLane(l) = placedInLane(l) + 1;
        step = alongSize / countPerLane(l);
        alongPos(i) = mod(laneOffset(l) + (placedInLane(l) - 1) * step, alongSize);
        crossPos(i) = laneCentres(l);
    end
end
