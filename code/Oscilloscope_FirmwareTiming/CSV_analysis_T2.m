
%% ================================================================
% OPENXSTIM - OSCILLOSCOPE TIMING ANALYSIS
%
% OpenXstim v1.3 / Arduino Uno R4 / AD5722
% Monophasic stimulation, bench loads only
%
% SINGLE CSV PER RUN
%
% CH1: Load voltage
% CH2: Debug bit 0 (D5)
% CH3: Debug bit 1 (D8)
% CH4: Debug bit 2 (A2)
%
% Automatically saves:
%   - Readable TXT report
%   - Summary and detailed CSV tables
%   - Three PNG figures
%   - Three editable MATLAB FIG figures
%   - Compact MAT results file
%
% Output folder derives from CSV name:
% RigolDS0.csv -> DS0
% RigolDS1.csv -> DS1
%
% No batch processing or additional toolboxes.
%% ================================================================

clear;
clc;
close all;

%% 1. USER CONFIGURATION

% CHANGE THIS FOR EACH EXPERIMENT.
cfg.filename = 'RigolDS5.csv';

% Use the full oscilloscope resolution.
cfg.downsampleFactor = 1;

cfg.expectedPulses = 20;
cfg.adcSamplesPerPulse = 8;

% NaN means automatic digital threshold detection.
cfg.digitalThresholds = [NaN NaN NaN];

% Valid execution-state duration ranges in microseconds.
cfg.adcRange_us = [150 210];
cfg.settleRange_us = [150 300];
cfg.positiveRange_us = [700 1100];
cfg.baselineRange_us = [400 1100];
cfg.finalRange_us = [2 20];
cfg.controlRange_us = [6 100];
cfg.loggingRange_us = [400 2000];

% Physical HIGH pulse duration range.
cfg.highDurationRange_us = [300 1800];

% Firmware event matching tolerances.
cfg.maxDACToRise_us = 1300;
cfg.maxSettleToADC_us = 500;
cfg.maxADCToBaseline_us = 80;
cfg.maxBaselineEndError_us = 50;

% Set ONLY if CH1 is across a known resistor.
% For example, 1000 for a verified 1 kohm resistor.
cfg.loadResistanceOhm = NaN;

% Figure settings.
cfg.figureResolution = 250;
cfg.maxPlotPoints = 25000;

% Retain editable MATLAB figure files.
cfg.saveMATLABFigures = true;

stateNames = [
    "Idle"
    "Positive DAC"
    "ADC settling"
    "ADC acquisition"
    "Baseline DAC"
    "Measurement finalisation"
    "Controller and supervisor"
    "CSV logging"
];

%% 2. FILE PATHS AND UNIQUE OUTPUT FOLDER

% Resolve CSV relative to the MATLAB script's directory,
% independently of MATLAB's current working directory.

scriptPath = mfilename('fullpath');
scriptDir = fileparts(scriptPath);

if isempty(scriptDir)
    scriptDir = pwd;
end

csvPath = fullfile(scriptDir,cfg.filename);

assert(isfile(csvPath), ...
    'Cannot find CSV: %s',csvPath);

[~,csvName,~] = fileparts(cfg.filename);

% RigolDS0 -> DS0
% RigolDS12 -> DS12
% Other filenames use their own sanitised basename.

nameTokens = regexpi(csvName, ...
    '^RigolDS(\d+)$','tokens','once');

if ~isempty(nameTokens)
    outputName = ['DS' nameTokens{1}];
else
    outputName = regexprep(csvName, ...
        '[^a-zA-Z0-9_-]','_');
end

outputDir = fullfile(scriptDir,outputName);

if ~isfolder(outputDir)
    mkdir(outputDir);
end

reportPath = fullfile(outputDir, ...
    [outputName '_Report.txt']);

fprintf('\n========================================\n');
fprintf(' OPENXSTIM TIMING ANALYSIS\n');
fprintf('========================================\n');
fprintf('Source: %s\n',cfg.filename);
fprintf('Output folder: %s\n',outputDir);

%% 3. IMPORT RIGOL CSV

fid = fopen(csvPath,'r');
assert(fid>=0,'Unable to open CSV.');

header = fgetl(fid);

numberPattern = ...
    '([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)';

t0Match = regexp(header, ...
    ['t0\s*=\s*' numberPattern], ...
    'tokens','once');

dtMatch = regexp(header, ...
    ['tInc\s*=\s*' numberPattern], ...
    'tokens','once');

assert(~isempty(t0Match), ...
    'Missing t0 in Rigol header.');

assert(~isempty(dtMatch), ...
    'Missing tInc in Rigol header.');

t0 = str2double(t0Match{1});
originalDt = str2double(dtMatch{1});

assert(isfinite(t0) && ...
    isfinite(originalDt) && originalDt>0, ...
    'Invalid Rigol timing metadata.');

assert(cfg.downsampleFactor>=1 && ...
    cfg.downsampleFactor==floor(cfg.downsampleFactor), ...
    'Downsampling factor must be a positive integer.');

info = dir(csvPath);

estimatedRows = max(1000, ...
    ceil(info.bytes/55/cfg.downsampleFactor));

V = zeros(estimatedRows,4);
sampleIndex = zeros(estimatedRows,1);

nStored = 0;
nOriginal = 0;
badRows = 0;

fprintf('\nImporting %s...\n',cfg.filename);

importTimer = tic;

while ~feof(fid)

    line = fgetl(fid);

    if ~ischar(line)
        break;
    end

    if mod(nOriginal,cfg.downsampleFactor)==0

        values = sscanf( ...
            strrep(line,',',' '),'%f',4);

        nStored = nStored+1;

        if nStored>size(V,1)
            V(end+100000,4) = 0;
            sampleIndex(end+100000,1) = 0;
        end

        if numel(values)==4 && all(isfinite(values))
            V(nStored,:) = values(:)';
        else
            badRows = badRows+1;
        end

        sampleIndex(nStored) = nOriginal;
    end

    nOriginal = nOriginal+1;
end

fclose(fid);

assert(badRows==0, ...
    'Malformed selected rows: %d',badRows);

V = V(1:nStored,:);
sampleIndex = sampleIndex(1:nStored);

t = t0+sampleIndex*originalDt;

N = numel(t);
dt = originalDt*cfg.downsampleFactor;
fs = 1/dt;
duration_s = t(end)-t(1);
importSeconds = toc(importTimer);

assert(N>100,'Insufficient samples.');

fprintf('Samples: %d\n',N);
fprintf('Sampling rate: %.6f MHz\n',fs/1e6);
fprintf('Resolution: %.3f us\n',dt*1e6);
fprintf('Duration: %.6f s\n',duration_s);
fprintf('Import time: %.2f s\n',importSeconds);

channelNumber = (1:4)';
minimum_V = min(V,[],1)';
maximum_V = max(V,[],1)';

channelTable = table( ...
    channelNumber,minimum_V,maximum_V);

%% 4. DIGITAL THRESHOLDING

bits = false(N,3);
usedThresholds = zeros(1,3);

for ch = 1:3

    signal = V(:,ch+1);

    testValues = sort(signal(1:100:end));
    nTest = numel(testValues);

    loIdx = max(1,round(0.02*nTest));
    hiIdx = min(nTest,round(0.98*nTest));

    lowDigital = testValues(loIdx);
    highDigital = testValues(hiIdx);

    if isnan(cfg.digitalThresholds(ch))
        threshold = (lowDigital+highDigital)/2;
    else
        threshold = cfg.digitalThresholds(ch);
    end

    assert(highDigital-lowDigital>1, ...
        'CH%d lacks distinguishable logic levels.', ...
        ch+1);

    bits(:,ch) = signal>=threshold;
    usedThresholds(ch) = threshold;
end

%% 5. DECODE RAW FIRMWARE STATES

rawState = uint8(bits(:,1)) ...
    + uint8(2)*uint8(bits(:,2)) ...
    + uint8(4)*uint8(bits(:,3));

[segStart,segEnd,segCode] = ...
    stateSegments(rawState);

segT0 = t(segStart);
segT1 = t(segEnd)+dt;
segDuration = segT1-segT0;

% Preserve the original GPIO state sequence.
% Do not indiscriminately discard short states.

stateNumber = (0:7)';

occurrences = zeros(8,1);
mean_us = NaN(8,1);
median_us = NaN(8,1);
std_us = NaN(8,1);
min_us = NaN(8,1);
max_us = NaN(8,1);
shortCount = zeros(8,1);

for s = 0:7

    x = segDuration(segCode==s)*1e6;

    occurrences(s+1) = numel(x);

    if isempty(x)
        continue;
    end

    mean_us(s+1) = mean(x);
    median_us(s+1) = median(x);
    min_us(s+1) = min(x);
    max_us(s+1) = max(x);

    if numel(x)>1
        std_us(s+1) = std(x);
    end

    shortCount(s+1) = nnz(x<=6);
end

stateTable = table( ...
    stateNumber,stateNames,occurrences, ...
    mean_us,median_us,std_us, ...
    min_us,max_us,shortCount);

%% 6. QUALIFY EXECUTION EVENTS

adcSeg = qualifySegments( ...
    segCode,segDuration,3,cfg.adcRange_us);

settleSeg = qualifySegments( ...
    segCode,segDuration,2,cfg.settleRange_us);

posSeg = qualifySegments( ...
    segCode,segDuration,1,cfg.positiveRange_us);

baseSeg = qualifySegments( ...
    segCode,segDuration,4,cfg.baselineRange_us);

finalSeg = qualifySegments( ...
    segCode,segDuration,5,cfg.finalRange_us);

controlSeg = qualifySegments( ...
    segCode,segDuration,6,cfg.controlRange_us);

logSeg = qualifySegments( ...
    segCode,segDuration,7,cfg.loggingRange_us);

nADC = numel(adcSeg);

adcStartTimes = segT0(adcSeg);
adcEndTimes = segT1(adcSeg);

fprintf('\nQualified ADC windows: %d\n',nADC);
fprintf('Logging markers: %d\n',numel(logSeg));

%% 7. DETECT PHYSICAL OUTPUT PULSES

loadV = V(:,1);

% Estimate voltage levels from the extremes of a
% sparsely sampled distribution.
%
% This avoids assuming that the output must be
% near 0 V and 10 V for every experiment.

