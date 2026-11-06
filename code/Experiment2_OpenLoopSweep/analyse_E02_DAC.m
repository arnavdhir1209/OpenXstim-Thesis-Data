
%% analyse_E02_DAC.m
% E02: OpenXstim DAC-to-current plant identification
% MATLAB R2025a
%
% Place in E02 DAC Current Relation beside the six CSVs.
% No toolboxes required.
% Original recordings are never modified.

clearvars;
clc;

%% 1. Paths and configuration

scriptDir = fileparts(mfilename('fullpath'));
assert(~isempty(scriptDir),'Save the script before running.');

outDir = fullfile(scriptDir,'E02_DAC_Results');
auditDir = fullfile(outDir,'RowAudits');

if ~isfolder(outDir), mkdir(outDir); end
if ~isfolder(auditDir), mkdir(auditDir); end

cfg.loads = [100 220 560 1000 2000 4000];
cfg.minPlateau = 5;
cfg.minCounters = 3;
cfg.minCounterSpan = 10;
cfg.maxGap_s = 0.5;
cfg.preFaultRows = 5;
cfg.preFault_s = 0.5;
cfg.maxCounter = 322;
cfg.maxRequest_mA = 15;
cfg.target_mA = 10;
cfg.nominalSlope = 0.0458338958;
cfg.nominal4kCurrent215 = 9.593752;
cfg.localWindows = [8 12;7 13;6 14];
cfg.minPlateauSensitivity = [3 5 8];
cfg.firstBurstThreshold_mA = 0.25;
cfg.driftThreshold_mA = 0.30;
cfg.collapseFraction = 0.55;
cfg.weightFloor_mA = 0.030;

required = { ...
    'time_ms','burst','mode','stim_state', ...
    'requested_mA','effective_target_mA', ...
    'command_mA','measured_mA','error_mA', ...
    'counter_applied','counter_next', ...
    'p_term_counts','i_term_counts', ...
    'command_limited','reference_limited', ...
    'fault_code','dt_ms'};

%% 2. Source inventory

F = dir(fullfile(scriptDir,'E02_R*_OL_T*.csv'));

assert(numel(F)==numel(cfg.loads), ...
    'Expected six source files; found %d.',numel(F));

actualNames = string({F.name});

for R = cfg.loads

    expected = string(sprintf( ...
        'E02_R%04d_OL_T01.csv',R));

    assert(nnz(actualNames==expected)==1, ...
        'Missing or duplicate file: %s',expected);

end

%% 3. Output containers

fileAudit = table();
commandSegments = table();

anomalies = table( ...
    'Size',[0 7], ...
    'VariableTypes',{ ...
    'string','double','double','double', ...
    'string','string','string'}, ...
    'VariableNames',{ ...
    'File','Load_Ohm','StartRow','EndRow', ...
    'Kind','Disposition','Detail'});

rawData = struct( ...
    'File',{},'Load_Ohm',{},'Rows',{});

segmentID = 0;

%% 4. Import every recording

