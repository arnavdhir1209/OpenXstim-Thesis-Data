function O = OpenXstimCapState_ProcessCapture( ...
    stage2ResultFile,phaseMetrics,normalizedModel,modelTime_us, ...
    stage4cfg,cfg)
% Reconstruct continuous signed charge across one selected packet and map
% Stage 4 passive thresholds onto that state trajectory.

S2 = load(stage2ResultFile);

if ~isfield(S2,"results")
    error("Stage 2 per-capture MAT must contain variable 'results'.");
end

R2 = S2.results;

if ~isfield(R2,"physicalEvents")
    error("Stage 2 result does not contain physicalEvents.");
end

if ~isfield(R2,"csvPath") || ~isfile(R2.csvPath)
    error("Raw CSV referenced by Stage 2 cannot be found.");
end

E = R2.physicalEvents;

m = ...
    E.AcceptedResponse & ...
    isfinite(E.ResponseTime_s);

E = E(m,:);

[~,ord] = sort(E.CommandEvent);
E = E(ord,:);

if height(E)<41
    error("Only %d accepted events are available; expected 41.",height(E));
end

E = E(1:41,:);

[data,t,Ts] = loadRigolMemoryCSV(string(R2.csvPath));

if size(data,2)<3
    error("Raw CSV does not contain CH3.");
end

Iraw_mA = 1000*data(:,3)/cfg.R_LOAD_OHM;

packetStart_s = E.ResponseTime_s(1);
packetEnd_s = E.ResponseTime_s(end);

if ~all(isfinite([packetStart_s,packetEnd_s])) || packetEnd_s<=packetStart_s
    error("Invalid packet timing.");
end

% Capture metadata is needed by the baseline/exclusion audit below.
captureID = phaseMetrics.CaptureID(1);
attemptNumber = phaseMetrics.AttemptNumber(1);
commandCurrent_mA = phaseMetrics.CommandCurrent_mA(1);
captureWithinAttempt = phaseMetrics.CaptureWithinAttempt(1);

%% ========================================================================
% BASELINE CORRECTION
% ========================================================================

% The safest zero-output interval is inside the FIRST command-to-response
% latency of the selected packet. The firmware/debug command has already
% changed, but the physical CH3 response has not yet started.
%
% This avoids the failure mode of the original Stage 4A baseline estimator:
% a fixed window before the selected packet could overlap a neighbouring
% partial packet caught elsewhere in the oscilloscope acquisition.

firstCommand_s = E.CommandTime_s(1);
firstResponse_s = E.ResponseTime_s(1);

baselineMethod = "FIRST_COMMAND_RESPONSE_LATENCY";
baselineWindowStart_s = NaN;
baselineWindowEnd_s = NaN;
baseline_mA = NaN;
baselineNoiseRobustSD_mA = NaN;

delay_s = firstResponse_s-firstCommand_s;

useLatencyWindow = ...
    isfinite(delay_s) && ...
    delay_s>0;

if useLatencyWindow

    baselineWindowStart_s = ...
        firstCommand_s + ...
        cfg.BASELINE_LATENCY_START_FRACTION*delay_s;

    baselineWindowEnd_s = ...
        firstCommand_s + ...
        cfg.BASELINE_LATENCY_END_FRACTION*delay_s;

    latencyWindow_us = ...
        (baselineWindowEnd_s-baselineWindowStart_s)*1e6;

    if latencyWindow_us<cfg.BASELINE_MIN_WINDOW_US
        useLatencyWindow = false;
    end
end

if useLatencyWindow

    mbase = ...
        t>=baselineWindowStart_s & ...
        t<=baselineWindowEnd_s & ...
        isfinite(Iraw_mA);

    if nnz(mbase)<20
        useLatencyWindow = false;
    end
end

if useLatencyWindow

    xbase = Iraw_mA(mbase);

    baseline_mA = ...
        median(xbase,'omitnan');

    baselineNoiseRobustSD_mA = ...
        robustSigmaLocal(xbase);

