%% Repeated10mAAnalysis.m
% OpenXstim repeated 10 mA isolated-step characterisation
%
% Expected folder structure:
%
%   Repeated10mAAnalysis.m
%   Repeated Trials 10mA/
%       Attempt 6 10mA repeated trial 1/
%           Rise/CH1.CSV
%           Rise/CH2.CSV
%           Fall/CH1.CSV
%           Fall/CH2.CSV
%       Attempt 7 10mA repeated trial 2/
%           ...
%       ...
%       Attempt 10 10mA repeated trial 5/
%
% Experiment:
%   Rise: nominal firmware command 0 -> 10 mA
%   Fall: nominal firmware command 10 -> 0 mA
%
% IMPORTANT:
%   The old OpenXstim calibration constant is known to be inaccurate.
%   Therefore:
%
%       nominal command = 10 mA
%
%   does NOT imply:
%
%       measured current step = 10 mA
%
%   This script preserves the measured CH2 amplitude. It reports:
%       1. measured current step through the 1 kOhm resistor
%       2. effective nominal-command gain = measured step / 10 mA
%       3. normalized dynamics, independent of amplitude scaling
%
% CH1 is used only as a timing reference for the DAC/SPI transaction.
% Its voltage magnitude is not used as a plant input.
%
% System identification:
%   The script fits simple normalized continuous-time candidate models:
%
%       P1   : K / (tau*s + 1)
%       P1D  : K*exp(-Td*s) / (tau*s + 1)
%       P2   : K / ((tau1*s + 1)(tau2*s + 1))
%
%   No System Identification Toolbox is required. Fitting uses fminsearch.
%
%   Trials 1-3 are used for estimation and trials 4-5 for validation by
%   default. Change N_ESTIMATION_TRIALS below if desired.
%
% Outputs are written to:
%   Repeated10mA_AnalysisResults/
%
% Main outputs:
%   TrialMetrics.csv
%   RepeatabilitySummary.csv
%   ModelFits_Rise.csv
%   ModelFits_Fall.csv
%   ModelFits_Combined.csv
%   RawAlignedTransitions.png
%   NormalizedOverlays.png
%   MeanRiseVsFall.png
%   RepeatabilityMetrics.png
%   ModelValidation_Rise.png
%   ModelValidation_Fall.png
%   ModelValidation_Combined.png
%
% Thesis interpretation:
%   The normalized model describes the dynamic shape.
%
%   If you deliberately keep the stale firmware command calibration inside
%   the black-box plant definition, multiply the normalized dynamic model by:
%
%       K_eff = mean(measured step magnitude) / 10 mA
%
%   If the firmware is later recalibrated, do not blindly carry this old
%   static gain into the recalibrated plant.
%
% CHANGE LOG (this revision):
%   The per-trial metrics table and the repeatability summary table used
%   to be built by preallocating a struct array and assigning full struct
%   values into indexed elements. That pattern is fragile in MATLAB,
%   since every element of a struct array must share identical fields,
%   and any mismatch throws "Subscripted assignment between dissimilar
%   structures". Both sections now build table rows directly and
%   concatenate them with vertcat, which avoids that entire class of
%   error. No numerical or signal processing logic was changed.

clear;
clc;
close all;

%% USER SETTINGS

% -------------------------------------------------------------------------
% Folder and files
% -------------------------------------------------------------------------
ROOT_FOLDER = getScriptFolder();
REPEATED_FOLDER = fullfile(ROOT_FOLDER, "Repeated Trials 10mA");

CH1_NAME = "CH1.CSV";
CH2_NAME = "CH2.CSV";

RESULTS_FOLDER = fullfile(ROOT_FOLDER, "Repeated10mA_AnalysisResults");

% -------------------------------------------------------------------------
% Electrical setup
% -------------------------------------------------------------------------
LOAD_R_OHM = 1000;

NOMINAL_COMMAND_STEP_MA = 10;

% Keep at 1 unless you later VERIFY a probe/export scaling correction.
% Do not use this merely to force the measured result to equal 10 mA.
CH2_SCALE_FACTOR = 1;

% -------------------------------------------------------------------------
% SYNC detection
% -------------------------------------------------------------------------
% CH1 appears active-low. The useful command timestamp is normally the
% rising edge at the end of the SPI/DAC transaction.
SYNC_EDGE_TYPE = "rising";     % "rising", "falling", "largest"

SYNC_THRESHOLD_V = NaN;        % NaN = automatic robust midpoint

% Candidate SYNC edges are scored according to the output-current change
% immediately after the edge. This is safer than blindly using edge #1.
SYNC_PRE_SCORE_S  = 2e-6;
SYNC_POST_SCORE_S = 8e-6;

% -------------------------------------------------------------------------
% Analysis windows, relative to detected command t = 0
% -------------------------------------------------------------------------
ANALYSIS_PRE_S  = 8e-6;
ANALYSIS_POST_S = 12e-6;

BASELINE_START_S = -6e-6;
BASELINE_END_S   = -0.5e-6;

% Use the final fraction of available post-command samples for plateau.
PLATEAU_TAIL_FRACTION = 0.20;

% -------------------------------------------------------------------------
% Time-domain metrics
% -------------------------------------------------------------------------
ONSET_FRACTION = 0.05;
LOW_FRACTION   = 0.10;
MID_FRACTION   = 0.50;
HIGH_FRACTION  = 0.90;

