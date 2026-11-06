%% FallAnalysis10mA_CausalSync.m
% OpenXstim repeated nominal 10 mA FALL analysis
%
% PURPOSE
% -------
% Analyse the repeated OFF transitions:
%
%       nominal firmware command: 10 mA -> 0 mA
%
% The output is already undergoing passive droop before the commanded OFF
% transition. Therefore this script explicitly separates:
%
%   1. passive pre-command droop
%   2. the true DAC/SPI OFF transaction
%   3. the fast commanded fall after that transaction
%
% CRITICAL CHANGE FROM THE PREVIOUS SCRIPT
% ----------------------------------------
% The OFF command is NOT selected by asking which SYNC edge has the largest
% output change after it.
%
% Instead:
%
%   A. detect the fast commanded fall onset from CH2
%   B. detect complete active-low SYNC transactions from CH1
%   C. choose the LAST complete SYNC transaction that FINISHES BEFORE the
%      detected fall onset
%   D. use that transaction end as the true OFF command timing reference
%
% This enforces causality:
%
%       command must occur before response
%
% CH1 = Arduino / DAC SYNC
% CH2 = voltage across 1 kOhm resistor
%
% No System Identification Toolbox is required.
%
% OUTPUTS
% -------
%   FallCausalSync_Results/
%       FallTrialMetrics.csv
%       FallRepeatabilitySummary.csv
%       FallModelFits_SyncReferenced.csv
%       FallModelFits_OnsetReferenced.csv
%
%       FallRawAligned.png
%       FallPassiveDroop.png
%       FallSyncTransactionVerification.png
%       FallNormalizedLocalBaseline.png
%       FallMeanResponse.png
%       FallModelValidation_SyncReferenced.png
%       FallModelValidation_OnsetReferenced.png
%
% NOTE
% ----
% The stale firmware current calibration is intentionally NOT corrected.
% Measured current through the 1 kOhm resistor is treated as the physical
% output. The nominal 10 mA command is retained only as command metadata.

clear;
clc;
close all;

%% USER SETTINGS

% =========================================================================
% FILES
% =========================================================================

ROOT_FOLDER = getScriptFolder();

REPEATED_FOLDER = fullfile(ROOT_FOLDER,"Repeated Trials 10mA");

CH1_NAME = "CH1.CSV";
CH2_NAME = "CH2.CSV";

RESULTS_FOLDER = fullfile(ROOT_FOLDER,"FallCausalSync_Results");

% =========================================================================
% ELECTRICAL SETUP
% =========================================================================

LOAD_R_OHM = 1000;

NOMINAL_COMMAND_STEP_MA = 10;

% Keep at 1 unless a scope/probe export scaling correction has been verified.
CH2_SCALE_FACTOR = 1;

% =========================================================================
% SYNC SIGNAL
% =========================================================================
%
% CH1 is active low in the observed captures:
%
%       high -> low = transaction start
%       low  -> high = transaction end
%
% For the DAC timing reference we use the END of the transaction by default.

SYNC_THRESHOLD_V = NaN;          % NaN = automatic midpoint
SYNC_ACTIVE_LOW = true;

% Reject pathological pulse widths. These are deliberately broad.
SYNC_MIN_PULSE_WIDTH_S = 0.05e-6;
SYNC_MAX_PULSE_WIDTH_S = 20e-6;

% Only consider SYNC transactions whose END occurs no more than this long
% before the detected commanded fall onset.
MAX_SYNC_TO_FALL_LEAD_S = 10e-6;

% If no valid transaction exists inside that window, allow fallback to the
% nearest complete transaction before the fall onset and print a warning.
ALLOW_SYNC_FALLBACK = true;

% =========================================================================
% FAST FALL ONSET DETECTION
% =========================================================================
%
% The fall onset is used ONLY to associate the correct preceding SYNC
% transaction and to create an onset-referenced dynamic model.
%
% It does NOT replace the true SYNC command time.
%
% Modes:
%
%   "derivative"
%       Recommended default. Detect the strongest sustained negative slope
%       after removing the slow passive trend.
%
%   "interactive"
%       Show each trace and click where the fast commanded fall begins.
%
%   "threshold"
%       First post-search point that falls below a threshold relative to the
%       local pre-fall level.
%
FALL_ONSET_MODE = "derivative";

% Search the fall onset over the entire capture first, before alignment.
% To avoid picking the final settling tail, detection uses derivative
% magnitude plus a sustained-change requirement.
DERIVATIVE_SMOOTHING_S = 0.10e-6;
DERIVATIVE_HOLD_S = 0.15e-6;

% Threshold-mode setting.
FALL_ONSET_FRACTION = 0.05;

% =========================================================================
% INITIAL CONDITION AND PASSIVE DROOP
% =========================================================================
%
% Once the true OFF transaction is found, estimate I0 from a SHORT window
% immediately before that transaction.

LOCAL_BASELINE_START_S = -0.50e-6;
LOCAL_BASELINE_END_S   = -0.05e-6;

% Fit a simple local line to quantify passive droop before OFF.
DROOP_FIT_START_S = -6e-6;
DROOP_FIT_END_S   = -0.20e-6;

% Final current from the tail of the post-command capture.
FINAL_TAIL_FRACTION = 0.20;

% =========================================================================
% ANALYSIS WINDOW
% =========================================================================

ANALYSIS_PRE_S  = 8e-6;
ANALYSIS_POST_S = 10e-6;

% =========================================================================
% TIME DOMAIN METRICS
% =========================================================================

LOW_FRACTION  = 0.10;
MID_FRACTION  = 0.50;
HIGH_FRACTION = 0.90;

SETTLING_BAND_FRACTION = 0.02;
MIN_SETTLING_HOLD_S = 0.8e-6;

% =========================================================================
% COMMON TIMEBASE
% =========================================================================

COMMON_TS_S = 25e-9;

COMMON_SYNC_PRE_S  = 4e-6;
COMMON_SYNC_POST_S = 10e-6;

ONSET_MODEL_POST_S = 8e-6;

