%% Script02_NormalizeTransitions.m
% OPENXSTIM STAGE 2: CONSOLIDATED NORMALIZATION AND DIAGNOSTICS
%
% Run this file as the single Stage 2 entry point.
% Input: Stage 1 CommandAwareGradientResults.mat (variable: results).
% The input and output paths are fixed in the USER SETTINGS block below.
%
% Processing basis: uploaded Script02_NormalizeTransitions_V2.m.
% Fast normalization, timing, phase segmentation, droop extraction and the
% 5 us model grid retain that implementation. This consolidation restores
% diagnostics from V1/V3 and adds traceable QC; it performs no plant fitting.
%
% Outputs in Stage2_Normalization beside Stage1_Classification:
%   NormalizedTransitions.mat  (normalization)
%   CommandDelayResults.mat    (delay)
%   PassiveDroopResults.mat    (droop)
%   original modelling CSV files plus diagnostic summary tables
%   Figures/01_...png through Figures/12_...png, and optional editable .fig
%   Figures/DiagnosticFigureManifest.csv records this run's export status.
%   Figures open as docked tabs in one shared figure container.
%
% Figure inventory (older duplicate views have one canonical name here):
% 01 LocalDetrendingVerification: raw CH3, actual fit spans, extrapolation
% 02 NormalizedOverlaysByClass: replaces NormalizedFastTransitions
% 03 BipolarSymmetry: direction means and their difference
% 04 RawVsDetrendedNormalization: mean responses and correction size
% 05 FastMetricRepeatability: 10-90 time by command event
% 06 RefinedCommandResponseDelay: replaces CommandDelay (t10/t50/t90)
% 07 T10AlignedBipolarTransitions: individual aligned traces and mean
% 08 PassiveDroopSeparatedRawMagnitude: absolute magnitude in mA
% 09 PassiveDroopRebasedIndividual: replaces RebasedPassiveDroop
% 10 PassiveDroopMeanComparison: replaces both old droop mean comparisons
% 11 PassiveDroopModelGrid: replaces DroopModelGrid (actual model matrix)
% 12 PassiveDroopNormalizationCheck: initial and final values per phase
%
% Droop time zero is the guarded slow-phase origin, not the command time.
% Figure 08 uses lightly smoothed magnitude, as in the earlier mA overlays;
% set its display option below to false to inspect unsmoothed magnitudes.
% Plotting never re-normalizes data or changes model matrix columns.
% The combined model matrix is ordered positive phases, then negative.
% Its column map retains the original physical phase and command event IDs.
%
% Stage 3 slow modelling still needs its separate whole-phase validation
% revision. Compatibility aliases are retained, including droop.time_ms.

clear; clc; close all;

try
    set(groot,'defaultAxesToolbarVisible','off');
catch
end

%% USER SETTINGS ==========================================================

% Change only this block when processing a different capture.
PROJECT_FOLDER = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.
STAGE1_INPUT_FILE = fullfile(PROJECT_FOLDER,"Stage1_Classification", ...
    "CommandAwareGradientResults.mat");
STAGE2_OUTPUT_FOLDER = fullfile(PROJECT_FOLDER,"Stage2_Normalization");

% Figure display/export settings. All 12 diagnostics are always attempted.
FIGURE_VISIBLE = "off";         % "off" exports without opening windows
FIGURE_WINDOW_STYLE = "normal"; % tabs in one container; "normal" = separate windows
SAVE_EDITABLE_FIGURES = false;   % save .fig as well as mandatory PNG
FIGURE_RESOLUTION_DPI = 180;
MAX_LOCAL_DETREND_EVENTS = 8;
LOCAL_DETREND_EVENT_NUMBERS = []; % [] = include all classes, then spread
LOCAL_DETREND_VIEW_US = [-300 300];
FAST_PLOT_YLIM = [-0.2 1.2];
DROOP_MAGNITUDE_PLOT_SMOOTHED = true; % display only, extraction unchanged
DROOP_NORMALIZATION_CHECK_TOL = 1e-9;

% Every individual fast/droop trace is plotted. Means use a dark line on
% explicitly white axes so they remain visible with MATLAB's dark theme.
plotConfig = struct();
plotConfig.visible = FIGURE_VISIBLE;
plotConfig.windowStyle = FIGURE_WINDOW_STYLE;
plotConfig.saveEditable = SAVE_EDITABLE_FIGURES;
plotConfig.resolution = FIGURE_RESOLUTION_DPI;
plotConfig.maxLocalEvents = MAX_LOCAL_DETREND_EVENTS;
plotConfig.localEventNumbers = LOCAL_DETREND_EVENT_NUMBERS;
plotConfig.localView_us = LOCAL_DETREND_VIEW_US;
plotConfig.fastYLim = FAST_PLOT_YLIM;
plotConfig.magnitudeSmoothed = DROOP_MAGNITUDE_PLOT_SMOOTHED;
plotConfig.normalizationTolerance = DROOP_NORMALIZATION_CHECK_TOL;
plotConfig.classColors = [0.00 0.35 0.65; 0.82 0.28 0.04; ...
                         0.00 0.48 0.32; 0.52 0.24 0.66];
plotConfig.positiveColor = [0.00 0.35 0.65];
plotConfig.negativeColor = [0.82 0.28 0.04];
plotConfig.meanColor = [0.08 0.08 0.08];

% Fast-transition normalization
FAST_WINDOW_PRE_US  = 25;
FAST_WINDOW_POST_US = 30;

PRE_FIT_START_US  = -250;
PRE_FIT_END_US    = -40;
POST_FIT_START_US = 40;
POST_FIT_END_US   = 250;

NEIGHBOUR_EDGE_GUARD_US = 50;
METRIC_SMOOTH_US = 0.24;

SETTLING_BAND = 0.02;
SETTLING_HOLD_US = 3.0;

MIN_STEP_MAGNITUDE_mA = 0.50;
NORMALIZED_BASELINE_TOL = 0.15;
NORMALIZED_FINAL_TOL = 0.15;

COMMON_DT_US = NaN;

% Slow-droop normalization
DROOP_START_GUARD_US = 20;
DROOP_END_GUARD_US   = 20;
DROOP_SMOOTH_US      = 4.0;

% Full-resolution saved droop grid. NaN = scope sample interval.
DROOP_FULL_DT_US = NaN;

% Stage 3 modelling grid
DROOP_MODEL_DT_US = 5.0;

% Exact D(0)=1 after smoothing and the start guard.
DROOP_REFERENCE_MODE = "first_smoothed_sample";

% Used for QC/reporting, and if reference mode is changed to early_median.
DROOP_REFERENCE_WINDOW_US = 20;
DROOP_LATE_WINDOW_US = 20;

%% LOAD STAGE 1 ===========================================================

resultsPath = STAGE1_INPUT_FILE;
verifyHardcodedInputs(resultsPath,"Stage 1 MAT",PROJECT_FOLDER);

S = load(resultsPath);
if ~isfield(S,"results")
    error("MAT file must contain variable 'results'.");
end
R = S.results;
captureRoot = PROJECT_FOLDER;

need = ["t","currentRaw_mA","currentSmooth_mA","matchedTable", ...
    "phaseTable","Ts","Fs"];
for k=1:numel(need)
    if ~isfield(R,need(k))
        error("Missing results.%s",need(k));
    end
end

t = R.t(:);
Iraw = R.currentRaw_mA(:);
Ts = R.Ts;
Fs = R.Fs;
events = R.matchedTable;

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 2 CONSOLIDATED NORMALIZATION\n");
fprintf("============================================================\n");
fprintf("Stage 1 file : %s\n",resultsPath);
fprintf("Samples      : %d\n",numel(t));
fprintf("Fs           : %.6f MSa/s\n",Fs/1e6);
fprintf("Ts           : %.3f ns\n",Ts*1e9);

%% MATCHED EVENTS =========================================================

reqCols = ["CommandEvent","CommandTime_s","CommandClass", ...
    "ResponseTime_s","MatchStatus"];

if ~all(ismember(reqCols,string(events.Properties.VariableNames)))
    error("matchedTable does not contain expected Stage 1 columns.");
end

matchedMask = startsWith(string(events.MatchStatus),"matched");
E = events(matchedMask,:);

if isempty(E), error("No matched Stage 1 events."); end

eventNumber = E.CommandEvent;
commandClass = string(E.CommandClass);
commandTime_s = E.CommandTime_s;
responsePeakTime_s = E.ResponseTime_s;

classes = ["zero_to_pos","pos_to_neg","neg_to_pos","neg_to_zero"];
nEvents = height(E);

fprintf("\nMatched events: %d\n",nEvents);
for c=1:numel(classes)
    fprintf("%-12s : %d\n",prettyTransition(classes(c)), ...
        nnz(commandClass==classes(c)));
end

%% FAST GRID =============================================================

if isnan(COMMON_DT_US), fastDt_us = Ts*1e6;
else, fastDt_us = COMMON_DT_US;
end

fastTime_us = (-FAST_WINDOW_PRE_US:fastDt_us:FAST_WINDOW_POST_US).';
nFast = numel(fastTime_us);

%% FAST PREALLOCATION ====================================================

I0star_mA = NaN(nEvents,1);
Ifstar_mA = NaN(nEvents,1);
stepMagnitude_mA = NaN(nEvents,1);

preSlope_mA_per_ms = NaN(nEvents,1);
postSlope_mA_per_ms = NaN(nEvents,1);
% Diagnostic metadata only: actual sampled trend-fit bounds, in us.
preFitStartUsed_us = NaN(nEvents,1);
preFitEndUsed_us = NaN(nEvents,1);
postFitStartUsed_us = NaN(nEvents,1);
postFitEndUsed_us = NaN(nEvents,1);

preFitR2 = NaN(nEvents,1);
postFitR2 = NaN(nEvents,1);

