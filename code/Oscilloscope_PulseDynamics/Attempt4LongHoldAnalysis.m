%% Attempt4LongHoldAnalysis.m
% OpenXstim Attempt 4 long-hold analysis
%
% Purpose:
% Analyse the earlier nominal 30 mA capture that showed a fast turn-on,
% followed by a much slower output decay.
%
% Known test configuration:
%   External load resistor   = 1 kOhm
%   Known output capacitance = 0.1 uF
%   Nominal firmware command = 30 mA
%
% If the 0.1 uF capacitor discharged through exactly 1 kOhm:
%
%   tau_expected = R*C = 100 us
%
% This 100 us value is used only as a theoretical comparison. The actual
% capacitor may see a different effective resistance inside the stimulator.
%
% CH1 = Arduino / DAC SYNC timing reference
% CH2 = voltage across the 1 kOhm external resistor
%
% Since R = 1 kOhm, I_mA = V_R numerically when V_R is in volts.
%
% This is one long-hold capture. Model fits from this file are preliminary
% parameter estimates, not independent validation.
%
% The script:
%   - robustly imports CH1 and CH2
%   - detects complete active-low SYNC transactions
%   - lets you select the fast-rise onset, slow-droop start, and slow-droop
%     fit end interactively
%   - causally associates the fast rise with the last complete SYNC
%     transaction before the rise
%   - quantifies fast rise dynamics
%   - fits P1, P1D, and P2 models to the fast rise
%   - fits the slow decay to an exponential
%   - compares the slow time constant with the theoretical 100 us value
%   - estimates an effective discharge resistance from tau/C
%   - fits an exploratory two-timescale model
%   - warns if SYNC activity occurs near or inside the selected slow region
%   - saves figures, CSV metrics, and a MAT file containing fitted models
%
% No special toolbox is required for fitting.

clear;
clc;
close all;

%% USER SETTINGS

ROOT_FOLDER = getScriptFolder();

ATTEMPT_NUMBER = 4;

CH1_NAME = "CH1.CSV";
CH2_NAME = "CH2.CSV";

RESULTS_FOLDER = fullfile(ROOT_FOLDER,"Attempt4_AnalysisResults");

% Electrical parameters
LOAD_R_OHM = 1000;
KNOWN_OUTPUT_C_F = 0.1e-6;
NOMINAL_COMMAND_MA = 30;
THEORETICAL_TAU_S = LOAD_R_OHM*KNOWN_OUTPUT_C_F;

CH2_SCALE_FACTOR = 1;

% Region selection:
% "interactive" is recommended for this unusual single capture.
% You click:
%   1. fast rise onset
%   2. slow droop start
%   3. slow droop fit end
%
% "manual" uses the three times below.
% "automatic" estimates them from CH2.
REGION_SELECTION_MODE = "interactive";

MANUAL_FAST_RISE_ONSET_S = NaN;
MANUAL_SLOW_DROOP_START_S = NaN;
MANUAL_SLOW_DROOP_END_S = NaN;

% SYNC detection
SYNC_ACTIVE_LOW = true;
SYNC_THRESHOLD_V = NaN;

SYNC_MIN_PULSE_WIDTH_S = 0.05e-6;
SYNC_MAX_PULSE_WIDTH_S = 50e-6;

MAX_SYNC_TO_RISE_LEAD_S = 50e-6;
SYNC_NEAR_DROOP_WARNING_S = 20e-6;

% Fast rise analysis
FAST_BASELINE_START_S = -50e-6;
FAST_BASELINE_END_S   = -5e-6;

EARLY_PLATEAU_START_AFTER_RISE_S = 20e-6;
EARLY_PLATEAU_MAX_END_AFTER_RISE_S = 100e-6;
EARLY_PLATEAU_GUARD_BEFORE_DROOP_S = 20e-6;

FAST_FIT_MAX_DURATION_S = 30e-6;

LOW_FRACTION  = 0.10;
MID_FRACTION  = 0.50;
HIGH_FRACTION = 0.90;

SETTLING_BAND_FRACTION = 0.02;
MIN_SETTLING_HOLD_S = 1e-6;

% Slow droop
DROOP_REPORT_TIMES_S = [20 50 100 200 300 500 750 1000] * 1e-6;

% Two-timescale model
FIT_TWO_TIMESCALE_MODEL = true;

%% FIND ATTEMPT 4 DATA

if ~isfolder(RESULTS_FOLDER)
    mkdir(RESULTS_FOLDER);
end

[ch1Path,ch2Path,attemptFolder] = findAttemptFiles( ...
    ROOT_FOLDER,ATTEMPT_NUMBER,CH1_NAME,CH2_NAME);

fprintf('\n============================================================\n');
fprintf('OPENXSTIM ATTEMPT 4 LONG-HOLD ANALYSIS\n');
fprintf('============================================================\n');

fprintf('Attempt folder:\n%s\n\n',attemptFolder);

fprintf('CH1:\n%s\n',ch1Path);
fprintf('CH2:\n%s\n\n',ch2Path);

fprintf('Load resistance         : %.6g ohm\n',LOAD_R_OHM);
fprintf('Known output capacitance: %.6g uF\n',1e6*KNOWN_OUTPUT_C_F);
fprintf('Theoretical R*C         : %.6g us\n',1e6*THEORETICAL_TAU_S);
fprintf('Nominal firmware command: %.6g mA\n',NOMINAL_COMMAND_MA);

%% IMPORT AND ALIGN CHANNELS

[t1,syncV] = loadScopeCSV(ch1Path);
[t2,loadV] = loadScopeCSV(ch2Path);

[t,syncV,loadV,Ts] = alignChannels(t1,syncV,t2,loadV);

t = t-t(1);

current_mA = 1000*loadV*CH2_SCALE_FACTOR/LOAD_R_OHM;

fprintf('\nSample period: %.9g s\n',Ts);
fprintf('Sample rate  : %.9g MSa/s\n',1e-6/Ts);
fprintf('Capture time : %.9g ms\n',1e3*(t(end)-t(1)));

%% DETECT COMPLETE SYNC TRANSACTIONS

[txnStart,txnEnd,syncThreshold] = detectSyncTransactions( ...
    t,syncV,SYNC_THRESHOLD_V,SYNC_ACTIVE_LOW, ...
    SYNC_MIN_PULSE_WIDTH_S,SYNC_MAX_PULSE_WIDTH_S);

fprintf('\nDetected complete SYNC transactions: %d\n',numel(txnEnd));
fprintf('SYNC threshold: %.9g V\n',syncThreshold);