probe = sort(loadV(1:50:end));
nProbe = numel(probe);

edgeCount = max(1,round(0.01*nProbe));

lowLevel = median(probe(1:edgeCount));
highLevel = median(probe(end-edgeCount+1:end));

physicalAvailable = highLevel-lowLevel>0.5;

riseThreshold = NaN;
physicalRiseTimes = [];
physicalFallTimes = [];
highWidth_us = [];

if physicalAvailable

    riseThreshold = (lowLevel+highLevel)/2;

    loadHigh = loadV>=riseThreshold;

    riseIndex = find( ...
        ~loadHigh(1:end-1) & ...
        loadHigh(2:end))+1;

    fallIndex = find( ...
        loadHigh(1:end-1) & ...
        ~loadHigh(2:end))+1;

    % Pair rising and falling edges in chronological
    % order. Unpaired capture-edge transitions are
    % not assumed to form complete pulses.

    r = 1;
    f = 1;

    while r<=numel(riseIndex) && ...
          f<=numel(fallIndex)

        while f<=numel(fallIndex) && ...
              fallIndex(f)<=riseIndex(r)
            f = f+1;
        end

        if f>numel(fallIndex)
            break;
        end

        if r<numel(riseIndex) && ...
           riseIndex(r+1)<fallIndex(f)

            r = r+1;
            continue;
        end

        width_us = ...
            (t(fallIndex(f))-t(riseIndex(r)))*1e6;

        if width_us>=cfg.highDurationRange_us(1) && ...
           width_us<=cfg.highDurationRange_us(2)

            physicalRiseTimes(end+1,1) = ...
                t(riseIndex(r));

            physicalFallTimes(end+1,1) = ...
                t(fallIndex(f));

            highWidth_us(end+1,1) = width_us;
        end

        r = r+1;
        f = f+1;
    end
end

fprintf('Qualified physical pulses: %d\n', ...
    numel(physicalRiseTimes));

%% 8. MATCH PHYSICAL PULSES TO ADC WINDOWS

pulseRise_s = NaN(nADC,1);
pulseFall_s = NaN(nADC,1);
pulseHighWidth_us = NaN(nADC,1);

for k = 1:nADC

    candidate = find( ...
        physicalRiseTimes<=adcStartTimes(k) & ...
        physicalFallTimes>=adcEndTimes(k), ...
        1,'last');

    if isempty(candidate)
        continue;
    end

    pulseRise_s(k) = physicalRiseTimes(candidate);
    pulseFall_s(k) = physicalFallTimes(candidate);
    pulseHighWidth_us(k) = ...
        highWidth_us(candidate);
end

physicalMatchCount = nnz(isfinite(pulseRise_s));

%% 9. MATCH INDIVIDUAL FIRMWARE PHASES

positiveMarker = NaN(nADC,1);
settleMarker = NaN(nADC,1);
baselineMarker = NaN(nADC,1);

positive_us = NaN(nADC,1);
settling_us = NaN(nADC,1);
acquisition_us = segDuration(adcSeg)*1e6;
baseline_us = NaN(nADC,1);

positiveToRise_us = NaN(nADC,1);
baselineToFall_us = NaN(nADC,1);

for k = 1:nADC

    a0 = adcStartTimes(k);
    a1 = adcEndTimes(k);

    % Settling marker immediately before ADC.
    candidates = settleSeg( ...
        segT0(settleSeg)>= ...
        a0-cfg.maxSettleToADC_us*1e-6 & ...
        segT1(settleSeg)<=a0+2*dt);

    if ~isempty(candidates)

        [~,j] = max(segT1(candidates));
        s = candidates(j);

        settleMarker(k) = s;
        settling_us(k) = segDuration(s)*1e6;
    end

    r = pulseRise_s(k);
    f = pulseFall_s(k);

    if ~isfinite(r) || ~isfinite(f)
        continue;
    end

    % Positive DAC marker before physical rise.
    candidates = posSeg( ...
        segT0(posSeg)>= ...
        r-cfg.maxDACToRise_us*1e-6 & ...
        segT0(posSeg)<r & ...
        segT1(posSeg)<=r+2*dt);

    if ~isempty(candidates)

        [~,j] = max(segDuration(candidates));
        s = candidates(j);

        positiveMarker(k) = s;
        positive_us(k) = segDuration(s)*1e6;

        positiveToRise_us(k) = ...
            (r-segT0(s))*1e6;
    end

    % Baseline DAC marker following ADC.
    candidates = baseSeg( ...
        segT0(baseSeg)>=a1-2*dt & ...
        segT0(baseSeg)<= ...
        a1+cfg.maxADCToBaseline_us*1e-6 & ...
        abs(segT1(baseSeg)-f)<= ...
        cfg.maxBaselineEndError_us*1e-6);

    if ~isempty(candidates)

        [~,j] = min( ...
            abs(segT1(candidates)-f));

        s = candidates(j);

        baselineMarker(k) = s;
        baseline_us(k) = segDuration(s)*1e6;

        baselineToFall_us(k) = ...
            (f-segT0(s))*1e6;
    end
end

fullyMatched = ...
    isfinite(positiveMarker) & ...
    isfinite(settleMarker) & ...
    isfinite(baselineMarker) & ...
    isfinite(pulseRise_s);

%% 10. BASELINE AND PLATEAU VOLTAGES

pulseBaseline_V = NaN(nADC,1);
pulsePlateau_V = NaN(nADC,1);

for k = 1:nADC

    if ~isfinite(pulseRise_s(k))
        continue;
    end

    r = pulseRise_s(k);

    % Baseline before physical rise.
    pulseBaseline_V(k) = intervalMedian( ...
        loadV,r-200e-6,r-50e-6,t(1),dt);

    % Plateau within ADC acquisition window.
    pulsePlateau_V(k) = intervalMedian( ...
        loadV, ...
        adcStartTimes(k)+20e-6, ...
        adcEndTimes(k)-20e-6, ...
        t(1),dt);
end

pulseAmplitude_V = ...
    pulsePlateau_V-pulseBaseline_V;

pulseCurrent_mA = NaN(nADC,1);

if isfinite(cfg.loadResistanceOhm) && ...
        cfg.loadResistanceOhm>0

    pulseCurrent_mA = ...
        1000*pulseAmplitude_V/cfg.loadResistanceOhm;
end

%% 11. FEEDBACK BURSTS

% Each qualified State 7 event closes one burst.
%
% Unlike a State 7-to-State 7 interval, this
% also allows us to analyse a single logged burst.
%
% The first burst may start before the recording.
% Its completeness must be verified independently.

logTimes = segT0(logSeg);

nBursts = numel(logTimes);
burstID = (1:nBursts)';

burstStartBoundary_s = NaN(nBursts,1);
burstLogTime_s = logTimes;

adcCount = zeros(nBursts,1);
positiveCount = zeros(nBursts,1);
baselineCount = zeros(nBursts,1);

burstFirstRise_s = NaN(nBursts,1);
burstLastFall_s = NaN(nBursts,1);
burstLastADCend_s = NaN(nBursts,1);

burstFinalStart_s = NaN(nBursts,1);
burstFinalEnd_s = NaN(nBursts,1);

burstPlateau_V = NaN(nBursts,1);
burstBaseline_V = NaN(nBursts,1);

burstAcquisition_ms = NaN(nBursts,1);
burstPhysical_ms = NaN(nBursts,1);

pulsePeriod_us = [];

for k = 1:nBursts

    if k==1
        left = t(1);
    else
        left = logTimes(k-1);
    end

    right = logTimes(k);

    if k>1
        burstStartBoundary_s(k) = left;
    end

    ids = find( ...
        adcStartTimes>left & ...
        adcEndTimes<right);

    adcCount(k) = numel(ids);

    positiveCount(k) = nnz( ...
        segT0(posSeg)>left & ...
        segT0(posSeg)<right);

    baselineCount(k) = nnz( ...
        segT0(baseSeg)>left & ...
        segT0(baseSeg)<right);

    if isempty(ids)
        continue;
    end

    burstLastADCend_s(k) = ...
        adcEndTimes(ids(end));

    if numel(ids)==cfg.expectedPulses

        pulsePeriod_us = [pulsePeriod_us; ...
            diff(adcStartTimes(ids))*1e6];
    end

    if all(isfinite(pulseRise_s(ids))) && ...
       all(isfinite(pulseFall_s(ids)))

        burstFirstRise_s(k) = ...
            pulseRise_s(ids(1));

        burstLastFall_s(k) = ...
            pulseFall_s(ids(end));

        burstPhysical_ms(k) = ...
            (burstLastFall_s(k)- ...
             burstFirstRise_s(k))*1e3;

        burstAcquisition_ms(k) = ...
            (burstLastADCend_s(k)- ...
             burstFirstRise_s(k))*1e3;
    end

    plateaus = pulsePlateau_V(ids);
    plateaus = plateaus(isfinite(plateaus));

    if ~isempty(plateaus)
        burstPlateau_V(k) = median(plateaus);
    end

    baselines = pulseBaseline_V(ids);
    baselines = baselines(isfinite(baselines));

    if ~isempty(baselines)
        burstBaseline_V(k) = median(baselines);
    end

    % Finalisation after the final ADC window.
    finals = finalSeg( ...
        segT0(finalSeg)>burstLastADCend_s(k) & ...
        segT0(finalSeg)<right);

    if numel(finals)==1

        f = finals(1);

        burstFinalStart_s(k) = segT0(f);
        burstFinalEnd_s(k) = segT1(f);
    end
end

completeADC = adcCount==cfg.expectedPulses;

completePhysical = completeADC & ...
    isfinite(burstFirstRise_s) & ...
    isfinite(burstLastFall_s);

completeFeedback = completePhysical & ...
    isfinite(burstFinalEnd_s);

%% 12. CONTROLLER UPDATE PERIOD

% Periods are measured between consecutive markers.
% A one-burst capture cannot establish a period.

Ts_logging_ms = diff(logTimes)*1e3;

Ts_controller_ms = [];

finalTimes = segT0(finalSeg);

if numel(finalSeg)>=2 && ...
   numel(finalSeg)==numel(logSeg)

    aligned = all( ...
        finalTimes<logTimes & ...
        finalTimes>logTimes-0.010);

    if aligned
        Ts_controller_ms = ...
            diff(finalTimes)*1e3;
    end
