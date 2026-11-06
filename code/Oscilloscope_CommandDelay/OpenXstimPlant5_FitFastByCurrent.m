function O = OpenXstimPlant5_FitFastByCurrent(fast,audit,cfg)
% OpenXstimPlant5_FitFastByCurrent
%
% Independently identifies fast electrical behaviour at each commanded
% current.
%
% Two primary physical regimes are kept separate:
%
%   FULL_REVERSAL
%     Healthy +I -> -I / -I -> +I reversal.
%
%   NEAR_ZERO_START
%     A nominal bipolar command whose measured pre-state has already
%     collapsed close to zero, but whose opposite-polarity post-state is
%     healthy. This is especially important at 30 and 50 mA.
%
% NEAR_ZERO_START is not a relabelled firmware zero_to_pos command.
%
% Literal packet startup 0 -> +I and final -I -> 0 are sparse boundary
% cases. They are characterized with the selected local fast family, but
% they do not drive family selection.

A = audit.fastEventAudit;

if ~isfield(fast,"allTransitionTypes")
    error("Stage 3 fast struct has no allTransitionTypes dataset.");
end

Y = fast.allTransitionTypes.normalizedDetrended;
t_us = fast.allTransitionTypes.time_us(:);

if width(Y)~=height(A)
    error("Stage 3 all-transition waveform matrix and Stage 3A audit are misaligned.");
end

required = [ ...
    "CaptureID","CommandCurrent_mA","CaptureWithinAttempt", ...
    "TransitionClass","PhysicalRegime","ValidEvent","IsBipolar", ...
    "CommandToGradientPeak_us","WaveformOutlier","MetricOutlier", ...
    "CaptureOutlierQC","RecommendedForFastModel", ...
    "RecommendedForStrictSensitivityCheck"];

if ~all(ismember(required,string(A.Properties.VariableNames)))
    error("Stage 3A FastEventAudit lacks fields required by revised Stage 5.");
end

fitTime = ...
    t_us>=cfg.FAST_FIT_START_US & ...
    t_us<=cfg.FAST_FIT_END_US;

if nnz(fitTime)<20
    error("Fast fitting window contains too few samples.");
end

currents = cfg.COMMAND_CURRENTS_mApp(:);

byCurrent = repmat(blankCurrentFast(),numel(currents),1);

candidateParts = cell(0,1);
cvParts = cell(0,1);
modelSummaryParts = cell(0,1);
directionParts = cell(0,1);
boundaryParts = cell(0,1);
delayParts = cell(0,1);
regimeCountParts = cell(numel(currents),1);

