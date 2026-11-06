%% UnitPulseAnalysis.m
% OpenXstim isolated-step characterisation
%
% Folder layout expected:
%
%   UnitPulseAnalysis.m
%   Rise/
%       CH1.CSV     % Arduino / DAC SYNC timing reference
%       CH2.CSV     % voltage across 1 kOhm load
%   Fall/
%       CH1.CSV
%       CH2.CSV
%
% Experiment:
%   Rise capture: 0 mA -> 10 mA
%   Fall capture: 10 mA -> 0 mA
%
% CH1 is used ONLY to determine command timing.
% Its measured voltage amplitude is not used as the plant input.
%
% CH2 is converted to load current using:
%
%       I_mA = 1000 * Vload / Rload
%
% For Rload = 1000 ohm:
%
%       I_mA = Vload
%
% numerically, when Vload is expressed in volts.
%
% For system identification, MATLAB reconstructs the known input as:
%
%       u(t) = 0 mA,   t < 0
%              10 mA,  t >= 0
%
% The falling response is sign-corrected so that it can be compared with
% the rising response as another positive 0 -> 10 mA incremental step.
%
% Candidate continuous-time models:
%   P1  : first-order
%   P1D : first-order plus dead time
%   P2  : second-order, two real poles
%
% Recommended interpretation:
%   Use one capture for estimation and the opposite transition for
%   independent validation.
%
% IMPORTANT:
%   The timing origin is the observed CH1/SYNC event. Any firmware execution
%   delay before that observable event is outside this measured boundary.

clear;
clc;
close all;

%% USER SETTINGS

% ========================================================================
% FILE LOCATIONS
% ========================================================================

RISE_FOLDER = "Rise";
FALL_FOLDER = "Fall";

CH1_FILENAME = "CH1.CSV";
CH2_FILENAME = "CH2.CSV";

% If automatic column detection is wrong, replace NaN with the correct
% numeric column number after looking at the preview printed by MATLAB.

RISE_CH1_TIME_COL   = NaN;
RISE_CH1_SIGNAL_COL = NaN;
RISE_CH2_TIME_COL   = NaN;
RISE_CH2_SIGNAL_COL = NaN;

FALL_CH1_TIME_COL   = NaN;
FALL_CH1_SIGNAL_COL = NaN;
FALL_CH2_TIME_COL   = NaN;
FALL_CH2_SIGNAL_COL = NaN;

% ========================================================================
% ELECTRICAL SETUP
% ========================================================================

LOAD_R_OHM = 1000;

% Known firmware command states.
RISE_INITIAL_COMMAND_MA = 0;
RISE_FINAL_COMMAND_MA   = 10;

FALL_INITIAL_COMMAND_MA = 10;
FALL_FINAL_COMMAND_MA   = 0;

COMMAND_STEP_MA = ...
    abs(RISE_FINAL_COMMAND_MA - RISE_INITIAL_COMMAND_MA);

% Optional CH2 scale correction.
%
% Leave at 1 if the oscilloscope CSV already reports the actual voltage at
% the probe tip. If the scope export does not include your probe attenuation
% correctly, adjust this factor after checking the scope settings.
CH2_VOLTAGE_SCALE = 1;

% ========================================================================
% SYNC TIMING
% ========================================================================

% From the isolated captures, the useful timing event appears to be the
% rising transition of CH1. Change this if inspection shows otherwise.
%
% Options:
%   "rising"
%   "falling"
%   "largest"
SYNC_EDGE_TYPE = "rising";

% NaN lets MATLAB estimate the threshold from the robust low/high levels.
SYNC_THRESHOLD_V = NaN;

% If several matching edges exist, select which one corresponds to the
% actual command update.
SYNC_EDGE_NUMBER_RISE = 1;
SYNC_EDGE_NUMBER_FALL = 1;

% Optional manual timing adjustment after visual verification.
SYNC_TIME_OFFSET_RISE_S = 0;
SYNC_TIME_OFFSET_FALL_S = 0;

% ========================================================================
% ANALYSIS WINDOWS
% ========================================================================
% Times below are relative to detected command time t = 0.
%
% Your screenshots suggest the transient is only a few microseconds long,
% so these defaults leave ample baseline and settling data.

ANALYSIS_PRE_S  = 8e-6;
ANALYSIS_POST_S = 12e-6;

BASELINE_START_S = -7e-6;
BASELINE_END_S   = -1e-6;

PLATEAU_START_S = NaN;
PLATEAU_END_S   = NaN;

% ========================================================================
% TIME-DOMAIN METRICS
% ========================================================================

RESPONSE_ONSET_FRACTION = 0.05;   % apparent delay threshold
LOW_LEVEL_FRACTION      = 0.10;
HIGH_LEVEL_FRACTION     = 0.90;

SETTLING_BAND_FRACTION = 0.02;    % +/-2% band
MIN_SETTLE_HOLD_S       = 1e-6;

% ========================================================================
% SYSTEM IDENTIFICATION
% ========================================================================

RUN_IDENTIFICATION = true;

% Recommended:
% estimate from rise, validate against independently measured fall.
ESTIMATION_CAPTURE = "rise";      % "rise" or "fall"

SECOND_ORDER_STRUCTURE = "P2";

% Use 1 initially. Increase only if the scope sample count makes estimation
% unnecessarily slow.
ID_DECIMATION = 1;

