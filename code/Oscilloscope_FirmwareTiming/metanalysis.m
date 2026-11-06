
%% ================================================================
% OPENXSTIM - MULTI-RECORDING TIMING META-ANALYSIS
%
% Combines existing per-CSV analysis results.
% Does NOT read or reanalyse the raw Rigol CSV files.
%
% Inputs expected in each DS output folder:
%   DSx_TimingSummary.csv
%   DSx_PulseTiming.csv
%   DSx_FeedbackCycles.csv
%   DSx_State0PerCycle.csv
%   DSx_State1Audit.csv (optional)
%   DSx_Report.txt (optional)
%
% Outputs:
%   RecordingInventory.csv
%   RecordingMetrics.csv
%   PooledTimingStatistics.csv
%   State0MetaAnalysis.csv
%   State1MetaAnalysis.csv
%   StateOccupancyMetaAnalysis.csv
%   MetaAnalysis_Report.txt
%   Three summary figures, PNG and FIG
%
% Each recording is identified by its full relative path.
% No additional toolboxes required.
%% ================================================================

clear;
clc;
close all;

%% 1. CONFIGURATION

% Put this script in V4_TimingAnalysis.
% The parent directory is automatically selected.
scriptPath = mfilename('fullpath');
rootDir = fileparts(scriptPath);

if isempty(rootDir)
    rootDir = pwd;
end

cfg.rootDir = rootDir;

% Search all experiment folders under the root.
cfg.searchSubfolders = true;

cfg.outputFolder = fullfile( ...
    cfg.rootDir,'MetaAnalysis_Results');

cfg.expectedPulses = 20;

% State 0 update-period classification.
cfg.shortRange_ms = [74 82];
cfg.longRange_ms = [82 91];

cfg.exportFigures = true;
cfg.figureResolution = 250;

if ~isfolder(cfg.outputFolder)
    mkdir(cfg.outputFolder);
end

fprintf('\n========================================\n');
fprintf(' OPENXSTIM META-ANALYSIS\n');
fprintf('========================================\n');
fprintf('Root: %s\n',cfg.rootDir);

%% 2. DISCOVER COMPLETED RESULT FOLDERS

if cfg.searchSubfolders

    candidates = dir(fullfile( ...
        cfg.rootDir,'**','*_TimingSummary.csv'));

else

    candidates = dir(fullfile( ...
        cfg.rootDir,'*_TimingSummary.csv'));
end

% A valid recording folder must contain one timing
% summary and matching pulse/feedback tables.
%
% Ignore anything inside the meta-analysis output.
recordings = struct( ...
    'id',{},'folder',{},'prefix',{}, ...
    'relativePath',{},'group',{});

for i = 1:numel(candidates)

    folder = candidates(i).folder;
    filename = candidates(i).name;

    if isWithinFolder(folder,cfg.outputFolder)
        continue;
    end

    suffix = '_TimingSummary.csv';

    if ~endsWith(filename,suffix)
        continue;
    end

    prefix = extractBefore(string(filename), ...
        strlength(string(filename))- ...
        strlength(suffix)+1);

    prefix = char(prefix);

    pulseFile = fullfile( ...
        folder,[prefix '_PulseTiming.csv']);

    cycleFile = fullfile( ...
        folder,[prefix '_FeedbackCycles.csv']);

    if ~isfile(pulseFile) || ~isfile(cycleFile)

        warning('Skipping incomplete result folder: %s', ...
            folder);
        continue;
    end

    relative = erase(string(folder), ...
        string(cfg.rootDir));

    relative = strip(relative,filesep);

    % Parent experiment group, e.g. T2 10s Long.
    relativeParts = split(relative,filesep);

    if numel(relativeParts)>=2
        groupName = relativeParts(1);
    else
        groupName = "Root";
    end

    j = numel(recordings)+1;

    recordings(j).id = j;
    recordings(j).folder = folder;
    recordings(j).prefix = prefix;
    recordings(j).relativePath = char(relative);
    recordings(j).group = char(groupName);
end

nFiles = numel(recordings);

assert(nFiles>0, ...
    'No completed analysis folders were found.');

fprintf('\nFound %d recording result folders.\n',nFiles);

%% 3. CONTAINERS

% Every row represents one metric from one recording.
allMetricRows = table();

% Recording inventory.
inventoryRows = table();

