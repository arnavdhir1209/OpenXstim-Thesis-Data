%% BatchOpenXstimAnalysis.m
% Batch analysis for OpenXstim Phase 0 characterisation
%
% Designed for a folder containing multiple "Attempt ..." subfolders with
% CH1.CSV and CH2.CSV files.
%
% RESISTOR ATTEMPTS
%   CH1 = Arduino/DAC SYNC timing reference
%   CH2 = voltage across 1 kOhm resistor
%
% RC ATTEMPTS
%   Both channels are analogue load measurements. No SYNC is assumed.
%   By default:
%       CH1 = resistor voltage
%       CH2 = capacitor voltage
%   Change RC_RES_CHANNEL / RC_CAP_CHANNEL below if needed.
%
% This script requires only base MATLAB. It does NOT require System
% Identification Toolbox. Low-order models are fitted with fminsearch.
%
% Main outputs:
%   1. Per-attempt summary table
%   2. Commanded-current calibration curve
%   3. Rise/fall timing vs command amplitude
%   4. Repeatability statistics
%   5. Long-hold droop analysis
%   6. Normalized P1 / P1D / P2 model fitting
%   7. Exploratory RC analysis with explicit measurement-validity warnings
%
% IMPORTANT:
%   The input "command current" means the nominal current setting used in
%   your firmware. If the old calibration constant is wrong, the measured
%   current may be much smaller. That is not corrected away automatically.
%
%   For resistor tests:
%       measured current = V_R / R
%
%   For RC tests, separate oscilloscope channel ground clips are normally
%   internally common on a bench scope. If the two probes were connected
%   across different floating elements of a series RC network, the scope
%   grounding itself may have changed the circuit. Treat those attempts as
%   exploratory unless the measurement topology is verified.

clear;
clc;
close all;

%% USER SETTINGS

% ------------------------------------------------------------------------
% Folder structure
% ------------------------------------------------------------------------
ROOT_FOLDER = getScriptFolder();

CH1_NAME = "CH1.CSV";
CH2_NAME = "CH2.CSV";

RESULTS_FOLDER = fullfile(ROOT_FOLDER, "AnalysisResults");

% Attempts to ignore completely. Add known bad early attempts here.
IGNORE_ATTEMPTS = [];      % example: [1 2 3]

% User stated attempts 20 and 21 are the series-RC experiments.
RC_ATTEMPTS = [20 21];

% ------------------------------------------------------------------------
% Known load values
% ------------------------------------------------------------------------
RESISTOR_OHM = 1000;
RC_R_OHM = 1000;
RC_C_F = 330e-9;

% RC channel assignment.
% Change if your wiring notes show the opposite assignment.
RC_RES_CHANNEL = 1;   % CH1 by default
RC_CAP_CHANNEL = 2;   % CH2 by default

% ------------------------------------------------------------------------
% Nominal command current parsing
% ------------------------------------------------------------------------
% The script tries to read values such as "5mA", "10 mA", "15mA", "20mA"
% from each attempt folder path.
%
% If some folders do not contain the current in their name, enter manual
% mappings here as:
%
%   [attemptNumber, nominalCurrent_mA]
%
% Example:
% MANUAL_COMMAND_MAP = [
%      8,  5
%      9, 10
%     10, 15
%     11, 20
% ];
%
MANUAL_COMMAND_MAP = [];

% ------------------------------------------------------------------------
% SYNC timing for resistor attempts
% ------------------------------------------------------------------------
SYNC_EDGE_TYPE = "rising";      % "rising", "falling", "largest"
SYNC_THRESHOLD_V = NaN;         % NaN = robust automatic threshold

% Associate a SYNC edge with an output change by looking this far after it.
SYNC_SCORE_WINDOW_S = 12e-6;

% Two associated events separated by more than this are interpreted as a
% long ON/OFF hold rather than a single isolated step.
LONG_HOLD_MIN_S = 40e-6;

% ------------------------------------------------------------------------
% Fast transition metrics
% ------------------------------------------------------------------------
ONSET_FRACTION = 0.05;
LOW_FRACTION = 0.10;
HIGH_FRACTION = 0.90;
SETTLING_BAND = 0.02;

PRE_BASELINE_S = 5e-6;
FAST_PLATEAU_START_S = 8e-6;
FAST_PLATEAU_END_S = 15e-6;

% ------------------------------------------------------------------------
% Long-hold droop
% ------------------------------------------------------------------------
% Evaluate current after the fast transient has settled.
DROOP_REFERENCE_DELAY_S = 12e-6;

DROOP_CHECK_TIMES_S = [20 50 100 200 500] * 1e-6;

% ------------------------------------------------------------------------
% Low-order dynamic model fitting
% ------------------------------------------------------------------------
% Prefer 10 mA captures if available.
MODEL_COMMAND_MA = 10;

% Decimate/interpolate model traces to this sample interval. This keeps
% model fitting lightweight even when the scope acquired at GHz rates.
MODEL_TS_S = 50e-9;

FIT_P2D_EXPLORATORY = false;  % optional second-order + delay

% ------------------------------------------------------------------------
% RC exploratory analysis
% ------------------------------------------------------------------------
% If capacitor voltage exceeds this magnitude, flag possible compliance,
% probe-ratio, grounding, or scaling problems.
RC_SUSPICIOUS_VOLTAGE_V = 100;

% The capacitor estimate C = I / (dVc/dt) is only calculated where current
% is appreciable and the capacitor voltage has a finite slope.
RC_MIN_CURRENT_A = 1e-6;

%% FIND ALL DATASETS

if ~exist(RESULTS_FOLDER,'dir')
    mkdir(RESULTS_FOLDER);
end

ch1Files = dir(fullfile(ROOT_FOLDER, "**", CH1_NAME));

datasets = struct([]);
n = 0;

for k = 1:numel(ch1Files)

    folder = ch1Files(k).folder;
    ch2Path = fullfile(folder, CH2_NAME);

    if ~isfile(ch2Path)
        continue;
    end

    attempt = parseAttemptNumber(folder);

    if ~isnan(attempt) && ismember(attempt, IGNORE_ATTEMPTS)
        continue;
    end

    n = n + 1;

    datasets(n).folder = folder;
    datasets(n).ch1Path = fullfile(folder, CH1_NAME);
    datasets(n).ch2Path = ch2Path;
    datasets(n).attempt = attempt;
    datasets(n).nominal_mA = parseNominalCurrent(folder, attempt, MANUAL_COMMAND_MAP);

    if ~isnan(attempt) && ismember(attempt, RC_ATTEMPTS)
        datasets(n).type = "RC";
    else
        datasets(n).type = "RESISTOR";
    end
end

