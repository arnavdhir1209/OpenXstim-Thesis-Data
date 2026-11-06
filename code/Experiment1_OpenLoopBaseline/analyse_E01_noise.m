
%% analyse_E01_noise.m
% ==============================================================
% OpenXstim v1.3: E01 Final Open-Loop Noise Characterisation
% MATLAB R2025a
%
% INPUT:
%   E01_Rxxxx_OL_Txx.csv in the same directory as this script
%
% OUTPUT:
%   E01_Noise_Results/Run_yyyymmdd_HHMMSS/
%
% All primary statistics use actual, unfiltered burst-averaged
% current measurements, after explicit operating-state qualification.
%
% Residuals are centred independently by contiguous, qualified
% fixed-command segment. No smoothing or detrending is applied.
%
% No firmware, Simulink models, or source CSVs are modified.
% ==============================================================

clearvars;
close all;
clc;

%% 1. Configuration

scriptDir = fileparts(mfilename('fullpath'));

if isempty(scriptDir)
    error('Save this script as analyse_E01_noise.m before running.');
end

cfg = struct();

cfg.scriptDir = scriptDir;
cfg.resultsRoot = fullfile(scriptDir,'E01_Noise_Results');

cfg.reference_mA = 10;
cfg.appliedCounter = 215;
cfg.maximumRequest_mA = 15;
cfg.maximumCounter = 322;

cfg.expectedLoads = [100 220 560 1000 2000 4000];
cfg.expectedTrials = [1 2];

cfg.minSegmentSamples = 20;

% Startup is NOT removed unless an actual transition is detected.
cfg.startupDetectionBurstMax = 3;
cfg.startupDifference_mA = 0.20;
cfg.startupStableTolerance_mA = 0.15;
cfg.startupConsecutive = 4;

% Evidence-based anomaly review.
cfg.collapseFraction = 0.55;
cfg.collapseConsecutive = 2;
cfg.driftReview_mA = 0.030;

cfg.faultLookaheadRows = 4;
cfg.faultLookahead_s = 0.50;

cfg.maximumTimeGap_s = 0.50;
cfg.maxACFLag = 12;
cfg.movingWindow = 40;

cfg.thresholds = [ ...
    0.020 0.025 0.030 0.035 0.040 0.045 ...
    0.050 0.055 0.060 0.070 0.080 0.100];

cfg.nominalADCstep_mA = ...
    (4.883/(2^14-1))/10*1000;

cfg.csvIncrement_mA = 0.001;
cfg.nominalDACstep_mA = 0.0458338958;

cfg.figureDPI = 250;

% Every invocation gets a new archive.
if ~isfolder(cfg.resultsRoot)
    mkdir(cfg.resultsRoot);
end

runName = ['Run_' datestr(now,'yyyymmdd_HHMMSS')];
outDir = fullfile(cfg.resultsRoot,runName);

assert(~isfolder(outDir), ...
    'Results directory already exists; avoid overwriting.');

mkdir(outDir);

figDir = fullfile(outDir,'Figures');
mkdir(figDir);

%% 2. Discover E01 files

F = dir(fullfile(scriptDir,'E01_R*_OL_T*.csv'));

assert(~isempty(F),'No E01 files found beside the script.');

entries = table();

for k = 1:numel(F)

    filename = string(F(k).name);

    token = regexpi(char(filename), ...
        '^E01_R(\d+)_OL_T(\d+)\.csv$', ...
        'tokens','once');

    assert(~isempty(token), ...
        'Unrecognised E01 filename: %s',filename);

    resistance = str2double(token{1});
    trial = str2double(token{2});

    entries = [entries;table( ...
        filename, ...
        string(fullfile(F(k).folder,F(k).name)), ...
        resistance,trial, ...
        'VariableNames',{ ...
        'File','Path','Resistance_Ohm','Trial'})]; %#ok<AGROW>

end

entries = sortrows(entries,{'Resistance_Ohm','Trial'});

keys = entries.Resistance_Ohm + ...
    100000*entries.Trial;

assert(numel(unique(keys))==height(entries), ...
    'Duplicate resistance/trial identifiers.');

assert(height(entries)==12, ...
    'Expected 12 recordings; found %d.',height(entries));

