function [leaves, info] = initLeafLanes(numLeavesPerFlock, fieldRect, outerLengthPx, outerWidthPx, ...
    c1PointDir, c1MoveDir, c2PointDir, c2MoveDir, speedPxPerFrame, clearanceMarginPx, placementMode)
% initLeafLanes  Places both flocks on fixed, wrapping paths that never
% overlap, so no leaf ever has to disappear or respawn mid-trial. Drop-in
% alternative to initLeaves.m: the returned struct has the same
% x/y/vx/vy/flockID fields (no `life` - nothing expires here) and is
% advanced by updateLeafLanes.m instead of updateLeaves.m.
%
% Every leaf in a flock shares one velocity, so within a flock the relative
% geometry is frozen for the whole trial - leaves that start far enough
% apart stay exactly that far apart forever. (That is already true in
% initLeaves.m, which is why every respawn there is caused by the OTHER
% flock, or by the lifetime timer.) All the work is therefore in keeping the
% two flocks apart, and that splits into two cases.
%
% CASE 1 - the flocks move along the same axis, in opposite directions (e.g.
% up vs down). Lay parallel lanes across that axis and give the flocks
% interleaved, disjoint lane sets. A leaf's cross-lane coordinate never
% changes, so leaves in different lanes can never meet. Exact, and needs no
% timing argument at all.
%
% CASE 2 - the flocks move along perpendicular axes (e.g. right vs up).
% Their lanes now form a grid and crossings are unavoidable in space, so
% they must be avoided in time. Write flock A (traveling on x) as
% X(t) = mod(alpha + sigmaA*s, Wf) on lane Y = a, and flock B (on y) as
% Y(t) = mod(beta + sigmaB*s, Hf) on lane X = b, with s the distance
% travelled. A is at the crossing when s = sigmaA*(b - alpha) (mod Wf), B
% when s = sigmaB*(a - beta) (mod Hf). Both can hold at once only if those
% agree modulo g = gcd(Wf, Hf), which rearranges to
%
%     sigmaA*alpha + sigmaB*a  ==  sigmaA*b + sigmaB*beta   (mod g)
%
% Give each leaf the scalar invariant on its own side of that identity, and
% the distance between an A/B pair is governed by the circular distance D
% between their invariants on a circle of circumference g. Keeping flock A's
% invariants far enough from flock B's on that circle therefore guarantees
% they never overlap, for the whole trial, with no per-frame collision
% checks. placeLeavesOnInvariantGrid.m does the placement, and the required
% D is worked out at `cReq` below - note it is NOT simply the summed y
% extents, because both flocks move at the same speed and so trade x-offset
% for y-offset as they approach a crossing.
%
% The catch is that g must exceed twice that clearance, and g is the gcd of
% the field's own width and height. A full 1920x1080 field gives g = 120,
% less than one leaf, and cannot work at all; insetting to 1920x960 gives
% g = 960 and works comfortably. info.feasible reports this rather than
% silently producing a field that collides - always check it, and prefer
% confirming the result with verifyLeafLanes.m, which simulates a full
% period and measures the real minimum separation rather than trusting the
% algebra above.
%
% clearanceMarginPx is added on top of every extent-derived spacing, as
% slack against rounding and to stop leaves looking like they graze.
%
% placementMode picks what to do about CASE 2, and the choice is a real one:
%
%   'strict' (default) - the invariant construction above. Zero overlaps,
%       guaranteed. The cost is coverage: every leaf's invariant has to sit
%       inside an arc of width g/2 - cReq out of g, so the flock can only
%       occupy a fraction 0.5 - cReq/g of the field and the rest is
%       necessarily empty. At the default leaf size that is 11-28% depending
%       on g, which reads on screen as diagonal bands of leaves separated by
%       empty bands. Bigger g widens the bands but gives fewer of them.
%
%   'even' - drop the invariant constraint and simply spread each flock
%       evenly along its lanes, exactly as CASE 1 does. Coverage is uniform
%       and the field can be the full screen (no gcd requirement at all),
%       but the two flocks now cross freely, so a leaf of one flock will
%       occasionally pass over a leaf of the other. Within-flock separation
%       is still exact, and nothing is ever respawned.
%
% Neither mode respawns anything and both keep the on-screen count constant;
% they differ only in whether cross-flock overlap is impossible or merely
% occasional. Use verifyLeafLanes.m to measure the overlap rate of an 'even'
% layout rather than guessing at it.
%
% info fields: feasible, message, mode, nLanes1, nLanes2, invariantModulus,
% invariantClearancePx (the last two are NaN in case 1).

    if nargin < 11 || isempty(placementMode)
        placementMode = 'strict';
    end

    Wf = fieldRect(3) - fieldRect(1);
    Hf = fieldRect(4) - fieldRect(2);
    x0 = fieldRect(1);
    y0 = fieldRect(2);

    [xE1, yE1] = leafExtentsForDirection(c1PointDir, outerLengthPx, outerWidthPx);
    [xE2, yE2] = leafExtentsForDirection(c2PointDir, outerLengthPx, outerWidthPx);

    moveVec1 = directionToVector(c1MoveDir);
    moveVec2 = directionToVector(c2MoveDir);

    info = struct('feasible', true, 'message', '', 'mode', '', ...
        'nLanes1', 0, 'nLanes2', 0, 'invariantModulus', NaN, 'invariantClearancePx', NaN);

    totalLeaves = 2 * numLeavesPerFlock;
    x = zeros(totalLeaves, 1);
    y = zeros(totalLeaves, 1);
    flockID = [ones(numLeavesPerFlock, 1); 2 * ones(numLeavesPerFlock, 1)];
    isFlock1 = flockID == 1;

    if (moveVec1(1) ~= 0) == (moveVec2(1) ~= 0)
        % ---------------- CASE 1: same axis, opposite directions ----------
        info.mode = 'interleaved lanes';
        flocksTravelOnX = moveVec1(1) ~= 0;
        if flocksTravelOnX
            crossSize = Hf; alongSize = Wf;
            crossExtent = max(yE1, yE2);
            alongExtent1 = xE1; alongExtent2 = xE2;
        else
            crossSize = Wf; alongSize = Hf;
            crossExtent = max(xE1, xE2);
            alongExtent1 = yE1; alongExtent2 = yE2;
        end

        laneSpacing = crossExtent + clearanceMarginPx;
        nLanes = floor(crossSize / laneSpacing);
        if nLanes < 2
            info.feasible = false;
            info.message = sprintf(['Only %d lane(s) fit across %.0fpx at %.0fpx spacing - need ' ...
                'at least one per flock. Use smaller leaves or a bigger field.'], ...
                nLanes, crossSize, laneSpacing);
        else
            laneCentres = ((1:nLanes)' - 0.5) * (crossSize / nLanes);
            lanes1 = laneCentres(1:2:nLanes);   % interleaved: flock 1 odd lanes, flock 2 even
            lanes2 = laneCentres(2:2:nLanes);
            info.nLanes1 = numel(lanes1);
            info.nLanes2 = numel(lanes2);

            [along1, cross1, ok1, msg1] = placeLeavesAlongLanes(numLeavesPerFlock, lanes1, ...
                alongSize, alongExtent1 + clearanceMarginPx);
            [along2, cross2, ok2, msg2] = placeLeavesAlongLanes(numLeavesPerFlock, lanes2, ...
                alongSize, alongExtent2 + clearanceMarginPx);
            if ~ok1
                info.feasible = false;
                info.message = msg1;
            elseif ~ok2
                info.feasible = false;
                info.message = msg2;
            end

            if flocksTravelOnX
                x(isFlock1) = x0 + along1;  y(isFlock1) = y0 + cross1;
                x(~isFlock1) = x0 + along2; y(~isFlock1) = y0 + cross2;
            else
                x(isFlock1) = x0 + cross1;  y(isFlock1) = y0 + along1;
                x(~isFlock1) = x0 + cross2; y(~isFlock1) = y0 + along2;
            end
        end
    else
        % ---------------- CASE 2: perpendicular axes ----------------------
        info.mode = 'phase-locked grid';
        flock1TravelsOnX = moveVec1(1) ~= 0;
        if flock1TravelsOnX
            sigmaA = moveVec1(1); sigmaB = moveVec2(2);
            xEA = xE1; yEA = yE1; xEB = xE2; yEB = yE2;
        else
            sigmaA = moveVec2(1); sigmaB = moveVec1(2);
            xEA = xE2; yEA = yE2; xEB = xE1; yEB = yE1;
        end

        % Required separation on the invariant circle. The naive answer is
        % the summed y half-extents - the gap when A sits exactly on the
        % crossing - but that is not enough. Both flocks move at the SAME
        % speed, so while A is still delta short of the crossing, B is delta
        % short of (or past) its own, and the pair can already overlap: the
        % clearance as A sweeps through works out to (D - hx - hy)/2 for the
        % unfavourable sign combination, where D is the invariant distance.
        % Requiring D >= hx + hy + 2*margin makes that worst case land at
        % +margin. Verified by verifyLeafLanes.m - budgeting only hy lets
        % pairs overlap by ~10px on a 1800x1080 field.
        halfExtentX = (xEA + xEB) / 2;
        halfExtentY = (yEA + yEB) / 2;
        g = gcd(round(Wf), round(Hf));
        cReq = halfExtentX + halfExtentY + 2 * clearanceMarginPx;
        info.invariantModulus = g;
        info.invariantClearancePx = cReq;

        if strcmp(placementMode, 'even')
            % No invariant constraint: lay each flock out along its own
            % lanes with free phases, the same way CASE 1 does. Uniform
            % coverage, no gcd requirement, but the flocks cross freely.
            info.mode = 'even lanes (flocks may cross)';
            nLanesA = max(1, floor(Hf / (yEA + clearanceMarginPx)));
            nLanesB = max(1, floor(Wf / (xEB + clearanceMarginPx)));
            lanesA = ((1:nLanesA)' - 0.5) * (Hf / nLanesA);
            lanesB = ((1:nLanesB)' - 0.5) * (Wf / nLanesB);

            [alongA, crossA, okA, msgA] = placeLeavesAlongLanes(numLeavesPerFlock, lanesA, ...
                Wf, xEA + clearanceMarginPx);
            [alongB, crossB, okB, msgB] = placeLeavesAlongLanes(numLeavesPerFlock, lanesB, ...
                Hf, yEB + clearanceMarginPx);
            if ~okA
                info.feasible = false;
                info.message = msgA;
            elseif ~okB
                info.feasible = false;
                info.message = msgB;
            end

            if flock1TravelsOnX
                info.nLanes1 = nLanesA; info.nLanes2 = nLanesB;
                x(isFlock1) = x0 + alongA;  y(isFlock1) = y0 + crossA;
                x(~isFlock1) = x0 + crossB; y(~isFlock1) = y0 + alongB;
            else
                info.nLanes1 = nLanesB; info.nLanes2 = nLanesA;
                x(~isFlock1) = x0 + alongA; y(~isFlock1) = y0 + crossA;
                x(isFlock1) = x0 + crossB;  y(isFlock1) = y0 + alongB;
            end
        elseif g <= 2 * cReq
            info.feasible = false;
            info.message = sprintf(['Field %.0fx%.0f has gcd = %d, but perpendicular flocks need ' ...
                'gcd > 2*%.0f = %.0f. Inset the field so its width and height share a larger ' ...
                'common factor - e.g. 1920x960 gives 960, while 1920x1080 gives only 120.'], ...
                Wf, Hf, g, cReq, 2 * cReq);
        else
            % Split the leftover arc budget evenly: A's invariants occupy
            % [-hA, +hA] about 0 and B's occupy [-hB, +hB] about g/2, which
            % leaves a gap of at least cReq on both sides of the circle.
            arcBudget = g / 2 - cReq;
            hA = arcBudget / 2;
            hB = arcBudget / 2;

            % Lane count is chosen to MATCH the leaf count, not maximised.
            % Along a lane the usable positions are a fixed grid of
            % nWindows x slotsPerWindow, so packing in as many lanes as
            % geometrically fit gives far more slots than leaves and the
            % surplus shows up as holes: at 50 leaves per flock this branch
            % used to build 16 lanes x 5 windows = 80 slots and leave 30 of
            % them empty, which reads on screen as gaps running through the
            % field. Sizing the lanes so lanes x slots just covers the leaf
            % count fills essentially every slot instead. It also makes the
            % density consistent from one direction combination to the next,
            % since the slot count varies with whether a flock points along
            % or across its own motion.
            maxLanesA = max(1, floor(Hf / (yEA + clearanceMarginPx)));  % A's lanes are y values
            maxLanesB = max(1, floor(Wf / (xEB + clearanceMarginPx)));  % B's lanes are x values
            slotsA = max(1, round(Wf / g)) * ...
                countInvariantSlotsPerWindow(hA, xEA + clearanceMarginPx);
            slotsB = max(1, round(Hf / g)) * ...
                countInvariantSlotsPerWindow(hB, yEB + clearanceMarginPx);
            nLanesA = min(maxLanesA, max(1, ceil(numLeavesPerFlock / slotsA)));
            nLanesB = min(maxLanesB, max(1, ceil(numLeavesPerFlock / slotsB)));
            lanesA = ((1:nLanesA)' - 0.5) * (Hf / nLanesA);
            lanesB = ((1:nLanesB)' - 0.5) * (Wf / nLanesB);

            [alongA, crossA, okA, msgA] = placeLeavesOnInvariantGrid(numLeavesPerFlock, lanesA, ...
                Wf, g, hA, 0, sigmaA, sigmaB, xEA + clearanceMarginPx);
            [alongB, crossB, okB, msgB] = placeLeavesOnInvariantGrid(numLeavesPerFlock, lanesB, ...
                Hf, g, hB, g / 2, sigmaB, sigmaA, yEB + clearanceMarginPx);
            if ~okA
                info.feasible = false;
                info.message = msgA;
            elseif ~okB
                info.feasible = false;
                info.message = msgB;
            end

            if flock1TravelsOnX
                info.nLanes1 = nLanesA; info.nLanes2 = nLanesB;
                x(isFlock1) = x0 + alongA;  y(isFlock1) = y0 + crossA;
                x(~isFlock1) = x0 + crossB; y(~isFlock1) = y0 + alongB;
            else
                info.nLanes1 = nLanesB; info.nLanes2 = nLanesA;
                x(~isFlock1) = x0 + alongA; y(~isFlock1) = y0 + crossA;
                x(isFlock1) = x0 + crossB;  y(isFlock1) = y0 + alongB;
            end
        end
    end

    vx = zeros(totalLeaves, 1);
    vy = zeros(totalLeaves, 1);
    vx(isFlock1) = moveVec1(1) * speedPxPerFrame;
    vy(isFlock1) = moveVec1(2) * speedPxPerFrame;
    vx(~isFlock1) = moveVec2(1) * speedPxPerFrame;
    vy(~isFlock1) = moveVec2(2) * speedPxPerFrame;

    leaves.x = x;
    leaves.y = y;
    leaves.vx = vx;
    leaves.vy = vy;
    leaves.flockID = flockID;
end