% State 0 and State 1 observations across recordings.
allState0 = table();
allState1 = table();

% Pooled state occupancy, one row per interval.
allStateOccupancy = table();

% Values for figures.
allPeriods = [];
allLatencies = [];
allPeriodRecordingID = [];
allLatencyRecordingID = [];

% Important timing metrics to retain.
selectedMetrics = [
    "Positive DAC state"
    "ADC settling"
    "ADC acquisition"
    "Baseline DAC state"
    "ADC-to-ADC pulse period"
    "Physical HIGH width"
    "First rise to final ADC"
    "First rise to final fall"
    "Controller timestamp interval"
    "Logging update interval"
    "Final ADC to next physical rise"
    "Finalisation to next physical rise"
    "Final ADC to next DAC marker"
    "Finalisation to next DAC marker"
    "DAC marker to physical rise"
    "Measurement finalisation state"
    "Controller and supervisor state"
    "CSV logging state"
    "Load baseline voltage"
    "Load plateau voltage"
    "Load pulse amplitude"
];

%% 4. IMPORT EACH RECORDING

for i = 1:nFiles

    R = recordings(i);

    fprintf('\n[%d/%d] %s\n', ...
        i,nFiles,R.relativePath);

    summaryFile = fullfile(R.folder, ...
        [R.prefix '_TimingSummary.csv']);

    pulseFile = fullfile(R.folder, ...
        [R.prefix '_PulseTiming.csv']);

    cycleFile = fullfile(R.folder, ...
        [R.prefix '_FeedbackCycles.csv']);

    state0File = fullfile(R.folder, ...
        [R.prefix '_State0PerCycle.csv']);

    state1File = fullfile(R.folder, ...
        [R.prefix '_State1Audit.csv']);

    reportFile = fullfile(R.folder, ...
        [R.prefix '_Report.txt']);

    S = readtable(summaryFile, ...
        'TextType','string');

    P = readtable(pulseFile, ...
        'TextType','string');

    C = readtable(cycleFile, ...
        'TextType','string');

    % Required source schema.
    requireVariables(S, ...
        {'metricNames','metricUnits','metricN', ...
         'metricMean','metricStd', ...
         'metricMin','metricMax'}, ...
        summaryFile);

    requireVariables(C, ...
        {'adcCount','completePhysical', ...
         'burstAcquisition_ms','burstPhysical_ms'}, ...
        cycleFile);

    % Recording duration from existing text report.
    recordingDuration_s = NaN;

    if isfile(reportFile)

        reportText = fileread(reportFile);

        token = regexp(reportText, ...
            'Recording duration:\s*([\d\.]+)\s*s', ...
            'tokens','once');

        if ~isempty(token)
            recordingDuration_s = ...
                str2double(token{1});
        end
    end

    %% 4A. RECORDING INVENTORY

    nPulseRows = height(P);
    nBurstRows = height(C);

    validPhysical = logical(C.completePhysical);

    nComplete = nnz(validPhysical);

    nCompleteADC = nnz( ...
        logical(C.completeADC));

    nValidLatency = 0;

    if ismember('finalisationToRise_ms', ...
            C.Properties.VariableNames)

        nValidLatency = nnz( ...
            isfinite(C.finalisationToRise_ms));
    end

    ID = i;
    Recording = string(R.relativePath);
    ExperimentGroup = string(R.group);
    SourcePrefix = string(R.prefix);

    inventoryRow = table( ...
        ID,Recording,ExperimentGroup, ...
        SourcePrefix,recordingDuration_s, ...
        nPulseRows,nBurstRows,nCompleteADC, ...
        nComplete,nValidLatency, ...
        'VariableNames',{ ...
        'RecordingID','Recording','ExperimentGroup', ...
        'SourcePrefix','Duration_s', ...
        'PulseRows','LoggedBursts', ...
        'CompleteADCBursts', ...
        'CompletePhysicalBursts', ...
        'ValidPhysicalLatencies'});

    inventoryRows = [inventoryRows;inventoryRow];

    %% 4B. NORMALISE METRIC TABLE

    metricName = string(S.metricNames);
    metricUnit = string(S.metricUnits);

    for j = 1:height(S)

        name = metricName(j);

        if ~ismember(name,selectedMetrics)
            continue;
        end

        xN = double(S.metricN(j));
        xMean = double(S.metricMean(j));
        xStd = double(S.metricStd(j));
        xMin = double(S.metricMin(j));
        xMax = double(S.metricMax(j));

        % Correct the partial-burst bias by replacing
        % only the two affected burst-duration summaries
        % with values from complete physical bursts.
        if name=="First rise to final ADC"

            values = C.burstAcquisition_ms(validPhysical);

            [xN,xMean,xStd,xMin,xMax] = ...
                basicStats(values);

        elseif name=="First rise to final fall"

            values = C.burstPhysical_ms(validPhysical);

            [xN,xMean,xStd,xMin,xMax] = ...
                basicStats(values);
        end

        newRow = table( ...
            i,string(R.relativePath), ...
            name,metricUnit(j), ...
            xN,xMean,xStd,xMin,xMax, ...
            'VariableNames',{ ...
            'RecordingID','Recording', ...
            'Metric','Unit', ...
            'N','Mean','Std','Minimum','Maximum'});

        allMetricRows = [allMetricRows;newRow];
    end

    %% 4C. COLLECT UPDATE PERIOD AND LATENCY VECTORS

    if ismember('Ts_afterBurst_ms', ...
            C.Properties.VariableNames)

        x = C.Ts_afterBurst_ms;
        valid = isfinite(x);

        allPeriods = [allPeriods;x(valid)];
        allPeriodRecordingID = ...
            [allPeriodRecordingID;repmat(i,nnz(valid),1)];
    end

    if ismember('finalisationToRise_ms', ...
            C.Properties.VariableNames)

        x = C.finalisationToRise_ms;
        valid = isfinite(x);

        allLatencies = [allLatencies;x(valid)];
        allLatencyRecordingID = ...
            [allLatencyRecordingID;repmat(i,nnz(valid),1)];
    end

    %% 4D. IMPORT STATE 0 ANALYSIS

    if isfile(state0File)

        Z = readtable(state0File);

        required = { ...
            'Complete','Class','Period_ms', ...
            'State0_ms','OtherStates_ms'};

        requireVariables(Z,required,state0File);

        % Only complete consecutive feedback intervals.
        valid = logical(Z.Complete);

        Z = Z(valid,:);

        if ~isempty(Z)

            Z.RecordingID = ...
                repmat(i,height(Z),1);

            Z.Recording = ...
                repmat(string(R.relativePath), ...
                height(Z),1);

            % Retain a fixed, known schema so the
            % analysis works if source versions differ.
            baseNames = { ...
                'RecordingID','Recording', ...
                'Class','Period_ms', ...
                'State0_ms','OtherStates_ms'};

            Zbasic = Z(:,baseNames);

            if isempty(allState0)
                allState0 = Zbasic;
            else
                allState0 = [allState0;Zbasic];
            end

            % Add individual state occupancy when present.
            stateColumns = ...
                arrayfun(@(s)sprintf('State%d_ms',s), ...
                0:7,'UniformOutput',false);

            if all(ismember(stateColumns, ...
                    Z.Properties.VariableNames))

                Zstates = Z(:, ...
                    [{'RecordingID','Recording', ...
                      'Class','Period_ms'}, ...
                     stateColumns]);

                if isempty(allStateOccupancy)
                    allStateOccupancy = Zstates;
                else
                    allStateOccupancy = ...
                        [allStateOccupancy;Zstates];
                end
            end
        end
    end

    %% 4E. IMPORT STATE 1 AUDIT

    if isfile(state1File)

        A = readtable(state1File);

        needed = { ...
            'Class','Complete', ...
            'RawState1Count', ...
            'QualifiedState1Count', ...
            'MatchedPositiveDACCount', ...
            'ADCCount','PhysicalPulseCount', ...
            'BoundaryCrossingCount', ...
            'TotalState1_ms', ...
            'QualifiedState1_ms', ...
            'UnqualifiedState1_ms'};

        requireVariables(A,needed,state1File);

        A = A(logical(A.Complete),:);

        if ~isempty(A)

            A.RecordingID = ...
                repmat(i,height(A),1);

            A.Recording = ...
                repmat(string(R.relativePath), ...
                height(A),1);

            columns = [ ...
                {'RecordingID','Recording'},needed];

            A = A(:,columns);

            if isempty(allState1)
                allState1 = A;
            else
                allState1 = [allState1;A];
            end
        end
    end
