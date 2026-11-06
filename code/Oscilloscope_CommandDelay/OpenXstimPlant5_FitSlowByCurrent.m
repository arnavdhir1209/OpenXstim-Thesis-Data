function O = OpenXstimPlant5_FitSlowByCurrent(passive,capState,cfg)
% OpenXstimPlant5_FitSlowByCurrent
%
% Per-current identification of:
%   1. ordinary passive droop before compliance collapse
%   2. compliance-collapse attenuation after ordinary droop is divided out
%
% The statistical unit for fitting and validation is the PHASE / CAPTURE,
% not the individual 5 us model-grid sample.
%
% Continuous oriented state on the Stage 4 grid is reconstructed as:
%
%   q_oriented(t) = OrientedStateStart_uC + q_phase_local(t)
%
% because Stage 4 q_phase_local is delivered charge magnitude from the
% guarded phase start, and multiplying signed packet charge by polarity
% makes the within-phase increment positive for both polarities.

P = passive.phaseMetrics;
Y = passive.normalizedModel;
qLocal = passive.chargeModel_uC;
t_us = passive.modelTime_us(:);

Q = capState.phaseStateMetrics;

if width(Y)~=height(P) || width(qLocal)~=height(P)
    error("Stage 4 matrices are not aligned with Stage 4 phase metadata.");
end

Q = alignPhaseStateTable(P,Q);

requiredP = [ ...
    "CaptureID","CommandCurrent_mA","CaptureWithinAttempt", ...
    "PhaseNumber","PulseNumber","Polarity","ValidPhase"];

requiredQ = [ ...
    "CaptureID","PhaseNumber","IncludedInChargeAnalysis", ...
    "OrientedStateStart_uC","KneeTime_us","KneeCurrentNormalized"];

if ~all(ismember(requiredP,string(P.Properties.VariableNames)))
    error("Stage 4 PhaseMetrics lacks fields required by revised Stage 5.");
end

if ~all(ismember(requiredQ,string(Q.Properties.VariableNames)))
    error("Stage 4A phaseStateMetrics lacks fields required by revised Stage 5.");
end

% Full Stage 4-grid continuous oriented state proxy.
qOriented = ...
    qLocal + reshape(Q.OrientedStateStart_uC,1,[]);

currents = cfg.COMMAND_CURRENTS_mApp(:);

byCurrent = repmat(blankCurrentSlow(),numel(currents),1);

droopSummaryParts = cell(0,1);
droopCandidateParts = cell(0,1);
droopCVParts = cell(0,1);
droopPolarityParts = cell(0,1);

collapseSummaryParts = cell(0,1);
collapseCandidateParts = cell(0,1);
collapseCVParts = cell(0,1);

phaseAuditParts = cell(numel(currents),1);

