%% OpenXstim Phase 0 Black-Box Characterisation
% PID-based current control thesis
%
% Purpose:
%   1. Import oscilloscope data containing Arduino/DAC SYNC and stimulator output.
%   2. Convert the 1 kOhm load voltage to current.
%   3. Group related SYNC activity into command events.
%   4. Segment repeated stimulation transitions and calculate time-domain metrics.
%   5. Compare normalized repeated transitions.
%   6. Estimate simple continuous-time process models:
%         P1   = first-order
%         P1D  = first-order plus dead time
%         P2   = second-order with real poles
%      (set SECOND_ORDER_TYPE = "P2U" if clear underdamped ringing is present)
%   7. Validate on different pulses where enough repeated transitions exist.
%
% IMPORTANT MODEL BOUNDARY:
%   SYNC is used as a timing reference only. The raw SYNC voltage is NOT
%   treated as a continuously-valued plant input.
%
%   The measured delay in this script is therefore SYNC-to-current delay.
%   Any firmware execution delay that occurs BEFORE the observed SYNC
%   transaction cannot be identified from these two oscilloscope channels.
%   A separate command-start timing marker would be required to measure that
%   part of the black-box delay directly.
%
%   If the commanded DAC magnitude is unavailable, identification is carried
%   out on normalized step-like transitions. The resulting model identifies
%   dynamic shape (time constants / delay), not the absolute gain from DAC
%   code to output current.
%
% Requires:
%   - Base MATLAB for import, plotting and time-domain analysis
%   - System Identification Toolbox for procest/iddata/sim
%   - Control System Toolbox for tf() and c2d() conversion/discretization

clear;
clc;
close all;

%% USER SETTINGS

% ----------------------- File configuration ------------------------------
% Your current capture appears to use separate files:
%   CH1.CSV = Arduino/DAC SYNC
%   CH2.CSV = stimulator output across the external resistor
IMPORT_MODE = "separate";          % "separate" or "combined"

CH1_FILE = "CH1.CSV";
CH2_FILE = "CH2.CSV";
COMBINED_FILE = "capture.csv";     % only used if IMPORT_MODE = "combined"

% Resolve files relative to the actual open .m file instead of MATLAB's
% temporary Editor execution folder. Falls back to pwd.
USE_ACTIVE_EDITOR_FOLDER = true;

% ----------------------- Column assignments ------------------------------
% Set a column number explicitly if the automatic choice is wrong.
% Leave as NaN to allow automatic detection.
%
% Column numbers correspond to columns in the numeric matrix returned by
% readmatrix(). The script prints a preview so these are easy to verify.

% Separate-file mode:
CH1_TIME_COL   = NaN;
CH1_SIGNAL_COL = NaN;
CH2_TIME_COL   = NaN;
CH2_SIGNAL_COL = NaN;

% Combined-file mode:
COMBINED_TIME_COL   = NaN;
COMBINED_SYNC_COL   = NaN;
COMBINED_OUTPUT_COL = NaN;

% ----------------------- Electrical scaling ------------------------------
LOAD_R_OHM = 1000;                 % external resistive load

% I_mA = 1000 * V / R_ohm
% Therefore, for 1 kOhm, 1 V numerically equals 1 mA.

REMOVE_DC_OFFSET = true;
DC_OFFSET_METHOD = "median";       % "median", "pretrigger", or "none"
PRETRIGGER_FRACTION = 0.05;        % used only for "pretrigger"

% ----------------------- SYNC event detection ----------------------------
SYNC_THRESHOLD_V = NaN;            % NaN = midpoint of robust low/high levels
MIN_SYNC_EDGE_SPACING_S = NaN;     % NaN = 2 samples
SYNC_GROUP_GAP_S = NaN;            % NaN = estimate from edge-gap clustering

% A grouped SYNC burst is treated as ONE candidate command event.
% Individual rising/falling edges inside a burst are not separate commands.

% ----------------------- Transition analysis -----------------------------
MIN_TRANSITION_MA = NaN;           % NaN = 5% of robust current range
BASELINE_WINDOW_S = NaN;           % NaN = 20% of median command interval
MAX_RESPONSE_WINDOW_S = NaN;       % NaN = until just before next SYNC group

BASELINE_TAIL_FRACTION = 0.50;     % tail of pre-event window used for y_initial
PLATEAU_TAIL_FRACTION  = 0.25;     % tail of post-event window used for y_final

RISE_LOW_FRACTION  = 0.10;
RISE_HIGH_FRACTION = 0.90;
DELAY_THRESHOLD_FRACTION = 0.05;   % apparent response onset
SETTLING_BAND_FRACTION = 0.02;     % +/-2% of step size
SETTLING_HOLD_FRACTION = 0.15;     % must remain settled for this fraction
MIN_SETTLING_HOLD_S = NaN;         % NaN = at least 10 samples

N_OVERLAY = 8;

% Optional nominal plateau currents for error calculation.
% Leave NaN when the actual command magnitude is not yet reconstructed.
NOMINAL_POSITIVE_MA = NaN;
NOMINAL_NEGATIVE_MA = NaN;

% Optional known current rail for saturation warning.
KNOWN_ABS_CURRENT_LIMIT_MA = NaN;

% ----------------------- System identification ---------------------------
RUN_SYSTEM_IDENTIFICATION = true;

% Which transition family should define the plant model?
% "positive" = transitions ending on a positive plateau
% "negative" = transitions ending on a negative plateau
% "both"     = combine both after normalization
ID_POLARITY = "positive";

% If true, each response is normalized:
%       y_norm = (y-y_initial)/(y_final-y_initial)
% and the identification input is a unit step.
%
% This is the correct default when DAC command magnitude is unknown.
ID_USE_NORMALIZED_RESPONSE = true;

% Only used if ID_USE_NORMALIZED_RESPONSE = false.
% Enter the actual command step magnitude in whatever command units you want
% the plant gain expressed against, e.g. DAC codes or commanded mA.
ID_COMMAND_STEP_MAGNITUDE = NaN;

% Data reduction for very high scope sample rates. 1 keeps every sample.
ID_DECIMATION = 1;

% Use P2 for two real poles. Use P2U if visually clear ringing suggests an
% underdamped second-order response.
SECOND_ORDER_TYPE = "P2";          % "P2" or "P2U"

% No high-order model is selected automatically.
% After reviewing validation, set to "P1", "P1D", "P2", or "none".
SELECTED_MODEL = "none";

% Enter controller/discrete model sample time here when ready.
% Leave NaN to skip discretization.
DISCRETE_TS_S = NaN;

%% IMPORT DATA

dataFolder = resolveDataFolder(USE_ACTIVE_EDITOR_FOLDER);

fprintf('\n============================================================\n');
fprintf('OpenXstim Phase 0 analysis\n');
fprintf('Data folder:\n%s\n', dataFolder);
fprintf('============================================================\n\n');

