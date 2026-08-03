function [validResponse, participantResponse, reactionTime] = getColorResponse( ...
    runningOnMac, cedrus, leftKey, rightKey, leftLabel, rightLabel, responseOnsetTime)
% getColorResponse  Checks for a 2-alternative color response: Cedrus button
% box (Left = 3, Right = 5; every other button ignored, including Up/Middle/
% Down) on Windows, left/right arrow keys on mac. Used by gameNFv5.m, where
% the participant reports the *color* of the cued flock rather than a
% direction.
%
% The label each side maps to is supplied by the caller (leftLabel /
% rightLabel, e.g. 'orange' / 'blue') rather than hard-coded here, so the
% color-to-button mapping stays visible in the experiment script's
% PARAMETERS block alongside the colors themselves. participantResponse is
% returned as one of those two strings, or 'missed' when nothing valid was
% pressed.
%
% reactionTime is measured from responseOnsetTime (the cue onset timestamp)
% in both cases - on Windows from the Cedrus box's own timer, which the
% caller resets at cue onset.
%
% responseOnsetTime must be a RAW GetSecs value, not a
% getElapsedTime(experimentStartTime) one: the mac branch computes
% GetSecs - responseOnsetTime, so a time already expressed relative to
% experiment start yields roughly "seconds since boot" instead of a
% reaction time. Callers log the relative value to CSV but pass the
% absolute one here (see cueOnsetAbsTime in gameNFv5.m). The Windows branch
% ignores it entirely and uses the Cedrus timer described above.

    validResponse = false;
    participantResponse = 'missed';
    reactionTime = NaN;

    cedrusLeftButton  = 3;
    cedrusRightButton = 5;

    if ~runningOnMac
        [button, responseEventTimeMs, ohhItIsPressed] = cedrus.getpress();
        if ohhItIsPressed
            switch button
                case cedrusLeftButton
                    participantResponse = leftLabel;
                    validResponse = true;
                case cedrusRightButton
                    participantResponse = rightLabel;
                    validResponse = true;
            end
            if validResponse
                reactionTime = responseEventTimeMs / 1000;
            end
        end
    else
        [keyIsDown, ~, keyCode] = KbCheck(-1);
        if keyIsDown && keyCode(leftKey)
            participantResponse = leftLabel;
            validResponse = true;
        elseif keyIsDown && keyCode(rightKey)
            participantResponse = rightLabel;
            validResponse = true;
        end
        if validResponse
            reactionTime = GetSecs - responseOnsetTime;
        end
    end
end