for R = cfg.loads

    file = string(sprintf('E02_R%04d_OL_T01.csv',R));
    path = fullfile(scriptDir,char(file));

    A = readtable(path, ...
        'TextType','string', ...
        'VariableNamingRule','preserve');

    missing = setdiff(required,A.Properties.VariableNames);

    assert(isempty(missing), ...
        'Missing columns in %s: %s', ...
        file,strjoin(missing,', '));

    n = height(A);

    % Explicitly force every imported field to a column.
    t = numericColumn(A.time_ms,n,'time_ms')/1000;
    burst = numericColumn(A.burst,n,'burst');

    req = numericColumn(A.requested_mA,n,'requested_mA');
    eff = numericColumn(A.effective_target_mA,n, ...
        'effective_target_mA');

    cmd = numericColumn(A.command_mA,n,'command_mA');
    y = numericColumn(A.measured_mA,n,'measured_mA');
    loggedError = numericColumn(A.error_mA,n,'error_mA');

    u = numericColumn(A.counter_applied,n,'counter_applied');
    un = numericColumn(A.counter_next,n,'counter_next');

    pTerm = numericColumn(A.p_term_counts,n,'p_term_counts');
    iTerm = numericColumn(A.i_term_counts,n,'i_term_counts');

    cmdLim = numericColumn(A.command_limited,n, ...
        'command_limited');

    refLim = numericColumn(A.reference_limited,n, ...
        'reference_limited');

    dt = numericColumn(A.dt_ms,n,'dt_ms');

    mode = textColumn(A.mode,n,'mode');
    state = textColumn(A.stim_state,n,'stim_state');
    fault = textColumn(A.fault_code,n,'fault_code');

    %% 4A. Qualify operating state

    running = state=="RUNNING";
    openLoop = mode=="OPEN_LOOP";

    faultFree = ismember(fault, ...
        ["NONE","NO_FAULT","0"]);

    faultEvent = ~faultFree | state=="FAULT_LATCHED";

    limited = ...
        cmdLim~=0 | refLim~=0 | ...
        req<0 | ...
        req>cfg.maxRequest_mA+1e-6 | ...
        eff<0 | ...
        eff>cfg.maxRequest_mA+1e-6;

    finiteRow = ...
        isfinite(t) & isfinite(burst) & ...
        isfinite(req) & isfinite(eff) & ...
        isfinite(cmd) & isfinite(y) & ...
        isfinite(u) & isfinite(un) & ...
        isfinite(loggedError);

    counterValid = ...
        u==round(u) & ...
        u>=0 & u<=cfg.maxCounter;

    candidate = ...
        running & openLoop & finiteRow & ...
        counterValid & y>0;

    %% 4B. Fault precursor detection

    precursor = false(n,1);

    faultStarts = find( ...
        faultEvent & ...
        ~[false;faultEvent(1:end-1)]);

    for j = 1:numel(faultStarts)

        firstFault = faultStarts(j);

        previous = ...
            max(1,firstFault-cfg.preFaultRows): ...
            firstFault-1;

        if isempty(previous) || ...
                ~isfinite(t(firstFault))
            continue;
        end

        previous = previous(:);

        keep = ...
            running(previous) & ...
            openLoop(previous) & ...
            faultFree(previous) & ...
            isfinite(t(previous)) & ...
            t(firstFault)>=t(previous) & ...
            t(firstFault)-t(previous)<=cfg.preFault_s;

        previous = previous(keep);

        if ~isempty(previous)

            precursor(previous) = true;

            row = table( ...
                file,R,min(previous),max(previous), ...
                "POSSIBLE_FAULT_PRECURSOR", ...
                "EXCLUDED", ...
                "RUNNING rows immediately preceding recorded fault", ...
                'VariableNames',{ ...
                'File','Load_Ohm','StartRow','EndRow', ...
                'Kind','Disposition','Detail'});

            anomalies = [anomalies;row]; %#ok<AGROW>

        end

    end

    normal = ...
        candidate & faultFree & ~limited & ~precursor;

    %% 4C. Segment contiguous constant-Counter periods

    groups = cell(0,1);
    active = [];

    for k = 1:n

        if ~candidate(k)

            if ~isempty(active)
                groups{end+1} = active; %#ok<SAGROW>
                active = [];
            end

            continue;
        end

        if isempty(active)

            active = k;

        else

            previousRow = active(end);

            split = ...
                k~=previousRow+1 || ...
                u(k)~=u(previousRow) || ...
                burst(k)~=burst(previousRow)+1 || ...
                t(k)<=t(previousRow) || ...
                t(k)-t(previousRow)>cfg.maxGap_s || ...
                limited(k)~=limited(previousRow) || ...
                precursor(k)~=precursor(previousRow) || ...
                faultFree(k)~=faultFree(previousRow);

            if split

                groups{end+1} = active; %#ok<SAGROW>
                active = k;

            else

                active(end+1) = k;

            end

        end

    end

    if ~isempty(active)
        groups{end+1} = active;
    end

    acceptedRows = false(n,1);
    segmentIDs = nan(n,1);

    decision = repmat("NOT_RUNNING",n,1);

    decision(running & ~openLoop) = "WRONG_MODE";
    decision(running & openLoop & ~candidate) = ...
        "INVALID_READING_OR_COUNTER";

    decision(candidate) = "PENDING_PLATEAU_REVIEW";
    decision(candidate & limited) = ...
        "FIRMWARE_LIMITED";
    decision(candidate & precursor) = ...
        "FAULT_PRECURSOR";

    %% 4D. Evaluate every plateau

    fileAccepted = 0;

    for g = 1:numel(groups)

        ids = groups{g}(:);
        a = ids(1);
        b = ids(end);

        segmentID = segmentID+1;
        segmentIDs(ids) = segmentID;

        N = numel(ids);
        z = y(ids);

        mu = mean(z);
        med = median(z);

        plateauSD = NaN;

        if N>=2
            plateauSD = std(z);
        end

        duration = t(b)-t(a);
        drift = NaN;

        if N>=3 && duration>0
            pp = polyfit(t(ids)-t(a),z,1);
            drift = pp(1);
        end

        firstMinusLater = NaN;
        postStepFlag = false;

        if N>=5

            later = z(2:end);
            lateMedian = median(later);

            firstMinusLater = z(1)-lateMedian;

            robustMAD = median(abs(later-lateMedian));

            postStepFlag = ...
                abs(firstMinusLater)>max( ...
                cfg.firstBurstThreshold_mA, ...
                6*1.4826*robustMAD);

        end

        collapseFlag = false;

        if N>=3

            low = z<cfg.collapseFraction*med;

            collapseFlag = any( ...
                low(1:end-1) & low(2:end));

        end

        driftFlag = ...
            isfinite(drift) && ...
            abs(drift*duration)>max( ...
            cfg.driftThreshold_mA,0.04*abs(med));

        reason = "ACCEPTED";

        if ~all(faultFree(ids))
            reason = "FAULT_STATE";

        elseif any(limited(ids))
            reason = "FIRMWARE_LIMITED";

        elseif any(precursor(ids))
            reason = "FAULT_PRECURSOR";

        elseif N<cfg.minPlateau
            reason = "SHORT_PLATEAU";

        elseif collapseFlag
            reason = "SUSTAINED_COLLAPSE_REVIEW";

        elseif postStepFlag
            reason = "LARGE_FIRST_BURST_REVIEW";

        elseif driftFlag
            reason = "DRIFT_REVIEW";

        end

        accepted = reason=="ACCEPTED";

        if accepted

            assert(all(normal(ids)), ...
                'Invalid plateau qualified in %s.',file);

            acceptedRows(ids) = true;
            fileAccepted = fileAccepted+1;

        end

        decision(ids) = reason;

        prevCounter = NaN;
        nextCounter = NaN;

        if a>1 && running(a-1) && isfinite(u(a-1))
            prevCounter = u(a-1);
        end

        if b<n && running(b+1) && isfinite(u(b+1))
            nextCounter = u(b+1);
        end

        stepSize = NaN;
        direction = "UNKNOWN";

        if isfinite(prevCounter)

            stepSize = u(a)-prevCounter;

            if stepSize>0
                direction = "UP";
            elseif stepSize<0
                direction = "DOWN";
            else
                direction = "SAME";
            end

        end

        row = table( ...
            file,R,1,segmentID,u(a), ...
            a,b,t(a),t(b),burst(a),burst(b), ...
            N,duration,prevCounter,nextCounter, ...
            stepSize,direction,mu,med,plateauSD, ...
            drift,firstMinusLater,accepted,reason, ...
            any(limited(ids)),any(precursor(ids)), ...
            collapseFlag,postStepFlag,driftFlag, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Trial','SegmentID', ...
            'Counter','StartRow','EndRow', ...
            'StartTime_s','EndTime_s', ...
            'StartBurst','EndBurst', ...
            'Samples','Duration_s', ...
            'PreviousCounter','NextCounter', ...
            'StepCounts','Direction', ...
            'Mean_mA','Median_mA','SD_mA', ...
            'Drift_mA_per_s','FirstMinusLater_mA', ...
            'Accepted','Reason','Limited', ...
            'FaultPrecursor','CollapseFlag', ...
            'PostStepFlag','DriftFlag'});

        commandSegments = appendRow( ...
            commandSegments,row);

        if ~accepted && reason~="SHORT_PLATEAU"

            anomalyRow = table( ...
                file,R,a,b,reason, ...
                "EXCLUDED_FROM_PRIMARY_FIT", ...
                "Segment retained in E02_RejectedPlateaus.csv", ...
                'VariableNames',{ ...
                'File','Load_Ohm','StartRow','EndRow', ...
                'Kind','Disposition','Detail'});

            anomalies = [anomalies;anomalyRow]; %#ok<AGROW>

        end

    end

    %% 4E. Construct row audit, with shape verification

    % The previous table(...) constructor failed here.
    % Add columns individually so an unexpected field
    % cannot silently create a malformed table.

    rowAudit = table((1:n)', ...
        'VariableNames',{'Row'});

    fieldNames = { ...
        'Time_s','Burst','Mode','State','Fault', ...
        'Requested_mA','EffectiveTarget_mA', ...
        'Command_mA','Measured_mA','LoggedError_mA', ...
        'CounterApplied','CounterNext', ...
        'PTerm','ITerm','Dt_ms', ...
        'CommandLimited','ReferenceLimited', ...
        'FaultPrecursor','SegmentID', ...
        'AcceptedForFit','Decision'};

    fieldValues = { ...
        t,burst,mode,state,fault, ...
        req,eff,cmd,y,loggedError, ...
        u,un,pTerm,iTerm,dt, ...
        cmdLim,refLim,precursor,segmentIDs, ...
        acceptedRows,decision};

    assert(numel(fieldNames)==numel(fieldValues));

    for j = 1:numel(fieldNames)

        values = fieldValues{j};
        values = values(:);

        assert(numel(values)==n, ...
            ['E02 row-audit size mismatch in file %s: ' ...
             'field %s has %d elements; expected %d.'], ...
            file,fieldNames{j},numel(values),n);

        rowAudit.(fieldNames{j}) = values;

    end

    assert(height(rowAudit)==n);

    assert(~any(acceptedRows & ~normal), ...
        'Unqualified row marked accepted.');

    assert(nnz(acceptedRows)==sum( ...
        commandSegments.Samples( ...
        commandSegments.Load_Ohm==R & ...
        commandSegments.Accepted)));

    originalErrorCheck = ...
        normal & isfinite(loggedError);

    mismatch = ...
        abs(loggedError-(eff-y))>0.002;

    errorMismatches = nnz( ...
        originalErrorCheck & mismatch);

    % Preserve discrepancies rather than silently changing
    % the logged error.
    if errorMismatches>0

        anomalyRow = table( ...
            file,R,1,n,"LOGGED_ERROR_MISMATCH", ...
            "REVIEW", ...
            "Firmware error differs from target minus measurement", ...
            'VariableNames',{ ...
            'File','Load_Ohm','StartRow','EndRow', ...
            'Kind','Disposition','Detail'});

        anomalies = [anomalies;anomalyRow]; %#ok<AGROW>

    end

    writetable(rowAudit,fullfile(auditDir, ...
        char(erase(file,'.csv')+"_RowAudit.csv")));

    rawData(end+1) = struct( ...
        'File',file, ...
        'Load_Ohm',R, ...
        'Rows',rowAudit); %#ok<SAGROW>

    %% 4F. File-level audit

    adjacent = ...
        running(1:end-1) & running(2:end) & ...
        isfinite(u(1:end-1)) & ...
        isfinite(u(2:end)) & ...
        isfinite(un(1:end-1)) & ...
        diff(burst)==1 & ...
        diff(t)>0 & ...
        diff(t)<=cfg.maxGap_s;

    transitions = nnz( ...
        adjacent & diff(u)~=0);

    nextMismatch = nnz( ...
        adjacent & un(1:end-1)~=u(2:end));

    row = table( ...
        file,R,n,nnz(running), ...
        nnz(state=="DISABLED"), ...
        nnz(faultEvent), ...
        nnz(cmdLim~=0), ...
        nnz(refLim~=0), ...
        nnz(normal),nnz(precursor), ...
        nnz(acceptedRows),transitions, ...
        nextMismatch,numel(groups),fileAccepted, ...
        errorMismatches,t(end)-t(1), ...
        'VariableNames',{ ...
        'File','Load_Ohm','TotalRows', ...
        'RunningRows','DisabledRows','FaultRows', ...
        'CommandLimitedRows','ReferenceLimitedRows', ...
        'UnrestrictedRunningRows', ...
        'PreFaultExcludedRows','AcceptedPlateauRows', ...
        'CounterChanges','NextCounterMismatches', ...
        'CandidateSegments','AcceptedSegments', ...
        'LoggedErrorMismatches','RecordDuration_s'});

    fileAudit = appendRow(fileAudit,row);

    fprintf(['%4d ohm: %4d RUNNING rows, ' ...
             '%2d accepted plateaus, %d fault rows, ' ...
             '%d command-limited rows\n'], ...
        R,nnz(running),fileAccepted, ...
        nnz(faultEvent),nnz(cmdLim~=0));

