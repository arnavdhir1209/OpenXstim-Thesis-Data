%% Stage6A_StatisticalModelReduction.m
% OPENXSTIM SUPPORTING ANALYSIS 6A
% STATISTICAL EVIDENCE FOR MODEL REDUCTION
%
% Purpose
% -------
% Stage 6 compared local, common, current-dependent, and regime-based plant
% architectures using engineering RMSE criteria. Stage 6A quantifies how
% stable those RMSE differences are before Stage 7 commits them to Simulink.
%
% This stage deliberately treats commanded-current level as the statistical
% unit because Stage 6 itself gives equal weight to current levels. It does
% NOT treat individual oscilloscope samples as independent observations.
%
% Primary statistical tools
% -------------------------
% 1. Paired nonparametric bootstrap of current-level losses.
% 2. Exact paired sign-flip/randomization tests on current-level loss
%    differences.
% 3. Practical non-inferiority/equivalence checks using the engineering
%    tolerances already declared in Stage 6.
% 4. Holm correction for the multiple pairwise comparisons within each
%    subsystem.
%
% Secondary sensitivity tests
% ---------------------------
% If Statistics and Machine Learning Toolbox functions are available,
% paired t-test and Wilcoxon signed-rank p-values are also reported. They are
% sensitivity checks only, not the primary decision rule.
%
% Why no Diebold-Mariano test?
% ----------------------------
% These are not competing stochastic time-series forecasts. Waveform samples
% within each physical transition are strongly correlated, so applying a
% forecast test sample-by-sample would create pseudo-replication.
%
% Important limitation
% --------------------
% FAST, DROOP, and COLLAPSE architecture losses are the Stage 6 observed
% current-level approximation errors. Their bootstrap therefore quantifies
% stability across the measured current range, not generalisation to an
% unseen future current. STATIC and DELAY additionally use leave-one-current-
% out predictions where those architectures are naturally identifiable.
%
% Required input
% --------------
% Matlab Analysis/
%   Stage6_ModelUnification/
%       Stage6ModelUnificationResults.mat
%
% Required helper files beside this script
% ----------------------------------------
%   OpenXstimPlant6A_Statistics.m
%   OpenXstimPlant6A_PlotDiagnostics.m
%
% Main outputs
% ------------
% Stage6A_StatisticalModelReduction/
%   Stage6AStatisticalResults.mat
%   Stage6A_StaticArchitectureStats.csv
%   Stage6A_StaticPairwiseStats.csv
%   Stage6A_FastArchitectureStats.csv
%   Stage6A_FastPairwiseStats.csv
%   Stage6A_DelayArchitectureStats.csv
%   Stage6A_DelayPairwiseStats.csv
%   Stage6A_DroopArchitectureStats.csv
%   Stage6A_DroopPairwiseStats.csv
%   Stage6A_CollapseArchitectureStats.csv
%   Stage6A_CollapsePairwiseStats.csv
%   Stage6A_ModelReductionEvidence.csv
%   numbered diagnostic figures

clear;
clc;
close all;

%% USER SETTINGS ==========================================================

cfg = struct();

cfg.DATA_ROOT = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.

cfg.ANALYSIS_FOLDER = fullfile(cfg.DATA_ROOT,"Matlab Analysis");

cfg.STAGE6_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage6_ModelUnification", ...
    "Stage6ModelUnificationResults.mat");

cfg.OUTPUT_FOLDER = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage6A_StatisticalModelReduction");

cfg.OVERWRITE_EXISTING_OUTPUT = true;

% Reproducible bootstrap.
cfg.RNG_SEED = 42;

% 20,000 is cheap here because Stage 6A resamples already-computed
% current-level losses rather than refitting nonlinear models.
cfg.N_BOOTSTRAP = 20000;

cfg.CONFIDENCE_LEVEL = 0.95;

% Optional classical sensitivity tests.
cfg.RUN_PARAMETRIC_SENSITIVITY = true;
cfg.RUN_SIGNRANK_SENSITIVITY = true;

% Plot settings.
cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;

%% CHECK INPUT ============================================================

if ~isfile(cfg.STAGE6_FILE)
    error("Stage 6 result file not found:\n%s",cfg.STAGE6_FILE);
end

requiredHelpers = [ ...
    "OpenXstimPlant6A_Statistics.m", ...
    "OpenXstimPlant6A_PlotDiagnostics.m"];

for k = 1:numel(requiredHelpers)
    p = fullfile(cfg.ANALYSIS_FOLDER,requiredHelpers(k));
    if ~isfile(p)
        error("Required Stage 6A helper is missing:\n%s",p);
    end
end

%% PREPARE OUTPUT =========================================================

if isfolder(cfg.OUTPUT_FOLDER)
    if cfg.OVERWRITE_EXISTING_OUTPUT
        fprintf("Replacing existing Stage 6A output folder:\n%s\n\n", ...
            cfg.OUTPUT_FOLDER);
        rmdir(cfg.OUTPUT_FOLDER,'s');
    else
        error("Stage 6A output folder already exists:\n%s",cfg.OUTPUT_FOLDER);
    end
end

mkdir(cfg.OUTPUT_FOLDER);

%% LOAD STAGE 6 ===========================================================

