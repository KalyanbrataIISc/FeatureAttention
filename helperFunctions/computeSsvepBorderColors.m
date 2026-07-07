function [flock1BorderColor, flock2BorderColor] = computeSsvepBorderColors( ...
    ssvepFrame, interFrameInterval, freqC1Hz, freqC2Hz, colorLow, colorHigh)
% computeSsvepBorderColors  Computes the current border color for each
% flock from a continuous, trial-elapsed-time sinusoid, so every leaf in
% a flock (sharing the same frequency and time base) is phase-locked to
% the others with no per-leaf bookkeeping.

    t = (ssvepFrame - 1) * interFrameInterval;
    lum1 = 0.5 + 0.5 * sin(2 * pi * freqC1Hz * t);
    lum2 = 0.5 + 0.5 * sin(2 * pi * freqC2Hz * t);
    flock1BorderColor = colorLow + lum1 * (colorHigh - colorLow);
    flock2BorderColor = colorLow + lum2 * (colorHigh - colorLow);
end
