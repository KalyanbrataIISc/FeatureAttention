function color = computeNfLeafColor(colorNeutral, colorTarget, nfValue, baselineWeight)
% computeNfLeafColor  Interpolates from colorNeutral toward colorTarget, in
% proportion to nfValue - the real-time SSVEP lateralisation in the
% cue-consistent direction (see readNFValue) - starting from a fixed
% baselineWeight rather than from zero. baselineWeight is the deliberate,
% subtle reveal applied right at cue onset: without it, nfValue<=0 would
% render both flocks identically at colorNeutral and the participant would
% have no way to tell which flock is which to start attending to it.
%
% nfValue is clipped to [0, 1] first (nfValue<=0 renders at exactly
% baselineWeight, never below it; nfValue>=1 renders at exactly
% colorTarget), then linearly rescaled into [baselineWeight, 1].

    nfClipped = max(0, min(1, nfValue));
    weight = baselineWeight + nfClipped * (1 - baselineWeight);
    color = colorNeutral + weight * (colorTarget - colorNeutral);
end
