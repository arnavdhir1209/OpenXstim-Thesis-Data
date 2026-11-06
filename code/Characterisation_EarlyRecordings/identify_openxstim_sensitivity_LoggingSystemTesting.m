
%% identify_openxstim_sensitivity.m
% Standalone DAC-current sensitivity study.
% Place this script alongside the CSV files.
%
% Does NOT modify the Simulink model.
%
% Output folder:
%   DAC_Sensitivity_Results
%
% Outputs:
%   dac_sensitivity_results.csv
%   dac_sensitivity_results.mat
%   dac_sensitivity_by_load.png

clearvars;
close all;
clc;

%% 1. Set working directories

% Location of this MATLAB script and the input CSV files
root = fileparts(mfilename('fullpath'));

if isempty(root)
    root = pwd;
end

% Save results in a dedicated folder in the working directory
outputDir = fullfile(pwd, 'DAC_Sensitivity_Results');

if ~exist(outputDir, 'dir')
    mkdir(outputDir);
end

%% 2. Import dataset definitions

% Each row contains:
% Dataset name, load (Ohms), operating mode, CSV format
%
% standard: Original controller CSV format
% simple:   New DAC sweep CSV format

files = { ...
    'Open Loop DAC sweep 1k',  1000, 'OPEN_LOOP',  'standard'; ...
    'Open Loop 1k',            1000, 'OPEN_LOOP',  'standard'; ...
    'PI_Control DAC Sweep 1k', 1000, 'PI_CONTROL', 'standard'; ...
    'B1 2k 10mA',             2000, 'OPEN_LOOP',  'standard'; ...
    'B3 2k 10mA',             2000, 'PI_CONTROL', 'standard'; ...
    'B2 4k 10mA',             4000, 'OPEN_LOOP',  'standard'; ...
    'B4 4k 10mA',             4000, 'PI_CONTROL', 'standard'; ...
    'DAC sweep 1k',           1000, 'OPEN_LOOP',  'simple'; ...
    '3k DAC sweep',           3000, 'OPEN_LOOP',  'simple'; ...
    '4k DAC sweep',           4000, 'OPEN_LOOP',  'simple'; ...
    '5k1 DAC sweep',          5100, 'OPEN_LOOP',  'simple'; ...
    'DAC sweep 5k7',          5700, 'OPEN_LOOP',  'simple' ...
};

%% 3. Find CSV files automatically

% Ignore numerical filename suffixes:
%
%   B2 4k 10mA.csv
%   B2 4k 10mA(1).csv
%   B2 4k 10mA(2).csv
%
% All resolve to the same dataset name.

allCSV = dir(fullfile(root, '*.csv'));

for k = 1:numel(allCSV)

    allCSV(k).canonical = lower(regexprep( ...
        allCSV(k).name, ...
        '\s*\(\d+\)(?=\.csv$)', ...
        '', ...
        'ignorecase'));

    allCSV(k).canonical = regexprep( ...
        allCSV(k).canonical, ...
        '\.csv$', '');

end

%% 4. Analysis settings

% Local DAC range relevant to the 10 mA target
localCounterRange = [195 235];

% Minimum number of distinct DAC Counters needed
% to calculate a sensitivity
minDistinct = 2;

% Store results
result = table();
detail = struct([]);

%% 5. Prepare comparison figure

figure( ...
    'Name', 'DAC-to-current sensitivity by load', ...
    'Color', 'w');

loads = unique(cell2mat(files(:,2)))';

tiledlayout(2, 3, 'TileSpacing', 'compact');

for q = 1:numel(loads)

    nexttile;

    hold on;
    grid on;

    xlabel('Applied DAC Counter');
    ylabel('Measured current (mA)');

    title(sprintf('%g kOhm', loads(q)/1000));

end

%% 6. Analyse every dataset