SETTLING_BAND_FRACTION = 0.02;
MIN_SETTLING_HOLD_S = 0.8e-6;

% -------------------------------------------------------------------------
% Common timebase for overlays and model fitting
% -------------------------------------------------------------------------
COMMON_TS_S = 25e-9;

COMMON_PRE_S  = 4e-6;
COMMON_POST_S = 10e-6;

% -------------------------------------------------------------------------
% Estimation / validation split
% -------------------------------------------------------------------------
% With 5 repeated trials, 3 estimation + 2 validation is a clean split.
N_ESTIMATION_TRIALS = 3;

% -------------------------------------------------------------------------
% Optional second-order-plus-delay model
% -------------------------------------------------------------------------
FIT_P2D = false;

%% FIND REPEATED TRIALS

assert(isfolder(REPEATED_FOLDER), ...
    'Could not find repeated-trials folder:\n%s', REPEATED_FOLDER);

if ~isfolder(RESULTS_FOLDER)
    mkdir(RESULTS_FOLDER);
end

attemptDirs = dir(fullfile(REPEATED_FOLDER, "Attempt *"));
attemptDirs = attemptDirs([attemptDirs.isdir]);

if isempty(attemptDirs)
    error('No Attempt folders found under:\n%s', REPEATED_FOLDER);
end

% Parse trial number and attempt number so ordering is deterministic.
attemptInfo = struct([]);

for k = 1:numel(attemptDirs)

    folderName = string(attemptDirs(k).name);
    fullFolder = fullfile(attemptDirs(k).folder,attemptDirs(k).name);

    attemptNo = parseAttemptNumber(folderName);
    trialNo = parseTrialNumber(folderName);

    if isnan(trialNo)
        trialNo = attemptNo;
    end

    attemptInfo(k).folder = fullFolder;
    attemptInfo(k).name = folderName;
    attemptInfo(k).attempt = attemptNo;
    attemptInfo(k).trial = trialNo;
end

[~,order] = sort([attemptInfo.trial]);
attemptInfo = attemptInfo(order);

fprintf('\n============================================================\n');
fprintf('OPENXSTIM REPEATED 10 mA ANALYSIS\n');
fprintf('============================================================\n');
fprintf('Repeated trials folder:\n%s\n\n',REPEATED_FOLDER);
fprintf('Trial pairs found: %d\n\n',numel(attemptInfo));

%% LOAD AND ANALYSE EACH RISE/FALL PAIR

trials = struct([]);

for k = 1:numel(attemptInfo)

    info = attemptInfo(k);

    riseFolder = fullfile(info.folder,"Rise");
    fallFolder = fullfile(info.folder,"Fall");

    riseCH1 = fullfile(riseFolder,CH1_NAME);
    riseCH2 = fullfile(riseFolder,CH2_NAME);

    fallCH1 = fullfile(fallFolder,CH1_NAME);
    fallCH2 = fullfile(fallFolder,CH2_NAME);

    assert(isfile(riseCH1), 'Missing Rise/CH1.CSV in %s',info.folder);
    assert(isfile(riseCH2), 'Missing Rise/CH2.CSV in %s',info.folder);
    assert(isfile(fallCH1), 'Missing Fall/CH1.CSV in %s',info.folder);
    assert(isfile(fallCH2), 'Missing Fall/CH2.CSV in %s',info.folder);

    fprintf('\n------------------------------------------------------------\n');
    fprintf('Trial %d, Attempt %d\n',round(info.trial),round(info.attempt));
    fprintf('Folder: %s\n',info.folder);

    rise = analyseSingleTransition( ...
        riseCH1,riseCH2,"rise", ...
        LOAD_R_OHM,CH2_SCALE_FACTOR, ...
        SYNC_EDGE_TYPE,SYNC_THRESHOLD_V, ...
        SYNC_PRE_SCORE_S,SYNC_POST_SCORE_S, ...
        ANALYSIS_PRE_S,ANALYSIS_POST_S, ...
        BASELINE_START_S,BASELINE_END_S, ...
        PLATEAU_TAIL_FRACTION, ...
        ONSET_FRACTION,LOW_FRACTION,MID_FRACTION,HIGH_FRACTION, ...
        SETTLING_BAND_FRACTION,MIN_SETTLING_HOLD_S);

    fall = analyseSingleTransition( ...
        fallCH1,fallCH2,"fall", ...
        LOAD_R_OHM,CH2_SCALE_FACTOR, ...
        SYNC_EDGE_TYPE,SYNC_THRESHOLD_V, ...
        SYNC_PRE_SCORE_S,SYNC_POST_SCORE_S, ...
        ANALYSIS_PRE_S,ANALYSIS_POST_S, ...
        BASELINE_START_S,BASELINE_END_S, ...
        PLATEAU_TAIL_FRACTION, ...
        ONSET_FRACTION,LOW_FRACTION,MID_FRACTION,HIGH_FRACTION, ...
        SETTLING_BAND_FRACTION,MIN_SETTLING_HOLD_S);

    trials(k).trial = info.trial;
    trials(k).attempt = info.attempt;
    trials(k).folder = info.folder;
    trials(k).rise = rise;
    trials(k).fall = fall;

    fprintf('  Rise measured step : %.6g mA\n',rise.step_mA);
    fprintf('  Fall measured step : %.6g mA\n',fall.step_mA);
    fprintf('  Rise t10-90        : %.6g us\n',1e6*rise.metrics.t10_90_s);
    fprintf('  Fall t10-90        : %.6g us\n',1e6*fall.metrics.t10_90_s);
