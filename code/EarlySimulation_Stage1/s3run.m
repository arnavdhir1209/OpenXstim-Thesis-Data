
%% s3run.m
% OpenXstim Stage 1: Compare PI control with and without noise.
%
% Run after:
%   s1param
%   s2build
%
% Outputs:
%   Figure 1: Combined current response
%   Figure 2: Separate current responses
%   Figure 3: DAC commands and tracking error
%   Numerical comparison and MAT results file
%
% Uses the same plant, gains and noise sequence in both runs.

%% 1. Load model and parameters

if ~exist('P','var') || ~isfield(P,'B2')
    s1param;
end

if ~bdIsLoaded(P.model)
    load_system(P.model);
end

% Make the reproducible B2 residual sequence available.
assignin('base','B2_noise_input',P.noiseInput);

% Both simulations use the same controller settings.
set_param([P.model '/Enable_PI'],'Gain','1');

% Use 60 seconds for both comparisons.
simulationDuration = 60;

set_param(P.model, ...
    'StopTime',num2str(simulationDuration,17));

fprintf('\nOpenXstim PI noise comparison\n');
fprintf('Nominal sampling interval: %.4f s\n',P.Ts);
fprintf('Kp = %.3f, Ki = %.3f\n',P.Kp,P.Ki);

%% 2. Run noise-free PI simulation

fprintf('\nRunning noise-free simulation...\n');

set_param([P.model '/Noise_enable'],'Gain','0');

outClean = sim(P.model);

clean = extractSignals(outClean);

%% 3. Run PI simulation with measurement noise

fprintf('Running simulation with B2-derived noise...\n');

set_param([P.model '/Noise_enable'],'Gain','1');

outNoisy = sim(P.model);

noisy = extractSignals(outNoisy);

% Restore the model to noise-free operation.
set_param([P.model '/Noise_enable'],'Gain','0');

%% 4. Figure 1: Both current responses on one graph

figure('Name','PI current comparison', ...
       'Color','w');

plot(clean.measured.time,clean.measured.data, ...
    'LineWidth',1.5, ...
    'DisplayName','Without noise');

hold on;

plot(noisy.measured.time,noisy.measured.data, ...
    'LineWidth',0.7, ...
    'DisplayName','With noise');

yline(P.r,'k--', ...
    'DisplayName','Reference (10 mA)');

xlabel('Time (s)');
ylabel('Measured current (mA)');

title('OpenXstim PI Control: With and Without Noise');

legend('Location','southeast');
grid on;

%% 5. Figure 2: Individual responses

figure('Name','Separate current responses', ...
       'Color','w');

subplot(2,1,1);

plot(clean.measured.time,clean.measured.data, ...
    'LineWidth',1.2);

hold on;
yline(P.r,'k--');

ylabel('Current (mA)');
title('A. PI Control Without Measurement Noise');
grid on;

subplot(2,1,2);

plot(noisy.measured.time,noisy.measured.data, ...
    'LineWidth',0.8);

hold on;
yline(P.r,'k--');

xlabel('Time (s)');
ylabel('Current (mA)');
title('B. PI Control With Measurement Noise');
grid on;

%% 6. Figure 3: Controller behaviour

figure('Name','DAC commands and tracking error', ...
       'Color','w');

subplot(2,1,1);

stairs(clean.counter.time,clean.counter.data, ...
    'LineWidth',1.3, ...
    'DisplayName','Without noise');

hold on;

stairs(noisy.counter.time,noisy.counter.data, ...
    'LineWidth',0.8, ...
    'DisplayName','With noise');

ylabel('Applied DAC Counter');
title('Controller Output');

legend('Location','southeast');
grid on;

subplot(2,1,2);

plot(clean.error.time,clean.error.data, ...
    'LineWidth',1.2, ...
    'DisplayName','Without noise');

hold on;

plot(noisy.error.time,noisy.error.data, ...
    'LineWidth',0.7, ...
    'DisplayName','With noise');

yline(0,'k:');

xlabel('Time (s)');
ylabel('Current error (mA)');
title('Tracking Error');

legend('Location','northeast');
grid on;

%% 7. Calculate performance metrics

