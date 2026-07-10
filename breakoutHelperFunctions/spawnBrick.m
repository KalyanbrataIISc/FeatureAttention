function brickRect = spawnBrick(regionRect, brickWidthPx, brickHeightPx, ...
    ballX, ballY, minBallClearancePx, maxAttempts)
% spawnBrick  Returns a [left top right bottom] rect for one brick at a
% random position lying entirely inside regionRect (the band above the screen
% midline where bricks are allowed).
%
% Exactly one brick exists at a time in this task, and the next one only
% appears after the ball has bounced off the paddle again, so there is no
% brick-vs-brick overlap to resolve. What does have to be avoided is spawning
% a brick on top of the ball: the ball is in flight when a brick appears, and
% a brick materialising around it would be broken instantly (or trap it). So
% candidate positions are rejection-sampled until the brick clears the ball's
% current position by minBallClearancePx (pass the ball radius plus whatever
% extra margin you want).
%
% If maxAttempts candidates are all rejected - only possible if the ball is
% sitting in the middle of a region barely larger than one brick - the last
% candidate is returned rather than stalling the frame loop. Size the region
% generously relative to the brick and this never fires.

    regionLeft   = regionRect(1);
    regionTop    = regionRect(2);
    regionRight  = regionRect(3);
    regionBottom = regionRect(4);

    % Top-left corner is drawn from the sub-rectangle that keeps the whole
    % brick inside the region.
    maxLeft = max(regionLeft, regionRight  - brickWidthPx);
    maxTop  = max(regionTop,  regionBottom - brickHeightPx);

    brickRect = [regionLeft, regionTop, regionLeft + brickWidthPx, regionTop + brickHeightPx];

    for attempt = 1:maxAttempts
        left = regionLeft + rand() * (maxLeft - regionLeft);
        top  = regionTop  + rand() * (maxTop  - regionTop);
        brickRect = [left, top, left + brickWidthPx, top + brickHeightPx];

        % Distance from the ball center to the closest point of this brick.
        closestX = max(brickRect(1), min(ballX, brickRect(3)));
        closestY = max(brickRect(2), min(ballY, brickRect(4)));
        if hypot(ballX - closestX, ballY - closestY) >= minBallClearancePx
            return;
        end
    end
end
