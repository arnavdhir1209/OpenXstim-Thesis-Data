
%% OpenXstim - Lecture Presentation Current Comparison
% Open-loop versus PI current regulation at a fixed 4 kOhm load.
%
% Solid lines: measured data, smoothed for presentation.
% Dashed blue extension: illustrative steady-state extrapolation.
%
% IMPORTANT:
% Extrapolated samples are never included in error calculations.

clear; close all; clc;

%% ===================== 1. USER SETTINGS =====================

openloop_file = 'B2 4k 10mA.csv';
pi_file       = 'B4 4k 10mA.csv';

out_folder = 'presentation_figures';

if ~exist(out_folder, 'dir')
    mkdir(out_folder);
end

reference_mA = 10.0;

% The CSV time column is in milliseconds.
time_scale = 1/1000;

% Number of samples for presentation-only smoothing
smooth_window = 11;

% Final fraction of each active recording used for
% calculating steady-state statistics.
steady_fraction = 0.20;

% Extend the open-loop curve to match PI duration
extend_openloop = true;

% High-resolution image export
export_dpi = 400;

%% ===================== 2. THEME =====================

col_open = [0.48 0.67 0.84];  % Pastel blue
col_pi   = [0.91 0.59 0.43];  % Pastel terracotta
col_ref  = [0.50 0.52 0.55];  % Soft grey
col_text = [0.20 0.23 0.27];
col_grid = [0.87 0.89 0.91];

font_name = 'Arial';

%% ===================== 3. IMPORT DATA =====================

T_ol = readtable(openloop_file);
T_pi = readtable(pi_file);

% These names match the existing experiment CSV format.
t_ol = double(T_ol.time_ms(:)) * time_scale;
t_pi = double(T_pi.time_ms(:)) * time_scale;

y_ol = double(T_ol.measured_mA(:));
y_pi = double(T_pi.measured_mA(:));

%% ===================== 4. VALIDATE DATA =====================

valid_ol = isfinite(t_ol) & isfinite(y_ol);
valid_pi = isfinite(t_pi) & isfinite(y_pi);

t_ol = t_ol(valid_ol);
y_ol = y_ol(valid_ol);

t_pi = t_pi(valid_pi);
y_pi = y_pi(valid_pi);

assert(~isempty(t_ol) && ~isempty(t_pi), ...
    'One or both recordings contain no valid samples.');

%% ===================== 5. EXTRACT ACTIVE PERIOD =====================

% Find the first and last samples with nonzero stimulation.
% Assumes each file contains one principal active test interval.

active_threshold_mA = 1.0;

idx_ol = find(y_ol > active_threshold_mA);
idx_pi = find(y_pi > active_threshold_mA);

assert(~isempty(idx_ol) && ~isempty(idx_pi), ...
    'Could not identify an active stimulation interval.');

t_ol = t_ol(idx_ol(1):idx_ol(end));
y_ol = y_ol(idx_ol(1):idx_ol(end));

t_pi = t_pi(idx_pi(1):idx_pi(end));
y_pi = y_pi(idx_pi(1):idx_pi(end));

% Align both experiments to their first active measurement.
t_ol = t_ol - t_ol(1);
t_pi = t_pi - t_pi(1);

% Remove duplicate time stamps.
[t_ol, idx] = unique(t_ol, 'stable');
y_ol = y_ol(idx);

[t_pi, idx] = unique(t_pi, 'stable');
y_pi = y_pi(idx);

% Sort chronologically.
[t_ol, idx] = sort(t_ol);
y_ol = y_ol(idx);

[t_pi, idx] = sort(t_pi);
y_pi = y_pi(idx);

%% ===================== 6. SMOOTH FOR DISPLAY =====================

% The raw measurements remain unchanged.
y_ol_s = movmean(y_ol, smooth_window);
y_pi_s = movmean(y_pi, smooth_window);