for k = 1:numel(currents)

    I = currents(k);

    eligible = ...
        P.ValidPhase & ...
        Q.IncludedInChargeAnalysis & ...
        P.CommandCurrent_mA==I & ...
        ~ismember(P.CaptureID,cfg.EXCLUDE_CAPTURE_IDS);

    % ================================================================
    % A. ORDINARY DROOP
    % ================================================================

    [droopMasks,usedDroop] = ...
        buildDroopMasks( ...
        t_us,Y,P,Q,eligible,cfg);

    DR = fitDroopCurrent( ...
        I,t_us,Y,P,droopMasks,usedDroop,cfg);

    byCurrent(k).commandCurrent_mA = I;
    byCurrent(k).droop = DR;

    droopSummaryParts{end+1,1} = ...
        droopSummaryRow(I,DR); %#ok<AGROW>

    if ~isempty(DR.candidateSummary)
        droopCandidateParts{end+1,1} = DR.candidateSummary; %#ok<AGROW>
    end

    if ~isempty(DR.crossValidation)
        droopCVParts{end+1,1} = DR.crossValidation; %#ok<AGROW>
    end

    if DR.identifiable

        pol = fitDroopPolarity( ...
            I,DR.best.modelName,t_us,Y,P,droopMasks,usedDroop,cfg);

        DR.polaritySummary = pol;
        byCurrent(k).droop = DR;

        if ~isempty(pol)
            droopPolarityParts{end+1,1} = pol; %#ok<AGROW>
        end
    end

    % ================================================================
    % B. COMPLIANCE COLLAPSE
    % ================================================================

    if DR.identifiable

        [collapseMasks,collapseObserved,usedCollapse] = ...
            buildCollapseMasks( ...
            t_us,Y,qLocal,qOriented,P,Q,eligible,DR.best,cfg);

        CR = fitCollapseCurrent( ...
            I, ...
            qLocal, ...
            qOriented, ...
            collapseObserved, ...
            P, ...
            collapseMasks, ...
            usedCollapse, ...
            cfg);

    else

        collapseMasks = cell(height(P),1);
        usedCollapse = false(height(P),1);

        CR = blankCollapse();
        CR.reason = "DROOP_MODEL_NOT_IDENTIFIABLE";
    end

    byCurrent(k).collapse = CR;

    collapseSummaryParts{end+1,1} = ...
        collapseSummaryRow(I,CR); %#ok<AGROW>

    if ~isempty(CR.candidateSummary)
        collapseCandidateParts{end+1,1} = CR.candidateSummary; %#ok<AGROW>
    end

    if ~isempty(CR.crossValidation)
        collapseCVParts{end+1,1} = CR.crossValidation; %#ok<AGROW>
    end

    % ================================================================
    % PHASE AUDIT
    % ================================================================

    rows = find(P.CommandCurrent_mA==I);

    if isempty(rows)
        continue;
    end

    reason = strings(numel(rows),1);

    for j = 1:numel(rows)

        p = rows(j);

        if ~eligible(p)
            reason(j) = "NOT_ELIGIBLE";
        elseif usedCollapse(p)
            reason(j) = "USED_DROOP_AND_COLLAPSE";
        elseif usedDroop(p)
            reason(j) = "USED_DROOP_ONLY";
        else
            reason(j) = "NO_USABLE_MODEL_WINDOW";
        end
    end

    phaseAuditParts{k} = table( ...
        P.CaptureID(rows), ...
        P.CommandCurrent_mA(rows), ...
        P.CaptureWithinAttempt(rows), ...
        P.PhaseNumber(rows), ...
        P.PulseNumber(rows), ...
        string(P.Polarity(rows)), ...
        eligible(rows), ...
        usedDroop(rows), ...
        usedCollapse(rows), ...
        Q.KneeTime_us(rows), ...
        Q.KneeCurrentNormalized(rows), ...
        reason, ...
        'VariableNames',{ ...
        'CaptureID','CommandCurrent_mA','CaptureWithinAttempt', ...
        'PhaseNumber','PulseNumber','Polarity', ...
        'Eligible','UsedForDroop','UsedForCollapse', ...
        'KneeTime_us','KneeCurrentNormalized','Stage5SlowReason'});
end

O = struct();

O.byCurrent = byCurrent;

O.droopSummary = ...
    vertcatNonempty(droopSummaryParts);

O.droopCandidates = ...
    vertcatNonempty(droopCandidateParts);

O.droopCrossValidation = ...
    vertcatNonempty(droopCVParts);

O.droopPolaritySummary = ...
    vertcatNonempty(droopPolarityParts);

O.collapseSummary = ...
    vertcatNonempty(collapseSummaryParts);

O.collapseCandidates = ...
    vertcatNonempty(collapseCandidateParts);

O.collapseCrossValidation = ...
    vertcatNonempty(collapseCVParts);

O.phaseAudit = ...
    vertcatNonempty(phaseAuditParts);

O.note = [ ...
    "Ordinary droop is fitted independently at each current and only before the detected compliance knee."; ...
    "Collapse attenuation is fitted to D_measured / D_droop rather than raw D."; ...
    "Continuous oriented state on the model grid equals OrientedStateStart + phase-local delivered charge."; ...
    "Cross-current unification is deferred to Stage 6." ...
    ];

end

%% ========================================================================
% DROOP MASKS
% ========================================================================

function [masks,used] = buildDroopMasks(t_us,Y,P,Q,eligible,cfg)

