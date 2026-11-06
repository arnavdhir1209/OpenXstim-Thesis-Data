
%% analyse_E03_PI_gains.m
% E03: Hardware PI gain validation
% MATLAB R2025a
%
% Place beside:
%   Empirical/
%   Faster/
%
% This script:
%   - Discovers E03 CSV recordings
%   - Verifies folder and filename identity
%   - Audits validity, timing, and burst indexing
%   - Calculates transient and steady metrics
%   - Saves accepted trajectories and summaries
%
% No firmware changes or simulation reruns.

clearvars;
clc;

%% Configuration

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir), scriptDir = pwd; end

outDir = fullfile(scriptDir,'E03_PI_Results');
if ~isfolder(outDir), mkdir(outDir); end

controllers = ["Empirical","Faster"];
controllerCodes = ["E","F"];

Kp = [5.000000,4.867577];
Ki = [3.000000,9.758558];

reference_mA = 10;
deadband_mA = 0.030;

accuracyBands = [0.030 0.050 0.100 0.200];

maxGap_s = 0.5;
minimumDuration_s = 50;

steadyWindow_s = 20;
earlyWindow_s = 10;
transientWindow_s = 30;

% Detection thresholds, used only for anomaly review.
collapseFlag_mA = 2.0;
largeCounterStep = 5;

%% Discover E03 files

entries = struct( ...
    'File',{},'Path',{},'Load',{}, ...
    'Controller',{},'Trial',{});

for c = 1:2

    folder = fullfile(scriptDir,char(controllers(c)));

    assert(isfolder(folder), ...
        'Missing controller folder: %s',folder);

    F = dir(fullfile(folder,'*.csv'));

    for k = 1:numel(F)

        filename = string(F(k).name);

        token = regexp(char(filename), ...
            '^E03_R(\d+)_PI_([EF])_T(\d+)\.csv$', ...
            'tokens','once','ignorecase');

        if isempty(token)
            warning('Unrecognised CSV in %s: %s', ...
                folder,filename);
            continue;
        end

        code = upper(string(token{2}));

        assert(code==controllerCodes(c), ...
            'Folder/controller mismatch: %s',filename);

        entry.File = filename;
        entry.Path = fullfile(F(k).folder,F(k).name);
        entry.Load = str2double(token{1});
        entry.Controller = controllers(c);
        entry.Trial = str2double(token{3});

        entries(end+1) = entry; %#ok<SAGROW>
    end
end

assert(~isempty(entries),'No E03 recordings found.');

keys = strings(numel(entries),1);

for k = 1:numel(entries)
    keys(k) = sprintf('%d_%s_%d', ...
        entries(k).Load, ...
        entries(k).Controller, ...
        entries(k).Trial);
end

assert(numel(unique(keys))==numel(keys), ...
    'Duplicate E03 recording identifier.');

fprintf('\nE03 recordings discovered: %d\n', ...
    numel(entries));

%% Output containers

fileAudit = table();
trialMetrics = table();
transientMetrics = table();
settlingSummary = table();
dacActivity = table();
dacOccupancy = table();
anomalyRegister = table( ...
    strings(0,1),zeros(0,1), ...
    strings(0,1),zeros(0,1),strings(0,1), ...
    'VariableNames',{ ...
    'File','Load_Ohm','Controller','Trial','Reason'});

trajectories = struct( ...
    'File',{},'Load_Ohm',{},'Controller',{}, ...
    'Trial',{},'Time_s',{},'Current_mA',{}, ...
    'Error_mA',{},'AppliedCounter',{}, ...
    'NextCounter',{},'PTerm',{},'ITerm',{}, ...
    'Burst',{},'Dt_ms',{});

%% Process all recordings

