
%% ========================================================================
% OPENXSTIM STAGE 1 - FINAL TIMING CHARACTERISATION
%
% OpenXstim v1.3 / Arduino Uno R4 / AD5722
% Monophasic current pulses, bench resistor load
%
% CH1 = Voltage across output load
% CH2 = Debug bit 0, Arduino D5
% CH3 = Debug bit 1, Arduino D8
% CH4 = Debug bit 2, Arduino A2
%
% State = CH2 + 2*CH3 + 4*CH4
%
% 0 = Idle, waiting, user interface
% 1 = Positive DAC write
% 2 = ADC settling
% 3 = Eight ADC readings
% 4 = Baseline DAC write
% 5 = Measurement finalisation
% 6 = Controller and supervisor
% 7 = Serial CSV logging
%
% Primary analysis:
%   1. Recover genuine ADC windows
%   2. Verify 20 acquisitions per feedback burst
%   3. Identify physical voltage pulses from CH1
%   4. Measure controller update intervals
%   5. Measure feedback-to-physical-output latency
%   6. Export thesis timing evidence
%
% No controller tuning or Simulink.
% No specialised MATLAB toolboxes required.
%% ========================================================================

clear;
clc;
close all;

%% 1. CONFIGURATION

cfg.filename = 'RigolDS0.csv';
cfg.outputFolder = 'OpenXstim_Stage1_Final';

% Keep 1 for original timing resolution.
cfg.downsampleFactor = 1;

cfg.expectedPulses = 20;
cfg.adcSamplesPerPulse = 8;

% Digital thresholds.
% NaN means estimate automatically.
cfg.digitalThresholds = [NaN NaN NaN];

% Qualified state duration ranges, microseconds.
% These separate stable operations from brief GPIO codes.
cfg.adcRange_us = [150 210];
cfg.settleRange_us = [150 300];
cfg.positiveRange_us = [700 1100];
cfg.baselineRange_us = [400 1100];
cfg.finalRange_us = [2 20];
cfg.controlRange_us = [6 100];
cfg.loggingRange_us = [400 2000];

% Physical pulse qualification.
cfg.highDurationRange_us = [300 1800];

% Maximum matching distances.
cfg.maxDACToRise_us = 1300;
cfg.maxSettleToADC_us = 500;
cfg.maxADCToBaseline_us = 80;
cfg.maxBaselineEndError_us = 50;

% Optional physical load resistance.
% Enter 1000 only if CH1 is across a verified 1 kOhm
% resistor. Leave NaN for voltage-only characterisation.
cfg.loadResistanceOhm = NaN;

% Figure settings.
cfg.maxPlotPoints = 25000;
cfg.exportFigures = true;
cfg.figureResolution = 250;

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

if ~isfolder(cfg.outputFolder)
    mkdir(cfg.outputFolder);
end

fprintf('\n========================================\n');
fprintf(' OPENXSTIM TIMING CHARACTERISATION\n');
fprintf('========================================\n');

%% 2. IMPORT RIGOL CSV

assert(isfile(cfg.filename), ...
    'File not found: %s',cfg.filename);

assert(cfg.downsampleFactor >= 1 && ...
    cfg.downsampleFactor == floor(cfg.downsampleFactor), ...
    'Downsampling factor must be a positive integer.');

fid = fopen(cfg.filename,'r');
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
    'Could not extract t0 from Rigol header.');

assert(~isempty(dtMatch), ...
    'Could not extract tInc from Rigol header.');

t0 = str2double(t0Match{1});
originalDt = str2double(dtMatch{1});

assert(isfinite(t0) && isfinite(originalDt) ...
    && originalDt>0,'Invalid timing metadata.');

fileInfo = dir(cfg.filename);

estimatedRows = max(1000, ...
    ceil(fileInfo.bytes/55/cfg.downsampleFactor));

V = zeros(estimatedRows,4);
sampleIndex = zeros(estimatedRows,1);

nStored = 0;
nOriginal = 0;
badRows = 0;

fprintf('\nReading CSV, factor %d...\n', ...
    cfg.downsampleFactor);

tic;

while ~feof(fid)

    line = fgetl(fid);

    if ~ischar(line)
        break;
    end

    if mod(nOriginal,cfg.downsampleFactor)==0

        values = sscanf(strrep(line,',',' '),'%f',4);

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
    'Malformed selected CSV rows: %d',badRows);

V = V(1:nStored,:);
sampleIndex = sampleIndex(1:nStored);

t = t0 + sampleIndex*originalDt;

N = numel(t);
dt = originalDt*cfg.downsampleFactor;
fs = 1/dt;

assert(N>100,'Insufficient samples.');

fprintf('Imported samples: %d\n',N);
fprintf('Original samples: %d\n',nOriginal);
fprintf('Import time: %.2f s\n',toc);
fprintf('Sampling rate: %.6f MHz\n',fs/1e6);
fprintf('Resolution: %.3f us\n',dt*1e6);
fprintf('Duration: %.6f s\n',t(end)-t(1));

channelNumber = (1:4)';
minimum_V = min(V,[],1)';
maximum_V = max(V,[],1)';

channelTable = table( ...
    channelNumber,minimum_V,maximum_V);

disp(channelTable);

%% 3. DIGITAL THRESHOLDING

