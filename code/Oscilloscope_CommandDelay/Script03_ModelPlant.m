%% 03_ModelOpenXstimPlant.m
% -------------------------------------------------------------------------
% OpenXstim Stage 3: model the three identified plant components separately.
%
% Inputs from Stage 2:
%   NormalizedTransitions.mat
%   CommandDelayResults.mat
%   PassiveDroopResults.mat
%
% Outputs:
%   Stage3ModelResults.mat
%   DelayModelSummary.csv
%   FastModelCandidateSummary.csv
%   DroopModelCandidateSummary.csv
%   Stage3_Models/Figures/ PNG and editable FIG diagnostics (13 figures)
%   DroopPhaseErrors.csv, DroopPhasePartitions.csv
%   DroopPolarityComparison.csv, DroopPredictions.csv
%
% Modelling philosophy:
%
%   command
%      |
%      v
%   [transport / firmware delay]
%      |
%      v
%   [fast electrical dynamics]
%      |
%      v
%   [slow within-phase droop]
%
% The three components are intentionally NOT collapsed into one transfer
% function.  This makes the model easier to interpret and much easier to
% revise when more command-current amplitudes are collected.
%
% Fast candidate models:
%   FOP          : first-order pole
%   TWO_POLE     : two real poles, unit DC gain
%   SECOND_ORDER : standard second-order model, unit DC gain
%
% Revised passive droop: LINEAR, QUADRATIC, SIMPLE_EXP.
% Uses Stage 2 modelTime_ms and individual modelNormalizedMagnitude columns.
% No second rebase, no 80 ns fit, no sample-wise train/validation splitting.
% Each candidate is fitted to complete training phases with equal phase
% weight. Validation reports errors on complete held-out phases, including
% their scatter. Holdout data select model family; they are not a final
% independent test set. Future captures are needed for that test.
%
% Positive and negative models are fitted first. A shared model is retained
% only if the configurable mean-curve and per-polarity validation checks pass.
% These are practical engineering tolerances, not a significance test.
% The 5 us grid reduces oversampling; it does not establish independence.
% Candidates satisfy D(0)=1 and monotone nonnegative droop on this measured
% interval. Quadratic extrapolation beyond that interval is not justified.
%
% models.droop.<group>.best is the TRAINING fit used for validation.
% models.droop.<group>.finalModel is a separately labelled all-phase refit.
% models.droop.combined is a trial until models.droop.comparison.accepted.
% models.droop.recommended identifies the shared/separate model to simulate.
% AIC/BIC remain unchanged for fast models and are not used for slow models.
% Figures are exported individually, then displayed as docked tabs.
%
% This script uses fminsearch only, so model fitting does not require the
% Optimization Toolbox.
% -------------------------------------------------------------------------

clear;
close all;
clc;

%% ========================================================================
% USER SETTINGS
% ========================================================================

% Change only this block when processing a different capture.
PROJECT_FOLDER = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.
STAGE2_INPUT_FOLDER = fullfile(PROJECT_FOLDER,"Stage2_Normalization");
STAGE3_OUTPUT_FOLDER = fullfile(PROJECT_FOLDER,"Stage3_Models");

stage2Folder = STAGE2_INPUT_FOLDER;
fastFile = fullfile(stage2Folder,"NormalizedTransitions.mat");
delayFile = fullfile(stage2Folder,"CommandDelayResults.mat");
droopFile = fullfile(stage2Folder,"PassiveDroopResults.mat");

% -------------------------------------------------------------------------
% FAST MODEL SETTINGS
% -------------------------------------------------------------------------

% Fit the fast model around the actual transition only.  The Stage 2 time
% axis is relative to the peak output gradient.
FAST_FIT_START_US = -6;
FAST_FIT_END_US   = 18;

% Deterministic held-out validation.  Every fourth bipolar transition is
% held out.  This prevents us from selecting model order only by fitting the
% same mean trace that was used for parameter estimation.
FAST_HOLDOUT_EVERY = 4;

% Candidate fast models.
FAST_MODEL_NAMES = [
    "FOP"
    "TWO_POLE"
    "SECOND_ORDER"
];

% -------------------------------------------------------------------------
% DROOP MODEL SETTINGS
% -------------------------------------------------------------------------

DROOP_MODEL_NAMES = ["LINEAR"; "QUADRATIC"; "SIMPLE_EXP"];
DROOP_HOLDOUT_EVERY = 4;       % every fourth original column of each polarity
DROOP_MIN_TRAIN_PHASES = 3;
DROOP_MIN_VALIDATION_PHASES = 2;
DROOP_EXPECTED_GRID_US = 5;    % must match the Stage 2 modelling grid
DROOP_START_TOL = 1e-6;       % normalized units; check only, never rebase

% Select the fewest-parameter model within this tolerance of the lowest
% validation RMSE. Equally complex candidates are ranked by validation RMSE.
DROOP_SELECTION_ABS_TOL = 0.001; % 0.1 percentage point of normalized current
DROOP_SELECTION_REL_TOL = 0.05;

% Practical polarity-pooling gates, local to this capture/current/load.
% Gate 1 uses TRAINING mean curves. Gate 2 checks the shared model on each
% polarity's held-out phases against that polarity's separate model.
DROOP_POOL_MEAN_RMSE_TOL = 0.010;
DROOP_POOL_MEAN_MAX_TOL = 0.030;
DROOP_POOL_VALIDATION_ABS_TOL = 0.001;
DROOP_POOL_VALIDATION_REL_TOL = 0.05;
DROOP_REFIT_ALL_PHASES = true;

FIGURE_WINDOW_STYLE = "normal";
FIGURE_VISIBLE = "off";
SAVE_EDITABLE_FIGURES = false;
FIGURE_RESOLUTION_DPI = 180;
% Plotting only: no effect on fitting, validation or model selection.
PLOT_FONT_SIZE = 11;
DROOP_RESIDUAL_ZOOM_MS = [0.10 0.30];
plotConfig = struct('fontSize',PLOT_FONT_SIZE, ...
    'droopResidualZoom_ms',DROOP_RESIDUAL_ZOOM_MS);

droopConfig = struct('modelNames',DROOP_MODEL_NAMES, ...
    'holdoutEvery',DROOP_HOLDOUT_EVERY, ...
    'minTraining',DROOP_MIN_TRAIN_PHASES, ...
    'minValidation',DROOP_MIN_VALIDATION_PHASES, ...
    'expectedGrid_us',DROOP_EXPECTED_GRID_US,'startTolerance',DROOP_START_TOL, ...
    'selectionAbsTolerance',DROOP_SELECTION_ABS_TOL, ...
    'selectionRelTolerance',DROOP_SELECTION_REL_TOL, ...
    'poolMeanRMSETolerance',DROOP_POOL_MEAN_RMSE_TOL, ...
    'poolMeanMaxTolerance',DROOP_POOL_MEAN_MAX_TOL, ...
    'poolValidationAbsTolerance',DROOP_POOL_VALIDATION_ABS_TOL, ...
    'poolValidationRelTolerance',DROOP_POOL_VALIDATION_REL_TOL, ...
    'refitAll',DROOP_REFIT_ALL_PHASES);

% -------------------------------------------------------------------------
% OPTIMISATION SETTINGS
% -------------------------------------------------------------------------

optimOptions = optimset( ...
    'Display','off', ...
    'MaxIter',5000, ...
    'MaxFunEvals',20000, ...
    'TolX',1e-10, ...
    'TolFun',1e-12);

%% ========================================================================
% LOAD STAGE 2 RESULTS
% ========================================================================

verifyHardcodedInputs([fastFile;delayFile;droopFile], ...
    "Stage 2 MAT files",PROJECT_FOLDER);

Sfast = load(fastFile);
Sdelay = load(delayFile);
Sdroop = load(droopFile);

assert(isfield(Sfast,"normalization"), ...
    "NormalizedTransitions.mat does not contain 'normalization'.");

assert(isfield(Sdelay,"delay"), ...
    "CommandDelayResults.mat does not contain 'delay'.");

assert(isfield(Sdroop,"droop"), ...
    "PassiveDroopResults.mat does not contain 'droop'.");

normalization = Sfast.normalization;
delayData = Sdelay.delay;
droopData = Sdroop.droop;
captureRoot = PROJECT_FOLDER;
outFolder = STAGE3_OUTPUT_FOLDER;
figureFolder = fullfile(outFolder,"Figures");
if ~isfolder(figureFolder), mkdir(figureFolder); end

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 3 PLANT MODELLING\n");
fprintf("============================================================\n");
fprintf("Stage 2 folder:\n%s\n",stage2Folder);

%% ========================================================================
% FAST DYNAMICS DATASET
% ========================================================================

assert(isfield(normalization,"groups"), ...
    "Normalization structure does not contain grouped responses.");

assert(isfield(normalization.groups,"bipolarCombined"), ...
    "No bipolarCombined group found.");

Gb = normalization.groups.bipolarCombined;

tFast_us = Gb.time_us(:);
Yb = Gb.detrendedResponses;

assert(~isempty(Yb), ...
    "No bipolar fast-transition responses found.");

nFastEvents = size(Yb,2);

fitTimeMask = ...
    tFast_us>=FAST_FIT_START_US & ...
    tFast_us<=FAST_FIT_END_US;

assert(nnz(fitTimeMask)>=20, ...
    "Fast fitting window contains too few samples.");