for k = 1:numel(currents)

    I = currents(k);

    notExcluded = ~ismember(A.CaptureID,cfg.EXCLUDE_CAPTURE_IDS);

    currentValid = ...
        A.ValidEvent & ...
        A.CommandCurrent_mA==I & ...
        notExcluded;

    bipolar = currentValid & A.IsBipolar;

    fullMask = ...
        A.RecommendedForFastModel & ...
        A.CommandCurrent_mA==I & ...
        notExcluded;

    fullStrictMask = ...
        A.RecommendedForStrictSensitivityCheck & ...
        A.CommandCurrent_mA==I & ...
        notExcluded;

    nearZeroMask = ...
        bipolar & ...
        string(A.PhysicalRegime)=="NEAR_ZERO_TO_OPPOSITE" & ...
        ~A.WaveformOutlier & ...
        ~A.MetricOutlier;

    nearZeroStrictMask = ...
        nearZeroMask & ...
        ~A.CaptureOutlierQC;

    partialMask = ...
        bipolar & ...
        string(A.PhysicalRegime)=="PARTIAL_REVERSAL";

    otherMask = ...
        bipolar & ...
        ~ismember(string(A.PhysicalRegime), ...
        ["FULL_REVERSAL","NEAR_ZERO_TO_OPPOSITE","PARTIAL_REVERSAL"]);

    startupMask = ...
        currentValid & ...
        string(A.TransitionClass)=="zero_to_pos" & ...
        string(A.PhysicalRegime)=="CLEAN_ZERO_TO_POS";

    shutdownMask = ...
        currentValid & ...
        string(A.TransitionClass)=="neg_to_zero" & ...
        ismember(string(A.PhysicalRegime), ...
        ["CLEAN_NEG_TO_ZERO","PRECOLLAPSED_NEG_TO_ZERO"]);

    regimeCountParts{k} = table( ...
        I, ...
        nnz(fullMask), ...
        nnz(nearZeroMask), ...
        nnz(partialMask), ...
        nnz(otherMask), ...
        nnz(startupMask), ...
        nnz(shutdownMask), ...
        'VariableNames',{ ...
        'CommandCurrent_mA', ...
        'FullReversalN', ...
        'NearZeroStartN', ...
        'PartialReversalN', ...
        'OtherBipolarN', ...
        'CleanStartupN', ...
        'ShutdownBoundaryN'});

    % ---------------------------------------------------------------
    % Full reversal model
    % ---------------------------------------------------------------
    FR = fitSelectableRegime( ...
        I, ...
        "FULL_REVERSAL", ...
        fullMask, ...
        fullStrictMask, ...
        t_us, ...
        Y, ...
        fitTime, ...
        A, ...
        cfg);

    byCurrent(k).commandCurrent_mA = I;
    byCurrent(k).fullReversal = FR;

    if ~isempty(FR.candidateSummary)
        candidateParts{end+1,1} = FR.candidateSummary; %#ok<AGROW>
    end

    if ~isempty(FR.crossValidation)
        cvParts{end+1,1} = FR.crossValidation; %#ok<AGROW>
    end

    modelSummaryParts{end+1,1} = ...
        modelSummaryRow(I,"FULL_REVERSAL",FR); %#ok<AGROW>

    if FR.identifiable
        D = fitDirections( ...
            I,"FULL_REVERSAL",fullMask,FR.best.modelName, ...
            t_us,Y,fitTime,A,cfg);
        if ~isempty(D)
            directionParts{end+1,1} = D; %#ok<AGROW>
        end

        Dt = delayRows( ...
            I,"FULL_REVERSAL",fullMask,FR.best.theta_us,A);

        if ~isempty(Dt)
            delayParts{end+1,1} = Dt; %#ok<AGROW>
        end
    end

    % ---------------------------------------------------------------
    % Near-zero-start model
    % ---------------------------------------------------------------
    NZ = fitSelectableRegime( ...
        I, ...
        "NEAR_ZERO_START", ...
        nearZeroMask, ...
        nearZeroStrictMask, ...
        t_us, ...
        Y, ...
        fitTime, ...
        A, ...
        cfg);

    byCurrent(k).nearZeroStart = NZ;

    if ~isempty(NZ.candidateSummary)
        candidateParts{end+1,1} = NZ.candidateSummary; %#ok<AGROW>
    end

    if ~isempty(NZ.crossValidation)
        cvParts{end+1,1} = NZ.crossValidation; %#ok<AGROW>
    end

    modelSummaryParts{end+1,1} = ...
        modelSummaryRow(I,"NEAR_ZERO_START",NZ); %#ok<AGROW>

    if NZ.identifiable

        D = fitDirections( ...
            I,"NEAR_ZERO_START",nearZeroMask,NZ.best.modelName, ...
            t_us,Y,fitTime,A,cfg);

        if ~isempty(D)
            directionParts{end+1,1} = D; %#ok<AGROW>
        end

        Dt = delayRows( ...
            I,"NEAR_ZERO_START",nearZeroMask,NZ.best.theta_us,A);

        if ~isempty(Dt)
            delayParts{end+1,1} = Dt; %#ok<AGROW>
        end
    end

    % ---------------------------------------------------------------
    % Sparse literal boundaries.
    % Use the local selected family, but do not let N=4/5 select a family.
    % ---------------------------------------------------------------
    referenceFamily = "SECOND_ORDER";

    if FR.identifiable
        referenceFamily = FR.best.modelName;
    elseif NZ.identifiable
        referenceFamily = NZ.best.modelName;
    end

    ST = fitBoundaryRegime( ...
        I, ...
        "LITERAL_ZERO_TO_POS", ...
        startupMask, ...
        referenceFamily, ...
        t_us,Y,fitTime,A,cfg);

    SH = fitBoundaryRegime( ...
        I, ...
        "NEG_TO_ZERO_BOUNDARY", ...
        shutdownMask, ...
        referenceFamily, ...
        t_us,Y,fitTime,A,cfg);

    byCurrent(k).startupZeroToPos = ST;
    byCurrent(k).shutdownNegToZero = SH;

    boundaryParts{end+1,1} = ...
        boundarySummaryRow(I,"LITERAL_ZERO_TO_POS",ST); %#ok<AGROW>

    boundaryParts{end+1,1} = ...
        boundarySummaryRow(I,"NEG_TO_ZERO_BOUNDARY",SH); %#ok<AGROW>

    if ST.fitted

        Dt = delayRows( ...
            I,"LITERAL_ZERO_TO_POS",startupMask,ST.model.theta_us,A);

        if ~isempty(Dt)
            delayParts{end+1,1} = Dt; %#ok<AGROW>
        end
    end

    if SH.fitted

        Dt = delayRows( ...
            I,"NEG_TO_ZERO_BOUNDARY",shutdownMask,SH.model.theta_us,A);

        if ~isempty(Dt)
            delayParts{end+1,1} = Dt; %#ok<AGROW>
        end
    end

    % Keep masks for later diagnostics / Stage 6.
    byCurrent(k).masks = struct();
    byCurrent(k).masks.fullReversal = fullMask;
    byCurrent(k).masks.nearZeroStart = nearZeroMask;
    byCurrent(k).masks.partialReversal = partialMask;
    byCurrent(k).masks.startupZeroToPos = startupMask;
    byCurrent(k).masks.shutdownNegToZero = shutdownMask;
