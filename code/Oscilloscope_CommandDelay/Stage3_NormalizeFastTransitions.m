%% Stage3_NormalizeFastTransitions.m
% OPENXSTIM PIPELINE STAGE 3
% FAST-TRANSITION NORMALIZATION
%
% Core pipeline naming:
%   Stage0_IndexAndPlot.m
%   Stage1_IdentifyPacketsAndDecodeCommands.m
%   Stage2_ClassifyCurrentResponses.m
%   Stage3_NormalizeFastTransitions.m
%   Stage4_NormalizePassivePhases.m
%   Stage5_ModelOpenXstimPlant.m
%
% Lettered scripts such as Stage2A / Stage2B remain optional supporting
% analyses and are not part of the required pipeline.
%
% Required helper files in the same Matlab Analysis folder:
%   OpenXstimFast_ProcessCapture.m
%   OpenXstimFast_BuildSummaries.m
%   OpenXstimFast_PlotDiagnostics.m
%
% Stage 3 creates TWO fast-transition datasets:
%
%   A. PRIMARY MODEL DATASET
%      Only the repeating bipolar transitions:
%        +I -> -I
%        -I -> +I
%
%      This remains the clean model-ready dataset used by later plant fitting.
%
%   B. ADDITIONAL TRANSITION-TYPE CHARACTERIZATION
%      All physically observed fast transitions:
%        0  -> +I
%        +I -> -I
%        -I -> +I
%        -I -> 0
%
%      This dataset is used only to test whether the normalized fast response
%      depends on transition type and operating current. Timing-surrogate
%      boundary events from Stage 2 are NOT treated as physical edges.
%
% Stage 3 does not fit the final plant.

clear;
clc;
close all;

%% USER SETTINGS ==========================================================

cfg = struct();

cfg.DATA_ROOT = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.

cfg.ANALYSIS_FOLDER = fullfile(cfg.DATA_ROOT,"Matlab Analysis");

cfg.STAGE2_MASTER_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage2_CurrentResponseClassification", ...
    "Stage2MasterResults.mat");

cfg.OUTPUT_FOLDER = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage3_FastTransitionNormalization");

cfg.OVERWRITE_EXISTING_OUTPUT = true;

% Hardware / data
cfg.OUTPUT_CHANNEL = 3;
cfg.R_LOAD_OHM = 1000;

% Fast waveform grid
cfg.FAST_WINDOW_PRE_US = 20;
cfg.FAST_WINDOW_POST_US = 25;
cfg.COMMON_DT_US = 0.16;

% Narrow local trend fits
cfg.PRE_FIT_START_US = -60;
cfg.PRE_FIT_END_US = -15;
cfg.POST_FIT_START_US = 12;
cfg.POST_FIT_END_US = 45;
cfg.NEIGHBOUR_EDGE_GUARD_US = 20;

% Fast metrics
cfg.METRIC_SMOOTH_US = 0.32;
cfg.SETTLING_BAND = 0.02;
cfg.SETTLING_HOLD_US = 2.0;
cfg.FAST_METRIC_END_US = 15;

% QC
cfg.MIN_LOCAL_STEP_mA = 0.30;

cfg.BASELINE_QC_START_US = -15;
cfg.BASELINE_QC_END_US = -5;
cfg.BASELINE_TOL = 0.15;

cfg.FINAL_QC_START_US = 8;
cfg.FINAL_QC_END_US = 15;
cfg.FINAL_TOL = 0.20;

cfg.REQUIRE_TREND_R2 = false;
cfg.MIN_TREND_R2 = 0.80;

% Plots
cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;
cfg.MAX_TRACES_PER_CURRENT_PLOT = 35;

%% CHECK FILES ============================================================

helpers = [ ...
    "OpenXstimFast_ProcessCapture.m", ...
    "OpenXstimFast_BuildSummaries.m", ...
    "OpenXstimFast_PlotDiagnostics.m"];

