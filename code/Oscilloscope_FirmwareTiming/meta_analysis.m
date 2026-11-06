
%% ========================================================================
% OPENXSTIM - MULTI-CAPTURE TIMING META-ANALYSIS
%
% Reads the previously generated DS* analysis folders.
% Does NOT load raw Rigol CSV waveforms.
%
% Included:
%   T2 10s Long
%   T3 5s Long
%   T4 1s Long
%
% Excluded:
%   T1 One Burst
%
% Outputs:
%   Inventory and quality checks
%   Pooled event distributions
%   All eight state distributions
%   Short/long feedback-cycle comparisons
%   State 1 anomaly investigation
%   Feedback timing and latency comparisons
%   Duplicate detection
%   Simulation timing parameters
%   Anomaly register
%   TXT report, CSV tables, PNG and FIG figures
%
% No specialised MATLAB toolboxes.
%% ========================================================================

clear;
clc;
close all;

%% 1. CONFIGURATION

scriptFile = mfilename('fullpath');
rootDir = fileparts(scriptFile);

if isempty(rootDir)
    rootDir = pwd;
end

cfg.groups = { ...
    'T2 10s Long', ...
    'T3 5s Long', ...
    'T4 1s Long'};

cfg.outputDir = fullfile(rootDir,'MetaAnalysis_Results');

cfg.expectedPulses = 20;

cfg.shortRange_ms = [74 82];
cfg.longRange_ms = [82 91];

% Diagnostic thresholds only.
% These do not alter the underlying measurements.
cfg.periodTolerance_ms = 0.10;
cfg.minimumADC_us = 170;
cfg.maximumADC_us = 185;
cfg.minimumPositive_us = 950;
cfg.maximumPositive_us = 1010;
cfg.state7Low_us = 830;
cfg.state7High_us = 885;

cfg.figureResolution = 250;
cfg.saveFigures = true;

% Records with identical pulse and cycle tables are
% treated as potential duplicate exports.
cfg.excludeDuplicates = true;

if ~isfolder(cfg.outputDir)
    mkdir(cfg.outputDir);
end

fprintf('\n============================================\n');
fprintf(' OPENXSTIM TIMING META-ANALYSIS\n');
fprintf('============================================\n');

%% 2. FIND RECORDING FOLDERS

records = struct( ...
    'ID',{},'Group',{},'Name',{},'Path',{}, ...
    'Pulse',{},'Cycle',{},'State0',{}, ...
    'State1',{},'Summary',{},'Report',{}, ...
    'Duration',{},'Resolution',{}, ...
    'DuplicateOf',{},'Included',{});

for g = 1:numel(cfg.groups)

    groupDir = fullfile(rootDir,cfg.groups{g});

    if ~isfolder(groupDir)
        warning('Missing experiment folder: %s',groupDir);
        continue;
    end

    folders = dir(fullfile(groupDir,'DS*'));
    folders = folders([folders.isdir]);

    for f = 1:numel(folders)

        folderName = folders(f).name;
        folderPath = fullfile(groupDir,folderName);

        prefix = folderName;

        pulsePath = fullfile(folderPath, ...
            [prefix '_PulseTiming.csv']);

        cyclePath = fullfile(folderPath, ...
            [prefix '_FeedbackCycles.csv']);

        summaryPath = fullfile(folderPath, ...
            [prefix '_TimingSummary.csv']);

        state0Path = fullfile(folderPath, ...
            [prefix '_State0PerCycle.csv']);

        state1Path = fullfile(folderPath, ...
            [prefix '_State1Audit.csv']);

        reportPath = fullfile(folderPath, ...
            [prefix '_Report.txt']);

        required = {pulsePath,cyclePath, ...
            summaryPath,state0Path};

        if ~all(cellfun(@isfile,required))
            warning('Skipping incomplete folder: %s',folderPath);
            continue;
        end

        R.ID = numel(records)+1;
        R.Group = string(cfg.groups{g});
        R.Name = string(folderName);
        R.Path = string(folderPath);

        R.Pulse = readtable(pulsePath);
        R.Cycle = readtable(cyclePath);
        R.State0 = readtable(state0Path);
        R.Summary = readtable(summaryPath);

        if isfile(state1Path)
            R.State1 = readtable(state1Path);
        else
            R.State1 = table();
        end

        R.Report = reportPath;
        R.Duration = NaN;
        R.Resolution = NaN;
        R.DuplicateOf = 0;
        R.Included = true;

        if isfile(reportPath)

            txt = fileread(reportPath);

            R.Duration = readReportNumber( ...
                txt,'Recording duration');

            R.Resolution = readReportNumber( ...
                txt,'Time resolution');
        end

        records(end+1) = R;
    end
end

assert(~isempty(records), ...
    'No valid DS analysis folders found.');

nRecords = numel(records);

fprintf('Discovered recordings: %d\n',nRecords);

%% 3. REQUIRED SCHEMA CHECKS

