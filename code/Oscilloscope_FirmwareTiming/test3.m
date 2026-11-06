
%% OpenXstim Timing Analysis - Stage 1
% Single Rigol CSV, 4 channels, 3-bit state decoder
% CH1 = load voltage
% CH2 = bit 0 (D5)
% CH3 = bit 1 (D8)
% CH4 = bit 2 (A2)
%
% State 0: Idle
% State 1: Positive DAC write
% State 2: ADC settling
% State 3: ADC acquisition
% State 4: Baseline DAC write
% State 5: Measurement finalisation
% State 6: Fault checks + PI + preparation
% State 7: Logging
%
% Requires MATLAB R2019b or newer.

clear; clc; close all;

%% 1. CONFIGURATION

filename = 'RigolDS0.csv';  % Change to actual filename

pulsesPerBurst = 20;

% Set manually if digital HIGH voltage is known.
% Leave NaN for automatic thresholding.
digitalThresholds = [NaN NaN NaN];

% Conservative glitch rejection:
% Only remove short intermediary codes bracketed by
% stable states requiring multiple GPIO bit changes.
maxGlitch_us = 1.0;
minNeighbour_us = 1.0;

% Maximum number of plotted samples per trace.
maxPlotPoints = 15000;

stateNames = [
    "Idle"
    "Positive DAC"
    "ADC settling"
    "ADC acquisition"
    "Baseline DAC"
    "Measurement finalisation"
    "Fault checks + PI"
    "Logging"
];



%% 2. CSV IMPORT - RIGOL WITH DIRECT DOWNSAMPLING

assert(isfile(filename), ...
    'CSV file not found: %s', filename);

fprintf('\n=== OPENXSTIM STAGE 1 ===\n');
fprintf('File: %s\n', filename);

% Downsampling factor:
% 1 = keep every sample
% 10 = keep every tenth sample
downsampleFactor = 1;

fid = fopen(filename, 'r');
assert(fid >= 0, 'Unable to open CSV.');

% Read Rigol metadata header.
header = fgetl(fid);

t0Match = regexp(header, ...
    't0\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
    'tokens', 'once');

dtMatch = regexp(header, ...
    'tInc\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
    'tokens', 'once');

assert(~isempty(t0Match), ...
    'Could not find t0 in CSV header.');

assert(~isempty(dtMatch), ...
    'Could not find tInc in CSV header.');

t0 = str2double(t0Match{1});
originalDt = str2double(dtMatch{1});

assert(isfinite(t0) && ...
       isfinite(originalDt) && originalDt > 0, ...
       'Invalid timing metadata.');

% Allocate space for approximately 1 million samples.
fileInfo = dir(filename);

estimatedRows = max(1000, ...
    ceil(fileInfo.bytes / 60 / downsampleFactor));

voltage = zeros(estimatedRows,4);
sampleIndices = zeros(estimatedRows,1);

storedCount = 0;
originalIndex = 0;
malformedCount = 0;

fprintf('Reading every %dth sample...\n', ...
    downsampleFactor);

tic;

while ~feof(fid)

    line = fgetl(fid);

    if ~ischar(line)
        break;
    end

    % Only parse every nth row.
    if mod(originalIndex,downsampleFactor) == 0

        % Read first four comma-separated values.
        values = sscanf(strrep(line,',',' '), ...
            '%f',4);

        if numel(values) == 4 && all(isfinite(values))

            storedCount = storedCount + 1;

            % Expand allocation if needed.
            if storedCount > size(voltage,1)
                voltage(end+100000,4) = 0;
                sampleIndices(end+100000,1) = 0;
            end

            voltage(storedCount,:) = values(:)';
            sampleIndices(storedCount) = originalIndex;

        else
            malformedCount = malformedCount + 1;
        end
    end

    originalIndex = originalIndex + 1;

end

fclose(fid);

% Trim unused allocated memory.
voltage = voltage(1:storedCount,:);
sampleIndices = sampleIndices(1:storedCount);

assert(storedCount > 100, ...
    'Too few valid samples imported.');

% Warn about malformed selected rows.
if malformedCount > 0
    warning('%d selected rows were malformed.', ...
        malformedCount);
