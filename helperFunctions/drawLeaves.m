function drawLeaves(window, leaves, flock1InnerShape, flock1OuterShape, flock2InnerShape, flock2OuterShape, ...
    flock1FillColor, flock2FillColor, flock1BorderColor, flock2BorderColor)
% drawLeaves  Draws every leaf for the current frame: a slightly larger
% "border" polygon first (SSVEP-flicker color), then the true-sized leaf
% polygon on top (flock fill color). flock*InnerShape/flock*OuterShape
% are Nx2 vertex arrays centered on the origin (from createLeafShape),
% already oriented for that flock's pointing direction this trial.

    numLeaves = numel(leaves.x);
    for i = 1:numLeaves
        leafPosition = [leaves.x(i), leaves.y(i)];
        if leaves.flockID(i) == 1
            outerVertices = bsxfun(@plus, flock1OuterShape, leafPosition);
            innerVertices = bsxfun(@plus, flock1InnerShape, leafPosition);
            fillColor = flock1FillColor;
            borderColor = flock1BorderColor;
        else
            outerVertices = bsxfun(@plus, flock2OuterShape, leafPosition);
            innerVertices = bsxfun(@plus, flock2InnerShape, leafPosition);
            fillColor = flock2FillColor;
            borderColor = flock2BorderColor;
        end

        Screen('FillPoly', window, borderColor, outerVertices);
        Screen('FillPoly', window, fillColor, innerVertices);
    end
end