end

% Align each logging period to the earlier burst.
Ts_afterBurst_ms = NaN(nBursts,1);

if nBursts>=2
    Ts_afterBurst_ms(1:end-1) = ...
        Ts_logging_ms;
end

%% 13. PHYSICAL FEEDBACK LATENCY

finalADCToRise_ms = NaN(nBursts,1);
finalisationToRise_ms = NaN(nBursts,1);

finalADCToDACMarker_ms = NaN(nBursts,1);
finalisationToDACMarker_ms = NaN(nBursts,1);

nextBurstRise_s = NaN(nBursts,1);

for k = 1:nBursts

    if ~completeFeedback(k)
        continue;
    end

    % First ADC window following this logging event.
    nextADC = find( ...
        adcStartTimes>logTimes(k),1,'first');

    if isempty(nextADC)
        continue;
    end

    nextRise = pulseRise_s(nextADC);

    if ~isfinite(nextRise) || ...
       nextRise<=logTimes(k)
        continue;
    end

    nextBurstRise_s(k) = nextRise;

    finalADCToRise_ms(k) = ...
        (nextRise-burstLastADCend_s(k))*1e3;

    finalisationToRise_ms(k) = ...
        (nextRise-burstFinalEnd_s(k))*1e3;

    % DAC marker measurement is supplementary.
    p = positiveMarker(nextADC);

    if isfinite(p)

        markerTime = segT0(p);

        if markerTime>logTimes(k)

            finalADCToDACMarker_ms(k) = ...
                (markerTime- ...
                 burstLastADCend_s(k))*1e3;

            finalisationToDACMarker_ms(k) = ...
                (markerTime- ...
                 burstFinalEnd_s(k))*1e3;
        end
    end
end

%% 14. PER-PULSE AND PER-BURST TABLES

pulseNumber = (1:nADC)';
pulseBurst = NaN(nADC,1);

for k = 1:nBursts

    if k==1
        left = t(1);
    else
        left = logTimes(k-1);
    end

    mask = adcStartTimes>left & ...
        adcStartTimes<logTimes(k);

    pulseBurst(mask) = k;
end

pulseTable = table( ...
    pulseNumber,pulseBurst, ...
    adcStartTimes,adcEndTimes, ...
    pulseRise_s,pulseFall_s, ...
    positive_us,settling_us, ...
    acquisition_us,baseline_us, ...
    positiveToRise_us,baselineToFall_us, ...
    pulseHighWidth_us, ...
    pulseBaseline_V,pulsePlateau_V, ...
    pulseAmplitude_V,pulseCurrent_mA, ...
    fullyMatched);

burstTable = table( ...
    burstID,burstStartBoundary_s,burstLogTime_s, ...
    adcCount,positiveCount,baselineCount, ...
    completeADC,completePhysical,completeFeedback, ...
    burstFirstRise_s,burstLastFall_s, ...
    burstLastADCend_s, ...
    burstFinalStart_s,burstFinalEnd_s, ...
    burstBaseline_V,burstPlateau_V, ...
    burstAcquisition_ms,burstPhysical_ms, ...
    Ts_afterBurst_ms, ...
    nextBurstRise_s, ...
    finalADCToRise_ms,finalisationToRise_ms, ...
    finalADCToDACMarker_ms, ...
    finalisationToDACMarker_ms);

%% 15. NUMERICAL SUMMARY

