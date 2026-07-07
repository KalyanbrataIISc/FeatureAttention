function color = lookupNfColor(lut, nfValue)
% lookupNfColor  Fast per-frame replacement for computeNfLeafColor.m: given
% a lookup table from buildNfColorLut.m, clips nfValue to [0, 1] and rounds
% to the nearest precomputed row (default lutSize of 1001 keeps the
% quantization step far below any perceptible color difference) - just a
% clip and an array index, not the CIELAB math itself.

    lutSize = size(lut, 1);
    nfClipped = max(0, min(1, nfValue));
    idx = 1 + round(nfClipped * (lutSize - 1));
    color = lut(idx, :);
end