bits = false(N,3);
usedThresholds = zeros(1,3);

for ch = 1:3

    signal = V(:,ch+1);

    % Use a sparse representation only for threshold
    % estimation. Full-resolution data is still decoded.
    testValues = sort(signal(1:100:end));

    nTest = numel(testValues);

    lowIndex = max(1,round(0.02*nTest));
    highIndex = min(nTest,round(0.98*nTest));

    lowLevel = testValues(lowIndex);
    highLevel = testValues(highIndex);

    if isnan(cfg.digitalThresholds(ch))
        threshold = (lowLevel+highLevel)/2;
    else
        threshold = cfg.digitalThresholds(ch);
    end

    assert(highLevel-lowLevel>1, ...
        'CH%d lacks clear digital levels.',ch+1);

    bits(:,ch) = signal>=threshold;
    usedThresholds(ch) = threshold;

    fprintf('CH%d threshold: %.3f V\n', ...
        ch+1,threshold);
end

%% 4. DECODE RAW FIRMWARE STATES

rawState = uint8(bits(:,1)) ...
    + uint8(2)*uint8(bits(:,2)) ...
    + uint8(4)*uint8(bits(:,3));

[segStart,segEnd,segCode] = ...
    stateSegments(rawState);

segT0 = t(segStart);
segT1 = t(segEnd)+dt;
segDuration = segT1-segT0;

fprintf('\nTotal state segments: %d\n', ...
    numel(segCode));

% Keep all original states.
% Short intermediary codes are not globally deleted.

%% 5. STATE STATISTICS

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

    if ~isempty(x)

        mean_us(s+1) = mean(x);
        median_us(s+1) = median(x);
        min_us(s+1) = min(x);
        max_us(s+1) = max(x);

        if numel(x)>1
            std_us(s+1) = std(x);
        end

        shortCount(s+1) = nnz(x<=6);
    end
end

stateTable = table( ...
    stateNumber,stateNames,occurrences, ...
    mean_us,median_us,std_us, ...
    min_us,max_us,shortCount);

fprintf('\n=== STATE STATISTICS ===\n');
disp(stateTable);

%% 6. IDENTIFY STABLE EXECUTION EVENTS

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

fprintf('\n=== QUALIFIED EVENTS ===\n');

fprintf('ADC windows: %d\n',numel(adcSeg));
fprintf('Settling markers: %d\n',numel(settleSeg));
fprintf('Positive DAC markers: %d\n',numel(posSeg));
fprintf('Baseline DAC markers: %d\n',numel(baseSeg));
fprintf('Finalisation markers: %d\n',numel(finalSeg));
fprintf('Controller markers: %d\n',numel(controlSeg));
fprintf('Logging markers: %d\n',numel(logSeg));

assert(numel(logSeg)>=3, ...
    'Insufficient logging events for cycle analysis.');

%% 7. DETECT PHYSICAL OUTPUT PULSES

loadV = V(:,1);

% Estimate voltage levels from a sparse subset.
probe = loadV(1:50:end);

lowSamples = probe(probe<2);
highSamples = probe(probe>7);

assert(~isempty(lowSamples) && ...
    ~isempty(highSamples), ...
    'Cannot identify low and high output voltage levels.');

lowLevel = median(lowSamples);
highLevel = median(highSamples);

riseThreshold = (lowLevel+highLevel)/2;

fprintf('\n=== PHYSICAL OUTPUT LEVELS ===\n');
fprintf('Estimated LOW level: %.4f V\n',lowLevel);
fprintf('Estimated HIGH level: %.4f V\n',highLevel);
fprintf('Transition threshold: %.4f V\n',riseThreshold);

% Binary output-voltage sequence.
loadHigh = loadV>=riseThreshold;

% Rising crossing: first sample above threshold.
riseIndex = find( ...
    ~loadHigh(1:end-1) & loadHigh(2:end))+1;

% Falling crossing: first sample below threshold.
fallIndex = find( ...
    loadHigh(1:end-1) & ~loadHigh(2:end))+1;

% Remove unmatched transitions at acquisition edges.
if ~isempty(riseIndex) && ~isempty(fallIndex)

    if fallIndex(1)<riseIndex(1)
        fallIndex(1) = [];
    end

    if ~isempty(riseIndex) && ~isempty(fallIndex)
        if riseIndex(end)>fallIndex(end)
            riseIndex(end) = [];
        end
    end
end

assert(numel(riseIndex)==numel(fallIndex), ...
    'Unpaired output-voltage threshold crossings.');

physicalRiseTimes = t(riseIndex);
physicalFallTimes = t(fallIndex);

highWidth_us = ...
    (physicalFallTimes-physicalRiseTimes)*1e6;

validHigh = ...
    highWidth_us>=cfg.highDurationRange_us(1) & ...
    highWidth_us<=cfg.highDurationRange_us(2);

physicalRiseTimes = physicalRiseTimes(validHigh);
physicalFallTimes = physicalFallTimes(validHigh);
highWidth_us = highWidth_us(validHigh);

fprintf('Qualified physical pulses: %d\n', ...
    numel(physicalRiseTimes));

%% 8. MATCH PHYSICAL PULSES TO ADC WINDOWS

nADC = numel(adcSeg);

