%% OpenXstim Phase 0 System Identification
% Known command amplitude: 10 mA
%
% CH1.CSV = Arduino / DAC SYNC
% CH2.CSV = voltage across 1 kOhm load
%
% IMPORTANT:
% SYNC is used ONLY as a timing reference for DAC activity.
% It is NOT treated as an analogue plant input.
%
% Because the firmware is set to 10 mA bipolar stimulation, this script
% assumes the intended command levels are approximately:
%       -10 mA, 0 mA, +10 mA
%
% The script infers the most likely command transition by comparing measured
% pre/post plateaus with those levels. This makes it possible to estimate:
%
%       G(s) = measured current / commanded current
%
% rather than only a normalized step shape.
%
% Review all detected events visually before accepting the identified model.

clear;
clc;
close all;

%% USER SETTINGS

% ----------------------- Files -------------------------------------------
CH1_FILE = "CH1.CSV";       % Arduino / DAC SYNC
CH2_FILE = "CH2.CSV";       % load voltage

% If automatic column detection is wrong, set these manually.
% Leave NaN for automatic detection.
CH1_TIME_COL   = NaN;
CH1_SIGNAL_COL = NaN;

CH2_TIME_COL   = NaN;
CH2_SIGNAL_COL = NaN;

% ----------------------- Electrical settings -----------------------------
LOAD_R_OHM = 1000;

% Firmware command magnitude
COMMAND_AMPLITUDE_MA = 5;

% Intended bipolar command levels
COMMAND_LEVELS_MA = [-COMMAND_AMPLITUDE_MA, 0, COMMAND_AMPLITUDE_MA];

% Maximum distance between a measured plateau and an intended command level
% before the inferred command level is rejected.
LEVEL_MATCH_TOL_MA = 4;

% ----------------------- Offset removal ----------------------------------
REMOVE_DC_OFFSET = false;
DC_OFFSET_METHOD = "median";   % "median", "pretrigger", "none"
PRETRIGGER_FRACTION = 0.05;

% ----------------------- SYNC detection ----------------------------------
SYNC_THRESHOLD_V = NaN;        % NaN = automatic
SYNC_GROUP_GAP_S = NaN;        % NaN = automatic
MIN_SYNC_EDGE_SPACING_S = NaN; % NaN = 2 samples

% ----------------------- Event analysis ----------------------------------
BASELINE_WINDOW_S = NaN;       % NaN = 20% of median event spacing
MAX_RESPONSE_WINDOW_S = NaN;   % NaN = until just before next event

MIN_OUTPUT_STEP_MA = 1.0;

RISE_LOW_FRACTION = 0.10;
RISE_HIGH_FRACTION = 0.90;
DELAY_THRESHOLD_FRACTION = 0.05;
SETTLING_BAND_FRACTION = 0.02;

N_OVERLAY = 8;

% ----------------------- Identification ----------------------------------
RUN_SYSTEM_IDENTIFICATION = true;

% Select which command transition family to identify.
% Examples:
%   "0_to_+10"
%   "+10_to_0"
%   "0_to_-10"
%   "-10_to_0"
%   "all_10mA_steps"
ID_TRANSITION_FAMILY = "all_10mA_steps";

% Data decimation for very high oscilloscope sample rates.
ID_DECIMATION = 1;

% Candidate second-order process structure.
% "P2" = two real poles
% "P2U" = underdamped pair
SECOND_ORDER_TYPE = "P2";

% Do not automatically select the numerically best model.
SELECTED_MODEL = "none";       % "P1", "P1D", "P2", "none"

% Controller / discrete model sampling period.
% Leave NaN until you decide it.
DISCRETE_TS_S = NaN;

%% IMPORT DATA

dataFolder = getScriptFolder();

ch1Path = fullfile(dataFolder, CH1_FILE);
ch2Path = fullfile(dataFolder, CH2_FILE);

assert(isfile(ch1Path), "Cannot find CH1 file: " + ch1Path);
assert(isfile(ch2Path), "Cannot find CH2 file: " + ch2Path);

fprintf("\n============================================================\n");
fprintf("OpenXstim Phase 0 analysis\n");
fprintf("Known command amplitude: %.3f mA\n", COMMAND_AMPLITUDE_MA);
fprintf("Data folder:\n%s\n", dataFolder);
fprintf("============================================================\n");

M1 = readScopeNumericBlock(ch1Path, "CH1 / SYNC");
M2 = readScopeNumericBlock(ch2Path, "CH2 / output");

[tSync, syncV, ch1TimeUsed, ch1SignalUsed] = ...
    selectColumns(M1, CH1_TIME_COL, CH1_SIGNAL_COL);

