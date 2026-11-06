function O = OpenXstimFast_ProcessCapture(stage2ResultFile,fastTime_us,cfg)
% Normalize all physically observed accepted fast transitions in one capture.
%
% Returned primary fields remain the repeating bipolar dataset.
% Additional allTransition* fields contain all four physical transition
% classes for characterization only.

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

events = R2.physicalEvents;

requiredCols = [ ...
    "CaptureID", ...
    "CommandCurrent_mA", ...
    "PulseNumber", ...
    "CommandEvent", ...
    "CommandClass", ...
    "IsBipolar", ...
    "IsBoundary", ...
    "AcceptedResponse", ...
    "PhysicalEdgeObserved", ...
    "ResponseTimeSource", ...
    "CommandTime_s", ...
    "ResponseTime_s", ...
    "Delay_us"];

if ~all(ismember(requiredCols,string(events.Properties.VariableNames)))
    error("Stage 2 physicalEvents table is missing required columns.");
end

transitionClasses = [ ...
    "zero_to_pos", ...
    "pos_to_neg", ...
    "neg_to_pos", ...
    "neg_to_zero"];

allMask = ...
    events.AcceptedResponse & ...
    events.PhysicalEdgeObserved & ...
    isfinite(events.ResponseTime_s) & ...
    ismember(string(events.CommandClass),transitionClasses);

E = events(allMask,:);

if isempty(E)
    error("No accepted physically observed fast transitions.");
end

[~,ord] = sort(E.ResponseTime_s);
E = E(ord,:);

[data,t,Ts] = loadRigolMemoryCSV(string(R2.csvPath));

if size(data,2)<cfg.OUTPUT_CHANNEL
    error("CSV does not contain requested CH3 output.");
end

Iraw = 1000*data(:,cfg.OUTPUT_CHANNEL)/cfg.R_LOAD_OHM;

nEvents = height(E);
nFast = numel(fastTime_us);

CaptureID = E.CaptureID;
AttemptNumber = repmat(R2.attemptNumber,nEvents,1);
CommandCurrent_mA = E.CommandCurrent_mA;
CaptureWithinAttempt = repmat(R2.captureWithinAttempt,nEvents,1);

PulseNumber = E.PulseNumber;
CommandEvent = E.CommandEvent;
TransitionClass = string(E.CommandClass);

IsBipolar = E.IsBipolar;
IsBoundary = E.IsBoundary;

CommandTime_s = E.CommandTime_s;
ResponsePeakTime_s = E.ResponseTime_s;
CommandToGradientPeak_us = E.Delay_us;
ResponseTimeSource = string(E.ResponseTimeSource);

NativeFs_MSa_s = repmat((1/Ts)/1e6,nEvents,1);
NativeTs_us = repmat(Ts*1e6,nEvents,1);

I0star_mA = NaN(nEvents,1);
Ifstar_mA = NaN(nEvents,1);
LocalStep_mA = NaN(nEvents,1);
LocalStepMagnitude_mA = NaN(nEvents,1);
StepToCommandRatio = NaN(nEvents,1);

PreSlope_mA_per_ms = NaN(nEvents,1);
PostSlope_mA_per_ms = NaN(nEvents,1);
PreFitR2 = NaN(nEvents,1);
PostFitR2 = NaN(nEvents,1);

PreFitStart_us = NaN(nEvents,1);
PreFitEnd_us = NaN(nEvents,1);
PostFitStart_us = NaN(nEvents,1);
PostFitEnd_us = NaN(nEvents,1);

BaselineNormalizedMean = NaN(nEvents,1);
FinalNormalizedMean = NaN(nEvents,1);

T10_us = NaN(nEvents,1);
T50_us = NaN(nEvents,1);
T90_us = NaN(nEvents,1);
T10_90_us = NaN(nEvents,1);

CommandToT10_us = NaN(nEvents,1);
CommandToT50_us = NaN(nEvents,1);
CommandToT90_us = NaN(nEvents,1);

