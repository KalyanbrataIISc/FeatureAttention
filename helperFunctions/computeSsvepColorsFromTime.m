function [flock1BorderColor, flock2BorderColor] = computeSsvepColorsFromTime( ...
    t, freqC1Hz, freqC2Hz, colorLow, colorHigh)
% computeSsvepColorsFromTime  Computes the current border color for each
% flock from a continuous sinusoid evaluated at an actual-elapsed-time
% value t (seconds since trial start), rather than a frame-count times a
% fixed nominal refresh interval (contrast computeSsvepBorderColors.m).
%
% Callers should derive t from real Screen('Flip') VBL timestamps
% (measured wall-clock time), not from an incrementing frame counter: a
% frame-counter-based time base assumes every loop iteration corresponds
% to exactly one real display refresh, which silently and permanently
% detunes the driving frequency below its nominal value whenever the GPU
% falls behind and frames are dropped/delayed (the counter keeps advancing
% at the nominal rate while real time advances slower). Deriving t from the
% measured VBL instead means a dropped frame only costs a single bounded
% phase correction on the very next frame, rather than an ever-growing,
% unrecovered frequency error.

    lum1 = 0.5 + 0.5 * sin(2 * pi * freqC1Hz * t);
    lum2 = 0.5 + 0.5 * sin(2 * pi * freqC2Hz * t);
    flock1BorderColor = colorLow + lum1 * (colorHigh - colorLow);
    flock2BorderColor = colorLow + lum2 * (colorHigh - colorLow);
end