else

    baselineMethod = "QUIET_WINDOW_FALLBACK";

    [baseline_mA, ...
        baselineNoiseRobustSD_mA, ...
        baselineWindowStart_s, ...
        baselineWindowEnd_s] = ...
        estimateQuietBaselineFallback( ...
        t, ...
        Iraw_mA, ...
        firstCommand_s, ...
        packetStart_s, ...
        packetEnd_s, ...
        cfg);
end

if ~isfinite(baseline_mA)
    error("Could not estimate a finite CH3 zero-current baseline.");
end

baselineOffsetPass = ...
    abs(baseline_mA)<=cfg.BASELINE_OFFSET_MAX_mA;

baselineNoiseWarning = ...
    baselineNoiseRobustSD_mA>cfg.BASELINE_NOISE_WARN_mA;

knownCaptureExclusion = ...
    ismember(captureID,cfg.EXCLUDE_CAPTURE_IDS);

IncludedInChargeAnalysis = ...
    baselineOffsetPass && ...
    ~knownCaptureExclusion;

if knownCaptureExclusion
    ExclusionReason = "KNOWN_BAD_CAPTURE";
elseif ~baselineOffsetPass
    ExclusionReason = "NONZERO_BASELINE_OFFSET";
else
    ExclusionReason = "";
end

% Compatibility alias for older downstream inspection. This now refers only
% to the offset validity condition, not to elevated noise.
baselineSanityPass = baselineOffsetPass;

Icorr_mA = Iraw_mA-baseline_mA;

%% ========================================================================
% CONTINUOUS SIGNED CHARGE THROUGH PACKET
% ========================================================================

mpacket = ...
    t>=packetStart_s & ...
    t<=packetEnd_s;

tPacket_s = t(mpacket);
Ipacket_mA = Icorr_mA(mpacket);

if numel(tPacket_s)<100
    error("Packet current trace is unexpectedly short.");
end

tPacket_rel_ms = ...
    (tPacket_s-packetStart_s)*1000;

% 1 mA * 1 s = 1000 uC.
qRel_uC = ...
    cumtrapz(tPacket_s,Ipacket_mA)*1000;

qMin_uC = min(qRel_uC,[],'omitnan');
qMax_uC = max(qRel_uC,[],'omitnan');

qMid_uC = 0.5*(qMin_uC+qMax_uC);

qCentered_uC = ...
    qRel_uC-qMid_uC;

vCenteredProxy_V = ...
    qCentered_uC/cfg.BLOCKING_CAP_UF;

qSpan_uC = qMax_uC-qMin_uC;
vSpanProxy_V = qSpan_uC/cfg.BLOCKING_CAP_UF;

netPacketCharge_uC = ...
    qRel_uC(end)-qRel_uC(1);

%% ========================================================================
% MAP PHASE METRICS TO CONTINUOUS CHARGE STATE
% ========================================================================

P = phaseMetrics;

nPhases = height(P);

if width(normalizedModel)~=nPhases
    error("Stage 4 normalizedModel columns are not aligned with phase table.");
end

% New Stage 4A features.
ChargeStateStartRel_uC = NaN(nPhases,1);
ChargeStateEndRel_uC = NaN(nPhases,1);

ChargeStateStartCentered_uC = NaN(nPhases,1);
ChargeStateEndCentered_uC = NaN(nPhases,1);

OrientedStateStart_uC = NaN(nPhases,1);
OrientedStateEnd_uC = NaN(nPhases,1);

VoltageStateStartProxy_V = NaN(nPhases,1);
VoltageStateEndProxy_V = NaN(nPhases,1);

KneeTime_us = NaN(nPhases,1);
KneeCurrentNormalized = NaN(nPhases,1);

ChargeStateKneeRel_uC = NaN(nPhases,1);
ChargeStateKneeCentered_uC = NaN(nPhases,1);
OrientedStateKnee_uC = NaN(nPhases,1);
VoltageStateKneeProxy_V = NaN(nPhases,1);

ChargeState90Rel_uC = NaN(nPhases,1);
ChargeState75Rel_uC = NaN(nPhases,1);
ChargeState50Rel_uC = NaN(nPhases,1);
ChargeState25Rel_uC = NaN(nPhases,1);