end

O = struct();

O.time_us = t_us;
O.fitMask = fitTime;
O.byCurrent = byCurrent;

O.regimeCounts = vertcatNonempty(regimeCountParts);
O.modelSummary = vertcatNonempty(modelSummaryParts);
O.candidateSummary = vertcatNonempty(candidateParts);
O.crossValidation = vertcatNonempty(cvParts);
O.directionSummary = vertcatNonempty(directionParts);
O.boundarySummary = vertcatNonempty(boundaryParts);
O.delaySummary = vertcatNonempty(delayParts);

O.note = [ ...
    "FULL_REVERSAL and NEAR_ZERO_START are separate Stage 5 fast regimes."; ...
    "At high current, NEAR_ZERO_START uses internal nominal bipolar commands only after Stage 3A verifies the measured pre-state is near zero."; ...
    "Literal zero_to_pos startup is sparse and is characterized separately."; ...
    "Cross-current unification is intentionally deferred to Stage 6." ...
    ];

end

%% ========================================================================
% SELECTABLE REGIME
% ========================================================================

function R = fitSelectableRegime(I,label,mask,strictMask,t_us,Y,fitTime,A,cfg)

R = blankSelectableRegime();
R.label = string(label);
R.N = nnz(mask);
R.NCaptures = numel(unique(A.CaptureID(mask)));
R.mask = mask;
R.strictMask = strictMask;

if R.N>0
    R.meanWaveform = mean(Y(:,mask),2,'omitnan');
end

enough = ...
    R.N>=cfg.MIN_FAST_EVENTS_MODEL && ...
    R.NCaptures>=cfg.MIN_FAST_CAPTURES_MODEL;