% Do not choose automatically.
SELECTED_MODEL = "none";          % "none", "P1", "P1D", "P2"

% Set later when you are ready to make a discrete controller model.
DISCRETE_TS_S = NaN;

%% BUILD FILE PATHS

scriptFolder = getScriptFolder();

riseFolder = fullfile(scriptFolder, RISE_FOLDER);
fallFolder = fullfile(scriptFolder, FALL_FOLDER);

riseCH1Path = fullfile(riseFolder, CH1_FILENAME);
riseCH2Path = fullfile(riseFolder, CH2_FILENAME);

fallCH1Path = fullfile(fallFolder, CH1_FILENAME);
fallCH2Path = fullfile(fallFolder, CH2_FILENAME);

fprintf('\n============================================================\n');
fprintf('OPENXSTIM ISOLATED STEP ANALYSIS\n');
fprintf('============================================================\n');
fprintf('Script folder:\n%s\n\n', scriptFolder);

fprintf('Rise files:\n');
fprintf('  %s\n', riseCH1Path);
fprintf('  %s\n', riseCH2Path);

fprintf('\nFall files:\n');
fprintf('  %s\n', fallCH1Path);
fprintf('  %s\n', fallCH2Path);

assert(isfile(riseCH1Path), 'Cannot find Rise/CH1.CSV:\n%s', riseCH1Path);
assert(isfile(riseCH2Path), 'Cannot find Rise/CH2.CSV:\n%s', riseCH2Path);
assert(isfile(fallCH1Path), 'Cannot find Fall/CH1.CSV:\n%s', fallCH1Path);
assert(isfile(fallCH2Path), 'Cannot find Fall/CH2.CSV:\n%s', fallCH2Path);

%% IMPORT RISE DATA

fprintf('\n============================================================\n');
fprintf('IMPORT RISE CAPTURE\n');
fprintf('============================================================\n');

M1 = importNumericBlock(riseCH1Path, "Rise CH1");
M2 = importNumericBlock(riseCH2Path, "Rise CH2");

[t1, sync1, riseCH1TimeUsed, riseCH1SignalUsed] = ...
    chooseTimeSignal(M1, RISE_CH1_TIME_COL, RISE_CH1_SIGNAL_COL);

[t2, output1, riseCH2TimeUsed, riseCH2SignalUsed] = ...
    chooseTimeSignal(M2, RISE_CH2_TIME_COL, RISE_CH2_SIGNAL_COL);

[rise.t, rise.syncV, rise.outputV, rise.Ts] = ...
    alignSeparateChannels(t1, sync1, t2, output1);

rise.t = rise.t - rise.t(1);

fprintf('Rise CH1 selected columns: time=%d, signal=%d\n', ...
    riseCH1TimeUsed, riseCH1SignalUsed);
fprintf('Rise CH2 selected columns: time=%d, signal=%d\n', ...
    riseCH2TimeUsed, riseCH2SignalUsed);
fprintf('Rise sample period: %.9g s\n', rise.Ts);
fprintf('Rise sample rate  : %.6g Hz\n', 1/rise.Ts);

%% IMPORT FALL DATA

fprintf('\n============================================================\n');
fprintf('IMPORT FALL CAPTURE\n');
fprintf('============================================================\n');

M1 = importNumericBlock(fallCH1Path, "Fall CH1");
M2 = importNumericBlock(fallCH2Path, "Fall CH2");

[t1, sync1, fallCH1TimeUsed, fallCH1SignalUsed] = ...
    chooseTimeSignal(M1, FALL_CH1_TIME_COL, FALL_CH1_SIGNAL_COL);

[t2, output1, fallCH2TimeUsed, fallCH2SignalUsed] = ...
    chooseTimeSignal(M2, FALL_CH2_TIME_COL, FALL_CH2_SIGNAL_COL);

[fall.t, fall.syncV, fall.outputV, fall.Ts] = ...
    alignSeparateChannels(t1, sync1, t2, output1);

fall.t = fall.t - fall.t(1);

fprintf('Fall CH1 selected columns: time=%d, signal=%d\n', ...
    fallCH1TimeUsed, fallCH1SignalUsed);
fprintf('Fall CH2 selected columns: time=%d, signal=%d\n', ...
    fallCH2TimeUsed, fallCH2SignalUsed);
fprintf('Fall sample period: %.9g s\n', fall.Ts);
fprintf('Fall sample rate  : %.6g Hz\n', 1/fall.Ts);

%% CONVERT CH2 VOLTAGE TO CURRENT

rise.current_mA = ...
    1000 .* rise.outputV .* CH2_VOLTAGE_SCALE ./ LOAD_R_OHM;

fall.current_mA = ...
    1000 .* fall.outputV .* CH2_VOLTAGE_SCALE ./ LOAD_R_OHM;

fprintf('\n============================================================\n');
fprintf('ELECTRICAL SCALING\n');
fprintf('============================================================\n');
fprintf('Load resistance       : %.6g ohm\n', LOAD_R_OHM);
fprintf('CH2 voltage scale     : %.6g\n', CH2_VOLTAGE_SCALE);
fprintf('Known command states  : Rise %.3f -> %.3f mA\n', ...
    RISE_INITIAL_COMMAND_MA, RISE_FINAL_COMMAND_MA);
fprintf('Known command states  : Fall %.3f -> %.3f mA\n', ...
    FALL_INITIAL_COMMAND_MA, FALL_FINAL_COMMAND_MA);