for i = 1:nRecords

    R = records(i);

    requireColumns(R.Pulse,{ ...
        'acquisition_us', ...
        'positive_us', ...
        'settling_us', ...
        'baseline_us', ...
        'pulseHighWidth_us'},R.Path);

    requireColumns(R.Cycle,{ ...
        'adcCount', ...
        'completePhysical', ...
        'burstAcquisition_ms', ...
        'burstPhysical_ms', ...
        'finalisationToRise_ms'},R.Path);

    requireColumns(R.State0,{ ...
        'Complete','Class','Period_ms', ...
        'State0_ms','OtherStates_ms', ...
        'State1_ms','State2_ms','State3_ms', ...
        'State4_ms','State5_ms','State6_ms', ...
        'State7_ms'},R.Path);
end

%% 4. DETECT DUPLICATE EXPORTS

% Compare numerical measurement tables, rather
% than only filenames or rounded summary values.

for i = 2:nRecords

    for j = 1:i-1

        % Only compare against the first retained
        % occurrence of a recording.
        if ~records(j).Included
            continue;
        end

        samePulse = isequaln( ...
            records(i).Pulse,records(j).Pulse);

        sameCycle = isequaln( ...
            records(i).Cycle,records(j).Cycle);

        if samePulse && sameCycle

            records(i).DuplicateOf = records(j).ID;

            if cfg.excludeDuplicates
                records(i).Included = false;
            end

            fprintf('Duplicate candidate: %s/%s == %s/%s\n', ...
                records(i).Group,records(i).Name, ...
                records(j).Group,records(j).Name);

            break;
        end
    end
end

%% 5. PREPARE UNIFIED OBSERVATION TABLES

% Long-form event table.
% State event duration is measured in microseconds,
% except State 0, which is analysed per cycle.

E = table();

% State occupancy per verified feedback interval.
C = table();

% Anomaly register.
A = table();

inventory = table();

% Recording-level means.
recordMetrics = table();

%% 6. IMPORT MEASUREMENTS AND QUALITY FLAGS

