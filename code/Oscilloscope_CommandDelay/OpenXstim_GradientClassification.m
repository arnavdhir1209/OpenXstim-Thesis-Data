%% OpenXstim_GradientClassification.m
% STEP 2 ONLY: gradient-first CH3 classification and causal command matching
%
% This script deliberately does NOT normalize responses and does NOT fit a
% transfer function yet.
%
% Channels for this experiment:
%   CH1 = D5 debug bit
%   CH2 = D8 debug bit
%   CH3 = output voltage across 1 kOhm load
%
% Transition encoding:
%   D8 D5 = 00 -> -I -> 0
%   D8 D5 = 01 ->  0 -> +I
%   D8 D5 = 10 -> -I -> +I
%   D8 D5 = 11 -> +I -> -I
%
% Analysis strategy:
%   1. Decode command transition type and command time from D5/D8.
%   2. Smooth CH3 lightly and use dI/dt as the PRIMARY fast-edge detector.
%   3. Use broad pre/post sign checks only to classify each detected edge.
%      These are NOT the final CH3 state thresholds.
%   4. Match each command to the first compatible FUTURE CH3 edge.
%      No 1 ms delay is assumed or hard-coded.
%   5. Use the intervals between matched fast edges to measure the slow
%      within-phase droop.
%   6. Derive final positive/negative CH3 thresholds from the weakest
%      legitimate drooped phase levels.
%
% The next script, after visual verification of this one, should normalize
% only the fast transient while retaining the slow droop separately.

clear;
clc;
close all;

%% ========================================================================
% USER SETTINGS
% ========================================================================

CSV_FILE = "enc_6_2.csv";
EXPECTED_PULSE_COUNT = 20;

% Correct channel assignment
D5_CHANNEL = 1;       % CH1
D8_CHANNEL = 2;       % CH2
OUTPUT_CHANNEL = 3;   % CH3

R_LOAD_OHM = 1000;

% Debug thresholds. NaN = automatic midpoint between robust low/high.
D5_THRESHOLD_V = NaN;
D8_THRESHOLD_V = NaN;

% Reject very short false transition codes from sequential GPIO changes.
MIN_DEBUG_DWELL_US = 5;

% CH3 smoothing for derivative detection only.
OUTPUT_SMOOTH_US = 0.50;

% Automatic gradient threshold parameters.
% The final detector threshold is the larger of:
%   noise multiplier * robust derivative noise
%   span fraction * total bipolar span per microsecond
GRADIENT_NOISE_SIGMA_MULTIPLIER = 15;
GRADIENT_SPAN_FRACTION_PER_US = 0.015;

% Fast edges much closer than this are treated as one event.
MIN_EDGE_SEPARATION_US = 40;

% Pre/post windows used to classify candidate fast edges.
EDGE_LEVEL_GUARD_US = 8;
EDGE_LEVEL_WINDOW_US = 20;

% Broad sign classification used ONLY during initial edge matching.
% Final positive/negative state thresholds are derived later from droop.
BROAD_ZERO_FRACTION_OF_EXCURSION = 0.12;
BROAD_ZERO_NOISE_SIGMAS = 8;

% Reject derivative events that do not cause a meaningful current change.
MIN_EDGE_CHANGE_FRACTION = 0.30;

% Slow-droop analysis.
PHASE_EDGE_EXCLUSION_US = 25;
PHASE_LEVEL_WINDOW_US = 60;

% Final threshold placement between zero and the weakest legitimate phase.
% Example: weakest positive late level = 2.0 mA, margin 0.75 -> 1.5 mA.
FINAL_THRESHOLD_MARGIN = 0.75;
POSITIVE_FLOOR_PERCENTILE = 5;
NEGATIVE_CEILING_PERCENTILE = 95;

% Matching does not use this. It only flags suspicious delays afterward.
DELAY_WARNING_FACTOR = 2.0;

MAX_PLOT_POINTS = 60000;

%% ========================================================================
% IMPORT
% ========================================================================

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
fprintf("OPENXSTIM GRADIENT-FIRST CH3 CLASSIFICATION\n");
fprintf("============================================================\n");
fprintf("File   : %s\n",csvPath);
fprintf("Rows   : %d\n",size(data,1));
fprintf("Fs     : %.6f MSa/s\n",Fs/1e6);
fprintf("Ts     : %.3f ns\n",Ts*1e9);
fprintf("Capture: %.3f ms\n",(t(end)-t(1))*1e3);

requiredChannel = max([D5_CHANNEL,D8_CHANNEL,OUTPUT_CHANNEL]);
if size(data,2)<requiredChannel
    error("CSV does not contain all requested channels.");
end

d5V = data(:,D5_CHANNEL);
d8V = data(:,D8_CHANNEL);
outputV = data(:,OUTPUT_CHANNEL);

% With 1 kOhm, 1 V across the load = 1 mA.
currentRaw_mA = 1000*outputV/R_LOAD_OHM;