if ~enough
    R.reason = "INSUFFICIENT_REPEATED_EVENTS";
    return;
end

families = cfg.FAST_MODEL_NAMES(:);
candidateParts = cell(numel(families),1);
cvParts = cell(0,1);
models = cell(numel(families),1);

folds = unique(A.CaptureWithinAttempt(mask & isfinite(A.CaptureWithinAttempt))).';

for m = 1:numel(families)

    fam = families(m);

    foldRMSE = NaN(numel(folds),1);

    for f = 1:numel(folds)

        fold = folds(f);

        train = mask & A.CaptureWithinAttempt~=fold;
        val = mask & A.CaptureWithinAttempt==fold;

        if nnz(train)<max(8,cfg.MIN_FAST_EVENTS_MODEL/2) || nnz(val)<1
            continue;
        end

        trainMean = mean(Y(:,train),2,'omitnan');

        M = fitFastCandidate( ...
            fam, ...
            t_us(fitTime), ...
            trainMean(fitTime), ...
            cfg.optimOptions);

        pred = fastResponse(M,t_us(fitTime));

        foldRMSE(f) = ...
            eventSetRMSE(Y(fitTime,val),pred);

        cvParts{end+1,1} = table( ...
            I,string(label),fam,fold,nnz(train),nnz(val),foldRMSE(f), ...
            'VariableNames',{ ...
            'CommandCurrent_mA','FastRegime','Model','Fold', ...
            'NTrain','NValidation','EventRMSE'}); %#ok<AGROW>
    end

    meanAll = mean(Y(:,mask),2,'omitnan');

    M = fitFastCandidate( ...
        fam, ...
        t_us(fitTime), ...
        meanAll(fitTime), ...
        cfg.optimOptions);

    M = addCrossingMetrics(M,cfg.FAST_FIT_END_US);

    models{m} = M;

    candidateParts{m} = table( ...
        I, ...
        string(label), ...
        fam, ...
        R.N, ...
        R.NCaptures, ...
        M.parameterCount, ...
        mean(foldRMSE,'omitnan'), ...
        std(foldRMSE,'omitnan'), ...
        M.RMSE, ...
        string(M.parameterText), ...
        false, ...
        'VariableNames',{ ...
        'CommandCurrent_mA','FastRegime','Model','N','NCaptures', ...
        'ParameterCount','CrossValidationRMSE','CrossValidationSD', ...
        'MeanWaveformFitRMSE','Parameters','Selected'});
end

cand = vertcat(candidateParts{:});

errs = cand.CrossValidationRMSE;
finiteErr = isfinite(errs);

if ~any(finiteErr)
    R.reason = "CROSS_VALIDATION_FAILED";
    R.candidateSummary = cand;
    R.crossValidation = vertcatNonempty(cvParts);
    return;
end

bestErr = min(errs(finiteErr));

tol = max( ...
    cfg.FAST_SELECTION_ABS_TOL, ...
    cfg.FAST_SELECTION_REL_TOL*bestErr);

short = find(finiteErr & errs<=bestErr+tol);

complexity = cand.ParameterCount(short);

[~,ord] = sortrows( ...
    [complexity errs(short)], ...
    [1 2]);

selectedRow = short(ord(1));

cand.Selected(selectedRow) = true;

best = models{selectedRow};

pred = fastResponse(best,t_us(fitTime));

eventErr = eventRMSE( ...
    Y(fitTime,mask), ...
    pred);

best.individualEventRMSEMean = ...
    mean(eventErr,'omitnan');

best.individualEventRMSESD = ...
    std(eventErr,'omitnan');

% Strict sensitivity uses the selected family only.
strict = struct();
if nnz(strictMask)>=cfg.MIN_FAST_EVENTS_MODEL

    strictMean = mean(Y(:,strictMask),2,'omitnan');

    strict = fitFastCandidate( ...
        best.modelName, ...
        t_us(fitTime), ...
        strictMean(fitTime), ...
        cfg.optimOptions);

    strict = addCrossingMetrics(strict,cfg.FAST_FIT_END_US);
    strict.N = nnz(strictMask);
