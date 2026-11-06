function stats = OpenXstimPlant6A_Statistics(stage6,cfg)
% OpenXstimPlant6A_Statistics
%
% Builds current-level loss matrices from the Stage 6 saved model
% architectures, then performs:
%   * paired bootstrap confidence intervals,
%   * exact paired sign-flip/randomization tests,
%   * optional paired t-test and sign-rank sensitivity checks,
%   * Holm multiple-comparison correction,
%   * practical non-inferiority evidence using Stage 6 tolerances.
%
% No Statistics Toolbox is required for the primary analysis.

stats = struct();

%% STATIC SCALE ===========================================================

[staticLoss,staticMode,staticNote] = buildStaticLoss(stage6);

stats.static = analyzeSubsystem( ...
    "STATIC_SCALE", ...
    staticLoss, ...
    staticMode, ...
    cfg);

stats.static.note = staticNote;

%% FAST DYNAMICS ==========================================================

[fastLoss,fastMode,fastNote] = buildFastLoss(stage6);

stats.fast = analyzeSubsystem( ...
    "FAST_DYNAMICS", ...
    fastLoss, ...
    fastMode, ...
    cfg);

stats.fast.note = fastNote;

%% DELAY ==================================================================

stats.delay = analyzeDelay(stage6,cfg);

%% ORDINARY DROOP =========================================================

[droopLoss,droopMode,droopNote] = buildDroopLoss(stage6);

stats.droop = analyzeSubsystem( ...
    "ORDINARY_DROOP", ...
    droopLoss, ...
    droopMode, ...
    cfg);

stats.droop.note = droopNote;

%% COMPLIANCE COLLAPSE ====================================================

[collapseLoss,collapseMode,collapseNote] = buildCollapseLoss(stage6);

stats.collapse = analyzeSubsystem( ...
    "COMPLIANCE_COLLAPSE", ...
    collapseLoss, ...
    collapseMode, ...
    cfg);

stats.collapse.note = collapseNote;

%% BUILD MODEL-REDUCTION EVIDENCE TABLE ==================================

stats.evidenceTable = buildEvidenceTable(stats,stage6,cfg);

end

%% ========================================================================
% STATIC SCALE
% ========================================================================

function [T,mode,note] = buildStaticLoss(stage6)

R = stage6.static;

x = R.commandCurrent_mA(:);
y = R.measuredIpp_mA(:);

valid = isfinite(x) & isfinite(y);
x = x(valid);
y = y(valid);

predGain = NaN(size(y));
predQuad = NaN(size(y));

for k = 1:numel(x)

    tr = true(size(x));
    tr(k) = false;

    g = sum(x(tr).*y(tr))/sum(x(tr).^2);
    predGain(k) = g*x(k);

    X = [x(tr) x(tr).^2];
    b = X\y(tr);
    predQuad(k) = [x(k) x(k)^2]*b;
end

T = table( ...
    x, ...
    abs(y-predGain), ...
    abs(y-predQuad), ...
    'VariableNames',{ ...
    'CommandCurrent_mA', ...
    'GAIN', ...
    'QUADRATIC_ORIGIN'});

% Static Stage 6 selection used leave-one-current-out RMSE, so the aggregate
% statistic is root(mean(error^2)).
mode = "RMS";

note = [ ...
    "STATIC_SCALE uses leave-one-current-out prediction residuals. " + ...
    "This directly matches the Stage 6 cross-current validation question."];
end

%% ========================================================================
% FAST DYNAMICS
% ========================================================================

function [T,mode,note] = buildFastLoss(stage6)

R = stage6.fast;

D = R.data(:);
valid = find([D.valid]);

n = numel(valid);

current = NaN(n,1);
local = NaN(n,1);
common = NaN(n,1);
regime = NaN(n,1);

t = R.time_us(:);
fitMask = R.fitMask(:);

commonModel = R.allCommon.selected.model;
fullModel = R.fullReversalCommon.selected.model;
nearModel = R.nearZeroCommon.selected.model;

for j = 1:n

    q = valid(j);

    current(j) = D(q).current;
    local(j) = D(q).localRMSE;

    common(j) = ...
        currentFastRMSE(D(q),commonModel,t,fitMask);

    if string(D(q).regime)=="FULL_REVERSAL"
        regime(j) = ...
            currentFastRMSE(D(q),fullModel,t,fitMask);
    elseif string(D(q).regime)=="NEAR_ZERO_START"
        regime(j) = ...
            currentFastRMSE(D(q),nearModel,t,fitMask);
    end
end

T = table( ...
    current,local,common,regime, ...
    'VariableNames',{ ...
    'CommandCurrent_mA', ...
    'LOCAL_REFERENCE', ...
    'ALL_CURRENT_COMMON', ...
    'PHYSICAL_REGIME_SPLIT'});