[tOut, outV, ch2TimeUsed, ch2SignalUsed] = ...
    selectColumns(M2, CH2_TIME_COL, CH2_SIGNAL_COL);

fprintf("\nSelected columns:\n");
fprintf("  CH1 time   : %d\n", ch1TimeUsed);
fprintf("  CH1 signal : %d\n", ch1SignalUsed);
fprintf("  CH2 time   : %d\n", ch2TimeUsed);
fprintf("  CH2 signal : %d\n", ch2SignalUsed);

[t, syncV, outV, Ts] = alignChannels(tSync, syncV, tOut, outV);
t = t - t(1);

fprintf("\nAligned data:\n");
fprintf("  Samples          : %d\n", numel(t));
fprintf("  Sample period    : %.9g s\n", Ts);
fprintf("  Sample frequency : %.6g Hz\n", 1/Ts);
fprintf("  Duration         : %.6g s\n", t(end));

%% CLEAN AND SCALE SIGNALS

% I[mA] = 1000*V/R
currentRaw_mA = 1000 .* outV ./ LOAD_R_OHM;

switch DC_OFFSET_METHOD
    case "median"
        dcOffset_mA = median(currentRaw_mA, "omitnan");

    case "pretrigger"
        nPre = max(5, round(PRETRIGGER_FRACTION*numel(currentRaw_mA)));
        dcOffset_mA = median(currentRaw_mA(1:nPre), "omitnan");

    case "none"
        dcOffset_mA = 0;

    otherwise
        error("Unknown DC_OFFSET_METHOD.");
end

if ~REMOVE_DC_OFFSET
    dcOffset_mA = 0;
end

current_mA = currentRaw_mA - dcOffset_mA;

fprintf("\nCurrent scaling:\n");
fprintf("  Load resistor    : %.1f ohm\n", LOAD_R_OHM);
fprintf("  DC offset removed: %.6f mA\n", dcOffset_mA);
fprintf("  Expected plateaus: %.1f, 0, +%.1f mA\n", ...
    -COMMAND_AMPLITUDE_MA, COMMAND_AMPLITUDE_MA);

%% PLOT RAW DATA

figure("Name","Raw OpenXstim capture");

tl = tiledlayout(3,1);
title(tl, "OpenXstim raw oscilloscope capture");

ax1 = nexttile;
plot(t, syncV, "LineWidth", 1);
grid on;
ylabel("SYNC (V)");
title("CH1: Arduino / DAC SYNC");

ax2 = nexttile;
plot(t, outV, "LineWidth", 1);
grid on;
ylabel("Load voltage (V)");
title("CH2: voltage across 1 kOhm load");

ax3 = nexttile;
plot(t, currentRaw_mA, "LineWidth", 1);
hold on;
plot(t, current_mA, "LineWidth", 1);
yline(+COMMAND_AMPLITUDE_MA, ":");
yline(0, ":");
yline(-COMMAND_AMPLITUDE_MA, ":");
grid on;
xlabel("Time (s)");
ylabel("Current (mA)");
title("Calculated load current");
legend("Raw", "Offset corrected", "Location","best");

linkaxes([ax1 ax2 ax3],"x");

%% DETECT COMMAND EVENTS

syncLow  = pct(syncV,5);
syncHigh = pct(syncV,95);

if isnan(SYNC_THRESHOLD_V)
    syncThreshold = 0.5*(syncLow + syncHigh);
else
    syncThreshold = SYNC_THRESHOLD_V;
end

syncLogic = syncV > syncThreshold;
edgeIdx = find(diff(syncLogic) ~= 0) + 1;
edgeTimes = t(edgeIdx);

if isempty(edgeTimes)
    error("No SYNC edges detected. Check CH1 column or SYNC threshold.");
end

if isnan(MIN_SYNC_EDGE_SPACING_S)
    minEdgeSpacing = 2*Ts;
else
    minEdgeSpacing = MIN_SYNC_EDGE_SPACING_S;
end

keep = [true; diff(edgeTimes) >= minEdgeSpacing];
edgeTimes = edgeTimes(keep);

if isnan(SYNC_GROUP_GAP_S)
    syncGroupGap = estimateGroupGap(edgeTimes, Ts);
else
    syncGroupGap = SYNC_GROUP_GAP_S;
end

[eventTimes, burstEndTimes, edgesPerBurst] = ...
    groupEdges(edgeTimes, syncGroupGap);

fprintf("\nSYNC event detection:\n");
fprintf("  SYNC threshold         : %.6g V\n", syncThreshold);
fprintf("  Detected edges         : %d\n", numel(edgeTimes));
fprintf("  Burst grouping gap     : %.9g s\n", syncGroupGap);
fprintf("  Grouped SYNC events    : %d\n", numel(eventTimes));