PeakNormalized = NaN(nEvents,1);
Overshoot_pct = NaN(nEvents,1);
SettlingFromT10_us = NaN(nEvents,1);

ValidEvent = false(nEvents,1);
QualityReason = strings(nEvents,1);

normalizedRawAll = NaN(nFast,nEvents);
normalizedDetrendedAll = NaN(nFast,nEvents);

metricSmoothSamples = max(3,round(cfg.METRIC_SMOOTH_US/cfg.COMMON_DT_US));

if mod(metricSmoothSamples,2)==0
    metricSmoothSamples = metricSmoothSamples+1;
end

for e = 1:nEvents

    tEdge = ResponsePeakTime_s(e);

    if e==1
        prevEdge = -Inf;
    else
        prevEdge = ResponsePeakTime_s(e-1);
    end

    if e==nEvents
        nextEdge = Inf;
    else
        nextEdge = ResponsePeakTime_s(e+1);
    end

    preStart = cfg.PRE_FIT_START_US;
    preEnd = cfg.PRE_FIT_END_US;
    postStart = cfg.POST_FIT_START_US;
    postEnd = cfg.POST_FIT_END_US;

    if isfinite(prevEdge)

        preStart = max( ...
            preStart, ...
            (prevEdge-tEdge)*1e6+cfg.NEIGHBOUR_EDGE_GUARD_US);
    end

    if isfinite(nextEdge)

        postEnd = min( ...
            postEnd, ...
            (nextEdge-tEdge)*1e6-cfg.NEIGHBOUR_EDGE_GUARD_US);
    end

    PreFitStart_us(e) = preStart;
    PreFitEnd_us(e) = preEnd;
    PostFitStart_us(e) = postStart;
    PostFitEnd_us(e) = postEnd;

    if preStart>=preEnd || postStart>=postEnd

        QualityReason(e) = "trend_fit_window_invalid";
        continue;
    end

    preMask = t>=tEdge+preStart*1e-6 & t<=tEdge+preEnd*1e-6;
    postMask = t>=tEdge+postStart*1e-6 & t<=tEdge+postEnd*1e-6;

    if nnz(preMask)<20 || nnz(postMask)<20

        QualityReason(e) = "too_few_trend_samples";
        continue;
    end

    [preCoeff,PreFitR2(e)] = robustLinearFit( ...
        (t(preMask)-tEdge)*1e6,Iraw(preMask));

    [postCoeff,PostFitR2(e)] = robustLinearFit( ...
        (t(postMask)-tEdge)*1e6,Iraw(postMask));

    I0star_mA(e) = preCoeff(2);
    Ifstar_mA(e) = postCoeff(2);

    PreSlope_mA_per_ms(e) = preCoeff(1)*1000;
    PostSlope_mA_per_ms(e) = postCoeff(1)*1000;

    LocalStep_mA(e) = Ifstar_mA(e)-I0star_mA(e);
    LocalStepMagnitude_mA(e) = abs(LocalStep_mA(e));

    if CommandCurrent_mA(e)>0

        StepToCommandRatio(e) = ...
            LocalStepMagnitude_mA(e)/CommandCurrent_mA(e);
    end

    if LocalStepMagnitude_mA(e)<cfg.MIN_LOCAL_STEP_mA

        QualityReason(e) = "local_step_too_small";
        continue;
    end

    fastMask = ...
        t>=tEdge-cfg.FAST_WINDOW_PRE_US*1e-6 & ...
        t<=tEdge+cfg.FAST_WINDOW_POST_US*1e-6;

    if nnz(fastMask)<20

        QualityReason(e) = "too_few_fast_samples";
        continue;
    end

    tx = (t(fastMask)-tEdge)*1e6;
    Ix = Iraw(fastMask);

    Ic = interp1(tx,Ix,fastTime_us,'linear',NaN);

    normalizedRawAll(:,e) = ...
        (Ic-I0star_mA(e))/LocalStep_mA(e);

    Icorr = Ic;

    before = fastTime_us<0;
    after = ~before;

    Icorr(before) = ...
        Ic(before)-preCoeff(1)*fastTime_us(before);

    Icorr(after) = ...
        Ic(after)-postCoeff(1)*fastTime_us(after);

    normalizedDetrendedAll(:,e) = ...
        (Icorr-I0star_mA(e))/LocalStep_mA(e);

    ym = movmean( ...
        normalizedDetrendedAll(:,e), ...
        metricSmoothSamples, ...
        'omitnan');

    T10_us(e) = firstCrossingTime(fastTime_us,ym,0.10);
    T50_us(e) = firstCrossingTime(fastTime_us,ym,0.50);
    T90_us(e) = firstCrossingTime(fastTime_us,ym,0.90);

    if all(isfinite([T10_us(e),T90_us(e)]))

        T10_90_us(e) = ...
            T90_us(e)-T10_us(e);
    end

    if isfinite(T10_us(e))

        CommandToT10_us(e) = ...
            (tEdge+T10_us(e)*1e-6-CommandTime_s(e))*1e6;
    end

    if isfinite(T50_us(e))

        CommandToT50_us(e) = ...
            (tEdge+T50_us(e)*1e-6-CommandTime_s(e))*1e6;
    end

    if isfinite(T90_us(e))

        CommandToT90_us(e) = ...
            (tEdge+T90_us(e)*1e-6-CommandTime_s(e))*1e6;
    end

    if isfinite(T90_us(e))

        mm = ...
            fastTime_us>=T90_us(e) & ...
            fastTime_us<=cfg.FAST_METRIC_END_US & ...
            isfinite(ym);

        if any(mm)

            PeakNormalized(e) = max(ym(mm));
            Overshoot_pct(e) = max(0,(PeakNormalized(e)-1)*100);
        end
    end

    if isfinite(T10_us(e))

        mm = fastTime_us<=cfg.FAST_METRIC_END_US;

        SettlingFromT10_us(e) = settlingTimeAfterReference( ...
            fastTime_us(mm),ym(mm),T10_us(e), ...
            cfg.SETTLING_BAND,cfg.SETTLING_HOLD_US);
    end

    baselineMask = ...
        fastTime_us>=cfg.BASELINE_QC_START_US & ...
        fastTime_us<=cfg.BASELINE_QC_END_US;

    finalMask = ...
        fastTime_us>=cfg.FINAL_QC_START_US & ...
        fastTime_us<=cfg.FINAL_QC_END_US;

    BaselineNormalizedMean(e) = ...
        mean(normalizedDetrendedAll(baselineMask,e),'omitnan');

    FinalNormalizedMean(e) = ...
        mean(normalizedDetrendedAll(finalMask,e),'omitnan');

    passBaseline = ...
        abs(BaselineNormalizedMean(e))<=cfg.BASELINE_TOL;

    passFinal = ...
        abs(FinalNormalizedMean(e)-1)<=cfg.FINAL_TOL;

    passCrossing = ...
        all(isfinite([T10_us(e),T50_us(e),T90_us(e)])) && ...
        T10_us(e)<T50_us(e) && ...
        T50_us(e)<T90_us(e);

    if cfg.REQUIRE_TREND_R2

        passTrend = ...
            PreFitR2(e)>=cfg.MIN_TREND_R2 && ...
            PostFitR2(e)>=cfg.MIN_TREND_R2;

    else

        passTrend = true;
    end

    if ~passBaseline

        QualityReason(e) = "normalized_pre_level_check_failed";

    elseif ~passFinal

        QualityReason(e) = "normalized_early_post_level_check_failed";

    elseif ~passCrossing

        QualityReason(e) = "normalized_crossing_check_failed";

    elseif ~passTrend

        QualityReason(e) = "trend_fit_r2_check_failed";

    else

        ValidEvent(e) = true;
        QualityReason(e) = "pass";
    end