% Build deterministic train / validation split.
if nFastEvents>=8

    validationCols = ...
        mod((1:nFastEvents).',FAST_HOLDOUT_EVERY)==0;

    trainingCols = ~validationCols;

else

    trainingCols = true(nFastEvents,1);
    validationCols = false(nFastEvents,1);
end

Ytrain = Yb(:,trainingCols);
Yval = Yb(:,validationCols);

meanTrain = mean(Ytrain,2,'omitnan');
meanAll = mean(Yb,2,'omitnan');

if any(validationCols)
    meanVal = mean(Yval,2,'omitnan');
else
    meanVal = NaN(size(meanAll));
end

tFit_us = tFast_us(fitTimeMask);
yTrainFit = meanTrain(fitTimeMask);
yAllFit = meanAll(fitTimeMask);

if any(validationCols)
    yValFit = meanVal(fitTimeMask);
else
    yValFit = NaN(size(tFit_us));
end

fprintf("\n============================================================\n");
fprintf("FAST-DYNAMICS DATASET\n");
fprintf("============================================================\n");
fprintf("Bipolar transitions total : %d\n",nFastEvents);
fprintf("Training transitions      : %d\n",nnz(trainingCols));
fprintf("Validation transitions    : %d\n",nnz(validationCols));
fprintf("Fit window                : %.3f to %.3f us\n", ...
    FAST_FIT_START_US,FAST_FIT_END_US);

%% ========================================================================
% FIT FAST-DYNAMICS CANDIDATES
% ========================================================================

fastCandidates = repmat(emptyFastModel(),numel(FAST_MODEL_NAMES),1);

for m = 1:numel(FAST_MODEL_NAMES)

    modelName = FAST_MODEL_NAMES(m);

    fastCandidates(m) = fitFastCandidate( ...
        modelName, ...
        tFit_us, ...
        yTrainFit, ...
        optimOptions);

    % Validation is performed on data not used for fitting.
    if any(validationCols)

        yhatVal = fastModelResponse( ...
            fastCandidates(m), ...
            tFit_us);

        fastCandidates(m).validationRMSE = ...
            sqrt(mean((yValFit-yhatVal).^2,'omitnan'));

        fastCandidates(m).validationMaxAbsError = ...
            max(abs(yValFit-yhatVal),[],'omitnan');

    else

        fastCandidates(m).validationRMSE = NaN;
        fastCandidates(m).validationMaxAbsError = NaN;
    end
end

% Choose by held-out RMSE when held-out data exist.
if any(validationCols)

    criterion = [fastCandidates.validationRMSE].';

    [~,bestFastIndex] = min(criterion);

    fastSelectionBasis = "held-out RMSE";

else

    criterion = [fastCandidates.BIC].';

    [~,bestFastIndex] = min(criterion);

    fastSelectionBasis = "BIC";
end

bestFastFamily = fastCandidates(bestFastIndex).modelName;

% Refit selected family using ALL bipolar responses.
fastBest = fitFastCandidate( ...
    bestFastFamily, ...
    tFit_us, ...
    yAllFit, ...
    optimOptions);

fastBest.selectionBasis = fastSelectionBasis;

% Evaluate final selected model on every measured bipolar transition.
yhatBestFit = fastModelResponse(fastBest,tFit_us);

individualFastRMSE = NaN(nFastEvents,1);

for k = 1:nFastEvents

    yi = Yb(fitTimeMask,k);

    individualFastRMSE(k) = ...
        sqrt(mean((yi-yhatBestFit).^2,'omitnan'));
end

fastBest.individualEventRMSE = individualFastRMSE;
fastBest.individualEventRMSEMean = mean(individualFastRMSE,'omitnan');
fastBest.individualEventRMSESD = std(individualFastRMSE,'omitnan');

% Dynamic crossing times measured from the fitted model's own onset.
denseFast_us = linspace( ...
    fastBest.theta_us, ...
    max(FAST_FIT_END_US,fastBest.theta_us+30), ...
    10000).';

denseFastResponse = fastModelResponse( ...
    fastBest, ...
    denseFast_us);

fastBest.t10FromOnset_us = ...
    crossingTime( ...
    denseFast_us-fastBest.theta_us, ...
    denseFastResponse, ...
    0.10);

fastBest.t50FromOnset_us = ...
    crossingTime( ...
    denseFast_us-fastBest.theta_us, ...
    denseFastResponse, ...
    0.50);

fastBest.t90FromOnset_us = ...
    crossingTime( ...
    denseFast_us-fastBest.theta_us, ...
    denseFastResponse, ...
    0.90);

fastBest.t10_90_us = ...
    fastBest.t90FromOnset_us ...
    - fastBest.t10FromOnset_us;

% Direction-specific fits using the same selected model family.
fastDirection = struct();

directionNames = [
    "pos_to_neg"
    "neg_to_pos"
];

for d = 1:numel(directionNames)

    className = directionNames(d);
    fieldName = matlab.lang.makeValidName(className);

    assert(isfield(normalization.groups,fieldName), ...
        "Missing fast group: %s",fieldName);

    Gdir = normalization.groups.(fieldName);

    fastDirection.(fieldName) = fitFastCandidate( ...
        bestFastFamily, ...
        Gdir.time_us(fitTimeMask), ...
        Gdir.meanDetrended(fitTimeMask), ...
        optimOptions);

    fastDirection.(fieldName).N = Gdir.N;
end

fprintf("\n============================================================\n");
fprintf("FAST MODEL CANDIDATE COMPARISON\n");
fprintf("============================================================\n");

for m = 1:numel(fastCandidates)

    F = fastCandidates(m);

    fprintf("\n%s\n",F.modelName);
    fprintf("  Fit RMSE       : %.8f\n",F.RMSE);
    fprintf("  Fit R2         : %.8f\n",F.R2);
    fprintf("  AIC            : %.6f\n",F.AIC);
    fprintf("  BIC            : %.6f\n",F.BIC);

    if any(validationCols)
        fprintf("  Validation RMSE: %.8f\n",F.validationRMSE);
    end
end

fprintf("\nSELECTED FAST MODEL: %s\n",fastBest.modelName);
fprintf("Selection basis         : %s\n",fastSelectionBasis);
fprintf("Alignment/onset offset  : %.6f us from gradient peak\n", ...
    fastBest.theta_us);
fprintf("Model t10 from onset    : %.6f us\n", ...
    fastBest.t10FromOnset_us);
fprintf("Model t50 from onset    : %.6f us\n", ...
    fastBest.t50FromOnset_us);
fprintf("Model t90 from onset    : %.6f us\n", ...
    fastBest.t90FromOnset_us);
fprintf("Model 10-90             : %.6f us\n", ...
    fastBest.t10_90_us);
fprintf("Event RMSE mean         : %.8f\n", ...
    fastBest.individualEventRMSEMean);

printFastParameters(fastBest);

%% ========================================================================
% MODEL COMMAND DELAY
% ========================================================================

delayMetrics = delayData.metrics;

requiredDelayVars = [
    "EventNumber"
    "TransitionClass"
    "ValidEvent"
    "CommandToGradientPeak_us"
    "CommandToT10_us"
    "CommandToT50_us"
    "CommandToT90_us"
];

assert(all(ismember(requiredDelayVars,string(delayMetrics.Properties.VariableNames))), ...
    "CommandDelayResults.mat is missing expected delay fields.");

validDelay = ...
    delayMetrics.ValidEvent & ...
    isfinite(delayMetrics.CommandToGradientPeak_us);

classNames = unique( ...
    string(delayMetrics.TransitionClass(validDelay)), ...
    'stable');

% Global constant delay model, retained only as a baseline.
allPeakDelay = ...
    delayMetrics.CommandToGradientPeak_us(validDelay);

globalPeakMedian_us = median(allPeakDelay,'omitnan');

globalResidual = ...
    allPeakDelay-globalPeakMedian_us;

globalDelayRMSE_us = ...
    sqrt(mean(globalResidual.^2,'omitnan'));

delayRows = repmat(emptyDelayRow(),numel(classNames),1);

for c = 1:numel(classNames)

    cls = classNames(c);

    mask = ...
        validDelay & ...
        string(delayMetrics.TransitionClass)==cls;

    xPeak = delayMetrics.CommandToGradientPeak_us(mask);
    x10 = delayMetrics.CommandToT10_us(mask);
    x50 = delayMetrics.CommandToT50_us(mask);
    x90 = delayMetrics.CommandToT90_us(mask);

    row = emptyDelayRow();

    row.TransitionClass = cls;
    row.N = nnz(mask);

    row.PeakMean_us = mean(xPeak,'omitnan');
    row.PeakSD_us = std(xPeak,'omitnan');
    row.PeakMedian_us = median(xPeak,'omitnan');
    row.PeakMAD_us = median(abs(xPeak-row.PeakMedian_us),'omitnan');

    % Convert the measured command-to-gradient-peak timing into a pure
    % command-to-fast-model-onset transport delay.
    row.TransportDelayToOnset_us = ...
        row.PeakMedian_us + fastBest.theta_us;

    row.MeasuredT10Mean_us = mean(x10,'omitnan');
    row.MeasuredT50Mean_us = mean(x50,'omitnan');
    row.MeasuredT90Mean_us = mean(x90,'omitnan');

    row.PredictedT10Mean_us = ...
        row.TransportDelayToOnset_us ...
        + fastBest.t10FromOnset_us;

    row.PredictedT50Mean_us = ...
        row.TransportDelayToOnset_us ...
        + fastBest.t50FromOnset_us;

    row.PredictedT90Mean_us = ...
        row.TransportDelayToOnset_us ...
        + fastBest.t90FromOnset_us;

    row.T10PredictionError_us = ...
        row.MeasuredT10Mean_us-row.PredictedT10Mean_us;

    row.T50PredictionError_us = ...
        row.MeasuredT50Mean_us-row.PredictedT50Mean_us;

    row.T90PredictionError_us = ...
        row.MeasuredT90Mean_us-row.PredictedT90Mean_us;

    delayRows(c) = row;
end

delayModelTable = struct2table(delayRows);

% Class-dependent residual error.
classPredPeak = NaN(height(delayMetrics),1);

for c = 1:height(delayModelTable)

    cls = delayModelTable.TransitionClass(c);

    mask = ...
        validDelay & ...
        string(delayMetrics.TransitionClass)==cls;

    classPredPeak(mask) = ...
        delayModelTable.PeakMedian_us(c);
end

classResidual = ...
    delayMetrics.CommandToGradientPeak_us(validDelay) ...
    - classPredPeak(validDelay);

classDelayRMSE_us = ...
    sqrt(mean(classResidual.^2,'omitnan'));

fprintf("\n============================================================\n");
fprintf("COMMAND-DELAY MODEL\n");
fprintf("============================================================\n");
fprintf("Global constant peak-delay RMSE : %.6f us\n", ...
    globalDelayRMSE_us);
fprintf("Class-dependent peak-delay RMSE : %.6f us\n", ...
    classDelayRMSE_us);
fprintf("\nThe Simulink transport delay should use the class-dependent\n");
fprintf("command-to-FAST-ONSET value, not command-to-gradient-peak.\n");

disp(delayModelTable);

% Plot inputs reference the existing numerical results. The validation
% view uses fastCandidates(bestFastIndex), the actual training-only fit.
fastPlotData = struct();
fastPlotData.delayMetrics = delayMetrics;
fastPlotData.delayTable = delayModelTable;
fastPlotData.time_us = tFast_us;
fastPlotData.fitTime_us = tFit_us;
fastPlotData.meanTrain = meanTrain;
fastPlotData.meanVal = meanVal;
fastPlotData.trainingCount = nnz(trainingCols);
fastPlotData.validationCount = nnz(validationCols);
fastPlotData.candidates = fastCandidates;
fastPlotData.selectedTraining = fastCandidates(bestFastIndex);
fastPlotData.finalRefit = fastBest;
fastPlotData.direction = fastDirection;
fastPlotData.groups = normalization.groups;

%% ========================================================================
% PASSIVE-DROOP MODELLING
% ========================================================================

% Slow processing uses only the Stage 2 model-grid matrices. The complete
% fast and delay estimation above is deliberately preserved.
droopGroups = modelPassiveDroopPhases(droopData,droopConfig,optimOptions);
printPassiveDroopResults(droopGroups);

%% ========================================================================
% BUILD MODEL SUMMARY TABLES
% ========================================================================

fastSummaryRows = repmat(emptyFastSummaryRow(),numel(fastCandidates),1);

for m = 1:numel(fastCandidates)

    F = fastCandidates(m);

    r = emptyFastSummaryRow();

    r.Model = F.modelName;
    r.Parameters = string(F.parameterText);
    r.Theta_us = F.theta_us;
    r.FitRMSE = F.RMSE;
    r.ValidationRMSE = F.validationRMSE;
    r.R2 = F.R2;
    r.AIC = F.AIC;
    r.BIC = F.BIC;
    r.Selected = F.modelName==bestFastFamily;

    fastSummaryRows(m) = r;
end

fastSummaryTable = struct2table(fastSummaryRows);

[droopSummaryTable,droopPhaseErrorTable,droopPhaseAuditTable, ...
    droopComparisonTable,droopPredictionTable] = makeDroopResultTables(droopGroups);
writetable(droopPhaseErrorTable,fullfile(outFolder,"DroopPhaseErrors.csv"));
writetable(droopPhaseAuditTable,fullfile(outFolder,"DroopPhasePartitions.csv"));
writetable(droopComparisonTable,fullfile(outFolder,"DroopPolarityComparison.csv"));
writetable(droopPredictionTable,fullfile(outFolder,"DroopPredictions.csv"));

writetable( ...
    delayModelTable, ...
    fullfile(outFolder,"DelayModelSummary.csv"));

writetable( ...
    fastSummaryTable, ...
    fullfile(outFolder,"FastModelCandidateSummary.csv"));

writetable( ...
    droopSummaryTable, ...
    fullfile(outFolder,"DroopModelCandidateSummary.csv"));

%% ========================================================================
% SAVE STAGE 3 MODEL STRUCTURE
% ========================================================================

models = struct();

models.stage2Folder = stage2Folder;
models.captureRoot = captureRoot;
models.outputRoot = captureRoot;
models.stageOutputFolder = outFolder;
models.outputLayout = "sibling_stage_folders";

models.delay = struct();
models.delay.table = delayModelTable;
models.delay.globalPeakMedian_us = globalPeakMedian_us;
models.delay.globalPeakRMSE_us = globalDelayRMSE_us;
models.delay.classDependentPeakRMSE_us = classDelayRMSE_us;
models.delay.fastOnsetOffsetFromGradientPeak_us = fastBest.theta_us;

models.fast = struct();
models.fast.candidates = fastCandidates;
models.fast.best = fastBest;
models.fast.direction = fastDirection;
models.fast.trainingColumns = trainingCols;
models.fast.validationColumns = validationCols;
models.fast.selectionBasis = fastSelectionBasis;

models.droop = droopGroups;

models.notes = struct();

models.notes.fast = ...
    "The fast model is delay-free. theta_us is only the alignment offset " + ...
    "between the Stage 2 gradient-peak reference and the model's physical onset.";

models.notes.delay = ...
    "Use TransportDelayToOnset_us as the pure delay in a combined plant model.";

models.notes.droop = ...
    "Droop fits are local to this capture, amplitude, load and guarded phase interval. " + ...
    "best uses training phases only; finalModel is a labelled all-phase refit. " + ...
    "Validation selects model family/pooling and is not an independent final test.";

save( ...
    fullfile(outFolder,"Stage3ModelResults.mat"), ...
    "models", ...
    "-v7.3");

%% ========================================================================
% EXPORT FIGURES
% ========================================================================

% Save numerical outputs before attempting the new slow diagnostics.
try
    plotFastAndDelayResults(fastPlotData,plotConfig);
    plotPassiveDroopResults(droopGroups,plotConfig);
catch ME
    models.plotError = string(ME.message);
    warning('Stage3:DiagnosticPlot','Diagnostics incomplete: %s',ME.message);
end
figureManifest = exportStage3Figures(figureFolder,FIGURE_RESOLUTION_DPI, ...
    FIGURE_WINDOW_STYLE,FIGURE_VISIBLE,SAVE_EDITABLE_FIGURES);
models.figureManifest = figureManifest;
save(fullfile(outFolder,"Stage3ModelResults.mat"),"models","-v7.3");

%% ========================================================================
% FINAL CONSOLE SUMMARY
% ========================================================================

fprintf("\n============================================================\n");
fprintf("STAGE 3 COMPLETE\n");
fprintf("============================================================\n");

fprintf("\nDELAY\n");
fprintf("  Class-dependent delay model retained.\n");
fprintf("  Peak-delay RMSE, global       : %.6f us\n", ...
    globalDelayRMSE_us);
fprintf("  Peak-delay RMSE, class-based  : %.6f us\n", ...
    classDelayRMSE_us);

fprintf("\nFAST DYNAMICS\n");
fprintf("  Selected family : %s\n",fastBest.modelName);
fprintf("  Selection basis : %s\n",fastSelectionBasis);
fprintf("  10-90 time      : %.6f us\n",fastBest.t10_90_us);
fprintf("  Event RMSE mean : %.8f\n",fastBest.individualEventRMSEMean);

fprintf("\nPASSIVE DROOP\n");
fprintf("  Positive model : %s\n",droopGroups.positive.best.modelName);
fprintf("  Negative model : %s\n",droopGroups.negative.best.modelName);
fprintf("  Plant mode     : %s\n",droopGroups.recommended.mode);
fprintf("  Pooling result : %s\n",droopGroups.comparison.reason);
fprintf("  Validation is within this capture, by whole phase.\n");

fprintf("\nSaved to:\n%s\n",outFolder);

fprintf("\nPrimary result:\n");
fprintf("  Stage3ModelResults.mat\n");

fprintf("\nCSV summaries:\n");
fprintf("  DelayModelSummary.csv\n");
fprintf("  FastModelCandidateSummary.csv\n");
fprintf("  DroopModelCandidateSummary.csv\n");

fprintf("\nIMPORTANT:\n");
fprintf("The droop model identified here is local to this measured amplitude.\n");
fprintf("Higher-current captures should be run through the same Stage 1 -> 2 -> 3\n");
fprintf("pipeline before building an amplitude-dependent nonlinear droop model.\n");

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function F = fitFastCandidate(modelName,t_us,y,optimOptions)

    t_us = t_us(:);
    y = y(:);

    good = isfinite(t_us) & isfinite(y);

    t_us = t_us(good);
    y = y(good);

    switch modelName

        case "FOP"

            starts = [
                log(2.0), -2.0
                log(3.0), -2.0
                log(1.0), -1.5
                log(4.0), -3.0
            ];

        case "TWO_POLE"

            starts = [
                log(1.0), log(2.0), -2.0
                log(0.5), log(3.0), -2.0
                log(1.5), log(1.5), -2.5
                log(2.0), log(4.0), -3.0
            ];

        case "SECOND_ORDER"

            starts = [
                log(2.0), log(1.0), -2.0
                log(2.0), log(0.8), -2.0
                log(1.5), log(1.2), -2.5
                log(3.0), log(0.7), -3.0
            ];

        otherwise
            error("Unknown fast model: %s",modelName);
    end

    bestP = [];
    bestObj = inf;

    for s = 1:size(starts,1)

        p0 = starts(s,:);

        obj = @(p) fastObjective(modelName,p,t_us,y);

        [pFit,fval] = fminsearch( ...
            obj, ...
            p0, ...
            optimOptions);

        if fval<bestObj
            bestObj = fval;
            bestP = pFit;
        end
    end

    F = decodeFastModel(modelName,bestP);

    yhat = fastModelResponse(F,t_us);

    M = fitMetrics(y,yhat,numel(bestP));

    F.RMSE = M.RMSE;
    F.R2 = M.R2;
    F.SSE = M.SSE;
    F.AIC = M.AIC;
    F.BIC = M.BIC;
    F.MaxAbsError = M.MaxAbsError;

    F.validationRMSE = NaN;
    F.validationMaxAbsError = NaN;
end

function value = fastObjective(modelName,p,t_us,y)

    F = decodeFastModel(modelName,p);

    yhat = fastModelResponse(F,t_us);

    residual = y-yhat;

    value = mean(residual.^2,'omitnan');

    % Soft physical penalties.
    penalty = 0;

    if F.theta_us < -15 || F.theta_us > 5
        penalty = penalty + 10*(abs(F.theta_us)+1);
    end

    switch modelName

        case "FOP"

            if F.tau_us<0.05 || F.tau_us>30
                penalty = penalty + 10;
            end

        case "TWO_POLE"

            if F.tau1_us<0.05 || F.tau1_us>30
                penalty = penalty + 10;
            end

            if F.tau2_us<0.05 || F.tau2_us>30
                penalty = penalty + 10;
            end

        case "SECOND_ORDER"

            if F.naturalTime_us<0.05 || F.naturalTime_us>30
                penalty = penalty + 10;
            end

            if F.zeta<0.05 || F.zeta>5
                penalty = penalty + 10;
            end
    end

    value = value+penalty;
end

function F = decodeFastModel(modelName,p)

    F = emptyFastModel();

    F.modelName = modelName;

    switch modelName

        case "FOP"

            F.tau_us = exp(p(1));
            F.theta_us = p(2);

            F.parameterCount = 2;

            F.parameterText = sprintf( ...
                'tau=%.6g us, theta=%.6g us', ...
                F.tau_us,F.theta_us);

            tau_s = F.tau_us*1e-6;

            F.tfNumerator = 1;
            F.tfDenominator = [tau_s 1];

        case "TWO_POLE"

            tauA = exp(p(1));
            tauB = exp(p(2));

            taus = sort([tauA tauB]);

            F.tauFast_us = taus(1);
            F.tauSlow_us = taus(2);

            F.tau1_us = F.tauFast_us;
            F.tau2_us = F.tauSlow_us;

            F.theta_us = p(3);

            F.parameterCount = 3;

            F.parameterText = sprintf( ...
                'tauFast=%.6g us, tauSlow=%.6g us, theta=%.6g us', ...
                F.tauFast_us,F.tauSlow_us,F.theta_us);

            t1 = F.tauFast_us*1e-6;
            t2 = F.tauSlow_us*1e-6;

            F.tfNumerator = 1;
            F.tfDenominator = [t1*t2, t1+t2, 1];

        case "SECOND_ORDER"

            F.naturalTime_us = exp(p(1));
            F.zeta = exp(p(2));
            F.theta_us = p(3);

            F.wn_rad_per_us = 1/F.naturalTime_us;
            F.wn_rad_per_s = F.wn_rad_per_us*1e6;

            F.parameterCount = 3;

            F.parameterText = sprintf( ...
                'wn=%.6g Mrad/s, zeta=%.6g, theta=%.6g us', ...
                F.wn_rad_per_s/1e6,F.zeta,F.theta_us);

            wn = F.wn_rad_per_s;

            F.tfNumerator = wn^2;
            F.tfDenominator = [1, 2*F.zeta*wn, wn^2];

        otherwise

            error("Unknown fast model.");
    end
end

function y = fastModelResponse(F,t_us)

    x = t_us(:)-F.theta_us;

    y = zeros(size(x));

    active = x>=0;

    xa = x(active);

    switch F.modelName

        case "FOP"

            y(active) = ...
                1-exp(-xa/F.tau_us);

        case "TWO_POLE"

            t1 = F.tau1_us;
            t2 = F.tau2_us;

            if abs(t1-t2) < 1e-5*max(t1,t2)

                tau = 0.5*(t1+t2);

                y(active) = ...
                    1-exp(-xa/tau).*(1+xa/tau);

            else

                y(active) = ...
                    1 - ...
                    ( ...
                    t2*exp(-xa/t2) ...
                    - t1*exp(-xa/t1) ...
                    )/(t2-t1);
            end

        case "SECOND_ORDER"

            wn = F.wn_rad_per_us;
            z = F.zeta;

            if z < 1-1e-5

                wd = wn*sqrt(1-z^2);

                y(active) = ...
                    1 - ...
                    exp(-z*wn*xa) .* ...
                    ( ...
                    cos(wd*xa) ...
                    + z/sqrt(1-z^2)*sin(wd*xa) ...
                    );

            elseif z > 1+1e-5

                q = sqrt(z^2-1);

                r1 = -wn*(z-q);
                r2 = -wn*(z+q);

                y(active) = ...
                    1 + ...
                    ( ...
                    r2*exp(r1*xa) ...
                    - r1*exp(r2*xa) ...
                    )/(r1-r2);

            else

                y(active) = ...
                    1-exp(-wn*xa).*(1+wn*xa);
            end

        otherwise

            error("Unknown fast model.");
    end
end

function printFastParameters(F)

    fprintf("\nFast-model parameters\n");

    switch F.modelName

        case "FOP"

            fprintf("  tau             : %.6f us\n",F.tau_us);

        case "TWO_POLE"

            fprintf("  tau fast        : %.6f us\n",F.tauFast_us);
            fprintf("  tau slow        : %.6f us\n",F.tauSlow_us);

        case "SECOND_ORDER"

            fprintf("  natural time    : %.6f us\n",F.naturalTime_us);
            fprintf("  wn              : %.6f Mrad/s\n", ...
                F.wn_rad_per_s/1e6);
            fprintf("  damping zeta    : %.6f\n",F.zeta);
    end

    fprintf("  theta alignment : %.6f us\n",F.theta_us);

    fprintf("  TF numerator    : ");
    fprintf("%.9g ",F.tfNumerator);
    fprintf("\n");

    fprintf("  TF denominator  : ");
    fprintf("%.9g ",F.tfDenominator);
    fprintf("\n");
end

function M = fitMetrics(y,yhat,k)

    y = y(:);
    yhat = yhat(:);

    good = isfinite(y) & isfinite(yhat);

    y = y(good);
    yhat = yhat(good);

    residual = y-yhat;

    n = numel(y);

    M.SSE = sum(residual.^2);
    M.RMSE = sqrt(mean(residual.^2));
    M.MaxAbsError = max(abs(residual));

    denom = sum((y-mean(y)).^2);

    if denom>0
        M.R2 = 1-M.SSE/denom;
    else
        M.R2 = NaN;
    end

    safeSSE = max(M.SSE,realmin);

    M.AIC = ...
        n*log(safeSSE/n) ...
        + 2*k;

    M.BIC = ...
        n*log(safeSSE/n) ...
        + k*log(n);
end

function tCross = crossingTime(t,y,level)

    t = t(:);
    y = y(:);

    good = isfinite(t) & isfinite(y);

    t = t(good);
    y = y(good);

    idx = find(y>=level,1,'first');

    if isempty(idx)
        tCross = NaN;
        return;
    end

    if idx==1
        tCross = t(1);
        return;
    end

    t1 = t(idx-1);
    t2 = t(idx);

    y1 = y(idx-1);
    y2 = y(idx);

    if y2==y1
        tCross = t2;
    else
        tCross = ...
            t1 ...
            + (level-y1)*(t2-t1)/(y2-y1);
    end
end

function label = prettyTransition(type)

    type = string(type);

    label = strings(size(type));

    for k = 1:numel(type)

        switch type(k)

            case "zero_to_pos"
                label(k) = "0 -> +I";

            case "pos_to_neg"
                label(k) = "+I -> -I";

            case "neg_to_pos"
                label(k) = "-I -> +I";

            case "neg_to_zero"
                label(k) = "-I -> 0";

            otherwise
                label(k) = type(k);
        end
    end
end

function F = emptyFastModel()

    F = struct( ...
        'modelName',"", ...
        'parameterText',"", ...
        'parameterCount',NaN, ...
        'theta_us',NaN, ...
        'tau_us',NaN, ...
        'tauFast_us',NaN, ...
        'tauSlow_us',NaN, ...
        'tau1_us',NaN, ...
        'tau2_us',NaN, ...
        'naturalTime_us',NaN, ...
        'wn_rad_per_us',NaN, ...
        'wn_rad_per_s',NaN, ...
        'zeta',NaN, ...
        'tfNumerator',NaN, ...
        'tfDenominator',NaN, ...
        'RMSE',NaN, ...
        'R2',NaN, ...
        'SSE',NaN, ...
        'AIC',NaN, ...
        'BIC',NaN, ...
        'MaxAbsError',NaN, ...
        'validationRMSE',NaN, ...
        'validationMaxAbsError',NaN);
end

function r = emptyDelayRow()

    r = struct( ...
        'TransitionClass',"", ...
        'N',0, ...
        'PeakMean_us',NaN, ...
        'PeakSD_us',NaN, ...
        'PeakMedian_us',NaN, ...
        'PeakMAD_us',NaN, ...
        'TransportDelayToOnset_us',NaN, ...
        'MeasuredT10Mean_us',NaN, ...
        'MeasuredT50Mean_us',NaN, ...
        'MeasuredT90Mean_us',NaN, ...
        'PredictedT10Mean_us',NaN, ...
        'PredictedT50Mean_us',NaN, ...
        'PredictedT90Mean_us',NaN, ...
        'T10PredictionError_us',NaN, ...
        'T50PredictionError_us',NaN, ...
        'T90PredictionError_us',NaN);
end

function r = emptyFastSummaryRow()

    r = struct( ...
        'Model',"", ...
        'Parameters',"", ...
        'Theta_us',NaN, ...
        'FitRMSE',NaN, ...
        'ValidationRMSE',NaN, ...
        'R2',NaN, ...
        'AIC',NaN, ...
        'BIC',NaN, ...
        'Selected',false);
end


%% PASSIVE-DROOP PHASE MODELLING ==========================================

function S = modelPassiveDroopPhases(droop,cfg,optimOptions)
assert(isfield(droop,'modelTime_ms'), ...
    'Stage 2 modelTime_ms is missing. Run the consolidated Stage 2 first.');
t = droop.modelTime_ms(:);
assert(numel(t)>=10 && all(isfinite(t)) && all(diff(t)>0), ...
    'The slow modelling time grid must contain at least 10 increasing finite times.');
assert(abs(t(1))<=1e-9,'The Stage 2 slow grid must begin at zero; no rebasing is done here.');
dt_us = median(diff(t))*1000;
assert(all(abs(diff(t)*1000-dt_us)<=max(1e-8,dt_us*1e-6)), ...
    'The slow model grid is not uniform. Check Stage 2.');
assert(abs(dt_us-cfg.expectedGrid_us)<=max(1e-8,cfg.expectedGrid_us*1e-6), ...
    'Expected %.6g us model grid, found %.6g us. Check Stage 2 or DROOP_EXPECTED_GRID_US.', ...
    cfg.expectedGrid_us,dt_us);
assert(cfg.holdoutEvery>=2 && cfg.holdoutEvery==floor(cfg.holdoutEvery), ...
    'DROOP_HOLDOUT_EVERY must be an integer >= 2.');
assert(cfg.minTraining>=1 && cfg.minValidation>=1, ...
    'Minimum phase counts must be positive.');

S = struct();
S.config = cfg;
S.time_ms = t;
S.modelDt_us = dt_us;
S.phaseOrigin = "Stage 2 guarded slow-phase origin";
if isfield(droop,'settings'), S.stage2Settings = droop.settings; end
if isfield(droop,'sourceStage1Mat'), S.sourceStage1Mat = droop.sourceStage1Mat; end
assert(isfield(droop,'positive') && isfield(droop,'negative'), ...
    'Stage 2 positive and negative droop groups are required.');

S.positive = fitDroopPhaseGroup( ...
    prepareDroopPhaseData("positive",droop.positive,t,cfg),cfg,optimOptions);
S.negative = fitDroopPhaseGroup( ...
    prepareDroopPhaseData("negative",droop.negative,t,cfg),cfg,optimOptions);
S.combined = emptyDroopPhaseGroup("combined",t);
S.combined.status = "not_fitted: polarity evidence not yet sufficient";

A = S.positive; B = S.negative;
C = struct('accepted',false,'shapePassed',false,'validationPassed',false, ...
    'trainingMeanRMSE',NaN,'trainingMeanMaxDifference',NaN, ...
    'positiveSeparateRMSE',NaN,'negativeSeparateRMSE',NaN, ...
    'positiveSharedRMSE',NaN,'negativeSharedRMSE',NaN, ...
    'positiveModelOnNegativeRMSE',NaN,'negativeModelOnPositiveRMSE',NaN, ...
    'positiveAllowedRMSE',NaN,'negativeAllowedRMSE',NaN, ...
    'reason',"Separate validated models are required before pooling.");

if A.available && B.available
    delta = A.trainingMean-B.trainingMean;
    C.trainingMeanRMSE = sqrt(mean(delta.^2));
    C.trainingMeanMaxDifference = max(abs(delta));
    C.shapePassed = C.trainingMeanRMSE<=cfg.poolMeanRMSETolerance && ...
        C.trainingMeanMaxDifference<=cfg.poolMeanMaxTolerance;
    C.positiveSeparateRMSE = A.best.validationRMSE;
    C.negativeSeparateRMSE = B.best.validationRMSE;
    C.positiveModelOnNegativeRMSE = droopPhaseScore( ...
        B.data(:,B.validationMask),predictDroopPhaseModel(A.best,t));
    C.negativeModelOnPositiveRMSE = droopPhaseScore( ...
        A.data(:,A.validationMask),predictDroopPhaseModel(B.best,t));
    C.positiveAllowedRMSE = C.positiveSeparateRMSE+max( ...
        cfg.poolValidationAbsTolerance,cfg.poolValidationRelTolerance*C.positiveSeparateRMSE);
    C.negativeAllowedRMSE = C.negativeSeparateRMSE+max( ...
        cfg.poolValidationAbsTolerance,cfg.poolValidationRelTolerance*C.negativeSeparateRMSE);

    if C.shapePassed
        % Preserve exactly the original per-polarity split when pooling.
        % Stage 2 combined columns are positive first, then negative.
        combinedAudit = [A.phaseAudit;B.phaseAudit];
        combinedAudit.Group(:) = "combined";
        combinedAudit.OriginalColumn = (1:height(combinedAudit)).';
        trial = emptyDroopPhaseGroup("combined",t);
        trial.data = [A.data B.data];
        trial.phaseAudit = combinedAudit;
        trial.trainingMask = [A.trainingMask;B.trainingMask];
        trial.validationMask = [A.validationMask;B.validationMask];
        trial.validMask = [A.validMask;B.validMask];
        trial = refreshDroopGroupMeans(trial);
        S.combined = fitDroopPhaseGroup(trial,cfg,optimOptions);
        if S.combined.available
            prediction = predictDroopPhaseModel(S.combined.best,t);
            C.positiveSharedRMSE = droopPhaseScore(A.data(:,A.validationMask),prediction);
            C.negativeSharedRMSE = droopPhaseScore(B.data(:,B.validationMask),prediction);
            C.validationPassed = C.positiveSharedRMSE<=C.positiveAllowedRMSE && ...
                C.negativeSharedRMSE<=C.negativeAllowedRMSE;
            C.accepted = C.validationPassed;
            if C.accepted
                C.reason = "Shared model passed training-curve and both polarity validation tolerances.";
            else
                C.reason = "Shared trial worsens validation beyond tolerance for at least one polarity.";
            end
        else
            C.reason = "Shared trial has no eligible model; retain separate polarity models.";
        end
    else
        C.reason = "Training mean curves differ beyond pooling tolerances; retain separate models.";
    end
end
S.comparison = C;

% Refit only after validation-based selection. Never overwrite best or its
% validation residuals with predictions obtained from this all-phase refit.
S.positive = finalizeDroopPhaseGroup(S.positive,cfg,optimOptions);
S.negative = finalizeDroopPhaseGroup(S.negative,cfg,optimOptions);
if C.accepted
    S.combined = finalizeDroopPhaseGroup(S.combined,cfg,optimOptions);
end

R = struct('mode',"insufficient_evidence", ...
    'shared',emptyDroopPhaseCandidate(), ...
    'positive',emptyDroopPhaseCandidate(),'negative',emptyDroopPhaseCandidate());
if C.accepted
    R.mode = "shared";
    R.shared = S.combined.finalModel;
    S.combined.usedForPlant = true;
elseif S.positive.available && S.negative.available
    R.mode = "separate";
    R.positive = S.positive.finalModel;
    R.negative = S.negative.finalModel;
    S.positive.usedForPlant = true;
    S.negative.usedForPlant = true;
end
R.validTimeInterval_ms = [t(1) t(end)];
R.note = "Local empirical droop multiplier. Do not extrapolate to other currents, loads or durations.";
S.recommended = R;
S.notes = [ ...
    "Validation phases select the family and pooling; use future captures for independent testing."; ...
    "Lower sampling rate does not make samples or consecutive phases statistically independent."; ...
    "Whole columns with nonfinite data or a failed D(0) check are excluded and reported."; ...
    "All models satisfy D(0)=1 and nonnegative monotone droop over the observed interval."; ...
    "The guarded slow origin must be handled explicitly when recombining fast and slow dynamics."];
end

function G = prepareDroopPhaseData(name,source,t,cfg)
G = emptyDroopPhaseGroup(name,t);
if isfield(source,'N') && source.N==0
    G.status = "no_phases";
    return;
end
assert(isfield(source,'modelNormalizedMagnitude'), ...
    'Missing %s.modelNormalizedMagnitude. Run the consolidated Stage 2.',name);
Y = source.modelNormalizedMagnitude;
assert(isnumeric(Y) && isreal(Y) && size(Y,1)==numel(t), ...
    '%s model matrix must have one row per modelTime_ms sample.',name);
n = size(Y,2);
assert(isfield(source,'phaseTable') && height(source.phaseTable)==n, ...
    '%s phase metadata must have one row per model-matrix column.',name);
assert(all(ismember({'phaseStartEvent','phaseEndEvent'}, ...
    source.phaseTable.Properties.VariableNames)), ...
    '%s phaseTable lacks command event IDs.',name);

good = all(isfinite(Y),1).';
startOK = isfinite(Y(1,:)).' & abs(Y(1,:).'-1)<=cfg.startTolerance;
valid = good & startOK;
column = (1:n).';
% Assign the holdout on original columns before QC removes any phases.
validation = valid & mod(column,cfg.holdoutEvery)==0;
training = valid & ~validation;
partition = repmat("rejected",n,1);
partition(training) = "training";
partition(validation) = "validation";
reason = repmat("pass",n,1);
reason(~good) = "nonfinite_model_column";
reason(good & ~startOK) = "D0_not_one_no_automatic_rebase";
G.phaseAudit = table(repmat(name,n,1),repmat(name,n,1),column,column, ...
    source.phaseTable.phaseStartEvent,source.phaseTable.phaseEndEvent, ...
    partition,reason,Y(1,:).',sum(isfinite(Y),1).', ...
    'VariableNames',{'Group','Polarity','OriginalColumn','PolarityColumn', ...
    'StartEvent','EndEvent','Partition','QCReason','D0','FiniteSamples'});