% =========================================================================
% ESTIMATION / VALIDATION SPLIT
% =========================================================================

N_ESTIMATION_TRIALS = 3;

% =========================================================================
% MODEL FITTING
% =========================================================================

FIT_P2D = false;

%% FIND TRIALS

assert(isfolder(REPEATED_FOLDER), ...
    'Could not find repeated trials folder:\n%s',REPEATED_FOLDER);

if ~isfolder(RESULTS_FOLDER)
    mkdir(RESULTS_FOLDER);
end

attemptDirs = dir(fullfile(REPEATED_FOLDER,"Attempt *"));
attemptDirs = attemptDirs([attemptDirs.isdir]);

if isempty(attemptDirs)
    error('No Attempt folders found under:\n%s',REPEATED_FOLDER);
end

infoCells = cell(numel(attemptDirs),1);

for k = 1:numel(attemptDirs)

    name = string(attemptDirs(k).name);
    folder = fullfile(attemptDirs(k).folder,attemptDirs(k).name);

    x.folder = folder;
    x.attempt = parseAttemptNumber(name);
    x.trial = parseTrialNumber(name);

    if isnan(x.trial)
        x.trial = x.attempt;
    end

    infoCells{k} = x;
end

info = vertcat(infoCells{:});

[~,ord] = sort([info.trial]);
info = info(ord);

fprintf('\n============================================================\n');
fprintf('OPENXSTIM REPEATED 10 mA FALL ANALYSIS\n');
fprintf('CAUSAL SYNC ASSOCIATION\n');
fprintf('============================================================\n');
fprintf('Trials found : %d\n',numel(info));
fprintf('Onset mode   : %s\n',FALL_ONSET_MODE);
fprintf('SYNC logic   : active low\n');

%% PROCESS EACH TRIAL

fallCells = cell(numel(info),1);

for k = 1:numel(info)

    fallFolder = fullfile(info(k).folder,"Fall");

    ch1Path = fullfile(fallFolder,CH1_NAME);
    ch2Path = fullfile(fallFolder,CH2_NAME);

    assert(isfile(ch1Path),'Missing Fall/CH1.CSV in %s',info(k).folder);
    assert(isfile(ch2Path),'Missing Fall/CH2.CSV in %s',info(k).folder);

    fprintf('\n------------------------------------------------------------\n');
    fprintf('Trial %d, Attempt %d\n',round(info(k).trial),round(info(k).attempt));

    F = analyseFallCausal( ...
        ch1Path,ch2Path, ...
        LOAD_R_OHM,CH2_SCALE_FACTOR, ...
        SYNC_THRESHOLD_V,SYNC_ACTIVE_LOW, ...
        SYNC_MIN_PULSE_WIDTH_S,SYNC_MAX_PULSE_WIDTH_S, ...
        MAX_SYNC_TO_FALL_LEAD_S,ALLOW_SYNC_FALLBACK, ...
        FALL_ONSET_MODE, ...
        DERIVATIVE_SMOOTHING_S,DERIVATIVE_HOLD_S, ...
        FALL_ONSET_FRACTION, ...
        ANALYSIS_PRE_S,ANALYSIS_POST_S, ...
        LOCAL_BASELINE_START_S,LOCAL_BASELINE_END_S, ...
        DROOP_FIT_START_S,DROOP_FIT_END_S, ...
        FINAL_TAIL_FRACTION, ...
        LOW_FRACTION,MID_FRACTION,HIGH_FRACTION, ...
        SETTLING_BAND_FRACTION,MIN_SETTLING_HOLD_S);

    F.trial = info(k).trial;
    F.attempt = info(k).attempt;
    F.folder = info(k).folder;

    fallCells{k} = F;

    fprintf('  Detected fast fall onset  : %.6g s absolute\n',F.fastFallOnsetAbsolute_s);
    fprintf('  Selected OFF SYNC end     : %.6g s absolute\n',F.commandTimeAbsolute_s);
    fprintf('  SYNC -> fast fall delay   : %.6g us\n',1e6*F.commandToFallDelay_s);
    fprintf('  I immediately before OFF  : %.6g mA\n',F.initialAtCommand_mA);
    fprintf('  Final current             : %.6g mA\n',F.final_mA);
    fprintf('  Commanded fall magnitude  : %.6g mA\n',F.step_mA);
    fprintf('  Passive droop slope       : %.6g mA/us\n', ...
        1e-6*F.preDroopSlope_mA_per_s);
    fprintf('  10-90 fall time           : %.6g us\n', ...
        1e6*F.metricsSync.t10_90_s);

    fprintf('  Candidate SYNC transactions before fall:\n');

    for j = 1:numel(F.candidateTransactionEndAbsolute_s)

        lead = ...
            F.fastFallOnsetAbsolute_s - ...
            F.candidateTransactionEndAbsolute_s(j);

        marker = " ";

        if j==F.selectedCandidateIndex
            marker = "*";
        end

        fprintf('    %s %2d: start %.6g s, end %.6g s, lead %.6g us\n', ...
            marker,j, ...
            F.candidateTransactionStartAbsolute_s(j), ...
            F.candidateTransactionEndAbsolute_s(j), ...
            1e6*lead);
    end
end

falls = vertcat(fallCells{:});
nTrials = numel(falls);

%% METRICS TABLE

rowCells = cell(nTrials,1);