fprintf('\n============================================================\n');
fprintf('OPENXSTIM BATCH ANALYSIS\n');
fprintf('============================================================\n');
fprintf('Root folder: %s\n', ROOT_FOLDER);
fprintf('Datasets found: %d\n\n', numel(datasets));

if isempty(datasets)
    error(['No folders containing both CH1.CSV and CH2.CSV were found ' ...
           'under the script folder.']);
end

%% PROCESS RESISTOR DATASETS

rows = struct([]);
resistorResults = struct([]);
rcResults = struct([]);

rCount = 0;
rcCount = 0;
rowCount = 0;

for k = 1:numel(datasets)

    ds = datasets(k);

    fprintf('\n------------------------------------------------------------\n');
    fprintf('Folder: %s\n', ds.folder);
    fprintf('Attempt: %s\n', numberOrUnknown(ds.attempt));
    fprintf('Type: %s\n', ds.type);
    fprintf('Nominal command: %s mA\n', numberOrUnknown(ds.nominal_mA));

    try
        [t1, y1] = loadScopeCSV(ds.ch1Path);
        [t2, y2] = loadScopeCSV(ds.ch2Path);

        [t, ch1, ch2, Ts] = alignChannels(t1,y1,t2,y2);
        t = t - t(1);

        if ds.type == "RESISTOR"

            rCount = rCount + 1;

            R = analyseResistorDataset( ...
                t, ch1, ch2, Ts, ds, ...
                RESISTOR_OHM, ...
                SYNC_EDGE_TYPE, SYNC_THRESHOLD_V, ...
                SYNC_SCORE_WINDOW_S, LONG_HOLD_MIN_S, ...
                PRE_BASELINE_S, ...
                FAST_PLATEAU_START_S, FAST_PLATEAU_END_S, ...
                ONSET_FRACTION, LOW_FRACTION, HIGH_FRACTION, ...
                SETTLING_BAND, ...
                DROOP_REFERENCE_DELAY_S, DROOP_CHECK_TIMES_S);

            resistorResults(rCount) = R;

            rowCount = rowCount + 1;
            rows(rowCount) = summaryRowFromResistor(R);

        else

            rcCount = rcCount + 1;

            RC = analyseRCDataset( ...
                t,ch1,ch2,Ts,ds, ...
                RC_RES_CHANNEL,RC_CAP_CHANNEL, ...
                RC_R_OHM,RC_C_F, ...
                RC_SUSPICIOUS_VOLTAGE_V, ...
                RC_MIN_CURRENT_A);

            rcResults(rcCount) = RC;

            rowCount = rowCount + 1;
            rows(rowCount) = summaryRowFromRC(RC);
        end

    catch ME

        warning('Failed to process "%s": %s', ds.folder, ME.message);

        rowCount = rowCount + 1;

        rows(rowCount).Attempt = ds.attempt;
        rows(rowCount).Type = ds.type;
        rows(rowCount).Nominal_mA = ds.nominal_mA;
        rows(rowCount).Direction = "FAILED";
        rows(rowCount).MeasuredStep_mA = NaN;
        rows(rowCount).Delay_us = NaN;
        rows(rowCount).T10_90_us = NaN;
        rows(rowCount).Settling_us = NaN;
        rows(rowCount).Overshoot_pct = NaN;
        rows(rowCount).Hold_us = NaN;
        rows(rowCount).Droop_pct = NaN;
        rows(rowCount).PeakAbsVoltage_V = NaN;
        rows(rowCount).QualityFlag = string(ME.message);
        rows(rowCount).Folder = string(ds.folder);
    end
end

summaryTable = struct2table(rows);

summaryPath = fullfile(RESULTS_FOLDER,"AttemptSummary.csv");
writetable(summaryTable,summaryPath);

fprintf('\nSaved per-attempt summary:\n%s\n',summaryPath);

%% RESISTOR SUMMARY TABLES

