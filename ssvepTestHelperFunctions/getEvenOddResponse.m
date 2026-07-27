function [validResponse, participantResponse, reactionTime] = getEvenOddResponse( ...
    runningOnMac, cedrus, oddKey, evenKey, responseOnsetTime)
% getEvenOddResponse  Checks for a 2-alternative even/odd response: Cedrus
% Left(3)=Odd, Right(5)=Even on Windows; left/right arrow keys on mac.
% reactionTime is measured from responseOnsetTime in both cases.

    validResponse = false;
    participantResponse = 'missed';
    reactionTime = NaN;

    cedrusLeftButton  = 3; % Odd
    cedrusRightButton = 5; % Even

    if ~runningOnMac
        [button, responseEventTimeMs, ohhItIsPressed] = cedrus.getpress();
        if ohhItIsPressed
            switch button
                case cedrusLeftButton
                    participantResponse = 'odd';
                    validResponse = true;
                case cedrusRightButton
                    participantResponse = 'even';
                    validResponse = true;
            end
            if validResponse
                reactionTime = responseEventTimeMs / 1000;
            end
        end
    else
        [keyIsDown, ~, keyCode] = KbCheck(-1);
        if keyIsDown && keyCode(oddKey)
            participantResponse = 'odd';
            validResponse = true;
        elseif keyIsDown && keyCode(evenKey)
            participantResponse = 'even';
            validResponse = true;
        end
        if validResponse
            reactionTime = GetSecs - responseOnsetTime;
        end
    end
end