end

nTrials = numel(trials);

%% BUILD PER-TRIAL METRICS TABLE
%
% Each call to metricsRow returns a single table row with a fixed set of
% variable names. Collecting the rows in a cell array and calling vertcat
% once at the end avoids struct array field mismatches entirely.

rowTables = cell(2*nTrials,1);
r = 0;

for k = 1:nTrials

    r = r+1;
    rowTables{r} = metricsRow( ...
        trials(k).trial,trials(k).attempt,"Rise",trials(k).rise, ...
        NOMINAL_COMMAND_STEP_MA,trials(k).folder);

    r = r+1;
    rowTables{r} = metricsRow( ...
        trials(k).trial,trials(k).attempt,"Fall",trials(k).fall, ...
        NOMINAL_COMMAND_STEP_MA,trials(k).folder);
end

trialMetrics = vertcat(rowTables{:});

writetable(trialMetrics, ...
    fullfile(RESULTS_FOLDER,"TrialMetrics.csv"));

fprintf('\n============================================================\n');
fprintf('PER-TRIAL METRICS\n');
fprintf('============================================================\n');

disp(trialMetrics(:,{ ...
    'Trial','Attempt','Direction','Initial_mA','Final_mA','Step_mA', ...
    'EffectiveGain','Delay_us','T10_us','T50_us','T90_us', ...
    'T10_90_us','Settling_us','Overshoot_pct','MaxSlope_mA_per_us'}));

%% REPEATABILITY SUMMARY
%
% Same approach as above: build each summary row as a table directly,
% then vertcat once.

summaryTables = cell(2,1);

summaryTables{1} = repeatabilitySummary(trialMetrics,"Rise");
summaryTables{2} = repeatabilitySummary(trialMetrics,"Fall");

repeatability = vertcat(summaryTables{:});

writetable(repeatability, ...
    fullfile(RESULTS_FOLDER,"RepeatabilitySummary.csv"));

fprintf('\n============================================================\n');
fprintf('REPEATABILITY SUMMARY\n');
fprintf('============================================================\n');

disp(repeatability);

% Overall effective stale-calibration gain.
meanStepAll = mean(trialMetrics.Step_mA,'omitnan');
stdStepAll = std(trialMetrics.Step_mA,'omitnan');

effectiveGainAll = meanStepAll/NOMINAL_COMMAND_STEP_MA;

fprintf('\nCombined rise/fall measured step:\n');
fprintf('  Mean step magnitude     : %.9g mA\n',meanStepAll);
fprintf('  Standard deviation      : %.9g mA\n',stdStepAll);
fprintf('  Effective nominal gain  : %.9g mA/mA\n',effectiveGainAll);
fprintf(['  NOTE: this is the gain under the stale firmware calibration and\n' ...
         '  current scope scaling. It is not forced to equal 1.\n']);

%% CREATE COMMON NORMALIZED TIMEBASE

tCommon = (-COMMON_PRE_S:COMMON_TS_S:COMMON_POST_S).';

riseNorm = nan(numel(tCommon),nTrials);
fallNorm = nan(numel(tCommon),nTrials);

riseCurrent = nan(numel(tCommon),nTrials);
fallCurrent = nan(numel(tCommon),nTrials);

for k = 1:nTrials

    riseNorm(:,k) = interp1( ...
        trials(k).rise.tr, ...
        trials(k).rise.normalized, ...
        tCommon,'linear',NaN);

    fallNorm(:,k) = interp1( ...
        trials(k).fall.tr, ...
        trials(k).fall.normalized, ...
        tCommon,'linear',NaN);

    riseCurrent(:,k) = interp1( ...
        trials(k).rise.tr, ...
        trials(k).rise.incremental_mA, ...
        tCommon,'linear',NaN);

    fallCurrent(:,k) = interp1( ...
        trials(k).fall.tr, ...
        trials(k).fall.incremental_mA, ...
        tCommon,'linear',NaN);
end

riseMean = mean(riseNorm,2,'omitnan');
riseStd  = std(riseNorm,0,2,'omitnan');

fallMean = mean(fallNorm,2,'omitnan');
fallStd  = std(fallNorm,0,2,'omitnan');

%% FIGURE 1: RAW / INCREMENTAL ALIGNED TRANSITIONS

figure('Name','Repeated 10 mA aligned transitions');

tl = tiledlayout(2,1);
title(tl,'Repeated nominal 10 mA isolated transitions');

ax1 = nexttile;
hold(ax1,'on');

for k = 1:nTrials
    plot(ax1,tCommon*1e6,riseCurrent(:,k),'LineWidth',0.9);
end

xline(ax1,0,'--','SYNC command');
grid(ax1,'on');
xlabel(ax1,'Time from command (us)');
ylabel(ax1,'Incremental measured current (mA)');
title(ax1,'Rise trials, 0 to nominal 10 mA');
hold(ax1,'off');

ax2 = nexttile;
hold(ax2,'on');

for k = 1:nTrials
    plot(ax2,tCommon*1e6,fallCurrent(:,k),'LineWidth',0.9);
end

xline(ax2,0,'--','SYNC command');
grid(ax2,'on');
xlabel(ax2,'Time from command (us)');
ylabel(ax2,'Sign-corrected incremental current (mA)');
title(ax2,'Fall trials, nominal 10 mA to 0');
hold(ax2,'off');

