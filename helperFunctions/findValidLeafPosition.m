function position = findValidLeafPosition(fieldRect, existingPositions, minSeparationPx, targetLeafCount)
% findValidLeafPosition  Samples a random (x,y) inside fieldRect that is at
% least minSeparationPx away from every row of existingPositions (an Nx2
% matrix, may be empty). Falls back to the last sampled candidate if no
% valid position is found within the attempt budget.
%
% Candidates are drawn from whichever grid cell currently holds the FEWEST
% leaves in existingPositions (ties broken randomly), not from the whole
% field uniformly - plain field-wide uniform sampling has nothing stopping
% several respawns in a row from all landing in the same already-crowded
% region, which is what produces visible clustering/gaps. Since this runs
% on every respawn (not just at trial start via initLeaves.m), it keeps
% rebalancing toward whatever region is currently sparse as leaves drift,
% so density stays even over time too, not just in the first frame.
%
% Grid cells are sized so each holds ~1 leaf on average at targetLeafCount
% (the actual number of leaves sharing the field - initLeaves.m/
% updateLeaves.m pass in their current leaf count). A grid finer than that
% leaves almost every cell permanently at 0 occupancy, which gives the
% "prefer least-occupied" rule nothing meaningful to differentiate between
% and makes it behave just like plain uniform-random (measured: with cells
% pitched at minSeparationPx alone, ~190 cells for 40 leaves, this did NOT
% reliably beat plain uniform-random across seeds). The grid is never
% coarser than minSeparationPx though, since cells much bigger than that
% stop usefully constraining candidates for the distance check below.

    maxAttempts = 25;
    fieldLeft = fieldRect(1);
    fieldTop = fieldRect(2);
    fieldWidth = fieldRect(3) - fieldRect(1);
    fieldHeight = fieldRect(4) - fieldRect(2);

    idealCellSize = sqrt((fieldWidth * fieldHeight) / max(1, targetLeafCount));
    cellSize = max(minSeparationPx, idealCellSize);
    numCellsX = max(1, floor(fieldWidth / cellSize));
    numCellsY = max(1, floor(fieldHeight / cellSize));
    cellWidth = fieldWidth / numCellsX;
    cellHeight = fieldHeight / numCellsY;

    occupancy = zeros(numCellsX * numCellsY, 1);
    if ~isempty(existingPositions)
        colIdx = min(numCellsX, max(1, floor((existingPositions(:,1) - fieldLeft) / cellWidth) + 1));
        rowIdx = min(numCellsY, max(1, floor((existingPositions(:,2) - fieldTop) / cellHeight) + 1));
        cellIdx = (rowIdx - 1) * numCellsX + colIdx;
        occupancy = accumarray(cellIdx, 1, [numCellsX * numCellsY, 1]);
    end

    sparsestCells = find(occupancy == min(occupancy));
    chosenCell = sparsestCells(randi(numel(sparsestCells)));
    chosenRow = floor((chosenCell - 1) / numCellsX) + 1;
    chosenCol = chosenCell - (chosenRow - 1) * numCellsX;
    cellLeft = fieldLeft + (chosenCol - 1) * cellWidth;
    cellTop = fieldTop + (chosenRow - 1) * cellHeight;

    position = [cellLeft + rand() * cellWidth, cellTop + rand() * cellHeight];
    for attempt = 1:maxAttempts
        candidate = [cellLeft + rand() * cellWidth, cellTop + rand() * cellHeight];
        if isempty(existingPositions)
            position = candidate;
            break;
        end
        distances = hypot(existingPositions(:,1) - candidate(1), existingPositions(:,2) - candidate(2));
        position = candidate;
        if all(distances >= minSeparationPx)
            break;
        end
    end
end