ChargeState90Centered_uC = NaN(nPhases,1);
ChargeState75Centered_uC = NaN(nPhases,1);
ChargeState50Centered_uC = NaN(nPhases,1);
ChargeState25Centered_uC = NaN(nPhases,1);

OrientedState90_uC = NaN(nPhases,1);
OrientedState75_uC = NaN(nPhases,1);
OrientedState50_uC = NaN(nPhases,1);
OrientedState25_uC = NaN(nPhases,1);

VoltageState90Proxy_V = NaN(nPhases,1);
VoltageState75Proxy_V = NaN(nPhases,1);
VoltageState50Proxy_V = NaN(nPhases,1);
VoltageState25Proxy_V = NaN(nPhases,1);

for p = 1:nPhases

    usableStart_s = ...
        P.StartResponseTime_s(p) ...
        + stage4cfg.START_GUARD_US*1e-6;

    usableEnd_s = ...
        P.EndResponseTime_s(p) ...
        - stage4cfg.END_GUARD_US*1e-6;

    [q0Rel,q0Centered] = ...
        stateAtTime( ...
        usableStart_s, ...
        tPacket_s, ...
        qRel_uC, ...
        qCentered_uC);

    [q1Rel,q1Centered] = ...
        stateAtTime( ...
        usableEnd_s, ...
        tPacket_s, ...
        qRel_uC, ...
        qCentered_uC);

    ChargeStateStartRel_uC(p) = q0Rel;
    ChargeStateEndRel_uC(p) = q1Rel;

    ChargeStateStartCentered_uC(p) = q0Centered;
    ChargeStateEndCentered_uC(p) = q1Centered;

    OrientedStateStart_uC(p) = ...
        P.PolaritySign(p)*q0Centered;

    OrientedStateEnd_uC(p) = ...
        P.PolaritySign(p)*q1Centered;

    VoltageStateStartProxy_V(p) = ...
        q0Centered/cfg.BLOCKING_CAP_UF;

    VoltageStateEndProxy_V(p) = ...
        q1Centered/cfg.BLOCKING_CAP_UF;

    % ---------------------------------------------------------------
    % Threshold states
    % ---------------------------------------------------------------

    [ChargeState90Rel_uC(p), ...
        ChargeState90Centered_uC(p), ...
        OrientedState90_uC(p), ...
        VoltageState90Proxy_V(p)] = ...
        thresholdState( ...
        P.TimeTo90_us(p), ...
        usableStart_s, ...
        P.PolaritySign(p), ...
        tPacket_s, ...
        qRel_uC, ...
        qCentered_uC, ...
        cfg.BLOCKING_CAP_UF);

    [ChargeState75Rel_uC(p), ...
        ChargeState75Centered_uC(p), ...
        OrientedState75_uC(p), ...
        VoltageState75Proxy_V(p)] = ...
        thresholdState( ...
        P.TimeTo75_us(p), ...
        usableStart_s, ...
        P.PolaritySign(p), ...
        tPacket_s, ...
        qRel_uC, ...
        qCentered_uC, ...
        cfg.BLOCKING_CAP_UF);

    [ChargeState50Rel_uC(p), ...
        ChargeState50Centered_uC(p), ...
        OrientedState50_uC(p), ...
        VoltageState50Proxy_V(p)] = ...
        thresholdState( ...
        P.TimeTo50_us(p), ...
        usableStart_s, ...
        P.PolaritySign(p), ...
        tPacket_s, ...
        qRel_uC, ...
        qCentered_uC, ...
        cfg.BLOCKING_CAP_UF);

    [ChargeState25Rel_uC(p), ...
        ChargeState25Centered_uC(p), ...
        OrientedState25_uC(p), ...
        VoltageState25Proxy_V(p)] = ...
        thresholdState( ...
        P.TimeTo25_us(p), ...
        usableStart_s, ...
        P.PolaritySign(p), ...
        tPacket_s, ...
        qRel_uC, ...
        qCentered_uC, ...
        cfg.BLOCKING_CAP_UF);

    % ---------------------------------------------------------------
    % Collapse-knee state
    % ---------------------------------------------------------------

    y = normalizedModel(:,p);

    if isfinite(P.TimeTo75_us(p))

        knee = findKnee( ...
            modelTime_us, ...
            y, ...
            cfg);

        if isfinite(knee.time_us)

            KneeTime_us(p) = knee.time_us;
            KneeCurrentNormalized(p) = knee.D;

            kneeAbs_s = ...
                usableStart_s+knee.time_us*1e-6;

            [qKneeRel,qKneeCentered] = ...
                stateAtTime( ...
                kneeAbs_s, ...
                tPacket_s, ...
                qRel_uC, ...
                qCentered_uC);

            ChargeStateKneeRel_uC(p) = qKneeRel;
            ChargeStateKneeCentered_uC(p) = qKneeCentered;

            OrientedStateKnee_uC(p) = ...
                P.PolaritySign(p)*qKneeCentered;

            VoltageStateKneeProxy_V(p) = ...
                qKneeCentered/cfg.BLOCKING_CAP_UF;
        end
    end