saveas(gcf,fullfile(RESULTS_FOLDER,"RawAlignedTransitions.png"));

%% FIGURE 2: NORMALIZED OVERLAYS + MEAN +/- SD

figure('Name','Repeated normalized transitions');

tl = tiledlayout(2,1);
title(tl,'Normalized repeated 10 mA dynamics');

ax1 = nexttile;
plotNormalizedEnvelope( ...
    ax1,tCommon,riseNorm,riseMean,riseStd, ...
    'Rise normalized responses');

ax2 = nexttile;
plotNormalizedEnvelope( ...
    ax2,tCommon,fallNorm,fallMean,fallStd, ...
    'Fall normalized responses, sign corrected');

saveas(gcf,fullfile(RESULTS_FOLDER,"NormalizedOverlays.png"));

%% FIGURE 3: MEAN RISE VS MEAN FALL

good = isfinite(riseMean)&isfinite(fallMean);

symmetryRMSE = sqrt(mean((riseMean(good)-fallMean(good)).^2));
symmetryMaxDifference = max(abs(riseMean(good)-fallMean(good)));

figure('Name','Mean rise versus fall');

plot(tCommon*1e6,riseMean,'LineWidth',1.6);
hold on;
plot(tCommon*1e6,fallMean,'LineWidth',1.6);

xline(0,'--','SYNC command');
yline(0.1,':','10%');
yline(0.5,':','50%');
yline(0.9,':','90%');
yline(1,':','final');

grid on;
xlabel('Time from command (us)');
ylabel('Normalized response');

title(sprintf( ...
    'Mean rise vs fall, normalized RMSE = %.4f',symmetryRMSE));

legend('Mean rise','Mean fall, sign corrected','Location','best');
hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"MeanRiseVsFall.png"));

fprintf('\nRise/fall dynamic symmetry:\n');
fprintf('  RMSE normalized difference : %.9g\n',symmetryRMSE);
fprintf('  Max normalized difference  : %.9g\n',symmetryMaxDifference);

%% FIGURE 4: REPEATABILITY METRICS

figure('Name','Repeated trial metrics');

tl = tiledlayout(2,2);
title(tl,'Repeated 10 mA trial repeatability');

riseMask = trialMetrics.Direction=="Rise";
fallMask = trialMetrics.Direction=="Fall";

nexttile;
plot(trialMetrics.Trial(riseMask),trialMetrics.Step_mA(riseMask),'o-');
hold on;
plot(trialMetrics.Trial(fallMask),trialMetrics.Step_mA(fallMask),'s-');
grid on;
xlabel('Repeated trial');
ylabel('Measured step magnitude (mA)');
title('Measured output step');
legend('Rise','Fall','Location','best');
hold off;

nexttile;
plot(trialMetrics.Trial(riseMask),trialMetrics.Delay_us(riseMask),'o-');
hold on;
plot(trialMetrics.Trial(fallMask),trialMetrics.Delay_us(fallMask),'s-');
grid on;
xlabel('Repeated trial');
ylabel('SYNC-to-5% delay (us)');
title('Apparent command delay');
legend('Rise','Fall','Location','best');
hold off;

nexttile;
plot(trialMetrics.Trial(riseMask),trialMetrics.T10_90_us(riseMask),'o-');
hold on;
plot(trialMetrics.Trial(fallMask),trialMetrics.T10_90_us(fallMask),'s-');
grid on;
xlabel('Repeated trial');
ylabel('10-90% time (us)');
title('Transition time');
legend('Rise','Fall','Location','best');
hold off;

nexttile;
plot(trialMetrics.Trial(riseMask),trialMetrics.Settling_us(riseMask),'o-');
hold on;
plot(trialMetrics.Trial(fallMask),trialMetrics.Settling_us(fallMask),'s-');
grid on;
xlabel('Repeated trial');
ylabel('2% settling time (us)');
title('Settling time');
legend('Rise','Fall','Location','best');
hold off;

saveas(gcf,fullfile(RESULTS_FOLDER,"RepeatabilityMetrics.png"));

%% SYSTEM IDENTIFICATION: ESTIMATION / VALIDATION SPLIT

nEst = min(N_ESTIMATION_TRIALS,nTrials-1);

if nEst < 1
    error('Need at least two repeated trials for estimation/validation.');
end

estIdx = 1:nEst;
valIdx = (nEst+1):nTrials;

fprintf('\n============================================================\n');
fprintf('LOW-ORDER SYSTEM IDENTIFICATION\n');
fprintf('============================================================\n');
fprintf('Estimation trials : %s\n',mat2str(estIdx));
fprintf('Validation trials : %s\n',mat2str(valIdx));

% Fit only from t >= 0 through the selected post window.
modelMask = tCommon>=0 & tCommon<=COMMON_POST_S;

tModel = tCommon(modelMask);

riseEst = mean(riseNorm(modelMask,estIdx),2,'omitnan');
riseVal = mean(riseNorm(modelMask,valIdx),2,'omitnan');

fallEst = mean(fallNorm(modelMask,estIdx),2,'omitnan');
fallVal = mean(fallNorm(modelMask,valIdx),2,'omitnan');

combinedEst = mean( ...
    [riseNorm(modelMask,estIdx),fallNorm(modelMask,estIdx)], ...
    2,'omitnan');

combinedVal = mean( ...
    [riseNorm(modelMask,valIdx),fallNorm(modelMask,valIdx)], ...
    2,'omitnan');