fprintf('Incremental step size : %.3f mA\n', COMMAND_STEP_MA);

%% DETECT RISE AND FALL COMMAND TIMES

[rise.commandTime, rise.syncThreshold, rise.syncEdgeTimes] = ...
    detectSyncTime( ...
    rise.t, rise.syncV, ...
    SYNC_EDGE_TYPE, SYNC_THRESHOLD_V, ...
    SYNC_EDGE_NUMBER_RISE, SYNC_TIME_OFFSET_RISE_S);

[fall.commandTime, fall.syncThreshold, fall.syncEdgeTimes] = ...
    detectSyncTime( ...
    fall.t, fall.syncV, ...
    SYNC_EDGE_TYPE, SYNC_THRESHOLD_V, ...
    SYNC_EDGE_NUMBER_FALL, SYNC_TIME_OFFSET_FALL_S);

rise.tr = rise.t - rise.commandTime;
fall.tr = fall.t - fall.commandTime;

fprintf('\n============================================================\n');
fprintf('SYNC TIMING\n');
fprintf('============================================================\n');
fprintf('SYNC edge type        : %s\n', SYNC_EDGE_TYPE);
fprintf('Rise command time     : %.9g s\n', rise.commandTime);
fprintf('Fall command time     : %.9g s\n', fall.commandTime);
fprintf('Rise SYNC threshold   : %.9g V\n', rise.syncThreshold);
fprintf('Fall SYNC threshold   : %.9g V\n', fall.syncThreshold);

%% CROP TO ANALYSIS WINDOW

riseMask = ...
    rise.tr >= -ANALYSIS_PRE_S & rise.tr <= ANALYSIS_POST_S;

fallMask = ...
    fall.tr >= -ANALYSIS_PRE_S & fall.tr <= ANALYSIS_POST_S;

rise = cropCapture(rise, riseMask);
fall = cropCapture(fall, fallMask);

%% RAW ALIGNED PLOTS

figure('Name','Isolated rise and fall captures');

tl = tiledlayout(2,2);
title(tl, 'OpenXstim isolated 0 to 10 mA and 10 to 0 mA steps');

nexttile;
plot(rise.tr, rise.syncV, 'LineWidth', 1);
hold on;
xline(0,'--','command');
yline(rise.syncThreshold,':','SYNC threshold');
grid on;
ylabel('CH1 voltage (V)');
title('Rise: SYNC timing reference');
hold off;

nexttile;
plot(rise.tr, rise.current_mA, 'LineWidth', 1);
hold on;
xline(0,'--','command');
yline(RISE_INITIAL_COMMAND_MA,':','0 mA command');
yline(RISE_FINAL_COMMAND_MA,':','10 mA command');
grid on;
ylabel('Measured current (mA)');
title('Rise: 0 to 10 mA');
hold off;

nexttile;
plot(fall.tr, fall.syncV, 'LineWidth', 1);
hold on;
xline(0,'--','command');
yline(fall.syncThreshold,':','SYNC threshold');
grid on;
xlabel('Time from command (s)');
ylabel('CH1 voltage (V)');
title('Fall: SYNC timing reference');
hold off;

nexttile;
plot(fall.tr, fall.current_mA, 'LineWidth', 1);
hold on;
xline(0,'--','command');
yline(FALL_INITIAL_COMMAND_MA,':','10 mA command');
yline(FALL_FINAL_COMMAND_MA,':','0 mA command');
grid on;
xlabel('Time from command (s)');
ylabel('Measured current (mA)');
title('Fall: 10 to 0 mA');
hold off;

%% ESTIMATE BASELINE AND PLATEAU LEVELS

rise = characterizeLevels( ...
    rise, ...
    BASELINE_START_S, BASELINE_END_S, ...
    PLATEAU_START_S, PLATEAU_END_S);

fall = characterizeLevels( ...
    fall, ...
    BASELINE_START_S, BASELINE_END_S, ...
    PLATEAU_START_S, PLATEAU_END_S);

% Rising incremental response:
%
% measured 0 -> approximately +10 mA
rise.deltaCurrent_mA = ...
    rise.current_mA - rise.initialMeasured_mA;

rise.measuredStep_mA = ...
    rise.finalMeasured_mA - rise.initialMeasured_mA;

% Falling response:
%
% measured approximately +10 -> 0 mA
%
% Sign-correct it so identification sees another positive incremental
% 0 -> approximately +10 mA response.
fall.deltaCurrent_mA = ...
    fall.initialMeasured_mA - fall.current_mA;

fall.measuredStep_mA = ...
    fall.initialMeasured_mA - fall.finalMeasured_mA;

rise.normalized = ...
    rise.deltaCurrent_mA ./ rise.measuredStep_mA;

fall.normalized = ...
    fall.deltaCurrent_mA ./ fall.measuredStep_mA;

rise.staticGain = ...
    rise.measuredStep_mA / COMMAND_STEP_MA;

fall.staticGain = ...
    fall.measuredStep_mA / COMMAND_STEP_MA;

fprintf('\n============================================================\n');
fprintf('MEASURED CURRENT LEVELS\n');
fprintf('============================================================\n');

