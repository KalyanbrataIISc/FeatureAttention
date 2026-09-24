function drawCueArrow(window, centerX, centerY, pointsLeft, color, arrowLengthPx, arrowHeadPx, lineWidthPx)
% drawCueArrow  Draw a horizontal left- or right-pointing arrow.

% The arrow is made from three lines so it does not depend on a font having
% Unicode arrow glyphs.

    if pointsLeft
        direction = -1;
    else
        direction = 1;
    end

    tailX = centerX - direction * arrowLengthPx / 2;
    tipX = centerX + direction * arrowLengthPx / 2;
    headBaseX = tipX - direction * arrowHeadPx;

    lineCoordinates = [tailX tipX headBaseX tipX headBaseX tipX; ...
                       centerY centerY centerY-arrowHeadPx centerY centerY+arrowHeadPx centerY];
    Screen('DrawLines', window, lineCoordinates, lineWidthPx, color);
end