riseFits = fitAndValidateModels(tModel,riseEst,riseVal,FIT_P2D);
fallFits = fitAndValidateModels(tModel,fallEst,fallVal,FIT_P2D);
combinedFits = fitAndValidateModels(tModel,combinedEst,combinedVal,FIT_P2D);

writetable(riseFits.table, ...
    fullfile(RESULTS_FOLDER,"ModelFits_Rise.csv"));

writetable(fallFits.table, ...
    fullfile(RESULTS_FOLDER,"ModelFits_Fall.csv"));

writetable(combinedFits.table, ...
    fullfile(RESULTS_FOLDER,"ModelFits_Combined.csv"));

fprintf('\nRise models:\n');
disp(riseFits.table);

fprintf('\nFall models:\n');
disp(fallFits.table);

fprintf('\nCombined rise/fall models:\n');
disp(combinedFits.table);

%% MODEL VALIDATION FIGURES

plotModelValidation( ...
    tModel,riseVal,riseFits, ...
    'Rise model validation', ...
    fullfile(RESULTS_FOLDER,"ModelValidation_Rise.png"));

plotModelValidation( ...
    tModel,fallVal,fallFits, ...
    'Fall model validation', ...
    fullfile(RESULTS_FOLDER,"ModelValidation_Fall.png"));

plotModelValidation( ...
    tModel,combinedVal,combinedFits, ...
    'Combined rise/fall model validation', ...
    fullfile(RESULTS_FOLDER,"ModelValidation_Combined.png"));

%% PRINT TRANSFER FUNCTIONS

fprintf('\n============================================================\n');
fprintf('CANDIDATE NORMALIZED TRANSFER FUNCTIONS\n');
fprintf('============================================================\n');

fprintf('\nCOMBINED P1:\n');
printModelEquation(combinedFits.P1,"P1");

fprintf('\nCOMBINED P1D:\n');
printModelEquation(combinedFits.P1D,"P1D");

fprintf('\nCOMBINED P2:\n');
printModelEquation(combinedFits.P2,"P2");

if FIT_P2D
    fprintf('\nCOMBINED P2D:\n');
    printModelEquation(combinedFits.P2D,"P2D");
end

fprintf('\nStatic gain under current nominal firmware calibration:\n');
fprintf('  K_eff = %.9g measured mA / nominal mA\n',effectiveGainAll);

fprintf(['\nIf you want a complete local black-box model from nominal firmware\n' ...
         'current command to measured current, multiply the selected\n' ...
         'normalized dynamic model by K_eff.\n\n']);

fprintf(['If you later fix the firmware calibration, re-estimate the static gain\n' ...
         'or separate the calibration map from the normalized dynamics.\n']);

%% MODEL SELECTION GUIDANCE

fprintf('\n============================================================\n');
fprintf('MODEL SELECTION GUIDANCE\n');
fprintf('============================================================\n');

fprintf(['Use the validation columns, not only estimation fit.\n' ...
         'Prefer the simplest model that captures the held-out trials.\n' ...
         'A small validation improvement from P1D to P2 is not by itself\n' ...
         'enough reason to use P2.\n\n']);

fprintf(['Because the measured responses are visibly S-shaped, P2 may be a\n' ...
         'reasonable structural candidate. The validation data will decide\n' ...
         'whether that extra pole is actually justified.\n']);

%% FINAL SUMMARY

fprintf('\n============================================================\n');
fprintf('FINAL REPEATED-TRIAL SUMMARY\n');
fprintf('============================================================\n');

fprintf('Trials analysed                    : %d\n',nTrials);
fprintf('Nominal firmware step             : %.6g mA\n',NOMINAL_COMMAND_STEP_MA);
fprintf('Mean measured step                : %.9g mA\n',meanStepAll);
fprintf('Measured-step SD                  : %.9g mA\n',stdStepAll);
fprintf('Effective nominal-command gain    : %.9g\n',effectiveGainAll);

fprintf('Mean rise/fall normalized RMSE    : %.9g\n',symmetryRMSE);
fprintf('Maximum rise/fall normalized diff : %.9g\n',symmetryMaxDifference);

fprintf('\nResults folder:\n%s\n',RESULTS_FOLDER);

fprintf('\nAnalysis complete.\n');

%% =======================================================================
% LOCAL FUNCTIONS
% ========================================================================

