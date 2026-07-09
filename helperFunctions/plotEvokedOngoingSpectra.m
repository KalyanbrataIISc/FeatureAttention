function plotEvokedOngoingSpectra(miniEpochs, chronuxParamsOngoing, chronuxParamsEvoked, normMode, ...
    freqsHz, freqLabels, freqColors, titlePrefix, subtitleStr, resultsDir, saveFigures, fileTagPrefix)
% plotEvokedOngoingSpectra  Computes and plots the ongoing (induced) and
% evoked power spectra from a pool of mini-epochs
% (helperFunctions/extractMiniEpochs.m), matching
% analysis/singleParticipantBehaviourOffline.m's processSinglePSSpectra
% method (see helperFunctions/computeOngoingSpectrum.m and
% computeEvokedSpectrum.m), then saves both figures. Factored out so the
% same computation can run on the combined (all participants) pool and,
% for the "individual" plotting mode, on each participant's own pool
% separately, without duplicating the logic.
%
%   miniEpochs: channels x epochLenSamples x nEpochs (already pooled -
%       e.g. across trials/participants, per the caller's chosen scope).
%   chronuxParamsOngoing, chronuxParamsEvoked: Chronux param structs (see
%       computeOngoingSpectrum.m / computeEvokedSpectrum.m).
%   normMode: passed to normalizeSpectrum.m (e.g. 'rel-mean').
%   freqsHz, freqLabels, freqColors: the SSVEP tagging frequencies to mark
%       on the spectrum plots.
%   titlePrefix: prepended to "Ongoing (induced) power spectrum" / "Evoked
%       power spectrum" for each figure's title.
%   subtitleStr: figure subtitle (e.g. trial/epoch/channel counts).
%   resultsDir: folder to save PNG/mat outputs into.
%   saveFigures: true to save; false to only display.
%   fileTagPrefix: filename prefix for saved PNG/mat files.

    nMiniEpochs = size(miniEpochs, 3);
    if nMiniEpochs == 0
        warning('plotEvokedOngoingSpectra:noMiniEpochs', ...
            'No mini-epochs available for "%s"; skipping its evoked/ongoing spectra.', titlePrefix);
        return;
    end

    [ongoingSpectrum, ongoingFreqs] = computeOngoingSpectrum(miniEpochs, chronuxParamsOngoing);
    ongoingSpectrum = normalizeSpectrum(ongoingSpectrum, normMode);
    ongoingMean = mean(ongoingSpectrum, 1);
    ongoingSem = computeSemOmitNan(ongoingSpectrum);

    [evokedSpectrum, evokedFreqs] = computeEvokedSpectrum(miniEpochs, chronuxParamsEvoked);
    evokedSpectrum = normalizeSpectrum(evokedSpectrum, normMode);
    evokedMean = mean(evokedSpectrum, 1);
    evokedSem = computeSemOmitNan(evokedSpectrum);

    participantPrefix = regexp(titlePrefix, '^P\d+', 'match', 'once');
    if ~isempty(participantPrefix)
        figureNamePrefix = participantPrefix;
    else
        figureNamePrefix = 'All';
    end

    plotPowerSpectrumMeanSem(ongoingFreqs, ongoingMean, ongoingSem, freqsHz, freqColors, freqLabels, ...
        [titlePrefix, 'Ongoing (induced) power spectrum'], subtitleStr, [figureNamePrefix, ' Ongoing']);
    if saveFigures
        exportgraphics(gcf, fullfile(resultsDir, [fileTagPrefix, '_ongoing.png']), 'Resolution', 150);
        save(fullfile(resultsDir, [fileTagPrefix, '_ongoing.mat']), ...
            'ongoingFreqs', 'ongoingMean', 'ongoingSem', 'freqsHz', 'freqLabels', 'nMiniEpochs');
        close(gcf);
    end

    plotPowerSpectrumMeanSem(evokedFreqs, evokedMean, evokedSem, freqsHz, freqColors, freqLabels, ...
        [titlePrefix, 'Evoked power spectrum'], subtitleStr, [figureNamePrefix, ' Evoked']);
    if saveFigures
        exportgraphics(gcf, fullfile(resultsDir, [fileTagPrefix, '_evoked.png']), 'Resolution', 150);
        save(fullfile(resultsDir, [fileTagPrefix, '_evoked.mat']), ...
            'evokedFreqs', 'evokedMean', 'evokedSem', 'freqsHz', 'freqLabels', 'nMiniEpochs');
        close(gcf);
    end
end