if isempty(txnEnd)
    warning('No complete SYNC transactions were detected.');
end

%% OVERVIEW FIGURE

figure('Name','Attempt 4 overview');

tl = tiledlayout(2,1);
title(tl,'Attempt 4 raw capture and detected SYNC transactions');

nexttile;
plot(t*1e3,syncV,'LineWidth',0.8);
hold on;
for k = 1:numel(txnEnd)
    xline(txnEnd(k)*1e3,':');
end
grid on;
ylabel('SYNC (V)');
title('CH1: detected complete SYNC transaction ends');
hold off;

nexttile;
plot(t*1e3,current_mA,'LineWidth',1.1);
hold on;
for k = 1:numel(txnEnd)
    xline(txnEnd(k)*1e3,':');
end
grid on;
xlabel('Capture time (ms)');
ylabel('Measured current (mA)');
title('CH2: current through 1 kOhm');
hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"Attempt4_RawOverview.png"));

%% SELECT FAST RISE / SLOW DROOP REGIONS

switch REGION_SELECTION_MODE

    case "interactive"

        figure('Name','Select Attempt 4 regions');

        plot(t*1e3,current_mA,'LineWidth',1.2);
        hold on;

        for k = 1:numel(txnEnd)
            xline(txnEnd(k)*1e3,':');
        end

        grid on;
        xlabel('Capture time (ms)');
        ylabel('Measured current (mA)');

        title({ ...
            'Click 3 points in order:', ...
            '1 fast rise onset, 2 slow droop start, 3 slow droop fit end'});

        fprintf('\nInteractive selection:\n');
        fprintf('  Click 1: fast rise onset\n');
        fprintf('  Click 2: slow droop start\n');
        fprintf('  Click 3: slow droop fit end\n');

        [xClick,~] = ginput(3);

        close(gcf);

        selectedTimes = 1e-3*xClick(:);

        if numel(selectedTimes)~=3 || ...
                ~(selectedTimes(1)<selectedTimes(2) && ...
                  selectedTimes(2)<selectedTimes(3))
            error('Selected times must be in increasing order.');
        end

        fastRiseOnset = selectedTimes(1);
        slowDroopStart = selectedTimes(2);
        slowDroopEnd = selectedTimes(3);

    case "manual"

        selectedTimes = [ ...
            MANUAL_FAST_RISE_ONSET_S, ...
            MANUAL_SLOW_DROOP_START_S, ...
            MANUAL_SLOW_DROOP_END_S];

        if any(~isfinite(selectedTimes))
            error('Manual selection mode requires all three manual times.');
        end

        if ~(selectedTimes(1)<selectedTimes(2) && ...
             selectedTimes(2)<selectedTimes(3))
            error('Manual selected times must be in increasing order.');
        end

        fastRiseOnset = selectedTimes(1);
        slowDroopStart = selectedTimes(2);
        slowDroopEnd = selectedTimes(3);

    case "automatic"

        [fastRiseOnset,slowDroopStart,slowDroopEnd] = ...
            automaticRegionSelection(t,current_mA,Ts);

    otherwise
        error('REGION_SELECTION_MODE must be interactive, manual, or automatic.');
end

fprintf('\nSelected regions:\n');
fprintf('  Fast rise onset : %.9g ms\n',1e3*fastRiseOnset);
fprintf('  Slow droop start: %.9g ms\n',1e3*slowDroopStart);
fprintf('  Slow droop end  : %.9g ms\n',1e3*slowDroopEnd);

%% CAUSALLY SELECT THE ON SYNC TRANSACTION

beforeRise = txnEnd < fastRiseOnset;

candidateStart = txnStart(beforeRise);
candidateEnd = txnEnd(beforeRise);

if isempty(candidateEnd)
    error('No complete SYNC transaction occurs before the selected rise onset.');
end

lead = fastRiseOnset-candidateEnd;

preferred = lead<=MAX_SYNC_TO_RISE_LEAD_S;

if any(preferred)

    preferredIndices = find(preferred);
    [~,localBest] = min(lead(preferred));
    selectedCandidate = preferredIndices(localBest);

else

    warning([ ...
        'No SYNC transaction found inside the preferred causal window. ' ...
        'Using the nearest complete transaction before the rise.']);

    [~,selectedCandidate] = min(lead);
end

onCommandTime = candidateEnd(selectedCandidate);
commandToRiseDelay = fastRiseOnset-onCommandTime;

fprintf('\n============================================================\n');
fprintf('CAUSAL ON-COMMAND ASSOCIATION\n');
fprintf('============================================================\n');

for k = 1:numel(candidateEnd)

    marker = " ";

    if k==selectedCandidate
        marker = "*";
    end

    fprintf('  %s transaction %d: end %.9g ms, lead to rise %.6g us\n', ...
        marker,k,1e3*candidateEnd(k), ...
        1e6*(fastRiseOnset-candidateEnd(k)));
end

fprintf('\nSelected ON SYNC end : %.9g ms\n',1e3*onCommandTime);
fprintf('SYNC -> fast rise    : %.9g us\n',1e6*commandToRiseDelay);

%% CHECK WHETHER SLOW DROOP IS ASSOCIATED WITH SYNC ACTIVITY

if ~isempty(txnEnd)

    [nearestDroopDistance,nearestDroopIdx] = ...
        min(abs(txnEnd-slowDroopStart));

    nearestDroopSigned = ...
        txnEnd(nearestDroopIdx)-slowDroopStart;

    fprintf('\n============================================================\n');
    fprintf('SLOW-DROOP COMMAND CHECK\n');
    fprintf('============================================================\n');

    fprintf('Nearest SYNC transaction end to droop start:\n');
    fprintf('  SYNC end      : %.9g ms\n',1e3*txnEnd(nearestDroopIdx));
    fprintf('  Droop start   : %.9g ms\n',1e3*slowDroopStart);
    fprintf('  Signed offset : %.9g us\n',1e6*nearestDroopSigned);

    if nearestDroopDistance<=SYNC_NEAR_DROOP_WARNING_S

        warning([ ...
            'A SYNC transaction ends within %.3f us of the selected slow ' ...
            'droop start. Do not call the droop purely passive until this ' ...
            'transaction is understood.'], ...
            1e6*nearestDroopDistance);

    else

        fprintf(['No complete SYNC transaction was detected within %.3f us ' ...
                 'of the selected droop start.\n'], ...
                 1e6*SYNC_NEAR_DROOP_WARNING_S);
    end

    insideDroop = ...
        txnEnd>=slowDroopStart & ...
        txnEnd<=slowDroopEnd;

    fprintf('SYNC transaction ends inside selected droop region: %d\n', ...
        nnz(insideDroop));

    if any(insideDroop)
        warning(['The selected slow-droop fit region contains SYNC activity. ' ...
                 'Interpret the exponential fit cautiously.']);
    end