%% ========================================================================
% PART A: COMMAND TRANSITION CLASSIFICATION
% ========================================================================

[d5Bit,d5Threshold] = thresholdBit(d5V,D5_THRESHOLD_V);
[d8Bit,d8Threshold] = thresholdBit(d8V,D8_THRESHOLD_V);

rawCode = uint8(2*d8Bit+d5Bit);
minDebugSamples = max(2,round(MIN_DEBUG_DWELL_US*1e-6/Ts));
cleanCode = removeShortRuns(rawCode,minDebugSamples);

[cmdRunStart,~,cmdRunCode] = runsFromCode(cleanCode);

% Every NEW stable code directly identifies the transition just requested.
commandIdx = cmdRunStart(2:end);
commandCode = double(cmdRunCode(2:end));
commandTime_s = t(commandIdx);
nCommands = numel(commandIdx);

commandClass = strings(nCommands,1);
for e = 1:nCommands
    commandClass(e) = transitionCodeLabel(commandCode(e));
end

commandEvent = (1:nCommands).';
commandTable = table(commandEvent,commandTime_s,commandCode,commandClass, ...
    'VariableNames',{'CommandEvent','CommandTime_s','TransitionCode','CommandClass'});

fprintf("\n============================================================\n");
fprintf("COMMAND CLASSIFICATION\n");
fprintf("============================================================\n");
fprintf("D5 threshold: %.6f V\n",d5Threshold);
fprintf("D8 threshold: %.6f V\n",d8Threshold);
fprintf("Expected command events: %d\n",2*EXPECTED_PULSE_COUNT+1);
fprintf("Detected command events: %d\n",nCommands);
fprintf("0 -> +I  : %d\n",nnz(commandClass=="zero_to_pos"));
fprintf("+I -> -I : %d\n",nnz(commandClass=="pos_to_neg"));
fprintf("-I -> +I : %d\n",nnz(commandClass=="neg_to_pos"));
fprintf("-I -> 0  : %d\n",nnz(commandClass=="neg_to_zero"));
fprintf("Unexpected: %d\n",nnz(commandClass=="unexpected"));

%% ========================================================================
% PART B: ZERO LEVEL, NOISE, AND ROBUST BIPOLAR EXCURSIONS
% ========================================================================

if numel(commandTime_s)>=2
    typicalCommandSpacing_s = median(diff(commandTime_s),'omitnan');
else
    typicalCommandSpacing_s = 1e-3;
end

preBurstEnd_s = commandTime_s(1)-0.25*typicalCommandSpacing_s;
zeroMask = t<preBurstEnd_s;

if nnz(zeroMask)<100
    warning("Little pre-burst zero data. Using first 5 percent of capture.");
    nZero = max(100,round(0.05*numel(t)));
    zeroMask = false(size(t));
    zeroMask(1:nZero) = true;
end

zeroLevel_mA = median(currentRaw_mA(zeroMask),'omitnan');
zeroNoiseSD_mA = robustSigma(currentRaw_mA(zeroMask));

% Robust extrema reject switching spikes.
positiveRobust_mA = percentileLocal(currentRaw_mA,95);
negativeRobust_mA = percentileLocal(currentRaw_mA,5);

positiveExcursion_mA = positiveRobust_mA-zeroLevel_mA;
negativeExcursion_mA = zeroLevel_mA-negativeRobust_mA;
minExcursion_mA = min(positiveExcursion_mA,negativeExcursion_mA);

if positiveExcursion_mA<=0 || negativeExcursion_mA<=0
    error("Could not infer bipolar CH3 excursions. Check output channel/polarity.");
end

fprintf("\n============================================================\n");
fprintf("CH3 BASIC LEVELS\n");
fprintf("============================================================\n");
fprintf("Zero level            : %.6f mA\n",zeroLevel_mA);
fprintf("Zero robust noise SD  : %.6f mA\n",zeroNoiseSD_mA);
fprintf("Robust positive level : %.6f mA\n",positiveRobust_mA);
fprintf("Robust negative level : %.6f mA\n",negativeRobust_mA);

%% ========================================================================
% PART C: SMOOTH CH3 AND COMPUTE dI/dt
% ========================================================================

smoothSamples = max(3,round(OUTPUT_SMOOTH_US*1e-6/Ts));
if mod(smoothSamples,2)==0
    smoothSamples = smoothSamples+1;
end

currentSmooth_mA = movmean(currentRaw_mA,smoothSamples);
gradient_mA_per_us = gradient(currentSmooth_mA,Ts)/1e6;

gradientNoiseSigma = robustSigma(gradient_mA_per_us(zeroMask));
spanBasedGradientThreshold = GRADIENT_SPAN_FRACTION_PER_US * ...
    (positiveExcursion_mA+negativeExcursion_mA);

gradientThreshold_mA_per_us = max( ...
    GRADIENT_NOISE_SIGMA_MULTIPLIER*gradientNoiseSigma, ...
    spanBasedGradientThreshold);