end

%% 5. POOLED TIMING STATISTICS

% Combine recording-level sample statistics using
% pooled sample counts, means and variances.
%
% This is NOT an arithmetic average of file means.
%
% With n_i, mean_i and sample std_i:
%
% Grand mean = sum(n_i*mean_i)/sum(n_i)
%
% Pooled sample variance =
% sum((n_i-1)*std_i^2 +
%     n_i*(mean_i-grandMean)^2)/(sum(n_i)-1)
%
% Exact pooled medians cannot be recovered from
% file-level means/standard deviations alone.

pooledRows = table();

metrics = unique(allMetricRows.Metric,'stable');

for j = 1:numel(metrics)

    name = metrics(j);

    subset = allMetricRows( ...
        allMetricRows.Metric==name,:);

    units = unique(subset.Unit);

    assert(numel(units)==1, ...
        'Unit mismatch for metric: %s',name);

    valid = subset.N>0 & ...
        isfinite(subset.Mean);

    subset = subset(valid,:);

    if isempty(subset)
        continue;
    end

    n = double(subset.N);
    mu = double(subset.Mean);
    sigma = double(subset.Std);

    % A single sample contributes zero within-file
    % sum of squares.
    sigma(n==1 & ~isfinite(sigma)) = 0;

    if any(n>1 & ~isfinite(sigma))
        warning('Missing variance for metric %s.',name);
        continue;
    end

    totalN = sum(n);

    pooledMean = sum(n.*mu)/totalN;

    if totalN>1

        ssWithin = sum( ...
            (n-1).*(sigma.^2));

        ssBetween = sum( ...
            n.*(mu-pooledMean).^2);

        pooledStd = sqrt( ...
            (ssWithin+ssBetween)/(totalN-1));

    else
        pooledStd = NaN;
    end

    pooledMin = min(subset.Minimum);
    pooledMax = max(subset.Maximum);

    fileMean = mean(mu);

    if numel(mu)>1
        betweenRecordingStd = std(mu);
    else
        betweenRecordingStd = NaN;
    end

    newRow = table( ...
        name,units(1), ...
        height(subset),totalN, ...
        pooledMean,pooledStd, ...
        pooledMin,pooledMax, ...
        fileMean,betweenRecordingStd, ...
        'VariableNames',{ ...
        'Metric','Unit', ...
        'Recordings','Observations', ...
        'PooledMean','PooledStd', ...
        'Minimum','Maximum', ...
        'MeanOfRecordingMeans', ...
        'BetweenRecordingStd'});

    pooledRows = [pooledRows;newRow];