G.data = Y;
G.validMask = valid;
G.trainingMask = training;
G.validationMask = validation;
G = refreshDroopGroupMeans(G);
end

function G = refreshDroopGroupMeans(G)
G.N = size(G.data,2);
G.trainingColumns = find(G.trainingMask);
G.validationColumns = find(G.validationMask);
G.rejectedColumns = find(~G.validMask);
G.Ntraining = nnz(G.trainingMask);
G.Nvalidation = nnz(G.validationMask);
G.meanAll = mean(G.data(:,G.validMask),2,'omitnan');
G.trainingMean = mean(G.data(:,G.trainingMask),2);
G.validationMean = mean(G.data(:,G.validationMask),2);
end

function G = fitDroopPhaseGroup(G,cfg,optimOptions)
if G.Ntraining<cfg.minTraining || G.Nvalidation<cfg.minValidation
    G.status = string(sprintf('insufficient_phases: training %d, validation %d', ...
        G.Ntraining,G.Nvalidation));
    warning('Stage3:DroopPhaseCount','%s: %s',G.groupName,G.status);
    return;
end
G.candidates = repmat(emptyDroopPhaseCandidate(),numel(cfg.modelNames),1);
Ytrain = G.data(:,G.trainingMask);
Yval = G.data(:,G.validationMask);
for m = 1:numel(cfg.modelNames)
    C = fitDroopPhaseCandidate(cfg.modelNames(m),G.time_ms,Ytrain,optimOptions);
    if C.isPhysical
        [C.validationRMSE,C.validationPhaseRMSE,C.validationResidual] = ...
            droopPhaseScore(Yval,C.yhat);
        C.validationPhaseRMSESD = std(C.validationPhaseRMSE);
        C.validationMaxPhaseRMSE = max(C.validationPhaseRMSE);
    end
    C.fitRole = "training_only";
    G.candidates(m) = C;
