%% OpenXstim_ClassifyEncodedCapture.m
% STEP 1 ONLY: classify the two-bit command encoding and the analogue phases.
%
% This script intentionally DOES NOT:
%   - normalize responses
%   - fit transfer functions
%   - estimate poles
%
% Current experiment:
%   CH1 = D5 debug bit
%   CH2 = D8 debug bit
%   CH3 = output voltage across 1 kOhm load
%
% Encoding used by the firmware:
%
%   D8 D5   code   requested state
%    0  0     0    ZERO
%    0  1     1    POSITIVE, first positive phase
%    1  0     2    POSITIVE, entered from negative
%    1  1     3    NEGATIVE
%
% For pulse_number = 20 the expected command-event sequence is:
%
%   00 -> 01 -> 11 -> 10 -> 11 -> 10 ... -> 11 -> 00
%
% This gives exactly:
%   1  x 0 -> +I
%   20 x +I -> -I
%   19 x -I -> +I
%   1  x -I -> 0
%
% Total expected command transitions = 41.
%
% A minimum state-dwell filter is applied because two analogue GPIO traces
% can cross their thresholds on adjacent oscilloscope samples even though
% PORTD changes both bits atomically. Without this filter MATLAB can invent
% a one-sample intermediate code that never existed in firmware.

clear;
clc;
close all;

%% USER SETTINGS

CSV_FILE = "enc_6_2.csv";

EXPECTED_PULSE_COUNT = 20;

% Correct channel assignment for this experiment
D5_CHANNEL = 1;       % CH1
D8_CHANNEL = 2;       % CH2
OUTPUT_CHANNEL = 3;   % CH3

% CH3 is voltage across the 1 kOhm resistor.
R_LOAD_OHM = 1000;

% Thresholds. NaN = determine automatically from robust low/high levels.
D5_THRESHOLD_V = NaN;
D8_THRESHOLD_V = NaN;

% Any decoded state that survives for less than this is treated as a
% threshold-crossing/glitch artefact and merged into the previous state.
% Legitimate states last roughly 1 ms, so 5 us is very conservative.
MIN_STATE_DWELL_US = 5;

% Plot at most this many points so figures stay responsive.
MAX_PLOT_POINTS = 50000;

%% IMPORT

scriptFolder = getScriptFolder();

if isfile(fullfile(scriptFolder,CSV_FILE))
    csvPath = fullfile(scriptFolder,CSV_FILE);
else
    [f,p] = uigetfile("*.csv","Select Rigol memory CSV");
    if isequal(f,0)
        error("No CSV selected.");
    end
    csvPath = fullfile(p,f);
end

[data,t,t0,Ts,header] = loadRigolMemoryCSV(csvPath);

Fs = 1/Ts;

fprintf("\n============================================================\n");
fprintf("OPENXSTIM COMMAND CLASSIFICATION\n");
fprintf("============================================================\n");
fprintf("File: %s\n",csvPath);
fprintf("Rows: %d\n",size(data,1));
fprintf("Fs  : %.6f MSa/s\n",Fs/1e6);
fprintf("Ts  : %.6f ns\n",Ts*1e9);
fprintf("Capture: %.3f ms\n",(t(end)-t(1))*1e3);

required = max([D5_CHANNEL,D8_CHANNEL,OUTPUT_CHANNEL]);
if size(data,2) < required
    error("CSV does not contain all requested channels.");
end

d5V = data(:,D5_CHANNEL);
d8V = data(:,D8_CHANNEL);
outputV = data(:,OUTPUT_CHANNEL);

% With exactly 1 kOhm:
% 1 V across the load = 1 mA.
current_mA = 1000*outputV/R_LOAD_OHM;

%% DECODE RAW DEBUG BITS

[d5Raw,d5Threshold] = thresholdBit(d5V,D5_THRESHOLD_V);
[d8Raw,d8Threshold] = thresholdBit(d8V,D8_THRESHOLD_V);

rawCode = uint8(2*d8Raw + d5Raw);

fprintf("\nThresholds\n");
fprintf("D5: %.6f V\n",d5Threshold);
fprintf("D8: %.6f V\n",d8Threshold);

%% REMOVE VERY SHORT FALSE INTERMEDIATE STATES

minDwellSamples = max(2,round(MIN_STATE_DWELL_US*1e-6/Ts));

cleanCode = removeShortRuns(rawCode,minDwellSamples);

changedSamples = nnz(cleanCode ~= rawCode);