for j = 1:size(files,1)

    wantedName = files{j,1};
    R = files{j,2};

    modeExpected = files{j,3};
    schema = files{j,4};

    %% Find the matching CSV

    matches = find(strcmp( ...
        {allCSV.canonical}, ...
        lower(wantedName)));

    if isempty(matches)

        warning( ...
            'Missing dataset %s. Skipping.', ...
            wantedName);

        continue;

    end

    if numel(matches) > 1

        warning( ...
            'Multiple files matched %s. Using %s.', ...
            wantedName, ...
            allCSV(matches(1)).name);

    end

    filename = allCSV(matches(1)).name;
    fullpath = fullfile(root, filename);

    fprintf('\nProcessing: %s\n', filename);

    T = readtable(fullpath);

    %% Read original controller CSV format

    if strcmp(schema, 'standard')

        needed = { ...
            'stim_state', ...
            'mode', ...
            'counter_applied', ...
            'measured_mA' ...
        };

        assert( ...
            all(ismember(needed, T.Properties.VariableNames)), ...
            'Expected standard columns absent in %s', ...
            filename);

        valid = ...
            strcmpi(string(T.stim_state), 'RUNNING') & ...
            strcmpi(string(T.mode), modeExpected) & ...
            isfinite(double(T.counter_applied)) & ...
            isfinite(double(T.measured_mA));

        % Exclude fault conditions where available
        if ismember('fault_code', T.Properties.VariableNames)

            valid = valid & ...
                strcmpi(string(T.fault_code), 'NONE');

        end

        % Exclude command-limited samples
        if ismember('command_limited', T.Properties.VariableNames)

            valid = valid & ...
                double(T.command_limited) == 0;

        end

        % Exclude reference-limited samples
        if ismember('reference_limited', T.Properties.VariableNames)

            valid = valid & ...
                double(T.reference_limited) == 0;

        end

        counterColumn = double(T.counter_applied);

    %% Read newer, simpler DAC sweep format

    else

        needed = {'counter', 'measured_mA'};

        assert( ...
            all(ismember(needed, T.Properties.VariableNames)), ...
            'Expected sweep columns absent in %s', ...
            filename);

        counterColumn = double(T.counter);

        valid = ...
            isfinite(counterColumn) & ...
            isfinite(double(T.measured_mA));

        % These files do not contain RUNNING or fault flags.
        % Near-zero measurements are initially retained.
        % They may be rejected as within-Counter outliers below.

    end

    %% Extract usable samples

    u = counterColumn(valid);
    y = double(T.measured_mA(valid));

    before = numel(u);

    if isempty(u)

        warning('No valid samples in %s', filename);
        continue;

    end

    %% 7. Screen extreme measurement outliers

    % Compare measurements at the SAME DAC Counter.
    %
    % This avoids accidentally removing valid high-current
    % observations from large Counter values.
    %
    % Require at least 5 measurements per Counter before
    % applying this outlier screen.

    keep = true(size(u));

    codes = unique(u);

    for c = codes(:)'

        ix = find(u == c);

        if numel(ix) < 5
            continue;
        end

        med = median(y(ix));

        mad0 = median(abs(y(ix) - med));

        % Robust spread estimate with a 0.25 mA floor
        threshold = max(0.25, 6 * 1.4826 * mad0);

        keep(ix) = abs(y(ix) - med) <= threshold;

    end

    u = u(keep);
    y = y(keep);

    excluded = before - numel(u);

    %% 8. Group measurements by DAC Counter

    codes = unique(u);

    nCodes = numel(codes);

    groupMean = zeros(nCodes,1);
    groupMedian = zeros(nCodes,1);
    groupN = zeros(nCodes,1);

    for k = 1:nCodes

        z = y(u == codes(k));

        groupMean(k) = mean(z);
        groupMedian(k) = median(z);
        groupN(k) = numel(z);

    end

    %% 9. Fit DAC-to-current sensitivity

    slope = NaN;
    intercept = NaN;
    R2 = NaN;

    slopeGrouped = NaN;
    localSlope = NaN;

    if nCodes >= minDistinct

        % Fit 1: Ordinary regression using all valid samples
        coeff = polyfit(u, y, 1);

        slope = coeff(1);
        intercept = coeff(2);

        pred = polyval(coeff, u);

        denom = sum((y - mean(y)).^2);

        if denom > 0

            R2 = 1 - sum((y - pred).^2) / denom;

        end

        % Fit 2: Regression on one median per DAC Counter
        %
        % This gives each distinct Counter equal weighting.
        coeffG = polyfit(codes, groupMedian, 1);

        slopeGrouped = coeffG(1);

        % Fit 3: Local regression near the operating point
        m = ...
            u >= localCounterRange(1) & ...
            u <= localCounterRange(2);

        if numel(unique(u(m))) >= minDistinct

            coeffL = polyfit(u(m), y(m), 1);

            localSlope = coeffL(1);

        end

    end

    %% 10. Store results

    label = string(filename);

    result = [result; table( ...
        label, ...
        R, ...
        string(modeExpected), ...
        numel(u), ...
        nCodes, ...
        excluded, ...
        slope, ...
        slopeGrouped, ...
        localSlope, ...
        intercept, ...
        R2, ...
        'VariableNames', { ...
            'File', ...
            'Load_Ohm', ...
            'Mode', ...
            'Samples', ...
            'DistinctCodes', ...
            'Excluded', ...
            'SlopeRaw_mA_per_count', ...
            'SlopeGroupMedian', ...
            'SlopeLocal', ...
            'Intercept_mA', ...
            'R2' ...
        })]; %#ok<AGROW>

    detail(end+1).file = filename; %#ok<SAGROW>

    detail(end).loadOhm = R;
    detail(end).mode = modeExpected;

    detail(end).codes = codes;
    detail(end).medianCurrent = groupMedian;

    detail(end).meanCurrent = groupMean;
    detail(end).counts = groupN;

    %% 11. Plot the results for this load

    tile = find(loads == R);

    nexttile(tile);

    if strcmp(modeExpected, 'OPEN_LOOP')

        lineStyle = 'o-';

    else

        lineStyle = 's--';

    end

    plot( ...
        codes, ...
        groupMedian, ...
        lineStyle, ...
        'DisplayName', erase(filename, '.csv'));

    legend( ...
        'Location', 'best', ...
        'Interpreter', 'none');