fprintf("\n============================================================\n");
fprintf("GRADIENT DETECTOR\n");
fprintf("============================================================\n");
fprintf("Smoothing window       : %.3f us (%d samples)\n", ...
    OUTPUT_SMOOTH_US,smoothSamples);
fprintf("Gradient robust noise  : %.6f mA/us\n",gradientNoiseSigma);
fprintf("Gradient threshold     : %.6f mA/us\n",gradientThreshold_mA_per_us);

%% ========================================================================
% PART D: FIND FAST CH3 EDGE CANDIDATES FROM GRADIENT
% ========================================================================

aboveGradient = abs(gradient_mA_per_us)>=gradientThreshold_mA_per_us;
[groupStart,groupEnd] = trueRuns(aboveGradient);

candidateIdx = zeros(numel(groupStart),1);
for k = 1:numel(groupStart)
    idx = groupStart(k):groupEnd(k);
    [~,loc] = max(abs(gradient_mA_per_us(idx)));
    candidateIdx(k) = idx(loc);
end

minEdgeSeparationSamples = max(1,round(MIN_EDGE_SEPARATION_US*1e-6/Ts));
candidateIdx = mergeCloseEdgeCandidates(candidateIdx,gradient_mA_per_us, ...
    minEdgeSeparationSamples);

nCandidates = numel(candidateIdx);
fprintf("Raw grouped gradient candidates: %d\n",nCandidates);

%% ========================================================================
% PART E: CLASSIFY GRADIENT CANDIDATES FROM PRE/POST LEVELS
% ========================================================================

% This broad tolerance is only for saying obvious POS / ZERO / NEG while
% pairing fast edges. It is intentionally NOT the final state threshold.
broadZeroTolerance_mA = max( ...
    BROAD_ZERO_NOISE_SIGMAS*zeroNoiseSD_mA, ...
    BROAD_ZERO_FRACTION_OF_EXCURSION*minExcursion_mA);

minCandidateChange_mA = MIN_EDGE_CHANGE_FRACTION*minExcursion_mA;

guardSamples = max(1,round(EDGE_LEVEL_GUARD_US*1e-6/Ts));
levelWindowSamples = max(2,round(EDGE_LEVEL_WINDOW_US*1e-6/Ts));

candidateTime_s = t(candidateIdx);
candidateGradient_mA_per_us = gradient_mA_per_us(candidateIdx);

candidatePre_mA = NaN(nCandidates,1);
candidatePost_mA = NaN(nCandidates,1);
candidateDelta_mA = NaN(nCandidates,1);
candidatePreState = strings(nCandidates,1);
candidatePostState = strings(nCandidates,1);
candidateClass = strings(nCandidates,1);
candidateAccepted = false(nCandidates,1);
candidateReason = strings(nCandidates,1);

for k = 1:nCandidates
    idx = candidateIdx(k);

    preEnd = idx-guardSamples;
    preStart = preEnd-levelWindowSamples+1;
    postStart = idx+guardSamples;
    postEnd = postStart+levelWindowSamples-1;

    if preStart<1 || postEnd>numel(t)
        candidateReason(k) = "capture_boundary";
        continue;
    end

    candidatePre_mA(k) = median(currentSmooth_mA(preStart:preEnd),'omitnan');
    candidatePost_mA(k) = median(currentSmooth_mA(postStart:postEnd),'omitnan');
    candidateDelta_mA(k) = candidatePost_mA(k)-candidatePre_mA(k);

    candidatePreState(k) = broadStateLabel(candidatePre_mA(k), ...
        zeroLevel_mA,broadZeroTolerance_mA);
    candidatePostState(k) = broadStateLabel(candidatePost_mA(k), ...
        zeroLevel_mA,broadZeroTolerance_mA);

    candidateClass(k) = physicalTransitionFromLabels( ...
        candidatePreState(k),candidatePostState(k));

    if abs(candidateDelta_mA(k))<minCandidateChange_mA
        candidateReason(k) = "current_change_too_small";
        continue;
    end

    if candidateClass(k)=="unexpected"
        candidateReason(k) = "unknown_pre_post_state_pair";
        continue;
    end

    expectedDirection = transitionDirection(candidateClass(k));
    if sign(candidateGradient_mA_per_us(k))~=expectedDirection
        candidateReason(k) = "gradient_direction_disagrees";
        continue;
    end

    candidateAccepted(k) = true;
    candidateReason(k) = "accepted";
end

candidateTable = table((1:nCandidates).',candidateTime_s, ...
    candidateGradient_mA_per_us,candidatePre_mA,candidatePost_mA, ...
    candidateDelta_mA,candidatePreState,candidatePostState,candidateClass, ...
    candidateAccepted,candidateReason, ...
    'VariableNames',{'Candidate','Time_s','Gradient_mA_per_us','PreLevel_mA', ...
    'PostLevel_mA','Delta_mA','PreState','PostState','ResponseClass', ...
    'Accepted','Reason'});

