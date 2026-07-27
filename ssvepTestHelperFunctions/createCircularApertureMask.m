function apertureMaskTexture = createCircularApertureMask(window, diameterPx, radiusPx, maskColor, edgeSoftnessPx)
% createCircularApertureMask  Builds a diameterPx x diameterPx RGBA texture
% that is fully transparent inside radiusPx of its center and opaque
% maskColor outside it (with a linear alpha ramp edgeSoftnessPx pixels wide
% at the boundary, so the circle edge isn't hard-aliased). Drawing this on
% top of a plain rectangular grating leaves only a circular patch of it
% visible - built once here, not per frame, since the aperture geometry
% never changes across the block.

    [gridX, gridY] = meshgrid(1:diameterPx, 1:diameterPx);
    centerXY = diameterPx / 2;
    distFromCenter = sqrt((gridX - centerXY) .^ 2 + (gridY - centerXY) .^ 2);
    maskAlpha = uint8(255 * min(1, max(0, (distFromCenter - radiusPx) / edgeSoftnessPx)));

    maskImage = zeros(diameterPx, diameterPx, 4, 'uint8');
    maskImage(:, :, 1) = maskColor(1);
    maskImage(:, :, 2) = maskColor(2);
    maskImage(:, :, 3) = maskColor(3);
    maskImage(:, :, 4) = maskAlpha;

    apertureMaskTexture = Screen('MakeTexture', window, maskImage);
end