fprintf('\nRISE: 0 -> 10 mA\n');
fprintf('Measured initial current : %.9g mA\n', rise.initialMeasured_mA);
fprintf('Measured final current   : %.9g mA\n', rise.finalMeasured_mA);
fprintf('Measured step magnitude  : %.9g mA\n', rise.measuredStep_mA);
fprintf('Static gain DeltaI/DeltaU: %.9g\n', rise.staticGain);

fprintf('\nFALL: 10 -> 0 mA\n');
fprintf('Measured initial current : %.9g mA\n', fall.initialMeasured_mA);
fprintf('Measured final current   : %.9g mA\n', fall.finalMeasured_mA);
fprintf('Measured step magnitude  : %.9g mA\n', fall.measuredStep_mA);
fprintf('Static gain |DeltaI|/|DeltaU|: %.9g\n', fall.staticGain);

%% TIME-DOMAIN METRICS

rise.metrics = calculateMetrics( ...
    rise.tr, ...
    rise.deltaCurrent_mA, ...
    rise.measuredStep_mA, ...
    RESPONSE_ONSET_FRACTION, ...
    LOW_LEVEL_FRACTION, ...
    HIGH_LEVEL_FRACTION, ...
    SETTLING_BAND_FRACTION, ...
    MIN_SETTLE_HOLD_S, ...
    rise.Ts);

fall.metrics = calculateMetrics( ...
    fall.tr, ...
    fall.deltaCurrent_mA, ...
    fall.measuredStep_mA, ...
    RESPONSE_ONSET_FRACTION, ...
    LOW_LEVEL_FRACTION, ...
    HIGH_LEVEL_FRACTION, ...
    SETTLING_BAND_FRACTION, ...
    MIN_SETTLE_HOLD_S, ...
    fall.Ts);

fprintf('\n============================================================\n');
fprintf('TIME-DOMAIN METRICS\n');
fprintf('============================================================\n');

printMetrics("RISE 0 -> 10 mA", rise.metrics);
printMetrics("FALL 10 -> 0 mA", fall.metrics);

%% METRIC VERIFICATION FIGURE

figure('Name','Automatic transition metric verification');

tl = tiledlayout(2,1);
title(tl, 'Automatic transition metric verification');

ax1 = nexttile;
plotMetricVerification(ax1, rise, "Rise: 0 to 10 mA");

ax2 = nexttile;
plotMetricVerification(ax2, fall, "Fall: 10 to 0 mA, sign corrected");

%% NORMALIZED RISE VS FALL

commonTs = max(rise.Ts, fall.Ts);

commonStart = max(min(rise.tr), min(fall.tr));
commonEnd   = min(max(rise.tr), max(fall.tr));

tCommon = (commonStart:commonTs:commonEnd).';

riseNorm = interp1( ...
    rise.tr, rise.normalized, tCommon, 'linear', NaN);

fallNorm = interp1( ...
    fall.tr, fall.normalized, tCommon, 'linear', NaN);

good = isfinite(riseNorm) & isfinite(fallNorm);

normalizedRMSE = sqrt( ...
    mean((riseNorm(good)-fallNorm(good)).^2));

normalizedMaxDifference = max( ...
    abs(riseNorm(good)-fallNorm(good)));

figure('Name','Normalized rise fall comparison');

plot(tCommon, riseNorm, 'LineWidth', 1.4);
hold on;
plot(tCommon, fallNorm, 'LineWidth', 1.4);

xline(0,'--','command');
yline(0.1,':','10%');
yline(0.9,':','90%');
yline(1,':','final');

grid on;
xlabel('Time from command (s)');
ylabel('Normalized response');

title('Normalized rise and fall dynamics');
legend('Rise 0 to 10 mA', ...
       'Fall 10 to 0 mA, sign corrected', ...
       'Location','best');

hold off;

fprintf('\n============================================================\n');
fprintf('RISE / FALL SYMMETRY\n');
fprintf('============================================================\n');
fprintf('Normalized RMSE               : %.9g\n', normalizedRMSE);
fprintf('Maximum normalized difference : %.9g\n', normalizedMaxDifference);

%% SYSTEM IDENTIFICATION

modelP1 = [];
modelP1D = [];
modelP2 = [];

validationTable = table();