if ~isempty(resistorResults)

    % Build a flat table explicitly for compatibility across MATLAB versions.
    rr = repmat(struct(), numel(resistorResults), 1);
    for k = 1:numel(resistorResults)
        rr(k) = resistorFlatRow(resistorResults(k));
    end
    resistorTable = struct2table(rr);

    writetable(resistorTable, ...
        fullfile(RESULTS_FOLDER,"ResistorMetrics.csv"));

    fprintf('\n============================================================\n');
    fprintf('RESISTOR DATA SUMMARY\n');
    fprintf('============================================================\n');

    disp(resistorTable(:,{ ...
        'Attempt','Nominal_mA','Direction','MeasuredStep_mA', ...
        'Delay_us','T10_90_us','Settling_us','Overshoot_pct', ...
        'Hold_us','Droop_pct'}));

    %% CALIBRATION CURVE

    fastMask = ...
        isfinite(resistorTable.Nominal_mA) & ...
        isfinite(resistorTable.MeasuredStep_mA) & ...
        resistorTable.Hold_us < 40;

    calT = resistorTable(fastMask,:);

    if height(calT) >= 2

        x = calT.Nominal_mA;
        y = calT.MeasuredStep_mA;

        p = polyfit(x,y,1);

        yhat = polyval(p,x);

        ssRes = sum((y-yhat).^2);
        ssTot = sum((y-mean(y)).^2);
        R2 = 1 - ssRes/max(eps,ssTot);

        fprintf('\nCalibration fit from nominal firmware current to measured current:\n');
        fprintf('  I_measured = %.9g * I_nominal + %.9g mA\n',p(1),p(2));
        fprintf('  R^2 = %.6f\n',R2);

        figure('Name','Current calibration');
        scatter(x,y,50,'filled');
        hold on;

        xx = linspace(min(x),max(x),200);
        plot(xx,polyval(p,xx),'LineWidth',1.4);

        grid on;
        xlabel('Nominal firmware current setting (mA)');
        ylabel('Measured step current through 1 kOhm (mA)');
        title(sprintf('OpenXstim current calibration, R^2 = %.4f',R2));
        hold off;

        saveas(gcf,fullfile(RESULTS_FOLDER,"CalibrationCurve.png"));

        calibration = table( ...
            p(1),p(2),R2, ...
            'VariableNames',{'Slope','Intercept_mA','R2'});

        writetable(calibration, ...
            fullfile(RESULTS_FOLDER,"CalibrationFit.csv"));

    else
        warning('Not enough command-labelled fast resistor captures for calibration fit.');
        p = [NaN NaN];
        R2 = NaN;
    end

    %% DYNAMICS VS COMMAND AMPLITUDE

    dynMask = fastMask & ...
        isfinite(resistorTable.T10_90_us) & ...
        isfinite(resistorTable.Delay_us);

    dynT = resistorTable(dynMask,:);

    if height(dynT) >= 2

        figure('Name','Dynamics vs command current');

        tiledlayout(2,1);

        nexttile;
        scatter(dynT.Nominal_mA,dynT.T10_90_us,45,'filled');
        grid on;
        xlabel('Nominal firmware current (mA)');
        ylabel('10-90% time (us)');
        title('Transition speed vs command amplitude');

        nexttile;
        scatter(dynT.Nominal_mA,dynT.Delay_us,45,'filled');
        grid on;
        xlabel('Nominal firmware current (mA)');
        ylabel('SYNC-to-5% delay (us)');
        title('Apparent delay vs command amplitude');

        saveas(gcf,fullfile(RESULTS_FOLDER,"DynamicsVsCommand.png"));
    end

    %% REPEATABILITY STATISTICS

    validCmds = unique(resistorTable.Nominal_mA(isfinite(resistorTable.Nominal_mA)));

    repRows = [];

    for c = validCmds.'

        for dir = ["rise","fall"]

            mask = ...
                resistorTable.Nominal_mA == c & ...
                resistorTable.Direction == dir & ...
                resistorTable.Hold_us < 40 & ...
                isfinite(resistorTable.MeasuredStep_mA);

            T = resistorTable(mask,:);

            if height(T) == 0
                continue;
            end

            rr0.Command_mA = c;
            rr0.Direction = dir;
            rr0.N = height(T);

            rr0.StepMean_mA = mean(T.MeasuredStep_mA,'omitnan');
            rr0.StepStd_mA = std(T.MeasuredStep_mA,'omitnan');

            rr0.DelayMean_us = mean(T.Delay_us,'omitnan');
            rr0.DelayStd_us = std(T.Delay_us,'omitnan');

            rr0.T1090Mean_us = mean(T.T10_90_us,'omitnan');
            rr0.T1090Std_us = std(T.T10_90_us,'omitnan');

            if isempty(repRows)
                repRows = rr0;
            else
                repRows(end+1) = rr0; %#ok<SAGROW>
            end
        end
    end

    if ~isempty(repRows)
        repeatabilityTable = struct2table(repRows);
        writetable(repeatabilityTable, ...
            fullfile(RESULTS_FOLDER,"Repeatability.csv"));

        fprintf('\nRepeatability:\n');
        disp(repeatabilityTable);
    end

    %% LONG-HOLD DROOP

    longIdx = find(arrayfun(@(x)x.isLongHold,resistorResults));

    if ~isempty(longIdx)

        fprintf('\n============================================================\n');
        fprintf('LONG-HOLD DROOP\n');
        fprintf('============================================================\n');

        droopRows = [];

        for ii = 1:numel(longIdx)

            R = resistorResults(longIdx(ii));

            dr.Attempt = R.attempt;
            dr.Nominal_mA = R.nominal_mA;
            dr.Hold_us = 1e6*R.holdDuration_s;
            dr.ReferenceCurrent_mA = R.droop.referenceCurrent_mA;
            dr.EndCurrent_mA = R.droop.endCurrent_mA;
            dr.Droop_pct = R.droop.droop_pct;
            dr.DroopTau_us = 1e6*R.droop.tau_s;

            if isempty(droopRows)
                droopRows = dr;
            else
                droopRows(end+1) = dr; %#ok<SAGROW>
            end

            plotLongHold(R,RESULTS_FOLDER);
        end

        droopTable = struct2table(droopRows);
        writetable(droopTable, ...
            fullfile(RESULTS_FOLDER,"LongHoldDroop.csv"));

        disp(droopTable);
    end

    %% LOW-ORDER MODEL FITTING

    [fitTrace,fitInfo] = buildRepresentativeModelTrace( ...
        resistorResults,MODEL_COMMAND_MA,MODEL_TS_S);

    if ~isempty(fitTrace)

        fprintf('\n============================================================\n');
        fprintf('LOW-ORDER DYNAMIC MODEL FITTING\n');
        fprintf('============================================================\n');
        fprintf('Representative command: %.6g mA\n',MODEL_COMMAND_MA);
        fprintf('Captures used: %d\n',fitInfo.N);

        modelFits = fitLowOrderModels( ...
            fitTrace.t,fitTrace.y,FIT_P2D_EXPLORATORY);

        disp(modelFits.table);

        writetable(modelFits.table, ...
            fullfile(RESULTS_FOLDER,"LowOrderModelFits.csv"));

        figure('Name','Low-order model comparison');

        plot(fitTrace.t*1e6,fitTrace.y,'LineWidth',1.6);
        hold on;

        plot(fitTrace.t*1e6,modelFits.P1.yhat,'LineWidth',1.2);
        plot(fitTrace.t*1e6,modelFits.P1D.yhat,'LineWidth',1.2);
        plot(fitTrace.t*1e6,modelFits.P2.yhat,'LineWidth',1.2);

        if FIT_P2D_EXPLORATORY
            plot(fitTrace.t*1e6,modelFits.P2D.yhat,'LineWidth',1.2);
            legend('Measured normalized response','P1','P1D','P2','P2D', ...
                'Location','best');
        else
            legend('Measured normalized response','P1','P1D','P2', ...
                'Location','best');
        end

        grid on;
        xlabel('Time from command (us)');
        ylabel('Normalized current response');
        title(sprintf('Low-order model comparison at nominal %.0f mA',MODEL_COMMAND_MA));
        hold off;

        saveas(gcf,fullfile(RESULTS_FOLDER,"LowOrderModelComparison.png"));

        fprintf('\nModel equations, normalized dynamic gain:\n');

        fprintf('\nP1:\n');
        fprintf('  G(s) = %.8g / (%.8g s + 1)\n', ...
            modelFits.P1.K,modelFits.P1.tau);

        fprintf('\nP1D:\n');
        fprintf('  G(s) = %.8g exp(-%.8g s) / (%.8g s + 1)\n', ...
            modelFits.P1D.K,modelFits.P1D.Td,modelFits.P1D.tau);

        fprintf('\nP2:\n');
        fprintf(['  G(s) = %.8g / ((%.8g s + 1)(%.8g s + 1))\n'], ...
            modelFits.P2.K,modelFits.P2.tau1,modelFits.P2.tau2);

        if all(isfinite(p))
            fprintf('\nUsing the calibration slope, an approximate effective\n');
            fprintf('nominal-command -> actual-current DC gain is %.8g.\n',p(1));
            fprintf(['Multiply the normalized model numerator by this gain if\n' ...
                     'you deliberately want the stale firmware calibration to\n' ...
                     'remain inside the black-box plant definition.\n']);
        end

    else
        warning('Could not build a representative fast transition for model fitting.');
    end
