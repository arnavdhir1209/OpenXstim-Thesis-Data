%% Stage4_NormalizePassivePhases.m
% OPENXSTIM PIPELINE STAGE 4
% PASSIVE-PHASE NORMALIZATION + COMPLIANCE CHARACTERIZATION
%
% Required pipeline:
%   Stage0_IndexAndPlot.m
%   Stage1_IdentifyPacketsAndDecodeCommands.m
%   Stage2_ClassifyCurrentResponses.m
%   Stage3_NormalizeFastTransitions.m
%   Stage4_NormalizePassivePhases.m
%   Stage5_ModelOpenXstimPlant.m
%
% Supporting analyses such as Stage2A, Stage2B and Stage3A are optional
% analyses. Stage 4 can use Stage3A metadata when available, but it does
% NOT discard compliance-affected phases.
%
% Stage 4 characterizes the SLOW within-phase behavior between fast edges.
% It does not fit a final mathematical plant model.
%
% For every active phase:
%   1. Use the Stage 2 response/surrogate timing to define the phase.
%   2. Exclude a short guard after the starting fast transition.
%   3. Exclude a short guard before the next transition.
%   4. Sign-correct negative phases so both polarities are positive-going.
%   5. Smooth only for the slow/passive analysis.
%   6. Normalize each individual phase so D(0) = 1 exactly.
%   7. Resample onto a 5 us modelling grid.
%   8. Extract time-domain and charge-domain loss metrics.
%   9. Retain all phases, including strong compliance collapse.
%
% Required helper files in Matlab Analysis:
%   OpenXstimPassive_ProcessCapture.m
%   OpenXstimPassive_BuildSummaries.m
%   OpenXstimPassive_PlotDiagnostics.m

clear;
clc;
close all;

%% ========================================================================
% USER SETTINGS
% ========================================================================

cfg = struct();

cfg.DATA_ROOT = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.

cfg.ANALYSIS_FOLDER = ...
    fullfile(cfg.DATA_ROOT,"Matlab Analysis");

cfg.STAGE2_MASTER_FILE = ...
    fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage2_CurrentResponseClassification", ...
    "Stage2MasterResults.mat");

cfg.STAGE3A_AUDIT_FILE = ...
    fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage3A_FastTransitionOutlierAnalysis", ...
    "Stage3A_FastTransitionAudit.mat");

cfg.OUTPUT_FOLDER = ...
    fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage4_PassivePhaseNormalization");

cfg.OVERWRITE_EXISTING_OUTPUT = true;

% -------------------------------------------------------------------------
% HARDWARE / DATA
% -------------------------------------------------------------------------

cfg.OUTPUT_CHANNEL = 3;
cfg.R_LOAD_OHM = 1000;

% Known series blocking capacitor C15.
cfg.BLOCKING_CAP_UF = 0.1;

% -------------------------------------------------------------------------
% PHASE EXTRACTION
% -------------------------------------------------------------------------

% Keep the fast edge structurally separate from the passive dynamics.
cfg.START_GUARD_US = 20;
cfg.END_GUARD_US = 20;

% Slow-waveform smoothing only. This is far slower than the ~5 us fast edge.
cfg.SLOW_SMOOTH_US = 4.0;

% Exact individual-phase normalization:
% D(0) is the FIRST finite smoothed sample after the start guard.
cfg.MIN_REFERENCE_CURRENT_mA = 0.20;

% -------------------------------------------------------------------------
% MODEL-READY GRID
% -------------------------------------------------------------------------

cfg.MODEL_DT_US = 5.0;

% Most repeating phases are around 1 ms. The first phase can be longer
% because 0 -> +I has a different execution delay. 1600 us safely preserves
% that first-phase behavior while shorter phases simply contain NaN later.
cfg.MODEL_MAX_US = 1600;

% -------------------------------------------------------------------------
% DESCRIPTIVE METRICS
% -------------------------------------------------------------------------

cfg.EARLY_SLOPE_START_US = 0;
cfg.EARLY_SLOPE_END_US = 200;

cfg.LATE_SLOPE_WINDOW_US = 200;

% Smooth derivative before reporting the strongest collapse rate.
cfg.COLLAPSE_RATE_SMOOTH_US = 20;

% Transparent descriptive thresholds. These do not fit a model.
cfg.THRESHOLD_LEVELS = [0.90 0.75 0.50 0.25];

% Simple descriptive regime classification.
cfg.DROOP_ONLY_MIN_D = 0.75;
cfg.STRONG_COLLAPSE_MAX_D = 0.25;

% -------------------------------------------------------------------------
% FIGURES
% -------------------------------------------------------------------------

cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;

cfg.MAX_TRACES_PER_CURRENT = 50;

%% ========================================================================
% CHECK FILES
% ========================================================================

helpers = [ ...
    "OpenXstimPassive_ProcessCapture.m", ...
    "OpenXstimPassive_BuildSummaries.m", ...
    "OpenXstimPassive_PlotDiagnostics.m"];

