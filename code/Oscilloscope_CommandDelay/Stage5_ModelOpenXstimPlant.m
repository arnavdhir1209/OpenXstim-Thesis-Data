%% Stage5_ModelOpenXstimPlant.m
% OPENXSTIM PIPELINE STAGE 5
% PER-CURRENT EMPIRICAL PLANT IDENTIFICATION
%
% Revised Stage 5 philosophy:
%   Stage 5 identifies the plant LOCALLY at each commanded current.
%   Stage 6 will compare the local models and decide what can be unified.
%
% This is deliberate. We do NOT impose cross-current invariance in Stage 5.
%
% Required inputs:
%   Stage2_CurrentResponseClassification/Stage2MasterResults.mat
%   Stage3_FastTransitionNormalization/Stage3FastNormalizedTransitions.mat
%   Stage3A_FastTransitionOutlierAnalysis/Stage3A_FastTransitionAudit.mat
%   Stage4_PassivePhaseNormalization/Stage4PassivePhases.mat
%   Stage4A_CapacitorStateAnalysis/Stage4A_CapacitorStateAudit.mat
%
% Per-current model components:
%   1. Static measured current scale
%   2. Fast electrical response
%      a. FULL_REVERSAL, when physically available
%      b. NEAR_ZERO_START, special high-current regime
%      c. literal packet-start 0 -> +I as sparse boundary characterization
%   3. Command-to-fast-onset delay, separately by physical regime/class
%   4. Ordinary pre-collapse passive droop
%   5. Compliance-collapse attenuation, after ordinary droop is divided out
%
% IMPORTANT HIGH-CURRENT INTERPRETATION
% -------------------------------------
% At 30 and 50 mA, nominal bipolar commands often occur after the preceding
% phase has already collapsed near zero. They are NOT relabelled as firmware
% "zero_to_pos" commands. Instead they are identified as the physically
% distinct NEAR_ZERO_START regime:
%
%   nominal -I -> +I, but measured pre-state ~ 0  => near-zero -> +I
%   nominal +I -> -I, but measured pre-state ~ 0  => near-zero -> -I
%
% These events can legitimately identify fast electrical dynamics in the
% compliance-affected high-current operating state, provided they are kept
% separate from clean full reversals and from the literal first 0 -> +I event.
%
% Stage 6 will later test whether:
%   - the full-reversal and near-zero-start fast models can be unified,
%   - fast parameters depend on current,
%   - droop rates are invariant,
%   - one collapse-state law works across current.
%
% Stage 7 can then do full packet reconstruction and Simulink export.

clear;
clc;
close all;

%% ========================================================================
% USER SETTINGS
% ========================================================================

cfg = struct();

cfg.DATA_ROOT = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.

cfg.ANALYSIS_FOLDER = fullfile(cfg.DATA_ROOT,"Matlab Analysis");

cfg.STAGE2_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage2_CurrentResponseClassification", ...
    "Stage2MasterResults.mat");

cfg.STAGE3_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage3_FastTransitionNormalization", ...
    "Stage3FastNormalizedTransitions.mat");

cfg.STAGE3A_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage3A_FastTransitionOutlierAnalysis", ...
    "Stage3A_FastTransitionAudit.mat");

cfg.STAGE4_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage4_PassivePhaseNormalization", ...
    "Stage4PassivePhases.mat");

cfg.STAGE4A_FILE = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage4A_CapacitorStateAnalysis", ...
    "Stage4A_CapacitorStateAudit.mat");

cfg.OUTPUT_FOLDER = fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage5_PlantIdentification");

cfg.OVERWRITE_EXISTING_OUTPUT = true;

% Capture 1 was independently identified as a bad 5 mA acquisition.
cfg.EXCLUDE_CAPTURE_IDS = 1;

% Expected tested current set. The script will still use the data if this
% list is edited later.
cfg.COMMAND_CURRENTS_mApp = [5 10 15 20 30 50];

% -------------------------------------------------------------------------
% FAST ELECTRICAL MODEL
% -------------------------------------------------------------------------
cfg.FAST_FIT_START_US = -6;
cfg.FAST_FIT_END_US = 18;

