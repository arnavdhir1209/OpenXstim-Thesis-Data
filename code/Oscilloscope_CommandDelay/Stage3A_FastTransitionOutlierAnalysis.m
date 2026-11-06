%% Stage3A_FastTransitionOutlierAnalysis.m
% OPENXSTIM SUPPORTING ANALYSIS 3A
% FAST-TRANSITION OUTLIER + PHYSICAL-STATE AUDIT
%
% This is NOT a required pipeline stage. It is a supporting analysis used
% to decide which Stage 3 fast transitions are suitable for later plant
% identification.
%
% It DOES NOT modify Stage 3 and DOES NOT delete any measurements.
%
% Main questions:
%   1. Which normalized waveforms are statistical shape outliers?
%   2. Which fast metrics are statistical outliers?
%   3. Are any entire captures inconsistent with their repeats?
%   4. Was the physical current actually at the expected polarity before
%      and after each command?
%   5. Which nominal "+I -> -I" / "-I -> +I" commands were physically full
%      reversals, partial reversals, or effectively near-zero starts?
%
% The key physical-state quantities are:
%
%   PreStateRatio  = |I0*| / (Ipp_measured / 2)
%   PostStateRatio = |If*| / (Ipp_measured / 2)
%
% where Ipp_measured is the Stage 2 mean early measured peak-to-peak current
% for that capture.
%
% Outputs:
%   Stage3A_FastTransitionOutlierAnalysis/
%       Stage3A_FastEventAudit.csv
%       Stage3A_ModelSelectionMask.csv
%       Stage3A_CaptureAudit.csv
%       Stage3A_MissingPhysicalEdges.csv
%       Stage3A_RegimeSummary.csv
%       Stage3A_FastTransitionAudit.mat
%
%       01_EventOutlierAndStateAudit.png
%       02_CaptureConsistency.png
%       03_PhysicalRegimesByCurrent.png
%       04_RecommendedVsExcludedWaveforms.png
%       05_TransitionTypeStateAudit.png
%
% RecommendedForFastModel is intentionally conservative:
%
%   valid Stage 3 event
%   AND bipolar transition
%   AND physical regime = FULL_REVERSAL
%   AND not a waveform-shape outlier
%   AND not a fast-metric outlier
%
% Capture-level outliers are NOT automatically deleted. A second stricter
% mask is also supplied:
%
%   RecommendedForStrictSensitivityCheck
%
% which additionally excludes captures flagged by capture-level consistency
% checks.
%
% This lets later Stage 5 fit:
%   primary model      -> RecommendedForFastModel
%   sensitivity model  -> RecommendedForStrictSensitivityCheck

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

cfg.STAGE3_FILE = ...
    fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage3_FastTransitionNormalization", ...
    "Stage3FastNormalizedTransitions.mat");

cfg.OUTPUT_FOLDER = ...
    fullfile( ...
    cfg.ANALYSIS_FOLDER, ...
    "Stage3A_FastTransitionOutlierAnalysis");

cfg.OVERWRITE_EXISTING_OUTPUT = true;

% -------------------------------------------------------------------------
% OUTLIER DETECTION
% -------------------------------------------------------------------------

% Only use automatic robust outlier statistics when a current x transition
% group has enough repeated observations. This means the large bipolar
% groups are tested statistically, while N=4 or N=5 boundary groups remain
% descriptive.
cfg.MIN_EVENTS_FOR_ROBUST_GROUP = 20;

% Robust z threshold. 4 is deliberately conservative.
cfg.EVENT_ROBUST_Z_THRESHOLD = 4.0;

% Waveform RMSE is evaluated only around the actual fast response, rather
% than using the whole -20 to +25 us record.
cfg.SHAPE_WINDOW_START_US = -5;
cfg.SHAPE_WINDOW_END_US = 12;

% Metrics included in robust event-outlier testing.
cfg.TEST_T10_90 = true;
cfg.TEST_T50 = true;
cfg.TEST_T90 = true;
cfg.TEST_DELAY = true;

% -------------------------------------------------------------------------
% PHYSICAL-STATE CLASSIFICATION
% -------------------------------------------------------------------------

% Expected active-polarity magnitude is Ipp_measured / 2.
%
% >= FULL_STATE_MIN means the current is considered substantially at its
% expected active-polarity level.
cfg.FULL_STATE_MIN = 0.70;

% <= NEAR_ZERO_MAX means the state is effectively near zero relative to the
% capture's measured half-current level.
cfg.NEAR_ZERO_MAX = 0.30;