for i = 1:nRecords

    R = records(i);

    nPulse = height(R.Pulse);
    nBurst = height(R.Cycle);

    nComplete = nnz( ...
        logical(R.Cycle.completePhysical));

    nIntervals = nnz(logical(R.State0.Complete));

    newInventory = table( ...
        i,R.Group,R.Name, ...
        R.Duration,R.Resolution, ...
        nPulse,nBurst,nComplete,nIntervals, ...
        R.Included,R.DuplicateOf, ...
        'VariableNames',{ ...
        'RecordingID','Group','Capture', ...
        'Duration_s','Resolution_us', ...
        'PulseRows','LoggedBursts', ...
        'CompleteBursts','CompleteIntervals', ...
        'Included','DuplicateOf'});

    inventory = [inventory;newInventory];

    if R.DuplicateOf>0

        A = addAnomaly(A,i,R.Group,R.Name, ...
            "PossibleDuplicate", ...
            "Recording",NaN,NaN, ...
            "Identical pulse and cycle tables", ...
            "Review source capture identity");
    end

    if ~R.Included
        continue;
    end

    P = R.Pulse;
    B = R.Cycle;
    Z = R.State0;

    %% 6A. QUALIFIED STATE EXECUTION DURATIONS

    E = appendMetric(E,i,R.Group,R.Name, ...
        "State1_PositiveDAC",P.positive_us,"us");

    E = appendMetric(E,i,R.Group,R.Name, ...
        "State2_Settling",P.settling_us,"us");

    E = appendMetric(E,i,R.Group,R.Name, ...
        "State3_ADC",P.acquisition_us,"us");

    E = appendMetric(E,i,R.Group,R.Name, ...
        "State4_BaselineDAC",P.baseline_us,"us");

    E = appendMetric(E,i,R.Group,R.Name, ...
        "PhysicalHigh",P.pulseHighWidth_us,"us");

    if ismember('pulseAmplitude_V', ...
            P.Properties.VariableNames)

        E = appendMetric(E,i,R.Group,R.Name, ...
            "PulseAmplitude",P.pulseAmplitude_V,"V");
    end

    %% 6B. COMPLETE BURST DURATIONS

    validBurst = logical(B.completePhysical);

    E = appendMetric(E,i,R.Group,R.Name, ...
        "BurstRiseToLastADC", ...
        B.burstAcquisition_ms(validBurst),"ms");

    E = appendMetric(E,i,R.Group,R.Name, ...
        "BurstRiseToLastFall", ...
        B.burstPhysical_ms(validBurst),"ms");

    %% 6C. FEEDBACK LATENCIES

    if ismember('finalisationToRise_ms', ...
            B.Properties.VariableNames)

        latency = B.finalisationToRise_ms;

        validLatency = validBurst & isfinite(latency);

        E = appendMetric(E,i,R.Group,R.Name, ...
            "FinalisationToRise", ...
            latency(validLatency),"ms");
    end

    if ismember('finalADCToRise_ms', ...
            B.Properties.VariableNames)

        latency = B.finalADCToRise_ms;

        validLatency = validBurst & isfinite(latency);

        E = appendMetric(E,i,R.Group,R.Name, ...
            "FinalADCToRise", ...
            latency(validLatency),"ms");
    end

    %% 6D. COMPLETE CYCLE STATE OCCUPANCY

    Z = Z(logical(Z.Complete),:);

    if ~isempty(Z)

        n = height(Z);

        X = table( ...
            repmat(i,n,1), ...
            repmat(R.Group,n,1), ...
            repmat(R.Name,n,1), ...
            (1:n)', ...
            double(Z.Class), ...
            double(Z.Period_ms), ...
            'VariableNames',{ ...
            'RecordingID','Group','Capture', ...
            'Interval','Class','Period_ms'});

        X.Latency_ms = NaN(n,1);

        if ismember('Interval',Z.Properties.VariableNames)
        
            for q = 1:n
        
                burstIndex = Z.Interval(q)+1;
        
                if burstIndex<=height(B) && ...
                   logical(B.completePhysical(burstIndex))
        
                    X.Latency_ms(q) = ...
                        B.finalisationToRise_ms(burstIndex);
                end
            end
        end

        for s = 0:7

            field = sprintf('State%d_ms',s);

            X.(field) = double(Z.(field));
        end

        if ismember('IdleBeforeRise_ms', ...
                Z.Properties.VariableNames)

            X.IdleBeforeRise_ms = ...
                double(Z.IdleBeforeRise_ms);
        else
            X.IdleBeforeRise_ms = NaN(n,1);
        end

        if ismember('ClosureError_us', ...
                Z.Properties.VariableNames)

            X.ClosureError_us = ...
                double(Z.ClosureError_us);
        else
            X.ClosureError_us = NaN(n,1);
        end

        C = [C;X];

        E = appendMetric(E,i,R.Group,R.Name, ...
            "FeedbackPeriod",X.Period_ms,"ms");

        % Individual State 5, 6 and 7 events
        % occur once per cycle in the validated
        % firmware instrumentation.
        %
        % Their per-cycle occupancy is treated as
        % one qualified execution measurement.

        for s = 5:7

            field = sprintf('State%d_ms',s);

            E = appendMetric(E,i,R.Group,R.Name, ...
                "State"+s+"_CycleOccupancy", ...
                X.(field)*1000,"us");
        end
    end

    %% 6E. TARGETED ANOMALY CHECKS

    % Short or unusually long ADC acquisitions.
    x = P.acquisition_us;

    bad = find(isfinite(x) & ...
        (x<cfg.minimumADC_us | ...
         x>cfg.maximumADC_us));

    for j = reshape(bad,1,[])

        A = addAnomaly(A,i,R.Group,R.Name, ...
            "ADCDuration", ...
            "Pulse",j,x(j), ...
            "ADC acquisition outside nominal range", ...
            "Check event timing");
    end

    % Atypical qualified positive DAC duration.
    x = P.positive_us;

    bad = find(isfinite(x) & ...
        (x<cfg.minimumPositive_us | ...
         x>cfg.maximumPositive_us));

    for j = reshape(bad,1,[])

        A = addAnomaly(A,i,R.Group,R.Name, ...
            "PositiveDACDuration", ...
            "Pulse",j,x(j), ...
            "Atypical positive DAC duration", ...
            "Inspect marker qualification");
    end

    % Incomplete physical bursts.
    bad = find(~logical(B.completePhysical));

    for j = reshape(bad,1,[])

        A = addAnomaly(A,i,R.Group,R.Name, ...
            "IncompleteBurst", ...
            "Burst",j,double(B.adcCount(j)), ...
            "Fewer than expected complete physical pulses", ...
            "Check acquisition boundary");
    end

    % Update intervals outside the two usual modes.
    if ~isempty(Z)

        bad = find( ...
            abs(Z.Period_ms-76)> ...
                cfg.periodTolerance_ms & ...
            abs(Z.Period_ms-89)> ...
                cfg.periodTolerance_ms);

        for j = reshape(bad,1,[])

            A = addAnomaly(A,i,R.Group,R.Name, ...
                "UpdatePeriodOutlier", ...
                "CompleteInterval",j, ...
                Z.Period_ms(j), ...
                "Outside both expected timing modes", ...
                "Retain for sensitivity analysis");
        end

        % State 7 timing outliers.
        x = Z.State7_ms*1000;

        bad = find( ...
            x<cfg.state7Low_us | ...
            x>cfg.state7High_us);

        for j = reshape(bad,1,[])

            A = addAnomaly(A,i,R.Group,R.Name, ...
                "State7Outlier", ...
                "CompleteInterval",j,x(j), ...
                "Logging duration outside diagnostic limits", ...
                "Compare with other recordings");
        end

        % Check state accounting.
        stateSum = zeros(height(Z),1);

        for s = 0:7
            stateSum = stateSum + ...
                Z.(sprintf('State%d_ms',s));
        end

        bad = find(abs(stateSum-Z.Period_ms)>0.002);

        for j = reshape(bad,1,[])

            A = addAnomaly(A,i,R.Group,R.Name, ...
                "StateClosure", ...
                "CompleteInterval",j, ...
                (stateSum(j)-Z.Period_ms(j))*1000, ...
                "State durations do not reproduce period", ...
                "Audit state segmentation");
        end
    end

    %% 6F. STATE 1 COUNT AUDIT

    if ~isempty(R.State1)

        S1 = R.State1;

        required = { ...
            'QualifiedState1Count', ...
            'ADCCount','PhysicalPulseCount', ...
            'Complete','Class'};

        if all(ismember(required, ...
                S1.Properties.VariableNames))

            for j = 1:height(S1)

                if ~logical(S1.Complete(j))
                    continue;
                end

                expected = cfg.expectedPulses;

                if S1.QualifiedState1Count(j)~=expected

                    % Systematic long-cycle marker
                    % differences are logged, not
                    % automatically called missing pulses.
                    A = addAnomaly(A,i,R.Group,R.Name, ...
                        "State1Qualification", ...
                        "Interval",j, ...
                        S1.QualifiedState1Count(j), ...
                        "Qualified DAC marker count differs from 20", ...
                        "Compare physical and ADC counts");
                end
            end
        end
    end

    %% 6G. RECORDING LEVEL STATISTICS

    metrics = unique(E.Metric( ...
        E.RecordingID==i));

    for j = 1:numel(metrics)

        mask = E.RecordingID==i & ...
               E.Metric==metrics(j);

        values = E.Value(mask);

        [n,mu,sd,mn,mx] = stats(values);

        row = table( ...
            i,R.Group,R.Name,metrics(j), ...
            n,mu,sd,mn,mx, ...
            'VariableNames',{ ...
            'RecordingID','Group','Capture', ...
            'Metric','N','Mean','Std', ...
            'Minimum','Maximum'});

        recordMetrics = [recordMetrics;row];
    end
