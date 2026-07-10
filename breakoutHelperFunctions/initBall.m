function ball = initBall(spawnX, spawnY, speedPxPerFrame, maxLaunchAngleRad, radiusPx)
% initBall  Creates the ball struct at the start of a trial (the ball spawn
% *is* the trial start - see gameBreakout.m).
%
% The ball is launched upward at a random angle drawn uniformly from
% +/- maxLaunchAngleRad either side of straight up, so the participant does
% not learn a fixed opening trajectory. Screen y grows downward, so "upward"
% is a negative vy.
%
% Fields:
%   x, y      - center position, px
%   vx, vy    - velocity, px per displayed frame
%   spin      - angular velocity, arbitrary units; positive spin curves the
%               ball to the right of its direction of travel (see moveBall.m).
%               Only the paddle ever sets spin (see collideBallPaddle.m).
%   radius    - px

    launchAngleRad = (2 * rand() - 1) * maxLaunchAngleRad;   % from vertical, + = toward +x

    ball = struct();
    ball.x = spawnX;
    ball.y = spawnY;
    ball.vx =  speedPxPerFrame * sin(launchAngleRad);
    ball.vy = -speedPxPerFrame * cos(launchAngleRad);
    ball.spin = 0;
    ball.radius = radiusPx;
end
