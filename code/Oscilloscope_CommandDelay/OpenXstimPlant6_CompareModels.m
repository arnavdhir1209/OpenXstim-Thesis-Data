function results = OpenXstimPlant6_CompareModels( ...
    staticResult,fastResult,slowResult,cfg)
% OpenXstimPlant6_CompareModels
%
% Quantitative Stage 6 model-reduction comparison.
%
% The main principle is equal weighting of current levels wherever possible.
% A current with many more waveform samples should not automatically dominate
% the decision simply because it contributes more points.

results = struct();

fprintf("============================================================\n");
fprintf("1. STATIC SCALE UNIFICATION\n");
fprintf("============================================================\n");
results.static = compareStatic(staticResult,cfg);
disp(results.static.candidates);
fprintf("Selected static architecture: %s\n\n",results.static.recommended);

fprintf("============================================================\n");
fprintf("2. FAST-DYNAMICS UNIFICATION\n");
fprintf("============================================================\n");
results.fast = compareFast(fastResult,cfg);
disp(results.fast.architectureCandidates);
fprintf("Selected fast architecture: %s\n\n",results.fast.recommended);

fprintf("============================================================\n");
fprintf("3. DELAY UNIFICATION\n");
fprintf("============================================================\n");
results.delay = compareDelay(fastResult,cfg);
disp(results.delay.candidates);

fprintf("============================================================\n");
fprintf("4. ORDINARY-DROOP UNIFICATION\n");
fprintf("============================================================\n");
results.droop = compareDroop(slowResult,cfg);
disp(results.droop.candidates);
fprintf("Selected droop architecture: %s\n\n",results.droop.recommended);

fprintf("============================================================\n");
fprintf("5. COMPLIANCE-COLLAPSE UNIFICATION\n");
fprintf("============================================================\n");
results.collapse = compareCollapse(slowResult,cfg);
disp(results.collapse.candidates);
fprintf("Selected collapse architecture: %s\n\n",results.collapse.recommended);

results.recommendationTable = buildRecommendationTable(results);
end

%% ========================================================================
% STATIC SCALE
% ========================================================================

function R = compareStatic(staticResult,cfg)

T = staticResult.currentSummary;

x = T.CommandCurrent_mA(:);
y = T.MeanMeasuredIpp_mA(:);

valid = isfinite(x) & isfinite(y);
x = x(valid);
y = y(valid);

% Equal current weighting is deliberate. The tiny repeat SD values likely
% under-represent systematic effects such as finite output impedance,
% heating/calibration drift, and compliance/headroom effects.

g = sum(x.*y)/sum(x.^2);
yGain = g*x;

Xq = [x x.^2];
bq = Xq\y;
yQuad = Xq*bq;

rmseGain = rmse(y,yGain);
rmseQuad = rmse(y,yQuad);

looGain = staticLoo(x,y,"GAIN");
looQuad = staticLoo(x,y,"QUADRATIC_ORIGIN");

Model = ["GAIN";"QUADRATIC_ORIGIN"];
ParameterCount = [1;2];
FitRMSE_mA = [rmseGain;rmseQuad];
LeaveOneCurrentOutRMSE_mA = [looGain;looQuad];
Parameters = [ ...
    string(sprintf("Ipp=%.9g*Icmd",g)); ...
    string(sprintf("Ipp=%.9g*Icmd + %.9g*Icmd^2",bq(1),bq(2)))];

candidates = table(Model,ParameterCount,FitRMSE_mA, ...
    LeaveOneCurrentOutRMSE_mA,Parameters);

bestCv = min(LeaveOneCurrentOutRMSE_mA);
eligible = LeaveOneCurrentOutRMSE_mA <= ...
    bestCv*(1+cfg.SIMPLICITY_RELATIVE_RMSE_TOL);

idx = find(eligible,1,'first');
if isempty(idx)
    [~,idx] = min(LeaveOneCurrentOutRMSE_mA);
end

recommended = Model(idx);

R = struct();
R.candidates = candidates;
R.recommended = recommended;
R.commandCurrent_mA = x;
R.measuredIpp_mA = y;
R.gain = g;
R.quadratic = bq;
R.predGain_mA = yGain;
R.predQuadratic_mA = yQuad;
R.interpretationNote = [ ...
    "Empirical amplitude calibration only. A current-dependent scale does " + ...
    "not prove intrinsic nonlinear gain; finite output impedance, resistor " + ...
    "heating, calibration and compliance/headroom may contribute."];
end

function value = staticLoo(x,y,model)

pred = NaN(size(y));

for k = 1:numel(x)
    tr = true(size(x));
    tr(k) = false;

    switch string(model)
        case "GAIN"
            g = sum(x(tr).*y(tr))/sum(x(tr).^2);
            pred(k) = g*x(k);

        case "QUADRATIC_ORIGIN"
            X = [x(tr) x(tr).^2];
            b = X\y(tr);
            pred(k) = [x(k) x(k)^2]*b;
    end