acceptedRows = find(candidateAccepted);
responseEvent = (1:numel(acceptedRows)).';
responseTime_s = candidateTime_s(candidateAccepted);
responseClass = candidateClass(candidateAccepted);
responseGradient_mA_per_us = candidateGradient_mA_per_us(candidateAccepted);
responsePre_mA = candidatePre_mA(candidateAccepted);
responsePost_mA = candidatePost_mA(candidateAccepted);

responseTable = table(responseEvent,acceptedRows,responseTime_s,responseClass, ...
    responseGradient_mA_per_us,responsePre_mA,responsePost_mA, ...
    'VariableNames',{'ResponseEvent','CandidateRow','ResponseTime_s', ...
    'ResponseClass','PeakGradient_mA_per_us','PreLevel_mA','PostLevel_mA'});

fprintf("\n============================================================\n");
fprintf("FAST CH3 RESPONSE CLASSIFICATION\n");
fprintf("============================================================\n");
fprintf("Broad zero tolerance: +/- %.6f mA\n",broadZeroTolerance_mA);
fprintf("Minimum edge change : %.6f mA\n",minCandidateChange_mA);
fprintf("Accepted edges      : %d\n",height(responseTable));
fprintf("0 -> +I  : %d\n",nnz(responseClass=="zero_to_pos"));
fprintf("+I -> -I : %d\n",nnz(responseClass=="pos_to_neg"));
fprintf("-I -> +I : %d\n",nnz(responseClass=="neg_to_pos"));
fprintf("-I -> 0  : %d\n",nnz(responseClass=="neg_to_zero"));

%% ========================================================================
% PART F: CAUSALLY MATCH COMMANDS TO FUTURE CH3 EDGES
% ========================================================================

matchedResponseEvent = NaN(nCommands,1);
matchedResponseTime_s = NaN(nCommands,1);
delay_us = NaN(nCommands,1);
matchedGradient_mA_per_us = NaN(nCommands,1);
matchedPre_mA = NaN(nCommands,1);
matchedPost_mA = NaN(nCommands,1);
matchStatus = strings(nCommands,1);

lastUsedResponseRow = 0;

for e = 1:nCommands
    rows = find((1:height(responseTable)).' > lastUsedResponseRow & ...
        responseTable.ResponseTime_s >= commandTime_s(e) & ...
        responseTable.ResponseClass == commandClass(e));

    if isempty(rows)
        matchStatus(e) = "no_compatible_future_response";
        continue;
    end

    r = rows(1);
    matchedResponseEvent(e) = responseTable.ResponseEvent(r);
    matchedResponseTime_s(e) = responseTable.ResponseTime_s(r);
    delay_us(e) = 1e6*(matchedResponseTime_s(e)-commandTime_s(e));
    matchedGradient_mA_per_us(e) = responseTable.PeakGradient_mA_per_us(r);
    matchedPre_mA(e) = responseTable.PreLevel_mA(r);
    matchedPost_mA(e) = responseTable.PostLevel_mA(r);
    matchStatus(e) = "matched";
    lastUsedResponseRow = r;
end

% Warning only. This does not affect matching.
delayWarning_us = DELAY_WARNING_FACTOR*typicalCommandSpacing_s*1e6;
for e = 1:nCommands
    if matchStatus(e)=="matched" && delay_us(e)>delayWarning_us
        matchStatus(e) = "matched_but_delay_is_large";
    end
end

matchedMask = startsWith(matchStatus,"matched");
matchedTable = table(commandEvent,commandTime_s,commandCode,commandClass, ...
    matchedResponseEvent,matchedResponseTime_s,delay_us, ...
    matchedGradient_mA_per_us,matchedPre_mA,matchedPost_mA,matchStatus, ...
    'VariableNames',{'CommandEvent','CommandTime_s','TransitionCode', ...
    'CommandClass','ResponseEvent','ResponseTime_s','Delay_us', ...
    'PeakGradient_mA_per_us','PreLevel_mA','PostLevel_mA','MatchStatus'});

fprintf("\n============================================================\n");
fprintf("COMMAND -> CH3 MATCHING\n");
fprintf("============================================================\n");
fprintf("Matched commands: %d / %d\n",nnz(matchedMask),nCommands);

if any(matchedMask)
    fprintf("Delay mean   : %.6f us\n",mean(delay_us(matchedMask),'omitnan'));
    fprintf("Delay SD     : %.6f us\n",std(delay_us(matchedMask),'omitnan'));
    fprintf("Delay median : %.6f us\n",median(delay_us(matchedMask),'omitnan'));
    fprintf("Delay min    : %.6f us\n",min(delay_us(matchedMask)));
    fprintf("Delay max    : %.6f us\n",max(delay_us(matchedMask)));
end

%% ========================================================================
% PART G: SLOW WITHIN-PHASE DROOP BETWEEN MATCHED FAST EDGES
% ========================================================================

matchedCommandRows = find(matchedMask);
if numel(matchedCommandRows)<2
    error("Too few matched responses to classify physical phases.");
end