for k = 1:numel(helpers)

    helperPath = fullfile(cfg.ANALYSIS_FOLDER,helpers(k));

    if ~isfile(helperPath)
        error("Required Stage 3 helper is missing:\n%s",helperPath);
    end
end

if ~isfile(cfg.STAGE2_MASTER_FILE)
    error("Stage 2 master file not found:\n%s",cfg.STAGE2_MASTER_FILE);
end

if cfg.OVERWRITE_EXISTING_OUTPUT && isfolder(cfg.OUTPUT_FOLDER)

    fprintf("Replacing existing Stage 3 output folder:\n%s\n", ...
        cfg.OUTPUT_FOLDER);

    rmdir(cfg.OUTPUT_FOLDER,'s');
end

if ~isfolder(cfg.OUTPUT_FOLDER)
    mkdir(cfg.OUTPUT_FOLDER);
end

%% LOAD STAGE 2 ===========================================================

S2 = load(cfg.STAGE2_MASTER_FILE);

if ~isfield(S2,"CaptureSummary") || ~isfield(S2,"resultFiles")
    error("Stage2MasterResults.mat must contain CaptureSummary and resultFiles.");
end

stage2Summary = S2.CaptureSummary;
stage2ResultFiles = string(S2.resultFiles);

nCaptures = height(stage2Summary);

fastTime_us = ( ...
    -cfg.FAST_WINDOW_PRE_US: ...
    cfg.COMMON_DT_US: ...
    cfg.FAST_WINDOW_POST_US).';

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 3: FAST TRANSITION NORMALIZATION\n");
fprintf("============================================================\n");

fprintf("Captures                    : %d\n",nCaptures);
fprintf("Common dt                   : %.3f us\n",cfg.COMMON_DT_US);
fprintf("Fast window                 : %.1f to %.1f us\n", ...
    fastTime_us(1),fastTime_us(end));
fprintf("Pre local fit               : %.1f to %.1f us\n", ...
    cfg.PRE_FIT_START_US,cfg.PRE_FIT_END_US);
fprintf("Post local fit              : %.1f to %.1f us\n", ...
    cfg.POST_FIT_START_US,cfg.POST_FIT_END_US);

%% PROCESS CAPTURES =======================================================

metricParts = cell(nCaptures,1);
rawParts = cell(nCaptures,1);
detrendedParts = cell(nCaptures,1);

allTypeMetricParts = cell(nCaptures,1);
allTypeRawParts = cell(nCaptures,1);
allTypeDetrendedParts = cell(nCaptures,1);

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

        O = OpenXstimFast_ProcessCapture( ...
            stage2ResultFiles(c), ...
            fastTime_us, ...
            cfg);

        % Existing primary bipolar dataset.
        metricParts{c} = O.eventMetrics;
        rawParts{c} = O.normalizedRaw;
        detrendedParts{c} = O.normalizedDetrended;

        % Additional all-transition-type characterization dataset.
        allTypeMetricParts{c} = O.allTransitionEventMetrics;
        allTypeRawParts{c} = O.allTransitionNormalizedRaw;
        allTypeDetrendedParts{c} = O.allTransitionNormalizedDetrended;

        fprintf("Bipolar events              : %d\n",height(O.eventMetrics));
        fprintf("Valid bipolar events        : %d\n",nnz(O.eventMetrics.ValidEvent));

        fprintf("Observed all-type edges     : %d\n", ...
            height(O.allTransitionEventMetrics));

        fprintf("Valid all-type edges        : %d\n", ...
            nnz(O.allTransitionEventMetrics.ValidEvent));

        if any(O.eventMetrics.ValidEvent)

            fprintf("Mean bipolar 10-90          : %.6f us\n", ...
                mean(O.eventMetrics.T10_90_us(O.eventMetrics.ValidEvent), ...
                'omitnan'));
        end

    catch ME

        fprintf(2,"Capture failed: %s\n",ME.message);
    end
end

%% COMBINE PRIMARY MODEL-READY BIPOLAR DATA ==============================

validCells = ~cellfun(@isempty,metricParts);

