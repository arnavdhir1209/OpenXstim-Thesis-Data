
%% analyse_E04_deadband.m
% E04 hardware deadband validation
% MATLAB R2025a
%
% Run from the parent HardwareValidation folder.
% Only E04 recordings are analysed.
%
% IMPORTANT:
% Accuracy metrics use Arduino measured current.
% They are NOT independently calibrated true current.
%
% Abnormal/faulted/limited recordings are audited,
% but excluded from the primary condition summaries.

clearvars; clc;

%% Configuration

root = fileparts(mfilename('fullpath'));
if isempty(root), root = pwd; end

out = fullfile(root,'E04_Deadband_Results');
if ~isfolder(out), mkdir(out); end

expectedLoads = [100 4000];
expectedD = [0.030 0.045 0.060];
expectedTrialsPerCondition = 5;

reference_mA = 10;
expectedMode = "PI_CONTROL";

minFullDuration_s = 50;
steadyDuration_s = 20;
transientDuration_s = 30;

bands = [0.030 0.045 0.060 0.100];

% Maximum allowed gap between consecutive
% eligible burst records for transition counting.
maxGap_s = 0.5;

% Large unexpected changes are flagged, not
% automatically interpreted as physical faults.
collapseThreshold_mA = 2.0;

% The initial code may differ from 215 after
% a recording starts. Preserve actual values.
nominalInitialCounter = 215;


%% Discover and validate actual E04 recordings

% The script is stored directly beside all 30 CSV files.
% Actual naming:
% E04_R0100_D030_T01.csv
% E04_R4000_D060_T05.csv
%
% Also supports the older optional PI_F naming style.

F = dir(fullfile(root,'E04_R*_D*_T*.csv'));

files = struct( ...
    'path',{},'name',{},'load',{}, ...
    'deadband',{},'trial',{});

for k = 1:numel(F)

    name = string(F(k).name);

    tok = regexpi(char(name), ...
        ['^E04_R(\d+)_(?:PI[_-]?F_)?' ...
         'D(\d+)_T(\d+)\.csv$'], ...
        'tokens','once');

    if isempty(tok)
        warning('Unexpected E04 filename: %s',name);
        continue;
    end

    entry.path = fullfile(F(k).folder,F(k).name);
    entry.name = name;
    entry.load = str2double(tok{1});
    entry.deadband = str2double(tok{2})/1000;
    entry.trial = str2double(tok{3});

    assert(ismember(entry.load,expectedLoads), ...
        'Unexpected resistance: %s',name);

    assert(any(abs(expectedD-entry.deadband)<1e-9), ...
        'Unexpected deadband: %s',name);

    files(end+1) = entry; %#ok<SAGROW>

end

assert(numel(files)==30, ...
    'Expected 30 E04 recordings, found %d.',numel(files));

keys = strings(numel(files),1);

for k = 1:numel(files)

    keys(k) = sprintf('R%04d_D%03d_T%02d', ...
        files(k).load, ...
        round(files(k).deadband*1000), ...
        files(k).trial);

end

assert(numel(unique(keys))==numel(keys), ...
    'Duplicate E04 recording identifiers detected.');

% Verify that every expected condition has five trials.

for R = expectedLoads
    for D = expectedD

        foundTrials = [];

        for k = 1:numel(files)

            if files(k).load==R && ...
                    abs(files(k).deadband-D)<1e-9

                foundTrials(end+1) = ...
                    files(k).trial; %#ok<SAGROW>

            end

        end

        assert(isequal(sort(foundTrials),1:5), ...
            'Incomplete trials at R=%d, D=%.3f.',R,D);

    end
end

fprintf('\n====================================\n');
fprintf('E04 HARDWARE RECORDING INVENTORY\n');
fprintf('====================================\n');

fprintf('Total E04 CSV files: %d\n',numel(files));
fprintf('Resistances: 100 and 4000 ohms\n');
fprintf('Deadbands: 0.030, 0.045, 0.060 mA\n');
fprintf('Five recordings per condition: VERIFIED\n');