figure("Name","SYNC event grouping");
plot(t, syncV, "LineWidth", 1);
hold on;
yline(syncThreshold, ":");
for k = 1:numel(eventTimes)
    xline(eventTimes(k),"--");
end
grid on;
xlabel("Time (s)");
ylabel("SYNC (V)");
title("Grouped SYNC activity");
hold off;

%% SEGMENT PULSES

if numel(eventTimes) < 2
    error("Need at least two grouped SYNC events.");
end

medianEventPeriod = median(diff(eventTimes));

if isnan(BASELINE_WINDOW_S)
    baselineWindow = max(10*Ts, 0.20*medianEventPeriod);
else
    baselineWindow = BASELINE_WINDOW_S;
end

nEvents = numel(eventTimes);

Initial_mA        = nan(nEvents,1);
Final_mA          = nan(nEvents,1);
MeasuredStep_mA   = nan(nEvents,1);

CommandInitial_mA = nan(nEvents,1);
CommandFinal_mA   = nan(nEvents,1);
CommandStep_mA    = nan(nEvents,1);

PlateauError_mA   = nan(nEvents,1);
PlateauError_pct  = nan(nEvents,1);

Peak_mA           = nan(nEvents,1);
T10_s             = nan(nEvents,1);
T90_s             = nan(nEvents,1);
Transition1090_s  = nan(nEvents,1);
Delay_s           = nan(nEvents,1);
Settling_s        = nan(nEvents,1);
Overshoot_pct     = nan(nEvents,1);

AnalysisEnd_s     = nan(nEvents,1);
Significant       = false(nEvents,1);
TransitionLabel   = strings(nEvents,1);

for k = 1:nEvents

    te = eventTimes(k);

    if k < nEvents
        naturalEnd = eventTimes(k+1) - 2*Ts;
    else
        naturalEnd = min(t(end), te + medianEventPeriod);
    end

    if isnan(MAX_RESPONSE_WINDOW_S)
        tEnd = naturalEnd;
    else
        tEnd = min(naturalEnd, te + MAX_RESPONSE_WINDOW_S);
    end

    tEnd = min(tEnd,t(end));
    AnalysisEnd_s(k) = tEnd;

    preIdx = find(t >= max(t(1),te-baselineWindow) & t < te);
    postIdx = find(t >= te & t <= tEnd);

    if numel(preIdx) < 5 || numel(postIdx) < 10
        continue;
    end

    nPreTail = max(3,round(0.50*numel(preIdx)));
    nPostTail = max(5,round(0.25*numel(postIdx)));

    y0 = median(current_mA(preIdx(end-nPreTail+1:end)),"omitnan");
    yf = median(current_mA(postIdx(end-nPostTail+1:end)),"omitnan");

    Initial_mA(k) = y0;
    Final_mA(k) = yf;
    MeasuredStep_mA(k) = yf-y0;

    if abs(yf-y0) < MIN_OUTPUT_STEP_MA
        continue;
    end

    Significant(k) = true;

    % Infer intended command levels from known +/-10 mA setting.
    cmd0 = nearestCommandLevel(y0, COMMAND_LEVELS_MA, LEVEL_MATCH_TOL_MA);
    cmdf = nearestCommandLevel(yf, COMMAND_LEVELS_MA, LEVEL_MATCH_TOL_MA);

    CommandInitial_mA(k) = cmd0;
    CommandFinal_mA(k) = cmdf;

    if isfinite(cmd0) && isfinite(cmdf)
        CommandStep_mA(k) = cmdf-cmd0;
        TransitionLabel(k) = commandLabel(cmd0,cmdf);

        if abs(cmdf) > eps
            PlateauError_mA(k) = yf-cmdf;
            PlateauError_pct(k) = 100*(yf-cmdf)/abs(cmdf);
        end
    else
        TransitionLabel(k) = "unclassified";
    end

    ts = t(postIdx);
    ys = current_mA(postIdx);

    [Peak_mA(k), T10_s(k), T90_s(k), Transition1090_s(k), ...
        Delay_s(k), Settling_s(k), Overshoot_pct(k)] = ...
        transitionMetrics(ts,ys,te,y0,yf, ...
        RISE_LOW_FRACTION,RISE_HIGH_FRACTION, ...
        DELAY_THRESHOLD_FRACTION,SETTLING_BAND_FRACTION,Ts);
end

Event = (1:nEvents).';
SyncStart_s = eventTimes(:);
SyncBurstEnd_s = burstEndTimes(:);
SyncEdges = edgesPerBurst(:);