end

%% 5. Separate accepted and rejected plateaus

assert(height(fileAudit)==6);
assert(~isempty(commandSegments));

accepted = commandSegments( ...
    commandSegments.Accepted,:);

rejected = commandSegments( ...
    ~commandSegments.Accepted,:);

assert(~isempty(accepted), ...
    'No qualified plateaus remain.');

assert(height(accepted)+height(rejected)== ...
    height(commandSegments));

assert(all(accepted.Samples>=cfg.minPlateau));
assert(~any(accepted.Limited | ...
    accepted.FaultPrecursor | ...
    accepted.CollapseFlag | ...
    accepted.PostStepFlag | ...
    accepted.DriftFlag));

%% 6. Aggregate repeated visits by Counter

counterSummary = table();

for R = cfg.loads

    P = accepted(accepted.Load_Ohm==R,:);

    for counter = unique(P.Counter)'

        Q = P(P.Counter==counter,:);

        betweenSD = NaN;

        if height(Q)>1
            betweenSD = std(Q.Mean_mA);
        end

        row = table( ...
            R,counter,height(Q), ...
            sum(Q.Samples),mean(Q.Mean_mA), ...
            betweenSD,mean(Q.SD_mA,'omitnan'), ...
            min(Q.StartTime_s),max(Q.EndTime_s), ...
            'VariableNames',{ ...
            'Load_Ohm','Counter','Visits', ...
            'TotalBursts','MeanOfPlateauMeans_mA', ...
            'BetweenVisitSD_mA', ...
            'MeanWithinPlateauSD_mA', ...
            'FirstTime_s','LastTime_s'});

        counterSummary = appendRow( ...
            counterSummary,row);

    end