t10_us = NaN(nEvents,1);
t50_us = NaN(nEvents,1);
t90_us = NaN(nEvents,1);
t10_90_us = NaN(nEvents,1);

commandToT10_us = NaN(nEvents,1);
commandToT50_us = NaN(nEvents,1);
commandToT90_us = NaN(nEvents,1);

peakNormalized = NaN(nEvents,1);
overshoot_pct = NaN(nEvents,1);
settlingFromT10_us = NaN(nEvents,1);

preNormMean = NaN(nEvents,1);
postNormMean = NaN(nEvents,1);

validEvent = false(nEvents,1);
qualityReason = strings(nEvents,1);

normalizedRaw = NaN(nFast,nEvents);
normalizedDetrended = NaN(nFast,nEvents);

metricSmoothSamples = max(3,round(METRIC_SMOOTH_US*1e-6/Ts));
if mod(metricSmoothSamples,2)==0
    metricSmoothSamples = metricSmoothSamples+1;
end

%% FAST NORMALIZATION ====================================================

for e=1:nEvents

    tEdge = responsePeakTime_s(e);

    if e==1, prevEdge=-Inf; else, prevEdge=responsePeakTime_s(e-1); end
    if e==nEvents, nextEdge=Inf; else, nextEdge=responsePeakTime_s(e+1); end

    preStart = PRE_FIT_START_US;
    preEnd   = PRE_FIT_END_US;
    postStart = POST_FIT_START_US;
    postEnd   = POST_FIT_END_US;

    if isfinite(prevEdge)
        preStart = max(preStart, ...
            (prevEdge-tEdge)*1e6 + NEIGHBOUR_EDGE_GUARD_US);
    end

    if isfinite(nextEdge)
        postEnd = min(postEnd, ...
            (nextEdge-tEdge)*1e6 - NEIGHBOUR_EDGE_GUARD_US);
    end

    if preStart>=preEnd || postStart>=postEnd
        qualityReason(e)="trend_fit_window_invalid";
        continue;
    end

    preMask = t>=tEdge+preStart*1e-6 & t<=tEdge+preEnd*1e-6;
    postMask = t>=tEdge+postStart*1e-6 & t<=tEdge+postEnd*1e-6;

    if nnz(preMask)<20 || nnz(postMask)<20
        qualityReason(e)="too_few_trend_samples";
        continue;
    end

    preFitStartUsed_us(e) = (t(find(preMask,1,'first'))-tEdge)*1e6;
    preFitEndUsed_us(e) = (t(find(preMask,1,'last'))-tEdge)*1e6;
    postFitStartUsed_us(e) = (t(find(postMask,1,'first'))-tEdge)*1e6;
    postFitEndUsed_us(e) = (t(find(postMask,1,'last'))-tEdge)*1e6;

    [preCoeff,preFitR2(e)] = robustLinearFit( ...
        (t(preMask)-tEdge)*1e6,Iraw(preMask));

    [postCoeff,postFitR2(e)] = robustLinearFit( ...
        (t(postMask)-tEdge)*1e6,Iraw(postMask));

    I0star_mA(e)=preCoeff(2);
    Ifstar_mA(e)=postCoeff(2);

    preSlope_mA_per_ms(e)=preCoeff(1)*1000;
    postSlope_mA_per_ms(e)=postCoeff(1)*1000;

    stepMagnitude_mA(e)=Ifstar_mA(e)-I0star_mA(e);

    if abs(stepMagnitude_mA(e))<MIN_STEP_MAGNITUDE_mA
        qualityReason(e)="local_step_too_small";
        continue;
    end

    fm = t>=tEdge-FAST_WINDOW_PRE_US*1e-6 & ...
         t<=tEdge+FAST_WINDOW_POST_US*1e-6;

    if nnz(fm)<20
        qualityReason(e)="too_few_fast_samples";
        continue;
    end

    tx = (t(fm)-tEdge)*1e6;
    Ix = Iraw(fm);

    Ic = interp1(tx,Ix,fastTime_us,'linear',NaN);

    normalizedRaw(:,e)=(Ic-I0star_mA(e))/stepMagnitude_mA(e);

    Icorr=Ic;
    before=fastTime_us<0;
    after=~before;

    Icorr(before)=Ic(before)-preCoeff(1)*fastTime_us(before);
    Icorr(after)=Ic(after)-postCoeff(1)*fastTime_us(after);

    normalizedDetrended(:,e)= ...
        (Icorr-I0star_mA(e))/stepMagnitude_mA(e);

    ym=movmean(normalizedDetrended(:,e),metricSmoothSamples,'omitnan');

    t10_us(e)=firstCrossingTime(fastTime_us,ym,0.10);
    t50_us(e)=firstCrossingTime(fastTime_us,ym,0.50);
    t90_us(e)=firstCrossingTime(fastTime_us,ym,0.90);

    if all(isfinite([t10_us(e),t90_us(e)]))
        t10_90_us(e)=t90_us(e)-t10_us(e);
    end

    if isfinite(t10_us(e))
        commandToT10_us(e)= ...
            (tEdge+t10_us(e)*1e-6-commandTime_s(e))*1e6;
    end
    if isfinite(t50_us(e))
        commandToT50_us(e)= ...
            (tEdge+t50_us(e)*1e-6-commandTime_s(e))*1e6;
    end
    if isfinite(t90_us(e))
        commandToT90_us(e)= ...
            (tEdge+t90_us(e)*1e-6-commandTime_s(e))*1e6;
    end

    if isfinite(t90_us(e))
        mm=fastTime_us>=t90_us(e) & isfinite(ym);
        if any(mm)
            peakNormalized(e)=max(ym(mm));
            overshoot_pct(e)=max(0,(peakNormalized(e)-1)*100);
        end
    end

    if isfinite(t10_us(e))
        settlingFromT10_us(e)=settlingTimeAfterReference( ...
            fastTime_us,ym,t10_us(e),SETTLING_BAND,SETTLING_HOLD_US);
    end

    preNormMean(e)=mean(normalizedDetrended(fastTime_us<=-5,e),'omitnan');
    postNormMean(e)=mean(normalizedDetrended(fastTime_us>=10,e),'omitnan');

    passBaseline=abs(preNormMean(e))<=NORMALIZED_BASELINE_TOL;
    passFinal=abs(postNormMean(e)-1)<=NORMALIZED_FINAL_TOL;
    passCross=all(isfinite([t10_us(e),t50_us(e),t90_us(e)])) && ...
        t10_us(e)<t50_us(e) && t50_us(e)<t90_us(e);

    if ~passBaseline
        qualityReason(e)="normalized_pre_level_check_failed";
    elseif ~passFinal
        qualityReason(e)="normalized_post_level_check_failed";
    elseif ~passCross
        qualityReason(e)="normalized_crossing_check_failed";
    else
        validEvent(e)=true;
        qualityReason(e)="pass";
    end
end

eventMetrics = table( ...
    eventNumber,commandClass,commandTime_s,responsePeakTime_s, ...
    validEvent,qualityReason,I0star_mA,Ifstar_mA,stepMagnitude_mA, ...
    preSlope_mA_per_ms,postSlope_mA_per_ms,preFitR2,postFitR2, ...
    preNormMean,postNormMean,t10_us,t50_us,t90_us,t10_90_us, ...
    commandToT10_us,commandToT50_us,commandToT90_us, ...
    peakNormalized,overshoot_pct,settlingFromT10_us);

fprintf("\n============================================================\n");
fprintf("FAST NORMALIZATION SUMMARY\n");
fprintf("============================================================\n");
fprintf("Total matched : %d\n",nEvents);
fprintf("Valid         : %d\n",nnz(validEvent));
fprintf("Rejected      : %d\n",nnz(~validEvent));

%% FAST GROUPS ===========================================================

groups=struct();

for c=1:numel(classes)
    m=validEvent & commandClass==classes(c);
    fn=matlab.lang.makeValidName(classes(c));
    groups.(fn)=buildGroup(fastTime_us,normalizedRaw(:,m), ...
        normalizedDetrended(:,m),eventMetrics(m,:),classes(c));
end

bipolarMask=validEvent & ...
    (commandClass=="pos_to_neg" | commandClass=="neg_to_pos");

groups.bipolarCombined=buildGroup( ...
    fastTime_us,normalizedRaw(:,bipolarMask), ...
    normalizedDetrended(:,bipolarMask), ...
    eventMetrics(bipolarMask,:),"bipolar_combined");

Gpn=groups.pos_to_neg;
Gnp=groups.neg_to_pos;

symmetryRMSE=NaN;
symmetryMaxDifference=NaN;

if Gpn.N>0 && Gnp.N>0
    m=isfinite(Gpn.meanDetrended) & isfinite(Gnp.meanDetrended);
    d=Gpn.meanDetrended(m)-Gnp.meanDetrended(m);
    symmetryRMSE=sqrt(mean(d.^2));
    symmetryMaxDifference=max(abs(d));
end

%% T10 ALIGNED RESPONSES =================================================

t10AlignedTime_us=fastTime_us;
t10AlignedResponses=NaN(nFast,nEvents);

for e=1:nEvents
    if ~validEvent(e) || ~isfinite(t10_us(e)), continue; end
    shifted=fastTime_us-t10_us(e);
    t10AlignedResponses(:,e)=interp1(shifted, ...
        normalizedDetrended(:,e),t10AlignedTime_us,'linear',NaN);
end

%% COMMAND DELAY =========================================================

stage1PeakDelay_us=(responsePeakTime_s-commandTime_s)*1e6;

