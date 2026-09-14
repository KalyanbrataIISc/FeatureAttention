function[cut_off_init] = RT_acquisition_CCA(varargin) 
% RT_acquisition_CCA - Real - Time Spatial Attention 
% BCI Acquisition Script 
%
% Baseline Strategy(CCA):
%   - Hardware-friendly CCA (HW-CCA) scores with no baseline period.

global run;
run = true;
channels = 41; % set to the same value as in Actiview "Channels sent by TCP" Fs = 128;
Fs = 128;
SSVEP_freq = [19 23];
trial_on = false;

subject_no = 9988;
run_no = 101;
method = 'DSS';

delta = [ 2, 2 ];
deltas = [ 1, 1 ];

cut_off_init = [ 0, 0 ];
cut_off = cut_off_init;

triggers.trial_spatialCue = 11;
triggers.trial_rightCue = 12;
triggers.trial_start = 20;
triggers.trial_stop = 30;
triggers.block_stop = 25;

trial_no = 0;

% Preprocessing Flags 
demean_reref = true;
z_score = false;

assignopts(who, varargin{ : });
warning('off', 'FieldTrip:ft_read_header');
warning('off', 'MATLAB:mkdir:DirectoryExists');
if exist ('ft_warning', 'file')
  ft_warning off;
end

