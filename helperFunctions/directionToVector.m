function vector = directionToVector(direction)
% directionToVector  Cardinal direction name to a unit [dx dy] vector in
% screen coordinates (x right, y down).

    switch direction
        case 'up'
            vector = [0 -1];
        case 'down'
            vector = [0 1];
        case 'left'
            vector = [-1 0];
        case 'right'
            vector = [1 0];
        otherwise
            error('directionToVector:invalidDirection', 'Unknown direction: %s', direction);
    end
end