for k = 1:nTrials

    F = falls(k);

    row.Trial = F.trial;
    row.Attempt = F.attempt;

    row.FastFallOnsetAbsolute_s = F.fastFallOnsetAbsolute_s;
    row.CommandTimeAbsolute_s = F.commandTimeAbsolute_s;

    row.SyncToFallDelay_us = 1e6*F.commandToFallDelay_s;

    row.CurrentAtCommand_mA = F.initialAtCommand_mA;
    row.FinalCurrent_mA = F.final_mA;
    row.CommandedFallStep_mA = F.step_mA;

    row.EffectiveGain = F.step_mA/NOMINAL_COMMAND_STEP_MA;

    row.PreCommandDroopSlope_mA_per_us = ...
        1e-6*F.preDroopSlope_mA_per_s;

    row.PreCommandDroopAcrossWindow_mA = F.preDroopDelta_mA;

    row.T10_SYNC_us = 1e6*F.metricsSync.t10_s;
    row.T50_SYNC_us = 1e6*F.metricsSync.t50_s;
    row.T90_SYNC_us = 1e6*F.metricsSync.t90_s;
    row.T10_90_SYNC_us = 1e6*F.metricsSync.t10_90_s;

    row.T10_ONSET_us = 1e6*F.metricsOnset.t10_s;
    row.T50_ONSET_us = 1e6*F.metricsOnset.t50_s;
    row.T90_ONSET_us = 1e6*F.metricsOnset.t90_s;
    row.T10_90_ONSET_us = 1e6*F.metricsOnset.t10_90_s;

    row.Settling_SYNC_us = 1e6*F.metricsSync.settling_s;
    row.Settling_ONSET_us = 1e6*F.metricsOnset.settling_s;

    row.Overshoot_pct = F.metricsSync.overshoot_pct;

    row.MaxSlope_mA_per_us = ...
        1e-6*F.metricsSync.maxSlope_mA_per_s;

    row.ScopeSamplePeriod_ns = 1e9*F.Ts;

    row.Folder = string(F.folder);

    rowCells{k} = row;
end

rows = vertcat(rowCells{:});
fallMetrics = struct2table(rows);

writetable(fallMetrics, ...
    fullfile(RESULTS_FOLDER,"FallTrialMetrics.csv"));

fprintf('\n============================================================\n');
fprintf('FALL TRIAL METRICS\n');
fprintf('============================================================\n');

disp(fallMetrics(:,{ ...
    'Trial','Attempt','SyncToFallDelay_us', ...
    'CurrentAtCommand_mA','FinalCurrent_mA','CommandedFallStep_mA', ...
    'PreCommandDroopSlope_mA_per_us', ...
    'T10_90_SYNC_us','T10_90_ONSET_us','Settling_SYNC_us'}));

%% REPEATABILITY SUMMARY

summary.Direction = "Fall";
summary.N = height(fallMetrics);

summary.StepMean_mA = mean(fallMetrics.CommandedFallStep_mA,'omitnan');
summary.StepSD_mA = std(fallMetrics.CommandedFallStep_mA,'omitnan');
summary.StepCV_pct = ...
    100*summary.StepSD_mA/max(eps,abs(summary.StepMean_mA));

summary.CurrentAtCommandMean_mA = ...
    mean(fallMetrics.CurrentAtCommand_mA,'omitnan');

summary.CurrentAtCommandSD_mA = ...
    std(fallMetrics.CurrentAtCommand_mA,'omitnan');

summary.PreDroopSlopeMean_mA_per_us = ...
    mean(fallMetrics.PreCommandDroopSlope_mA_per_us,'omitnan');

summary.PreDroopSlopeSD_mA_per_us = ...
    std(fallMetrics.PreCommandDroopSlope_mA_per_us,'omitnan');

summary.SyncToFallDelayMean_us = ...
    mean(fallMetrics.SyncToFallDelay_us,'omitnan');

summary.SyncToFallDelaySD_us = ...
    std(fallMetrics.SyncToFallDelay_us,'omitnan');

summary.T1090SyncMean_us = ...
    mean(fallMetrics.T10_90_SYNC_us,'omitnan');

summary.T1090SyncSD_us = ...
    std(fallMetrics.T10_90_SYNC_us,'omitnan');

summary.T1090OnsetMean_us = ...
    mean(fallMetrics.T10_90_ONSET_us,'omitnan');

summary.T1090OnsetSD_us = ...
    std(fallMetrics.T10_90_ONSET_us,'omitnan');

summaryTable = struct2table(summary);

writetable(summaryTable, ...
    fullfile(RESULTS_FOLDER,"FallRepeatabilitySummary.csv"));

fprintf('\n============================================================\n');
fprintf('FALL REPEATABILITY SUMMARY\n');
fprintf('============================================================\n');

disp(summaryTable);

%% COMMON SYNC REFERENCED TIMEBASE

tSyncCommon = ...
    (-COMMON_SYNC_PRE_S:COMMON_TS_S:COMMON_SYNC_POST_S).';

Ysync = nan(numel(tSyncCommon),nTrials);
Iraw  = nan(numel(tSyncCommon),nTrials);

for k = 1:nTrials

    Ysync(:,k) = interp1Safe( ...
        falls(k).trSync, ...
        falls(k).normalizedSync, ...
        tSyncCommon);

    Iraw(:,k) = interp1Safe( ...
        falls(k).trSync, ...
        falls(k).current_mA, ...
        tSyncCommon);
end

meanSync = mean(Ysync,2,'omitnan');
stdSync  = std(Ysync,0,2,'omitnan');

%% COMMON ONSET REFERENCED TIMEBASE

tOnsetCommon = ...
    (0:COMMON_TS_S:ONSET_MODEL_POST_S).';

Yonset = nan(numel(tOnsetCommon),nTrials);

for k = 1:nTrials

    Yonset(:,k) = interp1Safe( ...
        falls(k).trOnset, ...
        falls(k).normalizedOnset, ...
        tOnsetCommon);
end

meanOnset = mean(Yonset,2,'omitnan');
stdOnset  = std(Yonset,0,2,'omitnan');

%% FIGURE 1: RAW FALLS ALIGNED TO TRUE OFF COMMAND

figure('Name','Fall raw aligned');

hold on;

for k = 1:nTrials
    plot(tSyncCommon*1e6,Iraw(:,k),'LineWidth',0.9);
end

xline(0,'--','true OFF SYNC');

grid on;

xlabel('Time from OFF command (us)');
ylabel('Measured current (mA)');

title('Repeated fall trials aligned to the causal OFF command');

hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"FallRawAligned.png"));

%% FIGURE 2: PASSIVE DROOP

figure('Name','Fall passive droop');

hold on;

