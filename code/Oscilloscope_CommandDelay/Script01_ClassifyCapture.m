%% OpenXstim_CommandAwareGradientClassifier.m
% OPENXSTIM COMMAND-AWARE GRADIENT CLASSIFIER
%
% Purpose
% -------
% This script is the "candidate generator + strong validation" version of
% the analysis.
%
% It deliberately does NOT normalize responses and does NOT fit a transfer
% function yet.
%
% Processing logic
% ----------------
%
%   D5 / D8
%      |
%      v
%   decode command events
%
%   CH3
%      |
%      v
%   smooth -> dI/dt
%      |
%      v
%   SENSITIVE gradient candidate generator
%      |
%      +--> may deliberately include extra candidates
%      |
%      v
%   strong validation using:
%      - robust current level BEFORE candidate
%      - robust current level AFTER candidate
%      - actual current change
%      - gradient direction
%      - recognised physical transition type
%      - compatible earlier command
%
%      |
%      v
%   accepted physical response
%
% After command/response matching:
%
%   matched fast edge
%      |
%      v
%   physical positive / negative phase
%      |
%      v
%   early level + late level + slope + magnitude droop
%
% Only AFTER measuring droop are final +/- state thresholds derived.
%
% Channels
% --------
%   CH1 = D5
%   CH2 = D8
%   CH3 = output voltage across 1 kOhm
%
% Current CSV enc_6_2.csv:
%   use COMMAND_ENCODING_MODE = "legacy_state_pair"
%
% Future captures using:
%   TRANS_NEG_TO_ZERO = 0
%   TRANS_ZERO_TO_POS = 1
%   TRANS_NEG_TO_POS  = 2
%   TRANS_POS_TO_NEG  = 3
%
%   use COMMAND_ENCODING_MODE = "transition_code"

clear;
clc;
close all;

%% ========================================================================
% USER SETTINGS
% ========================================================================

% Change only this block when processing a different capture.
PROJECT_FOLDER = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.
CSV_FILE = fullfile(PROJECT_FOLDER,"enc_6_2.csv");
STAGE1_OUTPUT_FOLDER = fullfile(PROJECT_FOLDER,"Stage1_Classification");

FIGURE_WINDOW_STYLE = "normal";
FIGURE_VISIBLE = "off";
SAVE_EDITABLE_FIGURES = false;
FIGURE_RESOLUTION_DPI = 180;

EXPECTED_PULSE_COUNT = 20;

% For enc_6_2.csv:
COMMAND_ENCODING_MODE = "legacy_state_pair";

% For new data using the final TRANS_* firmware:
% COMMAND_ENCODING_MODE = "transition_code";

% Channel assignment
D5_CHANNEL = 1;
D8_CHANNEL = 2;
OUTPUT_CHANNEL = 3;

R_LOAD_OHM = 1000;

% Debug thresholds. NaN = automatic robust midpoint.
D5_THRESHOLD_V = NaN;
D8_THRESHOLD_V = NaN;

MIN_DEBUG_DWELL_US = 5;

% -------------------------------------------------------------------------
% CH3 SMOOTHING
% -------------------------------------------------------------------------

% Used only for edge detection / derivative estimation.
% Raw data is retained for actual reported levels.
OUTPUT_SMOOTH_US = 0.50;

% -------------------------------------------------------------------------
% SENSITIVE GRADIENT CANDIDATE GENERATOR
% -------------------------------------------------------------------------

% For THIS capture I recommend starting with 0.30 mA/us.
%
% Set to NaN if you want the script to calculate an automatic threshold.
MANUAL_GRADIENT_THRESHOLD_mA_per_us = 0.30;

% Automatic mode settings, only used if manual threshold = NaN.
GRADIENT_NOISE_SIGMA_MULTIPLIER = 8;

% Expected fast edge is only used to scale an automatic candidate
% threshold. This is NOT the firmware delay.
EXPECTED_FAST_EDGE_US = 5;

% Automatic candidate threshold is approximately this fraction of the
% expected half-step average gradient.
AUTO_EDGE_GRADIENT_FRACTION = 0.50;

% Candidate peaks closer than this are treated as one edge.
MIN_EDGE_SEPARATION_US = 40;

% -------------------------------------------------------------------------
% STRONG CANDIDATE VALIDATION
% -------------------------------------------------------------------------

% Robust levels are measured well away from the few-us fast edge.
EDGE_LEVEL_GUARD_US = 30;
EDGE_LEVEL_WINDOW_US = 100;

% Broad ZERO region used only to classify a candidate as:
% ZERO, POSITIVE, or NEGATIVE.
%
% This is NOT the final state threshold.
BROAD_ZERO_NOISE_SIGMAS = 8;
BROAD_ZERO_FRACTION_OF_HALF_EXCURSION = 0.12;

% Candidate must cause a real current change.
%
% The threshold is based on the measured one-sided output excursion, so
% 0 -> +I and -I -> 0 are not penalised for being approximately half the
% magnitude of +/- reversals.
MIN_REAL_CHANGE_FRACTION_OF_HALF_STEP = 0.25;

% -------------------------------------------------------------------------
% COMMAND / RESPONSE MATCHING
% -------------------------------------------------------------------------

% Matching does NOT assume a 1 ms delay.
%
% This factor is only used to flag a suspicious result after matching.
DELAY_WARNING_FACTOR = 2.0;

% -------------------------------------------------------------------------
% PASSIVE DROOP ANALYSIS
% -------------------------------------------------------------------------

% Remove the fast-edge neighbourhood from the slow-phase analysis.
PHASE_EDGE_EXCLUSION_US = 40;

% Robust early/late windows within every physical phase.
PHASE_LEVEL_WINDOW_US = 100;

% Threshold from late-phase drooped values:
%
% if weakest positive phase ~= +2.0 mA and margin = 0.75,
% final positive state threshold ~= +1.5 mA.
FINAL_THRESHOLD_MARGIN = 0.75;

POSITIVE_FLOOR_PERCENTILE = 5;
NEGATIVE_CEILING_PERCENTILE = 95;

MAX_PLOT_POINTS = 60000;

%% ========================================================================
% IMPORT
% ========================================================================

csvPath = CSV_FILE;
verifyHardcodedInputs(csvPath,"Stage 1 CSV",PROJECT_FOLDER);

[data,t,t0,Ts,header] = loadRigolMemoryCSV(csvPath);

Fs = 1/Ts;

if size(data,2) < max([D5_CHANNEL,D8_CHANNEL,OUTPUT_CHANNEL])
    error("CSV does not contain all requested channels.");
end

d5V = data(:,D5_CHANNEL);
d8V = data(:,D8_CHANNEL);
outputV = data(:,OUTPUT_CHANNEL);

% 1 V across 1 kOhm = 1 mA.
currentRaw_mA = 1000*outputV/R_LOAD_OHM;

fprintf("\n============================================================\n");
fprintf("OPENXSTIM COMMAND-AWARE GRADIENT CLASSIFIER\n");
fprintf("============================================================\n");
fprintf("File      : %s\n",csvPath);
fprintf("Rows      : %d\n",size(data,1));
fprintf("Fs        : %.6f MSa/s\n",Fs/1e6);
fprintf("Ts        : %.3f ns\n",Ts*1e9);
fprintf("Capture   : %.3f ms\n",(t(end)-t(1))*1e3);
fprintf("Cmd mode  : %s\n",COMMAND_ENCODING_MODE);

%% ========================================================================
% PART A: COMMAND DETECTION FROM D5 / D8
% ========================================================================