end

%% RC EXPLORATORY ANALYSIS

if ~isempty(rcResults)

    fprintf('\n============================================================\n');
    fprintf('SERIES-RC EXPLORATORY ANALYSIS\n');
    fprintf('============================================================\n');

    rcRows = repmat(struct(),numel(rcResults),1);

    for k = 1:numel(rcResults)

        RC = rcResults(k);

        rcRows(k).Attempt = RC.attempt;
        rcRows(k).PeakAbsVr_V = RC.peakAbsVr_V;
        rcRows(k).PeakAbsVc_V = RC.peakAbsVc_V;
        rcRows(k).PeakAbsCurrent_mA = 1000*RC.peakAbsCurrent_A;
        rcRows(k).EstimatedC_nF = 1e9*RC.Cestimate_F;
        rcRows(k).ExpectedC_nF = 1e9*RC.expectedC_F;
        rcRows(k).DecayTau_ms = 1e3*RC.decayTau_s;
        rcRows(k).QualityFlag = RC.qualityFlag;

        plotRCResult(RC,RESULTS_FOLDER);
    end

    rcTable = struct2table(rcRows);

    writetable(rcTable,fullfile(RESULTS_FOLDER,"RC_ExploratoryMetrics.csv"));

    disp(rcTable);

    fprintf('\nIMPORTANT RC MEASUREMENT NOTE:\n');
    fprintf(['A standard bench oscilloscope normally has common, earth-referenced\n' ...
             'channel grounds. Probing separately across the resistor and\n' ...
             'capacitor in a floating series network can short two circuit\n' ...
             'nodes together through the oscilloscope. Therefore attempts 20\n' ...
             'and 21 should not be used as quantitative validation of the RC\n' ...
             'model until the probe-ground topology is confirmed.\n']);
end

%% FINAL NOTES

fprintf('\n============================================================\n');
fprintf('ANALYSIS COMPLETE\n');
fprintf('============================================================\n');
fprintf('Results written to:\n%s\n\n',RESULTS_FOLDER);

fprintf('Recommended interpretation order:\n');
fprintf('  1. Use resistor fast steps for dynamic model structure.\n');
fprintf('  2. Use current sweep for nominal-command calibration and linearity.\n');
fprintf('  3. Use repeated 10 mA captures for repeatability and validation.\n');
fprintf('  4. Treat long-hold resistor data as a separate droop phenomenon.\n');
fprintf('  5. Treat attempts 20/21 RC data as exploratory until grounding is verified.\n');

%% =======================================================================
% LOCAL FUNCTIONS
% ========================================================================

function R = analyseResistorDataset( ...
    t,syncV,loadV,Ts,ds,Rohm, ...
    syncEdgeType,userThreshold,scoreWindow,longHoldMin, ...
    preBaseline,plateauStart,plateauEnd, ...
    onsetFrac,lowFrac,highFrac,settlingBand, ...
    droopReferenceDelay,droopCheckTimes)

    current_mA = 1000*loadV/Rohm;

    [syncEdges,threshold] = findSyncEdges(t,syncV,syncEdgeType,userThreshold);

    if isempty(syncEdges)
        error('No usable SYNC edges detected.');
    end

    % Score each SYNC edge by output change shortly after the edge.
    scores = zeros(size(syncEdges));
    signedChanges = zeros(size(syncEdges));

    for i = 1:numel(syncEdges)

        te = syncEdges(i);

        pre = current_mA(t >= te-preBaseline & t < te);
        post = current_mA(t > te+0.5e-6 & t <= te+scoreWindow);

        if numel(pre) < 3 || numel(post) < 3
            scores(i) = 0;
            signedChanges(i) = 0;
            continue;
        end

        y0 = median(pre,'omitnan');
        y1 = median(post(end-max(2,round(numel(post)*0.25))+1:end),'omitnan');

        signedChanges(i) = y1-y0;
        scores(i) = abs(signedChanges(i));
    end

    maxScore = max(scores);

    if maxScore <= 0
        error('SYNC edges were found but none are associated with output change.');
    end

    associated = find(scores >= 0.20*maxScore);

    % Keep only distinct, meaningful events.
    associatedEdges = syncEdges(associated);
    associatedChanges = signedChanges(associated);

    [associatedEdges,ord] = sort(associatedEdges);
    associatedChanges = associatedChanges(ord);

    % Collapse edges closer than 2 us by retaining the larger output-change score.
    keep = true(size(associatedEdges));

    for i = 2:numel(associatedEdges)
        if associatedEdges(i)-associatedEdges(i-1) < 2e-6
            idxA = associated(i-1);
            idxB = associated(i);
            if scores(idxB) >= scores(idxA)
                keep(i-1) = false;
            else
                keep(i) = false;
            end
        end
    end

    associatedEdges = associatedEdges(keep);
    associatedChanges = associatedChanges(keep);

    if isempty(associatedEdges)
        error('No meaningful output transition could be associated with SYNC.');
    end

    % Choose the largest transition as primary.
    [~,primaryLocal] = max(abs(associatedChanges));
    te = associatedEdges(primaryLocal);

    % Look for a second large event after the primary.
    later = find(associatedEdges > te + longHoldMin);

    isLongHold = false;
    offTime = NaN;

    if ~isempty(later)
        [~,jrel] = max(abs(associatedChanges(later)));
        j = later(jrel);
        offTime = associatedEdges(j);
        isLongHold = true;
    end

    % Determine direction and fast metrics.
    preMask = t >= te-preBaseline & t < te;

    if isLongHold
        plateauStop = min(te+plateauEnd,offTime-2*Ts);
    else
        plateauStop = min(te+plateauEnd,t(end));
    end

    plateauStartAbs = min(te+plateauStart,plateauStop-3*Ts);

    postMask = t >= plateauStartAbs & t <= plateauStop;

    if nnz(preMask)<5 || nnz(postMask)<5
        % Fallback to final 20% of available post-event data.
        postAll = find(t > te);
        if isLongHold
            postAll = postAll(t(postAll)<offTime);
        end
        nTail = max(5,round(0.2*numel(postAll)));
        postIdx = postAll(end-nTail+1:end);
    else
        postIdx = find(postMask);
    end

    y0 = median(current_mA(preMask),'omitnan');
    yf = median(current_mA(postIdx),'omitnan');

    delta = yf-y0;
    direction = sign(delta);

    if direction == 0
        error('Detected transition has zero measured step.');
    end

    if direction > 0
        dirText = "rise";
    else
        dirText = "fall";
    end

    analysisEnd = min(t(end),te+max(20e-6,plateauEnd));

    if isLongHold
        analysisEnd = min(analysisEnd,offTime-2*Ts);
    end

    idx = t>=te-preBaseline & t<=analysisEnd;

    tr = t(idx)-te;
    yr = current_mA(idx);

    yincr = direction*(yr-y0);
    stepMag = abs(delta);

    metrics = transitionMetrics( ...
        tr,yincr,stepMag,onsetFrac,lowFrac,highFrac,settlingBand,Ts);

    % Long-hold droop analysis.
    droop = emptyDroop();

    if isLongHold

        holdDuration = offTime-te;

        droop = analyseDroop( ...
            t,current_mA,te,offTime,direction,y0, ...
            droopReferenceDelay,droopCheckTimes);

    else
        holdDuration = NaN;
    end

    R.attempt = ds.attempt;
    R.folder = ds.folder;
    R.nominal_mA = ds.nominal_mA;

    R.t = t;
    R.syncV = syncV;
    R.loadV = loadV;
    R.current_mA = current_mA;
    R.Ts = Ts;

    R.syncThreshold = threshold;
    R.syncEdges = syncEdges;
    R.eventTime = te;
    R.offTime = offTime;

    R.initial_mA = y0;
    R.final_mA = yf;
    R.measuredStep_mA = stepMag;
    R.direction = dirText;

    R.metrics = metrics;

    R.isLongHold = isLongHold;
    R.holdDuration_s = holdDuration;
    R.droop = droop;

    % Plot each fast transition.
    figure('Visible','off');
    plot(tr*1e6,yincr,'LineWidth',1.2);
    hold on;
    xline(0,'--','SYNC command');
    yline(0.1*stepMag,':','10%');
    yline(0.9*stepMag,':','90%');
    yline(stepMag,'--','plateau');
    grid on;
    xlabel('Time from command (us)');
    ylabel('Incremental measured current (mA)');
    title(sprintf('Attempt %s, %s, nominal %s mA', ...
        numberOrUnknown(ds.attempt),dirText,numberOrUnknown(ds.nominal_mA)));
    hold off;

    out = fullfile(getScriptFolder(),"AnalysisResults", ...
        sprintf('Attempt_%s_FastTransition.png',safeNumber(ds.attempt)));
    saveas(gcf,out);
    close(gcf);