end

%% ESTIMATE INITIAL AND EARLY PLATEAU CURRENT

trCommand = t-onCommandTime;

baselineMask = ...
    trCommand>=FAST_BASELINE_START_S & ...
    trCommand<=FAST_BASELINE_END_S;

if nnz(baselineMask)<10
    error('Fast-rise baseline window contains too few samples.');
end

Ibaseline = median(current_mA(baselineMask),'omitnan');

plateauStart = ...
    fastRiseOnset+EARLY_PLATEAU_START_AFTER_RISE_S;

plateauEnd = min( ...
    fastRiseOnset+EARLY_PLATEAU_MAX_END_AFTER_RISE_S, ...
    slowDroopStart-EARLY_PLATEAU_GUARD_BEFORE_DROOP_S);

if plateauEnd<=plateauStart

    plateauStart = ...
        fastRiseOnset+0.25*(slowDroopStart-fastRiseOnset);

    plateauEnd = ...
        fastRiseOnset+0.70*(slowDroopStart-fastRiseOnset);
end

plateauMask = ...
    t>=plateauStart & ...
    t<=plateauEnd;

if nnz(plateauMask)<10
    error('Early plateau window contains too few samples.');
end

Iearly = median(current_mA(plateauMask),'omitnan');

fastStep_mA = Iearly-Ibaseline;

if fastStep_mA<=0
    error('Measured fast rise step is not positive.');
end

effectivePeakGain = fastStep_mA/NOMINAL_COMMAND_MA;

fprintf('\n============================================================\n');
fprintf('FAST RISE LEVELS\n');
fprintf('============================================================\n');

fprintf('Pre-command baseline      : %.9g mA\n',Ibaseline);
fprintf('Early plateau current     : %.9g mA\n',Iearly);
fprintf('Fast measured step        : %.9g mA\n',fastStep_mA);
fprintf('Local nominal-command gain: %.9g measured mA / nominal mA\n', ...
    effectivePeakGain);

%% FAST RISE METRICS

fastAnalysisEnd = min( ...
    onCommandTime+FAST_FIT_MAX_DURATION_S, ...
    slowDroopStart);

fastMask = ...
    t>=onCommandTime & ...
    t<=fastAnalysisEnd;

tFast = t(fastMask)-onCommandTime;

yFast_mA = current_mA(fastMask)-Ibaseline;

yFastNorm = yFast_mA/fastStep_mA;

fastMetrics = transitionMetrics( ...
    tFast,yFast_mA,fastStep_mA, ...
    LOW_FRACTION,MID_FRACTION,HIGH_FRACTION, ...
    SETTLING_BAND_FRACTION,MIN_SETTLING_HOLD_S,Ts);

fprintf('\nFast rise metrics:\n');
fprintf('  Causal command-to-rise delay : %.9g us\n', ...
    1e6*commandToRiseDelay);
fprintf('  10%% crossing                 : %.9g us\n', ...
    1e6*fastMetrics.t10_s);
fprintf('  50%% crossing                 : %.9g us\n', ...
    1e6*fastMetrics.t50_s);
fprintf('  90%% crossing                 : %.9g us\n', ...
    1e6*fastMetrics.t90_s);
fprintf('  10-90%% rise time             : %.9g us\n', ...
    1e6*fastMetrics.t10_90_s);
fprintf('  Overshoot                    : %.9g %%\n', ...
    fastMetrics.overshoot_pct);
fprintf('  Settling time                : %.9g us\n', ...
    1e6*fastMetrics.settling_s);

%% FAST RISE LOW-ORDER FITS

fastFits = fitFastModels(tFast,yFastNorm);

fprintf('\n============================================================\n');
fprintf('FAST RISE MODEL FITS\n');
fprintf('============================================================\n');

disp(fastFits.table);

writetable(fastFits.table, ...
    fullfile(RESULTS_FOLDER,"Attempt4_FastModelFits.csv"));

figure('Name','Attempt 4 fast model fit');

plot(tFast*1e6,yFastNorm,'LineWidth',1.6);
hold on;

plot(tFast*1e6,fastFits.P1.yhat,'LineWidth',1.2);
plot(tFast*1e6,fastFits.P1D.yhat,'LineWidth',1.2);
plot(tFast*1e6,fastFits.P2.yhat,'LineWidth',1.2);

xline(commandToRiseDelay*1e6,':','selected rise onset');

grid on;

xlabel('Time from selected ON SYNC (us)');
ylabel('Normalized fast response');

title('Attempt 4 fast-rise low-order model fits');

legend('Measured','P1','P1D','P2','Location','best');

hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"Attempt4_FastModelFits.png"));

%% SLOW DROOP DATA

slowMask = ...
    t>=slowDroopStart & ...
    t<=slowDroopEnd;

tSlow = t(slowMask)-slowDroopStart;
ISlow = current_mA(slowMask);

if numel(tSlow)<20
    error('Selected slow-droop region contains too few samples.');
end

nStartSlow = max(5,round(0.02*numel(ISlow)));
nEndSlow = max(5,round(0.05*numel(ISlow)));

IstartSlow = median(ISlow(1:nStartSlow),'omitnan');
IendSlow = median(ISlow(end-nEndSlow+1:end),'omitnan');

droopChange_mA = IstartSlow-IendSlow;

IstartRelative = IstartSlow-Ibaseline;
IendRelative = IendSlow-Ibaseline;

droopPercent = ...
    100*(IstartRelative-IendRelative)/max(eps,abs(IstartRelative));

%% FIT SLOW EXPONENTIAL

slowFree = fitExponentialFreeAsymptote(tSlow,ISlow);
slowFixed = fitExponentialFixedAsymptote(tSlow,ISlow,Ibaseline);

R_eff_free = slowFree.tau_s/KNOWN_OUTPUT_C_F;
R_eff_fixed = slowFixed.tau_s/KNOWN_OUTPUT_C_F;

fprintf('\n============================================================\n');
fprintf('SLOW DROOP ANALYSIS\n');
fprintf('============================================================\n');