[d5Bit,d5Threshold] = thresholdBit(d5V,D5_THRESHOLD_V);
[d8Bit,d8Threshold] = thresholdBit(d8V,D8_THRESHOLD_V);

rawCode = uint8(2*d8Bit+d5Bit);

minDebugSamples = max(2,round(MIN_DEBUG_DWELL_US*1e-6/Ts));

cleanCode = removeShortRuns(rawCode,minDebugSamples);

[cmdRunStart,~,cmdRunCode] = runsFromCode(cleanCode);

commandIdx = cmdRunStart(2:end);
commandTime_s = t(commandIdx);

fromCode = double(cmdRunCode(1:end-1));
toCode = double(cmdRunCode(2:end));

nCommands = numel(commandIdx);

commandClass = strings(nCommands,1);
commandContext = strings(nCommands,1);

for e = 1:nCommands

    if COMMAND_ENCODING_MODE=="legacy_state_pair"

        [commandClass(e),commandContext(e)] = ...
            classifyLegacyCodePair(fromCode(e),toCode(e));

    elseif COMMAND_ENCODING_MODE=="transition_code"

        commandClass(e) = transitionCodeLabel(toCode(e));
        commandContext(e) = sprintf("new_code_%d",toCode(e));

    else

        error("Unknown COMMAND_ENCODING_MODE.");
    end
end

commandEvent = (1:nCommands).';

commandTable = table( ...
    commandEvent,commandTime_s,fromCode,toCode, ...
    commandClass,commandContext, ...
    'VariableNames',{ ...
    'CommandEvent','CommandTime_s','FromCode','ToCode', ...
    'CommandClass','Context'});

expectedTotalCommands = 2*EXPECTED_PULSE_COUNT+1;

fprintf("\n============================================================\n");
fprintf("COMMAND DETECTION\n");
fprintf("============================================================\n");

fprintf("D5 threshold : %.6f V\n",d5Threshold);
fprintf("D8 threshold : %.6f V\n",d8Threshold);

fprintf("\nExpected total : %d\n",expectedTotalCommands);
fprintf("Detected total : %d\n",nCommands);

fprintf("0 -> +I        : %d\n",nnz(commandClass=="zero_to_pos"));
fprintf("+I -> -I       : %d\n",nnz(commandClass=="pos_to_neg"));
fprintf("-I -> +I       : %d\n",nnz(commandClass=="neg_to_pos"));
fprintf("-I -> 0        : %d\n",nnz(commandClass=="neg_to_zero"));
fprintf("Unexpected     : %d\n",nnz(commandClass=="unexpected"));

commandPass = ...
    nCommands==expectedTotalCommands && ...
    nnz(commandClass=="zero_to_pos")==1 && ...
    nnz(commandClass=="pos_to_neg")==EXPECTED_PULSE_COUNT && ...
    nnz(commandClass=="neg_to_pos")==EXPECTED_PULSE_COUNT-1 && ...
    nnz(commandClass=="neg_to_zero")==1 && ...
    nnz(commandClass=="unexpected")==0;

if commandPass
    fprintf("COMMAND RESULT  : PASS\n");
else
    fprintf("COMMAND RESULT  : CHECK REQUIRED\n");
end

%% ========================================================================
% PART B: ZERO LEVEL AND ROBUST OUTPUT SCALE
% ========================================================================

if nCommands>=2
    typicalCommandSpacing_s = median(diff(commandTime_s),'omitnan');
else
    typicalCommandSpacing_s = 1e-3;
end

preBurstEnd_s = ...
    commandTime_s(1)-0.25*typicalCommandSpacing_s;

zeroMask = t<preBurstEnd_s;

if nnz(zeroMask)<100

    nZero = max(100,round(0.05*numel(t)));

    zeroMask = false(size(t));
    zeroMask(1:nZero) = true;
end

zeroLevel_mA = ...
    median(currentRaw_mA(zeroMask),'omitnan');

zeroNoiseSD_mA = ...
    robustSigma(currentRaw_mA(zeroMask));

positiveRobust_mA = ...
    percentileLocal(currentRaw_mA,95);

negativeRobust_mA = ...
    percentileLocal(currentRaw_mA,5);

positiveHalfExcursion_mA = ...
    positiveRobust_mA-zeroLevel_mA;

negativeHalfExcursion_mA = ...
    zeroLevel_mA-negativeRobust_mA;

halfStepScale_mA = ...
    min(positiveHalfExcursion_mA,negativeHalfExcursion_mA);

if halfStepScale_mA<=0
    error("Could not determine bipolar CH3 excursion.");
end

fprintf("\n============================================================\n");
fprintf("CH3 BASIC LEVELS\n");
fprintf("============================================================\n");

fprintf("Zero level             : %.6f mA\n",zeroLevel_mA);
fprintf("Zero robust noise SD   : %.6f mA\n",zeroNoiseSD_mA);
fprintf("Robust positive level  : %.6f mA\n",positiveRobust_mA);
fprintf("Robust negative level  : %.6f mA\n",negativeRobust_mA);
fprintf("One-sided step scale   : %.6f mA\n",halfStepScale_mA);

%% ========================================================================
% PART C: SMOOTH CH3 AND CALCULATE dI/dt
% ========================================================================

smoothSamples = ...
    max(3,round(OUTPUT_SMOOTH_US*1e-6/Ts));

if mod(smoothSamples,2)==0
    smoothSamples = smoothSamples+1;
end

currentSmooth_mA = ...
    movmean(currentRaw_mA,smoothSamples);

gradient_mA_per_us = ...
    gradient(currentSmooth_mA,Ts)/1e6;

gradientNoiseSD = ...
    robustSigma(gradient_mA_per_us(zeroMask));

% Automatic candidate threshold based on:
% 1. derivative noise
% 2. expected average gradient of the one-sided step
noiseGradientThreshold = ...
    GRADIENT_NOISE_SIGMA_MULTIPLIER*gradientNoiseSD;

expectedHalfStepAverageGradient = ...
    halfStepScale_mA/EXPECTED_FAST_EDGE_US;

scaledGradientThreshold = ...
    AUTO_EDGE_GRADIENT_FRACTION* ...
    expectedHalfStepAverageGradient;

autoGradientThreshold = ...
    max(noiseGradientThreshold,scaledGradientThreshold);

if isnan(MANUAL_GRADIENT_THRESHOLD_mA_per_us)

    gradientThreshold = autoGradientThreshold;
    gradientThresholdMode = "automatic";

else

    gradientThreshold = MANUAL_GRADIENT_THRESHOLD_mA_per_us;
    gradientThresholdMode = "manual";
end

fprintf("\n============================================================\n");
fprintf("SENSITIVE GRADIENT CANDIDATE GENERATOR\n");
fprintf("============================================================\n");

fprintf("Smoothing window          : %.3f us\n",OUTPUT_SMOOTH_US);
fprintf("Gradient noise SD         : %.6f mA/us\n",gradientNoiseSD);
fprintf("Noise-based threshold     : %.6f mA/us\n",noiseGradientThreshold);
fprintf("Scaled half-step threshold: %.6f mA/us\n",scaledGradientThreshold);
fprintf("Auto threshold            : %.6f mA/us\n",autoGradientThreshold);
fprintf("Threshold mode            : %s\n",gradientThresholdMode);
fprintf("USED candidate threshold  : %.6f mA/us\n",gradientThreshold);

%% ========================================================================
% PART D: GENERATE MANY FAST-EDGE CANDIDATES
% ========================================================================

gradientCandidateMask = ...
    abs(gradient_mA_per_us)>=gradientThreshold;

[gradStart,gradEnd] = ...
    trueRuns(gradientCandidateMask);