for k = 1:nTrials

    F = falls(k);

    mask = ...
        F.trSync>=DROOP_FIT_START_S & ...
        F.trSync<=0;

    plot(F.trSync(mask)*1e6,F.current_mA(mask),'LineWidth',1.0);
end

xline(0,'--','true OFF SYNC');

grid on;

xlabel('Time from OFF command (us)');
ylabel('Measured current (mA)');

title('Passive current droop before the commanded OFF event');

hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"FallPassiveDroop.png"));

%% FIGURE 3: SYNC TRANSACTION VERIFICATION

figure('Name','SYNC transaction verification');

tl = tiledlayout(nTrials,1);
title(tl,'Causal OFF-command selection from complete SYNC transactions');

for k = 1:nTrials

    nexttile;

    F = falls(k);

    % Show a small region around the selected command and fall onset.
    trAbs = F.fullTimeAbsolute_s-F.commandTimeAbsolute_s;

    mask = ...
        trAbs>=-8e-6 & ...
        trAbs<=8e-6;

    yyaxis left;

    plot(trAbs(mask)*1e6,F.fullSyncV(mask),'LineWidth',0.9);

    ylabel('SYNC (V)');

    yyaxis right;

    plot(trAbs(mask)*1e6,F.fullCurrent_mA(mask),'LineWidth',1.0);

    ylabel('Current (mA)');

    hold on;

    xline(0,'--','selected OFF SYNC');

    xline( ...
        F.commandToFallDelay_s*1e6, ...
        ':', ...
        'fast fall onset');

    grid on;

    title(sprintf( ...
        'Trial %d, SYNC to fall = %.3f us', ...
        round(F.trial),1e6*F.commandToFallDelay_s));

    if k==nTrials
        xlabel('Time from selected OFF SYNC (us)');
    end

    hold off;
end

saveas(gcf, ...
    fullfile(RESULTS_FOLDER,"FallSyncTransactionVerification.png"));

%% FIGURE 4: NORMALIZED FALL WITH LOCAL INITIAL CONDITION

figure('Name','Fall normalized local baseline');

hold on;

for k = 1:nTrials
    plot(tSyncCommon*1e6,Ysync(:,k),'LineWidth',0.8);
end

valid = isfinite(meanSync)&isfinite(stdSync);

x = tSyncCommon(valid)*1e6;

fill( ...
    [x;flipud(x)], ...
    [meanSync(valid)+stdSync(valid); ...
     flipud(meanSync(valid)-stdSync(valid))], ...
    [0.5 0.5 0.5], ...
    'FaceAlpha',0.18, ...
    'EdgeColor','none');

plot(tSyncCommon*1e6,meanSync,'k','LineWidth',2);

xline(0,'--','true OFF SYNC');

yline(0.1,':','10%');
yline(0.5,':','50%');
yline(0.9,':','90%');
yline(1,':','final');

grid on;

xlabel('Time from true OFF command (us)');
ylabel('Normalized commanded fall');

title('Fall normalization using current immediately before the true OFF command');

hold off;

saveas(gcf, ...
    fullfile(RESULTS_FOLDER,"FallNormalizedLocalBaseline.png"));

%% FIGURE 5: MEAN SYNC AND ONSET REFERENCED RESPONSE

figure('Name','Fall mean response');

tiledlayout(2,1);

nexttile;

plot(tSyncCommon*1e6,meanSync,'LineWidth',1.7);
hold on;

xline(0,'--','true OFF SYNC');

yline(0.1,':','10%');
yline(0.5,':','50%');
yline(0.9,':','90%');
yline(1,':','final');

grid on;

xlabel('Time from true OFF command (us)');
ylabel('Normalized fall');

title('Mean fall, true command time retained');

hold off;

nexttile;

plot(tOnsetCommon*1e6,meanOnset,'LineWidth',1.7);
hold on;

xline(0,'--','fast fall onset');

yline(0.1,':','10%');
yline(0.5,':','50%');
yline(0.9,':','90%');
yline(1,':','final');

grid on;

xlabel('Time from fast fall onset (us)');
ylabel('Normalized fall');

title('Mean fast fall after removing measured command delay');

hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"FallMeanResponse.png"));

%% SYSTEM IDENTIFICATION SPLIT

nEst = min(N_ESTIMATION_TRIALS,nTrials-1);

if nEst<1
    error('Need at least two trials for estimation and validation.');
end

estIdx = 1:nEst;
valIdx = (nEst+1):nTrials;

fprintf('\n============================================================\n');
fprintf('FALL SYSTEM IDENTIFICATION\n');
fprintf('============================================================\n');

fprintf('Estimation trials : %s\n',mat2str(estIdx));
fprintf('Validation trials : %s\n',mat2str(valIdx));

%% SYNC REFERENCED MODELS

syncMask = tSyncCommon>=0;

tSyncModel = tSyncCommon(syncMask);

ySyncEst = mean(Ysync(syncMask,estIdx),2,'omitnan');
ySyncVal = mean(Ysync(syncMask,valIdx),2,'omitnan');

syncFits = fitSyncReferencedModels( ...
    tSyncModel,ySyncEst,ySyncVal,FIT_P2D);

writetable(syncFits.table, ...
    fullfile(RESULTS_FOLDER,"FallModelFits_SyncReferenced.csv"));

fprintf('\nSYNC-referenced model fits:\n');
disp(syncFits.table);

plotSyncModelValidation( ...
    tSyncModel,ySyncVal,syncFits, ...
    fullfile(RESULTS_FOLDER,"FallModelValidation_SyncReferenced.png"));

%% ONSET REFERENCED MODELS

yOnsetEst = mean(Yonset(:,estIdx),2,'omitnan');
yOnsetVal = mean(Yonset(:,valIdx),2,'omitnan');

onsetFits = fitOnsetReferencedModels( ...
    tOnsetCommon,yOnsetEst,yOnsetVal);

writetable(onsetFits.table, ...
    fullfile(RESULTS_FOLDER,"FallModelFits_OnsetReferenced.csv"));

fprintf('\nONSET-referenced model fits:\n');
disp(onsetFits.table);