mode = "MEAN";

note = [ ...
    "FAST_DYNAMICS uses Stage 6 per-current mean-waveform RMSE. " + ...
    "Bootstrap resampling therefore asks whether the observed architecture " + ...
    "penalty is stable across the six measured current levels."];
end

function value = currentFastRMSE(Dk,M,t,fitMask)

yhat = fastCurve(M,t);

good = ...
    fitMask & ...
    isfinite(Dk.y(:)) & ...
    isfinite(yhat(:));

if nnz(good)<20
    value = NaN;
else
    value = rmsError(Dk.y(good),yhat(good));
end
end

%% ========================================================================
% DELAY
% ========================================================================

function out = analyzeDelay(stage6,cfg)

out = struct();

if ~isfield(stage6,"delay") || ...
        ~isfield(stage6.delay,"models") || ...
        isempty(fieldnames(stage6.delay.models))

    out.architecture = table();
    out.pairwise = table();
    out.byClass = struct();
    out.note = "No Stage 6 delay model structures found.";
    return;
end

classes = string(fieldnames(stage6.delay.models));

archParts = cell(numel(classes),1);
pairParts = cell(numel(classes),1);

byClass = struct();

for c = 1:numel(classes)

    fieldName = classes(c);
    M = stage6.delay.models.(fieldName);

    cls = restoreDelayClassName(fieldName,M);

    x = M.x(:);
    y = M.y(:);

    valid = isfinite(x) & isfinite(y);
    x = x(valid);
    y = y(valid);

    if numel(x)<2
        continue;
    end

    % Use leave-one-current-out prediction for CONSTANT and LINEAR.
    % For the regime split, refit the group constant after removing each
    % held-out current. This is stronger than the in-sample Stage 6 split
    % comparison and avoids rewarding extra parameters solely in sample.
    predConst = looDelayPrediction(x,y,"CONSTANT",stage6.cfg);
    predLinear = looDelayPrediction(x,y,"LINEAR",stage6.cfg);

    includeSplit = ismember(cls,["pos_to_neg","neg_to_pos"]);

    if includeSplit
        predSplit = looDelayPrediction(x,y,"REGIME_SPLIT",stage6.cfg);
    else
        predSplit = NaN(size(y));
    end

    if includeSplit
        L = table( ...
            x, ...
            abs(y-predConst), ...
            abs(y-predLinear), ...
            abs(y-predSplit), ...
            'VariableNames',{ ...
            'CommandCurrent_mA', ...
            'CONSTANT', ...
            'LINEAR_CURRENT', ...
            'PHYSICAL_REGIME_SPLIT_CONSTANT'});
    else
        L = table( ...
            x, ...
            abs(y-predConst), ...
            abs(y-predLinear), ...
            'VariableNames',{ ...
            'CommandCurrent_mA', ...
            'CONSTANT', ...
            'LINEAR_CURRENT'});
    end

    A = analyzeSubsystem( ...
        "DELAY_" + upper(cls), ...
        L, ...
        "RMS", ...
        cfg);

    A.transitionClass = cls;

    byClass.(matlab.lang.makeValidName(cls)) = A;

    AA = A.architecture;
    if ~isempty(AA)
        AA.TransitionClass = repmat(cls,height(AA),1);
        AA = movevars(AA,"TransitionClass",'Before',1);
        archParts{c} = AA;
    end

    PP = A.pairwise;
    if ~isempty(PP)
        PP.TransitionClass = repmat(cls,height(PP),1);
        PP = movevars(PP,"TransitionClass",'Before',1);
        pairParts{c} = PP;
    end
end

archParts = archParts(~cellfun(@isempty,archParts));
pairParts = pairParts(~cellfun(@isempty,pairParts));

if isempty(archParts)
    out.architecture = table();
else
    out.architecture = vertcat(archParts{:});
end

if isempty(pairParts)
    out.pairwise = table();
else
    out.pairwise = vertcat(pairParts{:});
end

out.byClass = byClass;
out.note = [ ...
    "Delay statistics use leave-one-current-out prediction errors. " + ...
    "Literal zero_to_pos startup remains a separate firmware event even if " + ...
    "a simple statistical delay law happens to fit it."];
end

function cls = restoreDelayClassName(fieldName,M)

if isfield(M,"recommended")
    % The struct field was produced by matlab.lang.makeValidName on the
    % original class, so the common names can be restored explicitly.
    switch lower(string(fieldName))
        case "pos_to_neg"
            cls = "pos_to_neg";
        case "neg_to_pos"
            cls = "neg_to_pos";
        case "neg_to_zero"
            cls = "neg_to_zero";
        case "zero_to_pos"
            cls = "zero_to_pos";
        otherwise
            cls = string(fieldName);
    end
