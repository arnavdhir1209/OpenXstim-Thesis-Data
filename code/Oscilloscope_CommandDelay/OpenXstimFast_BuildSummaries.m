function summary = OpenXstimFast_BuildSummaries( ...
    fastTime_us, ...
    normalizedDetrended, ...
    M, ...
    allTransitionNormalizedDetrended, ...
    A)
% Build the existing bipolar summaries plus transition-type summaries.

valid = M.ValidEvent;

currents = unique(M.CommandCurrent_mA);
directions = ["pos_to_neg";"neg_to_pos"];

%% EXISTING CURRENT SUMMARY ==============================================

n = numel(currents);

CommandCurrent_mA = currents;
NEvents = zeros(n,1);
NValid = zeros(n,1);
ValidFraction = NaN(n,1);

MeanT10_us = NaN(n,1);
SDT10_us = NaN(n,1);
MeanT50_us = NaN(n,1);
SDT50_us = NaN(n,1);
MeanT90_us = NaN(n,1);
SDT90_us = NaN(n,1);
MeanT10_90_us = NaN(n,1);
SDT10_90_us = NaN(n,1);

MeanOvershoot_pct = NaN(n,1);
SDOvershoot_pct = NaN(n,1);

MeanLocalStepMagnitude_mA = NaN(n,1);
SDLocalStepMagnitude_mA = NaN(n,1);

for k = 1:n

    a = M.CommandCurrent_mA==currents(k);
    v = a & valid;

    NEvents(k) = nnz(a);
    NValid(k) = nnz(v);
    ValidFraction(k) = NValid(k)/NEvents(k);

    MeanT10_us(k) = mean(M.T10_us(v),'omitnan');
    SDT10_us(k) = std(M.T10_us(v),'omitnan');

    MeanT50_us(k) = mean(M.T50_us(v),'omitnan');
    SDT50_us(k) = std(M.T50_us(v),'omitnan');

    MeanT90_us(k) = mean(M.T90_us(v),'omitnan');
    SDT90_us(k) = std(M.T90_us(v),'omitnan');

    MeanT10_90_us(k) = mean(M.T10_90_us(v),'omitnan');
    SDT10_90_us(k) = std(M.T10_90_us(v),'omitnan');

    MeanOvershoot_pct(k) = mean(M.Overshoot_pct(v),'omitnan');
    SDOvershoot_pct(k) = std(M.Overshoot_pct(v),'omitnan');

    MeanLocalStepMagnitude_mA(k) = ...
        mean(M.LocalStepMagnitude_mA(v),'omitnan');

    SDLocalStepMagnitude_mA(k) = ...
        std(M.LocalStepMagnitude_mA(v),'omitnan');
end

CurrentSummary = table( ...
    CommandCurrent_mA,NEvents,NValid,ValidFraction, ...
    MeanT10_us,SDT10_us,MeanT50_us,SDT50_us, ...
    MeanT90_us,SDT90_us,MeanT10_90_us,SDT10_90_us, ...
    MeanOvershoot_pct,SDOvershoot_pct, ...
    MeanLocalStepMagnitude_mA,SDLocalStepMagnitude_mA);

%% EXISTING DIRECTION SUMMARY ============================================

rows = cell(numel(currents)*numel(directions),1);
r = 0;

for k = 1:numel(currents)

    for d = 1:numel(directions)

        r = r+1;

        a = ...
            M.CommandCurrent_mA==currents(k) & ...
            M.TransitionClass==directions(d);

        v = a & valid;

        rows{r} = table( ...
            currents(k),directions(d),nnz(a),nnz(v), ...
            mean(M.T10_90_us(v),'omitnan'), ...
            std(M.T10_90_us(v),'omitnan'), ...
            mean(M.Overshoot_pct(v),'omitnan'), ...
            mean(M.CommandToGradientPeak_us(v),'omitnan'), ...
            std(M.CommandToGradientPeak_us(v),'omitnan'), ...
            'VariableNames',{ ...
            'CommandCurrent_mA','TransitionClass','NEvents','NValid', ...
            'MeanT10_90_us','SDT10_90_us','MeanOvershoot_pct', ...
            'MeanCommandToGradientPeak_us','SDCommandToGradientPeak_us'});
    end
end

DirectionSummary = vertcat(rows{:});

%% EXISTING BIPOLAR MEAN WAVEFORMS =======================================

meanRows = cell(numel(currents)*numel(directions),1);
r = 0;

