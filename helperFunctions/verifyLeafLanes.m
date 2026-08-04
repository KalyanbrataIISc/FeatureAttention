function report = verifyLeafLanes(leaves, fieldRect, xExtent1, yExtent1, xExtent2, yExtent2, maxFrames)
% verifyLeafLanes  Brute-force check that an initLeafLanes.m layout really
% never overlaps, by simulating the motion and measuring the actual closest
% approach instead of trusting the placement algebra.
%
% The motion is periodic: flock 1 returns to its start after Wf (or Hf)
% pixels of travel and flock 2 likewise, so the whole configuration repeats
% after lcm(Wf, Hf) pixels. Simulating that one period therefore proves the
% behaviour for a trial of any length. maxFrames caps the work if the period
% is impractically long (report.covered says whether a full period was
% reached; a partial run can only ever miss a collision, never invent one).
%
% Overlap is tested as axis-aligned bounding boxes, matching how
% leafExtentsForDirection.m sizes leaves: a pair is disjoint iff its centre
% separation exceeds the summed half-extents on at least one axis. The
% reported clearance for a pair is
%
%     max(|dx| - (xExtent1+xExtent2)/2,  |dy| - (yExtent1+yExtent2)/2)
%
% which is >= 0 exactly when the two do not overlap. Separations are
% measured on the wrapped (toroidal) field, so a pair straddling an edge is
% compared across it rather than through the middle of the screen.
%
% report fields: minCrossFlockClearancePx (the number that matters),
% minWithinFlockClearancePx, collisionFree, framesSimulated, covered,
% worstFrame, worstPair.

    Wf = fieldRect(3) - fieldRect(1);
    Hf = fieldRect(4) - fieldRect(2);

    speed1 = hypot(leaves.vx(find(leaves.flockID == 1, 1)), leaves.vy(find(leaves.flockID == 1, 1)));
    speed2 = hypot(leaves.vx(find(leaves.flockID == 2, 1)), leaves.vy(find(leaves.flockID == 2, 1)));
    speed = max([speed1, speed2, eps]);
    periodPx = lcm(round(Wf), round(Hf));
    periodFrames = ceil(periodPx / speed);

    framesToRun = min(periodFrames, maxFrames);
    report.framesSimulated = framesToRun;
    report.covered = framesToRun >= periodFrames;

    idx1 = find(leaves.flockID == 1);
    idx2 = find(leaves.flockID == 2);

    % Half-extent sums: cross-flock pairs mix the two flocks' extents, while
    % within-flock pairs use that flock's own extent twice.
    crossHalfX = (xExtent1 + xExtent2) / 2;
    crossHalfY = (yExtent1 + yExtent2) / 2;

    report.minCrossFlockClearancePx = Inf;
    report.minWithinFlockClearancePx = Inf;
    report.worstFrame = NaN;
    report.worstPair = [NaN NaN];

    for frame = 1:framesToRun
        ax = leaves.x(idx1); ay = leaves.y(idx1);
        bx = leaves.x(idx2); by = leaves.y(idx2);

        dx = abs(bsxfun(@minus, ax, bx.'));
        dy = abs(bsxfun(@minus, ay, by.'));
        dx = min(dx, Wf - dx);   % wrapped (toroidal) separation
        dy = min(dy, Hf - dy);
        clearance = max(dx - crossHalfX, dy - crossHalfY);

        [frameMin, linearIdx] = min(clearance(:));
        if frameMin < report.minCrossFlockClearancePx
            report.minCrossFlockClearancePx = frameMin;
            [i1, i2] = ind2sub(size(clearance), linearIdx);
            report.worstFrame = frame;
            report.worstPair = [idx1(i1), idx2(i2)];
        end

        if frame == 1
            % Within-flock separations are frozen (one velocity per flock),
            % so checking the first frame settles every later one.
            report.minWithinFlockClearancePx = min( ...
                minLeafSelfClearance(ax, ay, Wf, Hf, xExtent1, yExtent1), ...
                minLeafSelfClearance(bx, by, Wf, Hf, xExtent2, yExtent2));
        end

        leaves = updateLeafLanes(leaves, fieldRect);
    end

    report.collisionFree = report.minCrossFlockClearancePx >= 0 && ...
        report.minWithinFlockClearancePx >= 0;
end