end
eligible = [G.candidates.isPhysical].' & [G.candidates.converged].' & ...
    isfinite([G.candidates.validationRMSE].');
if ~any(eligible)
    G.status = "no_converged_physical_candidate";
    warning('Stage3:DroopFit','%s has no eligible droop model.',G.groupName);
    return;
end
errors = [G.candidates.validationRMSE].';
bestError = min(errors(eligible));
G.selectionToleranceUsed = max(cfg.selectionAbsTolerance,cfg.selectionRelTolerance*bestError);
shortlist = find(eligible & errors<=bestError+G.selectionToleranceUsed);
parameterCounts = [G.candidates(shortlist).parameterCount].';
[~,order] = sortrows([parameterCounts errors(shortlist)],[1 2]);
G.bestIndex = shortlist(order(1));
G.best = G.candidates(G.bestIndex);
G.selectionMetric = "whole_phase_validation_RMSE_with_complexity_tolerance";
G.status = "fitted_and_validated";
G.available = true;
end

function G = finalizeDroopPhaseGroup(G,cfg,optimOptions)
if ~G.available, return; end
if cfg.refitAll
    C = fitDroopPhaseCandidate(G.best.modelName,G.time_ms,G.data(:,G.validMask),optimOptions);
    if C.isPhysical && C.converged
        C.fitRole = "all_valid_phases_refit_not_independent_validation";
        G.finalModel = C;
        G.finalRefitPerformed = true;
    else
        warning('Stage3:DroopRefit','%s all-phase refit failed; retain the training fit.',G.groupName);
        G.finalModel = G.best;
        G.finalModel.fitRole = "training_fit_fallback_after_failed_refit";
    end
else
    G.finalModel = G.best;
    G.finalModel.fitRole = "training_fit_no_refit_requested";
end
end

function C = fitDroopPhaseCandidate(name,t,Y,optimOptions)
C = emptyDroopPhaseCandidate();
C.modelName = string(name);
C.validTimeInterval_ms = [t(1) t(end)];
T = t(end);
assert(T>0 && ~isempty(Y) && all(isfinite(Y(:))), ...
    'Droop candidate fits require complete finite phases and positive duration.');
meanY = mean(Y,2);
estimatedDrop = min(max(1-meanY(end),1e-5),1-1e-5);
if C.modelName=="LINEAR"
    % With a common complete grid and equal phase weights, this is exactly
    % the constrained least-squares solution for all training columns.
    C.k_per_ms = min(max(-sum(t.*(meanY-1))/sum(t.^2),0),1/T);
    C.parameterCount = 1;
    C.endDrop = C.k_per_ms*T;
    C.parameterText = string(sprintf('D=1-k*t; k=%.8g /ms',C.k_per_ms));
    C.converged = true;
    C.exitflag = 1;
else
    switch C.modelName
        case "QUADRATIC"
            % End drop in (0,1) and fraction q in (0,1) parameterize the
            % initial/final negative slopes. This guarantees monotonicity
            % and D>=0 on [0,T], including between sampled grid points.
            starts = [repmat(droopLogit(estimatedDrop),3,1), ...
                [droopLogit(.25);0;droopLogit(.75)]];
        case "SIMPLE_EXP"
            rate = max(-log(max(meanY(end),1e-6))/T,1e-6);
            starts = log(rate*[.5;1;2]);
        otherwise
            error('Unknown passive-droop model: %s',C.modelName);
    end
    bestLoss = Inf; bestP = []; bestFlag = NaN; foundConverged = false;
    for k = 1:size(starts,1)
        [p,loss,flag] = fminsearch(@(p) droopPhaseObjective( ...
            C.modelName,p,t,Y),starts(k,:),optimOptions);
        isConverged = flag>0;
        if isfinite(loss) && ((isConverged && ~foundConverged) || ...
                (isConverged==foundConverged && loss<bestLoss))
            bestLoss = loss; bestP = p; bestFlag = flag;
            foundConverged = isConverged;
        end
    end
    if isempty(bestP), C.failureReason = "optimization_failed"; return; end
    C = decodeDroopPhaseParameters(C.modelName,bestP,T);
    C.exitflag = bestFlag;
    C.converged = foundConverged;
end
C.yhat = predictDroopPhaseModel(C,t);
C.isPhysical = all(isfinite(C.yhat)) && abs(C.yhat(1)-1)<=1e-9 && ...
    all(C.yhat>=-1e-10) && all(diff(C.yhat)<=1e-10);
if C.isPhysical
    [C.trainingRMSE,C.trainingPhaseRMSE,C.trainingResidual] = droopPhaseScore(Y,C.yhat);
    C.RMSE = C.trainingRMSE; % compatibility: explicitly training error
else
    C.failureReason = "nonphysical_prediction";
end
end

function loss = droopPhaseObjective(name,p,t,Y)
if any(~isfinite(p)) || any(abs(p)>80), loss = 1e12; return; end
C = decodeDroopPhaseParameters(name,p,t(end));
prediction = predictDroopPhaseModel(C,t);
if any(~isfinite(prediction)), loss = 1e12; return; end
residual = Y-prediction;
phaseMSE = mean(residual.^2,1);
loss = mean(phaseMSE); % each whole training phase has equal weight
end

function C = decodeDroopPhaseParameters(name,p,T)
C = emptyDroopPhaseCandidate();
C.modelName = name;
C.validTimeInterval_ms = [0 T];
switch string(name)
    case "QUADRATIC"
        drop = 1/(1+exp(-p(1)));
        q = 1/(1+exp(-p(2)));
        C.endDrop = drop;
        C.shapeFraction = q;
        C.a_per_ms = -2*drop*q/T;
        C.b_per_ms2 = drop*(2*q-1)/T^2;
        C.parameterCount = 2;
        C.parameterText = string(sprintf('D=1+a*t+b*t^2; a=%.8g /ms, b=%.8g /ms^2', ...
            C.a_per_ms,C.b_per_ms2));
    case "SIMPLE_EXP"
        C.k_per_ms = exp(p(1));
        C.tau_ms = 1/C.k_per_ms;
        C.parameterCount = 1;
        C.endDrop = 1-exp(-C.k_per_ms*T);
        C.parameterText = string(sprintf('D=exp(-t/tau); tau=%.8g ms',C.tau_ms));
    otherwise
        error('Unsupported passive-droop parameterization.');
end
end

function y = predictDroopPhaseModel(C,t)
t = t(:);
switch string(C.modelName)
    case "LINEAR", y = 1-C.k_per_ms*t;
    case "QUADRATIC", y = 1+C.a_per_ms*t+C.b_per_ms2*t.^2;
    case "SIMPLE_EXP", y = exp(-C.k_per_ms*t);
    otherwise, y = NaN(size(t));
end
end

function [rmse,phaseRMSE,residual] = droopPhaseScore(Y,prediction)
if isempty(Y)
    rmse = NaN; phaseRMSE = zeros(0,1); residual = zeros(size(Y)); return;
end
residual = Y-prediction(:);
phaseMSE = mean(residual.^2,1);
phaseRMSE = sqrt(phaseMSE).';
rmse = sqrt(mean(phaseMSE));
end

function p = droopLogit(x)
x = min(max(x,1e-8),1-1e-8);
p = log(x/(1-x));
end

function C = emptyDroopPhaseCandidate()
C = struct('modelName',"NONE",'parameterText',"",'parameterCount',NaN, ...
    'k_per_ms',NaN,'a_per_ms',NaN,'b_per_ms2',NaN,'tau_ms',NaN, ...
    'endDrop',NaN,'shapeFraction',NaN,'validTimeInterval_ms',[NaN NaN], ...
    'yhat',[],'RMSE',NaN,'trainingRMSE',NaN,'validationRMSE',NaN, ...
    'trainingPhaseRMSE',[],'validationPhaseRMSE',[], ...
    'validationPhaseRMSESD',NaN,'validationMaxPhaseRMSE',NaN, ...
    'trainingResidual',[],'validationResidual',[], ...
    'converged',false,'exitflag',NaN,'isPhysical',false, ...
    'fitRole',"unfitted",'failureReason',"");
end

function G = emptyDroopPhaseGroup(name,t)
G = struct();
G.groupName = name;
G.time_ms = t;
G.data = zeros(numel(t),0);
G.N = 0; G.Ntraining = 0; G.Nvalidation = 0;
G.trainingMask = false(0,1); G.validationMask = false(0,1);
G.validMask = false(0,1);
G.trainingColumns = []; G.validationColumns = []; G.rejectedColumns = [];
G.meanAll = NaN(size(t)); G.trainingMean = NaN(size(t)); G.validationMean = NaN(size(t));
G.candidates = repmat(emptyDroopPhaseCandidate(),0,1);
G.bestIndex = NaN;
G.best = emptyDroopPhaseCandidate();
G.finalModel = emptyDroopPhaseCandidate();
G.finalRefitPerformed = false;
G.selectionToleranceUsed = NaN;
G.selectionMetric = "unavailable";
G.available = false; G.usedForPlant = false; G.status = "not_fitted";
G.phaseAudit = table('Size',[0 10], ...
    'VariableTypes',{'string','string','double','double','double','double', ...
    'string','string','double','double'}, ...
    'VariableNames',{'Group','Polarity','OriginalColumn','PolarityColumn', ...
    'StartEvent','EndEvent','Partition','QCReason','D0','FiniteSamples'});
end

function printPassiveDroopResults(S)
fprintf('\n============================================================\n');
fprintf('PASSIVE DROOP: WHOLE-PHASE FITTING AND VALIDATION\n');
fprintf('============================================================\n');
fprintf('Model grid: %.6g us; interval [%.6g, %.6g] ms\n', ...
    S.modelDt_us,S.time_ms(1),S.time_ms(end));
fprintf('D(0) is checked against 1; Stage 3 does not normalize again.\n');
names = ["positive","negative","combined"];
for k = 1:numel(names)
    G = S.(names(k));
    fprintf('\n%s: %s\n',upper(names(k)),G.status);
    fprintf('  Training %d; validation %d; rejected %d\n', ...
        G.Ntraining,G.Nvalidation,numel(G.rejectedColumns));
    for m = 1:numel(G.candidates)
        C = G.candidates(m);
        marker = "";
        if G.available && m==G.bestIndex, marker = " [selected within group]"; end
        fprintf('  %-12s train RMSE %.7f; val RMSE %.7f; phase-RMSE SD %.7f%s\n', ...
            C.modelName,C.trainingRMSE,C.validationRMSE,C.validationPhaseRMSESD,marker);
    end
    if G.available
        fprintf('  Training-fit parameters: %s\n',G.best.parameterText);
        fprintf('  Complexity-selection tolerance: %.7f normalized units\n',G.selectionToleranceUsed);
        if G.finalRefitPerformed
            fprintf('  All-phase refit (separate from validation): %s\n',G.finalModel.parameterText);
        end
    end
end
C = S.comparison;
fprintf('\nPOLARITY COMPARISON\n');
fprintf('  Training mean-curve RMSE: %.7f (limit %.7f)\n', ...
    C.trainingMeanRMSE,S.config.poolMeanRMSETolerance);
fprintf('  Training max difference: %.7f (limit %.7f)\n', ...
    C.trainingMeanMaxDifference,S.config.poolMeanMaxTolerance);
fprintf('  Shared positive validation RMSE: %.7f (allowed %.7f)\n', ...
    C.positiveSharedRMSE,C.positiveAllowedRMSE);
fprintf('  Shared negative validation RMSE: %.7f (allowed %.7f)\n', ...
    C.negativeSharedRMSE,C.negativeAllowedRMSE);
fprintf('  Result: %s\n',C.reason);
fprintf('  Recommended plant mode: %s\n',S.recommended.mode);
fprintf('Validation is within one capture and is used for selection, not a final independent test.\n');
end

function [summary,errors,audit,comparison,predictions] = makeDroopResultTables(S)
names = ["positive","negative","combined"];
summary = table('Size',[0 15],'VariableTypes', ...
    {'string','string','string','double','double','double','double','double', ...
    'double','double','logical','logical','logical','logical','string'}, ...
    'VariableNames',{'Group','Model','TrainingParameters','ParameterCount', ...
    'NTraining','NValidation','TrainingRMSE','ValidationRMSE', ...
    'ValidationPhaseRMSESD','ValidationMaxPhaseRMSE','Physical','Converged', ...
    'SelectedWithinGroup','UsedForPlant','FitRole'});
errors = table('Size',[0 10],'VariableTypes', ...
    {'string','string','double','string','double','double','string','double','double','double'}, ...
    'VariableNames',{'Group','Model','OriginalColumn','Polarity','StartEvent', ...
    'EndEvent','Partition','RMSE','MeanResidual','MaxAbsResidual'});
audit = S.positive.phaseAudit([],:);
predictions = table(S.time_ms,'VariableNames',{'Time_ms'});
for k = 1:numel(names)
    G = S.(names(k));
    audit = [audit;G.phaseAudit]; %#ok<AGROW>
    predictions.(char(names(k)+"_TrainingMean")) = G.trainingMean;
    predictions.(char(names(k)+"_ValidationMean")) = G.validationMean;
    predictions.(char(names(k)+"_SelectedTrainingFit")) = predictDroopPhaseModel(G.best,S.time_ms);
    predictions.(char(names(k)+"_FinalModel")) = predictDroopPhaseModel(G.finalModel,S.time_ms);
    for m = 1:numel(G.candidates)
        C = G.candidates(m);
        selected = G.available && m==G.bestIndex;
        summary(end+1,:) = {names(k),C.modelName,C.parameterText,C.parameterCount, ...
            G.Ntraining,G.Nvalidation,C.trainingRMSE,C.validationRMSE, ...
            C.validationPhaseRMSESD,C.validationMaxPhaseRMSE,C.isPhysical, ...
            C.converged,selected,selected && G.usedForPlant,C.fitRole}; %#ok<AGROW>
        if ~C.isPhysical, continue; end
        columns = find(G.validMask);
        for j = 1:numel(columns)
            col = columns(j);
            residual = G.data(:,col)-C.yhat;
            A = G.phaseAudit(col,:);
            errors(end+1,:) = {names(k),C.modelName,col,A.Polarity, ...
                A.StartEvent,A.EndEvent,A.Partition,sqrt(mean(residual.^2)), ...
                mean(residual),max(abs(residual))}; %#ok<AGROW>
        end
    end
end
comparison = struct2table(S.comparison);
comparison.MeanRMSETolerance = S.config.poolMeanRMSETolerance;
comparison.MeanMaxTolerance = S.config.poolMeanMaxTolerance;
comparison.ValidationAbsTolerance = S.config.poolValidationAbsTolerance;
comparison.ValidationRelTolerance = S.config.poolValidationRelTolerance;
comparison.RecommendedMode = S.recommended.mode;
end

%% STAGE 3 DIAGNOSTICS ====================================================

function plotFastAndDelayResults(P,cfg)
palette = stage3Palette();

% 01: show the measured class clusters and the two delay definitions.
fig = newStage3Figure('01 Delay model',[1280 820],cfg);
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Command delay model', ...
    'Transport delay is measured from the command to the fitted fast-model onset');