end

%% ========================================================================
% ADD CAPTURE CONSTANTS
% ========================================================================

BaselineCurrent_mA = repmat(baseline_mA,nPhases,1);
BaselineNoiseRobustSD_mA = repmat(baselineNoiseRobustSD_mA,nPhases,1);
BaselineMethod = repmat(baselineMethod,nPhases,1);
BaselineSanityPass = repmat(baselineSanityPass,nPhases,1);
BaselineOffsetPass = repmat(baselineOffsetPass,nPhases,1);
BaselineNoiseWarning = repmat(baselineNoiseWarning,nPhases,1);
KnownCaptureExclusion = repmat(knownCaptureExclusion,nPhases,1);

% IMPORTANT:
% Keep the capture-level scalar variables IncludedInChargeAnalysis and
% ExclusionReason unchanged for the one-row capture summary below.
% Use separate column-vector names for the phase table.
IncludedInChargeAnalysisCol = repmat(IncludedInChargeAnalysis,nPhases,1);
ExclusionReasonCol = repmat(ExclusionReason,nPhases,1);

BaselineWindowStart_s = repmat(baselineWindowStart_s,nPhases,1);
BaselineWindowEnd_s = repmat(baselineWindowEnd_s,nPhases,1);

CaptureChargeMin_uC = repmat(qMin_uC,nPhases,1);
CaptureChargeMax_uC = repmat(qMax_uC,nPhases,1);
CaptureChargeMid_uC = repmat(qMid_uC,nPhases,1);
CaptureChargeSpan_uC = repmat(qSpan_uC,nPhases,1);

CaptureVoltageSpanProxy_V = repmat(vSpanProxy_V,nPhases,1);

NetPacketCharge_uC = repmat(netPacketCharge_uC,nPhases,1);

%% ========================================================================
% PHASE TABLE
% ========================================================================

phaseStateMetrics = P;

phaseStateMetrics.BaselineCurrent_mA = ...
    BaselineCurrent_mA;

phaseStateMetrics.BaselineNoiseRobustSD_mA = ...
    BaselineNoiseRobustSD_mA;

phaseStateMetrics.BaselineMethod = ...
    BaselineMethod;

phaseStateMetrics.BaselineSanityPass = ...
    BaselineSanityPass;

phaseStateMetrics.BaselineOffsetPass = ...
    BaselineOffsetPass;

phaseStateMetrics.BaselineNoiseWarning = ...
    BaselineNoiseWarning;

phaseStateMetrics.KnownCaptureExclusion = ...
    KnownCaptureExclusion;

phaseStateMetrics.IncludedInChargeAnalysis = ...
    IncludedInChargeAnalysisCol;

phaseStateMetrics.ExclusionReason = ...
    ExclusionReasonCol;

phaseStateMetrics.BaselineWindowStart_s = ...
    BaselineWindowStart_s;

phaseStateMetrics.BaselineWindowEnd_s = ...
    BaselineWindowEnd_s;

