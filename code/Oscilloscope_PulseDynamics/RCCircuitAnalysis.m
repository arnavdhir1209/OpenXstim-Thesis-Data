%% RCCircuitAnalysis.m
% OpenXstim series-RC exploratory analysis
%
% Expected folder structure:
%
%   RCCircuitAnalysis.m
%   Attempt 20 RC series 10mA/
%       CH1.CSV
%       CH2.CSV
%   Attempt 21 RC series 10mA/
%       CH1.CSV
%       CH2.CSV
%
% Known external load:
%   R = 1 kOhm
%   C = 330 nF
%
% IMPORTANT MEASUREMENT NOTE
% --------------------------
% A conventional bench oscilloscope normally has channel ground clips tied
% together internally and often tied to protective earth. If CH1 and CH2
% were connected directly across two different elements in a FLOATING series
% RC network, those probe grounds may have altered the circuit.
%
% Therefore this script does TWO things:
%
%   1. Extracts as much useful information as possible from the CSV files.
%   2. Quantifies whether the measured resistor current and capacitor
%      derivative obey the expected series-RC relationship:
%
%           i_R(t) = V_R(t)/R
%
%           i_C(t) = C * dV_C(t)/dt
%
%      For a valid undisturbed series RC branch:
%
%           i_R(t) ~= i_C(t)
%
% This consistency test is especially useful for determining whether these
% captures can be used quantitatively in the thesis.
%
% The script DOES NOT assume the nominal firmware setting of 10 mA was
% actually delivered. Current is inferred from the measured resistor voltage.
%
% Outputs:
%   RC_AnalysisResults/
%       RC_Metrics.csv
%       RC_Comparison.png
%       Attempt_20_Raw.png
%       Attempt_20_Derived.png
%       Attempt_20_RCConsistency.png
%       Attempt_20_ChargeConsistency.png
%       Attempt_20_DecayFit.png       (if fit is possible)
%       ...
%
% No special toolbox is required.

clear;
clc;
close all;

%% USER SETTINGS

% =========================================================================
% FILE LOCATIONS
% =========================================================================

ROOT_FOLDER = getScriptFolder();

ATTEMPT_FOLDERS = [
    "Attempt 20 RC series 10mA"
    "Attempt 21 RC series 10mA"
];

CH1_NAME = "CH1.CSV";
CH2_NAME = "CH2.CSV";

RESULTS_FOLDER = fullfile(ROOT_FOLDER,"RC_AnalysisResults");

% =========================================================================
% CIRCUIT VALUES
% =========================================================================

R_OHM = 1000;
C_F   = 330e-9;

NOMINAL_FIRMWARE_CURRENT_MA = 10;

% OpenXstim nominal compliance level, used ONLY as a warning threshold.
% Change if your experimental configuration used a different limit.
COMPLIANCE_V = 96;

% =========================================================================
% CHANNEL ASSIGNMENT
% =========================================================================
%
% From the oscilloscope screenshot, CH1 was at a much larger voltage scale
% and CH2 at a few hundred mV. Therefore the default assumption is:
%
%   CH1 = capacitor voltage
%   CH2 = resistor voltage
%
% If your notes show the opposite, swap these:
%
CAPACITOR_CHANNEL = 1;
RESISTOR_CHANNEL  = 2;

% Multipliers applied AFTER CSV import.
%
% Leave at 1 if the oscilloscope CSV already contains the physical voltage
% after probe attenuation. Do NOT put 10 here merely because a 10:1 probe
% was used unless you verify the CSV is uncorrected.
CH1_SCALE = 1;
CH2_SCALE = 1;

% If probe polarities were arbitrary, automatic polarity alignment compares
% V_R/R with C*dV_C/dt and flips capacitor polarity if necessary.
AUTO_POLARITY_ALIGNMENT = true;

% =========================================================================
% EVENT DETECTION
% =========================================================================

% Fraction of capture used to estimate pre-event baseline/noise.
BASELINE_FRACTION = 0.10;

% Current activity threshold is the larger of:
%   ACTIVITY_FRACTION * peak activity
%   NOISE_SIGMA_MULTIPLIER * baseline noise
ACTIVITY_FRACTION = 0.05;
NOISE_SIGMA_MULTIPLIER = 6;

% Expand the detected active region for plotting/feature extraction.
EVENT_PADDING_S = 100e-6;

% =========================================================================
% DERIVATIVE / CONSISTENCY SETTINGS
% =========================================================================

% dVc/dt is noisy. Smooth Vc before differentiation.
% This is a TIME duration, not a fixed sample count.
DERIVATIVE_SMOOTHING_S = 5e-6;