for R = cfg.expectedLoads

    Q = entries(entries.Resistance_Ohm==R,:);

    assert(isequal(sort(Q.Trial)',cfg.expectedTrials), ...
        'Incomplete trial inventory at %d ohm.',R);

end

fprintf('\nE01 HARDWARE NOISE CHARACTERISATION\n');
fprintf('Recordings discovered: %d\n',height(entries));
fprintf('Output: %s\n',outDir);

%% 3. Initialise output tables with defined empty schemas

fileAudit = table();
trialSummary = table();
segmentSummary = table();
qualifiedResiduals = table();
temporalSummary = table();
thresholdSummary = table();

anomalyRegister = table( ...
    strings(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1), ...
    strings(0,1),strings(0,1),strings(0,1), ...
    'VariableNames',{ ...
    'File','Resistance_Ohm','Trial', ...
    'StartRow','EndRow', ...
    'Anomaly','Disposition','Explanation'});

globalSegmentID = 0;

%% 4. Process each recording

for f = 1:height(entries)

    filename = entries.File(f);
    resistance = entries.Resistance_Ohm(f);
    trial = entries.Trial(f);

    fprintf('\nProcessing %s\n',filename);

    T = readtable(char(entries.Path(f)), ...
        'VariableNamingRule','preserve');

    required = { ...
        'time_ms','burst','mode','stim_state', ...
        'requested_mA','effective_target_mA', ...
        'command_mA','measured_mA','error_mA', ...
        'counter_applied','counter_next', ...
        'p_term_counts','i_term_counts', ...
        'command_limited','reference_limited', ...
        'fault_code','dt_ms'};

    missing = setdiff(required,T.Properties.VariableNames);

    assert(isempty(missing), ...
        'Missing columns in %s: %s', ...
        filename,strjoin(missing,', '));

    N = height(T);

    time = toNumber(T.time_ms)/1000;
    burst = toNumber(T.burst);

    measured = toNumber(T.measured_mA);
    requested = toNumber(T.requested_mA);
    target = toNumber(T.effective_target_mA);
    command = toNumber(T.command_mA);

    applied = toNumber(T.counter_applied);
    next = toNumber(T.counter_next);
    loggedError = toNumber(T.error_mA);
    dt = toNumber(T.dt_ms);

    commandLimited = toNumber(T.command_limited);
    referenceLimited = toNumber(T.reference_limited);

    mode = upper(strtrim(string(T.mode)));
    state = upper(strtrim(string(T.stim_state)));
    fault = upper(strtrim(string(T.fault_code)));

    %% 4A. Row-level eligibility

    running = state=="RUNNING";
    openLoop = mode=="OPEN_LOOP";

    faultFree = ismember(fault, ...
        ["NONE","NO_FAULT","0"]);

    limitsOK = ...
        commandLimited==0 & ...
        referenceLimited==0;

    referenceOK = ...
        isfinite(requested) & ...
        isfinite(target) & ...
        abs(requested-cfg.reference_mA)<=0.001 & ...
        abs(target-cfg.reference_mA)<=0.001 & ...
        requested<=cfg.maximumRequest_mA;

    counterOK = ...
        isfinite(applied) & ...
        applied==cfg.appliedCounter & ...
        applied==round(applied) & ...
        isfinite(next) & ...
        next==cfg.appliedCounter;

    numericOK = ...
        isfinite(time) & ...
        isfinite(burst) & ...
        isfinite(measured) & ...
        measured>0 & ...
        isfinite(command) & ...
        isfinite(dt);

    valid = running & openLoop & faultFree & ...
        limitsOK & referenceOK & counterOK & numericOK;

    decision = repmat("VALID_CANDIDATE",N,1);

    decision(~running) = "NOT_RUNNING";
    decision(running & ~openLoop) = "NOT_OPEN_LOOP";
    decision(running & ~faultFree) = "FAULT";
    decision(running & faultFree & ~limitsOK) = ...
        "SOFTWARE_LIMITED";
    decision(running & faultFree & limitsOK & ...
        ~referenceOK) = "REFERENCE_MISMATCH";
    decision(running & faultFree & limitsOK & ...
        referenceOK & ~counterOK) = ...
        "COMMAND_MISMATCH";
    decision(running & faultFree & limitsOK & ...
        referenceOK & counterOK & ~numericOK) = ...
        "INVALID_MEASUREMENT";

    % No PI-controlled observation can enter E01.
    assert(~any(valid & ~openLoop));

    %% 4B. Build continuous constant-command segments

    % Invalid rows break segments.
    % Timestamp and burst discontinuities also break them.
    % No accepted temporal series may span those boundaries.

    segments = zeros(0,2);

    inside = false;
    first = 0;

    for k = 1:N

        if ~valid(k)

            if inside
                segments(end+1,:) = ...
                    [first k-1]; %#ok<SAGROW>
                inside = false;
            end

            continue;
        end

        if ~inside

            first = k;
            inside = true;

        else

            badTime = ...
                time(k)<=time(k-1) || ...
                time(k)-time(k-1)>cfg.maximumTimeGap_s;

            badBurst = burst(k)~=burst(k-1)+1;

            changedCounter = applied(k)~=applied(k-1);

            if badTime || badBurst || changedCounter

                segments(end+1,:) = ...
                    [first k-1]; %#ok<SAGROW>

                first = k;

            end

        end

    end

    if inside
        segments(end+1,:) = [first N];
    end

    acceptedInFile = 0;
    acceptedSegments = 0;

    %% 4C. Evaluate individual segments

    for s = 1:size(segments,1)

        a = segments(s,1);
        b = segments(s,2);

        ids = (a:b)';

        if numel(ids)<cfg.minSegmentSamples

            decision(ids) = "SHORT_SEGMENT";
            continue;

        end

        %% Detect a fault immediately after the segment

        preFault = false;

        for q = b+1:min(N,b+cfg.faultLookaheadRows)

            if valid(q)
                break;
            end

            faultEvent = ~faultFree(q) || ...
                contains(state(q),"FAULT");

            if ~faultEvent
                continue;
            end

            if isfinite(time(q)) && ...
                    time(q)>=time(b) && ...
                    time(q)-time(b)<=cfg.faultLookahead_s

                preFault = true;
                break;

            end

        end

        if preFault

            decision(ids) = "PRE_FAULT_SEGMENT";

            anomalyRegister = [anomalyRegister; ...
                anomalyRow(filename,resistance,trial, ...
                a,b,"FAULT_ASSOCIATED","EXCLUDED", ...
                "Continuous segment terminated immediately before recorded fault")]; ...
                %#ok<AGROW>

            continue;

        end

        %% Detect severe sustained current collapse

        values = measured(ids);
        referenceLevel = median(values);

        collapse = ...
            values<cfg.collapseFraction*referenceLevel;

        collapseDetected = false;

        if numel(collapse)>=cfg.collapseConsecutive

            for c = 1:numel(collapse)- ...
                    cfg.collapseConsecutive+1

                if all(collapse( ...
                        c:c+cfg.collapseConsecutive-1))

                    collapseDetected = true;
                    break;

                end

            end

        end

        if collapseDetected

            decision(ids) = "CURRENT_COLLAPSE_REVIEW";

            anomalyRegister = [anomalyRegister; ...
                anomalyRow(filename,resistance,trial, ...
                a,b,"SUSTAINED_COLLAPSE","QUARANTINED", ...
                "Multiple consecutive observations below configured fraction of segment median")]; ...
                %#ok<AGROW>

            continue;

        end

        %% Startup selection

        % Only assess startup when the actual burst
        % index indicates that recording begins at
        % the start of an experiment.
        %
        % No automatic exclusion for mid-operation files.

        firstAccepted = a;

        if burst(a)<=cfg.startupDetectionBurstMax

            tailCount = min(30,numel(ids));

            lateLevel = median( ...
                measured(ids(end-tailCount+1:end)));

            earlyCount = min(3,numel(ids));

            earlyLevel = median( ...
                measured(ids(1:earlyCount)));

            if abs(earlyLevel-lateLevel)> ...
                    cfg.startupDifference_mA

                candidate = NaN;

                for k = a:b-cfg.startupConsecutive+1

                    group = measured( ...
                        k:k+cfg.startupConsecutive-1);

                    if all(abs(group-lateLevel)<= ...
                            cfg.startupStableTolerance_mA)

                        candidate = k;
                        break;

                    end

                end

                if isnan(candidate)

                    decision(ids) = "STARTUP_REVIEW";

                    anomalyRegister = [anomalyRegister; ...
                        anomalyRow(filename,resistance,trial, ...
                        a,b,"STARTUP_NOT_STABLE","QUARANTINED", ...
                        "No stable startup transition could be identified")]; ...
                        %#ok<AGROW>

                    continue;

                end

                firstAccepted = candidate;

                if firstAccepted>a

                    decision(a:firstAccepted-1) = ...
                        "OBSERVED_STARTUP_TRANSIENT";

                    anomalyRegister = [anomalyRegister; ...
                        anomalyRow(filename,resistance,trial, ...
                        a,firstAccepted-1, ...
                        "STARTUP_TRANSIENT","EXCLUDED", ...
                        "Observed initial transition toward later steady operating level")]; ...
                        %#ok<AGROW>

                end

            end

        end

        idx = (firstAccepted:b)';

        if numel(idx)<cfg.minSegmentSamples

            decision(idx) = "SHORT_STABLE_SEGMENT";
            continue;

        end

        %% Primary residual definition

        y = measured(idx);

        mu = mean(y);
        med = median(y);
        residual = y-mu;

        assert(abs(mean(residual))<1e-10, ...
            'Residual centring failed.');

        elapsed = time(idx)-time(idx(1));

        duration = elapsed(end);

        driftCoefficients = polyfit(elapsed,y,1);

        driftSlope = driftCoefficients(1);
        driftTotal = driftSlope*duration;

        driftFlag = abs(driftTotal)>cfg.driftReview_mA;

        if driftFlag

            anomalyRegister = [anomalyRegister; ...
                anomalyRow(filename,resistance,trial, ...
                idx(1),idx(end), ...
                "DRIFT_REVIEW","RETAINED_FLAGGED", ...
                "Fitted current drift exceeds configured review threshold")]; ...
                %#ok<AGROW>

        end

        %% Per-segment descriptive statistics

        sd = std(y,0);
        rmsResidual = sqrt(mean(residual.^2));

        madMedian = median(abs(y-med));
        iqrValue = percentile(y,75)-percentile(y,25);

        absResidual = abs(residual);

        q = percentile(residual, ...
            [1 5 25 50 75 95 99]);

        qAbs = percentile(absResidual,[90 95 99]);

        standardizedSkew = NaN;
        excessKurtosis = NaN;

        central = y-mu;

        if std(central,1)>0

            sigmaPop = std(central,1);

            standardizedSkew = ...
                mean(central.^3)/sigmaPop^3;

            excessKurtosis = ...
                mean(central.^4)/sigmaPop^4-3;

        end

        lag1 = lagCorrelation(residual,1);

        globalSegmentID = globalSegmentID+1;
        segmentID = globalSegmentID;

        decision(idx) = "ACCEPTED";

        acceptedInFile = acceptedInFile+numel(idx);
        acceptedSegments = acceptedSegments+1;

        segmentRow = table( ...
            segmentID,filename,resistance,trial, ...
            applied(a),a,b,idx(1),idx(end), ...
            numel(idx),duration, ...
            mu,med,mu-cfg.reference_mA, ...
            sd,rmsResidual, ...
            min(y),max(y),max(y)-min(y), ...
            madMedian,iqrValue, ...
            standardizedSkew,excessKurtosis, ...
            min(residual),max(residual), ...
            max(absResidual), ...
            q(1),q(2),q(3),q(4), ...
            q(5),q(6),q(7), ...
            qAbs(1),qAbs(2),qAbs(3), ...
            driftSlope,driftTotal,driftFlag,lag1, ...
            'VariableNames',{ ...
            'SegmentID','File','Resistance_Ohm','Trial', ...
            'Counter','StartRow','EndRow', ...
            'FirstAcceptedRow','LastAcceptedRow', ...
            'Samples','Duration_s', ...
            'MeanCurrent_mA','MedianCurrent_mA', ...
            'MeanActualMinusTarget_mA', ...
            'SD_mA','ResidualRMS_mA', ...
            'MinCurrent_mA','MaxCurrent_mA','PeakPeak_mA', ...
            'MedianAbsoluteDeviation_mA','IQR_mA', ...
            'Skewness','ExcessKurtosis', ...
            'MinResidual_mA','MaxResidual_mA', ...
            'MaximumAbsResidual_mA', ...
            'ResidualP01_mA','ResidualP05_mA', ...
            'ResidualP25_mA','ResidualP50_mA', ...
            'ResidualP75_mA','ResidualP95_mA', ...
            'ResidualP99_mA', ...
            'AbsResidualP90_mA','AbsResidualP95_mA', ...
            'AbsResidualP99_mA', ...
            'DriftSlope_mA_per_s','TotalDrift_mA', ...
            'DriftFlag','Lag1ACF'});

        segmentSummary = [ ...
            segmentSummary;segmentRow]; %#ok<AGROW>

        %% Accepted residual archive

        residualRows = table( ...
            repmat(filename,numel(idx),1), ...
            repmat(resistance,numel(idx),1), ...
            repmat(trial,numel(idx),1), ...
            repmat(segmentID,numel(idx),1), ...
            idx,burst(idx),time(idx), ...
            time(idx)-time(idx(1)), ...
            dt(idx),applied(idx),y, ...
            repmat(mu,numel(idx),1),residual, ...
            'VariableNames',{ ...
            'File','Resistance_Ohm','Trial','SegmentID', ...
            'OriginalRow','Burst','Time_s','Elapsed_s', ...
            'Dt_ms','Counter','Measured_mA', ...
            'SegmentMean_mA','Residual_mA'});

        qualifiedResiduals = [ ...
            qualifiedResiduals;residualRows]; %#ok<AGROW>

        %% Temporal statistics without joining segments

        deltaTime = diff(time(idx));
        medianInterval_ms = 1000*median(deltaTime);

        irregularFraction = mean( ...
            abs(deltaTime-median(deltaTime))>0.020);

        phase80 = dt(idx)>=77 & dt(idx)<=83;
        phase93 = dt(idx)>=90 & dt(idx)<=96;

        mean80 = NaN;
        mean93 = NaN;

        if any(phase80)
            mean80 = mean(residual(phase80));
        end

        if any(phase93)
            mean93 = mean(residual(phase93));
        end

        even = mod(burst(idx),2)==0;
        odd = ~even;

        evenMean = NaN;
        oddMean = NaN;

        if any(even)
            evenMean = mean(residual(even));
        end

        if any(odd)
            oddMean = mean(residual(odd));
        end

        temporalRow = table( ...
            segmentID,filename,resistance,trial, ...
            medianInterval_ms,irregularFraction, ...
            mean80,mean93,mean93-mean80, ...
            evenMean,oddMean,evenMean-oddMean, ...
            driftSlope,driftTotal,lag1, ...
            'VariableNames',{ ...
            'SegmentID','File','Resistance_Ohm','Trial', ...
            'MedianInterval_ms','IrregularIntervalFraction', ...
            'MeanResidual80ms_mA', ...
            'MeanResidual93ms_mA', ...
            'Phase93Minus80_mA', ...
            'MeanEvenBurstResidual_mA', ...
            'MeanOddBurstResidual_mA', ...
            'EvenMinusOdd_mA', ...
            'DriftSlope_mA_per_s','TotalDrift_mA', ...
            'Lag1ACF'});

        temporalSummary = [ ...
            temporalSummary;temporalRow]; %#ok<AGROW>

        for lag = 1:cfg.maxACFLag

            acfRow = table( ...
                segmentID,filename,resistance,trial, ...
                lag,lagCorrelation(residual,lag), ...
                'VariableNames',{ ...
                'SegmentID','File','Resistance_Ohm', ...
                'Trial','Lag','ACF'});

            % Separate full autocorrelation archive.
            if ~exist('acfSummary','var')
                acfSummary = acfRow;
            else
                acfSummary = [acfSummary;acfRow]; %#ok<AGROW>
            end

        end

    end

    %% 4D. File audit and integrity checks

    assert(nnz(decision=="ACCEPTED")==acceptedInFile, ...
        'Accepted count mismatch in %s.',filename);

    assert(~any(decision=="ACCEPTED" & ~valid), ...
        'Invalid observation accepted in %s.',filename);

    assert(~any(decision=="ACCEPTED" & ...
        state~="RUNNING"), ...
        'Disabled observation accepted.');

    assert(~any(decision=="ACCEPTED" & ...
        applied~=cfg.appliedCounter), ...
        'Incorrect DAC Counter accepted.');

    trialFolder = fullfile(outDir, ...
        sprintf('R%04d',resistance), ...
        sprintf('T%02d',trial));

    if ~isfolder(trialFolder)
        mkdir(trialFolder);
    end

    rowAudit = table( ...
        (1:N)',burst,time,mode,state,fault, ...
        requested,target,command, ...
        measured,loggedError,applied,next, ...
        commandLimited,referenceLimited,dt, ...
        valid,decision, ...
        'VariableNames',{ ...
        'OriginalRow','Burst','Time_s','Mode', ...
        'StimState','Fault','Requested_mA', ...
        'EffectiveTarget_mA','Command_mA', ...
        'Measured_mA','LoggedError_mA', ...
        'CounterApplied','CounterNext', ...
        'CommandLimited','ReferenceLimited', ...
        'Dt_ms','InitialEligibility','FinalDecision'});

    writetable(rowAudit, ...
        fullfile(trialFolder,'E01_RowAudit.csv'));

    Q = qualifiedResiduals( ...
        qualifiedResiduals.File==filename,:);

    if ~isempty(Q)
        writetable(Q, ...
            fullfile(trialFolder,'E01_AcceptedResiduals.csv'));
    end

    if acceptedInFile>0

        meanCurrent = mean(Q.Measured_mA);
        trialResidualRMS = sqrt(mean(Q.Residual_mA.^2));
        trialResidualSD = std(Q.Residual_mA,0);

        trialRow = table( ...
            filename,resistance,trial, ...
            height(Q),meanCurrent, ...
            meanCurrent-cfg.reference_mA, ...
            trialResidualSD,trialResidualRMS, ...
            percentile(abs(Q.Residual_mA),95), ...
            mean(abs(Q.Residual_mA)>0.030), ...
            mean(abs(Q.Residual_mA)>0.045), ...
            mean(abs(Q.Residual_mA)>0.060), ...
            acceptedSegments, ...
            'VariableNames',{ ...
            'File','Resistance_Ohm','Trial', ...
            'AcceptedBursts','MeanCurrent_mA', ...
            'MeanActualMinusTarget_mA', ...
            'ResidualSD_mA','ResidualRMS_mA', ...
            'AbsResidualP95_mA', ...
            'Exceed030','Exceed045','Exceed060', ...
            'AcceptedSegments'});

        trialSummary = [ ...
            trialSummary;trialRow]; %#ok<AGROW>

    end

    auditRow = table( ...
        filename,resistance,trial,N, ...
        nnz(running),nnz(isfinite(measured)), ...
        acceptedInFile,N-acceptedInFile, ...
        size(segments,1),acceptedSegments, ...
        nnz(~faultFree), ...
        nnz(commandLimited~=0 | referenceLimited~=0), ...
        'VariableNames',{ ...
        'File','Resistance_Ohm','Trial','TotalRows', ...
        'RunningRows','FiniteMeasuredRows', ...
        'AcceptedRows','RejectedRows', ...
        'CandidateSegments','AcceptedSegments', ...
        'FaultRows','LimitedRows'});

    fileAudit = [fileAudit;auditRow]; %#ok<AGROW>

    fprintf('  Accepted: %d / %d observations\n', ...
        acceptedInFile,N);

end

%% 5. Global verification

assert(height(fileAudit)==12, ...
    'File audit does not contain 12 recordings.');

assert(~isempty(qualifiedResiduals), ...
    'No qualified residuals generated.');

assert(height(qualifiedResiduals)== ...
    sum(fileAudit.AcceptedRows), ...
    'Global accepted-residual count mismatch.');

keys = qualifiedResiduals.File + ":" + ...
    string(qualifiedResiduals.OriginalRow);

assert(numel(unique(keys))==height(qualifiedResiduals), ...
    'Duplicate residual source rows.');

for s = unique(qualifiedResiduals.SegmentID)'

    Q = qualifiedResiduals( ...
        qualifiedResiduals.SegmentID==s,:);

    assert(abs(mean(Q.Residual_mA))<1e-10, ...
        'Incorrect residual centring.');

    assert(numel(unique(Q.Counter))==1, ...
        'Multiple DAC Counters in one residual segment.');

    assert(all(diff(Q.Time_s)>0), ...
        'Nonmonotonic accepted segment timestamps.');

    assert(all(diff(Q.Burst)==1), ...
        'Discontinuous accepted burst indices.');

end

%% 6. Aggregate independently by resistance

loadSummary = table();
thresholdSummary = table();

for R = cfg.expectedLoads

    Q = qualifiedResiduals( ...
        qualifiedResiduals.Resistance_Ohm==R,:);

    V = trialSummary( ...
        trialSummary.Resistance_Ohm==R,:);

    assert(height(V)==2, ...
        'Two qualified trials required at %d ohm.',R);

    assert(~isempty(Q), ...
        'No qualified residuals at %d ohm.',R);

    pooledRMS = sqrt(mean(Q.Residual_mA.^2));

    trialMeans = V.MeanCurrent_mA;
    trialSDs = V.ResidualSD_mA;

    meanTrialCurrent = mean(trialMeans);
    betweenTrialSD = std(trialMeans,0);

    meanTrialSD = mean(trialSDs);
    betweenTrialNoiseSD = std(trialSDs,0);

    loadRow = table( ...
        R,height(V),height(Q), ...
        meanTrialCurrent,betweenTrialSD, ...
        abs(diff(trialMeans)), ...
        meanTrialSD,betweenTrialNoiseSD, ...
        pooledRMS, ...
        percentile(abs(Q.Residual_mA),90), ...
        percentile(abs(Q.Residual_mA),95), ...
        percentile(abs(Q.Residual_mA),99), ...
        mean(abs(Q.Residual_mA)>0.030), ...
        mean(abs(Q.Residual_mA)>0.045), ...
        mean(abs(Q.Residual_mA)>0.060), ...
        'VariableNames',{ ...
        'Resistance_Ohm','Trials','AcceptedBursts', ...
        'MeanOfTrialMeans_mA', ...
        'BetweenTrialMeanSD_mA', ...
        'DifferenceBetweenTrialMeans_mA', ...
        'MeanWithinTrialSD_mA', ...
        'BetweenTrialNoiseSD_mA', ...
        'PooledWithinTrialResidualRMS_mA', ...
        'AbsResidualP90_mA', ...
        'AbsResidualP95_mA', ...
        'AbsResidualP99_mA', ...
        'Exceed030','Exceed045','Exceed060'});

    loadSummary = [ ...
        loadSummary;loadRow]; %#ok<AGROW>

    for D = cfg.thresholds

        r = Q.Residual_mA;

        exceed = abs(r)>D;

        % Consecutive exceedance runs must be calculated
        % separately within each contiguous segment.
        longestRun = 0;
        numberRuns = 0;

        for sid = unique(Q.SegmentID)'

            W = Q(Q.SegmentID==sid,:);

            mask = abs(W.Residual_mA)>D;

            lengths = runLengths(mask);

            if ~isempty(lengths)

                longestRun = max( ...
                    longestRun,max(lengths));

                numberRuns = numberRuns+numel(lengths);

            end

        end

        thresholdRow = table( ...
            R,D,height(Q),nnz(exceed), ...
            mean(exceed),mean(~exceed), ...
            mean(r>D),mean(r< -D), ...
            longestRun,numberRuns, ...
            'VariableNames',{ ...
            'Resistance_Ohm','Deadband_mA', ...
            'Samples','ExceedCount', ...
            'ExceedProbability','WithinProbability', ...
            'PositiveExceedProbability', ...
            'NegativeExceedProbability', ...
            'LongestExceedRun', ...
            'NumberExceedRuns'});

        thresholdSummary = [ ...
            thresholdSummary;thresholdRow]; %#ok<AGROW>

        % Denominator verification.
        assert(thresholdRow.ExceedCount== ...
            nnz(abs(Q.Residual_mA)>D));

    end

    resistanceFolder = fullfile(outDir, ...
        sprintf('R%04d',R));

    writetable(V,fullfile(resistanceFolder, ...
        'TrialComparison.csv'));

end

%% 7. Reconciliation with historical checkpoints

% These values are comparison references only.
% They are never substituted for measured results.

historicalR = cfg.expectedLoads(:);

historicalMean = [ ...
    10.2737
    10.2548
    10.2014
    10.1180
    9.9427
    9.5939];

historicalRMS = [ ...
    0.058321
    0.054392
    0.050831
    0.048370
    0.045129
    0.048159];

reconciliation = table( ...
    historicalR, ...
    historicalMean, ...
    loadSummary.MeanOfTrialMeans_mA, ...
    loadSummary.MeanOfTrialMeans_mA-historicalMean, ...
    historicalRMS, ...
    loadSummary.PooledWithinTrialResidualRMS_mA, ...
    loadSummary.PooledWithinTrialResidualRMS_mA- ...
        historicalRMS, ...
    'VariableNames',{ ...
    'Resistance_Ohm', ...
    'PreviousMeanCurrent_mA', ...
    'NewMeanCurrent_mA', ...
    'DifferenceMean_mA', ...
    'PreviousResidualRMS_mA', ...
    'NewResidualRMS_mA', ...
    'DifferenceResidualRMS_mA'});

%% 8. Export numerical results

writetable(fileAudit,fullfile( ...
    outDir,'E01_FileAudit.csv'));

writetable(trialSummary,fullfile( ...
    outDir,'E01_TrialSummary.csv'));

writetable(segmentSummary,fullfile( ...
    outDir,'E01_SegmentSummary.csv'));

writetable(loadSummary,fullfile( ...
    outDir,'E01_LoadSummary.csv'));

writetable(qualifiedResiduals,fullfile( ...
    outDir,'E01_QualifiedResiduals.csv'));

writetable(thresholdSummary,fullfile( ...
    outDir,'E01_ThresholdExceedance.csv'));

writetable(temporalSummary,fullfile( ...
    outDir,'E01_TemporalSummary.csv'));

writetable(acfSummary,fullfile( ...
    outDir,'E01_Autocorrelation.csv'));

writetable(anomalyRegister,fullfile( ...
    outDir,'E01_AnomalyRegister.csv'));

writetable(reconciliation,fullfile( ...
    outDir,'E01_Reconciliation.csv'));

NoiseModels = struct();

NoiseModels.Residuals = qualifiedResiduals;
NoiseModels.TrialSummary = trialSummary;
NoiseModels.LoadSummary = loadSummary;
NoiseModels.SegmentSummary = segmentSummary;
NoiseModels.Thresholds = thresholdSummary;
NoiseModels.Selection = cfg;

save(fullfile(outDir,'E01_ProcessedResults.mat'), ...
    'NoiseModels','cfg','fileAudit','trialSummary', ...
    'segmentSummary','loadSummary', ...
    'qualifiedResiduals','thresholdSummary', ...
    'temporalSummary','acfSummary', ...
    'anomalyRegister','reconciliation','-v7.3');

%% 9. Figures

Rvalues = cfg.expectedLoads;

% Figure 1: Current time series
f1 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1100 950]);