phaseStateMetrics.CaptureChargeMin_uC = ...
    CaptureChargeMin_uC;

phaseStateMetrics.CaptureChargeMax_uC = ...
    CaptureChargeMax_uC;

phaseStateMetrics.CaptureChargeMid_uC = ...
    CaptureChargeMid_uC;

phaseStateMetrics.CaptureChargeSpan_uC = ...
    CaptureChargeSpan_uC;

phaseStateMetrics.CaptureVoltageSpanProxy_V = ...
    CaptureVoltageSpanProxy_V;

phaseStateMetrics.NetPacketCharge_uC = ...
    NetPacketCharge_uC;

phaseStateMetrics.ChargeStateStartRel_uC = ...
    ChargeStateStartRel_uC;

phaseStateMetrics.ChargeStateEndRel_uC = ...
    ChargeStateEndRel_uC;

phaseStateMetrics.ChargeStateStartCentered_uC = ...
    ChargeStateStartCentered_uC;

phaseStateMetrics.ChargeStateEndCentered_uC = ...
    ChargeStateEndCentered_uC;

phaseStateMetrics.OrientedStateStart_uC = ...
    OrientedStateStart_uC;

phaseStateMetrics.OrientedStateEnd_uC = ...
    OrientedStateEnd_uC;

phaseStateMetrics.VoltageStateStartProxy_V = ...
    VoltageStateStartProxy_V;

phaseStateMetrics.VoltageStateEndProxy_V = ...
    VoltageStateEndProxy_V;

phaseStateMetrics.KneeTime_us = ...
    KneeTime_us;

phaseStateMetrics.KneeCurrentNormalized = ...
    KneeCurrentNormalized;

phaseStateMetrics.ChargeStateKneeRel_uC = ...
    ChargeStateKneeRel_uC;

phaseStateMetrics.ChargeStateKneeCentered_uC = ...
    ChargeStateKneeCentered_uC;

phaseStateMetrics.OrientedStateKnee_uC = ...
    OrientedStateKnee_uC;

phaseStateMetrics.VoltageStateKneeProxy_V = ...
    VoltageStateKneeProxy_V;

phaseStateMetrics.ChargeState90Rel_uC = ...
    ChargeState90Rel_uC;

phaseStateMetrics.ChargeState75Rel_uC = ...
    ChargeState75Rel_uC;

phaseStateMetrics.ChargeState50Rel_uC = ...
    ChargeState50Rel_uC;

phaseStateMetrics.ChargeState25Rel_uC = ...
    ChargeState25Rel_uC;

phaseStateMetrics.ChargeState90Centered_uC = ...
    ChargeState90Centered_uC;

phaseStateMetrics.ChargeState75Centered_uC = ...
    ChargeState75Centered_uC;

phaseStateMetrics.ChargeState50Centered_uC = ...
    ChargeState50Centered_uC;

phaseStateMetrics.ChargeState25Centered_uC = ...
    ChargeState25Centered_uC;

phaseStateMetrics.OrientedState90_uC = ...
    OrientedState90_uC;

phaseStateMetrics.OrientedState75_uC = ...
    OrientedState75_uC;

phaseStateMetrics.OrientedState50_uC = ...
    OrientedState50_uC;

phaseStateMetrics.OrientedState25_uC = ...
    OrientedState25_uC;

phaseStateMetrics.VoltageState90Proxy_V = ...
    VoltageState90Proxy_V;

phaseStateMetrics.VoltageState75Proxy_V = ...
    VoltageState75Proxy_V;

phaseStateMetrics.VoltageState50Proxy_V = ...
    VoltageState50Proxy_V;

phaseStateMetrics.VoltageState25Proxy_V = ...
    VoltageState25Proxy_V;

%% ========================================================================
% CAPTURE SUMMARY
% ========================================================================