% Anything between these two values is a partial state.
%
% A clean full bipolar reversal therefore requires:
%   pre magnitude ratio  >= 0.70
%   post magnitude ratio >= 0.70
%   correct polarity signs
%
% High-current compliance-affected reversals are expected to fall into:
%   PARTIAL_REVERSAL
% or
%   NEAR_ZERO_TO_OPPOSITE

% Boundary event duration is compared to the same-current bipolar median.
% This is diagnostic only. It catches cases such as an OFF transition that
% has been spread out by prior compliance collapse.
cfg.BOUNDARY_DURATION_RATIO_WARNING = 1.75;

% -------------------------------------------------------------------------
% CAPTURE-LEVEL CONSISTENCY
% -------------------------------------------------------------------------

cfg.CAPTURE_ROBUST_Z_THRESHOLD = 3.5;

% Minimum absolute difference before a capture mean t10-90 is called an
% outlier, even if the other four captures are extremely repeatable.
cfg.CAPTURE_MIN_T1090_DEVIATION_US = 0.08;

% -------------------------------------------------------------------------
% FIGURES
% -------------------------------------------------------------------------

cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;

cfg.MAX_NONRECOMMENDED_TRACES_PER_CURRENT = 35;

%% ========================================================================
% INPUT / OUTPUT
% ========================================================================

if ~isfile(cfg.STAGE3_FILE)
    error("Stage 3 MAT file not found:\n%s",cfg.STAGE3_FILE);
end

if cfg.OVERWRITE_EXISTING_OUTPUT && isfolder(cfg.OUTPUT_FOLDER)

    fprintf("Replacing existing Stage 3A output folder:\n%s\n", ...
        cfg.OUTPUT_FOLDER);

    rmdir(cfg.OUTPUT_FOLDER,'s');
end

if ~isfolder(cfg.OUTPUT_FOLDER)
    mkdir(cfg.OUTPUT_FOLDER);
end

%% ========================================================================
% LOAD STAGE 3
% ========================================================================

S3 = load(cfg.STAGE3_FILE);

if ~isfield(S3,"fast")
    error("Stage 3 MAT must contain struct 'fast'.");
end

fast = S3.fast;

if ~isfield(fast,"allTransitionTypes")
    error([ ...
        "Stage 3 MAT contains no fast.allTransitionTypes data.\n" ...
        "Run the updated Stage3_NormalizeFastTransitions.m first."]);
end

A = fast.allTransitionTypes.eventMetrics;
Y = fast.allTransitionTypes.normalizedDetrended;
tFast_us = fast.allTransitionTypes.time_us;

if width(Y)~=height(A)
    error("Stage 3 all-transition waveform matrix is misaligned with metadata.");
end

requiredCols = [ ...
    "CaptureID", ...
    "CommandCurrent_mA", ...
    "CaptureWithinAttempt", ...
    "PulseNumber", ...
    "CommandEvent", ...
    "TransitionClass", ...
    "IsBipolar", ...
    "IsBoundary", ...
    "ValidEvent", ...
    "I0star_mA", ...
    "Ifstar_mA", ...
    "LocalStepMagnitude_mA", ...
    "T10_us", ...
    "T50_us", ...
    "T90_us", ...
    "T10_90_us", ...
    "CommandToGradientPeak_us"];

if ~all(ismember(requiredCols,string(A.Properties.VariableNames)))
    error("Stage 3 all-transition event table is missing required fields.");
end

%% ========================================================================
% LOAD STAGE 2 CAPTURE CURRENT SCALE
% ========================================================================

stage2Path = "";

if isfield(fast,"sourceStage2Master")
    stage2Path = string(fast.sourceStage2Master);
end

if strlength(stage2Path)==0 || ~isfile(stage2Path)

    stage2Path = fullfile( ...
        cfg.ANALYSIS_FOLDER, ...
        "Stage2_CurrentResponseClassification", ...
        "Stage2MasterResults.mat");
end

if ~isfile(stage2Path)
    error("Stage 2 master file required for measured Ipp reference was not found.");
end

S2 = load(stage2Path);

if ~isfield(S2,"CaptureSummary") || ~isfield(S2,"PhysicalEvents")
    error("Stage 2 master must contain CaptureSummary and PhysicalEvents.");
end

C2 = S2.CaptureSummary;
E2 = S2.PhysicalEvents;

if ~ismember( ...
        "MeanEarlyMeasuredIpp_mA", ...
        string(C2.Properties.VariableNames))

    error("Stage 2 CaptureSummary has no MeanEarlyMeasuredIpp_mA field.");
end