adcStartTimes = segT0(adcSeg);
adcEndTimes = segT1(adcSeg);

pulseRise_s = NaN(nADC,1);
pulseFall_s = NaN(nADC,1);
pulseHighWidth_us = NaN(nADC,1);

% Match a physical HIGH interval containing the
% genuine ADC acquisition interval.
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

fprintf('\n=== PHYSICAL PULSE MATCHING ===\n');
fprintf('ADC windows: %d\n',nADC);

fprintf('ADC-to-voltage matches: %d\n', ...
    nnz(isfinite(pulseRise_s)));

%% 9. MATCH FIRMWARE PHASES TO EACH ADC PULSE

positiveMarker = NaN(nADC,1);
settleMarker = NaN(nADC,1);
baselineMarker = NaN(nADC,1);

positive_us = NaN(nADC,1);
settling_us = NaN(nADC,1);
acquisition_us = segDuration(adcSeg)*1e6;
baseline_us = NaN(nADC,1);

% Marker-to-physical-output timings.
positiveToRise_us = NaN(nADC,1);
baselineToFall_us = NaN(nADC,1);

for k = 1:nADC

    a0 = adcStartTimes(k);
    a1 = adcEndTimes(k);
    r = pulseRise_s(k);
    f = pulseFall_s(k);

    % ------------------------------------------------------------
    % SETTLING MARKER
    % ------------------------------------------------------------

    settleCandidates = settleSeg( ...
        segT0(settleSeg)>= ...
        a0-cfg.maxSettleToADC_us*1e-6 & ...
        segT1(settleSeg)<=a0+2*dt);

    if ~isempty(settleCandidates)

        [~,j] = max(segT1(settleCandidates));
        s = settleCandidates(j);

        settleMarker(k) = s;
        settling_us(k) = segDuration(s)*1e6;
    end

    if ~isfinite(r) || ~isfinite(f)
        continue;
    end

    % ------------------------------------------------------------
    % POSITIVE DAC MARKER
    % ------------------------------------------------------------

    positiveCandidates = posSeg( ...
        segT0(posSeg)>= ...
        r-cfg.maxDACToRise_us*1e-6 & ...
        segT0(posSeg)<r & ...
        segT1(posSeg)<=r+2*dt);

    if ~isempty(positiveCandidates)

        % Prefer the longest stable positive-DAC state.
        [~,j] = max(segDuration(positiveCandidates));
        s = positiveCandidates(j);

        positiveMarker(k) = s;
        positive_us(k) = segDuration(s)*1e6;

        positiveToRise_us(k) = ...
            (r-segT0(s))*1e6;
    end

    % ------------------------------------------------------------
    % BASELINE DAC MARKER
    % ------------------------------------------------------------

    baselineCandidates = baseSeg( ...
        segT0(baseSeg)>= ...
        a1-2*dt & ...
        segT0(baseSeg)<= ...
        a1+cfg.maxADCToBaseline_us*1e-6 & ...
        abs(segT1(baseSeg)-f)<= ...
        cfg.maxBaselineEndError_us*1e-6);

    if ~isempty(baselineCandidates)

        [~,j] = min( ...
            abs(segT1(baselineCandidates)-f));

        s = baselineCandidates(j);

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

fprintf('\n=== FIRMWARE PULSE MATCHING ===\n');

fprintf('Positive phases matched: %d/%d\n', ...
    nnz(isfinite(positiveMarker)),nADC);

fprintf('Settling phases matched: %d/%d\n', ...
    nnz(isfinite(settleMarker)),nADC);

fprintf('Baseline phases matched: %d/%d\n', ...
    nnz(isfinite(baselineMarker)),nADC);

fprintf('All four phases matched: %d/%d\n', ...
    nnz(fullyMatched),nADC);

fprintf(['Unmatched individual GPIO phases do not ' ...
    'invalidate an ADC-confirmed burst.\n']);

%% 10. MEASURE BASELINE AND PLATEAU VOLTAGES

% Baseline is measured before physical rising edge,
% during the preceding stable LOW interval.
%
% Plateau is measured inside the ADC acquisition
% interval, avoiding the boundaries.

pulseBaseline_V = NaN(nADC,1);
pulsePlateau_V = NaN(nADC,1);

for k = 1:nADC

    if ~isfinite(pulseRise_s(k))
        continue;
    end

    r = pulseRise_s(k);

    baselineStart = r-200e-6;
    baselineEnd = r-50e-6;

    plateauStart = adcStartTimes(k)+20e-6;
    plateauEnd = adcEndTimes(k)-20e-6;

    pulseBaseline_V(k) = ...
        intervalMedian(loadV,baselineStart, ...
        baselineEnd,t(1),dt);

    pulsePlateau_V(k) = ...
        intervalMedian(loadV,plateauStart, ...
        plateauEnd,t(1),dt);
end

pulseAmplitude_V = ...
    pulsePlateau_V-pulseBaseline_V;

fprintf('\n=== LOAD VOLTAGE ===\n');

reportMetric('Baseline voltage',pulseBaseline_V,'V');
reportMetric('Plateau voltage',pulsePlateau_V,'V');
reportMetric('Pulse amplitude',pulseAmplitude_V,'V');
reportMetric('Physical HIGH duration', ...
    pulseHighWidth_us,'us');

