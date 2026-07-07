function leaves = updateLeaves(leaves, fieldRect, minSeparationPx, maxLifeFrames)
% updateLeaves  Advances one frame: moves every leaf, ages its lifetime,
% and respawns (at a fresh non-colliding position) any leaf that expired,
% left the field, or drifted within minSeparationPx of another leaf. This
% is what keeps the leaves behaving like RDK dots that appear and
% disappear without ever visibly overlapping.

    leaves.x = leaves.x + leaves.vx;
    leaves.y = leaves.y + leaves.vy;
    leaves.life = leaves.life - 1;

    outOfBounds = leaves.x < fieldRect(1) | leaves.x > fieldRect(3) | ...
        leaves.y < fieldRect(2) | leaves.y > fieldRect(4);
    needsRespawn = leaves.life <= 0 | outOfBounds;

    n = numel(leaves.x);
    activeIdx = find(~needsRespawn);
    if numel(activeIdx) > 1
        ax = leaves.x(activeIdx);
        ay = leaves.y(activeIdx);
        dx = bsxfun(@minus, ax, ax');
        dy = bsxfun(@minus, ay, ay');
        distances = hypot(dx, dy);
        distances(1:size(distances, 1) + 1:end) = Inf;
        tooClose = any(distances < minSeparationPx, 2);
        needsRespawn(activeIdx(tooClose)) = true;
    end

    respawnIdx = find(needsRespawn);
    for k = 1:numel(respawnIdx)
        idx = respawnIdx(k);
        otherMask = true(n, 1);
        otherMask(idx) = false;
        existingPositions = [leaves.x(otherMask), leaves.y(otherMask)];
        newPosition = findValidLeafPosition(fieldRect, existingPositions, minSeparationPx, n);
        leaves.x(idx) = newPosition(1);
        leaves.y(idx) = newPosition(2);
        leaves.life(idx) = maxLifeFrames;
    end
end
