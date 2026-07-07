function lut = buildNfColorLut(labNeutral, labTarget, maxDeltaE, baselineDeltaE, lutSize)
% buildNfColorLut  Precomputes an (lutSize x 3) sRGB lookup table for
% computeNfLeafColor.m's mapping, indexed by nfValue linearly spaced over
% [0, 1] (row 1 = nf 0, row lutSize = nf 1).
%
% Call this once outside any per-frame loop - it exists specifically so
% the frame loop can look up a color by plain array indexing (see
% lookupNfColor.m) instead of running the CIELAB conversion math (several
% non-integer power/exponent calls per color - see srgb2lab.m/lab2srgb.m -
% measurably heavier than sin/cos-style per-frame work) on every single
% displayed frame. Doing that math every frame (twice - once per flock)
% was adding enough delay before each flip to measurably drift the SSVEP
% tagging frequency, which breaks phase-locked power spectral analysis.

    lut = zeros(lutSize, 3);
    for i = 1:lutSize
        nfValue = (i - 1) / (lutSize - 1);
        lut(i, :) = computeNfLeafColor(labNeutral, labTarget, maxDeltaE, nfValue, baselineDeltaE);
    end
end