function result = analyseSingleTransition( ...
    ch1Path,ch2Path,directionText, ...
    Rload,scaleFactor, ...
    syncEdgeType,userSyncThreshold, ...
    preScoreS,postScoreS, ...
    analysisPreS,analysisPostS, ...
    baselineStartS,baselineEndS, ...
    plateauTailFraction, ...
    onsetFrac,lowFrac,midFrac,highFrac, ...
    settlingBand,minSettlingHoldS)

    [t1,syncV] = loadScopeCSV(ch1Path);
    [t2,loadV] = loadScopeCSV(ch2Path);

    [t,syncV,loadV,Ts] = alignChannels(t1,syncV,t2,loadV);

    t = t-t(1);

    current_mA = 1000*loadV*scaleFactor/Rload;

    [commandTime,syncThreshold,candidateEdges] = ...
        chooseCommandEdge( ...
        t,syncV,current_mA, ...
        syncEdgeType,userSyncThreshold, ...
        preScoreS,postScoreS);

    trFull = t-commandTime;

    crop = trFull>=-analysisPreS & trFull<=analysisPostS;

    tr = trFull(crop);
    syncCrop = syncV(crop);
    currentCrop = current_mA(crop);

    baselineMask = tr>=baselineStartS & tr<=baselineEndS;

    if nnz(baselineMask)<5
        error('Too few baseline samples in %s',ch2Path);
    end

    initial = median(currentCrop(baselineMask),'omitnan');

    postIdx = find(tr>0);

    if numel(postIdx)<10
        error('Too few post-command samples in %s',ch2Path);
    end

    nPlateau = max(5,round(plateauTailFraction*numel(postIdx)));

    plateauIdx = postIdx(end-nPlateau+1:end);

    final = median(currentCrop(plateauIdx),'omitnan');

    if directionText=="rise"
        incremental = currentCrop-initial;
        stepMag = final-initial;
    else
        incremental = initial-currentCrop;
        stepMag = initial-final;
    end

    if stepMag<=0
        error(['Expected positive incremental step magnitude after sign ' ...
               'correction, but got %.6g mA in %s'],stepMag,ch2Path);
    end

    normalized = incremental/stepMag;

    metrics = calculateTransitionMetrics( ...
        tr,incremental,stepMag, ...
        onsetFrac,lowFrac,midFrac,highFrac, ...
        settlingBand,minSettlingHoldS,Ts);

    result.tr = tr;
    result.syncV = syncCrop;
    result.current_mA = currentCrop;
    result.incremental_mA = incremental;
    result.normalized = normalized;

    result.initial_mA = initial;
    result.final_mA = final;
    result.step_mA = stepMag;

    result.commandTime_s = commandTime;
    result.syncThreshold_V = syncThreshold;
    result.candidateEdges_s = candidateEdges;

    result.metrics = metrics;
    result.Ts = Ts;
end

function [commandTime,threshold,edges] = chooseCommandEdge( ...
    t,syncV,current_mA,edgeType,userThreshold,preScoreS,postScoreS)

    lo = percentileLocal(syncV,5);
    hi = percentileLocal(syncV,95);

    if isnan(userThreshold)
        threshold = 0.5*(lo+hi);
    else
        threshold = userThreshold;
    end

    logic = syncV>threshold;

    switch edgeType
        case "rising"
            idx = find(diff(logic)==1)+1;

        case "falling"
            idx = find(diff(logic)==-1)+1;

        case "largest"
            [~,i] = max(abs(diff(syncV)));
            idx = i+1;

        otherwise
            error('SYNC_EDGE_TYPE must be rising, falling, or largest.');
    end

    if isempty(idx)
        error('No candidate SYNC edges detected.');
    end

    edges = t(idx);

    scores = -inf(size(edges));

    for k = 1:numel(edges)

        te = edges(k);

        preMask = t>=te-preScoreS & t<te-0.2e-6;
        postMask = t>=te+1e-6 & t<=te+postScoreS;

        if nnz(preMask)<3 || nnz(postMask)<3
            continue;
        end

        y0 = median(current_mA(preMask),'omitnan');

        postVals = current_mA(postMask);
        nTail = max(3,round(0.25*numel(postVals)));

        y1 = median(postVals(end-nTail+1:end),'omitnan');

        scores(k) = abs(y1-y0);
    end

    [bestScore,best] = max(scores);

    if ~isfinite(bestScore)
        error('SYNC edges found, but none had enough surrounding output data.');
    end

    commandTime = edges(best);
end

function metrics = calculateTransitionMetrics( ...
    t,y,stepMag,onsetFrac,lowFrac,midFrac,highFrac, ...
    settlingBand,minSettlingHoldS,Ts)

    metrics.delay_s = crossingTime(t,y,onsetFrac*stepMag);
    metrics.t10_s   = crossingTime(t,y,lowFrac*stepMag);
    metrics.t50_s   = crossingTime(t,y,midFrac*stepMag);
    metrics.t90_s   = crossingTime(t,y,highFrac*stepMag);

    metrics.t10_90_s = metrics.t90_s-metrics.t10_s;

    [peak,peakIdx] = max(y);

    metrics.peak_mA = peak;
    metrics.peakTime_s = t(peakIdx);

    metrics.overshoot_pct = ...
        max(0,100*(peak-stepMag)/max(eps,stepMag));

    % Maximum positive slope after command.
    dt = median(diff(t));
    dy = gradient(y,dt);

    postMask = t>=0;

    [maxSlope,localIdx] = max(dy(postMask));

    postIndices = find(postMask);
    slopeIdx = postIndices(localIdx);

    metrics.maxSlope_mA_per_s = maxSlope;
    metrics.maxSlopeTime_s = t(slopeIdx);

    % Settling into +/- band around measured final incremental step.
    band = settlingBand*stepMag;

    err = abs(y-stepMag);

    holdSamples = max(3,ceil(minSettlingHoldS/Ts));

    metrics.settling_s = NaN;

    startIdx = find(t>=max(0,metrics.t90_s),1,'first');

    if isempty(startIdx)
        return;
    end

    for k = startIdx:(numel(y)-holdSamples+1)

        if all(err(k:k+holdSamples-1)<=band)
            metrics.settling_s = t(k);
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

function row = metricsRow( ...
    trial,attempt,direction,result,nominalStep,folder)
