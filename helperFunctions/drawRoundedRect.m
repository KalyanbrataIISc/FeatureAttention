function drawRoundedRect(window, color, rect, cornerRadius)
% drawRoundedRect  Fills rect with color with rounded corners of the given
% radius. Built from two overlapping full-bleed rectangles (covering
% everything except the four corner squares) plus four corner circles,
% since Screen('FillRect', ...) has no native corner-radius option.

    left = rect(1); top = rect(2); right = rect(3); bottom = rect(4);

    horizontalRect = [left, top + cornerRadius, right, bottom - cornerRadius];
    verticalRect   = [left + cornerRadius, top, right - cornerRadius, bottom];
    Screen('FillRect', window, color, horizontalRect);
    Screen('FillRect', window, color, verticalRect);

    cornerCenters = [left + cornerRadius,  top + cornerRadius; ...
                     right - cornerRadius, top + cornerRadius; ...
                     left + cornerRadius,  bottom - cornerRadius; ...
                     right - cornerRadius, bottom - cornerRadius];
    for i = 1:4
        cornerRect = [cornerCenters(i, 1) - cornerRadius, cornerCenters(i, 2) - cornerRadius, ...
                      cornerCenters(i, 1) + cornerRadius, cornerCenters(i, 2) + cornerRadius];
        Screen('FillOval', window, color, cornerRect);
    end
end