% Ignore very small current values when estimating C and RC consistency.
MIN_CURRENT_FRACTION = 0.10;

% =========================================================================
% DECAY FIT
% =========================================================================

% Fit Vc after the main current event to:
%
%       Vc(t) = V_inf + A exp(-t/tau)
%
% This is an empirical feature. It is compared against the ideal external:
%
%       tau_RC = R*C
%
% The fit is attempted only when enough post-event data exists.
MIN_DECAY_DURATION_S = 0.25e-3;

% =========================================================================
% PLOTTING
% =========================================================================

SAVE_FIGURES = true;

%% INITIALIZE

if ~isfolder(RESULTS_FOLDER)
    mkdir(RESULTS_FOLDER);
end

tauExpected = R_OHM*C_F;

fprintf('\n============================================================\n');
fprintf('OPENXSTIM SERIES-RC ANALYSIS\n');
fprintf('============================================================\n');
fprintf('Root folder               : %s\n',ROOT_FOLDER);
fprintf('External resistor         : %.6g ohm\n',R_OHM);
fprintf('External capacitor        : %.6g nF\n',1e9*C_F);
fprintf('Ideal external R*C        : %.6g us\n',1e6*tauExpected);
fprintf('Nominal firmware setting  : %.6g mA\n',NOMINAL_FIRMWARE_CURRENT_MA);
fprintf('Capacitor channel         : CH%d\n',CAPACITOR_CHANNEL);
fprintf('Resistor channel          : CH%d\n',RESISTOR_CHANNEL);

%% PROCESS EACH RC ATTEMPT

resultCells = cell(numel(ATTEMPT_FOLDERS),1);
attemptResults = struct([]);