else
    cls = string(fieldName);
end
end

function pred = looDelayPrediction(x,y,mode,stage6cfg)

pred = NaN(size(y));

for k = 1:numel(x)

    tr = true(size(x));
    tr(k) = false;

    switch string(mode)

        case "CONSTANT"

            pred(k) = mean(y(tr),'omitnan');

        case "LINEAR"

            if nnz(tr)>=2
                b = polyfit(x(tr),y(tr),1);
                pred(k) = polyval(b,x(k));
            end

        case "REGIME_SPLIT"

            low = ismember(x,stage6cfg.FULL_REVERSAL_CURRENTS_mApp);
            high = ismember(x,stage6cfg.NEAR_ZERO_START_CURRENTS_mApp);

            if low(k)
                pool = tr & low;
            elseif high(k)
                pool = tr & high;
            else
                pool = false(size(tr));
            end

            if any(pool)
                pred(k) = mean(y(pool),'omitnan');
            end
    end
end
end

%% ========================================================================
% ORDINARY DROOP
% ========================================================================

function [T,mode,note] = buildDroopLoss(stage6)

R = stage6.droop;
D = R.data(:);

valid = find([D.valid]);

n = numel(valid);

current = NaN(n,1);
local = NaN(n,1);
common = NaN(n,1);
linearCurrent = NaN(n,1);
twoGroup = NaN(n,1);

for j = 1:n

    q = valid(j);

    current(j) = D(q).current;
    local(j) = D(q).localRMSE;

    t = D(q).t(D(q).use);
    y = D(q).y(D(q).use);

    kCommon = R.commonRate_per_ms;
    common(j) = rmsError(y,1-kCommon*t);

    p = R.linearCurrentCoeff;
    kLinear = p(1)+p(2)*D(q).current;
    linearCurrent(j) = rmsError(y,1-kLinear*t);

    if ismember(D(q).current,stage6.cfg.FULL_REVERSAL_CURRENTS_mApp)
        kGroup = R.twoGroupRates_per_ms(1);
    else
        kGroup = R.twoGroupRates_per_ms(2);
    end

    twoGroup(j) = rmsError(y,1-kGroup*t);
end

T = table( ...
    current, ...
    local, ...
    common, ...
    linearCurrent, ...
    twoGroup, ...
    'VariableNames',{ ...
    'CommandCurrent_mA', ...
    'LOCAL_REFERENCE', ...
    'COMMON_LINEAR', ...
    'LINEAR_CURRENT', ...
    'TWO_GROUP_LINEAR'});

mode = "MEAN";

note = [ ...
    "ORDINARY_DROOP uses the same Stage 6 pre-collapse windows and " + ...
    "per-current RMSE definition, with each current receiving equal weight."];
end

%% ========================================================================
% COMPLIANCE COLLAPSE
% ========================================================================

function [T,mode,note] = buildCollapseLoss(stage6)

R = stage6.collapse;
D = R.data(:);

valid = find([D.valid]);

n = numel(valid);

current = NaN(n,1);
local = NaN(n,1);
commonShifted = NaN(n,1);
commonStretched = NaN(n,1);
thresholdStretched = NaN(n,1);
transitionStrong = NaN(n,1);

for j = 1:n

    q = valid(j);

    current(j) = D(q).current;
    local(j) = D(q).localRMSE;

    commonShifted(j) = mapStoredPerCurrent( ...
        R.commonShifted,D(q).current);

    commonStretched(j) = mapStoredPerCurrent( ...
        R.commonStretched,D(q).current);

    thresholdStretched(j) = mapStoredPerCurrent( ...
        R.currentThresholdStretched,D(q).current);
end

if isfield(R,"twoRegimePerCurrentRMSE")
    v = R.twoRegimePerCurrentRMSE(:);
    if numel(v)==n
        transitionStrong = v;
    else
        transitionStrong(1:min(n,numel(v))) = v(1:min(n,numel(v)));
    end
end

T = table( ...
    current, ...
    local, ...
    commonShifted, ...
    commonStretched, ...
    thresholdStretched, ...
    transitionStrong, ...
    'VariableNames',{ ...
    'CommandCurrent_mA', ...
    'LOCAL_REFERENCE', ...
    'COMMON_SHIFTED_EXP', ...
    'COMMON_STRETCHED_EXP', ...
    'CURRENT_THRESHOLD_STRETCHED_EXP', ...
    'TRANSITION_PLUS_STRONG_COLLAPSE'});

mode = "MEAN";

note = [ ...
    "COMPLIANCE_COLLAPSE has only three identifiable current levels " + ...
    "(20, 30, and 50 mA). Exact two-sided significance testing therefore " + ...
    "has very low resolution. Effect size, bootstrap uncertainty, physical " + ...
    "interpretability, and parameter count must carry more weight."];