for f = 1:numel(entries)

    info = entries(f);

    T = readtable(info.Path, ...
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

    assert(isempty(missing), ...
        'Missing CSV fields in %s: %s', ...
        info.File,strjoin(missing,', '));

    N = height(T);

    time = asNumeric(T.time_ms)/1000;
    burst = asNumeric(T.burst);

    requested = asNumeric(T.requested_mA);
    target = asNumeric(T.effective_target_mA);
    measured = asNumeric(T.measured_mA);

    loggedError = asNumeric(T.error_mA);

    applied = asNumeric(T.counter_applied);
    next = asNumeric(T.counter_next);

    pTerm = asNumeric(T.p_term_counts);
    iTerm = asNumeric(T.i_term_counts);

    dt = asNumeric(T.dt_ms);

    commandLimit = asNumeric(T.command_limited);
    referenceLimit = asNumeric(T.reference_limited);

    mode = upper(strtrim(string(T.mode)));
    state = upper(strtrim(string(T.stim_state)));
    fault = upper(strtrim(string(T.fault_code)));

    running = state=="RUNNING";
    piMode = mode=="PI_CONTROL";
    faultFree = fault=="NONE";

    limited = commandLimit~=0 | referenceLimit~=0;

    numericalValid = ...
        isfinite(time) & isfinite(burst) & ...
        isfinite(requested) & isfinite(target) & ...
        isfinite(measured) & isfinite(loggedError) & ...
        isfinite(applied) & isfinite(next) & ...
        isfinite(pTerm) & isfinite(iTerm);

    referenceValid = ...
        abs(requested-reference_mA)<0.001 & ...
        abs(target-reference_mA)<0.001;

    counterValid = ...
        applied==round(applied) & ...
        next==round(next) & ...
        applied>=0 & applied<=322 & ...
        next>=0 & next<=322;

    valid = ...
        running & piMode & faultFree & ...
        ~limited & numericalValid & ...
        referenceValid & counterValid & ...
        measured>0;

    decision = repmat("VALID_CANDIDATE",N,1);

    decision(~running) = "NOT_RUNNING";
    decision(running & ~piMode) = "WRONG_MODE";
    decision(running & ~faultFree) = "FAULT";
    decision(running & limited) = "LIMITED";
    decision(running & ~numericalValid) = ...
        "INVALID_NUMERIC";
    decision(running & ~referenceValid) = ...
        "REFERENCE_MISMATCH";
    decision(running & ~counterValid) = ...
        "INVALID_COUNTER";

    ix = find(valid);

    if isempty(ix)
        activeDuration = NaN;
    else
        activeDuration = time(ix(end))-time(ix(1));
    end

    %% File-level consistency

    allRunning = find(running);

    observedFault = any(running & ~faultFree);
    observedLimit = any(running & limited);
    wrongMode = any(running & ~piMode);

    invalidRunning = any(running & ~valid);

    timeOK = numel(ix)>=2 && ...
        all(diff(time(ix))>0);

    burstOK = numel(ix)>=2 && ...
        all(diff(burst(ix))==1);

    errorOK = true;
    indexingOK = true;
    timingOK = true;

    if numel(ix)>=2

        e = target(ix)-measured(ix);

        errorOK = all( ...
            abs(e-loggedError(ix))<=0.002);

        % Next command from burst k must be applied
        % to the immediately following burst.
        indexingOK = all( ...
            next(ix(1:end-1))== ...
            applied(ix(2:end)));

        interval_ms = 1000*diff(time(ix));

        timingOK = all(interval_ms>0 & ...
            interval_ms<=1000*maxGap_s);

    end

    % Identify major current collapses.
    collapseEvents = 0;
    largeSteps = 0;

    if numel(ix)>=2

        y = measured(ix);
        u = applied(ix);

        collapseEvents = nnz( ...
            diff(y)<-collapseFlag_mA);

        largeSteps = nnz( ...
            abs(diff(u))>largeCounterStep);

    end

    % A collapse requires manual review.
    % It is not automatically classified as a
    % fault merely because it is large.
    eligible = ...
        ~observedFault && ...
        ~observedLimit && ...
        ~wrongMode && ...
        ~invalidRunning && ...
        timeOK && burstOK && ...
        errorOK && indexingOK && timingOK && ...
        collapseEvents==0 && ...
        isfinite(activeDuration) && ...
        activeDuration>=minimumDuration_s;

    if eligible
        decision(valid) = "ACCEPTED";
    else
        decision(valid) = "QUARANTINED_RUN";
    end

    %% File audit

    issues = strings(0,1);

    if observedFault
        issues(end+1) = "FAULT";
    end

    if observedLimit
        issues(end+1) = "SOFTWARE_LIMIT";
    end

    if wrongMode
        issues(end+1) = "WRONG_MODE";
    end

    if invalidRunning
        issues(end+1) = "INVALID_RUNNING_ROWS";
    end

    if ~timeOK
        issues(end+1) = "TIMESTAMP";
    end

    if ~burstOK
        issues(end+1) = "BURST_INDEX";
    end

    if ~errorOK
        issues(end+1) = "ERROR_MISMATCH";
    end

    if ~indexingOK
        issues(end+1) = "NEXT_COMMAND_MISMATCH";
    end

    if ~timingOK
        issues(end+1) = "TIMING_GAP";
    end

    if collapseEvents>0
        issues(end+1) = "CURRENT_COLLAPSE_REVIEW";
    end

    if activeDuration<minimumDuration_s
        issues(end+1) = "SHORT_RUN";
    end

    if isempty(issues)
        issueText = "NONE";
    else
        issueText = strjoin(issues,";");
    end

    cidx = find(controllers==info.Controller);

    auditRow = table( ...
        info.File, ...
        string(info.Path), ...
        info.Load, ...
        info.Controller, ...
        info.Trial, ...
        Kp(cidx),Ki(cidx), ...
        N,nnz(running),nnz(valid), ...
        activeDuration, ...
        observedFault,observedLimit, ...
        collapseEvents,largeSteps, ...
        timeOK,burstOK,errorOK,indexingOK, ...
        eligible,issueText, ...
        'VariableNames',{ ...
        'File','SourcePath','Load_Ohm', ...
        'Controller','Trial', ...
        'ExpectedKp','ExpectedKi', ...
        'TotalRows','RunningRows','ValidRows', ...
        'ActiveDuration_s','AnyFault','AnyLimit', ...
        'CollapseEvents','LargeCounterSteps', ...
        'TimeOK','BurstOK','ErrorOK', ...
        'IndexingOK','Eligible','Issues'});

    fileAudit = [fileAudit;auditRow]; %#ok<AGROW>

    %% Preserve rejected row decisions

    trialDir = fullfile(outDir, ...
        sprintf('R%04d',info.Load), ...
        char(info.Controller), ...
        sprintf('T%02d',info.Trial));

    if ~isfolder(trialDir)
        mkdir(trialDir);
    end

    rowAudit = table( ...
        (1:N)',time,burst,state,mode,fault, ...
        measured,target,applied,next, ...
        commandLimit,referenceLimit, ...
        valid,decision, ...
        'VariableNames',{ ...
        'OriginalRow','Time_s','Burst','State', ...
        'Mode','Fault','Measured_mA', ...
        'Target_mA','CounterApplied', ...
        'CounterNext','CommandLimited', ...
        'ReferenceLimited','InitiallyValid', ...
        'FinalDecision'});

    writetable(rowAudit, ...
        fullfile(trialDir,'RowAudit.csv'));

    if ~eligible

        anomalyRegister = [anomalyRegister;table( ...
            info.File,info.Load,info.Controller, ...
            info.Trial,issueText, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Controller', ...
            'Trial','Reason'})]; %#ok<AGROW>

        fprintf('%s: QUARANTINED (%s)\n', ...
            info.File,issueText);

        continue;
    end

    %% Qualified trajectory

    t = time(ix)-time(ix(1));
    y = measured(ix);
    e = target(ix)-y;

    u = applied(ix);
    un = next(ix);

    P = pTerm(ix);
    I = iTerm(ix);

    observedDt = diff(t);

    assert(all(observedDt>0), ...
        'Invalid elapsed timestamps.');

    % Time-weight each burst by the interval until
    % the next burst. Estimate the final duration
    % using the median observed interval.
    finalDt = median(observedDt);

    weights = [observedDt;finalDt];

    %% Performance windows

    full = true(numel(t),1);
    early10 = t<earlyWindow_s;
    early30 = t<transientWindow_s;
    steady = t>=t(end)-steadyWindow_s;

    MF = calcMetrics(e,u,t,weights,full,maxGap_s);
    M10 = calcMetrics(e,u,t,weights,early10,maxGap_s);
    M30 = calcMetrics(e,u,t,weights,early30,maxGap_s);
    MS = calcMetrics(e,u,t,weights,steady,maxGap_s);

    %% Trial metrics

    trialRow = table( ...
        info.File,info.Load,info.Controller, ...
        info.Trial, ...
        y(1),e(1),u(1), ...
        t(end), ...
        MF.RMSE,M10.RMSE,M30.RMSE,MS.RMSE, ...
        M10.IAE,M30.IAE, ...
        MS.Bias,abs(MS.Bias), ...
        MS.MAE,MS.CurrentSD, ...
        MS.Within030,MS.Within050, ...
        MS.Within100,MS.Within200, ...
        MF.SwitchRate,M10.SwitchRate, ...
        M30.SwitchRate,MS.SwitchRate, ...
        MF.Movement,MS.Movement, ...
        MS.CounterMode,u(end), ...
        'VariableNames',{ ...
        'File','Load_Ohm','Controller','Trial', ...
        'InitialCurrent_mA','InitialError_mA', ...
        'InitialCounter','Duration_s', ...
        'FullRMSE_mA','Early10RMSE_mA', ...
        'Early30RMSE_mA','SteadyRMSE_mA', ...
        'Early10IAE_mAs','Early30IAE_mAs', ...
        'SteadyBias_mA','SteadyAbsBias_mA', ...
        'SteadyMAE_mA','SteadyCurrentSD_mA', ...
        'Within030','Within050', ...
        'Within100','Within200', ...
        'FullSwitchRate','Early10SwitchRate', ...
        'Early30SwitchRate','SteadySwitchRate', ...
        'FullDACMovement','SteadyDACMovement', ...
        'MostCommonCounter','FinalCounter'});

    trialMetrics = [trialMetrics;trialRow]; %#ok<AGROW>

    %% Transient metrics

    firstChange = find(diff(u)~=0,1,'first');

    timeFirstCorrection = NaN;

    if ~isempty(firstChange)
        timeFirstCorrection = t(firstChange+1);
    end

    transientMetrics = [transientMetrics;table( ...
        info.File,info.Load,info.Controller, ...
        info.Trial,e(1), ...
        timeFirstCorrection, ...
        max(y-10),max(10-y), ...
        max(abs(e)), ...
        M10.Switches,M30.Switches, ...
        M10.RMSE,M30.RMSE, ...
        'VariableNames',{ ...
        'File','Load_Ohm','Controller','Trial', ...
        'InitialError_mA', ...
        'FirstCorrection_s', ...
        'MaximumOvershoot_mA', ...
        'MaximumUndershoot_mA', ...
        'PeakAbsoluteError_mA', ...
        'Early10Switches','Early30Switches', ...
        'Early10RMSE_mA','Early30RMSE_mA'})]; ...
        %#ok<AGROW>

    %% Settling metrics

    for band = accuracyBands

        firstEntry = firstBandEntry(t,e,band);
        sustained = sustainedBandEntry(t,e,band,2);
        permanent = permanentBandEntry(t,e,band);

        settlingSummary = [settlingSummary;table( ...
            info.File,info.Load,info.Controller, ...
            info.Trial,band, ...
            firstEntry,sustained,permanent, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Controller','Trial', ...
            'Band_mA','FirstEntry_s', ...
            'Hold2s_s','Permanent_s'})]; %#ok<AGROW>

    end

    %% DAC activity by evaluation window

    labels = ["Full","Early10","Early30","Steady"];
    MM = {MF,M10,M30,MS};

    for k = 1:4

        M = MM{k};

        dacActivity = [dacActivity;table( ...
            info.File,info.Load,info.Controller, ...
            info.Trial,labels(k), ...
            M.Switches,M.SwitchRate,M.Movement, ...
            M.Up,M.Down,M.Reversals, ...
            M.CounterMode, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Controller','Trial', ...
            'Window','Changes','ChangesPer_s', ...
            'AbsoluteMovement','UpwardChanges', ...
            'DownwardChanges','Reversals', ...
            'MostCommonCounter'})]; %#ok<AGROW>

    end

    %% Counter occupancy, steady interval

    us = u(steady);
    ws = weights(steady);

    for code = unique(us(:))'

        fraction = sum(ws(us==code))/sum(ws);

        dacOccupancy = [dacOccupancy;table( ...
            info.File,info.Load,info.Controller, ...
            info.Trial,code,fraction, ...
            'VariableNames',{ ...
            'File','Load_Ohm','Controller','Trial', ...
            'Counter','Occupancy'})]; %#ok<AGROW>

    end

    %% Save trajectory

    q = numel(trajectories)+1;

    trajectories(q).File = info.File;
    trajectories(q).Load_Ohm = info.Load;
    trajectories(q).Controller = info.Controller;
    trajectories(q).Trial = info.Trial;

    trajectories(q).Time_s = t;
    trajectories(q).Current_mA = y;
    trajectories(q).Error_mA = e;

    trajectories(q).AppliedCounter = u;
    trajectories(q).NextCounter = un;

    trajectories(q).PTerm = P;
    trajectories(q).ITerm = I;

    trajectories(q).Burst = burst(ix);
    trajectories(q).Dt_ms = dt(ix);

    processed = table( ...
        t,y,e,u,un,P,I,burst(ix),dt(ix), ...
        'VariableNames',{ ...
        'Time_s','Measured_mA','Error_mA', ...
        'CounterApplied','CounterNext', ...
        'PTerm','ITerm','Burst','Dt_ms'});

    writetable(processed, ...
        fullfile(trialDir,'QualifiedTrajectory.csv'));

    fprintf('%s: accepted, %.2f seconds\n', ...
        info.File,t(end));