tiledlayout(3,2,'TileSpacing','compact');

for j = 1:numel(Rvalues)

    nexttile;
    hold on;

    V = qualifiedResiduals( ...
        qualifiedResiduals.Resistance_Ohm==Rvalues(j),:);

    for tr = 1:2

        W = V(V.Trial==tr,:);

        plot(W.Time_s-W.Time_s(1),W.Measured_mA, ...
            '.','MarkerSize',5, ...
            'DisplayName',sprintf('T%02d',tr));

    end

    yline(cfg.reference_mA,'k:', ...
        'HandleVisibility','off');

    title(sprintf('%d ohm',Rvalues(j)));

    xlabel('Elapsed time (s)');
    ylabel('Measured current (mA)');

    grid on;
    legend('Location','best');

end

sgtitle('E01-1: Qualified Fixed-Command Current');

exportFigure(f1,figDir,'E01_Fig01_CurrentTime',cfg.figureDPI);

% Figure 2: Mean current versus resistance
f2 = figure('Visible','off','Color','w');

hold on;

for tr = 1:2

    V = trialSummary(trialSummary.Trial==tr,:);

    plot(V.Resistance_Ohm,V.MeanCurrent_mA,'o', ...
        'MarkerSize',7, ...
        'DisplayName',sprintf('Trial %d',tr));