S6 = load(cfg.STAGE6_FILE);

if ~isfield(S6,"results")
    error("Stage 6 MAT file must contain variable 'results'.");
end

stage6 = S6.results;

if ~isfield(stage6,"cfg")
    error("Stage 6 results do not contain the Stage 6 configuration.");
end

stage6cfg = stage6.cfg;

% Reuse the exact engineering tolerances that Stage 6 used.
cfg.SIMPLICITY_RELATIVE_RMSE_TOL = ...
    stage6cfg.SIMPLICITY_RELATIVE_RMSE_TOL;

cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO = ...
    stage6cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO;

if isfield(stage6cfg,"WORST_CURRENT_RELATIVE_TOL")
    cfg.WORST_CURRENT_RELATIVE_TOL = ...
        stage6cfg.WORST_CURRENT_RELATIVE_TOL;
else
    cfg.WORST_CURRENT_RELATIVE_TOL = NaN;
end

rng(cfg.RNG_SEED,'twister');

fprintf("============================================================\n");
fprintf("OPENXSTIM STAGE 6A: STATISTICAL MODEL-REDUCTION EVIDENCE\n");
fprintf("============================================================\n");
fprintf("Stage 6 source                : %s\n",cfg.STAGE6_FILE);
fprintf("Bootstrap replicates          : %d\n",cfg.N_BOOTSTRAP);
fprintf("Confidence level              : %.1f %%\n",100*cfg.CONFIDENCE_LEVEL);
fprintf("Simplicity RMSE tolerance     : %.1f %%\n", ...
    100*cfg.SIMPLICITY_RELATIVE_RMSE_TOL);
fprintf("Maximum unified/local ratio   : %.3f\n\n", ...
    cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO);

fprintf("Primary inference:\n");
fprintf("  paired current-level bootstrap + exact sign-flip test.\n");
fprintf("  Individual waveform samples are NOT treated as independent N.\n\n");

%% RUN STATISTICAL ANALYSIS ==============================================

stats = OpenXstimPlant6A_Statistics(stage6,cfg);

stats.processingStage = "Stage6A_StatisticalModelReduction";
stats.sourceStage6 = cfg.STAGE6_FILE;
stats.created = datetime('now');
stats.settings = cfg;

%% SAVE TABLES ============================================================

writeIfTable(stats.static.architecture, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_StaticArchitectureStats.csv"));

writeIfTable(stats.static.pairwise, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_StaticPairwiseStats.csv"));

writeIfTable(stats.fast.architecture, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_FastArchitectureStats.csv"));

writeIfTable(stats.fast.pairwise, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_FastPairwiseStats.csv"));

writeIfTable(stats.delay.architecture, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_DelayArchitectureStats.csv"));

writeIfTable(stats.delay.pairwise, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_DelayPairwiseStats.csv"));

writeIfTable(stats.droop.architecture, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_DroopArchitectureStats.csv"));

writeIfTable(stats.droop.pairwise, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_DroopPairwiseStats.csv"));

writeIfTable(stats.collapse.architecture, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_CollapseArchitectureStats.csv"));

writeIfTable(stats.collapse.pairwise, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_CollapsePairwiseStats.csv"));

writeIfTable(stats.evidenceTable, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6A_ModelReductionEvidence.csv"));

save( ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6AStatisticalResults.mat"), ...
    "stats","cfg","-v7.3");

%% PLOTS ==================================================================

OpenXstimPlant6A_PlotDiagnostics(stats,cfg);

%% CONSOLE SUMMARY ========================================================

fprintf("\n============================================================\n");
fprintf("STAGE 6A COMPLETE\n");
fprintf("============================================================\n\n");

fprintf("MODEL-REDUCTION EVIDENCE SUMMARY\n");
disp(stats.evidenceTable);

fprintf("\nFAST DYNAMICS\n");
disp(stats.fast.architecture);
disp(stats.fast.pairwise);

fprintf("\nORDINARY DROOP\n");
disp(stats.droop.architecture);
disp(stats.droop.pairwise);

fprintf("\nCOMPLIANCE COLLAPSE\n");
disp(stats.collapse.architecture);
disp(stats.collapse.pairwise);

fprintf("\nInterpretation notes:\n");
fprintf("  1. A bootstrap CI for a paired RMSE difference is more useful than\n");
fprintf("     comparing overlap between separate RMSE confidence intervals.\n");
fprintf("  2. A non-significant difference does NOT prove equivalence.\n");
fprintf("  3. Practical model reduction is supported only when the simpler model\n");
fprintf("     also satisfies the declared Stage 6 engineering margin.\n");
fprintf("  4. With only three collapse-current levels, the minimum attainable\n");
fprintf("     two-sided exact sign-flip p-value is 0.25. Collapse decisions must\n");
fprintf("     therefore rely heavily on effect size, uncertainty, physics, and\n");
fprintf("     model complexity rather than p<0.05 alone.\n");
fprintf("  5. Stage 6A does not overwrite any Stage 5 or Stage 6 decision.\n\n");

fprintf("Saved to:\n%s\n",cfg.OUTPUT_FOLDER);

%% LOCAL HELPER ===========================================================

function writeIfTable(T,path)
if istable(T) && ~isempty(T)
    writetable(T,path);
end
end
