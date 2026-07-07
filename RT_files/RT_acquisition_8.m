function [cut_off_init] = RT_acquisition_8(varargin)

global run;
run=true;
channels = 41;             %set to the same value as in Actiview "Channels sent by TCP"
Fs = 128;
trial_on = false;

subject_no = 9988;
run_no = 101;
method = 'DSS';

delta = [2,2];
deltas = [0.2,0.2];

cut_off_init = [0,0];

triggers.trial_spatialCue=11;
triggers.trial_rightCue=12;
triggers.trial_start=20;
triggers.trial_stop=30;
triggers.block_stop = 25;

trial_no = 0;

% Preprocessing Flags
demean_reref = true;
z_score = false;

assignopts(who,varargin{:});

filepath = [pwd '\' sprintf('RT_S%d\\run%d_%s\\',subject_no,run_no,method)];
savepath = filepath;
mkdir(filepath(1:end-1));

% Feedback
feedback_file_name='X:\FeatureAttention\nf.txt';

% Filtering
Delay = round(Fs/50);

% Ring buffer data
ring_buffer_time = 1; %enter value in seconds %change 4 to 2 for total time of epoch
ring_buffer_size = round(Fs*ring_buffer_time) + Delay;

save('data_init');
a=load('DSS_data.mat');  % pnqL1 and pnqL2
pnqL1 = [28 30 32 36 38];       % Right Electrodes
pnqL2 = [15 17 5 7 9];          % Left Electrodes

pnqL1S = [28 30 32 36 38 35 37 39 40 41 26 27 29 31]; % All right Electrodes for SSVEP
pnqL2S = [15 17 5 7 9 6 8 10 11 12 13 14 16 18]; % All left Electrodes for SSVEP

FB_dist = a.fit_dist';

% mtspectrumc initialization
params = struct();
params.Fs = 128;
params.tapers = [1 1];
params.pad = -1;
params.err = 0;
params.trialave = 0;

save([filepath sprintf('RT_data_init_S%d_run%d.mat',subject_no,run_no)]);

%fieldtrip initialization
addpath(genpath('F:\Real-Time\Toolbox/chronux_2_12.v03'));
addpath('F:\Real-Time\Toolbox/fieldtrip-20170817/');
ft_defaults;
initsample=1;

% Remove inital junk data
data=ft_read_data('buffer://localhost:1972','begsample',1,'endsample',inf);
initsample=initsample+size(data,2);
% total_data =[];
total_errors = [];
errors = 0; cnt=1;
ring_buffer = zeros(channels,ring_buffer_size);
fb_out_send_all = [];
Alpha_power_all = [];
change_val_all = [];
FB_out_all = [];
ring_buffer_all = [];
AMI_all = [];
cut_off_allL = [];
cut_off_allR = [];

Cue = 0;
prev_samp = initsample;
cut_off = cut_off_init;
data_size_all = [];
i1=1;
i2=1;
wsamp = 0;
while(1)
    
    try
        event=ft_read_event('buffer://localhost:1972');
        data=ft_read_data('buffer://localhost:1972','begsample',initsample,'endsample',inf);%,'blocking',true);
    catch
        errors = errors +1;
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
%     ring_buffer=ring_buffer-repmat(mean(ring_buffer,1),[channels,1]);
%     ring_buffer=resample(double(ring_buffer'),100,128)';
    
    total_errors = [total_errors errors];
    errors = 0;
    
    if ~isempty(event)
        event_select=event(strcmp('stimulus', {event.type}));
        trig_values=[event_select(cell2mat({event_select.sample})>prev_samp).value];
        event_sample=event_select(cell2mat({event_select.sample})>prev_samp);
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
        
%         ring_buffer=ring_buffer-repmat(mean(ring_buffer,1),[channels,1]);
%         ring_buffer=resample(double(ring_buffer'),100,128)';
        
        try
        fid1=fopen(feedback_file_name,'w');
        fwrite(fid1,[0,0,0,0,0],'double');
        fclose(fid1);
        catch
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
            'Alpha_power_all','fb_out_send_all','FB_out_all','ring_buffer_all', 'AMI_all', ...
            'cut_off_allL','cut_off_allR','outcome');
        cnt = 1;
        fb_out_send_all = [];
        
        cut_off = cut_off_init;
        ring_buffer_all = [];
        Alpha_power_all = [];
        SSVEP_power_all = [];
        data_size_all = [];
        FB_out_all = [];
        AMI_all = [];
        SMI_all = [];
        cut_off_allL = [];
         cut_off_allR = [];
    
        try
        fid1=fopen(feedback_file_name,'w');
        fwrite(fid1,[0,0,0,0,0],'double');
        fclose(fid1);
        catch
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
    
%     if ~isempty(find(trig_values==triggers.block_stop, 1))
% %         if size(data_baseline,3)==10
% %             baseline(trials,pnqL1,pnqL2);
% %            save(sprintf('baselinedata%d',trial_no),'data_baseline','trials');
% %         end
%         
%         clear trials
%         break;
%     end
    if trial_on
        % Filtering
        buff_filt = ring_buffer(:,Delay+1:end) - ring_buffer(:,1:end-Delay); %Filtering
        
        if demean_reref
            buff_filt = buff_filt - repmat(mean(buff_filt,1),[channels,1]);
%             buff_filt = buff_filt - repmat(mean(buff_filt,2),[1,size(buff_filt,2)]);
        end
             % Z-score
        if z_score
            buff_filt = zscore(buff_filt')';
        end

        for i=1:1 % change 4 to 2 for number of chunks
            buff_filt_epochs(:,:,i)=buff_filt(:,128*(i-1)+1:128*i);
        end

%         if cnt>20                           % For calculating Alpha without noise for t=1s to t=2s
            mean_buff_filt = mean(buff_filt_epochs,3);
%         else
%             mean_buff_filt = squeeze(buff_filt_epochs(:,:,2));
%         end

         for xs = 1:14
            params.fpass=[5 40];
            All_power1= mtspectrumc(mean_buff_filt(pnqL1S(xs),:)',params); % right elecs
            All_power2= mtspectrumc(mean_buff_filt(pnqL2S(xs),:)',params); % left elecs
            
            SSVEP_power(1) = All_power1(13)./mean([All_power1(12) All_power1(14)]); % 14Hz re
            SSVEP_power(2) = All_power2(16)./mean([All_power2(15) All_power2(17)]); % 18Hz le
            
            SSVEP_power_all(xs,:,cnt) = SSVEP_power;
            SSVEP_power=[];
            
            Alpha_power(1) = mean(All_power1(4:8)/mean(All_power1));
            Alpha_power(2) = mean(All_power2(4:8)/mean(All_power2));
            
            Alpha_power_all(xs,:,cnt) = Alpha_power;
            Alpha_power=[];FB_out=[];

            SS_power_allR(xs,:,cnt) = All_power1; %SS_power;
            SS_power_allL(xs,:,cnt) = All_power2; %SS_power;            
         end

       
        avg_alpha = mean(Alpha_power_all(1:5,:,cnt),1);
        avg_SSVEP = mean(SSVEP_power_all(:,:,cnt),1);
        
%          FB_out(1) = cdf(FB_dist(1),avg_SSVEP(1));    
%          FB_out(2) = cdf(FB_dist(2),avg_SSVEP(2));
        
        % Feedback Calculation
        avg_AMI(1) = (avg_alpha(1)-avg_alpha(2))/(avg_alpha(1)+avg_alpha(2)); % re - le / re + le
        avg_AMI(2) = (avg_alpha(2)-avg_alpha(1))/(avg_alpha(1)+avg_alpha(2)); % le- re / re + le

        avg_SMI(1) = (log(avg_SSVEP(1))-log(avg_SSVEP(2))); % 14 - 18 Hz
        avg_SMI(2) = (log(avg_SSVEP(2))-log(avg_SSVEP(1))); % 18 - 14 Hz
     
        AMI_all(:,cnt) = avg_AMI;
        SMI_all(:,cnt) = avg_SMI;
%         
%         FB_out=(FB_out);
%         if cnt>5
%             FB_out_send=(FB_out+FB_out_all(:,cnt-1)'+FB_out_all(:,cnt-2)'+FB_out_all(:,cnt-3)'+FB_out_all(:,cnt-4)')/5;
%         else
%             FB_out_send=FB_out;
%         c
        if cnt>11 %change 29 to 15 for 2 seconds
%             avg_alpha_prev = median(mean(Alpha_power_all(:,:,21:cnt-1),1),3); %change 28 to 14 for 2 seconds
            %cut_off = cut_off + 0.0015;
            avg_AMI_prev = median(AMI_all(:,11:cnt-1),2);
            avg_SMI_prev = median(SMI_all(:,11:cnt-1),2);

            % AMI_zero = (mean(AMI_all(:,1:10),2));
            % SMI_zero = (mean(SMI_all(:,1:10),2));
%             AMI_curr = median(AMI_all(:,cnt-4:cnt),2);
            %AMI_zero = (AMI_all(:,1));
%             K1 = 1./abs(AMI_zero);
%              K2 = K1./(cnt/10 + K1);
             K2 = [1 1];
            % avg_alpha_prev = log(abs(avg_alpha_prev));
        else
            % avg_alpha_prev = avg_alpha;
            % avg_SSVEP_prev = avg_SSVEP;
%             AMI_curr = AMI_all(:,cnt);
            avg_AMI_prev(1) = avg_AMI(1);
            avg_AMI_prev(2) = avg_AMI(2);

            avg_SMI_prev(1) = avg_SMI(1);
            avg_SMI_prev(2) = avg_SMI(2);

            K2 = [1 1];
        end
        

           
% FEEDBACK Alternatives

        
% 1. Ramp down

%         FB_out_avg(1)=-((avg_alpha(1)-avg_alpha(2))/(avg_alpha(1)+avg_alpha(2)) - (avg_alpha_prev(1)-avg_alpha_prev(2))/(avg_alpha_prev(1)+avg_alpha_prev(2)));
%         FB_out_avg(2)=-((avg_alpha(2)-avg_alpha(1))/(avg_alpha(1)+avg_alpha(2)) - (avg_alpha_prev(2)-avg_alpha_prev(1))/(avg_alpha_prev(1)+avg_alpha_prev(2)));
%        
        FB_out_avg(1) = -(avg_AMI(1) - K2(1)*avg_AMI_prev(1)); % reduce alpha in right wrt left elecs
        FB_out_avg(2) = -(avg_AMI(2) - K2(2)*avg_AMI_prev(2)); % reduce alpha in left wrt right elecs
        FB_out_avgs(1) = (avg_SMI(1) - avg_SMI_prev(1)); % increase 14 Hz wrt 18 Hz
        FB_out_avgs(2) = (avg_SMI(2) - avg_SMI_prev(2)); % increase 18 Hz wrt 14 Hz
%
% % 2. Ramp Down 2.0
% % Left
%             if avg_AMI(1)<avg_AMI_prev(1)
%                         FB_out_avg(1) = -(avg_AMI(1));
%             else
%                         FB_out_avg(1) = -(avg_AMI(1) - K2.*avg_AMI_prev(1));
%             end
% % Right
%             if avg_AMI(2)<avg_AMI_prev(2)
%                         FB_out_avg(2) = -(avg_AMI(2));
%             else
%                         FB_out_avg(2) = -(avg_AMI(2) - K2.*avg_AMI_prev(2));
%             end
%
% % 3. Thresholding
% % Left
%             if avg_AMI(1)<-0.27
%                         FB_out_avg(1) = -(avg_AMI(1) - K2.*avg_AMI_prev(1));
%             else
%                         FB_out_avg(1) = 0
%             end
% % Right
%             if avg_AMI(2)<-0.27
%                         FB_out_avg(2) = -(avg_AMI(2) - K2.*avg_AMI_prev(2));
%             else
%                         FB_out_avg(2) = 0
%             end
% 
% % 4. Thresholding and Ramp down together
% % Left
%             if avg_AMI(1)<-0.27
%                         FB_out_avg(1) = -(avg_AMI(1));
%             else
%                         FB_out_avg(1) = -(avg_AMI(1) - K2.*avg_AMI_prev(1));
%             end
% % Right
%             if avg_AMI(2)<-0.27
%                         FB_out_avg(2) = -(avg_AMI(2));
%             else
%                         FB_out_avg(2) = -(avg_AMI(2) - K2.*avg_AMI_prev(2));
%             end

        %fb_out_send = prev_FB_out + (FB_out_avg - cut_off).*delta;
%         if FB_out_avg(1)<0
%             FB_out_avg(1)=FB_out_avg(1)/2;            % positive and
%                   % negative feedback MUST be same. hence commented out
%         end
%         if FB_out_avg(2)<0
%             FB_out_avg(2)=FB_out_avg(2)/2;
%         end

        fb_out_send = (FB_out_avg - cut_off).*delta;
        fb_out_sends = (FB_out_avgs - cut_off).*deltas;

       
        if abs(fb_out_send(1))>1 || abs(fb_out_send(2))>1
            fb_out_send(1) = 1*fb_out_send(1)./abs(fb_out_send(1)); 
        end

        if abs(fb_out_sends(1))>1
           fb_out_sends = fb_out_sends./abs(fb_out_sends); 
        end

%         fb_out_send(fb_out_send<0) = 0;
        disp([fb_out_send fb_out_sends]);
        %fb_out_send(fb_out_send<0) = 0;
        %fb_out_send(fb_out_send>1) = 1;
%         disp(fb_out_send);
       
        fb_out_send_all(:,cnt) = [fb_out_send fb_out_sends];
        fb_out_sendw = fb_out_send_all(:,cnt);
        if cnt>5
            fb_out_sendw = median(fb_out_send_all(:,end-5+1:end),2);
        end
           
        fb_out_sendw(5) = cnt;
       
        ring_buffer_all(:,:,cnt) = ring_buffer;
        cut_off_allL(:,:,cnt) = squeeze((SS_power_allL(:,:,cnt)));
        cut_off_allR(:,:,cnt) = squeeze((SS_power_allR(:,:,cnt)));

% %         change_val_all(:,cnt) = change_val;
        FB_out_all(:,cnt) = FB_out_avg;
   %     data_all=[data_all data];
        cnt=cnt+1;
                
        try
        fid1=fopen(feedback_file_name,'w');
        fwrite(fid1,fb_out_sendw,'double');
      %  disp(fb_out_send);
        fclose(fid1);
        catch
        
        end
        
        prev_FB_out = fb_out_sendw;
        %disp(delta);
    end
    
end

end