end

function value = mapStoredPerCurrent(F,current)

value = NaN;

if ~isstruct(F) || ...
        ~isfield(F,"currents") || ...
        ~isfield(F,"perCurrentRMSE")
    return;
end

idx = find(abs(F.currents(:)-current)<1e-12,1);

if ~isempty(idx)
    value = F.perCurrentRMSE(idx);
end
end

%% ========================================================================
% GENERIC SUBSYSTEM ANALYSIS
% ========================================================================

function out = analyzeSubsystem(subsystem,lossTable,mode,cfg)

out = struct();

if isempty(lossTable) || width(lossTable)<3
    out.lossTable = lossTable;
    out.architecture = table();
    out.pairwise = table();
    return;
end

unitName = string(lossTable.Properties.VariableNames{1});
archNames = string(lossTable.Properties.VariableNames(2:end));

X = lossTable{:,2:end};
units = lossTable{:,1};

% Retain only rows where every architecture being directly compared is
% available. This guarantees paired inference.
rowValid = all(isfinite(X),2) & isfinite(units);

X = X(rowValid,:);
units = units(rowValid);

lossTable = lossTable(rowValid,:);

n = size(X,1);
m = size(X,2);

if n<2
    out.lossTable = lossTable;
    out.architecture = table();
    out.pairwise = table();
    return;
end

B = cfg.N_BOOTSTRAP;

bootScores = NaN(B,m);

for b = 1:B

    idx = randi(n,n,1);

    for a = 1:m
        bootScores(b,a) = aggregateScore(X(idx,a),mode);
    end
end

observed = NaN(m,1);
bootMean = NaN(m,1);
ciLo = NaN(m,1);
ciHi = NaN(m,1);
pBest = NaN(m,1);
pWithinTolBest = NaN(m,1);

for a = 1:m

    observed(a) = aggregateScore(X(:,a),mode);
    bootMean(a) = mean(bootScores(:,a),'omitnan');

    ci = empiricalCI(bootScores(:,a),cfg.CONFIDENCE_LEVEL);
    ciLo(a) = ci(1);
    ciHi(a) = ci(2);

    pBest(a) = mean( ...
        bootScores(:,a) <= min(bootScores,[],2) + 1e-15, ...
        'omitnan');

    bestBoot = min(bootScores,[],2);

    pWithinTolBest(a) = mean( ...
        bootScores(:,a) <= ...
        bestBoot.*(1+cfg.SIMPLICITY_RELATIVE_RMSE_TOL), ...
        'omitnan');
end

Architecture = archNames(:);
NCurrentLevels = repmat(n,m,1);
ObservedScore = observed;
BootstrapMean = bootMean;
CI95_Lower = ciLo;
CI95_Upper = ciHi;
ProbabilityBest = pBest;
ProbabilityWithinStage6SimplicityTolerance = pWithinTolBest;
MinimumAttainableTwoSidedSignFlipP = ...
    repmat(minExactTwoSidedP(n),m,1);

architecture = table( ...
    repmat(string(subsystem),m,1), ...
    Architecture, ...
    NCurrentLevels, ...
    ObservedScore, ...
    BootstrapMean, ...
    CI95_Lower, ...
    CI95_Upper, ...
    ProbabilityBest, ...
    ProbabilityWithinStage6SimplicityTolerance, ...
    MinimumAttainableTwoSidedSignFlipP, ...
    'VariableNames',{ ...
    'Subsystem', ...
    'Architecture', ...
    'NCurrentLevels', ...
    'ObservedScore', ...
    'BootstrapMean', ...
    'CI95_Lower', ...
    'CI95_Upper', ...
    'ProbabilityBest', ...
    'ProbabilityWithinStage6SimplicityTolerance', ...
    'MinimumAttainableTwoSidedSignFlipP'});

% Pairwise comparisons.
pairRows = cell(m*(m-1)/2,1);
r = 0;