if IMPORT_MODE == "separate"

    ch1Path = fullfile(dataFolder, CH1_FILE);
    ch2Path = fullfile(dataFolder, CH2_FILE);

    assert(isfile(ch1Path), 'Could not find CH1 file:\n%s', ch1Path);
    assert(isfile(ch2Path), 'Could not find CH2 file:\n%s', ch2Path);

    M1 = importNumericScopeCSV(ch1Path, 2, "CH1 / SYNC");
    M2 = importNumericScopeCSV(ch2Path, 2, "CH2 / Output");

    [tSync, syncV, ch1TimeUsed, ch1SignalUsed] = ...
        chooseTimeAndSignal(M1, CH1_TIME_COL, CH1_SIGNAL_COL);

    [tOut, outputV, ch2TimeUsed, ch2SignalUsed] = ...
        chooseTimeAndSignal(M2, CH2_TIME_COL, CH2_SIGNAL_COL);

    fprintf('\nSelected columns:\n');
    fprintf('  CH1: time = column %d, SYNC = column %d\n', ...
        ch1TimeUsed, ch1SignalUsed);
    fprintf('  CH2: time = column %d, output = column %d\n', ...
        ch2TimeUsed, ch2SignalUsed);

    [t, syncV, outputV, Ts] = alignSeparateChannels( ...
        tSync, syncV, tOut, outputV);

elseif IMPORT_MODE == "combined"

    combinedPath = fullfile(dataFolder, COMBINED_FILE);
    assert(isfile(combinedPath), 'Could not find combined file:\n%s', combinedPath);

    M = importNumericScopeCSV(combinedPath, 3, "Combined scope file");

    [t, syncV, outputV, timeUsed, syncUsed, outputUsed] = ...
        chooseCombinedColumns(M, COMBINED_TIME_COL, ...
        COMBINED_SYNC_COL, COMBINED_OUTPUT_COL);

    fprintf('\nSelected columns:\n');
    fprintf('  time = column %d, SYNC = column %d, output = column %d\n', ...
        timeUsed, syncUsed, outputUsed);

    [t, syncV, outputV, Ts] = cleanCombinedSignals(t, syncV, outputV);

else
    error('IMPORT_MODE must be "separate" or "combined".');
end

% Make time start at zero for easier interpretation.
t = t - t(1);

fprintf('\nAligned analysis data:\n');
fprintf('  Samples          : %d\n', numel(t));
fprintf('  Sample period    : %.9g s\n', Ts);
fprintf('  Sample frequency : %.6g Hz\n', 1/Ts);
fprintf('  Record duration  : %.6g s\n', t(end)-t(1));

%% CLEAN AND SCALE SIGNALS

currentRaw_mA = (1000 / LOAD_R_OHM) .* outputV;

switch DC_OFFSET_METHOD
    case "none"
        dcOffset_mA = 0;

    case "median"
        dcOffset_mA = median(currentRaw_mA, 'omitnan');

    case "pretrigger"
        nPre = max(5, round(PRETRIGGER_FRACTION * numel(currentRaw_mA)));
        dcOffset_mA = median(currentRaw_mA(1:nPre), 'omitnan');

    otherwise
        error('DC_OFFSET_METHOD must be "median", "pretrigger", or "none".');
end

if ~REMOVE_DC_OFFSET
    dcOffset_mA = 0;
end

current_mA = currentRaw_mA - dcOffset_mA;

fprintf('\nCurrent conversion:\n');
fprintf('  Load resistance : %.6g ohm\n', LOAD_R_OHM);
fprintf('  Removed offset  : %.6g mA\n', dcOffset_mA);

%% PLOT RAW DATA

figure('Name','Raw scope data');
tl = tiledlayout(3,1);
title(tl, 'OpenXstim raw oscilloscope capture');

ax1 = nexttile;
plot(t, syncV, 'LineWidth', 1);
grid on;
ylabel('SYNC (V)');
title('Channel 1: Arduino / DAC SYNC');

ax2 = nexttile;
plot(t, outputV, 'LineWidth', 1);
grid on;
ylabel('Load voltage (V)');
title('Channel 2: voltage across external load');

ax3 = nexttile;
plot(t, currentRaw_mA, 'LineWidth', 1);
hold on;
plot(t, current_mA, 'LineWidth', 1);
grid on;
xlabel('Time (s)');
ylabel('Current (mA)');
title('Calculated output current');
legend('Raw', 'Offset-corrected', 'Location','best');

linkaxes([ax1 ax2 ax3], 'x');

%% DETECT COMMAND EVENTS

syncLow  = localPercentile(syncV, 5);
syncHigh = localPercentile(syncV, 95);

if isnan(SYNC_THRESHOLD_V)
    syncThreshold = 0.5 * (syncLow + syncHigh);
else
    syncThreshold = SYNC_THRESHOLD_V;
end

syncLogic = syncV > syncThreshold;
syncEdgeIdx = find(diff(syncLogic) ~= 0) + 1;
syncEdgeTimes = t(syncEdgeIdx);

if isempty(syncEdgeTimes)
    error(['No SYNC edges were detected. Check the selected CH1 signal ' ...
           'column and SYNC_THRESHOLD_V.']);
end

if isnan(MIN_SYNC_EDGE_SPACING_S)
    minSyncEdgeSpacing = 2 * Ts;
else
    minSyncEdgeSpacing = MIN_SYNC_EDGE_SPACING_S;
end

% Remove edge detections that are effectively duplicate samples.
keepEdge = [true; diff(syncEdgeTimes) >= minSyncEdgeSpacing];
syncEdgeTimes = syncEdgeTimes(keepEdge);
syncEdgeIdx = syncEdgeIdx(keepEdge);

if isnan(SYNC_GROUP_GAP_S)
    syncGroupGap = estimateSyncGroupGap(syncEdgeTimes, Ts);
else
    syncGroupGap = SYNC_GROUP_GAP_S;
end

[eventTimes, eventBurstEndTimes, eventEdgeCounts] = ...
    groupSyncEdges(syncEdgeTimes, syncGroupGap);

fprintf('\nSYNC detection:\n');
fprintf('  Threshold                     : %.6g V\n', syncThreshold);
fprintf('  Raw/debounced SYNC edges      : %d\n', numel(syncEdgeTimes));
fprintf('  SYNC burst grouping gap       : %.9g s\n', syncGroupGap);
fprintf('  Grouped command candidates    : %d\n', numel(eventTimes));

if numel(eventTimes) < 2
    error(['Fewer than two grouped SYNC events were found. Adjust ' ...
           'SYNC_THRESHOLD_V or SYNC_GROUP_GAP_S.']);
end

medianCommandInterval = median(diff(eventTimes), 'omitnan');

if isnan(BASELINE_WINDOW_S)
    baselineWindow = max(10*Ts, 0.20 * medianCommandInterval);
else
    baselineWindow = BASELINE_WINDOW_S;
end

if isnan(MIN_TRANSITION_MA)
    currentRobustRange = localPercentile(current_mA, 95) - ...
                         localPercentile(current_mA, 5);
    minTransition = max(10*eps, 0.05 * abs(currentRobustRange));
else
    minTransition = MIN_TRANSITION_MA;
end