end

value = rmse(y,pred);
end

%% ========================================================================
% FAST DYNAMICS
% ========================================================================

function R = compareFast(fastResult,cfg)

currents = cfg.COMMAND_CURRENTS_mApp(:);
t = fastResult.time_us(:);
fitMask = t>=cfg.FAST_FIT_START_US & t<=cfg.FAST_FIT_END_US;

D = repmat(struct(),numel(currents),1);

for k = 1:numel(currents)
    I = currents(k);
    B = fastResult.byCurrent(k);

    if B.fullReversal.identifiable
        Q = B.fullReversal;
        regime = "FULL_REVERSAL";
    elseif B.nearZeroStart.identifiable
        Q = B.nearZeroStart;
        regime = "NEAR_ZERO_START";
    else
        Q = [];
        regime = "UNIDENTIFIED";
    end

    D(k).current = I;
    D(k).regime = regime;

    if isempty(Q)
        D(k).valid = false;
        D(k).y = NaN(size(t));
        D(k).localModel = struct();
        D(k).localRMSE = NaN;
        continue;
    end

    y = Q.meanWaveform(:);
    good = fitMask & isfinite(t) & isfinite(y);

    D(k).valid = nnz(good)>=20;
    D(k).y = y;
    D(k).localModel = Q.best;

    if D(k).valid
        yLocal = fastCurve(Q.best,t);
        D(k).localRMSE = rmse(y(good),yLocal(good));
    else
        D(k).localRMSE = NaN;
    end
end

validIdx = find([D.valid]);
fullIdx = validIdx(arrayfun(@(q) q.regime=="FULL_REVERSAL",D(validIdx)));
nearIdx = validIdx(arrayfun(@(q) q.regime=="NEAR_ZERO_START",D(validIdx)));

families = ["FOP","SECOND_ORDER","TWO_POLE"];

allFit = fitFastGroup(D,validIdx,t,fitMask,families,cfg);
fullFit = fitFastGroup(D,fullIdx,t,fitMask,families,cfg);
nearFit = fitFastGroup(D,nearIdx,t,fitMask,families,cfg);

localMean = mean([D(validIdx).localRMSE],'omitnan');
localWorst = max([D(validIdx).localRMSE],[],'omitnan');

allMean = allFit.selected.meanCurrentRMSE;
allWorst = allFit.selected.worstCurrentRMSE;

splitRMSE = NaN(numel(validIdx),1);
for q = 1:numel(validIdx)
    idx = validIdx(q);
    if D(idx).regime=="FULL_REVERSAL"
        splitRMSE(q) = currentFastRMSE(D(idx),fullFit.selected.model,t,fitMask);
    else
        splitRMSE(q) = currentFastRMSE(D(idx),nearFit.selected.model,t,fitMask);
    end
end
splitMean = mean(splitRMSE,'omitnan');
splitWorst = max(splitRMSE,[],'omitnan');

Architecture = ["LOCAL_REFERENCE";"ALL_CURRENT_COMMON";"PHYSICAL_REGIME_SPLIT"];
ParameterCount = [NaN;allFit.selected.parameterCount; ...
    fullFit.selected.parameterCount + nearFit.selected.parameterCount];
MeanCurrentRMSE = [localMean;allMean;splitMean];
WorstCurrentRMSE = [localWorst;allWorst;splitWorst];
RelativeToLocal = MeanCurrentRMSE/localMean;
Description = [ ...
    "Stage 5 per-current selected fast models"; ...
    "One fitted fast model across all physical regimes"; ...
    "One FULL_REVERSAL model plus one NEAR_ZERO_START model"];

architectureCandidates = table(Architecture,ParameterCount, ...
    MeanCurrentRMSE,WorstCurrentRMSE,RelativeToLocal,Description);

% Prefer all-common only if it is effectively as good as regime split and
% does not create a bad worst-current penalty. Otherwise retain regime split.
if allMean <= splitMean*(1+cfg.SIMPLICITY_RELATIVE_RMSE_TOL) && ...
        allWorst <= splitWorst*(1+cfg.WORST_CURRENT_RELATIVE_TOL) && ...
        allMean <= localMean*cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO
    recommended = "ALL_CURRENT_COMMON";
elseif splitMean <= localMean*cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO
    recommended = "PHYSICAL_REGIME_SPLIT";
else
    recommended = "KEEP_CURRENT_SPECIFIC";
end

R = struct();
R.data = D;
R.time_us = t;
R.fitMask = fitMask;
R.allCommon = allFit;
R.fullReversalCommon = fullFit;
R.nearZeroCommon = nearFit;
R.architectureCandidates = architectureCandidates;
R.recommended = recommended;
R.highCurrentFlag = [ ...
    "30/50 mA NEAR_ZERO_START is a physical pre-state category only. " + ...
    "Firmware transition classes and their delays remain unchanged."];
end