candidateIdx = ...
    zeros(numel(gradStart),1);

for k = 1:numel(gradStart)

    region = gradStart(k):gradEnd(k);

    [~,loc] = ...
        max(abs(gradient_mA_per_us(region)));

    candidateIdx(k) = region(loc);
end

minEdgeSepSamples = ...
    max(1,round(MIN_EDGE_SEPARATION_US*1e-6/Ts));

candidateIdx = ...
    mergeCloseEdgeCandidates( ...
    candidateIdx, ...
    gradient_mA_per_us, ...
    minEdgeSepSamples);

nCandidates = numel(candidateIdx);

fprintf("Candidate peaks generated : %d\n",nCandidates);

%% ========================================================================
% PART E: STRONGLY VALIDATE EACH CANDIDATE
% ========================================================================

guardSamples = ...
    max(1,round(EDGE_LEVEL_GUARD_US*1e-6/Ts));

levelWindowSamples = ...
    max(2,round(EDGE_LEVEL_WINDOW_US*1e-6/Ts));

broadZeroTolerance_mA = max( ...
    BROAD_ZERO_NOISE_SIGMAS*zeroNoiseSD_mA, ...
    BROAD_ZERO_FRACTION_OF_HALF_EXCURSION*halfStepScale_mA);

minimumRealChange_mA = ...
    MIN_REAL_CHANGE_FRACTION_OF_HALF_STEP*halfStepScale_mA;

candidateNumber = (1:nCandidates).';
candidateTime_s = t(candidateIdx);
candidateGradient = gradient_mA_per_us(candidateIdx);

candidatePre_mA = NaN(nCandidates,1);
candidatePost_mA = NaN(nCandidates,1);
candidateDelta_mA = NaN(nCandidates,1);

candidatePreState = strings(nCandidates,1);
candidatePostState = strings(nCandidates,1);
candidateClass = strings(nCandidates,1);

candidatePassLevelChange = false(nCandidates,1);
candidatePassStatePair = false(nCandidates,1);
candidatePassDirection = false(nCandidates,1);

candidateAcceptedPhysics = false(nCandidates,1);
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

    candidatePre_mA(k) = ...
        median(currentRaw_mA(preStart:preEnd),'omitnan');

    candidatePost_mA(k) = ...
        median(currentRaw_mA(postStart:postEnd),'omitnan');

    candidateDelta_mA(k) = ...
        candidatePost_mA(k)-candidatePre_mA(k);

    candidatePreState(k) = ...
        broadStateLabel( ...
        candidatePre_mA(k), ...
        zeroLevel_mA, ...
        broadZeroTolerance_mA);

    candidatePostState(k) = ...
        broadStateLabel( ...
        candidatePost_mA(k), ...
        zeroLevel_mA, ...
        broadZeroTolerance_mA);

    candidateClass(k) = ...
        physicalTransitionFromLabels( ...
        candidatePreState(k), ...
        candidatePostState(k));

    candidatePassLevelChange(k) = ...
        abs(candidateDelta_mA(k))>=minimumRealChange_mA;

    candidatePassStatePair(k) = ...
        candidateClass(k)~="unexpected";

    if candidatePassStatePair(k)

        expectedDirection = ...
            transitionDirection(candidateClass(k));

        candidatePassDirection(k) = ...
            sign(candidateGradient(k))==expectedDirection;
    end

    candidateAcceptedPhysics(k) = ...
        candidatePassLevelChange(k) && ...
        candidatePassStatePair(k) && ...
        candidatePassDirection(k);

    if ~candidatePassLevelChange(k)

        candidateReason(k) = "reject_small_current_change";

    elseif ~candidatePassStatePair(k)

        candidateReason(k) = "reject_unknown_pre_post_states";

    elseif ~candidatePassDirection(k)

        candidateReason(k) = "reject_wrong_gradient_direction";

    else

        candidateReason(k) = "physics_pass";
    end
end

candidateTable = table( ...
    candidateNumber, ...
    candidateTime_s, ...
    candidateGradient, ...
    candidatePre_mA, ...
    candidatePost_mA, ...
    candidateDelta_mA, ...
    candidatePreState, ...
    candidatePostState, ...
    candidateClass, ...
    candidatePassLevelChange, ...
    candidatePassStatePair, ...
    candidatePassDirection, ...
    candidateAcceptedPhysics, ...
    candidateReason, ...
    'VariableNames',{ ...
    'Candidate', ...
    'Time_s', ...
    'Gradient_mA_per_us', ...
    'PreLevel_mA', ...
    'PostLevel_mA', ...
    'Delta_mA', ...
    'PreState', ...
    'PostState', ...
    'PhysicalClass', ...
    'PassLevelChange', ...
    'PassStatePair', ...
    'PassDirection', ...
    'PhysicsPass', ...
    'Reason'});

physicsRows = find(candidateAcceptedPhysics);

fprintf("\n============================================================\n");
fprintf("PHYSICS VALIDATION OF GRADIENT CANDIDATES\n");
fprintf("============================================================\n");

fprintf("Broad ZERO tolerance    : +/- %.6f mA\n",broadZeroTolerance_mA);
fprintf("Minimum real edge change: %.6f mA\n",minimumRealChange_mA);

fprintf("Candidate peaks         : %d\n",nCandidates);
fprintf("Physics-valid candidates: %d\n",numel(physicsRows));

fprintf("Physics-valid 0 -> +I   : %d\n", ...
    nnz(candidateClass(physicsRows)=="zero_to_pos"));

fprintf("Physics-valid +I -> -I  : %d\n", ...
    nnz(candidateClass(physicsRows)=="pos_to_neg"));

fprintf("Physics-valid -I -> +I  : %d\n", ...
    nnz(candidateClass(physicsRows)=="neg_to_pos"));

fprintf("Physics-valid -I -> 0   : %d\n", ...
    nnz(candidateClass(physicsRows)=="neg_to_zero"));

%% ========================================================================
% PART F: COMMAND-AWARE CAUSAL MATCHING
% ========================================================================

% A candidate is not accepted as the final response merely because it
% passed the physics checks.
%
% For every command:
%   - search ONLY forward in time
%   - candidate must pass physics checks
%   - candidate physical transition must equal command transition
%   - candidate must not already be used
%
% No expected delay is supplied to the matching algorithm.

matchedCandidate = NaN(nCommands,1);
matchedResponseTime_s = NaN(nCommands,1);
delay_us = NaN(nCommands,1);

matchedPre_mA = NaN(nCommands,1);
matchedPost_mA = NaN(nCommands,1);
matchedGradient = NaN(nCommands,1);

matchStatus = strings(nCommands,1);

usedCandidate = false(nCandidates,1);

lastMatchedCandidateTime = -Inf;

for e = 1:nCommands

    compatible = find( ...
        candidateAcceptedPhysics & ...
        ~usedCandidate & ...
        candidateTime_s>=commandTime_s(e) & ...
        candidateTime_s>=lastMatchedCandidateTime & ...
        candidateClass==commandClass(e));

    if isempty(compatible)

        matchStatus(e) = "no_compatible_future_candidate";
        continue;
    end

    % First physically compatible FUTURE candidate.
    k = compatible(1);

    matchedCandidate(e) = k;
    matchedResponseTime_s(e) = candidateTime_s(k);

    delay_us(e) = ...
        1e6*(matchedResponseTime_s(e)-commandTime_s(e));

    matchedPre_mA(e) = candidatePre_mA(k);
    matchedPost_mA(e) = candidatePost_mA(k);
    matchedGradient(e) = candidateGradient(k);

    matchStatus(e) = "matched";

    usedCandidate(k) = true;

    lastMatchedCandidateTime = candidateTime_s(k);
