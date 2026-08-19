sca;
clear all;

Screen('Preference', 'SkipSyncTests', 1);

screens = Screen('Screens');
disp(screens);

screenNumber = max(screens);
fprintf('Testing PTB screen %d\n', screenNumber);

PsychImaging('PrepareConfiguration');
[w, rect] = PsychImaging('OpenWindow', screenNumber, 0);

ifi = Screen('GetFlipInterval', w);

fprintf('\nSUCCESS!\n');
fprintf('IFI = %.6f ms\n', ifi * 1000);
fprintf('Refresh = %.6f Hz\n', 1/ifi);

WaitSecs(3);
sca;