end

%% 7. CLASSIFY CYCLE TIMING MODES

C.Class = zeros(height(C),1);

C.Class( ...
    C.Period_ms>=cfg.shortRange_ms(1) & ...
    C.Period_ms<cfg.shortRange_ms(2)) = 1;

C.Class( ...
    C.Period_ms>=cfg.longRange_ms(1) & ...
    C.Period_ms<=cfg.longRange_ms(2)) = 2;

shortMask = C.Class==1;
longMask = C.Class==2;

%% 8. POOLED EVENT STATISTICS

pooled = table();

metricList = unique(E.Metric,'stable');

for j = 1:numel(metricList)

    mask = E.Metric==metricList(j);

    values = E.Value(mask);

    [n,mu,sd,mn,mx] = stats(values);

    med = medianFinite(values);

    recordingCount = numel(unique( ...
        E.RecordingID(mask)));

    row = table( ...
        metricList(j),E.Unit(find(mask,1)), ...
        recordingCount,n,mu,med,sd,mn,mx, ...
        'VariableNames',{ ...
        'Metric','Unit','Recordings','N', ...
        'Mean','Median','Std', ...
        'Minimum','Maximum'});

    pooled = [pooled;row];
end

%% 9. ALL EIGHT STATE OCCUPANCY COMPARISON

stateComparison = table();

for s = 0:7

    field = sprintf('State%d_ms',s);

    allValues = C.(field);

    xShort = allValues(shortMask);
    xLong = allValues(longMask);

    [ns,ms,ss,mins,maxs] = stats(xShort);
    [nl,ml,sl,minl,maxl] = stats(xLong);

    row = table( ...
        s,ns,nl, ...
        ms,ml,ml-ms, ...
        ss,sl,mins,maxs,minl,maxl, ...
        'VariableNames',{ ...
        'State','ShortN','LongN', ...
        'ShortMean_ms','LongMean_ms', ...
        'Difference_ms', ...
        'ShortStd_ms','LongStd_ms', ...
        'ShortMin_ms','ShortMax_ms', ...
        'LongMin_ms','LongMax_ms'});

    stateComparison = [stateComparison;row];
end

%% 10. CAPTURE GROUP COMPARISON

groupComparison = table();

for g = 1:numel(cfg.groups)

    groupName = string(cfg.groups{g});

    selected = C.Group==groupName;

    x = C.Period_ms(selected);

    if isempty(x)
        continue;
    end

    [n,mu,sd,mn,mx] = stats(x);

    shortN = nnz(selected & shortMask);
    longN = nnz(selected & longMask);

    selectedE = E.Group==groupName & ...
        E.Metric=="FinalisationToRise";

    latency = E.Value(selectedE);

    [latN,latMean,latStd,~,~] = stats(latency);

    row = table( ...
        groupName,n,shortN,longN, ...
        mu,sd,mn,mx, ...
        latN,latMean,latStd, ...
        'VariableNames',{ ...
        'Group','Intervals', ...
        'ShortIntervals','LongIntervals', ...
        'MeanPeriod_ms','StdPeriod_ms', ...
        'MinPeriod_ms','MaxPeriod_ms', ...
        'LatencyN','MeanLatency_ms', ...
        'StdLatency_ms'});

    groupComparison = [groupComparison;row];