ax = nexttile(tl); hold(ax,'on');
classes = string(P.delayTable.TransitionClass);
for k = 1:numel(classes)
    mask = string(P.delayMetrics.TransitionClass)==classes(k) & ...
        isfinite(P.delayMetrics.CommandToGradientPeak_us);
    scatter(ax,P.delayMetrics.EventNumber(mask), ...
        P.delayMetrics.CommandToGradientPeak_us(mask),38, ...
        'MarkerFaceColor',palette.class(k,:), ...
        'MarkerEdgeColor','none','DisplayName', ...
        sprintf('%s, N=%d',prettyTransition(classes(k)),nnz(mask)));
end
decorateStage3Axis(ax,'Command event','Command to gradient peak (us)');
title(ax,'Measured command-to-peak delay by transition class');
legend(ax,'show','Location','eastoutside','AutoUpdate','off');
tightYFromLines(ax,2.5);

ax = nexttile(tl); hold(ax,'on');
x = (1:height(P.delayTable)).';
peak = P.delayTable.PeakMedian_us;
spread = P.delayTable.PeakMAD_us;
onset = P.delayTable.TransportDelayToOnset_us;
for k = 1:numel(x)
    plot(ax,[x(k) x(k)],[onset(k) peak(k)],'-', ...
        'Color',[.72 .72 .72],'LineWidth',1.2,'HandleVisibility','off');