% Returns a single-row table for one rise or fall transition. Building a
% table directly here, instead of a struct destined for struct2table,
% means the caller only ever has to vertcat tables with matching
% variable names, which MATLAB validates cleanly and cannot silently
% desync the way indexed struct assignment can.

    m = result.metrics;

    row = table( ...
        trial, ...
        attempt, ...
        direction, ...
        result.initial_mA, ...
        result.final_mA, ...
        result.step_mA, ...
        result.step_mA/nominalStep, ...
        1e6*m.delay_s, ...
        1e6*m.t10_s, ...
        1e6*m.t50_s, ...
        1e6*m.t90_s, ...
        1e6*m.t10_90_s, ...
        1e6*m.settling_s, ...
        m.overshoot_pct, ...
        m.peak_mA, ...
        1e6*m.peakTime_s, ...
        1e-6*m.maxSlope_mA_per_s, ...
        1e6*m.maxSlopeTime_s, ...
        1e9*result.Ts, ...
        result.commandTime_s, ...
        string(folder), ...
        'VariableNames',{ ...
            'Trial','Attempt','Direction','Initial_mA','Final_mA', ...
            'Step_mA','EffectiveGain','Delay_us','T10_us','T50_us', ...
            'T90_us','T10_90_us','Settling_us','Overshoot_pct', ...
            'PeakIncremental_mA','PeakTime_us','MaxSlope_mA_per_us', ...
            'MaxSlopeTime_us','ScopeSamplePeriod_ns','CommandTime_s', ...
            'Folder'});
end

function out = repeatabilitySummary(T,direction)
% Returns a single-row table summarising repeatability for one direction.

    mask = T.Direction==direction;

    S = T(mask,:);

    N = height(S);

    StepMean_mA = mean(S.Step_mA,'omitnan');
    StepSD_mA = std(S.Step_mA,'omitnan');
    StepCV_pct = 100*StepSD_mA/max(eps,abs(StepMean_mA));

    GainMean = mean(S.EffectiveGain,'omitnan');
    GainSD = std(S.EffectiveGain,'omitnan');

    DelayMean_us = mean(S.Delay_us,'omitnan');
    DelaySD_us = std(S.Delay_us,'omitnan');

    T1090Mean_us = mean(S.T10_90_us,'omitnan');
    T1090SD_us = std(S.T10_90_us,'omitnan');

    SettlingMean_us = mean(S.Settling_us,'omitnan');
    SettlingSD_us = std(S.Settling_us,'omitnan');

    OvershootMean_pct = mean(S.Overshoot_pct,'omitnan');
    OvershootSD_pct = std(S.Overshoot_pct,'omitnan');

    MaxSlopeMean_mA_per_us = mean(S.MaxSlope_mA_per_us,'omitnan');
    MaxSlopeSD_mA_per_us = std(S.MaxSlope_mA_per_us,'omitnan');

    out = table( ...
        direction,N,StepMean_mA,StepSD_mA,StepCV_pct, ...
        GainMean,GainSD,DelayMean_us,DelaySD_us, ...
        T1090Mean_us,T1090SD_us,SettlingMean_us,SettlingSD_us, ...
        OvershootMean_pct,OvershootSD_pct, ...
        MaxSlopeMean_mA_per_us,MaxSlopeSD_mA_per_us, ...
        'VariableNames',{ ...
            'Direction','N','StepMean_mA','StepSD_mA','StepCV_pct', ...
            'GainMean','GainSD','DelayMean_us','DelaySD_us', ...
            'T1090Mean_us','T1090SD_us','SettlingMean_us','SettlingSD_us', ...
            'OvershootMean_pct','OvershootSD_pct', ...
            'MaxSlopeMean_mA_per_us','MaxSlopeSD_mA_per_us'});
end

function plotNormalizedEnvelope(ax,t,Y,mu,sigma,titleText)

    hold(ax,'on');

    for k = 1:size(Y,2)
        plot(ax,t*1e6,Y(:,k),'LineWidth',0.8);
    end

    valid = isfinite(mu)&isfinite(sigma);

    x = t(valid)*1e6;
    upper = mu(valid)+sigma(valid);
    lower = mu(valid)-sigma(valid);

    fill(ax, ...
        [x;flipud(x)], ...
        [upper;flipud(lower)], ...
        [0.5 0.5 0.5], ...
        'FaceAlpha',0.18, ...
        'EdgeColor','none');

    plot(ax,t*1e6,mu,'k','LineWidth',2);

    xline(ax,0,'--','SYNC command');
    yline(ax,0.1,':','10%');
    yline(ax,0.5,':','50%');
    yline(ax,0.9,':','90%');
    yline(ax,1,':','final');

    grid(ax,'on');

    xlabel(ax,'Time from command (us)');
    ylabel(ax,'Normalized response');

    title(ax,titleText);

    hold(ax,'off');
end

function fits = fitAndValidateModels(t,yEst,yVal,fitP2D)

    P1 = fitP1(t,yEst);
    P1D = fitP1D(t,yEst);
    P2 = fitP2(t,yEst);

    P1.validation = modelFitStats(yVal,P1.yhat);
    P1D.validation = modelFitStats(yVal,P1D.yhat);
    P2.validation = modelFitStats(yVal,P2.yhat);

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
        P2D.validation = modelFitStats(yVal,P2D.yhat);

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
        Model, ...
        EstimationFit_pct, ...
        EstimationRMSE, ...
        ValidationFit_pct, ...
        ValidationRMSE);
end