end

%% 6. STATE 0 META-ANALYSIS

state0Meta = table();

if ~isempty(allState0)

    classNames = ["Short";"Long"];
    classCodes = [1;2];

    for k = 1:2

        x = allState0( ...
            allState0.Class==classCodes(k),:);

        if isempty(x)
            continue;
        end

        [n,mu,sigma,xmin,xmax] = ...
            basicStats(x.State0_ms);

        uniqueRecordings = numel( ...
            unique(x.RecordingID));

        periodMean = mean(x.Period_ms);
        otherMean = mean(x.OtherStates_ms);

        newRow = table( ...
            classNames(k),uniqueRecordings, ...
            n,periodMean,mu,sigma, ...
            xmin,xmax,otherMean, ...
            'VariableNames',{ ...
            'Group','Recordings','Intervals', ...
            'MeanPeriod_ms','MeanState0_ms', ...
            'StdState0_ms', ...
            'MinState0_ms','MaxState0_ms', ...
            'MeanOtherStates_ms'});

        state0Meta = [state0Meta;newRow];
    end
end

%% 7. STATE CONTRIBUTION META-ANALYSIS

occupancyMeta = table();

if ~isempty(allStateOccupancy)

    shortMask = allStateOccupancy.Class==1;
    longMask = allStateOccupancy.Class==2;

    for s = 0:7

        field = sprintf('State%d_ms',s);

        shortValues = ...
            allStateOccupancy.(field)(shortMask);

        longValues = ...
            allStateOccupancy.(field)(longMask);

        shortMean = meanFinite(shortValues);
        longMean = meanFinite(longValues);

        delta = longMean-shortMean;

        newRow = table( ...
            s,shortMean,longMean,delta, ...
            nnz(isfinite(shortValues)), ...
            nnz(isfinite(longValues)), ...
            'VariableNames',{ ...
            'State','ShortMean_ms', ...
            'LongMean_ms','Difference_ms', ...
            'ShortN','LongN'});

        occupancyMeta = [occupancyMeta;newRow];
    end