if RUN_IDENTIFICATION

    if exist('iddata','file') ~= 2 || exist('procest','file') ~= 2

        warning(['System Identification Toolbox was not found. ' ...
                 'Skipping transfer-function estimation.']);

    else

        if ESTIMATION_CAPTURE == "rise"

            est = rise;
            val = fall;

            estName = "rise 0 -> 10 mA";
            valName = "fall 10 -> 0 mA";

        elseif ESTIMATION_CAPTURE == "fall"

            est = fall;
            val = rise;

            estName = "fall 10 -> 0 mA";
            valName = "rise 0 -> 10 mA";

        else
            error('ESTIMATION_CAPTURE must be "rise" or "fall".');
        end

        decimation = max(1, round(ID_DECIMATION));

        idTs = max(est.Ts, val.Ts) * decimation;

        idStart = max( ...
            [min(est.tr), min(val.tr), -ANALYSIS_PRE_S]);

        idEnd = min( ...
            [max(est.tr), max(val.tr), ANALYSIS_POST_S]);

        tID = (idStart:idTs:idEnd).';

        % Reconstructed ideal current command.
        %
        % This is the actual known command information used for ID.
        % CH1 only defines where t = 0 occurs.
        uID = COMMAND_STEP_MA .* double(tID >= 0);

        yEst = interp1( ...
            est.tr, est.deltaCurrent_mA, ...
            tID, 'linear', NaN);

        yVal = interp1( ...
            val.tr, val.deltaCurrent_mA, ...
            tID, 'linear', NaN);

        good = ...
            isfinite(tID) & ...
            isfinite(uID) & ...
            isfinite(yEst) & ...
            isfinite(yVal);

        tID  = tID(good);
        uID  = uID(good);
        yEst = yEst(good);
        yVal = yVal(good);

        dataEst = iddata(yEst, uID, idTs);

        dataEst.InterSample = 'zoh';
        dataEst.InputName   = 'commanded current change';
        dataEst.InputUnit   = 'mA';
        dataEst.OutputName  = 'measured current change';
        dataEst.OutputUnit  = 'mA';

        fprintf('\n============================================================\n');
        fprintf('SYSTEM IDENTIFICATION\n');
        fprintf('============================================================\n');

        fprintf('Estimation data : %s\n', estName);
        fprintf('Validation data : %s\n', valName);
        fprintf('ID sample time  : %.9g s\n', idTs);
        fprintf('Constructed step: 0 -> %.6g mA\n', COMMAND_STEP_MA);

        modelP1 = procest(dataEst, 'P1');
        modelP1D = procest(dataEst, 'P1D');
        modelP2 = procest(dataEst, char(SECOND_ORDER_STRUCTURE));

        % Simulate all models against the known validation input.
        inputValidation = iddata([], uID, idTs);
        inputValidation.InterSample = 'zoh';

        yP1  = sim(modelP1,  inputValidation).OutputData;
        yP1D = sim(modelP1D, inputValidation).OutputData;
        yP2  = sim(modelP2,  inputValidation).OutputData;

        [fitP1, rmseP1] = ...
            fitMetrics(yVal, yP1);

        [fitP1D, rmseP1D] = ...
            fitMetrics(yVal, yP1D);

        [fitP2, rmseP2] = ...
            fitMetrics(yVal, yP2);

        Model = [ ...
            "P1";
            "P1D";
            string(SECOND_ORDER_STRUCTURE)];

        ValidationFit_pct = [ ...
            fitP1;
            fitP1D;
            fitP2];

        ValidationRMSE_mA = [ ...
            rmseP1;
            rmseP1D;
            rmseP2];

        validationTable = table( ...
            Model, ...
            ValidationFit_pct, ...
            ValidationRMSE_mA);

        fprintf('\nIndependent validation results:\n');
        disp(validationTable);

        figure('Name','Low-order model validation');

        plot(tID, yVal, 'LineWidth', 1.5);
        hold on;

        plot(tID, yP1,  'LineWidth', 1.2);
        plot(tID, yP1D, 'LineWidth', 1.2);
        plot(tID, yP2,  'LineWidth', 1.2);

        xline(0,'--','command');

        grid on;

        xlabel('Time from command (s)');
        ylabel('Incremental current (mA)');

        title(sprintf( ...
            'Independent validation using %s', valName));

        legend( ...
            'Measured validation response', ...
            sprintf('P1, %.1f%% fit',fitP1), ...
            sprintf('P1D, %.1f%% fit',fitP1D), ...
            sprintf('%s, %.1f%% fit', ...
            SECOND_ORDER_STRUCTURE,fitP2), ...
            'Location','best');

        hold off;

        fprintf('\n============================================================\n');
        fprintf('CONTINUOUS-TIME MODELS\n');
        fprintf('============================================================\n');

        fprintf('\nP1, first order:\n');
        displayModel(modelP1);

        fprintf('\nP1D, first order plus dead time:\n');
        displayModel(modelP1D);

        fprintf('\n%s, second order:\n', SECOND_ORDER_STRUCTURE);
        displayModel(modelP2);

        fprintf('\nModel-selection principle:\n');
        fprintf(['Choose the simplest model that adequately reproduces the\n' ...
                 'independent validation response. A slightly higher fit\n' ...
                 'alone is not a reason to choose a higher-order model.\n']);

    end
end

%% OPTIONAL DISCRETISATION

if SELECTED_MODEL ~= "none"

    switch upper(SELECTED_MODEL)

        case "P1"
            selected = modelP1;

        case "P1D"
            selected = modelP1D;

        case "P2"
            selected = modelP2;

        otherwise
            error( ...
                'SELECTED_MODEL must be "none", "P1", "P1D", or "P2".');
    end

    if isempty(selected)

        warning('Selected model is unavailable.');

    elseif ~isfinite(DISCRETE_TS_S) || DISCRETE_TS_S <= 0

        warning( ...
            'Set DISCRETE_TS_S before discretising the selected model.');

    else

        Gc = tf(selected);

        Gd = c2d( ...
            Gc, ...
            DISCRETE_TS_S, ...
            'zoh');

        fprintf('\n============================================================\n');
        fprintf('DISCRETE MODEL\n');
        fprintf('============================================================\n');

        fprintf('Selected model : %s\n', SELECTED_MODEL);
        fprintf('Sample time    : %.9g s\n', DISCRETE_TS_S);
        fprintf('Method         : zero-order hold\n\n');

        disp(Gd);

    end
end

%% FINAL SUMMARY

fprintf('\n============================================================\n');
fprintf('FINAL SUMMARY\n');
fprintf('============================================================\n');