function G = fitFastGroup(D,idx,t,fitMask,families,cfg)

G = struct();

if isempty(idx)
    G.candidates = table();
    G.models = cell(0,1);
    G.selected = emptyFastSelection();
    return;
end

rows = cell(numel(families),1);

% Different fast-model families have different parameter fields. Store the
% fitted model structs in a cell array so MATLAB never has to force FOP,
% SECOND_ORDER and TWO_POLE into one homogeneous struct array.
models = cell(numel(families),1);

for f = 1:numel(families)
    family = families(f);
    M = fitCommonFastFamily(D,idx,t,fitMask,family,cfg);
    models{f} = M;
    rows{f} = table( ...
        family,M.parameterCount,M.meanCurrentRMSE,M.worstCurrentRMSE, ...
        string(M.parameterText), ...
        'VariableNames',{ ...
        'Model','ParameterCount','MeanCurrentRMSE','WorstCurrentRMSE','Parameters'});
end

C = vertcat(rows{:});

best = min(C.MeanCurrentRMSE);
eligible = C.MeanCurrentRMSE <= best*(1+0.03);

% Family preference when errors are effectively tied:
% FOP first for simplicity, then SECOND_ORDER, then TWO_POLE.
priority = [1 2 3];
sel = NaN;
for p = priority
    if eligible(p)
        sel = p;
        break;
    end
end
if ~isfinite(sel)
    [~,sel] = min(C.MeanCurrentRMSE);
end

G.candidates = C;
G.models = models;
selectedModel = models{sel};

G.selected = struct( ...
    'family',families(sel), ...
    'model',selectedModel, ...
    'parameterCount',selectedModel.parameterCount, ...
    'meanCurrentRMSE',selectedModel.meanCurrentRMSE, ...
    'worstCurrentRMSE',selectedModel.worstCurrentRMSE);
end

function S = emptyFastSelection()
S = struct('family',"",'model',struct(),'parameterCount',NaN, ...
    'meanCurrentRMSE',NaN,'worstCurrentRMSE',NaN);
end

function M = fitCommonFastFamily(D,idx,t,fitMask,family,cfg)

% Reasonable transformed initial guesses.
switch string(family)
    case "FOP"
        p0 = [log(2.0), -1.0];
    case "SECOND_ORDER"
        p0 = [log(0.68), log(1.0), -1.5];
    case "TWO_POLE"
        p0 = [log(1.4), log(1.8), -1.5];
    otherwise
        error("Unknown fast family %s",family);
end

obj = @(p) commonFastObjective(p,D,idx,t,fitMask,family);
[p,~] = fminsearch(obj,p0,cfg.optimOptions);

M = unpackFastParams(p,family);
M.parameterCount = numel(p);

perCurrent = NaN(numel(idx),1);
for q = 1:numel(idx)
    perCurrent(q) = currentFastRMSE(D(idx(q)),M,t,fitMask);
end

M.perCurrentRMSE = perCurrent;
M.currents = [D(idx).current].';
M.meanCurrentRMSE = mean(perCurrent,'omitnan');
M.worstCurrentRMSE = max(perCurrent,[],'omitnan');
M.parameterText = fastParameterText(M);
end

function value = commonFastObjective(p,D,idx,t,fitMask,family)
M = unpackFastParams(p,family);
e = NaN(numel(idx),1);
for q = 1:numel(idx)
    e(q) = currentFastRMSE(D(idx(q)),M,t,fitMask);
end
value = mean(e.^2,'omitnan');
if ~isfinite(value), value = 1e6; end
end

function value = currentFastRMSE(Dk,M,t,fitMask)
yhat = fastCurve(M,t);
good = fitMask & isfinite(Dk.y) & isfinite(yhat);
if nnz(good)<20
    value = NaN;
else
    value = rmse(Dk.y(good),yhat(good));
end
end

function M = unpackFastParams(p,family)
M = struct();

% modelName must be attached here, not only after fminsearch. The objective
% function calls fastCurve() on every trial parameter vector, so the model
% family has to be known during optimization as well as after it.
M.modelName = string(family);

switch string(family)
    case "FOP"
        M.tau_us = exp(p(1));
        M.theta_us = p(2);
    case "SECOND_ORDER"
        M.wn_rad_per_us = exp(p(1));
        M.zeta = exp(p(2));
        M.theta_us = p(3);
    case "TWO_POLE"
        a = exp(p(1));
        b = exp(p(2));
        M.tau1_us = min(a,b);
        M.tau2_us = max(a,b);
        M.theta_us = p(3);
end
end

function s = fastParameterText(M)
switch string(M.modelName)
    case "FOP"
        s = sprintf("tau=%.5g us, theta=%.5g us",M.tau_us,M.theta_us);
    case "SECOND_ORDER"
        s = sprintf("wn=%.5g Mrad/s, zeta=%.5g, theta=%.5g us", ...
            M.wn_rad_per_us,M.zeta,M.theta_us);
    case "TWO_POLE"
        s = sprintf("tau1=%.5g us, tau2=%.5g us, theta=%.5g us", ...
            M.tau1_us,M.tau2_us,M.theta_us);