cfg.FAST_MODEL_NAMES = [ ...
    "FOP"; ...
    "TWO_POLE"; ...
    "SECOND_ORDER"];

% Model selection: among candidates close to the best held-out error, prefer
% the lower parameter count.
cfg.FAST_SELECTION_ABS_TOL = 0.001;
cfg.FAST_SELECTION_REL_TOL = 0.05;

% Full-reversal / near-zero regimes need enough repeated events for primary
% model selection.
cfg.MIN_FAST_EVENTS_MODEL = 15;
cfg.MIN_FAST_CAPTURES_MODEL = 3;

% Sparse boundary events are descriptive. A model is fitted only to support
% delay/shape comparison, not to select the global family.
cfg.MIN_BOUNDARY_EVENTS_FIT = 3;

% -------------------------------------------------------------------------
% ORDINARY PASSIVE DROOP
% -------------------------------------------------------------------------
cfg.DROOP_KNEE_GUARD_US = 40;
cfg.DROOP_MIN_NORMALIZED_CURRENT = 0.80;
cfg.DROOP_MIN_SAMPLES_PER_PHASE = 20;

cfg.DROOP_MODEL_NAMES = ["LINEAR";"EXP"];

% Linear is preferred when its held-out error is effectively indistinguishable
% from exponential.
cfg.DROOP_SELECTION_ABS_TOL = 0.0010;
cfg.DROOP_SELECTION_REL_TOL = 0.05;

% -------------------------------------------------------------------------
% COMPLIANCE COLLAPSE
% -------------------------------------------------------------------------
% Collapse is modelled after dividing out the selected ordinary-droop model:
%
%   C_observed(t) = D_measured(t) / D_droop(t)
%
% This avoids asking the collapse state law to explain ordinary passive droop.
cfg.COLLAPSE_START_D = 0.90;
cfg.COLLAPSE_MIN_ATTENUATION = 0.03;
cfg.COLLAPSE_MAX_ATTENUATION = 1.05;
cfg.COLLAPSE_MIN_SAMPLES_PER_PHASE = 8;
cfg.COLLAPSE_MIN_PHASES = 10;
cfg.COLLAPSE_MIN_CAPTURES = 3;

cfg.COLLAPSE_COORDINATES = [ ...
    "PHASE_LOCAL"; ...
    "CONTINUOUS_ORIENTED"];

cfg.COLLAPSE_MODEL_NAMES = [ ...
    "SHIFTED_EXP"; ...
    "STRETCHED_EXP"];

cfg.COLLAPSE_SELECTION_ABS_TOL = 0.010;
cfg.COLLAPSE_SELECTION_REL_TOL = 0.05;

% Guard against numerically extreme stretched-exponential solutions.
cfg.COLLAPSE_POWER_MIN = 0.35;
cfg.COLLAPSE_POWER_MAX = 12.0;

% -------------------------------------------------------------------------
% OPTIMISATION / OUTPUT
% -------------------------------------------------------------------------
cfg.optimOptions = optimset( ...
    'Display','off', ...
    'MaxIter',5000, ...
    'MaxFunEvals',20000, ...
    'TolX',1e-10, ...
    'TolFun',1e-12);

cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;
cfg.MAX_COLLAPSE_SCATTER_POINTS = 4000;

%% ========================================================================
% CHECK FILES
% ========================================================================

helpers = [ ...
    "OpenXstimPlant5_FitStaticByCurrent.m", ...
    "OpenXstimPlant5_FitFastByCurrent.m", ...
    "OpenXstimPlant5_FitSlowByCurrent.m", ...
    "OpenXstimPlant5_PlotDiagnostics.m"];

for k = 1:numel(helpers)
    p = fullfile(cfg.ANALYSIS_FOLDER,helpers(k));
    if ~isfile(p)
        error("Required revised Stage 5 helper is missing:\n%s",p);
    end
end

inputs = [ ...
    cfg.STAGE2_FILE; ...
    cfg.STAGE3_FILE; ...
    cfg.STAGE3A_FILE; ...
    cfg.STAGE4_FILE; ...
    cfg.STAGE4A_FILE];

