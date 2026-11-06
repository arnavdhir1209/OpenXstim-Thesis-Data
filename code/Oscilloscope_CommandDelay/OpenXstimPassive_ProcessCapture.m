function O = OpenXstimPassive_ProcessCapture( ...
    stage2ResultFile,modelTime_us,FastAudit,cfg)
% Process one capture into 40 sign-corrected active passive phases.

S = load(stage2ResultFile);

if ~isfield(S,"results")
    error("Per-capture Stage 2 MAT must contain variable 'results'.");
end

R2 = S.results;

if ~isfield(R2,"physicalEvents")
    error("Stage 2 result has no physicalEvents table.");
end

if ~isfield(R2,"csvPath") || ~isfile(R2.csvPath)
    error("Raw CSV referenced by Stage 2 cannot be found.");
end

E = R2.physicalEvents;

requiredCols = [ ...
    "CaptureID", ...
    "CommandCurrent_mA", ...
    "CommandEvent", ...
    "CommandClass", ...
    "AcceptedResponse", ...
    "PhysicalEdgeObserved", ...
    "ResponseTimeSource", ...
    "CommandTime_s", ...
    "ResponseTime_s"];

if ~all(ismember(requiredCols,string(E.Properties.VariableNames)))
    error("Stage 2 physicalEvents table is missing required columns.");
end

m = ...
    E.AcceptedResponse & ...
    isfinite(E.ResponseTime_s);

E = E(m,:);

[~,ord] = sort(E.CommandEvent);
E = E(ord,:);

if height(E)<41
    error("Only %d accepted command events are available; expected 41.",height(E));
end

% Use the selected packet only. Stage 2 should already contain 41 events.
E = E(1:41,:);

[data,t,Ts] = loadRigolMemoryCSV(string(R2.csvPath));

if size(data,2)<cfg.OUTPUT_CHANNEL
    error("CSV does not contain requested CH3 output.");
end

Iraw = 1000*data(:,cfg.OUTPUT_CHANNEL)/cfg.R_LOAD_OHM;

Fs = 1/Ts;

slowSmoothSamples = max(3,round(cfg.SLOW_SMOOTH_US*1e-6*Fs));

if mod(slowSmoothSamples,2)==0
    slowSmoothSamples = slowSmoothSamples+1;
end

collapseSmoothSamples = max(3,round(cfg.COLLAPSE_RATE_SMOOTH_US/cfg.MODEL_DT_US));

if mod(collapseSmoothSamples,2)==0
    collapseSmoothSamples = collapseSmoothSamples+1;
end

nPhasesExpected = 40;
nGrid = numel(modelTime_us);

currentModel_mA = NaN(nGrid,nPhasesExpected);
normalizedModel = NaN(nGrid,nPhasesExpected);
chargeModel_uC = NaN(nGrid,nPhasesExpected);

% Metadata
CaptureID = NaN(nPhasesExpected,1);
AttemptNumber = repmat(R2.attemptNumber,nPhasesExpected,1);
CommandCurrent_mA = NaN(nPhasesExpected,1);
CaptureWithinAttempt = repmat(R2.captureWithinAttempt,nPhasesExpected,1);

PhaseNumber = (1:nPhasesExpected).';
PulseNumber = ceil(PhaseNumber/2);

Polarity = strings(nPhasesExpected,1);
PolaritySign = NaN(nPhasesExpected,1);

StartCommandEvent = NaN(nPhasesExpected,1);
EndCommandEvent = NaN(nPhasesExpected,1);

StartTransitionClass = strings(nPhasesExpected,1);
EndTransitionClass = strings(nPhasesExpected,1);

StartPhysicalEdgeObserved = false(nPhasesExpected,1);
EndPhysicalEdgeObserved = false(nPhasesExpected,1);

StartResponseTimeSource = strings(nPhasesExpected,1);
EndResponseTimeSource = strings(nPhasesExpected,1);

StartResponseTime_s = NaN(nPhasesExpected,1);
EndResponseTime_s = NaN(nPhasesExpected,1);

FullPhaseDuration_us = NaN(nPhasesExpected,1);
UsableDuration_us = NaN(nPhasesExpected,1);