end

%% 7. Global fits and local-window sensitivity

globalFits = table();
localFits = table();
fitSensitivity = table();

for R = cfg.loads

    P = accepted(accepted.Load_Ohm==R,:);

    C = counterSummary( ...
        counterSummary.Load_Ohm==R,:);

    GF = fitLine( ...
        C.Counter,C.MeanOfPlateauMeans_mA,cfg);

    row = fitTableRow( ...
        R,"GLOBAL",GF,height(P));

    globalFits = appendRow(globalFits,row);

    selectedFit = fitLine([],[],cfg);
    selected = P([],:);

    selectedWindow = "NOT_IDENTIFIED";

    for minN = cfg.minPlateauSensitivity

        for w = 1:size(cfg.localWindows,1)

            lo = cfg.localWindows(w,1);
            hi = cfg.localWindows(w,2);

            % Reconsider otherwise valid SHORT_PLATEAU
            % segments for the 3-burst sensitivity test.
            potential = commandSegments( ...
                commandSegments.Load_Ohm==R & ...
                commandSegments.Samples>=minN & ...
                ismember(commandSegments.Reason, ...
                ["ACCEPTED","SHORT_PLATEAU"]),:);

            local = potential( ...
                potential.Mean_mA>=lo & ...
                potential.Mean_mA<=hi,:);

            [xu,yu] = uniqueCounterMeans(local);

            fit = fitLine(xu,yu,cfg);

            row = table( ...
                R,minN,lo,hi,height(local), ...
                numel(xu),fit.Valid, ...
                fit.Slope,fit.RMSE, ...
                'VariableNames',{ ...
                'Load_Ohm','MinPlateauBursts', ...
                'WindowLow_mA','WindowHigh_mA', ...
                'Plateaus','DistinctCounters','ValidFit', ...
                'Slope_mA_per_Count','FitRMSE_mA'});

            fitSensitivity = appendRow( ...
                fitSensitivity,row);

            if minN==cfg.minPlateau && ...
                    selectedWindow=="NOT_IDENTIFIED" && ...
                    fit.Valid

                selected = local;
                selectedFit = fit;

                selectedWindow = sprintf( ...
                    '%.1f_to_%.1f_mA',lo,hi);

            end

        end

    end

    equalPlateauSlope = NaN;
    weightedSlope = NaN;

    if selectedFit.Valid

        [xu,yu] = uniqueCounterMeans(selected);

        plateauFit = fitLine( ...
            selected.Counter,selected.Mean_mA,cfg);

        equalPlateauSlope = plateauFit.Slope;

        uncertainty = zeros(numel(xu),1);

        for k = 1:numel(xu)

            V = selected( ...
                selected.Counter==xu(k),:);

            estimatedSE = ...
                V.SD_mA./sqrt(V.Samples);

            estimatedSE = ...
                estimatedSE(isfinite(estimatedSE));

            if isempty(estimatedSE)

                uncertainty(k) = cfg.weightFloor_mA;

            else

                uncertainty(k) = max( ...
                    cfg.weightFloor_mA, ...
                    mean(estimatedSE));

            end

        end

        weights = 1./uncertainty.^2;
        Xfit = [xu ones(size(xu))];

        beta = ...
            (Xfit.*sqrt(weights))\ ...
            (yu.*sqrt(weights));

        weightedSlope = beta(1);

    end

    counter10 = NaN;

    if selectedFit.Valid && ...
            abs(selectedFit.Slope)>eps

        counter10 = ...
            (cfg.target_mA-selectedFit.Intercept)/ ...
            selectedFit.Slope;

    end

    row = table( ...
        R,string(selectedWindow),cfg.minPlateau, ...
        height(selected),selectedFit.NumCounters, ...
        selectedFit.Valid,selectedFit.Slope, ...
        selectedFit.Intercept,selectedFit.RMSE, ...
        selectedFit.R2,selectedFit.CounterMin, ...
        selectedFit.CounterMax,equalPlateauSlope, ...
        weightedSlope,counter10, ...
        selectedFit.Slope-cfg.nominalSlope, ...
        'VariableNames',{ ...
        'Load_Ohm','Window','MinPlateauBursts', ...
        'Plateaus','DistinctCounters','FitValid', ...
        'Slope_mA_per_Count','Intercept_mA', ...
        'RMSE_mA','R2','CounterMin', ...
        'CounterMax', ...
        'EqualPlateauSlope_mA_per_Count', ...
        'ExploratoryWeightedSlope_mA_per_Count', ...
        'CounterFor10mA', ...
        'SlopeMinusNominal_mA_per_Count'});

    localFits = appendRow(localFits,row);