if isfinite(cfg.loadResistanceOhm) && ...
        cfg.loadResistanceOhm>0

    pulseCurrent_mA = ...
        1000*pulseAmplitude_V/cfg.loadResistanceOhm;

    reportMetric('Resistive load current', ...
        pulseCurrent_mA,'mA');

else
    pulseCurrent_mA = NaN(nADC,1);

    fprintf(['Load current not calculated: ' ...
        'load resistance unspecified.\n']);
end

%% 11. FEEDBACK CYCLE DETECTION

% Consecutive State 7 events bound one complete
% feedback iteration.
%
% Validate each interval using 20 genuine State 3
% ADC windows, independently of DAC-marker matching.

logTimes = segT0(logSeg);

nCycles = numel(logTimes)-1;

cycleID = (1:nCycles)';

cycleStart_s = logTimes(1:end-1);
cycleEnd_s = logTimes(2:end);

Ts_logging_ms = diff(logTimes)*1e3;

adcCount = zeros(nCycles,1);
positiveCount = zeros(nCycles,1);
baselineCount = zeros(nCycles,1);

cycleFirstADC_s = NaN(nCycles,1);
cycleLastADCend_s = NaN(nCycles,1);

cycleFirstRise_s = NaN(nCycles,1);
cycleLastFall_s = NaN(nCycles,1);

cycleFinalStart_s = NaN(nCycles,1);
cycleFinalEnd_s = NaN(nCycles,1);
cycleControlStart_s = NaN(nCycles,1);

cyclePlateau_V = NaN(nCycles,1);
cycleBaseline_V = NaN(nCycles,1);

burstAcquisition_ms = NaN(nCycles,1);
burstPhysical_ms = NaN(nCycles,1);

pulsePeriod_us = [];

for k = 1:nCycles

    left = cycleStart_s(k);
    right = cycleEnd_s(k);

    % ADC windows inside this feedback interval.
    ids = find( ...
        adcStartTimes>left & ...
        adcStartTimes<right);

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

    cycleFirstADC_s(k) = ...
        adcStartTimes(ids(1));

    cycleLastADCend_s(k) = ...
        adcEndTimes(ids(end));

    % Periods between adjacent ADC windows.
    % Use only verified 20-window intervals.
    if numel(ids)==cfg.expectedPulses

        pulsePeriod_us = [pulsePeriod_us; ...
            diff(adcStartTimes(ids))*1e6];

    end

    % Physical output events.
    if all(isfinite(pulseRise_s(ids))) && ...
       all(isfinite(pulseFall_s(ids)))

        cycleFirstRise_s(k) = ...
            pulseRise_s(ids(1));

        cycleLastFall_s(k) = ...
            pulseFall_s(ids(end));

        burstPhysical_ms(k) = ...
            (cycleLastFall_s(k)- ...
             cycleFirstRise_s(k))*1e3;
    end

    % First physical rise to final ADC completion.
    if isfinite(cycleFirstRise_s(k))

        burstAcquisition_ms(k) = ...
            (cycleLastADCend_s(k)- ...
             cycleFirstRise_s(k))*1e3;
    end

    % Median pulse voltage levels within burst.
    v = pulsePlateau_V(ids);
    v = v(isfinite(v));

    if ~isempty(v)
        cyclePlateau_V(k) = median(v);
    end

    v = pulseBaseline_V(ids);
    v = v(isfinite(v));

    if ~isempty(v)
        cycleBaseline_V(k) = median(v);
    end

    % Find the finalisation marker after last ADC,
    % before the closing logging marker.
    finals = finalSeg( ...
        segT0(finalSeg)>cycleLastADCend_s(k) & ...
        segT0(finalSeg)<right);

    if numel(finals)==1

        f = finals(1);

        cycleFinalStart_s(k) = segT0(f);
        cycleFinalEnd_s(k) = segT1(f);

        controls = controlSeg( ...
            segT0(controlSeg)>=segT1(f)-2*dt & ...
            segT0(controlSeg)<right);

        if numel(controls)==1
            cycleControlStart_s(k) = ...
                segT0(controls(1));
        end
    end
end

% ADC-complete cycles are the primary structural result.
completeADC = ...
    adcCount==cfg.expectedPulses;

% Fully validated physical cycles.
completePhysical = ...
    completeADC & ...
    isfinite(cycleFirstRise_s) & ...
    isfinite(cycleLastFall_s);

% Feedback cycles with one identifiable finalisation.
completeFeedback = ...
    completePhysical & ...
    isfinite(cycleFinalStart_s);

fprintf('\n=== FEEDBACK CYCLE VERIFICATION ===\n');

fprintf('Logging intervals: %d\n',nCycles);

fprintf('20-ADC cycles: %d/%d\n', ...
    nnz(completeADC),nCycles);

fprintf('Physical-output cycles: %d/%d\n', ...
    nnz(completePhysical),nCycles);

fprintf('Cycles with finalisation: %d/%d\n', ...
    nnz(completeFeedback),nCycles);

fprintf('ADC count range: %d to %d\n', ...
    min(adcCount),max(adcCount));

%% 12. CONTROLLER TIMESTAMP PERIOD

% Firmware reads micros() inside State 5.
%
% State 5 start is a close observable proxy.
% Compare consecutive finalisation timestamps.
%
% Align every finalisation marker with State 7.
% This avoids losing cycles through GPIO phase matching.