n = height(P);

masks = cell(n,1);
used = false(n,1);

for p = 1:n

    if ~eligible(p)
        continue;
    end

    m = ...
        isfinite(t_us) & ...
        isfinite(Y(:,p)) & ...
        Y(:,p)>=cfg.DROOP_MIN_NORMALIZED_CURRENT;

    if isfinite(Q.KneeTime_us(p))

        endT = ...
            Q.KneeTime_us(p) - cfg.DROOP_KNEE_GUARD_US;

        m = m & t_us<=endT;
    end

    if nnz(m)>=cfg.DROOP_MIN_SAMPLES_PER_PHASE

        masks{p} = m;
        used(p) = true;
    end
end

end

%% ========================================================================
% DROOP FIT
% ========================================================================

function R = fitDroopCurrent(I,t_us,Y,P,masks,used,cfg)

R = blankDroop();
R.NPhases = nnz(used);
R.NCaptures = numel(unique(P.CaptureID(used)));
R.usedPhaseMask = used;
R.sampleMasks = masks;

if R.NPhases<8 || R.NCaptures<3
    R.reason = "INSUFFICIENT_PRECOLLAPSE_PHASES";
    return;
end

models = cfg.DROOP_MODEL_NAMES(:);

candidateParts = cell(numel(models),1);
cvParts = cell(0,1);
fittedModels = cell(numel(models),1);

folds = unique(P.CaptureWithinAttempt(used & isfinite(P.CaptureWithinAttempt))).';

for m = 1:numel(models)

    name = models(m);

    foldRMSE = NaN(numel(folds),1);

    for f = 1:numel(folds)

        fold = folds(f);

        train = ...
            used & ...
            P.CaptureWithinAttempt~=fold;

        val = ...
            used & ...
            P.CaptureWithinAttempt==fold;

        if nnz(train)<5 || nnz(val)<1
            continue;
        end

        M = fitDroopCandidate( ...
            name,t_us,Y,masks,find(train),cfg);

        foldRMSE(f) = ...
            scoreDroop( ...
            M,t_us,Y,masks,find(val));

        cvParts{end+1,1} = table( ...
            I,name,fold,nnz(train),nnz(val),foldRMSE(f), ...
            'VariableNames',{ ...
            'CommandCurrent_mA','Model','Fold','NTrainPhases', ...
            'NValidationPhases','PhaseRMSE'}); %#ok<AGROW>
    end

    M = fitDroopCandidate( ...
        name,t_us,Y,masks,find(used),cfg);

    fitRMSE = ...
        scoreDroop( ...
        M,t_us,Y,masks,find(used));

    fittedModels{m} = M;

    candidateParts{m} = table( ...
        I,name,M.parameterCount,R.NPhases,R.NCaptures, ...
        mean(foldRMSE,'omitnan'), ...
        std(foldRMSE,'omitnan'), ...
        fitRMSE, ...
        string(M.parameterText), ...
        false, ...
        'VariableNames',{ ...
        'CommandCurrent_mA','Model','ParameterCount','NPhases','NCaptures', ...
        'CrossValidationRMSE','CrossValidationSD','FitPhaseRMSE', ...
        'Parameters','Selected'});
end

cand = vertcat(candidateParts{:});

errs = cand.CrossValidationRMSE;
finiteErr = isfinite(errs);

if ~any(finiteErr)
    R.reason = "DROOP_CROSS_VALIDATION_FAILED";
    R.candidateSummary = cand;
    R.crossValidation = vertcatNonempty(cvParts);
    return;
end

bestErr = min(errs(finiteErr));

tol = max( ...
    cfg.DROOP_SELECTION_ABS_TOL, ...
    cfg.DROOP_SELECTION_REL_TOL*bestErr);

short = find(finiteErr & errs<=bestErr+tol);

% Explicit simplicity/interpretability preference:
% LINEAR first when statistically indistinguishable.
linearRows = short(cand.Model(short)=="LINEAR");

if ~isempty(linearRows)
    selectedRow = linearRows(1);