end

function RC = analyseRCDataset( ...
    t,ch1,ch2,Ts,ds,resCh,capCh,Rohm,Cexpected, ...
    suspiciousV,minCurrentA)

    channels = {ch1,ch2};

    Vr = channels{resCh};
    Vc = channels{capCh};

    current_A = Vr/Rohm;

    % No SYNC in these captures. Detect the main event from the resistor
    % voltage/current channel derivative.
    dI = [0;diff(current_A)]/Ts;

    % Smooth lightly with a moving average implemented using conv.
    nSmooth = max(3,round(0.2e-6/Ts));
    nSmooth = min(nSmooth,max(3,round(numel(dI)/100)));

    kernel = ones(nSmooth,1)/nSmooth;
    dIs = conv(dI,kernel,'same');

    [~,onIdx] = max(abs(dIs));

    eventTime = t(onIdx);
    tr = t-eventTime;

    peakAbsVr = max(abs(Vr),[],'omitnan');
    peakAbsVc = max(abs(Vc),[],'omitnan');
    peakAbsCurrent = max(abs(current_A),[],'omitnan');

    % Estimate capacitance only from regions where current is appreciable
    % and Vc has a useful slope. This is exploratory only.
    dVc = [0;diff(Vc)]/Ts;

    mask = ...
        abs(current_A) >= minCurrentA & ...
        abs(dVc) > max(1e-9,0.05*max(abs(dVc)));

    Cinst = current_A(mask)./dVc(mask);
    Cinst = Cinst(isfinite(Cinst) & Cinst>0);

    if numel(Cinst)>=10
        Cest = median(Cinst,'omitnan');
    else
        Cest = NaN;
    end

    % Generic exponential decay estimate after the largest |Vc| point.
    [~,peakIdx] = max(abs(Vc));

    decayTau = estimateExponentialTau(t,Vc,peakIdx);

    flags = strings(0,1);

    if peakAbsVc > suspiciousV || peakAbsVr > suspiciousV
        flags(end+1) = ...
            "Very high measured voltage: verify probe attenuation, compliance, and grounding.";
    end

    if isfinite(Cest)
        ratio = Cest/Cexpected;
        if ratio < 0.5 || ratio > 2
            flags(end+1) = ...
                "C estimate differs greatly from nominal 330 nF.";
        end
    end

    flags(end+1) = ...
        "No SYNC timing channel: event onset inferred from resistor-current derivative.";

    flags(end+1) = ...
        "Common-ground bench-scope measurement across separate series elements may have altered the circuit.";

    RC.attempt = ds.attempt;
    RC.folder = ds.folder;
    RC.nominal_mA = ds.nominal_mA;

    RC.t = t;
    RC.tr = tr;
    RC.Vr = Vr;
    RC.Vc = Vc;
    RC.current_A = current_A;
    RC.Ts = Ts;
    RC.eventTime = eventTime;

    RC.peakAbsVr_V = peakAbsVr;
    RC.peakAbsVc_V = peakAbsVc;
    RC.peakAbsCurrent_A = peakAbsCurrent;
    RC.Cestimate_F = Cest;
    RC.expectedC_F = Cexpected;
    RC.decayTau_s = decayTau;
    RC.qualityFlag = strjoin(flags," | ");
end

function d = analyseDroop( ...
    t,current_mA,onTime,offTime,direction,y0, ...
    referenceDelay,checkTimes)

    refTime = onTime+referenceDelay;

    refMask = ...
        t>=refTime & ...
        t<=min(refTime+5e-6,offTime-2e-6);

    if nnz(refMask)<3
        refIdx = find(t>=refTime,1,'first');
        reference = direction*(current_mA(refIdx)-y0);
    else
        reference = median(direction*(current_mA(refMask)-y0),'omitnan');
    end

    endMask = ...
        t>=max(refTime,offTime-10e-6) & ...
        t<offTime-1e-6;

    if nnz(endMask)>=3
        endCurrent = median(direction*(current_mA(endMask)-y0),'omitnan');
    else
        endIdx = find(t<offTime,1,'last');
        endCurrent = direction*(current_mA(endIdx)-y0);
    end

    droopPct = 100*(reference-endCurrent)/max(eps,abs(reference));

    sampleValues = nan(size(checkTimes));

    for k = 1:numel(checkTimes)
        tq = onTime+checkTimes(k);
        if tq < offTime && tq <= t(end)
            sampleValues(k) = interp1(t,direction*(current_mA-y0),tq,'linear');
        end
    end

    holdMask = t>=refTime & t<offTime-2e-6;

    th = t(holdMask)-refTime;
    yh = direction*(current_mA(holdMask)-y0);

    tau = fitDroopTau(th,yh);

    d.referenceCurrent_mA = reference;
    d.endCurrent_mA = endCurrent;
    d.droop_pct = droopPct;
    d.checkTimes_s = checkTimes;
    d.checkCurrents_mA = sampleValues;
    d.tau_s = tau;