end
end

%% ========================================================================
% DELAY
% ========================================================================

function R = compareDelay(fastResult,cfg)

T = resolveDelaySummary(fastResult);

classes = ["pos_to_neg","neg_to_pos","neg_to_zero","zero_to_pos"];
rows = {};
models = struct();

for c = 1:numel(classes)
    cls = classes(c);

    m = string(T.TransitionClass)==cls & isfinite(T.MeanTransportDelay_us);
    Q = T(m,:);

    if isempty(Q)
        continue;
    end

    x = Q.CommandCurrent_mA(:);
    y = Q.MeanTransportDelay_us(:);

    % Collapse duplicate current entries only if they exist.
    [xu,~,g] = unique(x);
    yu = accumarray(g,y,[],@mean);

    const = mean(yu,'omitnan');
    predConst = repmat(const,size(yu));
    rmseConst = rmse(yu,predConst);
    cvConst = looDelay(xu,yu,"CONSTANT");

    if numel(xu)>=3
        b = polyfit(xu,yu,1);
        predLin = polyval(b,xu);
        rmseLin = rmse(yu,predLin);
        cvLin = looDelay(xu,yu,"LINEAR");
    else
        b = [NaN NaN];
        rmseLin = NaN;
        cvLin = NaN;
    end

    % Physical-regime split is only meaningful for repeating internal
    % bipolar transition classes. Firmware class remains unchanged.
    rmseSplit = NaN;
    splitLow = NaN;
    splitHigh = NaN;

    if ismember(cls,["pos_to_neg","neg_to_pos"])
        low = ismember(xu,cfg.FULL_REVERSAL_CURRENTS_mApp);
        high = ismember(xu,cfg.NEAR_ZERO_START_CURRENTS_mApp);
        if any(low) && any(high)
            splitLow = mean(yu(low),'omitnan');
            splitHigh = mean(yu(high),'omitnan');
            pred = NaN(size(yu));
            pred(low) = splitLow;
            pred(high) = splitHigh;
            rmseSplit = rmse(yu,pred);
        end
    end

    if cls=="zero_to_pos"
        rec = "KEEP_LITERAL_STARTUP_SEPARATE";
    elseif cls=="neg_to_zero"
        rec = "CONSTANT_BOUNDARY_DELAY";
    else
        improveSplit = rmseConst-rmseSplit;
        improveLinear = cvConst-cvLin;

        if isfinite(rmseSplit) && ...
                improveSplit>=cfg.DELAY_MIN_ABSOLUTE_IMPROVEMENT_US && ...
                rmseSplit < rmseConst*(1-cfg.SIMPLICITY_RELATIVE_RMSE_TOL)
            rec = "PHYSICAL_REGIME_SPLIT_CONSTANT";
        elseif isfinite(cvLin) && ...
                improveLinear>=cfg.DELAY_MIN_ABSOLUTE_IMPROVEMENT_US
            rec = "LINEAR_CURRENT";
        else
            rec = "CONSTANT";
        end
    end

    models.(matlab.lang.makeValidName(cls)) = struct( ...
        'x',xu,'y',yu,'constant',const,'linearCoeff',b, ...
        'splitLow',splitLow,'splitHigh',splitHigh,'recommended',rec);

    rows{end+1,1} = table( ...
        cls,numel(xu),rmseConst,cvConst,rmseLin,cvLin,rmseSplit,rec, ...
        'VariableNames',{ ...
        'TransitionClass','NCurrentLevels','ConstantFitRMSE_us', ...
        'ConstantLOOCVRMSE_us','LinearFitRMSE_us','LinearLOOCVRMSE_us', ...
        'RegimeSplitFitRMSE_us','Recommended'}); %#ok<AGROW>
end

if isempty(rows)
    candidates = table();
else
    candidates = vertcat(rows{:});
end

R = struct();
R.delaySummary = T;
R.candidates = candidates;
R.models = models;
R.note = [ ...
    "Firmware transition class and physical transition regime are separate. " + ...
    "30/50 mA internal near-zero starts keep their original pos_to_neg or " + ...
    "neg_to_pos firmware-delay interpretation."];
end

function value = looDelay(x,y,model)
pred = NaN(size(y));
for k = 1:numel(x)
    tr = true(size(x));
    tr(k)=false;
    switch string(model)
        case "CONSTANT"
            pred(k)=mean(y(tr),'omitnan');
        case "LINEAR"
            if nnz(tr)>=2
                b=polyfit(x(tr),y(tr),1);
                pred(k)=polyval(b,x(k));
            end
    end
end
value=rmse(y,pred);
end

%% ========================================================================
% DROOP
% ========================================================================

function R = compareDroop(slowResult,cfg)