for a = 1:numel(ATTEMPT_FOLDERS)

    folderName = ATTEMPT_FOLDERS(a);
    folderPath = fullfile(ROOT_FOLDER,folderName);

    ch1Path = fullfile(folderPath,CH1_NAME);
    ch2Path = fullfile(folderPath,CH2_NAME);

    assert(isfile(ch1Path),'Cannot find:\n%s',ch1Path);
    assert(isfile(ch2Path),'Cannot find:\n%s',ch2Path);

    attemptNo = parseAttemptNumber(folderName);

    fprintf('\n------------------------------------------------------------\n');
    fprintf('Attempt %d\n',attemptNo);
    fprintf('Folder: %s\n',folderPath);

    [t1,y1] = loadScopeCSV(ch1Path);
    [t2,y2] = loadScopeCSV(ch2Path);

    [t,ch1,ch2,Ts] = alignChannels(t1,y1,t2,y2);
    t = t-t(1);

    ch1 = CH1_SCALE*ch1;
    ch2 = CH2_SCALE*ch2;

    channels = {ch1,ch2};

    VcRaw = channels{CAPACITOR_CHANNEL};
    VrRaw = channels{RESISTOR_CHANNEL};

    % ---------------------------------------------------------------------
    % Baseline correction
    % ---------------------------------------------------------------------

    nBase = max(10,round(BASELINE_FRACTION*numel(t)));
    baseIdx = 1:min(nBase,numel(t));

    VrBaseline = median(VrRaw(baseIdx),'omitnan');
    VcBaseline = median(VcRaw(baseIdx),'omitnan');

    Vr = VrRaw-VrBaseline;
    Vc = VcRaw-VcBaseline;

    currentA = Vr/R_OHM;

    % ---------------------------------------------------------------------
    % Detect active event primarily from resistor current
    % ---------------------------------------------------------------------

    currentSmooth = movmean(currentA,max(3,round(1e-6/Ts)));

    baselineCurrent = currentSmooth(baseIdx);
    noiseSigma = robustSigma(baselineCurrent);

    peakActivity = max(abs(currentSmooth),[],'omitnan');

    activityThreshold = max( ...
        ACTIVITY_FRACTION*peakActivity, ...
        NOISE_SIGMA_MULTIPLIER*noiseSigma);

    activeLogical = abs(currentSmooth)>=activityThreshold;

    [eventStartIdx,eventEndIdx] = largestTrueRegion(activeLogical);

    % Fallback to capacitor derivative if current activity is weak.
    if isempty(eventStartIdx)

        nSmoothFallback = max(3,round(DERIVATIVE_SMOOTHING_S/Ts));
        VcFallback = movmean(Vc,nSmoothFallback);
        dVcFallback = gradient(VcFallback,Ts);

        derivativeThreshold = max( ...
            ACTIVITY_FRACTION*max(abs(dVcFallback)), ...
            NOISE_SIGMA_MULTIPLIER*robustSigma(dVcFallback(baseIdx)));

        [eventStartIdx,eventEndIdx] = ...
            largestTrueRegion(abs(dVcFallback)>=derivativeThreshold);
    end

    if isempty(eventStartIdx)
        warning('Could not confidently detect a main event in Attempt %d.',attemptNo);
        eventStartIdx = 1;
        eventEndIdx = numel(t);
    end

    eventStartTime = t(eventStartIdx);
    eventEndTime = t(eventEndIdx);

    % ---------------------------------------------------------------------
    % Smooth Vc and calculate capacitor current
    % ---------------------------------------------------------------------

    nSmooth = max(3,round(DERIVATIVE_SMOOTHING_S/Ts));
    if mod(nSmooth,2)==0
        nSmooth = nSmooth+1;
    end

    nSmooth = min(nSmooth,max(3,2*floor(numel(t)/20)+1));

    VcSmooth = movmean(Vc,nSmooth);
    dVc_dt = gradient(VcSmooth,Ts);

    iCapNominal = C_F*dVc_dt;

    % Automatic polarity alignment.
    eventMask = false(size(t));
    eventMask(eventStartIdx:eventEndIdx) = true;

    currentThresholdForFit = MIN_CURRENT_FRACTION*max(abs(currentA(eventMask)));

    fitMask = eventMask & abs(currentA)>=currentThresholdForFit;

    if nnz(fitMask)<10
        fitMask = eventMask;
    end

    corrBefore = safeCorr(currentA(fitMask),iCapNominal(fitMask));

    polarityFlip = 1;

    if AUTO_POLARITY_ALIGNMENT && isfinite(corrBefore) && corrBefore<0
        polarityFlip = -1;
        Vc = -Vc;
        VcSmooth = -VcSmooth;
        dVc_dt = -dVc_dt;
        iCapNominal = -iCapNominal;
    end

    % ---------------------------------------------------------------------
    % Series RC consistency
    % ---------------------------------------------------------------------

    corrIRIC = safeCorr(currentA(fitMask),iCapNominal(fitMask));

    differenceA = currentA-iCapNominal;

    consistencyRMSE_A = sqrt(mean(differenceA(fitMask).^2,'omitnan'));

    currentRMS_A = sqrt(mean(currentA(fitMask).^2,'omitnan'));

    consistencyNRMSE = consistencyRMSE_A/max(eps,currentRMS_A);

    % Least-squares capacitance estimate from i = C*dVc/dt.
    x = dVc_dt(fitMask);
    y = currentA(fitMask);

    finiteFit = isfinite(x)&isfinite(y);

    x = x(finiteFit);
    y = y(finiteFit);

    if numel(x)>=10 && sum(x.^2)>eps
        C_est = (x.'*y)/(x.'*x);
    else
        C_est = NaN;
    end

    % ---------------------------------------------------------------------
    % Charge consistency
    % ---------------------------------------------------------------------

    cumulativeCharge_C = cumtrapz(t,currentA);

    deltaVcPredicted = cumulativeCharge_C/C_F;

    measuredDeltaVc = Vc-Vc(1);

    Q_event_C = trapz(t(eventMask),currentA(eventMask));

    deltaVcEventMeasured = ...
        Vc(eventEndIdx)-Vc(eventStartIdx);

    deltaVcEventPredicted = Q_event_C/C_F;

    if abs(deltaVcEventMeasured)>eps
        chargeConsistencyRatio = ...
            deltaVcEventPredicted/deltaVcEventMeasured;
    else
        chargeConsistencyRatio = NaN;
    end

    % ---------------------------------------------------------------------
    % Voltage / current / energy features
    % ---------------------------------------------------------------------

    Vtotal = Vr+Vc;

    [peakAbsCurrent_A,peakCurrentLocal] = ...
        max(abs(currentA(eventMask)));

    eventIndices = find(eventMask);
    peakCurrentIdx = eventIndices(peakCurrentLocal);

    [peakAbsVr_V,~] = max(abs(Vr));
    [peakAbsVc_V,peakVcIdx] = max(abs(Vc));
    [peakAbsVtotal_V,peakTotalIdx] = max(abs(Vtotal));

    resistorPower_W = currentA.^2*R_OHM;
    resistorEnergy_J = trapz(t,resistorPower_W);

    capacitorEnergy_J = 0.5*C_F*Vc.^2;

    deltaCapEnergy_J = ...
        capacitorEnergy_J(eventEndIdx)-capacitorEnergy_J(eventStartIdx);

    % ---------------------------------------------------------------------
    % Empirical capacitor decay fit after active current event
    % ---------------------------------------------------------------------

    decay = fitDecayAfterEvent( ...
        t,Vc,eventEndIdx,MIN_DECAY_DURATION_S);

    % ---------------------------------------------------------------------
    % Quality flags
    % ---------------------------------------------------------------------

    flags = strings(0,1);

    if peakAbsVc_V>1.1*COMPLIANCE_V || peakAbsVtotal_V>1.1*COMPLIANCE_V
        flags(end+1) = ...
            "Measured voltage exceeds nominal compliance range; verify probe scaling and grounding.";
    end

    if ~isfinite(corrIRIC) || corrIRIC<0.8
        flags(end+1) = ...
            "Poor agreement between V_R/R and C*dV_C/dt.";
    end

    if isfinite(C_est)
        capRatio = C_est/C_F;

        if capRatio<0.7 || capRatio>1.3
            flags(end+1) = ...
                "Capacitance inferred from i=C*dV/dt differs by more than 30% from 330 nF.";
        end
    else
        flags(end+1) = ...
            "Effective capacitance could not be estimated reliably.";
    end

    if consistencyNRMSE>0.30
        flags(end+1) = ...
            "Series-current consistency NRMSE exceeds 30%.";
    end

    flags(end+1) = ...
        "Bench-scope common-ground topology must be verified before quantitative RC validation.";

    if polarityFlip==-1
        flags(end+1) = ...
            "Capacitor channel polarity was flipped in software to align with resistor current.";
    end

    if isempty(flags)
        qualityText = "No automatic warning";
    else
        qualityText = strjoin(flags," | ");
    end

    % ---------------------------------------------------------------------
    % Store
    % ---------------------------------------------------------------------

    R.attempt = attemptNo;
    R.folder = folderPath;

    R.t = t;
    R.Ts = Ts;

    R.ch1 = ch1;
    R.ch2 = ch2;

    R.Vr = Vr;
    R.Vc = Vc;
    R.VcSmooth = VcSmooth;
    R.Vtotal = Vtotal;

    R.currentA = currentA;
    R.iCapNominal = iCapNominal;
    R.dVc_dt = dVc_dt;

    R.eventStartIdx = eventStartIdx;
    R.eventEndIdx = eventEndIdx;
    R.eventStartTime = eventStartTime;
    R.eventEndTime = eventEndTime;
    R.eventDuration_s = eventEndTime-eventStartTime;

    R.peakAbsCurrent_A = peakAbsCurrent_A;
    R.peakCurrentTime_s = t(peakCurrentIdx);

    R.peakAbsVr_V = peakAbsVr_V;
    R.peakAbsVc_V = peakAbsVc_V;
    R.peakAbsVtotal_V = peakAbsVtotal_V;
    R.peakVcTime_s = t(peakVcIdx);
    R.peakTotalTime_s = t(peakTotalIdx);

    R.currentCapCorrelation = corrIRIC;
    R.consistencyRMSE_A = consistencyRMSE_A;
    R.consistencyNRMSE = consistencyNRMSE;

    R.C_est_F = C_est;

    R.Q_event_C = Q_event_C;
    R.deltaVcEventMeasured_V = deltaVcEventMeasured;
    R.deltaVcEventPredicted_V = deltaVcEventPredicted;
    R.chargeConsistencyRatio = chargeConsistencyRatio;

    R.cumulativeCharge_C = cumulativeCharge_C;
    R.deltaVcPredicted = deltaVcPredicted;
    R.measuredDeltaVc = measuredDeltaVc;

    R.resistorEnergy_J = resistorEnergy_J;
    R.deltaCapEnergy_J = deltaCapEnergy_J;

    R.decay = decay;

    R.polarityFlip = polarityFlip;
    R.qualityFlag = qualityText;

    resultCells{a} = R;

    % ---------------------------------------------------------------------
    % Print attempt summary
    % ---------------------------------------------------------------------

    fprintf('  Sample period              : %.9g s\n',Ts);
    fprintf('  Event start                : %.9g s\n',eventStartTime);
    fprintf('  Event end                  : %.9g s\n',eventEndTime);
    fprintf('  Detected active duration   : %.6g us\n',1e6*R.eventDuration_s);

    fprintf('  Peak |I_R|                 : %.9g mA\n',1e3*peakAbsCurrent_A);
    fprintf('  Peak |V_R|                 : %.9g V\n',peakAbsVr_V);
    fprintf('  Peak |V_C|                 : %.9g V\n',peakAbsVc_V);
    fprintf('  Peak |V_R + V_C|           : %.9g V\n',peakAbsVtotal_V);

    fprintf('  Corr(i_R, C*dVc/dt)        : %.6f\n',corrIRIC);
    fprintf('  Current consistency NRMSE  : %.6f\n',consistencyNRMSE);

    fprintf('  Estimated C                : %.9g nF\n',1e9*C_est);
    fprintf('  Nominal C                  : %.9g nF\n',1e9*C_F);

    fprintf('  Event charge               : %.9g uC\n',1e6*Q_event_C);
    fprintf('  Measured Delta Vc          : %.9g V\n',deltaVcEventMeasured);
    fprintf('  Q/C predicted Delta Vc     : %.9g V\n',deltaVcEventPredicted);
    fprintf('  Charge consistency ratio   : %.9g\n',chargeConsistencyRatio);

    if decay.valid
        fprintf('  Empirical post-event tau   : %.9g us\n',1e6*decay.tau_s);
        fprintf('  Ideal R*C tau              : %.9g us\n',1e6*tauExpected);
    else
        fprintf('  Empirical post-event tau   : not reliably fitted\n');
    end

    fprintf('  Quality flags              : %s\n',qualityText);

    % ---------------------------------------------------------------------
    % Figures
    % ---------------------------------------------------------------------

    plotAttemptRaw(R,CAPACITOR_CHANNEL,RESISTOR_CHANNEL,RESULTS_FOLDER,SAVE_FIGURES);
    plotAttemptDerived(R,RESULTS_FOLDER,SAVE_FIGURES);
    plotRCConsistency(R,C_F,RESULTS_FOLDER,SAVE_FIGURES);
    plotChargeConsistency(R,RESULTS_FOLDER,SAVE_FIGURES);

    if decay.valid
        plotDecayFit(R,tauExpected,RESULTS_FOLDER,SAVE_FIGURES);
    end
