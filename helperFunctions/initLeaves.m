function leaves = initLeaves(numLeavesPerFlock, fieldRect, minSeparationPx, maxLifeFrames, flock1Velocity, flock2Velocity)
% initLeaves  Creates the combined leaf state (both flocks) for a new
% trial. Positions are placed one at a time, each checked against every
% already-placed leaf (regardless of flock) so no two leaves start closer
% than minSeparationPx. Lifetimes are staggered uniformly in
% [1, maxLifeFrames] so leaves don't all respawn in sync.

    totalLeaves = numLeavesPerFlock * 2;
    flockID = [ones(numLeavesPerFlock, 1); 2 * ones(numLeavesPerFlock, 1)];
    vx = zeros(totalLeaves, 1);
    vy = zeros(totalLeaves, 1);
    vx(flockID == 1) = flock1Velocity(1);
    vy(flockID == 1) = flock1Velocity(2);
    vx(flockID == 2) = flock2Velocity(1);
    vy(flockID == 2) = flock2Velocity(2);

    x = zeros(totalLeaves, 1);
    y = zeros(totalLeaves, 1);
    life = randi(maxLifeFrames, totalLeaves, 1);

    placementOrder = randperm(totalLeaves);
    for i = 1:totalLeaves
        idx = placementOrder(i);
        placedSoFar = placementOrder(1:i-1);
        existingPositions = [x(placedSoFar), y(placedSoFar)];
        newPosition = findValidLeafPosition(fieldRect, existingPositions, minSeparationPx, totalLeaves);
        x(idx) = newPosition(1);
        y(idx) = newPosition(2);
    end

    leaves.x = x;
    leaves.y = y;
    leaves.life = life;
    leaves.vx = vx;
    leaves.vy = vy;
    leaves.flockID = flockID;
end