currents = cfg.COMMAND_CURRENTS_mApp(:);
D = repmat(struct(),numel(currents),1);

for k = 1:numel(currents)
    S = slowResult.byCurrent(k);
    D(k).current = currents(k);

    if ~S.droop.identifiable
        D(k).valid=false;
        continue;
    end

    t = S.droop.time_us(:)/1000;
    y = S.droop.meanUsedWaveform(:);
    good = isfinite(t) & isfinite(y);
    t=t(good); y=y(good);

    kLocal = S.droop.best.rate_per_ms;
    ordinary = 1-kLocal*t;

    idx = [];
    if S.collapse.identifiable
        idx = find( ...
            y < ordinary-cfg.DROOP_DEPARTURE_THRESHOLD & ...
            y < cfg.DROOP_COLLAPSE_LEVEL,1,'first');
    else
        % Even without a formally identifiable collapse model, trim a sharp
        % end artifact if it departs strongly from the local ordinary trend.
        idx = find(y < ordinary-0.08 & y<0.80,1,'first');
    end

    if isempty(idx)
        use = true(size(t));
    else
        use = (1:numel(t)).' < idx;
    end

    if nnz(use)<cfg.MIN_DROOP_SAMPLES
        use = true(size(t));
    end

    D(k).valid=true;
    D(k).t=t;
    D(k).y=y;
    D(k).use=use;
    D(k).localRate=kLocal;
    D(k).collapseIdentifiable=S.collapse.identifiable;
    D(k).localRMSE=rmse(y(use),1-kLocal*t(use));
end

valid = find([D.valid]);

% Common slope through D(0)=1.
[kCommon,rmseCommon,perCommon] = fitDroopArchitecture(D,valid,"COMMON",cfg);

% Smooth linear dependence k(I)=a+bI.
[linCoeff,rmseLinear,perLinear] = fitDroopArchitecture(D,valid,"LINEAR_CURRENT",cfg);

% Two simple groups. This is tested, not assumed.
[groupRates,rmseTwo,perTwo] = fitDroopArchitecture(D,valid,"TWO_GROUP",cfg);

localPer = [D(valid).localRMSE].';
localMean = mean(localPer,'omitnan');

Architecture = ["LOCAL_REFERENCE";"COMMON_LINEAR";"LINEAR_CURRENT";"TWO_GROUP_LINEAR"];
ParameterCount = [numel(valid);1;2;2];
MeanCurrentRMSE = [localMean;rmseCommon;rmseLinear;rmseTwo];
WorstCurrentRMSE = [max(localPer);max(perCommon);max(perLinear);max(perTwo)];
RelativeToLocal = MeanCurrentRMSE/localMean;
Parameters = [ ...
    "One independent Stage 5 k per current"; ...
    sprintf("k=%.8g /ms",kCommon); ...
    sprintf("k=%.8g + %.8g*Icmd /ms",linCoeff(1),linCoeff(2)); ...
    sprintf("kFull=%.8g /ms, kHigh=%.8g /ms",groupRates(1),groupRates(2))];

candidates = table(Architecture,ParameterCount,MeanCurrentRMSE, ...
    WorstCurrentRMSE,RelativeToLocal,Parameters);

% Choose among unified/grouped candidates only, then compare to local.
idxUnified = 2:4;
best = min(MeanCurrentRMSE(idxUnified));
eligible = MeanCurrentRMSE(idxUnified) <= ...
    best*(1+cfg.SIMPLICITY_RELATIVE_RMSE_TOL);

% Prefer common, then linear-current, then two-group when errors are tied.
ord = idxUnified(eligible);
if isempty(ord)
    [~,ii]=min(MeanCurrentRMSE(idxUnified));
    sel=idxUnified(ii);
else
    sel=ord(1);
end

if MeanCurrentRMSE(sel) > localMean*cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO
    recommended = "KEEP_CURRENT_SPECIFIC";
else
    recommended = Architecture(sel);
end

R = struct();
R.data=D;
R.candidates=candidates;
R.commonRate_per_ms=kCommon;
R.linearCurrentCoeff=linCoeff;
R.twoGroupRates_per_ms=groupRates;
R.recommended=recommended;
end

function [param,meanRMSE,perCurrent] = fitDroopArchitecture(D,idx,mode,cfg)

switch string(mode)
    case "COMMON"
        num=0; den=0;
        for q=idx(:).'
            t=D(q).t(D(q).use); y=D(q).y(D(q).use);
            num=num+sum(t.*(1-y));
            den=den+sum(t.^2);
        end
        param=max(num/max(den,eps),0);

    case "LINEAR_CURRENT"
        A=[]; b=[];
        for q=idx(:).'
            t=D(q).t(D(q).use); y=D(q).y(D(q).use);
            I=D(q).current;
            A=[A; t I*t]; %#ok<AGROW>
            b=[b; 1-y]; %#ok<AGROW>
        end
        p=A\b;
        param=p(:).';

    case "TWO_GROUP"
        low=idx(ismember([D(idx).current],cfg.FULL_REVERSAL_CURRENTS_mApp));
        high=idx(ismember([D(idx).current],cfg.NEAR_ZERO_START_CURRENTS_mApp));
        if isempty(high)
            high=idx([D(idx).current]>20);
        end
        k1=fitSingleDroopRate(D,low);
        k2=fitSingleDroopRate(D,high);
        param=[k1 k2];
