function leaves = updateLeafLanes(leaves, fieldRect)
% updateLeafLanes  Advances one frame for the fixed-path motion built by
% initLeafLanes.m: every leaf moves by its own constant velocity and wraps
% around the field edges. Nothing ages, nothing respawns, nothing is checked
% for collisions - the placement guarantees separation for all time, which
% is the whole point of the scheme.
%
% Contrast updateLeaves.m, which respawns a leaf whenever its lifetime
% expires, it leaves the field, or it drifts within minSeparationPx of
% another leaf. That is what makes leaves visibly appear and disappear;
% here the leaf count on screen is constant and every path is continuous.
%
% A leaf straddling an edge is a single leaf occupying both sides at once.
% Draw it with drawLeavesWrapped.m, which paints the wrapped copies, so it
% slides across the boundary instead of popping from one edge to the other.

    Wf = fieldRect(3) - fieldRect(1);
    Hf = fieldRect(4) - fieldRect(2);

    leaves.x = mod(leaves.x + leaves.vx - fieldRect(1), Wf) + fieldRect(1);
    leaves.y = mod(leaves.y + leaves.vy - fieldRect(2), Hf) + fieldRect(2);
end