%% ===================== 7. STEADY-STATE STATISTICS =====================

% Final 20% of the actual ACTIVE recording.
% Verify visually that this interval is steady.

steady_start_ol = t_ol(end) * (1-steady_fraction);
steady_start_pi = t_pi(end) * (1-steady_fraction);

mask_ol = t_ol >= steady_start_ol;
mask_pi = t_pi >= steady_start_pi;

% Mean measured current
mean_ol = mean(y_ol(mask_ol), 'omitnan');
mean_pi = mean(y_pi(mask_pi), 'omitnan');

% Mean absolute error
mae_ol = mean(abs(y_ol(mask_ol)-reference_mA), 'omitnan');
mae_pi = mean(abs(y_pi(mask_pi)-reference_mA), 'omitnan');

% RMSE
rmse_ol = sqrt(mean( ...
    (y_ol(mask_ol)-reference_mA).^2, 'omitnan'));

rmse_pi = sqrt(mean( ...
    (y_pi(mask_pi)-reference_mA).^2, 'omitnan'));

% Signed steady-state bias
bias_ol = mean_ol-reference_mA;
bias_pi = mean_pi-reference_mA;

% Normalised metrics
bias_pct_ol = 100*bias_ol/reference_mA;
bias_pct_pi = 100*bias_pi/reference_mA;

mae_pct_ol = 100*mae_ol/reference_mA;
mae_pct_pi = 100*mae_pi/reference_mA;

% Relative MAE reduction
if mae_ol > 0
    mae_reduction_pct = 100*(1-mae_pi/mae_ol);
else
    mae_reduction_pct = NaN;
end

%% ===================== 8. PRINT RESULTS =====================

fprintf('\n');
fprintf('============================================\n');
fprintf(' OPENXSTIM STEADY-STATE COMPARISON\n');
fprintf('============================================\n');

fprintf('\nREFERENCE: %.3f mA\n',reference_mA);

fprintf('\nOPEN LOOP\n');
fprintf('Recorded duration: %.2f s\n',t_ol(end));
fprintf('Mean current: %.4f mA\n',mean_ol);
fprintf('Mean absolute error: %.4f mA\n',mae_ol);
fprintf('RMSE: %.4f mA\n',rmse_ol);
fprintf('Signed bias: %.4f mA\n',bias_ol);
fprintf('Normalised MAE: %.3f %%\n',mae_pct_ol);
fprintf('Normalised bias: %.3f %%\n',bias_pct_ol);

fprintf('\nPI CONTROL\n');
fprintf('Recorded duration: %.2f s\n',t_pi(end));
fprintf('Mean current: %.4f mA\n',mean_pi);
fprintf('Mean absolute error: %.4f mA\n',mae_pi);
fprintf('RMSE: %.4f mA\n',rmse_pi);
fprintf('Signed bias: %.4f mA\n',bias_pi);
fprintf('Normalised MAE: %.3f %%\n',mae_pct_pi);
fprintf('Normalised bias: %.3f %%\n',bias_pct_pi);

fprintf('\nCOMPARISON\n');
fprintf('Steady-state MAE reduction: %.2f %%\n', ...
    mae_reduction_pct);

%% ===================== 9. OPEN-LOOP EXTENSION =====================

% Extend open-loop for VISUAL COMPARISON ONLY.
%
% A constant-value extrapolation is used, based on the
% actual steady-state mean.
%
% Do not use these values as experimental measurements.

t_extended = [];
y_extended = [];

if extend_openloop && t_pi(end) > t_ol(end)

    % Use original median sampling interval.
    dt = median(diff(t_ol));

    assert(isfinite(dt) && dt > 0, ...
        'Invalid open-loop sampling interval.');

    % Generate times after last actual open-loop sample.
    t_extended = ((t_ol(end)+dt):dt:t_pi(end))';

    % Extrapolate the measured steady-state mean.
    y_extended = mean_ol * ones(size(t_extended));