%% ========================================================================
% HEADER
% ========================================================================

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 3A: FAST TRANSITION OUTLIER ANALYSIS\n");
fprintf("============================================================\n");

fprintf("Stage 3 source                : %s\n",cfg.STAGE3_FILE);
fprintf("All observed transitions      : %d\n",height(A));
fprintf("Valid Stage 3 transitions     : %d\n",nnz(A.ValidEvent));
fprintf("Shape window                  : %.1f to %.1f us\n", ...
    cfg.SHAPE_WINDOW_START_US,cfg.SHAPE_WINDOW_END_US);
fprintf("Event robust-z threshold      : %.2f\n", ...
    cfg.EVENT_ROBUST_Z_THRESHOLD);
fprintf("Full-state minimum ratio      : %.2f\n",cfg.FULL_STATE_MIN);
fprintf("Near-zero maximum ratio       : %.2f\n",cfg.NEAR_ZERO_MAX);

%% ========================================================================
% MAP MEASURED Ipp TO EVERY EVENT
% ========================================================================

nEvents = height(A);

ReferenceMeasuredIpp_mA = NaN(nEvents,1);
ReferenceHalfCurrent_mA = NaN(nEvents,1);

for i = 1:nEvents

    row = find(C2.CaptureID==A.CaptureID(i),1);

    if isempty(row)
        continue;
    end

    ReferenceMeasuredIpp_mA(i) = ...
        C2.MeanEarlyMeasuredIpp_mA(row);

    ReferenceHalfCurrent_mA(i) = ...
        0.5*ReferenceMeasuredIpp_mA(i);
end

if any(~isfinite(ReferenceMeasuredIpp_mA))

    warning("%d events could not be mapped to Stage 2 measured Ipp.", ...
        nnz(~isfinite(ReferenceMeasuredIpp_mA)));
end

%% ========================================================================
% PHYSICAL STATE FEATURES
% ========================================================================

PreStateMagnitudeRatio = ...
    abs(A.I0star_mA)./ReferenceHalfCurrent_mA;

PostStateMagnitudeRatio = ...
    abs(A.Ifstar_mA)./ReferenceHalfCurrent_mA;

StepToMeasuredIppRatio = ...
    A.LocalStepMagnitude_mA./ReferenceMeasuredIpp_mA;

SignPatternPass = false(nEvents,1);
PhysicalRegime = strings(nEvents,1);

