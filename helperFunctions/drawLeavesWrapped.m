function drawLeavesWrapped(window, leaves, fieldRect, maxLeafRadiusPx, ...
    flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
    flock1FillColor, flock2FillColor, flock1BorderColor, flock2BorderColor)
% drawLeavesWrapped  Like drawLeaves.m, but for the wrapping motion built by
% initLeafLanes.m/updateLeafLanes.m: a leaf whose body crosses a field edge
% is painted on both sides, so it slides across the boundary instead of
% popping from one edge to the other.
%
% Without this a wrapping leaf briefly vanishes at one edge before appearing
% at the other, which would reintroduce exactly the appear/disappear
% behaviour the fixed-path scheme exists to remove - and would make the
% on-screen leaf count dip. With it, the count is genuinely constant.
%
% maxLeafRadiusPx is how far the drawn polygon can reach from the leaf's
% centre (half the diagonal of the outer bounding box is a safe value); it
% decides when a leaf is close enough to an edge to need its mirror copy.

    Wf = fieldRect(3) - fieldRect(1);
    Hf = fieldRect(4) - fieldRect(2);
    numLeaves = numel(leaves.x);

    for i = 1:numLeaves
        if leaves.flockID(i) == 1
            outerShape = flock1OuterShape;
            innerShape = flock1InnerShape;
            fillColor = flock1FillColor;
            borderColor = flock1BorderColor;
        else
            outerShape = flock2OuterShape;
            innerShape = flock2InnerShape;
            fillColor = flock2FillColor;
            borderColor = flock2BorderColor;
        end

        % Only the edges this leaf actually overhangs need a mirror copy.
        xOffsets = 0;
        if leaves.x(i) - maxLeafRadiusPx < fieldRect(1)
            xOffsets = [xOffsets, Wf]; %#ok<AGROW>
        elseif leaves.x(i) + maxLeafRadiusPx > fieldRect(3)
            xOffsets = [xOffsets, -Wf]; %#ok<AGROW>
        end
        yOffsets = 0;
        if leaves.y(i) - maxLeafRadiusPx < fieldRect(2)
            yOffsets = [yOffsets, Hf]; %#ok<AGROW>
        elseif leaves.y(i) + maxLeafRadiusPx > fieldRect(4)
            yOffsets = [yOffsets, -Hf]; %#ok<AGROW>
        end

        for xo = xOffsets
            for yo = yOffsets
                leafPosition = [leaves.x(i) + xo, leaves.y(i) + yo];
                Screen('FillPoly', window, borderColor, bsxfun(@plus, outerShape, leafPosition));
                Screen('FillPoly', window, fillColor, bsxfun(@plus, innerShape, leafPosition));
            end
        end
    end
end