end

%% 8. Quantisation predictions and model comparisons

quantisation = table();
loadComparison = table();
modelComparison = table();

for R = cfg.loads

    L = localFits(localFits.Load_Ohm==R,:);

    if ~L.FitValid
        continue;
    end

    k = L.Slope_mA_per_Count;
    b = L.Intercept_mA;

    u10 = L.CounterFor10mA;
    nearest = round(u10);

    inside = ...
        nearest>=L.CounterMin & ...
        nearest<=L.CounterMax;

    for code = nearest-1:nearest+1

        if code<0 || code>cfg.maxCounter
            continue;
        end

        V = counterSummary( ...
            counterSummary.Load_Ohm==R & ...
            counterSummary.Counter==code,:);

        observed = NaN;

        if ~isempty(V)
            observed = V.MeanOfPlateauMeans_mA;
        end

        pred = k*code+b;

        row = table( ...
            R,code,pred,pred-cfg.target_mA, ...
            observed,u10,inside, ...
            code>=L.CounterMin && ...
            code<=L.CounterMax, ...
            'VariableNames',{ ...
            'Load_Ohm','CandidateCounter', ...
            'PredictedCurrent_mA','PredictedError_mA', ...
            'DirectlyObservedMean_mA','ModelCounter10', ...
            'CounterInsideLocalFitRange', ...
            'WithinFittedRange'});

        quantisation = appendRow(quantisation,row);

    end

    row = table( ...
        R,k,cfg.nominalSlope, ...
        100*(k/cfg.nominalSlope-1), ...
        u10,nearest,k*nearest+b,inside, ...
        'VariableNames',{ ...
        'Load_Ohm','LocalSlope_mA_per_Count', ...
        'NominalSlope_mA_per_Count', ...
        'PercentSlopeDifference', ...
        'EstimatedCounterAt10mA', ...
        'NearestCounter','PredictedNearestCurrent_mA', ...
        'NearestWithinLocalRange'});

    loadComparison = appendRow(loadComparison,row);

    % Descriptive, in-sample model comparisons.
    % These are not cross-validated predictions.
    P = accepted(accepted.Load_Ohm==R,:);

    bounds = sscanf( ...
        char(L.Window),'%f_to_%f_mA');

    if numel(bounds)~=2
        continue;
    end

    W = P( ...
        P.Mean_mA>=bounds(1) & ...
        P.Mean_mA<=bounds(2),:);

    [x,y] = uniqueCounterMeans(W);

    if numel(x)<cfg.minCounters
        continue;
    end

    modelA = ...
        cfg.nominal4kCurrent215 + ...
        cfg.nominalSlope*(x-215);

    sharedSlopeIntercept = ...
        mean(y-cfg.nominalSlope*x);

    modelB = ...
        sharedSlopeIntercept+cfg.nominalSlope*x;

    modelC = b+k*x;

    modelNames = [ ...
        "A_Frozen4kModel", ...
        "B_CommonSlopeLoadIntercept", ...
        "C_LoadSpecificLocalModel"];

    predictions = [modelA modelB modelC];

    for j = 1:3

        rmse = sqrt(mean( ...
            (y-predictions(:,j)).^2));

        row = table( ...
            R,modelNames(j),numel(x),rmse,false, ...
            'VariableNames',{ ...
            'Load_Ohm','Model','DistinctCounters', ...
            'InSampleRMSE_mA','OutOfSampleValidated'});

        modelComparison = appendRow( ...
            modelComparison,row);

    end