end

%% Save results

writetable(fileAudit,fullfile( ...
    outDir,'E03_FileAudit.csv'));

writetable(anomalyRegister,fullfile( ...
    outDir,'E03_AnomalyRegister.csv'));

assert(~isempty(trialMetrics), ...
    'No qualified E03 trials.');

writetable(trialMetrics,fullfile( ...
    outDir,'E03_TrialMetrics.csv'));

writetable(transientMetrics,fullfile( ...
    outDir,'E03_TransientMetrics.csv'));

writetable(settlingSummary,fullfile( ...
    outDir,'E03_SettlingSummary.csv'));

writetable(dacActivity,fullfile( ...
    outDir,'E03_DACActivity.csv'));

writetable(dacOccupancy,fullfile( ...
    outDir,'E03_DACOccupancy.csv'));

%% Condition summary

conditionSummary = groupsummary( ...
    trialMetrics, ...
    {'Load_Ohm','Controller'}, ...
    {'mean','std'}, ...
    {'InitialError_mA', ...
     'Early10RMSE_mA', ...
     'Early30RMSE_mA', ...
     'FullRMSE_mA', ...
     'SteadyRMSE_mA', ...
     'SteadyBias_mA', ...
     'SteadySwitchRate', ...
     'Within030'});

writetable(conditionSummary,fullfile( ...
    outDir,'E03_ConditionSummary.csv'));