[sortedResponseTimes,order] = sort(matchedResponseTime_s(matchedMask));
sortedCommandRows = matchedCommandRows(order);
sortedClasses = commandClass(sortedCommandRows);

% Every response except the final one defines a destination phase that lasts
% until the next physical response.
nPhases = numel(sortedResponseTimes)-1;
phaseNumber = (1:nPhases).';
phaseSourceCommand = sortedClasses(1:end-1);
phaseState = strings(nPhases,1);
phaseStartResponseTime_s = sortedResponseTimes(1:end-1);
phaseEndResponseTime_s = sortedResponseTimes(2:end);
phaseAnalysisStart_s = NaN(nPhases,1);
phaseAnalysisEnd_s = NaN(nPhases,1);
phaseDuration_us = NaN(nPhases,1);
phaseEarlyLevel_mA = NaN(nPhases,1);
phaseLateLevel_mA = NaN(nPhases,1);
droopDelta_mA = NaN(nPhases,1);
droopMagnitude_mA = NaN(nPhases,1);
droopSlope_mA_per_ms = NaN(nPhases,1);
droopFitR2 = NaN(nPhases,1);

edgeExclude_s = PHASE_EDGE_EXCLUSION_US*1e-6;
levelWindow_s = PHASE_LEVEL_WINDOW_US*1e-6;

for p = 1:nPhases
    phaseState(p) = destinationState(phaseSourceCommand(p));

    a = phaseStartResponseTime_s(p)+edgeExclude_s;
    b = phaseEndResponseTime_s(p)-edgeExclude_s;
    phaseAnalysisStart_s(p) = a;
    phaseAnalysisEnd_s(p) = b;
    phaseDuration_us(p) = (b-a)*1e6;

    if b<=a
        continue;
    end

    mask = t>=a & t<=b;
    if nnz(mask)<20
        continue;
    end

    tt_ms = (t(mask)-a)*1e3;
    yy = currentSmooth_mA(mask);

    coeff = polyfit(tt_ms,yy,1);
    yhat = polyval(coeff,tt_ms);
    droopSlope_mA_per_ms(p) = coeff(1);

    denom = sum((yy-mean(yy)).^2);
    if denom>0
        droopFitR2(p) = 1-sum((yy-yhat).^2)/denom;
    end

    earlyEnd = min(a+levelWindow_s,b);
    lateStart = max(b-levelWindow_s,a);
    earlyMask = t>=a & t<=earlyEnd;
    lateMask = t>=lateStart & t<=b;

    phaseEarlyLevel_mA(p) = median(currentSmooth_mA(earlyMask),'omitnan');
    phaseLateLevel_mA(p) = median(currentSmooth_mA(lateMask),'omitnan');
    droopDelta_mA(p) = phaseLateLevel_mA(p)-phaseEarlyLevel_mA(p);
    droopMagnitude_mA(p) = abs(droopDelta_mA(p));
end

phaseTable = table(phaseNumber,phaseSourceCommand,phaseState, ...
    phaseStartResponseTime_s,phaseEndResponseTime_s,phaseAnalysisStart_s, ...
    phaseAnalysisEnd_s,phaseDuration_us,phaseEarlyLevel_mA,phaseLateLevel_mA, ...
    droopDelta_mA,droopMagnitude_mA,droopSlope_mA_per_ms,droopFitR2);

posPhase = phaseState=="POSITIVE";
negPhase = phaseState=="NEGATIVE";

fprintf("\n============================================================\n");
fprintf("SLOW WITHIN-PHASE DROOP\n");
fprintf("============================================================\n");

if any(posPhase)
    fprintf("Positive phases        : %d\n",nnz(posPhase));
    fprintf("Positive early mean    : %.6f mA\n",mean(phaseEarlyLevel_mA(posPhase),'omitnan'));
    fprintf("Positive late mean     : %.6f mA\n",mean(phaseLateLevel_mA(posPhase),'omitnan'));
    fprintf("Positive droop mean    : %.6f mA\n",mean(droopMagnitude_mA(posPhase),'omitnan'));
    fprintf("Positive slope mean    : %.6f mA/ms\n",mean(droopSlope_mA_per_ms(posPhase),'omitnan'));
end

if any(negPhase)
    fprintf("Negative phases        : %d\n",nnz(negPhase));
    fprintf("Negative early mean    : %.6f mA\n",mean(phaseEarlyLevel_mA(negPhase),'omitnan'));
    fprintf("Negative late mean     : %.6f mA\n",mean(phaseLateLevel_mA(negPhase),'omitnan'));
    fprintf("Negative droop mean    : %.6f mA\n",mean(droopMagnitude_mA(negPhase),'omitnan'));
    fprintf("Negative slope mean    : %.6f mA/ms\n",mean(droopSlope_mA_per_ms(negPhase),'omitnan'));
end

%% ========================================================================
% PART H: DERIVE FINAL STATE THRESHOLDS FROM MEASURED DROOP
% ========================================================================