end

errorbar(loadSummary.Resistance_Ohm, ...
    loadSummary.MeanOfTrialMeans_mA, ...
    loadSummary.BetweenTrialMeanSD_mA, ...
    'ks','LineWidth',1.3, ...
    'DisplayName','Mean and between-trial SD');

yline(cfg.reference_mA,'k:', ...
    'DisplayName','10 mA reference');

xlabel('Resistance (ohm)');
ylabel('Mean measured current (mA)');

title('E01-2: Load-Dependent Fixed-Command Current');

legend('Location','best');
grid on;

exportFigure(f2,figDir,'E01_Fig02_MeanCurrent',cfg.figureDPI);

% Figure 3: Trial SD and pooled residual RMS
f3 = figure('Visible','off','Color','w');

hold on;

for tr = 1:2

    V = trialSummary(trialSummary.Trial==tr,:);

    plot(V.Resistance_Ohm,V.ResidualSD_mA,'o', ...
        'MarkerSize',7, ...
        'DisplayName',sprintf('Trial %d SD',tr));

end

plot(loadSummary.Resistance_Ohm, ...
    loadSummary.PooledWithinTrialResidualRMS_mA, ...
    'ks','LineWidth',1.3, ...
    'DisplayName','Pooled within-trial residual RMS');

xlabel('Resistance (ohm)');
ylabel('Current variability (mA)');

