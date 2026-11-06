%% Stage4A_CapacitorStateAnalysis.m
% OPENXSTIM SUPPORTING ANALYSIS 4A
% CONTINUOUS SIGNED CHARGE + BLOCKING-CAPACITOR STATE PROXY
%
% Purpose
% -------
% Stage 4 showed that phase-local current loss is strongly current dependent
% and that collapse occurs at very different TIMES, while phase-local charge
% to a given loss threshold forms a smaller number of bands.
%
% Stage 4A asks whether those bands become more coherent when the capacitor
% state is carried continuously across the full biphasic packet instead of
% resetting charge to zero at the start of every phase.
%
% This is a SUPPORTING analysis, not a required pipeline stage.
% It does not alter Stage 4 or delete any measurements.
%
% Physical quantity
% -----------------
% The load current also flows through the series blocking capacitor C15.
% Therefore the change in capacitor charge is proportional to:
%
%       dq = i(t) dt
%
% and the corresponding change in capacitor voltage is:
%
%       dVc = dq / C
%
% Absolute capacitor voltage is NOT known from this experiment because the
% initial capacitor voltage is not measured. Stage 4A therefore reports:
%
%   1. q_rel(t)
%      Signed charge relative to the first physical response in the packet.
%
%   2. q_centered(t)
%      q_rel shifted by the midpoint between the packet minimum and maximum.
%      This is an exploratory symmetry-centered state proxy.
%
%   3. q_oriented(t)
%      polaritySign * q_centered(t)
%
% If compliance limits are approximately symmetric for positive and negative
% phases, q_oriented at collapse should cluster more tightly than phase-local
% charge-to-collapse.
%
% Main outputs
% ------------
%   Stage4A_CapacitorStateAnalysis/
%       Stage4A_CapacitorStateAudit.mat
%       Stage4A_PhaseStateMetrics.csv
%       Stage4A_CaptureChargeSummary.csv
%       Stage4A_ThresholdStateSummary.csv
%
%       01_ContinuousChargeStateByCurrent.png
%       02_ThresholdStateClustering.png
%       03_CollapseKneeState.png
%       04_PulseNumberChargeState.png
%       05_PacketChargeBalance.png
%       06_LocalVsContinuousChargeSpread.png
%
% Required helper files:
%   OpenXstimCapState_ProcessCapture.m
%   OpenXstimCapState_BuildSummaries.m
%   OpenXstimCapState_PlotDiagnostics.m

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

cfg.STAGE4_FILE = ...
    fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage4_PassivePhaseNormalization", ...
    "Stage4PassivePhases.mat");

cfg.OUTPUT_FOLDER = ...
    fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage4A_CapacitorStateAnalysis");

cfg.OVERWRITE_EXISTING_OUTPUT = true;

% -------------------------------------------------------------------------
% HARDWARE
% -------------------------------------------------------------------------

cfg.R_LOAD_OHM = 1000;

% C15 on the OpenXstim board.
cfg.BLOCKING_CAP_UF = 0.1;

% -------------------------------------------------------------------------
% BASELINE CORRECTION FOR CONTINUOUS CURRENT INTEGRATION
% -------------------------------------------------------------------------

% PRIMARY METHOD:
% Use the known command-to-response latency of the FIRST selected packet
% event. After the debug command changes, CH3 remains at zero current until
% the physical response begins. This interval is therefore a much safer
% baseline source than a fixed window before the packet, which can contain
% remnants of a neighbouring oscilloscope-captured packet.
%
% Use the middle 60% of that delay to stay away from both timing edges.
cfg.BASELINE_LATENCY_START_FRACTION = 0.20;
cfg.BASELINE_LATENCY_END_FRACTION   = 0.80;

% Require a useful amount of zero-output data.
cfg.BASELINE_MIN_WINDOW_US = 100;

% FALLBACK METHOD:
% If the command-to-response interval is unavailable, scan outside the
% selected packet for the quietest short window.
cfg.BASELINE_FALLBACK_WINDOW_US = 200;
cfg.BASELINE_FALLBACK_SEARCH_US = 5000;

% -------------------------------------------------------------------------
% CAPTURE INCLUSION / BASELINE QC
% -------------------------------------------------------------------------

% Capture 1 (5 mA repeat 1) was independently identified as a bad
% acquisition. It has a non-zero "zero-current" baseline near 2.16 mA and
% produces a physically impossible continuous-charge integral. Keep it in
% the audit trail, but exclude it from every Stage 4A aggregate/model input.
cfg.EXCLUDE_CAPTURE_IDS = 1;

% Baseline OFFSET is a validity condition for continuous integration.
% A capture exceeding this limit is excluded from charge-state aggregates.
cfg.BASELINE_OFFSET_MAX_mA = 0.25;

