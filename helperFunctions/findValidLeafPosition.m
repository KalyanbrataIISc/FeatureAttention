function position = findValidLeafPosition(fieldRect, existingPositions, minSeparationPx)
% findValidLeafPosition  Samples a random (x,y) inside fieldRect that is
% at least minSeparationPx away from every row of existingPositions
% (an Nx2 matrix, may be empty). Falls back to the last sampled
% candidate if no valid position is found within the attempt budget.

    maxAttempts = 25;
    fieldLeft = fieldRect(1);
    fieldTop = fieldRect(2);
    fieldWidth = fieldRect(3) - fieldRect(1);
    fieldHeight = fieldRect(4) - fieldRect(2);

    position = [fieldLeft + rand() * fieldWidth, fieldTop + rand() * fieldHeight];
    for attempt = 1:maxAttempts
        candidate = [fieldLeft + rand() * fieldWidth, fieldTop + rand() * fieldHeight];
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
