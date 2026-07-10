function drawFlickerGrating(window, rect, barColorA, barColorB, barWidthPx)
% drawFlickerGrating  Draws a vertical square-wave grating filling rect,
% alternating bars of barColorA and barColorB, each barWidthPx wide.
%
% This function is pure drawing and holds no notion of time: the caller
% passes the two bar colors already modulated for this frame's flicker phase
% (see computeGratingColors.m). Keeping the flicker phase out of here is what
% lets the phase be driven from real VBL timestamps.
%
% If barWidthPx does not divide the rect width exactly, the final bar is
% clipped to the rect edge rather than overhanging it, so the grating never
% spills outside the paddle.

    left   = rect(1);
    top    = rect(2);
    right  = rect(3);
    bottom = rect(4);

    barLeft = left;
    barIndex = 0;
    while barLeft < right
        barRight = min(barLeft + barWidthPx, right);
        if mod(barIndex, 2) == 0
            Screen('FillRect', window, barColorA, [barLeft, top, barRight, bottom]);
        else
            Screen('FillRect', window, barColorB, [barLeft, top, barRight, bottom]);
        end
        barLeft = barRight;
        barIndex = barIndex + 1;
    end
end
