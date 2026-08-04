function [fieldRect, info] = chooseWrapFieldRect(windowRect, requiredGcdPx, maxShrinkPx, minRepeatsPerAxis)
% chooseWrapFieldRect  Picks the largest centred sub-rectangle of windowRect
% whose width and height share a common factor of at least requiredGcdPx.
%
% initLeafLanes.m's phase-locked grid (flocks moving on perpendicular axes)
% only works when gcd(fieldWidth, fieldHeight) comfortably exceeds a leaf -
% that gcd is the circumference of the circle the collision invariants live
% on, so a small one leaves nowhere to separate the two flocks. The gcd of a
% raw screen is a lottery: 1920x1080 gives 120 and fails, 1920x960 gives 960
% and works, and other resolutions land anywhere. Rather than make the
% caller hand-tune an inset per monitor, this searches for one.
%
% The requirement is a single number, not one per trial: initLeafLanes.m
% needs g > 2*((xExtentA + xExtentB)/2 + (yExtentA + yExtentB)/2 + 2*margin),
% and because a leaf's two extents are the outer length and width in one
% order or the other, xExtent + yExtent = outerLength + outerWidth whichever
% way it points. So the pointing directions cancel and
%
%     requiredGcdPx = 2*(outerLengthPx + outerWidthPx + 2*marginPx) + 1
%
% covers every direction combination at once, which means the field can be
% fixed for the whole block instead of resized per trial.
%
% minRepeatsPerAxis is what keeps the result from looking clumpy, and it is
% the reason a bigger gcd is not simply better. Along any lane the usable
% positions repeat every g pixels, and within each repeat they are confined
% to a band of width g/2 - cReq. So the leaves in a lane form one cluster
% per repeat, and the number of repeats is fieldWidth/g (or fieldHeight/g).
% Maximising area alone tends to pick the largest possible g, which is the
% worst case: on a 1920x1080 display it gives 1920x960 with g = 960, i.e.
% two clusters along x and a single one along y, leaving big empty stretches
% between them. Demanding at least minRepeatsPerAxis repeats on BOTH axes
% forces a smaller g, which spreads the leaves out - at 2 or more the bands
% get narrow enough that each repeat holds roughly one leaf and the spacing
% along a lane becomes even.
%
% Search is over every (width, height) within maxShrinkPx of the window,
% keeping the pair of largest area that satisfies both constraints, so the
% field gives up as little screen as it can. info.feasible is false when
% nothing within maxShrinkPx qualifies - raise maxShrinkPx, lower
% minRepeatsPerAxis, or shrink the leaves.

    windowWidth = windowRect(3) - windowRect(1);
    windowHeight = windowRect(4) - windowRect(2);

    if nargin < 4 || isempty(minRepeatsPerAxis)
        minRepeatsPerAxis = 2;
    end

    info = struct('feasible', false, 'message', '', 'achievedGcdPx', NaN, ...
        'lostWidthPx', NaN, 'lostHeightPx', NaN, 'repeatsX', NaN, 'repeatsY', NaN);
    fieldRect = windowRect;

    maxShrinkPx = min([maxShrinkPx, windowWidth - 1, windowHeight - 1]);
    if maxShrinkPx < 0 || requiredGcdPx * minRepeatsPerAxis > min(windowWidth, windowHeight)
        info.message = sprintf(['Need a common factor of %d px repeated at least %d times on ' ...
            'each axis, but the window is only %dx%d. Use smaller leaves, a lower ' ...
            'minRepeatsPerAxis, or a bigger display.'], ...
            requiredGcdPx, minRepeatsPerAxis, windowWidth, windowHeight);
        return;
    end

    candidateWidths = (windowWidth:-1:windowWidth - maxShrinkPx)';
    candidateHeights = windowWidth * 0 + (windowHeight:-1:windowHeight - maxShrinkPx);
    candidateWidths = candidateWidths(candidateWidths > 0);
    candidateHeights = candidateHeights(candidateHeights > 0);

    widthGrid = repmat(candidateWidths, 1, numel(candidateHeights));
    heightGrid = repmat(candidateHeights, numel(candidateWidths), 1);
    gcdGrid = gcd(widthGrid, heightGrid);

    % g divides both sides, so these are exact integer repeat counts.
    repeatsXGrid = widthGrid ./ gcdGrid;
    repeatsYGrid = heightGrid ./ gcdGrid;

    qualifies = gcdGrid >= requiredGcdPx & ...
        repeatsXGrid >= minRepeatsPerAxis & repeatsYGrid >= minRepeatsPerAxis;

    areaGrid = widthGrid .* heightGrid;
    areaGrid(~qualifies) = -Inf;

    [bestArea, bestIdx] = max(areaGrid(:));
    if ~isfinite(bestArea)
        info.message = sprintf(['No field within %d px of %dx%d has a common factor of at least ' ...
            '%d px repeated %d+ times on both axes. Raise maxShrinkPx, lower minRepeatsPerAxis, ' ...
            'or use smaller leaves (the requirement scales with leaf size).'], ...
            maxShrinkPx, windowWidth, windowHeight, requiredGcdPx, minRepeatsPerAxis);
        return;
    end

    [wIdx, hIdx] = ind2sub(size(areaGrid), bestIdx);
    fieldWidth = candidateWidths(wIdx);
    fieldHeight = candidateHeights(hIdx);

    % Centre it, so whatever is given up is split evenly around the display.
    marginX = floor((windowWidth - fieldWidth) / 2);
    marginY = floor((windowHeight - fieldHeight) / 2);
    fieldRect = [windowRect(1) + marginX, windowRect(2) + marginY, ...
                 windowRect(1) + marginX + fieldWidth, windowRect(2) + marginY + fieldHeight];

    info.feasible = true;
    info.achievedGcdPx = gcd(fieldWidth, fieldHeight);
    info.repeatsX = fieldWidth / info.achievedGcdPx;
    info.repeatsY = fieldHeight / info.achievedGcdPx;
    info.lostWidthPx = windowWidth - fieldWidth;
    info.lostHeightPx = windowHeight - fieldHeight;
    info.message = sprintf('%dx%d (gcd %d, %dx%d repeats), giving up %d x %d px of the display.', ...
        fieldWidth, fieldHeight, info.achievedGcdPx, info.repeatsX, info.repeatsY, ...
        info.lostWidthPx, info.lostHeightPx);
end
