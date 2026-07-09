function plotRtBarsByBlock(stats, cueLabels, cueColors, titleStr, subtitleStr, figureName)
% plotRtBarsByBlock  Grouped bar chart of mean +/- SEM reaction time (see
% computeRtStatsByBlockAndCue.m): one group of bars per block, one bar per
% cue within each group, side by side.
%
%   stats: struct from computeRtStatsByBlockAndCue.m (blocks, meanRt,
%       semRt).
%   cueLabels: cellstr, one per cue column, e.g. {'c1', 'c2'}.
%   cueColors: numel(cueLabels) x 3 RGB triples in [0, 1].
%   titleStr, subtitleStr: figure title/subtitle.
%   figureName: optional short MATLAB window name.

    if nargin < 6 || isempty(figureName)
        figureName = titleStr;
    end

    figure('Name', figureName, 'Color', 'w');
    hold on;

    x = 1:numel(stats.blocks);
    barHandles = bar(x, stats.meanRt);
    numCues = numel(barHandles);
    for c = 1:numCues
        barHandles(c).FaceColor = cueColors(c, :);
        barHandles(c).DisplayName = cueLabels{c};
        errorbar(barHandles(c).XEndPoints, stats.meanRt(:, c).', stats.semRt(:, c).', ...
            'k', 'LineStyle', 'none', 'HandleVisibility', 'off', 'CapSize', 8, 'LineWidth', 1);
    end

    xticks(x);
    xticklabels(arrayfun(@(b) sprintf('Block %d', b), stats.blocks, 'UniformOutput', false));
    xlabel('Block');
    ylabel('Mean reaction time (s)');
    legend('Location', 'best');
    title(titleStr);
    subtitle(subtitleStr);
    box on;
    hold off;
end