end

function d = emptyDroop()
    d.referenceCurrent_mA = NaN;
    d.endCurrent_mA = NaN;
    d.droop_pct = NaN;
    d.checkTimes_s = [];
    d.checkCurrents_mA = [];
    d.tau_s = NaN;
end

function tau = fitDroopTau(t,y)

    tau = NaN;

    if numel(t)<20
        return;
    end

    % Model y(t) = c + A exp(-t/tau)
    y0 = y(1);
    tailStart = max(1,numel(y)-round(0.1*numel(y))+1);
    yend = median(y(tailStart:end),'omitnan');

    A0 = y0-yend;

    if abs(A0) < 0.01*max(eps,abs(y0))
        return;
    end

    tau0 = max(1e-6,0.5*(t(end)-t(1)));

    obj = @(q) mean(( ...
        (q(1) + q(2)*exp(-t/exp(q(3)))) - y).^2);

    q0 = [yend,A0,log(tau0)];

    q = fminsearch(obj,q0,optimset('Display','off'));

    tau = exp(q(3));
end

function metrics = transitionMetrics( ...
    t,y,stepMag,onsetFrac,lowFrac,highFrac,settlingBand,Ts)

    metrics.delay_s = crossingTime(t,y,onsetFrac*stepMag);
    metrics.t10_s = crossingTime(t,y,lowFrac*stepMag);
    metrics.t90_s = crossingTime(t,y,highFrac*stepMag);

    metrics.t10_90_s = metrics.t90_s-metrics.t10_s;

    [peak,idx] = max(y);

    metrics.peak_mA = peak;
    metrics.peakTime_s = t(idx);

    metrics.overshoot_pct = ...
        max(0,100*(peak-stepMag)/max(eps,stepMag));

    band = settlingBand*stepMag;
    err = abs(y-stepMag);

    holdSamples = max(3,round(0.5e-6/Ts));

    metrics.settling_s = NaN;

    startIdx = find(t>=max(0,metrics.t90_s),1,'first');

    for k = startIdx:max(startIdx,numel(y)-holdSamples+1)
        if k+holdSamples-1 > numel(y)
            break;
        end

        if all(err(k:k+holdSamples-1)<=band)
            metrics.settling_s = t(k);
            break;
        end
    end
end

function tc = crossingTime(t,y,level)

    valid = t>=0;
    t = t(valid);
    y = y(valid);

    i = find(y>=level,1,'first');

    if isempty(i)
        tc = NaN;
        return;
    end

    if i==1
        tc = t(1);
        return;
    end

    if y(i)==y(i-1)
        tc = t(i);
    else
        a = (level-y(i-1))/(y(i)-y(i-1));
        tc = t(i-1)+a*(t(i)-t(i-1));
    end
end

function [edges,threshold] = findSyncEdges(t,syncV,edgeType,userThreshold)

    lo = percentileLocal(syncV,5);
    hi = percentileLocal(syncV,95);

    if isnan(userThreshold)
        threshold = 0.5*(lo+hi);
    else
        threshold = userThreshold;
    end

    logic = syncV>threshold;

    rising = find(diff(logic)==1)+1;
    falling = find(diff(logic)==-1)+1;

    switch edgeType
        case "rising"
            idx = rising;
        case "falling"
            idx = falling;
        case "largest"
            [~,i] = max(abs(diff(syncV)));
            idx = i+1;
        otherwise
            error('Unknown SYNC_EDGE_TYPE.');
    end

    edges = t(idx);
end

function plotLongHold(R,resultsFolder)

    t0 = R.eventTime;
    t1 = R.offTime;

    mask = R.t>=t0-10e-6 & R.t<=min(R.t(end),t1+50e-6);

    tr = R.t(mask)-t0;
    y = sign(R.final_mA-R.initial_mA)*(R.current_mA(mask)-R.initial_mA);

    figure('Visible','off');
    plot(tr*1e6,y,'LineWidth',1.2);
    hold on;
    xline(0,'--','ON');
    xline((t1-t0)*1e6,'--','OFF');

    if isfinite(R.droop.referenceCurrent_mA)
        yline(R.droop.referenceCurrent_mA,':','droop reference');
    end

    grid on;
    xlabel('Time from ON command (us)');
    ylabel('Incremental current (mA)');
    title(sprintf('Attempt %s long-hold droop, %.2f%%', ...
        numberOrUnknown(R.attempt),R.droop.droop_pct));
    hold off;

    saveas(gcf,fullfile(resultsFolder, ...
        sprintf('Attempt_%s_LongHoldDroop.png',safeNumber(R.attempt))));
    close(gcf);
end

function plotRCResult(RC,resultsFolder)

    figure('Visible','off');

    tiledlayout(3,1);

    nexttile;
    plot(RC.tr*1e3,RC.Vr,'LineWidth',1);
    grid on;
    ylabel('V_R (V)');
    title(sprintf('RC Attempt %s: resistor voltage',numberOrUnknown(RC.attempt)));

    nexttile;
    plot(RC.tr*1e3,RC.Vc,'LineWidth',1);
    grid on;
    ylabel('V_C (V)');
    title('Capacitor voltage');

    nexttile;
    plot(RC.tr*1e3,1000*RC.current_A,'LineWidth',1);
    grid on;
    xlabel('Time from detected event (ms)');
    ylabel('I = V_R/R (mA)');
    title('Current inferred from resistor voltage');

    saveas(gcf,fullfile(resultsFolder, ...
        sprintf('Attempt_%s_RC.png',safeNumber(RC.attempt))));
    close(gcf);
end

