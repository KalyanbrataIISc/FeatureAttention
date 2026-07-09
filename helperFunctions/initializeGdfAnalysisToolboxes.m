function initializeGdfAnalysisToolboxes()
% initializeGdfAnalysisToolboxes  Adds FieldTrip, Chronux, and NoiseTools to
% the MATLAB path for the offline GDF/SSVEP analysis scripts in analysis/,
% then runs ft_defaults. Mirrors the toolbox locations already used by
% analysis/singleParticipantBehaviourOffline.m on this machine.

    addpath(genpath('/Users/kalyanbrata/Local/chronux_2_12'));
    addpath('/Users/kalyanbrata/Local/fieldtrip-20230613');
    ft_defaults;
    addpath(genpath('/Users/kalyanbrata/Local/NoiseTools'));
end