end
errorbar(ax,x,peak,spread,'o','Color',palette.blue, ...
    'MarkerFaceColor',palette.blue,'LineWidth',1.2, ...
    'DisplayName','Gradient-peak median +/- MAD');
scatter(ax,x,onset,55,'diamond','MarkerFaceColor',palette.orange, ...
    'MarkerEdgeColor',palette.orange,'DisplayName','Fast-model onset delay');
for k = 1:numel(x)
    text(ax,x(k)+0.04,onset(k),sprintf('%.2f',onset(k)), ...
        'FontSize',max(cfg.fontSize-2,8),'VerticalAlignment','middle');
end
xticks(ax,x); xticklabels(ax,cellstr(prettyTransition(classes)));
xlim(ax,[.55 numel(x)+.55]);
decorateStage3Axis(ax,'Transition class','Delay (us)');
title(ax,'Class parameters used by the delay model');
legend(ax,'show','Location','eastoutside','AutoUpdate','off');
tightYFromLines(ax,3);

% 02: candidate responses and their training-mean residuals.
fig = newStage3Figure('02 Fast candidate fits',[1280 850],cfg);
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Fast-dynamics candidate fits', ...
    'All candidates are fitted to the training mean over the displayed window');
t = P.fitTime_us(:);
yTrain = vectorOnFitWindow(P.time_us,P.meanTrain,t);
ax = nexttile(tl); hold(ax,'on');
plot(ax,t,yTrain,'Color',palette.black,'LineWidth',2.2, ...
    'DisplayName',sprintf('Training mean, N=%d',P.trainingCount));
for m = 1:numel(P.candidates)
    C = P.candidates(m);
    selected = '';
    width = 1.5;
    if C.modelName==P.selectedTraining.modelName
        selected = ' [selected]'; width = 2.2;
    end
    plot(ax,t,fastModelResponse(C,t),'Color',palette.model(m,:), ...
        'LineWidth',width,'DisplayName',sprintf('%s, val RMSE %.4g%s', ...
        prettyModelName(C.modelName),C.validationRMSE,selected));
end
addResponseGuides(ax);
decorateStage3Axis(ax,'Time from gradient peak (us)','Normalized response');
title(ax,'Measured training mean and candidate predictions');
legend(ax,'show','Location','eastoutside','AutoUpdate','off');

ax = nexttile(tl); hold(ax,'on');
for m = 1:numel(P.candidates)
    C = P.candidates(m);
    plot(ax,t,100*(yTrain-fastModelResponse(C,t)), ...
        'Color',palette.model(m,:),'LineWidth',1.6, ...
        'DisplayName',prettyModelName(C.modelName));
end
yline(ax,0,':','Color',[.35 .35 .35],'HandleVisibility','off');
decorateStage3Axis(ax,'Time from gradient peak (us)','Residual (pp)');
title(ax,'Training-mean residuals: measured minus prediction');
legend(ax,'show','Location','eastoutside','AutoUpdate','off');
tightYFromLines(ax,.15);

% 03: keep the actual held-out comparison separate from the all-event refit.
fig = newStage3Figure('03 Fast validation',[1280 850],cfg);
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Fast-model held-out validation', ...
    'Selection uses the training-only fit; the all-event refit is labelled separately');
yVal = vectorOnFitWindow(P.time_us,P.meanVal,t);
ySelected = fastModelResponse(P.selectedTraining,t);
ax = nexttile(tl); hold(ax,'on');
plot(ax,t,yTrain,'Color',palette.blue,'LineWidth',1.5, ...
    'DisplayName',sprintf('Training mean, N=%d',P.trainingCount));
if any(isfinite(yVal))
    plot(ax,t,yVal,'Color',palette.orange,'LineWidth',1.8, ...
        'DisplayName',sprintf('Held-out mean, N=%d',P.validationCount));
end
plot(ax,t,ySelected,'Color',palette.black,'LineWidth',2.2, ...
    'DisplayName',sprintf('Training-only %s fit', ...
    prettyModelName(P.selectedTraining.modelName)));
plot(ax,t,fastModelResponse(P.finalRefit,t),'--','Color',palette.gray, ...
    'LineWidth',1.5,'DisplayName','All-event refit, final parameters');
xline(ax,P.selectedTraining.theta_us,':','Color',palette.black, ...
    'HandleVisibility','off');
addResponseGuides(ax);
decorateStage3Axis(ax,'Time from gradient peak (us)','Normalized response');
title(ax,sprintf('Held-out RMSE %.5f',P.selectedTraining.validationRMSE));
legend(ax,'show','Location','eastoutside','AutoUpdate','off');

ax = nexttile(tl); hold(ax,'on');
if any(isfinite(yVal))
    plot(ax,t,100*(yVal-ySelected),'Color',palette.orange, ...
        'LineWidth',1.8,'DisplayName','Held-out mean residual');
end
yline(ax,0,':','Color',[.35 .35 .35],'HandleVisibility','off');
decorateStage3Axis(ax,'Time from gradient peak (us)','Residual (pp)');
title(ax,'Held-out mean minus the training-only prediction');
if any(isfinite(yVal)), legend(ax,'show','Location','eastoutside','AutoUpdate','off'); end
tightYFromLines(ax,.15);

% 04: compare each bipolar direction with its own fit and residual.
fig = newStage3Figure('04 Fast direction comparison',[1280 850],cfg);
tl = tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Fast dynamics by bipolar direction', ...
    'The selected model family is fitted independently to each direction');
directionNames = ["pos_to_neg","neg_to_pos"];
for d = 1:2
    name = directionNames(d);
    G = P.groups.(matlab.lang.makeValidName(name));
    F = P.direction.(matlab.lang.makeValidName(name));
    measured = vectorOnFitWindow(G.time_us,G.meanDetrended,t);
    prediction = fastModelResponse(F,t);
    ax = nexttile(tl,d); hold(ax,'on');
    plot(ax,t,measured,'Color',palette.class(d+1,:), ...
        'LineWidth',2,'DisplayName',sprintf('Measured mean, N=%d',F.N));
    plot(ax,t,prediction,'--','Color',palette.black, ...
        'LineWidth',1.8,'DisplayName',sprintf('%s fit',prettyModelName(F.modelName)));
    addResponseGuides(ax);
    decorateStage3Axis(ax,'Time from gradient peak (us)','Normalized response');
    title(ax,prettyTransition(name));
    legend(ax,'show','Location','best','AutoUpdate','off');
    ax = nexttile(tl,d+2); hold(ax,'on');
    plot(ax,t,100*(measured-prediction),'Color',palette.class(d+1,:), ...
        'LineWidth',1.7,'DisplayName','Mean residual');
    yline(ax,0,':','Color',[.35 .35 .35],'HandleVisibility','off');
    decorateStage3Axis(ax,'Time from gradient peak (us)','Residual (pp)');
    title(ax,sprintf('%s residual',prettyTransition(name)));
    tightYFromLines(ax,.15);
end
end

function plotPassiveDroopResults(S,cfg)
names = ["positive","negative","combined"];
palette = stage3Palette();

% 05: retain the candidate comparison, with fixed colors and clean legends.
fig = newStage3Figure('05 Droop candidate fits',[1320 1050],cfg);
tl = tiledlayout(fig,3,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Passive-droop candidate fits', ...
    'Training means, held-out means and training-only model predictions');
for g = 1:3
    G = S.(names(g)); ax = nexttile(tl); hold(ax,'on');
    if G.available
        plot(ax,G.time_ms,G.trainingMean,'Color',palette.black, ...
            'LineWidth',2.1,'DisplayName','Training mean');
        plot(ax,G.time_ms,G.validationMean,':','Color',palette.gray, ...
            'LineWidth',1.8,'DisplayName','Held-out mean');
        for m = 1:numel(G.candidates)
            C = G.candidates(m);
            if ~C.isPhysical, continue; end
            selected = '';
            width = 1.5;
            if m==G.bestIndex, selected=' [selected]'; width=2.2; end
            plot(ax,G.time_ms,C.yhat,'Color',palette.model(m,:), ...
                'LineWidth',width,'DisplayName',sprintf('%s, val %.5f%s', ...
                prettyModelName(C.modelName),C.validationRMSE,selected));
        end
        legend(ax,'show','Location','eastoutside','AutoUpdate','off');
        xlim(ax,[G.time_ms(1) G.time_ms(end)]);
    else
        noStage3Data(ax,G.status);
    end
    decorateStage3Axis(ax,'Time from slow-phase origin (ms)', ...
        'Normalized magnitude D(t)');
    title(ax,droopGroupHeading(S,names(g)));
end

% 06: compare polarities and show their small difference on a useful scale.
fig = newStage3Figure('06 Droop positive negative',[1280 850],cfg);
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Positive and negative passive droop', ...
    'Independent training fits, followed by the measured polarity difference');
ax = nexttile(tl); hold(ax,'on');
for g = 1:2
    G = S.(names(g));
    if G.available
        plot(ax,G.time_ms,G.trainingMean,'Color',palette.polarity(g,:), ...
            'LineWidth',2,'DisplayName',sprintf('%s training mean',titleCase(names(g))));
        plot(ax,G.time_ms,G.best.yhat,'--','Color',palette.polarity(g,:), ...
            'LineWidth',1.8,'DisplayName',sprintf('%s %s fit', ...
            titleCase(names(g)),prettyModelName(G.best.modelName)));
    end
end
decorateStage3Axis(ax,'Time from slow-phase origin (ms)','Normalized magnitude D(t)');
title(ax,'Separate polarity fits');
if S.positive.available || S.negative.available
    legend(ax,'show','Location','eastoutside','AutoUpdate','off');
end

ax = nexttile(tl); hold(ax,'on');
difference_pp = 100*(S.positive.trainingMean-S.negative.trainingMean);
plot(ax,S.time_ms,difference_pp,'Color',palette.purple,'LineWidth',1.8, ...
    'DisplayName','Positive minus negative');