else
    [~,ii] = min(errs(short));
    selectedRow = short(ii);
end

cand.Selected(selectedRow) = true;

R.identifiable = true;
R.reason = "PASS";
R.candidateSummary = cand;
R.crossValidation = vertcatNonempty(cvParts);
R.best = fittedModels{selectedRow};
R.selectionTolerance = tol;
R.time_us = t_us;
R.meanUsedWaveform = mean(Y(:,used),2,'omitnan');

end

function M = fitDroopCandidate(name,t_us,Y,masks,idx,cfg)

name = string(name);

starts = log([0.05 0.10 0.15 0.25 0.40]);

bestP = NaN;
bestObj = Inf;

for s = 1:numel(starts)

    [p,v] = fminsearch( ...
        @(p)droopObjective(name,p,t_us,Y,masks,idx), ...
        starts(s), ...
        cfg.optimOptions);

    if v<bestObj
        bestObj = v;
        bestP = p;
    end
end

M = struct();
M.modelName = name;
M.rate_per_ms = exp(bestP);
M.parameterCount = 1;

switch name

    case "LINEAR"

        M.parameterText = ...
            sprintf("D(t)=1-k*t; k=%.8g /ms",M.rate_per_ms);

    case "EXP"

        M.parameterText = ...
            sprintf("D(t)=exp(-k*t); k=%.8g /ms",M.rate_per_ms);

    otherwise

        error("Unknown droop model %s",name);
end

M.PredictedD_at_1ms = ...
    predictDroop(M,1.0);

end

function v = droopObjective(name,p,t_us,Y,masks,idx)

M = struct();
M.modelName = string(name);
M.rate_per_ms = exp(p);

phaseMSE = NaN(numel(idx),1);

for j = 1:numel(idx)

    q = idx(j);
    m = masks{q};

    if isempty(m)
        continue;
    end

    pred = ...
        predictDroop(M,t_us(m)/1000);

    if any(~isfinite(pred)) || any(pred<0) || any(pred>1.05)
        v = 1e6;
        return;
    end

    phaseMSE(j) = ...
        mean((Y(m,q)-pred).^2,'omitnan');
end

v = mean(phaseMSE,'omitnan');

if ~isfinite(v)
    v = 1e6;
end

end

function r = scoreDroop(M,t_us,Y,masks,idx)

phaseMSE = NaN(numel(idx),1);

for j = 1:numel(idx)

    q = idx(j);
    m = masks{q};

    if isempty(m)
        continue;
    end

    pred = ...
        predictDroop(M,t_us(m)/1000);

    phaseMSE(j) = ...
        mean((Y(m,q)-pred).^2,'omitnan');
end

r = sqrt(mean(phaseMSE,'omitnan'));

end

function y = predictDroop(M,t_ms)

t_ms = t_ms(:);

switch string(M.modelName)

    case "LINEAR"

        y = 1-M.rate_per_ms*t_ms;

    case "EXP"

        y = exp(-M.rate_per_ms*t_ms);

    otherwise

        error("Unknown droop model.");
end

end

function T = fitDroopPolarity(I,family,t_us,Y,P,masks,used,cfg)

pols = ["positive","negative"];

parts = cell(0,1);

for p = 1:numel(pols)

    m = ...
        used & ...
        string(P.Polarity)==pols(p);

    if nnz(m)<4
        continue;
    end

    M = fitDroopCandidate( ...
        family,t_us,Y,masks,find(m),cfg);

    rmse = scoreDroop( ...
        M,t_us,Y,masks,find(m));

    parts{end+1,1} = table( ...
        I,pols(p),nnz(m),string(M.modelName),M.rate_per_ms, ...
        M.PredictedD_at_1ms,rmse,string(M.parameterText), ...
        'VariableNames',{ ...
        'CommandCurrent_mA','Polarity','NPhases','Model', ...
        'Rate_per_ms','PredictedD_at_1ms','FitPhaseRMSE','Parameters'}); %#ok<AGROW>
end

T = vertcatNonempty(parts);

end

%% ========================================================================
% COLLAPSE MASKS
% ========================================================================