end

R.identifiable = true;
R.reason = "PASS";
R.candidateSummary = cand;
R.crossValidation = vertcatNonempty(cvParts);
R.best = best;
R.strictSensitivity = strict;
R.selectionTolerance = tol;

end

%% ========================================================================
% BOUNDARY FIT
% ========================================================================

function B = fitBoundaryRegime(I,label,mask,family,t_us,Y,fitTime,A,cfg)

B = blankBoundaryRegime();
B.label = string(label);
B.family = string(family);
B.N = nnz(mask);
B.NCaptures = numel(unique(A.CaptureID(mask)));
B.mask = mask;

if B.N>0
    B.meanWaveform = mean(Y(:,mask),2,'omitnan');
end

if B.N<cfg.MIN_BOUNDARY_EVENTS_FIT
    B.reason = "TOO_FEW_BOUNDARY_EVENTS";
    return;
end

M = fitFastCandidate( ...
    family, ...
    t_us(fitTime), ...
    B.meanWaveform(fitTime), ...
    cfg.optimOptions);

M = addCrossingMetrics(M,cfg.FAST_FIT_END_US);

folds = unique(A.CaptureWithinAttempt(mask & isfinite(A.CaptureWithinAttempt))).';
foldRMSE = NaN(numel(folds),1);

for f = 1:numel(folds)

    fold = folds(f);

    train = mask & A.CaptureWithinAttempt~=fold;
    val = mask & A.CaptureWithinAttempt==fold;

    if nnz(train)<2 || nnz(val)<1
        continue;
    end

    trainMean = mean(Y(:,train),2,'omitnan');

    Mf = fitFastCandidate( ...
        family, ...
        t_us(fitTime), ...
        trainMean(fitTime), ...
        cfg.optimOptions);

    foldRMSE(f) = eventSetRMSE( ...
        Y(fitTime,val), ...
        fastResponse(Mf,t_us(fitTime)));
end

B.fitted = true;
B.reason = "DESCRIPTIVE_BOUNDARY_FIT";
B.model = M;
B.crossValidationRMSE = mean(foldRMSE,'omitnan');
B.crossValidationSD = std(foldRMSE,'omitnan');

end

%% ========================================================================
% DIRECTION FITS
% ========================================================================

function T = fitDirections(I,regime,mask,family,t_us,Y,fitTime,A,cfg)

classes = unique(string(A.TransitionClass(mask)),'stable');
parts = cell(0,1);

for c = 1:numel(classes)

    cls = classes(c);

    m = mask & string(A.TransitionClass)==cls;

    if nnz(m)<5
        continue;
    end

    meanWave = mean(Y(:,m),2,'omitnan');

    M = fitFastCandidate( ...
        family, ...
        t_us(fitTime), ...
        meanWave(fitTime), ...
        cfg.optimOptions);

    M = addCrossingMetrics(M,cfg.FAST_FIT_END_US);

    pred = fastResponse(M,t_us(fitTime));
    e = eventRMSE(Y(fitTime,m),pred);

    parts{end+1,1} = table( ...
        I, ...
        string(regime), ...
        cls, ...
        nnz(m), ...
        string(M.modelName), ...
        M.theta_us, ...
        M.t10_90_us, ...
        mean(e,'omitnan'), ...
        std(e,'omitnan'), ...
        string(M.parameterText), ...
        'VariableNames',{ ...
        'CommandCurrent_mA','FastRegime','TransitionClass','N','Model', ...
        'Theta_us','T10_90_us','MeanEventRMSE','SDEventRMSE','Parameters'}); %#ok<AGROW>
end

T = vertcatNonempty(parts);

end

%% ========================================================================
% DELAY
% ========================================================================

