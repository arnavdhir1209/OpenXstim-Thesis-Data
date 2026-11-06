
%% final_dac_linear_fit.m
% Final selected open-loop linear-region DAC fits

root = fileparts(mfilename('fullpath'));
if isempty(root), root = pwd; end

outDir = fullfile(pwd, 'DAC_Sensitivity_Results');
if ~exist(outDir,'dir'), mkdir(outDir); end

% Filename stem, load in Ohms, first Counter, last Counter
fits = {
    'DAC sweep 1k',          1000, 220, 320;
    '3k DAC sweep',          3000, 230, 330;
    '4k DAC sweep',          4000, 220, 265
};

allFiles = dir(fullfile(root,'*.csv'));
results = table();

figure('Color','w','Name','Selected linear DAC fits');
tiledlayout(1,3,'TileSpacing','compact');

for j = 1:size(fits,1)

    stem = fits{j,1};
    loadOhm = fits{j,2};
    lo = fits{j,3};
    hi = fits{j,4};

    % Match filenames with or without (1), (2), etc.
    chosen = '';

    for k = 1:numel(allFiles)
        nm = regexprep(allFiles(k).name, ...
            '\s*\(\d+\)(?=\.csv$)', '', 'ignorecase');
        nm = regexprep(nm, '\.csv$', '', 'ignorecase');

        if strcmpi(nm, stem)
            chosen = allFiles(k).name;
            break;
        end
    end

    if isempty(chosen)
        warning('Missing file: %s. Skipping.', stem);
        continue;
    end

    T = readtable(fullfile(root,chosen));

    if ismember('counter_applied',T.Properties.VariableNames)
        u = double(T.counter_applied);
        valid = strcmpi(string(T.stim_state),'RUNNING');

        if ismember('fault_code',T.Properties.VariableNames)
            valid = valid & strcmpi(string(T.fault_code),'NONE');
        end

        if ismember('command_limited',T.Properties.VariableNames)
            valid = valid & double(T.command_limited)==0;
        end

        if ismember('reference_limited',T.Properties.VariableNames)
            valid = valid & double(T.reference_limited)==0;
        end
    else
        u = double(T.counter);
        valid = true(height(T),1);
    end

    I = double(T.measured_mA);

    valid = valid & isfinite(u) & isfinite(I) & ...
            u>=lo & u<=hi & I>1;

    % One median current per distinct DAC Counter
    codes = unique(u(valid));
    current = zeros(numel(codes),1);

    for k = 1:numel(codes)
        current(k) = median(I(valid & u==codes(k)));
    end

    assert(numel(codes)>=3, ...
        'Insufficient Counter levels in %s',chosen);

    coefficients = polyfit(codes,current,1);
    K = coefficients(1);
    b = coefficients(2);

    predicted = polyval(coefficients,codes);

    R2 = 1 - sum((current-predicted).^2) / ...
         sum((current-mean(current)).^2);

    results = [results; table( ...
        string(chosen),loadOhm,lo,hi,numel(codes),K,b,R2, ...
        'VariableNames',{'File','Load_Ohm', ...
        'CounterMin','CounterMax','DistinctCodes', ...
        'Gain_mA_per_count','Intercept_mA','R2'})];

    nexttile;
    plot(codes,current,'o','DisplayName','Measured median');
    hold on;
    plot(codes,predicted,'-','LineWidth',1.5, ...
        'DisplayName','Linear fit');
    xlabel('DAC Counter');
    ylabel('Current (mA)');
    title(sprintf('%s: K = %.5f',stem,K));
    legend('Location','best');
    grid on;
end

% A descriptive central estimate, not a formal pooled estimator
Knominal = mean(results.Gain_mA_per_count);

fprintf('\nSELECTED OPEN-LOOP LINEAR FITS\n');
disp(results);

fprintf('Mean linear-region gain: %.8f mA/count\n', ...
    Knominal);

writetable(results, ...
    fullfile(outDir,'final_dac_linear_fits.csv'));

save(fullfile(outDir,'final_dac_linear_fits.mat'), ...
    'results','Knominal','fits');

exportgraphics(gcf, ...
    fullfile(outDir,'final_dac_linear_fits.png'), ...
    'Resolution',200);

fprintf('Results saved to %s\n',outDir);