end

attemptResults = vertcat(resultCells{:});

%% SUMMARY TABLE

summaryCells = cell(numel(attemptResults),1);

for k = 1:numel(attemptResults)

    R = attemptResults(k);

    S.Attempt = R.attempt;

    S.EventDuration_us = 1e6*R.eventDuration_s;

    S.PeakCurrent_mA = 1e3*R.peakAbsCurrent_A;

    S.PeakVr_V = R.peakAbsVr_V;
    S.PeakVc_V = R.peakAbsVc_V;
    S.PeakVtotal_V = R.peakAbsVtotal_V;

    S.CurrentCapCorrelation = R.currentCapCorrelation;
    S.CurrentConsistencyNRMSE = R.consistencyNRMSE;

    S.EstimatedC_nF = 1e9*R.C_est_F;
    S.NominalC_nF = 1e9*C_F;

    S.EventCharge_uC = 1e6*R.Q_event_C;

    S.MeasuredDeltaVc_V = R.deltaVcEventMeasured_V;
    S.PredictedDeltaVc_V = R.deltaVcEventPredicted_V;
    S.ChargeConsistencyRatio = R.chargeConsistencyRatio;

    S.ResistorEnergy_uJ = 1e6*R.resistorEnergy_J;
    S.CapEnergyChange_uJ = 1e6*R.deltaCapEnergy_J;

    if R.decay.valid
        S.DecayTau_us = 1e6*R.decay.tau_s;
    else
        S.DecayTau_us = NaN;
    end

    S.ExpectedRCTau_us = 1e6*tauExpected;

    S.QualityFlag = string(R.qualityFlag);
    S.Folder = string(R.folder);

    summaryCells{k} = S;