end

matchedMask = matchStatus=="matched";

delayWarning_us = ...
    DELAY_WARNING_FACTOR*typicalCommandSpacing_s*1e6;

for e = 1:nCommands

    if matchedMask(e) && delay_us(e)>delayWarning_us
        matchStatus(e) = "matched_but_delay_large";
    end
end

matchedMask = startsWith(matchStatus,"matched");

matchedTable = table( ...
    commandEvent, ...
    commandTime_s, ...
    fromCode, ...
    toCode, ...
    commandClass, ...
    matchedCandidate, ...
    matchedResponseTime_s, ...
    delay_us, ...
    matchedGradient, ...
    matchedPre_mA, ...
    matchedPost_mA, ...
    matchStatus, ...
    'VariableNames',{ ...
    'CommandEvent', ...
    'CommandTime_s', ...
    'FromCode', ...
    'ToCode', ...
    'CommandClass', ...
    'MatchedCandidate', ...
    'ResponseTime_s', ...
    'Delay_us', ...
    'PeakGradient_mA_per_us', ...
    'PreLevel_mA', ...
    'PostLevel_mA', ...
    'MatchStatus'});

fprintf("\n============================================================\n");
fprintf("COMMAND-AWARE MATCHING\n");
fprintf("============================================================\n");

fprintf("Matched commands: %d / %d\n", ...
    nnz(matchedMask),nCommands);

if any(matchedMask)

    fprintf("Delay mean   : %.6f us\n", ...
        mean(delay_us(matchedMask),'omitnan'));

    fprintf("Delay SD     : %.6f us\n", ...
        std(delay_us(matchedMask),'omitnan'));

    fprintf("Delay median : %.6f us\n", ...
        median(delay_us(matchedMask),'omitnan'));

    fprintf("Delay min    : %.6f us\n", ...
        min(delay_us(matchedMask)));

    fprintf("Delay max    : %.6f us\n", ...
        max(delay_us(matchedMask)));
end

fprintf("\nMatched event counts:\n");

fprintf("0 -> +I  : %d\n", ...
    nnz(commandClass(matchedMask)=="zero_to_pos"));

fprintf("+I -> -I : %d\n", ...
    nnz(commandClass(matchedMask)=="pos_to_neg"));

fprintf("-I -> +I : %d\n", ...
    nnz(commandClass(matchedMask)=="neg_to_pos"));

fprintf("-I -> 0  : %d\n", ...
    nnz(commandClass(matchedMask)=="neg_to_zero"));

%% ========================================================================
% PART G: BUILD PHYSICAL PHASES BETWEEN MATCHED RESPONSES
% ========================================================================

matchedCommandRows = find(matchedMask);

if numel(matchedCommandRows)<2
    error("Too few matched events to build physical phases.");
end

[sortedResponseTimes,sortOrder] = ...
    sort(matchedResponseTime_s(matchedMask));

sortedCommandRows = ...
    matchedCommandRows(sortOrder);

sortedCommandClasses = ...
    commandClass(sortedCommandRows);

nPhases = numel(sortedResponseTimes)-1;

phaseNumber = (1:nPhases).';

phaseState = strings(nPhases,1);
phaseSourceTransition = strings(nPhases,1);

phaseFastStart_s = sortedResponseTimes(1:end-1);
phaseFastEnd_s = sortedResponseTimes(2:end);

phaseAnalysisStart_s = NaN(nPhases,1);
phaseAnalysisEnd_s = NaN(nPhases,1);
phaseDuration_us = NaN(nPhases,1);

earlyCurrent_mA = NaN(nPhases,1);
lateCurrent_mA = NaN(nPhases,1);

signedCurrentChange_mA = NaN(nPhases,1);

% Positive means magnitude decreased toward zero.
magnitudeDroop_mA = NaN(nPhases,1);

signedSlope_mA_per_ms = NaN(nPhases,1);

% Slope of |I|. Negative means current magnitude decreased.
magnitudeSlope_mA_per_ms = NaN(nPhases,1);

fitR2 = NaN(nPhases,1);

edgeExclude_s = ...
    PHASE_EDGE_EXCLUSION_US*1e-6;

levelWindow_s = ...
    PHASE_LEVEL_WINDOW_US*1e-6;

for p = 1:nPhases

    phaseSourceTransition(p) = ...
        sortedCommandClasses(p);

    phaseState(p) = ...
        destinationState(sortedCommandClasses(p));

    a = phaseFastStart_s(p)+edgeExclude_s;
    b = phaseFastEnd_s(p)-edgeExclude_s;

    phaseAnalysisStart_s(p) = a;
    phaseAnalysisEnd_s(p) = b;

    phaseDuration_us(p) = (b-a)*1e6;

    if b<=a
        continue;
    end

    phaseMask = t>=a & t<=b;

    if nnz(phaseMask)<20
        continue;
    end

    tt_ms = ...
        (t(phaseMask)-a)*1e3;

    yy = ...
        currentSmooth_mA(phaseMask);

    coeffSigned = ...
        polyfit(tt_ms,yy,1);

    signedSlope_mA_per_ms(p) = ...
        coeffSigned(1);

    coeffMagnitude = ...
        polyfit(tt_ms,abs(yy),1);

    magnitudeSlope_mA_per_ms(p) = ...
        coeffMagnitude(1);

    yhat = polyval(coeffSigned,tt_ms);

    denom = sum((yy-mean(yy)).^2);

    if denom>0

        fitR2(p) = ...
            1-sum((yy-yhat).^2)/denom;
    end

    earlyEnd = min(a+levelWindow_s,b);
    lateStart = max(b-levelWindow_s,a);

    earlyMask = t>=a & t<=earlyEnd;
    lateMask = t>=lateStart & t<=b;

    earlyCurrent_mA(p) = ...
        median(currentRaw_mA(earlyMask),'omitnan');

    lateCurrent_mA(p) = ...
        median(currentRaw_mA(lateMask),'omitnan');

    signedCurrentChange_mA(p) = ...
        lateCurrent_mA(p)-earlyCurrent_mA(p);

    magnitudeDroop_mA(p) = ...
        abs(earlyCurrent_mA(p))-abs(lateCurrent_mA(p));
end

phaseTable = table( ...
    phaseNumber, ...
    phaseSourceTransition, ...
    phaseState, ...
    phaseFastStart_s, ...
    phaseFastEnd_s, ...
    phaseAnalysisStart_s, ...
    phaseAnalysisEnd_s, ...
    phaseDuration_us, ...
    earlyCurrent_mA, ...
    lateCurrent_mA, ...
    signedCurrentChange_mA, ...
    magnitudeDroop_mA, ...
    signedSlope_mA_per_ms, ...
    magnitudeSlope_mA_per_ms, ...
    fitR2);

positivePhaseMask = ...
    phaseState=="POSITIVE";

negativePhaseMask = ...
    phaseState=="NEGATIVE";

fprintf("\n============================================================\n");
fprintf("PASSIVE DROOP ANALYSIS\n");
fprintf("============================================================\n");

fprintf("Positive phases: %d\n",nnz(positivePhaseMask));
fprintf("Negative phases: %d\n",nnz(negativePhaseMask));