end

%% 9. Limits, fault table and repeated visits

limits = fileAudit(:,{ ...
    'File','Load_Ohm','FaultRows', ...
    'CommandLimitedRows','ReferenceLimitedRows', ...
    'PreFaultExcludedRows'});

repeatedVisits = table();

for R = cfg.loads

    P = accepted(accepted.Load_Ohm==R,:);

    for code = unique(P.Counter)'

        V = P(P.Counter==code,:);

        if height(V)<2
            continue;
        end

        upward = V.Mean_mA(V.Direction=="UP");
        downward = V.Mean_mA(V.Direction=="DOWN");

        directionDifference = NaN;

        if ~isempty(upward) && ~isempty(downward)

            directionDifference = ...
                mean(upward)-mean(downward);

        end

        row = table( ...
            R,code,height(V), ...
            min(V.Mean_mA),max(V.Mean_mA), ...
            range(V.Mean_mA),directionDifference, ...
            'VariableNames',{ ...
            'Load_Ohm','Counter','Visits', ...
            'MinMean_mA','MaxMean_mA', ...
            'RangeOfVisitMeans_mA','UpMinusDown_mA'});

        repeatedVisits = appendRow(repeatedVisits,row);

    end

end

if isempty(repeatedVisits)

    repeatedVisits = table( ...
        'Size',[0 7], ...
        'VariableTypes',repmat({'double'},1,7), ...
        'VariableNames',{ ...
        'Load_Ohm','Counter','Visits', ...
        'MinMean_mA','MaxMean_mA', ...
        'RangeOfVisitMeans_mA','UpMinusDown_mA'});