for a = 2:m
    for b = 1:a-1

        r = r+1;

        bootDelta = bootScores(:,a)-bootScores(:,b);
        bootRatio = bootScores(:,a)./bootScores(:,b);

        deltaObs = observed(a)-observed(b);
        ratioObs = observed(a)/observed(b);

        deltaCI = empiricalCI(bootDelta,cfg.CONFIDENCE_LEVEL);
        ratioCI = empiricalCI(bootRatio,cfg.CONFIDENCE_LEVEL);

        unitDiff = pairedUnitLossDifference(X(:,a),X(:,b),mode);

        pSignFlip = exactSignFlipP(unitDiff);

        pT = NaN;
        if cfg.RUN_PARAMETRIC_SENSITIVITY && exist('ttest','file')==2
            try
                [~,pT] = ttest(unitDiff);
            catch
                pT = NaN;
            end
        end

        pW = NaN;
        if cfg.RUN_SIGNRANK_SENSITIVITY && exist('signrank','file')==2
            try
                pW = signrank(unitDiff);
            catch
                pW = NaN;
            end
        end

        pABetter = mean(bootDelta<0,'omitnan');

        pWithinSimpleTol = mean( ...
            bootScores(:,a) <= ...
            bootScores(:,b).*(1+cfg.SIMPLICITY_RELATIVE_RMSE_TOL), ...
            'omitnan');

        pWithinMaxUnified = mean( ...
            bootScores(:,a) <= ...
            bootScores(:,b).*cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO, ...
            'omitnan');

        marginSimple = ...
            cfg.SIMPLICITY_RELATIVE_RMSE_TOL*observed(b);

        marginUnified = ...
            (cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO-1)*observed(b);

        pairRows{r} = table( ...
            string(subsystem), ...
            archNames(a), ...
            archNames(b), ...
            n, ...
            observed(a), ...
            observed(b), ...
            deltaObs, ...
            deltaCI(1), ...
            deltaCI(2), ...
            ratioObs, ...
            ratioCI(1), ...
            ratioCI(2), ...
            pABetter, ...
            pSignFlip, ...
            pT, ...
            pW, ...
            marginSimple, ...
            pWithinSimpleTol, ...
            marginUnified, ...
            pWithinMaxUnified, ...
            minExactTwoSidedP(n), ...
            'VariableNames',{ ...
            'Subsystem', ...
            'ArchitectureA', ...
            'ArchitectureB', ...
            'NPairedCurrentLevels', ...
            'ScoreA', ...
            'ScoreB', ...
            'Delta_AminusB', ...
            'DeltaCI95_Lower', ...
            'DeltaCI95_Upper', ...
            'Ratio_AoverB', ...
            'RatioCI95_Lower', ...
            'RatioCI95_Upper', ...
            'BootstrapProbability_A_Better', ...
            'ExactSignFlipP', ...
            'PairedTTestP_SensitivityOnly', ...
            'WilcoxonSignRankP_SensitivityOnly', ...
            'Stage6SimplicityMarginAbsolute_vsB', ...
            'BootstrapProbability_A_WithinSimplicityMarginOfB', ...
            'Stage6MaxUnifiedPenaltyAbsolute_vsB', ...
            'BootstrapProbability_A_WithinMaxUnifiedPenaltyOfB', ...
            'MinimumAttainableTwoSidedSignFlipP'});
    end
end

pairRows = pairRows(~cellfun(@isempty,pairRows));

if isempty(pairRows)
    pairwise = table();
else
    pairwise = vertcat(pairRows{:});

    pairwise.HolmAdjustedExactSignFlipP = ...
        holmAdjust(pairwise.ExactSignFlipP);
end

out.lossTable = lossTable;
out.unitName = unitName;
out.scoreMode = mode;
out.architecture = architecture;
out.pairwise = pairwise;
out.bootstrapScores = bootScores;
out.architectureNames = archNames;

end

function score = aggregateScore(v,mode)

v = v(isfinite(v));

if isempty(v)
    score = NaN;
    return;
end

switch string(mode)
    case "MEAN"
        score = mean(v);
    case "RMS"
        score = sqrt(mean(v.^2));
    otherwise
        error("Unknown aggregate score mode: %s",mode);
end
end

function d = pairedUnitLossDifference(a,b,mode)

good = isfinite(a) & isfinite(b);
a = a(good);
b = b(good);

switch string(mode)
    case "MEAN"
        d = a-b;
    case "RMS"
        % Equality of RMSE is equivalent to equality of mean squared error
        % before the square-root transform, so test squared loss differences.
        d = a.^2-b.^2;
    otherwise
        error("Unknown score mode.");
end

d = d(:);
end

%% ========================================================================
% EVIDENCE TABLE
% ========================================================================

function T = buildEvidenceTable(stats,stage6,cfg)

rows = {};

rows{end+1,1} = evidenceRow( ...
    "STATIC_SCALE", ...
    stats.static, ...
    "GAIN", ...
    "QUADRATIC_ORIGIN", ...
    cfg, ...
    "Can the simpler constant gain be retained instead of quadratic calibration?");

rows{end+1,1} = evidenceRow( ...
    "FAST_DYNAMICS", ...
    stats.fast, ...
    "ALL_CURRENT_COMMON", ...
    "LOCAL_REFERENCE", ...
    cfg, ...
    "Can one fast model replace all per-current local fast models?");

rows{end+1,1} = evidenceRow( ...
    "FAST_DYNAMICS", ...
    stats.fast, ...
    "PHYSICAL_REGIME_SPLIT", ...
    "LOCAL_REFERENCE", ...
    cfg, ...
    "Can two physical fast regimes replace per-current local fast models?");