positiveLate = phaseLateLevel_mA(posPhase & isfinite(phaseLateLevel_mA));
negativeLate = phaseLateLevel_mA(negPhase & isfinite(phaseLateLevel_mA));

if isempty(positiveLate) || isempty(negativeLate)
    error("Cannot derive droop-based thresholds because phase data are missing.");
end

positiveDroopFloor_mA = percentileLocal(positiveLate,POSITIVE_FLOOR_PERCENTILE);
negativeDroopCeiling_mA = percentileLocal(negativeLate,NEGATIVE_CEILING_PERCENTILE);

finalPositiveThreshold_mA = zeroLevel_mA + FINAL_THRESHOLD_MARGIN * ...
    (positiveDroopFloor_mA-zeroLevel_mA);
finalNegativeThreshold_mA = zeroLevel_mA + FINAL_THRESHOLD_MARGIN * ...
    (negativeDroopCeiling_mA-zeroLevel_mA);

fprintf("\n============================================================\n");
fprintf("DROOP-DERIVED FINAL CH3 THRESHOLDS\n");
fprintf("============================================================\n");
fprintf("Positive droop floor     : %.6f mA\n",positiveDroopFloor_mA);
fprintf("Negative droop ceiling   : %.6f mA\n",negativeDroopCeiling_mA);
fprintf("Threshold margin         : %.3f\n",FINAL_THRESHOLD_MARGIN);
fprintf("FINAL positive threshold : %.6f mA\n",finalPositiveThreshold_mA);
fprintf("FINAL negative threshold : %.6f mA\n",finalNegativeThreshold_mA);

% Final stable-state classification for verification only.
finalCH3State = zeros(size(currentSmooth_mA),'int8');
finalCH3State(currentSmooth_mA>=finalPositiveThreshold_mA) = 1;
finalCH3State(currentSmooth_mA<=finalNegativeThreshold_mA) = -1;

%% ========================================================================
% FIGURES
% ========================================================================

N = numel(t);
stride = max(1,ceil(N/MAX_PLOT_POINTS));
plotIdx = 1:stride:N;

% 1. Gradient-first detection
figure('Name','Gradient-first CH3 detection');
tl = tiledlayout(2,1);
title(tl,'CH3 gradient-first fast-transition detection');

nexttile;
plot(t(plotIdx)*1e3,currentRaw_mA(plotIdx),'LineWidth',0.7);
hold on;
plot(t(plotIdx)*1e3,currentSmooth_mA(plotIdx),'LineWidth',1.0);
for r = 1:height(responseTable)
    xline(responseTable.ResponseTime_s(r)*1e3,':');
end
grid on;
ylabel('Current (mA)');
title('Raw and smoothed CH3 with accepted fast edges');
legend('Raw','Smoothed','Location','best');
hold off;

nexttile;
plot(t(plotIdx)*1e3,gradient_mA_per_us(plotIdx),'LineWidth',0.8);
hold on;
yline( gradientThreshold_mA_per_us,'--');
yline(-gradientThreshold_mA_per_us,'--');
for r = 1:height(responseTable)
    plot(responseTable.ResponseTime_s(r)*1e3, ...
        responseTable.PeakGradient_mA_per_us(r),'o');
end
grid on;
xlabel('Time (ms)');
ylabel('dI/dt (mA/us)');
title('Smoothed CH3 gradient and automatic detection limit');
hold off;

% 2. Command-response matching
figure('Name','Causal command response matching');
plot(t(plotIdx)*1e3,currentRaw_mA(plotIdx),'LineWidth',0.8);
hold on;
yl = ylim;
for e = 1:nCommands
    xCmd = commandTime_s(e)*1e3;
    xline(xCmd,':');

    if matchedMask(e)
        xResp = matchedResponseTime_s(e)*1e3;
        pairY = yl(2)-(0.06+0.025*mod(e,5))*(yl(2)-yl(1));
        plot([xCmd xResp],[pairY pairY],'-','LineWidth',0.9);
        yResp = interp1(t,currentRaw_mA,matchedResponseTime_s(e));
        plot(xResp,yResp,'o','MarkerSize',4);

        if e<=4 || e>nCommands-3
            text(xCmd,pairY,sprintf(' %d %s',e,prettyTransition(commandClass(e))), ...
                'VerticalAlignment','bottom');
        end
    end
end
grid on;
xlabel('Time (ms)');
ylabel('Current (mA)');
title('Commands paired to first compatible future CH3 fast edge');
hold off;

% 3. Slow droop overlays
figure('Name','Measured slow droop');
tl = tiledlayout(2,1);
title(tl,'Slow within-phase current evolution');

nexttile;
hold on;
posRows = find(posPhase & isfinite(phaseAnalysisStart_s));
for jj = 1:numel(posRows)
    p = posRows(jj);
    mask = t>=phaseAnalysisStart_s(p) & t<=phaseAnalysisEnd_s(p);
    tt_ms = (t(mask)-phaseAnalysisStart_s(p))*1e3;
    plot(tt_ms,currentRaw_mA(mask),'LineWidth',0.5);