fprintf('Slow-region initial current : %.9g mA\n',IstartSlow);
fprintf('Slow-region final current   : %.9g mA\n',IendSlow);
fprintf('Current drop in fit region  : %.9g mA\n',droopChange_mA);
fprintf('Droop relative to baseline  : %.9g %%\n',droopPercent);

fprintf('\nFree-asymptote exponential:\n');
fprintf('  I_inf                       : %.9g mA\n',slowFree.Iinf_mA);
fprintf('  A                           : %.9g mA\n',slowFree.A_mA);
fprintf('  tau_s                       : %.9g us\n',1e6*slowFree.tau_s);
fprintf('  RMSE                        : %.9g mA\n',slowFree.rmse_mA);
fprintf('  fit                         : %.9g %%\n',slowFree.fit_pct);
fprintf('  inferred R_eff = tau/C      : %.9g ohm\n',R_eff_free);

fprintf('\nBaseline-fixed exponential:\n');
fprintf('  fixed asymptote             : %.9g mA\n',Ibaseline);
fprintf('  A                           : %.9g mA\n',slowFixed.A_mA);
fprintf('  tau_s                       : %.9g us\n',1e6*slowFixed.tau_s);
fprintf('  RMSE                        : %.9g mA\n',slowFixed.rmse_mA);
fprintf('  fit                         : %.9g %%\n',slowFixed.fit_pct);
fprintf('  inferred R_eff = tau/C      : %.9g ohm\n',R_eff_fixed);

fprintf('\nTheoretical comparison:\n');
fprintf('  known C                     : %.9g uF\n',1e6*KNOWN_OUTPUT_C_F);
fprintf('  external R                  : %.9g ohm\n',LOAD_R_OHM);
fprintf('  R*C                         : %.9g us\n',1e6*THEORETICAL_TAU_S);
fprintf('  tau_free / (R*C)            : %.9g\n', ...
    slowFree.tau_s/THEORETICAL_TAU_S);
fprintf('  tau_fixed / (R*C)           : %.9g\n', ...
    slowFixed.tau_s/THEORETICAL_TAU_S);

%% FIXED-TIME DROOP REPORT

reportCells = {};

for k = 1:numel(DROOP_REPORT_TIMES_S)

    tq = DROOP_REPORT_TIMES_S(k);

    if tq>tSlow(end)
        continue;
    end

    Iq = interp1(tSlow,ISlow,tq,'linear');

    drop_mA = IstartSlow-Iq;

    drop_pct = ...
        100*drop_mA/max(eps,abs(IstartRelative));

    rr.Time_us = 1e6*tq;
    rr.Current_mA = Iq;
    rr.DropFromSlowStart_mA = drop_mA;
    rr.Drop_pct = drop_pct;

    reportCells{end+1,1} = rr; %#ok<SAGROW>
end

if ~isempty(reportCells)

    reportRows = vertcat(reportCells{:});
    droopTimeTable = struct2table(reportRows);

    fprintf('\nSlow droop at fixed times:\n');
    disp(droopTimeTable);

    writetable(droopTimeTable, ...
        fullfile(RESULTS_FOLDER,"Attempt4_DroopAtFixedTimes.csv"));
end

%% SLOW DROOP FIGURE

figure('Name','Attempt 4 slow droop fit');

plot(tSlow*1e6,ISlow,'LineWidth',1.5);
hold on;

plot(tSlow*1e6,slowFree.yhat_mA,'LineWidth',1.3);
plot(tSlow*1e6,slowFixed.yhat_mA,'LineWidth',1.3);

theoryNorm = exp(-tSlow/THEORETICAL_TAU_S);

theoryCurve = ...
    Ibaseline + ...
    (IstartSlow-Ibaseline)*theoryNorm;

plot(tSlow*1e6,theoryCurve,'--','LineWidth',1.2);

grid on;

xlabel('Time from selected slow-droop start (us)');
ylabel('Measured current (mA)');

title(sprintf( ...
    'Slow droop: fitted tau = %.1f us, theoretical R*C = %.1f us', ...
    1e6*slowFree.tau_s,1e6*THEORETICAL_TAU_S));

legend( ...
    'Measured', ...
    'Free-asymptote fit', ...
    'Baseline-fixed fit', ...
    'Theoretical 100 us decay', ...
    'Location','best');

hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"Attempt4_SlowDroopFit.png"));

%% WHOLE ON-RESPONSE TWO-TIMESCALE MODEL

twoMode = struct();

if FIT_TWO_TIMESCALE_MODEL

    wholeMask = ...
        t>=onCommandTime & ...
        t<=slowDroopEnd;

    tWhole = t(wholeMask)-onCommandTime;
    yWhole = current_mA(wholeMask)-Ibaseline;

    TdFixed = commandToRiseDelay;

    Kf0 = max(yWhole);
    Ks0 = max(0.05*Kf0,Kf0-(IendSlow-Ibaseline));

    tauFast0 = max(0.2e-6,fastFits.P1D.tau_s);
    tauSlow0 = max(5*tauFast0,slowFree.tau_s);

    twoMode = fitTwoTimescaleModel( ...
        tWhole,yWhole,TdFixed, ...
        Kf0,Ks0,tauFast0,tauSlow0);

    fprintf('\n============================================================\n');
    fprintf('EXPLORATORY TWO-TIMESCALE MODEL\n');
    fprintf('============================================================\n');

    fprintf('Fixed measured delay Td : %.9g us\n',1e6*TdFixed);
    fprintf('Kf                      : %.9g mA/event\n',twoMode.Kf_mA);
    fprintf('Ks                      : %.9g mA/event\n',twoMode.Ks_mA);
    fprintf('tau_f                   : %.9g us\n',1e6*twoMode.tau_f_s);
    fprintf('tau_s                   : %.9g us\n',1e6*twoMode.tau_s_s);
    fprintf('fit                     : %.9g %%\n',twoMode.fit_pct);
    fprintf('RMSE                    : %.9g mA\n',twoMode.rmse_mA);

    fprintf('\nLocal nominal-current scaling, assuming linearity near 30 mA:\n');
    fprintf('Kf / 30 mA              : %.9g mA/mA\n', ...
        twoMode.Kf_mA/NOMINAL_COMMAND_MA);
    fprintf('Ks / 30 mA              : %.9g mA/mA\n', ...
        twoMode.Ks_mA/NOMINAL_COMMAND_MA);

    if (slowDroopEnd-slowDroopStart)<2*twoMode.tau_s_s
        warning([ ...
            'The selected slow observation window is shorter than two fitted ' ...
            'slow time constants. Ks and tau_s may be weakly identifiable ' ...
            'from this single capture.']);
    end

    figure('Name','Attempt 4 two-timescale fit');

    plot(tWhole*1e6,yWhole,'LineWidth',1.5);
    hold on;

    plot(tWhole*1e6,twoMode.yhat_mA,'LineWidth',1.4);

    xline(TdFixed*1e6,':','measured rise onset');
    xline((slowDroopStart-onCommandTime)*1e6,':','selected slow start');

    grid on;

    xlabel('Time from selected ON SYNC (us)');
    ylabel('Incremental measured current (mA)');

    title(sprintf( ...
        'Exploratory two-timescale plant fit, %.1f%%', ...
        twoMode.fit_pct));

    legend('Measured','Two-timescale model','Location','best');

    hold off;

    saveas(gcf, ...
        fullfile(RESULTS_FOLDER,"Attempt4_TwoTimescaleFit.png"));