rows{end+1,1} = evidenceRow( ...
    "FAST_DYNAMICS", ...
    stats.fast, ...
    "ALL_CURRENT_COMMON", ...
    "PHYSICAL_REGIME_SPLIT", ...
    cfg, ...
    "Can the two physical fast regimes themselves be collapsed to one model?");

rows{end+1,1} = evidenceRow( ...
    "ORDINARY_DROOP", ...
    stats.droop, ...
    "COMMON_LINEAR", ...
    "LOCAL_REFERENCE", ...
    cfg, ...
    "Can one ordinary-droop slope replace per-current slopes?");

rows{end+1,1} = evidenceRow( ...
    "ORDINARY_DROOP", ...
    stats.droop, ...
    "LINEAR_CURRENT", ...
    "COMMON_LINEAR", ...
    cfg, ...
    "Does adding current dependence materially improve ordinary droop?");

rows{end+1,1} = evidenceRow( ...
    "ORDINARY_DROOP", ...
    stats.droop, ...
    "TWO_GROUP_LINEAR", ...
    "COMMON_LINEAR", ...
    cfg, ...
    "Does a two-group droop law materially improve on one common slope?");

rows{end+1,1} = evidenceRow( ...
    "COMPLIANCE_COLLAPSE", ...
    stats.collapse, ...
    "TRANSITION_PLUS_STRONG_COLLAPSE", ...
    "LOCAL_REFERENCE", ...
    cfg, ...
    "Can 20 mA remain separate while 30/50 mA share one strong-collapse law?");

rows{end+1,1} = evidenceRow( ...
    "COMPLIANCE_COLLAPSE", ...
    stats.collapse, ...
    "COMMON_STRETCHED_EXP", ...
    "LOCAL_REFERENCE", ...
    cfg, ...
    "Can all collapse currents share one stretched exponential?");

rows{end+1,1} = evidenceRow( ...
    "COMPLIANCE_COLLAPSE", ...
    stats.collapse, ...
    "COMMON_SHIFTED_EXP", ...
    "LOCAL_REFERENCE", ...
    cfg, ...
    "Can all collapse currents share one shifted exponential?");

% Delay evidence, one row per internal repeating class.
delayClasses = ["pos_to_neg","neg_to_pos"];

for c = 1:numel(delayClasses)

    cls = delayClasses(c);
    f = matlab.lang.makeValidName(cls);

    if ~isfield(stats.delay.byClass,f)
        continue;
    end

    A = stats.delay.byClass.(f);

    rows{end+1,1} = evidenceRow( ...
        "DELAY_" + upper(cls), ...
        A, ...
        "LINEAR_CURRENT", ...
        "CONSTANT", ...
        cfg, ...
        "Does a linear current term improve this firmware transition delay?");

    if any(A.architecture.Architecture=="PHYSICAL_REGIME_SPLIT_CONSTANT")

        rows{end+1,1} = evidenceRow( ...
            "DELAY_" + upper(cls), ...
            A, ...
            "PHYSICAL_REGIME_SPLIT_CONSTANT", ...
            "CONSTANT", ...
            cfg, ...
            "Does a physical-regime split improve this firmware transition delay?");
    end
end

rows = rows(~cellfun(@isempty,rows));

if isempty(rows)
    T = table();
else
    T = vertcat(rows{:});
end

% Carry the original Stage 6 recommendation beside the evidence when there
% is a direct subsystem-level recommendation.
OriginalStage6Recommendation = strings(height(T),1);

for i = 1:height(T)

    s = T.Subsystem(i);

    if startsWith(s,"FAST_DYNAMICS")
        OriginalStage6Recommendation(i) = string(stage6.fast.recommended);
    elseif startsWith(s,"ORDINARY_DROOP")
        OriginalStage6Recommendation(i) = string(stage6.droop.recommended);
    elseif startsWith(s,"COMPLIANCE_COLLAPSE")
        OriginalStage6Recommendation(i) = string(stage6.collapse.recommended);
    elseif startsWith(s,"STATIC_SCALE")
        OriginalStage6Recommendation(i) = string(stage6.static.recommended);
    elseif startsWith(s,"DELAY_")
        OriginalStage6Recommendation(i) = "TRANSITION_CLASS_SPECIFIC";
    end
end

T.OriginalStage6Recommendation = OriginalStage6Recommendation;

end

function row = evidenceRow( ...
    subsystem,A,candidate,reference,cfg,question)

if isempty(A) || ~isfield(A,"architecture") || isempty(A.architecture)
    row = table();
    return;
end

candidate = string(candidate);
reference = string(reference);

arch = A.architecture;