Ts_controller_ms = [];

allFinalTimes = segT0(finalSeg);

finalisationToLogging_ms = [];

if numel(finalSeg)==numel(logSeg)

    aligned = all( ...
        allFinalTimes<logTimes & ...
        allFinalTimes>logTimes-0.010);

    if aligned

        Ts_controller_ms = ...
            diff(allFinalTimes)*1e3;

        finalisationToLogging_ms = ...
            (logTimes-allFinalTimes)*1e3;

    else
        warning('State 5 and State 7 alignment failed.');
    end

else
    warning('State 5 and State 7 counts differ.');
end

%% 13. MEASUREMENT-TO-PHYSICAL-OUTPUT LATENCY

% Each completed burst provides one averaged
% current measurement.
%
% We compare the final ADC event and measurement
% finalisation against the NEXT physical pulse rise.
%
% This is the primary feedback latency result.

finalADCToRise_ms = NaN(nCycles,1);
finalisationToRise_ms = NaN(nCycles,1);

% Additional GPIO-based comparison.
finalADCToDACMarker_ms = NaN(nCycles,1);
finalisationToDACMarker_ms = NaN(nCycles,1);

for k = 1:nCycles

    if ~completeADC(k) || ...
       ~isfinite(cycleFinalEnd_s(k))
        continue;
    end

    % Next ADC window after closing logging marker.
    nextADC = find( ...
        adcStartTimes>cycleEnd_s(k), ...
        1,'first');

    if isempty(nextADC)
        continue;
    end

    nextRise = pulseRise_s(nextADC);

    if ~isfinite(nextRise)
        continue;
    end

    % Verify next physical rise belongs to the
    % pulse following this logging marker.
    if nextRise<=cycleEnd_s(k)
        continue;
    end

    % Final ADC completion to physical actuation.
    finalADCToRise_ms(k) = ...
        (nextRise-cycleLastADCend_s(k))*1e3;

    % Measurement finalisation completion to
    % physical output threshold crossing.
    finalisationToRise_ms(k) = ...
        (nextRise-cycleFinalEnd_s(k))*1e3;

    % Optional positive-DAC marker latency.
    p = positiveMarker(nextADC);

    if isfinite(p)

        nextMarker = segT0(p);

        if nextMarker>cycleEnd_s(k)

            finalADCToDACMarker_ms(k) = ...
                (nextMarker- ...
                 cycleLastADCend_s(k))*1e3;

            finalisationToDACMarker_ms(k) = ...
                (nextMarker- ...
                 cycleFinalEnd_s(k))*1e3;
        end
    end
end

fprintf('\n=== PHYSICAL FEEDBACK LATENCY ===\n');

reportMetric('Final ADC to voltage rise', ...
    finalADCToRise_ms,'ms');

reportMetric('Finalisation to voltage rise', ...
    finalisationToRise_ms,'ms');

fprintf('Valid physical latencies: %d/%d\n', ...
    nnz(isfinite(finalisationToRise_ms)),nCycles);

fprintf('\n=== DAC MARKER COMPARISON ===\n');

reportMetric('Final ADC to DAC marker', ...
    finalADCToDACMarker_ms,'ms');

reportMetric('Finalisation to DAC marker', ...
    finalisationToDACMarker_ms,'ms');

reportMetric('DAC marker to voltage rise', ...
    positiveToRise_us,'us');

%% 14. CONTROLLER UPDATE PERIOD DISTRIBUTION

shortPeriod = Ts_logging_ms>=74 & ...
              Ts_logging_ms<82;

longPeriod = Ts_logging_ms>=82 & ...
             Ts_logging_ms<=91;

otherPeriod = ~(shortPeriod | longPeriod);

fprintf('\n=== UPDATE PERIOD ANALYSIS ===\n');

reportMetric('State 7 interval', ...
    Ts_logging_ms,'ms');

reportMetric('Controller timestamp interval', ...
    Ts_controller_ms,'ms');

reportMetric('Short update period', ...
    Ts_logging_ms(shortPeriod),'ms');

reportMetric('Long update period', ...
    Ts_logging_ms(longPeriod),'ms');

fprintf('Short intervals: %d\n',nnz(shortPeriod));
fprintf('Long intervals: %d\n',nnz(longPeriod));
fprintf('Other intervals: %d\n',nnz(otherPeriod));

% Detect alternation between the two classes.
class = zeros(nCycles,1);
class(shortPeriod) = 1;
class(longPeriod) = 2;

alternates = all( ...
    class(1:end-1)~=class(2:end) & ...
    class(1:end-1)>0 & ...
    class(2:end)>0);

fprintf('Strict short/long alternation: %d\n', ...
    alternates);

%% 15. DETAILED OPERATION TIMING

fprintf('\n=== PULSE OPERATION TIMING ===\n');

reportMetric('Positive DAC state',positive_us,'us');
reportMetric('ADC settling',settling_us,'us');
reportMetric('ADC acquisition',acquisition_us,'us');
reportMetric('Baseline DAC state',baseline_us,'us');
reportMetric('ADC-to-ADC pulse period', ...
    pulsePeriod_us,'us');