for k = 1:numel(helpers)

    helperPath = fullfile(cfg.ANALYSIS_FOLDER,helpers(k));

    if ~isfile(helperPath)
        error("Required Stage 4 helper is missing:\n%s",helperPath);
    end
end

if ~isfile(cfg.STAGE2_MASTER_FILE)
    error("Stage 2 master file not found:\n%s",cfg.STAGE2_MASTER_FILE);
end

if cfg.OVERWRITE_EXISTING_OUTPUT && isfolder(cfg.OUTPUT_FOLDER)

    fprintf("Replacing existing Stage 4 output folder:\n%s\n", ...
        cfg.OUTPUT_FOLDER);

    rmdir(cfg.OUTPUT_FOLDER,'s');
end

if ~isfolder(cfg.OUTPUT_FOLDER)
    mkdir(cfg.OUTPUT_FOLDER);
end

%% ========================================================================
% LOAD STAGE 2
% ========================================================================

S2 = load(cfg.STAGE2_MASTER_FILE);

if ~isfield(S2,"CaptureSummary") || ~isfield(S2,"resultFiles")
    error("Stage2MasterResults.mat must contain CaptureSummary and resultFiles.");
end

stage2Summary = S2.CaptureSummary;
stage2ResultFiles = string(S2.resultFiles);

nCaptures = height(stage2Summary);

%% ========================================================================
% LOAD OPTIONAL STAGE 3A AUDIT
% ========================================================================

FastAudit = table();

if isfile(cfg.STAGE3A_AUDIT_FILE)

    S3A = load(cfg.STAGE3A_AUDIT_FILE);

    if isfield(S3A,"FastEventAudit")
        FastAudit = S3A.FastEventAudit;
    elseif isfield(S3A,"audit") && isfield(S3A.audit,"fastEventAudit")
        FastAudit = S3A.audit.fastEventAudit;
    end

    fprintf("Stage 3A audit loaded         : YES\n");

else

    fprintf("Stage 3A audit loaded         : NO\n");
end

%% ========================================================================
% COMMON MODEL GRID
% ========================================================================

modelTime_us = (0:cfg.MODEL_DT_US:cfg.MODEL_MAX_US).';

%% ========================================================================
% HEADER
% ========================================================================

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 4: PASSIVE-PHASE NORMALIZATION\n");
fprintf("============================================================\n");

fprintf("Captures                     : %d\n",nCaptures);
fprintf("Expected active phases       : %d\n",nCaptures*40);
fprintf("Start / end guards           : %.1f / %.1f us\n", ...
    cfg.START_GUARD_US,cfg.END_GUARD_US);
fprintf("Slow smoothing               : %.1f us\n",cfg.SLOW_SMOOTH_US);
fprintf("Model grid                   : %.1f us\n",cfg.MODEL_DT_US);
fprintf("Model-grid extent            : 0 to %.1f us\n",cfg.MODEL_MAX_US);

%% ========================================================================
% PROCESS CAPTURES
% ========================================================================

metricParts = cell(nCaptures,1);
currentParts = cell(nCaptures,1);
normalizedParts = cell(nCaptures,1);
chargeParts = cell(nCaptures,1);

for c = 1:nCaptures

    fprintf("\n------------------------------------------------------------\n");
    fprintf("CAPTURE %d / %d | %.3g mA p-p\n", ...
        c,nCaptures,stage2Summary.CommandCurrent_mA(c));
    fprintf("------------------------------------------------------------\n");

    try

        if c>numel(stage2ResultFiles) || ...
                strlength(stage2ResultFiles(c))==0 || ...
                ~isfile(stage2ResultFiles(c))

            error("Stage 2 per-capture result file is missing.");
        end

        O = OpenXstimPassive_ProcessCapture( ...
            stage2ResultFiles(c), ...
            modelTime_us, ...
            FastAudit, ...
            cfg);

        metricParts{c} = O.phaseMetrics;
        currentParts{c} = O.currentModel_mA;
        normalizedParts{c} = O.normalizedModel;
        chargeParts{c} = O.chargeModel_uC;

        fprintf("Active phases extracted      : %d\n",height(O.phaseMetrics));
        fprintf("Valid normalized phases      : %d\n",nnz(O.phaseMetrics.ValidPhase));

        fprintf("Strong-collapse phases       : %d\n", ...
            nnz(O.phaseMetrics.PassiveRegime=="STRONG_COLLAPSE"));

    catch ME

        fprintf(2,"Capture failed: %s\n",ME.message);
    end
end

%% ========================================================================
% COMBINE
% ========================================================================

validCells = ~cellfun(@isempty,metricParts);

if ~any(validCells)
    error("No Stage 4 capture produced passive-phase data.");
end

PhaseMetrics = vertcat(metricParts{validCells});

passiveCurrentModel_mA = cat(2,currentParts{validCells});
passiveNormalizedModel = cat(2,normalizedParts{validCells});
passiveChargeModel_uC = cat(2,chargeParts{validCells});

