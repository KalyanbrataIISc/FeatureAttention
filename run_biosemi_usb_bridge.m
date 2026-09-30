function run_biosemi_usb_bridge(feedbackFile, serialPort, tcpPort)
% P-SYSTEM: carry tablet markers and acquisition NF over one ADB USB tunnel.
% MATLAB R2015 compatible. Run Start-BiosemiUsb.ps1 in a second terminal.
% First identify the trigger adapter on P with Register-BiosemiTriggerAdapter.ps1.
% Then: run_biosemi_usb_bridge('D:\Public\FeatureAttention\nf.txt')
% feedbackFile must resolve on P to the file written by the A system.

if nargin < 1 || isempty(feedbackFile)
    feedbackFile = 'D:\Public\FeatureAttention\nf.txt';
end
if nargin < 2 || isempty(serialPort)
    serialPort = 'auto';
end
if nargin < 3 || isempty(tcpPort)
    tcpPort = 5010;
end
if tcpPort < 1 || tcpPort > 65535 || tcpPort ~= floor(tcpPort)
    error('TCP port must be an integer from 1 to 65535.');
end
if ~exist(feedbackFile, 'file')
    error('P cannot read the shared A-system NF file: %s', feedbackFile);
end

if strcmpi(serialPort, 'auto')
    if ~ispc
        error('Automatic trigger-port detection requires Windows on the P system.');
    end
    resolver = fullfile(fileparts(mfilename('fullpath')), ...
        'Register-BiosemiTriggerAdapter.ps1');
    if ~exist(resolver, 'file')
        error('Trigger-adapter resolver is missing: %s', resolver);
    end
    [status, result] = system(sprintf( ...
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s" -Resolve', ...
        resolver));
    serialPort = strtrim(result);
    if status ~= 0 || isempty(regexp(serialPort, '^COM[1-9][0-9]*$', 'once'))
        error(['Could not identify the Biosemi trigger adapter. %s ' ...
            'On P, run powershell -ExecutionPolicy Bypass -File ' ...
            '.\Register-BiosemiTriggerAdapter.ps1 -Learn before the experiment.'], ...
            strtrim(result));
    end
end

% Windows has already resolved the registered device. Opening the port below
% verifies access without requiring the optional instrhwinfo function.
paraport = serial(serialPort, 'BaudRate', 115200, 'DataBits', 8, ...
    'StopBits', 1, 'Parity', 'none', 'FlowControl', 'none', 'Timeout', 1); %#ok<SERIAL>
try
    fopen(paraport);
catch ME
    delete(paraport);
    rethrow(ME);
end
server = [];
client = [];
try
    server = java.net.ServerSocket(tcpPort, 1, java.net.InetAddress.getByName('127.0.0.1'));
catch ME
    fclose(paraport);
    delete(paraport);
    rethrow(ME);
end
cleanup = onCleanup(@() closeBridge(paraport, server)); %#ok<NASGU>
server.setSoTimeout(1000);
fprintf('Biosemi USB bridge listening on P-system loopback port %d.\n', tcpPort);
fprintf('Trigger output: %s. NF input: %s\n', serialPort, feedbackFile);
fprintf('Press Ctrl+C to stop after the experiment.\n');

