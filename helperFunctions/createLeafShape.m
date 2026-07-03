function vertices = createLeafShape(pointDirection, leafLengthPx, leafWidthPx)
% createLeafShape  Builds a round-tailed, pointed leaf polygon (Nx2, in
% pixels) centered on the origin, oriented so its point faces
% pointDirection ('up'/'down'/'left'/'right'). Call once per flock per
% trial (pointing direction is constant within a trial) and translate the
% returned vertices to each leaf's position every frame.

    nArcPoints = 10;
    radius = leafWidthPx / 2;
    tailCenterX = -leafLengthPx / 2 + radius;
    tipX = leafLengthPx / 2;

    arcAngles = linspace(90, 270, nArcPoints);
    arcX = tailCenterX + radius * cosd(arcAngles);
    arcY = radius * sind(arcAngles);

    baseVertices = [arcX(:), arcY(:); tipX, 0];

    switch pointDirection
        case 'right'
            angleDeg = 0;
        case 'down'
            angleDeg = 90;
        case 'left'
            angleDeg = 180;
        case 'up'
            angleDeg = -90;
        otherwise
            error('createLeafShape:invalidDirection', 'Unknown direction: %s', pointDirection);
    end

    rotationMatrix = [cosd(angleDeg), -sind(angleDeg); sind(angleDeg), cosd(angleDeg)];
    vertices = (rotationMatrix * baseVertices')';
end
