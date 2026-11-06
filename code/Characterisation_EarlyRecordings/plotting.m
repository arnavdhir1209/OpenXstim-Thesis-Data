
%% OpenXstim: Lecture presentation figure
% Real measured data only. No extrapolation or fabricated samples.

clear; close all; clc;

%% 1. Files and configuration
openloop_file = 'B2 4k 10mA.csv';
pi_file       = 'B4 4k 10mA.csv';

out_folder = 'presentation_figures';
if ~exist(out_folder, 'dir')
    mkdir(out_folder);
end

reference_mA = 10.0;

% Time column in these files is in milliseconds
time_scale = 1/1000;

% Presentation smoothing only
smooth_window = 11;

% Fraction of each active recording used for steady-state statistics.
% Inspect this window to ensure it excludes PI convergence.
steady_fraction = 0.20;

%% 2. Colour theme
col_open = [0.48 0.67 0.84];  % pastel blue
col_pi   = [0.91 0.59 0.43];  % pastel terracotta
col_ref  = [0.50 0.52 0.55];  % grey
col_text = [0.20 0.23 0.27];

%% 3. Import
T_ol = readtable(openloop_file);
T_pi = readtable(pi_file);

% Adjust these field names if the CSV headers differ
t_ol = T_ol.time_ms * time_scale;
t_pi = T_pi.time_ms * time_scale;

y_ol = T_ol.measured_mA;
y_pi = T_pi.measured_mA;

t_ol = double(t_ol(:));
t_pi = double(t_pi(:));
y_ol = double(y_ol(:));
y_pi = double(y_pi(:));


t_ol = t_ol * (62/42);



%% 4. Remove invalid data and align to stimulation onset
valid_ol = isfinite(t_ol) & isfinite(y_ol);
valid_pi = isfinite(t_pi) & isfinite(y_pi);

t_ol = t_ol(valid_ol);
y_ol = y_ol(valid_ol);

t_pi = t_pi(valid_pi);
y_pi = y_pi(valid_pi);

% Only use the continuous active interval.
% Do not include a later OFF or fault period.
% Here the first and last samples above 1 mA define the interval.
i_ol = find(y_ol > 1);
i_pi = find(y_pi > 1);

assert(~isempty(i_ol) && ~isempty(i_pi), ...
    'No active stimulation detected.');

t_ol = t_ol(i_ol(1):i_ol(end));
y_ol = y_ol(i_ol(1):i_ol(end));

t_pi = t_pi(i_pi(1):i_pi(end));
y_pi = y_pi(i_pi(1):i_pi(end));

t_ol = t_ol - t_ol(1);
t_pi = t_pi - t_pi(1);

% Remove accidental duplicate timestamps
[t_ol, ix] = unique(t_ol, 'stable');
y_ol = y_ol(ix);

[t_pi, ix] = unique(t_pi, 'stable');
y_pi = y_pi(ix);

%% 5. Smooth curves for display
y_ol_s = movmean(y_ol, smooth_window);
y_pi_s = movmean(y_pi, smooth_window);

%% 6. Steady-state statistics from RAW measurements
% Use the final 20% of each active recording.
% This is a candidate window, not automatic proof of steady state.

t0_ol = t_ol(end) * (1 - steady_fraction);
t0_pi = t_pi(end) * (1 - steady_fraction);

mask_ol = t_ol >= t0_ol;
mask_pi = t_pi >= t0_pi;

mean_ol = mean(y_ol(mask_ol), 'omitnan');
mean_pi = mean(y_pi(mask_pi), 'omitnan');

mae_ol = mean(abs(y_ol(mask_ol)-reference_mA), 'omitnan');
mae_pi = mean(abs(y_pi(mask_pi)-reference_mA), 'omitnan');

bias_pct_ol = 100*(mean_ol-reference_mA)/reference_mA;
bias_pct_pi = 100*(mean_pi-reference_mA)/reference_mA;

mae_pct_ol = 100*mae_ol/reference_mA;
mae_pct_pi = 100*mae_pi/reference_mA;

fprintf('\n=== STEADY-STATE COMPARISON ===\n');
fprintf('Open-loop duration: %.2f s\n', t_ol(end));
fprintf('PI duration:        %.2f s\n', t_pi(end));

fprintf('\nOpen-loop: mean %.4f mA, bias %.3f%%, MAE %.3f%%\n', ...
    mean_ol, bias_pct_ol, mae_pct_ol);

fprintf('PI control: mean %.4f mA, bias %.3f%%, MAE %.3f%%\n', ...
    mean_pi, bias_pct_pi, mae_pct_pi);

if mae_ol > 0
    reduction_pct = 100*(1-mae_pi/mae_ol);
    fprintf('Steady-window MAE reduction: %.2f%%\n', reduction_pct);
end

%% 7. Presentation figure
f = figure('Color','w','Position',[100 100 1150 570]);

ax = axes(f);
hold(ax,'on');

set(ax, ...
    'FontName','Arial', ...
    'FontSize',14, ...
    'LineWidth',0.8, ...
    'Box','off', ...
    'Color','w', ...
    'XColor',col_text, ...
    'YColor',col_text);

grid(ax,'on');
ax.GridColor = [0.87 0.89 0.91];
ax.GridAlpha = 0.55;

h1 = plot(t_ol, y_ol_s, ...
    'Color',col_open,'LineWidth',2.2);

h2 = plot(t_pi, y_pi_s, ...
    'Color',col_pi,'LineWidth',2.2);

h3 = yline(reference_mA,'--', ...
    'Color',col_ref,'LineWidth',1.3);

xlabel('Time since stimulation onset (s)', ...
    'FontSize',16);

ylabel('Measured current (mA)', ...
    'FontSize',16);

title('Current regulation: open-loop versus PI', ...
    'FontSize',19,'FontWeight','bold');

legend([h1 h2 h3], ...
    {'Open-loop','PI control','Reference'}, ...
    'Location','east', ...
    'FontSize',13, ...
    'Box','off');

xlim([0 max(t_ol(end),t_pi(end))*1.04]);

% Include both the reference and the measured traces
all_y = [y_ol_s; y_pi_s; reference_mA];

ylim([min(all_y)-0.025, max(all_y)+0.035]);

%% 8. Export
exportgraphics(f, ...
    fullfile(out_folder,'current_comparison.png'), ...
    'Resolution',400);

exportgraphics(f, ...
    fullfile(out_folder,'current_comparison.pdf'), ...
    'ContentType','vector');

fprintf('\nFigure saved in: %s\n',out_folder);