for i = 1:nEvents

    cls = string(A.TransitionClass(i));

    pre = A.I0star_mA(i);
    post = A.Ifstar_mA(i);

    rPre = PreStateMagnitudeRatio(i);
    rPost = PostStateMagnitudeRatio(i);

    if ~all(isfinite([pre,post,rPre,rPost]))

        PhysicalRegime(i) = "UNKNOWN";
        continue;
    end

    switch cls

        case "pos_to_neg"

            % If the pre-state has already collapsed close to zero, its
            % tiny residual sign is not physically meaningful. Classify
            % the event from the near-zero magnitude and the healthy
            % opposite-polarity post-state before applying a sign test.
            if rPre<=cfg.NEAR_ZERO_MAX && ...
                    rPost>=cfg.FULL_STATE_MIN && ...
                    post<0

                SignPatternPass(i) = true;
                PhysicalRegime(i) = "NEAR_ZERO_TO_OPPOSITE";

            elseif pre>0 && post<0 && ...
                    rPre>=cfg.FULL_STATE_MIN && ...
                    rPost>=cfg.FULL_STATE_MIN

                SignPatternPass(i) = true;
                PhysicalRegime(i) = "FULL_REVERSAL";

            elseif pre>0 && post<0 && ...
                    rPre<cfg.FULL_STATE_MIN && ...
                    rPost>=cfg.FULL_STATE_MIN

                SignPatternPass(i) = true;
                PhysicalRegime(i) = "PARTIAL_REVERSAL";

            elseif ~(post<0)

                SignPatternPass(i) = false;
                PhysicalRegime(i) = "STATE_SIGN_MISMATCH";

            else

                SignPatternPass(i) = pre>0 && post<0;
                PhysicalRegime(i) = "OTHER_BIPOLAR_STATE";
            end

        case "neg_to_pos"

            % Same rule in the opposite direction: once the pre-state is
            % effectively zero, do not let numerical/noise sign determine
            % the physical regime.
            if rPre<=cfg.NEAR_ZERO_MAX && ...
                    rPost>=cfg.FULL_STATE_MIN && ...
                    post>0

                SignPatternPass(i) = true;
                PhysicalRegime(i) = "NEAR_ZERO_TO_OPPOSITE";

            elseif pre<0 && post>0 && ...
                    rPre>=cfg.FULL_STATE_MIN && ...
                    rPost>=cfg.FULL_STATE_MIN

                SignPatternPass(i) = true;
                PhysicalRegime(i) = "FULL_REVERSAL";

            elseif pre<0 && post>0 && ...
                    rPre<cfg.FULL_STATE_MIN && ...
                    rPost>=cfg.FULL_STATE_MIN

                SignPatternPass(i) = true;
                PhysicalRegime(i) = "PARTIAL_REVERSAL";

            elseif ~(post>0)

                SignPatternPass(i) = false;
                PhysicalRegime(i) = "STATE_SIGN_MISMATCH";

            else

                SignPatternPass(i) = pre<0 && post>0;
                PhysicalRegime(i) = "OTHER_BIPOLAR_STATE";
            end

        case "zero_to_pos"

            SignPatternPass(i) = post>0;

            if rPre<=cfg.NEAR_ZERO_MAX && ...
                    rPost>=cfg.FULL_STATE_MIN && ...
                    SignPatternPass(i)

                PhysicalRegime(i) = "CLEAN_ZERO_TO_POS";

            elseif SignPatternPass(i)

                PhysicalRegime(i) = "PARTIAL_ZERO_TO_POS";

            else

                PhysicalRegime(i) = "STATE_SIGN_MISMATCH";
            end

        case "neg_to_zero"

            SignPatternPass(i) = pre<0;

            if rPre>=cfg.FULL_STATE_MIN && ...
                    rPost<=cfg.NEAR_ZERO_MAX && ...
                    SignPatternPass(i)

                PhysicalRegime(i) = "CLEAN_NEG_TO_ZERO";

            elseif rPre<cfg.FULL_STATE_MIN && ...
                    SignPatternPass(i)

                PhysicalRegime(i) = "PRECOLLAPSED_NEG_TO_ZERO";

            elseif SignPatternPass(i)

                PhysicalRegime(i) = "PARTIAL_NEG_TO_ZERO";

            else

                PhysicalRegime(i) = "STATE_SIGN_MISMATCH";
            end

        otherwise

            PhysicalRegime(i) = "UNKNOWN_TRANSITION";
    end
end

%% ========================================================================
% SAME-CURRENT BIPOLAR REFERENCE DURATION
% ========================================================================

currents = unique(A.CommandCurrent_mA);

BipolarMedianT1090_us = NaN(nEvents,1);
DurationRatioToBipolarMedian = NaN(nEvents,1);
BoundaryDurationWarning = false(nEvents,1);

for k = 1:numel(currents)

    Icmd = currents(k);

    mb = ...
        A.CommandCurrent_mA==Icmd & ...
        A.IsBipolar & ...
        A.ValidEvent & ...
        isfinite(A.T10_90_us);

    ref = median(A.T10_90_us(mb),'omitnan');

    mCurrent = A.CommandCurrent_mA==Icmd;

    BipolarMedianT1090_us(mCurrent) = ref;

    DurationRatioToBipolarMedian(mCurrent) = ...
        A.T10_90_us(mCurrent)/ref;
end

BoundaryDurationWarning = ...
    A.IsBoundary & ...
    isfinite(DurationRatioToBipolarMedian) & ...
    DurationRatioToBipolarMedian ...
    > cfg.BOUNDARY_DURATION_RATIO_WARNING;

%% ========================================================================
% WAVEFORM SHAPE OUTLIERS
% ========================================================================

shapeMask = ...
    tFast_us>=cfg.SHAPE_WINDOW_START_US & ...
    tFast_us<=cfg.SHAPE_WINDOW_END_US;

WaveformRMSEToGroupMedian = NaN(nEvents,1);
WaveformRobustZ = NaN(nEvents,1);
WaveformOutlier = false(nEvents,1);

transitionClasses = unique(string(A.TransitionClass));

for k = 1:numel(currents)

    for d = 1:numel(transitionClasses)

        m = ...
            A.CommandCurrent_mA==currents(k) & ...
            string(A.TransitionClass)==transitionClasses(d) & ...
            A.ValidEvent;

        rows = find(m);

        if isempty(rows)
            continue;
        end

        referenceWave = ...
            median(Y(:,rows),2,'omitnan');

        for q = 1:numel(rows)

            r = rows(q);

            good = ...
                shapeMask & ...
                isfinite(Y(:,r)) & ...
                isfinite(referenceWave);

            if any(good)

                delta = ...
                    Y(good,r)-referenceWave(good);

                WaveformRMSEToGroupMedian(r) = ...
                    sqrt(mean(delta.^2));
            end
        end

        if numel(rows)>=cfg.MIN_EVENTS_FOR_ROBUST_GROUP

            z = robustZ( ...
                WaveformRMSEToGroupMedian(rows));

            WaveformRobustZ(rows) = z;

            WaveformOutlier(rows) = ...
                z>cfg.EVENT_ROBUST_Z_THRESHOLD;
        end
    end
