function position = findValidLeafPosition(fieldRect, existingPositions, minSeparationPx, grid)
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
% grid (numCellsX/numCellsY/cellWidth/cellHeight) is precomputed once by
% computeLeafPlacementGrid.m and passed in rather than recomputed here,
% since fieldRect/minSeparationPx/leaf count never change mid-experiment
% and this can run many times per second across a whole block of trials.

    maxAttempts = 25;
    fieldLeft = fieldRect(1);
    fieldTop = fieldRect(2);

    numCellsX = grid.numCellsX;
    numCellsY = grid.numCellsY;
    cellWidth = grid.cellWidth;
    cellHeight = grid.cellHeight;

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
