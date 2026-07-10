function [ball, hitWall] = collideBallWalls(ball, fieldLeft, fieldRight, fieldTop)
% collideBallWalls  Reflects the ball off the left, right and top edges of
% the playing field. The bottom edge is deliberately absent: a ball that
% passes it has fallen, which is what ends the trial (see gameBreakout.m).
%
% Walls are modelled as frictionless: the reflection flips one velocity
% component, preserving speed, and leaves spin untouched. Only the paddle
% imparts spin (collideBallPaddle.m), which keeps the one interesting
% coupling in this task - participant/NF control of the paddle -> ball
% trajectory - from being contaminated by incidental wall contacts.
%
% hitWall is true if the ball bounced off any wall on this frame. A corner
% hit reflects off both walls but still reports a single bounce, so the
% caller never emits two wall-bounce triggers within one frame.

    hitWall = false;
    r = ball.radius;

    if ball.x - r < fieldLeft
        ball.x = fieldLeft + r;
        ball.vx = abs(ball.vx);
        hitWall = true;
    elseif ball.x + r > fieldRight
        ball.x = fieldRight - r;
        ball.vx = -abs(ball.vx);
        hitWall = true;
    end

    if ball.y - r < fieldTop
        ball.y = fieldTop + r;
        ball.vy = abs(ball.vy);
        hitWall = true;
    end
end