fprintf("\nState cleaning\n");
fprintf("Minimum valid dwell: %.3f us (%d samples)\n", ...
    MIN_STATE_DWELL_US,minDwellSamples);
fprintf("Samples changed by glitch cleanup: %d\n",changedSamples);

%% BUILD STABLE STATE RUN TABLE

[runStartIdx,runEndIdx,runCode] = runsFromCode(cleanCode);

nRuns = numel(runCode);

runStart_s = t(runStartIdx);
runEnd_s = t(runEndIdx);
runDuration_ms = (runEnd_s-runStart_s+Ts)*1e3;

runState = strings(nRuns,1);
runPhysicalSign = zeros(nRuns,1);
runPulse = NaN(nRuns,1);

pulseCounter = 0;

for r = 1:nRuns

    runState(r) = codeLabel(runCode(r));
    runPhysicalSign(r) = codeToSign(runCode(r));

    if runCode(r)==1 || runCode(r)==2
        pulseCounter = pulseCounter + 1;
        runPulse(r) = pulseCounter;

    elseif runCode(r)==3
        if pulseCounter > 0
            runPulse(r) = pulseCounter;
        end

    else
        runPulse(r) = NaN;
    end
end

runTable = table( ...
    (1:nRuns).', ...
    double(runCode), ...
    runState, ...
    runPhysicalSign, ...
    runPulse, ...
    runStart_s, ...
    runEnd_s, ...
    runDuration_ms, ...
    'VariableNames',{ ...
    'Run','Code','State','RequestedSign','Pulse', ...
    'Start_s','End_s','Duration_ms'});

%% BUILD COMMAND EVENT TABLE

eventIdx = runStartIdx(2:end);

nEvents = numel(eventIdx);

eventNumber = (1:nEvents).';
eventTime_s = t(eventIdx);

fromCode = double(runCode(1:end-1));
toCode = double(runCode(2:end));

fromState = strings(nEvents,1);
toState = strings(nEvents,1);

fromSign = zeros(nEvents,1);
toSign = zeros(nEvents,1);

transitionClass = strings(nEvents,1);
transitionContext = strings(nEvents,1);
pulseNumber = NaN(nEvents,1);

for e = 1:nEvents

    fromState(e) = codeLabel(fromCode(e));
    toState(e) = codeLabel(toCode(e));

    fromSign(e) = codeToSign(fromCode(e));
    toSign(e) = codeToSign(toCode(e));

    [transitionClass(e),transitionContext(e)] = ...
        classifyCodePair(fromCode(e),toCode(e));

    pulseNumber(e) = runPulse(e+1);

    if transitionClass(e)=="neg_to_zero"
        pulseNumber(e) = runPulse(e);
    end
end

eventTable = table( ...
    eventNumber, ...
    eventTime_s, ...
    fromCode,toCode, ...
    fromState,toState, ...
    fromSign,toSign, ...
    transitionClass,transitionContext, ...
    pulseNumber);

%% SANITY CHECK AGAINST FIRMWARE SEQUENCE

expectedTransitions = 2*EXPECTED_PULSE_COUNT + 1;

expectedCounts = struct( ...
    'zero_to_pos',1, ...
    'pos_to_neg',EXPECTED_PULSE_COUNT, ...
    'neg_to_pos',EXPECTED_PULSE_COUNT-1, ...
    'neg_to_zero',1);

n0p = nnz(transitionClass=="zero_to_pos");
npn = nnz(transitionClass=="pos_to_neg");
nnp = nnz(transitionClass=="neg_to_pos");
nn0 = nnz(transitionClass=="neg_to_zero");
nunexpected = nnz(transitionClass=="unexpected");

fprintf("\n============================================================\n");
fprintf("CLASSIFICATION SUMMARY\n");
fprintf("============================================================\n");

fprintf("Expected total transitions: %d\n",expectedTransitions);
fprintf("Detected total transitions: %d\n\n",nEvents);

fprintf("Transition                Expected    Detected\n");
fprintf("0 -> +I                   %8d    %8d\n",expectedCounts.zero_to_pos,n0p);
fprintf("+I -> -I                  %8d    %8d\n",expectedCounts.pos_to_neg,npn);
fprintf("-I -> +I                  %8d    %8d\n",expectedCounts.neg_to_pos,nnp);
fprintf("-I -> 0                   %8d    %8d\n",expectedCounts.neg_to_zero,nn0);
fprintf("Unexpected                            %8d\n",nunexpected);