end

summaryStruct = vertcat(summaryCells{:});
summaryTable = struct2table(summaryStruct);

writetable(summaryTable,fullfile(RESULTS_FOLDER,"RC_Metrics.csv"));

fprintf('\n============================================================\n');
fprintf('RC SUMMARY\n');
fprintf('============================================================\n');

disp(summaryTable(:,{ ...
    'Attempt','EventDuration_us','PeakCurrent_mA', ...
    'PeakVr_V','PeakVc_V','PeakVtotal_V', ...
    'CurrentCapCorrelation','CurrentConsistencyNRMSE', ...
    'EstimatedC_nF','DecayTau_us','ExpectedRCTau_us'}));

%% ATTEMPT-TO-ATTEMPT COMPARISON

if numel(attemptResults)>=2

    figure('Name','RC attempt comparison');

    tiledlayout(3,1);

    nexttile;
    hold on;

    for k = 1:numel(attemptResults)

        R = attemptResults(k);

        tr = R.t-R.eventStartTime;

        plot(tr*1e3,1e3*R.currentA,'LineWidth',1.1);
    end

    xline(0,'--','detected event');
    grid on;
    xlabel('Time from detected event (ms)');
    ylabel('I_R (mA)');
    title('Current inferred from resistor voltage');

    legend(compose('Attempt %d',[attemptResults.attempt]), ...
        'Location','best');

    hold off;

    nexttile;
    hold on;

    for k = 1:numel(attemptResults)

        R = attemptResults(k);

        tr = R.t-R.eventStartTime;

        plot(tr*1e3,R.Vc,'LineWidth',1.1);
    end

    xline(0,'--','detected event');
    grid on;
    xlabel('Time from detected event (ms)');
    ylabel('V_C (V)');
    title('Measured capacitor voltage');

    legend(compose('Attempt %d',[attemptResults.attempt]), ...
        'Location','best');

    hold off;

    nexttile;
    hold on;

    for k = 1:numel(attemptResults)

        R = attemptResults(k);

        tr = R.t-R.eventStartTime;

        plot(tr*1e3,R.Vtotal,'LineWidth',1.1);
    end

    xline(0,'--','detected event');
    yline(COMPLIANCE_V,':','+ nominal compliance');
    yline(-COMPLIANCE_V,':','- nominal compliance');

    grid on;
    xlabel('Time from detected event (ms)');
    ylabel('V_R + V_C (V)');
    title('Reconstructed series-load voltage, interpretation requires valid probe grounding');

    legend(compose('Attempt %d',[attemptResults.attempt]), ...
        'Location','best');

    hold off;

    if SAVE_FIGURES
        saveas(gcf,fullfile(RESULTS_FOLDER,"RC_Comparison.png"));
    end