title('E01-3: Burst-Level Variability by Load');

legend('Location','best');
grid on;

exportFigure(f3,figDir,'E01_Fig03_NoiseScale',cfg.figureDPI);

% Figure 4: Residual empirical CDFs
f4 = figure('Visible','off','Color','w');

hold on;

for R = Rvalues

    V = qualifiedResiduals( ...
        qualifiedResiduals.Resistance_Ohm==R,:);

    r = sort(V.Residual_mA);

    plot(r,(1:numel(r))'/numel(r), ...
        'LineWidth',1.4, ...
        'DisplayName',sprintf('%d ohm',R));

end

xlabel('Mean-centred measured-current residual (mA)');
ylabel('Empirical cumulative probability');

title('E01-4: Residual Distributions');

legend('Location','best');
grid on;

exportFigure(f4,figDir,'E01_Fig04_ResidualCDF',cfg.figureDPI);

% Figure 5: Threshold exceedance
f5 = figure('Visible','off','Color','w');

hold on;

for R = Rvalues

    V = thresholdSummary( ...
        thresholdSummary.Resistance_Ohm==R,:);

    plot(V.Deadband_mA,100*V.ExceedProbability, ...
        '-o','LineWidth',1.2, ...
        'DisplayName',sprintf('%d ohm',R));