sequencePass = ...
    nEvents==expectedTransitions && ...
    n0p==expectedCounts.zero_to_pos && ...
    npn==expectedCounts.pos_to_neg && ...
    nnp==expectedCounts.neg_to_pos && ...
    nn0==expectedCounts.neg_to_zero && ...
    nunexpected==0;

if sequencePass
    fprintf("\nRESULT: PASS. Encoded command sequence matches the firmware.\n");
else
    fprintf("\nRESULT: CHECK REQUIRED. Sequence does not exactly match expectation.\n");
end

fprintf("\nEvent sequence:\n");

disp(eventTable(:,{ ...
    'eventNumber','eventTime_s', ...
    'fromState','toState', ...
    'transitionClass','transitionContext','pulseNumber'}));

%% PHASE DURATION CHECK

positiveMask = runPhysicalSign==1;
negativeMask = runPhysicalSign==-1;

fprintf("\n============================================================\n");
fprintf("COMMAND-STATE DURATIONS\n");
fprintf("============================================================\n");

if any(positiveMask)
    fprintf("Positive command-state duration: mean %.6f ms, SD %.6f ms\n", ...
        mean(runDuration_ms(positiveMask)), ...
        std(runDuration_ms(positiveMask)));
end

if any(negativeMask)
    fprintf("Negative command-state duration: mean %.6f ms, SD %.6f ms\n", ...
        mean(runDuration_ms(negativeMask)), ...
        std(runDuration_ms(negativeMask)));
end

%% FIGURE 1: RAW DEBUG BITS + OUTPUT + DECODED STATE

N = numel(t);
stride = max(1,ceil(N/MAX_PLOT_POINTS));
p = 1:stride:N;

figure('Name','Encoded command classification');

tl = tiledlayout(4,1);
title(tl,'OpenXstim two-bit command classification');

nexttile;
plot(t(p)*1e3,d5V(p),'LineWidth',0.9);
hold on;
yline(d5Threshold,':');
grid on;
ylabel('D5 (V)');
title('CH1 = D5');
hold off;

nexttile;
plot(t(p)*1e3,d8V(p),'LineWidth',0.9);
hold on;
yline(d8Threshold,':');
grid on;
ylabel('D8 (V)');
title('CH2 = D8');
hold off;

nexttile;
stairs(t(p)*1e3,double(cleanCode(p)),'LineWidth',1);
grid on;
ylabel('Code');
yticks([0 1 2 3]);
yticklabels({'00 zero','01 + first','10 + repeat','11 negative'});
title('Clean decoded command code');

nexttile;
plot(t(p)*1e3,current_mA(p),'LineWidth',0.9);
grid on;
ylabel('Current (mA)');
xlabel('Time (ms)');
title('CH3 output, shown only for reference');

saveas(gcf,fullfile(fileparts(csvPath),"Classification_Overview.png"));

%% FIGURE 2: EVENT CLASSIFICATION TIMELINE

figure('Name','Command event classification');

plot(t(p)*1e3,current_mA(p),'LineWidth',0.9);
hold on;

for e = 1:nEvents

    xline(eventTime_s(e)*1e3,':');

    if e<=5 || e>nEvents-4
        yl = ylim;
        text( ...
            eventTime_s(e)*1e3, ...
            yl(2)-0.05*(yl(2)-yl(1)), ...
            sprintf('%d: %s',e,prettyTransition(transitionClass(e))), ...
            'Rotation',90, ...
            'VerticalAlignment','top', ...
            'HorizontalAlignment','right');
    end
end

grid on;
xlabel('Time (ms)');
ylabel('Measured current (mA)');
title('Command event times overlaid on output, no response matching yet');

hold off;

saveas(gcf,fullfile(fileparts(csvPath),"Classification_Events.png"));

%% SAVE TABLES

outFolder = fullfile(fileparts(csvPath),"ClassificationResults");

if ~isfolder(outFolder)
    mkdir(outFolder);
end

writetable(runTable,fullfile(outFolder,"StateRuns.csv"));
writetable(eventTable,fullfile(outFolder,"CommandEvents.csv"));

results = struct();
results.csvPath = csvPath;
results.header = header;
results.Ts = Ts;
results.Fs = Fs;
results.d5Threshold = d5Threshold;
results.d8Threshold = d8Threshold;
results.rawCode = rawCode;
results.cleanCode = cleanCode;
results.runTable = runTable;
results.eventTable = eventTable;
results.sequencePass = sequencePass;

save(fullfile(outFolder,"ClassificationResults.mat"),"results");

fprintf("\nSaved:\n%s\n",outFolder);

fprintf("\n============================================================\n");
fprintf("CLASSIFICATION COMPLETE\n");
fprintf("============================================================\n");