%% Output tables

fileAudit = table();
trialMetrics = table();
bandSummary = table();
occupancy = table();
transients = table();
anomalies = table();
verification = strings(0,1);

trajectories = struct( ...
    'File',{},'Load_Ohm',{},'Deadband_mA',{}, ...
    'Trial',{},'Eligible',{},'Time_s',{}, ...
    'Current_mA',{},'Error_mA',{}, ...
    'AppliedCounter',{},'NextCounter',{}, ...
    'PTerm',{},'ITerm',{},'Burst',{}, ...
    'Dt_ms',{});

%% Process recordings

for f = 1:numel(files)

    info = files(f);

    T = readtable(info.path, ...
        'VariableNamingRule','preserve');

    required = { ...
        'time_ms','burst','mode','stim_state', ...
        'requested_mA','effective_target_mA', ...
        'command_mA','measured_mA','error_mA', ...
        'counter_applied','counter_next', ...
        'p_term_counts','i_term_counts', ...
        'command_limited','reference_limited', ...
        'fault_code','dt_ms'};

    missing = setdiff(required, ...
        T.Properties.VariableNames);

    if ~isempty(missing)
        error('%s is missing columns: %s', ...
            info.name,strjoin(missing,', '));
    end

    N = height(T);

    t = numeric(T.time_ms)/1000;
    burst = numeric(T.burst);
    target = numeric(T.effective_target_mA);
    requested = numeric(T.requested_mA);
    current = numeric(T.measured_mA);
    applied = numeric(T.counter_applied);
    next = numeric(T.counter_next);
    pTerm = numeric(T.p_term_counts);
    iTerm = numeric(T.i_term_counts);
    dt = numeric(T.dt_ms);

    state = upper(strtrim(string(T.stim_state)));
    mode = upper(strtrim(string(T.mode)));
    fault = upper(strtrim(string(T.fault_code)));

    limited = ...
        numeric(T.command_limited)~=0 | ...
        numeric(T.reference_limited)~=0;

    running = state=="RUNNING";

    % Explicitly recognise expected mode aliases.
    piMode = ismember(mode, ...
        ["PI_CONTROL","PI","CLOSED_LOOP","PI-CONTROL"]);

    faultFree = ismember(fault, ...
        ["NONE","NO_FAULT","0"]);

    finite = ...
        isfinite(t) & ...
        isfinite(burst) & ...
        isfinite(current) & ...
        isfinite(target) & ...
        isfinite(requested) & ...
        isfinite(applied) & ...
        isfinite(next);

    valid = ...
        running & piMode & faultFree & ...
        ~limited & finite & ...
        current>0 & ...
        abs(target-reference_mA)<0.001 & ...
        abs(requested-reference_mA)<0.001 & ...
        applied==round(applied) & ...
        next==round(next) & ...
        applied>=0 & applied<=322 & ...
        next>=0 & next<=322;

    decision = repmat("VALID_CANDIDATE",N,1);
    decision(~running) = "NOT_RUNNING";
    decision(running & ~piMode) = "NOT_PI_MODE";
    decision(~faultFree) = "FAULT";
    decision(limited) = "SOFTWARE_LIMIT";
    decision(~finite) = "INVALID_MEASUREMENT";

    badReference = ...
        isfinite(target) & ...
        abs(target-reference_mA)>=0.001;

    decision(badReference) = "REFERENCE_MISMATCH";

    % Assess ordered running timestamps and burst IDs.
    runningRows = find(running & isfinite(t));

    monotonic = all(diff(t(runningRows))>0);

    validRows = find(valid);

    burstMonotonic = true;

    if numel(validRows)>1
        burstMonotonic = ...
            all(diff(burst(validRows))>0);
    end

    % Detect an unexpected large current decrease.
    collapseRows = zeros(0,1);

    for k = 2:N

        if valid(k) && valid(k-1) && ...
                current(k-1)-current(k)> ...
                collapseThreshold_mA

            collapseRows(end+1,1) = k; %#ok<SAGROW>

        end

    end

    % The run is quarantined if a fault, limit,
    % major collapse or invalid operating condition
    % is observed in its active RUNNING interval.
    activeFault = any(running & ~faultFree);
    anyFault = any(~faultFree);
    activeLimit = any(running & limited);
    wrongMode = any(running & ~piMode);

    if ~isempty(validRows)
        activeDuration = ...
            t(validRows(end))-t(validRows(1));
    else
        activeDuration = NaN;
    end

    eligible = ...
        ~anyFault && ...
        ~activeLimit && ...
        ~wrongMode && ...
        isempty(collapseRows) && ...
        monotonic && ...
        burstMonotonic && ...
        numel(validRows)>=10 && ...
        activeDuration>=minFullDuration_s;

    if eligible
        decision(valid) = "ACCEPTED";
    else
        decision(valid) = "QUARANTINED_RUN";
    end

    % Raw row audit, including rejected observations.
    trialDir = fullfile(out, ...
        sprintf('R%04d',info.load), ...
        sprintf('D%03d',round(info.deadband*1000)), ...
        sprintf('T%02d',info.trial));

    if ~isfolder(trialDir), mkdir(trialDir); end

    rowAudit = table( ...
        (1:N)',t,burst,state,mode,fault, ...
        requested,target,current,applied,next, ...
        limited,valid,decision, ...
        'VariableNames',{ ...
        'OriginalRow','Time_s','Burst','State', ...
        'Mode','Fault','Requested_mA', ...
        'EffectiveTarget_mA','Measured_mA', ...
        'CounterApplied','CounterNext', ...
        'Limited','InitiallyValid','FinalDecision'});

    writetable(rowAudit, ...
        fullfile(trialDir,'E04_RowAudit.csv'));

    %% File-level audit

    issue = "NONE";

    if anyFault
        issue = issue + "|FAULT";
    end
    if activeLimit
        issue = issue + "|SOFTWARE_LIMIT";
    end
    if wrongMode
        issue = issue + "|WRONG_MODE";
    end
    if ~monotonic
        issue = issue + "|TIMESTAMP";
    end
    if ~burstMonotonic
        issue = issue + "|BURST_INDEX";
    end
    if ~isempty(collapseRows)
        issue = issue + "|CURRENT_COLLAPSE";
    end
    if ~(activeDuration>=minFullDuration_s)
        issue = issue + "|SHORT_RUN";
    end

    if anyFault || activeLimit || ...
            ~isempty(collapseRows)

        anomalyRow = table( ...
            info.name,info.load,info.deadband, ...
            info.trial,issue,~eligible, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Deadband_mA', ...
            'Trial','Issue','ExcludedFromPrimary'});

        anomalies = [anomalies;anomalyRow]; %#ok<AGROW>

    end

    auditRow = table( ...
        info.name,string(info.path), ...
        info.load,info.deadband,info.trial, ...
        N,nnz(running),nnz(valid), ...
        N-nnz(valid),activeDuration, ...
        anyFault,activeLimit, ...
        monotonic,burstMonotonic, ...
        numel(collapseRows),eligible,issue, ...
        'VariableNames',{ ...
        'File','SourcePath','Load_Ohm', ...
        'Deadband_mA','Trial','TotalRows', ...
        'RunningRows','ValidCurrentRows', ...
        'RejectedRows','ActiveDuration_s', ...
        'AnyFault','ActiveLimit', ...
        'TimeMonotonic','BurstMonotonic', ...
        'CollapseEvents','Eligible','Issue'});

    fileAudit = [fileAudit;auditRow]; %#ok<AGROW>

    fprintf('%s: %d rows, eligible=%d\n', ...
        info.name,N,eligible);

    if ~eligible
        continue;
    end

    %% Qualified trajectory

    ix = find(valid);

    tv = t(ix);
    y = current(ix);
    r = target(ix);
    u = applied(ix);
    unext = next(ix);

    e = r-y;
    elapsed = tv-tv(1);

    % Use timestamps to define sample intervals.
    % The final interval is estimated from observed
    % positive intervals rather than assumed timing.
    dtime = diff(tv);

    assert(all(dtime>0), ...
        'Nonmonotonic eligible timestamps.');

    lastDt = median(dtime(dtime>0));

    w = [dtime;lastDt];

    % Do not integrate across excessively large gaps.
    gaps = [false;dtime>maxGap_s];

    if any(gaps)
        warning('%s contains gaps in valid records.', ...
            info.name);
    end

    %% Time windows

    fullMask = true(numel(ix),1);

    transientMask = elapsed<transientDuration_s;

    steadyStart = elapsed(end)-steadyDuration_s;

    steadyMask = elapsed>=steadyStart;

    % The steady window must cover a meaningful
    % final interval with enough observations.
    assert(nnz(steadyMask)>=10, ...
        'Insufficient steady-state observations.');

    %% Full, transient and steady metrics

    MF = windowMetrics( ...
        e,u,w,tv,fullMask,maxGap_s);

    MT = windowMetrics( ...
        e,u,w,tv,transientMask,maxGap_s);

    MS = windowMetrics( ...
        e,u,w,tv,steadyMask,maxGap_s);

    %% Primary trial summary

    trialRow = table( ...
        info.name,info.load,info.deadband,info.trial, ...
        MF.RMSE,MT.RMSE,MS.RMSE, ...
        MS.SignedBias,MS.AbsBias, ...
        MS.MeanAbsError,MS.CurrentSD, ...
        MS.SwitchRate,MS.Switches, ...
        MS.Movement,MS.Within030, ...
        MS.Within045,MS.Within060, ...
        MS.Within100,MS.CounterMode, ...
        MS.FinalCounter, ...
        MS.Duration_s, ...
        'VariableNames',{ ...
        'File','Load_Ohm','Deadband_mA','Trial', ...
        'FullRMSE_mA','TransientRMSE_mA', ...
        'SteadyRMSE_mA','SteadySignedBias_mA', ...
        'SteadyAbsBias_mA','SteadyMAE_mA', ...
        'SteadyCurrentSD_mA', ...
        'SteadyDACChangesPer_s', ...
        'SteadyDACChanges','SteadyDACMovement', ...
        'Within030','Within045','Within060', ...
        'Within100','MostCommonCounter', ...
        'FinalCounter','SteadyDuration_s'});

    trialMetrics = [trialMetrics;trialRow]; %#ok<AGROW>

    %% Common accuracy bands

    for b = bands

        m = steadyMask;

        denominator = sum(w(m));

        frac = sum( ...
            w(m & abs(e)<=b))/denominator;

        above = sum( ...
            w(m & e< -b))/denominator;

        below = sum( ...
            w(m & e> b))/denominator;

        bandSummary = [bandSummary;table( ...
            info.name,info.load,info.deadband, ...
            info.trial,b,frac,above,below, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Deadband_mA', ...
            'Trial','AccuracyBand_mA', ...
            'WithinBand','AboveTarget','BelowTarget'})]; ...
            %#ok<AGROW>

    end

    %% Steady-state Counter occupancy

    us = u(steadyMask);
    ws = w(steadyMask);

    codes = unique(us);

    for c = codes(:)'

        occ = sum(ws(us==c))/sum(ws);

        occupancy = [occupancy;table( ...
            info.name,info.load,info.deadband, ...
            info.trial,c,occ, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Deadband_mA', ...
            'Trial','Counter','Occupancy'})]; ...
            %#ok<AGROW>

    end

    assert(abs(sum(occupancy.Occupancy( ...
        occupancy.File==info.name))-1)<1e-8, ...
        'Counter occupancy does not sum to one.');

    %% Transient metrics

    initialError = e(1);

    firstIn030 = firstEntry(elapsed,e,0.03);

    hold030 = sustainedEntry( ...
        elapsed,e,0.03,2.0);

    transients = [transients;table( ...
        info.name,info.load,info.deadband, ...
        info.trial,y(1),initialError,u(1), ...
        firstIn030,hold030, ...
        max(y-r),max(r-y), ...
        MT.Switches,MT.RMSE, ...
        'VariableNames',{ ...
        'File','Load_Ohm','Deadband_mA', ...
        'Trial','InitialCurrent_mA', ...
        'InitialError_mA','InitialCounter', ...
        'FirstEntry030_s','Hold2s030_s', ...
        'Overshoot_mA','Undershoot_mA', ...
        'TransientSwitches','TransientRMSE_mA'})]; ...
        %#ok<AGROW>

    %% Save representative raw trajectories

    q = numel(trajectories)+1;

    trajectories(q).File = info.name;
    trajectories(q).Load_Ohm = info.load;
    trajectories(q).Deadband_mA = info.deadband;
    trajectories(q).Trial = info.trial;
    trajectories(q).Eligible = true;
    trajectories(q).Time_s = elapsed;
    trajectories(q).Current_mA = y;
    trajectories(q).Error_mA = e;
    trajectories(q).AppliedCounter = u;
    trajectories(q).NextCounter = unext;
    trajectories(q).PTerm = pTerm(ix);
    trajectories(q).ITerm = iTerm(ix);
    trajectories(q).Burst = burst(ix);
    trajectories(q).Dt_ms = dt(ix);

    processed = table( ...
        elapsed,y,r,e,u,unext,pTerm(ix), ...
        iTerm(ix),burst(ix),dt(ix), ...
        'VariableNames',{ ...
        'Elapsed_s','Measured_mA', ...
        'Target_mA','Error_mA', ...
        'CounterApplied','CounterNext', ...
        'PTerm','ITerm','Burst','Dt_ms'});

    writetable(processed, ...
        fullfile(trialDir,'E04_QualifiedTrajectory.csv'));

    %% Observable one-burst indexing check

    % Only consecutive original rows can be compared.
    consecutive = diff(ix)==1;

    if any(consecutive)

        observed = u(2:end);
        predicted = unext(1:end-1);

        assert(all( ...
            observed(consecutive)== ...
            predicted(consecutive)), ...
            'Applied/next Counter indexing mismatch.');

    end