end

%% ========================================================================
% FAST METRIC OUTLIERS
% ========================================================================

T1090RobustZ = NaN(nEvents,1);
T50RobustZ = NaN(nEvents,1);
T90RobustZ = NaN(nEvents,1);
DelayRobustZ = NaN(nEvents,1);

MetricOutlier = false(nEvents,1);

for k = 1:numel(currents)

    for d = 1:numel(transitionClasses)

        m = ...
            A.CommandCurrent_mA==currents(k) & ...
            string(A.TransitionClass)==transitionClasses(d) & ...
            A.ValidEvent;

        rows = find(m);

        if numel(rows)<cfg.MIN_EVENTS_FOR_ROBUST_GROUP
            continue;
        end

        if cfg.TEST_T10_90

            z = robustZ(A.T10_90_us(rows));
            T1090RobustZ(rows) = z;
        end

        if cfg.TEST_T50

            z = robustZ(A.T50_us(rows));
            T50RobustZ(rows) = z;
        end

        if cfg.TEST_T90

            z = robustZ(A.T90_us(rows));
            T90RobustZ(rows) = z;
        end

        if cfg.TEST_DELAY

            z = robustZ(A.CommandToGradientPeak_us(rows));
            DelayRobustZ(rows) = z;
        end
    end
end

zMatrix = [ ...
    abs(T1090RobustZ), ...
    abs(T50RobustZ), ...
    abs(T90RobustZ), ...
    abs(DelayRobustZ)];

MaxMetricRobustZ = max(zMatrix,[],2,'omitnan');

MetricOutlier = ...
    isfinite(MaxMetricRobustZ) & ...
    MaxMetricRobustZ>cfg.EVENT_ROBUST_Z_THRESHOLD;

%% ========================================================================
% CAPTURE-LEVEL CONSISTENCY
% ========================================================================

captureIDs = unique(A.CaptureID);

nCaptures = numel(captureIDs);

CaptureID = captureIDs;
CommandCurrent_mA = NaN(nCaptures,1);
CaptureWithinAttempt = NaN(nCaptures,1);

NBipolarEvents = zeros(nCaptures,1);
NFullReversal = zeros(nCaptures,1);
FullReversalFraction = NaN(nCaptures,1);

MeanT10_90_us = NaN(nCaptures,1);
SDT10_90_us = NaN(nCaptures,1);

CaptureMeanWaveformRMSE = NaN(nCaptures,1);

CaptureT1090RobustZ = NaN(nCaptures,1);
CaptureWaveformRobustZ = NaN(nCaptures,1);

CaptureT1090Outlier = false(nCaptures,1);
CaptureWaveformOutlier = false(nCaptures,1);
CaptureOutlierQC = false(nCaptures,1);

captureMeanWaves = NaN(numel(tFast_us),nCaptures);

for c = 1:nCaptures

    m = ...
        A.CaptureID==CaptureID(c) & ...
        A.IsBipolar & ...
        A.ValidEvent;

    rows = find(m);

    if isempty(rows)
        continue;
    end

    CommandCurrent_mA(c) = A.CommandCurrent_mA(rows(1));
    CaptureWithinAttempt(c) = A.CaptureWithinAttempt(rows(1));

    NBipolarEvents(c) = numel(rows);

    NFullReversal(c) = ...
        nnz(PhysicalRegime(rows)=="FULL_REVERSAL");

    FullReversalFraction(c) = ...
        NFullReversal(c)/NBipolarEvents(c);

    MeanT10_90_us(c) = ...
        mean(A.T10_90_us(rows),'omitnan');

    SDT10_90_us(c) = ...
        std(A.T10_90_us(rows),'omitnan');

    captureMeanWaves(:,c) = ...
        mean(Y(:,rows),2,'omitnan');
end