%% Verify accepted trial counts and occupancy

for R = unique(trialMetrics.Load_Ohm)'

    for C = controllers

        n = nnz( ...
            trialMetrics.Load_Ohm==R & ...
            trialMetrics.Controller==C);

        fprintf('R=%d, %s: %d trials\n',R,C,n);

    end
end

for k = 1:height(trialMetrics)

    ix = dacOccupancy.File==trialMetrics.File(k);

    assert(abs(sum(dacOccupancy.Occupancy(ix))-1)<1e-8, ...
        'DAC occupancy sum mismatch.');

end

assert(all(trialMetrics.Early10RMSE_mA>=0));
assert(all(trialMetrics.Early30RMSE_mA>=0));
assert(all(trialMetrics.SteadyRMSE_mA>=0));

assert(all(trialMetrics.Within030>=0 & ...
    trialMetrics.Within030<=1));

%% Save raw numerical archive

save(fullfile(outDir,'E03_ProcessedResults.mat'), ...
    'fileAudit','trialMetrics', ...
    'conditionSummary','transientMetrics', ...
    'settlingSummary','dacActivity', ...
    'dacOccupancy','anomalyRegister', ...
    'trajectories','Kp','Ki', ...
    'reference_mA','deadband_mA','-v7.3');

fid = fopen(fullfile(outDir, ...
    'E03_AnalysisVerification.txt'),'w');