ic = find(arch.Architecture==candidate,1);
ir = find(arch.Architecture==reference,1);

if isempty(ic) || isempty(ir)
    row = table();
    return;
end

scoreCandidate = arch.ObservedScore(ic);
scoreReference = arch.ObservedScore(ir);

% Recover the pairwise comparison in either orientation.
P = A.pairwise;

idx = find( ...
    (P.ArchitectureA==candidate & P.ArchitectureB==reference) | ...
    (P.ArchitectureA==reference & P.ArchitectureB==candidate), ...
    1);

if isempty(idx)
    row = table();
    return;
end

if P.ArchitectureA(idx)==candidate

    delta = P.Delta_AminusB(idx);
    dLo = P.DeltaCI95_Lower(idx);
    dHi = P.DeltaCI95_Upper(idx);
    ratio = P.Ratio_AoverB(idx);
    rLo = P.RatioCI95_Lower(idx);
    rHi = P.RatioCI95_Upper(idx);
    pCandidateBetter = P.BootstrapProbability_A_Better(idx);
    pExact = P.ExactSignFlipP(idx);
    pHolm = P.HolmAdjustedExactSignFlipP(idx);

else

    delta = -P.Delta_AminusB(idx);
    dLo = -P.DeltaCI95_Upper(idx);
    dHi = -P.DeltaCI95_Lower(idx);

    ratio = 1/P.Ratio_AoverB(idx);
    rLo = 1/P.RatioCI95_Upper(idx);
    rHi = 1/P.RatioCI95_Lower(idx);

    pCandidateBetter = 1-P.BootstrapProbability_A_Better(idx);
    pExact = P.ExactSignFlipP(idx);
    pHolm = P.HolmAdjustedExactSignFlipP(idx);
end

simplicityMarginAbs = ...
    cfg.SIMPLICITY_RELATIVE_RMSE_TOL*scoreReference;

maxUnifiedMarginAbs = ...
    (cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO-1)*scoreReference;

% Use stored bootstrap score matrices to compute direct practical
% probabilities in the requested orientation.
archNames = A.architectureNames;

jc = find(archNames==candidate,1);
jr = find(archNames==reference,1);

bc = A.bootstrapScores(:,jc);
br = A.bootstrapScores(:,jr);

pWithinSimple = mean( ...
    bc <= br.*(1+cfg.SIMPLICITY_RELATIVE_RMSE_TOL), ...
    'omitnan');

pWithinMax = mean( ...
    bc <= br.*cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO, ...
    'omitnan');

% Practical interpretation.
statDifferent = ...
    (dLo>0 || dHi<0) && ...
    isfinite(pHolm) && ...
    pHolm<0.05;

simpleNonInferior = dHi <= simplicityMarginAbs;
maxNonInferior = dHi <= maxUnifiedMarginAbs;

if simpleNonInferior
    practical = "WITHIN_STAGE6_SIMPLICITY_MARGIN";
elseif maxNonInferior
    practical = "WITHIN_STAGE6_MAX_UNIFIED_PENALTY";
else
    practical = "PENALTY_NOT_SHOWN_NONINFERIOR";
end

if statDifferent
    if delta<0
        statistical = "CANDIDATE_LOWER_ERROR";
    else
        statistical = "CANDIDATE_HIGHER_ERROR";
    end
else
    statistical = "NO_HOLM_CORRECTED_DIFFERENCE_DETECTED";
end

row = table( ...
    string(subsystem), ...
    candidate, ...
    reference, ...
    string(question), ...
    scoreCandidate, ...
    scoreReference, ...
    delta, ...
    dLo, ...
    dHi, ...
    ratio, ...
    rLo, ...
    rHi, ...
    pCandidateBetter, ...
    pExact, ...
    pHolm, ...
    simplicityMarginAbs, ...
    pWithinSimple, ...
    maxUnifiedMarginAbs, ...
    pWithinMax, ...
    string(statistical), ...
    string(practical), ...
    'VariableNames',{ ...
    'Subsystem', ...
    'CandidateArchitecture', ...
    'ReferenceArchitecture', ...
    'Question', ...
    'CandidateScore', ...
    'ReferenceScore', ...
    'DeltaCandidateMinusReference', ...
    'DeltaCI95_Lower', ...
    'DeltaCI95_Upper', ...
    'RatioCandidateOverReference', ...
    'RatioCI95_Lower', ...
    'RatioCI95_Upper', ...
    'BootstrapProbabilityCandidateLowerError', ...
    'ExactSignFlipP', ...
    'HolmAdjustedExactSignFlipP', ...
    'Stage6SimplicityMarginAbsolute', ...
    'BootstrapProbabilityWithinSimplicityMargin', ...
    'Stage6MaxUnifiedPenaltyAbsolute', ...
    'BootstrapProbabilityWithinMaxUnifiedPenalty', ...
    'StatisticalEvidence', ...
    'PracticalEvidence'});