if any(positivePhaseMask)

    fprintf("\nPOSITIVE PHASES\n");

    fprintf("Early mean           : %.6f mA\n", ...
        mean(earlyCurrent_mA(positivePhaseMask),'omitnan'));

    fprintf("Late mean            : %.6f mA\n", ...
        mean(lateCurrent_mA(positivePhaseMask),'omitnan'));

    fprintf("Magnitude droop mean : %.6f mA\n", ...
        mean(magnitudeDroop_mA(positivePhaseMask),'omitnan'));

    fprintf("Signed slope mean    : %.6f mA/ms\n", ...
        mean(signedSlope_mA_per_ms(positivePhaseMask),'omitnan'));

    fprintf("|I| slope mean       : %.6f mA/ms\n", ...
        mean(magnitudeSlope_mA_per_ms(positivePhaseMask),'omitnan'));
end

if any(negativePhaseMask)

    fprintf("\nNEGATIVE PHASES\n");

    fprintf("Early mean           : %.6f mA\n", ...
        mean(earlyCurrent_mA(negativePhaseMask),'omitnan'));

    fprintf("Late mean            : %.6f mA\n", ...
        mean(lateCurrent_mA(negativePhaseMask),'omitnan'));

    fprintf("Magnitude droop mean : %.6f mA\n", ...
        mean(magnitudeDroop_mA(negativePhaseMask),'omitnan'));

    fprintf("Signed slope mean    : %.6f mA/ms\n", ...
        mean(signedSlope_mA_per_ms(negativePhaseMask),'omitnan'));

    fprintf("|I| slope mean       : %.6f mA/ms\n", ...
        mean(magnitudeSlope_mA_per_ms(negativePhaseMask),'omitnan'));
end

%% ========================================================================
% PART H: DERIVE FINAL CH3 STATE THRESHOLDS FROM MEASURED DROOP
% ========================================================================

positiveLate = ...
    lateCurrent_mA( ...
    positivePhaseMask & ...
    isfinite(lateCurrent_mA));

negativeLate = ...
    lateCurrent_mA( ...
    negativePhaseMask & ...
    isfinite(lateCurrent_mA));

if isempty(positiveLate) || isempty(negativeLate)

    error("Not enough physical phase data to derive final thresholds.");
end

positiveDroopFloor_mA = ...
    percentileLocal( ...
    positiveLate, ...
    POSITIVE_FLOOR_PERCENTILE);

negativeDroopCeiling_mA = ...
    percentileLocal( ...
    negativeLate, ...
    NEGATIVE_CEILING_PERCENTILE);

finalPositiveThreshold_mA = ...
    zeroLevel_mA + ...
    FINAL_THRESHOLD_MARGIN* ...
    (positiveDroopFloor_mA-zeroLevel_mA);

finalNegativeThreshold_mA = ...
    zeroLevel_mA + ...
    FINAL_THRESHOLD_MARGIN* ...
    (negativeDroopCeiling_mA-zeroLevel_mA);

fprintf("\n============================================================\n");
fprintf("DROOP-DERIVED FINAL STATE THRESHOLDS\n");
fprintf("============================================================\n");

fprintf("Positive droop floor      : %.6f mA\n", ...
    positiveDroopFloor_mA);

fprintf("Negative droop ceiling    : %.6f mA\n", ...
    negativeDroopCeiling_mA);

fprintf("Threshold margin          : %.3f\n", ...
    FINAL_THRESHOLD_MARGIN);

fprintf("Final positive threshold  : %.6f mA\n", ...
    finalPositiveThreshold_mA);

fprintf("Final negative threshold  : %.6f mA\n", ...
    finalNegativeThreshold_mA);

finalState = ...
    zeros(size(currentSmooth_mA),'int8');

finalState( ...
    currentSmooth_mA>=finalPositiveThreshold_mA) = 1;

finalState( ...
    currentSmooth_mA<=finalNegativeThreshold_mA) = -1;

%% ========================================================================
% FIGURE 1: COMMAND DETECTION ONLY
% ========================================================================

N = numel(t);

stride = max(1,ceil(N/MAX_PLOT_POINTS));

plotIdx = 1:stride:N;

figure('Name','01 Command detection','Visible','off','WindowStyle','normal','Color','w');

tl = tiledlayout(3,1);

title(tl,'Encoded command detection only');

nexttile;

plot(t(plotIdx)*1e3,d5V(plotIdx),'LineWidth',0.8);

hold on;

yline(d5Threshold,':');

grid on;

ylabel('D5 (V)');
title('CH1 = D5');

hold off;

nexttile;

plot(t(plotIdx)*1e3,d8V(plotIdx),'LineWidth',0.8);

hold on;

yline(d8Threshold,':');

grid on;

ylabel('D8 (V)');
title('CH2 = D8');

hold off;

nexttile;

stairs( ...
    t(plotIdx)*1e3, ...
    double(cleanCode(plotIdx)), ...
    'LineWidth',1);

hold on;

for e = 1:nCommands

    xline(commandTime_s(e)*1e3,':');

    if e<=5 || e>nCommands-4

        text( ...
            commandTime_s(e)*1e3, ...
            3.25, ...
            sprintf('%d %s', ...
            e,prettyTransition(commandClass(e))), ...
            'Rotation',90, ...
            'VerticalAlignment','bottom');
    end
end

grid on;

ylim([-0.3 4]);

yticks([0 1 2 3]);
yticklabels({'00','01','10','11'});

ylabel('D8D5');
xlabel('Time (ms)');
title('Stable debug code and command events');

hold off;

%% ========================================================================
% FIGURE 2: ALL GRADIENT CANDIDATES AND PHYSICS-VALID CANDIDATES
% ========================================================================

figure('Name','02 Gradient candidates','Visible','off','WindowStyle','normal','Color','w');

tl = tiledlayout(2,1);

title(tl,'Sensitive gradient candidate generation');

nexttile;

plot( ...
    t(plotIdx)*1e3, ...
    currentRaw_mA(plotIdx), ...
    'LineWidth',0.7);

hold on;

for k = 1:nCandidates

    if candidateAcceptedPhysics(k)

        plot( ...
            candidateTime_s(k)*1e3, ...
            interp1(t,currentRaw_mA,candidateTime_s(k)), ...
            'o', ...
            'MarkerSize',5);

    else

        plot( ...
            candidateTime_s(k)*1e3, ...
            interp1(t,currentRaw_mA,candidateTime_s(k)), ...
            'x', ...
            'MarkerSize',5);
    end
end

grid on;

ylabel('Current (mA)');
title('CH3, circles = physics-valid candidates, x = rejected candidates');

hold off;

nexttile;

plot( ...
    t(plotIdx)*1e3, ...
    gradient_mA_per_us(plotIdx), ...
    'LineWidth',0.7);

hold on;

yline( gradientThreshold,'--');
yline(-gradientThreshold,'--');

for k = 1:nCandidates

    if candidateAcceptedPhysics(k)

        plot( ...
            candidateTime_s(k)*1e3, ...
            candidateGradient(k), ...
            'o', ...
            'MarkerSize',5);

    else

        plot( ...
            candidateTime_s(k)*1e3, ...
            candidateGradient(k), ...
            'x', ...
            'MarkerSize',5);
    end
end

grid on;

xlabel('Time (ms)');
ylabel('dI/dt (mA/us)');

title(sprintf( ...
    'Candidate threshold = %.3f mA/us', ...
    gradientThreshold));

hold off;

%% ========================================================================
% FIGURE 3: COMMAND EVENTS VS ACCEPTED PHYSICAL RESPONSES
% ========================================================================

figure('Name','03 Commands vs responses','Visible','off','WindowStyle','normal','Color','w');

tl = tiledlayout(2,1);

title(tl,'Manual check: commands versus accepted CH3 responses');

ax1 = nexttile;

commandY = NaN(nCommands,1);