end

%% 11. REPEATABILITY BETWEEN RECORDINGS

repeatability = table();

for j = 1:numel(metricList)

    name = metricList(j);

    X = recordMetrics( ...
        recordMetrics.Metric==name & ...
        recordMetrics.N>0,:);

    if isempty(X)
        continue;
    end

    means = X.Mean;

    row = table( ...
        name,height(X), ...
        mean(means),stdFinite(means), ...
        min(means),max(means), ...
        'VariableNames',{ ...
        'Metric','Recordings', ...
        'MeanRecordingMean', ...
        'BetweenRecordingStd', ...
        'MinimumRecordingMean', ...
        'MaximumRecordingMean'});

    repeatability = [repeatability;row];
end

%% 12. SIMULATION TIMING PARAMETERS

% Distinguish the two update-period modes.
shortPeriod = C.Period_ms(shortMask);
longPeriod = C.Period_ms(longMask);

% Physical latency observations are independent
% event measurements. Preserve the complete pooled
% distribution and its extrema.

latencyValues = E.Value( ...
    E.Metric=="FinalisationToRise");

[~,shortTs,shortSd,shortMin,shortMax] = ...
    stats(shortPeriod);

[~,longTs,longSd,longMin,longMax] = ...
    stats(longPeriod);

[~,latMean,latSd,latMin,latMax] = ...
    stats(latencyValues);

simulationParameters = table( ...
    ["Short period"; ...
     "Long period"; ...
     "Pooled physical latency"], ...
    [shortTs;longTs;latMean], ...
    [shortSd;longSd;latSd], ...
    [shortMin;longMin;latMin], ...
    [shortMax;longMax;latMax], ...
    ["ms";"ms";"ms"], ...
    'VariableNames',{ ...
    'Parameter','Mean','Std', ...
    'Minimum','Maximum','Unit'});

%% 13. FIGURE 1: ALL EIGHT STATE DISTRIBUTIONS

fig1 = figure( ...
    'Color','w', ...
    'Position',[80 70 1550 1050], ...
    'Name','All state timing distributions');

tl = tiledlayout(4,2, ...
    'TileSpacing','loose', ...
    'Padding','loose');

for s = 0:7

    ax = nexttile(tl);

    if s==0

        x1 = C.State0_ms(shortMask);
        x2 = C.State0_ms(longMask);

        histogram(ax,x1, ...
            'BinMethod','auto', ...
            'FaceAlpha',0.6, ...
            'DisplayName','Short cycles');

        hold(ax,'on');

        histogram(ax,x2, ...
            'BinMethod','auto', ...
            'FaceAlpha',0.6, ...
            'DisplayName','Long cycles');

        xlabel(ax,'Total State 0 per cycle (ms)');
        title(ax,'State 0: idle and UI');

        legend(ax,'Location','best');

    elseif s<=4

        metric = "State"+s+"_"+ ...
            stateMetricSuffix(s);

        x = E.Value(E.Metric==metric);

        if ~isempty(x)

            histogram(ax,x,'BinMethod','auto');

        else
            missingPlot(ax);
        end

        xlabel(ax,'Qualified execution duration (us)');
        title(ax,sprintf('State %d',s));

    else

        field = sprintf('State%d_ms',s);
        x = C.(field)*1000;

        histogram(ax,x,'BinMethod','auto');

        xlabel(ax,'Cycle occupancy (us)');
        title(ax,sprintf('State %d',s));
    end

    ylabel(ax,'Observations');
    grid(ax,'on');

    try
        ax.Toolbar.Visible = 'off';
    catch
    end
end

title(tl,'OpenXstim: timing distributions of States 0 to 7');

%% 14. FIGURE 2: SHORT/LONG STATE COMPARISON

fig2 = figure( ...
    'Color','w', ...
    'Position',[100 100 1450 850], ...
    'Name','Feedback cycle state decomposition');

tl = tiledlayout(2,1, ...
    'TileSpacing','loose', ...
    'Padding','loose');

ax1 = nexttile(tl);

bar(ax1,0:7, ...
    [stateComparison.ShortMean_ms, ...
     stateComparison.LongMean_ms]);

ylabel(ax1,'Occupancy per cycle (ms)');
xlabel(ax1,'Firmware state');

legend(ax1,{'76 ms cycles','89 ms cycles'}, ...
    'Location','best');

title(ax1,'Mean state occupancy by timing mode');
grid(ax1,'on');

ax2 = nexttile(tl);

barh(ax2,0:7,stateComparison.Difference_ms);

yticks(ax2,0:7);
set(ax2,'YDir','reverse');

xlabel(ax2,'Long minus short occupancy (ms)');
ylabel(ax2,'Firmware state');

