function drawPaddle(window, paddleRect, gratingWidthPx, gratingBarWidthPx, ...
    leftBarColorA, leftBarColorB, rightBarColorA, rightBarColorB, ...
    paddleBodyColor, paddleBorderColor, paddleBorderPx)
% drawPaddle  Draws the paddle as three regions across its width:
%
%   [ left grating | inert middle | right grating ]
%
% The left grating flickers at the 17 Hz tag, the right at 20 Hz, and the
% middle strip deliberately does not flicker at all. The two gratings are the
% task's entire SSVEP stimulus: they drive the response the real-time
% acquisition picks up, and the lateralisation of that response is what moves
% this very paddle (see computePaddleVelocityFromNf.m). Attending left of the
% paddle's center drives it left; attending right drives it right.
%
% The gratings are drawn on top of a solid paddle body, so the paddle's
% outline stays visible even at the trough of the flicker cycle, when both
% gratings collapse to their uniform mid-color and carry no pattern.
%
% Both grating colors for this frame are supplied by the caller, already
% modulated for the current flicker phase (see computeGratingColors.m).

    left   = paddleRect(1);
    top    = paddleRect(2);
    right  = paddleRect(3);
    bottom = paddleRect(4);

    if paddleBorderPx > 0
        Screen('FillRect', window, paddleBorderColor, ...
            [left - paddleBorderPx, top - paddleBorderPx, ...
             right + paddleBorderPx, bottom + paddleBorderPx]);
    end

    % Solid body first; the middle strip is whatever this leaves uncovered.
    Screen('FillRect', window, paddleBodyColor, paddleRect);

    leftGratingRect  = [left, top, left + gratingWidthPx, bottom];
    rightGratingRect = [right - gratingWidthPx, top, right, bottom];

    drawFlickerGrating(window, leftGratingRect,  leftBarColorA,  leftBarColorB,  gratingBarWidthPx);
    drawFlickerGrating(window, rightGratingRect, rightBarColorA, rightBarColorB, gratingBarWidthPx);
end
