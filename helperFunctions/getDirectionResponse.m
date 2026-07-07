function [validResponse, participantResponse, reactionTime] = getDirectionResponse( ...
    runningOnMac, cedrus, leftKey, rightKey, upKey, downKey, responseOnsetTime)
% getDirectionResponse  Checks for a 4-direction response: Cedrus button
% box (Up=1, Right=5, Left=3, Down=6; Middle=4 unused) on Windows, arrow
% keys on mac. reactionTime is measured from responseOnsetTime (the cue
% onset timestamp) in both cases.

    validResponse = false;
    participantResponse = 'missed';
    reactionTime = NaN;

    cedrusUpButton = 1;
    cedrusRightButton = 5;
    cedrusLeftButton = 3;
    cedrusDownButton = 6;

    if ~runningOnMac
        [button, responseEventTimeMs, ohhItIsPressed] = cedrus.getpress();
        if ohhItIsPressed
            switch button
                case cedrusUpButton
                    participantResponse = 'up';
                    validResponse = true;
                case cedrusRightButton
                    participantResponse = 'right';
                    validResponse = true;
                case cedrusLeftButton
                    participantResponse = 'left';
                    validResponse = true;
                case cedrusDownButton
                    participantResponse = 'down';
                    validResponse = true;
            end
            if validResponse
                reactionTime = responseEventTimeMs / 1000;
            end
        end
    else
        [keyIsDown, ~, keyCode] = KbCheck(-1);
        if keyIsDown && keyCode(upKey)
            participantResponse = 'up';
            validResponse = true;
        elseif keyIsDown && keyCode(downKey)
            participantResponse = 'down';
            validResponse = true;
        elseif keyIsDown && keyCode(leftKey)
            participantResponse = 'left';
            validResponse = true;
        elseif keyIsDown && keyCode(rightKey)
            participantResponse = 'right';
            validResponse = true;
        end
        if validResponse
            reactionTime = GetSecs - responseOnsetTime;
        end
    end
end