title(ax2,'Contribution to the longer feedback interval');
grid(ax2,'on');

title(tl,'State-level explanation of timing modes');

%% 15. FIGURE 3: STATE 7 DETAIL

fig3 = figure( ...
    'Color','w', ...
    'Position',[120 100 1450 900], ...
    'Name','State 7 logging timing');

tl = tiledlayout(2,2, ...
    'TileSpacing','loose', ...
    'Padding','loose');

state7 = C.State7_ms*1000;

ax1 = nexttile(tl);

histogram(ax1,state7, ...
    'BinMethod','auto');

xlabel(ax1,'State 7 duration (us)');
ylabel(ax1,'Cycles');
title(ax1,'Logging duration distribution');
grid(ax1,'on');

ax2 = nexttile(tl);

plot(ax2,state7,'.','MarkerSize',6);

xlabel(ax2,'Pooled cycle index');
ylabel(ax2,'State 7 duration (us)');
title(ax2,'Logging duration sequence');
grid(ax2,'on');

ax3 = nexttile(tl);

histogram(ax3,state7(shortMask), ...
    'BinMethod','auto', ...
    'FaceAlpha',0.6);

hold(ax3,'on');

histogram(ax3,state7(longMask), ...
    'BinMethod','auto', ...
    'FaceAlpha',0.6);

legend(ax3,{'Short','Long'},'Location','best');

xlabel(ax3,'State 7 duration (us)');
ylabel(ax3,'Cycles');
title(ax3,'Logging duration by update mode');
grid(ax3,'on');

ax4 = nexttile(tl);

scatter(ax4,C.Period_ms,state7,12,'filled');

xlabel(ax4,'Feedback period (ms)');
ylabel(ax4,'State 7 duration (us)');
title(ax4,'Logging duration versus update period');
grid(ax4,'on');

title(tl,'State 7: variability and possible subgroups');

%% 16. FIGURE 4: UPDATE PERIOD AND FEEDBACK LATENCY

fig4 = figure( ...
    'Color','w', ...
    'Position',[150 100 1450 800], ...
    'Name','Control sampling and feedback latency');

tl = tiledlayout(1,2, ...
    'TileSpacing','loose', ...
    'Padding','loose');

ax1 = nexttile(tl);

histogram(ax1,C.Period_ms, ...
    'BinMethod','auto');

xlabel(ax1,'Update interval (ms)');
ylabel(ax1,'Complete intervals');

title(ax1,'Feedback update timing modes');
grid(ax1,'on');

ax2 = nexttile(tl);

histogram(ax2,latencyValues, ...
    'BinMethod','auto');

xlabel(ax2,'Finalisation to physical rise (ms)');
ylabel(ax2,'Observations');

title(ax2,'Physical feedback latency distribution');
grid(ax2,'on');

title(tl,'Controller update and feedback latency');

%% 17. FIGURE 5: REPEATABILITY BY RECORDING

fig5 = figure( ...
    'Color','w', ...
    'Position',[160 80 1450 900], ...
    'Name','Recording-level repeatability');

tl = tiledlayout(2,1, ...
    'TileSpacing','loose', ...
    'Padding','loose');

metricA = "State3_ADC";
metricB = "FinalisationToRise";

ax1 = nexttile(tl);

plotMetricByRecording( ...
    ax1,recordMetrics,metricA);

ylabel(ax1,'ADC duration (us)');
title(ax1,'ADC timing across individual recordings');
grid(ax1,'on');

ax2 = nexttile(tl);

plotMetricByRecording( ...
    ax2,recordMetrics,metricB);

ylabel(ax2,'Feedback latency (ms)');
xlabel(ax2,'Recording index');

title(ax2,'Feedback latency across recordings');
grid(ax2,'on');

title(tl,'Between-recording repeatability');

%% 18. EXPORT TABLES

out = cfg.outputDir;

writetable(inventory, ...
    fullfile(out,'RecordingInventory.csv'));

writetable(E, ...
    fullfile(out,'AllEventMeasurements.csv'));

writetable(C, ...
    fullfile(out,'AllCompleteCycles.csv'));

writetable(pooled, ...
    fullfile(out,'PooledStatistics.csv'));

writetable(stateComparison, ...
    fullfile(out,'StateModeComparison.csv'));

writetable(groupComparison, ...
    fullfile(out,'CaptureGroupComparison.csv'));

writetable(recordMetrics, ...
    fullfile(out,'RecordingMetrics.csv'));

writetable(repeatability, ...
    fullfile(out,'BetweenRecordingRepeatability.csv'));

writetable(simulationParameters, ...
    fullfile(out,'SimulationTimingParameters.csv'));

if ~isempty(A)
    writetable(A, ...
        fullfile(out,'AnomalyRegister.csv'));
end

%% 19. EXPORT FIGURES