% Baseline NOISE is diagnostic only. Exceeding this threshold produces a
% warning, but does NOT exclude an otherwise valid capture. This keeps the
% 50 mA captures, whose baseline means are near zero but are noisier.
cfg.BASELINE_NOISE_WARN_mA = 0.05;

% -------------------------------------------------------------------------
% COLLAPSE-KNEE DETECTION
% -------------------------------------------------------------------------

% Do not call ordinary low-current droop a compliance knee.
% Knee is calculated only for phases that cross D = 0.75.
cfg.KNEE_REQUIRED_LEVEL = 0.75;

% Ignore the very beginning of the passive analysis when searching for the
% strongest negative derivative.
cfg.KNEE_SEARCH_START_US = 50;

% Smooth derivative on the Stage 4 model grid before finding its minimum.
cfg.KNEE_DERIVATIVE_SMOOTH_US = 20;

% -------------------------------------------------------------------------
% SUMMARY
% -------------------------------------------------------------------------

cfg.THRESHOLD_LEVELS = [0.90 0.75 0.50 0.25];

% -------------------------------------------------------------------------
% FIGURES
% -------------------------------------------------------------------------

cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;

%% ========================================================================
% CHECK INPUTS
% ========================================================================

helpers = [ ...
    "OpenXstimCapState_ProcessCapture.m", ...
    "OpenXstimCapState_BuildSummaries.m", ...
    "OpenXstimCapState_PlotDiagnostics.m"];

for k = 1:numel(helpers)

    helperPath = fullfile(cfg.ANALYSIS_FOLDER,helpers(k));

    if ~isfile(helperPath)
        error("Required Stage 4A helper is missing:\n%s",helperPath);
    end
end

if ~isfile(cfg.STAGE2_MASTER_FILE)
    error("Stage 2 master file not found:\n%s",cfg.STAGE2_MASTER_FILE);
end

if ~isfile(cfg.STAGE4_FILE)
    error("Stage 4 MAT file not found:\n%s",cfg.STAGE4_FILE);
end

if cfg.OVERWRITE_EXISTING_OUTPUT && isfolder(cfg.OUTPUT_FOLDER)

    fprintf("Replacing existing Stage 4A output folder:\n%s\n", ...
        cfg.OUTPUT_FOLDER);

    rmdir(cfg.OUTPUT_FOLDER,'s');
end

if ~isfolder(cfg.OUTPUT_FOLDER)
    mkdir(cfg.OUTPUT_FOLDER);
end

%% ========================================================================
% LOAD STAGE 2 + STAGE 4
% ========================================================================

S2 = load(cfg.STAGE2_MASTER_FILE);

if ~isfield(S2,"CaptureSummary") || ~isfield(S2,"resultFiles")
    error("Stage 2 master must contain CaptureSummary and resultFiles.");
end

stage2Summary = S2.CaptureSummary;
stage2ResultFiles = string(S2.resultFiles);

S4 = load(cfg.STAGE4_FILE);

if ~isfield(S4,"passive")
    error("Stage 4 MAT must contain struct 'passive'.");
end

passive = S4.passive;

requiredStage4Fields = [ ...
    "modelTime_us", ...
    "normalizedModel", ...
    "phaseMetrics", ...
    "settings"];

for k = 1:numel(requiredStage4Fields)

    if ~isfield(passive,requiredStage4Fields(k))
        error("Stage 4 passive struct is missing field '%s'.", ...
            requiredStage4Fields(k));
    end
end

modelTime_us = passive.modelTime_us;
normalizedModel = passive.normalizedModel;
PhaseMetrics = passive.phaseMetrics;

stage4cfg = passive.settings;

if ~isfield(stage4cfg,"START_GUARD_US")
    error("Stage 4 settings do not contain START_GUARD_US.");
end

%% ========================================================================
% HEADER
% ========================================================================

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 4A: CAPACITOR STATE ANALYSIS\n");
fprintf("============================================================\n");

fprintf("Stage 4 phases               : %d\n",height(PhaseMetrics));
fprintf("Stage 4 valid phases         : %d\n",nnz(PhaseMetrics.ValidPhase));
fprintf("Blocking capacitor           : %.3f uF\n",cfg.BLOCKING_CAP_UF);
fprintf("Baseline method              : first command-to-response quiet interval\n");
fprintf("Baseline delay fractions     : %.2f to %.2f\n", ...
    cfg.BASELINE_LATENCY_START_FRACTION, ...
    cfg.BASELINE_LATENCY_END_FRACTION);