for k = 1:numel(currents)

    for d = 1:numel(directions)

        a = ...
            valid & ...
            M.CommandCurrent_mA==currents(k) & ...
            M.TransitionClass==directions(d);

        if ~any(a)
            continue;
        end

        Y = normalizedDetrended(:,a);

        r = r+1;

        meanRows{r} = table( ...
            repmat(currents(k),numel(fastTime_us),1), ...
            repmat(directions(d),numel(fastTime_us),1), ...
            fastTime_us, ...
            mean(Y,2,'omitnan'), ...
            std(Y,0,2,'omitnan'), ...
            sum(isfinite(Y),2), ...
            'VariableNames',{ ...
            'CommandCurrent_mA','TransitionClass','Time_us', ...
            'MeanNormalizedCurrent','SDNormalizedCurrent','NSamples'});
    end
end

meanRows = meanRows(~cellfun(@isempty,meanRows));
FastMeanWaveforms = vertcat(meanRows{:});

%% EXISTING DIRECTION SYMMETRY ===========================================

symRows = cell(numel(currents),1);
FastByCurrent = struct();

for k = 1:numel(currents)

    Icmd = currents(k);

    allCurrent = valid & M.CommandCurrent_mA==Icmd;

    fieldName = matlab.lang.makeValidName(sprintf("I_%g_mA",Icmd));

    FastByCurrent.(fieldName).commandCurrent_mA = Icmd;
    FastByCurrent.(fieldName).N = nnz(allCurrent);
    FastByCurrent.(fieldName).eventRows = find(allCurrent);
    FastByCurrent.(fieldName).mean = ...
        mean(normalizedDetrended(:,allCurrent),2,'omitnan');
    FastByCurrent.(fieldName).sd = ...
        std(normalizedDetrended(:,allCurrent),0,2,'omitnan');

    pn = ...
        valid & ...
        M.CommandCurrent_mA==Icmd & ...
        M.TransitionClass=="pos_to_neg";

    np = ...
        valid & ...
        M.CommandCurrent_mA==Icmd & ...
        M.TransitionClass=="neg_to_pos";

    muPN = mean(normalizedDetrended(:,pn),2,'omitnan');
    muNP = mean(normalizedDetrended(:,np),2,'omitnan');

    finitePair = isfinite(muPN) & isfinite(muNP);

    if any(finitePair)

        delta = muPN(finitePair)-muNP(finitePair);

        rmse = sqrt(mean(delta.^2));
        maxAbs = max(abs(delta));

    else

        rmse = NaN;
        maxAbs = NaN;
    end

    symRows{k} = table( ...
        Icmd,nnz(pn),nnz(np),rmse,maxAbs, ...
        'VariableNames',{ ...
        'CommandCurrent_mA','NPosToNeg','NNegToPos', ...
        'MeanCurveRMSE','MeanCurveMaxAbsDifference'});
end

FastSymmetryByCurrent = vertcat(symRows{:});

%% NEW: TRANSITION-TYPE SUMMARY ==========================================

allValid = A.ValidEvent;

allCurrents = unique(A.CommandCurrent_mA);

transitionClasses = [ ...
    "zero_to_pos"; ...
    "pos_to_neg"; ...
    "neg_to_pos"; ...
    "neg_to_zero"];

expectedPerCapture = [1;20;19;1];

typeRows = cell(numel(allCurrents)*numel(transitionClasses),1);

r = 0;

for k = 1:numel(allCurrents)

    Icmd = allCurrents(k);

    capturesAtCurrent = ...
        unique(A.CaptureID(A.CommandCurrent_mA==Icmd));

    nCapturesAtCurrent = numel(capturesAtCurrent);

    for d = 1:numel(transitionClasses)

        r = r+1;

        cls = transitionClasses(d);

        a = ...
            A.CommandCurrent_mA==Icmd & ...
            A.TransitionClass==cls;

        v = a & allValid;

        nExpected = ...
            expectedPerCapture(d)*nCapturesAtCurrent;

        nObserved = nnz(a);
        nValid = nnz(v);

        if nExpected>0
            observedFraction = nObserved/nExpected;
        else
            observedFraction = NaN;
        end

        if nObserved>0
            validFractionObserved = nValid/nObserved;
        else
            validFractionObserved = NaN;
        end

        typeRows{r} = table( ...
            Icmd, ...
            cls, ...
            nCapturesAtCurrent, ...
            nExpected, ...
            nObserved, ...
            nValid, ...
            observedFraction, ...
            validFractionObserved, ...
            mean(A.T10_us(v),'omitnan'), ...
            std(A.T10_us(v),'omitnan'), ...
            mean(A.T50_us(v),'omitnan'), ...
            std(A.T50_us(v),'omitnan'), ...
            mean(A.T90_us(v),'omitnan'), ...
            std(A.T90_us(v),'omitnan'), ...
            mean(A.T10_90_us(v),'omitnan'), ...
            std(A.T10_90_us(v),'omitnan'), ...
            mean(A.Overshoot_pct(v),'omitnan'), ...
            std(A.Overshoot_pct(v),'omitnan'), ...
            mean(A.CommandToGradientPeak_us(v),'omitnan'), ...
            std(A.CommandToGradientPeak_us(v),'omitnan'), ...
            mean(A.LocalStepMagnitude_mA(v),'omitnan'), ...
            std(A.LocalStepMagnitude_mA(v),'omitnan'), ...
            mean(A.StepToCommandRatio(v),'omitnan'), ...
            std(A.StepToCommandRatio(v),'omitnan'), ...
            'VariableNames',{ ...
            'CommandCurrent_mA', ...
            'TransitionClass', ...
            'NCaptures', ...
            'NExpected', ...
            'NPhysicalEdgesObserved', ...
            'NValidNormalized', ...
            'PhysicalEdgeObservedFraction', ...
            'ValidFractionOfObserved', ...
            'MeanT10_us', ...
            'SDT10_us', ...
            'MeanT50_us', ...
            'SDT50_us', ...
            'MeanT90_us', ...
            'SDT90_us', ...
            'MeanT10_90_us', ...
            'SDT10_90_us', ...
            'MeanOvershoot_pct', ...
            'SDOvershoot_pct', ...
            'MeanCommandToGradientPeak_us', ...
            'SDCommandToGradientPeak_us', ...
            'MeanLocalStepMagnitude_mA', ...
            'SDLocalStepMagnitude_mA', ...
            'MeanStepToCommandRatio', ...
            'SDStepToCommandRatio'});
    end