end

%% Export primary tables

writetable(fileAudit, ...
    fullfile(out,'E04_FileAudit.csv'));

writetable(anomalies, ...
    fullfile(out,'E04_AnomalyRegister.csv'));

assert(~isempty(trialMetrics), ...
    ['No eligible E04 hardware trials. ' ...
     'Inspect E04_FileAudit.csv before continuing.']);

writetable(trialMetrics, ...
    fullfile(out,'E04_TrialMetrics.csv'));

writetable(bandSummary, ...
    fullfile(out,'E04_AccuracyBandSummary.csv'));

writetable(occupancy, ...
    fullfile(out,'E04_DACOccupancy.csv'));

writetable(transients, ...
    fullfile(out,'E04_TransientSummary.csv'));

%% Aggregate by load and deadband

conditionSummary = groupsummary( ...
    trialMetrics, ...
    {'Load_Ohm','Deadband_mA'}, ...
    {'mean','std'}, ...
    {'SteadyRMSE_mA', ...
     'SteadyAbsBias_mA', ...
     'SteadySignedBias_mA', ...
     'SteadyDACChangesPer_s', ...
     'SteadyDACMovement', ...
     'Within030', ...
     'SteadyCurrentSD_mA'});

writetable(conditionSummary, ...
    fullfile(out,'E04_ConditionSummary.csv'));