for k = 1:numel(inputs)
    if ~isfile(inputs(k))
        error("Required Stage 5 input is missing:\n%s",inputs(k));
    end
end

if cfg.OVERWRITE_EXISTING_OUTPUT && isfolder(cfg.OUTPUT_FOLDER)
    fprintf("Replacing existing Stage 5 output folder:\n%s\n",cfg.OUTPUT_FOLDER);
    rmdir(cfg.OUTPUT_FOLDER,'s');
end

if ~isfolder(cfg.OUTPUT_FOLDER)
    mkdir(cfg.OUTPUT_FOLDER);
end

%% ========================================================================
% LOAD INPUTS
% ========================================================================

S2 = load(cfg.STAGE2_FILE);
S3 = load(cfg.STAGE3_FILE);
S3A = load(cfg.STAGE3A_FILE);
S4 = load(cfg.STAGE4_FILE);
S4A = load(cfg.STAGE4A_FILE);

assert(isfield(S2,"CaptureSummary"), ...
    "Stage 2 MAT lacks CaptureSummary.");

assert(isfield(S3,"fast"), ...
    "Stage 3 MAT lacks fast.");

assert(isfield(S3A,"audit"), ...
    "Stage 3A MAT lacks audit.");

assert(isfield(S4,"passive"), ...
    "Stage 4 MAT lacks passive.");

assert(isfield(S4A,"capState"), ...
    "Stage 4A MAT lacks capState.");

CaptureSummary = S2.CaptureSummary;
fast = S3.fast;
audit = S3A.audit;
passive = S4.passive;
capState = S4A.capState;

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 5: PER-CURRENT PLANT IDENTIFICATION\n");
fprintf("============================================================\n");
fprintf("Stage 2 captures             : %d\n",height(CaptureSummary));
fprintf("Stage 3A audited events      : %d\n",height(audit.fastEventAudit));
fprintf("Stage 4 passive phases       : %d\n",height(passive.phaseMetrics));
fprintf("Stage 4A mapped phases       : %d\n",height(capState.phaseStateMetrics));
fprintf("Known excluded captures      : ");
fprintf("%d ",cfg.EXCLUDE_CAPTURE_IDS);
fprintf("\n");
fprintf("\nStage 5 rule:\n");
fprintf("  identify each current independently first;\n");
fprintf("  Stage 6 will test whether models can be unified.\n");

%% ========================================================================
% 1. STATIC CURRENT SCALE BY CURRENT
% ========================================================================

fprintf("\n============================================================\n");
fprintf("1. STATIC CURRENT SCALE BY CURRENT\n");
fprintf("============================================================\n");

staticResult = ...
    OpenXstimPlant5_FitStaticByCurrent(CaptureSummary,cfg);

disp(staticResult.currentSummary);

%% ========================================================================
% 2. FAST DYNAMICS + LOCAL DELAY BY CURRENT
% ========================================================================

fprintf("\n============================================================\n");
fprintf("2. FAST ELECTRICAL DYNAMICS BY CURRENT\n");
fprintf("============================================================\n");

fastResult = ...
    OpenXstimPlant5_FitFastByCurrent(fast,audit,cfg);

disp(fastResult.modelSummary);

fprintf("\nHIGH-CURRENT SPECIAL CASE\n");
fprintf("NEAR_ZERO_START is a PHYSICAL state category, not a relabelled\n");
fprintf("firmware zero_to_pos command. 30/50 mA may therefore contribute\n");
fprintf("fast models even when clean full reversals are unavailable.\n");

fprintf("\n============================================================\n");
fprintf("3. COMMAND-TO-FAST-ONSET DELAY BY CURRENT / REGIME\n");
fprintf("============================================================\n");

disp(fastResult.delaySummary);

%% ========================================================================
% 4. ORDINARY DROOP + 5. COLLAPSE BY CURRENT
% ========================================================================

fprintf("\n============================================================\n");
fprintf("4. ORDINARY PASSIVE DROOP BY CURRENT\n");
fprintf("============================================================\n");

slowResult = ...
    OpenXstimPlant5_FitSlowByCurrent(passive,capState,cfg);