end

%% 8. STATE 1 META-ANALYSIS

state1Meta = table();

if ~isempty(allState1)

    fields = [
        "RawState1Count"
        "QualifiedState1Count"
        "MatchedPositiveDACCount"
        "ADCCount"
        "PhysicalPulseCount"
        "BoundaryCrossingCount"
        "TotalState1_ms"
        "QualifiedState1_ms"
        "UnqualifiedState1_ms"
    ];

    shortMask = allState1.Class==1;
    longMask = allState1.Class==2;

    for j = 1:numel(fields)

        field = char(fields(j));

        shortValues = ...
            allState1.(field)(shortMask);

        longValues = ...
            allState1.(field)(longMask);

        shortMean = meanFinite(shortValues);
        longMean = meanFinite(longValues);

        newRow = table( ...
            fields(j), ...
            nnz(isfinite(shortValues)), ...
            nnz(isfinite(longValues)), ...
            shortMean,longMean, ...
            longMean-shortMean, ...
            'VariableNames',{ ...
            'Measurement','ShortN','LongN', ...
            'ShortMean','LongMean', ...
            'Difference'});

        state1Meta = [state1Meta;newRow];
    end
end

%% 9. TIMING DISTRIBUTION CLASSIFICATION

shortPeriods = ...
    allPeriods>=cfg.shortRange_ms(1) & ...
    allPeriods<cfg.shortRange_ms(2);

longPeriods = ...
    allPeriods>=cfg.longRange_ms(1) & ...
    allPeriods<=cfg.longRange_ms(2);

otherPeriods = ~(shortPeriods | longPeriods);

periodShortStats = basicStats(allPeriods(shortPeriods));
periodLongStats = basicStats(allPeriods(longPeriods));

latencyStats = basicStats(allLatencies);

%% 10. EXPORT TABLES

writetable(inventoryRows,fullfile( ...
    cfg.outputFolder,'RecordingInventory.csv'));

writetable(allMetricRows,fullfile( ...
    cfg.outputFolder,'RecordingMetrics.csv'));

writetable(pooledRows,fullfile( ...
    cfg.outputFolder,'PooledTimingStatistics.csv'));

if ~isempty(allState0)

    writetable(allState0,fullfile( ...
        cfg.outputFolder,'AllState0Intervals.csv'));
end

if ~isempty(state0Meta)

    writetable(state0Meta,fullfile( ...
        cfg.outputFolder,'State0MetaAnalysis.csv'));
end

if ~isempty(occupancyMeta)

    writetable(occupancyMeta,fullfile( ...
        cfg.outputFolder,'StateOccupancyMetaAnalysis.csv'));
end

if ~isempty(state1Meta)

    writetable(state1Meta,fullfile( ...
        cfg.outputFolder,'State1MetaAnalysis.csv'));
end

%% 11. FIGURE 1: RECORDING-LEVEL TIMING

fig1 = figure( ...
    'Color','w', ...
    'Position',[100 100 1450 850], ...
    'Name','Recording-level timing comparison');

tl = tiledlayout(2,1, ...
    'Padding','loose', ...
    'TileSpacing','loose');

ax1 = nexttile(tl);

plotRecordingMetric( ...
    ax1,allMetricRows, ...
    "Logging update interval", ...
    nFiles);

ylabel(ax1,'Update period (ms)');
title(ax1,'Mean feedback update period by recording');
grid(ax1,'on');

ax2 = nexttile(tl);

plotRecordingMetric( ...
    ax2,allMetricRows, ...
    "Finalisation to next physical rise", ...
    nFiles);

ylabel(ax2,'Physical latency (ms)');
xlabel(ax2,'Recording ID');

title(ax2, ...
    'Mean measurement-to-output latency by recording');

grid(ax2,'on');

title(tl,'OpenXstim recording-level timing repeatability');

%% 12. FIGURE 2: POOLED PERIODS AND LATENCIES

fig2 = figure( ...
    'Color','w', ...
    'Position',[120 100 1450 780], ...
    'Name','Pooled timing distributions');