delayMetrics=table( ...
    eventNumber,commandClass,commandTime_s,responsePeakTime_s,validEvent, ...
    stage1PeakDelay_us,commandToT10_us,commandToT50_us,commandToT90_us, ...
    'VariableNames',{'EventNumber','TransitionClass','CommandTime_s', ...
    'Stage1GradientPeakTime_s','ValidEvent','CommandToGradientPeak_us', ...
    'CommandToT10_us','CommandToT50_us','CommandToT90_us'});

delay=struct();
delay.metrics=delayMetrics;
delay.classes=classes;
delay.sourceStage1Mat=resultsPath;
delay.captureRoot=captureRoot;

for c=1:numel(classes)
    m=validEvent & commandClass==classes(c);
    fn=matlab.lang.makeValidName(classes(c));

    D=struct();
    D.className=classes(c);
    D.N=nnz(m);
    D.eventNumber=eventNumber(m);
    D.commandToGradientPeak_us=stage1PeakDelay_us(m);
    D.commandToT10_us=commandToT10_us(m);
    D.commandToT50_us=commandToT50_us(m);
    D.commandToT90_us=commandToT90_us(m);

    D.gradientPeakMean_us=mean(D.commandToGradientPeak_us,'omitnan');
    D.gradientPeakSD_us=std(D.commandToGradientPeak_us,'omitnan');
    D.t10Mean_us=mean(D.commandToT10_us,'omitnan');
    D.t10SD_us=std(D.commandToT10_us,'omitnan');
    D.t50Mean_us=mean(D.commandToT50_us,'omitnan');
    D.t50SD_us=std(D.commandToT50_us,'omitnan');
    D.t90Mean_us=mean(D.commandToT90_us,'omitnan');
    D.t90SD_us=std(D.commandToT90_us,'omitnan');

    delay.byClass.(fn)=D;
end

%% PHYSICAL PHASE SEGMENTATION ==========================================

[~,ord]=sort(responsePeakTime_s);
ordEvent=eventNumber(ord);
ordClass=commandClass(ord);
ordTime=responsePeakTime_s(ord);

phasePolarity=strings(0,1);
phaseStartEvent=zeros(0,1);
phaseEndEvent=zeros(0,1);
phaseStart_s=zeros(0,1);
phaseEnd_s=zeros(0,1);

for k=1:numel(ordClass)-1
    a=ordClass(k);
    b=ordClass(k+1);

    if (a=="zero_to_pos" || a=="neg_to_pos") && b=="pos_to_neg"
        phasePolarity(end+1,1)="positive";
    elseif a=="pos_to_neg" && (b=="neg_to_pos" || b=="neg_to_zero")
        phasePolarity(end+1,1)="negative";
    else
        continue;
    end

    phaseStartEvent(end+1,1)=ordEvent(k);
    phaseEndEvent(end+1,1)=ordEvent(k+1);
    phaseStart_s(end+1,1)=ordTime(k);
    phaseEnd_s(end+1,1)=ordTime(k+1);
end

phaseDuration_us=(phaseEnd_s-phaseStart_s)*1e6;
phaseUsableDuration_us=phaseDuration_us- ...
    DROOP_START_GUARD_US-DROOP_END_GUARD_US;

vm=isfinite(phaseUsableDuration_us) & phaseUsableDuration_us>50;

phasePolarity=phasePolarity(vm);
phaseStartEvent=phaseStartEvent(vm);
phaseEndEvent=phaseEndEvent(vm);
phaseStart_s=phaseStart_s(vm);
phaseEnd_s=phaseEnd_s(vm);
phaseDuration_us=phaseDuration_us(vm);
phaseUsableDuration_us=phaseUsableDuration_us(vm);

phaseTable=table(phasePolarity,phaseStartEvent,phaseEndEvent, ...
    phaseStart_s,phaseEnd_s,phaseDuration_us,phaseUsableDuration_us);

%% REBASED SLOW DROOP ====================================================

droop=struct();

if isempty(phaseTable)

    warning("No complete passive-droop phases found.");
    droop.positive=emptyDroopGroup();
    droop.negative=emptyDroopGroup();
    droop.combined=emptyDroopGroup();

else

    if isnan(DROOP_FULL_DT_US), droopFullDt_us=Ts*1e6;
    else, droopFullDt_us=DROOP_FULL_DT_US;
    end

    commonMax_us=min(phaseUsableDuration_us);

    droopFullTime_us=(0:droopFullDt_us:commonMax_us).';
    droopModelTime_us=(0:DROOP_MODEL_DT_US:commonMax_us).';

    posRows=find(phaseTable.phasePolarity=="positive");
    negRows=find(phaseTable.phasePolarity=="negative");

    positiveDroop=extractDroopGroupV2( ...
        phaseTable(posRows,:),t,Iraw,droopFullTime_us,droopModelTime_us, ...
        DROOP_START_GUARD_US,DROOP_END_GUARD_US,Ts,DROOP_SMOOTH_US,+1, ...
        DROOP_REFERENCE_MODE,DROOP_REFERENCE_WINDOW_US,DROOP_LATE_WINDOW_US);

    negativeDroop=extractDroopGroupV2( ...
        phaseTable(negRows,:),t,Iraw,droopFullTime_us,droopModelTime_us, ...
        DROOP_START_GUARD_US,DROOP_END_GUARD_US,Ts,DROOP_SMOOTH_US,-1, ...
        DROOP_REFERENCE_MODE,DROOP_REFERENCE_WINDOW_US,DROOP_LATE_WINDOW_US);

    combinedDroop=combineDroopGroupsV2( ...
        droopFullTime_us,droopModelTime_us,positiveDroop,negativeDroop);

    % New fields
    droop.fullTime_us=droopFullTime_us;
    droop.fullTime_ms=droopFullTime_us/1000;
    droop.modelTime_us=droopModelTime_us;
    droop.modelTime_ms=droopModelTime_us/1000;

    % Compatibility aliases for the previous Stage 3 script
    droop.time_us=droopFullTime_us;
    droop.time_ms=droopFullTime_us/1000;

    droop.phaseTable=phaseTable;
    droop.positive=positiveDroop;
    droop.negative=negativeDroop;
    droop.combined=combinedDroop;

    droop.settings.startGuard_us=DROOP_START_GUARD_US;
    droop.settings.endGuard_us=DROOP_END_GUARD_US;
    droop.settings.smooth_us=DROOP_SMOOTH_US;
    droop.settings.fullDt_us=droopFullDt_us;
    droop.settings.modelDt_us=DROOP_MODEL_DT_US;
    droop.settings.referenceMode=DROOP_REFERENCE_MODE;
    droop.settings.referenceWindow_us=DROOP_REFERENCE_WINDOW_US;

    fprintf("\n============================================================\n");
    fprintf("REBASED PASSIVE-DROOP DATASET\n");
    fprintf("============================================================\n");
    fprintf("Reference mode : %s\n",DROOP_REFERENCE_MODE);
    fprintf("Start guard    : %.3f us\n",DROOP_START_GUARD_US);
    fprintf("End guard      : %.3f us\n",DROOP_END_GUARD_US);
    fprintf("Model grid dt  : %.3f us\n",DROOP_MODEL_DT_US);

    printDroopSummary("POSITIVE",positiveDroop);
    printDroopSummary("NEGATIVE",negativeDroop);

    fprintf("\nCOMBINED\n");
    fprintf("  N phases        : %d\n",combinedDroop.N);
    if combinedDroop.N>0
        fprintf("  Mean D(0)       : %.9f\n", ...
            combinedDroop.meanNormalizedMagnitude(1));
        fprintf("  Mean final D    : %.9f\n", ...
            combinedDroop.meanNormalizedMagnitude(end));
    end
end

%% DIAGNOSTIC TABLES (NO CHANGES TO MODELLING ARRAYS) =====================

trendFitWindows = table(eventNumber,preFitStartUsed_us,preFitEndUsed_us, ...
    postFitStartUsed_us,postFitEndUsed_us);

[fastClassSummary,delayClassSummary] = summarizeStage2Classes( ...
    groups,delay,classes);

droopNormalizationCheck = buildDroopNormalizationCheck( ...
    droop,plotConfig.normalizationTolerance);
droop.sourceStage1Mat = resultsPath;
droop.captureRoot = captureRoot;
droop.normalizationCheck = droopNormalizationCheck;
droop.phaseColumnMap = buildDroopColumnMap(droop);

fprintf("\nFast metrics by transition class (SD needs repeated events):\n");
disp(fastClassSummary);
fprintf("\nDelay metrics by transition class (peak and t10/t50/t90):\n");
disp(delayClassSummary);
fprintf("\nBipolar mean-curve RMSE: %.8f; max difference: %.8f\n", ...
    symmetryRMSE,symmetryMaxDifference);
if any(~validEvent)
    fprintf("\nRejected fast events:\n");
    disp(eventMetrics(~validEvent,["eventNumber","commandClass","qualityReason"]));
end
if ~isempty(droopNormalizationCheck)
    fprintf("Droop D(0)=1 checks passed: %d / %d phases\n", ...
        nnz(droopNormalizationCheck.StartAtOne),height(droopNormalizationCheck));
    if any(~droopNormalizationCheck.StartAtOne)
        warning('Stage2:DroopStartCheck', ...
            'Some initial droop values are missing or differ from 1. See Figure 12.');
    end
    fprintf("Complete finite model columns: %d / %d phases\n", ...
        nnz(droopNormalizationCheck.ModelColumnComplete), ...
        height(droopNormalizationCheck));
end

%% SAVE ==================================================================

outFolder=STAGE2_OUTPUT_FOLDER;
if ~isfolder(outFolder), mkdir(outFolder); end
figureFolder = fullfile(outFolder,"Figures");
if ~isfolder(figureFolder), mkdir(figureFolder); end

writetable(trendFitWindows,fullfile(outFolder,"LocalTrendFitWindows.csv"));
writetable(fastClassSummary,fullfile(outFolder,"FastClassSummary.csv"));
writetable(delayClassSummary,fullfile(outFolder,"CommandDelayClassSummary.csv"));
writetable(droopNormalizationCheck, ...
    fullfile(outFolder,"PassiveDroopNormalizationCheck.csv"));