%% Verify factorial coverage

for R = expectedLoads
    for D = expectedD

        n = nnz( ...
            trialMetrics.Load_Ohm==R & ...
            abs(trialMetrics.Deadband_mA-D)<1e-8);

        if n~=expectedTrialsPerCondition
            warning( ...
                'R=%d, D=%.3f: %d/%d eligible trials.', ...
                R,D,n,expectedTrialsPerCondition);
        end

    end
end

%% Verification and archive

assert(all(trialMetrics.SteadyRMSE_mA>=0));
assert(all(trialMetrics.Within030>=0 & ...
    trialMetrics.Within030<=1));
assert(all(trialMetrics.SteadyDACChangesPer_s>=0));

save(fullfile(out,'E04_ProcessedResults.mat'), ...
    'fileAudit','trialMetrics','conditionSummary', ...
    'bandSummary','occupancy','transients', ...
    'anomalies','trajectories','-v7.3');

fid = fopen(fullfile(out,'E04_VerificationLog.txt'),'w');

fprintf(fid,'E04 HARDWARE ANALYSIS VERIFICATION\n');
fprintf(fid,'MATLAB: %s\n',version);
fprintf(fid,'Discovered files: %d\n',numel(files));
fprintf(fid,'Eligible trials: %d\n',height(trialMetrics));
fprintf(fid,'Quarantined/ineligible files: %d\n', ...
    nnz(~fileAudit.Eligible));