plotOnsetModelValidation( ...
    tOnsetCommon,yOnsetVal,onsetFits, ...
    fullfile(RESULTS_FOLDER,"FallModelValidation_OnsetReferenced.png"));

%% PRINT MODELS

fprintf('\n============================================================\n');
fprintf('CANDIDATE FALL MODELS\n');
fprintf('============================================================\n');

fprintf('\nSYNC-referenced P1:\n');
printModel(syncFits.P1,"P1");

fprintf('\nSYNC-referenced P1D:\n');
printModel(syncFits.P1D,"P1D");

fprintf('\nSYNC-referenced P2:\n');
printModel(syncFits.P2,"P2");

fprintf('\nONSET-referenced P1:\n');
printModel(onsetFits.P1,"P1");

fprintf('\nONSET-referenced P2:\n');
printModel(onsetFits.P2,"P2");

fprintf('\nMeasured OFF-command delay:\n');
fprintf('  Mean = %.6g us\n',summary.SyncToFallDelayMean_us);
fprintf('  SD   = %.6g us\n',summary.SyncToFallDelaySD_us);

%% FINAL SUMMARY

fprintf('\n============================================================\n');
fprintf('FINAL FALL SUMMARY\n');
fprintf('============================================================\n');

fprintf('Trials analysed                    : %d\n',nTrials);
fprintf('Mean current at true OFF command  : %.9g mA\n', ...
    summary.CurrentAtCommandMean_mA);

fprintf('Mean commanded fall magnitude     : %.9g mA\n', ...
    summary.StepMean_mA);

fprintf('Fall step CV                      : %.6g %%\n', ...
    summary.StepCV_pct);

fprintf('Mean passive pre-OFF slope        : %.9g mA/us\n', ...
    summary.PreDroopSlopeMean_mA_per_us);

fprintf('Mean true OFF SYNC -> fall onset  : %.9g us\n', ...
    summary.SyncToFallDelayMean_us);

fprintf('Mean 10-90 fall time, SYNC ref    : %.9g us\n', ...
    summary.T1090SyncMean_us);

fprintf('Mean 10-90 fall time, onset ref   : %.9g us\n', ...
    summary.T1090OnsetMean_us);

fprintf('\nResults folder:\n%s\n',RESULTS_FOLDER);

fprintf('\nAnalysis complete.\n');

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function F = analyseFallCausal( ...
    ch1Path,ch2Path,Rload,scaleFactor, ...
    userSyncThreshold,syncActiveLow, ...
    syncMinWidth,syncMaxWidth,maxSyncLead,allowFallback, ...
    onsetMode,derivativeSmoothing,derivativeHold,onsetFraction, ...
    analysisPre,analysisPost, ...
    baselineStart,baselineEnd, ...
    droopStart,droopEnd,tailFraction, ...
    lowFrac,midFrac,highFrac, ...
    settlingBand,minSettlingHold)

    [t1,syncV] = loadScopeCSV(ch1Path);
    [t2,loadV] = loadScopeCSV(ch2Path);

    [t,syncV,loadV,Ts] = alignChannels(t1,syncV,t2,loadV);

    current_mA = 1000*loadV*scaleFactor/Rload;

    % ---------------------------------------------------------------------
    % Step 1: detect fast commanded fall onset from CH2
    % ---------------------------------------------------------------------

    fastFallOnset = detectFastFallOnsetAbsolute( ...
        t,current_mA,Ts, ...
        onsetMode,derivativeSmoothing,derivativeHold,onsetFraction);

    % ---------------------------------------------------------------------
    % Step 2: detect complete SYNC transactions
    % ---------------------------------------------------------------------

    [txnStart,txnEnd,syncThreshold] = detectSyncTransactions( ...
        t,syncV,userSyncThreshold,syncActiveLow, ...
        syncMinWidth,syncMaxWidth);

    if isempty(txnEnd)
        error('No complete valid SYNC transactions were detected.');
    end

    % ---------------------------------------------------------------------
    % Step 3: enforce causality
    % ---------------------------------------------------------------------
    %
    % Command must finish BEFORE the fast fall onset.

    beforeFall = txnEnd < fastFallOnset;

    candidateStart = txnStart(beforeFall);
    candidateEnd = txnEnd(beforeFall);

    if isempty(candidateEnd)
        error('No complete SYNC transaction occurs before the fast fall onset.');
    end

    leadTimes = fastFallOnset-candidateEnd;

    insideWindow = leadTimes<=maxSyncLead;

    if any(insideWindow)

        candidateStart = candidateStart(insideWindow);
        candidateEnd = candidateEnd(insideWindow);

        % Last complete transaction before fall onset.
        [commandTime,selectedIdx] = max(candidateEnd);

    else

        if ~allowFallback
            error(['No complete SYNC transaction ended within %.3f us ' ...
                   'before the fast fall onset.'],1e6*maxSyncLead);
        end

        warning([ ...
            'No SYNC transaction found within the preferred causal window. ' ...
            'Using nearest complete transaction before the fall onset.']);

        [commandTime,selectedIdx] = max(candidateEnd);
    end

    commandToFallDelay = fastFallOnset-commandTime;

    if commandToFallDelay<0
        error('Causality check failed: selected command occurs after response.');
    end

    % ---------------------------------------------------------------------
    % Step 4: align everything to the true OFF command
    % ---------------------------------------------------------------------

    trFull = t-commandTime;

    crop = trFull>=-analysisPre & trFull<=analysisPost;

    tr = trFull(crop);

    current = current_mA(crop);
    syncCrop = syncV(crop);

    % ---------------------------------------------------------------------
    % Step 5: local initial condition immediately before OFF command
    % ---------------------------------------------------------------------

    localMask = tr>=baselineStart & tr<=baselineEnd;

    if nnz(localMask)<5
        error('Local pre-command baseline window contains too few samples.');
    end

    I0 = median(current(localMask),'omitnan');

    postIdx = find(tr>0);

    if numel(postIdx)<10
        error('Too few post-command samples.');
    end

    nTail = max(5,round(tailFraction*numel(postIdx)));

    finalIdx = postIdx(end-nTail+1:end);

    If = median(current(finalIdx),'omitnan');

    stepMag = I0-If;

    if stepMag<=0
        error('Measured commanded fall magnitude is not positive.');
    end

    % ---------------------------------------------------------------------
    % Step 6: quantify passive pre-command droop
    % ---------------------------------------------------------------------

    droopMask = tr>=droopStart & tr<=droopEnd;

    td = tr(droopMask);
    yd = current(droopMask);

    good = isfinite(td)&isfinite(yd);

    td = td(good);
    yd = yd(good);

    if numel(td)>=5

        p = polyfit(td,yd,1);

        droopSlope = p(1);
        droopIntercept = p(2);

        droopDelta = ...
            polyval(p,droopEnd)-polyval(p,droopStart);

    else

        droopSlope = NaN;
        droopIntercept = NaN;
        droopDelta = NaN;
    end

    % ---------------------------------------------------------------------
    % Step 7: normalize from true OFF-command initial condition
    % ---------------------------------------------------------------------

    incrementalSync = I0-current;
    normalizedSync = incrementalSync/stepMag;

    % ---------------------------------------------------------------------
    % Step 8: onset referenced representation
    % ---------------------------------------------------------------------

    onsetRelativeToCommand = fastFallOnset-commandTime;

    onsetMask = tr>=onsetRelativeToCommand;

    trOnset = tr(onsetMask)-onsetRelativeToCommand;

    currentOnset = current(onsetMask);

    IOnset = interp1(tr,current,onsetRelativeToCommand,'linear');

    stepOnset = IOnset-If;

    incrementalOnset = IOnset-currentOnset;

    normalizedOnset = ...
        incrementalOnset/max(eps,stepOnset);

    % ---------------------------------------------------------------------
    % Metrics
    % ---------------------------------------------------------------------

    metricsSync = transitionMetrics( ...
        tr,incrementalSync,stepMag, ...
        lowFrac,midFrac,highFrac, ...
        settlingBand,minSettlingHold,Ts);

    metricsOnset = transitionMetrics( ...
        trOnset,incrementalOnset,stepOnset, ...
        lowFrac,midFrac,highFrac, ...
        settlingBand,minSettlingHold,Ts);

    % ---------------------------------------------------------------------
    % Store
    % ---------------------------------------------------------------------

    F.fullTimeAbsolute_s = t;
    F.fullSyncV = syncV;
    F.fullCurrent_mA = current_mA;

    F.fastFallOnsetAbsolute_s = fastFallOnset;
    F.commandTimeAbsolute_s = commandTime;
    F.commandToFallDelay_s = commandToFallDelay;

    F.candidateTransactionStartAbsolute_s = candidateStart;
    F.candidateTransactionEndAbsolute_s = candidateEnd;
    F.selectedCandidateIndex = selectedIdx;

    F.syncThreshold_V = syncThreshold;

    F.trSync = tr;
    F.current_mA = current;
    F.syncV = syncCrop;

    F.initialAtCommand_mA = I0;
    F.final_mA = If;
    F.step_mA = stepMag;

    F.preDroopSlope_mA_per_s = droopSlope;
    F.preDroopIntercept_mA = droopIntercept;
    F.preDroopDelta_mA = droopDelta;

    F.incrementalSync_mA = incrementalSync;
    F.normalizedSync = normalizedSync;

    F.trOnset = trOnset;
    F.incrementalOnset_mA = incrementalOnset;
    F.normalizedOnset = normalizedOnset;

    F.metricsSync = metricsSync;
    F.metricsOnset = metricsOnset;

    F.Ts = Ts;