end

allTransitionEventMetrics = table( ...
    CaptureID,AttemptNumber,CommandCurrent_mA,CaptureWithinAttempt, ...
    PulseNumber,CommandEvent,TransitionClass,IsBipolar,IsBoundary, ...
    CommandTime_s,ResponsePeakTime_s,CommandToGradientPeak_us, ...
    ResponseTimeSource,NativeFs_MSa_s,NativeTs_us, ...
    ValidEvent,QualityReason, ...
    I0star_mA,Ifstar_mA,LocalStep_mA,LocalStepMagnitude_mA, ...
    StepToCommandRatio, ...
    PreSlope_mA_per_ms,PostSlope_mA_per_ms,PreFitR2,PostFitR2, ...
    PreFitStart_us,PreFitEnd_us,PostFitStart_us,PostFitEnd_us, ...
    BaselineNormalizedMean,FinalNormalizedMean, ...
    T10_us,T50_us,T90_us,T10_90_us, ...
    CommandToT10_us,CommandToT50_us,CommandToT90_us, ...
    PeakNormalized,Overshoot_pct,SettlingFromT10_us);

% Preserve the existing primary model dataset exactly as bipolar-only.
bipolarRows = allTransitionEventMetrics.IsBipolar;

eventMetrics = ...
    allTransitionEventMetrics(bipolarRows,:);