ReferenceCurrent_mA = NaN(nPhasesExpected,1);
EndCurrent_mA = NaN(nPhasesExpected,1);
EndNormalized = NaN(nPhasesExpected,1);
MinimumNormalized = NaN(nPhasesExpected,1);
CurrentLoss_pct = NaN(nPhasesExpected,1);

EarlySlope_per_ms = NaN(nPhasesExpected,1);
LateSlope_per_ms = NaN(nPhasesExpected,1);
MaxCollapseRate_per_ms = NaN(nPhasesExpected,1);

TimeTo90_us = NaN(nPhasesExpected,1);
TimeTo75_us = NaN(nPhasesExpected,1);
TimeTo50_us = NaN(nPhasesExpected,1);
TimeTo25_us = NaN(nPhasesExpected,1);

ChargeTo90_uC = NaN(nPhasesExpected,1);
ChargeTo75_uC = NaN(nPhasesExpected,1);
ChargeTo50_uC = NaN(nPhasesExpected,1);
ChargeTo25_uC = NaN(nPhasesExpected,1);

TerminalCharge_uC = NaN(nPhasesExpected,1);
EstimatedDeltaVcEnd_V = NaN(nPhasesExpected,1);

ModelGridTruncated = false(nPhasesExpected,1);

NextPhysicalRegime = strings(nPhasesExpected,1);
NextRecommendedForFastModel = false(nPhasesExpected,1);

PassiveRegime = strings(nPhasesExpected,1);

ValidPhase = false(nPhasesExpected,1);
QualityReason = strings(nPhasesExpected,1);