if cfg.saveFigures

    figs = [fig1 fig2 fig3 fig4 fig5];

    names = { ...
        'Figure1_AllStateDistributions'
        'Figure2_StateModeComparison'
        'Figure3_State7Detailed'
        'Figure4_UpdateAndLatency'
        'Figure5_RecordingRepeatability'};

    for j = 1:numel(figs)

        axesList = findall(figs(j),'Type','axes');

        for a = 1:numel(axesList)
            try
                axesList(a).Toolbar.Visible = 'off';
            catch
            end
        end

        base = fullfile(out,names{j});

        exportgraphics(figs(j), ...
            [base '.png'], ...
            'Resolution',cfg.figureResolution);

        savefig(figs(j),[base '.fig']);
    end
end

%% 20. HUMAN-READABLE REPORT

reportFile = fullfile(out,'MetaAnalysis_Report.txt');

fid = fopen(reportFile,'w');

assert(fid>=0,'Unable to create report.');

fprintf(fid,'============================================\n');
fprintf(fid,'OPENXSTIM TIMING META-ANALYSIS\n');
fprintf(fid,'============================================\n\n');

fprintf(fid,'Date: %s\n',datestr(now));
fprintf(fid,'Included groups: T2, T3, T4\n');
fprintf(fid,'T1 excluded by design.\n\n');

fprintf(fid,'RECORDING INVENTORY\n');
fprintf(fid,'--------------------------------------------\n');

for i = 1:height(inventory)

    fprintf(fid,'%s / %s\n', ...
        char(inventory.Group(i)), ...
        char(inventory.Capture(i)));

    fprintf(fid, ...
        '  Included: %d, Duplicate of: %d\n', ...
        inventory.Included(i), ...
        inventory.DuplicateOf(i));

    fprintf(fid, ...
        '  Pulses: %d, Complete bursts: %d\n', ...
        inventory.PulseRows(i), ...
        inventory.CompleteBursts(i));
end

fprintf(fid,'\nPOOLED STATE/EVENT STATISTICS\n');
fprintf(fid,'--------------------------------------------\n');

fprintf(fid, ...
    '%-32s %8s %12s %12s %8s\n', ...
    'Metric','N','Mean','Std','Unit');

for j = 1:height(pooled)

    fprintf(fid, ...
        '%-32s %8d %12.4f %12.4f %8s\n', ...
        char(pooled.Metric(j)), ...
        pooled.N(j), ...
        pooled.Mean(j), ...
        pooled.Std(j), ...
        char(pooled.Unit(j)));
end

fprintf(fid,'\nSTATE COMPARISON: SHORT VS LONG\n');
fprintf(fid,'--------------------------------------------\n');

fprintf(fid, ...
    '%-8s %12s %12s %12s\n', ...
    'State','Short ms','Long ms','Delta ms');

for j = 1:height(stateComparison)

    fprintf(fid, ...
        '%-8d %12.4f %12.4f %12.4f\n', ...
        stateComparison.State(j), ...
        stateComparison.ShortMean_ms(j), ...
        stateComparison.LongMean_ms(j), ...
        stateComparison.Difference_ms(j));
end

fprintf(fid,'\nCAPTURE GROUP COMPARISON\n');
fprintf(fid,'--------------------------------------------\n');

for j = 1:height(groupComparison)

    fprintf(fid,'%s\n', ...
        char(groupComparison.Group(j)));

    fprintf(fid, ...
        '  Complete intervals: %d\n', ...
        groupComparison.Intervals(j));

    fprintf(fid, ...
        '  Short: %d, Long: %d\n', ...
        groupComparison.ShortIntervals(j), ...
        groupComparison.LongIntervals(j));

    fprintf(fid, ...
        '  Mean update period: %.4f ms\n', ...
        groupComparison.MeanPeriod_ms(j));

    fprintf(fid, ...
        '  Mean physical latency: %.4f ms\n', ...
        groupComparison.MeanLatency_ms(j));
end

fprintf(fid,'\nSIMULATION PARAMETERS\n');
fprintf(fid,'--------------------------------------------\n');

for j = 1:height(simulationParameters)

    fprintf(fid, ...
        '%s: mean %.4f, std %.4f %s\n', ...
        char(simulationParameters.Parameter(j)), ...
        simulationParameters.Mean(j), ...
        simulationParameters.Std(j), ...
        char(simulationParameters.Unit(j)));
end

fprintf(fid,'\nABNORMALITIES\n');
fprintf(fid,'--------------------------------------------\n');

if isempty(A)

    fprintf(fid,'No abnormalities met configured criteria.\n');

else

    types = unique(A.Type);

    for j = 1:numel(types)

        count = nnz(A.Type==types(j));

        fprintf(fid,'%s: %d observations\n', ...
            char(types(j)),count);
    end
end

fprintf(fid,'\nMETHODOLOGY AND LIMITATIONS\n');
fprintf(fid,'--------------------------------------------\n');