end

%% 10. Export numerical outputs

results = { ...
    'E02_FileAudit.csv',fileAudit; ...
    'E02_CommandSegments.csv',commandSegments; ...
    'E02_AcceptedPlateaus.csv',accepted; ...
    'E02_RejectedPlateaus.csv',rejected; ...
    'E02_CounterSummary.csv',counterSummary; ...
    'E02_GlobalFits.csv',globalFits; ...
    'E02_LocalFits.csv',localFits; ...
    'E02_FitSensitivity.csv',fitSensitivity; ...
    'E02_LoadComparison.csv',loadComparison; ...
    'E02_QuantisationPredictions.csv',quantisation; ...
    'E02_LimitsAndFaults.csv',limits; ...
    'E02_AnomalyRegister.csv',anomalies; ...
    'E02_ModelComparison.csv',modelComparison; ...
    'E02_RepeatedVisitComparison.csv',repeatedVisits};

for k = 1:size(results,1)

    writetable(results{k,2}, ...
        fullfile(outDir,results{k,1}));

end

%% 11. Verification and processed archive

assert(height(fileAudit)==6);
assert(height(globalFits)==6);
assert(height(localFits)==6);

assert(height(accepted)+height(rejected)== ...
    height(commandSegments));

assert(all(accepted.Counter==round(accepted.Counter)));

assert(all(accepted.Samples>=cfg.minPlateau));

for R = cfg.loads

    Q = accepted(accepted.Load_Ohm==R,:);

    assert(~isempty(Q), ...
        'No accepted plateaus at %d ohm.',R);

end

save(fullfile(outDir,'E02_ProcessedResults.mat'), ...
    'cfg','fileAudit','commandSegments', ...
    'accepted','rejected','counterSummary', ...
    'globalFits','localFits','fitSensitivity', ...
    'loadComparison','quantisation','limits', ...
    'anomalies','modelComparison','repeatedVisits', ...
    'rawData','-v7.3');

fid = fopen(fullfile(outDir, ...
    'E02_VerificationLog.txt'),'w');