for k = 1:numel(currents)

    mCap = CommandCurrent_mA==currents(k);

    capRows = find(mCap);

    if isempty(capRows)
        continue;
    end

    currentReferenceWave = ...
        median(captureMeanWaves(:,capRows),2,'omitnan');

    for q = 1:numel(capRows)

        c = capRows(q);

        good = ...
            shapeMask & ...
            isfinite(captureMeanWaves(:,c)) & ...
            isfinite(currentReferenceWave);

        if any(good)

            delta = ...
                captureMeanWaves(good,c) ...
                - currentReferenceWave(good);

            CaptureMeanWaveformRMSE(c) = ...
                sqrt(mean(delta.^2));
        end
    end

    zTime = robustZ(MeanT10_90_us(capRows));
    zWave = robustZ(CaptureMeanWaveformRMSE(capRows));

    CaptureT1090RobustZ(capRows) = zTime;
    CaptureWaveformRobustZ(capRows) = zWave;

    medTime = median(MeanT10_90_us(capRows),'omitnan');

    CaptureT1090Outlier(capRows) = ...
        abs(zTime)>cfg.CAPTURE_ROBUST_Z_THRESHOLD & ...
        abs(MeanT10_90_us(capRows)-medTime) ...
        >= cfg.CAPTURE_MIN_T1090_DEVIATION_US;

    CaptureWaveformOutlier(capRows) = ...
        zWave>cfg.CAPTURE_ROBUST_Z_THRESHOLD;
end

CaptureOutlierQC = ...
    CaptureT1090Outlier | ...
    CaptureWaveformOutlier;

CaptureAudit = table( ...
    CaptureID, ...
    CommandCurrent_mA, ...
    CaptureWithinAttempt, ...
    NBipolarEvents, ...
    NFullReversal, ...
    FullReversalFraction, ...
    MeanT10_90_us, ...
    SDT10_90_us, ...
    CaptureMeanWaveformRMSE, ...
    CaptureT1090RobustZ, ...
    CaptureWaveformRobustZ, ...
    CaptureT1090Outlier, ...
    CaptureWaveformOutlier, ...
    CaptureOutlierQC);

%% ========================================================================
% MAP CAPTURE QC BACK TO EVENTS
% ========================================================================

EventCaptureOutlierQC = false(nEvents,1);

for i = 1:nEvents

    c = find(CaptureAudit.CaptureID==A.CaptureID(i),1);

    if ~isempty(c)
        EventCaptureOutlierQC(i) = CaptureAudit.CaptureOutlierQC(c);
    end
end

%% ========================================================================
% MODEL RECOMMENDATION
% ========================================================================

RecommendedForFastModel = ...
    A.ValidEvent & ...
    A.IsBipolar & ...
    PhysicalRegime=="FULL_REVERSAL" & ...
    ~WaveformOutlier & ...
    ~MetricOutlier;

RecommendedForStrictSensitivityCheck = ...
    RecommendedForFastModel & ...
    ~EventCaptureOutlierQC;

ExclusionReason = strings(nEvents,1);

for i = 1:nEvents

    reasons = strings(0,1);

    if ~A.ValidEvent(i)
        reasons(end+1) = "STAGE3_INVALID";
    end

    if ~A.IsBipolar(i)
        reasons(end+1) = "BOUNDARY_CHARACTERIZATION_ONLY";
    end

    if A.IsBipolar(i) && PhysicalRegime(i)~="FULL_REVERSAL"
        reasons(end+1) = "PHYSICAL_STATE_" + PhysicalRegime(i);
    end

    if WaveformOutlier(i)
        reasons(end+1) = "WAVEFORM_OUTLIER";
    end

    if MetricOutlier(i)
        reasons(end+1) = "METRIC_OUTLIER";
    end

    if EventCaptureOutlierQC(i)
        reasons(end+1) = "CAPTURE_OUTLIER_QC";
    end

    if BoundaryDurationWarning(i)
        reasons(end+1) = "BOUNDARY_DURATION_ANOMALY";
    end

    if isempty(reasons)

        ExclusionReason(i) = "NONE";

    else

        ExclusionReason(i) = strjoin(reasons,";");
    end
end

%% ========================================================================
% BUILD EVENT AUDIT TABLE
% ========================================================================

FastEventAudit = A;

FastEventAudit.ReferenceMeasuredIpp_mA = ...
    ReferenceMeasuredIpp_mA;

FastEventAudit.ReferenceHalfCurrent_mA = ...
    ReferenceHalfCurrent_mA;

FastEventAudit.PreStateMagnitudeRatio = ...
    PreStateMagnitudeRatio;

FastEventAudit.PostStateMagnitudeRatio = ...
    PostStateMagnitudeRatio;

FastEventAudit.StepToMeasuredIppRatio = ...
    StepToMeasuredIppRatio;

FastEventAudit.SignPatternPass = ...
    SignPatternPass;