end

% Time reconstruction uses ORIGINAL indices.
t = t0 + sampleIndices*originalDt;

% Effective sampling interval.
dt = originalDt*downsampleFactor;
fs = 1/dt;

N = size(voltage,1);
recordDuration = t(end)-t(1);

fprintf('\n=== ACQUISITION SUMMARY ===\n');
fprintf('Original data rows: %d\n',originalIndex);
fprintf('Retained samples: %d\n',N);
fprintf('Downsampling factor: %d\n',downsampleFactor);

fprintf('Original sampling rate: %.3f MHz\n', ...
    1/originalDt/1e6);

fprintf('Effective sampling rate: %.3f MHz\n', ...
    fs/1e6);

fprintf('Effective sample interval: %.3f ns\n', ...
    dt*1e9);

fprintf('Recording duration: %.3f ms\n', ...
    recordDuration*1e3);

fprintf('Import time: %.2f seconds\n',toc);

for ch = 1:4
    fprintf('CH%d range: %.4f to %.4f V\n', ...
        ch,min(voltage(:,ch)),max(voltage(:,ch)));
end

fprintf('\nCSV import successful.\n');


%% 3. DIGITAL THRESHOLDING

debugVoltages = voltage(:, 2:4);
bits = false(N, 3);

for ch = 1:3
    v = debugVoltages(:,ch);

    vLow = min(v);
    vHigh = max(v);

    if isnan(digitalThresholds(ch))
        threshold = (vLow + vHigh)/2;
    else
        threshold = digitalThresholds(ch);
    end

    assert(vHigh > vLow, ...
        'CH%d has no measurable variation.', ch+1);

    bits(:,ch) = v > threshold;

    lowCount = nnz(~bits(:,ch));
    highCount = nnz(bits(:,ch));

    fprintf(['CH%d: threshold %.3f V, ' ...
        'LOW %d, HIGH %d\n'], ...
        ch+1, threshold, lowCount, highCount);

    if min(lowCount, highCount) < 5
        warning('CH%d has very few samples at one logic level.', ...
            ch+1);
    end
end

%% 4. ORIGINAL STATE DECODING

rawState = uint8(bits(:,1)) ...
         + 2*uint8(bits(:,2)) ...
         + 4*uint8(bits(:,3));

% Retain rawState for diagnostic comparison.
state = rawState;

%% 5. CONSERVATIVE GLITCH HANDLING

glitchCount = 0;
glitchSamples = 0;

% Multiple passes accommodate consecutive intermediary codes.
for pass = 1:3

    [segStart, segEnd, segCode] = makeSegments(state);

    changed = false;

    for k = 2:numel(segCode)-1
        current = segCode(k);
        previous = segCode(k-1);
        following = segCode(k+1);

        currentDuration = ...
            (segEnd(k)-segStart(k)+1)*dt;

        previousDuration = ...
            (segEnd(k-1)-segStart(k-1)+1)*dt;

        followingDuration = ...
            (segEnd(k+1)-segStart(k+1)+1)*dt;

        % Preserve the intentionally short processing states.
        if ismember(current, uint8([5 6 7]))
            continue;
        end

        if currentDuration > maxGlitch_us*1e-6
            continue;
        end

        if previousDuration < minNeighbour_us*1e-6 || ...
           followingDuration < minNeighbour_us*1e-6
            continue;
        end

        % A likely intermediary GPIO code lies one bit
        % away from both the preceding and following states.
        distanceBefore = bitCount(bitxor(current,previous));
        distanceAfter = bitCount(bitxor(current,following));
        distanceAcross = bitCount(bitxor(previous,following));

        if distanceBefore == 1 && ...
           distanceAfter == 1 && distanceAcross >= 2

            % Replace the intermediary segment with the
            % preceding code. Preserve rawState separately.
            idx = segStart(k):segEnd(k);
            state(idx) = previous;

            glitchCount = glitchCount + 1;
            glitchSamples = glitchSamples + numel(idx);
            changed = true;
        end
    end

    if ~changed
        break;
    end
end

