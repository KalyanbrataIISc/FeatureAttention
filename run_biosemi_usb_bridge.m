function run_biosemi_usb_bridge(feedbackFile, serialPort, tcpPort)
% P-SYSTEM: carry tablet markers and acquisition NF over one ADB USB tunnel.
% MATLAB R2015 compatible. Run Start-BiosemiUsb.ps1 in a second terminal.
% Example: run_biosemi_usb_bridge('X:\FeatureAttention\nf.txt', 'COM9', 5010)
% feedbackFile must resolve on P to the file written by the A system.

if nargin < 1 || isempty(feedbackFile)
    feedbackFile = fullfile(fileparts(mfilename('fullpath')), 'nf.txt');
end
if nargin < 2 || isempty(serialPort)
    serialPort = 'COM9';
end
if nargin < 3 || isempty(tcpPort)
    tcpPort = 5010;
end
if tcpPort < 1 || tcpPort > 65535 || tcpPort ~= floor(tcpPort)
    error('TCP port must be an integer from 1 to 65535.');
end

paraport = serial(serialPort, 'BaudRate', 115200, 'DataBits', 8, ...
    'StopBits', 1, 'Parity', 'none'); %#ok<SERIAL>
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
    input = client.getInputStream();
    output = client.getOutputStream();
    fprintf('Tablet connected. Waiting for marker lines and NF file updates.\n');
    line = '';
    trialOpen = false;
    lastRecord = uint8([]);
    lastReadClock = tic;
    lastSendClock = tic;
    try
        while true
            while input.available() > 0
                byte = input.read();
                if byte < 0
                    error('Tablet connection closed.');
                end
                if byte == 10
                    value = str2double(line);
                    if ~isempty(line) && length(line) <= 3 && ...
                            ~isnan(value) && value == floor(value) && ...
                            value >= 0 && value <= 255
                        % Exactly one numeric trigger byte; no name lookup.
                        fwrite(paraport, uint8(value), 'uint8');
                        if value == 20 || value == 21
                            trialOpen = true;
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
                    if length(line) > 8
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
                            lastRecord = raw;
                            lastSendClock = tic;
                        end
                    end
                end
            end
            % An idle heartbeat makes a removed USB cable observable even
            % between trials, without fabricating fresh NF during a trial.
            if ~trialOpen && ~isempty(lastRecord) && toc(lastSendClock) >= 1
                output.write(typecast(lastRecord(:)', 'int8'), 0, 24);
                lastSendClock = tic;
            end
            pause(0.002);
        end
    catch ME
        fprintf('Tablet session ended: %s\n', ME.message);
    end
    if trialOpen
        % A must not stay in an open NF trial after a USB disconnect.
        try
            fwrite(paraport, uint8(30), 'uint8');
            fprintf('USB interruption: sent trial stop 30 to %s.\n', serialPort);
        catch ME
            warning('Could not send interruption trial stop: %s', ME.message);
        end
    end
    try
        client.close();
    catch
    end
    client = [];
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
