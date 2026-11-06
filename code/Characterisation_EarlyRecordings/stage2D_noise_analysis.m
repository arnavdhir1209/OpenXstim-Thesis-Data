
%% stage2D_noise_analysis.m
% OpenXstim: Stage 2D-N
% Fault-aware open-loop current variability characterisation
%
% Included datasets:
%   B1 2k 10mA.csv
%   B2 4k 10mA.csv
%   Open loop 1k.csv
%
% Excluded:
%   Open Loop DAC sweep 1k.csv
%
% Key features:
%   - Strict RUNNING/open-loop/fault-free filtering
%   - Constant-command operating segments
%   - Startup-transition exclusion
%   - Entire pre-CURRENT_LOSS segment exclusion
%   - Row-level and fault-event audit
%   - Residual distribution and temporal correlation
%   - Automated data-integrity checks
%
% No controller parameters, firmware, or previous
% simulation files are modified.

clearvars;
clc;

%% ============================================================
% 1. USER CONFIGURATION
% ============================================================

rootDir = pwd;

fileList = {
    'B1 2k 10mA.csv'
    'B2 4k 10mA.csv'
    'Open loop 1k.csv'
};

loads = [2000; 4000; 1000];

outDir = fullfile(rootDir,'NoiseAnalysis_Results');

if ~exist(outDir,'dir')
    mkdir(outDir);
end

% Minimum number of retained stable observations
minStableSamples = 20;

% Exclude the first two bursts after each valid segment begins
startupSkip = 2;

% Detect obvious initial current transitions
detectStartup = true;

% Startup detector settings
startupTolerance_mA = 0.20;
startupToleranceFraction = 0.08;
startupConsecutive = 3;
postTransitionSkip = 2;

% Fault association:
% Look for CURRENT_LOSS shortly after a RUNNING segment
faultLookAheadRows = 3;
maximumFaultDelay_s = 0.5;

% Residual thresholds
thresholds = [0.03 0.05 0.08];

% Temporal analysis
maxLag = 10;

% Drift flag, not an automatic exclusion
driftThreshold_mA = 0.03;

fprintf('\n========================================\n');
fprintf('STAGE 2D-N: FAULT-AWARE NOISE ANALYSIS\n');
fprintf('========================================\n');

fprintf('Included recordings: %d\n',numel(fileList));
fprintf('DAC sweep excluded: YES\n');
fprintf('Pre-CURRENT_LOSS exclusion: ENABLED\n');

%% ============================================================
% 2. INITIALISE OUTPUT TABLES
% ============================================================

recordingStats = table();
segmentStats = table();
residualTable = table();
rowAudit = table();
datasetAudit = table();

faultEventAudit = table( ...
    strings(0,1), ...
    zeros(0,1), ...
    zeros(0,1), ...
    zeros(0,1), ...
    zeros(0,1), ...
    zeros(0,1), ...
    zeros(0,1), ...
    strings(0,1), ...
    'VariableNames',{ ...
    'File', ...
    'SegmentStartRow', ...
    'SegmentEndRow', ...
    'FaultRow', ...
    'FaultTime_s', ...
    'Counter', ...
    'ExcludedRows', ...
    'Reason'});

globalSegmentID = 0;

%% ============================================================
% 3. PROCESS EACH RECORDING
% ============================================================