end

%% INTERPRETATION OUTPUT

fprintf('\n============================================================\n');
fprintf('INTERPRETATION GUIDE\n');
fprintf('============================================================\n');

fprintf(['For an undisturbed series RC branch, the most important internal\n' ...
         'consistency checks are:\n\n']);

fprintf('  i_R(t) = V_R(t)/R\n');
fprintf('  i_C(t) = C*dV_C(t)/dt\n');
fprintf('  Delta V_C = (1/C) integral i(t) dt\n\n');

fprintf(['If i_R and C*dV_C/dt agree closely, and the inferred capacitance is\n' ...
         'near 330 nF, the capture has evidence of being physically consistent\n' ...
         'with the intended series RC load.\n\n']);

fprintf(['If they disagree strongly, do NOT force a transfer-function fit.\n' ...
         'First investigate probe grounding, channel scaling, saturation,\n' ...
         'compliance limiting, and whether the oscilloscope changed the\n' ...
         'floating circuit.\n\n']);

fprintf(['The expected passive time constant R*C = %.3f us. A measured\n' ...
         'post-event exponential time constant far from this value is not\n' ...
         'automatically an OpenXstim plant pole because the internal output\n' ...
         'network and measurement topology can also contribute.\n'],1e6*tauExpected);

fprintf('\nResults folder:\n%s\n',RESULTS_FOLDER);

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function [t,y] = loadScopeCSV(path)

    M = readmatrix(path);

    if isempty(M)
        error('No numeric data found in:\n%s',path);
    end

    numericPerRow = sum(isfinite(M),2);
    dataLike = numericPerRow>=2;

    if ~any(dataLike)
        error('Could not identify numeric scope data in:\n%s',path);
    end

    d = diff([false;dataLike;false]);

    starts = find(d==1);
    stops = find(d==-1)-1;

    [~,best] = max(stops-starts+1);

    M = M(starts(best):stops(best),:);

    M(:,all(~isfinite(M),1)) = [];

    if size(M,2)<2
        error('Expected at least two numeric columns in:\n%s',path);
    end

    timeCol = autoTimeColumn(M);
    signalCol = autoSignalColumn(M,timeCol);

    t = M(:,timeCol);
    y = M(:,signalCol);

    good = isfinite(t)&isfinite(y);

    t = t(good);
    y = y(good);

    [t,order] = sort(t);
    y = y(order);

    [t,idx] = unique(t,'stable');
    y = y(idx);
end

function [t,y1,y2,Ts] = alignChannels(t1,y1,t2,y2)

    Ts = max(median(diff(t1)),median(diff(t2)));

    tStart = max(t1(1),t2(1));
    tStop  = min(t1(end),t2(end));

    if tStop<=tStart
        error('CH1 and CH2 time ranges do not overlap.');
    end

    t = (tStart:Ts:tStop).';

    y1 = interp1(t1,y1,t,'linear');
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

        monotonicity = max(mean(dx>0),mean(dx<0));

        nz = abs(dx)>eps(max(abs(x)));

        if ~any(nz)
            continue;
        end

        dd = abs(dx(nz));

        regularity = 1/(1+std(dd)/max(eps,mean(dd)));

        score(k) = 3*monotonicity+regularity;
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

        score(k) = abs(percentileLocal(x,95)-percentileLocal(x,5));
    end

    [~,idx] = max(score);

    c = candidates(idx);
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