end

xline(0.030,'k:','0.030');
xline(0.045,'k--','0.045');
xline(0.060,'k-.','0.060');

xlabel('Residual threshold (mA)');
ylabel('Absolute exceedance probability (%)');

title('E01-5: Empirical Deadband-Scale Exceedance');

legend('Location','best');
grid on;

exportFigure(f5,figDir,'E01_Fig05_Exceedance',cfg.figureDPI);

% Figure 6: Autocorrelation
f6 = figure('Visible','off','Color','w');

hold on;

for R = Rvalues

    A = acfSummary(acfSummary.Resistance_Ohm==R,:);

    meanACF = nan(cfg.maxACFLag,1);

    for lag = 1:cfg.maxACFLag

        z = A.ACF(A.Lag==lag);
        z = z(isfinite(z));

        if ~isempty(z)
            meanACF(lag) = mean(z);
        end

    end

    plot(1:cfg.maxACFLag,meanACF, ...
        '-o','LineWidth',1.2, ...
        'DisplayName',sprintf('%d ohm',R));

end

xlabel('Burst lag');
ylabel('Mean within-segment autocorrelation');

title('E01-6: Temporal Correlation');

legend('Location','best');
grid on;

exportFigure(f6,figDir,'E01_Fig06_ACF',cfg.figureDPI);

% Figure 7: Between-trial repeatability
f7 = figure('Visible','off','Color','w', ...
    'Position',[100 100 950 660]);

tiledlayout(2,1,'TileSpacing','compact');

nexttile;

bar(loadSummary.Resistance_Ohm, ...
    loadSummary.DifferenceBetweenTrialMeans_mA);

xlabel('Resistance (ohm)');
ylabel('|T02 mean - T01 mean| (mA)');

title('Difference Between Trial Means');
grid on;

nexttile;

bar(loadSummary.Resistance_Ohm, ...
    loadSummary.BetweenTrialNoiseSD_mA);

xlabel('Resistance (ohm)');
ylabel('Between-trial residual SD variation (mA)');

title('Variation of Within-Trial Noise SD');
grid on;

sgtitle('E01-7: Trial Repeatability');

exportFigure(f7,figDir,'E01_Fig07_Repeatability',cfg.figureDPI);

% Figure 8: Quantisation context
f8 = figure('Visible','off','Color','w');