metricNames = [
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

metricUnits = [
    "us";"us";"us";"us";"us";"us"
    "ms";"ms";"ms";"ms";"ms";"ms"
    "ms";"ms";"us";"us";"us";"us"
    "V";"V";"V"
];

metricData = {
    positive_us
    settling_us
    acquisition_us
    baseline_us
    pulsePeriod_us
    pulseHighWidth_us
    burstAcquisition_ms
    burstPhysical_ms
    Ts_controller_ms
    Ts_logging_ms
    finalADCToRise_ms
    finalisationToRise_ms
    finalADCToDACMarker_ms
    finalisationToDACMarker_ms
    positiveToRise_us
    segDuration(finalSeg)*1e6
    segDuration(controlSeg)*1e6
    segDuration(logSeg)*1e6
    pulseBaseline_V
    pulsePlateau_V
    pulseAmplitude_V
};

assert(numel(metricNames)==numel(metricData) && ...
    numel(metricNames)==numel(metricUnits), ...
    'Metric configuration mismatch.');

nMetrics = numel(metricNames);

metricN = zeros(nMetrics,1);
metricMean = NaN(nMetrics,1);
metricMedian = NaN(nMetrics,1);
metricStd = NaN(nMetrics,1);
metricMin = NaN(nMetrics,1);
metricMax = NaN(nMetrics,1);

for k = 1:nMetrics

    x = metricData{k};
    x = x(isfinite(x));

    metricN(k) = numel(x);

    if isempty(x)
        continue;
    end

    metricMean(k) = mean(x);
    metricMedian(k) = median(x);
    metricMin(k) = min(x);
    metricMax(k) = max(x);

    if numel(x)>1
        metricStd(k) = std(x);
    end
end

summaryTable = table( ...
    metricNames,metricUnits,metricN, ...
    metricMean,metricMedian,metricStd, ...
    metricMin,metricMax);

%% 16. QUALITY ASSESSMENT

nFullADC = nnz(completeADC);
nFullPhysical = nnz(completePhysical);
nFullFeedback = nnz(completeFeedback);

nPhysicalLatencies = ...
    nnz(isfinite(finalisationToRise_ms));

nFullyMatched = nnz(fullyMatched);

nShortSegments = nnz(segDuration<=6e-6);

nExtraBaselineConfirmed = ...
    nnz(baselineCount==cfg.expectedPulses+1);

missingStates = find(occurrences==0)-1;

% Identify common logging periods to 0.1 ms.
periodValues = [];
periodCounts = [];

if ~isempty(Ts_logging_ms)

    roundedPeriod = ...
        round(Ts_logging_ms*10)/10;

    [periodValues,~,periodGroup] = ...
        unique(roundedPeriod);

    periodCounts = ...
        accumarray(periodGroup,1);
end



%% 16A. STATE 0 IDLE / OLED TIMING INVESTIGATION

% Each interval starts at one State 7 marker and ends
% at the next State 7 marker.
%
% Interval k contains the acquisition burst associated
% with completeFeedback(k+1).
%
% Sum all raw decoded state durations, clipping segments
% at interval boundaries. This includes multiple
% separate State 0 segments.
%
% State 0 also includes UI operations, delays and
% short intermediate GPIO codes. It is NOT an OLED
% activity marker by itself.

oledRefresh_ms = 150;  % From existing firmware

nUpdateIntervals = max(0,numel(logTimes)-1);

updateIntervalID = (1:nUpdateIntervals)';

updatePeriod_ms = diff(logTimes(:))*1e3;

% Columns correspond to states 0 through 7.
stateDurations_ms = zeros(nUpdateIntervals,8);

idleSegmentCount = zeros(nUpdateIntervals,1);
shortIdleCode_ms = zeros(nUpdateIntervals,1);

% Separate idle occupancy by physical burst phase.
idleBeforeFirstRise_ms = NaN(nUpdateIntervals,1);
idleDuringBurst_ms = NaN(nUpdateIntervals,1);
idleAfterLastFall_ms = NaN(nUpdateIntervals,1);

completeUpdateInterval = false(nUpdateIntervals,1);

for k = 1:nUpdateIntervals

    left = logTimes(k);
    right = logTimes(k+1);

    % The following logged burst belongs to this
    % State 7-to-State 7 interval.
    completeUpdateInterval(k) = completeFeedback(k+1);

    % All eight state durations, with exact boundary
    % clipping to avoid double-counting.
    [durationsRow,nIdle,nShortIdle] = ...
        clippedStateTiming( ...
        segT0,segT1,segCode,left,right);

    stateDurations_ms(k,:) = durationsRow;
    idleSegmentCount(k) = nIdle;
    shortIdleCode_ms(k) = nShortIdle;

    if ~completePhysical(k+1)
        continue;
    end

    firstRise = burstFirstRise_s(k+1);
    lastFall = burstLastFall_s(k+1);

    if ~isfinite(firstRise) || ...
       ~isfinite(lastFall) || ...
       firstRise<=left || ...
       lastFall<=firstRise || ...
       lastFall>=right
        continue;
    end

    % State 0 after previous logging begins but
    % before the first physical output rise.
    [x,~,~] = clippedStateTiming( ...
        segT0,segT1,segCode,left,firstRise);

    idleBeforeFirstRise_ms(k) = x(1);

    % State 0 during the physical 20-pulse burst.
    [x,~,~] = clippedStateTiming( ...
        segT0,segT1,segCode,firstRise,lastFall);

    idleDuringBurst_ms(k) = x(1);

    % State 0 after the final voltage fall until
    % the next logging event begins.
    [x,~,~] = clippedStateTiming( ...
        segT0,segT1,segCode,lastFall,right);

    idleAfterLastFall_ms(k) = x(1);
end

% Total time in State 0 and time in all other states.
state0Total_ms = stateDurations_ms(:,1);

nonIdleTotal_ms = ...
    sum(stateDurations_ms(:,2:8),2);

% An independent conservation check.
% These must sum to the measured cycle period.
closureError_us = ...
    (sum(stateDurations_ms,2)-updatePeriod_ms)*1e3;

if ~isempty(closureError_us)

    maxClosureError_us = max(abs(closureError_us));

    if maxClosureError_us > max(1,2*dt*1e6)

        warning(['State duration sum does not ' ...
            'match the measured update period.']);
    end
else
    maxClosureError_us = NaN;
end

%% 16B. CLASSIFY COMPLETE SHORT/LONG CYCLES

% These ranges cover the previously observed
% approximately 76 ms and 89 ms update periods.
%
% They are classification windows, not assumed
% actual durations.

shortUpdate = ...
    completeUpdateInterval & ...
    updatePeriod_ms>=74 & ...
    updatePeriod_ms<82;

longUpdate = ...
    completeUpdateInterval & ...
    updatePeriod_ms>=82 & ...
    updatePeriod_ms<=91;

otherUpdate = ...
    completeUpdateInterval & ...
    ~(shortUpdate | longUpdate);

nShortUpdate = nnz(shortUpdate);
nLongUpdate = nnz(longUpdate);

shortIdleStats = timingStatsMs( ...
    state0Total_ms(shortUpdate));

longIdleStats = timingStatsMs( ...
    state0Total_ms(longUpdate));

state0GroupTable = table( ...
    ["Short";"Long"], ...
    [nShortUpdate;nLongUpdate], ...
    [shortIdleStats(2);longIdleStats(2)], ...
    [shortIdleStats(3);longIdleStats(3)], ...
    [shortIdleStats(4);longIdleStats(4)], ...
    [shortIdleStats(5);longIdleStats(5)], ...
    [meanOrNaN(idleSegmentCount(shortUpdate)); ...
     meanOrNaN(idleSegmentCount(longUpdate))], ...
    'VariableNames',{ ...
    'Group','N','Mean_ms','Std_ms', ...
    'Minimum_ms','Maximum_ms', ...
    'MeanIdleSegments'});

%% 16C. DECOMPOSE 13 MS DIFFERENCE BY STATE

meanStateShort_ms = NaN(8,1);
meanStateLong_ms = NaN(8,1);

if nShortUpdate>0
    meanStateShort_ms = ...
        mean(stateDurations_ms(shortUpdate,:),1)';
end

if nLongUpdate>0
    meanStateLong_ms = ...
        mean(stateDurations_ms(longUpdate,:),1)';
end

stateDifference_ms = ...
    meanStateLong_ms-meanStateShort_ms;

stateContributionTable = table( ...
    (0:7)',stateNames, ...
    meanStateShort_ms,meanStateLong_ms, ...
    stateDifference_ms, ...
    'VariableNames',{ ...
    'State','Name', ...
    'ShortMean_ms','LongMean_ms', ...
    'LongMinusShort_ms'});

deltaTs_ms = NaN;
deltaState0_ms = NaN;
deltaNonIdle_ms = NaN;
idleExplained_pct = NaN;

if nShortUpdate>0 && nLongUpdate>0

    deltaTs_ms = ...
        mean(updatePeriod_ms(longUpdate)) - ...
        mean(updatePeriod_ms(shortUpdate));

    deltaState0_ms = stateDifference_ms(1);

    deltaNonIdle_ms = ...
        sum(stateDifference_ms(2:8));

    if abs(deltaTs_ms)>eps
        idleExplained_pct = ...
            100*deltaState0_ms/deltaTs_ms;
    end
end

% Locate the idle difference relative to the burst.
deltaIdleBefore_ms = NaN;
deltaIdleDuring_ms = NaN;
deltaIdleAfter_ms = NaN;
deltaShortIdleCode_ms = NaN;

if nShortUpdate>0 && nLongUpdate>0

    deltaIdleBefore_ms = ...
        meanOrNaN(idleBeforeFirstRise_ms(longUpdate)) - ...
        meanOrNaN(idleBeforeFirstRise_ms(shortUpdate));

    deltaIdleDuring_ms = ...
        meanOrNaN(idleDuringBurst_ms(longUpdate)) - ...
        meanOrNaN(idleDuringBurst_ms(shortUpdate));

    deltaIdleAfter_ms = ...
        meanOrNaN(idleAfterLastFall_ms(longUpdate)) - ...
        meanOrNaN(idleAfterLastFall_ms(shortUpdate));

    deltaShortIdleCode_ms = ...
        mean(shortIdleCode_ms(longUpdate)) - ...
        mean(shortIdleCode_ms(shortUpdate));
end

%% 16D. TEST ALTERNATION AND OLED COMPATIBILITY

% Class 1 = short, class 2 = long, class 0 = other.
updateClass = zeros(nUpdateIntervals,1);

updateClass(shortUpdate) = 1;
updateClass(longUpdate) = 2;

classifiedID = find(updateClass>0);

strictAlternation = false;

if numel(classifiedID)>=2

    % Require consecutive qualifying intervals and
    % alternation on every neighbouring pair.
    strictAlternation = ...
        all(diff(classifiedID)==1) && ...
        all(diff(updateClass(classifiedID))~=0) && ...
        nnz(otherUpdate)==0;
end

% Two consecutive update intervals together.
twoCycle_ms = [];

if nUpdateIntervals>=2

    pairsValid = ...
        completeUpdateInterval(1:end-1) & ...
        completeUpdateInterval(2:end);

    pairPeriods = ...
        updatePeriod_ms(1:end-1) + ...
        updatePeriod_ms(2:end);

    twoCycle_ms = pairPeriods(pairsValid);
end

%% 16E. PER-CYCLE TABLE

state0IntervalTable = table( ...
    updateIntervalID, ...
    logTimes(1:end-1),logTimes(2:end), ...
    completeUpdateInterval, ...
    updateClass,updatePeriod_ms, ...
    state0Total_ms,nonIdleTotal_ms, ...
    idleSegmentCount,shortIdleCode_ms, ...
    idleBeforeFirstRise_ms, ...
    idleDuringBurst_ms, ...
    idleAfterLastFall_ms, ...
    closureError_us, ...
    'VariableNames',{ ...
    'Interval','Start_s','End_s', ...
    'Complete','Class','Period_ms', ...
    'State0_ms','OtherStates_ms', ...
    'State0Segments','ShortState0_ms', ...
    'IdleBeforeRise_ms', ...
    'IdleDuringBurst_ms', ...
    'IdleAfterFall_ms', ...
    'ClosureError_us'});

% Add individual state occupancy for auditing.
for s = 0:7

    columnName = sprintf('State%d_ms',s);

    state0IntervalTable.(columnName) = ...
        stateDurations_ms(:,s+1);
end

%% 16F. COMMAND WINDOW SUMMARY

fprintf('\n========================================\n');
fprintf(' STATE 0 / OLED TIMING INVESTIGATION\n');
fprintf('========================================\n');

fprintf('Complete update intervals: %d/%d\n', ...
    nnz(completeUpdateInterval),nUpdateIntervals);

fprintf('Short update intervals: %d\n',nShortUpdate);
fprintf('Long update intervals: %d\n',nLongUpdate);
fprintf('Other complete intervals: %d\n', ...
    nnz(otherUpdate));

fprintf('Maximum timing closure error: %.6f us\n', ...
    maxClosureError_us);

fprintf('\nSTATE 0 DURATION BY GROUP\n');
disp(state0GroupTable);

fprintf('\nPER-STATE TIMING CONTRIBUTIONS\n');
disp(stateContributionTable);

if nShortUpdate>0 && nLongUpdate>0

    fprintf('\nLONG MINUS SHORT CYCLE\n');

    fprintf('Total period difference: %.4f ms\n', ...
        deltaTs_ms);

    fprintf('State 0 difference: %.4f ms\n', ...
        deltaState0_ms);

    fprintf('All other states: %.4f ms\n', ...
        deltaNonIdle_ms);

    fprintf('State 0 contribution: %.2f%%\n', ...
        idleExplained_pct);

    fprintf('\nSTATE 0 LOCATION OF EXTRA TIME\n');

    fprintf('Before first rise: %.4f ms\n', ...
        deltaIdleBefore_ms);

    fprintf('During physical burst: %.4f ms\n', ...
        deltaIdleDuring_ms);

    fprintf('After final fall: %.4f ms\n', ...
        deltaIdleAfter_ms);

    fprintf('Short State 0 codes: %.4f ms\n', ...
        deltaShortIdleCode_ms);

else

    fprintf(['\nBoth timing groups are required ' ...
        'for a State 0 comparison.\n']);
end

fprintf('\nALTERNATION / OLED SCHEDULE\n');

fprintf('Strict 76/89 ms alternation: %d\n', ...
    strictAlternation);

fprintf('Firmware OLED refresh threshold: %.1f ms\n', ...
    oledRefresh_ms);

if ~isempty(twoCycle_ms)

    fprintf('Mean two-cycle duration: %.4f ms\n', ...
        mean(twoCycle_ms));

    fprintf('Minimum two-cycle duration: %.4f ms\n', ...
        min(twoCycle_ms));
end

fprintf(['State 0 includes waiting, UI work and ' ...
    'GPIO transition codes.\n']);

fprintf(['State 0 attribution alone cannot ' ...
    'prove OLED causation.\n']);


%% 16G. STATE 1 DAC-WRITE OCCUPANCY AUDIT
%
% Investigate the approximately -0.542 ms State 1
% contribution in long feedback intervals.
%
% Do not modify state boundaries or measured timing.
%
% Checks:
% 1. Raw State 1 segment counts
% 2. Qualified State 1 segment counts
% 3. ADC pulse counts
% 4. Physical pulse counts
% 5. Matched positive DAC marker counts
% 6. Segments crossing cycle boundaries
% 7. Short/unqualified State 1 occupancy
% 8. Difference between the short and long groups

nAudit = nUpdateIntervals;

state1RawCount = zeros(nAudit,1);
state1QualifiedCount = zeros(nAudit,1);
state1MatchedCount = zeros(nAudit,1);
state1ADCCount = zeros(nAudit,1);
state1PhysicalCount = zeros(nAudit,1);

state1BoundaryCount = zeros(nAudit,1);
state1BoundaryTime_us = zeros(nAudit,1);

state1Qualified_ms = zeros(nAudit,1);
state1Unqualified_ms = zeros(nAudit,1);
state1Short_us = zeros(nAudit,1);

state1InteriorMean_us = NaN(nAudit,1);

for k = 1:nAudit

    left = logTimes(k);
    right = logTimes(k+1);

    % All State 1 segments overlapping this interval.
    ids = find( ...
        segCode==1 & ...
        segT0<right & ...
        segT1>left);

    state1RawCount(k) = numel(ids);

    if ~isempty(ids)

        % Exact clipped contribution to this interval.
        overlapStart = max(segT0(ids),left);
        overlapEnd = min(segT1(ids),right);

        overlap_us = ...
            max(0,overlapEnd-overlapStart)*1e6;

        fullDuration_us = ...
            segDuration(ids)*1e6;

        qualified = ...
            fullDuration_us>=cfg.positiveRange_us(1) & ...
            fullDuration_us<=cfg.positiveRange_us(2);

        state1QualifiedCount(k) = nnz(qualified);

        state1Qualified_ms(k) = ...
            sum(overlap_us(qualified))/1000;

        state1Unqualified_ms(k) = ...
            sum(overlap_us(~qualified))/1000;

        shortMask = fullDuration_us<=6;

        state1Short_us(k) = ...
            sum(overlap_us(shortMask));

        % Segments cut by one of the two logging
        % boundaries.
        crossing = ...
            segT0(ids)<left | segT1(ids)>right;

        state1BoundaryCount(k) = nnz(crossing);

        state1BoundaryTime_us(k) = ...
            sum(overlap_us(crossing));

        % Fully interior, qualified operations only.
        interior = qualified & ...
            segT0(ids)>=left & ...
            segT1(ids)<=right;

        if any(interior)
            state1InteriorMean_us(k) = ...
                mean(fullDuration_us(interior));
        end
    end

    % ADC windows from the next logged burst.
    adcIDs = find( ...
        adcStartTimes>left & ...
        adcStartTimes<right);

    state1ADCCount(k) = numel(adcIDs);

    if ~isempty(adcIDs)

        state1PhysicalCount(k) = ...
            nnz(isfinite(pulseRise_s(adcIDs)));

        state1MatchedCount(k) = ...
            nnz(isfinite(positiveMarker(adcIDs)));
    end
end

% Compare qualified and unqualified State 1 occupancy.
state1AccountingError_us = ...
    (state1Qualified_ms + state1Unqualified_ms - ...
     stateDurations_ms(:,2))*1000;

maxState1Error_us = NaN;

if ~isempty(state1AccountingError_us)
    maxState1Error_us = ...
        max(abs(state1AccountingError_us));
end

% Per-interval audit table.
state1AuditTable = table( ...
    updateIntervalID,updatePeriod_ms, ...
    updateClass,completeUpdateInterval, ...
    state1RawCount,state1QualifiedCount, ...
    state1MatchedCount, ...
    state1ADCCount,state1PhysicalCount, ...
    state1BoundaryCount,state1BoundaryTime_us, ...
    stateDurations_ms(:,2), ...
    state1Qualified_ms,state1Unqualified_ms, ...
    state1Short_us,state1InteriorMean_us, ...
    state1AccountingError_us, ...
    'VariableNames',{ ...
    'Interval','Period_ms','Class','Complete', ...
    'RawState1Count','QualifiedState1Count', ...
    'MatchedPositiveDACCount', ...
    'ADCCount','PhysicalPulseCount', ...
    'BoundaryCrossingCount', ...
    'BoundaryOverlap_us', ...
    'TotalState1_ms', ...
    'QualifiedState1_ms', ...
    'UnqualifiedState1_ms', ...
    'ShortState1_us', ...
    'InteriorMeanState1_us', ...
    'AccountingError_us'});

%% 16H. COMPARE STATE 1 BETWEEN TIMING GROUPS

auditMetricNames = [
    "Raw State 1 segments"
    "Qualified State 1 segments"
    "Matched positive DAC operations"
    "ADC windows"
    "Physical pulses"
    "Boundary-crossing segments"
    "Boundary overlap"
    "Total State 1 occupancy"
    "Qualified State 1 occupancy"
    "Unqualified State 1 occupancy"
    "Short State 1 occupancy"
    "Mean qualified interior duration"
];

auditMetricUnits = [
    "count";"count";"count";"count";"count"
    "count";"us";"ms";"ms";"ms";"us";"us"
];

auditMetricValues = {
    state1RawCount
    state1QualifiedCount
    state1MatchedCount
    state1ADCCount
    state1PhysicalCount
    state1BoundaryCount
    state1BoundaryTime_us
    stateDurations_ms(:,2)
    state1Qualified_ms
    state1Unqualified_ms
    state1Short_us
    state1InteriorMean_us
};

nAuditMetrics = numel(auditMetricNames);

shortAuditMean = NaN(nAuditMetrics,1);
longAuditMean = NaN(nAuditMetrics,1);

for j = 1:nAuditMetrics

    x = auditMetricValues{j};

    shortAuditMean(j) = ...
        meanOrNaN(x(shortUpdate));

    longAuditMean(j) = ...
        meanOrNaN(x(longUpdate));
end

auditDifference = ...
    longAuditMean-shortAuditMean;

state1AuditComparison = table( ...
    auditMetricNames,auditMetricUnits, ...
    shortAuditMean,longAuditMean,auditDifference, ...
    'VariableNames',{ ...
    'Measurement','Unit', ...
    'ShortMean','LongMean','LongMinusShort'});

%% 16I. STATE 1 DIAGNOSTIC SUMMARY

fprintf('\n========================================\n');
fprintf(' STATE 1 DAC-WRITE AUDIT\n');
fprintf('========================================\n');

disp(state1AuditComparison);

fprintf('\nBoundary checks:\n');

fprintf('Short cycles with boundary crossing: %d/%d\n', ...
    nnz(state1BoundaryCount(shortUpdate)>0), ...
    nShortUpdate);

fprintf('Long cycles with boundary crossing: %d/%d\n', ...
    nnz(state1BoundaryCount(longUpdate)>0), ...
    nLongUpdate);

fprintf('Maximum accounting error: %.6f us\n', ...
    maxState1Error_us);

fprintf('\nExpected pulse-count checks:\n');

fprintf('Short cycles with 20 ADC windows: %d/%d\n', ...
    nnz(state1ADCCount(shortUpdate)== ...
    cfg.expectedPulses),nShortUpdate);

fprintf('Long cycles with 20 ADC windows: %d/%d\n', ...
    nnz(state1ADCCount(longUpdate)== ...
    cfg.expectedPulses),nLongUpdate);

fprintf('Short cycles with 20 physical pulses: %d/%d\n', ...
    nnz(state1PhysicalCount(shortUpdate)== ...
    cfg.expectedPulses),nShortUpdate);

fprintf('Long cycles with 20 physical pulses: %d/%d\n', ...
    nnz(state1PhysicalCount(longUpdate)== ...
    cfg.expectedPulses),nLongUpdate);

fprintf('\nInterpretation:\n');

fprintf(['The audit distinguishes actual physical pulses ' ...
    'from decoded State 1 segments.\n']);

fprintf(['Any difference in raw or qualified segment ' ...
    'counts must be examined before modifying ' ...
    'the state decomposition.\n']);


%% 17. WRITE HUMAN-READABLE TXT REPORT

fid = fopen(reportPath,'w');

assert(fid>=0, ...
    'Could not create results report.');

fprintf(fid,'====================================================\n');
fprintf(fid,'OPENXSTIM TIMING CHARACTERISATION\n');
fprintf(fid,'====================================================\n\n');

fprintf(fid,'SOURCE INFORMATION\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'CSV file: %s\n',cfg.filename);
fprintf(fid,'CSV path: %s\n',csvPath);
fprintf(fid,'Analysis: %s\n',outputName);
fprintf(fid,'Analysis date: %s\n', ...
    datestr(now,'yyyy-mm-dd HH:MM:SS'));

fprintf(fid,'\nACQUISITION\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'Original samples: %d\n',nOriginal);
fprintf(fid,'Retained samples: %d\n',N);
fprintf(fid,'Downsampling factor: %d\n', ...
    cfg.downsampleFactor);
fprintf(fid,'Sampling frequency: %.6f MHz\n',fs/1e6);
fprintf(fid,'Time resolution: %.3f us\n',dt*1e6);
fprintf(fid,'Recording duration: %.6f s\n',duration_s);
fprintf(fid,'Start timestamp: %.9f s\n',t(1));
fprintf(fid,'End timestamp: %.9f s\n',t(end));

fprintf(fid,'\nCHANNELS\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'CH1: Output load voltage\n');
fprintf(fid,'CH2: Firmware state bit 0, D5\n');
fprintf(fid,'CH3: Firmware state bit 1, D8\n');
fprintf(fid,'CH4: Firmware state bit 2, A2\n\n');

for ch = 1:4
    fprintf(fid, ...
        'CH%d voltage range: %.4f to %.4f V\n', ...
        ch,minimum_V(ch),maximum_V(ch));
end

fprintf(fid,'\nDigital thresholds:\n');

for ch = 1:3
    fprintf(fid,'CH%d: %.4f V\n', ...
        ch+1,usedThresholds(ch));
end

fprintf(fid,'\nEVENT DETECTION\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'ADC windows: %d\n',nADC);
fprintf(fid,'Physical output pulses: %d\n', ...
    numel(physicalRiseTimes));

fprintf(fid,'ADC-to-physical matches: %d/%d\n', ...
    physicalMatchCount,nADC);

fprintf(fid,'Fully GPIO-matched pulses: %d/%d\n', ...
    nFullyMatched,nADC);

fprintf(fid,'Positive DAC markers: %d\n', ...
    numel(posSeg));

fprintf(fid,'Settling markers: %d\n', ...
    numel(settleSeg));

fprintf(fid,'Baseline DAC markers: %d\n', ...
    numel(baseSeg));

fprintf(fid,'Finalisation markers: %d\n', ...
    numel(finalSeg));

fprintf(fid,'Controller markers: %d\n', ...
    numel(controlSeg));

fprintf(fid,'Logging markers: %d\n', ...
    numel(logSeg));

fprintf(fid,'\nBURST VERIFICATION\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'Logged burst candidates: %d\n',nBursts);
fprintf(fid,'Expected ADC windows per burst: %d\n', ...
    cfg.expectedPulses);

fprintf(fid,'ADC-confirmed complete bursts: %d/%d\n', ...
    nFullADC,nBursts);

fprintf(fid,'Physically complete bursts: %d/%d\n', ...
    nFullPhysical,nBursts);

fprintf(fid,'Bursts with finalisation: %d/%d\n', ...
    nFullFeedback,nBursts);

fprintf(fid,'Physical feedback latencies: %d/%d\n', ...
    nPhysicalLatencies,nBursts);

fprintf(fid,'Bursts with 21 baseline writes: %d/%d\n', ...
    nExtraBaselineConfirmed,nBursts);

fprintf(fid,'\nNOTE: The first logged burst may be partially\n');
fprintf(fid,'captured if recording began during acquisition.\n');
fprintf(fid,'An incomplete edge burst is not automatically\n');
fprintf(fid,'interpreted as a firmware failure.\n');

fprintf(fid,'\nTIMING STATISTICS\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,['%-37s %5s %10s %10s ' ...
    '%10s %10s %10s %4s\n'], ...
    'Measurement','N','Mean','Median', ...
    'Std','Minimum','Maximum','Unit');

fprintf(fid,'%s\n',repmat('-',1,105));

for k = 1:nMetrics

    if metricN(k)==0

        fprintf(fid,'%-37s unavailable\n', ...
            char(metricNames(k)));

        continue;
    end

    fprintf(fid, ...
        ['%-37s %5d %10.3f %10.3f ' ...
         '%10.3f %10.3f %10.3f %4s\n'], ...
        char(metricNames(k)), ...
        metricN(k),metricMean(k), ...
        metricMedian(k),metricStd(k), ...
        metricMin(k),metricMax(k), ...
        char(metricUnits(k)));
end

fprintf(fid,'\nCOMMON FEEDBACK PERIODS\n');
fprintf(fid,'----------------------------------------------------\n');

if isempty(periodValues)

    fprintf(fid, ...
        'Unavailable: insufficient logging markers.\n');

else

    [~,order] = sort(periodCounts,'descend');

    for k = 1:min(10,numel(order))

        j = order(k);

        fprintf(fid,'%.1f ms: %d intervals\n', ...
            periodValues(j),periodCounts(j));
    end
end

fprintf(fid,'\nOUTPUT VOLTAGE LEVELS\n');
fprintf(fid,'----------------------------------------------------\n');

if physicalAvailable

    fprintf(fid,'Estimated LOW level: %.4f V\n', ...
        lowLevel);

    fprintf(fid,'Estimated HIGH level: %.4f V\n', ...
        highLevel);

    fprintf(fid,'Transition threshold: %.4f V\n', ...
        riseThreshold);

else

    fprintf(fid, ...
        'Physical output level separation unavailable.\n');
end

fprintf(fid,'\nSTATE TIMING\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'%-5s %-30s %8s %10s %10s\n', ...
    'State','Name','Count','Mean us','Median us');

for k = 1:8

    fprintf(fid,'%-5d %-30s %8d %10.3f %10.3f\n', ...
        stateNumber(k),char(stateNames(k)), ...
        occurrences(k),mean_us(k),median_us(k));
end

fprintf(fid,'\nQUALITY CHECKS\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'Short state segments retained: %d\n', ...
    nShortSegments);

if isempty(missingStates)
    fprintf(fid,'All eight states observed.\n');
else
    fprintf(fid,'Missing states: %s\n', ...
        mat2str(missingStates'));
end

if nBursts==0

    fprintf(fid, ...
        'No complete logged burst boundary detected.\n');

elseif nFullADC<nBursts

    fprintf(fid, ...
        'Some logged bursts lacked 20 ADC windows.\n');
end

if numel(logSeg)<2

    fprintf(fid,['Controller update period unavailable: ' ...
        'fewer than two logging markers.\n']);
end

if cfg.downsampleFactor>1

    fprintf(fid,['WARNING: Downsampling reduces ' ...
        'short-state timing resolution.\n']);
end

fprintf(fid,'\nINTERPRETATION NOTES\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'1. CH1 measures voltage across the load.\n');
fprintf(fid,'   It is not the 10 ohm shunt voltage.\n\n');

fprintf(fid,'2. Current is calculated only when a verified\n');
fprintf(fid,'   load resistance is explicitly configured.\n\n');

fprintf(fid,'3. Physical latency uses CH1 threshold crossing.\n');
fprintf(fid,'   It is not the isolated PI computation time.\n\n');

fprintf(fid,'4. State 6 combines controller computation and\n');
fprintf(fid,'   supervisory operations.\n\n');

fprintf(fid,'5. GPIO pins are written sequentially, so short\n');
fprintf(fid,'   intermediary state codes may be present.\n\n');

fprintf(fid,'6. State 5 is only a few microseconds long.\n');
fprintf(fid,'   Its duration is resolution-limited.\n\n');

fprintf(fid,'7. Variable update periods should be retained\n');
fprintf(fid,'   when developing the discrete-time model.\n\n');

fprintf(fid,'8. This is timing characterisation, not proof\n');
fprintf(fid,'   of PI stability or control accuracy.\n');


%% STATE 0 TIMING REPORT ADDITION

fprintf(fid,'\nSTATE 0 / OLED TIMING INVESTIGATION\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'Complete update intervals: %d/%d\n', ...
    nnz(completeUpdateInterval),nUpdateIntervals);

fprintf(fid,'Short intervals: %d\n',nShortUpdate);
fprintf(fid,'Long intervals: %d\n',nLongUpdate);
fprintf(fid,'Other complete intervals: %d\n', ...
    nnz(otherUpdate));

fprintf(fid,'Maximum closure error: %.6f us\n', ...
    maxClosureError_us);

fprintf(fid,'\nSTATE 0 OCCUPANCY STATISTICS\n');

fprintf(fid, ...
    '%-8s %5s %11s %11s %11s %11s\n', ...
    'Group','N','Mean ms','Std ms', ...
    'Min ms','Max ms');

for j = 1:height(state0GroupTable)

    fprintf(fid, ...
        '%-8s %5d %11.4f %11.4f %11.4f %11.4f\n', ...
        char(state0GroupTable.Group(j)), ...
        state0GroupTable.N(j), ...
        state0GroupTable.Mean_ms(j), ...
        state0GroupTable.Std_ms(j), ...
        state0GroupTable.Minimum_ms(j), ...
        state0GroupTable.Maximum_ms(j));
end

fprintf(fid,'\nPER-STATE TIMING DECOMPOSITION\n');

fprintf(fid, ...
    '%-5s %-27s %12s %12s %12s\n', ...
    'State','Name','Short ms','Long ms','Delta ms');

for j = 1:height(stateContributionTable)

    fprintf(fid, ...
        '%-5d %-27s %12.4f %12.4f %12.4f\n', ...
        stateContributionTable.State(j), ...
        char(stateContributionTable.Name(j)), ...
        stateContributionTable.ShortMean_ms(j), ...
        stateContributionTable.LongMean_ms(j), ...
        stateContributionTable.LongMinusShort_ms(j));
end

if nShortUpdate>0 && nLongUpdate>0

    fprintf(fid,'\nLONG MINUS SHORT TIMING\n');

    fprintf(fid,'Update period difference: %.4f ms\n', ...
        deltaTs_ms);

    fprintf(fid,'State 0 difference: %.4f ms\n', ...
        deltaState0_ms);

    fprintf(fid,'Other state difference: %.4f ms\n', ...
        deltaNonIdle_ms);

    fprintf(fid,'State 0 contribution: %.2f percent\n', ...
        idleExplained_pct);

    fprintf(fid,'\nSTATE 0 TIME LOCATION\n');

    fprintf(fid,'Before first rise difference: %.4f ms\n', ...
        deltaIdleBefore_ms);

    fprintf(fid,'During burst difference: %.4f ms\n', ...
        deltaIdleDuring_ms);

    fprintf(fid,'After final fall difference: %.4f ms\n', ...
        deltaIdleAfter_ms);

    fprintf(fid,'Short GPIO code difference: %.4f ms\n', ...
        deltaShortIdleCode_ms);

    if abs(deltaNonIdle_ms) <= 0.5

        fprintf(fid, ...
            ['INTERPRETATION: The additional cycle time ' ...
             'is predominantly accounted for by State 0.\n']);

    else

        fprintf(fid, ...
            ['INTERPRETATION: Other firmware states ' ...
             'also contribute materially to the ' ...
             'update-period difference.\n']);
    end

else

    fprintf(fid, ...
        'Comparison unavailable: both groups required.\n');
end

fprintf(fid,'\nALTERNATION AND OLED SCHEDULE\n');

fprintf(fid,'Strict alternation: %d\n', ...
    strictAlternation);

fprintf(fid,'OLED refresh threshold: %.1f ms\n', ...
    oledRefresh_ms);

if ~isempty(twoCycle_ms)

    fprintf(fid,'Mean two-cycle period: %.4f ms\n', ...
        mean(twoCycle_ms));

    fprintf(fid,'Minimum two-cycle period: %.4f ms\n', ...
        min(twoCycle_ms));
end

fprintf(fid,'\nINTERPRETATION LIMITATIONS\n');

fprintf(fid, ...
    ['State 0 includes inter-burst waiting, ' ...
     'button/UI activity, display operations, ' ...
     'and short GPIO transition codes.\n']);

fprintf(fid, ...
    ['An additional 13 ms in State 0 supports ' ...
     'the hypothesis of a blocking idle/UI operation.\n']);

fprintf(fid, ...
    ['It does not independently establish ' ...
     'that an OLED refresh caused the delay.\n']);

fprintf(fid, ...
    ['A controlled capture with OLED refresh ' ...
     'disabled or directly instrumented would ' ...
     'be needed for causal confirmation.\n']);


%% STATE 1 DAC-WRITE AUDIT REPORT

fprintf(fid,'\nSTATE 1 DAC-WRITE AUDIT\n');
fprintf(fid,'----------------------------------------------------\n');

fprintf(fid,'Short cycles: %d\n',nShortUpdate);
fprintf(fid,'Long cycles: %d\n',nLongUpdate);

fprintf(fid,'\n%-35s %12s %12s %12s\n', ...
    'Measurement','Short','Long','Difference');

for j = 1:height(state1AuditComparison)

    fprintf(fid,'%-35s %12.4f %12.4f %12.4f\n', ...
        char(state1AuditComparison.Measurement(j)), ...
        state1AuditComparison.ShortMean(j), ...
        state1AuditComparison.LongMean(j), ...
        state1AuditComparison.LongMinusShort(j));
end

fprintf(fid,'\nBOUNDARY VERIFICATION\n');

fprintf(fid,'Short cycles with crossings: %d/%d\n', ...
    nnz(state1BoundaryCount(shortUpdate)>0), ...
    nShortUpdate);

fprintf(fid,'Long cycles with crossings: %d/%d\n', ...
    nnz(state1BoundaryCount(longUpdate)>0), ...
    nLongUpdate);

fprintf(fid,'State 1 accounting error: %.6f us\n', ...
    maxState1Error_us);

fprintf(fid,'\nINTERPRETATION\n');

fprintf(fid, ...
    ['Individual GPIO marker counts and durations ' ...
     'are diagnostic and may include transition artefacts.\n']);

fprintf(fid, ...
    ['A reduction in decoded State 1 occupancy ' ...
     'does not independently prove a reduction in ' ...
     'DAC execution time.\n']);

fprintf(fid, ...
    ['Physical pulse counts and ADC acquisition ' ...
     'counts provide independent verification.\n']);



fprintf(fid,'\nEND OF REPORT\n');

fclose(fid);

fprintf('\nText report saved:\n%s\n',reportPath);

%% 18. FIGURE 1: RECORDING OVERVIEW

fig1 = figure( ...
    'Color','w', ...
    'Units','pixels', ...
    'Position',[100 100 1400 950], ...
    'Name',[outputName ' - Recording overview']);

tl1 = tiledlayout(fig1,3,1, ...
    'TileSpacing','loose', ...
    'Padding','loose');

% Plot 1: Per-burst voltage.
ax1 = nexttile(tl1);

if nBursts>0 && ...
        any(isfinite(burstPlateau_V))

    xBurst = burstLogTime_s-t(1);

    plot(ax1,xBurst,burstPlateau_V, ...
        'o-','LineWidth',1, ...
        'MarkerSize',3);

    xlabel(ax1,'Time in recording (s)');
    ylabel(ax1,'Plateau (V)');
    title(ax1,'Per-burst load-voltage plateau');

else

    showUnavailable(ax1, ...
        'No complete plateau measurements');

end

grid(ax1,'on');

% Plot 2: Update periods.
ax2 = nexttile(tl1);

if ~isempty(Ts_logging_ms)

    xPeriod = logTimes(2:end)-t(1);

    plot(ax2,xPeriod,Ts_logging_ms, ...
        '.-','LineWidth',1, ...
        'MarkerSize',9);

    xlabel(ax2,'Time in recording (s)');
    ylabel(ax2,'Period (ms)');
    title(ax2,'Feedback update intervals');

else

    showUnavailable(ax2, ...
        'Two logging markers are required for update timing');

end

grid(ax2,'on');

% Plot 3: Physical feedback latency.
ax3 = nexttile(tl1);

valid = isfinite(finalisationToRise_ms);

if any(valid)

    plot(ax3, ...
        burstLogTime_s(valid)-t(1), ...
        finalisationToRise_ms(valid), ...
        '.-','LineWidth',1, ...
        'MarkerSize',9);

    xlabel(ax3,'Time in recording (s)');
    ylabel(ax3,'Latency (ms)');

    title(ax3, ...
        'Measurement finalisation to next voltage rise');

else

    showUnavailable(ax3, ...
        'Physical feedback latency unavailable');

end

grid(ax3,'on');

title(tl1, ...
    sprintf('%s: recording-wide timing summary', ...
    outputName), ...
    'FontSize',16,'FontWeight','bold');

%% 19. FIGURE 2: REPRESENTATIVE PULSE

fig2 = figure( ...
    'Color','w', ...
    'Units','pixels', ...
    'Position',[150 100 1400 850], ...
    'Name',[outputName ' - Pulse timing']);

tl2 = tiledlayout(fig2,2,1, ...
    'TileSpacing','loose', ...
    'Padding','loose');

validPulseIDs = find(fullyMatched);

if isempty(validPulseIDs)
    validPulseIDs = find(isfinite(pulseRise_s));
end

if ~isempty(validPulseIDs)

    p = validPulseIDs( ...
        ceil(numel(validPulseIDs)/2));

    r = pulseRise_s(p);
    f = pulseFall_s(p);

    left = r-1.15e-3;
    right = f+250e-6;

    idx = find(t>=left & t<=right);
    idx = thinIndices(idx,cfg.maxPlotPoints);

    x_us = (t(idx)-r)*1e6;

    adcStart_us = ...
        (adcStartTimes(p)-r)*1e6;

    adcEnd_us = ...
        (adcEndTimes(p)-r)*1e6;

    fall_us = (f-r)*1e6;

    guides = [0 adcStart_us adcEnd_us fall_us];

    % Top: Physical voltage.
    ax1 = nexttile(tl2);

    plot(ax1,x_us,loadV(idx), ...
        'k','LineWidth',1.1);

    hold(ax1,'on');

    addGuides(ax1,guides);

    ylabel(ax1,'Load voltage (V)');
    title(ax1,'Physical output waveform');

    grid(ax1,'on');

    % Bottom: Firmware state.
    ax2 = nexttile(tl2);

    stairs(ax2,x_us,double(rawState(idx)), ...
        'LineWidth',1.2);

    hold(ax2,'on');

    addGuides(ax2,guides);

    ylim(ax2,[-0.5 7.8]);
    yticks(ax2,0:7);

    % Place labels horizontally near top of state plot.
    eventLabels = { ...
        'Rise','ADC start','ADC end','Fall'};

    for j = 1:numel(guides)

        text(ax2,guides(j),7.3,eventLabels{j}, ...
            'HorizontalAlignment','center', ...
            'VerticalAlignment','middle', ...
            'FontSize',9, ...
            'BackgroundColor','w', ...
            'Margin',2);
    end

    ylabel(ax2,'Firmware state');
    xlabel(ax2, ...
        'Time relative to physical voltage rise (us)');

    title(ax2,'Decoded firmware execution states');

    grid(ax2,'on');

    title(tl2,sprintf( ...
        ['%s: representative pulse | ' ...
         'ADC %.1f us | HIGH %.1f us'], ...
        outputName, ...
        acquisition_us(p),pulseHighWidth_us(p)), ...
        'FontSize',15,'FontWeight','bold');

else

    ax1 = nexttile(tl2);
    showUnavailable(ax1,'No matched physical pulse');

    ax2 = nexttile(tl2);
    showUnavailable(ax2,'Firmware pulse timing unavailable');

    title(tl2,[outputName ' - Pulse timing']);
end

%% 20. FIGURE 3: COMPLETE FEEDBACK CYCLE

fig3 = figure( ...
    'Color','w', ...
    'Units','pixels', ...
    'Position',[200 70 1500 1050], ...
    'Name',[outputName ' - Feedback cycle']);

tl3 = tiledlayout(fig3,3,1, ...
    'TileSpacing','loose', ...
    'Padding','loose');

validBursts = find(completeFeedback);

if ~isempty(validBursts)

    k = validBursts( ...
        ceil(numel(validBursts)/2));

    firstRise = burstFirstRise_s(k);

    nextRise = nextBurstRise_s(k);

    if isfinite(nextRise)
        right = nextRise+0.5e-3;
    else
        right = logTimes(k)+1.0e-3;
    end

    left = firstRise-0.5e-3;

    idx = find(t>=left & t<=right);
    idx = thinIndices(idx,cfg.maxPlotPoints);

    x_ms = (t(idx)-firstRise)*1e3;

    final_ms = ...
        (burstFinalStart_s(k)-firstRise)*1e3;

    logging_ms = ...
        (logTimes(k)-firstRise)*1e3;

    % Full physical burst.
    ax1 = nexttile(tl3);

    plot(ax1,x_ms,loadV(idx), ...
        'k','LineWidth',1);

    hold(ax1,'on');

    xline(ax1,final_ms,':', ...
        'Color',[0.55 0.55 0.55]);

    if isfinite(nextRise)
        xline(ax1,(nextRise-firstRise)*1e3,':', ...
            'Color',[0.55 0.55 0.55]);
    end

    ylabel(ax1,'Load voltage (V)');
    xlabel(ax1,'Time from first pulse rise (ms)');

    title(ax1,sprintf( ...
        'Physical burst: %d ADC windows',adcCount(k)));

    grid(ax1,'on');

    % Firmware state sequence.
    ax2 = nexttile(tl3);

    stairs(ax2,x_ms,double(rawState(idx)), ...
        'LineWidth',1);

    hold(ax2,'on');

    xline(ax2,final_ms,':', ...
        'Color',[0.55 0.55 0.55]);

    xline(ax2,logging_ms,':', ...
        'Color',[0.55 0.55 0.55]);

    ylabel(ax2,'State');
    xlabel(ax2,'Time from first pulse rise (ms)');

    yticks(ax2,0:7);
    ylim(ax2,[-0.5 7.5]);

    title(ax2, ...
        'Firmware execution, logging and waiting');

    grid(ax2,'on');

    % Zoomed end-of-burst processing.
    ax3 = nexttile(tl3);

    zoomLeft = burstFinalStart_s(k)-50e-6;
    zoomRight = logTimes(k)+100e-6;

    zoomIdx = find( ...
        t>=zoomLeft & t<=zoomRight);

    zoomX_us = ...
        (t(zoomIdx)-burstFinalStart_s(k))*1e6;

    stairs(ax3,zoomX_us, ...
        double(rawState(zoomIdx)), ...
        'LineWidth',1.1);

    hold(ax3,'on');

    xline(ax3,0,':', ...
        'Color',[0.55 0.55 0.55]);

    xline(ax3, ...
        (logTimes(k)-burstFinalStart_s(k))*1e6, ...
        ':','Color',[0.55 0.55 0.55]);

    ylabel(ax3,'State');
    xlabel(ax3,'Time relative to finalisation (us)');

    yticks(ax3,0:7);
    ylim(ax3,[-0.5 7.5]);

    title(ax3, ...
        'Processing detail: finalisation, PI and logging');

    grid(ax3,'on');

    title(tl3,sprintf( ...
        '%s: feedback burst %d',outputName,k), ...
        'FontSize',16,'FontWeight','bold');

else

    for j = 1:3
        ax = nexttile(tl3);
        showUnavailable(ax, ...
            'No complete logged burst identified');
    end

    title(tl3,[outputName ' - Feedback cycle']);
end



%% 20A. FIGURE 4: STATE 0 TIMING COMPARISON

fig4 = figure( ...
    'Color','w', ...
    'Units','pixels', ...
    'Position',[120 80 1550 1000], ...
    'Name',[outputName ' - State 0 timing comparison']);

tl4 = tiledlayout(fig4,2,2, ...
    'TileSpacing','loose', ...
    'Padding','loose');

% ------------------------------------------------------------
% PANEL A: CONTROLLER PERIOD AND STATE 0 OCCUPANCY
% ------------------------------------------------------------

ax1 = nexttile(tl4,[1 2]);

validID = find(completeUpdateInterval);

if ~isempty(validID)

    plot(ax1,validID,updatePeriod_ms(validID), ...
        'o-','LineWidth',1.0, ...
        'MarkerSize',3.5, ...
        'DisplayName','Total update period');

    hold(ax1,'on');

    plot(ax1,validID,state0Total_ms(validID), ...
        's-','LineWidth',1.0, ...
        'MarkerSize',3.5, ...
        'DisplayName','Total State 0 time');

    ylabel(ax1,'Duration (ms)');
    xlabel(ax1,'Feedback interval number');

    title(ax1, ...
        'Total update period compared with State 0 occupancy');

    legend(ax1,'Location','best');
    grid(ax1,'on');

else

    showUnavailable(ax1, ...
        'No complete consecutive feedback intervals');
end

% ------------------------------------------------------------
% PANEL B: STATE 0 DURATION DISTRIBUTIONS
% ------------------------------------------------------------

ax2 = nexttile(tl4,3);

if nShortUpdate>0 && nLongUpdate>0

    histogram(ax2,state0Total_ms(shortUpdate), ...
        'BinWidth',0.25, ...
        'FaceAlpha',0.6, ...
        'DisplayName','76 ms cycles');

    hold(ax2,'on');

    histogram(ax2,state0Total_ms(longUpdate), ...
        'BinWidth',0.25, ...
        'FaceAlpha',0.6, ...
        'DisplayName','89 ms cycles');

    xlabel(ax2,'Total State 0 time (ms)');
    ylabel(ax2,'Number of intervals');

    title(ax2,'State 0 distribution by update-period group');

    legend(ax2,'Location','best');
    grid(ax2,'on');

else

    showUnavailable(ax2, ...
        'Both timing groups are required');
end

% ------------------------------------------------------------
% PANEL C: CONTRIBUTION OF EACH STATE TO 13 MS
% ------------------------------------------------------------

ax3 = nexttile(tl4,4);

if nShortUpdate>0 && nLongUpdate>0

    barh(ax3,0:7,stateDifference_ms, ...
        'BarWidth',0.65);

    hold(ax3,'on');

    xline(ax3,0,':', ...
        'Color',[0.4 0.4 0.4]);

    yticks(ax3,0:7);

    yticklabels(ax3,{ ...
        '0: Idle / UI'
        '1: Positive DAC'
        '2: Settling'
        '3: ADC'
        '4: Baseline DAC'
        '5: Finalisation'
        '6: Controller'
        '7: Logging'});

    set(ax3,'YDir','reverse');

    xlabel(ax3,'Long minus short mean duration (ms)');

    title(ax3,'Contribution from each firmware state');

    grid(ax3,'on');

else

    showUnavailable(ax3, ...
        'State contribution comparison unavailable');
end

title(tl4, ...
    sprintf('%s: State 0 and alternating feedback timing', ...
    outputName), ...
    'FontSize',16, ...
    'FontWeight','bold');


%% 21. SAVE DATA TABLES

writetable(channelTable, ...
    fullfile(outputDir, ...
    [outputName '_ChannelSummary.csv']));

writetable(stateTable, ...
    fullfile(outputDir, ...
    [outputName '_StateTiming.csv']));

writetable(pulseTable, ...
    fullfile(outputDir, ...
    [outputName '_PulseTiming.csv']));

writetable(burstTable, ...
    fullfile(outputDir, ...
    [outputName '_FeedbackCycles.csv']));

writetable(summaryTable, ...
    fullfile(outputDir, ...
    [outputName '_TimingSummary.csv']));


%% ADDITIONAL STATE 0 CSV EXPORTS

writetable(state0IntervalTable, ...
    fullfile(outputDir, ...
    [outputName '_State0PerCycle.csv']));

writetable(stateContributionTable, ...
    fullfile(outputDir, ...
    [outputName '_StateContribution.csv']));

writetable(state0GroupTable, ...
    fullfile(outputDir, ...
    [outputName '_State0GroupStatistics.csv']));



%% SAVE STATE 1 AUDIT TABLES

writetable(state1AuditTable, ...
    fullfile(outputDir, ...
    [outputName '_State1Audit.csv']));

writetable(state1AuditComparison, ...
    fullfile(outputDir, ...
    [outputName '_State1Comparison.csv']));



%% 22. SAVE FIGURES


figures = [fig1 fig2 fig3 fig4];

figureNames = {
    'Figure1_Overview'
    'Figure2_Pulse'
    'Figure3_FeedbackCycle'
    'Figure4_State0Comparison'
};


for j = 1:numel(figures)

    basePath = fullfile(outputDir, ...
        [outputName '_' figureNames{j}]);

    % High-resolution image.
    exportgraphics(figures(j), ...
        [basePath '.png'], ...
        'Resolution',cfg.figureResolution);

    % Editable MATLAB figure.
    if cfg.saveMATLABFigures
        savefig(figures(j),[basePath '.fig']);
    end
end

%% 23. SAVE COMPACT MATLAB RESULTS


save(fullfile(outputDir, ...
    [outputName '_Results.mat']), ...
    'cfg','outputName', ...
    'channelTable','stateTable', ...
    'pulseTable','burstTable','summaryTable', ...
    'usedThresholds', ...
    'Ts_controller_ms','Ts_logging_ms', ...
    'finalADCToRise_ms', ...
    'finalisationToRise_ms', ...
    'pulsePeriod_us', ...
    'state0IntervalTable', ...
    'state0GroupTable', ...
    'stateContributionTable', ...
    'stateDurations_ms', ...
    'updatePeriod_ms', ...
    'completeUpdateInterval', ...
    'shortUpdate','longUpdate', ...
    'deltaTs_ms','deltaState0_ms', ...
    'deltaNonIdle_ms','idleExplained_pct');


%% 24. FINAL COMMAND WINDOW REPORT

fprintf('\n========================================\n');
fprintf(' FINAL ANALYSIS SUMMARY: %s\n',outputName);
fprintf('========================================\n');

fprintf('Samples: %d\n',N);
fprintf('Recording duration: %.3f s\n',duration_s);
fprintf('ADC windows: %d\n',nADC);
fprintf('Physical pulses matched: %d/%d\n', ...
    physicalMatchCount,nADC);

fprintf('Logged burst candidates: %d\n',nBursts);
fprintf('Complete ADC bursts: %d/%d\n', ...
    nFullADC,nBursts);

fprintf('Physical feedback latencies: %d\n', ...
    nPhysicalLatencies);

fprintf('\nTIMING SUMMARY:\n');
disp(summaryTable);

fprintf('\nFILES SAVED TO:\n%s\n',outputDir);

fprintf('\nAnalysis complete.\n');

%% ================================================================
% LOCAL HELPER FUNCTIONS
%% ================================================================

function [starts,ends,codes] = stateSegments(s)

    s = s(:);

    transitions = find( ...
        s(2:end)~=s(1:end-1));

    starts = [1;transitions+1];
    ends = [transitions;numel(s)];
    codes = s(starts);
end

function ids = qualifySegments( ...
    codes,duration,target,range_us)

    ids = find( ...
        codes==target & ...
        duration>=range_us(1)*1e-6 & ...
        duration<=range_us(2)*1e-6);
end

function y = intervalMedian( ...
    signal,startTime,endTime,t0,dt)

    y = NaN;

    if ~isfinite(startTime) || ...
       ~isfinite(endTime) || ...
       endTime<=startTime
        return;
    end

    n = numel(signal);

    i0 = max(1, ...
        ceil((startTime-t0)/dt)+1);

    i1 = min(n, ...
        floor((endTime-t0)/dt)+1);

    if i1<i0
        return;
    end

    samples = signal(i0:i1);
    samples = samples(isfinite(samples));

    if ~isempty(samples)
        y = median(samples);
    end
end

function idx = thinIndices(idx,maxPoints)

    if numel(idx)<=maxPoints
        return;
    end

    selected = unique(round( ...
        linspace(1,numel(idx),maxPoints)));

    idx = idx(selected);
end

function addGuides(ax,positions)

    for k = 1:numel(positions)

        xline(ax,positions(k),':', ...
            'Color',[0.6 0.6 0.6], ...
            'LineWidth',0.8);
    end
end

function showUnavailable(ax,message)

    text(ax,0.5,0.5,message, ...
        'Units','normalized', ...
        'HorizontalAlignment','center', ...
        'VerticalAlignment','middle', ...
        'FontSize',11);

    axis(ax,'off');
end



%% ================================================================
% STATE 0 ANALYSIS HELPERS
%% ================================================================

function [durations_ms,nIdleSegments,shortIdle_ms] = ...
    clippedStateTiming( ...
    segT0,segT1,segCode,left,right)

    durations_ms = zeros(1,8);
    nIdleSegments = 0;
    shortIdle_ms = 0;

    if ~isfinite(left) || ...
       ~isfinite(right) || ...
       right<=left
        return;
    end

    % Find state segments overlapping the time window.
    ids = find( ...
        segT0<right & ...
        segT1>left);

    if isempty(ids)
        return;
    end

    % Clip each segment to the exact window boundaries.
    clippedStart = max(segT0(ids),left);
    clippedEnd = min(segT1(ids),right);

    overlap_s = max(0,clippedEnd-clippedStart);

    % Sum occupied time independently for all states.
    durations_ms = accumarray( ...
        double(segCode(ids))+1, ...
        overlap_s*1e3, ...
        [8 1],@sum,0)';

    % Count separate State 0 segments.
    idleMask = ...
        segCode(ids)==0 & overlap_s>0;

    nIdleSegments = nnz(idleMask);

    % Small State 0 codes are retained in the total,
    % but separately quantified because some may be
    % GPIO transition artefacts rather than true idle.
    originalDuration_s = ...
        segT1(ids)-segT0(ids);

    shortIdleMask = ...
        idleMask & originalDuration_s<=6e-6;

    shortIdle_ms = ...
        sum(overlap_s(shortIdleMask))*1e3;
end

function stats = timingStatsMs(x)

    x = x(isfinite(x));

    % [N, mean, standard deviation, minimum, maximum]
    stats = [0 NaN NaN NaN NaN];

    if isempty(x)
        return;
    end

    stats(1) = numel(x);
    stats(2) = mean(x);

    if numel(x)>1
        stats(3) = std(x);
    end

    stats(4) = min(x);
    stats(5) = max(x);
end

function value = meanOrNaN(x)

    x = x(isfinite(x));

    if isempty(x)
        value = NaN;
    else
        value = mean(x);
    end
end