end

perCurrent=NaN(numel(idx),1);
for j=1:numel(idx)
    q=idx(j);
    t=D(q).t(D(q).use); y=D(q).y(D(q).use);
    switch string(mode)
        case "COMMON"
            k=param;
        case "LINEAR_CURRENT"
            k=param(1)+param(2)*D(q).current;
        case "TWO_GROUP"
            if ismember(D(q).current,cfg.FULL_REVERSAL_CURRENTS_mApp)
                k=param(1);
            else
                k=param(2);
            end
    end
    yhat=1-k*t;
    perCurrent(j)=rmse(y,yhat);
end
meanRMSE=mean(perCurrent,'omitnan');
end

function k=fitSingleDroopRate(D,idx)
num=0; den=0;
for q=idx(:).'
    t=D(q).t(D(q).use); y=D(q).y(D(q).use);
    num=num+sum(t.*(1-y));
    den=den+sum(t.^2);
end
k=max(num/max(den,eps),0);
end

%% ========================================================================
% COLLAPSE
% ========================================================================

function R = compareCollapse(slowResult,cfg)

currents = cfg.COMMAND_CURRENTS_mApp(:);
D = repmat(struct(),numel(currents),1);

for k=1:numel(currents)
    S=slowResult.byCurrent(k);
    D(k).current=currents(k);
    D(k).valid=S.collapse.identifiable;

    if ~D(k).valid
        continue;
    end

    x=S.collapse.diagnosticX(:);
    y=S.collapse.diagnosticObserved(:);
    good=isfinite(x)&isfinite(y);
    D(k).x=x(good);
    D(k).y=y(good);
    D(k).localModel=S.collapse.best;
    yhat=collapseCurve(S.collapse.best,D(k).x);
    D(k).localRMSE=rmse(D(k).y,yhat);
end

idx=find([D.valid]);

if isempty(idx)
    R=struct('data',D,'candidates',table(),'recommended',"NONE_IDENTIFIED");
    return;
end

localPer=[D(idx).localRMSE].';
localMean=mean(localPer,'omitnan');

commonShift=fitCollapseCommon(D,idx,"COMMON_SHIFTED",cfg);
commonStretch=fitCollapseCommon(D,idx,"COMMON_STRETCHED",cfg);
thresholdStretch=fitCollapseCommon(D,idx,"Q0_LINEAR_STRETCHED",cfg);

% Explicit two-regime hypothesis:
% 20 mA transition regime remains local, while 30/50 mA share one strong-
% collapse model. This tests the user's observed two slow behaviours without
% forcing 20 mA to look identical to 30/50 mA.
idxTransition=idx([D(idx).current]==cfg.TRANSITION_COLLAPSE_CURRENT_mApp);
idxStrong=idx(ismember([D(idx).current],cfg.STRONG_COLLAPSE_CURRENTS_mApp));

twoRegimePer=NaN(numel(idx),1);
twoRegimeParamCount=0;
strongFit=struct();

if ~isempty(idxStrong)
    strongFit=fitCollapseCommon(D,idxStrong,"COMMON_STRETCHED",cfg);
end

for j=1:numel(idx)
    q=idx(j);
    if ismember(q,idxTransition)
        twoRegimePer(j)=D(q).localRMSE;
    elseif ismember(q,idxStrong)
        twoRegimePer(j)=collapseCurrentRMSE(D(q),strongFit.model);
    end
end

if ~isempty(idxTransition)
    twoRegimeParamCount=twoRegimeParamCount+localCollapseParamCount(D(idxTransition(1)).localModel);
end
if ~isempty(idxStrong)
    twoRegimeParamCount=twoRegimeParamCount+strongFit.parameterCount;
end

twoRegimeMean=mean(twoRegimePer,'omitnan');
twoRegimeWorst=max(twoRegimePer,[],'omitnan');

Architecture=[ ...
    "LOCAL_REFERENCE"; ...
    "COMMON_SHIFTED_EXP"; ...
    "COMMON_STRETCHED_EXP"; ...
    "CURRENT_THRESHOLD_STRETCHED_EXP"; ...
    "TRANSITION_PLUS_STRONG_COLLAPSE"];
ParameterCount=[ ...
    sum(arrayfun(@(q)localCollapseParamCount(D(q).localModel),idx)); ...
    commonShift.parameterCount; ...
    commonStretch.parameterCount; ...
    thresholdStretch.parameterCount; ...
    twoRegimeParamCount];