while true
    try
        client = server.accept();
    catch ME
        if ~isempty(strfind(lower(ME.message), 'timed out')) %#ok<STREMP>
            continue;
        end
        rethrow(ME);
    end
    client.setTcpNoDelay(true);
    client.setKeepAlive(true);
    client.setSoTimeout(10);
    input = client.getInputStream();
    output = client.getOutputStream();
    fprintf('Tablet connected. Waiting for marker lines and NF file updates.\n');
    line = '';
    trialOpen = false;
    serialFailed = false;
    lastRecord = uint8([]);
    lastValues = [NaN NaN NaN];
    lastTabletCount = NaN;
    lastProbeClock = tic;
    lastReadClock = tic;
    lastSendClock = tic;
    lastReportClock = tic;
    lastChangedClock = tic;
    try
        while true
            % available()==0 also occurs after a peer closes its socket.
            % A bounded read checks EOF even if trial feedback has stopped.
            while input.available() > 0 || toc(lastProbeClock) >= 0.1
                lastProbeClock = tic;
                try
                    byte = input.read();
                catch readError
                    if ~isempty(strfind(lower(readError.message), 'timed out')) %#ok<STREMP>
                        break;
                    end
                    rethrow(readError);
                end
                if byte < 0
                    error('Tablet connection closed.');
                end
                if byte == 10
                    if strcmp(line, 'BYE')
                        error('Tablet closed the USB session.');
                    end
                    if length(line) > 2 && strcmp(line(1:2), 'R ')
                        lastTabletCount = str2double(line(3:end));
                        line = '';
                        continue;
                    end
                    value = str2double(line);
                    if ~isempty(line) && length(line) <= 3 && ...
                            ~isnan(value) && value == floor(value) && ...
                            value >= 0 && value <= 255
                        % Exactly one numeric trigger byte; no name lookup.
                        writeTriggerByte(paraport, value);
                        if value == 20 || value == 21
                            trialOpen = true;
                            lastChangedClock = tic;
                        elseif value == 30
                            trialOpen = false;
                        end
                        fprintf('Trigger %d -> %s\n', value, serialPort);
                    else
                        warning('Discarded invalid tablet marker: %s', line);
                    end
                    line = '';
                elseif byte ~= 13
                    line = [line char(byte)]; %#ok<AGROW>
                    if length(line) > 64
                        line = '';
                    end
                end
            end

            % nf.txt is three little-endian IEEE-754 doubles. Forward the
            % exact bytes only when a complete, changed record is available.
            if toc(lastReadClock) >= 0.01
                lastReadClock = tic;
                fid = fopen(feedbackFile, 'rb', 'ieee-le');
                if fid ~= -1
                    raw = fread(fid, 24, 'uint8=>uint8');
                    fclose(fid);
                    if numel(raw) == 24
                        values = typecast(raw(:)', 'double');
                        if all(isfinite(values)) && ...
                                (isempty(lastRecord) || ~isequal(raw, lastRecord))
                            output.write(typecast(raw(:)', 'int8'), 0, 24);
                            output.flush();
                            lastRecord = raw;
                            lastValues = values;
                            lastSendClock = tic;
                            lastChangedClock = tic;
                        end
                    end
                end
            end
            % An idle heartbeat makes a removed USB cable observable even
            % between trials, without fabricating fresh NF during a trial.
            if ~trialOpen && ~isempty(lastRecord) && toc(lastSendClock) >= 1
                output.write(typecast(lastRecord(:)', 'int8'), 0, 24);
                output.flush();
                lastSendClock = tic;
            end
            if trialOpen && toc(lastReportClock) >= 1
                fprintf('NF -> tablet: [%.6f %.6f], file count %.0f, tablet ACK %.0f, newest %.1f s ago\n', ...
                    lastValues(1), lastValues(2), lastValues(3), lastTabletCount, toc(lastChangedClock));
                lastReportClock = tic;
            end
            pause(0.002);
        end
    catch ME
        serialFailed = strcmp(ME.identifier, 'BiosemiUsbBridge:SerialWriteFailed');
        fprintf('Tablet session ended: %s\n', ME.message);
    end
    if trialOpen
        % A must not stay in an open NF trial after a USB disconnect.
        try
            writeTriggerByte(paraport, 30);
            fprintf('USB interruption: sent trial stop 30 to %s.\n', serialPort);
        catch ME
            serialFailed = true;
            warning('Could not send interruption trial stop: %s', ME.message);
        end
    end
    try
        client.close();
    catch
    end
    client = [];
    if serialFailed
        error('BiosemiUsbBridge:SerialDisconnected', ...
            ['Trigger output on %s failed. Stop the block and check A. ' ...
            'Reconnect the trigger adapter and restart this bridge to detect its current COM port.'], ...
            serialPort);
    end
end
end

function writeTriggerByte(paraport, value)
try
    % Legacy serial fwrite (including R2015b) has no output argument.
    % Check its ValuesSent counter after a synchronous one-byte write.
    before = get(paraport, 'ValuesSent');
    fwrite(paraport, uint8(value), 'uint8', 'sync');
    count = get(paraport, 'ValuesSent') - before;
catch ME
    error('BiosemiUsbBridge:SerialWriteFailed', 'Could not write trigger %d: %s', value, ME.message);
end
if count ~= 1
    error('BiosemiUsbBridge:SerialWriteFailed', 'Trigger %d was not fully written to the serial port.', value);
end
end
function closeBridge(paraport, server)
try
    if ~isempty(server), server.close(); end
catch
end
try
    if strcmp(paraport.Status, 'open'), fclose(paraport); end
    delete(paraport);
catch
end
end
