function cog_send_triggers(paraport,name_of_trigger)

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
%putvalue(paraport,pval);
fwrite(paraport,pval);
end