for e = 1:nCommands
    commandY(e) = transitionClassNumber(commandClass(e));
end

stem( ...
    commandTime_s*1e3, ...
    commandY, ...
    'filled', ...
    'MarkerSize',3);

grid on;

ylim([0.4 4.6]);

yticks([1 2 3 4]);
yticklabels({'0 -> +I','+I -> -I','-I -> +I','-I -> 0'});

ylabel('Command');
title('Encoded command events');

for e = 1:nCommands

    if e<=5 || e>nCommands-4

        text( ...
            commandTime_s(e)*1e3, ...
            commandY(e)+0.12, ...
            sprintf('%d',e), ...
            'HorizontalAlignment','center');
    end
end

ax2 = nexttile;

plot( ...
    t(plotIdx)*1e3, ...
    currentRaw_mA(plotIdx), ...
    'LineWidth',0.7);

hold on;

for e = 1:nCommands

    if matchedMask(e)

        xResp = matchedResponseTime_s(e)*1e3;

        xline(xResp,':');

        if e<=5 || e>nCommands-4

            yl = ylim;

            text( ...
                xResp, ...
                yl(2)-0.07*(yl(2)-yl(1)), ...
                sprintf('%d %s', ...
                e,prettyTransition(commandClass(e))), ...
                'Rotation',90, ...
                'VerticalAlignment','top');
        end
    end
end

grid on;

xlabel('Time (ms)');
ylabel('Current (mA)');
title('Matched physical CH3 responses');

hold off;

linkaxes([ax1 ax2],'x');

%% ========================================================================
% FIGURE 4: EXPLICIT COMMAND -> RESPONSE PAIRS
% ========================================================================

figure('Name','04 Command response pairs','Visible','off','WindowStyle','normal','Color','w');

plot( ...
    t(plotIdx)*1e3, ...
    currentRaw_mA(plotIdx), ...
    'LineWidth',0.7);

hold on;

yl = ylim;

for e = 1:nCommands

    xCmd = commandTime_s(e)*1e3;

    xline(xCmd,':');

    if matchedMask(e)

        xResp = matchedResponseTime_s(e)*1e3;

        pairY = ...
            yl(2)- ...
            (0.05+0.022*mod(e,7))* ...
            (yl(2)-yl(1));

        plot( ...
            [xCmd xResp], ...
            [pairY pairY], ...
            '-', ...
            'LineWidth',1);

        yResp = ...
            interp1(t,currentRaw_mA,matchedResponseTime_s(e));

        plot( ...
            xResp,yResp, ...
            'o','MarkerSize',4);

        if e<=6 || e>nCommands-4

            text( ...
                xCmd,pairY, ...
                sprintf('%d %s', ...
                e,prettyTransition(commandClass(e))), ...
                'VerticalAlignment','bottom');
        end
    end
end

grid on;

xlabel('Time (ms)');
ylabel('Current (mA)');
title('Causal command -> accepted physical response');

hold off;

%% ========================================================================
% FIGURE 5: FIRST EVENTS IN DETAIL
% ========================================================================

figure('Name','05 First events detail','Visible','off','WindowStyle','normal','Color','w');

nShow = min(8,nCommands);

lastShownResponse = ...
    max(matchedResponseTime_s(1:nShow),[],'omitnan');

if ~isfinite(lastShownResponse)

    lastShownResponse = ...
        commandTime_s(nShow)+typicalCommandSpacing_s;
end

xStart = ...
    (commandTime_s(1)-0.25*typicalCommandSpacing_s)*1e3;

xEnd = ...
    (lastShownResponse+0.25*typicalCommandSpacing_s)*1e3;

tl = tiledlayout(2,1);

title(tl,'First events: command and response classification');

ax3 = nexttile;

stem( ...
    commandTime_s(1:nShow)*1e3, ...
    commandY(1:nShow), ...
    'filled');

grid on;

xlim([xStart xEnd]);

ylim([0.4 4.6]);

yticks([1 2 3 4]);
yticklabels({'0 -> +I','+I -> -I','-I -> +I','-I -> 0'});

ylabel('Command');
title('First encoded commands');

for e = 1:nShow

    text( ...
        commandTime_s(e)*1e3, ...
        commandY(e)+0.12, ...
        sprintf('%d',e), ...
        'HorizontalAlignment','center');
end

ax4 = nexttile;

plot( ...
    t*1e3, ...
    currentRaw_mA, ...
    'LineWidth',0.7);

hold on;

for e = 1:nShow

    if matchedMask(e)

        xResp = ...
            matchedResponseTime_s(e)*1e3;

        xline(xResp,':');

        yl = ylim;

        text( ...
            xResp, ...
            yl(2)-0.08*(yl(2)-yl(1)), ...
            sprintf('%d %s', ...
            e,prettyTransition(commandClass(e))), ...
            'Rotation',90, ...
            'VerticalAlignment','top');
    end
end

grid on;

xlim([xStart xEnd]);

xlabel('Time (ms)');
ylabel('Current (mA)');
title('Corresponding accepted CH3 responses');

hold off;

linkaxes([ax3 ax4],'x');

%% ========================================================================
% FIGURE 6: PASSIVE DROOP, POSITIVE AND NEGATIVE PHASES SEPARATELY
% ========================================================================

figure('Name','06 Passive droop','Visible','off','WindowStyle','normal','Color','w');

tl = tiledlayout(2,1);

title(tl,'Passive within-phase droop');

nexttile;
hold on;

positiveRows = ...
    find( ...
    positivePhaseMask & ...
    isfinite(phaseAnalysisStart_s));

for jj = 1:numel(positiveRows)

    p = positiveRows(jj);

    mask = ...
        t>=phaseAnalysisStart_s(p) & ...
        t<=phaseAnalysisEnd_s(p);

    tt_ms = ...
        (t(mask)-phaseAnalysisStart_s(p))*1e3;

    plot( ...
        tt_ms, ...
        currentRaw_mA(mask), ...
        'LineWidth',0.45);
end

grid on;

ylabel('Current (mA)');

title(sprintf( ...
    'Positive phases, mean |I| slope = %.4f mA/ms', ...
    mean( ...
    magnitudeSlope_mA_per_ms(positivePhaseMask), ...
    'omitnan')));

hold off;

nexttile;
hold on;

negativeRows = ...
    find( ...
    negativePhaseMask & ...
    isfinite(phaseAnalysisStart_s));

for jj = 1:numel(negativeRows)

    p = negativeRows(jj);

    mask = ...
        t>=phaseAnalysisStart_s(p) & ...
        t<=phaseAnalysisEnd_s(p);

    tt_ms = ...
        (t(mask)-phaseAnalysisStart_s(p))*1e3;

    plot( ...
        tt_ms, ...
        currentRaw_mA(mask), ...
        'LineWidth',0.45);
end

grid on;

xlabel('Time within physical phase (ms)');
ylabel('Current (mA)');

title(sprintf( ...
    'Negative phases, mean |I| slope = %.4f mA/ms', ...
    mean( ...
    magnitudeSlope_mA_per_ms(negativePhaseMask), ...
    'omitnan')));

hold off;

%% ========================================================================
% FIGURE 7: PHYSICAL PHASES DRAWN ON THE ORIGINAL OUTPUT
% ========================================================================

figure('Name','07 Physical phase segmentation','Visible','off','WindowStyle','normal','Color','w');

plot( ...
    t(plotIdx)*1e3, ...
    currentRaw_mA(plotIdx), ...
    'LineWidth',0.7);

hold on;

yl = ylim;