MeanCurrentRMSE=[ ...
    localMean; ...
    commonShift.meanCurrentRMSE; ...
    commonStretch.meanCurrentRMSE; ...
    thresholdStretch.meanCurrentRMSE; ...
    twoRegimeMean];
WorstCurrentRMSE=[ ...
    max(localPer); ...
    commonShift.worstCurrentRMSE; ...
    commonStretch.worstCurrentRMSE; ...
    thresholdStretch.worstCurrentRMSE; ...
    twoRegimeWorst];
RelativeToLocal=MeanCurrentRMSE/localMean;
Eligibility=[true;true;true;false;true];
Description=[ ...
    "Independent Stage 5 collapse law per current"; ...
    "One shifted exponential across all collapse currents"; ...
    "One stretched exponential across all collapse currents"; ...
    "Exploratory: q0=a+bI, common stretched shape"; ...
    "20 mA transition regime separate; 30/50 mA share strong-collapse law"];

candidates=table(Architecture,ParameterCount,MeanCurrentRMSE, ...
    WorstCurrentRMSE,RelativeToLocal,Eligibility,Description);

% Automatic recommendation excludes the current-threshold model because
% only three collapse current levels exist. It remains a valuable diagnostic
% for Stage 7 / further data collection.
selRows=find(Eligibility & Architecture~="LOCAL_REFERENCE");
best=min(MeanCurrentRMSE(selRows));
elig=selRows(MeanCurrentRMSE(selRows)<=best*(1+cfg.SIMPLICITY_RELATIVE_RMSE_TOL));

if isempty(elig)
    [~,ii]=min(MeanCurrentRMSE(selRows));
    sel=selRows(ii);
else
    [~,jj]=min(ParameterCount(elig));
    sel=elig(jj);
end

if MeanCurrentRMSE(sel)>localMean*cfg.MAX_UNIFIED_TO_LOCAL_RMSE_RATIO
    recommended="KEEP_CURRENT_SPECIFIC";
else
    recommended=Architecture(sel);
end

R=struct();
R.data=D;
R.candidates=candidates;
R.commonShifted=commonShift;
R.commonStretched=commonStretch;
R.currentThresholdStretched=thresholdStretch;
R.strongCollapseCommon=strongFit;
R.twoRegimePerCurrentRMSE=twoRegimePer;
R.recommended=recommended;
R.note=[ ...
    "CURRENT_THRESHOLD_STRETCHED_EXP is exploratory because only 20, 30, " + ...
    "and 50 mA provide identifiable collapse. Do not over-interpret a " + ...
    "four-parameter current law from three current levels."];
end

function F=fitCollapseCommon(D,idx,mode,cfg)

switch string(mode)
    case "COMMON_SHIFTED"
        p0=[3.0 log(1.0)];
    case "COMMON_STRETCHED"
        p0=[2.0 log(2.5) log(4.0)];
    case "Q0_LINEAR_STRETCHED"
        p0=[4.0 -0.05 log(2.5) log(4.0)];
end

obj=@(p) collapseObjective(p,D,idx,mode);
[p,~]=fminsearch(obj,p0,cfg.optimOptions);
M=unpackCollapse(p,mode);

per=NaN(numel(idx),1);
for j=1:numel(idx)
    q=idx(j);
    per(j)=collapseCurrentRMSE(D(q),M,D(q).current);
end

F=struct();
F.model=M;
F.parameterCount=numel(p);
F.perCurrentRMSE=per;
F.currents=[D(idx).current].';
F.meanCurrentRMSE=mean(per,'omitnan');
F.worstCurrentRMSE=max(per,[],'omitnan');
end

function value=collapseObjective(p,D,idx,mode)
M=unpackCollapse(p,mode);
e=NaN(numel(idx),1);
for j=1:numel(idx)
    q=idx(j);
    e(j)=collapseCurrentRMSE(D(q),M,D(q).current);
end
value=mean(e.^2,'omitnan');
if ~isfinite(value), value=1e6; end
end

function M=unpackCollapse(p,mode)
M=struct();
M.mode=string(mode);
switch string(mode)
    case "COMMON_SHIFTED"
        M.q0=p(1);
        M.k=exp(p(2));
        M.modelName="SHIFTED_EXP";
    case "COMMON_STRETCHED"
        M.q0=p(1);
        M.scale=exp(p(2));
        M.power=exp(p(3));
        M.modelName="STRETCHED_EXP";
    case "Q0_LINEAR_STRETCHED"
        M.q0Intercept=p(1);
        M.q0Slope=p(2);
        M.scale=exp(p(3));
        M.power=exp(p(4));
        M.modelName="Q0_LINEAR_STRETCHED_EXP";
end
end

function value=collapseCurrentRMSE(Dk,M,current)
if nargin<3, current=Dk.current; end
yhat=collapseUnifiedCurve(M,Dk.x,current);
value=rmse(Dk.y,yhat);
end