end

%% REGION VERIFICATION FIGURE

figure('Name','Attempt 4 selected regions');

plot(t*1e3,current_mA,'LineWidth',1.15);
hold on;

xline(onCommandTime*1e3,'--','selected ON SYNC');
xline(fastRiseOnset*1e3,':','fast rise onset');
xline(slowDroopStart*1e3,':','slow droop start');
xline(slowDroopEnd*1e3,':','slow droop end');

for k = 1:numel(txnEnd)
    xline(txnEnd(k)*1e3,':');
end

yline(Ibaseline,'--','baseline');
yline(Iearly,'--','early plateau');

grid on;

xlabel('Capture time (ms)');
ylabel('Measured current (mA)');

title('Attempt 4 selected regions and SYNC transaction ends');

hold off;

saveas(gcf, ...
    fullfile(RESULTS_FOLDER,"Attempt4_SelectedRegions.png"));

%% SUMMARY CSV

summary.Attempt = ATTEMPT_NUMBER;
summary.NominalCommand_mA = NOMINAL_COMMAND_MA;

summary.LoadResistance_ohm = LOAD_R_OHM;
summary.KnownOutputCap_uF = 1e6*KNOWN_OUTPUT_C_F;
summary.TheoreticalRC_us = 1e6*THEORETICAL_TAU_S;

summary.OnCommandTime_ms = 1e3*onCommandTime;
summary.FastRiseOnset_ms = 1e3*fastRiseOnset;
summary.CommandToRiseDelay_us = 1e6*commandToRiseDelay;

summary.BaselineCurrent_mA = Ibaseline;
summary.EarlyPlateauCurrent_mA = Iearly;
summary.FastStep_mA = fastStep_mA;
summary.EffectivePeakGain_mA_per_mA = effectivePeakGain;

summary.FastT10_us = 1e6*fastMetrics.t10_s;
summary.FastT50_us = 1e6*fastMetrics.t50_s;
summary.FastT90_us = 1e6*fastMetrics.t90_s;
summary.FastT10_90_us = 1e6*fastMetrics.t10_90_s;

summary.SlowDroopStart_ms = 1e3*slowDroopStart;
summary.SlowDroopEnd_ms = 1e3*slowDroopEnd;
summary.SlowDroopDuration_us = 1e6*(slowDroopEnd-slowDroopStart);

summary.SlowStartCurrent_mA = IstartSlow;
summary.SlowEndCurrent_mA = IendSlow;
summary.SlowDroop_pct = droopPercent;

summary.SlowTauFree_us = 1e6*slowFree.tau_s;
summary.SlowTauFixed_us = 1e6*slowFixed.tau_s;

summary.ReffFree_ohm = R_eff_free;
summary.ReffFixed_ohm = R_eff_fixed;

summary.FastP1Fit_pct = fastFits.P1.fit_pct;
summary.FastP1DFit_pct = fastFits.P1D.fit_pct;
summary.FastP2Fit_pct = fastFits.P2.fit_pct;

summary.FastP1D_Td_us = 1e6*fastFits.P1D.Td_s;
summary.FastP1D_Tau_us = 1e6*fastFits.P1D.tau_s;
summary.FastP1D_K = fastFits.P1D.K;

if FIT_TWO_TIMESCALE_MODEL

    summary.TwoModeFit_pct = twoMode.fit_pct;
    summary.TwoMode_Kf_mA = twoMode.Kf_mA;
    summary.TwoMode_Ks_mA = twoMode.Ks_mA;
    summary.TwoMode_TauFast_us = 1e6*twoMode.tau_f_s;
    summary.TwoMode_TauSlow_us = 1e6*twoMode.tau_s_s;

else

    summary.TwoModeFit_pct = NaN;
    summary.TwoMode_Kf_mA = NaN;
    summary.TwoMode_Ks_mA = NaN;
    summary.TwoMode_TauFast_us = NaN;
    summary.TwoMode_TauSlow_us = NaN;
end

summaryTable = struct2table(summary);

writetable(summaryTable, ...
    fullfile(RESULTS_FOLDER,"Attempt4_Summary.csv"));

%% SAVE MODEL DATA

models = struct();

models.fastFits = fastFits;
models.slowFree = slowFree;
models.slowFixed = slowFixed;
models.twoMode = twoMode;

models.Ibaseline_mA = Ibaseline;
models.Iearly_mA = Iearly;

models.commandToRiseDelay_s = commandToRiseDelay;

models.theoreticalTau_s = THEORETICAL_TAU_S;
models.knownOutputC_F = KNOWN_OUTPUT_C_F;
models.loadR_ohm = LOAD_R_OHM;

models.region.fastRiseOnset_s = fastRiseOnset;
models.region.slowDroopStart_s = slowDroopStart;
models.region.slowDroopEnd_s = slowDroopEnd;

