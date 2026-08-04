function [xExtentPx, yExtentPx] = leafExtentsForDirection(pointDirection, leafLengthPx, leafWidthPx)
% leafExtentsForDirection  Axis-aligned bounding-box extents of a leaf whose
% point faces pointDirection. createLeafShape.m lays the leaf out with
% leafLengthPx along the pointing axis and leafWidthPx across it, so a leaf
% pointing left/right is wide in x and narrow in y, and vice versa.
%
% Pass the OUTER dimensions (leaf plus 2*leafBorderThicknessPx on each axis)
% when what you need is the footprint that must not overlap another leaf's -
% the SSVEP border polygon is the larger of the two drawn per leaf.
%
% Used by initLeafLanes.m/verifyLeafLanes.m to size lanes and to test
% overlap: two axis-aligned leaves are disjoint iff their centre separation
% exceeds the summed half-extents on at least one axis.

    switch pointDirection
        case {'left', 'right'}
            xExtentPx = leafLengthPx;
            yExtentPx = leafWidthPx;
        case {'up', 'down'}
            xExtentPx = leafWidthPx;
            yExtentPx = leafLengthPx;
        otherwise
            error('leafExtentsForDirection:invalidDirection', ...
                'Unknown direction: %s', pointDirection);
    end
end