end

%% ===================== 10. PRESENTATION FIGURE =====================

f = figure( ...
    'Color','w', ...
    'Position',[100 100 1150 570]);

ax = axes(f);
hold(ax,'on');

set(ax, ...
    'FontName',font_name, ...
    'FontSize',14, ...
    'LineWidth',0.8, ...
    'Box','off', ...
    'Color','w', ...
    'XColor',col_text, ...
    'YColor',col_text);

grid(ax,'on');

ax.GridColor = col_grid;
ax.GridAlpha = 0.55;

% Original measured open-loop data
h_open = plot(t_ol,y_ol_s, ...
    'Color',col_open, ...
    'LineWidth',2.2, ...
    'DisplayName','Open-loop (measured)');

% Open-loop illustrative extension
if ~isempty(t_extended)

    h_ext = plot( ...
        [t_ol(end); t_extended], ...
        [y_ol_s(end); y_extended], ...
        '--', ...
        'Color',col_open, ...
        'LineWidth',1.7, ...
        'DisplayName','Open-loop (extrapolated)');

    % Mark end of actual open-loop recording
    xline(t_ol(end),':', ...
        'Open-loop recording ends', ...
        'Color',col_open, ...
        'FontSize',10, ...
        'LabelVerticalAlignment','bottom', ...
        'LabelHorizontalAlignment','right', ...
        'HandleVisibility','off');

else
    h_ext = [];
end

% PI measured response
h_pi = plot(t_pi,y_pi_s, ...
    'Color',col_pi, ...
    'LineWidth',2.2, ...
    'DisplayName','PI control (measured)');

% Reference line
h_ref = yline(reference_mA,'--', ...
    'Color',col_ref, ...
    'LineWidth',1.4, ...
    'DisplayName','Reference');

%% ===================== 11. FORMATTING =====================

xlabel('Time since stimulation onset (s)', ...
    'FontSize',16);

ylabel('Measured current (mA)', ...
    'FontSize',16);

title('Current regulation: open-loop versus PI', ...
    'FontSize',19, ...
    'FontWeight','bold');

if ~isempty(h_ext)
    legend([h_open h_ext h_pi h_ref], ...
        {'Open-loop (measured)', ...
         'Open-loop (extrapolated)', ...
         'PI control (measured)', ...
         'Reference'}, ...
        'Location','southeast', ...
        'FontSize',12, ...
        'Box','off');
else
    legend([h_open h_pi h_ref], ...
        {'Open-loop (measured)', ...
         'PI control (measured)', ...
         'Reference'}, ...
        'Location','southeast', ...
        'FontSize',12, ...
        'Box','off');
end

% Time limits
xlim([0 max(t_ol(end),t_pi(end))*1.04]);

% Include all measured and extrapolated curves in vertical limits
all_y = [y_ol_s; y_pi_s; reference_mA];

if ~isempty(y_extended)
    all_y = [all_y; y_extended];
end

ylim([min(all_y)-0.025, max(all_y)+0.035]);

%% ===================== 12. EXPORT =====================

png_file = fullfile(out_folder,'current_comparison.png');
pdf_file = fullfile(out_folder,'current_comparison.pdf');

exportgraphics(f,png_file, ...
    'Resolution',export_dpi);

exportgraphics(f,pdf_file, ...
    'ContentType','vector');

fprintf('\n============================================\n');
fprintf(' FIGURE EXPORT COMPLETE\n');
fprintf('============================================\n');

fprintf('PNG: %s\n',png_file);
fprintf('PDF: %s\n',pdf_file);

if ~isempty(t_extended)
    fprintf('\nOpen-loop extrapolated from %.2f s to %.2f s.\n', ...
        t_ol(end),t_extended(end));
    fprintf('Extrapolated value: %.4f mA\n',mean_ol);
    fprintf('Extrapolated values excluded from ALL statistics.\n');
end
