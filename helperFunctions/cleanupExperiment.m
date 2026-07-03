function cleanupExperiment(runningOnMac, eyeTrackingStopped, participantInfo, blockInfo, paraport)
    global cedrus;

    Priority(0);
    ShowCursor;
    sca;

    if ~runningOnMac
        try
            if ~eyeTrackingStopped
                EyeTracking(str2double(participantInfo),str2double(blockInfo),'stop');
            end
        catch
        end

        if exist('paraport','var') && ~isempty(paraport)
            try
                cog_send_triggers(paraport, 'reset');
                fclose(paraport);
                delete(paraport);
            catch
            end
        end

        if isstruct(cedrus) && isfield(cedrus, 'close')
            try
                cedrus.close();
            catch
            end
        end
    end
end
