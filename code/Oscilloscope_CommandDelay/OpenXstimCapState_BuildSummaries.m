function summary = OpenXstimCapState_BuildSummaries(P,cfg)
% Compare phase-local charge to continuous capacitor-state proxies.
%
% IMPORTANT:
% Only phases with IncludedInChargeAnalysis == true contribute to aggregate
% statistics. Excluded captures remain in Stage4A_PhaseStateMetrics.csv for
% traceability, but do not influence Stage 4A conclusions.

thresholds = cfg.THRESHOLD_LEVELS(:);

baseMask = ...
    P.ValidPhase & ...
    P.IncludedInChargeAnalysis;

currents = unique(P.CommandCurrent_mA(baseMask));
polarities = ["positive";"negative"];

rows = cell(numel(currents)*numel(polarities)*numel(thresholds),1);
r = 0;

for k = 1:numel(currents)

    for p = 1:numel(polarities)

        for h = 1:numel(thresholds)

            level = thresholds(h);

            [localField,orientedField,centeredField] = ...
                thresholdFields(level);

            m = ...
                baseMask & ...
                P.CommandCurrent_mA==currents(k) & ...
                P.Polarity==polarities(p) & ...
                isfinite(P.(localField)) & ...
                isfinite(P.(orientedField));

            if ~any(m)
                continue;
            end

            xLocal = P.(localField)(m);
            xOriented = P.(orientedField)(m);
            xCentered = P.(centeredField)(m);

            r = r+1;

            rows{r} = table( ...
                currents(k), ...
                polarities(p), ...
                level, ...
                nnz(m), ...
                median(xLocal,'omitnan'), ...
                robustSigma(xLocal), ...
                median(xOriented,'omitnan'), ...
                robustSigma(xOriented), ...
                median(xCentered,'omitnan'), ...
                robustSigma(xCentered), ...
                'VariableNames',{ ...
                'CommandCurrent_mA', ...
                'Polarity', ...
                'ThresholdD', ...
                'NEvents', ...
                'MedianPhaseLocalCharge_uC', ...
                'RobustSpreadPhaseLocal_uC', ...
                'MedianOrientedCenteredState_uC', ...
                'RobustSpreadOrientedCentered_uC', ...
                'MedianCenteredSignedState_uC', ...
                'RobustSpreadCenteredSigned_uC'});
        end
    end
end

rows = rows(~cellfun(@isempty,rows));

if isempty(rows)
    ThresholdStateSummary = table();
else
    ThresholdStateSummary = vertcat(rows{:});
end

%% ========================================================================
% GLOBAL THRESHOLD SPREAD COMPARISON
% ========================================================================

grows = cell(numel(thresholds),1);

for h = 1:numel(thresholds)

    level = thresholds(h);

    [localField,orientedField,~] = ...
        thresholdFields(level);

    m = ...
        baseMask & ...
        isfinite(P.(localField)) & ...
        isfinite(P.(orientedField));

    xLocal = P.(localField)(m);
    xOriented = P.(orientedField)(m);

    medLocal = median(xLocal,'omitnan');
    sigLocal = robustSigma(xLocal);

    medOriented = median(xOriented,'omitnan');
    sigOriented = robustSigma(xOriented);

    localRelSpread = ...
        safeRelativeSpread(sigLocal,medLocal);

    orientedRelSpread = ...
        safeRelativeSpread(sigOriented,medOriented);

    grows{h} = table( ...
        level, ...
        nnz(m), ...
        medLocal, ...
        sigLocal, ...
        localRelSpread, ...
        medOriented, ...
        sigOriented, ...
        orientedRelSpread, ...
        'VariableNames',{ ...
        'ThresholdD', ...
        'NEvents', ...
        'MedianPhaseLocalCharge_uC', ...
        'RobustSpreadPhaseLocal_uC', ...
        'RelativeSpreadPhaseLocal', ...
        'MedianOrientedCenteredState_uC', ...
        'RobustSpreadOrientedCentered_uC', ...
        'RelativeSpreadOrientedCentered'});
end

GlobalThresholdSummary = vertcat(grows{:});

summary = struct();

summary.ThresholdStateSummary = ThresholdStateSummary;
summary.GlobalThresholdSummary = GlobalThresholdSummary;
summary.NIncludedPhases = nnz(baseMask);
summary.NExcludedPhases = nnz(P.ValidPhase & ~P.IncludedInChargeAnalysis);

end

%% ========================================================================
% HELPERS
% ========================================================================

function [localField,orientedField,centeredField] = thresholdFields(level)

switch round(level*100)

    case 90
        localField = "ChargeTo90_uC";
        orientedField = "OrientedState90_uC";
        centeredField = "ChargeState90Centered_uC";

    case 75
        localField = "ChargeTo75_uC";
        orientedField = "OrientedState75_uC";
        centeredField = "ChargeState75Centered_uC";

    case 50
        localField = "ChargeTo50_uC";
        orientedField = "OrientedState50_uC";
        centeredField = "ChargeState50Centered_uC";

    case 25
        localField = "ChargeTo25_uC";
        orientedField = "OrientedState25_uC";
        centeredField = "ChargeState25Centered_uC";

    otherwise
        error("Unsupported threshold level %.3f.",level);
end

end

function s = robustSigma(x)

x = x(isfinite(x));

if isempty(x)
    s = NaN;
    return;
end

med = median(x,'omitnan');
madRaw = median(abs(x-med),'omitnan');

s = 1.4826*madRaw;

end

function r = safeRelativeSpread(s,med)

if ~isfinite(s) || ~isfinite(med) || abs(med)<eps
    r = NaN;
else
    r = s/abs(med);
end

end
