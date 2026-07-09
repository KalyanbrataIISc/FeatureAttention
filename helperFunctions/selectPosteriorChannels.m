function roiLabels = selectPosteriorChannels(sfpFile, availableLabels, nChannels)
% selectPosteriorChannels  Picks an occipital/parieto-occipital region of
% interest from a Biosemi-style .sfp electrode position file, as the
% nChannels channels with the most posterior (most negative) Y-coordinate
% among availableLabels. This is a geometric, reproducible stand-in for
% naming specific 10-20 sites (e.g. Oz/O1/O2/POz) by hand: in the
% Biosemi_128_Cartesian_Default.sfp convention used here, Y is
% anterior(+)/posterior(-) - confirmed by inspection (e.g. channel C17 at
% Y=+11.4 sits over frontal cortex, low Z; channels A22-A25 at Y~-9 sit at
% the posterior midline). Both SSVEP-tagged flocks in this task are
% spatially co-located on screen (not left/right hemifield-separated), so
% one shared posterior ROI - not a left/right split - is used for both
% frequencies.
%
%   sfpFile: path to the .sfp position file (label x y z per line).
%   availableLabels: channel labels actually present in the data (e.g.
%       after bad-channel handling), restricting which sfp entries can be
%       selected.
%   nChannels: how many posterior channels to select.
%
% Returns roiLabels: nChannels x 1 cell array of channel labels.

    fid = fopen(sfpFile, 'r');
    if fid < 0
        error('selectPosteriorChannels:cannotOpenFile', 'Could not open sfp file: %s', sfpFile);
    end
    raw = textscan(fid, '%s %f %f %f');
    fclose(fid);

    sfpLabels = raw{1};
    sfpY = raw{3};

    keepMask = ismember(sfpLabels, availableLabels);
    sfpLabels = sfpLabels(keepMask);
    sfpY = sfpY(keepMask);

    if numel(sfpLabels) < nChannels
        error('selectPosteriorChannels:tooFewChannels', ...
            'Only %d of the requested %d channels are available in both the sfp file and the data.', ...
            numel(sfpLabels), nChannels);
    end

    [~, sortOrder] = sort(sfpY, 'ascend');
    roiLabels = sfpLabels(sortOrder(1:nChannels));
end