function sigma = robustSigma(x)

    x = x(isfinite(x));

    if numel(x)<5
        sigma = std(x,'omitnan');
        return;
    end

    med = median(x,'omitnan');

    madValue = median(abs(x-med),'omitnan');

    sigma = 1.4826*madValue;

    if ~isfinite(sigma) || sigma<=0
        sigma = std(x,'omitnan');
    end

    if ~isfinite(sigma)
        sigma = 0;
    end
end

function [startIdx,endIdx] = largestTrueRegion(logicalVector)

    logicalVector = logicalVector(:);

    d = diff([false;logicalVector;false]);

    starts = find(d==1);
    stops  = find(d==-1)-1;

    if isempty(starts)
        startIdx = [];
        endIdx = [];
        return;
    end

    [~,best] = max(stops-starts+1);

    startIdx = starts(best);
    endIdx = stops(best);
end

function c = safeCorr(x,y)

    good = isfinite(x)&isfinite(y);

    x = x(good);
    y = y(good);

    if numel(x)<3 || std(x)==0 || std(y)==0
        c = NaN;
        return;
    end

    C = corrcoef(x,y);

    c = C(1,2);
end

function decay = fitDecayAfterEvent(t,Vc,eventEndIdx,minDuration)

    decay.valid = false;
    decay.tau_s = NaN;
    decay.Vinf = NaN;
    decay.A = NaN;
    decay.t = [];
    decay.y = [];
    decay.yhat = [];
    decay.rmse = NaN;

    if eventEndIdx>=numel(t)-20
        return;
    end

    tPost = t(eventEndIdx:end)-t(eventEndIdx);
    yPost = Vc(eventEndIdx:end);

    if tPost(end)<minDuration
        return;
    end

    nTail = max(10,round(0.10*numel(yPost)));

    Vinf0 = median(yPost(end-nTail+1:end),'omitnan');
    A0 = yPost(1)-Vinf0;

    if abs(A0)<0.02*max(eps,max(abs(yPost)))
        return;
    end

    tau0 = max(1e-6,0.25*tPost(end));

    q0 = [Vinf0,A0,log(tau0)];

    objective = @(q) mean(( ...
        (q(1)+q(2)*exp(-tPost/exp(q(3))))-yPost).^2,'omitnan');

    q = fminsearch(objective,q0, ...
        optimset('Display','off','MaxIter',10000,'MaxFunEvals',10000));

    yhat = q(1)+q(2)*exp(-tPost/exp(q(3)));

    rmse = sqrt(mean((yPost-yhat).^2,'omitnan'));

    decay.valid = true;
    decay.tau_s = exp(q(3));
    decay.Vinf = q(1);
    decay.A = q(2);
    decay.t = tPost;
    decay.y = yPost;
    decay.yhat = yhat;
    decay.rmse = rmse;
end

function plotAttemptRaw(R,capChannel,resChannel,resultsFolder,saveFigures)

    figure('Name',sprintf('Attempt %d raw RC',R.attempt));

    tiledlayout(2,1);

    nexttile;
    plot(R.t*1e3,R.ch1,'LineWidth',1);
    hold on;
    xline(R.eventStartTime*1e3,'--','detected start');
    xline(R.eventEndTime*1e3,'--','detected end');
    grid on;
    ylabel('CH1 (V)');
    title(sprintf('Attempt %d raw CH1',R.attempt));
    hold off;

    nexttile;
    plot(R.t*1e3,R.ch2,'LineWidth',1);
    hold on;
    xline(R.eventStartTime*1e3,'--','detected start');
    xline(R.eventEndTime*1e3,'--','detected end');
    grid on;
    xlabel('Time (ms)');
    ylabel('CH2 (V)');
    title(sprintf( ...
        'Raw CH2, capacitor=CH%d, resistor=CH%d', ...
        capChannel,resChannel));
    hold off;

    if saveFigures
        saveas(gcf,fullfile(resultsFolder, ...
            sprintf('Attempt_%d_Raw.png',R.attempt)));
    end
end

