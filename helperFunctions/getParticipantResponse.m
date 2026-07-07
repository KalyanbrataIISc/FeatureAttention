function [validResponse, participantResponse, reactionTime] = getParticipantResponse( ...
    runningOnMac, cedrus, leftKey, rightKey, upKey, downKey, spaceKey, responseOnsetTime)

    validResponse = false;
    participantResponse = 'missed';
    reactionTime = NaN;

    if ~runningOnMac
        [button, responseEventTimeMs, ohhItIsPressed] = cedrus.getpress();
        if ohhItIsPressed
            if button == 1
                participantResponse = 'left';
                reactionTime = responseEventTimeMs / 1000;
                validResponse = true;
            elseif button == 6
                participantResponse = 'right';
                reactionTime = responseEventTimeMs / 1000;
                validResponse = true;
            elseif button == 4
                participantResponse = 'middle';
                reactionTime = responseEventTimeMs / 1000;
                validResponse = true;
            end
        end
    else
        [keyIsDown, ~, keyCode] = KbCheck(-1);
        if keyIsDown && keyCode(leftKey)
            participantResponse = 'left';
            reactionTime = GetSecs - responseOnsetTime;
            validResponse = true;
        elseif keyIsDown && keyCode(rightKey)
            participantResponse = 'right';
            reactionTime = GetSecs - responseOnsetTime;
            validResponse = true;
        elseif keyIsDown && keyCode(upKey)
            participantResponse = 'up';
            reactionTime = GetSecs - responseOnsetTime;
            validResponse = true;
        elseif keyIsDown && keyCode(downKey)
            participantResponse = 'down';
            reactionTime = GetSecs - responseOnsetTime;
            validResponse = true;
        elseif keyIsDown && keyCode(spaceKey)
            participantResponse = 'space';
            reactionTime = GetSecs - responseOnsetTime;
            validResponse = true;
        end
    end
end