reportMetric('Physical pulse HIGH width', ...
    pulseHighWidth_us,'us');

fprintf('\n=== BURST TIMING ===\n');

reportMetric('First rise to final ADC', ...
    burstAcquisition_ms,'ms');

reportMetric('First rise to final fall', ...
    burstPhysical_ms,'ms');

fprintf('\n=== PROCESSING TIMING ===\n');

reportMetric('State 5 finalisation', ...
    segDuration(finalSeg)*1e6,'us');

reportMetric('State 6 controller/supervisor', ...
    segDuration(controlSeg)*1e6,'us');

reportMetric('State 7 CSV logging', ...
    segDuration(logSeg)*1e6,'us');

reportMetric('Finalisation start to logging', ...
    finalisationToLogging_ms,'ms');

fprintf('\nNote:\n');
fprintf(['State 6 measures supervisor and PI execution ' ...
    'together, not PI computation alone.\n']);

%% 16. QUALITY CONTROL

fprintf('\n=== QUALITY REPORT ===\n');

missingStates = find(occurrences==0)-1;

if isempty(missingStates)
    fprintf('All eight states observed.\n');
else
    fprintf('Missing states: %s\n', ...
        mat2str(missingStates'));
end

% Short states are reported, not automatically
% classified as glitches.
shortStateCount = nnz( ...
    segDuration<=6e-6);

fprintf('Short state segments retained: %d\n', ...
    shortStateCount);

fprintf('Valid ADC windows: %d\n',nADC);

fprintf('ADC-confirmed complete cycles: %d/%d\n', ...
    nnz(completeADC),nCycles);

fprintf('Physical complete cycles: %d/%d\n', ...
    nnz(completePhysical),nCycles);

fprintf('Measured physical feedback latencies: %d/%d\n', ...
    nnz(isfinite(finalisationToRise_ms)),nCycles);

fprintf('Fully GPIO-matched individual pulses: %d/%d\n', ...
    nnz(fullyMatched),nADC);

% The original firmware performs an additional baseline
% DAC command after the final stimulation pulse.
fprintf('\nQualified State 4 occurrences per interval:\n');

if ~isempty(baselineCount)
    fprintf('Minimum: %d\n',min(baselineCount));
    fprintf('Median: %.1f\n',median(baselineCount));
    fprintf('Maximum: %d\n',max(baselineCount));
    fprintf('Exactly 21: %d/%d\n', ...
        nnz(baselineCount==21),nCycles);
end

if cfg.downsampleFactor~=1
    warning(['Analysis is downsampled. Short-state ' ...
        'timings may be unreliable.']);
end

if nnz(completeADC)<nCycles
    warning('Some feedback intervals have incomplete ADC counts.');
end

if nnz(isfinite(finalisationToRise_ms))<nCycles
    warning('Some physical feedback latencies are unavailable.');
end

%% 17. CREATE PULSE TABLE

pulseNumber = (1:nADC)';

pulseCycle = NaN(nADC,1);

for k = 1:nCycles

    mask = adcStartTimes>cycleStart_s(k) & ...
           adcStartTimes<cycleEnd_s(k);

    pulseCycle(mask) = k;
end

pulseTable = table( ...
    pulseNumber,pulseCycle, ...
    adcStartTimes,adcEndTimes, ...
    pulseRise_s,pulseFall_s, ...
    positive_us,settling_us, ...
    acquisition_us,baseline_us, ...
    positiveToRise_us, ...
    baselineToFall_us, ...
    pulseHighWidth_us, ...
    pulseBaseline_V,pulsePlateau_V, ...
    pulseAmplitude_V,pulseCurrent_mA, ...
    fullyMatched);

%% 18. CREATE FEEDBACK CYCLE TABLE

cycleTable = table( ...
    cycleID,cycleStart_s,cycleEnd_s, ...
    adcCount,positiveCount,baselineCount, ...
    completeADC,completePhysical,completeFeedback, ...
    cycleFirstADC_s,cycleLastADCend_s, ...
    cycleFirstRise_s,cycleLastFall_s, ...
    cycleFinalStart_s,cycleFinalEnd_s, ...
    cycleControlStart_s, ...
    cycleBaseline_V,cyclePlateau_V, ...
    Ts_logging_ms, ...
    burstAcquisition_ms,burstPhysical_ms, ...
    finalADCToRise_ms, ...
    finalisationToRise_ms, ...
    finalADCToDACMarker_ms, ...
    finalisationToDACMarker_ms);

%% 19. CREATE SUMMARY TABLE

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
    "State 7 update interval"
    "Short update interval"
    "Long update interval"
    "Final ADC to voltage rise"
    "Finalisation to voltage rise"
    "Final ADC to DAC marker"
    "Finalisation to DAC marker"
    "DAC marker to voltage rise"
    "Measurement finalisation"
    "Controller and supervisor"
    "CSV logging"
    "Load baseline voltage"
    "Load plateau voltage"
    "Load pulse amplitude"
];

metricValues = {
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
    Ts_logging_ms(shortPeriod)
    Ts_logging_ms(longPeriod)
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

units = [
    repmat("us",6,1)
    repmat("ms",10,1)
    repmat("us",4,1)
    repmat("V",3,1)
];

nMetrics = numel(metricNames);

metricN = zeros(nMetrics,1);
metricMean = NaN(nMetrics,1);
metricMedian = NaN(nMetrics,1);
metricStd = NaN(nMetrics,1);
metricMin = NaN(nMetrics,1);
metricMax = NaN(nMetrics,1);

for k = 1:nMetrics

    x = metricValues{k};
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
    metricNames,units,metricN, ...
    metricMean,metricMedian,metricStd, ...
    metricMin,metricMax);

%% 20. FIGURE 1: FULL RECORDING SUMMARY

% Do not compress thousands of pulses into a solid
% black waveform.
%
% Summarise the entire recording at burst resolution.

fig1 = figure( ...
    'Color','w', ...
    'Name','OpenXstim - Full timing overview');

tl = tiledlayout(3,1, ...
    'TileSpacing','compact', ...
    'Padding','compact');

recordTime_s = cycleEnd_s-t(1);

% ------------------------------------------------------------
% Per-burst output voltage
% ------------------------------------------------------------

nexttile;

plot(recordTime_s,cyclePlateau_V, ...
    'o-','MarkerSize',3,'LineWidth',0.9);

ylabel('Plateau voltage (V)');
title('Measured load-voltage plateau per burst');
grid on;

% ------------------------------------------------------------
% Update period
% ------------------------------------------------------------

nexttile;

plot(recordTime_s,Ts_logging_ms, ...
    '.-','LineWidth',0.8,'MarkerSize',8);

hold on;

yline(76,':','76 ms');
yline(89,':','89 ms');

ylabel('Update period (ms)');
title('Alternating controller update intervals');
grid on;

% ------------------------------------------------------------
% Physical feedback latency
% ------------------------------------------------------------

nexttile;

plot(recordTime_s,finalisationToRise_ms, ...
    '.-','LineWidth',0.8,'MarkerSize',8);

ylabel('Latency (ms)');
xlabel('Time since start of recording (s)');
title('Finalisation to next physical voltage rise');
grid on;

title(tl, ...
    'OpenXstim: full-recording feedback characterisation');

%% 21. FIGURE 2: REPRESENTATIVE PHYSICAL PULSE

% Select a fully matched pulse near the middle
% of the recording.

validPulseIDs = find(fullyMatched);

if isempty(validPulseIDs)
    validPulseIDs = find(isfinite(pulseRise_s));
end

fig2 = figure( ...
    'Color','w', ...
    'Name','OpenXstim - Individual pulse timing');

if ~isempty(validPulseIDs)

    p = validPulseIDs( ...
        ceil(numel(validPulseIDs)/2));

    r = pulseRise_s(p);
    f = pulseFall_s(p);

    left = r-1.12e-3;
    right = f+200e-6;

    idx = find(t>=left & t<=right);
    idx = thinIndices(idx,cfg.maxPlotPoints);

    x_us = (t(idx)-r)*1e6;

    yyaxis left;

    h1 = plot(x_us,loadV(idx), ...
        'k','LineWidth',1.1);

    ylabel('Load voltage (V)');

    yyaxis right;

    h2 = stairs(x_us,double(rawState(idx)), ...
        'LineWidth',1.1);

    ylabel('Firmware state');
    ylim([-0.5 7.5]);
    yticks(0:7);

    xlabel('Time relative to physical voltage rise (us)');

    hold on;

    xline(0,':','Physical rise');

    xline( ...
        (adcStartTimes(p)-r)*1e6, ...
        ':','ADC start');

    xline( ...
        (adcEndTimes(p)-r)*1e6, ...
        ':','ADC end');

    xline( ...
        (f-r)*1e6, ...
        ':','Physical fall');

    legend([h1 h2], ...
        {'Load voltage','Firmware state'}, ...
        'Location','best');

    title(sprintf( ...
        ['Representative pulse: ADC %.1f us, ' ...
        'physical HIGH %.1f us'], ...
        acquisition_us(p),pulseHighWidth_us(p)));

    grid on;

else

    text(0.1,0.5, ...
        'No representative physical pulse available.');

    axis off;
end

%% 22. FIGURE 3: REPRESENTATIVE COMPLETE FEEDBACK CYCLE

fig3 = figure( ...
    'Color','w', ...
    'Name','OpenXstim - Complete feedback cycle');

tl = tiledlayout(3,1, ...
    'TileSpacing','compact', ...
    'Padding','compact');

% Select a cycle with confirmed acquisition,
% physical pulse matching and latency.

validCycleIDs = find( ...
    completeFeedback & ...
    isfinite(finalisationToRise_ms));

if ~isempty(validCycleIDs)

    k = validCycleIDs( ...
        ceil(numel(validCycleIDs)/2));

    firstRise = cycleFirstRise_s(k);

    % Identify the next pulse rise after this
    % feedback cycle's closing logging marker.
    nextADC = find( ...
        adcStartTimes>cycleEnd_s(k),1,'first');

    nextRise = pulseRise_s(nextADC);

    plotLeft = firstRise-0.5e-3;
    plotRight = nextRise+0.5e-3;

    idx = find(t>=plotLeft & t<=plotRight);
    idx = thinIndices(idx,cfg.maxPlotPoints);

    x_ms = (t(idx)-firstRise)*1e3;

    % --------------------------------------------------------
    % Full physical waveform
    % --------------------------------------------------------

    nexttile;

    plot(x_ms,loadV(idx), ...
        'k','LineWidth',0.9);

    hold on;

    xline( ...
        (cycleFinalStart_s(k)-firstRise)*1e3, ...
        ':','Finalisation');

    xline( ...
        (nextRise-firstRise)*1e3, ...
        ':','Next burst');

    ylabel('Load voltage (V)');

    title(sprintf( ...
        'Complete feedback cycle %d: %d ADC windows', ...
        k,adcCount(k)));

    grid on;

    % --------------------------------------------------------
    % Firmware state
    % --------------------------------------------------------

    nexttile;

    stairs(x_ms,double(rawState(idx)), ...
        'LineWidth',0.8);

    hold on;

    xline( ...
        (cycleFinalStart_s(k)-firstRise)*1e3, ...
        ':','Finalisation');

    xline( ...
        (cycleEnd_s(k)-firstRise)*1e3, ...
        ':','Logging');

    ylabel('State');
    yticks(0:7);
    ylim([-0.5 7.5]);

    title('Firmware operation and inter-burst waiting');
    grid on;

    % --------------------------------------------------------
    % End-of-burst detail
    % --------------------------------------------------------

    nexttile;

    zoomLeft = cycleFinalStart_s(k)-2e-3;
    zoomRight = cycleEnd_s(k)+1.1e-3;

    zoomIdx = find( ...
        t>=zoomLeft & t<=zoomRight);

    zoomIdx = thinIndices( ...
        zoomIdx,cfg.maxPlotPoints);

    zoomX_us = ...
        (t(zoomIdx)-cycleFinalStart_s(k))*1e6;

    stairs(zoomX_us, ...
        double(rawState(zoomIdx)), ...
        'LineWidth',1.1);

    hold on;

    xline(0,':','State 5');

    xline( ...
        (cycleEnd_s(k)- ...
         cycleFinalStart_s(k))*1e6, ...
        ':','State 7');

    ylabel('State');
    xlabel('Time relative to finalisation (us)');

    yticks(0:7);
    ylim([-0.5 7.5]);

    title('End-of-burst processing detail');
    grid on;

else

    nexttile;
    text(0.1,0.5, ...
        'No fully validated feedback cycle available.');
    axis off;

    nexttile;
    axis off;

    nexttile;
    axis off;
end

title(tl, ...
    'OpenXstim: burst acquisition and feedback execution');

%% 23. EXPORT TABLES

writetable(channelTable, ...
    fullfile(cfg.outputFolder, ...
    'ChannelSummary.csv'));

writetable(stateTable, ...
    fullfile(cfg.outputFolder, ...
    'StateTiming.csv'));

writetable(pulseTable, ...
    fullfile(cfg.outputFolder, ...
    'PulseTiming.csv'));

writetable(cycleTable, ...
    fullfile(cfg.outputFolder, ...
    'FeedbackCycles.csv'));

writetable(summaryTable, ...
    fullfile(cfg.outputFolder, ...
    'TimingSummary.csv'));

%% 24. EXPORT FIGURES

if cfg.exportFigures

    exportgraphics(fig1, ...
        fullfile(cfg.outputFolder, ...
        'Figure1_RecordingSummary.png'), ...
        'Resolution',cfg.figureResolution);

    exportgraphics(fig2, ...
        fullfile(cfg.outputFolder, ...
        'Figure2_RepresentativePulse.png'), ...
        'Resolution',cfg.figureResolution);

    exportgraphics(fig3, ...
        fullfile(cfg.outputFolder, ...
        'Figure3_FeedbackCycle.png'), ...
        'Resolution',cfg.figureResolution);
end

%% 25. SAVE MATLAB RESULTS

% Save numerical results, not the entire
% multi-million-sample waveform.

save(fullfile(cfg.outputFolder, ...
    'Stage1_TimingResults.mat'), ...
    'cfg','channelTable','stateTable', ...
    'pulseTable','cycleTable','summaryTable', ...
    'usedThresholds', ...
    'Ts_controller_ms','Ts_logging_ms', ...
    'finalADCToRise_ms', ...
    'finalisationToRise_ms', ...
    'pulsePeriod_us');

fprintf('\n========================================\n');
fprintf(' FINAL TIMING SUMMARY\n');
fprintf('========================================\n');

disp(summaryTable);

fprintf('\nResults folder:\n%s\n', ...
    fullfile(pwd,cfg.outputFolder));

fprintf('\nAnalysis complete.\n');

%% ========================================================================
% LOCAL FUNCTIONS
%% ========================================================================

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

function reportMetric(name,x,unit)

    x = x(isfinite(x));

    if isempty(x)
        fprintf('%-37s unavailable\n',name);
        return;
    end

    if numel(x)>1
        sigma = std(x);
    else
        sigma = NaN;
    end

    fprintf( ...
        ['%-37s mean=%9.3f %s  ' ...
         'median=%9.3f  std=%8.3f  n=%d\n'], ...
        name,mean(x),unit, ...
        median(x),sigma,numel(x));
end

function idx = thinIndices(idx,maxPoints)

    if numel(idx)<=maxPoints
        return;
    end

    selected = unique(round( ...
        linspace(1,numel(idx),maxPoints)));

    idx = idx(selected);
end