fprintf('\nGlitch processing:\n');
fprintf('Suspected glitches: %d\n', glitchCount);
fprintf('Affected samples: %d\n', glitchSamples);

[segStart, segEnd, segCode] = makeSegments(state);

segT0 = t(segStart);
segT1 = t(segEnd) + dt;
segDuration = segT1 - segT0;

nSeg = numel(segCode);

%% 6. STATE TIMING STATISTICS

fprintf('\n=== STATE TIMING ===\n');

stateNumber = (0:7)';
occurrences = zeros(8,1);
mean_us = NaN(8,1);
median_us = NaN(8,1);
min_us = NaN(8,1);
max_us = NaN(8,1);
std_us = NaN(8,1);

for s = 0:7
    d = segDuration(segCode == s)*1e6;

    occurrences(s+1) = numel(d);

    if ~isempty(d)
        mean_us(s+1) = mean(d);
        median_us(s+1) = median(d);
        min_us(s+1) = min(d);
        max_us(s+1) = max(d);

        if numel(d) > 1
            std_us(s+1) = std(d);
        end
    else
        warning('State %d is absent.', s);
    end
end

stateTable = table( ...
    stateNumber, stateNames, occurrences, ...
    mean_us, median_us, min_us, max_us, std_us);

disp(stateTable);

%% 7. PULSE DETECTION

% A valid pulse requires the ordered sequence:
% 1 -> 2 -> 3 -> 4
%
% State 0 is permitted between these states.
% A standalone extra State 4 cannot form a new pulse.

positiveSegments = find(segCode == 1);

pulseStart = [];
pulseEnd = [];
pulseSegments = zeros(0,4);
incompletePulses = 0;
unexpectedSequences = 0;

