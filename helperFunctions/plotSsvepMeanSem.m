function plotSsvepMeanSem(timeAxisSec, meanMat, semMat, freqLabels, lineColors, titleStr, subtitleStr, xLabelStr, ...
    figureName, markerTimesSec)
% plotSsvepMeanSem  Plots one or more event-locked, baseline-corrected
% log-SNR time series (mean +/- shaded SEM) on a new figure, in the style of
% analysis/singleParticipantBehaviourOffline.m's plotMeanSem: a shaded
% SEM band (fill, low alpha, no legend entry) behind a mean line (legend
% entry), one pair per row of meanMat/semMat. Each series also gets its own
% line style (solid, dashed, ...), not just its own color - the task's own
% saturated stimulus colors (reused here so the plot ties back to
% colorC1/colorC2 in gameNFv3.m) read at fairly low contrast against a white
% figure background, so identity should not rest on color alone. A dashed
% vertical line at x=0 marks the locking event (see alignSeriesToEvent.m -
% cue onset or response, whichever the caller aligned to): trial durations
% vary trial-to-trial, so how far the data extends on either side of x=0
% varies trial-to-trial too, via alignSeriesToEvent.m's NaN-padding.
%
%   timeAxisSec: 1 x timelinePoints, seconds relative to the locking event.
%   meanMat, semMat: numFreqs x timelinePoints.
%   freqLabels: cellstr, one per row, e.g. {'17 Hz', '20 Hz'}.
%   lineColors: numFreqs x 3 RGB triples in [0, 1].
%   titleStr: figure title.
%   subtitleStr: figure subtitle (e.g. explaining what the cue means).
%   xLabelStr: x-axis label (e.g. 'Time relative to cue onset (s)' or
%       'Time relative to response (s)').
%   figureName: short MATLAB window name. Plot title still uses titleStr.
%   markerTimesSec: optional 1 x n vector of event times to mark with dots.

    lineStyleOrder = {'-', '--', ':', '-.'};
    if nargin < 9 || isempty(figureName)
        figureName = titleStr;
    end
    if nargin < 10
        markerTimesSec = [];
    end

    figure('Name', figureName, 'Color', 'w');
    hold on;
    numFreqs = size(meanMat, 1);
    for f = 1:numFreqs
        thisMean = meanMat(f, :);
        thisSem = semMat(f, :);
        thisLineStyle = lineStyleOrder{mod(f - 1, numel(lineStyleOrder)) + 1};

        mask = isfinite(timeAxisSec) & isfinite(thisMean) & isfinite(thisSem);
        if nnz(mask) > 1
            x = timeAxisSec(mask);
            y = thisMean(mask);
            e = thisSem(mask);
            fill([x, fliplr(x)], [y - e, fliplr(y + e)], lineColors(f, :), ...
                'FaceAlpha', 0.18, 'EdgeColor', 'none', 'HandleVisibility', 'off');
        end

        maskMean = isfinite(timeAxisSec) & isfinite(thisMean);
        plot(timeAxisSec(maskMean), thisMean(maskMean), 'Color', lineColors(f, :), ...
            'LineStyle', thisLineStyle, 'LineWidth', 2, 'DisplayName', freqLabels{f});
    end

    xline(0, 'k--', 'HandleVisibility', 'off');
    yline(0, 'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
    markerTimesSec = markerTimesSec(isfinite(markerTimesSec) & ...
        markerTimesSec >= timeAxisSec(1) & markerTimesSec <= timeAxisSec(end));
    if ~isempty(markerTimesSec)
        yLimits = ylim;
        jitterAmp = 0.025 * diff(yLimits);
        yLimits = [min(yLimits(1), -1.2 * jitterAmp), max(yLimits(2), 1.2 * jitterAmp)];
        ylim(yLimits);
        jitterLanes = mod(0:numel(markerTimesSec) - 1, 7) - 3;
        markerY = jitterAmp * jitterLanes / 3;
        plot(markerTimesSec, markerY, '.', ...
            'Color', [0.1 0.1 0.1], 'MarkerSize', 10, 'HandleVisibility', 'off');
    end
    xlabel(xLabelStr);
    ylabel('Log SNR (baseline-corrected to trial''s pre-cue period)');
    xlim([timeAxisSec(1), timeAxisSec(end)]);
    legend('Location', 'best');
    title(titleStr);
    subtitle(subtitleStr);
    box on;
    hold off;
end