end

%% ========================================================================
% STATISTICAL HELPERS
% ========================================================================

function ci = empiricalCI(x,level)

x = x(isfinite(x));

if isempty(x)
    ci = [NaN NaN];
    return;
end

alpha = 1-level;

ci = [ ...
    empiricalQuantile(x,alpha/2), ...
    empiricalQuantile(x,1-alpha/2)];
end

function q = empiricalQuantile(x,p)

x = sort(x(:));
n = numel(x);

if n==0
    q = NaN;
    return;
end

if n==1
    q = x;
    return;
end

p = min(max(p,0),1);

h = 1 + (n-1)*p;

lo = floor(h);
hi = ceil(h);

if lo==hi
    q = x(lo);
else
    w = h-lo;
    q = (1-w)*x(lo)+w*x(hi);
end
end

function p = exactSignFlipP(d)

d = d(isfinite(d));
d = d(abs(d)>0);

n = numel(d);

if n==0
    p = 1;
    return;
end

obs = abs(mean(d));

if n<=20

    nComb = 2^n;
    exceed = 0;

    for mask = 0:(nComb-1)

        s = ones(n,1);

        for k = 1:n
            if bitget(mask,k)
                s(k) = -1;
            end
        end

        stat = abs(mean(s.*d));

        if stat >= obs-1e-15
            exceed = exceed+1;
        end
    end

    p = exceed/nComb;

else

    B = 200000;
    exceed = 0;

    for b = 1:B
        s = 2*(rand(n,1)>0.5)-1;
        stat = abs(mean(s.*d));
        if stat >= obs-1e-15
            exceed = exceed+1;
        end
    end

    p = (exceed+1)/(B+1);
end
end

function pmin = minExactTwoSidedP(n)

if n<=0
    pmin = NaN;
else
    pmin = min(1,2^(1-n));
end
end

function adj = holmAdjust(p)

p = p(:);
adj = NaN(size(p));

valid = isfinite(p);

pv = p(valid);

if isempty(pv)
    return;
end

[mSorted,ord] = sort(pv);
m = numel(pv);

a = NaN(m,1);

running = 0;

for k = 1:m
    raw = (m-k+1)*mSorted(k);
    running = max(running,raw);
    a(k) = min(running,1);
end

tmp = NaN(m,1);
tmp(ord) = a;

adj(valid) = tmp;
end

%% ========================================================================
% PREDICTION HELPERS
% ========================================================================

function y = fastCurve(M,t)

modelName = resolveFastModelName(M);

x = t(:)-M.theta_us;
y = zeros(size(x));

a = x>=0;
xa = x(a);

switch modelName

    case "FOP"

        y(a) = 1-exp(-xa/M.tau_us);

    case "TWO_POLE"

        t1 = M.tau1_us;
        t2 = M.tau2_us;

        if abs(t1-t2)<1e-5*max(t1,t2)

            tau = .5*(t1+t2);
            y(a) = 1-exp(-xa/tau).*(1+xa/tau);

        else

            y(a) = ...
                1-(t2*exp(-xa/t2)-t1*exp(-xa/t1))/(t2-t1);
        end

    case "SECOND_ORDER"

        wn = M.wn_rad_per_us;
        z = M.zeta;

        if z<1-1e-5

            wd = wn*sqrt(1-z^2);

            y(a) = ...
                1-exp(-z*wn*xa).* ...
                (cos(wd*xa)+z/sqrt(1-z^2)*sin(wd*xa));

        elseif z>1+1e-5

            q = sqrt(z^2-1);
            r1 = -wn*(z-q);
            r2 = -wn*(z+q);

            y(a) = ...
                1+(r2*exp(r1*xa)-r1*exp(r2*xa))/(r1-r2);

        else

            y(a) = ...
                1-exp(-wn*xa).*(1+wn*xa);
        end

    otherwise

        y(:) = NaN;
end
end

function modelName = resolveFastModelName(M)

if isfield(M,'modelName') && strlength(string(M.modelName))>0
    modelName = string(M.modelName);
elseif isfield(M,'wn_rad_per_us') && isfield(M,'zeta')
    modelName = "SECOND_ORDER";
elseif isfield(M,'tau1_us') && isfield(M,'tau2_us')
    modelName = "TWO_POLE";
elseif isfield(M,'tau_us')
    modelName = "FOP";
else
    error("Unable to determine fast-model family.");
end
end

function r = rmsError(y,yhat)

good = isfinite(y) & isfinite(yhat);

if ~any(good)
    r = NaN;
else
    e = y(good)-yhat(good);
    r = sqrt(mean(e.^2));
end
end