if exist('tf','file')==2

    try

        Gfast_event = tf( ...
            fastFits.P1D.K, ...
            [fastFits.P1D.tau_s 1], ...
            'InputDelay',fastFits.P1D.Td_s);

        models.Gfast_event = Gfast_event;

        if FIT_TWO_TIMESCALE_MODEL

            Kf = twoMode.Kf_mA;
            Ks = twoMode.Ks_mA;

            tfast = twoMode.tau_f_s;
            tslow = twoMode.tau_s_s;

            num = [ ...
                Kf*tslow-Ks*tfast, ...
                Kf-Ks];

            den = [ ...
                tfast*tslow, ...
                tfast+tslow, ...
                1];

            Gtwo_event = tf( ...
                num,den, ...
                'InputDelay',commandToRiseDelay);

            Gtwo_nominal = tf( ...
                num/NOMINAL_COMMAND_MA, ...
                den, ...
                'InputDelay',commandToRiseDelay);

            models.Gtwo_event = Gtwo_event;
            models.Gtwo_nominal = Gtwo_nominal;

            fprintf('\nControl System Toolbox transfer functions created.\n');

            fprintf('\nGtwo_event(s), measured mA per unit 30 mA event:\n');
            disp(Gtwo_event);

            fprintf(['Gtwo_nominal(s), local measured mA / nominal mA ' ...
                     'assuming linearity near 30 mA:\n']);
            disp(Gtwo_nominal);
        end

    catch ME
        warning('Could not create transfer-function objects: %s',ME.message);
    end
end

save(fullfile(RESULTS_FOLDER,"Attempt4_Models.mat"),"models");

%% FINAL SUMMARY

fprintf('\n============================================================\n');
fprintf('FINAL ATTEMPT 4 SUMMARY\n');
fprintf('============================================================\n');

fprintf('Fast current establishment:\n');
fprintf('  measured causal delay      : %.6g us\n', ...
    1e6*commandToRiseDelay);
fprintf('  measured 10-90 rise        : %.6g us\n', ...
    1e6*fastMetrics.t10_90_s);
fprintf('  best fast candidate by fit : %s\n', ...
    string(fastFits.bestModel));

fprintf('\nSlow droop:\n');
fprintf('  selected duration          : %.6g us\n', ...
    1e6*(slowDroopEnd-slowDroopStart));
fprintf('  measured droop             : %.6g %%\n',droopPercent);
fprintf('  fitted tau, free asymptote : %.6g us\n', ...
    1e6*slowFree.tau_s);
fprintf('  theoretical 1k * 0.1uF     : %.6g us\n', ...
    1e6*THEORETICAL_TAU_S);
fprintf('  inferred effective R       : %.6g ohm\n',R_eff_free);

if FIT_TWO_TIMESCALE_MODEL
    fprintf('\nTwo-timescale exploratory fit:\n');
    fprintf('  Kf                         : %.6g mA/event\n',twoMode.Kf_mA);
    fprintf('  Ks                         : %.6g mA/event\n',twoMode.Ks_mA);
    fprintf('  tau_f                      : %.6g us\n',1e6*twoMode.tau_f_s);
    fprintf('  tau_s                      : %.6g us\n',1e6*twoMode.tau_s_s);
    fprintf('  same-capture fit           : %.6g %%\n',twoMode.fit_pct);
end

fprintf('\nImportant limitation:\n');
fprintf(['  These parameters come from one nominal 30 mA capture. They are\n' ...
         '  suitable for starting a provisional Simulink model, but the slow\n' ...
         '  mode needs repeated long-hold captures for defensible validation.\n']);

fprintf('\nResults folder:\n%s\n',RESULTS_FOLDER);

fprintf('\nAnalysis complete.\n');

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function [ch1Path,ch2Path,folder] = findAttemptFiles( ...
    rootFolder,attemptNumber,ch1Name,ch2Name)

    hits = dir(fullfile(rootFolder,"**",ch1Name));

    candidates = strings(0,1);

    for k = 1:numel(hits)

        f = hits(k).folder;

        pattern = sprintf('Attempt\\s*%d(?:\\D|$)',attemptNumber);

        if isempty(regexpi(f,pattern,'once'))
            continue;
        end

        if isfile(fullfile(f,ch2Name))
            candidates(end+1,1) = string(f); %#ok<AGROW>
        end
    end

    candidates = unique(candidates);

    if isempty(candidates)
        error([ ...
            'Could not find a folder containing Attempt %d with both ' ...
            '%s and %s below:\n%s'], ...
            attemptNumber,ch1Name,ch2Name,rootFolder);
    end

    if numel(candidates)==1

        folder = char(candidates(1));

    else

        fprintf('\nMultiple Attempt %d folders were found:\n',attemptNumber);

        for k = 1:numel(candidates)
            fprintf('  %d: %s\n',k,candidates(k));
        end

        selection = input('Choose folder number: ');

        if ~isscalar(selection) || ...
                selection<1 || ...
                selection>numel(candidates)
            error('Invalid folder selection.');
        end

        folder = char(candidates(selection));
    end

    ch1Path = fullfile(folder,ch1Name);
    ch2Path = fullfile(folder,ch2Name);
end

function [fastRise,slowStart,slowEnd] = ...
    automaticRegionSelection(t,current,Ts)

    nSmooth = max(3,round(1e-6/Ts));

    if mod(nSmooth,2)==0
        nSmooth = nSmooth+1;
    end

    y = movmean(current,nSmooth);
    dy = gradient(y,Ts);

    [~,riseCentre] = max(dy);

    positiveThreshold = 0.10*dy(riseCentre);

    riseCandidates = find( ...
        (1:numel(dy)).'<=riseCentre & ...
        dy>=positiveThreshold);

    if isempty(riseCandidates)
        fastRiseIdx = riseCentre;
    else
        fastRiseIdx = riseCandidates(1);
    end

    fastRise = t(fastRiseIdx);

    [~,peakIdx] = max(y);

    searchStart = min(numel(y), ...
        peakIdx+round(20e-6/Ts));

    if searchStart>=numel(y)
        error('Automatic slow-droop detection failed.');
    end

    negative = dy(searchStart:end);

    [~,localNegative] = min(negative);

    negativeCentre = searchStart+localNegative-1;

    negThreshold = 0.10*dy(negativeCentre);

    startCandidates = find( ...
        (1:numel(dy)).'>=searchStart & ...
        (1:numel(dy)).'<=negativeCentre & ...
        dy<=negThreshold);

    if isempty(startCandidates)
        slowStartIdx = negativeCentre;
    else
        slowStartIdx = startCandidates(1);
    end

    slowStart = t(slowStartIdx);

    tailN = max(10,round(0.10*numel(y)));

    late = median(y(end-tailN+1:end),'omitnan');

    startLevel = y(slowStartIdx);

    threshold = late+0.05*(startLevel-late);

    after = find( ...
        (1:numel(y)).'>=slowStartIdx & ...
        y<=threshold, ...
        1,'first');

    if isempty(after)
        slowEndIdx = numel(y);
    else
        slowEndIdx = after;
    end

    slowEnd = t(slowEndIdx);
end