assert(fid>0,'Unable to create verification log.');

stamp = string(datetime("now", ...
    'Format',"yyyy-MM-dd HH:mm:ss"));

fprintf(fid,'E02 Plant Identification Verification\n\n');

fprintf(fid,'Generated: %s\n',char(stamp));
fprintf(fid,'MATLAB: %s\n',version);
fprintf(fid,'Files: %d\n',height(fileAudit));
fprintf(fid,'Segments: %d\n',height(commandSegments));
fprintf(fid,'Accepted plateaus: %d\n',height(accepted));
fprintf(fid,'Rejected plateaus: %d\n',height(rejected));
fprintf(fid,'Anomaly entries: %d\n\n',height(anomalies));

fprintf(fid, ...
    ['Executed checks: file identity, schema, ' ...
     'column dimensions, operating-state eligibility, ' ...
     'plateau acceptance, Counter integrality, ' ...
     'aggregation and result inventory.\n']);

fprintf(fid, ...
    ['The numerical PI and firmware calibration ' ...
     'settings require independent firmware confirmation.\n']);

fprintf(fid, ...
    ['There is one manually acquired sweep per load. ' ...
     'No independent replicate-based confidence ' ...
     'intervals were calculated.\n']);

fclose(fid);

fprintf('\nE02 ANALYSIS COMPLETED\n');

disp(localFits(:,{ ...
    'Load_Ohm','Window','DistinctCounters', ...
    'FitValid','Slope_mA_per_Count', ...
    'RMSE_mA','CounterFor10mA'}));

fprintf('\nResults: %s\n',outDir);

%% ============================================================
% Local functions
% ============================================================

function x = numericColumn(v,n,name)

    if isnumeric(v) || islogical(v)
        x = double(v(:));
    else
        x = str2double(string(v(:)));
    end

    assert(numel(x)==n, ...
        'Column %s: expected %d values, found %d.', ...
        name,n,numel(x));

end

function x = textColumn(v,n,name)

    x = upper(strtrim(string(v(:))));

    assert(numel(x)==n, ...
        'Text column %s: expected %d values, found %d.', ...
        name,n,numel(x));

end

function T = appendRow(T,row)

    if isempty(T) && width(T)==0

        T = row;

    else

        assert(isequal( ...
            T.Properties.VariableNames, ...
            row.Properties.VariableNames), ...
            'Table schema mismatch during row append.');

        T = [T;row];

    end

end

function [x,y] = uniqueCounterMeans(P)

    if isempty(P)

        x = zeros(0,1);
        y = zeros(0,1);
        return;

    end

    x = unique(P.Counter);
    x = x(:);

    y = zeros(size(x));

    for j = 1:numel(x)

        y(j) = mean( ...
            P.Mean_mA(P.Counter==x(j)));

    end

end

function F = fitLine(x,y,cfg)

    x = x(:);
    y = y(:);

    F = struct( ...
        'Valid',false, ...
        'NumCounters',numel(unique(x)), ...
        'Slope',NaN, ...
        'Intercept',NaN, ...
        'RMSE',NaN, ...
        'R2',NaN, ...
        'CounterMin',NaN, ...
        'CounterMax',NaN);

    if numel(x)<cfg.minCounters || ...
            numel(unique(x))<cfg.minCounters
        return;
    end

    if max(x)-min(x)<cfg.minCounterSpan
        return;
    end

    p = polyfit(x,y,1);
    predicted = polyval(p,x);

    F.Valid = true;
    F.Slope = p(1);
    F.Intercept = p(2);
    F.RMSE = sqrt(mean((y-predicted).^2));

    total = sum((y-mean(y)).^2);

    if total>0

        F.R2 = ...
            1-sum((y-predicted).^2)/total;

    end

    F.CounterMin = min(x);
    F.CounterMax = max(x);

end

function row = fitTableRow(R,name,F,plateaus)

    row = table( ...
        R,string(name),F.Valid,F.NumCounters, ...
        plateaus,F.CounterMin,F.CounterMax, ...
        F.Slope,F.Intercept,F.RMSE,F.R2, ...
        'VariableNames',{ ...
        'Load_Ohm','Fit','FitValid', ...
        'DistinctCounters','Plateaus', ...
        'CounterMin','CounterMax', ...
        'Slope_mA_per_Count','Intercept_mA', ...
        'RMSE_mA','R2'});

end