function plotAttemptDerived(R,resultsFolder,saveFigures)

    tr = R.t-R.eventStartTime;

    figure('Name',sprintf('Attempt %d derived RC',R.attempt));

    tiledlayout(4,1);

    nexttile;
    plot(tr*1e3,1e3*R.currentA,'LineWidth',1.2);
    xline(0,'--','event');
    grid on;
    ylabel('I_R (mA)');
    title(sprintf('Attempt %d current from V_R/R',R.attempt));

    nexttile;
    plot(tr*1e3,R.Vr,'LineWidth',1.1);
    xline(0,'--','event');
    grid on;
    ylabel('V_R (V)');
    title('Baseline-corrected resistor voltage');

    nexttile;
    plot(tr*1e3,R.Vc,'LineWidth',1.1);
    xline(0,'--','event');
    grid on;
    ylabel('V_C (V)');
    title('Baseline-corrected capacitor voltage');

    nexttile;
    plot(tr*1e3,R.Vtotal,'LineWidth',1.1);
    xline(0,'--','event');
    grid on;
    xlabel('Time from detected event (ms)');
    ylabel('V_R + V_C (V)');
    title('Reconstructed total series-load voltage');

    if saveFigures
        saveas(gcf,fullfile(resultsFolder, ...
            sprintf('Attempt_%d_Derived.png',R.attempt)));
    end
end

function plotRCConsistency(R,Cnominal,resultsFolder,saveFigures)

    tr = R.t-R.eventStartTime;

    figure('Name',sprintf('Attempt %d RC consistency',R.attempt));

    tiledlayout(2,1);

    nexttile;
    plot(tr*1e3,1e3*R.currentA,'LineWidth',1.3);
    hold on;
    plot(tr*1e3,1e3*R.iCapNominal,'LineWidth',1.2);

    xline(0,'--','event');
    grid on;

    ylabel('Current (mA)');
    title(sprintf( ...
        'Series-current consistency, corr = %.3f, NRMSE = %.3f', ...
        R.currentCapCorrelation,R.consistencyNRMSE));

    legend('V_R/R', ...
        sprintf('C dV_C/dt, C = %.0f nF',1e9*Cnominal), ...
        'Location','best');

    hold off;

    nexttile;

    scatter(1e3*R.iCapNominal,1e3*R.currentA,8,'filled');
    hold on;

    lim = max(abs([ ...
        1e3*R.iCapNominal(:); ...
        1e3*R.currentA(:)]));

    if isfinite(lim) && lim>0
        plot([-lim lim],[-lim lim],'--');
        xlim([-lim lim]);
        ylim([-lim lim]);
    end

    axis square;
    grid on;

    xlabel('C dV_C/dt (mA)');
    ylabel('V_R/R (mA)');

    title(sprintf( ...
        'Inferred C = %.3f nF, nominal = %.3f nF', ...
        1e9*R.C_est_F,1e9*Cnominal));

    hold off;

    if saveFigures
        saveas(gcf,fullfile(resultsFolder, ...
            sprintf('Attempt_%d_RCConsistency.png',R.attempt)));
    end
end

function plotChargeConsistency(R,resultsFolder,saveFigures)

    tr = R.t-R.eventStartTime;

    figure('Name',sprintf('Attempt %d charge consistency',R.attempt));

    plot(tr*1e3,R.measuredDeltaVc,'LineWidth',1.4);
    hold on;

    plot(tr*1e3,R.deltaVcPredicted,'LineWidth',1.2);

    xline(0,'--','event');

    grid on;
    xlabel('Time from detected event (ms)');
    ylabel('Delta V_C (V)');

    title(sprintf( ...
        'Capacitor charge consistency, event ratio Q/C / DeltaV = %.3f', ...
        R.chargeConsistencyRatio));

    legend('Measured V_C change', ...
        'Predicted from integral i_R dt / C', ...
        'Location','best');

    hold off;

    if saveFigures
        saveas(gcf,fullfile(resultsFolder, ...
            sprintf('Attempt_%d_ChargeConsistency.png',R.attempt)));
    end
end

function plotDecayFit(R,tauExpected,resultsFolder,saveFigures)

    D = R.decay;

    figure('Name',sprintf('Attempt %d decay fit',R.attempt));

    plot(D.t*1e3,D.y,'LineWidth',1.4);
    hold on;

    plot(D.t*1e3,D.yhat,'LineWidth',1.2);

    grid on;
    xlabel('Time after detected active-current end (ms)');
    ylabel('V_C (V)');

    title(sprintf( ...
        'Post-event V_C decay: tau_{fit}=%.3f us, R*C=%.3f us', ...
        1e6*D.tau_s,1e6*tauExpected));

    legend('Measured V_C','Exponential fit','Location','best');

    hold off;

    if saveFigures
        saveas(gcf,fullfile(resultsFolder, ...
            sprintf('Attempt_%d_DecayFit.png',R.attempt)));
    end
end

function a = parseAttemptNumber(name)

    token = regexp(char(name),'Attempt\s+([0-9]+)','tokens','once');

    if isempty(token)
        a = NaN;
    else
        a = str2double(token{1});
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