end

TransitionTypeSummary = vertcat(typeRows{:});

%% NEW: ALL-TRANSITION MEAN WAVEFORMS ====================================

allMeanRows = cell(numel(allCurrents)*numel(transitionClasses),1);
r = 0;

for k = 1:numel(allCurrents)

    for d = 1:numel(transitionClasses)

        a = ...
            allValid & ...
            A.CommandCurrent_mA==allCurrents(k) & ...
            A.TransitionClass==transitionClasses(d);

        if ~any(a)
            continue;
        end

        Y = allTransitionNormalizedDetrended(:,a);

        r = r+1;

        allMeanRows{r} = table( ...
            repmat(allCurrents(k),numel(fastTime_us),1), ...
            repmat(transitionClasses(d),numel(fastTime_us),1), ...
            fastTime_us, ...
            mean(Y,2,'omitnan'), ...
            std(Y,0,2,'omitnan'), ...
            sum(isfinite(Y),2), ...
            'VariableNames',{ ...
            'CommandCurrent_mA', ...
            'TransitionClass', ...
            'Time_us', ...
            'MeanNormalizedCurrent', ...
            'SDNormalizedCurrent', ...
            'NSamples'});
    end
end

allMeanRows = allMeanRows(~cellfun(@isempty,allMeanRows));

if isempty(allMeanRows)

    AllTransitionMeanWaveforms = table();

else

    AllTransitionMeanWaveforms = vertcat(allMeanRows{:});
end

%% NEW: STRUCTURED ALL-TRANSITION VIEW ===================================

AllTransitionByType = struct();

for d = 1:numel(transitionClasses)

    cls = transitionClasses(d);

    typeField = matlab.lang.makeValidName(cls);

    AllTransitionByType.(typeField) = struct();

    for k = 1:numel(allCurrents)

        Icmd = allCurrents(k);

        m = ...
            allValid & ...
            A.CommandCurrent_mA==Icmd & ...
            A.TransitionClass==cls;

        currentField = ...
            matlab.lang.makeValidName(sprintf("I_%g_mA",Icmd));

        G = struct();

        G.commandCurrent_mA = Icmd;
        G.transitionClass = cls;
        G.N = nnz(m);
        G.eventRows = find(m);

        if any(m)

            G.mean = ...
                mean(allTransitionNormalizedDetrended(:,m),2,'omitnan');

            G.sd = ...
                std(allTransitionNormalizedDetrended(:,m),0,2,'omitnan');

        else

            G.mean = NaN(numel(fastTime_us),1);
            G.sd = NaN(numel(fastTime_us),1);
        end

        AllTransitionByType.(typeField).(currentField) = G;
    end
end

%% OUTPUT ================================================================

summary = struct();

summary.CurrentSummary = CurrentSummary;
summary.DirectionSummary = DirectionSummary;
summary.FastMeanWaveforms = FastMeanWaveforms;
summary.FastSymmetryByCurrent = FastSymmetryByCurrent;
summary.FastByCurrent = FastByCurrent;

summary.TransitionTypeSummary = TransitionTypeSummary;
summary.AllTransitionMeanWaveforms = AllTransitionMeanWaveforms;
summary.AllTransitionByType = AllTransitionByType;

end