positiveY = ...
    yl(2)-0.08*(yl(2)-yl(1));

negativeY = ...
    yl(1)+0.08*(yl(2)-yl(1));

for p = 1:nPhases

    if ~isfinite(phaseAnalysisStart_s(p))
        continue;
    end

    if phaseState(p)=="POSITIVE"

        yPhase = positiveY;

    elseif phaseState(p)=="NEGATIVE"

        yPhase = negativeY;

    else

        continue;
    end

    plot( ...
        [phaseAnalysisStart_s(p) phaseAnalysisEnd_s(p)]*1e3, ...
        [yPhase yPhase], ...
        '-', ...
        'LineWidth',2);
end

for e = 1:nCommands

    if matchedMask(e)

        xline( ...
            matchedResponseTime_s(e)*1e3, ...
            ':');
    end
end

grid on;

xlabel('Time (ms)');
ylabel('Current (mA)');
title('Physical phase spans used for passive-droop analysis');

hold off;

%% ========================================================================
% FIGURE 8: FINAL DROOP-DERIVED STATE THRESHOLDS
% ========================================================================

figure('Name','08 Final thresholds','Visible','off','WindowStyle','normal','Color','w');

tl = tiledlayout(2,1);

title(tl,'Final CH3 state thresholds from measured droop');

nexttile;

plot( ...
    t(plotIdx)*1e3, ...
    currentRaw_mA(plotIdx), ...
    'LineWidth',0.7);

hold on;

yline(zeroLevel_mA,':','zero');

yline( ...
    finalPositiveThreshold_mA, ...
    '--','+ threshold');

yline( ...
    finalNegativeThreshold_mA, ...
    '--','- threshold');

grid on;

ylabel('Current (mA)');
title('Measured output and derived thresholds');

hold off;

nexttile;

stairs( ...
    t(plotIdx)*1e3, ...
    double(finalState(plotIdx)), ...
    'LineWidth',1);

grid on;

ylim([-1.3 1.3]);

yticks([-1 0 1]);

yticklabels({ ...
    'NEGATIVE', ...
    'ZERO / FAST TRANSITION', ...
    'POSITIVE'});

xlabel('Time (ms)');
ylabel('CH3 state');

title('Final threshold-based CH3 state classification');

%% ========================================================================
% FIGURE 9: MEASURED DELAY BY TRANSITION CLASS
% ========================================================================

figure('Name','09 Measured delay','Visible','off','WindowStyle','normal','Color','w');

hold on;

classes = [ ...
    "zero_to_pos", ...
    "pos_to_neg", ...
    "neg_to_pos", ...
    "neg_to_zero"];

for c = 1:numel(classes)

    rows = ...
        matchedMask & ...
        commandClass==classes(c);

    if any(rows)

        scatter( ...
            commandEvent(rows), ...
            delay_us(rows), ...
            30, ...
            'filled', ...
            'DisplayName', ...
            prettyTransition(classes(c)));
    end
end

grid on;

xlabel('Command event');
ylabel('Measured command-to-response delay (us)');

title('Measured delay, no fixed delay assumed');

legend('Location','best');

hold off;

%% ========================================================================
% SAVE RESULTS
% ========================================================================

captureRoot = PROJECT_FOLDER;
outFolder = STAGE1_OUTPUT_FOLDER;
figureFolder = fullfile(outFolder,"Figures");
if ~isfolder(figureFolder), mkdir(figureFolder); end

if ~isfolder(outFolder)
    mkdir(outFolder);
end

writetable( ...
    commandTable, ...
    fullfile(outFolder,"01_CommandEvents.csv"));

writetable( ...
    candidateTable, ...
    fullfile(outFolder,"02_GradientCandidates.csv"));

writetable( ...
    matchedTable, ...
    fullfile(outFolder,"03_MatchedCommandResponses.csv"));

writetable( ...
    phaseTable, ...
    fullfile(outFolder,"04_PhysicalPhaseDroop.csv"));

figs = findall(0,'Type','figure');

for k = 1:numel(figs)

    figName = get(figs(k),'Name');

    switch figName

        case '01 Command detection'
            filename = "01_CommandDetection.png";

        case '02 Gradient candidates'
            filename = "02_GradientCandidates.png";

        case '03 Commands vs responses'
            filename = "03_CommandsVsResponses.png";

        case '04 Command response pairs'
            filename = "04_CommandResponsePairs.png";

        case '05 First events detail'
            filename = "05_FirstEventsDetail.png";

        case '06 Passive droop'
            filename = "06_PassiveDroop.png";

        case '07 Physical phase segmentation'
            filename = "07_PhysicalPhaseSegmentation.png";

        case '08 Final thresholds'
            filename = "08_FinalThresholds.png";

        case '09 Measured delay'
            filename = "09_MeasuredDelay.png";

        otherwise
            continue;
    end

    fig = figs(k);
    styleStage1Figure(fig);
    drawnow;
    try
        exportgraphics(fig,fullfile(figureFolder,filename), ...
            'Resolution',FIGURE_RESOLUTION_DPI,'BackgroundColor','white');
    catch
        saveas(fig,fullfile(figureFolder,filename));
    end
    if strcmpi(FIGURE_VISIBLE,'on')
        set(fig,'WindowStyle',char(FIGURE_WINDOW_STYLE),'Visible','on');
    end
    if SAVE_EDITABLE_FIGURES
        savefig(fig,fullfile(figureFolder,replace(filename,".png",".fig")));
    end
    if strcmpi(FIGURE_VISIBLE,'off'), close(fig); end
end

%% ========================================================================
% BUILD RESULTS STRUCTURE
% ========================================================================

results = struct();

% -------------------------------------------------------------------------
% SOURCE / ACQUISITION INFORMATION
% -------------------------------------------------------------------------

results.csvPath = csvPath;
results.captureRoot = captureRoot;
results.outputRoot = captureRoot;
results.stageOutputFolder = outFolder;
results.outputLayout = "sibling_stage_folders";
results.commandEncodingMode = COMMAND_ENCODING_MODE;

results.Ts = Ts;
results.Fs = Fs;
results.t0 = t0;
results.header = header;
results.captureDuration_s = t(end) - t(1);

% -------------------------------------------------------------------------
% PROCESSED WAVEFORMS
% -------------------------------------------------------------------------
% Saved here so later scripts do not need to reload and reprocess the
% original Rigol CSV.

results.t = t;
results.currentRaw_mA = currentRaw_mA;
results.currentSmooth_mA = currentSmooth_mA;

% -------------------------------------------------------------------------
% CH3 CHARACTERISATION
% -------------------------------------------------------------------------

results.zeroLevel_mA = zeroLevel_mA;
results.zeroNoiseSD_mA = zeroNoiseSD_mA;

results.gradientThresholdMode = gradientThresholdMode;
results.gradientThreshold_mA_per_us = gradientThreshold;

results.broadZeroTolerance_mA = broadZeroTolerance_mA;
results.minimumRealChange_mA = minimumRealChange_mA;

results.finalPositiveThreshold_mA = finalPositiveThreshold_mA;
results.finalNegativeThreshold_mA = finalNegativeThreshold_mA;

% -------------------------------------------------------------------------
% CLASSIFICATION TABLES
% -------------------------------------------------------------------------

results.commandTable = commandTable;
results.candidateTable = candidateTable;
results.matchedTable = matchedTable;
results.phaseTable = phaseTable;

% -------------------------------------------------------------------------
% SAVE FOR LATER ANALYSIS STAGES
% -------------------------------------------------------------------------

save( ...
    fullfile( ...
    outFolder, ...
    "CommandAwareGradientResults.mat"), ...
    "results", ...
    "-v7.3");