fprintf(fid,'Required row and schema checks executed.\n');
fprintf(fid,'Metric and occupancy assertions executed.\n');
fprintf(fid,'Controller gains not independently verified from CSV.\n');
fprintf(fid,'Trial pairing not assumed.\n');

fclose(fid);

fprintf('\nE04 analysis complete.\n');
disp(conditionSummary);

%% ============================================================
% Local functions
% ============================================================

function x = numeric(v)
    if isnumeric(v)
        x = double(v(:));
    else
        x = str2double(string(v(:)));
    end
end

function M = windowMetrics(e,u,w,t,mask,maxGap)

    ix = find(mask);
    ew = e(ix);
    uw = u(ix);
    ww = w(ix);
    tt = t(ix);

    W = sum(ww);

    assert(W>0);

    M.Duration_s = W;
    M.RMSE = sqrt(sum(ww.*ew.^2)/W);
    M.SignedBias = sum(ww.*ew)/W;
    M.AbsBias = abs(M.SignedBias);
    M.MeanAbsError = sum(ww.*abs(ew))/W;
    M.CurrentSD = std(ew);
    M.Within030 = sum(ww(abs(ew)<=0.030))/W;
    M.Within045 = sum(ww(abs(ew)<=0.045))/W;
    M.Within060 = sum(ww(abs(ew)<=0.060))/W;
    M.Within100 = sum(ww(abs(ew)<=0.100))/W;

    du = diff(uw);
    dt = diff(tt);

    adjacent = dt>0 & dt<=maxGap;

    M.Switches = nnz(du(adjacent)~=0);
    M.SwitchRate = M.Switches/W;
    M.Movement = sum(abs(du(adjacent)));

    [codes,~,g] = unique(uw);
    weightedCounts = accumarray(g,ww);
    [~,i] = max(weightedCounts);

    M.CounterMode = codes(i);
    M.FinalCounter = uw(end);

    assert(M.Movement>=M.Switches);

end

function v = firstEntry(t,e,band)

    ix = find(abs(e)<=band,1,'first');

    if isempty(ix)
        v = NaN;
    else
        v = t(ix);
    end

end

function v = sustainedEntry(t,e,band,duration)

    v = NaN;

    for k = 1:numel(t)

        q = find(t>=t(k)+duration,1,'first');

        if isempty(q), break; end

        if all(abs(e(k:q))<=band)
            v = t(k);
            return;
        end

    end

end
