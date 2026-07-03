function EyeTracking(subjectNumber,blockNumber,status)
%{
This function does the eye tracking for Gazepoint as well as SMI eye
tracker.
Parameter(s):
task : Specify 'WMC' or 'ADC' for WM Capacity Task and ADC task respectively
subjectNumber : subject Number as integer
block Number : Block Number as integer
status : 'start' or 'stop'
        'start' starts the calibration and eye-data collection.
        'stop' stops the data collection and saves the data.

Created on : Friday, 15th June, 2018
Compiled by: Sanchit Gupta using the pre-existing code written by Abhijit
and Suhas

Edits
16th August, 2018 : Changed appropriately to suit my task design
%}

% Initialize the eye tracker type
eye_tracker_type = 'SMI';

%% Some important parameters
% Gazepoint Variables
ip_address = '10.0.0.1'; port_no = 4243; typeCal = 9;
% SMI Variables
SMI_IP = '10.0.0.3'; Host_IP = '10.0.0.1';

%% Eye tracker setup instructions
disp('check');

if strcmp(eye_tracker_type,'Gazepoint')
    
    [client_socket] = cog_start_gazepoint(ip_address, port_no);
    start_val = 1;
    cog_startstop_gazepoint_send_data(client_socket, start_val);
    
elseif strcmp(eye_tracker_type,'SMI')
    
    [pCalibrationData, pSystemInfoData, pAccuracyData, libraryname] = cog_SMI_initializations();
    
    SMI_connected = cog_SMI_setup_connection(SMI_IP, Host_IP, pSystemInfoData, libraryname);
end
%%
switch status
    case 'start' % Start eye-tracking calibration and data recording
        %         [window, windowRect] = Screen('OpenWindow',screenNumber,[128 128 128]);
        %         if exist('window', 'var')
        %             black = BlackIndex(window); white = WhiteIndex(window);gray = round(white/2);
        %         else
        %             black = 0; white = 255;gray = white/2;
        %         end
        %         Screen('Flip', window);
        %         MonitorFlipInterval = Screen('GetFlipInterval', window);
        %         ScreenRefRate = round(1/MonitorFlipInterval);
        %         Screen('TextSize', window, 40);
        %         topPriorityLevel = MaxPriority(window);
        %         [screenXpixels, screenYpixels] = Screen('WindowSize', window);
        %         % [xCenter, yCenter] = RectCenter(windowRect);
        %         xCenter = screenXpixels/2; yCenter  = screenYpixels/2;
        %         xc = xCenter; yc = yCenter;
        %
        %         % Change the blend function to draw an antialiased fixation point
        %         % in the centre of the screen
        %         Screen('BlendFunction', window, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');
        %
        %         Screen('TextSize', window, 28);
        %         DrawFormattedText(window, 'Press ''Spacebar'' to Begin Calibration. Any Other Key To Skip.', 'center', 'center', black);
        %         Screen('Flip', window);
        %         [secs, keyCode0, deltaSecs] = KbStrokeWait;
        %         Screen('close',window);
        
        if strcmp(eye_tracker_type,'Gazepoint')
            %81 is ASCII value for Q. Press Q again will recalibrate the block
            if find(keyCode0 == 1) == 81
                hit = 0;
                while hit == 0
                    [client_socket] = cog_start_gazepoint_calibration(client_socket,typeCal);
                    [secs, keyCode, deltaSecs] = KbStrokeWait;
                    if find(keyCode == 1) ~= 81
                        hit = 1;
                    end
                end
            end
        elseif strcmp(eye_tracker_type,'SMI')
            recalib = input('Do you want to calibrate? (Y/N)?','s');
            while ~(strcmpi(recalib,'Y')||strcmpi(recalib,'N'))
                recalib = input('Do you want to calibrate? (Y/N)?','s');
            end
            while strcmpi(recalib, 'Y')
                
                cog_SMI_calibration(libraryname, pCalibrationData, pAccuracyData);
                
                pause(3);
                
                recalib = input('Do you want to recalibrate? (Y/N)?','s');
                while ~(strcmpi(recalib,'Y')||strcmpi(recalib,'N'))
                    recalib = input('Do you want to recalibrate? (Y/N)?','s');
                end
                
                pause(2);
                fprintf('recalib: %s\n', recalib);
                
            end
            
            % clear recording buffer
            calllib(libraryname, 'iV_ClearRecordingBuffer');
            
        end
    case 'stop' % Stop Recording Eye-tracking data
        dt = datestr(now,'mmmm_dd_yyyy_HH_MM_SS');
        if strcmp(eye_tracker_type,'Gazepoint')
            eyeTrackerData2{run}{tr} = DataStringArray;
            eyeTrackerData{tr} = DataStringArray;
        elseif strcmp(eye_tracker_type,'SMI')
            % save recorded data
            
            ovr = int32(1);
            disp ('Saving Data');
            user = 'A';
            eyeTrackingDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'data', 'eyetracking');
            if ~exist(eyeTrackingDir, 'dir')
                mkdir(eyeTrackingDir);
            end
            idfFilename = fullfile(eyeTrackingDir, sprintf('RT_S%d_B%d_%s.idf',subjectNumber,blockNumber,dt));
            description = fullfile(eyeTrackingDir, sprintf('RT_S%d_B%d__%s',subjectNumber,blockNumber,dt));
            ret = calllib(libraryname, 'iV_SaveData', idfFilename, description, user, ovr);
        end
end

end