for f = 1:numel(fileList)

    requested = string(fileList{f});

    %% Resolve filename

    inputPath = fullfile(rootDir,char(requested));

    if ~isfile(inputPath)

        available = dir(fullfile(rootDir,'*.csv'));

        [~,requestedStem,~] = fileparts(char(requested));

        matches = strings(0,1);

        for q = 1:numel(available)

            [~,candidateStem,~] = ...
                fileparts(available(q).name);

            candidateStem = regexprep( ...
                candidateStem,'\s*\(\d+\)$','');

            if strcmpi(strtrim(candidateStem), ...
                    strtrim(requestedStem))

                matches(end+1,1) = string(fullfile( ...
                    available(q).folder, ...
                    available(q).name)); %#ok<SAGROW>

            end
        end

        if numel(matches)==1

            inputPath = char(matches(1));

        elseif isempty(matches)

            warning('Missing recording: %s',requested);
            continue;

        else

            warning('Ambiguous recording: %s',requested);
            continue;

        end

    end

    [~,name,ext] = fileparts(inputPath);

    fileName = string([name ext]);

    fprintf('\nProcessing: %s\n',fileName);

    %% Import CSV

    T = readtable(inputPath, ...
        'VariableNamingRule','preserve');

    N = height(T);
    cols = string(T.Properties.VariableNames);

    %% Identify columns

    currentName = findColumn(cols,{ ...
        'measured_mA', ...
        'measured_current_mA', ...
        'current_mA'});

    counterName = findColumn(cols,{ ...
        'counter_applied', ...
        'applied_counter', ...
        'dac_counter'});

    stateName = findColumn(cols,{ ...
        'stim_state'});

    modeName = findColumn(cols,{ ...
        'mode', ...
        'control_mode'});

    faultName = findColumn(cols,{ ...
        'fault_code', ...
        'fault'});

    timeName = findColumn(cols,{ ...
        'time_ms', ...
        'timestamp_ms', ...
        'time_s'});

    % Refuse to silently analyse unknown operating states.
    if currentName=="" || counterName=="" || stateName==""

        warning('Required columns missing in %s.',fileName);
        continue;

    end

    %% Extract numeric and state values

    current = asNumeric(T.(char(currentName)));
    counter = asNumeric(T.(char(counterName)));

    state = upper(strtrim( ...
        string(T.(char(stateName)))));

    if modeName~=""

        mode = upper(strtrim( ...
            string(T.(char(modeName)))));

    else

        mode = repmat("NOT_RECORDED",N,1);

        warning('%s: mode column unavailable.',fileName);

    end

    if faultName~=""

        fault = upper(strtrim( ...
            string(T.(char(faultName)))));

    else

        fault = repmat("UNKNOWN",N,1);

        warning('%s: fault column unavailable.',fileName);

    end

    if timeName~=""

        t = asNumeric(T.(char(timeName)));

        if contains(lower(timeName),'ms')
            t = t/1000;
        end

    else

        t = nan(N,1);

    end

    %% ========================================================
    % 4. STRICT VALIDITY FILTER
    % ========================================================

    finiteData = ...
        isfinite(current) & isfinite(counter);

    positiveCurrent = current>0;

    running = state=="RUNNING";

    %% Fault status

    if faultName~=""

        faultOK = ...
            fault=="NONE" | ...
            fault=="NO_FAULT" | ...
            fault=="0";

    else

        faultOK = true(N,1);

    end

    %% Open-loop mode

    if modeName~=""

        openLoop = ...
            mode=="OPEN_LOOP" | ...
            mode=="OPEN" | ...
            mode=="MANUAL" | ...
            mode=="FIXED";

    else

        % Dataset provenance supplied by experimenter.
        openLoop = true(N,1);

    end

    %% Combined validity

    valid = ...
        finiteData & ...
        positiveCurrent & ...
        running & ...
        faultOK & ...
        openLoop;

    %% Row-level initial decisions

    reason = repmat("VALID_CANDIDATE",N,1);

    reason(~openLoop) = "NOT_OPEN_LOOP";

    reason(openLoop & ~faultOK) = "FAULT";

    reason(openLoop & faultOK & ~running) = ...
        "NOT_RUNNING";

    reason(openLoop & faultOK & running & ...
        ~finiteData) = "INVALID_NUMERIC";

    reason(openLoop & faultOK & running & ...
        finiteData & ~positiveCurrent) = ...
        "NONPOSITIVE_CURRENT";

    %% ========================================================
    % 5. IDENTIFY CONTINUOUS OPERATING SEGMENTS
    % ========================================================

    % A segment terminates whenever:
    %   1. A row becomes invalid
    %   2. The applied Counter changes
    %   3. Time reverses or repeats
    %
    % Do not remove invalid rows before segmenting.

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

            commandChanged = ...
                counter(k)~=counter(k-1);

            invalidTime = false;

            if isfinite(t(k)) && isfinite(t(k-1))

                invalidTime = t(k)<=t(k-1);

            end

            if commandChanged || invalidTime

                segments(end+1,:) = ...
                    [first k-1]; %#ok<SAGROW>

                first = k;

            end

        end

    end

    if inside

        segments(end+1,:) = ...
            [first N]; %#ok<SAGROW>

    end

    fprintf('Total rows: %d\n',N);
    fprintf('Initially valid rows: %d\n',nnz(valid));
    fprintf('Candidate operating segments: %d\n', ...
        size(segments,1));

    acceptedSegments = 0;

    %% ========================================================
    % 6. PROCESS EACH SEGMENT
    % ========================================================

    for s = 1:size(segments,1)

        a = segments(s,1);
        b = segments(s,2);

        rawIdx = (a:b)';

        %% ----------------------------------------------------
        % 6A. PRE-CURRENT_LOSS EXCLUSION
        % -----------------------------------------------------

        % Check the small interval immediately after
        % the valid RUNNING segment.
        %
        % If CURRENT_LOSS is subsequently latched,
        % exclude the ENTIRE preceding segment.
        %
        % This catches the situation where the current
        % collapses while stim_state is still RUNNING
        % and fault_code still reads NONE.

        preFaultSegment = false;
        associatedFaultRow = NaN;

        if faultName~=""

            searchEnd = min(N,b+faultLookAheadRows);

            for q = b+1:searchEnd

                % Stop at the next valid operating segment.
                % Do not associate distant or unrelated faults.
                if valid(q)
                    break;
                end

                currentLoss = contains( ...
                    fault(q),"CURRENT_LOSS");

                if ~currentLoss
                    continue;
                end

                timeOK = true;

                if isfinite(t(b)) && isfinite(t(q))

                    delay = t(q)-t(b);

                    timeOK = ...
                        delay>=0 && ...
                        delay<=maximumFaultDelay_s;

                end

                if timeOK

                    preFaultSegment = true;
                    associatedFaultRow = q;
                    break;

                end

            end

        end

        if preFaultSegment

            % Exclude the entire continuous RUNNING
            % segment from normal variability statistics.

            reason(rawIdx) = "PRE_CURRENT_LOSS_SEGMENT";

            faultTime = NaN;

            if isfinite(t(associatedFaultRow))

                faultTime = t(associatedFaultRow);

            end

            faultRecord = table( ...
                fileName, ...
                a, ...
                b, ...
                associatedFaultRow, ...
                faultTime, ...
                counter(a), ...
                numel(rawIdx), ...
                "CURRENT_LOSS after RUNNING segment", ...
                'VariableNames',{ ...
                'File', ...
                'SegmentStartRow', ...
                'SegmentEndRow', ...
                'FaultRow', ...
                'FaultTime_s', ...
                'Counter', ...
                'ExcludedRows', ...
                'Reason'});

            faultEventAudit = [ ...
                faultEventAudit;faultRecord]; %#ok<AGROW>

            fprintf( ...
                ['EXCLUDED pre-fault segment: ' ...
                 'rows %d to %d; fault row %d\n'], ...
                a,b,associatedFaultRow);

            continue;

        end

        %% ----------------------------------------------------
        % 6B. MINIMUM SEGMENT LENGTH
        % -----------------------------------------------------

        if numel(rawIdx)< ...
                minStableSamples+startupSkip

            reason(rawIdx) = "SHORT_SEGMENT";
            continue;

        end

        %% ----------------------------------------------------
        % 6C. STARTUP GUARD
        % -----------------------------------------------------

        firstUsable = a+startupSkip;

        reason(a:firstUsable-1) = ...
            "STARTUP_GUARD";

        %% ----------------------------------------------------
        % 6D. INITIAL TRANSITION DETECTION
        % -----------------------------------------------------

        if detectStartup

            values = current(a:b);

            % Estimate a late operating level using
            % the final portion of the segment.
            tailN = min( ...
                30,max(5,floor(numel(values)/3)));

            stableReference = median( ...
                values(end-tailN+1:end));

            tolerance = max( ...
                startupTolerance_mA, ...
                startupToleranceFraction * ...
                abs(stableReference));

            foundStable = false;

            for k = firstUsable: ...
                    b-startupConsecutive+1

                candidate = current( ...
                    k:k+startupConsecutive-1);

                if all(abs(candidate-stableReference) ...
                        <=tolerance)

                    firstStable = k;
                    foundStable = true;
                    break;

                end

            end

            if ~foundStable

                reason(firstUsable:b) = ...
                    "NO_STABLE_START";

                continue;

            end

            % Only add the transition guard when a
            % startup transition has actually occurred.
            if firstStable>firstUsable

                reason(firstUsable:firstStable-1) = ...
                    "STARTUP_TRANSITION";

                firstUsable = min( ...
                    b+1, ...
                    firstStable+postTransitionSkip);

            end

        end

        %% ----------------------------------------------------
        % 6E. SELECT FINAL STABLE OBSERVATIONS
        % -----------------------------------------------------

        if firstUsable>b
            continue;
        end

        idx = (firstUsable:b)';

        if numel(idx)<minStableSamples

            reason(idx) = "SHORT_STABLE_SEGMENT";
            continue;

        end

        %% ----------------------------------------------------
        % 6F. COMPUTE VARIABILITY
        % -----------------------------------------------------

        y = current(idx);

        mu = mean(y);
        med = median(y);

        residual = y-mu;

        sd = std(residual,0);

        rmsResidual = sqrt(mean(residual.^2));

        scaledMAD = 1.4826* ...
            median(abs(y-med));

        pct = prctile(residual,[5 95]);

        %% Temporal autocorrelation

        acf = nan(maxLag,1);

        for lag = 1:maxLag

            if numel(residual)<=lag+2
                continue;
            end

            x1 = residual(1:end-lag);
            x2 = residual(1+lag:end);

            if std(x1)>0 && std(x2)>0

                RR = corrcoef(x1,x2);
                acf(lag) = RR(1,2);

            end

        end

        %% Drift indication

        % Preserve raw noise distribution.
        % Do not detrend accepted residuals.

        if all(isfinite(t(idx))) && ...
                all(diff(t(idx))>0)

            tx = t(idx)-t(idx(1));

        else

            tx = (0:numel(idx)-1)';

        end

        fitLine = polyfit(tx,y,1);

        estimatedDrift_mA = fitLine(1)* ...
            (tx(end)-tx(1));

        driftFlag = ...
            abs(estimatedDrift_mA)>driftThreshold_mA;

        %% Threshold exceedance rates

        exceed03 = mean(abs(residual)>thresholds(1));
        exceed05 = mean(abs(residual)>thresholds(2));
        exceed08 = mean(abs(residual)>thresholds(3));

        %% Record accepted segment

        globalSegmentID = globalSegmentID+1;
        acceptedSegments = acceptedSegments+1;

        segmentID = globalSegmentID;

        segmentRow = table( ...
            segmentID, ...
            fileName, ...
            loads(f), ...
            counter(a), ...
            a,b, ...
            numel(idx), ...
            mu,med,sd, ...
            rmsResidual,scaledMAD, ...
            pct(1),pct(2), ...
            min(residual),max(residual), ...
            max(residual)-min(residual), ...
            exceed03,exceed05,exceed08, ...
            acf(1), ...
            estimatedDrift_mA,driftFlag, ...
            'VariableNames',{ ...
            'SegmentID', ...
            'File', ...
            'Load_Ohm', ...
            'Counter', ...
            'OriginalStartRow', ...
            'OriginalEndRow', ...
            'Samples', ...
            'Mean_mA', ...
            'Median_mA', ...
            'SD_mA', ...
            'ResidualRMS_mA', ...
            'ScaledMAD_mA', ...
            'P05_mA', ...
            'P95_mA', ...
            'MinResidual_mA', ...
            'MaxResidual_mA', ...
            'PeakToPeak_mA', ...
            'Exceed03', ...
            'Exceed05', ...
            'Exceed08', ...
            'Lag1', ...
            'EstimatedDrift_mA', ...
            'DriftFlag'});

        segmentStats = [ ...
            segmentStats;segmentRow]; %#ok<AGROW>

        %% Preserve accepted residuals

        residualRow = table( ...
            repmat(segmentID,numel(idx),1), ...
            repmat(fileName,numel(idx),1), ...
            repmat(loads(f),numel(idx),1), ...
            repmat(counter(a),numel(idx),1), ...
            idx, ...
            t(idx), ...
            y, ...
            residual, ...
            'VariableNames',{ ...
            'SegmentID', ...
            'File', ...
            'Load_Ohm', ...
            'Counter', ...
            'OriginalRow', ...
            'Time_s', ...
            'Measured_mA', ...
            'Residual_mA'});

        residualTable = [ ...
            residualTable;residualRow]; %#ok<AGROW>

        reason(idx) = "ACCEPTED";

    end

    %% ========================================================
    % 7. BUILD FILE-LEVEL AUDIT
    % ========================================================

    thisRowAudit = table( ...
        repmat(fileName,N,1), ...
        (1:N)', ...
        t, ...
        state, ...
        mode, ...
        fault, ...
        counter, ...
        current, ...
        valid, ...
        reason, ...
        'VariableNames',{ ...
        'File', ...
        'OriginalRow', ...
        'Time_s', ...
        'StimState', ...
        'Mode', ...
        'Fault', ...
        'Counter', ...
        'Measured_mA', ...
        'InitialValidity', ...
        'FinalDecision'});

    rowAudit = [ ...
        rowAudit;thisRowAudit]; %#ok<AGROW>

    fileAudit = table( ...
        fileName, ...
        loads(f), ...
        N, ...
        nnz(running), ...
        nnz(faultOK), ...
        nnz(openLoop), ...
        nnz(valid), ...
        nnz(reason=="ACCEPTED"), ...
        acceptedSegments, ...
        'VariableNames',{ ...
        'File', ...
        'Load_Ohm', ...
        'TotalRows', ...
        'RunningRows', ...
        'FaultOKRows', ...
        'OpenLoopRows', ...
        'InitiallyValidRows', ...
        'AcceptedRows', ...
        'AcceptedSegments'});

    datasetAudit = [ ...
        datasetAudit;fileAudit]; %#ok<AGROW>

    fprintf('Accepted segments: %d\n',acceptedSegments);
    fprintf('Accepted observations: %d\n', ...
        nnz(reason=="ACCEPTED"));

