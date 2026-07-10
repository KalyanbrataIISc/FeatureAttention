function [ball, hitPaddle] = collideBallPaddle(ball, paddleRect, paddleVxPxPerFrame, ...
    speedPxPerFrame, maxBounceAngleRad, paddlePushGain, paddleSpinGain)
% collideBallPaddle  Bounces the ball off the top face of the paddle. This is
% the only collision in the task that is not a plain mirror reflection, and
% the only one that sets spin - it is where the participant's (NF-driven)
% paddle motion is transferred into the ball.
%
% Three ingredients set the rebound, in this order:
%
%   1. Where the ball lands. hitOffset in [-1, 1] is the contact point
%      measured from the paddle center, and it sets the rebound angle away
%      from vertical: dead center bounces straight up, the far edge bounces
%      at maxBounceAngleRad. This is the classic Breakout control law - it is
%      what lets a paddle aim a ball at all.
%
%   2. How the paddle was moving. A paddle sliding sideways drags the ball
%      along with it (contact friction / carry), so paddlePushGain * paddleVx
%      is added to the ball's horizontal velocity. Speed is then renormalized,
%      so the carry changes the ball's *direction*, not its speed.
%
%   3. That same paddle motion spins the ball. spin is set (not accumulated)
%      from the paddle's velocity at the moment of contact, and then curves
%      the ball's subsequent flight via the Magnus term in moveBall.m. Sign
%      convention: a rightward-moving paddle (paddleVx > 0) gives positive
%      spin, which curves the ball rightward - the same direction the paddle
%      was travelling, i.e. the carry and the curve agree.
%
% Detection requires the ball to be descending (vy > 0), to overlap the
% paddle horizontally, and for its lower edge to have reached the paddle's
% top face while its center is still above the paddle's bottom face. That
% last clause stops a ball that has already fallen past the paddle from being
% teleported back up. Because the bounce leaves the ball resting exactly on
% the top face with vy < 0, it cannot re-trigger on the following frame.

    hitPaddle = false;
    r = ball.radius;

    paddleLeft   = paddleRect(1);
    paddleTop    = paddleRect(2);
    paddleRight  = paddleRect(3);
    paddleBottom = paddleRect(4);

    isDescending  = ball.vy > 0;
    overlapsInX   = (ball.x + r >= paddleLeft) && (ball.x - r <= paddleRight);
    reachedTopFace = (ball.y + r >= paddleTop) && (ball.y <= paddleBottom);
    if ~(isDescending && overlapsInX && reachedTopFace)
        return;
    end

    hitPaddle = true;

    % Lift the ball back out of the paddle so it rests on the top face.
    ball.y = paddleTop - r;

    % (1) Contact point sets the base rebound angle, always upward.
    paddleCenterX   = (paddleLeft + paddleRight) / 2;
    paddleHalfWidth = (paddleRight - paddleLeft) / 2;
    hitOffset = (ball.x - paddleCenterX) / paddleHalfWidth;
    hitOffset = max(-1, min(1, hitOffset));

    bounceAngleRad = hitOffset * maxBounceAngleRad;
    ball.vx =  speedPxPerFrame * sin(bounceAngleRad);
    ball.vy = -speedPxPerFrame * cos(bounceAngleRad);

    % (2) Paddle carry, then renormalize so only the direction changed.
    ball.vx = ball.vx + paddlePushGain * paddleVxPxPerFrame;
    speedNow = hypot(ball.vx, ball.vy);
    if speedNow > 0
        ball.vx = ball.vx * (speedPxPerFrame / speedNow);
        ball.vy = ball.vy * (speedPxPerFrame / speedNow);
    end

    % (3) Paddle motion sets the spin for the ball's next flight.
    ball.spin = paddleSpinGain * paddleVxPxPerFrame;
end
