%% Stage6_UnifyOpenXstimPlant.m
% OPENXSTIM PIPELINE STAGE 6
% MODEL UNIFICATION, REGIME GROUPING, AND MODEL-REDUCTION TESTING
%
% Purpose
% -------
% Stage 5 deliberately identified each commanded-current level independently.
% Stage 6 now asks which of those local models can be merged without losing
% important predictive accuracy.
%
% This stage DOES NOT build the Simulink plant. That is Stage 7.
%
% Main questions
% --------------
% 1. Static scale:
%      Is one constant gain enough, or is a smooth nonlinear calibration law
%      justified by the measured current sweep?
%
% 2. Fast dynamics:
%      Can all physical fast responses share one model?
%      If not, can clean FULL_REVERSAL and high-current NEAR_ZERO_START
%      responses each share one regime model?
%
% 3. Delay:
%      Which firmware transition classes can use a common delay law?
%      IMPORTANT: physical fast regime is kept separate from firmware class.
%
% 4. Ordinary droop:
%      Is one common linear droop rate sufficient?
%      Does a two-group low/high-current droop description materially improve
%      the pre-collapse fit?
%
% 5. Compliance collapse:
%      Can 20/30/50 mA share one charge-state collapse law?
%      Does a transition/strong-collapse split work better?
%      Is a simple current-dependent threshold worth carrying forward?
%
% Important interpretation note
% -----------------------------
% Static amplitude dependence is treated as EMPIRICAL CALIBRATION only.
% A fitted nonlinear current scale does not by itself prove intrinsic
% nonlinear gain. Finite output impedance, resistor heating, calibration,
% compliance headroom, and other experimental effects may contribute.
%
% Required Stage 5 input
% ----------------------
%   Stage5_PlantIdentification/Stage5PerCurrentPlantModels.mat
%
% Required helper files in the same Matlab Analysis folder
% --------------------------------------------------------
%   OpenXstimPlant6_CompareModels.m
%   OpenXstimPlant6_PlotDiagnostics.m
%
% Outputs
% -------
%   Stage6_ModelUnification/
%       Stage6ModelUnificationResults.mat
%       Stage6_StaticCandidates.csv
%       Stage6_FastArchitectureCandidates.csv
%       Stage6_DelayCandidates.csv
%       Stage6_DroopCandidates.csv
%       Stage6_CollapseCandidates.csv
%       Stage6_SubsystemRecommendation.csv
%       01_Stage6MeetingSummary.png
%       02_StaticScaleUnification.png
%       03_FastDynamicsUnification.png
%       04_DelayUnification.png
%       05_DroopUnification.png
%       06_SlowBehaviourByCurrent.png
%       07_CollapseUnification.png
%       08_ModelArchitectureSummary.png
%
% Modelling philosophy
% --------------------
% The per-current Stage 5 models remain the high-flexibility reference.
% Stage 6 tests simpler common/grouped models against that reference.
% Local models are not deleted or overwritten.
%
% 30/50 mA high-current fast responses remain explicitly flagged as
% PHYSICAL NEAR_ZERO_START responses. They must not be relabelled as a
% firmware zero_to_pos transition simply because their physical pre-state
% has collapsed near zero.

clear;
clc;
close all;

%% USER SETTINGS ==========================================================

cfg = struct();

cfg.DATA_ROOT = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.

cfg.ANALYSIS_FOLDER = fullfile(cfg.DATA_ROOT,"Matlab Analysis");

cfg.STAGE5_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage5_PlantIdentification", ...
    "Stage5PerCurrentPlantModels.mat");

cfg.OUTPUT_FOLDER = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage6_ModelUnification");

cfg.OVERWRITE_EXISTING_OUTPUT = true;

cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;

% -------------------------------------------------------------------------
% CURRENT / REGIME DEFINITIONS
% -------------------------------------------------------------------------

cfg.COMMAND_CURRENTS_mApp = [5 10 15 20 30 50];