function [trace,info] = buildRepresentativeModelTrace(results,command_mA,TsModel)

    trace = [];
    info.N = 0;

    candidates = [];

    for k = 1:numel(results)

        R = results(k);

        if R.isLongHold
            continue;
        end

        if ~isfinite(R.nominal_mA)
            continue;
        end

        if abs(R.nominal_mA-command_mA)>1e-9
            continue;
        end

        candidates(end+1) = k; %#ok<AGROW>
    end

    if isempty(candidates)
        % Fallback: use all short fast resistor transitions.
        candidates = find(~arrayfun(@(x)x.isLongHold,results));
    end

    if isempty(candidates)
        return;
    end

    tCommon = (-2e-6:TsModel:15e-6).';

    Y = nan(numel(tCommon),numel(candidates));

    validCount = 0;

    for i = 1:numel(candidates)

        R = results(candidates(i));

        direction = sign(R.final_mA-R.initial_mA);

        tr = R.t-R.eventTime;

        yn = direction*(R.current_mA-R.initial_mA)/max(eps,R.measuredStep_mA);

        yi = interp1(tr,yn,tCommon,'linear',NaN);

        if nnz(isfinite(yi)) < 0.9*numel(yi)
            continue;
        end

        validCount = validCount+1;
        Y(:,validCount) = yi;
    end

    Y = Y(:,1:validCount);

    if validCount==0
        return;
    end

    yMean = mean(Y,2,'omitnan');

    valid = isfinite(yMean);

    trace.t = tCommon(valid);
    trace.y = yMean(valid);

    info.N = validCount;
end

function fits = fitLowOrderModels(t,y,fitP2D)

    % Use only a small pre-command baseline plus full transient.
    y = y(:);
    t = t(:);

    P1 = fitP1(t,y);
    P1D = fitP1D(t,y);
    P2 = fitP2(t,y);

    Model = ["P1";"P1D";"P2"];
    Fit_pct = [P1.fit;P1D.fit;P2.fit];
    RMSE = [P1.rmse;P1D.rmse;P2.rmse];

    if fitP2D
        P2D = fitP2Dmodel(t,y);

        Model(end+1) = "P2D";
        Fit_pct(end+1) = P2D.fit;
        RMSE(end+1) = P2D.rmse;

        fits.P2D = P2D;
    end

    fits.P1 = P1;
    fits.P1D = P1D;
    fits.P2 = P2;

    fits.table = table(Model,Fit_pct,RMSE);
end

function M = fitP1(t,y)

    tau0 = 2e-6;
    K0 = 1;

    obj = @(q) mean((p1Response(t,exp(q(1)),exp(q(2)))-y).^2);

    q = fminsearch(obj,[log(tau0),log(K0)],optimset('Display','off'));

    M.tau = exp(q(1));
    M.K = exp(q(2));

    M.yhat = p1Response(t,M.tau,M.K);

    [M.fit,M.rmse] = fitStats(y,M.yhat);
end