function T = delayRows(I,regime,mask,theta_us,A)

classes = unique(string(A.TransitionClass(mask)),'stable');
parts = cell(0,1);

for c = 1:numel(classes)

    cls = classes(c);

    m = ...
        mask & ...
        string(A.TransitionClass)==cls & ...
        isfinite(A.CommandToGradientPeak_us);

    if ~any(m)
        continue;
    end

    y = A.CommandToGradientPeak_us(m) + theta_us;

    parts{end+1,1} = table( ...
        I, ...
        string(regime), ...
        cls, ...
        numel(y), ...
        mean(y,'omitnan'), ...
        median(y,'omitnan'), ...
        std(y,'omitnan'), ...
        robustSD(y), ...
        min(y), ...
        max(y), ...
        theta_us, ...
        'VariableNames',{ ...
        'CommandCurrent_mA','FastRegime','TransitionClass','N', ...
        'MeanTransportDelay_us','MedianTransportDelay_us','SDTransportDelay_us', ...
        'RobustSDTransportDelay_us','MinTransportDelay_us','MaxTransportDelay_us', ...
        'FastOnsetOffsetFromGradientPeak_us'}); %#ok<AGROW>
end

T = vertcatNonempty(parts);

end

%% ========================================================================
% SUMMARY ROWS
% ========================================================================

function T = modelSummaryRow(I,label,R)

if R.identifiable

    T = table( ...
        I,string(label),true,string(R.reason),R.N,R.NCaptures, ...
        string(R.best.modelName),R.best.theta_us,R.best.t10_90_us, ...
        R.best.individualEventRMSEMean, ...
        string(R.best.parameterText), ...
        'VariableNames',{ ...
        'CommandCurrent_mA','FastRegime','Identifiable','Reason','N','NCaptures', ...
        'SelectedModel','Theta_us','T10_90_us','MeanEventRMSE','Parameters'});

else

    T = table( ...
        I,string(label),false,string(R.reason),R.N,R.NCaptures, ...
        "",NaN,NaN,NaN,"", ...
        'VariableNames',{ ...
        'CommandCurrent_mA','FastRegime','Identifiable','Reason','N','NCaptures', ...
        'SelectedModel','Theta_us','T10_90_us','MeanEventRMSE','Parameters'});
end

end

function T = boundarySummaryRow(I,label,B)

if B.fitted

    T = table( ...
        I,string(label),true,string(B.reason),B.N,B.NCaptures, ...
        string(B.model.modelName),B.model.theta_us,B.model.t10_90_us, ...
        B.crossValidationRMSE,string(B.model.parameterText), ...
        'VariableNames',{ ...
        'CommandCurrent_mA','BoundaryRegime','Fitted','Reason','N','NCaptures', ...
        'Model','Theta_us','T10_90_us','FixedFamilyCVRMSE','Parameters'});

else

    T = table( ...
        I,string(label),false,string(B.reason),B.N,B.NCaptures, ...
        string(B.family),NaN,NaN,NaN,"", ...
        'VariableNames',{ ...
        'CommandCurrent_mA','BoundaryRegime','Fitted','Reason','N','NCaptures', ...
        'Model','Theta_us','T10_90_us','FixedFamilyCVRMSE','Parameters'});
end

end

%% ========================================================================
% FAST MODEL FUNCTIONS
% ========================================================================

function M = fitFastCandidate(name,t,y,opt)

t = t(:);
y = y(:);

if numel(t)~=numel(y)
    error("Fast-fit time and waveform vectors must have equal length.");
end

good = isfinite(t) & isfinite(y);
t = t(good);
y = y(good);

if numel(t)<15
    error("Fast fit has too few finite samples.");
end