function y=collapseUnifiedCurve(M,x,current)
x=x(:);
switch string(M.modelName)
    case "SHIFTED_EXP"
        z=max(x-M.q0,0);
        y=exp(-M.k*z);
    case "STRETCHED_EXP"
        z=max(x-M.q0,0);
        y=exp(-(z/M.scale).^M.power);
    case "Q0_LINEAR_STRETCHED_EXP"
        q0=M.q0Intercept+M.q0Slope*current;
        z=max(x-q0,0);
        y=exp(-(z/M.scale).^M.power);
    otherwise
        y=NaN(size(x));
end
end

function n=localCollapseParamCount(M)
switch string(M.modelName)
    case "SHIFTED_EXP", n=2;
    case "STRETCHED_EXP", n=3;
    otherwise, n=NaN;
end
end

%% ========================================================================
% RECOMMENDATION TABLE
% ========================================================================

function T=buildRecommendationTable(R)
Subsystem=["STATIC_SCALE";"FAST_DYNAMICS";"DELAY";"ORDINARY_DROOP";"COMPLIANCE_COLLAPSE"];
Recommendation=[ ...
    string(R.static.recommended); ...
    string(R.fast.recommended); ...
    "TRANSITION_CLASS_SPECIFIC"; ...
    string(R.droop.recommended); ...
    string(R.collapse.recommended)];
Comment=[ ...
    "Empirical calibration only; possible hardware/load systematic effects remain."; ...
    "30/50 mA near-zero starts remain physically separate from firmware class."; ...
    "Use the per-class Stage 6 delay table; literal startup and -I->0 boundary stay separate."; ...
    "Common vs current-dependent vs two-group slope tested on pre-collapse data."; ...
    "20 mA transition collapse and 30/50 strong collapse are explicitly compared."];
T=table(Subsystem,Recommendation,Comment);
end

%% ========================================================================
% SHARED HELPERS
% ========================================================================

function T=resolveDelaySummary(fastResult)
if isfield(fastResult,"delaySummary") && istable(fastResult.delaySummary)
    T=fastResult.delaySummary;
elseif isfield(fastResult,"DelaySummary") && istable(fastResult.DelaySummary)
    T=fastResult.DelaySummary;
else
    error("fastResult does not contain Stage 5 delay summary table.");
end
end

function y=fastCurve(M,t)
modelName = resolveFastModelName(M);

x=t(:)-M.theta_us;
y=zeros(size(x));
a=x>=0;
xa=x(a);

switch modelName
    case "FOP"
        y(a)=1-exp(-xa/M.tau_us);

    case "TWO_POLE"
        t1=M.tau1_us;
        t2=M.tau2_us;
        if abs(t1-t2)<1e-5*max(t1,t2)
            tau=.5*(t1+t2);
            y(a)=1-exp(-xa/tau).*(1+xa/tau);
        else
            y(a)=1-(t2*exp(-xa/t2)-t1*exp(-xa/t1))/(t2-t1);
        end

    case "SECOND_ORDER"
        wn=M.wn_rad_per_us;
        z=M.zeta;
        if z<1-1e-5
            wd=wn*sqrt(1-z^2);
            y(a)=1-exp(-z*wn*xa).* ...
                (cos(wd*xa)+z/sqrt(1-z^2)*sin(wd*xa));
        elseif z>1+1e-5
            q=sqrt(z^2-1);
            r1=-wn*(z-q);
            r2=-wn*(z+q);
            y(a)=1+(r2*exp(r1*xa)-r1*exp(r2*xa))/(r1-r2);
        else
            y(a)=1-exp(-wn*xa).*(1+wn*xa);
        end

    otherwise
        y(:)=NaN;
end
end

function modelName = resolveFastModelName(M)
% Resolve the fast-model family robustly. Stage 5 models normally carry
% modelName explicitly, while Stage 6 trial models are generated locally.
if isfield(M,'modelName') && strlength(string(M.modelName))>0
    modelName = string(M.modelName);
elseif isfield(M,'wn_rad_per_us') && isfield(M,'zeta')
    modelName = "SECOND_ORDER";
elseif isfield(M,'tau1_us') && isfield(M,'tau2_us')
    modelName = "TWO_POLE";
elseif isfield(M,'tau_us')
    modelName = "FOP";
else
    error('OpenXstimPlant6:UnknownFastModel', ...
        'Unable to determine fast-model family from the supplied structure.');
end
end

function y=collapseCurve(C,x)
z=max(x(:)-C.q0,0);
switch string(C.modelName)
    case "SHIFTED_EXP"
        y=exp(-C.k*z);
    case "STRETCHED_EXP"
        y=exp(-(z/C.scale).^C.power);
    otherwise
        y=NaN(size(z));
end
end

function value=rmse(y,yhat)
good=isfinite(y)&isfinite(yhat);
if ~any(good)
    value=NaN;
else
    value=sqrt(mean((y(good)-yhat(good)).^2));
end
end