function [masks,Cobs,used] = buildCollapseMasks( ...
    t_us,Y,qLocal,qOriented,P,Q,eligible,droopModel,cfg)

n = height(P);

masks = cell(n,1);
Cobs = NaN(size(Y));
used = false(n,1);

droopPredFull = ...
    predictDroop(droopModel,t_us/1000);

for p = 1:n

    if ~eligible(p)
        continue;
    end

    % Stage 4A defines a compliance knee only for phases that genuinely
    % cross into the collapse regime (D <= 0.75). This prevents ordinary
    % low-current droop from being mislabelled as compliance collapse.
    if ~isfinite(Q.KneeTime_us(p))
        continue;
    end

    D = Y(:,p);

    predD = droopPredFull;

    C = D./predD;

    m = ...
        isfinite(D) & ...
        isfinite(C) & ...
        isfinite(qLocal(:,p)) & ...
        isfinite(qOriented(:,p)) & ...
        D<=cfg.COLLAPSE_START_D & ...
        C>=cfg.COLLAPSE_MIN_ATTENUATION & ...
        C<=cfg.COLLAPSE_MAX_ATTENUATION;

    if nnz(m)>=cfg.COLLAPSE_MIN_SAMPLES_PER_PHASE

        masks{p} = m;
        Cobs(m,p) = C(m);
        used(p) = true;
    end
end

end

%% ========================================================================
% COLLAPSE FIT
% ========================================================================

function R = fitCollapseCurrent(I,qLocal,qOriented,Cobs,P,masks,used,cfg)

R = blankCollapse();
R.NPhases = nnz(used);
R.NCaptures = numel(unique(P.CaptureID(used)));
R.usedPhaseMask = used;
R.sampleMasks = masks;

if R.NPhases<cfg.COLLAPSE_MIN_PHASES || ...
        R.NCaptures<cfg.COLLAPSE_MIN_CAPTURES

    R.reason = "INSUFFICIENT_COLLAPSE_PHASES";
    return;
end

coords = cfg.COLLAPSE_COORDINATES(:);
models = cfg.COLLAPSE_MODEL_NAMES(:);

candidateParts = cell(numel(coords)*numel(models),1);
cvParts = cell(0,1);
fittedModels = cell(numel(coords)*numel(models),1);

folds = unique(P.CaptureWithinAttempt(used & isfinite(P.CaptureWithinAttempt))).';

q = 0;

for c = 1:numel(coords)

    coord = coords(c);

    X = coordinateMatrix(coord,qLocal,qOriented);

    for m = 1:numel(models)

        name = models(m);

        q = q+1;

        foldRMSE = NaN(numel(folds),1);

        for f = 1:numel(folds)

            fold = folds(f);

            train = ...
                used & ...
                P.CaptureWithinAttempt~=fold;

            val = ...
                used & ...
                P.CaptureWithinAttempt==fold;

            if nnz(train)<5 || nnz(val)<1
                continue;
            end

            C = fitCollapseCandidate( ...
                coord,name,X,Cobs,masks,find(train),cfg);

            foldRMSE(f) = ...
                scoreCollapse( ...
                C,X,Cobs,masks,find(val));

            cvParts{end+1,1} = table( ...
                I,coord,name,fold,nnz(train),nnz(val),foldRMSE(f), ...
                'VariableNames',{ ...
                'CommandCurrent_mA','Coordinate','Model','Fold', ...
                'NTrainPhases','NValidationPhases','PhaseRMSE'}); %#ok<AGROW>
        end

        C = fitCollapseCandidate( ...
            coord,name,X,Cobs,masks,find(used),cfg);

        fitRMSE = ...
            scoreCollapse( ...
            C,X,Cobs,masks,find(used));

        fittedModels{q} = C;

        candidateParts{q} = table( ...
            I,coord,name,C.parameterCount,R.NPhases,R.NCaptures, ...
            mean(foldRMSE,'omitnan'), ...
            std(foldRMSE,'omitnan'), ...
            fitRMSE, ...
            string(C.parameterText), ...
            false, ...
            'VariableNames',{ ...
            'CommandCurrent_mA','Coordinate','Model','ParameterCount', ...
            'NPhases','NCaptures','CrossValidationRMSE','CrossValidationSD', ...
            'FitPhaseRMSE','Parameters','Selected'});
    end