fprintf(fid,'1. Raw Rigol CSV waveforms were not reanalysed.\n');
fprintf(fid,'2. T1 One Burst was excluded.\n');
fprintf(fid,'3. Partial bursts were excluded from burst timing.\n');
fprintf(fid,'4. Identical exports were flagged as duplicates.\n');
fprintf(fid,'5. State 0 is total per-cycle occupancy.\n');
fprintf(fid,'6. States 1-4 use qualified pulse events.\n');
fprintf(fid,'7. States 5-7 use per-cycle state occupancy.\n');
fprintf(fid,'8. A bimodal period is not random Gaussian jitter.\n');
fprintf(fid,'9. Individual pulses in one run are correlated.\n');
fprintf(fid,'10. OLED causation remains unconfirmed.\n');
fprintf(fid,'11. Flagged events require source review.\n');
fprintf(fid,'12. Results describe the tested firmware setup.\n');

fprintf(fid,'\nEND OF REPORT\n');

fclose(fid);

%% 21. SAVE MATLAB RESULTS

save(fullfile(out,'MetaAnalysis_Results.mat'), ...
    'cfg','inventory','E','C','A', ...
    'pooled','stateComparison', ...
    'groupComparison','recordMetrics', ...
    'repeatability','simulationParameters');

%% 22. COMMAND WINDOW SUMMARY

fprintf('\n============================================\n');
fprintf(' META-ANALYSIS COMPLETE\n');
fprintf('============================================\n');

fprintf('Discovered: %d recordings\n',nRecords);
fprintf('Included: %d recordings\n', ...
    nnz(inventory.Included));

fprintf('Complete feedback intervals: %d\n', ...
    height(C));

fprintf('Event observations: %d\n',height(E));

fprintf('\nCAPTURE GROUPS:\n');
disp(groupComparison);

fprintf('\nSTATE COMPARISON:\n');
disp(stateComparison);

fprintf('\nSIMULATION PARAMETERS:\n');
disp(simulationParameters);

fprintf('\nResults:\n%s\n',out);

%% ========================================================================
% LOCAL HELPER FUNCTIONS
%% ========================================================================

function requireColumns(T,names,source)

    missing = names( ...
        ~ismember(names,T.Properties.VariableNames));

    if ~isempty(missing)

        error('Missing columns in %s: %s', ...
            source,strjoin(missing,', '));
    end
end

function y = readReportNumber(txt,label)

    escaped = regexptranslate('escape',label);

    tokens = regexp(txt, ...
        [escaped ':\s*([+-]?\d*\.?\d+)'], ...
        'tokens','once');

    if isempty(tokens)
        y = NaN;
    else
        y = str2double(tokens{1});
    end
end

function T = appendMetric( ...
    T,id,group,name,metric,x,unit)

    x = double(x(:));
    x = x(isfinite(x));

    if isempty(x)
        return;
    end

    n = numel(x);

    row = table( ...
        repmat(id,n,1), ...
        repmat(string(group),n,1), ...
        repmat(string(name),n,1), ...
        repmat(string(metric),n,1), ...
        repmat(string(unit),n,1),x, ...
        'VariableNames',{ ...
        'RecordingID','Group','Capture', ...
        'Metric','Unit','Value'});

    T = [T;row];
end

function A = addAnomaly( ...
    A,id,group,name,type,scope, ...
    index,value,description,action)

    row = table( ...
        id,string(group),string(name), ...
        string(type),string(scope), ...
        double(index),double(value), ...
        string(description),string(action), ...
        'VariableNames',{ ...
        'RecordingID','Group','Capture', ...
        'Type','Scope','Index','Value', ...
        'Description','SuggestedAction'});

    A = [A;row];
end

function [n,mu,sd,mn,mx] = stats(x)

    x = double(x(:));
    x = x(isfinite(x));

    n = numel(x);
    mu = NaN;
    sd = NaN;
    mn = NaN;
    mx = NaN;

    if n==0
        return;
    end

    mu = mean(x);
    mn = min(x);
    mx = max(x);

    if n>1
        sd = std(x);
    end
end

function m = medianFinite(x)

    x = x(isfinite(x));

    if isempty(x)
        m = NaN;
    else
        m = median(x);
    end
end

function s = stdFinite(x)

    x = x(isfinite(x));

    if numel(x)<2
        s = NaN;
    else
        s = std(x);
    end
end

function suffix = stateMetricSuffix(s)

    switch s
        case 1
            suffix = "PositiveDAC";
        case 2
            suffix = "Settling";
        case 3
            suffix = "ADC";
        case 4
            suffix = "BaselineDAC";
        otherwise
            suffix = "Unknown";
    end
end

function missingPlot(ax)

    text(ax,0.5,0.5,'Unavailable', ...
        'Units','normalized', ...
        'HorizontalAlignment','center');

    axis(ax,'off');
end

function plotMetricByRecording(ax,T,metric)

    mask = T.Metric==metric;
    X = T(mask,:);

    if isempty(X)
        missingPlot(ax);
        return;
    end

    plot(ax,X.RecordingID,X.Mean, ...
        'o-','LineWidth',1);

    xlabel(ax,'Recording ID');
end