fprintf("Known excluded captures      : "); fprintf("%d ",cfg.EXCLUDE_CAPTURE_IDS); fprintf("\n");
fprintf("Offset exclusion limit       : %.3f mA\n",cfg.BASELINE_OFFSET_MAX_mA);
fprintf("Noise warning threshold      : %.3f mA\n",cfg.BASELINE_NOISE_WARN_mA);
fprintf("Stage 4 passive guard        : %.1f us\n",stage4cfg.START_GUARD_US);

%% ========================================================================
% PROCESS EACH CAPTURE
% ========================================================================

captureIDs = unique(PhaseMetrics.CaptureID);
captureIDs = captureIDs(isfinite(captureIDs));

nCaptures = numel(captureIDs);

phaseParts = cell(nCaptures,1);
captureParts = cell(nCaptures,1);
traceParts = cell(nCaptures,1);

for c = 1:nCaptures

    captureID = captureIDs(c);

    pmRows = find(PhaseMetrics.CaptureID==captureID);

    if isempty(pmRows)
        continue;
    end

    current_mA = PhaseMetrics.CommandCurrent_mA(pmRows(1));

    fprintf("\n------------------------------------------------------------\n");
    fprintf("CAPTURE %d / %d | ID %d | %.3g mA p-p\n", ...
        c,nCaptures,captureID,current_mA);
    fprintf("------------------------------------------------------------\n");

    s2row = find(stage2Summary.CaptureID==captureID,1);

    if isempty(s2row)
        fprintf(2,"Capture ID not found in Stage 2 summary.\n");
        continue;
    end

    if s2row>numel(stage2ResultFiles) || ...
            ~isfile(stage2ResultFiles(s2row))

        fprintf(2,"Stage 2 per-capture file is missing.\n");
        continue;
    end

    try

        O = OpenXstimCapState_ProcessCapture( ...
            stage2ResultFiles(s2row), ...
            PhaseMetrics(pmRows,:), ...
            normalizedModel(:,pmRows), ...
            modelTime_us, ...
            stage4cfg, ...
            cfg);

        phaseParts{c} = O.phaseStateMetrics;
        captureParts{c} = O.captureSummary;
        traceParts{c} = O.trace;

        fprintf("Phases mapped                : %d\n", ...
            height(O.phaseStateMetrics));

        fprintf("Baseline                     : %.5f mA | noise %.5f mA | %s\n", ...
            O.captureSummary.BaselineCurrent_mA, ...
            O.captureSummary.BaselineNoiseRobustSD_mA, ...
            O.captureSummary.BaselineMethod);

        if O.captureSummary.BaselineNoiseWarning
            fprintf(2,"WARNING: elevated baseline noise; capture remains eligible.\n");
        end

        if ~O.captureSummary.IncludedInChargeAnalysis
            fprintf(2,"EXCLUDED FROM STAGE 4A AGGREGATES: %s\n", ...
                O.captureSummary.ExclusionReason);
        end

        fprintf("Packet q span                : %.4f uC\n", ...
            O.captureSummary.ChargeSpan_uC);

        fprintf("Equivalent V span            : %.2f V\n", ...
            O.captureSummary.VoltageSpanProxy_V);

        fprintf("Net packet charge            : %.4f uC\n", ...
            O.captureSummary.NetPacketCharge_uC);

    catch ME

        fprintf(2,"Capture failed: %s\n",ME.message);
    end
end

validCaptureCells = ~cellfun(@isempty,captureParts);

if ~any(validCaptureCells)
    error("No capture produced Stage 4A capacitor-state results.");
end

PhaseStateMetrics = vertcat(phaseParts{validCaptureCells});
CaptureChargeSummary = vertcat(captureParts{validCaptureCells});
ChargeTraces = traceParts(validCaptureCells);

%% ========================================================================
% BUILD SUMMARIES
% ========================================================================

summary = OpenXstimCapState_BuildSummaries( ...
    PhaseStateMetrics, ...
    cfg);

ThresholdStateSummary = summary.ThresholdStateSummary;
GlobalThresholdSummary = summary.GlobalThresholdSummary;

%% ========================================================================
% SAVE CSV
% ========================================================================

