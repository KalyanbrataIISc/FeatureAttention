function grid = computeLeafPlacementGrid(fieldRect, minSeparationPx, targetLeafCount)
% computeLeafPlacementGrid  Precomputes the grid geometry
% findValidLeafPosition.m needs (cell counts/sizes) once, so it isn't
% recomputed via sqrt/floor on every single respawn call throughout a
% whole block of trials. fieldRect/minSeparationPx/targetLeafCount don't
% change mid-experiment, so this only ever needs to run once, right after
% fieldRect is known - call it there and pass the result into
% initLeaves.m/updateLeaves.m, which forward it to
% findValidLeafPosition.m.

    fieldWidth = fieldRect(3) - fieldRect(1);
    fieldHeight = fieldRect(4) - fieldRect(2);
    idealCellSize = sqrt((fieldWidth * fieldHeight) / max(1, targetLeafCount));
    cellSize = max(minSeparationPx, idealCellSize);

    grid.numCellsX = max(1, floor(fieldWidth / cellSize));
    grid.numCellsY = max(1, floor(fieldHeight / cellSize));
    grid.cellWidth = fieldWidth / grid.numCellsX;
    grid.cellHeight = fieldHeight / grid.numCellsY;
end