end

%% ============================================================
% 8. EXPORT AUDIT TABLES
% ============================================================

writetable(datasetAudit, ...
    fullfile(outDir,'Noise_DatasetAudit.csv'));

writetable(rowAudit, ...
    fullfile(outDir,'Noise_RowAudit.csv'));

writetable(faultEventAudit, ...
    fullfile(outDir,'Noise_FaultEvents.csv'));

fprintf('\nPre-fault segments excluded: %d\n', ...
    height(faultEventAudit));

fprintf('Fault-associated observations excluded: %d\n', ...
    sum(faultEventAudit.ExcludedRows));

%% ============================================================
% 9. INTEGRITY VERIFICATION
% ============================================================

% A fault-associated observation must never
% enter the accepted noise residual model.

for k = 1:height(faultEventAudit)

    F = faultEventAudit(k,:);

    ix = ...
        residualTable.File==F.File & ...
        residualTable.OriginalRow>=F.SegmentStartRow & ...
        residualTable.OriginalRow<=F.SegmentEndRow;

    assert(~any(ix), ...
        'Pre-fault readings leaked into residual model.');

end

% Every accepted noise residual must correspond
% to an ACCEPTED row in the row-level audit.

for k = 1:height(residualTable)

    ix = ...
        rowAudit.File==residualTable.File(k) & ...
        rowAudit.OriginalRow== ...
        residualTable.OriginalRow(k);

    assert(nnz(ix)==1, ...
        'Residual source row missing or duplicated.');

    assert(rowAudit.FinalDecision(ix)=="ACCEPTED", ...
        'Rejected row entered residual model.');