hold on;

plot(loadSummary.Resistance_Ohm, ...
    loadSummary.PooledWithinTrialResidualRMS_mA, ...
    'ko','MarkerSize',7, ...
    'DisplayName','Measured residual RMS');

yline(cfg.nominalADCstep_mA,'k:', ...
    'DisplayName','Nominal raw ADC count');

yline(cfg.nominalDACstep_mA,'k--', ...
    'DisplayName','Historical nominal DAC count');

yline(cfg.csvIncrement_mA,'k-.', ...
    'DisplayName','CSV reporting increment');

xlabel('Resistance (ohm)');
ylabel('Current magnitude (mA)');

title('E01-8: Measurement and Actuation Resolution');

legend('Location','best');
grid on;

exportFigure(f8,figDir,'E01_Fig08_Resolution',cfg.figureDPI);

%% 10. Full human-readable TXT report

fid = fopen(fullfile(outDir, ...
    'E01_FullReport.txt'),'w');

assert(fid>0,'Cannot create TXT report.');

fprintf(fid,'E01 FINAL OPEN-LOOP NOISE ANALYSIS\n\n');
fprintf(fid,'Generated: %s\n',datestr(now));
fprintf(fid,'MATLAB version: %s\n\n',version);

fprintf(fid,'Number of recordings: %d\n',height(fileAudit));
fprintf(fid,'Qualified residual observations: %d\n\n', ...
    height(qualifiedResiduals));

fprintf(fid, ...
    ['Primary noise variable is burst-level measured ' ...
     'current minus its qualified segment mean.\n']);

fprintf(fid, ...
    ['It is not an isolated ADC noise measurement.\n\n']);

fprintf(fid, ...
    ['Load (ohm) | Mean current (mA) | Pooled RMS (mA) ' ...
     '| P(|r|>0.030) | P(|r|>0.045) | P(|r|>0.060)\n']);

for k = 1:height(loadSummary)

    V = loadSummary(k,:);

    fprintf(fid, ...
        '%d | %.6f | %.6f | %.6f | %.6f | %.6f\n', ...
        V.Resistance_Ohm, ...
        V.MeanOfTrialMeans_mA, ...
        V.PooledWithinTrialResidualRMS_mA, ...
        V.Exceed030,V.Exceed045,V.Exceed060);

end

fprintf(fid,'\nRECONCILIATION\n');

for k = 1:height(reconciliation)

    V = reconciliation(k,:);

    fprintf(fid, ...
        ['%d ohm: delta mean %.6f mA, ' ...
         'delta RMS %.6f mA\n'], ...
        V.Resistance_Ohm, ...
        V.DifferenceMean_mA, ...
        V.DifferenceResidualRMS_mA);

end

fprintf(fid,'\nANOMALIES\n');

if isempty(anomalyRegister)

    fprintf(fid,'No configured anomaly rules triggered.\n');

else

    for k = 1:height(anomalyRegister)

        fprintf(fid,'%s: %s, %s\n', ...
            char(anomalyRegister.File(k)), ...
            char(anomalyRegister.Anomaly(k)), ...
            char(anomalyRegister.Disposition(k)));

    end

end

fprintf(fid, ...
    ['\nExceedance probabilities are not ' ...
     'DAC switching probabilities.\n']);

fprintf(fid, ...
    ['Two trials per load provide limited evidence ' ...
     'about long-term repeatability.\n']);

fclose(fid);

%% 11. Markdown checkpoint

fid = fopen(fullfile(outDir, ...
    'E01_Final_Verification_and_Design_Checkpoint.md'),'w');

assert(fid>0,'Cannot create Markdown checkpoint.');

fprintf(fid,'# E01 Final Hardware Noise Characterisation\n\n');

fprintf(fid,'Generated: %s\n\n',datestr(now));

fprintf(fid,'## Experimental configuration\n\n');

fprintf(fid, ...
    ['OpenXstim v1.3, Arduino Uno R4, direct 10 ohm ' ...
     'current-sense resistor, 14-bit ADC, ' ...
     'fixed DAC Counter 215, nominal 10 mA reference.\n\n']);

fprintf(fid, ...
    ['Current is the firmware burst-averaged feedback ' ...
     'measurement. It is not independently calibrated ' ...
     'absolute current.\n\n']);

fprintf(fid,'## Qualification methodology\n\n');

fprintf(fid, ...
    ['OPEN_LOOP, RUNNING, fault-free, unrestricted ' ...
     'records were required. Applied Counter and ' ...
     'next Counter were required to equal 215. ' ...
     'Timestamps and burst indices were checked.\n\n']);

fprintf(fid, ...
    ['No automatic first-two-burst exclusion was used. ' ...
     'Startup observations were excluded only where ' ...
     'an observable initial transition was detected. ' ...
     'Fault-associated segments were excluded. ' ...
     'Severe sustained collapse was quarantined. ' ...
     'Drift was reported without detrending.\n\n']);

fprintf(fid,'## Final resistance comparison\n\n');

fprintf(fid, ...
    ['| Resistance (ohm) | Trials | Accepted bursts ' ...
     '| Mean current (mA) | Pooled residual RMS (mA) ' ...
     '| P(|r|>0.030) | P(|r|>0.045) | P(|r|>0.060) |\n']);

fprintf(fid,'|---:|---:|---:|---:|---:|---:|---:|---:|\n');

for k = 1:height(loadSummary)

    V = loadSummary(k,:);

    fprintf(fid, ...
        '| %d | %d | %d | %.6f | %.6f | %.4f | %.4f | %.4f |\n', ...
        V.Resistance_Ohm,V.Trials,V.AcceptedBursts, ...
        V.MeanOfTrialMeans_mA, ...
        V.PooledWithinTrialResidualRMS_mA, ...
        V.Exceed030,V.Exceed045,V.Exceed060);

end

fprintf(fid,'\n## Resolution interpretation\n\n');

fprintf(fid, ...
    '- Nominal raw ADC count: %.6f mA.\n', ...
    cfg.nominalADCstep_mA);

fprintf(fid, ...
    '- CSV reporting increment: %.6f mA.\n', ...
    cfg.csvIncrement_mA);

fprintf(fid, ...
    '- Historical nominal DAC sensitivity: %.9f mA/count.\n\n', ...
    cfg.nominalDACstep_mA);

fprintf(fid, ...
    ['These three quantities are not interchangeable. ' ...
     'Burst averaging changes numerical measurement ' ...
     'resolution but does not establish absolute accuracy.\n\n']);

