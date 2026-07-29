function plotPowerSpectrumMeanSem(freqAxis, meanSpectrum, semSpectrum, markFreqsHz, markColors, markLabels, ...
    titleStr, subtitleStr, figureName)
% plotPowerSpectrumMeanSem  Plots a channel-mean power spectrum (mean +/-
% shaded SEM across channels) on a new figure, with vertical reference
% lines at markFreqsHz (the SSVEP tagging frequencies) in their
% corresponding markColors/markLabels, so the 19Hz/23Hz peaks are easy to
% spot directly on the spectrum.
%
%   freqAxis: 1 x numFreqBins (Hz).
%   meanSpectrum, semSpectrum: 1 x numFreqBins (already averaged/SEM'd
%       across channels).
%   markFreqsHz: vector of frequencies to mark with a vertical line.
%   markColors: numel(markFreqsHz) x 3 RGB triples in [0, 1].
%   markLabels: cellstr, one per markFreqsHz entry.
%   titleStr, subtitleStr: figure title/subtitle.
%   figureName: optional short MATLAB window name.

    if nargin < 9 || isempty(figureName)
        figureName = titleStr;
    end

    figure('Name', figureName, 'Color', 'w');
    hold on;

    mask = isfinite(freqAxis) & isfinite(meanSpectrum) & isfinite(semSpectrum);
    if nnz(mask) > 1
        x = freqAxis(mask);
        y = meanSpectrum(mask);
        e = semSpectrum(mask);
        fill([x, fliplr(x)], [y - e, fliplr(y + e)], [0.4 0.4 0.4], ...
            'FaceAlpha', 0.18, 'EdgeColor', 'none', 'HandleVisibility', 'off');
    end
    plot(freqAxis(mask), meanSpectrum(mask), 'Color', [0.2 0.2 0.2], ...
        'LineWidth', 2, 'DisplayName', 'Mean across channels');

    for m = 1:numel(markFreqsHz)
        xline(markFreqsHz(m), '--', 'Color', markColors(m, :), 'LineWidth', 1.5, ...
            'DisplayName', markLabels{m});
    end

    xlabel('Frequency (Hz)');
    ylabel('Power (normalized)');
    legend('Location', 'best');
    title(titleStr);
    subtitle(subtitleStr);
    box on;
    hold off;
end