end

fprintf('PASS: Residual-to-audit consistency.\n');
fprintf('PASS: No pre-fault segment observations accepted.\n');

% Optional check for the previously identified event.
% Run this only if this timestamp appears in the source
% recording being analysed.

knownTimes = [193.051 193.131];


% The row audit does not contain a load column,
% so use filename matching instead.

oneK = rowAudit( ...
    startsWith(lower(rowAudit.File),"open loop 1k"),:);

for k = 1:numel(knownTimes)

    ix = abs(oneK.Time_s-knownTimes(k))<0.002;

    if any(ix)

        assert(all( ...
            oneK.FinalDecision(ix)== ...
            "PRE_CURRENT_LOSS_SEGMENT"), ...
            'Known 1 kOhm collapse event not excluded.');

    end

end

%% ============================================================
% 10. SAVE ACCEPTED RESULTS
% ============================================================

assert(~isempty(segmentStats), ...
    ['No usable steady-state segments remain. ' ...
     'Inspect Noise_RowAudit.csv.']);

writetable(segmentStats, ...
    fullfile(outDir,'Noise_PerSegment.csv'));

writetable(residualTable, ...
    fullfile(outDir,'Noise_Residuals.csv'));

%% ============================================================
% 11. RECORDING-LEVEL STATISTICS
% ============================================================