writetable(droop.phaseColumnMap, ...
    fullfile(outFolder,"PassiveDroopModelColumnMap.csv"));

writetable(eventMetrics,fullfile(outFolder,"NormalizedEventMetrics.csv"));
writetable(delayMetrics,fullfile(outFolder,"CommandDelayMetrics.csv"));

save(fullfile(outFolder,"CommandDelayResults.mat"),"delay");

save(fullfile(outFolder,"PassiveDroopResults.mat"),"droop","-v7.3");

if isfield(droop,"phaseTable")
    writetable(droop.phaseTable, ...
        fullfile(outFolder,"PassiveDroopPhaseTable.csv"));
end

if isfield(droop,"positive") && droop.positive.N>0
    writeDroopMeanCsv(fullfile(outFolder,"PositiveDroopMean.csv"), ...
        droop.fullTime_ms,droop.positive);
    writeDroopPhaseMetricsCsv( ...
        fullfile(outFolder,"PositiveDroopPhaseMetrics.csv"), ...
        droop.positive);
    writeMatrixCsv(fullfile(outFolder,"PositiveDroopModelMatrix.csv"), ...
        droop.modelTime_ms,droop.positive.modelNormalizedMagnitude, ...
        "Time_ms","PosPhase");
end

if isfield(droop,"negative") && droop.negative.N>0
    writeDroopMeanCsv(fullfile(outFolder,"NegativeDroopMean.csv"), ...
        droop.fullTime_ms,droop.negative);
    writeDroopPhaseMetricsCsv( ...
        fullfile(outFolder,"NegativeDroopPhaseMetrics.csv"), ...
        droop.negative);
    writeMatrixCsv(fullfile(outFolder,"NegativeDroopModelMatrix.csv"), ...
        droop.modelTime_ms,droop.negative.modelNormalizedMagnitude, ...
        "Time_ms","NegPhase");
end

if isfield(droop,"combined") && droop.combined.N>0
    writeDroopMeanCsv(fullfile(outFolder,"CombinedDroopMean.csv"), ...
        droop.fullTime_ms,droop.combined);
    writeMatrixCsv(fullfile(outFolder,"CombinedDroopModelMatrix.csv"), ...
        droop.modelTime_ms,droop.combined.modelNormalizedMagnitude, ...
        "Time_ms","Phase");
end

normalization=struct();
normalization.sourceStage1Mat=resultsPath;
normalization.captureRoot=captureRoot;
normalization.outputRoot=captureRoot;
normalization.stageOutputFolder=outFolder;
normalization.outputLayout="sibling_stage_folders";

if isfield(R,"csvPath"), normalization.sourceCsvPath=R.csvPath; end

normalization.Ts=Ts;
normalization.Fs=Fs;

normalization.timeFromGradientPeak_us=fastTime_us;
normalization.eventMetrics=eventMetrics;
normalization.validEvent=validEvent;

normalization.normalizedRaw=normalizedRaw;
normalization.normalizedDetrended=normalizedDetrended;

normalization.timeFromT10_us=t10AlignedTime_us;
normalization.t10AlignedResponses=t10AlignedResponses;

normalization.groups=groups;
normalization.commandDelay=delay;
normalization.passiveDroop=droop;

normalization.bipolarSymmetryRMSE=symmetryRMSE;
normalization.bipolarMaximumDifference=symmetryMaxDifference;

normalization.pipelineName = "Script02_NormalizeTransitions";
normalization.processingBasis = "Uploaded Stage 2 V2";
normalization.diagnostics.trendFitWindows = trendFitWindows;
normalization.diagnostics.fastClassSummary = fastClassSummary;
normalization.diagnostics.delayClassSummary = delayClassSummary;
normalization.diagnostics.droopNormalizationCheck = droopNormalizationCheck;
normalization.diagnostics.figureFolder = figureFolder;
normalization.diagnostics.plotConfig = plotConfig;

normalization.settings.preFitStart_us = PRE_FIT_START_US;
normalization.settings.preFitEnd_us = PRE_FIT_END_US;
normalization.settings.postFitStart_us = POST_FIT_START_US;
normalization.settings.postFitEnd_us = POST_FIT_END_US;
normalization.settings.neighbourEdgeGuard_us = NEIGHBOUR_EDGE_GUARD_US;
normalization.settings.metricSmooth_us = METRIC_SMOOTH_US;
normalization.settings.settlingBand = SETTLING_BAND;
normalization.settings.settlingHold_us = SETTLING_HOLD_US;
normalization.settings.fastDt_us = fastDt_us;
normalization.settings.droopFullDt_us = DROOP_FULL_DT_US;
normalization.settings.droopReferenceWindow_us = DROOP_REFERENCE_WINDOW_US;
normalization.settings.droopLateWindow_us = DROOP_LATE_WINDOW_US;
normalization.settings.fastWindowPre_us=FAST_WINDOW_PRE_US;
normalization.settings.fastWindowPost_us=FAST_WINDOW_POST_US;
normalization.settings.droopStartGuard_us=DROOP_START_GUARD_US;
normalization.settings.droopEndGuard_us=DROOP_END_GUARD_US;
normalization.settings.droopSmooth_us=DROOP_SMOOTH_US;
normalization.settings.droopModelDt_us=DROOP_MODEL_DT_US;
normalization.settings.droopReferenceMode=DROOP_REFERENCE_MODE;

save(fullfile(outFolder,"NormalizedTransitions.mat"), ...
    "normalization","-v7.3");

%% BUILD AND EXPORT ALL DIAGNOSTICS ======================================
% Core MAT/CSV outputs are already safe if a graphics/export error occurs.
% Only figures created here are exported; unrelated windows are not scanned.
plotData = struct();
plotData.t = t;
plotData.currentRaw_mA = Iraw;
plotData.eventMetrics = eventMetrics;
plotData.trendFitWindows = trendFitWindows;
plotData.classes = classes;
plotData.groups = groups;
plotData.time_us = fastTime_us;
plotData.timeFromT10_us = t10AlignedTime_us;
plotData.t10AlignedResponses = t10AlignedResponses;
plotData.bipolarMask = bipolarMask;
plotData.droop = droop;
plotData.symmetryRMSE = symmetryRMSE;
plotData.symmetryMaxDifference = symmetryMaxDifference;
plotData.droopCheck = droopNormalizationCheck;

figureManifest = plotAndSaveStage2Diagnostics(plotData,plotConfig,figureFolder);
normalization.diagnostics.figureManifest = figureManifest;
save(fullfile(outFolder,"NormalizedTransitions.mat"), ...
    "normalization","-v7.3");

fprintf("\n============================================================\n");
fprintf("STAGE 2 COMPLETE\n");
fprintf("============================================================\n");
fprintf("Saved to:\n%s\n",outFolder);
fprintf("Figures:\n%s\n",figureFolder);
fprintf("Diagnostic PNG exports: %d / %d\n", ...
    nnz(figureManifest.PNGSaved),height(figureManifest));
if any(~figureManifest.PlotSucceeded | ~figureManifest.PNGSaved)
    warning('Stage2:IncompleteDiagnostics', ...
        'Some diagnostics failed. Check DiagnosticFigureManifest.csv and warnings.');
end

fprintf("\nPrimary modelling files:\n");
fprintf("  NormalizedTransitions.mat  [fast dynamics]\n");
fprintf("  CommandDelayResults.mat    [delay]\n");
fprintf("  PassiveDroopResults.mat    [rebased slow droop]\n");

fprintf("\nStage 3 slow-droop inputs:\n");
fprintf("  droop.modelTime_ms\n");
fprintf("  droop.positive.modelNormalizedMagnitude\n");
fprintf("  droop.negative.modelNormalizedMagnitude\n");
fprintf("  droop.combined.modelNormalizedMagnitude\n");

fprintf("\nFit Stage 3 droop using the model-grid matrices, and split\n");
fprintf("training/validation by WHOLE PHASES, not by samples.\n");

%% LOCAL FUNCTIONS =======================================================

function [coeff,R2]=robustLinearFit(x,y)
x=x(:); y=y(:);
g=isfinite(x)&isfinite(y); x=x(g); y=y(g);
if numel(x)<3, coeff=[NaN NaN]; R2=NaN; return; end
c0=polyfit(x,y,1); r=y-polyval(c0,x);
med=median(r); sig=1.4826*median(abs(r-med));
if ~isfinite(sig)||sig<=0, sig=std(r); end
if ~isfinite(sig)||sig<=0, keep=true(size(r));
else, keep=abs(r-med)<=4*sig; end
if nnz(keep)<3, keep=true(size(r)); end
coeff=polyfit(x(keep),y(keep),1);
yh=polyval(coeff,x(keep)); yy=y(keep);
den=sum((yy-mean(yy)).^2);
if den>0, R2=1-sum((yy-yh).^2)/den; else, R2=NaN; end
end

function tc=firstCrossingTime(t,y,level)
tc=NaN;
g=isfinite(t)&isfinite(y); t=t(g); y=y(g);
if numel(t)<2, return; end
i=find(y(1:end-1)<level & y(2:end)>=level,1,'first');
if isempty(i), return; end
if y(i+1)==y(i), tc=t(i+1);
else
    a=(level-y(i))/(y(i+1)-y(i));
    tc=t(i)+a*(t(i+1)-t(i));
end
end

function st=settlingTimeAfterReference(t,y,tRef,band,holdTime)
st=NaN;
g=isfinite(t)&isfinite(y)&t>=tRef;
tt=t(g); yy=y(g);
if numel(tt)<2, return; end
dt=median(diff(tt));
if ~isfinite(dt)||dt<=0, return; end
n=max(1,ceil(holdTime/dt));
in=abs(yy-1)<=band;
run=movsum(double(in),[0 n-1]);
i=find(run>=n,1,'first');
if ~isempty(i), st=tt(i)-tRef; end
end