tl = tiledlayout(1,2, ...
    'Padding','loose', ...
    'TileSpacing','loose');

ax1 = nexttile(tl);

if ~isempty(allPeriods)

    histogram(ax1,allPeriods, ...
        'BinWidth',0.25);

    xlabel(ax1,'Update period (ms)');
    ylabel(ax1,'Number of intervals');

else
    showMissing(ax1,'No update intervals');
end

title(ax1,'Pooled controller update periods');
grid(ax1,'on');

ax2 = nexttile(tl);

if ~isempty(allLatencies)

    histogram(ax2,allLatencies, ...
        'BinWidth',0.25);

    xlabel(ax2,'Feedback latency (ms)');
    ylabel(ax2,'Number of intervals');

else
    showMissing(ax2,'No physical latency measurements');
end

title(ax2,'Pooled physical feedback latency');
grid(ax2,'on');

title(tl,'OpenXstim pooled timing distributions');

%% 13. FIGURE 3: STATE 0 AND STATE 1

fig3 = figure( ...
    'Color','w', ...
    'Position',[140 80 1450 850], ...
    'Name','State occupancy meta-analysis');

tl = tiledlayout(1,2, ...
    'Padding','loose', ...
    'TileSpacing','loose');

ax1 = nexttile(tl);

if ~isempty(allState0)

    shortValues = allState0.State0_ms( ...
        allState0.Class==1);

    longValues = allState0.State0_ms( ...
        allState0.Class==2);

    if ~isempty(shortValues)

        histogram(ax1,shortValues, ...
            'BinWidth',0.25, ...
            'FaceAlpha',0.6, ...
            'DisplayName','Short cycles');

        hold(ax1,'on');
    end

    if ~isempty(longValues)

        histogram(ax1,longValues, ...
            'BinWidth',0.25, ...
            'FaceAlpha',0.6, ...
            'DisplayName','Long cycles');
    end

    legend(ax1,'Location','best');

    xlabel(ax1,'State 0 occupancy (ms)');
    ylabel(ax1,'Feedback intervals');

else

    showMissing(ax1,'No State 0 timing tables');
end

title(ax1,'Pooled State 0 duration distributions');
grid(ax1,'on');

ax2 = nexttile(tl);

if ~isempty(occupancyMeta)

    barh(ax2, ...
        occupancyMeta.State, ...
        occupancyMeta.Difference_ms);

    yticks(ax2,0:7);

    yticklabels(ax2,{ ...
        '0: Idle/UI'
        '1: Positive DAC'
        '2: Settling'
        '3: ADC'
        '4: Baseline DAC'
        '5: Finalisation'
        '6: Controller'
        '7: Logging'});

    set(ax2,'YDir','reverse');

    xlabel(ax2, ...
        'Long minus short mean occupancy (ms)');

else

    showMissing(ax2, ...
        'No complete state occupancy data');
end

title(ax2,'State contributions to longer cycles');
grid(ax2,'on');

title(tl, ...
    'OpenXstim State 0 and State 1 meta-analysis');

%% 14. SAVE FIGURES

if cfg.exportFigures

    figs = [fig1 fig2 fig3];

    names = {
        'Figure1_RecordingComparison'
        'Figure2_PooledDistributions'
        'Figure3_StateOccupancy'
    };

    for j = 1:3

        base = fullfile( ...
            cfg.outputFolder,names{j});

        exportgraphics(figs(j), ...
            [base '.png'], ...
            'Resolution',cfg.figureResolution);

        savefig(figs(j),[base '.fig']);
    end
end

%% 15. HUMAN-READABLE META-ANALYSIS REPORT

reportPath = fullfile( ...
    cfg.outputFolder,'MetaAnalysis_Report.txt');

fid = fopen(reportPath,'w');

assert(fid>=0,'Unable to write meta-analysis report.');

fprintf(fid,'================================================\n');
fprintf(fid,'OPENXSTIM MULTI-RECORDING TIMING META-ANALYSIS\n');
fprintf(fid,'================================================\n\n');

fprintf(fid,'Analysis date: %s\n', ...
    datestr(now,'yyyy-mm-dd HH:MM:SS'));

fprintf(fid,'Root directory: %s\n',cfg.rootDir);
fprintf(fid,'Recordings analysed: %d\n',nFiles);