files = unique(segmentStats.File,'stable');

for f = 1:numel(files)

    Q = segmentStats( ...
        segmentStats.File==files(f),:);

    R = residualTable( ...
        residualTable.File==files(f),:);

    pooledRMS = sqrt(mean(R.Residual_mA.^2));

    recordRow = table( ...
        files(f), ...
        Q.Load_Ohm(1), ...
        height(Q), ...
        height(R), ...
        mean(Q.Mean_mA), ...
        mean(Q.SD_mA), ...
        median(Q.SD_mA), ...
        pooledRMS, ...
        mean(abs(R.Residual_mA)>0.03), ...
        mean(abs(R.Residual_mA)>0.05), ...
        mean(abs(R.Residual_mA)>0.08), ...
        mean(Q.DriftFlag), ...
        'VariableNames',{ ...
        'File', ...
        'Load_Ohm', ...
        'Segments', ...
        'Samples', ...
        'MeanSegmentCurrent_mA', ...
        'MeanSegmentSD_mA', ...
        'MedianSegmentSD_mA', ...
        'PooledResidualRMS_mA', ...
        'Exceed03', ...
        'Exceed05', ...
        'Exceed08', ...
        'FractionDriftFlagged'});

    recordingStats = [ ...
        recordingStats;recordRow]; %#ok<AGROW>