captureSummary = table( ...
    captureID, ...
    attemptNumber, ...
    commandCurrent_mA, ...
    captureWithinAttempt, ...
    baseline_mA, ...
    baselineNoiseRobustSD_mA, ...
    baselineMethod, ...
    baselineSanityPass, ...
    baselineOffsetPass, ...
    baselineNoiseWarning, ...
    knownCaptureExclusion, ...
    IncludedInChargeAnalysis, ...
    ExclusionReason, ...
    baselineWindowStart_s, ...
    baselineWindowEnd_s, ...
    qMin_uC, ...
    qMax_uC, ...
    qMid_uC, ...
    qSpan_uC, ...
    vSpanProxy_V, ...
    netPacketCharge_uC, ...
    'VariableNames',{ ...
    'CaptureID', ...
    'AttemptNumber', ...
    'CommandCurrent_mA', ...
    'CaptureWithinAttempt', ...
    'BaselineCurrent_mA', ...
    'BaselineNoiseRobustSD_mA', ...
    'BaselineMethod', ...
    'BaselineSanityPass', ...
    'BaselineOffsetPass', ...
    'BaselineNoiseWarning', ...
    'KnownCaptureExclusion', ...
    'IncludedInChargeAnalysis', ...
    'ExclusionReason', ...
    'BaselineWindowStart_s', ...
    'BaselineWindowEnd_s', ...
    'ChargeMinRel_uC', ...
    'ChargeMaxRel_uC', ...
    'ChargeMidRel_uC', ...
    'ChargeSpan_uC', ...
    'VoltageSpanProxy_V', ...
    'NetPacketCharge_uC'});

%% ========================================================================
% TRACE STRUCT
% ========================================================================

trace = struct();

trace.CaptureID = captureID;
trace.CommandCurrent_mA = commandCurrent_mA;
trace.CaptureWithinAttempt = captureWithinAttempt;

trace.time_ms = tPacket_rel_ms;
trace.current_mA = Ipacket_mA;

trace.qRel_uC = qRel_uC;
trace.qCentered_uC = qCentered_uC;
trace.vCenteredProxy_V = vCenteredProxy_V;

trace.packetStart_s = packetStart_s;
trace.packetEnd_s = packetEnd_s;

trace.baseline_mA = baseline_mA;
trace.baselineNoiseRobustSD_mA = baselineNoiseRobustSD_mA;
trace.baselineMethod = baselineMethod;
trace.baselineSanityPass = baselineSanityPass;
trace.baselineOffsetPass = baselineOffsetPass;
trace.baselineNoiseWarning = baselineNoiseWarning;
trace.knownCaptureExclusion = knownCaptureExclusion;
trace.IncludedInChargeAnalysis = IncludedInChargeAnalysis;
trace.ExclusionReason = ExclusionReason;
trace.baselineWindowStart_s = baselineWindowStart_s;
trace.baselineWindowEnd_s = baselineWindowEnd_s;

O = struct();

O.phaseStateMetrics = phaseStateMetrics;
O.captureSummary = captureSummary;
O.trace = trace;

end

%% ========================================================================
% HELPERS
% ========================================================================

function [qRel,qCentered] = stateAtTime(tAbs_s,tPacket_s,qRelTrace,qCenteredTrace)

qRel = NaN;
qCentered = NaN;

if ~isfinite(tAbs_s)
    return;
end

if tAbs_s<tPacket_s(1) || tAbs_s>tPacket_s(end)
    return;
end

qRel = interp1( ...
    tPacket_s, ...
    qRelTrace, ...
    tAbs_s, ...
    'linear');

qCentered = interp1( ...
    tPacket_s, ...
    qCenteredTrace, ...
    tAbs_s, ...
    'linear');

end

function [qRel,qCentered,qOriented,vProxy] = thresholdState( ...
    localTime_us,usableStart_s,polaritySign, ...
    tPacket_s,qRelTrace,qCenteredTrace,C_uF)

qRel = NaN;
qCentered = NaN;
qOriented = NaN;
vProxy = NaN;

if ~isfinite(localTime_us)
    return;
end

tAbs_s = ...
    usableStart_s+localTime_us*1e-6;

[qRel,qCentered] = ...
    stateAtTime( ...
    tAbs_s, ...
    tPacket_s, ...
    qRelTrace, ...
    qCenteredTrace);