writetable( ...
    PhaseStateMetrics, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4A_PhaseStateMetrics.csv"));

writetable( ...
    CaptureChargeSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4A_CaptureChargeSummary.csv"));

writetable( ...
    ThresholdStateSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4A_ThresholdStateSummary.csv"));

writetable( ...
    GlobalThresholdSummary, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4A_GlobalThresholdSummary.csv"));

%% ========================================================================
% SAVE MAT
% ========================================================================

capState = struct();

capState.processingStage = ...
    "Stage4A_CapacitorStateAnalysis";

capState.sourceStage2Master = ...
    cfg.STAGE2_MASTER_FILE;

capState.sourceStage4 = ...
    cfg.STAGE4_FILE;

capState.phaseStateMetrics = ...
    PhaseStateMetrics;

capState.captureChargeSummary = ...
    CaptureChargeSummary;

capState.thresholdStateSummary = ...
    ThresholdStateSummary;

capState.globalThresholdSummary = ...
    GlobalThresholdSummary;

capState.chargeTraces = ...
    ChargeTraces;

capState.settings = ...
    cfg;

capState.notes = [ ...
    "q_rel is relative to the first physical response in each packet."; ...
    "q_centered is shifted by the midpoint of each packet's q_rel extrema."; ...
    "q_oriented = polaritySign * q_centered."; ...
    "Capture 1 is retained in the audit tables but excluded from Stage 4A aggregates."; ...
    "Baseline noise warnings do not automatically exclude a capture."; ...
    "Absolute capacitor voltage is not measured and is not claimed."];

save( ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage4A_CapacitorStateAudit.mat"), ...
    "capState", ...
    "PhaseStateMetrics", ...
    "CaptureChargeSummary", ...
    "ThresholdStateSummary", ...
    "GlobalThresholdSummary", ...
    "cfg", ...
    "-v7.3");

%% ========================================================================
% PLOTS
% ========================================================================

OpenXstimCapState_PlotDiagnostics( ...
    PhaseStateMetrics, ...
    CaptureChargeSummary, ...
    ChargeTraces, ...
    ThresholdStateSummary, ...
    GlobalThresholdSummary, ...
    cfg);

%% ========================================================================
% FINAL CONSOLE SUMMARY
% ========================================================================

fprintf("\n============================================================\n");
fprintf("STAGE 4A COMPLETE\n");
fprintf("============================================================\n");

fprintf("Captures examined            : %d\n",height(CaptureChargeSummary));
fprintf("Captures included            : %d\n",nnz(CaptureChargeSummary.IncludedInChargeAnalysis));
fprintf("Captures excluded            : %d\n",nnz(~CaptureChargeSummary.IncludedInChargeAnalysis));
fprintf("Phases mapped                : %d\n",height(PhaseStateMetrics));
fprintf("Phases included in analysis  : %d\n",nnz(PhaseStateMetrics.IncludedInChargeAnalysis));
fprintf("Baseline noise warnings      : %d\n",nnz(CaptureChargeSummary.BaselineNoiseWarning));

if any(~CaptureChargeSummary.IncludedInChargeAnalysis)
    fprintf("\nExcluded captures retained for audit:\n");
    disp(CaptureChargeSummary(~CaptureChargeSummary.IncludedInChargeAnalysis, ...
        {'CaptureID','CommandCurrent_mA','CaptureWithinAttempt', ...
         'BaselineCurrent_mA','BaselineNoiseRobustSD_mA', ...
         'ExclusionReason'}));
end

if any(CaptureChargeSummary.BaselineNoiseWarning & ...
        CaptureChargeSummary.IncludedInChargeAnalysis)
    fprintf("\nIncluded captures with baseline-noise warning:\n");
    disp(CaptureChargeSummary( ...
        CaptureChargeSummary.BaselineNoiseWarning & ...
        CaptureChargeSummary.IncludedInChargeAnalysis, ...
        {'CaptureID','CommandCurrent_mA','CaptureWithinAttempt', ...
         'BaselineCurrent_mA','BaselineNoiseRobustSD_mA'}));
end

fprintf("\nPacket charge-state span by current:\n");

currents = unique(CaptureChargeSummary.CommandCurrent_mA( ...
    CaptureChargeSummary.IncludedInChargeAnalysis));

for k = 1:numel(currents)

    m = ...
        CaptureChargeSummary.CommandCurrent_mA==currents(k) & ...
        CaptureChargeSummary.IncludedInChargeAnalysis;

    fprintf("  %5.1f mA p-p : q span %.3f +/- %.3f uC | V proxy span %.1f +/- %.1f V\n", ...
        currents(k), ...
        mean(CaptureChargeSummary.ChargeSpan_uC(m),'omitnan'), ...
        std(CaptureChargeSummary.ChargeSpan_uC(m),'omitnan'), ...
        mean(CaptureChargeSummary.VoltageSpanProxy_V(m),'omitnan'), ...
        std(CaptureChargeSummary.VoltageSpanProxy_V(m),'omitnan'));
end

fprintf("\nThreshold consistency comparison:\n");
disp(GlobalThresholdSummary);

fprintf("\nOutput folder:\n%s\n",cfg.OUTPUT_FOLDER);

fprintf("\nInterpretation rule:\n");
fprintf("Smaller robust spread for OrientedCenteredState_uC than for\n");
fprintf("PhaseLocalCharge_uC supports a state-dependent capacitor/compliance model.\n");
fprintf("Absolute capacitor voltage remains unknown because the initial capacitor\n");
fprintf("voltage was not measured.\n");