for p = 1:nPhasesExpected

    startEvent = E(p,:);
    endEvent = E(p+1,:);

    startClass = string(startEvent.CommandClass);
    endClass = string(endEvent.CommandClass);

    if startClass=="zero_to_pos" || startClass=="neg_to_pos"

        pol = "positive";
        polSign = +1;

    elseif startClass=="pos_to_neg"

        pol = "negative";
        polSign = -1;

    else

        QualityReason(p) = "invalid_phase_start_class";
        continue;
    end

    tStart = startEvent.ResponseTime_s;
    tEnd = endEvent.ResponseTime_s;

    CaptureID(p) = startEvent.CaptureID;
    CommandCurrent_mA(p) = startEvent.CommandCurrent_mA;

    Polarity(p) = pol;
    PolaritySign(p) = polSign;

    StartCommandEvent(p) = startEvent.CommandEvent;
    EndCommandEvent(p) = endEvent.CommandEvent;

    StartTransitionClass(p) = startClass;
    EndTransitionClass(p) = endClass;

    StartPhysicalEdgeObserved(p) = startEvent.PhysicalEdgeObserved;
    EndPhysicalEdgeObserved(p) = endEvent.PhysicalEdgeObserved;

    StartResponseTimeSource(p) = string(startEvent.ResponseTimeSource);
    EndResponseTimeSource(p) = string(endEvent.ResponseTimeSource);

    StartResponseTime_s(p) = tStart;
    EndResponseTime_s(p) = tEnd;

    FullPhaseDuration_us(p) = (tEnd-tStart)*1e6;

    usableStart = tStart + cfg.START_GUARD_US*1e-6;
    usableEnd = tEnd - cfg.END_GUARD_US*1e-6;

    UsableDuration_us(p) = (usableEnd-usableStart)*1e6;

    if ~isfinite(usableStart) || ~isfinite(usableEnd) || usableEnd<=usableStart

        QualityReason(p) = "invalid_phase_window";
        continue;
    end

    mPhase = t>=usableStart & t<=usableEnd;

    if nnz(mPhase)<20

        QualityReason(p) = "too_few_phase_samples";
        continue;
    end

    localTime_us = (t(mPhase)-usableStart)*1e6;

    Iphase = polSign*Iraw(mPhase);

    Ismooth = movmean( ...
        Iphase, ...
        slowSmoothSamples, ...
        'omitnan');

    firstFinite = find(isfinite(Ismooth),1,'first');

    if isempty(firstFinite)

        QualityReason(p) = "no_finite_phase_current";
        continue;
    end

    Iref = Ismooth(firstFinite);

    ReferenceCurrent_mA(p) = Iref;

    if ~isfinite(Iref) || Iref<cfg.MIN_REFERENCE_CURRENT_mA

        QualityReason(p) = "reference_current_too_small";
        continue;
    end

    D = Ismooth/Iref;

    % Enforce the exact normalization convention.
    D(firstFinite) = 1;

    % Delivered charge magnitude. Tiny negative noise after strong collapse
    % is clipped only for the charge integral, not for the normalized trace.
    Icharge = max(Ismooth,0);

    q_uC = cumtrapz(localTime_us,Icharge)/1000;

    currentModel_mA(:,p) = interp1( ...
        localTime_us, ...
        Ismooth, ...
        modelTime_us, ...
        'linear', ...
        NaN);

    normalizedModel(:,p) = interp1( ...
        localTime_us, ...
        D, ...
        modelTime_us, ...
        'linear', ...
        NaN);

    chargeModel_uC(:,p) = interp1( ...
        localTime_us, ...
        q_uC, ...
        modelTime_us, ...
        'linear', ...
        NaN);

    finiteD = isfinite(D);

    if ~any(finiteD)

        QualityReason(p) = "normalization_failed";
        continue;
    end

    lastFinite = find(finiteD,1,'last');

    EndCurrent_mA(p) = Ismooth(lastFinite);
    EndNormalized(p) = D(lastFinite);
    MinimumNormalized(p) = min(D(finiteD));

    CurrentLoss_pct(p) = ...
        100*(1-EndNormalized(p));

    % Early normalized slope.
    earlyMask = ...
        localTime_us>=cfg.EARLY_SLOPE_START_US & ...
        localTime_us<=cfg.EARLY_SLOPE_END_US & ...
        isfinite(D);

    if nnz(earlyMask)>=5

        coeff = polyfit( ...
            localTime_us(earlyMask)/1000, ...
            D(earlyMask), ...
            1);

        EarlySlope_per_ms(p) = coeff(1);
    end

    % Late normalized slope over the last requested interval.
    lateStart = max( ...
        0, ...
        localTime_us(lastFinite)-cfg.LATE_SLOPE_WINDOW_US);

    lateMask = ...
        localTime_us>=lateStart & ...
        localTime_us<=localTime_us(lastFinite) & ...
        isfinite(D);

    if nnz(lateMask)>=5

        coeff = polyfit( ...
            localTime_us(lateMask)/1000, ...
            D(lateMask), ...
            1);

        LateSlope_per_ms(p) = coeff(1);
    end

    % Strongest smoothed negative normalized derivative.
    t_ms = localTime_us/1000;

    dDdt = gradient(D,t_ms);

    dDdtSmooth = movmean( ...
        dDdt, ...
        max(3,round(cfg.COLLAPSE_RATE_SMOOTH_US/median(diff(localTime_us)))), ...
        'omitnan');

    if any(isfinite(dDdtSmooth))

        MaxCollapseRate_per_ms(p) = ...
            max(0,-min(dDdtSmooth,[],'omitnan'));
    end

    % Threshold times + charge at threshold.
    [TimeTo90_us(p),ChargeTo90_uC(p)] = ...
        thresholdTimeCharge(localTime_us,D,q_uC,0.90);

    [TimeTo75_us(p),ChargeTo75_uC(p)] = ...
        thresholdTimeCharge(localTime_us,D,q_uC,0.75);

    [TimeTo50_us(p),ChargeTo50_uC(p)] = ...
        thresholdTimeCharge(localTime_us,D,q_uC,0.50);

    [TimeTo25_us(p),ChargeTo25_uC(p)] = ...
        thresholdTimeCharge(localTime_us,D,q_uC,0.25);

    TerminalCharge_uC(p) = q_uC(lastFinite);

    EstimatedDeltaVcEnd_V(p) = ...
        TerminalCharge_uC(p)/cfg.BLOCKING_CAP_UF;

    ModelGridTruncated(p) = ...
        localTime_us(lastFinite)>modelTime_us(end);

    % Descriptive slow-regime label.
    if MinimumNormalized(p)>cfg.DROOP_ONLY_MIN_D

        PassiveRegime(p) = "DROOP_ONLY";

    elseif MinimumNormalized(p)>cfg.STRONG_COLLAPSE_MAX_D

        PassiveRegime(p) = "PARTIAL_COLLAPSE";

    else

        PassiveRegime(p) = "STRONG_COLLAPSE";
    end

    % Link phase end to the next Stage 3A physical regime when available.
    if ~isempty(FastAudit)

        ma = ...
            FastAudit.CaptureID==CaptureID(p) & ...
            FastAudit.CommandEvent==EndCommandEvent(p);

        arow = find(ma,1,'first');

        if ~isempty(arow)

            NextPhysicalRegime(p) = ...
                string(FastAudit.PhysicalRegime(arow));

            NextRecommendedForFastModel(p) = ...
                FastAudit.RecommendedForFastModel(arow);

        elseif ~EndPhysicalEdgeObserved(p)

            NextPhysicalRegime(p) = ...
                "NO_PHYSICAL_EDGE";

        else

            NextPhysicalRegime(p) = ...
                "NOT_IN_STAGE3A_AUDIT";
        end

    else

        NextPhysicalRegime(p) = ...
            "STAGE3A_NOT_LOADED";
    end

    ValidPhase(p) = true;
    QualityReason(p) = "pass";