end

writetable(recordingStats, ...
    fullfile(outDir,'Noise_PerRecording.csv'));

%% ============================================================
% 12. SAVE REUSABLE NOISE MODEL
% ============================================================

NoiseModels = struct();

NoiseModels.recordings = recordingStats;
NoiseModels.segments = segmentStats;
NoiseModels.residuals = residualTable;

NoiseModels.faultEvents = faultEventAudit;

NoiseModels.selection = ...
    'RUNNING open-loop stable segments excluding pre-CURRENT_LOSS';

NoiseModels.startupSkip = startupSkip;
NoiseModels.minStableSamples = minStableSamples;

NoiseModels.description = ...
    'Effective burst-level current variability';

save(fullfile(outDir,'Noise_ResidualModels.mat'), ...
    'NoiseModels','rowAudit','datasetAudit');

%% ============================================================
% 13. FIGURE N1: VARIABILITY BY RECORDING
% ============================================================

f1 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1000 550]);

hold on;

for f = 1:numel(files)

    Q = segmentStats( ...
        segmentStats.File==files(f),:);

    scatter( ...
        f*ones(height(Q),1), ...
        Q.SD_mA, ...
        45,'filled');

end

xticks(1:numel(files));
xticklabels(files);
xtickangle(15);

ylabel('Stable-segment current SD (mA)');
title('Valid Open-loop Current Variability');