% Clean full-reversal regime identified in Stage 5.
cfg.FULL_REVERSAL_CURRENTS_mApp = [5 10 15 20];

% High-current internal transitions whose physical state has already
% collapsed near zero before the next firmware command.
cfg.NEAR_ZERO_START_CURRENTS_mApp = [30 50];

% The slow behaviour visibly changes as compliance becomes important.
cfg.ORDINARY_DOMINANT_CURRENTS_mApp = [5 10 15];
cfg.TRANSITION_COLLAPSE_CURRENT_mApp = 20;
cfg.STRONG_COLLAPSE_CURRENTS_mApp = [30 50];

% -------------------------------------------------------------------------
% MODEL REDUCTION TOLERANCES
% -------------------------------------------------------------------------
% These are practical engineering tolerances, not significance tests.
% They are intentionally visible here so the thesis can report them.

% A simpler model is considered competitive when its mean RMSE is within
% this fraction of the better candidate.
cfg.SIMPLICITY_RELATIVE_RMSE_TOL = 0.10;

% Also protect against one current becoming much worse after unification.
cfg.WORST_CURRENT_RELATIVE_TOL = 0.20;

% If the simplest unified model is far worse than the Stage 5 local
% reference, retain multiple regimes rather than forcing unification.
cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO = 1.50;

% Fast fitting window around Stage 3 gradient peak.
cfg.FAST_FIT_START_US = -6;
cfg.FAST_FIT_END_US = 18;

% Ordinary-droop fitting should stop before obvious collapse.
cfg.DROOP_DEPARTURE_THRESHOLD = 0.03;
cfg.DROOP_COLLAPSE_LEVEL = 0.90;

% Minimum samples required in a current's ordinary-droop window.
cfg.MIN_DROOP_SAMPLES = 20;

% Delay model must improve by at least this absolute amount before adding
% current dependence or a regime split.
cfg.DELAY_MIN_ABSOLUTE_IMPROVEMENT_US = 0.20;

% -------------------------------------------------------------------------
% OPTIMIZER
% -------------------------------------------------------------------------

cfg.optimOptions = optimset( ...
    'Display','off', ...
    'MaxIter',2500, ...
    'MaxFunEvals',10000, ...
    'TolX',1e-10, ...
    'TolFun',1e-11);

%% PREPARE OUTPUT =========================================================

if ~isfile(cfg.STAGE5_FILE)
    error("Stage 5 result file not found:\n%s",cfg.STAGE5_FILE);
end

if isfolder(cfg.OUTPUT_FOLDER)

    if cfg.OVERWRITE_EXISTING_OUTPUT
        fprintf("Replacing existing Stage 6 output folder:\n%s\n\n", ...
            cfg.OUTPUT_FOLDER);
        rmdir(cfg.OUTPUT_FOLDER,'s');
    else
        error("Stage 6 output folder already exists: %s",cfg.OUTPUT_FOLDER);
    end
end

mkdir(cfg.OUTPUT_FOLDER);

%% LOAD STAGE 5 ===========================================================

S5 = load(cfg.STAGE5_FILE);

[staticResult,fastResult,slowResult,stage5cfg] = ...
    resolveStage5Structures(S5);

fprintf("============================================================\n");
fprintf("OPENXSTIM STAGE 6: MODEL UNIFICATION\n");
fprintf("============================================================\n");
fprintf("Stage 5 source : %s\n",cfg.STAGE5_FILE);
fprintf("Currents       : ");
fprintf("%.0f ",cfg.COMMAND_CURRENTS_mApp);
fprintf("mA p-p\n\n");

fprintf("High-current rule:\n");
fprintf("  30/50 mA NEAR_ZERO_START remains a physical-state regime.\n");
fprintf("  It is NOT relabelled as firmware zero_to_pos.\n\n");