fprintf(fid,'\nRECORDING INVENTORY\n');
fprintf(fid,'------------------------------------------------\n');

for i = 1:height(inventoryRows)

    fprintf(fid,'%d. %s\n', ...
        inventoryRows.RecordingID(i), ...
        char(inventoryRows.Recording(i)));

    fprintf(fid, ...
        '   Complete physical bursts: %d/%d\n', ...
        inventoryRows.CompletePhysicalBursts(i), ...
        inventoryRows.LoggedBursts(i));

    fprintf(fid, ...
        '   Physical latency observations: %d\n', ...
        inventoryRows.ValidPhysicalLatencies(i));
end

fprintf(fid,'\nPOOLED TIMING STATISTICS\n');
fprintf(fid,'------------------------------------------------\n');

fprintf(fid, ...
    '%-37s %8s %12s %12s %5s\n', ...
    'Measurement','N','Mean','Std','Unit');

for j = 1:height(pooledRows)

    fprintf(fid, ...
        '%-37s %8d %12.4f %12.4f %5s\n', ...
        char(pooledRows.Metric(j)), ...
        pooledRows.Observations(j), ...
        pooledRows.PooledMean(j), ...
        pooledRows.PooledStd(j), ...
        char(pooledRows.Unit(j)));
end

fprintf(fid,'\nUPDATE PERIOD DISTRIBUTION\n');
fprintf(fid,'------------------------------------------------\n');

fprintf(fid,'Total valid periods: %d\n',numel(allPeriods));

fprintf(fid,'Short periods: %d\n',nnz(shortPeriods));
fprintf(fid,'Long periods: %d\n',nnz(longPeriods));
fprintf(fid,'Other periods: %d\n',nnz(otherPeriods));

fprintf(fid,'Short mean: %.4f ms\n',periodShortStats(2));
fprintf(fid,'Short std: %.4f ms\n',periodShortStats(3));

fprintf(fid,'Long mean: %.4f ms\n',periodLongStats(2));
fprintf(fid,'Long std: %.4f ms\n',periodLongStats(3));

fprintf(fid,'\nPHYSICAL FEEDBACK LATENCY\n');
fprintf(fid,'------------------------------------------------\n');

fprintf(fid,'Observations: %d\n',latencyStats(1));
fprintf(fid,'Mean: %.4f ms\n',latencyStats(2));
fprintf(fid,'Std: %.4f ms\n',latencyStats(3));
fprintf(fid,'Minimum: %.4f ms\n',latencyStats(4));
fprintf(fid,'Maximum: %.4f ms\n',latencyStats(5));

fprintf(fid,'\nSTATE 0 META-ANALYSIS\n');
fprintf(fid,'------------------------------------------------\n');

if ~isempty(state0Meta)

    for j = 1:height(state0Meta)

        fprintf(fid,'%s cycles:\n', ...
            char(state0Meta.Group(j)));

        fprintf(fid,'  Intervals: %d\n', ...
            state0Meta.Intervals(j));

        fprintf(fid,'  Mean State 0: %.4f ms\n', ...
            state0Meta.MeanState0_ms(j));

        fprintf(fid,'  Std State 0: %.4f ms\n', ...
            state0Meta.StdState0_ms(j));
    end

    if height(state0Meta)==2

        deltaIdle = ...
            state0Meta.MeanState0_ms(2)- ...
            state0Meta.MeanState0_ms(1);

        deltaPeriod = ...
            state0Meta.MeanPeriod_ms(2)- ...
            state0Meta.MeanPeriod_ms(1);

        fprintf(fid, ...
            'Long minus short State 0: %.4f ms\n', ...
            deltaIdle);

        fprintf(fid, ...
            'Long minus short update period: %.4f ms\n', ...
            deltaPeriod);
    end

else

    fprintf(fid,'No compatible State 0 data available.\n');
end

fprintf(fid,'\nSTATE 1 META-ANALYSIS\n');
fprintf(fid,'------------------------------------------------\n');

if ~isempty(state1Meta)

    for j = 1:height(state1Meta)

        fprintf(fid, ...
            '%s: short %.4f, long %.4f, delta %.4f\n', ...
            char(state1Meta.Measurement(j)), ...
            state1Meta.ShortMean(j), ...
            state1Meta.LongMean(j), ...
            state1Meta.Difference(j));
    end

