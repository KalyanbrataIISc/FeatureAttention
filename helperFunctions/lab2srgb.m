function srgb = lab2srgb(lab)
% lab2srgb  Converts CIELAB (1x3: [L, a, b], D65 white point) back to sRGB
% (1x3, each channel 0-255) - the inverse of srgb2lab.m. Result is clipped
% to [0, 255]: a straight-line path in Lab space between two in-gamut sRGB
% colors can briefly stray outside the sRGB gamut, so this guards against
% out-of-range values reaching Screen('FillPoly', ...).

    whitePoint = [95.047, 100.0, 108.883];
    L = lab(1); a = lab(2); b = lab(3);

    fy = (L + 16) / 116;
    fx = fy + a / 500;
    fz = fy - b / 200;
    f = [fx, fy, fz];

    delta = 6/29;
    fMask = f > delta;
    t = zeros(1, 3);
    t(fMask) = f(fMask) .^ 3;
    t(~fMask) = 3 * delta^2 * (f(~fMask) - 4/29);
    xyz = t .* whitePoint;

    Minv = [ 3.2404542, -1.5371385, -0.4985314; ...
            -0.9692660,  1.8760108,  0.0415560; ...
             0.0556434, -0.2040259,  1.0572252];
    linear = (Minv * (xyz(:) / 100))';

    s = zeros(1, 3);
    lowMask = linear <= 0.0031308;
    s(lowMask) = 12.92 * linear(lowMask);
    s(~lowMask) = 1.055 * linear(~lowMask) .^ (1/2.4) - 0.055;

    srgb = max(0, min(255, s * 255));
end