end

function onset = detectFastFallOnsetAbsolute( ...
    t,current,Ts,onsetMode,smoothingS,holdS,onsetFraction)

    switch onsetMode

        case "derivative"

            nSmooth = max(3,round(smoothingS/Ts));

            if mod(nSmooth,2)==0
                nSmooth = nSmooth+1;
            end

            ySmooth = movmean(current,nSmooth);

            % Remove slow trend so the fast commanded fall dominates.
            trendWindow = max(nSmooth+2,round(3e-6/Ts));

            yTrend = movmean(ySmooth,trendWindow);

            fastComponent = ySmooth-yTrend;

            dFast = gradient(fastComponent,Ts);

            % Strongest negative slope is near the centre of the fast fall.
            [~,steepestIdx] = min(dFast);

            % Work backwards from the steepest point to find the first
            % sustained departure from the local slow trend.
            preStart = max(1,steepestIdx-round(5e-6/Ts));

            localDerivative = dFast(preStart:steepestIdx);

            baselineCount = max(10,round(0.2*numel(localDerivative)));

            baselineDerivative = localDerivative(1:baselineCount);

            sigma = robustSigma(baselineDerivative);

            threshold = min( ...
                -5*sigma, ...
                0.10*min(localDerivative));

            holdSamples = max(2,ceil(holdS/Ts));

            onsetIdx = [];

            for i = preStart:steepestIdx

                iEnd = min(steepestIdx,i+holdSamples-1);

                if all(dFast(i:iEnd)<=threshold)
                    onsetIdx = i;
                    break;
                end
            end

            if isempty(onsetIdx)
                onsetIdx = steepestIdx;
            end

            onset = t(onsetIdx);

        case "threshold"

            % Estimate high and low levels from robust percentiles.
            highLevel = percentileLocal(current,90);
            lowLevel  = percentileLocal(current,10);

            stepMag = highLevel-lowLevel;

            threshold = highLevel-onsetFraction*stepMag;

            below = current<=threshold;

            idx = find(diff([false;below])==1,1,'first');

            if isempty(idx)
                error('Threshold fall onset could not be detected.');
            end

            onset = t(idx);

        case "interactive"

            figure('Name','Select fast commanded fall onset');

            plot(t*1e6,current,'LineWidth',1.1);

            grid on;

            xlabel('Absolute capture time (us)');
            ylabel('Measured current (mA)');

            title('Click where the FAST commanded fall begins');

            [x,~] = ginput(1);

            onset = x*1e-6;

            close(gcf);

        otherwise

            error('FALL_ONSET_MODE must be derivative, threshold, or interactive.');
    end
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

    widths = t(endsIdx)-t(startsIdx);

    valid = ...
        widths>=minWidth & ...
        widths<=maxWidth & ...
        endsIdx>startsIdx;

    txnStart = t(startsIdx(valid));
    txnEnd = t(endsIdx(valid));
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

    dt = median(diff(t));

    slope = gradient(y,dt);

    postMask = t>=0;

    [maxSlope,idxLocal] = max(slope(postMask));

    postIndices = find(postMask);

    idx = postIndices(idxLocal);

    M.maxSlope_mA_per_s = maxSlope;
    M.maxSlopeTime_s = t(idx);

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