function G=buildGroup(time_us,raw,detrended,metrics,name)
G=struct();
G.className=name;
G.time_us=time_us;
G.rawResponses=raw;
G.detrendedResponses=detrended;
G.eventMetrics=metrics;
G.N=size(detrended,2);
if G.N>0
    G.meanRaw=mean(raw,2,'omitnan');
    G.stdRaw=std(raw,0,2,'omitnan');
    G.meanDetrended=mean(detrended,2,'omitnan');
    G.stdDetrended=std(detrended,0,2,'omitnan');
else
    G.meanRaw=NaN(size(time_us));
    G.stdRaw=NaN(size(time_us));
    G.meanDetrended=NaN(size(time_us));
    G.stdDetrended=NaN(size(time_us));
end
end

function G=extractDroopGroupV2(phaseTable,t,Iraw,fullTime_us,modelTime_us, ...
    startGuard_us,endGuard_us,Ts,smooth_us,expectedSign,referenceMode, ...
    referenceWindow_us,lateWindow_us)

G=struct();
G.phaseTable=phaseTable;
G.N=height(phaseTable);

G.time_us=fullTime_us;
G.time_ms=fullTime_us/1000;
G.fullTime_us=fullTime_us;
G.fullTime_ms=fullTime_us/1000;
G.modelTime_us=modelTime_us;
G.modelTime_ms=modelTime_us/1000;

nf=numel(fullTime_us);
nm=numel(modelTime_us);

G.rawSigned_mA=NaN(nf,G.N);
G.magnitude_mA=NaN(nf,G.N);
G.magnitudeSmooth_mA=NaN(nf,G.N);
G.normalizedMagnitude=NaN(nf,G.N);
G.modelNormalizedMagnitude=NaN(nm,G.N);

G.initialMagnitude_mA=NaN(G.N,1);   % compatibility alias
G.referenceMagnitude_mA=NaN(G.N,1);
G.robustEarlyMagnitude_mA=NaN(G.N,1);
G.finalMagnitude_mA=NaN(G.N,1);
G.droopAmount_mA=NaN(G.N,1);
G.finalNormalizedMagnitude=NaN(G.N,1);

% Retain old fields for compatibility/reporting
G.linearSlope_mA_per_ms=NaN(G.N,1);
G.linearIntercept_mA=NaN(G.N,1);
G.linearFitR2=NaN(G.N,1);

ns=max(3,round(smooth_us*1e-6/Ts));
if mod(ns,2)==0, ns=ns+1; end

for k=1:G.N

    us=phaseTable.phaseStart_s(k)+startGuard_us*1e-6;
    ue=phaseTable.phaseEnd_s(k)-endGuard_us*1e-6;

    m=t>=us & t<=ue;
    if nnz(m)<3, continue; end

    tx=(t(m)-us)*1e6;
    signed=interp1(tx,Iraw(m),fullTime_us,'linear',NaN);
    G.rawSigned_mA(:,k)=signed;

    if expectedSign>0, mag=signed; else, mag=-signed; end

    G.magnitude_mA(:,k)=mag;
    ms=movmean(mag,ns,'omitnan');
    G.magnitudeSmooth_mA(:,k)=ms;

    early=fullTime_us>=0 & ...
        fullTime_us<=min(referenceWindow_us,fullTime_us(end));

    G.robustEarlyMagnitude_mA(k)=median(ms(early),'omitnan');

    switch lower(string(referenceMode))
        case "first_smoothed_sample"
            iv=find(isfinite(ms),1,'first');
            if isempty(iv), continue; end
            Iref=ms(iv);
        case "early_median"
            Iref=G.robustEarlyMagnitude_mA(k);
        otherwise
            error("Unknown DROOP_REFERENCE_MODE: %s",referenceMode);
    end

    if ~isfinite(Iref) || Iref<=0, continue; end

    G.referenceMagnitude_mA(k)=Iref;
    G.initialMagnitude_mA(k)=Iref;

    D=ms/Iref;
    G.normalizedMagnitude(:,k)=D;

    G.modelNormalizedMagnitude(:,k)=interp1( ...
        fullTime_us,D,modelTime_us,'linear',NaN);

    lateStart=max(0,fullTime_us(end)-lateWindow_us);
    late=fullTime_us>=lateStart;

    G.finalMagnitude_mA(k)=median(ms(late),'omitnan');
    G.droopAmount_mA(k)=Iref-G.finalMagnitude_mA(k);
    G.finalNormalizedMagnitude(k)=median(D(late),'omitnan');

    % Descriptive linear fit only. Stage 3 should fit candidate models.
    fit=isfinite(ms);
    if nnz(fit)>=3
        x=fullTime_us(fit)/1000;
        y=ms(fit);
        cf=polyfit(x,y,1);
        yh=polyval(cf,x);
        G.linearSlope_mA_per_ms(k)=cf(1);
        G.linearIntercept_mA(k)=cf(2);
        den=sum((y-mean(y)).^2);
        if den>0
            G.linearFitR2(k)=1-sum((y-yh).^2)/den;
        end
    end
end

G.meanRawSigned_mA=mean(G.rawSigned_mA,2,'omitnan');
G.stdRawSigned_mA=std(G.rawSigned_mA,0,2,'omitnan');

G.meanMagnitude_mA=mean(G.magnitudeSmooth_mA,2,'omitnan');
G.stdMagnitude_mA=std(G.magnitudeSmooth_mA,0,2,'omitnan');

G.meanNormalizedMagnitude=mean(G.normalizedMagnitude,2,'omitnan');
G.stdNormalizedMagnitude=std(G.normalizedMagnitude,0,2,'omitnan');

G.meanModelNormalizedMagnitude= ...
    mean(G.modelNormalizedMagnitude,2,'omitnan');
G.stdModelNormalizedMagnitude= ...
    std(G.modelNormalizedMagnitude,0,2,'omitnan');

% Compatibility fields from previous Stage 2
G.deltaFromStart_mA=G.magnitudeSmooth_mA-G.referenceMagnitude_mA.';
G.meanDeltaFromStart_mA=mean(G.deltaFromStart_mA,2,'omitnan');
G.stdDeltaFromStart_mA=std(G.deltaFromStart_mA,0,2,'omitnan');
end

function C=combineDroopGroupsV2(fullTime_us,modelTime_us,P,N)

C=struct();

C.time_us=fullTime_us;
C.time_ms=fullTime_us/1000;
C.fullTime_us=fullTime_us;
C.fullTime_ms=fullTime_us/1000;
C.modelTime_us=modelTime_us;
C.modelTime_ms=modelTime_us/1000;

C.magnitude_mA=[P.magnitudeSmooth_mA,N.magnitudeSmooth_mA];
C.normalizedMagnitude=[P.normalizedMagnitude,N.normalizedMagnitude];
C.modelNormalizedMagnitude=[ ...
    P.modelNormalizedMagnitude,N.modelNormalizedMagnitude];

C.phaseType=[repmat("positive",P.N,1);repmat("negative",N.N,1)];
C.N=size(C.normalizedMagnitude,2);

C.meanMagnitude_mA=mean(C.magnitude_mA,2,'omitnan');
C.stdMagnitude_mA=std(C.magnitude_mA,0,2,'omitnan');

C.meanNormalizedMagnitude=mean(C.normalizedMagnitude,2,'omitnan');
C.stdNormalizedMagnitude=std(C.normalizedMagnitude,0,2,'omitnan');

C.meanModelNormalizedMagnitude= ...
    mean(C.modelNormalizedMagnitude,2,'omitnan');
C.stdModelNormalizedMagnitude= ...
    std(C.modelNormalizedMagnitude,0,2,'omitnan');

% Compatibility fields
C.linearSlope_mA_per_ms=[P.linearSlope_mA_per_ms;N.linearSlope_mA_per_ms];
C.linearIntercept_mA=[P.linearIntercept_mA;N.linearIntercept_mA];
C.linearFitR2=[P.linearFitR2;N.linearFitR2];

C.deltaFromStart_mA=[P.deltaFromStart_mA,N.deltaFromStart_mA];
C.meanDeltaFromStart_mA=mean(C.deltaFromStart_mA,2,'omitnan');
C.stdDeltaFromStart_mA=std(C.deltaFromStart_mA,0,2,'omitnan');
end

function G=emptyDroopGroup()
G=struct(); G.N=0;
end

function printDroopSummary(label,G)
fprintf("\n%s\n",label);
fprintf("  N phases              : %d\n",G.N);
if G.N==0, return; end
fprintf("  Reference mean        : %.6f mA\n", ...
    mean(G.referenceMagnitude_mA,'omitnan'));
fprintf("  Robust early mean     : %.6f mA\n", ...
    mean(G.robustEarlyMagnitude_mA,'omitnan'));
fprintf("  Final mean            : %.6f mA\n", ...
    mean(G.finalMagnitude_mA,'omitnan'));
fprintf("  Droop mean            : %.6f mA\n", ...
    mean(G.droopAmount_mA,'omitnan'));
fprintf("  Mean D(0)             : %.9f\n", ...
    mean(G.normalizedMagnitude(1,:),'omitnan'));
fprintf("  Final normalized mean : %.9f\n", ...
    mean(G.finalNormalizedMagnitude,'omitnan'));
end

function writeDroopMeanCsv(filename,time_ms,G)
T=table(time_ms,G.meanMagnitude_mA,G.stdMagnitude_mA, ...
    G.meanNormalizedMagnitude,G.stdNormalizedMagnitude, ...
    'VariableNames',{'Time_ms','MeanMagnitude_mA','SDMagnitude_mA', ...
    'MeanNormalizedMagnitude','SDNormalizedMagnitude'});