if isfinite(qCentered)

    qOriented = ...
        polaritySign*qCentered;

    vProxy = ...
        qCentered/C_uF;
end

end

function knee = findKnee(modelTime_us,D,cfg)

knee = struct( ...
    'time_us',NaN, ...
    'D',NaN, ...
    'rate_per_ms',NaN);

m = ...
    isfinite(modelTime_us) & ...
    isfinite(D) & ...
    modelTime_us>=cfg.KNEE_SEARCH_START_US;

if nnz(m)<8
    return;
end

t = modelTime_us(m);
y = D(m);

dt_ms = median(diff(t))/1000;

if ~isfinite(dt_ms) || dt_ms<=0
    return;
end

dDdt = gradient(y,dt_ms);

smoothN = max(3,round(cfg.KNEE_DERIVATIVE_SMOOTH_US/median(diff(t))));

if mod(smoothN,2)==0
    smoothN = smoothN+1;
end

dDdt = movmean(dDdt,smoothN,'omitnan');

[minRate,idx] = min(dDdt,[],'omitnan');

if isempty(idx) || ~isfinite(minRate)
    return;
end

knee.time_us = t(idx);
knee.D = y(idx);
knee.rate_per_ms = -minRate;

end

function s = robustSigmaLocal(x)

x = x(isfinite(x));

if isempty(x)
    s = NaN;
    return;
end

med = median(x,'omitnan');
s = 1.4826*median(abs(x-med),'omitnan');

end

function [baseline_mA,noiseSD_mA,tStart_s,tEnd_s] = ...
    estimateQuietBaselineFallback( ...
    t,Iraw_mA,firstCommand_s,packetStart_s,packetEnd_s,cfg)
% Search outside the selected packet for the quietest short baseline
% interval. The score penalizes both nonzero level and noise.

window_s = cfg.BASELINE_FALLBACK_WINDOW_US*1e-6;
search_s = cfg.BASELINE_FALLBACK_SEARCH_US*1e-6;

candidateRegions = [ ...
    max(t(1),firstCommand_s-search_s), firstCommand_s; ...
    packetEnd_s, min(t(end),packetEnd_s+search_s)];

bestScore = Inf;

baseline_mA = NaN;
noiseSD_mA = NaN;
tStart_s = NaN;
tEnd_s = NaN;

for r = 1:size(candidateRegions,1)

    regionStart = candidateRegions(r,1);
    regionEnd = candidateRegions(r,2);

    if ~isfinite(regionStart) || ~isfinite(regionEnd) || ...
            regionEnd-regionStart<window_s
        continue;
    end

    starts = regionStart:window_s/2:(regionEnd-window_s);

    for sidx = 1:numel(starts)

        ws = starts(sidx);
        we = ws+window_s;

        m = ...
            t>=ws & ...
            t<=we & ...
            isfinite(Iraw_mA);

        if nnz(m)<20
            continue;
        end

        x = Iraw_mA(m);

        med = median(x,'omitnan');
        sig = robustSigmaLocal(x);

        % Baseline should be both quiet and near zero current.
        score = abs(med)+3*sig;

        if score<bestScore

            bestScore = score;

            baseline_mA = med;
            noiseSD_mA = sig;

            tStart_s = ws;
            tEnd_s = we;
        end
    end
end

end

function [data,t,Ts] = loadRigolMemoryCSV(path)

fid = fopen(path,'r');

if fid<0
    error("Could not open CSV.");
end

cleanup = onCleanup(@() fclose(fid));

header = fgetl(fid);

tok = regexp( ...
    header, ...
    't0\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
    'tokens','once');

if isempty(tok)
    error("Could not parse t0.");
end

t0 = str2double(tok{1});

tok = regexp( ...
    header, ...
    'tInc\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
    'tokens','once');

if isempty(tok)
    error("Could not parse tInc.");
end

Ts = str2double(tok{1});

data = readmatrix(path,'NumHeaderLines',1);

data(:,all(~isfinite(data),1)) = [];
data = data(any(isfinite(data),2),:);

t = t0+(0:size(data,1)-1).'*Ts;

end