assert(fid>0,'Cannot create verification log.');

fprintf(fid,'E03 PI HARDWARE VALIDATION\n');
fprintf(fid,'MATLAB: %s\n',version);
fprintf(fid,'Files discovered: %d\n',numel(entries));
fprintf(fid,'Eligible files: %d\n',height(trialMetrics));
fprintf(fid,'Quarantined: %d\n', ...
    nnz(~fileAudit.Eligible));

fprintf(fid,'Row, timing, indexing and error checks executed.\n');
fprintf(fid,'DAC occupancy checks executed.\n');
fprintf(fid, ...
    'Numerical Ki settings not independently verified.\n');

fclose(fid);

fprintf('\nE03 ANALYSIS COMPLETE\n');
disp(conditionSummary);

%% ============================================================
% Local helper functions
% ============================================================

function x = asNumeric(v)

    if isnumeric(v) || islogical(v)
        x = double(v(:));
    else
        x = str2double(string(v(:)));
    end

end

function M = calcMetrics(e,u,t,w,mask,maxGap)

    ix = find(mask);

    assert(numel(ix)>=2, ...
        'Insufficient observations in analysis window.');

    ee = e(ix);
    uu = u(ix);
    tt = t(ix);
    ww = w(ix);

    W = sum(ww);

    assert(W>0);

    M.Duration = W;

    M.Bias = sum(ww.*ee)/W;
    M.MAE = sum(ww.*abs(ee))/W;
    M.RMSE = sqrt(sum(ww.*ee.^2)/W);

    M.CurrentSD = std(ee);

    M.IAE = sum(ww.*abs(ee));
    M.ISE = sum(ww.*ee.^2);

    M.Within030 = sum(ww(abs(ee)<=0.030))/W;
    M.Within050 = sum(ww(abs(ee)<=0.050))/W;
    M.Within100 = sum(ww(abs(ee)<=0.100))/W;
    M.Within200 = sum(ww(abs(ee)<=0.200))/W;

    du = diff(uu);
    deltaTime = diff(tt);

    adjacent = ...
        diff(ix)==1 & ...
        deltaTime>0 & ...
        deltaTime<=maxGap;

    movement = du(adjacent);

    M.Switches = nnz(movement~=0);
    M.SwitchRate = M.Switches/W;

    M.Movement = sum(abs(movement));

    M.Up = nnz(movement>0);
    M.Down = nnz(movement<0);

    nonzero = movement(movement~=0);

    if numel(nonzero)>1
        M.Reversals = nnz( ...
            sign(nonzero(2:end))~= ...
            sign(nonzero(1:end-1)));
    else
        M.Reversals = 0;
    end

    codes = unique(uu);

    occupancy = zeros(numel(codes),1);

    for k = 1:numel(codes)
        occupancy(k) = sum(ww(uu==codes(k)));
    end

    [~,winner] = max(occupancy);
    M.CounterMode = codes(winner);

    assert(M.Movement>=M.Switches);

end

function value = firstBandEntry(t,e,band)

    ix = find(abs(e)<=band,1,'first');

    if isempty(ix)
        value = NaN;
    else
        value = t(ix);
    end

end

function value = sustainedBandEntry(t,e,band,seconds)

    value = NaN;

    for k = 1:numel(t)

        q = find(t>=t(k)+seconds,1,'first');

        if isempty(q)
            break;
        end

        if all(abs(e(k:q))<=band)
            value = t(k);
            return;
        end

    end

end

function value = permanentBandEntry(t,e,band)

    value = NaN;

    lastOutside = find(abs(e)>band,1,'last');

    if isempty(lastOutside)
        value = t(1);
    elseif lastOutside<numel(t)-1
        value = t(lastOutside+1);
    end

end