function [txnStart,txnEnd,threshold] = detectSyncTransactions( ...
    t,syncV,userThreshold,activeLow,minWidth,maxWidth)

    lo = percentileLocal(syncV,5);
    hi = percentileLocal(syncV,95);

    if isnan(userThreshold)
        threshold = 0.5*(lo+hi);
    else
        threshold = userThreshold;
    end

    if activeLow
        active = syncV<threshold;
    else
        active = syncV>threshold;
    end

    d = diff([false;active;false]);

    startsIdx = find(d==1);
    endsIdx = find(d==-1)-1;

    if isempty(startsIdx) || isempty(endsIdx)
        txnStart = [];
        txnEnd = [];
        return;
    end

    n = min(numel(startsIdx),numel(endsIdx));

    startsIdx = startsIdx(1:n);
    endsIdx = endsIdx(1:n);

    validOrder = endsIdx>startsIdx;

    startsIdx = startsIdx(validOrder);
    endsIdx = endsIdx(validOrder);

    widths = t(endsIdx)-t(startsIdx);

    validWidth = ...
        widths>=minWidth & ...
        widths<=maxWidth;

    txnStart = t(startsIdx(validWidth));
    txnEnd = t(endsIdx(validWidth));
end

function M = transitionMetrics( ...
    t,y,stepMag,lowFrac,midFrac,highFrac, ...
    settlingBand,minSettlingHold,Ts)

    M.t10_s = crossingTime(t,y,lowFrac*stepMag);
    M.t50_s = crossingTime(t,y,midFrac*stepMag);
    M.t90_s = crossingTime(t,y,highFrac*stepMag);

    M.t10_90_s = M.t90_s-M.t10_s;

    [peak,peakIdx] = max(y);

    M.peak_mA = peak;
    M.peakTime_s = t(peakIdx);

    M.overshoot_pct = ...
        max(0,100*(peak-stepMag)/max(eps,stepMag));

    band = settlingBand*stepMag;
    err = abs(y-stepMag);

    holdSamples = max(3,ceil(minSettlingHold/Ts));

    M.settling_s = NaN;

    startIdx = find(t>=max(0,M.t90_s),1,'first');

    if isempty(startIdx)
        return;
    end

    for k = startIdx:(numel(y)-holdSamples+1)

        if all(err(k:k+holdSamples-1)<=band)
            M.settling_s = t(k);
            break;
        end
    end
end

function tc = crossingTime(t,y,level)

    valid = t>=0;

    tv = t(valid);
    yv = y(valid);

    idx = find(yv>=level,1,'first');

    if isempty(idx)
        tc = NaN;
        return;
    end

    if idx==1
        tc = tv(1);
        return;
    end

    y1 = yv(idx-1);
    y2 = yv(idx);

    t1 = tv(idx-1);
    t2 = tv(idx);

    if y2==y1
        tc = t2;
    else
        a = (level-y1)/(y2-y1);
        tc = t1+a*(t2-t1);
    end
end

function fits = fitFastModels(t,y)

    P1 = fitP1(t,y);
    P1D = fitP1D(t,y);
    P2 = fitP2(t,y);

    Model = ["P1";"P1D";"P2"];

    Fit_pct = [P1.fit_pct;P1D.fit_pct;P2.fit_pct];
    RMSE = [P1.rmse;P1D.rmse;P2.rmse];

    fits.P1 = P1;
    fits.P1D = P1D;
    fits.P2 = P2;

    fits.table = table(Model,Fit_pct,RMSE);

    [~,best] = max(Fit_pct);
    fits.bestModel = Model(best);
end

function M = fitP1(t,y)

    tau0 = 2e-6;
    K0 = 1;

    q0 = [log(tau0),log(K0)];

    objective = @(q) mean(( ...
        responseP1(t,exp(q(1)),exp(q(2)))-y).^2,'omitnan');

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',5000,'MaxFunEvals',5000));

    M.tau_s = exp(q(1));
    M.K = exp(q(2));

    M.yhat = responseP1(t,M.tau_s,M.K);

    [M.fit_pct,M.rmse] = fitStats(y,M.yhat);
end