else

    fprintf(fid,'No compatible State 1 audit data.\n');
end

fprintf(fid,'\nMETHODOLOGICAL NOTES\n');
fprintf(fid,'------------------------------------------------\n');

fprintf(fid, ...
    ['Pooled means and standard deviations use ' ...
     'recording-level counts and variance estimates.\n']);

fprintf(fid, ...
    ['Recording means are also retained for ' ...
     'between-recording repeatability.\n']);

fprintf(fid, ...
    ['Incomplete physical bursts are excluded ' ...
     'from burst-duration pooled statistics.\n']);

fprintf(fid, ...
    ['Each physical feedback latency observation ' ...
     'uses the original validated event pairing.\n']);

fprintf(fid, ...
    ['The 76/89 ms classes are descriptive, ' ...
     'not proof of OLED causation.\n']);

fprintf(fid, ...
    ['State 0 includes idle, waiting, UI activity ' ...
     'and GPIO transition codes.\n']);

fprintf(fid, ...
    ['Different experimental configurations ' ...
     'should not be interpreted as equivalent ' ...
     'replicates without checking the settings.\n']);

fprintf(fid,'\nEND OF REPORT\n');

fclose(fid);

%% 16. SAVE MATLAB RESULTS

save(fullfile(cfg.outputFolder, ...
    'MetaAnalysis_Results.mat'), ...
    'cfg','recordings', ...
    'inventoryRows','allMetricRows', ...
    'pooledRows','allState0','allState1', ...
    'state0Meta','state1Meta', ...
    'occupancyMeta', ...
    'allPeriods','allLatencies', ...
    'allPeriodRecordingID', ...
    'allLatencyRecordingID');

%% 17. COMMAND WINDOW SUMMARY

fprintf('\n========================================\n');
fprintf(' META-ANALYSIS COMPLETE\n');
fprintf('========================================\n');

fprintf('Recordings: %d\n',nFiles);

fprintf('Pooled update intervals: %d\n', ...
    numel(allPeriods));

fprintf('Pooled physical latencies: %d\n', ...
    numel(allLatencies));

fprintf('\nPOOLED TIMING:\n');
disp(pooledRows);

fprintf('\nSTATE 0 COMPARISON:\n');
disp(state0Meta);

fprintf('\nSTATE 1 COMPARISON:\n');
disp(state1Meta);

fprintf('\nResults saved to:\n%s\n',cfg.outputFolder);

%% ================================================================
% LOCAL HELPER FUNCTIONS
%% ================================================================

function requireVariables(T,names,path)

    missing = names( ...
        ~ismember(names,T.Properties.VariableNames));

    if ~isempty(missing)

        error( ...
            'Missing columns in %s: %s', ...
            path,strjoin(missing,', '));
    end
end

function tf = isWithinFolder(path,folder)

    path = char(path);
    folder = char(folder);

    tf = strcmp(path,folder) || ...
        startsWith(path,[folder filesep]);
end

function [n,mu,sigma,xmin,xmax] = basicStats(x)

    x = double(x(:));
    x = x(isfinite(x));

    n = numel(x);
    mu = NaN;
    sigma = NaN;
    xmin = NaN;
    xmax = NaN;

    if n==0
        return;
    end

    mu = mean(x);
    xmin = min(x);
    xmax = max(x);

    if n>1
        sigma = std(x);
    end
end

function value = meanFinite(x)

    x = double(x(:));
    x = x(isfinite(x));

    if isempty(x)
        value = NaN;
    else
        value = mean(x);
    end
end

function plotRecordingMetric(ax,T,name,nFiles)

    ids = 1:nFiles;
    values = NaN(nFiles,1);

    for k = 1:nFiles

        mask = T.RecordingID==k & ...
            T.Metric==name & ...
            T.N>0;

        if any(mask)
            values(k) = T.Mean(find(mask,1));
        end
    end

    if ~any(isfinite(values))

        showMissing(ax, ...
            'No valid recording-level measurements');

        return;
    end

    plot(ax,ids,values,'o-', ...
        'LineWidth',1.1,'MarkerSize',6);

    xticks(ax,ids);
end

function showMissing(ax,message)

    text(ax,0.5,0.5,message, ...
        'Units','normalized', ...
        'HorizontalAlignment','center', ...
        'VerticalAlignment','middle');

    axis(ax,'off');
end