fprintf('  Median grouped-event interval : %.9g s\n', medianCommandInterval);
fprintf('  Baseline window               : %.9g s\n', baselineWindow);
fprintf('  Significant step threshold    : %.6g mA\n', minTransition);

figure('Name','Detected SYNC activity');
plot(t, syncV, 'LineWidth', 1);
hold on;
yline(syncThreshold, ':', 'SYNC threshold');
for k = 1:numel(eventTimes)
    xline(eventTimes(k), '--');
end
grid on;
xlabel('Time (s)');
ylabel('SYNC (V)');
title('Grouped SYNC command candidates');
hold off;

%% SEGMENT PULSES

nEvents = numel(eventTimes);

Initial_mA          = nan(nEvents,1);
Final_mA            = nan(nEvents,1);
Delta_mA            = nan(nEvents,1);
Peak_mA             = nan(nEvents,1);
T10_s               = nan(nEvents,1);
T90_s               = nan(nEvents,1);
Transition10to90_s  = nan(nEvents,1);
RiseTime_s          = nan(nEvents,1);
FallTime_s          = nan(nEvents,1);
Overshoot_pct       = nan(nEvents,1);
SettlingTime_s      = nan(nEvents,1);
ResponseDelay_s     = nan(nEvents,1);
CommandInterval_s   = nan(nEvents,1);
PlateauError_pct    = nan(nEvents,1);
AnalysisEnd_s       = nan(nEvents,1);
Significant         = false(nEvents,1);
Direction           = strings(nEvents,1);
PlateauType         = strings(nEvents,1);

for k = 1:nEvents

    te = eventTimes(k);

    if k < nEvents
        nextEvent = eventTimes(k+1);
        naturalEnd = nextEvent - 2*Ts;
        CommandInterval_s(k) = nextEvent - te;
    else
        nextEvent = NaN;
        naturalEnd = min(t(end), te + medianCommandInterval);
    end

    if ~isnan(MAX_RESPONSE_WINDOW_S)
        analysisEnd = min(naturalEnd, te + MAX_RESPONSE_WINDOW_S);
    else
        analysisEnd = naturalEnd;
    end

    analysisEnd = min(analysisEnd, t(end));
    AnalysisEnd_s(k) = analysisEnd;

    preMask = t >= max(t(1), te-baselineWindow) & t < te;
    postMask = t >= te & t <= analysisEnd;

    preIdx = find(preMask);
    postIdx = find(postMask);

    if numel(preIdx) < 5 || numel(postIdx) < 10
        Direction(k) = "insufficient-data";
        continue;
    end

    nBaseTail = max(3, round(BASELINE_TAIL_FRACTION * numel(preIdx)));
    baseTailIdx = preIdx(end-nBaseTail+1:end);
    y0 = median(current_mA(baseTailIdx), 'omitnan');

    nPlateau = max(5, round(PLATEAU_TAIL_FRACTION * numel(postIdx)));
    plateauIdx = postIdx(end-nPlateau+1:end);
    yf = median(current_mA(plateauIdx), 'omitnan');

    delta = yf - y0;

    Initial_mA(k) = y0;
    Final_mA(k) = yf;
    Delta_mA(k) = delta;

    if abs(delta) < minTransition
        Direction(k) = "no-significant-change";
        PlateauType(k) = classifyPlateau(yf, minTransition);
        continue;
    end

    Significant(k) = true;

    if delta > 0
        Direction(k) = "up";
    else
        Direction(k) = "down";
    end

    PlateauType(k) = classifyPlateau(yf, minTransition);

    ts = t(postIdx);
    ys = current_mA(postIdx);

    [m, peak, t10, t90, tDelay, tSettle, overshoot] = ...
        calculateTransitionMetrics(ts, ys, te, y0, yf, ...
        RISE_LOW_FRACTION, RISE_HIGH_FRACTION, ...
        DELAY_THRESHOLD_FRACTION, SETTLING_BAND_FRACTION, ...
        SETTLING_HOLD_FRACTION, MIN_SETTLING_HOLD_S, Ts);

    Peak_mA(k) = peak;
    T10_s(k) = t10;
    T90_s(k) = t90;
    Transition10to90_s(k) = m;
    ResponseDelay_s(k) = tDelay;
    SettlingTime_s(k) = tSettle;
    Overshoot_pct(k) = overshoot;

    if delta > 0
        RiseTime_s(k) = m;
    else
        FallTime_s(k) = m;
    end

    if yf > minTransition && isfinite(NOMINAL_POSITIVE_MA)
        PlateauError_pct(k) = 100 * (yf - NOMINAL_POSITIVE_MA) / ...
                              abs(NOMINAL_POSITIVE_MA);
    elseif yf < -minTransition && isfinite(NOMINAL_NEGATIVE_MA)
        PlateauError_pct(k) = 100 * (yf - NOMINAL_NEGATIVE_MA) / ...
                              abs(NOMINAL_NEGATIVE_MA);
    end
end

Event = (1:nEvents).';
SyncTime_s = eventTimes(:);
SyncBurstEnd_s = eventBurstEndTimes(:);
SyncEdgesInBurst = eventEdgeCounts(:);

metricsTable = table(Event, SyncTime_s, SyncBurstEnd_s, SyncEdgesInBurst, ...
    Direction, PlateauType, Significant, Initial_mA, Final_mA, Delta_mA, ...
    Peak_mA, ResponseDelay_s, T10_s, T90_s, Transition10to90_s, ...
    RiseTime_s, FallTime_s, Overshoot_pct, SettlingTime_s, ...
    CommandInterval_s, PlateauError_pct, AnalysisEnd_s);

fprintf('\nTime-domain event metrics:\n');
disp(metricsTable);

%% TIME-DOMAIN METRICS

sigIdx = find(Significant);
posIdx = find(Significant & Final_mA > minTransition);
negIdx = find(Significant & Final_mA < -minTransition);

fprintf('\nDetected significant transitions: %d / %d grouped SYNC events\n', ...
    numel(sigIdx), nEvents);
fprintf('  Positive-plateau transitions: %d\n', numel(posIdx));
fprintf('  Negative-plateau transitions: %d\n', numel(negIdx));

if ~isempty(posIdx)
    fprintf('\nRepresentative positive transition: Event %d\n', posIdx(1));
    printEventMetrics(metricsTable(posIdx(1),:));
end

if ~isempty(negIdx)
    fprintf('\nRepresentative negative transition: Event %d\n', negIdx(1));
    printEventMetrics(metricsTable(negIdx(1),:));
end

% Repetition period between starts of similar positive/negative phases.
positiveStarts = find(Significant & Final_mA > minTransition & Delta_mA > 0);
negativeStarts = find(Significant & Final_mA < -minTransition & Delta_mA < 0);

if numel(positiveStarts) >= 2
    positiveRepPeriod = median(diff(eventTimes(positiveStarts)), 'omitnan');
else
    positiveRepPeriod = NaN;
end

if numel(negativeStarts) >= 2
    negativeRepPeriod = median(diff(eventTimes(negativeStarts)), 'omitnan');