fprintf("Static-scale interpretation:\n");
fprintf("  empirical calibration only; finite output impedance, load heating,\n");
fprintf("  calibration and compliance effects remain plausible contributors.\n\n");

%% MODEL COMPARISON =======================================================

results = OpenXstimPlant6_CompareModels( ...
    staticResult,fastResult,slowResult,cfg);

results.cfg = cfg;
results.stage5cfg = stage5cfg;
results.stage5File = cfg.STAGE5_FILE;
results.created = datetime('now');

%% SAVE TABLES ============================================================

writeIfTable(results.static.candidates, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6_StaticCandidates.csv"));

writeIfTable(results.fast.architectureCandidates, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6_FastArchitectureCandidates.csv"));

writeIfTable(results.delay.candidates, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6_DelayCandidates.csv"));

writeIfTable(results.droop.candidates, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6_DroopCandidates.csv"));

writeIfTable(results.collapse.candidates, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6_CollapseCandidates.csv"));

writeIfTable(results.recommendationTable, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6_SubsystemRecommendation.csv"));

save( ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage6ModelUnificationResults.mat"), ...
    'results','cfg','-v7.3');

%% PLOTS ==================================================================

OpenXstimPlant6_PlotDiagnostics( ...
    staticResult,fastResult,slowResult,results,cfg);

%% CONSOLE SUMMARY ========================================================

fprintf("\n============================================================\n");
fprintf("STAGE 6 COMPLETE: MODEL REDUCTION / UNIFICATION\n");
fprintf("============================================================\n\n");

disp(results.recommendationTable);

fprintf("\nInterpretation rules for the thesis:\n");
fprintf("  1. Local Stage 5 models remain the reference.\n");
fprintf("  2. A common model is retained only if its error penalty is small.\n");
fprintf("  3. 30/50 mA physical near-zero starts remain specially flagged.\n");
fprintf("  4. Literal 0 -> +I startup remains separate from internal transitions.\n");
fprintf("  5. Slow ordinary droop and compliance collapse remain separate effects.\n");
fprintf("  6. Stage 7 will implement the selected architecture in Simulink.\n\n");

fprintf("Meeting-ready figures:\n");
fprintf("  01_Stage6MeetingSummary.png\n");
fprintf("  02_StaticScaleUnification.png\n");
fprintf("  03_FastDynamicsUnification.png\n");
fprintf("  04_DelayUnification.png\n");
fprintf("  05_DroopUnification.png\n");
fprintf("  06_SlowBehaviourByCurrent.png\n");
fprintf("  07_CollapseUnification.png\n");
fprintf("  08_ModelArchitectureSummary.png\n\n");

fprintf("Saved to:\n%s\n",cfg.OUTPUT_FOLDER);

%% LOCAL HELPERS ==========================================================

function [staticResult,fastResult,slowResult,stage5cfg] = ...
    resolveStage5Structures(S)
% Resolve the Stage 5 data robustly.
%
% The current Stage 5 pipeline may save staticResult, fastResult and
% slowResult directly, or they may sit inside a wrapper structure.  Do not
% assume one exact MAT-file layout here.  Instead, first try the direct
% names, then search recursively using the distinctive fields of each
% subsystem result.

% -------------------------------------------------------------------------
% Stage 5 configuration
% -------------------------------------------------------------------------
if isfield(S,"cfg") && isstruct(S.cfg)
    stage5cfg = S.cfg;
else
    stage5cfg = struct();
end

% -------------------------------------------------------------------------
% Fast path: expected direct variables
% -------------------------------------------------------------------------
if isfield(S,"staticResult") && ...
        isfield(S,"fastResult") && ...
        isfield(S,"slowResult")

    staticResult = S.staticResult;
    fastResult   = S.fastResult;
    slowResult   = S.slowResult;
    return;
end

% -------------------------------------------------------------------------
% Robust fallback: find the three structures by their actual contents.
% -------------------------------------------------------------------------
staticResult = findStage5StaticResult(S,0,8);
fastResult   = findStage5FastResult(S,0,8);
slowResult   = findStage5SlowResult(S,0,8);

missing = strings(0,1);

if isempty(staticResult)
    missing(end+1) = "staticResult"; %#ok<AGROW>
end

if isempty(fastResult)
    missing(end+1) = "fastResult"; %#ok<AGROW>
end

if isempty(slowResult)
    missing(end+1) = "slowResult"; %#ok<AGROW>
end

if ~isempty(missing)

    topLevel = strjoin(string(fieldnames(S)),", ");

    error( ...
        'Stage6:InvalidStage5File', ...
        ['Could not resolve the following Stage 5 structures: %s.\n' ...
         'Top-level variables found in Stage5PerCurrentPlantModels.mat: %s\n' ...
         'Stage 6 expects the per-current Stage 5 output containing the ' ...
         'static current summary, fast by-current models, and slow ' ...
         'droop/collapse models.'], ...
        strjoin(missing,", "), ...
        topLevel);
end
end

function out = findStage5StaticResult(v,depth,maxDepth)
% Find a structure whose currentSummary contains the Stage 5 static-current
% calibration columns.

out = [];

if depth>maxDepth
    return;
end

if isstruct(v)

    for n = 1:numel(v)

        if isfield(v(n),"currentSummary") && istable(v(n).currentSummary)

            names = string(v(n).currentSummary.Properties.VariableNames);
            required = ["CommandCurrent_mA","MeanMeasuredIpp_mA"];

            if all(ismember(required,names))
                out = v(n);
                return;
            end
        end

        fields = fieldnames(v(n));

        for k = 1:numel(fields)
            try
                child = v(n).(fields{k});
            catch
                continue;
            end

            out = findStage5StaticResult(child,depth+1,maxDepth);

            if ~isempty(out)
                return;
            end
        end
    end

elseif iscell(v)

    for k = 1:numel(v)
        out = findStage5StaticResult(v{k},depth+1,maxDepth);
        if ~isempty(out)
            return;
        end
    end
end
end

function out = findStage5FastResult(v,depth,maxDepth)
% Find the Stage 5 fast-dynamics result structure.

out = [];

if depth>maxDepth
    return;
end

if isstruct(v)

    for n = 1:numel(v)

        if isfield(v(n),"byCurrent") && ...
                isfield(v(n),"time_us") && ...
                isfield(v(n),"regimeCounts")
            out = v(n);
            return;
        end

        fields = fieldnames(v(n));

        for k = 1:numel(fields)
            try
                child = v(n).(fields{k});
            catch
                continue;
            end

            out = findStage5FastResult(child,depth+1,maxDepth);

            if ~isempty(out)
                return;
            end
        end
    end

elseif iscell(v)

    for k = 1:numel(v)
        out = findStage5FastResult(v{k},depth+1,maxDepth);
        if ~isempty(out)
            return;
        end
    end
end
end

function out = findStage5SlowResult(v,depth,maxDepth)
% Find the Stage 5 slow droop / compliance result structure.

out = [];

if depth>maxDepth
    return;
end

if isstruct(v)

    for n = 1:numel(v)

        if isfield(v(n),"byCurrent") && ...
                isfield(v(n),"droopSummary") && ...
                isfield(v(n),"collapseSummary")
            out = v(n);
            return;
        end

        fields = fieldnames(v(n));

        for k = 1:numel(fields)
            try
                child = v(n).(fields{k});
            catch
                continue;
            end

            out = findStage5SlowResult(child,depth+1,maxDepth);

            if ~isempty(out)
                return;
            end
        end
    end

elseif iscell(v)

    for k = 1:numel(v)
        out = findStage5SlowResult(v{k},depth+1,maxDepth);
        if ~isempty(out)
            return;
        end
    end
end
end

function writeIfTable(T,path)
if istable(T) && ~isempty(T)
    writetable(T,path);
end
end