writetable(T,filename);
end

function writeDroopPhaseMetricsCsv(filename,G)
if G.N==0, return; end
T=table(G.phaseTable.phaseStartEvent,G.phaseTable.phaseEndEvent, ...
    G.referenceMagnitude_mA,G.robustEarlyMagnitude_mA, ...
    G.finalMagnitude_mA,G.droopAmount_mA,G.finalNormalizedMagnitude, ...
    G.linearSlope_mA_per_ms,G.linearFitR2, ...
    'VariableNames',{'StartEvent','EndEvent','ReferenceMagnitude_mA', ...
    'RobustEarlyMagnitude_mA','FinalMagnitude_mA','DroopAmount_mA', ...
    'FinalNormalizedMagnitude','DescriptiveLinearSlope_mA_per_ms', ...
    'DescriptiveLinearFitR2'});
writetable(T,filename);
end

function writeMatrixCsv(filename,time_ms,Y,timeName,prefix)
n=size(Y,2);
names=strings(1,n+1);
names(1)=timeName;
for k=1:n, names(k+1)=sprintf('%s_%02d',prefix,k); end
T=array2table([time_ms,Y],'VariableNames',cellstr(names));
writetable(T,filename);
end

function label=prettyTransition(type)
switch string(type)
    case "zero_to_pos", label="0 -> +I";
    case "pos_to_neg", label="+I -> -I";
    case "neg_to_pos", label="-I -> +I";
    case "neg_to_zero", label="-I -> 0";
    case "bipolar_combined", label="Combined bipolar";
    otherwise, label=string(type);
end
end

%% DIAGNOSTIC HELPERS =====================================================

function [F,D] = summarizeStage2Classes(groups,delay,classes)
n = numel(classes);
fv = NaN(n,9);
dv = NaN(n,9);
for c = 1:n
    name = matlab.lang.makeValidName(classes(c));
    G = groups.(name);
    M = G.eventMetrics;
    fv(c,:) = [G.N,mean(abs(M.stepMagnitude_mA),'omitnan'), ...
        mean(M.t10_us,'omitnan'),mean(M.t50_us,'omitnan'), ...
        mean(M.t90_us,'omitnan'),mean(M.t10_90_us,'omitnan'), ...
        repeatedSD(M.t10_90_us),mean(M.overshoot_pct,'omitnan'), ...
        mean(M.settlingFromT10_us,'omitnan')];
    B = delay.byClass.(name);
    dv(c,:) = [B.N,B.gradientPeakMean_us,repeatedSD(B.commandToGradientPeak_us), ...
        B.t10Mean_us,repeatedSD(B.commandToT10_us), ...
        B.t50Mean_us,repeatedSD(B.commandToT50_us), ...
        B.t90Mean_us,repeatedSD(B.commandToT90_us)];
end
F = [table(classes(:),'VariableNames',{'TransitionClass'}), ...
    array2table(fv,'VariableNames',{'N','MeanAbsStep_mA','MeanT10_us', ...
    'MeanT50_us','MeanT90_us','MeanT10To90_us','SDT10To90_us', ...
    'MeanOvershoot_pct','MeanSettlingFromT10_us'})];
D = [table(classes(:),'VariableNames',{'TransitionClass'}), ...
    array2table(dv,'VariableNames',{'N','PeakMean_us','PeakSD_us', ...
    'T10Mean_us','T10SD_us','T50Mean_us','T50SD_us','T90Mean_us','T90SD_us'})];
end

function value = repeatedSD(x)
x = x(isfinite(x));
if numel(x)<2, value = NaN; else, value = std(x); end
end

function T = buildDroopNormalizationCheck(droop,tol)
names = {'PhaseNumber','Polarity','WithinPolarity','StartEvent','EndEvent', ...
    'D0Full','D0Model','DLastFull','DLastModel','DLateMedian', ...
    'FiniteModelSamples','ModelSamples','StartAtOne','ModelColumnComplete'};
types = ["double","string",repmat("double",1,10),"logical","logical"];
T = table('Size',[0 numel(names)],'VariableTypes',cellstr(types), ...
    'VariableNames',names);
if ~isfield(droop,'phaseTable'), return; end
polarityNames = ["positive","negative"];
for p = 1:2
    G = droop.(polarityNames(p));
    for k = 1:G.N
        [~,phaseNumber] = ismember(G.phaseTable.phaseStartEvent(k), ...
            droop.phaseTable.phaseStartEvent);
        fullColumn = G.normalizedMagnitude(:,k);
        modelColumn = G.modelNormalizedMagnitude(:,k);
        d0 = fullColumn(1);
        d0Model = modelColumn(1);
        atOne = isfinite(d0) && isfinite(d0Model) && ...
            abs(d0-1)<=tol && abs(d0Model-1)<=tol;
        T(end+1,:) = {phaseNumber,polarityNames(p),k, ...
            G.phaseTable.phaseStartEvent(k),G.phaseTable.phaseEndEvent(k), ...
            d0,d0Model,fullColumn(end),modelColumn(end), ...
            G.finalNormalizedMagnitude(k),nnz(isfinite(modelColumn)), ...
            numel(modelColumn),atOne,all(isfinite(modelColumn))}; %#ok<AGROW>
    end
end
T = sortrows(T,'PhaseNumber');
end

function T = buildDroopColumnMap(droop)
names = {'CombinedColumn','CombinedCSVColumn','Polarity','PolarityColumn', ...
    'PolarityCSVColumn','PhaseNumber','StartEvent','EndEvent'};
types = {'double','string','string','double','string','double','double','double'};
T = table('Size',[0 numel(names)],'VariableTypes',types,'VariableNames',names);
if ~isfield(droop,'phaseTable'), return; end
polarityNames = ["positive","negative"];
prefixes = ["PosPhase","NegPhase"];
column = 0;
for p = 1:2
    G = droop.(polarityNames(p));
    for k = 1:G.N
        column = column+1;
        [~,phaseNumber] = ismember(G.phaseTable.phaseStartEvent(k), ...
            droop.phaseTable.phaseStartEvent);
        T(end+1,:) = {column,string(sprintf('Phase_%02d',column)), ...
            polarityNames(p),k,string(sprintf('%s_%02d',prefixes(p),k)), ...
            phaseNumber,G.phaseTable.phaseStartEvent(k), ...
            G.phaseTable.phaseEndEvent(k)}; %#ok<AGROW>
    end
end
end

function manifest = plotAndSaveStage2Diagnostics(P,cfg,folder)
stems = [ ...
    "01_LocalDetrendingVerification"
    "02_NormalizedOverlaysByClass"
    "03_BipolarSymmetry"
    "04_RawVsDetrendedNormalization"
    "05_FastMetricRepeatability"
    "06_RefinedCommandResponseDelay"
    "07_T10AlignedBipolarTransitions"
    "08_PassiveDroopSeparatedRawMagnitude"
    "09_PassiveDroopRebasedIndividual"
    "10_PassiveDroopMeanComparison"
    "11_PassiveDroopModelGrid"
    "12_PassiveDroopNormalizationCheck"];
n = numel(stems);
plotOK = false(n,1); pngOK = false(n,1); figOK = false(n,1);
status = strings(n,1); details = strings(n,1);
for j = 1:n
    fprintf('  Building %s\n',stems(j));
    fig = [];
    try
        % Build/export invisibly at the specified size, then show a docked
        % tab. This avoids separate windows appearing during processing.
        fig = figure('Name',char(stems(j)),'NumberTitle','off', ...
            'Color','w','Visible','off','WindowStyle','normal', ...
            'Units','pixels','Position',[60 60 1200 800], ...
            'DefaultAxesColor','w','DefaultAxesXColor',[.1 .1 .1], ...
            'DefaultAxesYColor',[.1 .1 .1],'DefaultTextColor',[.1 .1 .1], ...
            'DefaultTextInterpreter','none','DefaultAxesFontSize',10, ...
            'DefaultAxesGridColor',[.55 .55 .55]);
        switch j
            case 1
                set(fig,'Position',[40 40 1300 1100]);
                plotLocalTrendChecks(fig,P,cfg);
            case 2
                plotFastClassOverlays(fig,P,cfg);
            case 3
                plotBipolarSymmetry(fig,P,cfg);
            case 4
                plotRawDetrendedComparison(fig,P,cfg);
            case 5
                ax = axes('Parent',fig);
                plotClassScatter(ax,P,P.eventMetrics.t10_90_us,cfg, ...
                    'Fast transition repeatability','10-90 transition time (us)');
            case 6
                set(fig,'Position',[50 50 1200 1000]);
                plotRefinedDelays(fig,P,cfg);
            case 7
                plotT10Aligned(fig,P,cfg);
            case {8,9}
                plotDroopIndividual(fig,P,cfg,j==9);
            case 10
                plotDroopMeans(fig,P,cfg);
            case 11
                plotDroopModelGrid(fig,P,cfg);
            case 12
                plotDroopNormalizationCheck(fig,P,cfg);
        end
        plotOK(j) = true;
        status(j) = "plotted";
    catch ME
        status(j) = "plot_failed";
        details(j) = string(ME.message);
        warning('Stage2:DiagnosticPlot','%s: %s',stems(j),ME.message);
        % A clearly marked placeholder replaces any stale PNG for this view.
        if ~isempty(fig) && isgraphics(fig)
            clf(fig);
            ax = axes('Parent',fig);
            showNoData(ax,{'Diagnostic could not be plotted.', ...
                'See the console and DiagnosticFigureManifest.csv.'});
        end
    end
    if ~isempty(fig) && isgraphics(fig)
        try
            styleDiagnosticFigure(fig);
            drawnow;
            pngPath = fullfile(folder,stems(j)+".png");
            try
                exportgraphics(fig,pngPath,'Resolution',cfg.resolution, ...
                    'BackgroundColor','white');
            catch firstExportError
                set(fig,'PaperPositionMode','auto','InvertHardcopy','off');
                print(fig,char(pngPath),'-dpng',sprintf('-r%d',cfg.resolution));
                details(j) = details(j)+" PNG used print fallback: "+ ...
                    string(firstExportError.message);
            end
            info = dir(pngPath);
            pngOK(j) = ~isempty(info) && info(1).bytes>0;
        catch ME
            details(j) = details(j)+" PNG export failed: "+string(ME.message);
            warning('Stage2:PNGExport','%s: %s',stems(j),ME.message);
        end
        % Dock after PNG export so the container size does not change the
        % exported layout. The editable FIG retains the chosen window style.
        if strcmpi(cfg.visible,'on')
            try
                set(fig,'WindowStyle',char(cfg.windowStyle),'Visible','on');
            catch ME
                details(j) = details(j)+" Figure display failed: "+string(ME.message);
                warning('Stage2:FigureDisplay','%s: %s',stems(j),ME.message);
            end
        end
        if cfg.saveEditable
            try
                savefig(fig,fullfile(folder,stems(j)+".fig"));
                figOK(j) = true;
            catch ME
                details(j) = details(j)+" FIG export failed: "+string(ME.message);
                warning('Stage2:FIGExport','%s: %s',stems(j),ME.message);
            end
        end
        if strcmpi(cfg.visible,'off'), close(fig); end
    end