end

%% 12. Display the full results table

disp(' ');
disp('PER-DATASET DAC SENSITIVITY');

disp(result);

%% 13. Save all results

writetable( ...
    result, ...
    fullfile(outputDir, 'dac_sensitivity_results.csv'));

save( ...
    fullfile(outputDir, 'dac_sensitivity_results.mat'), ...
    'result', ...
    'detail', ...
    'localCounterRange');

exportgraphics( ...
    gcf, ...
    fullfile(outputDir, 'dac_sensitivity_by_load.png'), ...
    'Resolution', 200);

%% 14. Print an interpretation by load

fprintf('\nMAIN INTERPRETATION\n');

for R = loads

    ix = ...
        result.Load_Ohm == R & ...
        result.Mode == "OPEN_LOOP" & ...
        result.DistinctCodes >= 2;

    if any(ix)

        subset = result(ix,:);

        % Use the open-loop dataset with the largest
        % number of distinct tested Counters.

        [~,k] = max(subset.DistinctCodes);

        fprintf( ...
            ['%g kOhm: strongest open-loop sweep = %s, ' ...
             'K = %.6f mA/count (%d codes)\n'], ...
            R/1000, ...
            subset.File(k), ...
            subset.SlopeRaw_mA_per_count(k), ...
            subset.DistinctCodes(k));

    else

        fprintf( ...
            '%g kOhm: no multi-code open-loop fit available.\n', ...
            R/1000);

    end

end

fprintf('\n');
fprintf('Do not pool loads or use closed-loop slopes as independent validation.\n');

fprintf('Results saved in:\n%s\n', outputDir);