for p = 1:numel(positiveSegments)

    i1 = positiveSegments(p);

    % Stop at the next positive command or processing
    % state, whichever comes first.
    stopIdx = nSeg + 1;

    for j = i1+1:nSeg
        if segCode(j) == 1 || segCode(j) >= 5
            stopIdx = j;
            break;
        end
    end

    matched = zeros(1,4);
    matched(1) = i1;

    searchFrom = i1 + 1;
    valid = true;

    for expected = 2:4
        candidate = [];

        for j = searchFrom:stopIdx-1
            if segCode(j) == expected
                candidate = j;
                break;
            end

            % Unexpected non-idle state.
            if segCode(j) ~= 0
                break;
            end
        end

        if isempty(candidate)
            valid = false;
            break;
        end

        matched(expected) = candidate;
        searchFrom = candidate + 1;
    end

    if ~valid
        incompletePulses = incompletePulses + 1;
        continue;
    end

    % Reject any non-idle event occurring out of order
    % inside the matched pulse.
    localCodes = double(segCode(i1:matched(4)));
    nonzeroCodes = localCodes(localCodes ~= 0);

    if ~isequal(nonzeroCodes(:)', [1 2 3 4])
        unexpectedSequences = unexpectedSequences + 1;
        continue;
    end

    % Do not certify a pulse that begins at capture edge.
    if segStart(i1) == 1
        incompletePulses = incompletePulses + 1;
        continue;
    end

    pulseStart(end+1,1) = segT0(i1);
    pulseEnd(end+1,1) = segT1(matched(4));
    pulseSegments(end+1,:) = matched;
end

nPulses = numel(pulseStart);

fprintf('\n=== PULSE DETECTION ===\n');
fprintf('Valid pulses: %d\n', nPulses);
fprintf('Incomplete candidates: %d\n', incompletePulses);
fprintf('Unexpected sequences: %d\n', unexpectedSequences);

pulseTable = table( ...
    pulseStart, pulseEnd, ...
    'VariableNames', {'Start_s','End_s'});

if nPulses > 0
    pulseTable.PositiveDAC_us = ...
        segDuration(pulseSegments(:,1))*1e6;
    pulseTable.ADCsettling_us = ...
        segDuration(pulseSegments(:,2))*1e6;
    pulseTable.ADCacquisition_us = ...
        segDuration(pulseSegments(:,3))*1e6;
    pulseTable.BaselineDAC_us = ...
        segDuration(pulseSegments(:,4))*1e6;
    pulseTable.PulseDuration_us = ...
        (pulseEnd-pulseStart)*1e6;
end

%% 8. BURST DETECTION

% State 5 marks the end of a feedback burst.
% Each complete burst must contain exactly 20 valid
% preceding pulses, bounded by processing markers.

endMarkers = find(segCode == 5);

nMarkers = numel(endMarkers);

burstFirstPulse = NaN(nMarkers,1);
burstLastPulse = NaN(nMarkers,1);
burstPulseCount = zeros(nMarkers,1);
burstComplete = false(nMarkers,1);

previousBoundary = -Inf;

for b = 1:nMarkers
    boundary = segT0(endMarkers(b));

    members = find( ...
        pulseStart > previousBoundary & ...
        pulseStart < boundary);

    burstPulseCount(b) = numel(members);

    if ~isempty(members)
        burstFirstPulse(b) = members(1);
        burstLastPulse(b) = members(end);
    end

    if numel(members) == pulsesPerBurst

        % Only accept complete, interior pulses.
        % The pulse decoder excludes a truncated
        % first pulse at the recording boundary.
        burstComplete(b) = true;
    end

    previousBoundary = boundary;
end

completeBurstIDs = find(burstComplete);

fprintf('\n=== BURST DETECTION ===\n');
fprintf('State 5 markers: %d\n', nMarkers);
fprintf('Complete 20-pulse bursts: %d\n', ...
    nnz(burstComplete));
fprintf('Incomplete/nonstandard groups: %d\n', ...
    nnz(~burstComplete));

for b = 1:nMarkers
    if ~burstComplete(b)
        fprintf('Group %d: %d pulses (not complete)\n', ...
            b, burstPulseCount(b));
    end
end

%% 9. TIMING CALCULATIONS

pulsePeriod_us = [];
burstAcquisition_ms = [];
controllerTs_ms = [];
commandLatency_ms = [];
measurementToCommand_ms = [];

% Pulse periods only within complete bursts.
for b = completeBurstIDs'
    ids = burstFirstPulse(b):burstLastPulse(b);

    if numel(ids) > 1
        pulsePeriod_us = [pulsePeriod_us; ...
            diff(pulseStart(ids))*1e6];
    end

    burstAcquisition_ms(end+1,1) = ...
        (pulseEnd(ids(end))-pulseStart(ids(1)))*1e3;
end

% Compare equivalent first-actuation events in
% consecutive complete bursts.
for k = 1:numel(completeBurstIDs)-1
    b = completeBurstIDs(k);
    nextB = completeBurstIDs(k+1);

    % Do not bridge over an incomplete burst.
    if nextB ~= b+1
        continue;
    end

    firstA = burstFirstPulse(b);
    firstB = burstFirstPulse(nextB);

    controllerTs_ms(end+1,1) = ...
        (pulseStart(firstB)-pulseStart(firstA))*1e3;

    % End of final ADC acquisition in burst A.
    lastPulse = burstLastPulse(b);
    adcSegment = pulseSegments(lastPulse,3);

    finalADCend = segT1(adcSegment);
    nextDACstart = pulseStart(firstB);

    commandLatency_ms(end+1,1) = ...
        (nextDACstart-finalADCend)*1e3;

    % This assumes State 5 starts when measurement
    % finalisation begins, NOT when the average is ready.
    finalisationEnd = segT1(endMarkers(b));

    measurementToCommand_ms(end+1,1) = ...
        (nextDACstart-finalisationEnd)*1e3;
end

% State 6 includes several operations, so it cannot
% be interpreted as pure PI calculation time.
state6_ms = segDuration(segCode == 6)*1e3;
state7_ms = segDuration(segCode == 7)*1e3;
state5_us = segDuration(segCode == 5)*1e6;

%% 10. NUMERICAL SUMMARY

fprintf('\n=== FEEDBACK TIMING SUMMARY ===\n');

printMetric('Pulse period',pulsePeriod_us,'us');
printMetric('Burst acquisition',burstAcquisition_ms,'ms');
printMetric('Controller update Ts',controllerTs_ms,'ms');
printMetric('Final ADC to next DAC',commandLatency_ms,'ms');
printMetric('End State 5 to next DAC', ...
    measurementToCommand_ms,'ms');

printMetric('State 5 finalisation',state5_us,'us');
printMetric('State 6 combined processing',state6_ms,'ms');
printMetric('State 7 logging',state7_ms,'ms');

fprintf('\nIMPORTANT:\n');
fprintf(['State 6 duration is not necessarily the ' ...
    'PI computation duration.\n']);
fprintf(['State 3 gives the acquisition-window duration, ' ...
    'not individual ADC timestamps.\n']);

% Distribution-based timing warning.
allTimings = {
    pulsePeriod_us, 'Pulse period'
    controllerTs_ms, 'Controller Ts'
    commandLatency_ms, 'Command latency'
};

for k = 1:size(allTimings,1)
    x = allTimings{k,1};

    if numel(x) >= 5
        med = median(x);
        deviation = abs(x-med);

        if med > 0 && max(deviation) > 0.20*med
            warning('%s has observations >20%% from median.', ...
                allTimings{k,2});
        end
    end
end

%% 11. FIGURE 1: FULL RECORDING

figure('Name','Stage 1 - Recording overview', ...
    'Color','w');

tiledlayout(4,1,'TileSpacing','compact');

plotIdx = unique(round(linspace(1,N, ...
    min(N,maxPlotPoints))));

for ch = 1:4
    nexttile;
    plot(t(plotIdx)*1e3,voltage(plotIdx,ch), ...
        'LineWidth',0.8);
    ylabel(sprintf('CH%d (V)',ch));
    grid on;

    if ch == 1
        title('Load voltage - Full recording');
    end
end

xlabel('Time (ms)');

% Highlight complete bursts on the load-voltage panel.
ax = nexttile(1);
hold(ax,'on');

for b = completeBurstIDs'
    x1 = pulseStart(burstFirstPulse(b))*1e3;
    x2 = segT1(endMarkers(b))*1e3;

    xline(ax,x1,':','Color',[0.2 0.6 0.2]);
    xline(ax,x2,':','Color',[0.6 0.2 0.2]);
end

%% 12. FIGURE 2: DECODED STATE SEQUENCE

figure('Name','Stage 1 - State decoding', ...
    'Color','w');

% Select several pulses from a complete burst if possible.
if ~isempty(completeBurstIDs)
    b = completeBurstIDs(1);
    firstP = burstFirstPulse(b);
    lastP = min(firstP+4,burstLastPulse(b));

    zoomStart = pulseStart(firstP);
    zoomEnd = pulseEnd(lastP);

elseif nPulses > 0
    zoomStart = pulseStart(1);
    zoomEnd = pulseEnd(min(5,nPulses));

else
    zoomStart = t(1);
    zoomEnd = t(1)+min(0.005,recordDuration);
end

zoomMask = t >= zoomStart & t <= zoomEnd;
zoomIdx = find(zoomMask);

if numel(zoomIdx) > maxPlotPoints
    zoomIdx = zoomIdx(unique(round(linspace( ...
        1,numel(zoomIdx),maxPlotPoints))));
end

tiledlayout(2,1);

nexttile;
stairs(t(zoomIdx)*1e3,double(rawState(zoomIdx)), ...
    'Color',[0.7 0.7 0.7]);
hold on;
stairs(t(zoomIdx)*1e3,double(state(zoomIdx)), ...
    'b','LineWidth',1);
ylim([-0.5 7.5]);
yticks(0:7);
ylabel('State');
title('Raw vs cleaned state');
legend('Raw','Cleaned');
grid on;

nexttile;
plot(t(zoomIdx)*1e3,voltage(zoomIdx,1),'k');
ylabel('Load voltage (V)');
xlabel('Time (ms)');
title('Corresponding physical output');
grid on;

%% 13. FIGURE 3: DETAILED TIMING

figure('Name','Stage 1 - Detailed timing', ...
    'Color','w');

tiledlayout(2,1,'TileSpacing','compact');

% Representative pulse.
nexttile;

if nPulses > 0
    if ~isempty(completeBurstIDs)
        p = burstFirstPulse(completeBurstIDs(1));
    else
        p = 1;
    end

    a = pulseStart(p)-5e-6;
    z = pulseEnd(p)+5e-6;

    plotStateVoltage(t,state,voltage(:,1),a,z, ...
        maxPlotPoints);

    title(sprintf(['Representative pulse: ' ...
        'DAC %.1f us, settle %.1f us, ' ...
        'ADC %.1f us, baseline %.1f us'], ...
        pulseTable.PositiveDAC_us(p), ...
        pulseTable.ADCsettling_us(p), ...
        pulseTable.ADCacquisition_us(p), ...
        pulseTable.BaselineDAC_us(p)));
else
    title('No complete pulse identified');
    axis off;
end

% End-of-burst processing.
nexttile;

if ~isempty(completeBurstIDs)
    b = completeBurstIDs(1);

    lastP = burstLastPulse(b);
    a = pulseStart(lastP);

    marker = endMarkers(b);
    z = min(t(end),segT1(marker)+0.005);

    % If next burst is available, include its beginning.
    if b < nMarkers && ~isnan(burstFirstPulse(b+1))
        z = min(t(end),pulseStart(burstFirstPulse(b+1)) ...
            + 0.0002);
    end

    plotStateVoltage(t,state,voltage(:,1),a,z, ...
        maxPlotPoints);
    title('Final pulse, processing and next command');

elseif ~isempty(endMarkers)
    marker = endMarkers(1);
    a = max(t(1),segT0(marker)-0.002);
    z = min(t(end),segT1(marker)+0.005);

    plotStateVoltage(t,state,voltage(:,1),a,z, ...
        maxPlotPoints);
    title('Processing marker - incomplete burst');

else
    title('No end-of-burst processing marker found');
    axis off;
end

%% 14. FINAL QUALITY REPORT

fprintf('\n=== QUALITY REPORT ===\n');

missingStates = find(occurrences == 0)-1;

if isempty(missingStates)
    fprintf('All eight states were observed.\n');
else
    fprintf('Missing states: %s\n',mat2str(missingStates'));
end

fprintf('Suspected GPIO glitches: %d\n',glitchCount);
fprintf('Incomplete pulse candidates: %d\n',incompletePulses);
fprintf('Unexpected pulse sequences: %d\n', ...
    unexpectedSequences);

fprintf('Complete bursts: %d\n',nnz(burstComplete));

if numel(controllerTs_ms) < 2
    fprintf(['WARNING: Insufficient consecutive complete ' ...
        'bursts to characterise Ts variation.\n']);
end

fprintf('\nStage 1 finished.\n');

%% LOCAL HELPER FUNCTIONS

function [starts,ends,codes] = makeSegments(s)
    s = s(:);

    starts = [1;find(diff(double(s))~=0)+1];
    ends = [starts(2:end)-1;numel(s)];
    codes = s(starts);
end

function n = bitCount(x)
    n = 0;
    x = uint8(x);

    for bit = 1:3
        n = n + double(bitget(x,bit));
    end
end

function printMetric(name,x,unit)
    if isempty(x)
        fprintf('%-31s : unavailable\n',name);
        return;
    end

    fprintf(['%-31s : mean %.3f %s, ' ...
        'std %.3f, n=%d\n'], ...
        name,mean(x),unit,std(x),numel(x));
end

function plotStateVoltage(t,state,v,a,z,maxPoints)

    idx = find(t >= a & t <= z);

    if isempty(idx)
        axis off;
        return;
    end

    if numel(idx) > maxPoints
        selected = unique(round(linspace( ...
            1,numel(idx),maxPoints)));
        idx = idx(selected);
    end

    yyaxis left;
    plot(t(idx)*1e3,v(idx),'k');
    ylabel('Load voltage (V)');

    yyaxis right;
    stairs(t(idx)*1e3,double(state(idx)), ...
        'b','LineWidth',1);
    ylabel('State');
    ylim([-0.5 7.5]);
    yticks(0:7);

    xlabel('Time (ms)');
    grid on;
end