grid on;
box on;

%% ============================================================
% 14. FIGURE N2: RESIDUAL DISTRIBUTIONS
% ============================================================

f2 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[110 110 1000 550]);

hold on;

for f = 1:numel(files)

    r = residualTable.Residual_mA( ...
        residualTable.File==files(f));

    [F,X] = ecdf(r);

    plot(X,F, ...
        'LineWidth',1.5, ...
        'DisplayName',char(files(f)));

end

for threshold = thresholds

    xline(threshold,'k:', ...
        'HandleVisibility','off');

    xline(-threshold,'k:', ...
        'HandleVisibility','off');

end

xlabel('Current residual (mA)');
ylabel('Empirical cumulative probability');
title('Accepted Open-loop Residual Distributions');

legend('Location','best');
grid on;
box on;

%% ============================================================
% 15. FIGURE N3: TEMPORAL BEHAVIOUR
% ============================================================

[~,idxLongest] = max(segmentStats.Samples);

chosenID = segmentStats.SegmentID(idxLongest);

Q = residualTable( ...
    residualTable.SegmentID==chosenID,:);

f3 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[120 100 1000 700]);

tiledlayout(2,1,'TileSpacing','compact');

nexttile;

if all(isfinite(Q.Time_s))

    tx = Q.Time_s-Q.Time_s(1);
    xlabelText = 'Elapsed time (s)';

else

    tx = (0:height(Q)-1)';
    xlabelText = 'Burst index';

end

plot(tx,Q.Residual_mA,'LineWidth',0.9);

yline(0,'k:');

xlabel(xlabelText);
ylabel('Residual (mA)');

title(sprintf('Accepted segment: %s', ...
    char(Q.File(1))));

grid on;

nexttile;

r = Q.Residual_mA;

acf = nan(maxLag,1);

for lag = 1:maxLag

    if numel(r)>lag+2

        x1 = r(1:end-lag);
        x2 = r(1+lag:end);

        if std(x1)>0 && std(x2)>0

            RR = corrcoef(x1,x2);
            acf(lag) = RR(1,2);

        end

    end

end

stem(1:maxLag,acf,'filled');

xlabel('Burst lag');
ylabel('Residual autocorrelation');
title('Temporal Correlation of Accepted Residuals');

grid on;

%% ============================================================
% 16. EXPORT THREE FIGURES
% ============================================================

figures = {f1,f2,f3};

figureNames = {
    'FigN1_NoiseByRecording.png'
    'FigN2_ResidualDistribution.png'
    'FigN3_TemporalBehaviour.png'
};

for k = 1:numel(figures)

    exportgraphics( ...
        figures{k}, ...
        fullfile(outDir,figureNames{k}), ...
        'Resolution',200);

    close(figures{k});

end

%% ============================================================
% 17. GENERATE MARKDOWN CHECKPOINT
% ============================================================

report = fullfile(outDir, ...
    'Stage2D_Noise_Characterisation.md');

fid = fopen(report,'w');

assert(fid>0, ...
    'Cannot create noise characterisation report.');

fprintf(fid, ...
    '# Stage 2D-N: Fault-aware Open-loop Noise Characterisation\n\n');

fprintf(fid, ...
    'Generated: %s\n\n', ...
    datestr(now,'yyyy-mm-dd HH:MM'));

fprintf(fid,'## Included recordings\n\n');

for f = 1:numel(fileList)

    fprintf(fid,'- %s\n',fileList{f});

end