disp(slowResult.droopSummary);

fprintf("\n============================================================\n");
fprintf("5. COMPLIANCE COLLAPSE BY CURRENT\n");
fprintf("============================================================\n");

disp(slowResult.collapseSummary);

%% ========================================================================
% ASSEMBLE ONE STRUCT PER CURRENT
% ========================================================================

currents = cfg.COMMAND_CURRENTS_mApp(:);

plantTemplate = struct( ...
    'commandCurrent_mApp',NaN, ...
    'static',table(), ...
    'fast',struct(), ...
    'delay',table(), ...
    'droop',struct(), ...
    'collapse',struct(), ...
    'validity',struct());

plantByCurrent = repmat(plantTemplate,numel(currents),1);

for k = 1:numel(currents)

    I = currents(k);

    plantByCurrent(k).commandCurrent_mApp = I;

    plantByCurrent(k).static = ...
        tableRowsForCurrent(staticResult.currentSummary,I);

    plantByCurrent(k).fast = ...
        fastResult.byCurrent(k);

    plantByCurrent(k).delay = ...
        tableRowsForCurrent(fastResult.delaySummary,I);

    plantByCurrent(k).droop = ...
        slowResult.byCurrent(k).droop;

    plantByCurrent(k).collapse = ...
        slowResult.byCurrent(k).collapse;

    plantByCurrent(k).validity = struct();

    plantByCurrent(k).validity.fullReversalFastIdentifiable = ...
        fastResult.byCurrent(k).fullReversal.identifiable;

    plantByCurrent(k).validity.nearZeroStartFastIdentifiable = ...
        fastResult.byCurrent(k).nearZeroStart.identifiable;

    plantByCurrent(k).validity.literalStartupCharacterized = ...
        fastResult.byCurrent(k).startupZeroToPos.fitted;

    plantByCurrent(k).validity.droopIdentifiable = ...
        slowResult.byCurrent(k).droop.identifiable;

    plantByCurrent(k).validity.collapseIdentifiable = ...
        slowResult.byCurrent(k).collapse.identifiable;

    if I>=30
        plantByCurrent(k).validity.highCurrentInterpretation = ...
            "Use NEAR_ZERO_START model where available. Do not call internal commands literal zero_to_pos.";
    else
        plantByCurrent(k).validity.highCurrentInterpretation = ...
            "Clean FULL_REVERSAL model is preferred when available.";
    end
end

%% ========================================================================
% SAVE TABLES
% ========================================================================