metrics = table(Event,SyncStart_s,SyncBurstEnd_s,SyncEdges, ...
    Significant,TransitionLabel,Initial_mA,Final_mA,MeasuredStep_mA, ...
    CommandInitial_mA,CommandFinal_mA,CommandStep_mA, ...
    PlateauError_mA,PlateauError_pct,Peak_mA,T10_s,T90_s, ...
    Transition1090_s,Delay_s,Settling_s,Overshoot_pct,AnalysisEnd_s);

fprintf("\nDetected transition table:\n");
disp(metrics);

%% TIME-DOMAIN METRICS

validEvents = find(Significant);

fprintf("\nSummary:\n");
fprintf("  Significant output transitions: %d\n",numel(validEvents));

labels = unique(TransitionLabel(validEvents));

for i = 1:numel(labels)
    lab = labels(i);

    if lab == "unclassified"
        continue;
    end

    idx = find(TransitionLabel == lab & Significant);

    fprintf("\n%s, n = %d\n",lab,numel(idx));
    fprintf("  Final current median : %.4f mA\n",median(Final_mA(idx),"omitnan"));
    fprintf("  10-90%% time median  : %.6g s\n",median(Transition1090_s(idx),"omitnan"));
    fprintf("  Delay median         : %.6g s\n",median(Delay_s(idx),"omitnan"));
    fprintf("  Settling median      : %.6g s\n",median(Settling_s(idx),"omitnan"));
    fprintf("  Overshoot median     : %.3f %%\n",median(Overshoot_pct(idx),"omitnan"));

    finiteErr = PlateauError_pct(idx);
    finiteErr = finiteErr(isfinite(finiteErr));
    if ~isempty(finiteErr)
        fprintf("  Plateau error median : %.3f %%\n",median(finiteErr));
    end
end

% Repetition period based on similar command starts
plusEvents = find(CommandFinal_mA == +COMMAND_AMPLITUDE_MA & Significant);
minusEvents = find(CommandFinal_mA == -COMMAND_AMPLITUDE_MA & Significant);

if numel(plusEvents) >= 2
    Tplus = median(diff(eventTimes(plusEvents)));
else
    Tplus = NaN;
end

if numel(minusEvents) >= 2
    Tminus = median(diff(eventTimes(minusEvents)));
else
    Tminus = NaN;
end

fprintf("\nRepetition timing:\n");
fprintf("  Positive-phase repetition period: %.9g s\n",Tplus);
fprintf("  Negative-phase repetition period: %.9g s\n",Tminus);

%% VISUAL METRIC CHECK

plotEvents = validEvents(1:min(4,numel(validEvents)));

if ~isempty(plotEvents)

    figure("Name","Metric verification");
    tl = tiledlayout(numel(plotEvents),1);
    title(tl,"Automatic transition metric verification");

    for j = 1:numel(plotEvents)
        k = plotEvents(j);
        ax = nexttile;
        plotEventMetrics(ax,t,current_mA,metrics(k,:), ...
            RISE_LOW_FRACTION,RISE_HIGH_FRACTION);
    end
end

%% NORMALIZED RESPONSE

if ~isempty(validEvents)

    commonWindow = 0.85*medianEventPeriod;
    tr = (0:Ts:commonWindow).';

    figure("Name","Repeated normalized transitions");
    hold on;

    nPlot = min(N_OVERLAY,numel(validEvents));

    for j = 1:nPlot

        k = validEvents(j);
        te = eventTimes(k);

        yi = interp1(t,current_mA,te+tr,"linear",NaN);

        y0 = Initial_mA(k);
        yf = Final_mA(k);

        if abs(yf-y0) < eps
            continue;
        end

        yn = (yi-y0)./(yf-y0);

        plot(tr,yn,"LineWidth",0.9);
    end

    yline(0,":");
    yline(1,":");
    yline(0.1,":");
    yline(0.9,":");

    grid on;
    xlabel("Time from grouped SYNC event (s)");
    ylabel("Normalized response");
    title("Repeated normalized current transitions");
    hold off;
end

%% SYSTEM IDENTIFICATION

modelP1 = [];
modelP1D = [];
modelP2 = [];

