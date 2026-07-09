function normalized = normalizeSpectrum(spectrum, mode)
% normalizeSpectrum  Normalizes a channels x freqBins power spectrum,
% per channel (each row), matching
% analysis/singleParticipantBehaviourOffline.m's local normalizeSpectrum.
%
%   mode: 'none' (unchanged), 'rel-mean' (divide by that channel's own
%       mean power across frequencies), 'db-abs' (10*log10), or
%       'db-relmean' (10*log10 of the rel-mean result).

    switch mode
        case 'none'
            normalized = spectrum;
        case 'rel-mean'
            normalized = spectrum ./ mean(spectrum, 2, 'omitnan');
        case 'db-abs'
            normalized = 10 * log10(spectrum);
        case 'db-relmean'
            normalized = 10 * log10(spectrum ./ mean(spectrum, 2, 'omitnan'));
        otherwise
            error('normalizeSpectrum:unknownMode', 'Unknown normalization mode "%s".', mode);
    end
end