FastEventAudit.PhysicalRegime = ...
    PhysicalRegime;

FastEventAudit.BipolarMedianT1090_us = ...
    BipolarMedianT1090_us;

FastEventAudit.DurationRatioToBipolarMedian = ...
    DurationRatioToBipolarMedian;

FastEventAudit.BoundaryDurationWarning = ...
    BoundaryDurationWarning;

FastEventAudit.WaveformRMSEToGroupMedian = ...
    WaveformRMSEToGroupMedian;

FastEventAudit.WaveformRobustZ = ...
    WaveformRobustZ;

FastEventAudit.WaveformOutlier = ...
    WaveformOutlier;

FastEventAudit.T1090RobustZ = ...
    T1090RobustZ;

FastEventAudit.T50RobustZ = ...
    T50RobustZ;

FastEventAudit.T90RobustZ = ...
    T90RobustZ;

FastEventAudit.DelayRobustZ = ...
    DelayRobustZ;

FastEventAudit.MaxMetricRobustZ = ...
    MaxMetricRobustZ;

FastEventAudit.MetricOutlier = ...
    MetricOutlier;

FastEventAudit.CaptureOutlierQC = ...
    EventCaptureOutlierQC;

FastEventAudit.RecommendedForFastModel = ...
    RecommendedForFastModel;

FastEventAudit.RecommendedForStrictSensitivityCheck = ...
    RecommendedForStrictSensitivityCheck;

FastEventAudit.ExclusionReason = ...
    ExclusionReason;

%% ========================================================================
% MODEL SELECTION MASK
% ========================================================================

ModelSelectionMask = ...
    FastEventAudit(:,{ ...
    'CaptureID', ...
    'CommandCurrent_mA', ...
    'CaptureWithinAttempt', ...
    'PulseNumber', ...
    'CommandEvent', ...
    'TransitionClass', ...
    'PhysicalRegime', ...
    'WaveformOutlier', ...
    'MetricOutlier', ...
    'CaptureOutlierQC', ...
    'RecommendedForFastModel', ...
    'RecommendedForStrictSensitivityCheck', ...
    'ExclusionReason'});

%% ========================================================================
% MISSING PHYSICAL EDGES FROM STAGE 2
% ========================================================================

if all(ismember( ...
        ["PhysicalEdgeObserved","AcceptedResponse","CommandClass"], ...
        string(E2.Properties.VariableNames)))

    missingMask = ...
        E2.AcceptedResponse & ...
        ~E2.PhysicalEdgeObserved;

    MissingPhysicalEdges = ...
        E2(missingMask,:);

else

    MissingPhysicalEdges = table();
end

%% ========================================================================
% REGIME SUMMARY
% ========================================================================

regimes = unique(PhysicalRegime);

summaryRows = cell(numel(currents)*numel(regimes),1);

r = 0;

for k = 1:numel(currents)

    for q = 1:numel(regimes)

        m = ...
            A.CommandCurrent_mA==currents(k) & ...
            PhysicalRegime==regimes(q);

        if ~any(m)
            continue;
        end

        r = r+1;

        summaryRows{r} = table( ...
            currents(k), ...
            regimes(q), ...
            nnz(m), ...
            nnz(m & RecommendedForFastModel), ...
            'VariableNames',{ ...
            'CommandCurrent_mA', ...
            'PhysicalRegime', ...
            'NEvents', ...
            'NRecommendedForFastModel'});
    end
end

summaryRows = summaryRows(~cellfun(@isempty,summaryRows));

if isempty(summaryRows)
    RegimeSummary = table();
else
    RegimeSummary = vertcat(summaryRows{:});
end

%% ========================================================================
% SAVE OUTPUTS
% ========================================================================