fprintf('\nKnown input:\n');
fprintf('  Rise: %.3f -> %.3f mA\n', ...
    RISE_INITIAL_COMMAND_MA, RISE_FINAL_COMMAND_MA);
fprintf('  Fall: %.3f -> %.3f mA\n', ...
    FALL_INITIAL_COMMAND_MA, FALL_FINAL_COMMAND_MA);
fprintf('  Incremental command magnitude: %.3f mA\n', ...
    COMMAND_STEP_MA);

fprintf('\nRise measurement:\n');
fprintf('  Initial current  : %.9g mA\n', rise.initialMeasured_mA);
fprintf('  Final current    : %.9g mA\n', rise.finalMeasured_mA);
fprintf('  Static gain      : %.9g\n', rise.staticGain);
fprintf('  Apparent delay   : %.9g s\n', rise.metrics.delay_s);
fprintf('  10-90 time       : %.9g s\n', rise.metrics.t10_90_s);
fprintf('  Settling time    : %.9g s\n', rise.metrics.settling_s);

fprintf('\nFall measurement:\n');
fprintf('  Initial current  : %.9g mA\n', fall.initialMeasured_mA);
fprintf('  Final current    : %.9g mA\n', fall.finalMeasured_mA);
fprintf('  Static gain      : %.9g\n', fall.staticGain);
fprintf('  Apparent delay   : %.9g s\n', fall.metrics.delay_s);
fprintf('  10-90 time       : %.9g s\n', fall.metrics.t10_90_s);
fprintf('  Settling time    : %.9g s\n', fall.metrics.settling_s);

fprintf('\nRise/fall comparison:\n');
fprintf('  Normalized RMSE  : %.9g\n', normalizedRMSE);
fprintf('  Maximum difference: %.9g\n', normalizedMaxDifference);

fprintf('\nInterpretation notes:\n');
fprintf('  1. CH1 amplitude is not used for identification.\n');
fprintf('     Only the timing of the selected SYNC transition is used.\n');
fprintf('  2. The input to the identification model is reconstructed as\n');
fprintf('     an ideal 0 -> 10 mA incremental command step.\n');
fprintf('  3. The falling response is sign-corrected to permit direct\n');
fprintf('     comparison and independent validation against the rise.\n');
fprintf('  4. Firmware delay before the observed SYNC event is not directly\n');
fprintf('     included in the measured command-to-response delay.\n');

if abs(rise.staticGain - fall.staticGain) > 0.05
    fprintf('\nWARNING:\n');
    fprintf(['  Rise and fall static gains differ by more than 0.05.\n' ...
             '  Check output scaling and possible polarity asymmetry.\n']);
end

if normalizedRMSE > 0.05
    fprintf('\nWARNING:\n');
    fprintf(['  Rise and fall normalized dynamics differ by more than about\n' ...
             '  5%% RMS. One common LTI model may need justification.\n']);
end

fprintf('\nAnalysis complete.\n');

%% =======================================================================
% LOCAL FUNCTIONS
% ========================================================================

function M = importNumericBlock(filename,label)

    fprintf('\nImporting %s:\n%s\n', label, filename);

    raw = readmatrix(filename);

    if isempty(raw)
        error('No numeric content found in:\n%s', filename);
    end

    numericCount = sum(isfinite(raw),2);

    dataLike = numericCount >= 2;

    if ~any(dataLike)
        error('Could not identify numeric scope data in:\n%s',filename);
    end

    d = diff([false;dataLike;false]);

    runStart = find(d==1);
    runEnd = find(d==-1)-1;

    [~,best] = max(runEnd-runStart+1);

    M = raw(runStart(best):runEnd(best),:);

    M(:,all(~isfinite(M),1)) = [];

    fprintf('Numeric block: %d rows x %d columns\n', ...
        size(M,1),size(M,2));

    fprintf('First rows:\n');
    disp(M(1:min(5,size(M,1)),:));

end

function [t,y,timeCol,signalCol] = ...
    chooseTimeSignal(M,timeCol,signalCol)

    if isnan(timeCol)
        timeCol = autoTimeColumn(M);
    end

    if isnan(signalCol)
        signalCol = autoSignalColumn(M,timeCol);
    end

    t = M(:,timeCol);
    y = M(:,signalCol);

    good = ...
        isfinite(t) & ...
        isfinite(y);

    t = t(good);
    y = y(good);

    [t,order] = sort(t);

    y = y(order);

    [t,uniqueIdx] = unique(t,'stable');

    y = y(uniqueIdx);

    if numel(t)<10 || any(diff(t)<=0)
        error('Selected time column is not a valid increasing time vector.');
    end

end

function c = autoTimeColumn(M)

    nCols = size(M,2);

    score = -inf(1,nCols);

    for k = 1:nCols

        x = M(:,k);

        x = x(isfinite(x));

        if numel(x)<10
            continue;
        end

        dx = diff(x);

        monotonicity = max( ...
            mean(dx>0), ...
            mean(dx<0));

        nonzero = ...
            abs(dx) > eps(max(abs(x)));

        if ~any(nonzero)
            continue;
        end

        d = abs(dx(nonzero));

        regularity = ...
            1/(1+std(d)/max(eps,mean(d)));

        score(k) = ...
            3*monotonicity + regularity;

    end

    [best,c] = max(score);

    if ~isfinite(best)
        error('Automatic time-column detection failed.');
    end