switch string(name)

    case "FOP"

        starts = [ ...
            log(2) -2; ...
            log(3) -2; ...
            log(1) -1.5; ...
            log(4) -3];

    case "TWO_POLE"

        starts = [ ...
            log(1) log(2) -2; ...
            log(.5) log(3) -2; ...
            log(1.5) log(1.5) -2.5; ...
            log(2) log(4) -3];

    case "SECOND_ORDER"

        starts = [ ...
            log(2) log(1) -2; ...
            log(2) log(.8) -2; ...
            log(1.5) log(1.2) -2.5; ...
            log(3) log(.7) -3];

    otherwise

        error("Unknown fast model %s",name);
end

bestP = [];
bestObj = Inf;

for s = 1:size(starts,1)

    [p,v] = fminsearch( ...
        @(p)objFast(name,p,t,y), ...
        starts(s,:), ...
        opt);

    if v<bestObj
        bestObj = v;
        bestP = p;
    end
end

M = decodeFast(name,bestP);

pred = fastResponse(M,t);
r = y-pred;

M.SSE = sum(r.^2);
M.RMSE = sqrt(mean(r.^2));

den = sum((y-mean(y)).^2);

if den>0
    M.R2 = 1-M.SSE/den;
else
    M.R2 = NaN;
end

n = numel(y);
k = M.parameterCount;
safe = max(M.SSE,realmin);

M.AIC = n*log(safe/n)+2*k;
M.BIC = n*log(safe/n)+k*log(n);

end

function v = objFast(name,p,t,y)

M = decodeFast(name,p);

pred = fastResponse(M,t);

v = mean((y-pred).^2,'omitnan');

pen = 0;

if M.theta_us<-15 || M.theta_us>5
    pen = pen + 10*(abs(M.theta_us)+1);
end

switch string(name)

    case "FOP"

        if M.tau_us<.05 || M.tau_us>30
            pen = pen+10;
        end

    case "TWO_POLE"

        if min(M.tau1_us,M.tau2_us)<.05 || ...
                max(M.tau1_us,M.tau2_us)>30

            pen = pen+10;
        end

    case "SECOND_ORDER"

        if M.naturalTime_us<.05 || ...
                M.naturalTime_us>30 || ...
                M.zeta<.05 || ...
                M.zeta>5

            pen = pen+10;
        end
end

v = v+pen;

end

function M = decodeFast(name,p)

M = struct( ...
    'modelName',string(name), ...
    'parameterCount',NaN, ...
    'parameterText',"", ...
    'theta_us',NaN, ...
    'tau_us',NaN, ...
    'tau1_us',NaN, ...
    'tau2_us',NaN, ...
    'naturalTime_us',NaN, ...
    'zeta',NaN, ...
    'wn_rad_per_us',NaN, ...
    'wn_rad_per_s',NaN, ...
    'tfNumerator',NaN, ...
    'tfDenominator',NaN);

switch string(name)

    case "FOP"

        M.tau_us = exp(p(1));
        M.theta_us = p(2);
        M.parameterCount = 2;

        M.parameterText = ...
            sprintf("tau=%.6g us, theta=%.6g us", ...
            M.tau_us,M.theta_us);

        tau = M.tau_us*1e-6;

        M.tfNumerator = 1;
        M.tfDenominator = [tau 1];

    case "TWO_POLE"

        tt = sort([exp(p(1)) exp(p(2))]);

        M.tau1_us = tt(1);
        M.tau2_us = tt(2);
        M.theta_us = p(3);
        M.parameterCount = 3;

        M.parameterText = ...
            sprintf("tau1=%.6g us, tau2=%.6g us, theta=%.6g us", ...
            M.tau1_us,M.tau2_us,M.theta_us);

        t1 = M.tau1_us*1e-6;
        t2 = M.tau2_us*1e-6;

        M.tfNumerator = 1;
        M.tfDenominator = [t1*t2 t1+t2 1];

    case "SECOND_ORDER"

        M.naturalTime_us = exp(p(1));
        M.zeta = exp(p(2));
        M.theta_us = p(3);
        M.parameterCount = 3;

        M.wn_rad_per_us = ...
            1/M.naturalTime_us;

        M.wn_rad_per_s = ...
            M.wn_rad_per_us*1e6;

        M.parameterText = ...
            sprintf("wn=%.6g Mrad/s, zeta=%.6g, theta=%.6g us", ...
            M.wn_rad_per_s/1e6,M.zeta,M.theta_us);

        wn = M.wn_rad_per_s;

        M.tfNumerator = wn^2;
        M.tfDenominator = [1 2*M.zeta*wn wn^2];