if ~any(validCells)
    error("No Stage 3 capture produced normalized bipolar fast-transition data.");
end

FastEventMetrics = vertcat(metricParts{validCells});
normalizedRaw = cat(2,rawParts{validCells});
normalizedDetrended = cat(2,detrendedParts{validCells});

if width(normalizedRaw)~=height(FastEventMetrics) || ...
        width(normalizedDetrended)~=height(FastEventMetrics)

    error("Primary waveform matrices and event metadata are misaligned.");
end

%% COMBINE ADDITIONAL ALL-TRANSITION-TYPE DATA ============================

validAllCells = ~cellfun(@isempty,allTypeMetricParts);

if ~any(validAllCells)
    error("No physical all-transition-type fast data were produced.");
end

AllTransitionEventMetrics = ...
    vertcat(allTypeMetricParts{validAllCells});

allTransitionNormalizedRaw = ...
    cat(2,allTypeRawParts{validAllCells});

allTransitionNormalizedDetrended = ...
    cat(2,allTypeDetrendedParts{validAllCells});

if width(allTransitionNormalizedRaw)~=height(AllTransitionEventMetrics) || ...
        width(allTransitionNormalizedDetrended)~=height(AllTransitionEventMetrics)

    error("All-transition waveform matrices and metadata are misaligned.");
end

%% BUILD SUMMARIES ========================================================

summary = OpenXstimFast_BuildSummaries( ...
    fastTime_us, ...
    normalizedDetrended, ...
    FastEventMetrics, ...
    allTransitionNormalizedDetrended, ...
    AllTransitionEventMetrics);

% Existing bipolar summaries.
CurrentSummary = summary.CurrentSummary;
DirectionSummary = summary.DirectionSummary;
FastMeanWaveforms = summary.FastMeanWaveforms;
FastSymmetryByCurrent = summary.FastSymmetryByCurrent;
FastByCurrent = summary.FastByCurrent;

% New transition-type summaries.
TransitionTypeSummary = summary.TransitionTypeSummary;
AllTransitionMeanWaveforms = summary.AllTransitionMeanWaveforms;
AllTransitionByType = summary.AllTransitionByType;

%% SAVE EXISTING TABLES ===================================================