end

function c = autoSignalColumn(M,timeCol)

    candidates = ...
        setdiff(1:size(M,2),timeCol);

    score = -inf(size(candidates));

    for k = 1:numel(candidates)

        x = M(:,candidates(k));

        if nnz(isfinite(x))<10
            continue;
        end

        score(k) = ...
            abs( ...
            pctileLocal(x,95) - ...
            pctileLocal(x,5));

    end

    [best,idx] = max(score);

    if ~isfinite(best)
        error('Automatic signal-column detection failed.');
    end

    c = candidates(idx);

end

function [t,syncV,outV,Ts] = ...
    alignSeparateChannels(t1,sync1,t2,out2)

    Ts1 = median(diff(t1));
    Ts2 = median(diff(t2));

    Ts = max(Ts1,Ts2);

    tStart = max(t1(1),t2(1));
    tStop  = min(t1(end),t2(end));

    if tStop<=tStart
        error('CH1 and CH2 time ranges do not overlap.');
    end

    t = (tStart:Ts:tStop).';

    syncV = ...
        interp1(t1,sync1,t,'nearest');

    outV = ...
        interp1(t2,out2,t,'linear');

    good = ...
        isfinite(syncV) & ...
        isfinite(outV);

    t = t(good);
    syncV = syncV(good);
    outV = outV(good);

end

function [commandTime,threshold,edgeTimes] = ...
    detectSyncTime( ...
    t,syncV,edgeType,userThreshold,edgeNumber,timeOffset)

    low = pctileLocal(syncV,5);
    high = pctileLocal(syncV,95);

    if isnan(userThreshold)
        threshold = 0.5*(low+high);
    else
        threshold = userThreshold;
    end

    logic = syncV > threshold;

    risingIdx = ...
        find(diff(logic)==1)+1;

    fallingIdx = ...
        find(diff(logic)==-1)+1;

    switch edgeType

        case "rising"
            idx = risingIdx;

        case "falling"
            idx = fallingIdx;

        case "largest"

            d = abs(diff(syncV));

            [~,i] = max(d);

            idx = i+1;

        otherwise

            error( ...
                'SYNC_EDGE_TYPE must be "rising", "falling", or "largest".');

    end

    if isempty(idx)
        error('No requested SYNC transition was detected.');
    end

    edgeTimes = t(idx);

    if edgeNumber>numel(edgeTimes)

        error( ...
            ['Requested SYNC edge %d, but only %d matching transitions ' ...
             'were detected.'], ...
             edgeNumber,numel(edgeTimes));

    end

    commandTime = ...
        edgeTimes(edgeNumber) + timeOffset;

end

function capture = cropCapture(capture,mask)

    capture.t = capture.t(mask);
    capture.tr = capture.tr(mask);
    capture.syncV = capture.syncV(mask);
    capture.outputV = capture.outputV(mask);
    capture.current_mA = capture.current_mA(mask);

end

function capture = characterizeLevels( ...
    capture,baseStart,baseEnd,plateauStart,plateauEnd)

    % Baseline region
    baseMask = ...
        capture.tr >= baseStart & ...
        capture.tr <= baseEnd;

    if nnz(baseMask) < 5
        error('Baseline analysis window contains too few samples.');
    end

    capture.initialMeasured_mA = ...
        median(capture.current_mA(baseMask),'omitnan');

    % Plateau region

    if isnan(plateauStart) || isnan(plateauEnd)

        % Automatically use the final 20% of post-command samples
        postIdx = find(capture.tr > 0);

        if numel(postIdx) < 10
            error('Too few post-command samples to estimate plateau.');
        end

        nPlateau = max(5,round(0.20*numel(postIdx)));

        plateauIdx = postIdx(end-nPlateau+1:end);

    else

        plateauIdx = find( ...
            capture.tr >= plateauStart & ...
            capture.tr <= plateauEnd);

        if numel(plateauIdx) < 5
            error('Plateau analysis window contains too few samples.');
        end

    end

    capture.finalMeasured_mA = ...
        median(capture.current_mA(plateauIdx),'omitnan');

end

function metrics = calculateMetrics( ...
    t,y,stepMagnitude,onsetFrac,lowFrac,highFrac, ...
    settlingFrac,minSettleHoldS,Ts)

    if stepMagnitude<=0
        error('Incremental measured step magnitude must be positive.');
    end

    onsetLevel = onsetFrac*stepMagnitude;
    lowLevel   = lowFrac*stepMagnitude;
    highLevel  = highFrac*stepMagnitude;

    tOnset = ...
        firstCrossing(t,y,onsetLevel);

    t10 = ...
        firstCrossing(t,y,lowLevel);

    t90 = ...
        firstCrossing(t,y,highLevel);

    if isfinite(tOnset)
        delay = tOnset;
    else
        delay = NaN;
    end

    if isfinite(t10) && isfinite(t90)
        transition1090 = t90-t10;
    else
        transition1090 = NaN;
    end

    [peak,peakIdx] = max(y);

    peakTime = t(peakIdx);

    overshoot = ...
        max( ...
        0, ...
        100*(peak-stepMagnitude)/max(eps,stepMagnitude));

    settlingBand = ...
        settlingFrac*stepMagnitude;

    finalError = ...
        abs(y-stepMagnitude);

    holdSamples = ...
        max( ...
        1, ...
        ceil(minSettleHoldS/Ts));

    settlingTime = NaN;

    startIdx = find(t>=0,1,'first');

    if isfinite(t90)
        startIdx = ...
            max( ...
            startIdx, ...
            find(t>=t90,1,'first'));
    end

    for k = startIdx:(numel(y)-holdSamples+1)

        if all( ...
                finalError(k:k+holdSamples-1) ...
                <= settlingBand)

            settlingTime = t(k);
            break;

        end

    end

    metrics.delay_s = delay;
    metrics.t10_s = t10;
    metrics.t90_s = t90;
    metrics.t10_90_s = transition1090;

    metrics.peak_mA = peak;
    metrics.peakTime_s = peakTime;

    metrics.overshoot_pct = overshoot;
    metrics.settling_s = settlingTime;

