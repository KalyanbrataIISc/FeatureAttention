function [barColorA, barColorB] = computeGratingColors(t, freqHz, midColor, barColorHigh, barColorLow)
% computeGratingColors  Returns this frame's two bar colors for one of the
% paddle's flickering SSVEP gratings, evaluated at t seconds since the start
% of the flicker.
%
% The grating's *contrast* is what flickers, sinusoidally, at freqHz:
%
%     w(t) = 0.5 + 0.5 * sin(2*pi*freqHz*t)      in [0, 1]
%     barA = midColor + w * (barColorHigh - midColor)
%     barB = midColor + w * (barColorLow  - midColor)
%
% At the peak of the cycle (w = 1) the bars sit at their full colors and the
% grating is at maximum contrast; at the trough (w = 0) both bars collapse to
% midColor and the grating vanishes into a uniform patch. So the pattern
% appears and disappears once per cycle, and the flicker fundamental is
% exactly freqHz. This matters: a contrast-*reversing* grating (bars swapping
% polarity) would put its dominant response at 2*freqHz instead, which would
% not line up with the 17/20 Hz bins the real-time acquisition and the paddle
% control law are built around.
%
% Derive t from real Screen('Flip') VBL timestamps, not from a frame counter.
% A frame counter assumes every loop iteration is exactly one display
% refresh, so each dropped frame permanently detunes the flicker below its
% nominal frequency, and the error only accumulates. Timestamps cost at most
% one bounded phase correction per drop. Same rationale, and the same fix, as
% helperFunctions/computeSsvepColorsFromTime.m in the leaves task.

    contrastEnvelope = 0.5 + 0.5 * sin(2 * pi * freqHz * t);

    barColorA = midColor + contrastEnvelope * (barColorHigh - midColor);
    barColorB = midColor + contrastEnvelope * (barColorLow  - midColor);
end