% Only use the final five seconds for steady-state metrics.
finalWindow = 5;

cleanFinal = clean.measured.time >= ...
    simulationDuration-finalWindow;

noisyFinal = noisy.measured.time >= ...
    simulationDuration-finalWindow;

meanClean = mean(clean.measured.data(cleanFinal));
meanNoisy = mean(noisy.measured.data(noisyFinal));

sdClean = std(clean.measured.data(cleanFinal));
sdNoisy = std(noisy.measured.data(noisyFinal));

rmseClean = sqrt(mean( ...
    (P.r-clean.measured.data).^2));

rmseNoisy = sqrt(mean( ...
    (P.r-noisy.measured.data).^2));

% Controller output activity
changesClean = sum(abs(diff(clean.counter.data))>0);
changesNoisy = sum(abs(diff(noisy.counter.data))>0);

% Overshoot relative to reference
overshootClean = max(0,max(clean.true.data)-P.r);
overshootNoisy = max(0,max(noisy.true.data)-P.r);

%% 8. Print results

fprintf('\n======================================\n');
fprintf('       PI NOISE COMPARISON\n');
fprintf('======================================\n');

fprintf('\n%-30s %12s %12s\n', ...
    'Metric','No noise','With noise');

fprintf('%-30s %12.5f %12.5f\n', ...
    'Final mean current (mA)',meanClean,meanNoisy);

fprintf('%-30s %12.5f %12.5f\n', ...
    'Final current SD (mA)',sdClean,sdNoisy);

fprintf('%-30s %12.5f %12.5f\n', ...
    'Overall RMSE (mA)',rmseClean,rmseNoisy);

fprintf('%-30s %12.5f %12.5f\n', ...
    'True-current overshoot (mA)', ...
    overshootClean,overshootNoisy);

fprintf('%-30d %12d %12d\n', ...
    'Number of DAC changes', ...
    changesClean,changesNoisy);

fprintf('%-30d %12d %12d\n', ...
    'Final DAC Counter', ...
    round(clean.counter.data(end)), ...
    round(noisy.counter.data(end)));

fprintf('\n');

%% 9. Verify controller command indexing

% Applied counter at burst k+1 must equal
% the next counter calculated for burst k.

checkIndexing(clean,'Noise-free');
checkIndexing(noisy,'Noisy');

%% 10. Save results and figures

save('OpenXstim_Noise_Comparison.mat', ...
    'P','clean','noisy', ...
    'meanClean','meanNoisy', ...
    'sdClean','sdNoisy', ...
    'rmseClean','rmseNoisy');

figs = findobj('Type','figure');

for k = 1:numel(figs)

    f = figs(k);

    filename = sprintf( ...
        'OpenXstim_Comparison_Figure_%d.png',f.Number);

    exportgraphics(f,filename,'Resolution',200);

end

fprintf('Noise comparison complete.\n');
fprintf('Saved numerical results and figure images.\n');

%% Local helper functions

function S = extractSignals(out)

    S.measured = extractOne(out,'measured_mA');
    S.true = extractOne(out,'true_mA');
    S.reference = extractOne(out,'reference_mA');
    S.error = extractOne(out,'error_mA');
    S.counter = extractOne(out,'counter_applied');
    S.next = extractOne(out,'counter_next');
    S.integral = extractOne(out,'integral_counts');
    S.proportional = extractOne(out,'proportional_counts');

end

function s = extractOne(out,name)

    ts = out.get(name);

    s.time = double(ts.Time(:));
    s.data = double(ts.Data(:));

    assert(numel(s.time)==numel(s.data), ...
        'Time/data mismatch for %s.',name);

    assert(all(isfinite(s.data)), ...
        'Nonfinite values in %s.',name);

end

function checkIndexing(S,label)

    a = S.counter.data;
    n = S.next.data;

    N = min(numel(a)-1,numel(n));

    assert(N>=1, ...
        'Insufficient command samples.');

    assert(all(a(2:N+1)==n(1:N)), ...
        '%s: Incorrect DAC command indexing.',label);

    fprintf('%s: %d DAC transitions verified.\n',label,N);

end