end

function printMetrics(label,m)

    fprintf('\n%s\n', label);

    fprintf('  Apparent delay      : %.9g s\n', ...
        m.delay_s);

    fprintf('  10%% crossing        : %.9g s\n', ...
        m.t10_s);

    fprintf('  90%% crossing        : %.9g s\n', ...
        m.t90_s);

    fprintf('  10-90%% time         : %.9g s\n', ...
        m.t10_90_s);

    fprintf('  Peak step response  : %.9g mA\n', ...
        m.peak_mA);

    fprintf('  Overshoot           : %.9g %%\n', ...
        m.overshoot_pct);

    fprintf('  Settling time       : %.9g s\n', ...
        m.settling_s);

end

function plotMetricVerification(ax,capture,label)

    plot( ...
        ax, ...
        capture.tr, ...
        capture.deltaCurrent_mA, ...
        'LineWidth',1.3);

    hold(ax,'on');

    xline(ax,0,'--','command');

    y10 = ...
        0.10*capture.measuredStep_mA;

    y90 = ...
        0.90*capture.measuredStep_mA;

    yline(ax,y10,':','10%');
    yline(ax,y90,':','90%');

    yline( ...
        ax, ...
        capture.measuredStep_mA, ...
        '--', ...
        'plateau');

    if isfinite(capture.metrics.delay_s)
        xline( ...
            ax, ...
            capture.metrics.delay_s, ...
            ':', ...
            'delay');
    end

    if isfinite(capture.metrics.t10_s)
        plot( ...
            ax, ...
            capture.metrics.t10_s, ...
            y10, ...
            'o');
    end

    if isfinite(capture.metrics.t90_s)
        plot( ...
            ax, ...
            capture.metrics.t90_s, ...
            y90, ...
            'o');
    end

    if isfinite(capture.metrics.settling_s)
        xline( ...
            ax, ...
            capture.metrics.settling_s, ...
            ':', ...
            'settling');
    end

    if isfinite(capture.metrics.peakTime_s)
        plot( ...
            ax, ...
            capture.metrics.peakTime_s, ...
            capture.metrics.peak_mA, ...
            's');
    end

    grid(ax,'on');

    xlabel( ...
        ax, ...
        'Time from detected command (s)');

    ylabel( ...
        ax, ...
        'Incremental current (mA)');

    title(ax,label);

    hold(ax,'off');

end

function tcross = firstCrossing(t,x,level)

    valid = t>=0;

    tv = t(valid);
    xv = x(valid);

    idx = ...
        find(xv>=level,1,'first');

    if isempty(idx)

        tcross = NaN;
        return;

    end

    if idx==1

        tcross = tv(1);
        return;

    end

    x1 = xv(idx-1);
    x2 = xv(idx);

    t1 = tv(idx-1);
    t2 = tv(idx);

    if x2==x1

        tcross = t2;

    else

        alpha = ...
            (level-x1)/(x2-x1);

        tcross = ...
            t1 + alpha*(t2-t1);

    end

end

function [fitPct,rmse] = ...
    fitMetrics(y,yhat)

    y = y(:);
    yhat = yhat(:);

    good = ...
        isfinite(y) & ...
        isfinite(yhat);

    y = y(good);
    yhat = yhat(good);

    residual = ...
        y-yhat;

    rmse = ...
        sqrt(mean(residual.^2));

    denom = ...
        norm(y-mean(y));

    if denom<=eps

        fitPct = NaN;

    else

        fitPct = ...
            100*(1-norm(residual)/denom);

    end

end

function displayModel(model)

    disp(model);

    try

        fprintf('Transfer-function form:\n');
        disp(tf(model));

    catch
    end

end

function folder = getScriptFolder()

    folder = pwd;

    try

        activeFile = ...
            matlab.desktop.editor.getActiveFilename;

        if ~isempty(activeFile)

            folder = fileparts(activeFile);
            return;

        end

    catch
    end

    try

        thisFile = ...
            mfilename('fullpath');

        if ~isempty(thisFile)
            folder = fileparts(thisFile);
        end

    catch
    end

end

function q = pctileLocal(x,p)

    x = ...
        x(isfinite(x));

    x = ...
        sort(x(:));

    if isempty(x)

        q = NaN;
        return;

    end

    if numel(x)==1

        q = x;
        return;

    end

    r = ...
        1 + (p/100)*(numel(x)-1);

    lo = floor(r);
    hi = ceil(r);

    if lo==hi

        q = x(lo);

    else

        q = ...
            x(lo) + ...
            (r-lo)*(x(hi)-x(lo));

    end

end
