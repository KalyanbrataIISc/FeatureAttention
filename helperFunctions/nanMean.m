function value = nanMean(values)
    values = values(~isnan(values));
    if isempty(values)
        value = NaN;
    else
        value = mean(values);
    end
end
