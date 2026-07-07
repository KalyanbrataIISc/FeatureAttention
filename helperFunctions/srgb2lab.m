function lab = srgb2lab(srgb)
% srgb2lab  Converts an sRGB color (1x3, each channel 0-255, D65 white
% point) to CIELAB (1x3: [L, a, b]). Standard sRGB->linear->XYZ->Lab
% pipeline (see e.g. Bruce Lindbloom's reference formulas) - used so
% computeNfLeafColor.m can interpolate leaf reveal color by *perceived*
% color difference (CIELAB Delta E) rather than raw RGB distance, which is
% what actually varies non-uniformly across hues.

    s = double(srgb) / 255;
    linear = zeros(1, 3);
    lowMask = s <= 0.04045;
    linear(lowMask) = s(lowMask) / 12.92;
    linear(~lowMask) = ((s(~lowMask) + 0.055) / 1.055) .^ 2.4;

    M = [0.4124564, 0.3575761, 0.1804375; ...
         0.2126729, 0.7151522, 0.0721750; ...
         0.0193339, 0.1191920, 0.9503041];
    xyz = (M * linear(:))' * 100;

    whitePoint = [95.047, 100.0, 108.883];
    t = xyz ./ whitePoint;
    delta = 6/29;
    fMask = t > delta^3;
    ft = zeros(1, 3);
    ft(fMask) = t(fMask) .^ (1/3);
    ft(~fMask) = t(~fMask) / (3 * delta^2) + 4/29;

    L = 116 * ft(2) - 16;
    a = 500 * (ft(1) - ft(2));
    b = 200 * (ft(2) - ft(3));
    lab = [L, a, b];
end
