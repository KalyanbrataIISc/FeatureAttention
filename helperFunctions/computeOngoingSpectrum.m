function [spectrum, freqs] = computeOngoingSpectrum(miniEpochs, chronuxParams)
% computeOngoingSpectrum  Ongoing (induced/total) power spectrum: per
% channel, a Chronux multitaper spectrum of every pooled mini-epoch
% (extractMiniEpochs.m) with chronuxParams.trialave=1, i.e. each epoch's own
% spectrum is computed first and epochs are then averaged in the power
% domain - this counts power regardless of whether it's phase-locked
% across epochs. Matches
% analysis/singleParticipantBehaviourOffline.m's processSinglePSSpectra
% (SInduced/fOngoing).
%
%   miniEpochs: channels x epochLenSamples x nEpochs.
%   chronuxParams: struct for mtspectrumc (Fs, tapers, pad, fpass, err,
%       trialave - trialave should be 1).
%
% Returns spectrum: numChannels x numFreqBins, freqs: 1 x numFreqBins.

    numChannels = size(miniEpochs, 1);

    firstChannelEpochs = squeeze(miniEpochs(1, :, :));
    if isvector(firstChannelEpochs)
        firstChannelEpochs = firstChannelEpochs(:);
    end
    [s, freqs] = mtspectrumc(firstChannelEpochs, chronuxParams);
    spectrum = zeros(numChannels, numel(s));
    spectrum(1, :) = s(:).';

    for ch = 2:numChannels
        channelEpochs = squeeze(miniEpochs(ch, :, :));
        if isvector(channelEpochs)
            channelEpochs = channelEpochs(:);
        end
        [s, freqs] = mtspectrumc(channelEpochs, chronuxParams);
        spectrum(ch, :) = s(:).';
    end
end