else
    negativeRepPeriod = NaN;
end

% Command interval following each active phase is used as a pulse-width
% proxy. Verify this visually because a SYNC burst can represent firmware
% activity other than an actual phase termination.
if ~isempty(posIdx)
    positivePulseWidthProxy = median(CommandInterval_s(posIdx), 'omitnan');
else
    positivePulseWidthProxy = NaN;
end

if ~isempty(negIdx)
    negativePulseWidthProxy = median(CommandInterval_s(negIdx), 'omitnan');
else
    negativePulseWidthProxy = NaN;
end

fprintf('\nPulse timing summary:\n');
fprintf('  Positive repetition period       : %.9g s\n', positiveRepPeriod);
fprintf('  Negative repetition period       : %.9g s\n', negativeRepPeriod);
fprintf('  Positive pulse-width proxy        : %.9g s\n', positivePulseWidthProxy);
fprintf('  Negative pulse-width proxy        : %.9g s\n', negativePulseWidthProxy);
fprintf('  NOTE: pulse width above is based on grouped SYNC event spacing.\n');
fprintf('        Confirm it against the current waveform before reporting it.\n');

% Plot representative positive and negative transitions with markers.
repEvents = [];
if ~isempty(posIdx), repEvents(end+1) = posIdx(1); end
if ~isempty(negIdx), repEvents(end+1) = negIdx(1); end

if ~isempty(repEvents)
    figure('Name','Representative transition metrics');
    tl = tiledlayout(numel(repEvents),1);
    title(tl, 'Representative OpenXstim transitions');

    for r = 1:numel(repEvents)
        k = repEvents(r);
        ax = nexttile;
        plotMetricTransition(ax, t, current_mA, metricsTable(k,:), ...
            RISE_LOW_FRACTION, RISE_HIGH_FRACTION);
    end
end

%% NORMALIZED RESPONSE

% Select several significant positive and negative phase transitions.
if ~isempty(sigIdx)

    if isnan(MAX_RESPONSE_WINDOW_S)
        commonPostWindow = 0.85 * medianCommandInterval;
    else
        commonPostWindow = min(MAX_RESPONSE_WINDOW_S, ...
                               0.85 * medianCommandInterval);
    end

    overlayPreWindow = baselineWindow;

    figure('Name','Repeated transition overlays');
    tl = tiledlayout(2,1);
    title(tl, 'Repeated output-current transitions');

    ax = nexttile;
    overlayTransitions(ax, t, current_mA, metricsTable, posIdx, ...
        N_OVERLAY, overlayPreWindow, commonPostWindow, false);
    title('Positive plateau transitions');
    ylabel('\Delta current (mA)');
    grid on;

    ax = nexttile;
    overlayTransitions(ax, t, current_mA, metricsTable, negIdx, ...
        N_OVERLAY, overlayPreWindow, commonPostWindow, false);
    title('Negative plateau transitions');
    xlabel('Time relative to grouped SYNC event (s)');
    ylabel('\Delta current (mA)');
    grid on;

    figure('Name','Normalized repeated transitions');
    tl = tiledlayout(2,1);
    title(tl, 'Normalized repeated transitions');

    ax = nexttile;
    overlayTransitions(ax, t, current_mA, metricsTable, posIdx, ...
        N_OVERLAY, overlayPreWindow, commonPostWindow, true);
    title('Positive plateau transitions, normalized');
    ylabel('y_{norm}');
    grid on;

    ax = nexttile;
    overlayTransitions(ax, t, current_mA, metricsTable, negIdx, ...
        N_OVERLAY, overlayPreWindow, commonPostWindow, true);
    title('Negative plateau transitions, normalized');
    xlabel('Time relative to grouped SYNC event (s)');
    ylabel('y_{norm}');
    grid on;
end

%% SYSTEM IDENTIFICATION

modelP1 = [];
modelP1D = [];
modelP2 = [];
validationFit = table();