function M = fitP1(t,y)

    tau0 = 2e-6;
    K0 = 1;

    q0 = [log(tau0),log(K0)];

    objective = @(q) mean(( ...
        responseP1(t,exp(q(1)),exp(q(2)))-y).^2);

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxFunEvals',5000,'MaxIter',5000));

    M.tau = exp(q(1));
    M.K = exp(q(2));

    M.yhat = responseP1(t,M.tau,M.K);

    M.estimation = modelFitStats(y,M.yhat);
end

function M = fitP1D(t,y)

    tau0 = 2e-6;
    Td0 = 0.7e-6;
    K0 = 1;

    q0 = [log(tau0),log(Td0),log(K0)];

    objective = @(q) mean(( ...
        responseP1D(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2);

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxFunEvals',8000,'MaxIter',8000));

    M.tau = exp(q(1));
    M.Td = exp(q(2));
    M.K = exp(q(3));

    M.yhat = responseP1D(t,M.tau,M.Td,M.K);

    M.estimation = modelFitStats(y,M.yhat);
end

function M = fitP2(t,y)

    tau10 = 2.5e-6;
    tau20 = 0.8e-6;
    K0 = 1;

    q0 = [log(tau10),log(tau20),log(K0)];

    objective = @(q) mean(( ...
        responseP2(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2);

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxFunEvals',10000,'MaxIter',10000));

    taus = sort([exp(q(1)),exp(q(2))],'descend');

    M.tau1 = taus(1);
    M.tau2 = taus(2);
    M.K = exp(q(3));

    M.yhat = responseP2(t,M.tau1,M.tau2,M.K);

    M.estimation = modelFitStats(y,M.yhat);
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
        optimset('Display','off','MaxFunEvals',15000,'MaxIter',15000));

    taus = sort([exp(q(1)),exp(q(2))],'descend');

    M.tau1 = taus(1);
    M.tau2 = taus(2);
    M.Td = exp(q(3));
    M.K = exp(q(4));

    M.yhat = responseP2D(t,M.tau1,M.tau2,M.Td,M.K);

    M.estimation = modelFitStats(y,M.yhat);
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

    if abs(tau1-tau2) < 1e-4*max(tau1,tau2)

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

    if abs(tau1-tau2) < 1e-4*max(tau1,tau2)

        tau = 0.5*(tau1+tau2);

        y(idx) = K*(1-exp(-tt/tau).*(1+tt/tau));

    else

        y(idx) = K*( ...
            1 - ...
            (tau1*exp(-tt/tau1)-tau2*exp(-tt/tau2)) ...
            /(tau1-tau2));
    end
end

function S = modelFitStats(y,yhat)

    good = isfinite(y)&isfinite(yhat);

    y = y(good);
    yhat = yhat(good);

    e = y-yhat;

    S.rmse = sqrt(mean(e.^2));

    denom = norm(y-mean(y));

    S.fit_pct = 100*(1-norm(e)/max(eps,denom));
end

function plotModelValidation(t,yVal,fits,titleText,filePath)

    figure('Name',titleText);

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
    xlabel('Time from command (us)');
    ylabel('Normalized response');
    title(titleText);

    hold off;

    saveas(gcf,filePath);
end

function printModelEquation(M,type)

    switch type

        case "P1"

            fprintf('G(s) = %.9g / (%.9g s + 1)\n', ...
                M.K,M.tau);

            fprintf('Estimation fit: %.4f %%\n', ...
                M.estimation.fit_pct);

            fprintf('Validation fit: %.4f %%\n', ...
                M.validation.fit_pct);

        case "P1D"

            fprintf('G(s) = %.9g exp(-%.9g s) / (%.9g s + 1)\n', ...
                M.K,M.Td,M.tau);

            fprintf('Estimation fit: %.4f %%\n', ...
                M.estimation.fit_pct);

            fprintf('Validation fit: %.4f %%\n', ...
                M.validation.fit_pct);

        case "P2"

            fprintf(['G(s) = %.9g / ((%.9g s + 1)(%.9g s + 1))\n'], ...
                M.K,M.tau1,M.tau2);

            fprintf('Estimation fit: %.4f %%\n', ...
                M.estimation.fit_pct);

            fprintf('Validation fit: %.4f %%\n', ...
                M.validation.fit_pct);

        case "P2D"

            fprintf(['G(s) = %.9g exp(-%.9g s) / ' ...
                     '((%.9g s + 1)(%.9g s + 1))\n'], ...
                M.K,M.Td,M.tau1,M.tau2);

            fprintf('Estimation fit: %.4f %%\n', ...
                M.estimation.fit_pct);

            fprintf('Validation fit: %.4f %%\n', ...
                M.validation.fit_pct);
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
        error('Could not find a numeric data block in:\n%s',path);
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

        monotonicity = max(mean(dx>0),mean(dx<0));

        nz = abs(dx)>eps(max(abs(x)));

        if ~any(nz)
            continue;
        end

        dd = abs(dx(nz));

        regularity = 1/(1+std(dd)/max(eps,mean(dd)));

        score(k) = 3*monotonicity+regularity;
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

function a = parseAttemptNumber(name)

    tok = regexp(char(name),'Attempt\s+([0-9]+)','tokens','once');

    if isempty(tok)
        a = NaN;
    else
        a = str2double(tok{1});
    end
end

function t = parseTrialNumber(name)

    tok = regexp(char(name),'trial\s+([0-9]+)','tokens','once','ignorecase');

    if isempty(tok)
        t = NaN;
    else
        t = str2double(tok{1});
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