end

cand = vertcat(candidateParts{:});

errs = cand.CrossValidationRMSE;
finiteErr = isfinite(errs);

if ~any(finiteErr)
    R.reason = "COLLAPSE_CROSS_VALIDATION_FAILED";
    R.candidateSummary = cand;
    R.crossValidation = vertcatNonempty(cvParts);
    return;
end

bestErr = min(errs(finiteErr));

tol = max( ...
    cfg.COLLAPSE_SELECTION_ABS_TOL, ...
    cfg.COLLAPSE_SELECTION_REL_TOL*bestErr);

short = find(finiteErr & errs<=bestErr+tol);

complexity = cand.ParameterCount(short);

[~,ord] = sortrows( ...
    [complexity errs(short)], ...
    [1 2]);

selectedRow = short(ord(1));

cand.Selected(selectedRow) = true;

best = fittedModels{selectedRow};

Xbest = coordinateMatrix( ...
    best.coordinate,qLocal,qOriented);

[xDiag,yDiag] = ...
    collapseDiagnosticVectors( ...
    Xbest,Cobs,masks,find(used));

if numel(xDiag)>cfg.MAX_COLLAPSE_SCATTER_POINTS

    keep = round(linspace(1,numel(xDiag),cfg.MAX_COLLAPSE_SCATTER_POINTS));

    xDiag = xDiag(keep);
    yDiag = yDiag(keep);
end

R.identifiable = true;
R.reason = "PASS";
R.candidateSummary = cand;
R.crossValidation = vertcatNonempty(cvParts);
R.best = best;
R.selectionTolerance = tol;
R.diagnosticX = xDiag;
R.diagnosticObserved = yDiag;
R.diagnosticPredicted = predictCollapse(best,xDiag);

end

function C = fitCollapseCandidate(coord,name,X,Y,masks,idx,cfg)

[xAll,~] = ...
    collapseDiagnosticVectors(X,Y,masks,idx);

xAll = xAll(isfinite(xAll));

if numel(xAll)<20
    error("Too few collapse coordinate samples.");
end

xmin = min(xAll);
xmax = max(xAll);
span = xmax-xmin;

if span<=eps
    error("Collapse coordinate has no useful spread.");
end

qstarts = [ ...
    xmin-0.10*span; ...
    simpleQuantile(xAll,0.05); ...
    simpleQuantile(xAll,0.20)];

switch string(name)

    case "SHIFTED_EXP"

        starts = [ ...
            qstarts repmat(log(1/max(span,eps)),numel(qstarts),1)];

    case "STRETCHED_EXP"

        rawP0 = inversePowerTransform(2.0,cfg);

        starts = [ ...
            qstarts ...
            repmat(log(max(span/2,eps)),numel(qstarts),1) ...
            repmat(rawP0,numel(qstarts),1)];

    otherwise

        error("Unknown collapse model.");
end

bestP = [];
bestObj = Inf;

for s = 1:size(starts,1)

    [p,v] = fminsearch( ...
        @(p)collapseObjective(coord,name,p,X,Y,masks,idx,cfg,xmin,xmax), ...
        starts(s,:), ...
        cfg.optimOptions);

    if v<bestObj
        bestObj = v;
        bestP = p;
    end
end

C = decodeCollapse(coord,name,bestP,cfg);

end

function v = collapseObjective( ...
    coord,name,p,X,Y,masks,idx,cfg,xmin,xmax)

C = decodeCollapse(coord,name,p,cfg);

phaseMSE = NaN(numel(idx),1);

for j = 1:numel(idx)

    q = idx(j);
    m = masks{q};

    if isempty(m)
        continue;
    end

    pred = ...
        predictCollapse(C,X(m,q));

    if any(~isfinite(pred)) || any(pred<0) || any(pred>1.001)
        v = 1e6;
        return;
    end

    phaseMSE(j) = ...
        mean((Y(m,q)-pred).^2,'omitnan');