writeIfNonempty(staticResult.captureTable, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_StaticCaptureMetrics.csv"));

writeIfNonempty(staticResult.currentSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_StaticByCurrent.csv"));

writeIfNonempty(fastResult.regimeCounts, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_FastPhysicalRegimeCounts.csv"));

writeIfNonempty(fastResult.modelSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_FastModelSummary.csv"));

writeIfNonempty(fastResult.candidateSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_FastCandidateSummary.csv"));

writeIfNonempty(fastResult.crossValidation, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_FastCrossValidation.csv"));

writeIfNonempty(fastResult.directionSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_FastDirectionSummary.csv"));

writeIfNonempty(fastResult.boundarySummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_FastBoundarySummary.csv"));

writeIfNonempty(fastResult.delaySummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_DelayByCurrentAndRegime.csv"));

writeIfNonempty(slowResult.droopSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_DroopModelSummary.csv"));

writeIfNonempty(slowResult.droopCandidates, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_DroopCandidateSummary.csv"));

writeIfNonempty(slowResult.droopCrossValidation, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_DroopCrossValidation.csv"));

writeIfNonempty(slowResult.droopPolaritySummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_DroopPolaritySummary.csv"));

writeIfNonempty(slowResult.collapseSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_CollapseModelSummary.csv"));

writeIfNonempty(slowResult.collapseCandidates, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_CollapseCandidateSummary.csv"));

writeIfNonempty(slowResult.collapseCrossValidation, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_CollapseCrossValidation.csv"));

writeIfNonempty(slowResult.phaseAudit, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5_SlowPhaseAudit.csv"));

%% ========================================================================
% SAVE MAT
% ========================================================================

stage5 = struct();

stage5.processingStage = ...
    "Stage5_ModelOpenXstimPlant_PER_CURRENT";

stage5.architecture = ...
    "Per-current identification. Cross-current unification intentionally deferred to Stage 6.";

stage5.sourceStage2 = cfg.STAGE2_FILE;
stage5.sourceStage3 = cfg.STAGE3_FILE;
stage5.sourceStage3A = cfg.STAGE3A_FILE;
stage5.sourceStage4 = cfg.STAGE4_FILE;
stage5.sourceStage4A = cfg.STAGE4A_FILE;

stage5.static = staticResult;
stage5.fast = fastResult;
stage5.slow = slowResult;
stage5.plantByCurrent = plantByCurrent;
stage5.settings = cfg;

stage5.notes = [ ...
    "30/50 mA nominal bipolar commands may be modelled as NEAR_ZERO_START only when Stage 3A verifies a near-zero pre-state and healthy opposite-polarity post-state."; ...
    "NEAR_ZERO_START is not the same thing as the literal packet-start zero_to_pos firmware command."; ...
    "Full-reversal and near-zero-start fast models remain separate in Stage 5."; ...
    "Compliance collapse is fitted after dividing out the selected ordinary-droop model."; ...
    "Continuous oriented charge is a relative capacitor-state proxy, not absolute capacitor voltage."; ...
    "Stage 6 should compare local parameters and decide whether a unified model is justified." ...
    ];

save( ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage5PerCurrentPlantModels.mat"), ...
    "stage5", ...
    "plantByCurrent", ...
    "cfg", ...
    "-v7.3");

%% ========================================================================
% PLOTS
% ========================================================================

OpenXstimPlant5_PlotDiagnostics( ...
    staticResult, ...
    fastResult, ...
    slowResult, ...
    cfg);

%% ========================================================================
% FINAL SUMMARY
% ========================================================================

fprintf("\n============================================================\n");
fprintf("STAGE 5 COMPLETE: PER-CURRENT MODELS\n");
fprintf("============================================================\n");

fprintf("\n%-8s %-18s %-18s %-16s %-16s\n", ...
    "Current","Full reversal","Near-zero start","Droop","Collapse");

for k = 1:numel(currents)

    I = currents(k);

    fr = yesNo(fastResult.byCurrent(k).fullReversal.identifiable);
    nz = yesNo(fastResult.byCurrent(k).nearZeroStart.identifiable);
    dr = yesNo(slowResult.byCurrent(k).droop.identifiable);
    co = yesNo(slowResult.byCurrent(k).collapse.identifiable);

    fprintf("%-8.1f %-18s %-18s %-16s %-16s\n", ...
        I,fr,nz,dr,co);
end

fprintf("\nHigh-current modelling rule:\n");
fprintf("  30/50 mA internal transitions may identify a NEAR_ZERO_START\n");
fprintf("  fast response when Stage 3A verifies the physical pre-state is\n");
fprintf("  near zero. Literal zero_to_pos remains a separate sparse startup case.\n");

fprintf("\nSaved to:\n%s\n",cfg.OUTPUT_FOLDER);
fprintf("\nPrimary result:\n  Stage5PerCurrentPlantModels.mat\n");
fprintf("\nNEXT:\n");
fprintf("Stage 6 should compare these local models and test whether static scale,\n");
fprintf("fast dynamics, delay, droop and collapse can be reduced to a unified\n");
fprintf("current-dependent or current-invariant plant.\n");

%% ========================================================================
% LOCAL HELPERS
% ========================================================================

function T = tableRowsForCurrent(Tall,I)

if isempty(Tall)
    T = table();
    return;
end

if ~ismember("CommandCurrent_mA",string(Tall.Properties.VariableNames))
    T = table();
    return;
end

T = Tall(Tall.CommandCurrent_mA==I,:);

end

function writeIfNonempty(T,path)

if istable(T) && ~isempty(T)
    writetable(T,path);
end

end

function s = yesNo(tf)

if tf
    s = 'YES';
else
    s = 'NO';
end

end