fprintf("\n============================================================\n");
fprintf("ANALYSIS COMPLETE\n");
fprintf("============================================================\n");

fprintf("Saved to:\n%s\n",outFolder);
fprintf("Figures:\n%s\n",figureFolder);

fprintf("\nNo normalization performed.\n");
fprintf("No transfer-function fitting performed.\n");

fprintf("\nThe most important manual checks are:\n");
fprintf("1. 01_CommandDetection.png\n");
fprintf("2. 02_GradientCandidates.png\n");
fprintf("3. 03_CommandsVsResponses.png\n");
fprintf("4. 05_FirstEventsDetail.png\n");
fprintf("5. 06_PassiveDroop.png\n");
fprintf("6. 07_PhysicalPhaseSegmentation.png\n");

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

    tok = regexp( ...
        header, ...
        't0\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');

    if isempty(tok)
        error("Could not parse t0.");
    end

    t0 = str2double(tok{1});

    tok = regexp( ...
        header, ...
        'tInc\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');

    if isempty(tok)
        error("Could not parse tInc.");
    end

    Ts = str2double(tok{1});

    data = readmatrix( ...
        path, ...
        'NumHeaderLines',1);

    data(:,all(~isfinite(data),1)) = [];

    data = ...
        data(any(isfinite(data),2),:);

    t = ...
        t0 + ...
        (0:size(data,1)-1).'*Ts;
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

function [class,context] = classifyLegacyCodePair(fromCode,toCode)

    fromCode = double(fromCode);
    toCode = double(toCode);

    if fromCode==0 && toCode==2

        class = "zero_to_pos";
        context = "legacy_00_to_10";

    elseif fromCode==2 && toCode==3

        class = "pos_to_neg";
        context = "legacy_first_pos_to_neg";

    elseif fromCode==3 && toCode==1

        class = "neg_to_pos";
        context = "legacy_neg_to_pos";

    elseif fromCode==1 && toCode==3

        class = "pos_to_neg";
        context = "legacy_repeated_pos_to_neg";

    elseif fromCode==3 && toCode==0

        class = "neg_to_zero";
        context = "legacy_neg_to_zero";

    else

        class = "unexpected";
        context = ...
            sprintf( ...
            "legacy_%d_to_%d", ...
            fromCode,toCode);
    end
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

function label = broadStateLabel( ...
    value,zeroLevel,tolerance)

    if value > zeroLevel+tolerance

        label = "POSITIVE";

    elseif value < zeroLevel-tolerance

        label = "NEGATIVE";

    else

        label = "ZERO";
    end
end

function label = physicalTransitionFromLabels( ...
    preState,postState)

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

function n = transitionClassNumber(type)

    switch type

        case "zero_to_pos"
            n = 1;

        case "pos_to_neg"
            n = 2;

        case "neg_to_pos"
            n = 3;

        case "neg_to_zero"
            n = 4;

        otherwise
            n = NaN;
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

        [starts,ends,codes] = ...
            runsFromCode(cleaned);

        lengths = ...
            ends-starts+1;

        shortRuns = ...
            find(lengths<minSamples);

        shortRuns( ...
            shortRuns==1 | ...
            shortRuns==numel(codes)) = [];

        if isempty(shortRuns)
            break;
        end

        for jj = 1:numel(shortRuns)

            r = shortRuns(jj);

            cleaned(starts(r):ends(r)) = ...
                codes(r-1);
        end
    end
end

function [starts,ends,codes] = runsFromCode(code)

    code = code(:);

    change = [ ...
        true; ...
        diff(double(code))~=0; ...
        true];

    edges = find(change);

    starts = edges(1:end-1);
    ends = edges(2:end)-1;

    codes = code(starts);
end

function [starts,ends] = trueRuns(mask)

    mask = logical(mask(:));

    d = ...
        diff([false;mask;false]);

    starts = find(d==1);
    ends = find(d==-1)-1;
end

function idxOut = mergeCloseEdgeCandidates( ...
    idxIn,gradientSignal,minSeparation)

    if isempty(idxIn)

        idxOut = idxIn;
        return;
    end

    idxIn = sort(idxIn(:));

    groupStart = 1;
    idxOut = [];

    for k = 2:numel(idxIn)+1

        isEnd = ...
            k>numel(idxIn);

        if ~isEnd

            separated = ...
                idxIn(k)-idxIn(k-1)> ...
                minSeparation;

        else

            separated = true;
        end

        if separated

            group = ...
                idxIn(groupStart:k-1);

            [~,loc] = ...
                max( ...
                abs( ...
                gradientSignal(group)));

            idxOut(end+1,1) = ...
                group(loc); %#ok<AGROW>

            groupStart = k;
        end
    end
end

function sigma = robustSigma(x)

    x = x(isfinite(x));

    if isempty(x)

        sigma = NaN;
        return;
    end

    med = median(x);

    sigma = ...
        1.4826* ...
        median(abs(x-med));

    if sigma<=0 || ~isfinite(sigma)

        sigma = std(x);
    end

    if sigma<=0 || ~isfinite(sigma)

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

    r = ...
        1 + ...
        (p/100)*(numel(x)-1);

    lo = floor(r);
    hi = ceil(r);

    if lo==hi

        q = x(lo);

    else

        q = ...
            x(lo) + ...
            (r-lo)*(x(hi)-x(lo));
    end
end

%% HARDCODED INPUT DIAGNOSTICS ===========================================

function verifyHardcodedInputs(paths,sourceLabel,projectFolder)
paths = string(paths(:));
missing = ~isfile(paths);
if ~any(missing), return; end

fprintf(2,'\n============================================================\n');
fprintf(2,'HARDCODED INPUT ERROR: %s\n',sourceLabel);
fprintf(2,'============================================================\n');
fprintf(2,'Current MATLAB folder:\n%s\n',pwd);
fprintf(2,'Configured project folder:\n%s\n',projectFolder);
for k = 1:numel(paths)
    status = "FOUND";
    if missing(k), status = "MISSING"; end
    fprintf(2,'[%s] %s\n',status,paths(k));
end
printFolderListing(projectFolder);
error('OpenXstim:MissingHardcodedInput', ...
    '%s input is missing. Correct PROJECT_FOLDER or CSV_FILE in the USER SETTINGS block.', ...
    sourceLabel);
end

function printFolderListing(folder)
if ~isfolder(folder)
    fprintf(2,'Configured folder does not exist:\n%s\n',folder);
    [parent,~,~] = fileparts(folder);
    if isfolder(parent)
        fprintf(2,'Contents of its existing parent folder:\n%s\n',parent);
        entries = dir(parent);
    else
        return;
    end
else
    fprintf(2,'Contents of configured folder:\n%s\n',folder);
    entries = dir(folder);
end
names = string({entries.name});
names = names(names~="." & names~="..");
if isempty(names)
    fprintf(2,'  <empty>\n');
else
    for k = 1:numel(names)
        fprintf(2,'  %s\n',names(k));
    end
end
end

function styleStage1Figure(fig)
set(fig,'Color','w');
set(findall(fig,'Type','axes'),'Color','w','XColor',[.1 .1 .1],'YColor',[.1 .1 .1]);
set(findall(fig,'Type','text'),'Color',[.1 .1 .1]);
set(findall(fig,'Type','legend'),'Color','w','TextColor',[.1 .1 .1]);
layouts = findall(fig,'-isa','matlab.graphics.layout.TiledChartLayout');
for j = 1:numel(layouts)
    layouts(j).Title.Color = [.1 .1 .1];
end
end
