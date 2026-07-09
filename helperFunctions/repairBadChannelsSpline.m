function [repairedData, removedLabels] = repairBadChannelsSpline(prepData, sfpFile, manualBadLabels)
% repairBadChannelsSpline  Detects bad channels with NoiseTools'
% my_nt_find_bad_channels (same call/parameters as
% analysis/singleParticipantBehaviourOffline.m: proportion=0.33, thresh1=4,
% thresh2=[], thresh3=4, applied to the whole continuous recording) unioned
% with any manually-specified bad channels, caps the automatic detections at
% the 15 worst-affected channels (same cap as that reference pipeline, to
% avoid triangulation/spline repair collapsing when too many channels are
% flagged at once), then spline-interpolates them from their spatial
% neighbours (ft_prepare_neighbours + ft_channelrepair), using electrode
% positions read from sfpFile.
%
%   prepData: continuous FieldTrip raw struct (post filter/downsample).
%   sfpFile: path to the Biosemi_128_Cartesian_Default.sfp electrode
%       position file.
%   manualBadLabels: cell array of channel labels to always treat as bad
%       (pass {} for none).
%
% Returns repairedData (same struct with bad channels replaced) and
% removedLabels (cell array of the channel labels that were repaired).

    dataMatrix = prepData.trial{1};
    [autoBadIdx, ~, badTimePoints] = my_nt_find_bad_channels(dataMatrix.', 0.33, 4, [], 4);
    if numel(autoBadIdx) > 15
        [~, worstOrder] = sort(badTimePoints, 'descend');
        autoBadIdx = sort(worstOrder(1:15));
    end

    autoBadLabels = prepData.label(autoBadIdx);
    removedLabels = unique([autoBadLabels(:); manualBadLabels(:)]);

    if isempty(removedLabels)
        repairedData = prepData;
        return;
    end

    cfgNeighbours = [];
    cfgNeighbours.method = 'triangulation';
    cfgNeighbours.elec = ft_read_sens(sfpFile);
    cfgNeighbours.channel = prepData.label;
    neighbours = ft_prepare_neighbours(cfgNeighbours);

    cfgRepair = [];
    cfgRepair.badchannel = removedLabels;
    cfgRepair.neighbours = neighbours;
    cfgRepair.elec = ft_read_sens(sfpFile);
    cfgRepair.method = 'spline';
    cfgRepair.senstype = 'eeg';
    repairedData = ft_channelrepair(cfgRepair, prepData);
end