filepath = [pwd '\' sprintf('RT_S%d\\run%d_%s\\',subject_no,run_no,method)];
savepath = filepath;
mkdir(filepath(1:end-1));

script_dir = fileparts(mfilename('fullpath'));
task_dir = fileparts(script_dir);
if ~exist('feedback_file_name', 'var') || isempty(feedback_file_name)
    feedback_file_name = fullfile(task_dir, 'nf.txt');
end

if ~exist('log_file_name', 'var') || isempty(log_file_name)
    log_file_name = fullfile(task_dir, 'nf_logged.csv');
end

% Filtering
Delay = round(Fs/50);

% Ring buffer data
ring_buffer_time = 1; % enter value in seconds
ring_buffer_size = round(Fs*ring_buffer_time) + Delay;

save('data_init');
a=load('DSS_data.mat');  % pnqL1 and pnqL2
pnqL1 = [28 30 32 36 38];       % Right Electrodes
pnqL2 = [15 17 5 7 9];          % Left Electrodes

pnqL1S = [28 30 32 36 38 35 37 39 40 41 26 27 29 31]; % All right Electrodes for SSVEP
pnqL2S = [15 17 5 7 9 6 8 10 11 12 13 14 16 18]; % All left Electrodes for SSVEP
pnqAllS = [pnqL1S, pnqL2S]; % Both SSVEP frequencies read off ALL electrodes together

FB_dist = a.fit_dist';

% Precompute Reference Terms for HW-CCA
% buff_filt is Fs length (1 second). We precompute Y and Cyy_inv once.
n_samples_cca = Fs; 
[Y17, Cyy_inv17] = precompute_reference_terms(17, n_samples_cca, Fs, 1);
[Y19, Cyy_inv19] = precompute_reference_terms(19, n_samples_cca, Fs, 1);

save([filepath sprintf('RT_data_init_S%d_run%d.mat',subject_no,run_no)]);

% fieldtrip initialization

if exist('F:\Real-Time\Toolbox\fieldtrip-20170817', 'dir')
    addpath('F:\Real-Time\Toolbox\fieldtrip-20170817');
elseif exist('C:\Personal_Files\IISc_CogLab\Learning Matlab\eeglab2026.0.0\plugins\Fieldtrip-lite250523', 'dir')
    addpath('C:\Personal_Files\IISc_CogLab\Learning Matlab\eeglab2026.0.0\plugins\Fieldtrip-lite250523');
end

if exist('ft_defaults', 'file')
    ft_defaults;
end

initsample=1;

% Remove initial junk data (mirrors RT_acquisition_8): syncs initsample to
% the live edge of the buffer so stale/backlogged trigger events already
% sitting in the buffer (e.g. left over from a previous run) are never
% (re)processed when this loop starts.
data=ft_read_data('buffer://localhost:1972','begsample',1,'endsample',inf);
initsample=initsample+size(data,2);

prev_samp = initsample;
cut_off = cut_off_init;
total_errors = [];
errors = 0;
cnt = 1;
ring_buffer = zeros(channels, ring_buffer_size);
fb_out_send_all = [];
change_val_all = [];
ring_buffer_all = [];
cut_off_all = [];
fid_log = -1;

% ==============================================================================
% NSK_3: Delta-Normalised Neurofeedback State Variables (Reset each trial)
% ==============================================================================
prev_SSVEP_power = [];

Cue = 0;
data_size_all = [];
i1=1;
i2=1;
wsamp = 0;
while(1)

    try
        event=ft_read_event('buffer://localhost:1972');
        data=ft_read_data('buffer://localhost:1972','begsample',initsample,'endsample',inf);
    catch
        errors = errors + 1;
        continue;
    end
    data=data(1:channels,:);
    initsample=initsample+size(data,2);
    wsamp = wsamp + size(data,2);
    data_size_all = [data_size_all,size(data,2)];
    if size(data,2)<=ring_buffer_size
        ring_buffer = [ ring_buffer(:,size(data,2)+1:end) data];
    else
        ring_buffer = data(:,end-ring_buffer_size+1:end);
    end
    if wsamp<13
        continue
    else
        wsamp = 0;
    end

    total_errors = [total_errors errors];
    errors = 0;

    trig_values = [];
    event_sample = [];
    if ~isempty(event)
        event_select=event(strcmp('stimulus', {event.type}));
        if ~isempty(event_select)
            samples_vec = cell2mat({event_select.sample});
            valid_mask = (samples_vec > prev_samp) & (samples_vec <= initsample);
            trig_values = [event_select(valid_mask).value];
            event_sample = event_select(valid_mask);
        end
    end

    if ~isempty(find(trig_values==triggers.trial_start, 1)) && ~trial_on
        trial_no = trial_no+1;
        prev_samp = event_sample(trig_values==triggers.trial_start).sample;
        disp('1');
        trial_on = true;
        try
            data=ft_read_data('buffer://localhost:1972','begsample',initsample,'endsample',inf);
        catch
            continue;
        end
        data=data(1:channels,:);
        initsample=initsample+size(data,2);
        wsamp = 0;

        if size(data,2)<=ring_buffer_size
            ring_buffer = [ ring_buffer(:,size(data,2)+1:end) data ];
        else
            ring_buffer = data(1:size(data,1),end-ring_buffer_size+1:end);
        end

        try
        fid1=fopen(feedback_file_name,'w');
        fwrite(fid1,[0,0,0],'double');
        fclose(fid1);
        catch
        end

        try
        is_new = ~exist(log_file_name, 'file');
        fid_log = fopen(log_file_name, 'a');
        if fid_log ~= -1 && (is_new || ftell(fid_log) == 0)
            fprintf(fid_log, 'nf_17_gt_19,nf_19_gt_17,cycle_cnt,timestamp\n');
        end
        if fid_log ~= -1
            fprintf(fid_log, '%.8f,%.8f,%d,%.6f\n', 0.0, 0.0, 0, posixtime(datetime('now')));
        end
        catch
        fid_log = -1;
        end

        FB_out_all = [];
        continue;
    end

    if ~isempty(find(trig_values==triggers.trial_stop, 1)) && trial_on

        if ~isempty(find(trig_values==50, 1))
            outcome=1;
        elseif ~isempty(find(trig_values==60, 1))
            outcome=2;
        else
            outcome=0;
            disp(0);
        end

        prev_samp = event_sample(trig_values==triggers.trial_stop).sample;
        timec = char(datetime('now','Format','yyyy-MM-dd-HH-mm-ss'));
        save([filepath sprintf('RT_basic_S%d_run%d_analysis_workspace_trial%d',subject_no,run_no,trial_no)],...
            'fb_out_send_all','ring_buffer_all', ...
            'cut_off_all','outcome');
        cnt = 1;
        fb_out_send_all = [];

        cut_off = cut_off_init;
        ring_buffer_all = [];
        SSVEP_power_all = [];
        data_size_all = [];
        SMI_all = [];
        cut_off_all = [];
        
        prev_SSVEP_power = [];

        try
        fid1=fopen(feedback_file_name,'w');
        fwrite(fid1,[0,0,0],'double');
        fclose(fid1);
        catch
        end

        try
        if fid_log ~= -1
            fprintf(fid_log, '%.8f,%.8f,%d,%.6f\n', 0.0, 0.0, 0, posixtime(datetime('now')));
            fclose(fid_log);
        end
        fid_log = -1;
        catch
        fid_log = -1;
        end

        try
        fid2=fopen(change_file_name,'w');
        fwrite(fid2,0,'double');
        fclose(fid2);
        catch
        end

        trial_on = false;
        disp('2');
    end

    if trial_on
        % Filtering
        buff_filt = ring_buffer(:,Delay+1:end) - ring_buffer(:,1:end-Delay);

        if demean_reref
            buff_filt = buff_filt - repmat(mean(buff_filt,1),[channels,1]);
        end

        if z_score
            buff_filt = zscore(buff_filt')';
        end

        for i=1:1
            buff_filt_epochs(:,:,i)=buff_filt(:,128*(i-1)+1:128*i);
        end

        mean_buff_filt = mean(buff_filt_epochs,3);

        % ======================================================================
        % CCA Baseline: Raw difference between Hardware-friendly CCA scores
        % ======================================================================
        % Extract the data block for all valid electrodes: Shape [n_channels x n_samples]
        X = mean_buff_filt(pnqAllS, :);
        X = X'; % Now [n_samples x n_channels]
        
        % Compute HW-CCA scores
        n_power_iters = 8;
        score_17 = hw_friendly_cca_score(X, Y17, Cyy_inv17, n_power_iters);
        score_19 = hw_friendly_cca_score(X, Y19, Cyy_inv19, n_power_iters);
        
        % Store scores for logging/analysis
        SSVEP_power_all(:,:,cnt) = [score_17, score_19];
        
        % Calculate feedback directly from CCA score difference
        % (No delta/baseline normalisation needed since CCA is bounded 0-1)
        FB_out_avgs(1) = score_17 - score_19; % increase 17 Hz wrt 19 Hz
        FB_out_avgs(2) = score_19 - score_17; % increase 19 Hz wrt 17 Hz

        fb_out_sends = (FB_out_avgs - cut_off).*deltas;

        if abs(fb_out_sends(1))>1
           fb_out_sends = fb_out_sends./abs(fb_out_sends);
        end

        disp(fb_out_sends);

        fb_out_send_all(:,cnt) = fb_out_sends;
        fb_out_sendw = fb_out_send_all(:,cnt);
        if cnt>5
            fb_out_sendw = median(fb_out_send_all(:,end-5+1:end),2);
        end

        fb_out_sendw(3) = cnt; % [NF_17gt19, NF_19gt17, sampleCount]

        ring_buffer_all(:,:,cnt) = ring_buffer;
        cut_off_all(:,:,cnt) = [score_17, score_19];
        cnt=cnt+1;

        try
        fid1=fopen(feedback_file_name,'w');
        fwrite(fid1,fb_out_sendw,'double');
        fclose(fid1);
        catch
        end

        try
            if fid_log ~= -1
                fprintf(fid_log, '%.8f,%.8f,%d,%.6f\n', fb_out_sendw(1), fb_out_sendw(2), round(fb_out_sendw(3)), posixtime(datetime('now')));
            end
        catch err
            disp(['LOG ERROR: ', err.getReport()]);
        end

        prev_FB_out = fb_out_sendw;
    end

end

end

% --- HW-CCA Local Functions ---
function [Y, Cyy_inv] = precompute_reference_terms(freq, n_samples, fs, n_harmonics)
    t = (0:n_samples-1)' / fs;
    Y = zeros(n_samples, 2 * n_harmonics);
    for h = 1:n_harmonics
        Y(:, 2*h-1) = sin(2 * pi * freq * h * t);
        Y(:, 2*h)   = cos(2 * pi * freq * h * t);
    end
    Y = Y - mean(Y, 1);
    Cyy = Y' * Y;
    Cyy_inv = inv(Cyy + 1e-8 * eye(size(Cyy, 1)));
end

function score = hw_friendly_cca_score(X, Y, Cyy_inv, n_power_iters)
    X = X - mean(X, 1);
    Cxx = X' * X;
    Cxy = X' * Y;
    Cxx_inv = inv(Cxx + 1e-6 * eye(size(Cxx, 1)));
    M = Cxx_inv * Cxy * Cyy_inv * Cxy';
    
    % Power Iteration
    v = ones(size(M, 1), 1) / sqrt(size(M, 1));
    for i = 1:n_power_iters
        v = M * v;
        nrm = norm(v);
        if nrm < 1e-12
            score = 0.0;
            return;
        end
        v = v / nrm;
    end
    eigenvalue = v' * M * v;
    score = sqrt(max(eigenvalue, 0.0));
end