function fits = fitSyncReferencedModels(t,yEst,yVal,fitP2D)

    P1 = fitP1(t,yEst);
    P1D = fitP1D(t,yEst);
    P2 = fitP2(t,yEst);

    P1.validation = fitStats(yVal,P1.yhat);
    P1D.validation = fitStats(yVal,P1D.yhat);
    P2.validation = fitStats(yVal,P2.yhat);

    Model = ["P1";"P1D";"P2"];

    EstimationFit_pct = [ ...
        P1.estimation.fit_pct;
        P1D.estimation.fit_pct;
        P2.estimation.fit_pct];

    EstimationRMSE = [ ...
        P1.estimation.rmse;
        P1D.estimation.rmse;
        P2.estimation.rmse];

    ValidationFit_pct = [ ...
        P1.validation.fit_pct;
        P1D.validation.fit_pct;
        P2.validation.fit_pct];

    ValidationRMSE = [ ...
        P1.validation.rmse;
        P1D.validation.rmse;
        P2.validation.rmse];

    if fitP2D

        P2D = fitP2DModel(t,yEst);
        P2D.validation = fitStats(yVal,P2D.yhat);

        Model(end+1,1) = "P2D";

        EstimationFit_pct(end+1,1) = P2D.estimation.fit_pct;
        EstimationRMSE(end+1,1) = P2D.estimation.rmse;

        ValidationFit_pct(end+1,1) = P2D.validation.fit_pct;
        ValidationRMSE(end+1,1) = P2D.validation.rmse;

        fits.P2D = P2D;
    end

    fits.P1 = P1;
    fits.P1D = P1D;
    fits.P2 = P2;

    fits.table = table( ...
        Model,EstimationFit_pct,EstimationRMSE, ...
        ValidationFit_pct,ValidationRMSE);
end

function fits = fitOnsetReferencedModels(t,yEst,yVal)

    P1 = fitP1(t,yEst);
    P2 = fitP2(t,yEst);

    P1.validation = fitStats(yVal,P1.yhat);
    P2.validation = fitStats(yVal,P2.yhat);

    Model = ["P1";"P2"];

    EstimationFit_pct = [ ...
        P1.estimation.fit_pct;
        P2.estimation.fit_pct];

    EstimationRMSE = [ ...
        P1.estimation.rmse;
        P2.estimation.rmse];

    ValidationFit_pct = [ ...
        P1.validation.fit_pct;
        P2.validation.fit_pct];

    ValidationRMSE = [ ...
        P1.validation.rmse;
        P2.validation.rmse];

    fits.P1 = P1;
    fits.P2 = P2;

    fits.table = table( ...
        Model,EstimationFit_pct,EstimationRMSE, ...
        ValidationFit_pct,ValidationRMSE);
end

function M = fitP1(t,y)

    tau0 = 2e-6;
    K0 = 1;

    q0 = [log(tau0),log(K0)];

    objective = @(q) mean(( ...
        responseP1(t,exp(q(1)),exp(q(2)))-y).^2);

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',5000,'MaxFunEvals',5000));

    M.tau = exp(q(1));
    M.K = exp(q(2));

    M.yhat = responseP1(t,M.tau,M.K);

    M.estimation = fitStats(y,M.yhat);
end

