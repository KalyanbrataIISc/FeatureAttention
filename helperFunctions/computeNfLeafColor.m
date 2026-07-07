function color = computeNfLeafColor(labNeutral, labTarget, maxDeltaE, nfValue, baselineDeltaE)
% computeNfLeafColor  Returns an sRGB (0-255) leaf fill color, interpolated
% in CIELAB space from labNeutral toward labTarget in proportion to nfValue
% - the real-time SSVEP lateralisation in the cue-consistent direction (see
% readNFValue) - starting from a fixed baselineDeltaE rather than from zero.
%
% Interpolation is done by CIELAB Delta E (perceived color difference) as
% the actual axis, not by a raw blend fraction: a rig test showed the same
% RGB-blend-fraction "baseline reveal" looked clearly more intense for one
% flock's color than the other's, since equal RGB distance does not mean
% equal perceived distance across different hues. Driving by Delta E
% instead means the fixed baseline reveal - and the whole live-NF reveal
% growth on top of it - looks equally intense regardless of which of
% colorC1/colorC2 is passed in as labTarget.
%
% labNeutral/labTarget/maxDeltaE (= norm(labTarget-labNeutral)) are
% precomputed once by the caller via srgb2lab.m (they never change during
% the experiment) rather than reconverted every call/frame.
%
% baselineDeltaE is the deliberate, subtle reveal applied right at cue
% onset: without it, nfValue<=0 would render both flocks identically at
% labNeutral and the participant would have no way to tell which flock is
% which to start attending to it. nfValue is clipped to [0, 1] first
% (nfValue<=0 renders at exactly baselineDeltaE of perceived difference,
% never less; nfValue>=1 renders at exactly labTarget, i.e. maxDeltaE).

    nfClipped = max(0, min(1, nfValue));
    targetDeltaE = baselineDeltaE + nfClipped * (maxDeltaE - baselineDeltaE);
    t = max(0, min(1, targetDeltaE / maxDeltaE));
    labColor = labNeutral + t * (labTarget - labNeutral);
    color = lab2srgb(labColor);
end
