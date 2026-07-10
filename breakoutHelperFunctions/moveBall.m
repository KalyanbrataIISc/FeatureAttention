function ball = moveBall(ball, speedPxPerFrame, magnusGainPerFrame, spinDecayPerFrame, minVerticalSpeedFraction)
% moveBall  Advances the ball by one displayed frame. No gravity. Order of
% operations: spin curves the velocity direction (Magnus), speed is
% renormalized, a minimum vertical component is enforced, spin decays, then
% position is integrated. Collisions are handled separately by the caller
% (collideBallWalls / collideBallPaddle / collideBallBrick).
%
% Speed is renormalized to speedPxPerFrame on every frame, so spin only ever
% changes *where the ball is going*, never *how fast*. That keeps the trial
% tightly controlled: ball speed is a single experimenter parameter that no
% amount of paddle motion or spin can drift.
%
% Magnus term. For a ball spinning about the axis perpendicular to the
% screen, the aerodynamic force is perpendicular to its velocity and
% proportional to the spin. Here (-vy, vx) is the velocity rotated +90 deg,
% so positive spin accelerates the ball to the right of its travel direction
% and the path curves that way. Example: a ball travelling straight up
% (vx=0, vy<0) with positive spin gets (-vy, vx) = (+, 0), i.e. pushed right.
%
% minVerticalSpeedFraction guards against a degenerate trial. Repeated Magnus
% curvature can rotate the velocity arbitrarily close to horizontal, and a
% purely horizontal ball never reaches the paddle and never falls, so the
% trial could only ever end on the safety timeout. Forcing |vy| to stay at
% least this fraction of the ball's speed makes every trial terminate.

    % --- Magnus: curve the direction of travel by an amount set by the spin.
    % Both components must be computed from the *pre-update* velocity.
    vxOld = ball.vx;
    vyOld = ball.vy;
    ball.vx = vxOld - magnusGainPerFrame * ball.spin * vyOld;
    ball.vy = vyOld + magnusGainPerFrame * ball.spin * vxOld;

    % --- Renormalize: Magnus rotates the velocity, it must not speed it up.
    speedNow = hypot(ball.vx, ball.vy);
    if speedNow > 0
        ball.vx = ball.vx * (speedPxPerFrame / speedNow);
        ball.vy = ball.vy * (speedPxPerFrame / speedNow);
    end

    % --- Never let the trajectory go (near-)horizontal; see header note.
    minVerticalSpeed = minVerticalSpeedFraction * speedPxPerFrame;
    if abs(ball.vy) < minVerticalSpeed
        vySign = sign(ball.vy);
        if vySign == 0
            vySign = 1;      % exactly horizontal: send it down, the paddle must save it
        end
        vxSign = sign(ball.vx);
        if vxSign == 0
            vxSign = 1;
        end
        ball.vy = vySign * minVerticalSpeed;
        ball.vx = vxSign * sqrt(max(0, speedPxPerFrame^2 - minVerticalSpeed^2));
    end

    % --- Spin bleeds off over time (drag), so a curve from one paddle hit
    % does not persist across the whole rest of the trial.
    ball.spin = ball.spin * spinDecayPerFrame;

    % --- Integrate.
    ball.x = ball.x + ball.vx;
    ball.y = ball.y + ball.vy;
end
