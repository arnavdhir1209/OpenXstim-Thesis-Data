
%% openxstim_B2B4_params.m
% Stage 1 parameters from B2 and B4.
% Requires standard MATLAB and Simulink.

P = struct();

P.model = 'OpenXstim_B2B4_PI';

thisFolder = fileparts(mfilename('fullpath'));

if isempty(thisFolder)
    thisFolder = pwd;
end

P.B2file = fullfile(thisFolder, 'B2 4k 10mA.csv');
P.B4file = fullfile(thisFolder, 'B4 4k 10mA.csv');

assert(isfile(P.B2file) && isfile(P.B4file), ...
    'Place both CSV files alongside this script.');

%% Load experimental data

T2 = readtable(P.B2file);
T4 = readtable(P.B4file);

run2 = strcmp(string(T2.stim_state), 'RUNNING') & ...
       isfinite(T2.measured_mA);

run4 = strcmp(string(T4.stim_state), 'RUNNING') & ...
       isfinite(T4.measured_mA);

P.B2 = T2(run2,:);
P.B4 = T4(run4,:);

assert(height(P.B2) > 100 && height(P.B4) > 100, ...
    'Insufficient valid RUNNING data.');

P.tB2 = (double(P.B2.time_ms) - ...
         double(P.B2.time_ms(1))) / 1000;

P.tB4 = (double(P.B4.time_ms) - ...
         double(P.B4.time_ms(1))) / 1000;

%% Independent B2 open-loop operating point

P.anchorCounter = 215;

assert(all(double(P.B2.counter_applied) == ...
           P.anchorCounter), ...
    'B2 does not have a constant applied Counter.');

P.anchorCurrent = mean(double(P.B2.measured_mA));

P.noiseResiduals = double(P.B2.measured_mA) - ...
                   P.anchorCurrent;

P.noiseStd = std(P.noiseResiduals);

%% Provisional plant sensitivity from B4

% B2 has only one applied Counter, so B2 cannot
% independently identify the DAC-to-current slope.

fitB4 = polyfit( ...
    double(P.B4.counter_applied), ...
    double(P.B4.measured_mA), 1);

P.Kplant = fitB4(1);

P.plantOffset = P.anchorCurrent - ...
                P.Kplant * P.anchorCounter;

%% Empirical PI controller parameters

P.r = 10;         % mA
P.Cff = 21.5;     % Counter per mA
P.Kp = 5;         % Counter per mA
P.Ki = 3;         % Counter per (mA*s)

P.u0 = 215;
P.xI0 = 0;

%% Controller timing from oscilloscope analysis

P.Ts_short = 0.076;   % seconds
P.Ts_long  = 0.089;   % seconds

% Stage 1: fixed nominal sampling period
P.Ts = (P.Ts_short + P.Ts_long) / 2;

% Preserve the B4 timing for comparison
P.Ts_B4 = mean(diff(P.tB4));


% Approximate deadband observed in B4.
P.deadband = 0.03;

P.enablePI = 1;
P.noiseEnabled = 1;

P.finalWindow = 5;
P.stopTime = P.tB4(end);

%% Reproducible noise from B2 measurements

rng(42, 'twister');

N = ceil(max(P.tB2(end), P.tB4(end)) / P.Ts) + 4;

idx = randi(numel(P.noiseResiduals), N, 1);

% Preserve first B2 measurement for the initial sample.
idx(1) = 1;

noise = P.noiseResiduals(idx);

P.noiseInput = [(0:N-1)' * P.Ts, noise];

assignin('base', 'B2_noise_input', P.noiseInput);

%% Summary

fprintf('\nB2 OPEN LOOP\n');

fprintf('Valid bursts: %d\n', height(P.B2));

fprintf('Counter: %d\n', P.anchorCounter);

fprintf('Mean current: %.6f mA\n', P.anchorCurrent);

fprintf('Current SD: %.6f mA\n', P.noiseStd);

fprintf('\nB4 CLOSED LOOP\n');

fprintf('Valid bursts: %d\n', height(P.B4));

fprintf('Nominal Ts: %.6f s\n', P.Ts);

fprintf('Provisional slope: %.6f mA/count\n', ...
    P.Kplant);

fprintf('\nPlant model:\n');

fprintf('I = %.6f + %.6f*(Counter - %d)\n', ...
    P.anchorCurrent, P.Kplant, P.anchorCounter);

fprintf(['NOTE: The slope is fitted from closed-loop B4 ' ...
         'and requires independent validation.\n']);
