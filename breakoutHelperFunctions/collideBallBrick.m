function [ball, hitBrick] = collideBallBrick(ball, brickRect)
% collideBallBrick  Circle-vs-axis-aligned-rectangle collision between the
% ball and a single brick.
%
% Overlap is tested against the closest point on the brick to the ball
% center, which handles face hits and corner hits with the same expression.
% On contact the ball reflects off whichever face it had penetrated least
% far - the face it must have entered through - and is pushed back out to
% rest against that face, so it cannot be caught inside the brick.
%
% Bricks, like walls, are frictionless: speed is preserved and spin is left
% alone. Only the paddle sets spin (see collideBallPaddle.m).
%
% One contact breaks the brick, so the caller removes it and sends the
% brick-bounce trigger on hitBrick.

    hitBrick = false;
    r = ball.radius;

    brickLeft   = brickRect(1);
    brickTop    = brickRect(2);
    brickRight  = brickRect(3);
    brickBottom = brickRect(4);

    % Closest point on the brick to the ball center; if it is further than
    % one radius away, the circle and the rectangle do not overlap.
    closestX = max(brickLeft, min(ball.x, brickRight));
    closestY = max(brickTop,  min(ball.y, brickBottom));
    dx = ball.x - closestX;
    dy = ball.y - closestY;
    if dx * dx + dy * dy > r * r
        return;
    end

    hitBrick = true;

    % How far the ball has pushed past each face. The smallest overlap on
    % each axis identifies the nearest face on that axis; the smaller of the
    % two axes is the face the ball actually came in through.
    overlapLeft   = (ball.x + r) - brickLeft;
    overlapRight  = brickRight - (ball.x - r);
    overlapTop    = (ball.y + r) - brickTop;
    overlapBottom = brickBottom - (ball.y - r);

    if min(overlapLeft, overlapRight) < min(overlapTop, overlapBottom)
        ball.vx = -ball.vx;
        if overlapLeft < overlapRight
            ball.x = brickLeft - r;      % entered through the left face
        else
            ball.x = brickRight + r;     % entered through the right face
        end
    else
        ball.vy = -ball.vy;
        if overlapTop < overlapBottom
            ball.y = brickTop - r;       % entered through the top face
        else
            ball.y = brickBottom + r;    % entered through the bottom face
        end
    end
end