function M = fitP1D(t,y)

    tau0 = 2e-6;
    Td0 = 0.5e-6;
    K0 = 1;

    q0 = [log(tau0),log(Td0),log(K0)];

    objective = @(q) mean(( ...
        responseP1D(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2,'omitnan');

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',8000,'MaxFunEvals',8000));

    M.tau_s = exp(q(1));
    M.Td_s = exp(q(2));
    M.K = exp(q(3));

    M.yhat = responseP1D(t,M.tau_s,M.Td_s,M.K);

    [M.fit_pct,M.rmse] = fitStats(y,M.yhat);
end

function M = fitP2(t,y)

    tau10 = 2e-6;
    tau20 = 0.8e-6;
    K0 = 1;

    q0 = [log(tau10),log(tau20),log(K0)];

    objective = @(q) mean(( ...
        responseP2(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2,'omitnan');

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',10000,'MaxFunEvals',10000));

    taus = sort([exp(q(1)),exp(q(2))],'descend');

    M.tau1_s = taus(1);
    M.tau2_s = taus(2);
    M.K = exp(q(3));

    M.yhat = responseP2(t,M.tau1_s,M.tau2_s,M.K);

    [M.fit_pct,M.rmse] = fitStats(y,M.yhat);
end

function y = responseP1(t,tau,K)

    tp = max(t,0);

    y = K*(1-exp(-tp/tau));
end

function y = responseP1D(t,tau,Td,K)

    y = zeros(size(t));

    idx = t>=Td;

    tp = t(idx)-Td;

    y(idx) = K*(1-exp(-tp/tau));
end

function y = responseP2(t,tau1,tau2,K)

    tp = max(t,0);

    if abs(tau1-tau2)<1e-4*max(tau1,tau2)

        tau = 0.5*(tau1+tau2);

        y = K*(1-exp(-tp/tau).*(1+tp/tau));

    else

        y = K*( ...
            1 - ...
            (tau1*exp(-tp/tau1)-tau2*exp(-tp/tau2)) ...
            /(tau1-tau2));
    end
end

function F = fitExponentialFreeAsymptote(t,y)

    nTail = max(10,round(0.10*numel(y)));

    Iinf0 = median(y(end-nTail+1:end),'omitnan');

    A0 = y(1)-Iinf0;

    tau0 = max(1e-6,0.25*t(end));

    q0 = [Iinf0,A0,log(tau0)];

    objective = @(q) mean(( ...
        (q(1)+q(2)*exp(-t/exp(q(3))))-y).^2,'omitnan');

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',10000,'MaxFunEvals',10000));

    F.Iinf_mA = q(1);
    F.A_mA = q(2);
    F.tau_s = exp(q(3));

    F.yhat_mA = ...
        F.Iinf_mA+F.A_mA*exp(-t/F.tau_s);

    [F.fit_pct,F.rmse_mA] = fitStats(y,F.yhat_mA);
end

function F = fitExponentialFixedAsymptote(t,y,Iinf)

    A0 = y(1)-Iinf;

    tau0 = max(1e-6,0.25*t(end));

    q0 = [A0,log(tau0)];

    objective = @(q) mean(( ...
        (Iinf+q(1)*exp(-t/exp(q(2))))-y).^2,'omitnan');

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',10000,'MaxFunEvals',10000));

    F.Iinf_mA = Iinf;
    F.A_mA = q(1);
    F.tau_s = exp(q(2));

    F.yhat_mA = ...
        Iinf+F.A_mA*exp(-t/F.tau_s);

    [F.fit_pct,F.rmse_mA] = fitStats(y,F.yhat_mA);
end

function M = fitTwoTimescaleModel( ...
    t,y,Td,Kf0,Ks0,tauf0,taus0)

    q0 = [ ...
        log(max(Kf0,eps)), ...
        log(max(Ks0,eps)), ...
        log(max(tauf0,eps)), ...
        log(max(taus0-tauf0,eps))];

    objective = @(q) mean(( ...
        twoTimescaleResponse( ...
            t,Td, ...
            exp(q(1)), ...
            exp(q(2)), ...
            exp(q(3)), ...
            exp(q(3))+exp(q(4))) ...
        - y).^2,'omitnan');

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',20000,'MaxFunEvals',20000));

    M.Kf_mA = exp(q(1));
    M.Ks_mA = exp(q(2));

    M.tau_f_s = exp(q(3));
    M.tau_s_s = exp(q(3))+exp(q(4));

    M.Td_s = Td;

    M.yhat_mA = twoTimescaleResponse( ...
        t,Td, ...
        M.Kf_mA,M.Ks_mA, ...
        M.tau_f_s,M.tau_s_s);

    [M.fit_pct,M.rmse_mA] = fitStats(y,M.yhat_mA);
end

function y = twoTimescaleResponse(t,Td,Kf,Ks,tauf,taus)

    y = zeros(size(t));

    idx = t>=Td;

    tp = t(idx)-Td;

    y(idx) = ...
        Kf*(1-exp(-tp/tauf)) ...
        - Ks*(1-exp(-tp/taus));
end

function [fitPct,rmse] = fitStats(y,yhat)

    good = isfinite(y)&isfinite(yhat);

    y = y(good);
    yhat = yhat(good);

    e = y-yhat;

    rmse = sqrt(mean(e.^2));

    denom = norm(y-mean(y));

    fitPct = 100*(1-norm(e)/max(eps,denom));
end

function [t,y] = loadScopeCSV(path)

    M = readmatrix(path);

    if isempty(M)
        error('No numeric data in:\n%s',path);
    end

    numericPerRow = sum(isfinite(M),2);

    dataLike = numericPerRow>=2;

    if ~any(dataLike)
        error('Could not find numeric scope data in:\n%s',path);
    end

    d = diff([false;dataLike;false]);

    starts = find(d==1);
    stops = find(d==-1)-1;

    [~,best] = max(stops-starts+1);

    M = M(starts(best):stops(best),:);

    M(:,all(~isfinite(M),1)) = [];

    if size(M,2)<2
        error('Expected at least two numeric columns in:\n%s',path);
    end

    timeCol = autoTimeColumn(M);
    signalCol = autoSignalColumn(M,timeCol);

    t = M(:,timeCol);
    y = M(:,signalCol);

    good = isfinite(t)&isfinite(y);

    t = t(good);
    y = y(good);

    [t,ord] = sort(t);
    y = y(ord);

    [t,idx] = unique(t,'stable');
    y = y(idx);
end

function [t,y1,y2,Ts] = alignChannels(t1,y1,t2,y2)

    Ts = max(median(diff(t1)),median(diff(t2)));

    t0 = max(t1(1),t2(1));
    tf = min(t1(end),t2(end));

    if tf<=t0
        error('CH1 and CH2 time ranges do not overlap.');
    end

    t = (t0:Ts:tf).';

    y1 = interp1(t1,y1,t,'nearest');
    y2 = interp1(t2,y2,t,'linear');

    good = isfinite(y1)&isfinite(y2);

    t = t(good);
    y1 = y1(good);
    y2 = y2(good);
end

function c = autoTimeColumn(M)

    score = -inf(1,size(M,2));

    for k = 1:size(M,2)

        x = M(:,k);
        x = x(isfinite(x));

        if numel(x)<10
            continue;
        end

        dx = diff(x);

        mono = max(mean(dx>0),mean(dx<0));

        nz = abs(dx)>eps(max(abs(x)));

        if ~any(nz)
            continue;
        end

        dd = abs(dx(nz));

        reg = 1/(1+std(dd)/max(eps,mean(dd)));

        score(k) = 3*mono+reg;
    end

    [best,c] = max(score);

    if ~isfinite(best)
        error('Automatic time-column detection failed.');
    end
end

function c = autoSignalColumn(M,timeCol)

    candidates = setdiff(1:size(M,2),timeCol);

    score = -inf(size(candidates));

    for k = 1:numel(candidates)

        x = M(:,candidates(k));

        score(k) = abs( ...
            percentileLocal(x,95)-percentileLocal(x,5));
    end

    [~,idx] = max(score);

    c = candidates(idx);
end

function q = percentileLocal(x,p)

    x = sort(x(isfinite(x)));

    if isempty(x)
        q = NaN;
        return;
    end

    if numel(x)==1
        q = x;
        return;
    end

    r = 1+(p/100)*(numel(x)-1);

    lo = floor(r);
    hi = ceil(r);

    if lo==hi
        q = x(lo);
    else
        q = x(lo)+(r-lo)*(x(hi)-x(lo));
    end
end

function folder = getScriptFolder()

    folder = pwd;

    try
        active = matlab.desktop.editor.getActiveFilename;

        if ~isempty(active)
            folder = fileparts(active);
            return;
        end
    catch
    end

    try
        f = mfilename('fullpath');

        if ~isempty(f)
            folder = fileparts(f);
        end
    catch
    end
end