end
grid on;
ylabel('Current (mA)');
title('Positive physical phases');
hold off;

nexttile;
hold on;
negRows = find(negPhase & isfinite(phaseAnalysisStart_s));
for jj = 1:numel(negRows)
    p = negRows(jj);
    mask = t>=phaseAnalysisStart_s(p) & t<=phaseAnalysisEnd_s(p);
    tt_ms = (t(mask)-phaseAnalysisStart_s(p))*1e3;
    plot(tt_ms,currentRaw_mA(mask),'LineWidth',0.5);
end
grid on;
xlabel('Time since fast transition (ms)');
ylabel('Current (mA)');
title('Negative physical phases');
hold off;

% 4. Final thresholds
figure('Name','Droop-derived CH3 thresholds');
tl = tiledlayout(2,1);
title(tl,'Final CH3 state thresholds derived from measured droop');

nexttile;
plot(t(plotIdx)*1e3,currentRaw_mA(plotIdx),'LineWidth',0.7);
hold on;
yline(zeroLevel_mA,':','zero');
yline(finalPositiveThreshold_mA,'--','final + threshold');
yline(finalNegativeThreshold_mA,'--','final - threshold');
grid on;
ylabel('Current (mA)');
title('Measured CH3 current and final thresholds');
hold off;

nexttile;
stairs(t(plotIdx)*1e3,double(finalCH3State(plotIdx)),'LineWidth',1);
grid on;
ylim([-1.3 1.3]);
yticks([-1 0 1]);
yticklabels({'NEG','ZERO / TRANSITION','POS'});
xlabel('Time (ms)');
ylabel('CH3 state');
title('Final threshold-based CH3 state classification');

% 5. Delay by event
figure('Name','Measured command delay');
hold on;
classes = ["zero_to_pos","pos_to_neg","neg_to_pos","neg_to_zero"];
for c = 1:numel(classes)
    rows = matchedMask & commandClass==classes(c);
    if any(rows)
        scatter(find(rows),delay_us(rows),30,'filled', ...
            'DisplayName',prettyTransition(classes(c)));
    end
end
grid on;
xlabel('Command event number');
ylabel('Measured command-to-edge delay (us)');
title('Measured delay with no fixed delay assumption');
legend('Location','best');
hold off;

%% ========================================================================
% SAVE RESULTS
% ========================================================================

outFolder = fullfile(fileparts(csvPath),"GradientClassificationResults");
if ~isfolder(outFolder)
    mkdir(outFolder);
end

writetable(commandTable,fullfile(outFolder,"CommandEvents.csv"));
writetable(candidateTable,fullfile(outFolder,"AllGradientCandidates.csv"));
writetable(responseTable,fullfile(outFolder,"AcceptedCH3FastEdges.csv"));
writetable(matchedTable,fullfile(outFolder,"MatchedCommandResponses.csv"));
writetable(phaseTable,fullfile(outFolder,"SlowPhysicalPhases.csv"));

figs = findall(0,'Type','figure');
for k = 1:numel(figs)
    switch get(figs(k),'Name')
        case 'Gradient-first CH3 detection'
            saveas(figs(k),fullfile(outFolder,"01_GradientFirstDetection.png"));
        case 'Causal command response matching'
            saveas(figs(k),fullfile(outFolder,"02_CommandResponseMatching.png"));
        case 'Measured slow droop'
            saveas(figs(k),fullfile(outFolder,"03_MeasuredSlowDroop.png"));
        case 'Droop-derived CH3 thresholds'
            saveas(figs(k),fullfile(outFolder,"04_DroopDerivedThresholds.png"));
        case 'Measured command delay'
            saveas(figs(k),fullfile(outFolder,"05_MeasuredDelay.png"));
    end
end

results = struct();
results.csvPath = csvPath;
results.header = header;
results.Ts = Ts;
results.Fs = Fs;
results.zeroLevel_mA = zeroLevel_mA;
results.zeroNoiseSD_mA = zeroNoiseSD_mA;
results.gradientThreshold_mA_per_us = gradientThreshold_mA_per_us;
results.broadZeroTolerance_mA = broadZeroTolerance_mA;
results.positiveDroopFloor_mA = positiveDroopFloor_mA;
results.negativeDroopCeiling_mA = negativeDroopCeiling_mA;
results.finalPositiveThreshold_mA = finalPositiveThreshold_mA;
results.finalNegativeThreshold_mA = finalNegativeThreshold_mA;
results.commandTable = commandTable;
results.candidateTable = candidateTable;
results.responseTable = responseTable;
results.matchedTable = matchedTable;
results.phaseTable = phaseTable;
results.cleanCommandCode = cleanCode;
results.finalCH3State = finalCH3State;

save(fullfile(outFolder,"GradientClassificationResults.mat"),"results");