fprintf(fid,'## Statistical treatment\n\n');

fprintf(fid, ...
    ['Each trial is retained as an experimental replicate. ' ...
     'Within-trial fluctuations and between-trial ' ...
     'differences are reported separately. ' ...
     'The primary residuals are neither smoothed ' ...
     'nor detrended.\n\n']);

fprintf(fid, ...
    ['Lag autocorrelation is calculated separately ' ...
     'within continuous qualified segments, never ' ...
     'across recording boundaries.\n\n']);

fprintf(fid,'## Interpretation\n\n');

fprintf(fid, ...
    ['The fixed-command mean current varies with ' ...
     'load resistance. Effective burst-level variability ' ...
     'is also load dependent, but only two recordings ' ...
     'are available at each resistance.\n\n']);

fprintf(fid, ...
    ['Exceedance of a residual threshold does not ' ...
     'imply an applied DAC command change. Closed-loop ' ...
     'controller activity depends on the PI state, ' ...
     'error, quantisation and command limits.\n\n']);

fprintf(fid, ...
    ['E01 can inform disturbance-scale assumptions ' ...
     'for E03 and E04, but cannot independently ' ...
     'establish the preferred feedback deadband.\n\n']);

fprintf(fid,'## Historical reconciliation\n\n');

fprintf(fid, ...
    ['Historical E01 results were obtained using ' ...
     'different sample-qualification rules. Differences ' ...
     'are documented in E01_Reconciliation.csv. ' ...
     'The historical values were not substituted ' ...
     'for the current measurements.\n\n']);

fprintf(fid,'## Recommended thesis figures\n\n');

fprintf(fid, ...
    ['Main thesis: Figures 2, 3, 5 and 7. ' ...
     'Appendix or supplementary: Figures 1, 4, 6 and 8.\n\n']);

fprintf(fid,'## Verification and limitations\n\n');

fprintf(fid, ...
    ['The MATLAB script checks file inventory, row eligibility, ' ...
     'constant DAC command, continuity, residual centring, ' ...
     'source-row uniqueness and aggregation dimensions.\n\n']);

fprintf(fid, ...
    ['All claims of successful MATLAB verification ' ...
     'are conditional on successful execution ' ...
     'of these assertions in MATLAB.\n\n']);

fprintf(fid, ...
    ['The firmware logs current to three decimal places. ' ...
     'No oscilloscope-synchronised current trace or ' ...
     'independent measurement reference is used.\n\n']);

fprintf(fid,'## Reproducibility inventory\n\n');

fprintf(fid,'MATLAB: %s\n\n',version);
fprintf(fid,'Script: analyse_E01_noise.m\n\n');

fprintf(fid, ...
    ['Inputs: the 12 original E01_Rxxxx_OL_Txx.csv files. ' ...
     'Outputs: trial summaries, load summaries, row audits, ' ...
     'residual archive, anomaly register, threshold tables, ' ...
     'temporal statistics, reconciliation and eight figures.\n']);

fclose(fid);

%% 12. Final checks and console summary

assert(height(loadSummary)==6);
assert(height(trialSummary)==12);

assert(all(fileAudit.AcceptedRows>=0));
assert(all(fileAudit.RejectedRows>=0));

assert(all( ...
    fileAudit.AcceptedRows+fileAudit.RejectedRows== ...
    fileAudit.TotalRows));

for R = cfg.expectedLoads

    Q = thresholdSummary( ...
        thresholdSummary.Resistance_Ohm==R,:);

    assert(height(Q)==numel(cfg.thresholds));

    assert(all(Q.ExceedProbability>=0 & ...
        Q.ExceedProbability<=1));

    assert(all(diff(Q.ExceedProbability)<=1e-12), ...
        'Exceedance probability must be nonincreasing.');

end

fprintf('\n========================================\n');
fprintf('E01 ANALYSIS COMPLETE\n');
fprintf('========================================\n');

disp(loadSummary);

fprintf('\nAccepted residuals: %d\n', ...
    height(qualifiedResiduals));

fprintf('Anomaly register entries: %d\n', ...
    height(anomalyRegister));

fprintf('\nResults saved in:\n%s\n',outDir);

%% ============================================================
% Local helper functions
% ============================================================

function x = toNumber(v)

    if isnumeric(v) || islogical(v)
        x = double(v(:));
    else
        x = str2double(string(v(:)));
    end

end

function p = percentile(x,percentages)

    % Toolbox-independent percentile calculation.
    % Linear interpolation of sorted observations.

    x = sort(x(isfinite(x)));
    p = nan(size(percentages));

    n = numel(x);

    if n==0
        return;
    end

    if n==1
        p(:) = x(1);
        return;
    end

    for k = 1:numel(percentages)

        position = 1+(n-1)*percentages(k)/100;

        lo = floor(position);
        hi = ceil(position);

        alpha = position-lo;

        p(k) = ...
            (1-alpha)*x(lo)+alpha*x(hi);

    end

end

function acf = lagCorrelation(x,lag)

    x = x(:);

    if numel(x)<=lag+2
        acf = NaN;
        return;
    end

    a = x(1:end-lag);
    b = x(1+lag:end);

    if std(a)==0 || std(b)==0
        acf = NaN;
        return;
    end

    a = a-mean(a);
    b = b-mean(b);

    acf = sum(a.*b)/sqrt(sum(a.^2)*sum(b.^2));

end

function lengths = runLengths(mask)

    mask = logical(mask(:));

    transitions = diff([false;mask;false]);

    starts = find(transitions==1);
    ends = find(transitions==-1)-1;

    lengths = ends-starts+1;

end

function row = anomalyRow(file,R,trial,a,b,kind,status,explanation)

    row = table( ...
        string(file),R,trial,a,b, ...
        string(kind),string(status),string(explanation), ...
        'VariableNames',{ ...
        'File','Resistance_Ohm','Trial', ...
        'StartRow','EndRow', ...
        'Anomaly','Disposition','Explanation'});

end

function exportFigure(fig,folder,name,dpi)

    pngPath = fullfile(folder,[name '.png']);
    pdfPath = fullfile(folder,[name '.pdf']);

    exportgraphics(fig,pngPath,'Resolution',dpi);

    exportgraphics(fig,pdfPath, ...
        'ContentType','vector');

    assert(isfile(pngPath));
    assert(isfile(pdfPath));

    close(fig);

end