yline(ax,0,':','Color',[.35 .35 .35],'HandleVisibility','off');
decorateStage3Axis(ax,'Time from slow-phase origin (ms)','Difference (pp)');
title(ax,sprintf('Training means: RMSE %.3f pp, max |difference| %.3f pp', ...
    100*S.comparison.trainingMeanRMSE,100*S.comparison.trainingMeanMaxDifference));
tightYFromLines(ax,.08);

% 07: complete held-out phases and residual means.
fig = newStage3Figure('07 Droop held out validation',[1380 1080],cfg);
tl = tiledlayout(fig,3,2,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Held-out passive-droop validation', ...
    'Complete validation phases are compared with the selected training-only fit');
for g = 1:3
    G = S.(names(g));
    ax = nexttile(tl,2*g-1); hold(ax,'on');
    if G.available
        plotTraceFamily(ax,G.time_ms,G.data(:,G.validationMask), ...
            palette.lightBlue,'Held-out phases');
        plot(ax,G.time_ms,G.validationMean,'Color',palette.black, ...
            'LineWidth',2,'DisplayName','Held-out mean');
        plot(ax,G.time_ms,G.best.yhat,'--','Color',palette.orange, ...
            'LineWidth',2,'DisplayName','Training-only prediction');
        legend(ax,'show','Location','eastoutside','AutoUpdate','off');
        xlim(ax,[G.time_ms(1) G.time_ms(end)]);
    else
        noStage3Data(ax,G.status);
    end
    decorateStage3Axis(ax,'Time (ms)','D(t)');
    title(ax,droopGroupHeading(S,names(g)));

    ax = nexttile(tl,2*g); hold(ax,'on');
    if G.available
        residual_pp = 100*G.best.validationResidual;
        plotTraceFamily(ax,G.time_ms,residual_pp,palette.lightOrange, ...
            'Held-out residuals');
        plot(ax,G.time_ms,mean(residual_pp,2),'Color',palette.orange, ...
            'LineWidth',2,'DisplayName','Mean residual');
        yline(ax,0,':','Color',[.35 .35 .35],'HandleVisibility','off');
        legend(ax,'show','Location','eastoutside','AutoUpdate','off');
        setSymmetricResidualLimit(ax,residual_pp,.08);
        xlim(ax,[G.time_ms(1) G.time_ms(end)]);
    else
        noStage3Data(ax,G.status);
    end
    decorateStage3Axis(ax,'Time (ms)','Residual (pp)');
    title(ax,sprintf('%s held-out residuals',titleCase(names(g))));
end

% 08: training and held-out residuals on the same scale within each group.
fig = newStage3Figure('08 Droop residuals',[1380 1080],cfg);
tl = tiledlayout(fig,3,2,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Passive-droop residuals', ...
    'Residual = measured D(t) minus selected training-model prediction; pp = 100 x normalized value');
for g = 1:3
    G = S.(names(g));
    if G.available
        allResidual_pp = 100*[G.best.trainingResidual G.best.validationResidual];
    else
        allResidual_pp = [];
    end
    for split = 1:2
        ax = nexttile(tl,2*g-2+split); hold(ax,'on');
        if G.available
            if split==1
                residual_pp = 100*G.best.trainingResidual;
                label = 'Training'; color = palette.lightBlue;
            else
                residual_pp = 100*G.best.validationResidual;
                label = 'Held-out'; color = palette.lightOrange;
            end
            plotTraceFamily(ax,G.time_ms,residual_pp,color, ...
                sprintf('%s residuals',label));
            plot(ax,G.time_ms,mean(residual_pp,2),'Color',palette.black, ...
                'LineWidth',1.9,'DisplayName','Mean residual');
            yline(ax,0,':','Color',[.35 .35 .35],'HandleVisibility','off');
            xlim(ax,[G.time_ms(1) G.time_ms(end)]);
            setSymmetricResidualLimit(ax,allResidual_pp,.08);
            legend(ax,'show','Location','eastoutside','AutoUpdate','off');
        else
            label = 'Unavailable'; noStage3Data(ax,G.status);
        end
        decorateStage3Axis(ax,'Time from slow-phase origin (ms)','Residual (pp)');
        title(ax,sprintf('%s: %s',titleCase(names(g)),label));
    end
end

% 09: phase-level errors, with polarity visible in the combined group.
fig = newStage3Figure('09 Droop phase errors',[1280 1050],cfg);
tl = tiledlayout(fig,3,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Whole-phase passive-droop errors', ...
    'Each point is one complete phase evaluated against the selected training fit');
for g = 1:3
    G = S.(names(g)); ax = nexttile(tl); hold(ax,'on');
    if G.available
        plotPhaseErrors(ax,G,palette);
        legend(ax,'show','Location','eastoutside','AutoUpdate','off');
    else
        noStage3Data(ax,G.status);
    end
    decorateStage3Axis(ax,'Phase-start command event','Phase RMSE (pp)');
    title(ax,droopGroupHeading(S,names(g)));
end

% 10: state both pooling gates in percentage points.
fig = newStage3Figure('10 Droop pooling decision',[1280 850],cfg);
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Shared passive-droop model decision',char(S.comparison.reason));
C = S.comparison;
ax = nexttile(tl); hold(ax,'on');
b = bar(ax,100*[C.trainingMeanRMSE S.config.poolMeanRMSETolerance; ...
    C.trainingMeanMaxDifference S.config.poolMeanMaxTolerance]);
set(b(1),'FaceColor',palette.blue,'DisplayName','Measured');
set(b(2),'FaceColor',palette.gray,'DisplayName','Allowed');
xticks(ax,[1 2]); xticklabels(ax,{'Mean-curve RMSE','Maximum mean difference'});
decorateStage3Axis(ax,'Training-curve gate','Difference (pp)');
title(ax,sprintf('Gate 1: curve shape, %s',passLabel(C.shapePassed)));
legend(ax,'show','Location','eastoutside','AutoUpdate','off');

ax = nexttile(tl); hold(ax,'on');
b = bar(ax,100*[C.positiveSeparateRMSE C.positiveSharedRMSE; ...
    C.negativeSeparateRMSE C.negativeSharedRMSE]);
set(b(1),'FaceColor',palette.blue,'DisplayName','Separate model');
set(b(2),'FaceColor',palette.orange,'DisplayName','Shared trial');
plot(ax,[1 2],100*[C.positiveAllowedRMSE C.negativeAllowedRMSE], ...
    'kd','MarkerFaceColor','k','MarkerSize',7,'LineStyle','none', ...
    'DisplayName','Maximum allowed shared RMSE');
xticks(ax,[1 2]); xticklabels(ax,{'Positive held-out','Negative held-out'});
decorateStage3Axis(ax,'Polarity validation gate','Whole-phase RMSE (pp)');
title(ax,sprintf('Gate 2: both polarities, %s',passLabel(C.validationPassed)));
legend(ax,'show','Location','eastoutside','AutoUpdate','off');

% 11: one compact audit view, using lanes for polarity and marker for split.
fig = newStage3Figure('11 Droop phase partitions',[1280 600],cfg);
tl = tiledlayout(fig,1,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Passive-droop phase partitions', ...
    'Deterministic whole-phase split; rejected columns remain visible in the audit');
ax = nexttile(tl); hold(ax,'on');
for g = 1:2
    G = S.(names(g));
    y = 3-g;
    plotPartitionMarkers(ax,G,y,palette);
end
yticks(ax,[1 2]); yticklabels(ax,{'Negative','Positive'}); ylim(ax,[.5 2.5]);
decorateStage3Axis(ax,'Phase-start command event','Polarity');
title(ax,sprintf('Positive: %d train, %d held-out, %d rejected | Negative: %d train, %d held-out, %d rejected', ...
    S.positive.Ntraining,S.positive.Nvalidation,numel(S.positive.rejectedColumns), ...
    S.negative.Ntraining,S.negative.Nvalidation,numel(S.negative.rejectedColumns)));
legend(ax,'show','Location','eastoutside','AutoUpdate','off');

% 12: explicitly show the complexity-tolerance selection rule.
fig = newStage3Figure('12 Droop model selection',[1320 1000],cfg);
tl = tiledlayout(fig,3,1,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Passive-droop model selection', ...
    'The fewest-parameter model within the validation tolerance is selected');
for g = 1:3
    G = S.(names(g)); ax = nexttile(tl); hold(ax,'on');
    if G.available
        train = 100*[G.candidates.trainingRMSE].';
        val = 100*[G.candidates.validationRMSE].';
        b = bar(ax,[train val]);
        set(b(1),'FaceColor',palette.blue,'DisplayName','Training RMSE');
        set(b(2),'FaceColor',palette.orange,'DisplayName','Held-out RMSE');
        eligible = [G.candidates.isPhysical].' & [G.candidates.converged].' & isfinite(val);
        cutoff = min(val(eligible))+100*G.selectionToleranceUsed;
        yline(ax,cutoff,'--','Color',palette.purple,'LineWidth',1.4, ...
            'DisplayName',sprintf('Eligibility cutoff %.3f pp',cutoff));
        scatter(ax,G.bestIndex,val(G.bestIndex),90,'pentagram', ...
            'MarkerFaceColor',palette.green,'MarkerEdgeColor',palette.black, ...
            'DisplayName',sprintf('Selected: %s',prettyModelName(G.best.modelName)));
        labels = strings(numel(G.candidates),1);
        for m = 1:numel(G.candidates)
            labels(m) = sprintf('%s (%d parameter%s)', ...
                prettyModelName(G.candidates(m).modelName), ...
                G.candidates(m).parameterCount,pluralS(G.candidates(m).parameterCount));
        end
        xticks(ax,1:numel(labels)); xticklabels(ax,cellstr(labels));
        decorateStage3Axis(ax,'Candidate model','RMSE (pp)');
        title(ax,sprintf('%s: selected %s within %.3f pp of the lowest validation RMSE', ...
            titleCase(names(g)),prettyModelName(G.best.modelName), ...
            100*G.selectionToleranceUsed));
        legend(ax,'show','Location','eastoutside','AutoUpdate','off');
    else
        noStage3Data(ax,G.status);
    end
end

% 13: expose repeatable residual structure without smoothing it.
fig = newStage3Figure('13 Droop residual structure',[1400 1080],cfg);
tl = tiledlayout(fig,3,2,'TileSpacing','compact','Padding','compact');
layoutHeading(tl,'Held-out residual structure by candidate model', ...
    'Mean residuals are shown directly, with no smoothing or filtering');
