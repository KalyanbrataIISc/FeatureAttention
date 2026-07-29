clear; clc; 
close all;
addpath(genpath('F:\Real-Time\Toolbox/chronux_2_12.v03'));
addpath('F:\Real-Time\Toolbox/fieldtrip-20170817/');
addpath(genpath('Functions'));
ft_defaults;
 

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
subject_no = input('Subject Number: '); %%%%%% Remember to Change it for every participant %%%%%%%
%%%%%%% b%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


run_no = input('Enter run no');
method = 'DSS';
channels = 41;        
Fs = 128;
SSVEP_freq = [19 23];
% Noise_freq = [22 24 28 30];
cut_off_init = [0,0]; %cc
delta = [2,2];  %cc % vestigial - alpha/AMI feedback is disabled in RT_acquisition_8.m, so this gain is no longer used; still passed through harmlessly
deltas = [0.2,0.2];  %cc % SMI/SSVEP feedback gain - this is the one that matters now
%Verification and Cut_off calibration 

run_no = run_no - 1;

while(1)

run_no = run_no + 1;
opts = {'subject_no',subject_no,'run_no',run_no,'method',method,'channels',channels,'Fs',Fs,...
    'SSVEP_freq',SSVEP_freq,'cut_off_init',cut_off_init,'delta',delta,'deltas',deltas};

[cut_off_init] = RT_acquisition_8(opts);

% user_in = input('1:continue 0:repeat');
% if user_in==0
%     break;
% end

end