end

v = mean(phaseMSE,'omitnan');

span = max(xmax-xmin,eps);

% q0 may lie before the first retained D<=0.90 sample, but not arbitrarily
% far away. Penalize obviously non-identifiable onset values.
if C.q0 < xmin-span || C.q0 > xmax
    v = v+10;
end

if C.modelName=="STRETCHED_EXP"

    if C.scale < 0.01*span || C.scale > 20*span
        v = v+10;
    end
end

if ~isfinite(v)
    v = 1e6;
end

end

function r = scoreCollapse(C,X,Y,masks,idx)

phaseMSE = NaN(numel(idx),1);

for j = 1:numel(idx)

    q = idx(j);
    m = masks{q};

    if isempty(m)
        continue;
    end

    pred = ...
        predictCollapse(C,X(m,q));

    phaseMSE(j) = ...
        mean((Y(m,q)-pred).^2,'omitnan');
end

r = sqrt(mean(phaseMSE,'omitnan'));

end

function C = decodeCollapse(coord,name,p,cfg)

C = struct();

C.coordinate = string(coord);
C.modelName = string(name);
C.q0 = p(1);
C.k = NaN;
C.scale = NaN;
C.power = NaN;
C.parameterCount = NaN;
C.parameterText = "";

switch string(name)

    case "SHIFTED_EXP"

        C.k = exp(p(2));
        C.parameterCount = 2;

        C.parameterText = ...
            sprintf("C=exp(-k*max(q-q0,0)); q0=%.8g uC, k=%.8g /uC", ...
            C.q0,C.k);

    case "STRETCHED_EXP"

        C.scale = exp(p(2));

        C.power = ...
            powerTransform(p(3),cfg);

        C.parameterCount = 3;

        C.parameterText = ...
            sprintf("C=exp(-(max(q-q0,0)/s)^p); q0=%.8g uC, s=%.8g uC, p=%.8g", ...
            C.q0,C.scale,C.power);
end

end

function y = predictCollapse(C,x)

z = max(x(:)-C.q0,0);

switch string(C.modelName)

    case "SHIFTED_EXP"

        y = exp(-C.k*z);

    case "STRETCHED_EXP"

        y = exp(-(z/C.scale).^C.power);

    otherwise

        error("Unknown collapse model.");
end

end

function X = coordinateMatrix(name,qLocal,qOriented)

switch string(name)

    case "PHASE_LOCAL"

        X = qLocal;

    case "CONTINUOUS_ORIENTED"

        X = qOriented;

    otherwise

        error("Unknown collapse coordinate.");
end

end

function [x,y] = collapseDiagnosticVectors(X,Y,masks,idx)

xParts = cell(numel(idx),1);
yParts = cell(numel(idx),1);

for j = 1:numel(idx)

    q = idx(j);
    m = masks{q};

    if isempty(m)
        continue;
    end

    xParts{j} = X(m,q);
    yParts{j} = Y(m,q);
end

xParts = xParts(~cellfun(@isempty,xParts));
yParts = yParts(~cellfun(@isempty,yParts));

if isempty(xParts)

    x = [];
    y = [];

else

    x = vertcat(xParts{:});
    y = vertcat(yParts{:});
end

end

function p = powerTransform(raw,cfg)

lo = cfg.COLLAPSE_POWER_MIN;
hi = cfg.COLLAPSE_POWER_MAX;

p = ...
    lo + (hi-lo)/(1+exp(-raw));

end

function raw = inversePowerTransform(p,cfg)

lo = cfg.COLLAPSE_POWER_MIN;
hi = cfg.COLLAPSE_POWER_MAX;

p = min(max(p,lo+1e-6),hi-1e-6);

u = (p-lo)/(hi-lo);

raw = log(u/(1-u));

end

%% ========================================================================
% SUMMARY TABLES
% ========================================================================

function T = droopSummaryRow(I,R)