if RUN_SYSTEM_IDENTIFICATION

    if exist("procest","file") ~= 2 || exist("iddata","file") ~= 2

        warning("System Identification Toolbox not found. Identification skipped.");

    else

        candidateEvents = chooseIDEvents( ...
            metrics,ID_TRANSITION_FAMILY,COMMAND_AMPLITUDE_MA);

        if isempty(candidateEvents)

            warning("No events match ID_TRANSITION_FAMILY.");

        else

            % Use only command steps whose size is known.
            candidateEvents = candidateEvents( ...
                isfinite(CommandStep_mA(candidateEvents)) & ...
                abs(CommandStep_mA(candidateEvents)) > 0);

            if isempty(candidateEvents)
                warning("No identified command steps have known magnitude.");
            else

                % Common identification window must end before any next event.
                availableWindow = AnalysisEnd_s(candidateEvents) - ...
                                  eventTimes(candidateEvents);

                idWindow = 0.90*min(availableWindow);

                if idWindow < 10*Ts
                    warning("Identification window is very short.");
                end

                decim = max(1,round(ID_DECIMATION));
                idTs = Ts*decim;

                tID = (0:idTs:idWindow).';

                Y = nan(numel(tID),numel(candidateEvents));
                U = nan(numel(tID),numel(candidateEvents));

                valid = false(numel(candidateEvents),1);

                for j = 1:numel(candidateEvents)

                    k = candidateEvents(j);
                    te = eventTimes(k);

                    yi = interp1(t,current_mA,te+tID,"linear",NaN);

                    if any(~isfinite(yi))
                        continue;
                    end

                    cmdStep = CommandStep_mA(k);

                    % Reorient negative command steps to a positive step.
                    s = sign(cmdStep);

                    Y(:,j) = s.*(yi-Initial_mA(k));
                    U(:,j) = abs(cmdStep).*ones(size(tID));

                    % A process model assumes step input has already occurred
                    % at t = 0, so the input record is constant after t = 0.
                    valid(j) = true;
                end

                candidateEvents = candidateEvents(valid);
                Y = Y(:,valid);
                U = U(:,valid);

                if isempty(candidateEvents)
                    warning("No complete identification windows.");
                else

                    % Separate identification and validation pulses.
                    if numel(candidateEvents) >= 4
                        estCols = 1:2:numel(candidateEvents);
                        valCols = 2:2:numel(candidateEvents);
                        independentValidation = true;

                    elseif numel(candidateEvents) >= 2
                        estCols = 1:numel(candidateEvents)-1;
                        valCols = numel(candidateEvents);
                        independentValidation = true;

                    else
                        estCols = 1;
                        valCols = 1;
                        independentValidation = false;
                    end

                    % Average repeated pulses.
                    yEst = mean(Y(:,estCols),2,"omitnan");
                    uEst = mean(U(:,estCols),2,"omitnan");

                    yVal = mean(Y(:,valCols),2,"omitnan");
                    uVal = mean(U(:,valCols),2,"omitnan");

                    % Add a pre-step zero sample so the estimator sees the
                    % transition from 0 to the commanded step.
                    tModel = [-idTs; tID];

                    yEstModel = [0; yEst];
                    yValModel = [0; yVal];

                    uEstModel = [0; uEst];
                    uValModel = [0; uVal];

                    dataEst = iddata(yEstModel,uEstModel,idTs);
                    dataVal = iddata(yValModel,uValModel,idTs);

                    dataEst.InterSample = "zoh";
                    dataVal.InterSample = "zoh";

                    fprintf("\nIdentification events: %s\n", ...
                        mat2str(candidateEvents(:).'));

                    fprintf("Estimation event columns: %s\n", ...
                        mat2str(estCols));
                    fprintf("Validation event columns: %s\n", ...
                        mat2str(valCols));

                    modelP1  = procest(dataEst,"P1");
                    modelP1D = procest(dataEst,"P1D");
                    modelP2  = procest(dataEst,char(SECOND_ORDER_TYPE));

                    inputVal = iddata([],uValModel,idTs);
                    inputVal.InterSample = "zoh";

                    yhat1  = sim(modelP1,inputVal);
                    yhat1D = sim(modelP1D,inputVal);
                    yhat2  = sim(modelP2,inputVal);

                    yp1  = yhat1.OutputData;
                    yp1D = yhat1D.OutputData;
                    yp2  = yhat2.OutputData;

                    [fit1,rmse1]   = fitMetric(yValModel,yp1);
                    [fit1D,rmse1D] = fitMetric(yValModel,yp1D);
                    [fit2,rmse2]   = fitMetric(yValModel,yp2);

                    Model = ["P1";"P1D";string(SECOND_ORDER_TYPE)];
                    Fit_percent = [fit1;fit1D;fit2];
                    RMSE_mA = [rmse1;rmse1D;rmse2];

                    fitTable = table(Model,Fit_percent,RMSE_mA);

                    fprintf("\nValidation fit:\n");
                    disp(fitTable);

                    if ~independentValidation
                        fprintf("WARNING: validation is not independent.\n");
                    end

                    figure("Name","Model validation");

                    plot(tModel,yValModel,"LineWidth",1.6);
                    hold on;
                    plot(tModel,yp1,"LineWidth",1.2);
                    plot(tModel,yp1D,"LineWidth",1.2);
                    plot(tModel,yp2,"LineWidth",1.2);

                    xline(0,"--","Command event");

                    grid on;
                    xlabel("Time from command event (s)");
                    ylabel("Current change (mA)");
                    title("Measured current vs identified low-order models");

                    legend( ...
                        "Measured validation", ...
                        sprintf("P1, %.1f%%",fit1), ...
                        sprintf("P1D, %.1f%%",fit1D), ...
                        sprintf("%s, %.1f%%",SECOND_ORDER_TYPE,fit2), ...
                        "Location","best");

                    hold off;

                    fprintf("\n============================================================\n");
                    fprintf("CONTINUOUS-TIME MODELS\n");
                    fprintf("============================================================\n");

                    fprintf("\nFirst order P1:\n");
                    printTF(modelP1);

                    fprintf("\nFirst order plus dead time P1D:\n");
                    printTF(modelP1D);

                    fprintf("\nSecond order %s:\n",SECOND_ORDER_TYPE);
                    printTF(modelP2);

                    fprintf("\nModel input units  : commanded current step, mA\n");
                    fprintf("Model output units : measured current change, mA\n");
                    fprintf("Expected DC gain should therefore be near 1 if regulation is accurate.\n");

                end
            end
        end
    end
end

%% MODEL VALIDATION

% The model is deliberately NOT selected automatically.
%
% Prefer the simplest model that reproduces:
%   - command-to-response delay
%   - dominant transition time
%   - overshoot / settling behaviour
%
% A slightly higher numerical fit is not sufficient justification for a
% higher-order model.

%% DISCRETIZATION

if SELECTED_MODEL ~= "none"

    switch upper(SELECTED_MODEL)
        case "P1"
            selectedModel = modelP1;

        case "P1D"
            selectedModel = modelP1D;

        case "P2"
            selectedModel = modelP2;

        otherwise
            error("SELECTED_MODEL must be P1, P1D, P2, or none.");
    end

    if isempty(selectedModel)
        warning("Selected model is unavailable.");

    elseif ~isfinite(DISCRETE_TS_S) || DISCRETE_TS_S <= 0

        fprintf("\nDISCRETE_TS_S not set. Discretization skipped.\n");

    else

        Gc = tf(selectedModel);
        Gd = c2d(Gc,DISCRETE_TS_S,"zoh");

        fprintf("\n============================================================\n");
        fprintf("DISCRETE SELECTED MODEL\n");
        fprintf("============================================================\n");
        fprintf("Selected model : %s\n",SELECTED_MODEL);
        fprintf("Sample time    : %.9g s\n",DISCRETE_TS_S);
        fprintf("Method         : zero-order hold\n\n");

        disp(Gd);
    end
end

%% SUMMARY OUTPUT

fprintf("\n============================================================\n");
fprintf("MODELLING NOTES\n");
fprintf("============================================================\n");

fprintf("1. SYNC is used as a timing reference, not as an analogue input.\n");

fprintf(["2. The known 10 mA firmware setting allows measured plateaus to be\n" ...
         "   associated approximately with -10, 0, and +10 mA commands.\n"]);

fprintf(["3. A transfer-function gain near 1 means approximately 1 mA measured\n" ...
         "   current change per 1 mA commanded current change.\n"]);

fprintf(["4. Any firmware execution delay occurring before the observed SYNC\n" ...
         "   activity is not visible in these two channels.\n"]);

fprintf(["5. Check the grouped SYNC markers manually. If multiple SPI/DAC\n" ...
         "   transactions are incorrectly separated, adjust SYNC_GROUP_GAP_S.\n"]);

fprintf(["6. Do not accept a model if pulses do not settle, positive/negative\n" ...
         "   phases are strongly asymmetric, clipping occurs, or repeatability\n" ...
         "   is poor.\n"]);

fprintf("\nAnalysis complete.\n");

%% LOCAL FUNCTIONS

function folder = getScriptFolder()

    folder = pwd;

    try
        f = matlab.desktop.editor.getActiveFilename;
        if ~isempty(f)
            folder = fileparts(f);
        end
    catch
    end
end

function M = readScopeNumericBlock(filename,label)

    fprintf("\nImporting %s:\n%s\n",label,filename);

    raw = readmatrix(filename);

    if isempty(raw)
        error("No numeric data found in " + filename);
    end

    finiteCount = sum(isfinite(raw),2);
    goodRow = finiteCount >= 2;

    if ~any(goodRow)
        error("Could not find numeric oscilloscope data block.");
    end

    d = diff([false;goodRow;false]);

    starts = find(d==1);
    stops = find(d==-1)-1;

    lengths = stops-starts+1;

    [~,best] = max(lengths);

    M = raw(starts(best):stops(best),:);

    emptyCols = all(~isfinite(M),1);
    M(:,emptyCols) = [];

    fprintf("Numeric block: %d rows x %d columns\n",size(M,1),size(M,2));
    fprintf("First six numeric rows:\n");
    disp(M(1:min(6,size(M,1)),:));
end

function [t,y,timeCol,signalCol] = selectColumns(M,timeCol,signalCol)

    if isnan(timeCol)
        timeCol = detectTimeColumn(M);
    end

    if isnan(signalCol)
        signalCol = detectSignalColumn(M,timeCol);
    end

    t = M(:,timeCol);
    y = M(:,signalCol);

    valid = isfinite(t) & isfinite(y);

    t = t(valid);
    y = y(valid);

    [t,order] = sort(t);
    y = y(order);

    [t,idx] = unique(t,"stable");
    y = y(idx);

    if numel(t)<10 || any(diff(t)<=0)
        error("Selected time column is not a valid time vector.");
    end
end

function col = detectTimeColumn(M)

    n = size(M,2);
    score = -inf(1,n);

    for c = 1:n

        x = M(:,c);
        x = x(isfinite(x));

        if numel(x) < 0.8*size(M,1)
            continue;
        end

        dx = diff(x);

        if isempty(dx)
            continue;
        end

        monotonic = max(mean(dx>0),mean(dx<0));

        nz = abs(dx)>eps(max(abs(x)));

        if ~any(nz)
            continue;
        end

        dx2 = abs(dx(nz));

        cv = std(dx2)/max(eps,mean(dx2));

        score(c) = 3*monotonic + 1/(1+cv);
    end

    [best,col] = max(score);

    if ~isfinite(best)
        error("Automatic time-column detection failed.");
    end
end

function col = detectSignalColumn(M,timeCol)

    candidates = setdiff(1:size(M,2),timeCol);

    span = -inf(size(candidates));

    for k = 1:numel(candidates)

        x = M(:,candidates(k));

        if nnz(isfinite(x)) < 0.5*size(M,1)
            continue;
        end

        span(k) = abs(pct(x,95)-pct(x,5));
    end

    [best,idx] = max(span);

    if ~isfinite(best)
        error("Automatic signal-column detection failed.");
    end

    col = candidates(idx);
end

function [t,syncV,outV,Ts] = alignChannels(t1,y1,t2,y2)

    Ts1 = median(diff(t1));
    Ts2 = median(diff(t2));

    Ts = max(Ts1,Ts2);

    t0 = max(t1(1),t2(1));
    tf = min(t1(end),t2(end));

    if tf<=t0
        error("CH1 and CH2 time ranges do not overlap.");
    end

    t = (t0:Ts:tf).';

    syncV = interp1(t1,y1,t,"nearest");
    outV = interp1(t2,y2,t,"linear");

    good = isfinite(syncV) & isfinite(outV);

    t = t(good);
    syncV = syncV(good);
    outV = outV(good);
end

function gap = estimateGroupGap(edgeTimes,Ts)

    d = diff(edgeTimes);
    d = d(d>2*Ts);

    if isempty(d)
        gap = 10*Ts;
        return;
    end

    if numel(d)<3
        gap = max(5*Ts,2*min(d));
        return;
    end

    ds = sort(d);

    ratios = ds(2:end)./max(ds(1:end-1),eps);

    [r,idx] = max(ratios);

    if r>=3
        gap = sqrt(ds(idx)*ds(idx+1));
    else
        gap = max(5*Ts,3*median(ds));
    end

    gap = max(gap,3*Ts);
end

function [eventTimes,endTimes,count] = groupEdges(edgeTimes,gap)

    newGroup = [true;diff(edgeTimes)>gap];

    starts = find(newGroup);
    stops = [starts(2:end)-1;numel(edgeTimes)];

    eventTimes = edgeTimes(starts);
    endTimes = edgeTimes(stops);
    count = stops-starts+1;
end

function level = nearestCommandLevel(measured,levels,tol)

    [distance,idx] = min(abs(levels-measured));

    if distance<=tol
        level = levels(idx);
    else
        level = NaN;
    end
end

function label = commandLabel(a,b)

    label = levelText(a) + "_to_" + levelText(b);
end

function s = levelText(x)

    if x>0
        s = "+" + string(round(x,6));
    elseif x<0
        s = string(round(x,6));
    else
        s = "0";
    end
end

function [peak,t10,t90,t1090,delay,settling,overshoot] = ...
    transitionMetrics(ts,ys,te,y0,yf,lowFrac,highFrac, ...
    delayFrac,settleFrac,Ts)

    delta = yf-y0;
    s = sign(delta);

    z = s.*(ys-y0);
    target = abs(delta);

    t10abs = crossing(ts,z,lowFrac*target);
    t90abs = crossing(ts,z,highFrac*target);
    tDelayAbs = crossing(ts,z,delayFrac*target);

    t10 = t10abs;
    t90 = t90abs;

    if isfinite(t10abs) && isfinite(t90abs)
        t1090 = t90abs-t10abs;
    else
        t1090 = NaN;
    end

    if isfinite(tDelayAbs)
        delay = tDelayAbs-te;
    else
        delay = NaN;
    end

    [peakZ,idxPeak] = max(z);
    peak = ys(idxPeak);

    overshoot = max(0,100*(peakZ-target)/max(eps,target));

    band = settleFrac*target;
    e = abs(ys-yf);

    holdSamples = max(10,round(0.15*numel(ys)));

    settling = NaN;

    for i = 1:(numel(ys)-holdSamples+1)

        j = i+holdSamples-1;

        if all(e(i:j)<=band)
            settling = ts(i)-te;
            break;
        end
    end
end

function tc = crossing(t,z,level)

    idx = find(z>=level,1,"first");

    if isempty(idx)
        tc = NaN;
        return;
    end

    if idx==1
        tc = t(1);
        return;
    end

    z1 = z(idx-1);
    z2 = z(idx);

    t1 = t(idx-1);
    t2 = t(idx);

    if z2==z1
        tc = t2;
    else
        alpha = (level-z1)/(z2-z1);
        tc = t1 + alpha*(t2-t1);
    end
end

function plotEventMetrics(ax,t,y,row,lowFrac,highFrac)

    te = row.SyncStart_s;
    tf = row.AnalysisEnd_s;

    mask = t>=te & t<=tf;

    tr = t(mask)-te;
    yr = y(mask);

    plot(ax,tr,yr,"LineWidth",1.3);
    hold(ax,"on");

    y0 = row.Initial_mA;
    yf = row.Final_mA;
    delta = yf-y0;

    y10 = y0+lowFrac*delta;
    y90 = y0+highFrac*delta;

    xline(ax,0,"--","SYNC");
    yline(ax,y10,":","10%");
    yline(ax,y90,":","90%");
    yline(ax,yf,"--","plateau");

    if isfinite(row.T10_s)
        plot(ax,row.T10_s-te,y10,"o");
    end

    if isfinite(row.T90_s)
        plot(ax,row.T90_s-te,y90,"o");
    end

    if isfinite(row.Delay_s)
        xline(ax,row.Delay_s,":","delay");
    end

    if isfinite(row.Settling_s)
        xline(ax,row.Settling_s,":","settling");
    end

    grid(ax,"on");
    xlabel(ax,"Time from grouped SYNC event (s)");
    ylabel(ax,"Current (mA)");

    title(ax,sprintf("Event %d: %s",row.Event,row.TransitionLabel));

    hold(ax,"off");
end

function events = chooseIDEvents(metrics,family,A)

    good = metrics.Significant & ...
           isfinite(metrics.CommandInitial_mA) & ...
           isfinite(metrics.CommandFinal_mA);

    switch family

        case "0_to_+10"
            events = find(good & ...
                metrics.CommandInitial_mA==0 & ...
                metrics.CommandFinal_mA==A);

        case "+10_to_0"
            events = find(good & ...
                metrics.CommandInitial_mA==A & ...
                metrics.CommandFinal_mA==0);

        case "0_to_-10"
            events = find(good & ...
                metrics.CommandInitial_mA==0 & ...
                metrics.CommandFinal_mA==-A);

        case "-10_to_0"
            events = find(good & ...
                metrics.CommandInitial_mA==-A & ...
                metrics.CommandFinal_mA==0);

        case "all_10mA_steps"
            events = find(good & ( ...
                abs(metrics.CommandStep_mA-A)<1e-9 | ...
                abs(metrics.CommandStep_mA+A)<1e-9 ));

        otherwise
            error("Unknown ID_TRANSITION_FAMILY.");
    end
end

function [fitPct,rmse] = fitMetric(y,yhat)

    y = y(:);
    yhat = yhat(:);

    good = isfinite(y) & isfinite(yhat);

    y = y(good);
    yhat = yhat(good);

    e = y-yhat;

    rmse = sqrt(mean(e.^2));

    denom = norm(y-mean(y));

    if denom<=eps
        fitPct = NaN;
    else
        fitPct = 100*(1-norm(e)/denom);
    end
end

function printTF(model)

    try
        disp(tf(model));
    catch
        disp(model);
    end
end

function q = pct(x,p)

    x = x(isfinite(x));

    if isempty(x)
        q = NaN;
        return;
    end

    x = sort(x(:));

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