end

end

function y = fastResponse(M,t)

x = t(:)-M.theta_us;

y = zeros(size(x));

a = x>=0;
xa = x(a);

switch string(M.modelName)

    case "FOP"

        y(a) = 1-exp(-xa/M.tau_us);

    case "TWO_POLE"

        t1 = M.tau1_us;
        t2 = M.tau2_us;

        if abs(t1-t2)<1e-5*max(t1,t2)

            tau = .5*(t1+t2);

            y(a) = ...
                1-exp(-xa/tau).*(1+xa/tau);

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
end

end

function M = addCrossingMetrics(M,end_us)

t = linspace( ...
    M.theta_us, ...
    max(end_us,M.theta_us+30), ...
    10000).';

y = fastResponse(M,t);

tr = t-M.theta_us;

M.t10FromOnset_us = crossing(tr,y,.1);
M.t50FromOnset_us = crossing(tr,y,.5);
M.t90FromOnset_us = crossing(tr,y,.9);

M.t10_90_us = ...
    M.t90FromOnset_us-M.t10FromOnset_us;

end

function t = crossing(x,y,lvl)

i = find(y>=lvl,1);

if isempty(i)
    t = NaN;
    return;
end

if i==1
    t = x(1);
    return;
end

if y(i)==y(i-1)

    t = x(i);

else

    t = ...
        x(i-1) + ...
        (lvl-y(i-1))* ...
        (x(i)-x(i-1))/ ...
        (y(i)-y(i-1));
end

end

function r = eventRMSE(Y,pred)

r = ...
    sqrt(mean((Y-pred(:)).^2,1,'omitnan')).';

end

function r = eventSetRMSE(Y,pred)

e = eventRMSE(Y,pred);

r = sqrt(mean(e.^2,'omitnan'));

end

%% ========================================================================
% BLANK STRUCTS / UTILITIES
% ========================================================================

function R = blankSelectableRegime()

R = struct();
R.label = "";
R.identifiable = false;
R.reason = "NOT_PROCESSED";
R.N = 0;
R.NCaptures = 0;
R.mask = [];
R.strictMask = [];
R.meanWaveform = [];
R.candidateSummary = table();
R.crossValidation = table();
R.best = struct();
R.strictSensitivity = struct();
R.selectionTolerance = NaN;

end

function B = blankBoundaryRegime()

B = struct();
B.label = "";
B.family = "";
B.fitted = false;
B.reason = "NOT_PROCESSED";
B.N = 0;
B.NCaptures = 0;
B.mask = [];
B.meanWaveform = [];
B.model = struct();
B.crossValidationRMSE = NaN;
B.crossValidationSD = NaN;

end

function S = blankCurrentFast()

S = struct();
S.commandCurrent_mA = NaN;
S.fullReversal = blankSelectableRegime();
S.nearZeroStart = blankSelectableRegime();
S.startupZeroToPos = blankBoundaryRegime();
S.shutdownNegToZero = blankBoundaryRegime();
S.masks = struct();

end

function s = robustSD(x)

x = x(isfinite(x));

if isempty(x)
    s = NaN;
    return;
end

med = median(x);

s = 1.4826*median(abs(x-med));

end

function T = vertcatNonempty(parts)

parts = parts(~cellfun(@isempty,parts));

if isempty(parts)
    T = table();
else
    T = vertcat(parts{:});
end

end