function M = fitP1D(t,y)

    tau0 = 2e-6;
    Td0 = 0.8e-6;
    K0 = 1;

    obj = @(q) mean(( ...
        p1dResponse(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2);

    q = fminsearch(obj, ...
        [log(tau0),log(Td0),log(K0)],optimset('Display','off'));

    M.tau = exp(q(1));
    M.Td = exp(q(2));
    M.K = exp(q(3));

    M.yhat = p1dResponse(t,M.tau,M.Td,M.K);

    [M.fit,M.rmse] = fitStats(y,M.yhat);
end

function M = fitP2(t,y)

    tau10 = 2e-6;
    tau20 = 0.8e-6;
    K0 = 1;

    obj = @(q) mean(( ...
        p2Response(t,exp(q(1)),exp(q(2)),exp(q(3)))-y).^2);

    q = fminsearch(obj, ...
        [log(tau10),log(tau20),log(K0)],optimset('Display','off'));

    taus = sort([exp(q(1)),exp(q(2))],'descend');

    M.tau1 = taus(1);
    M.tau2 = taus(2);
    M.K = exp(q(3));

    M.yhat = p2Response(t,M.tau1,M.tau2,M.K);

    [M.fit,M.rmse] = fitStats(y,M.yhat);
end

function M = fitP2Dmodel(t,y)

    tau10 = 2e-6;
    tau20 = 0.8e-6;
    Td0 = 0.5e-6;
    K0 = 1;

    obj = @(q) mean(( ...
        p2dResponse(t,exp(q(1)),exp(q(2)),exp(q(3)),exp(q(4)))-y).^2);

    q = fminsearch(obj, ...
        [log(tau10),log(tau20),log(Td0),log(K0)], ...
        optimset('Display','off'));

    taus = sort([exp(q(1)),exp(q(2))],'descend');

    M.tau1 = taus(1);
    M.tau2 = taus(2);
    M.Td = exp(q(3));
    M.K = exp(q(4));

    M.yhat = p2dResponse(t,M.tau1,M.tau2,M.Td,M.K);

    [M.fit,M.rmse] = fitStats(y,M.yhat);
end

function y = p1Response(t,tau,K)

    y = zeros(size(t));

    idx = t>=0;
    tt = t(idx);

    y(idx) = K*(1-exp(-tt/tau));
end

function y = p1dResponse(t,tau,Td,K)

    y = zeros(size(t));

    idx = t>=Td;
    tt = t(idx)-Td;

    y(idx) = K*(1-exp(-tt/tau));
end

function y = p2Response(t,tau1,tau2,K)

    y = zeros(size(t));

    idx = t>=0;
    tt = t(idx);

    if abs(tau1-tau2) < 1e-4*max(tau1,tau2)
        tau = 0.5*(tau1+tau2);
        y(idx) = K*(1-exp(-tt/tau).*(1+tt/tau));
    else
        y(idx) = K*( ...
            1 - ...
            (tau1*exp(-tt/tau1)-tau2*exp(-tt/tau2))/(tau1-tau2));
    end
end

function y = p2dResponse(t,tau1,tau2,Td,K)

    y = zeros(size(t));

    idx = t>=Td;
    tt = t(idx)-Td;

    if abs(tau1-tau2) < 1e-4*max(tau1,tau2)
        tau = 0.5*(tau1+tau2);
        y(idx) = K*(1-exp(-tt/tau).*(1+tt/tau));
    else
        y(idx) = K*( ...
            1 - ...
            (tau1*exp(-tt/tau1)-tau2*exp(-tt/tau2))/(tau1-tau2));
    end
end

function [fitPct,rmse] = fitStats(y,yhat)

    e = y-yhat;

    rmse = sqrt(mean(e.^2));

    denom = norm(y-mean(y));

    fitPct = 100*(1-norm(e)/max(eps,denom));
end

function tau = estimateExponentialTau(t,y,peakIdx)

    tau = NaN;

    if peakIdx>=numel(y)-20
        return;
    end

    td = t(peakIdx:end)-t(peakIdx);
    yd = y(peakIdx:end);

    tailStart = max(1,numel(yd)-round(0.1*numel(yd))+1);
    baseline = median(yd(tailStart:end),'omitnan');

    amp = yd(1)-baseline;

    if abs(amp)<eps
        return;
    end

    yn = (yd-baseline)/amp;

    mask = yn>0.1 & yn<0.9 & td>0;

    if nnz(mask)<10
        return;
    end

    p = polyfit(td(mask),log(abs(yn(mask))),1);

    if p(1)<0
        tau = -1/p(1);
    end
end

function row = summaryRowFromResistor(R)

    row.Attempt = R.attempt;
    row.Type = "RESISTOR";
    row.Nominal_mA = R.nominal_mA;
    row.Direction = R.direction;

    row.MeasuredStep_mA = R.measuredStep_mA;
    row.Delay_us = 1e6*R.metrics.delay_s;
    row.T10_90_us = 1e6*R.metrics.t10_90_s;
    row.Settling_us = 1e6*R.metrics.settling_s;
    row.Overshoot_pct = R.metrics.overshoot_pct;

    row.Hold_us = 1e6*R.holdDuration_s;
    row.Droop_pct = R.droop.droop_pct;

    row.PeakAbsVoltage_V = max(abs(R.loadV));

    if R.isLongHold
        row.QualityFlag = "Long hold";
    else
        row.QualityFlag = "Fast isolated step";
    end

    row.Folder = string(R.folder);
end

function row = summaryRowFromRC(RC)

    row.Attempt = RC.attempt;
    row.Type = "RC";
    row.Nominal_mA = RC.nominal_mA;
    row.Direction = "N/A";

    row.MeasuredStep_mA = NaN;
    row.Delay_us = NaN;
    row.T10_90_us = NaN;
    row.Settling_us = NaN;
    row.Overshoot_pct = NaN;

    row.Hold_us = NaN;
    row.Droop_pct = NaN;

    row.PeakAbsVoltage_V = max(RC.peakAbsVc_V,RC.peakAbsVr_V);
    row.QualityFlag = RC.qualityFlag;
    row.Folder = string(RC.folder);
end

function row = resistorFlatRow(R)

    row.Attempt = R.attempt;
    row.Nominal_mA = R.nominal_mA;
    row.Direction = R.direction;

    row.Initial_mA = R.initial_mA;
    row.Final_mA = R.final_mA;
    row.MeasuredStep_mA = R.measuredStep_mA;

    row.Delay_us = 1e6*R.metrics.delay_s;
    row.T10_us = 1e6*R.metrics.t10_s;
    row.T90_us = 1e6*R.metrics.t90_s;
    row.T10_90_us = 1e6*R.metrics.t10_90_s;

    row.Settling_us = 1e6*R.metrics.settling_s;
    row.Overshoot_pct = R.metrics.overshoot_pct;

    row.Hold_us = 1e6*R.holdDuration_s;
    row.Droop_pct = R.droop.droop_pct;

    row.Folder = string(R.folder);
end

function [t,y] = loadScopeCSV(path)

    M = readmatrix(path);

    if isempty(M)
        error('No numeric data in %s',path);
    end

    numericPerRow = sum(isfinite(M),2);
    good = numericPerRow>=2;

    if ~any(good)
        error('Could not identify numeric oscilloscope block in %s',path);
    end

    d = diff([false;good;false]);
    starts = find(d==1);
    stops = find(d==-1)-1;

    [~,best] = max(stops-starts+1);

    M = M(starts(best):stops(best),:);

    M(:,all(~isfinite(M),1)) = [];

    if size(M,2)<2
        error('Expected at least 2 numeric columns in %s',path);
    end

    timeCol = autoTimeColumn(M);
    signalCol = autoSignalColumn(M,timeCol);

    t = M(:,timeCol);
    y = M(:,signalCol);

    good = isfinite(t)&isfinite(y);

    t = t(good);
    y = y(good);

    [t,ord] = sort(t);
    y = y(ord);

    [t,idx] = unique(t,'stable');
    y = y(idx);
end

function [t,y1,y2,Ts] = alignChannels(t1,y1,t2,y2)

    Ts = max(median(diff(t1)),median(diff(t2)));

    t0 = max(t1(1),t2(1));
    tf = min(t1(end),t2(end));

    if tf<=t0
        error('Channel time ranges do not overlap.');
    end

    t = (t0:Ts:tf).';

    y1 = interp1(t1,y1,t,'nearest');
    y2 = interp1(t2,y2,t,'linear');

    good = isfinite(y1)&isfinite(y2);

    t = t(good);
    y1 = y1(good);
    y2 = y2(good);
end

function c = autoTimeColumn(M)

    score = -inf(1,size(M,2));

    for k = 1:size(M,2)

        x = M(:,k);
        x = x(isfinite(x));

        if numel(x)<10
            continue;
        end

        dx = diff(x);

        mono = max(mean(dx>0),mean(dx<0));

        nz = abs(dx)>eps(max(abs(x)));

        if ~any(nz)
            continue;
        end

        dd = abs(dx(nz));

        reg = 1/(1+std(dd)/max(eps,mean(dd)));

        score(k) = 3*mono+reg;
    end

    [best,c] = max(score);

    if ~isfinite(best)
        error('Automatic time-column detection failed.');
    end
end

function c = autoSignalColumn(M,timeCol)

    candidates = setdiff(1:size(M,2),timeCol);

    score = -inf(size(candidates));

    for k = 1:numel(candidates)

        x = M(:,candidates(k));

        score(k) = ...
            percentileLocal(x,95)-percentileLocal(x,5);
    end

    [~,idx] = max(abs(score));

    c = candidates(idx);
end

function p = percentileLocal(x,q)

    x = sort(x(isfinite(x)));

    if isempty(x)
        p = NaN;
        return;
    end

    r = 1+(q/100)*(numel(x)-1);

    lo = floor(r);
    hi = ceil(r);

    if lo==hi
        p = x(lo);
    else
        p = x(lo)+(r-lo)*(x(hi)-x(lo));
    end
end

function a = parseAttemptNumber(folder)

    tokens = regexp(folder,'[Aa]ttempt[^0-9]*([0-9]+)','tokens');

    if isempty(tokens)
        a = NaN;
    else
        a = str2double(tokens{end}{1});
    end
end

function c = parseNominalCurrent(folder,attempt,map)

    c = NaN;

    if ~isempty(map) && isfinite(attempt)
        idx = find(map(:,1)==attempt,1,'first');
        if ~isempty(idx)
            c = map(idx,2);
            return;
        end
    end

    tok = regexp(folder,'([0-9]+(?:\.[0-9]+)?)\s*mA','tokens','ignorecase');

    if ~isempty(tok)
        c = str2double(tok{end}{1});
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

function s = numberOrUnknown(x)

    if isfinite(x)
        s = sprintf('%.6g',x);
    else
        s = 'unknown';
    end
end

function s = safeNumber(x)

    if isfinite(x)
        s = sprintf('%d',round(x));
    else
        s = 'unknown';
    end
end