fprintf(fid, ...
    '\nExcluded: Open Loop DAC sweep 1k.csv.\n\n');

fprintf(fid,'## Selection methodology\n\n');

fprintf(fid, ...
    ['Only RUNNING, open-loop, fault-free ' ...
     'constant-command observations were considered.\n\n']);

fprintf(fid, ...
    ['The complete RUNNING segment immediately before ' ...
     'a CURRENT_LOSS event was excluded from normal ' ...
     'noise estimation.\n\n']);

fprintf(fid, ...
    ['Fault-associated segments remain available in ' ...
     'Noise_FaultEvents.csv and Noise_RowAudit.csv.\n\n']);

fprintf(fid, ...
    ['Startup guard: %d bursts. ' ...
     'Minimum stable segment: %d bursts.\n\n'], ...
    startupSkip,minStableSamples);

fprintf(fid, ...
    ['Primary residuals were mean-centred by segment, ' ...
     'without automatic detrending or post-startup ' ...
     'statistical outlier removal.\n\n']);

fprintf(fid,'## Per-recording results\n\n');

fprintf(fid, ...
    '| Recording | Load (Ohm) | Segments | Samples | Residual RMS (mA) |\n');

fprintf(fid,'|---|---:|---:|---:|---:|\n');

for k = 1:height(recordingStats)

    Q = recordingStats(k,:);

    fprintf(fid, ...
        '| %s | %.0f | %d | %d | %.6f |\n', ...
        char(Q.File), ...
        Q.Load_Ohm, ...
        Q.Segments, ...
        Q.Samples, ...
        Q.PooledResidualRMS_mA);

end

fprintf(fid,'\n## Fault-event exclusions\n\n');

fprintf(fid, ...
    'Excluded pre-CURRENT_LOSS segments: %d\n\n', ...
    height(faultEventAudit));

fprintf(fid, ...
    'Excluded fault-associated rows: %d\n\n', ...
    sum(faultEventAudit.ExcludedRows));

fprintf(fid,'## Verification\n\n');

fprintf(fid, ...
    '- Pre-fault residual leakage check: passed.\n');

fprintf(fid, ...
    '- Accepted row/residual correspondence: passed.\n');

fprintf(fid, ...
    '- Constant-command eligibility: checked.\n');

fprintf(fid, ...
    '- Startup filtering: checked.\n\n');

fprintf(fid,'## Limitations\n\n');

fprintf(fid, ...
    ['Recorded current variability may include ' ...
     'real delivered-current fluctuations, ' ...
     'sensor noise, ADC noise and drift.\n\n']);

fprintf(fid, ...
    ['A CURRENT_LOSS association is based on ' ...
     'proximity to the recorded fault event. ' ...
     'It does not identify the physical cause.\n\n']);

fprintf(fid, ...
    ['Independent residual resampling should not be ' ...
     'assumed valid until temporal correlations ' ...
     'are evaluated.\n\n']);

fprintf(fid, ...
    ['No previous controller simulation or firmware ' ...
     'was modified.\n']);

fclose(fid);

%% ============================================================
% 18. FINAL CONSOLE SUMMARY
% ============================================================

fprintf('\n========================================\n');
fprintf('NOISE ANALYSIS COMPLETE\n');
fprintf('========================================\n');

disp(recordingStats);

fprintf('\nDataset audit:\n');
disp(datasetAudit);

fprintf('\nFault events:\n');
disp(faultEventAudit);

fprintf('\nResults saved in:\n%s\n',outDir);

%% ============================================================
% LOCAL HELPER FUNCTIONS
% ============================================================

function name = findColumn(cols,candidates)

    name = "";

    for k = 1:numel(candidates)

        ix = find(strcmpi( ...
            cols,string(candidates{k})),1);

        if ~isempty(ix)

            name = cols(ix);
            return;

        end

    end

end

function x = asNumeric(data)

    if isnumeric(data) || islogical(data)

        x = double(data(:));

    else

        x = str2double(string(data(:)));

    end

end