for g = 1:3
    G = S.(names(g));
    for panel = 1:2
        ax = nexttile(tl,2*g-2+panel); hold(ax,'on');
        if G.available
            allMeanResiduals = [];
            for m = 1:numel(G.candidates)
                Cmodel = G.candidates(m);
                if ~Cmodel.isPhysical || isempty(Cmodel.validationResidual), continue; end
                meanResidual_pp = 100*mean(Cmodel.validationResidual,2);
                allMeanResiduals = [allMeanResiduals meanResidual_pp]; %#ok<AGROW>
                width = 1.5;
                if m==G.bestIndex, width=2.2; end
                plot(ax,G.time_ms,meanResidual_pp,'Color',palette.model(m,:), ...
                    'LineWidth',width,'DisplayName',prettyModelName(Cmodel.modelName));
            end
            yline(ax,0,':','Color',[.35 .35 .35],'HandleVisibility','off');
            if panel==1
                xlim(ax,[G.time_ms(1) G.time_ms(end)]);
                viewLabel = 'full interval';
                residualForLimit = allMeanResiduals;
            else
                zoom = sort(cfg.droopResidualZoom_ms(:).');
                zoom(1) = max(zoom(1),G.time_ms(1));
                zoom(2) = min(zoom(2),G.time_ms(end));
                if zoom(2)<=zoom(1), zoom=[G.time_ms(1) G.time_ms(end)]; end
                xlim(ax,zoom); viewLabel = sprintf('zoom %.2f to %.2f ms',zoom(1),zoom(2));
                zoomMask = G.time_ms>=zoom(1) & G.time_ms<=zoom(2);
                residualForLimit = allMeanResiduals(zoomMask,:);
            end
            setSymmetricResidualLimit(ax,residualForLimit,.04);
            legend(ax,'show','Location','eastoutside','AutoUpdate','off');
        else
            viewLabel = 'unavailable'; noStage3Data(ax,G.status);
        end
        decorateStage3Axis(ax,'Time from slow-phase origin (ms)','Mean residual (pp)');
        title(ax,sprintf('%s: %s',titleCase(names(g)),viewLabel));
    end
end
end

function plotPhaseErrors(ax,G,palette)
trainRows = find(G.trainingMask);
valRows = find(G.validationMask);
if G.groupName=="combined"
    polarities = ["positive","negative"];
    for p = 1:2
        trainSelect = string(G.phaseAudit.Polarity(trainRows))==polarities(p);
        valSelect = string(G.phaseAudit.Polarity(valRows))==polarities(p);
        scatter(ax,G.phaseAudit.StartEvent(trainRows(trainSelect)), ...
            100*G.best.trainingPhaseRMSE(trainSelect),35, ...
            'MarkerEdgeColor',palette.polarity(p,:), ...
            'DisplayName',sprintf('%s training',titleCase(polarities(p))));
        scatter(ax,G.phaseAudit.StartEvent(valRows(valSelect)), ...
            100*G.best.validationPhaseRMSE(valSelect),45, ...
            'MarkerFaceColor',palette.polarity(p,:), ...
            'MarkerEdgeColor',palette.polarity(p,:), ...
            'DisplayName',sprintf('%s held-out',titleCase(polarities(p))));
    end
else
    scatter(ax,G.phaseAudit.StartEvent(trainRows),100*G.best.trainingPhaseRMSE, ...
        35,'MarkerEdgeColor',palette.blue,'DisplayName','Training');
    scatter(ax,G.phaseAudit.StartEvent(valRows),100*G.best.validationPhaseRMSE, ...
        45,'MarkerFaceColor',palette.orange,'MarkerEdgeColor',palette.orange, ...
        'DisplayName','Held-out');
end
if ~isempty(G.best.validationPhaseRMSE)
    [worst,index] = max(G.best.validationPhaseRMSE);
    scatter(ax,G.phaseAudit.StartEvent(valRows(index)),100*worst,100,'diamond', ...
        'MarkerEdgeColor',palette.red,'LineWidth',1.5, ...
        'DisplayName',sprintf('Largest held-out: %.3f pp',100*worst));
end
grid(ax,'on');
end

function plotPartitionMarkers(ax,G,y,palette)
parts = ["training","validation","rejected"];
markers = {'o','s','x'};
labels = {'Training','Held-out','Rejected'};
for p = 1:3
    mask = string(G.phaseAudit.Partition)==parts(p);
    if ~any(mask), continue; end
    display = labels{p};
    if y==1, display=''; end
    args = {'Marker',markers{p},'LineStyle','none','MarkerSize',7, ...
        'Color',palette.partition(p,:)};
    if p<3, args=[args {'MarkerFaceColor',palette.partition(p,:)}]; end %#ok<AGROW>
    if strlength(string(display))==0
        args=[args {'HandleVisibility','off'}]; %#ok<AGROW>
    else
        args=[args {'DisplayName',display}]; %#ok<AGROW>
    end
    plot(ax,G.phaseAudit.StartEvent(mask),repmat(y,nnz(mask),1),args{:});
end
end

function plotTraceFamily(ax,t,Y,color,label)
if isempty(Y), return; end
for k = 1:size(Y,2)
    h = plot(ax,t,Y(:,k),'Color',color,'LineWidth',.7,'HandleVisibility','off');
    if k==1
        set(h,'HandleVisibility','on','DisplayName',label);
    end
end
end

function fig = newStage3Figure(name,dimensions,cfg)
fig = figure('Name',name,'Visible','off','WindowStyle','normal', ...
    'Color','w','NumberTitle','off','Units','pixels', ...
    'Position',[50 50 dimensions], ...
    'DefaultTextInterpreter','none','DefaultTextColor',[.1 .1 .1], ...
    'DefaultTextFontSize',cfg.fontSize, ...
    'DefaultAxesColor','w','DefaultAxesXColor',[.1 .1 .1], ...
    'DefaultAxesYColor',[.1 .1 .1],'DefaultAxesFontSize',cfg.fontSize);
end

function layoutHeading(tl,mainText,subText)
title(tl,{char(mainText);char(subText)},'Color',[.08 .08 .08], ...
    'FontWeight','bold','Interpreter','none');
end

function decorateStage3Axis(ax,xText,yText)
grid(ax,'on'); box(ax,'on');
xlabel(ax,xText,'Interpreter','none'); ylabel(ax,yText,'Interpreter','none');
ax.GridColor=[.55 .55 .55]; ax.GridAlpha=.25; ax.Layer='top';
end

function addResponseGuides(ax)
for level = [.1 .5 .9]
    yline(ax,level,':','Color',[.70 .70 .70],'HandleVisibility','off');
end
end

function y = vectorOnFitWindow(fullTime,fullVector,fitTime)
fullTime = fullTime(:); fullVector = fullVector(:); fitTime = fitTime(:);
if numel(fullVector)==numel(fitTime) && max(abs(fullTime-fitTime),[],'omitnan')<1e-9
    y = fullVector;
else
    y = interp1(fullTime,fullVector,fitTime,'linear',NaN);
end
end

function tightYFromLines(ax,minimumHalfRange)
objects = findall(ax,'-property','YData'); values=[];
for k = 1:numel(objects)
    v = get(objects(k),'YData');
    if isnumeric(v), values=[values;v(:)]; end %#ok<AGROW>
end
values=values(isfinite(values));
if isempty(values), return; end
lo=min(values); hi=max(values); pad=max(.08*(hi-lo),minimumHalfRange);
if hi==lo, lo=lo-minimumHalfRange; hi=hi+minimumHalfRange; end
ylim(ax,[lo-pad hi+pad]);
end

function setSymmetricResidualLimit(ax,Y,minimumHalfRange)
v=abs(Y(isfinite(Y)));
if isempty(v), limit=minimumHalfRange;
else, limit=max(1.08*max(v),minimumHalfRange); end
ylim(ax,[-limit limit]);
end

function textValue = droopGroupHeading(S,name)
G = S.(name);
if name=="combined"
    if S.comparison.accepted, suffix='shared model accepted';
    elseif G.available, suffix='pooling trial';
    else, suffix='not fitted'; end
else
    suffix=char(prettyModelName(G.best.modelName));
end
textValue=sprintf('%s: %s | %d training, %d held-out', ...
    titleCase(name),suffix,G.Ntraining,G.Nvalidation);
end

function noStage3Data(ax,label)
text(ax,.5,.5,char(label),'Units','normalized','HorizontalAlignment','center', ...
    'Interpreter','none','Color',[.45 .1 .1]);
end

function result = passLabel(value)
if value, result='passed'; else, result='failed'; end
end

function result = pluralS(count)
if count==1, result=''; else, result='s'; end
end

function result = titleCase(value)
value=char(value);
if isempty(value), result=value; return; end
result=[upper(value(1)) value(2:end)];
end

function result = prettyModelName(value)
switch string(value)
    case "FOP", result="First order";
    case "TWO_POLE", result="Two pole";
    case "SECOND_ORDER", result="Second order";
    case "LINEAR", result="Linear";
    case "QUADRATIC", result="Quadratic";
    case "SIMPLE_EXP", result="Simple exponential";
    otherwise, result=replace(string(value),'_',' ');
end
end

function P = stage3Palette()
P=struct();
P.black=[.08 .08 .08]; P.gray=[.38 .42 .46];
P.blue=[.00 .35 .64]; P.orange=[.85 .33 .10];
P.green=[.05 .52 .32]; P.purple=[.45 .24 .65]; P.red=[.72 .08 .12];
P.lightBlue=[.62 .78 .90]; P.lightOrange=[.94 .76 .62];
P.model=[P.blue;P.green;P.orange];
P.polarity=[P.blue;P.orange];
P.class=[P.green;P.blue;P.orange;P.purple];
P.partition=[P.blue;P.orange;P.red];
end

function manifest = exportStage3Figures(folder,resolution,windowStyle,visible,saveEditable)
names=["01 Delay model";"02 Fast candidate fits";"03 Fast validation"; ...
    "04 Fast direction comparison";"05 Droop candidate fits"; ...
    "06 Droop positive negative";"07 Droop held out validation"; ...
    "08 Droop residuals";"09 Droop phase errors";"10 Droop pooling decision"; ...
    "11 Droop phase partitions";"12 Droop model selection"; ...
    "13 Droop residual structure"];
stems=["01_DelayModel";"02_FastCandidateFits";"03_FastValidation"; ...
    "04_FastDirectionComparison";"05_DroopCandidateFits"; ...
    "06_DroopPositiveNegativeFits";"07_DroopHeldOutValidation"; ...
    "08_DroopResiduals";"09_DroopPhaseErrors";"10_DroopPoolingDecision"; ...
    "11_DroopPhasePartitions";"12_DroopModelSelection"; ...
    "13_DroopResidualStructure"];
pngSaved=false(numel(names),1); figSaved=false(numel(names),1);
details=strings(numel(names),1); figs=findall(groot,'Type','figure');
for k=1:numel(names)
    matching=[];
    for j=1:numel(figs)
        if string(get(figs(j),'Name'))==names(k), matching=figs(j); break; end
    end
    if isempty(matching), details(k)="Figure not created"; continue; end
    fig=matching; styleStage3Figure(fig);
    drawnow;
    try
        exportgraphics(fig,fullfile(folder,stems(k)+".png"), ...
            'Resolution',resolution,'BackgroundColor','white');
        pngSaved(k)=true;
    catch ME
        details(k)="PNG export failed: "+string(ME.message);
        warning('Stage3:PNGExport','%s: %s',stems(k),ME.message);
    end
    if strcmpi(visible,'on')
        try
            set(fig,'WindowStyle',char(windowStyle),'Visible','on');
        catch ME
            details(k)=details(k)+" Display failed: "+string(ME.message);
            warning('Stage3:FigureDisplay','%s: %s',stems(k),ME.message);
        end
    end
    if saveEditable
        try
            savefig(fig,fullfile(folder,stems(k)+".fig")); figSaved(k)=true;
        catch ME
            details(k)=details(k)+" FIG export failed: "+string(ME.message);
            warning('Stage3:FIGExport','%s: %s',stems(k),ME.message);
        end
    end
    if strcmpi(visible,'off'), close(fig); end
end
manifest=table(stems,pngSaved,figSaved,details, ...
    'VariableNames',{'Figure','PNGSaved','FIGSaved','Details'});
writetable(manifest,fullfile(folder,'Stage3FigureManifest.csv'));
fprintf('Stage 3 diagnostic PNG exports: %d / %d\n',nnz(pngSaved),numel(names));
end

function styleStage3Figure(fig)
set(fig,'Color','w');
axesHandles=findall(fig,'Type','axes');
set(axesHandles,'Color','w','XColor',[.1 .1 .1],'YColor',[.1 .1 .1], ...
    'GridColor',[.55 .55 .55],'GridAlpha',.25);
for j=1:numel(axesHandles)
    if isprop(axesHandles(j),'Toolbar'), axesHandles(j).Toolbar.Visible='off'; end
end
set(findall(fig,'Type','text'),'Color',[.1 .1 .1],'Interpreter','none');
set(findall(fig,'Type','legend'),'Color','w','TextColor',[.1 .1 .1], ...
    'Interpreter','none','AutoUpdate','off');
layouts=findall(fig,'-isa','matlab.graphics.layout.TiledChartLayout');
for j=1:numel(layouts), layouts(j).Title.Color=[.08 .08 .08]; end
end

%% HARDCODED INPUT DIAGNOSTICS ===========================================

function verifyHardcodedInputs(paths,sourceLabel,projectFolder)
paths = string(paths(:));
missing = ~isfile(paths);
if ~any(missing), return; end

fprintf(2,'\n============================================================\n');
fprintf(2,'HARDCODED INPUT ERROR: %s\n',sourceLabel);
fprintf(2,'============================================================\n');
fprintf(2,'Current MATLAB folder:\n%s\n',pwd);
fprintf(2,'Configured project folder:\n%s\n',projectFolder);
for k = 1:numel(paths)
    status = "FOUND";
    if missing(k), status = "MISSING"; end
    fprintf(2,'[%s] %s\n',status,paths(k));
end
printFolderListing(fileparts(paths(1)));
error('OpenXstim:MissingHardcodedInput', ...
    '%s are missing. Run Stage 2 first or correct PROJECT_FOLDER in USER SETTINGS.', ...
    sourceLabel);
end

function printFolderListing(folder)
if ~isfolder(folder)
    fprintf(2,'Expected input folder does not exist:\n%s\n',folder);
    [parent,~,~] = fileparts(folder);
    if isfolder(parent)
        fprintf(2,'Contents of its existing parent folder:\n%s\n',parent);
        entries = dir(parent);
    else
        return;
    end
else
    fprintf(2,'Contents of expected input folder:\n%s\n',folder);
    entries = dir(folder);
end
names = string({entries.name});
names = names(names~="." & names~="..");
if isempty(names)
    fprintf(2,'  <empty>\n');
else
    for k = 1:numel(names)
        fprintf(2,'  %s\n',names(k));
    end
end
end