if R.identifiable

    T = table( ...
        I,true,string(R.reason),R.NPhases,R.NCaptures, ...
        string(R.best.modelName),R.best.rate_per_ms, ...
        R.best.PredictedD_at_1ms,string(R.best.parameterText), ...
        'VariableNames',{ ...
        'CommandCurrent_mA','Identifiable','Reason','NPhases','NCaptures', ...
        'SelectedModel','Rate_per_ms','PredictedD_at_1ms','Parameters'});

else

    T = table( ...
        I,false,string(R.reason),R.NPhases,R.NCaptures, ...
        "",NaN,NaN,"", ...
        'VariableNames',{ ...
        'CommandCurrent_mA','Identifiable','Reason','NPhases','NCaptures', ...
        'SelectedModel','Rate_per_ms','PredictedD_at_1ms','Parameters'});
end

end

function T = collapseSummaryRow(I,R)

if R.identifiable

    selected = ...
        R.candidateSummary(R.candidateSummary.Selected,:);

    cv = NaN;

    if ~isempty(selected)
        cv = selected.CrossValidationRMSE(1);
    end

    T = table( ...
        I,true,string(R.reason),R.NPhases,R.NCaptures, ...
        string(R.best.coordinate),string(R.best.modelName), ...
        cv,string(R.best.parameterText), ...
        'VariableNames',{ ...
        'CommandCurrent_mA','Identifiable','Reason','NPhases','NCaptures', ...
        'SelectedCoordinate','SelectedModel','CrossValidationRMSE','Parameters'});

else

    T = table( ...
        I,false,string(R.reason),R.NPhases,R.NCaptures, ...
        "","",NaN,"", ...
        'VariableNames',{ ...
        'CommandCurrent_mA','Identifiable','Reason','NPhases','NCaptures', ...
        'SelectedCoordinate','SelectedModel','CrossValidationRMSE','Parameters'});
end

end

%% ========================================================================
% ALIGNMENT / BLANKS / UTILITIES
% ========================================================================

function Q = alignPhaseStateTable(P,Q)

if height(P)==height(Q) && ...
        isequaln(P.CaptureID,Q.CaptureID) && ...
        isequaln(P.PhaseNumber,Q.PhaseNumber)

    return;
end

keyP = ...
    string(P.CaptureID) + "_" + string(P.PhaseNumber);

keyQ = ...
    string(Q.CaptureID) + "_" + string(Q.PhaseNumber);

[tf,loc] = ismember(keyP,keyQ);

if ~all(tf)
    error("Stage 4 and Stage 4A phase tables cannot be aligned.");
end

Q = Q(loc,:);

end

function R = blankDroop()

R = struct();
R.identifiable = false;
R.reason = "NOT_PROCESSED";
R.NPhases = 0;
R.NCaptures = 0;
R.usedPhaseMask = [];
R.sampleMasks = {};
R.candidateSummary = table();
R.crossValidation = table();
R.best = struct();
R.selectionTolerance = NaN;
R.polaritySummary = table();
R.time_us = [];
R.meanUsedWaveform = [];

end

function R = blankCollapse()

R = struct();
R.identifiable = false;
R.reason = "NOT_PROCESSED";
R.NPhases = 0;
R.NCaptures = 0;
R.usedPhaseMask = [];
R.sampleMasks = {};
R.candidateSummary = table();
R.crossValidation = table();
R.best = struct();
R.selectionTolerance = NaN;
R.diagnosticX = [];
R.diagnosticObserved = [];
R.diagnosticPredicted = [];

end

function S = blankCurrentSlow()

S = struct();
S.commandCurrent_mA = NaN;
S.droop = blankDroop();
S.collapse = blankCollapse();

end

function q = simpleQuantile(x,p)

x = sort(x(isfinite(x)));

if isempty(x)
    q = NaN;
    return;
end

pos = 1+p*(numel(x)-1);
lo = floor(pos);
hi = ceil(pos);

if lo==hi

    q = x(lo);

else

    q = ...
        x(lo) + ...
        (pos-lo)*(x(hi)-x(lo));
end

end

function T = vertcatNonempty(parts)

parts = parts(~cellfun(@isempty,parts));

if isempty(parts)
    T = table();
else
    T = vertcat(parts{:});
end

end