end
manifest = table(stems,stems+".png",plotOK,pngOK,figOK,status,details, ...
    'VariableNames',{'Figure','PNGFile','PlotSucceeded','PNGSaved', ...
    'EditableFIGSaved','Status','Details'});
writetable(manifest,fullfile(folder,"DiagnosticFigureManifest.csv"));
end

function plotLocalTrendChecks(fig,P,cfg)
M = P.eventMetrics;
W = P.trendFitWindows;
if isempty(cfg.localEventNumbers)
    % Include both singleton classes plus early/late bipolar examples.
    selected = [];
    for c = 1:numel(P.classes)
        rows = find(M.commandClass==P.classes(c));
        if ~isempty(rows), selected = [selected;rows(1)]; end %#ok<AGROW>
    end
    remaining = unique([find(~M.validEvent); ...
        round(linspace(1,height(M),max(2,cfg.maxLocalEvents))).'], 'stable');
    selected = unique([selected;remaining],'stable');
    selected = sort(selected(1:min(numel(selected),cfg.maxLocalEvents)));
else
    selected = find(ismember(M.eventNumber,cfg.localEventNumbers));
end
if isempty(selected)
    showNoData(axes('Parent',fig),'No requested command event numbers found.');
    return;
end
tl = tiledlayout(fig,ceil(numel(selected)/2),2, ...
    'TileSpacing','compact','Padding','compact');
title(tl,{'Local trends used for normalization: raw CH3 and fitted spans', ...
    'Solid = fitted span; dashed = extrapolation to the gradient peak'});
legendCreated = false;
for j = 1:numel(selected)
    e = selected(j);
    ax = nexttile(tl); hold(ax,'on');
    edge = M.responsePeakTime_s(e);
    mask = P.t>=edge+cfg.localView_us(1)*1e-6 & ...
        P.t<=edge+cfg.localView_us(2)*1e-6;
    x = (P.t(mask)-edge)*1e6;
    plot(ax,x,P.currentRaw_mA(mask),'Color',[.45 .55 .66], ...
        'LineWidth',.6,'DisplayName','Raw CH3');
    coeffPre = [M.preSlope_mA_per_ms(e)/1000 M.I0star_mA(e)];
    coeffPost = [M.postSlope_mA_per_ms(e)/1000 M.Ifstar_mA(e)];
    pre = [W.preFitStartUsed_us(e) W.preFitEndUsed_us(e)];
    post = [W.postFitStartUsed_us(e) W.postFitEndUsed_us(e)];
    if all(isfinite([coeffPre coeffPost pre post]))
        plot(ax,pre,polyval(coeffPre,pre),'-','Color',cfg.positiveColor, ...
            'LineWidth',1.8,'DisplayName','Pre-trend fit');
        plot(ax,[pre(2) 0],polyval(coeffPre,[pre(2) 0]),'--', ...
            'Color',cfg.positiveColor,'LineWidth',1.4,'HandleVisibility','off');
        plot(ax,post,polyval(coeffPost,post),'-','Color',cfg.negativeColor, ...
            'LineWidth',1.8,'DisplayName','Post-trend fit');
        plot(ax,[0 post(1)],polyval(coeffPost,[0 post(1)]),'--', ...
            'Color',cfg.negativeColor,'LineWidth',1.4,'HandleVisibility','off');
        plot(ax,0,M.I0star_mA(e),'o','Color',cfg.positiveColor, ...
            'MarkerFaceColor','w','MarkerSize',6,'DisplayName','I0*');
        plot(ax,0,M.Ifstar_mA(e),'s','Color',cfg.negativeColor, ...
            'MarkerFaceColor','w','MarkerSize',6,'DisplayName','If*');
        if ~legendCreated
            lg = legend(ax,'show','Orientation','horizontal','NumColumns',5);
            lg.Layout.Tile = 'south';
            legendCreated = true;
        end
    end
    xline(ax,0,':','Color',[.3 .3 .3],'HandleVisibility','off');
    grid(ax,'on'); xlim(ax,cfg.localView_us);
    xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Current (mA)');
    title(ax,{sprintf('Event %d: %s',M.eventNumber(e), ...
        prettyTransition(M.commandClass(e))),char(M.qualityReason(e))});
end
end

function plotFastClassOverlays(fig,P,cfg)
tl = tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');
title(tl,'Locally detrended normalized transitions: all accepted events');
for c = 1:numel(P.classes)
    ax = nexttile(tl);
    G = P.groups.(matlab.lang.makeValidName(P.classes(c)));
    overlayTraces(ax,P.time_us,G.detrendedResponses,cfg, ...
        'Individual transitions','Class mean');
    addFastGuides(ax,cfg);
    xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Normalized response');
    rejected = nnz(~P.eventMetrics.validEvent & ...
        P.eventMetrics.commandClass==P.classes(c));
    title(ax,sprintf('%s | accepted %d, rejected %d', ...
        prettyTransition(P.classes(c)),G.N,rejected));
end
end

function plotBipolarSymmetry(fig,P,cfg)
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
title(tl,'Bipolar symmetry at the gradient-peak reference');
A = P.groups.pos_to_neg;
B = P.groups.neg_to_pos;
ax = nexttile(tl); hold(ax,'on');
plot(ax,P.time_us,A.meanDetrended,'Color',cfg.classColors(2,:), ...
    'LineWidth',1.8,'DisplayName','+I -> -I mean');
plot(ax,P.time_us,B.meanDetrended,'--','Color',cfg.classColors(3,:), ...
    'LineWidth',1.8,'DisplayName','-I -> +I mean');
addFastGuides(ax,cfg); legend(ax,'show','Location','best');
xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Normalized response');
if A.N==0 || B.N==0, showNoData(ax,'Both bipolar classes are needed for comparison.'); end
ax = nexttile(tl); hold(ax,'on');
plot(ax,P.time_us,A.meanDetrended-B.meanDetrended, ...
    'Color',cfg.meanColor,'LineWidth',1.4);
yline(ax,0,':','HandleVisibility','off'); grid(ax,'on');
xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Difference in means');
title(ax,sprintf('(+I -> -I) minus (-I -> +I): RMSE %.6g, max |difference| %.6g', ...
    P.symmetryRMSE,P.symmetryMaxDifference));
end

function plotRawDetrendedComparison(fig,P,cfg)
G = P.groups.bipolarCombined;
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
title(tl,'Effect of local detrending on the combined bipolar mean');
ax = nexttile(tl); hold(ax,'on');
plot(ax,P.time_us,G.meanRaw,'Color',cfg.positiveColor,'LineWidth',1.8, ...
    'DisplayName','Raw normalized mean');
plot(ax,P.time_us,G.meanDetrended,'--','Color',cfg.negativeColor,'LineWidth',1.8, ...
    'DisplayName','Locally detrended mean');
addFastGuides(ax,cfg); legend(ax,'show','Location','best');
xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Normalized response');
if G.N==0, showNoData(ax,'No accepted bipolar transitions.'); end
ax = nexttile(tl); hold(ax,'on');
delta = G.meanDetrended-G.meanRaw;
plot(ax,P.time_us,delta,'Color',cfg.meanColor,'LineWidth',1.4);
yline(ax,0,':','HandleVisibility','off'); grid(ax,'on');
xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Detrended minus raw');
title(ax,'Correction size on its own scale (same event set in both means)');
end

function plotClassScatter(ax,P,values,cfg,heading,yLabel)
hold(ax,'on'); M = P.eventMetrics;
hasPoints = false;
for c = 1:numel(P.classes)
    mask = M.validEvent & M.commandClass==P.classes(c) & isfinite(values);
    if any(mask)
        scatter(ax,M.eventNumber(mask),values(mask),32,cfg.classColors(c,:), ...
            'filled','DisplayName',prettyTransition(P.classes(c)));
        hasPoints = true;
    end
end
grid(ax,'on'); xlabel(ax,'Command event'); ylabel(ax,yLabel); title(ax,heading);
if hasPoints
    legend(ax,'show','Location','best');
else
    showNoData(ax,'No accepted finite measurements for this diagnostic.');
end
end

function plotRefinedDelays(fig,P,cfg)
tl = tiledlayout(fig,3,1,'TileSpacing','compact','Padding','compact');
title(tl,'Command-to-response delay, grouped by transition class');
values = [P.eventMetrics.commandToT10_us P.eventMetrics.commandToT50_us ...
    P.eventMetrics.commandToT90_us];
levels = [10 50 90];
for k = 1:3
    ax = nexttile(tl);
    plotClassScatter(ax,P,values(:,k),cfg, ...
        sprintf('Command to %d%% crossing',levels(k)),'Delay (us)');
end
end

function plotT10Aligned(fig,P,cfg)
ax = axes('Parent',fig);
overlayTraces(ax,P.timeFromT10_us,P.t10AlignedResponses(:,P.bipolarMask), ...
    cfg,'Individual bipolar transitions','Aligned bipolar mean');
addFastGuides(ax,cfg);
xlabel(ax,'Time from individual 10% crossing (us)'); ylabel(ax,'Normalized response');
title(ax,'Bipolar transitions aligned to each event''s measured t10');
end

function plotDroopIndividual(fig,P,cfg,normalized)
tl = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');
if normalized
    title(tl,'Slow phases normalized individually: first smoothed sample is the reference');
else
    if cfg.magnitudeSmoothed, signalText = 'lightly smoothed';
    else, signalText = 'unsmoothed'; end
    title(tl,sprintf('Absolute slow-phase magnitude in mA (%s)',signalText));
end
names = ["positive","negative"];
labels = ["Positive phases","Negative phases, sign corrected"];
for p = 1:2
    ax = nexttile(tl); G = P.droop.(names(p));
    if G.N>0 && isfield(P.droop,'fullTime_ms')
        if normalized
            Y = G.normalizedMagnitude;
        elseif cfg.magnitudeSmoothed
            Y = G.magnitudeSmooth_mA;
        else
            Y = G.magnitude_mA;
        end
        overlayTraces(ax,P.droop.fullTime_ms,Y,cfg,'Individual phases','Phase mean');
        if normalized, yline(ax,1,':','HandleVisibility','off'); end
    else
        showNoData(ax,'No complete phases for this polarity.');
    end
    xlabel(ax,'Time from guarded slow-phase origin (ms)');
    if normalized, ylabel(ax,'Normalized magnitude D(t)');
    else, ylabel(ax,'Current magnitude (mA)'); end
    title(ax,sprintf('%s | N = %d',labels(p),G.N));
end
end

function plotDroopMeans(fig,P,cfg)
ax = axes('Parent',fig); hold(ax,'on');
names = ["positive","negative","combined"];
labels = ["Positive mean","Negative mean, sign corrected","Combined mean"];
colors = [cfg.positiveColor;cfg.negativeColor;cfg.meanColor];
styles = {'-','--',':'};
hasData = false;
for p = 1:3
    G = P.droop.(names(p));
    if G.N>0 && isfield(P.droop,'fullTime_ms')
        plot(ax,P.droop.fullTime_ms,G.meanNormalizedMagnitude, ...
            'Color',colors(p,:),'LineStyle',styles{p},'LineWidth',2, ...
            'DisplayName',labels(p));
        hasData = true;
    end
end
yline(ax,1,':','HandleVisibility','off'); grid(ax,'on');
xlabel(ax,'Time from guarded slow-phase origin (ms)');
ylabel(ax,'Normalized magnitude D(t)');
title(ax,'Positive, negative and combined rebased droop means');
if hasData, legend(ax,'show','Location','best');
else, showNoData(ax,'No complete passive-droop phases.'); end
end

function plotDroopModelGrid(fig,P,cfg)
ax = axes('Parent',fig);
G = P.droop.combined;
if G.N>0 && isfield(P.droop,'modelTime_ms')
    overlayTraces(ax,P.droop.modelTime_ms,G.modelNormalizedMagnitude,cfg, ...
        'Individual model columns','Combined model-grid mean');
    yline(ax,1,':','HandleVisibility','off');
    title(ax,sprintf('Actual Stage 3 model matrix: dt = %.3g us, %d rows x %d phases', ...
        P.droop.settings.modelDt_us,size(G.modelNormalizedMagnitude,1),G.N));
else
    showNoData(ax,'No passive-droop model matrix available.');
    title(ax,'Stage 3 slow-droop model grid');
end
xlabel(ax,'Time from guarded slow-phase origin (ms)'); ylabel(ax,'Normalized magnitude D(t)');
end

function plotDroopNormalizationCheck(fig,P,cfg)
tl = tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');
title(tl,{'Per-phase normalization check: each saved dataset is inspected directly', ...
    'End values are last common-grid samples; late-window medians are saved separately'});
names = ["positive","negative"];
colors = [cfg.positiveColor;cfg.negativeColor];
for row = 1:2
    for p = 1:2
        ax = nexttile(tl); hold(ax,'on');
        Q = P.droopCheck(P.droopCheck.Polarity==names(p),:);
        if isempty(Q)
            showNoData(ax,'No complete phases for this polarity.');
        elseif row==1
            plot(ax,Q.PhaseNumber,Q.D0Full,'o','Color',colors(p,:), ...
                'MarkerFaceColor',colors(p,:),'DisplayName','Full grid D(0)');
            plot(ax,Q.PhaseNumber,Q.D0Model,'x','Color',cfg.meanColor, ...
                'LineWidth',1.3,'MarkerSize',8,'DisplayName','Model grid D(0)');
            yline(ax,1,':','HandleVisibility','off');
            finiteStarts = [Q.D0Full;Q.D0Model];
            finiteStarts = finiteStarts(isfinite(finiteStarts));
            if isempty(finiteStarts) || all(abs(finiteStarts-1)<0.005)
                ylim(ax,[0.995 1.005]);
            end
            legend(ax,'show','Location','best');
            title(ax,sprintf('%s: D(0) check passed %d / %d', ...
                names(p),nnz(Q.StartAtOne),height(Q)));
        else
            plot(ax,Q.PhaseNumber,Q.DLastFull,'o-','Color',colors(p,:), ...
                'MarkerSize',4,'DisplayName','Last full-grid value');
            plot(ax,Q.PhaseNumber,Q.DLastModel,'x--','Color',cfg.meanColor, ...
                'MarkerSize',6,'DisplayName','Last model-grid value');
            legend(ax,'show','Location','best');
            title(ax,sprintf('%s: finite model columns %d / %d', ...
                names(p),nnz(Q.ModelColumnComplete),height(Q)));
        end
        grid(ax,'on'); xlabel(ax,'Physical phase number (burst order)');
        if row==1, ylabel(ax,'Initial normalized magnitude');
        else, ylabel(ax,'Final normalized magnitude'); end
    end
end
end

function overlayTraces(ax,x,Y,cfg,individualLabel,meanLabel)
hold(ax,'on');
if isempty(Y) || ~any(isfinite(Y(:)))
    showNoData(ax,'No finite traces available.');
    return;
end
colors = lines(size(Y,2));
representative = [];
for k = 1:size(Y,2)
    h = plot(ax,x,Y(:,k),'Color',0.4*colors(k,:)+0.6, ...
        'LineWidth',.55,'HandleVisibility','off');
    if isempty(representative) && any(isfinite(Y(:,k))), representative = h; end
end
if ~isempty(representative)
    set(representative,'HandleVisibility','on','DisplayName',individualLabel);
end
plot(ax,x,mean(Y,2,'omitnan'),'Color',cfg.meanColor, ...
    'LineWidth',2,'DisplayName',meanLabel);
grid(ax,'on');
if numel(x)>1, xlim(ax,[x(1) x(end)]); end
legend(ax,'show','Location','best');
end

function addFastGuides(ax,cfg)
hold(ax,'on');
for level = [0 .1 .5 .9 1]
    yline(ax,level,':','Color',[.6 .6 .6],'HandleVisibility','off');
end
xline(ax,0,'--','Color',[.4 .4 .4],'HandleVisibility','off');
ylim(ax,cfg.fastYLim); grid(ax,'on');
end

function showNoData(ax,message)
text(ax,.5,.5,message,'Units','normalized','HorizontalAlignment','center', ...
    'VerticalAlignment','middle','Interpreter','none','Color',[.4 .1 .1]);
grid(ax,'on');
end

function styleDiagnosticFigure(fig)
axesHandles = findall(fig,'Type','axes');
for k = 1:numel(axesHandles)
    ax = axesHandles(k);
    set(ax,'Color','w','XColor',[.1 .1 .1],'YColor',[.1 .1 .1], ...
        'FontSize',10,'Box','on','GridColor',[.55 .55 .55],'GridAlpha',.25);
    if isprop(ax,'Toolbar'), ax.Toolbar.Visible = 'off'; end
end
layouts = findall(fig,'-isa','matlab.graphics.layout.TiledChartLayout');
for j = 1:numel(layouts)
    layouts(j).Title.Color = [.1 .1 .1];
end
textHandles = findall(fig,'Type','text');
set(textHandles,'Color',[.1 .1 .1],'Interpreter','none');
legends = findall(fig,'Type','legend');
for k = 1:numel(legends)
    set(legends(k),'Color','w','TextColor',[.1 .1 .1], ...
        'EdgeColor',[.65 .65 .65],'Interpreter','none','AutoUpdate','off');
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
printFolderListing(fileparts(paths(1)));
error('OpenXstim:MissingHardcodedInput', ...
    '%s input is missing. Run Stage 1 first or correct PROJECT_FOLDER in USER SETTINGS.', ...
    sourceLabel);
end

function printFolderListing(folder)
if ~isfolder(folder)
    fprintf(2,'Expected input folder does not exist:\n%s\n',folder);
    [parent,~,~] = fileparts(folder);
    if isfolder(parent)
        fprintf(2,'Contents of its existing parent folder:\n%s\n',parent);
        entries = dir(parent);
    else
        return;
    end
else
    fprintf(2,'Contents of expected input folder:\n%s\n',folder);
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