function M = fitP1D(t,y)

    tau0 = 2e-6;
    Td0 = 0.5e-6;
    K0 = 1;

    q0 = [log(tau0),log(Td0),log(K0)];

    objective = @(q) mean(( ...
        responseP1D(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2);

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',8000,'MaxFunEvals',8000));

    M.tau = exp(q(1));
    M.Td = exp(q(2));
    M.K = exp(q(3));

    M.yhat = responseP1D(t,M.tau,M.Td,M.K);

    M.estimation = fitStats(y,M.yhat);
end

function M = fitP2(t,y)

    tau10 = 2.5e-6;
    tau20 = 0.8e-6;
    K0 = 1;

    q0 = [log(tau10),log(tau20),log(K0)];

    objective = @(q) mean(( ...
        responseP2(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2);

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',10000,'MaxFunEvals',10000));

    taus = sort([exp(q(1)),exp(q(2))],'descend');

    M.tau1 = taus(1);
    M.tau2 = taus(2);
    M.K = exp(q(3));

    M.yhat = responseP2(t,M.tau1,M.tau2,M.K);

    M.estimation = fitStats(y,M.yhat);
end

function M = fitP2DModel(t,y)

    tau10 = 2e-6;
    tau20 = 0.7e-6;
    Td0 = 0.4e-6;
    K0 = 1;

    q0 = [log(tau10),log(tau20),log(Td0),log(K0)];

    objective = @(q) mean(( ...
        responseP2D( ...
        t,exp(q(1)),exp(q(2)),exp(q(3)),exp(q(4)))-y).^2);

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',15000,'MaxFunEvals',15000));

    taus = sort([exp(q(1)),exp(q(2))],'descend');

    M.tau1 = taus(1);
    M.tau2 = taus(2);
    M.Td = exp(q(3));
    M.K = exp(q(4));

    M.yhat = responseP2D(t,M.tau1,M.tau2,M.Td,M.K);

    M.estimation = fitStats(y,M.yhat);
end

function y = responseP1(t,tau,K)

    y = K*(1-exp(-max(t,0)/tau));
end

function y = responseP1D(t,tau,Td,K)

    y = zeros(size(t));

    idx = t>=Td;

    tt = t(idx)-Td;

    y(idx) = K*(1-exp(-tt/tau));
end

function y = responseP2(t,tau1,tau2,K)

    tt = max(t,0);

    if abs(tau1-tau2)<1e-4*max(tau1,tau2)

        tau = 0.5*(tau1+tau2);

        y = K*(1-exp(-tt/tau).*(1+tt/tau));

    else

        y = K*( ...
            1 - ...
            (tau1*exp(-tt/tau1)-tau2*exp(-tt/tau2)) ...
            /(tau1-tau2));
    end
end

function y = responseP2D(t,tau1,tau2,Td,K)

    y = zeros(size(t));

    idx = t>=Td;

    tt = t(idx)-Td;

    if abs(tau1-tau2)<1e-4*max(tau1,tau2)

        tau = 0.5*(tau1+tau2);

        y(idx) = K*(1-exp(-tt/tau).*(1+tt/tau));

    else

        y(idx) = K*( ...
            1 - ...
            (tau1*exp(-tt/tau1)-tau2*exp(-tt/tau2)) ...
            /(tau1-tau2));
    end
end

function S = fitStats(y,yhat)

    good = isfinite(y)&isfinite(yhat);

    y = y(good);
    yhat = yhat(good);

    e = y-yhat;

    S.rmse = sqrt(mean(e.^2));

    denom = norm(y-mean(y));

    S.fit_pct = 100*(1-norm(e)/max(eps,denom));
end

function plotSyncModelValidation(t,yVal,fits,filePath)

    figure('Name','Fall sync referenced validation');

    plot(t*1e6,yVal,'LineWidth',1.7);
    hold on;

    plot(t*1e6,fits.P1.yhat,'LineWidth',1.2);
    plot(t*1e6,fits.P1D.yhat,'LineWidth',1.2);
    plot(t*1e6,fits.P2.yhat,'LineWidth',1.2);

    if isfield(fits,'P2D')

        plot(t*1e6,fits.P2D.yhat,'LineWidth',1.2);

        legend( ...
            'Held-out measured mean', ...
            sprintf('P1 %.1f%%',fits.P1.validation.fit_pct), ...
            sprintf('P1D %.1f%%',fits.P1D.validation.fit_pct), ...
            sprintf('P2 %.1f%%',fits.P2.validation.fit_pct), ...
            sprintf('P2D %.1f%%',fits.P2D.validation.fit_pct), ...
            'Location','best');

    else

        legend( ...
            'Held-out measured mean', ...
            sprintf('P1 %.1f%%',fits.P1.validation.fit_pct), ...
            sprintf('P1D %.1f%%',fits.P1D.validation.fit_pct), ...
            sprintf('P2 %.1f%%',fits.P2.validation.fit_pct), ...
            'Location','best');
    end

    grid on;

    xlabel('Time from true OFF command (us)');
    ylabel('Normalized commanded fall');

    title('Fall model validation, causal SYNC reference');

    hold off;

    saveas(gcf,filePath);
end

function plotOnsetModelValidation(t,yVal,fits,filePath)

    figure('Name','Fall onset referenced validation');

    plot(t*1e6,yVal,'LineWidth',1.7);
    hold on;

    plot(t*1e6,fits.P1.yhat,'LineWidth',1.2);
    plot(t*1e6,fits.P2.yhat,'LineWidth',1.2);

    legend( ...
        'Held-out measured mean', ...
        sprintf('P1 %.1f%%',fits.P1.validation.fit_pct), ...
        sprintf('P2 %.1f%%',fits.P2.validation.fit_pct), ...
        'Location','best');

    grid on;

    xlabel('Time from detected fast fall onset (us)');
    ylabel('Normalized commanded fall');

    title('Fall model validation after measured command delay');

    hold off;

    saveas(gcf,filePath);
end

function printModel(M,type)

    switch type

        case "P1"

            fprintf('G(s) = %.9g / (%.9g s + 1)\n', ...
                M.K,M.tau);

        case "P1D"

            fprintf('G(s) = %.9g exp(-%.9g s) / (%.9g s + 1)\n', ...
                M.K,M.Td,M.tau);

        case "P2"

            fprintf(['G(s) = %.9g / ((%.9g s + 1)(%.9g s + 1))\n'], ...
                M.K,M.tau1,M.tau2);
    end

    fprintf('Estimation fit: %.4f %%\n',M.estimation.fit_pct);
    fprintf('Validation fit: %.4f %%\n',M.validation.fit_pct);
end

function yq = interp1Safe(x,y,xq)

    x = x(:);
    y = y(:);

    good = isfinite(x)&isfinite(y);

    x = x(good);
    y = y(good);

    [x,ord] = sort(x);
    y = y(ord);

    [x,idx] = unique(x,'stable');
    y = y(idx);

    yq = nan(size(xq));

    if numel(x)>=2
        yq = interp1(x,y,xq,'linear',NaN);
    end
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
        error('Channel time ranges do not overlap.');
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

function sigma = robustSigma(x)

    x = x(isfinite(x));

    if isempty(x)
        sigma = 0;
        return;
    end

    med = median(x,'omitnan');

    madValue = median(abs(x-med),'omitnan');

    sigma = 1.4826*madValue;

    if ~isfinite(sigma) || sigma<=0
        sigma = std(x,'omitnan');
    end

    if ~isfinite(sigma)
        sigma = 0;
    end
end

function a = parseAttemptNumber(name)

    token = regexp(char(name),'Attempt\s+([0-9]+)','tokens','once');

    if isempty(token)
        a = NaN;
    else
        a = str2double(token{1});
    end
end

function t = parseTrialNumber(name)

    token = regexp(char(name),'trial\s+([0-9]+)', ...
        'tokens','once','ignorecase');

    if isempty(token)
        t = NaN;
    else
        t = str2double(token{1});
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
