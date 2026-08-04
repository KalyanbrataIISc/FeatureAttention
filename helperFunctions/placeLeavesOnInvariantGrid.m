function [alongPos, crossPos, ok, message] = placeLeavesOnInvariantGrid(numLeaves, laneCentres, ...
    alongSize, invariantModulus, arcHalfWidth, arcCentre, ownSign, otherSign, minAlongSpacingPx)
% placeLeavesOnInvariantGrid  Places one flock for the perpendicular case in
% initLeafLanes.m, where the along-lane phase is NOT free: it is what
% controls whether this flock ever meets the other one.
%
% See initLeafLanes.m for the derivation. Each leaf carries the invariant
%
%     inv = mod(ownSign*alongPhase + otherSign*laneCentre, invariantModulus)
%
% and two leaves from opposite flocks can only ever collide when their
% invariants coincide, the closest approach being the circular distance
% between them. So this function pins every leaf's invariant inside the arc
% [arcCentre - arcHalfWidth, arcCentre + arcHalfWidth]; the caller gives the
% two flocks arcs far enough apart on the circle that no pair can meet.
%
% Inverting the identity for the phase gives
%
%     alongPhase = ownSign * (inv - otherSign*laneCentre)   (mod modulus)
%
% which fixes the phase only modulo `invariantModulus`, so the usable
% positions along a lane of length alongSize are that phase repeated in each
% of the alongSize/invariantModulus "windows", offset within a window by
% whatever slack the arc allows. Leaves are laid out (lane, window, slot)
% with lanes cycling fastest, so every lane is populated before any lane is
% given a second leaf.

    alongPos = zeros(numLeaves, 1);
    crossPos = zeros(numLeaves, 1);
    ok = true;
    message = '';

    nLanes = numel(laneCentres);
    nWindows = max(1, round(alongSize / invariantModulus));
    slotsPerWindow = countInvariantSlotsPerWindow(arcHalfWidth, minAlongSpacingPx);

    capacity = nLanes * nWindows * slotsPerWindow;
    if capacity < numLeaves
        ok = false;
        message = sprintf(['Only %d non-colliding slots exist for this flock (%d lanes x %d ' ...
            'windows x %d slots) but %d leaves were requested. Use fewer leaves per flock, ' ...
            'smaller leaves, or a field whose width and height share a larger common factor.'], ...
            capacity, nLanes, nWindows, slotsPerWindow, numLeaves);
        return;
    end

    if slotsPerWindow > 1
        slotStep = minAlongSpacingPx;   % pack slots tightly, leaving the rest as jitter slack
    else
        slotStep = 0;
    end

    % Whatever arc is left over after the slots are packed is spent as a
    % single random rotation PER LANE. Rotating a whole lane together cannot
    % change any within-lane spacing, and every leaf stays inside the arc,
    % so the collision guarantee is untouched - but it breaks up the rigid
    % diagonal alignment that comes from the phase depending on the lane.
    laneSlack = max(0, 2 * arcHalfWidth - (slotsPerWindow - 1) * slotStep);
    laneJitter = rand(nLanes, 1) * laneSlack;

    % Distribution matters as much as capacity. Filling window 1 across every
    % lane, then window 2, and so on leaves the last windows empty whenever
    % capacity exceeds numLeaves - and since the along-lane extent (and hence
    % capacity) depends on whether a flock points along or across its motion,
    % that produced a field with a large empty band on exactly the direction
    % combinations where leaves are long in their lane, and a perfectly even
    % field where they are short. So instead: give each lane a round-robin
    % share, then spread that lane's leaves evenly over the whole slot range
    % rather than packing them into the first few windows.
    laneOf = mod((0:numLeaves - 1)', nLanes) + 1;
    countPerLane = accumarray(laneOf, 1, [nLanes, 1]);
    totalSlots = nWindows * slotsPerWindow;

    placed = 0;
    for lane = 1:nLanes
        countThisLane = countPerLane(lane);
        for j = 1:countThisLane
            % Evenly spaced across this lane's slot range, then rotated by
            % the lane index so different lanes favour different windows and
            % the usage evens out across the whole field rather than per
            % lane. Distinct j give distinct slotIndex, so no two leaves in a
            % lane can land on the same slot.
            slotIndex = mod(floor((j - 1) * totalSlots / countThisLane) + (lane - 1), totalSlots);
            win = mod(slotIndex, nWindows) + 1;
            slot = floor(slotIndex / nWindows) + 1;

            placed = placed + 1;
            invariant = arcCentre - arcHalfWidth + laneJitter(lane) + (slot - 1) * slotStep;
            phase = mod(ownSign * (invariant - otherSign * laneCentres(lane)), invariantModulus);
            alongPos(placed) = mod(phase + (win - 1) * invariantModulus, alongSize);
            crossPos(placed) = laneCentres(lane);
        end
    end
end