if width(passiveCurrentModel_mA)~=height(PhaseMetrics) || ...
        width(passiveNormalizedModel)~=height(PhaseMetrics) || ...
        width(passiveChargeModel_uC)~=height(PhaseMetrics)

    error("Stage 4 model matrices and PhaseMetrics are misaligned.");
end

%% ========================================================================
% BUILD SUMMARIES
% ========================================================================

summary = OpenXstimPassive_BuildSummaries( ...
    modelTime_us, ...
    passiveCurrentModel_mA, ...
    passiveNormalizedModel, ...
    passiveChargeModel_uC, ...
    PhaseMetrics);

CurrentSummary = summary.CurrentSummary;
PolaritySummary = summary.PolaritySummary;
RegimeSummary = summary.RegimeSummary;
MeanWaveforms = summary.MeanWaveforms;
ByCurrent = summary.ByCurrent;

%% ========================================================================
% SAVE TABLES
% ========================================================================

writetable( ...
    PhaseMetrics, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4PassivePhaseMetrics.csv"));

writetable( ...
    CurrentSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4PassiveCurrentSummary.csv"));

writetable( ...
    PolaritySummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4PassivePolaritySummary.csv"));

writetable( ...
    RegimeSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4PassiveRegimeSummary.csv"));

writetable( ...
    MeanWaveforms, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4PassiveMeanWaveforms.csv"));

%% ========================================================================
% SAVE MAT
% ========================================================================

passive = struct();

passive.processingStage = ...
    "Stage4_NormalizePassivePhases";

passive.sourceStage2Master = ...
    cfg.STAGE2_MASTER_FILE;

passive.sourceStage3AAudit = ...
    cfg.STAGE3A_AUDIT_FILE;

passive.modelTime_us = ...
    modelTime_us;

passive.currentModel_mA = ...
    passiveCurrentModel_mA;

passive.normalizedModel = ...
    passiveNormalizedModel;

passive.chargeModel_uC = ...
    passiveChargeModel_uC;

passive.phaseMetrics = ...
    PhaseMetrics;

passive.currentSummary = ...
    CurrentSummary;

passive.polaritySummary = ...
    PolaritySummary;

passive.regimeSummary = ...
    RegimeSummary;

passive.meanWaveforms = ...
    MeanWaveforms;

passive.byCurrent = ...
    ByCurrent;

passive.settings = ...
    cfg;

save( ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4PassivePhases.mat"), ...
    "passive", ...
    "PhaseMetrics", ...
    "CurrentSummary", ...
    "PolaritySummary", ...
    "RegimeSummary", ...
    "MeanWaveforms", ...
    "cfg", ...
    "-v7.3");

%% ========================================================================
% DIAGNOSTICS
% ========================================================================

OpenXstimPassive_PlotDiagnostics( ...
    modelTime_us, ...
    passiveCurrentModel_mA, ...
    passiveNormalizedModel, ...
    passiveChargeModel_uC, ...
    PhaseMetrics, ...
    CurrentSummary, ...
    cfg);

%% ========================================================================
% FINAL SUMMARY
% ========================================================================

fprintf("\n============================================================\n");
fprintf("STAGE 4 COMPLETE\n");
fprintf("============================================================\n");

fprintf("Active phases processed      : %d\n",height(PhaseMetrics));
fprintf("Valid normalized phases      : %d\n",nnz(PhaseMetrics.ValidPhase));
fprintf("Invalid phases               : %d\n",nnz(~PhaseMetrics.ValidPhase));

fprintf("\nPassive regimes:\n");

regimes = unique(PhaseMetrics.PassiveRegime);

for k = 1:numel(regimes)

    rg = regimes(k);

    fprintf("  %-20s : %4d\n", ...
        rg, ...
        nnz(PhaseMetrics.PassiveRegime==rg));
end

fprintf("\nPer-current summary:\n");

disp(CurrentSummary(:,{ ...
    'CommandCurrent_mA', ...
    'NPhases', ...
    'NValid', ...
    'MeanEndNormalized', ...
    'MeanCurrentLoss_pct', ...
    'FractionCrossing75', ...
    'FractionCrossing50', ...
    'FractionStrongCollapse'}));

fprintf("\nOutput folder:\n%s\n",cfg.OUTPUT_FOLDER);

fprintf("\nInspect these before Stage 5:\n");
fprintf("  01_NormalizedPassivePhasesByCurrent.png\n");
fprintf("  02_PolarityComparisonByCurrent.png\n");
fprintf("  03_PassiveLossVsCurrent.png\n");
fprintf("  04_TimeAndChargeToThresholds.png\n");
fprintf("  05_PulseNumberEvolution.png\n");
fprintf("  06_LinkToNextTransitionRegime.png\n");

fprintf("\nNext required pipeline stage:\n");
fprintf("  Stage5_ModelOpenXstimPlant.m\n");