writetable( ...
    FastEventAudit, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3A_FastEventAudit.csv"));

writetable( ...
    ModelSelectionMask, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3A_ModelSelectionMask.csv"));

writetable( ...
    CaptureAudit, ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3A_CaptureAudit.csv"));

if ~isempty(MissingPhysicalEdges)

    writetable( ...
        MissingPhysicalEdges, ...
        fullfile(cfg.OUTPUT_FOLDER,"Stage3A_MissingPhysicalEdges.csv"));
end

if ~isempty(RegimeSummary)

    writetable( ...
        RegimeSummary, ...
        fullfile(cfg.OUTPUT_FOLDER,"Stage3A_RegimeSummary.csv"));
end

audit = struct();

audit.processingStage = ...
    "Stage3A_FastTransitionOutlierAnalysis";

audit.sourceStage3 = ...
    cfg.STAGE3_FILE;

audit.sourceStage2 = ...
    stage2Path;

audit.fastTime_us = ...
    tFast_us;

audit.fastEventAudit = ...
    FastEventAudit;

audit.modelSelectionMask = ...
    ModelSelectionMask;

audit.captureAudit = ...
    CaptureAudit;

audit.missingPhysicalEdges = ...
    MissingPhysicalEdges;

audit.regimeSummary = ...
    RegimeSummary;

audit.settings = cfg;

save( ...
    fullfile(cfg.OUTPUT_FOLDER,"Stage3A_FastTransitionAudit.mat"), ...
    "audit", ...
    "FastEventAudit", ...
    "ModelSelectionMask", ...
    "CaptureAudit", ...
    "MissingPhysicalEdges", ...
    "RegimeSummary", ...
    "cfg", ...
    "-v7.3");

%% ========================================================================
% PLOTS
% ========================================================================

OpenXstimFastOutlier_PlotDiagnostics( ...
    tFast_us, ...
    Y, ...
    FastEventAudit, ...
    CaptureAudit, ...
    RegimeSummary, ...
    cfg);

%% ========================================================================
% FINAL CONSOLE SUMMARY
% ========================================================================

fprintf("\n============================================================\n");
fprintf("STAGE 3A COMPLETE\n");
fprintf("============================================================\n");

fprintf("\nEVENT-LEVEL QC\n");
fprintf("Waveform outliers             : %d\n",nnz(WaveformOutlier));
fprintf("Metric outliers               : %d\n",nnz(MetricOutlier));
fprintf("Boundary duration warnings    : %d\n",nnz(BoundaryDurationWarning));

fprintf("\nCAPTURE-LEVEL QC\n");
fprintf("Capture outliers              : %d / %d\n", ...
    nnz(CaptureAudit.CaptureOutlierQC),height(CaptureAudit));

if any(CaptureAudit.CaptureOutlierQC)

    disp(CaptureAudit( ...
        CaptureAudit.CaptureOutlierQC, ...
        {'CaptureID','CommandCurrent_mA','CaptureWithinAttempt', ...
        'MeanT10_90_us','CaptureMeanWaveformRMSE', ...
        'CaptureT1090Outlier','CaptureWaveformOutlier'}));
end

fprintf("\nPHYSICAL REGIMES FOR BIPOLAR EVENTS\n");

bipolarRegimes = unique(PhysicalRegime(A.IsBipolar));

for q = 1:numel(bipolarRegimes)

    rg = bipolarRegimes(q);

    fprintf("  %-28s : %4d\n", ...
        rg, ...
        nnz(A.IsBipolar & PhysicalRegime==rg));
end

fprintf("\nFAST MODEL RECOMMENDATIONS\n");
fprintf("Observed bipolar events       : %d\n",nnz(A.IsBipolar));
fprintf("Recommended primary set       : %d\n", ...
    nnz(RecommendedForFastModel));
fprintf("Recommended strict set        : %d\n", ...
    nnz(RecommendedForStrictSensitivityCheck));

fprintf("\nRecommended primary set by current:\n");

for k = 1:numel(currents)

    m = A.CommandCurrent_mA==currents(k) & A.IsBipolar;

    fprintf("  %5.1f mA p-p : %3d / %3d\n", ...
        currents(k), ...
        nnz(m & RecommendedForFastModel), ...
        nnz(m));
end

fprintf("\nMissing physical edges recorded from Stage 2: %d\n", ...
    height(MissingPhysicalEdges));

fprintf("\nOutput folder:\n%s\n",cfg.OUTPUT_FOLDER);

fprintf("\nIMPORTANT:\n");
fprintf("Stage 3A has not deleted or modified any Stage 3 data.\n");
fprintf("Stage 5 should use RecommendedForFastModel as the primary fit mask,\n");
fprintf("and RecommendedForStrictSensitivityCheck for a sensitivity analysis.\n");
fprintf("Stage 4 may proceed independently while preserving compliance-affected\n");
fprintf("phases rather than discarding them.\n");

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function z = robustZ(x)

x = x(:);

z = NaN(size(x));

good = isfinite(x);

if nnz(good)<3
    return;
end

xg = x(good);

med = median(xg);
madRaw = median(abs(xg-med));

if madRaw>0

    zg = 0.67448975*(xg-med)/madRaw;

else

    s = std(xg);

    if isfinite(s) && s>0
        zg = (xg-med)/s;
    else
        zg = zeros(size(xg));
    end
end

z(good) = zg;

end