fprintf("%s\n", ...
    "Next step is NOT normalization yet.", ...
    "Next we attach one physical CH3 response time to each classified", ...
    "command event. That will let us separate:", ...
    "  (1) command delay,", ...
    "  (2) fast transition,", ...
    "  (3) within-phase slow droop.");

%% LOCAL FUNCTIONS

function [data,t,t0,Ts,header] = loadRigolMemoryCSV(path)

    fid = fopen(path,'r');
    if fid<0
        error("Could not open CSV.");
    end

    header = fgetl(fid);
    fclose(fid);

    tok = regexp(header, ...
        't0\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');

    if isempty(tok)
        error("Could not parse t0.");
    end
    t0 = str2double(tok{1});

    tok = regexp(header, ...
        'tInc\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');

    if isempty(tok)
        error("Could not parse tInc.");
    end
    Ts = str2double(tok{1});

    data = readmatrix(path,'NumHeaderLines',1);
    data(:,all(~isfinite(data),1)) = [];
    data = data(any(isfinite(data),2),:);

    t = t0 + (0:size(data,1)-1).'*Ts;
end

function [bit,threshold] = thresholdBit(v,userThreshold)

    lo = percentileLocal(v,5);
    hi = percentileLocal(v,95);

    if isnan(userThreshold)
        threshold = 0.5*(lo+hi);
    else
        threshold = userThreshold;
    end

    bit = double(v>threshold);
end

function cleaned = removeShortRuns(code,minSamples)

    cleaned = code(:);

    for iter = 1:20

        [starts,ends,codes] = runsFromCode(cleaned);

        lengths = ends-starts+1;

        shortIdx = find(lengths<minSamples);

        shortIdx(shortIdx==1 | shortIdx==numel(codes)) = [];

        if isempty(shortIdx)
            break;
        end

        changed = false;

        for jj = 1:numel(shortIdx)

            r = shortIdx(jj);

            cleaned(starts(r):ends(r)) = codes(r-1);

            changed = true;
        end

        if ~changed
            break;
        end
    end
end

function [starts,ends,codes] = runsFromCode(code)

    code = code(:);

    change = [true; diff(double(code))~=0; true];

    edges = find(change);

    starts = edges(1:end-1);
    ends = edges(2:end)-1;
    codes = code(starts);
end

function label = codeLabel(code)

    switch double(code)
        case 0
            label = "ZERO_00";
        case 1
            label = "POS_FIRST_01";
        case 2
            label = "POS_REPEAT_10";
        case 3
            label = "NEG_11";
        otherwise
            label = "INVALID";
    end
end

function s = codeToSign(code)

    switch double(code)
        case 0
            s = 0;
        case {1,2}
            s = 1;
        case 3
            s = -1;
        otherwise
            s = NaN;
    end
end

function [class,context] = classifyCodePair(fromCode,toCode)

    fromSign = codeToSign(fromCode);
    toSign   = codeToSign(toCode);

    if fromSign==0 && toSign==1

        class = "zero_to_pos";

    elseif fromSign==1 && toSign==-1

        class = "pos_to_neg";

    elseif fromSign==-1 && toSign==1

        class = "neg_to_pos";

    elseif fromSign==-1 && toSign==0

        class = "neg_to_zero";

    else

        class = "unexpected";
    end

    context = sprintf("code_%d_to_%d",fromCode,toCode);
end

function label = prettyTransition(type)

    switch type
        case "zero_to_pos"
            label = "0 -> +I";
        case "pos_to_neg"
            label = "+I -> -I";
        case "neg_to_pos"
            label = "-I -> +I";
        case "neg_to_zero"
            label = "-I -> 0";
        otherwise
            label = "unexpected";
    end
end

function q = percentileLocal(x,p)

    x = sort(x(isfinite(x)));

    if isempty(x)
        q = NaN;
        return;
    end

    if numel(x)==1
        q = x;
        return;
    end

    r = 1+(p/100)*(numel(x)-1);
    lo = floor(r);
    hi = ceil(r);

    if lo==hi
        q = x(lo);
    else
        q = x(lo)+(r-lo)*(x(hi)-x(lo));
    end
end

function folder = getScriptFolder()

    folder = pwd;

    try
        active = matlab.desktop.editor.getActiveFilename;
        if ~isempty(active)
            folder = fileparts(active);
            return;
        end
    catch
    end

    try
        f = mfilename('fullpath');
        if ~isempty(f)
            folder = fileparts(f);
        end
    catch
    end
end