if RUN_SYSTEM_IDENTIFICATION

    if exist('procest','file') ~= 2 || exist('iddata','file') ~= 2
        warning(['System Identification Toolbox functions were not found. ' ...
                 'Skipping model estimation.']);
    else
        idCandidates = chooseIDCandidates(metricsTable, ID_POLARITY, minTransition);

        if isempty(idCandidates)
            warning('No suitable transitions are available for identification.');
        else

            % Split repeated pulses into estimation and validation sets.
            if numel(idCandidates) >= 4
                estEvents = idCandidates(1:2:end);
                valEvents = idCandidates(2:2:end);
                independentValidation = true;
            elseif numel(idCandidates) >= 2
                estEvents = idCandidates(1:end-1);
                valEvents = idCandidates(end);
                independentValidation = true;
            else
                estEvents = idCandidates;
                valEvents = idCandidates;
                independentValidation = false;
                warning(['Only one suitable transition is available. ' ...
                         'Validation is not independent.']);
            end

            fprintf('\nIdentification pulse allocation:\n');
            fprintf('  Estimation events : %s\n', mat2str(estEvents(:).'));
            fprintf('  Validation events : %s\n', mat2str(valEvents(:).'));

            % Use a common window that finishes before the next command.
            candidateAvailable = ...
                AnalysisEnd_s(idCandidates) - eventTimes(idCandidates);

            idPostWindow = 0.95 * min(candidateAvailable, [], 'omitnan');
            idPreWindow = min(baselineWindow, 0.25*idPostWindow);

            if idPostWindow <= 10*Ts
                warning(['The available response window is extremely short. ' ...
                         'Transfer-function estimation is unlikely to be reliable.']);
            end

            idTs = Ts * max(1, round(ID_DECIMATION));

            tID = (-idPreWindow:idTs:idPostWindow).';
            uUnit = double(tID >= 0);

            [Yall, validIDEvents] = buildIDResponses( ...
                t, current_mA, metricsTable, idCandidates, tID, ...
                ID_USE_NORMALIZED_RESPONSE);

            % Remove any candidates that could not be interpolated safely.
            idCandidates = idCandidates(validIDEvents);
            Yall = Yall(:,validIDEvents);

            if isempty(idCandidates)
                warning('No complete transition windows remain for identification.');
            else
                % Rebuild allocation after validity filtering.
                if numel(idCandidates) >= 4
                    estLocal = 1:2:numel(idCandidates);
                    valLocal = 2:2:numel(idCandidates);
                    independentValidation = true;
                elseif numel(idCandidates) >= 2
                    estLocal = 1:numel(idCandidates)-1;
                    valLocal = numel(idCandidates);
                    independentValidation = true;
                else
                    estLocal = 1;
                    valLocal = 1;
                    independentValidation = false;
                end

                yEst = mean(Yall(:,estLocal), 2, 'omitnan');
                yVal = mean(Yall(:,valLocal), 2, 'omitnan');

                if ID_USE_NORMALIZED_RESPONSE
                    uEst = uUnit;
                    uVal = uUnit;
                    outputLabel = 'Normalized current response';
                    inputLabel = 'Unit command step';
                else
                    if ~isfinite(ID_COMMAND_STEP_MAGNITUDE) || ...
                            ID_COMMAND_STEP_MAGNITUDE == 0
                        error(['Set ID_COMMAND_STEP_MAGNITUDE when ' ...
                               'ID_USE_NORMALIZED_RESPONSE = false.']);
                    end
                    uEst = ID_COMMAND_STEP_MAGNITUDE .* uUnit;
                    uVal = ID_COMMAND_STEP_MAGNITUDE .* uUnit;
                    outputLabel = 'Current change (mA)';
                    inputLabel = 'Command step';
                end

                dataEst = iddata(yEst, uEst, idTs);
                dataVal = iddata(yVal, uVal, idTs);
                dataEst.InterSample = 'zoh';
                dataVal.InterSample = 'zoh';
                dataEst.InputName = inputLabel;
                dataEst.OutputName = outputLabel;
                dataVal.InputName = inputLabel;
                dataVal.OutputName = outputLabel;

                fprintf('\nEstimating low-order continuous-time process models...\n');

                modelP1  = procest(dataEst, 'P1');
                modelP1D = procest(dataEst, 'P1D');
                modelP2  = procest(dataEst, char(SECOND_ORDER_TYPE));

                % Simulate each candidate against validation input.
                inputOnlyVal = iddata([], uVal, idTs);
                inputOnlyVal.InterSample = 'zoh';

                yhatP1  = sim(modelP1,  inputOnlyVal);
                yhatP1D = sim(modelP1D, inputOnlyVal);
                yhatP2  = sim(modelP2,  inputOnlyVal);

                yp1  = yhatP1.OutputData;
                yp1d = yhatP1D.OutputData;
                yp2  = yhatP2.OutputData;

                [fitP1,  rmseP1]  = modelFitMetrics(yVal, yp1);
                [fitP1D, rmseP1D] = modelFitMetrics(yVal, yp1d);
                [fitP2,  rmseP2]  = modelFitMetrics(yVal, yp2);

                Model = ["P1"; "P1D"; string(SECOND_ORDER_TYPE)];
                Fit_pct = [fitP1; fitP1D; fitP2];
                RMSE = [rmseP1; rmseP1D; rmseP2];
                validationFit = table(Model, Fit_pct, RMSE);

                fprintf('\nValidation goodness of fit:\n');
                disp(validationFit);

                if ~independentValidation
                    fprintf(['WARNING: validation is not independent because ' ...
                             'only one suitable repeated transition was available.\n']);
                end

                % Final requested comparison figure.
                figure('Name','Low-order model validation');
                plot(tID, yVal, 'LineWidth', 1.5);
                hold on;
                plot(tID, yp1, 'LineWidth', 1.2);
                plot(tID, yp1d, 'LineWidth', 1.2);
                plot(tID, yp2, 'LineWidth', 1.2);
                xline(0, '--', 'Grouped SYNC event');
                grid on;
                xlabel('Time relative to command event (s)');
                ylabel(outputLabel);
                title('Measured validation response vs low-order models');
                legend('Measured', ...
                    sprintf('P1, fit %.1f%%',fitP1), ...
                    sprintf('P1D, fit %.1f%%',fitP1D), ...
                    sprintf('%s, fit %.1f%%',SECOND_ORDER_TYPE,fitP2), ...
                    'Location','best');
                hold off;

                % Also show repeated estimation and validation traces.
                figure('Name','Identification data split');
                tl = tiledlayout(2,1);
                title(tl, 'Identification and validation pulse sets');

                ax = nexttile;
                plot(tID, Yall(:,estLocal), 'LineWidth', 0.8);
                hold on;
                plot(tID, yEst, 'LineWidth', 2);
                xline(0, '--');
                grid on;
                ylabel(outputLabel);
                title('Estimation pulses and their mean');
                hold off;

                ax = nexttile;
                plot(tID, Yall(:,valLocal), 'LineWidth', 0.8);
                hold on;
                plot(tID, yVal, 'LineWidth', 2);
                xline(0, '--');
                grid on;
                xlabel('Time relative to command event (s)');
                ylabel(outputLabel);
                title('Validation pulses and their mean');
                hold off;
            end
        end
    end
end

%% MODEL VALIDATION

if ~isempty(modelP1)

    fprintf('\n============================================================\n');
    fprintf('CONTINUOUS-TIME MODEL RESULTS\n');
    fprintf('============================================================\n');

    if ID_USE_NORMALIZED_RESPONSE
        fprintf(['Models below describe NORMALIZED command-to-current dynamics.\n' ...
                 'Absolute gain from DAC command to mA is not identified until\n' ...
                 'the command magnitude is reconstructed or entered manually.\n\n']);
    end

    fprintf('First-order model, P1:\n');
    printTransferFunction(modelP1);

    fprintf('\nFirst-order plus dead-time model, P1D:\n');
    printTransferFunction(modelP1D);

    fprintf('\nSecond-order model, %s:\n', SECOND_ORDER_TYPE);
    printTransferFunction(modelP2);

    fprintf('\nNo model is selected automatically.\n');
    fprintf(['Prefer the simplest structure that adequately captures the ' ...
             'validation dynamics.\n']);
    fprintf(['A small numerical fit improvement alone is not a sufficient ' ...
             'reason to increase model order.\n']);
end

%% DISCRETIZATION

selectedContinuousModel = [];

if SELECTED_MODEL ~= "none"

    switch upper(SELECTED_MODEL)
        case "P1"
            selectedContinuousModel = modelP1;
        case "P1D"
            selectedContinuousModel = modelP1D;
        case "P2"
            selectedContinuousModel = modelP2;
        otherwise
            warning('SELECTED_MODEL must be "P1", "P1D", "P2", or "none".');
    end

    if isempty(selectedContinuousModel)
        warning('Selected model is unavailable because identification did not complete.');
    elseif ~isfinite(DISCRETE_TS_S) || DISCRETE_TS_S <= 0
        fprintf(['\nA model is selected, but DISCRETE_TS_S is NaN/invalid. ' ...
                 'Discretization skipped.\n']);
    else
        try
            Gselected = tf(selectedContinuousModel);
            Gdiscrete = c2d(Gselected, DISCRETE_TS_S, 'zoh');

            fprintf('\n============================================================\n');
            fprintf('SELECTED DISCRETE MODEL\n');
            fprintf('============================================================\n');
            fprintf('Selected model : %s\n', SELECTED_MODEL);
            fprintf('Sample time    : %.9g s\n', DISCRETE_TS_S);
            fprintf('Method         : zero-order hold\n\n');
            disp(Gdiscrete);

        catch ME
            warning('Could not discretize selected model: %s', ME.message);
        end
    end
end

%% SUMMARY OUTPUT

fprintf('\n============================================================\n');
fprintf('AUTOMATED DATA-QUALITY / MODELLING CHECKS\n');
fprintf('============================================================\n');

limitations = strings(0,1);

% 1. Ambiguous SYNC-to-current mapping.
significantFraction = nnz(Significant) / max(1,nEvents);
if significantFraction < 0.50
    limitations(end+1) = ...
        "Many grouped SYNC bursts do not correspond to a significant current transition.";
end

% 2. Insufficient settling.
if ~isempty(sigIdx)
    settleFraction = nnz(isfinite(SettlingTime_s(sigIdx))) / numel(sigIdx);
    if settleFraction < 0.50
        limitations(end+1) = ...
            "Most transitions do not demonstrably settle inside the available pulse window.";
    end
end

% 3. Ringing / overshoot.
if ~isempty(sigIdx)
    medOvershoot = median(Overshoot_pct(sigIdx), 'omitnan');
    if isfinite(medOvershoot) && medOvershoot > 20
        limitations(end+1) = ...
            "Large overshoot suggests ringing or dynamics not captured by a simple first-order model.";
    end
end

% 4. Repeatability.
if numel(sigIdx) >= 3
    absStep = abs(Delta_mA(sigIdx));
    cvStep = std(absStep, 'omitnan') / max(eps, mean(absStep, 'omitnan'));
    if cvStep > 0.10
        limitations(end+1) = ...
            "Repeated transition amplitudes vary by more than about 10%, indicating limited repeatability.";
    end
end

% 5. Sampling adequacy.
transitionTimes = Transition10to90_s(sigIdx);
transitionTimes = transitionTimes(isfinite(transitionTimes) & transitionTimes > 0);
if ~isempty(transitionTimes)
    samplesAcrossTransition = median(transitionTimes / Ts, 'omitnan');
    if samplesAcrossTransition < 10
        limitations(end+1) = ...
            "Fewer than about 10 samples span the typical 10-90% transition.";
    end
end

% 6. Positive/negative asymmetry.
posTrans = Transition10to90_s(posIdx);
negTrans = Transition10to90_s(negIdx);
posTrans = posTrans(isfinite(posTrans));
negTrans = negTrans(isfinite(negTrans));

if ~isempty(posTrans) && ~isempty(negTrans)
    tp = median(posTrans);
    tn = median(negTrans);
    asym = abs(tp-tn) / max(eps, 0.5*(tp+tn));
    if asym > 0.20
        limitations(end+1) = ...
            "Positive and negative phases show more than about 20% transition-time asymmetry.";
    end
end

% 7. Known rail proximity.
if isfinite(KNOWN_ABS_CURRENT_LIMIT_MA)
    if max(abs(current_mA),[],'omitnan') > 0.98*KNOWN_ABS_CURRENT_LIMIT_MA
        limitations(end+1) = ...
            "Measured current approaches the user-specified current limit; saturation may affect identification.";
    end
end

% 8. Identification boundary limitations.
if ID_USE_NORMALIZED_RESPONSE
    limitations(end+1) = ...
        "DAC command magnitude is not used, so identified gain is normalized rather than DAC-code-to-mA gain.";
end

limitations(end+1) = ...
    "Delay is referenced to observed SYNC activity; firmware execution time before SYNC is not observable in this capture.";

% Always remind the user of checks that are difficult to infer reliably.
limitations(end+1) = ...
    "Flat-topped clipping/saturation and firmware-specific command semantics still require visual verification.";

if isempty(limitations)
    fprintf('No obvious automated warning was triggered.\n');
else
    for k = 1:numel(limitations)
        fprintf('  %d. %s\n', k, limitations(k));
    end
end

fprintf('\nRecommended next action:\n');
fprintf(['  Visually verify grouped SYNC events, representative metric markers,\n' ...
         '  repeated-transition overlays, and validation plots before using\n' ...
         '  any estimated transfer function in Simulink.\n']);

fprintf('\nAnalysis complete.\n');

%% =========================== LOCAL FUNCTIONS ============================

function dataFolder = resolveDataFolder(useActiveEditorFolder)
    dataFolder = pwd;

    if useActiveEditorFolder
        try
            activeFile = matlab.desktop.editor.getActiveFilename;
            if ~isempty(activeFile)
                dataFolder = fileparts(activeFile);
            end
        catch
            % Fall back to pwd.
        end
    end
end

function M = importNumericScopeCSV(filename, minNumericColumns, label)
    fprintf('\nImporting %s:\n  %s\n', label, filename);

    Mraw = readmatrix(filename);

    if isempty(Mraw)
        error('No numeric content could be read from %s', filename);
    end

    numericCount = sum(isfinite(Mraw),2);
    goodRow = numericCount >= minNumericColumns;

    if ~any(goodRow)
        error(['Could not find a sustained numeric data block with at least ' ...
               '%d numeric columns in %s'], minNumericColumns, filename);
    end

    % Find longest contiguous run of data-like rows. This rejects most
    % header/metadata lines without assuming a specific oscilloscope format.
    d = diff([false; goodRow; false]);
    runStart = find(d == 1);
    runEnd   = find(d == -1) - 1;
    runLength = runEnd - runStart + 1;

    [~,best] = max(runLength);
    M = Mraw(runStart(best):runEnd(best), :);

    % Delete columns that contain no numeric data at all in the selected block.
    allNanCols = all(~isfinite(M),1);
    M(:,allNanCols) = [];

    fprintf('  Numeric data block: %d rows x %d columns\n', size(M,1), size(M,2));
    fprintf('  First few numeric rows:\n');
    disp(M(1:min(6,size(M,1)), :));
end

function [t, y, timeCol, signalCol] = chooseTimeAndSignal(M, timeCol, signalCol)

    if isnan(timeCol)
        timeCol = autoTimeColumn(M);
    end

    if isnan(signalCol)
        signalCol = autoSignalColumn(M, timeCol);
    end

    validateattributes(timeCol, {'numeric'}, {'scalar','integer','positive','<=',size(M,2)});
    validateattributes(signalCol, {'numeric'}, {'scalar','integer','positive','<=',size(M,2)});

    t = M(:,timeCol);
    y = M(:,signalCol);

    good = isfinite(t) & isfinite(y);
    t = t(good);
    y = y(good);

    [t,order] = sort(t);
    y = y(order);

    [t,uniqueIdx] = unique(t,'stable');
    y = y(uniqueIdx);

    if numel(t) < 10 || any(diff(t) <= 0)
        error('Selected time column is not a valid increasing time vector.');
    end
end

function [t, syncV, outputV, timeCol, syncCol, outputCol] = ...
    chooseCombinedColumns(M, timeCol, syncCol, outputCol)

    if isnan(timeCol)
        timeCol = autoTimeColumn(M);
    end

    candidates = setdiff(1:size(M,2), timeCol);

    if isnan(syncCol) || isnan(outputCol)
        ranges = nan(size(candidates));
        for k = 1:numel(candidates)
            x = M(:,candidates(k));
            ranges(k) = localPercentile(x,95) - localPercentile(x,5);
        end

        [~,order] = sort(ranges,'descend','MissingPlacement','last');
        if numel(order) < 2
            error('Could not automatically identify two signal columns.');
        end

        % Output across the load will usually have the larger voltage swing.
        autoOutput = candidates(order(1));
        autoSync = candidates(order(2));

        if isnan(outputCol), outputCol = autoOutput; end
        if isnan(syncCol),   syncCol = autoSync;     end
    end

    t = M(:,timeCol);
    syncV = M(:,syncCol);
    outputV = M(:,outputCol);
end

function timeCol = autoTimeColumn(M)
    nCols = size(M,2);
    scores = -inf(1,nCols);

    for c = 1:nCols
        x = M(:,c);
        x = x(isfinite(x));

        if numel(x) < max(10,0.8*size(M,1))
            continue;
        end

        dx = diff(x);
        if isempty(dx)
            continue;
        end

        positiveFraction = mean(dx > 0);
        negativeFraction = mean(dx < 0);
        monotonicity = max(positiveFraction, negativeFraction);

        nonzeroDx = dx(abs(dx) > eps(max(abs(x))));
        if isempty(nonzeroDx)
            continue;
        end

        stepMean = mean(abs(nonzeroDx));
        stepCV = std(abs(nonzeroDx)) / max(eps,stepMean);

        scores(c) = 3*monotonicity + 1/(1+stepCV);
    end

    [bestScore,timeCol] = max(scores);

    if ~isfinite(bestScore)
        error(['Automatic time-column detection failed. Set the time column ' ...
               'manually in USER SETTINGS.']);
    end
end

function signalCol = autoSignalColumn(M, timeCol)
    candidates = setdiff(1:size(M,2), timeCol);
    ranges = -inf(size(candidates));

    for k = 1:numel(candidates)
        x = M(:,candidates(k));
        if nnz(isfinite(x)) < 0.5*size(M,1)
            continue;
        end
        ranges(k) = abs(localPercentile(x,95) - localPercentile(x,5));
    end

    [best,idx] = max(ranges);

    if ~isfinite(best)
        error(['Automatic signal-column detection failed. Set the signal ' ...
               'column manually in USER SETTINGS.']);
    end

    signalCol = candidates(idx);
end

function [t, syncV, outputV, Ts] = alignSeparateChannels(t1, sync1, t2, out2)

    Ts1 = median(diff(t1));
    Ts2 = median(diff(t2));

    % Avoid artificially creating more samples than were actually recorded.
    Ts = max(Ts1, Ts2);

    tStart = max(t1(1), t2(1));
    tStop  = min(t1(end), t2(end));

    if tStop <= tStart
        error('CH1 and CH2 time ranges do not overlap.');
    end

    t = (tStart:Ts:tStop).';

    % Nearest-neighbour retains the digital nature of SYNC.
    syncV = interp1(t1, sync1, t, 'nearest');

    % Linear interpolation is appropriate for aligning the measured output.
    outputV = interp1(t2, out2, t, 'linear');

    good = isfinite(t) & isfinite(syncV) & isfinite(outputV);
    t = t(good);
    syncV = syncV(good);
    outputV = outputV(good);
end

function [t, syncV, outputV, Ts] = cleanCombinedSignals(t, syncV, outputV)

    good = isfinite(t) & isfinite(syncV) & isfinite(outputV);
    t = t(good);
    syncV = syncV(good);
    outputV = outputV(good);

    [t,order] = sort(t);
    syncV = syncV(order);
    outputV = outputV(order);

    [t,uniqueIdx] = unique(t,'stable');
    syncV = syncV(uniqueIdx);
    outputV = outputV(uniqueIdx);

    Ts = median(diff(t));

    if ~isfinite(Ts) || Ts <= 0
        error('Could not determine a valid sample period from combined file.');
    end

    % If sampling jitter is material, resample onto a uniform grid for
    % subsequent system-identification operations.
    jitter = std(diff(t)) / max(eps,Ts);

    if jitter > 1e-3
        tu = (t(1):Ts:t(end)).';
        syncV = interp1(t, syncV, tu, 'nearest');
        outputV = interp1(t, outputV, tu, 'linear');
        t = tu;
    end
end

function gap = estimateSyncGroupGap(edgeTimes, Ts)

    d = diff(edgeTimes);
    d = d(isfinite(d) & d > 2*Ts);

    if isempty(d)
        gap = 10*Ts;
        return;
    end

    if numel(d) < 3
        gap = max(5*Ts, 2*min(d));
        return;
    end

    ds = sort(d);
    ratio = ds(2:end) ./ max(ds(1:end-1), eps);

    [maxRatio,idx] = max(ratio);

    if maxRatio >= 3
        % Geometric midpoint between within-burst and between-burst gaps.
        gap = sqrt(ds(idx) * ds(idx+1));
    else
        % No obvious two-timescale split. Conservative fallback.
        gap = max(5*Ts, 3*median(ds));
    end

    gap = max(gap, 3*Ts);
end

function [eventTimes, burstEndTimes, counts] = groupSyncEdges(edgeTimes, gap)

    newGroup = [true; diff(edgeTimes) > gap];
    groupStart = find(newGroup);

    groupEnd = [groupStart(2:end)-1; numel(edgeTimes)];

    eventTimes = edgeTimes(groupStart);
    burstEndTimes = edgeTimes(groupEnd);
    counts = groupEnd - groupStart + 1;
end

function [transitionTime, peak, t10, t90, tDelay, tSettle, overshoot] = ...
    calculateTransitionMetrics(ts, ys, te, y0, yf, lowFrac, highFrac, ...
    delayFrac, settleFrac, settleHoldFrac, minSettleHoldS, Ts)

    delta = yf - y0;
    s = sign(delta);

    z = s .* (ys - y0);
    target = abs(delta);

    t10 = firstCrossing(ts, z, lowFrac*target);
    t90 = firstCrossing(ts, z, highFrac*target);
    tDelayAbs = firstCrossing(ts, z, delayFrac*target);

    if isfinite(t10) && isfinite(t90)
        transitionTime = t90 - t10;
    else
        transitionTime = NaN;
    end

    if isfinite(tDelayAbs)
        tDelay = tDelayAbs - te;
    else
        tDelay = NaN;
    end

    [peakZ,peakIdx] = max(z);
    peak = ys(peakIdx);

    overshoot = max(0, 100 * (peakZ-target) / max(eps,target));

    band = settleFrac * target;
    err = abs(ys - yf);

    if isnan(minSettleHoldS)
        minHoldSamples = 10;
    else
        minHoldSamples = max(1,ceil(minSettleHoldS/Ts));
    end

    holdSamples = max(minHoldSamples, ...
        round(settleHoldFrac * numel(ys)));

    tSettle = NaN;

    startIdx = 1;
    if isfinite(t90)
        startIdx = max(1, find(ts >= t90,1,'first'));
    end

    for i = startIdx:max(startIdx,numel(ys)-holdSamples+1)
        j = min(numel(ys), i+holdSamples-1);
        if j-i+1 < holdSamples
            break;
        end
        if all(err(i:j) <= band)
            tSettle = ts(i) - te;
            break;
        end
    end
end

function tcross = firstCrossing(t, z, level)
    idx = find(z >= level,1,'first');

    if isempty(idx)
        tcross = NaN;
        return;
    end

    if idx == 1
        tcross = t(1);
        return;
    end

    z1 = z(idx-1);
    z2 = z(idx);
    t1 = t(idx-1);
    t2 = t(idx);

    if z2 == z1
        tcross = t2;
    else
        alpha = (level-z1)/(z2-z1);
        tcross = t1 + alpha*(t2-t1);
    end
end

function type = classifyPlateau(yf, threshold)
    if yf > threshold
        type = "positive";
    elseif yf < -threshold
        type = "negative";
    else
        type = "near-zero";
    end
end

function printEventMetrics(row)
    fprintf('  SYNC time                : %.9g s\n', row.SyncTime_s);
    fprintf('  Initial current          : %.6g mA\n', row.Initial_mA);
    fprintf('  Final / plateau current  : %.6g mA\n', row.Final_mA);
    fprintf('  Peak current             : %.6g mA\n', row.Peak_mA);
    fprintf('  Apparent response delay  : %.9g s\n', row.ResponseDelay_s);
    fprintf('  10-90%% transition time   : %.9g s\n', row.Transition10to90_s);
    fprintf('  Rise time                : %.9g s\n', row.RiseTime_s);
    fprintf('  Fall time                : %.9g s\n', row.FallTime_s);
    fprintf('  Overshoot                : %.6g %%\n', row.Overshoot_pct);
    fprintf('  Settling time            : %.9g s\n', row.SettlingTime_s);
    fprintf('  Command interval         : %.9g s\n', row.CommandInterval_s);
    fprintf('  Plateau error            : %.6g %%\n', row.PlateauError_pct);
end

function plotMetricTransition(ax, t, y, row, lowFrac, highFrac)

    te = row.SyncTime_s;
    tEnd = row.AnalysisEnd_s;

    preWindow = max(0, te - max(t(1), te - 0.25*(tEnd-te)));
    mask = t >= max(t(1),te-preWindow) & t <= tEnd;

    tr = t(mask) - te;
    yr = y(mask);

    plot(ax, tr, yr, 'LineWidth', 1.3);
    hold(ax,'on');

    xline(ax,0,'--','SYNC event');

    y0 = row.Initial_mA;
    yf = row.Final_mA;
    delta = yf-y0;

    y10 = y0 + lowFrac*delta;
    y90 = y0 + highFrac*delta;

    yline(ax,y10,':','10%');
    yline(ax,y90,':','90%');
    yline(ax,yf,'--','plateau');

    if isfinite(row.T10_s)
        plot(ax,row.T10_s-te,y10,'o','MarkerSize',6);
    end

    if isfinite(row.T90_s)
        plot(ax,row.T90_s-te,y90,'o','MarkerSize',6);
    end

    if isfinite(row.Peak_mA)
        [~,idx] = min(abs(yr-row.Peak_mA));
        plot(ax,tr(idx),row.Peak_mA,'s','MarkerSize',6);
    end

    if isfinite(row.SettlingTime_s)
        xline(ax,row.SettlingTime_s,':','settling');
    end

    if isfinite(row.ResponseDelay_s)
        xline(ax,row.ResponseDelay_s,':','response onset');
    end

    grid(ax,'on');
    xlabel(ax,'Time relative to grouped SYNC event (s)');
    ylabel(ax,'Current (mA)');
    title(ax,sprintf('Event %d, %s transition',row.Event,row.Direction));
    hold(ax,'off');
end

function overlayTransitions(ax, t, y, metricsTable, eventIdx, ...
    nOverlay, preWindow, postWindow, normalize)

    if isempty(eventIdx)
        text(ax,0.5,0.5,'No transitions detected', ...
            'Units','normalized','HorizontalAlignment','center');
        return;
    end

    eventIdx = eventIdx(1:min(nOverlay,numel(eventIdx)));
    dt = median(diff(t));
    tr = (-preWindow:dt:postWindow).';

    hold(ax,'on');

    for ii = 1:numel(eventIdx)
        k = eventIdx(ii);
        te = metricsTable.SyncTime_s(k);
        yi = interp1(t,y,te+tr,'linear',NaN);

        y0 = metricsTable.Initial_mA(k);
        yf = metricsTable.Final_mA(k);

        if normalize
            denom = yf-y0;
            if abs(denom) <= eps
                continue;
            end
            yi = (yi-y0)./denom;
        else
            yi = yi-y0;
        end

        plot(ax,tr,yi,'LineWidth',0.9);
    end

    xline(ax,0,'--','SYNC event');
    hold(ax,'off');
end

function idx = chooseIDCandidates(metricsTable, polarity, threshold)

    sig = metricsTable.Significant;

    switch polarity
        case "positive"
            idx = find(sig & metricsTable.Final_mA > threshold);
        case "negative"
            idx = find(sig & metricsTable.Final_mA < -threshold);
        case "both"
            idx = find(sig);
        otherwise
            error('ID_POLARITY must be "positive", "negative", or "both".');
    end
end

function [Y, valid] = buildIDResponses(t, y, metricsTable, eventIdx, tID, normalized)

    Y = nan(numel(tID),numel(eventIdx));
    valid = false(numel(eventIdx),1);

    for k = 1:numel(eventIdx)
        e = eventIdx(k);
        te = metricsTable.SyncTime_s(e);

        yi = interp1(t,y,te+tID,'linear',NaN);

        if any(~isfinite(yi))
            continue;
        end

        y0 = metricsTable.Initial_mA(e);
        yf = metricsTable.Final_mA(e);
        delta = yf-y0;

        if abs(delta) <= eps
            continue;
        end

        if normalized
            yi = (yi-y0)./delta;
        else
            % Reorient negative-going transitions so a positive command
            % magnitude gives a positive current-response magnitude.
            yi = sign(delta).*(yi-y0);
        end

        Y(:,k) = yi;
        valid(k) = true;
    end
end

function [fitPct, rmse] = modelFitMetrics(yMeasured, yPredicted)

    yMeasured = yMeasured(:);
    yPredicted = yPredicted(:);

    good = isfinite(yMeasured) & isfinite(yPredicted);
    yMeasured = yMeasured(good);
    yPredicted = yPredicted(good);

    residual = yMeasured-yPredicted;
    rmse = sqrt(mean(residual.^2));

    denom = norm(yMeasured-mean(yMeasured));
    if denom <= eps
        fitPct = NaN;
    else
        fitPct = 100*(1 - norm(residual)/denom);
    end
end

function printTransferFunction(model)

    try
        G = tf(model);
        disp(G);
    catch
        % If Control System Toolbox conversion is unavailable, display the
        % identified process model itself.
        disp(model);
    end
end

function q = localPercentile(x, p)

    x = x(isfinite(x));
    if isempty(x)
        q = NaN;
        return;
    end

    x = sort(x(:));

    if numel(x) == 1
        q = x;
        return;
    end

    r = 1 + (p/100)*(numel(x)-1);
    lo = floor(r);
    hi = ceil(r);

    if lo == hi
        q = x(lo);
    else
        q = x(lo) + (r-lo)*(x(hi)-x(lo));
    end
end