end

PhaseMetrics = table( ...
    CaptureID, ...
    AttemptNumber, ...
    CommandCurrent_mA, ...
    CaptureWithinAttempt, ...
    PhaseNumber, ...
    PulseNumber, ...
    Polarity, ...
    PolaritySign, ...
    StartCommandEvent, ...
    EndCommandEvent, ...
    StartTransitionClass, ...
    EndTransitionClass, ...
    StartPhysicalEdgeObserved, ...
    EndPhysicalEdgeObserved, ...
    StartResponseTimeSource, ...
    EndResponseTimeSource, ...
    StartResponseTime_s, ...
    EndResponseTime_s, ...
    FullPhaseDuration_us, ...
    UsableDuration_us, ...
    ReferenceCurrent_mA, ...
    EndCurrent_mA, ...
    EndNormalized, ...
    MinimumNormalized, ...
    CurrentLoss_pct, ...
    EarlySlope_per_ms, ...
    LateSlope_per_ms, ...
    MaxCollapseRate_per_ms, ...
    TimeTo90_us, ...
    TimeTo75_us, ...
    TimeTo50_us, ...
    TimeTo25_us, ...
    ChargeTo90_uC, ...
    ChargeTo75_uC, ...
    ChargeTo50_uC, ...
    ChargeTo25_uC, ...
    TerminalCharge_uC, ...
    EstimatedDeltaVcEnd_V, ...
    ModelGridTruncated, ...
    PassiveRegime, ...
    NextPhysicalRegime, ...
    NextRecommendedForFastModel, ...
    ValidPhase, ...
    QualityReason);

O = struct();

O.phaseMetrics = PhaseMetrics;
O.currentModel_mA = currentModel_mA;
O.normalizedModel = normalizedModel;
O.chargeModel_uC = chargeModel_uC;

end

%% ========================================================================
% HELPERS
% ========================================================================

function [tCross_us,qCross_uC] = thresholdTimeCharge(t_us,D,q_uC,level)

tCross_us = NaN;
qCross_uC = NaN;

m = isfinite(t_us) & isfinite(D) & isfinite(q_uC);

t = t_us(m);
y = D(m);
q = q_uC(m);

if numel(t)<2
    return;
end

if y(1)<=level

    tCross_us = t(1);
    qCross_uC = q(1);
    return;
end

idx = find( ...
    y(1:end-1)>level & ...
    y(2:end)<=level, ...
    1, ...
    'first');

if isempty(idx)
    return;
end

if y(idx+1)==y(idx)

    alpha = 1;

else

    alpha = ...
        (level-y(idx))/(y(idx+1)-y(idx));
end

tCross_us = ...
    t(idx)+alpha*(t(idx+1)-t(idx));

qCross_uC = ...
    q(idx)+alpha*(q(idx+1)-q(idx));

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