fprintf("\n============================================================\n");
fprintf("STEP 2 COMPLETE\n");
fprintf("============================================================\n");
fprintf("Results saved to:\n%s\n",outFolder);
fprintf("\nNo normalization has been performed.\n");
fprintf("No transfer function has been fitted.\n");
fprintf("\nVerify the five figures before proceeding.\n");

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function [data,t,t0,Ts,header] = loadRigolMemoryCSV(path)
    fid = fopen(path,'r');
    if fid<0
        error("Could not open CSV.");
    end
    header = fgetl(fid);
    fclose(fid);

    tok = regexp(header,'t0\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');
    if isempty(tok)
        error("Could not parse t0.");
    end
    t0 = str2double(tok{1});

    tok = regexp(header,'tInc\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');
    if isempty(tok)
        error("Could not parse tInc.");
    end
    Ts = str2double(tok{1});

    data = readmatrix(path,'NumHeaderLines',1);
    data(:,all(~isfinite(data),1)) = [];
    data = data(any(isfinite(data),2),:);
    t = t0+(0:size(data,1)-1).'*Ts;
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

function label = transitionCodeLabel(code)
    switch double(code)
        case 0
            label = "neg_to_zero";
        case 1
            label = "zero_to_pos";
        case 2
            label = "neg_to_pos";
        case 3
            label = "pos_to_neg";
        otherwise
            label = "unexpected";
    end
end

function label = broadStateLabel(value,zeroLevel,zeroTolerance)
    if value>zeroLevel+zeroTolerance
        label = "POSITIVE";
    elseif value<zeroLevel-zeroTolerance
        label = "NEGATIVE";
    else
        label = "ZERO";
    end
end

function label = physicalTransitionFromLabels(preState,postState)
    if preState=="ZERO" && postState=="POSITIVE"
        label = "zero_to_pos";
    elseif preState=="POSITIVE" && postState=="NEGATIVE"
        label = "pos_to_neg";
    elseif preState=="NEGATIVE" && postState=="POSITIVE"
        label = "neg_to_pos";
    elseif preState=="NEGATIVE" && postState=="ZERO"
        label = "neg_to_zero";
    else
        label = "unexpected";
    end
end

function d = transitionDirection(type)
    switch type
        case "zero_to_pos"
            d = 1;
        case "pos_to_neg"
            d = -1;
        case "neg_to_pos"
            d = 1;
        case "neg_to_zero"
            d = 1;
        otherwise
            d = 0;
    end
end

function state = destinationState(type)
    switch type
        case {"zero_to_pos","neg_to_pos"}
            state = "POSITIVE";
        case "pos_to_neg"
            state = "NEGATIVE";
        case "neg_to_zero"
            state = "ZERO";
        otherwise
            state = "UNKNOWN";
    end
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

function cleaned = removeShortRuns(code,minSamples)
    cleaned = code(:);
    for iter = 1:30
        [starts,ends,codes] = runsFromCode(cleaned);
        lengths = ends-starts+1;
        shortRuns = find(lengths<minSamples);
        shortRuns(shortRuns==1 | shortRuns==numel(codes)) = [];
        if isempty(shortRuns)
            break;
        end
        for jj = 1:numel(shortRuns)
            r = shortRuns(jj);
            cleaned(starts(r):ends(r)) = codes(r-1);
        end
    end
end

function [starts,ends,codes] = runsFromCode(code)
    code = code(:);
    change = [true;diff(double(code))~=0;true];
    edges = find(change);
    starts = edges(1:end-1);
    ends = edges(2:end)-1;
    codes = code(starts);
end

function [starts,ends] = trueRuns(mask)
    mask = logical(mask(:));
    d = diff([false;mask;false]);
    starts = find(d==1);
    ends = find(d==-1)-1;
end

function idxOut = mergeCloseEdgeCandidates(idxIn,gradientSignal,minSeparation)
    if isempty(idxIn)
        idxOut = idxIn;
        return;
    end

    idxIn = sort(idxIn(:));
    idxOut = zeros(0,1);
    group = idxIn(1);

    for k = 2:numel(idxIn)
        if idxIn(k)-group(end)<=minSeparation
            group(end+1,1) = idxIn(k); %#ok<AGROW>
        else
            [~,loc] = max(abs(gradientSignal(group)));
            idxOut(end+1,1) = group(loc); %#ok<AGROW>
            group = idxIn(k);
        end
    end

    [~,loc] = max(abs(gradientSignal(group)));
    idxOut(end+1,1) = group(loc);
end

function sigma = robustSigma(x)
    x = x(isfinite(x));
    if isempty(x)
        sigma = NaN;
        return;
    end
    med = median(x);
    sigma = 1.4826*median(abs(x-med));
    if sigma==0 || ~isfinite(sigma)
        sigma = std(x);
    end
    if sigma==0 || ~isfinite(sigma)
        sigma = eps;
    end
end

function q = percentileLocal(x,p)
    x = sort(x(isfinite(x)));
    if isempty(x)
        q = NaN;
        return;
    end
    if isscalar(x)
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
