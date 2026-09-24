function bci_send_triggers(name_of_trigger)
% paraport is ignored, we now use UDP to localhost:5007
import java.net.DatagramSocket
import java.net.DatagramPacket
import java.net.InetAddress

switch name_of_trigger
    case 'pause_off'
        pval=254;
    case 'pause_on'
        pval=253;
    case 'fixation_leftCue'
        pval=11;
    case 'fixation_rightCue'
        pval=12;
    case 'spatialCue'
        pval=15;
    case 'trialstart'
        pval=20;
    case 'trialstart_left'
        pval=20;
    case 'trialstart_right'
        pval=21;
    case 'cueonset'
        pval=45;
    % case 'baseline_set'
    %     pval=25;
    case 'prime_left'
        pval=26;
    case 'prime_right'
        pval=27;
    case 'trial_cutoffset'
        pval= 5;
    case 'trialstop'
        pval=30;
    case 'response'
        pval=40;
    case 'reset'
        pval=0;
    case 'success'
        pval=50;
    case 'failure'
        pval=60;
    case 'blockstop'
        pval=25;
    otherwise
        error('ERROR: The name of the trigger mentioned is incorrect')
end
% Send the trigger via UDP to the Python TCP server (eeg_tcp_server.py)
% We use Java so it works natively on all MATLAB versions without requiring the Instrument Control Toolbox.
try
    socket = DatagramSocket();
    address = InetAddress.getByName('127.0.0.1');
    msg = int8(num2str(pval));
    packet = DatagramPacket(msg, length(msg), address, 5007);
    socket.send(packet);
    socket.close();
catch ME
    warning('Failed to send UDP trigger: %s', ME.message);
end
end