normalizedRaw = ...
    normalizedRawAll(:,bipolarRows);

normalizedDetrended = ...
    normalizedDetrendedAll(:,bipolarRows);

O = struct();

O.eventMetrics = eventMetrics;
O.normalizedRaw = normalizedRaw;
O.normalizedDetrended = normalizedDetrended;

O.allTransitionEventMetrics = allTransitionEventMetrics;
O.allTransitionNormalizedRaw = normalizedRawAll;
O.allTransitionNormalizedDetrended = normalizedDetrendedAll;

end

%% LOCAL HELPERS ==========================================================

function [coeff,R2] = robustLinearFit(x,y)

x = x(:);
y = y(:);

m = isfinite(x) & isfinite(y);
x = x(m);
y = y(m);

if numel(x)<2

    coeff = [NaN NaN];
    R2 = NaN;
    return;
end

p0 = polyfit(x,y,1);
residual = y-polyval(p0,x);

sigma = robustSigma(residual);

if isfinite(sigma) && sigma>0

    keep = abs(residual-median(residual))<=4*sigma;

else

    keep = true(size(x));
end

if nnz(keep)<2
    keep = true(size(x));
end

coeff = polyfit(x(keep),y(keep),1);

yhat = polyval(coeff,x(keep));
denom = sum((y(keep)-mean(y(keep))).^2);

if denom>0

    R2 = 1-sum((y(keep)-yhat).^2)/denom;

else

    R2 = NaN;
end

end

function tc = firstCrossingTime(t,y,level)

tc = NaN;

m = isfinite(t) & isfinite(y);
t = t(m);
y = y(m);

if numel(t)<2
    return;
end

idx = find(y(1:end-1)<level & y(2:end)>=level,1,'first');

if isempty(idx)
    return;
end

if y(idx+1)==y(idx)

    tc = t(idx+1);

else

    tc = t(idx) + ...
        (level-y(idx))*(t(idx+1)-t(idx))/(y(idx+1)-y(idx));
end

end

function st = settlingTimeAfterReference(t,y,tRef,band,holdTime)

st = NaN;

m = isfinite(t) & isfinite(y) & t>=tRef;
t = t(m);
y = y(m);

if numel(t)<2
    return;
end

dt = median(diff(t));
holdSamples = max(1,ceil(holdTime/dt));

within = abs(y-1)<=band;

for k = 1:numel(within)-holdSamples+1

    if all(within(k:k+holdSamples-1))

        st = t(k)-tRef;
        return;
    end
end

end

function sigma = robustSigma(x)

x = x(isfinite(x));

if isempty(x)

    sigma = NaN;
    return;
end

med = median(x);
sigma = 1.4826*median(abs(x-med));

if ~isfinite(sigma) || sigma<=0
    sigma = std(x);
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