writetable( ...
    FastEventMetrics, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3FastEventMetrics.csv"));

writetable( ...
    CurrentSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3FastCurrentSummary.csv"));

writetable( ...
    DirectionSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3FastDirectionSummary.csv"));

writetable( ...
    FastMeanWaveforms, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3FastMeanWaveforms.csv"));

writetable( ...
    FastSymmetryByCurrent, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3FastSymmetryByCurrent.csv"));

%% SAVE NEW TRANSITION-TYPE TABLES =======================================

writetable( ...
    AllTransitionEventMetrics, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3AllTransitionEventMetrics.csv"));

writetable( ...
    TransitionTypeSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3TransitionTypeSummary.csv"));

writetable( ...
    AllTransitionMeanWaveforms, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3AllTransitionMeanWaveforms.csv"));

%% SAVE MAT ===============================================================

fast = struct();

fast.processingStage = "Stage3_NormalizeFastTransitions";
fast.sourceStage2Master = cfg.STAGE2_MASTER_FILE;

% Existing primary model dataset.
fast.time_us = fastTime_us;
fast.normalizedRaw = normalizedRaw;
fast.normalizedDetrended = normalizedDetrended;

fast.eventMetrics = FastEventMetrics;
fast.currentSummary = CurrentSummary;
fast.directionSummary = DirectionSummary;
fast.meanWaveforms = FastMeanWaveforms;
fast.symmetryByCurrent = FastSymmetryByCurrent;
fast.byCurrent = FastByCurrent;

% Additional characterization only.
fast.allTransitionTypes = struct();

fast.allTransitionTypes.time_us = fastTime_us;

fast.allTransitionTypes.normalizedRaw = ...
    allTransitionNormalizedRaw;

fast.allTransitionTypes.normalizedDetrended = ...
    allTransitionNormalizedDetrended;

fast.allTransitionTypes.eventMetrics = ...
    AllTransitionEventMetrics;

fast.allTransitionTypes.summary = ...
    TransitionTypeSummary;

fast.allTransitionTypes.meanWaveforms = ...
    AllTransitionMeanWaveforms;

fast.allTransitionTypes.byType = ...
    AllTransitionByType;

fast.settings = cfg;

save( ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3FastNormalizedTransitions.mat"), ...
    "fast", ...
    "FastEventMetrics", ...
    "CurrentSummary", ...
    "DirectionSummary", ...
    "FastMeanWaveforms", ...
    "FastSymmetryByCurrent", ...
    "AllTransitionEventMetrics", ...
    "TransitionTypeSummary", ...
    "AllTransitionMeanWaveforms", ...
    "cfg", ...
    "-v7.3");

%% MASTER DIAGNOSTICS =====================================================

OpenXstimFast_PlotDiagnostics( ...
    fastTime_us, ...
    normalizedDetrended, ...
    FastEventMetrics, ...
    CurrentSummary, ...
    FastSymmetryByCurrent, ...
    allTransitionNormalizedDetrended, ...
    AllTransitionEventMetrics, ...
    TransitionTypeSummary, ...
    cfg);

%% FINAL SUMMARY ==========================================================

validMask = FastEventMetrics.ValidEvent;
allValidMask = AllTransitionEventMetrics.ValidEvent;

fprintf("\n============================================================\n");
fprintf("STAGE 3 COMPLETE\n");
fprintf("============================================================\n");

fprintf("\nPRIMARY BIPOLAR MODEL DATASET\n");
fprintf("Bipolar events processed    : %d\n",height(FastEventMetrics));
fprintf("Valid normalized events     : %d\n",nnz(validMask));
fprintf("Rejected normalized events  : %d\n",nnz(~validMask));
fprintf("Overall valid fraction      : %.4f\n",mean(validMask));

fprintf("\nADDITIONAL TRANSITION-TYPE CHARACTERIZATION\n");
fprintf("Observed physical edges     : %d\n",height(AllTransitionEventMetrics));
fprintf("Valid normalized edges      : %d\n",nnz(allValidMask));
fprintf("Rejected normalized edges   : %d\n",nnz(~allValidMask));

transitionClasses = [ ...
    "zero_to_pos", ...
    "pos_to_neg", ...
    "neg_to_pos", ...
    "neg_to_zero"];

for k = 1:numel(transitionClasses)

    cls = transitionClasses(k);

    m = AllTransitionEventMetrics.TransitionClass==cls;

    fprintf("  %-12s observed %4d | valid %4d\n", ...
        cls,nnz(m),nnz(m & allValidMask));
end

fprintf("\nPer-current bipolar summary:\n");

disp(CurrentSummary(:,{ ...
    'CommandCurrent_mA', ...
    'NEvents', ...
    'NValid', ...
    'ValidFraction', ...
    'MeanT10_90_us', ...
    'SDT10_90_us', ...
    'MeanOvershoot_pct'}));

fprintf("\nTransition-type summary:\n");

disp(TransitionTypeSummary(:,{ ...
    'CommandCurrent_mA', ...
    'TransitionClass', ...
    'NExpected', ...
    'NPhysicalEdgesObserved', ...
    'NValidNormalized', ...
    'MeanT10_90_us', ...
    'MeanCommandToGradientPeak_us', ...
    'MeanStepToCommandRatio'}));

fprintf("\nOutput folder:\n%s\n",cfg.OUTPUT_FOLDER);

fprintf("\nNew transition-type diagnostics:\n");
fprintf("  06_TransitionTypeComparisonByCurrent.png\n");
fprintf("  07_CrossCurrentComparisonByTransitionType.png\n");
fprintf("  08_TransitionMetricsByTypeAndCurrent.png\n");

fprintf("\nNext required pipeline stage:\n");
fprintf("  Stage4_NormalizePassivePhases.m\n");
