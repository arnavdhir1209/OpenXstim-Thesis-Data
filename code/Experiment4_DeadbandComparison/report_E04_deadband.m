
%% ============================================================
% report_E04_deadband.m
%
% OpenXstim E04 Hardware Deadband Comparison
% MATLAB R2025a
%
% Generates eight final figures from previously processed
% E04 hardware recordings.
%
% Required:
%   E04_Deadband_Results/E04_ProcessedResults.mat
%
% Optional:
%   F2_MainTrials.csv
%
% Figures:
%   E04-01 Representative measured-current trajectories
%   E04-02 Steady-state DAC switching
%   E04-03 Steady-state measured-current RMSE
%   E04-04 Accuracy versus switching
%   E04-05 Signed and absolute bias
%   E04-06 Applied DAC Counter occupancy
%   E04-07 Steady-state tracking-error distributions
%   E04-08 Time within common +/-0.030 mA band
%
% No firmware changes.
% No simulation reruns.
% No raw data modifications.
%% ============================================================

clearvars;
close all;
clc;

%% ============================================================
% 1. CONFIGURATION
% ============================================================

root = fileparts(mfilename('fullpath'));

if isempty(root)
    root = pwd;
end

out = fullfile(root,'E04_Deadband_Results');
figDir = fullfile(out,'Figures');

assert(isfile(fullfile(out,'E04_ProcessedResults.mat')), ...
    ['Missing E04_ProcessedResults.mat. ' ...
     'Run analyse_E04_deadband.m first.']);

if ~isfolder(figDir)
    mkdir(figDir);
end

loads = [100 4000];
deadbands = [0.030 0.045 0.060];

steadyDuration_s = 20;
reference_mA = 10;
commonAccuracy_mA = 0.030;

bootstrapSeed = 20261103;
nBootstrap = 2000;

% Expected settings are labels, not independent
% verification of the firmware configuration.

% Consistent colours for deadband comparisons.
colours = lines(numel(deadbands));

% Font and export settings.
fontSize = 11;
figureResolution = 250;

fprintf('\n========================================\n');
fprintf('E04 HARDWARE DEADBAND FINAL REPORT\n');
fprintf('========================================\n');

%% ============================================================
% 2. LOAD VERIFIED ANALYSIS RESULTS
% ============================================================

S = load(fullfile(out,'E04_ProcessedResults.mat'));

requiredFields = { ...
    'trialMetrics', ...
    'occupancy', ...
    'fileAudit', ...
    'trajectories'};

for k = 1:numel(requiredFields)

    assert(isfield(S,requiredFields{k}), ...
        'Missing saved variable: %s', ...
        requiredFields{k});

end

T = S.trialMetrics;
O = S.occupancy;
A = S.fileAudit;
X = S.trajectories;

assert(~isempty(T),'No eligible trial metrics available.');
assert(~isempty(X),'No processed trajectories available.');

fprintf('Recorded files: %d\n',height(A));
fprintf('Eligible trials: %d\n',height(T));

%% ============================================================
% 3. VALIDATE EXPERIMENTAL CONDITIONS
% ============================================================

assert(all(ismember(T.Load_Ohm,loads)), ...
    'Unexpected resistance in trial metrics.');

assert(all(ismembertol( ...
    T.Deadband_mA,deadbands,1e-8)), ...
    'Unexpected deadband in trial metrics.');

assert(all(T.SteadyRMSE_mA>=0));
assert(all(T.SteadyDACChangesPer_s>=0));

assert(all(T.Within030>=0 & T.Within030<=1));

% Verify that every expected combination exists.

for R = loads

    for D = deadbands

        ix = ...
            T.Load_Ohm==R & ...
            abs(T.Deadband_mA-D)<1e-8;

        fprintf( ...
            'R=%d ohm, D=%.3f: %d eligible trials\n', ...
            R,D,nnz(ix));

        assert(any(ix), ...
            'No eligible trials for R=%d, D=%.3f.',R,D);

    end

end

%% ============================================================
% 4. FINAL COMPACT COMPARISON TABLE
% ============================================================

rows = table();

for R = loads

    for D = deadbands

        ix = ...
            T.Load_Ohm==R & ...
            abs(T.Deadband_mA-D)<1e-8;

        V = T(ix,:);

        n = height(V);

        row = table( ...
            R,D,n, ...
            mean(V.SteadyRMSE_mA), ...
            std(V.SteadyRMSE_mA), ...
            mean(V.SteadyAbsBias_mA), ...
            mean(V.SteadySignedBias_mA), ...
            mean(V.SteadyDACChangesPer_s), ...
            std(V.SteadyDACChangesPer_s), ...
            mean(V.SteadyDACMovement), ...
            mean(V.Within030), ...
            mean(V.SteadyCurrentSD_mA), ...
            mean(V.TransientRMSE_mA), ...
            'VariableNames',{ ...
            'Load_Ohm', ...
            'Deadband_mA', ...
            'Trials', ...
            'SteadyRMSE_mA', ...
            'SteadyRMSE_SD_mA', ...
            'AbsoluteBias_mA', ...
            'SignedBias_mA', ...
            'DACChangesPer_s', ...
            'DACChanges_SD_per_s', ...
            'DACMovement', ...
            'Within030', ...
            'CurrentSD_mA', ...
            'TransientRMSE_mA'});

        rows = [rows;row]; %#ok<AGROW>

    end

end

writetable(rows,fullfile( ...
    out,'E04_CompactFinalComparison.csv'));

fprintf('\nFINAL HARDWARE COMPARISON\n');

disp(rows(:,{ ...
    'Load_Ohm', ...
    'Deadband_mA', ...
    'Trials', ...
    'SteadyRMSE_mA', ...
    'AbsoluteBias_mA', ...
    'DACChangesPer_s', ...
    'Within030'}));

%% ============================================================
% 5. INDEPENDENT-TRIAL STATISTICAL COMPARISONS
% ============================================================

% Do not assume T01 at D030 is experimentally
% paired with T01 at D045.
%
% Bootstrap independent trial groups separately.

comparisonPairs = [ ...
    0.045 0.030
    0.060 0.030
    0.060 0.045];

metrics = { ...
    'SteadyRMSE_mA', ...
    'SteadyAbsBias_mA', ...
    'SteadySignedBias_mA', ...
    'SteadyDACChangesPer_s', ...
    'SteadyDACMovement', ...
    'Within030', ...
    'SteadyCurrentSD_mA', ...
    'TransientRMSE_mA'};

rng(bootstrapSeed,'twister');

comparisonTable = table();

for R = loads

    for p = 1:size(comparisonPairs,1)

        alternative = comparisonPairs(p,1);
        baseline = comparisonPairs(p,2);

        ia = ...
            T.Load_Ohm==R & ...
            abs(T.Deadband_mA-alternative)<1e-8;

        ib = ...
            T.Load_Ohm==R & ...
            abs(T.Deadband_mA-baseline)<1e-8;

        for m = 1:numel(metrics)

            field = metrics{m};

            a = T.(field)(ia);
            b = T.(field)(ib);

            a = a(isfinite(a));
            b = b(isfinite(b));

            if isempty(a) || isempty(b)
                continue;
            end

            meanA = mean(a);
            meanB = mean(b);

            difference = meanA-meanB;

            changePct = NaN;

            if meanB~=0
                changePct = ...
                    100*difference/abs(meanB);
            end

            boot = zeros(nBootstrap,1);

            for z = 1:nBootstrap

                aa = a(randi(numel(a),numel(a),1));
                bb = b(randi(numel(b),numel(b),1));

                boot(z) = mean(aa)-mean(bb);

            end

            ci = localPercentile(boot,[2.5 97.5]);

            newRow = table( ...
                R,alternative,baseline, ...
                string(field), ...
                numel(a),numel(b), ...
                meanA,meanB,difference,changePct, ...
                ci(1),ci(2), ...
                'VariableNames',{ ...
                'Load_Ohm', ...
                'Alternative_mA', ...
                'Baseline_mA', ...
                'Metric', ...
                'AlternativeTrials', ...
                'BaselineTrials', ...
                'AlternativeMean', ...
                'BaselineMean', ...
                'MeanDifference', ...
                'ChangePercent', ...
                'CI95_Lower', ...
                'CI95_Upper'});

            comparisonTable = [ ...
                comparisonTable;newRow]; %#ok<AGROW>

        end

    end

end

writetable(comparisonTable,fullfile( ...
    out,'E04_IndependentTrialComparisons.csv'));

% Preserve compatibility with existing report references.
% The contents are UNPAIRED comparisons.
writetable(comparisonTable,fullfile( ...
    out,'E04_PairedComparisons.csv'));

%% ============================================================
% 6. REPRESENTATIVE TRIAL SELECTION
% ============================================================

% Representative trial:
% The eligible trial whose steady-state RMSE is
% closest to the median RMSE of its condition.
%
% This avoids arbitrarily assuming T03 is typical.

representatives = table();

for R = loads

    for D = deadbands

        ix = ...
            T.Load_Ohm==R & ...
            abs(T.Deadband_mA-D)<1e-8;

        V = T(ix,:);

        targetRMSE = median(V.SteadyRMSE_mA);

        [~,selected] = min( ...
            abs(V.SteadyRMSE_mA-targetRMSE));

        chosen = V(selected,:);

        representatives = [representatives; ...
            chosen(:,{ ...
            'File', ...
            'Load_Ohm', ...
            'Deadband_mA', ...
            'Trial', ...
            'SteadyRMSE_mA'})]; %#ok<AGROW>

    end

end

writetable(representatives,fullfile( ...
    out,'E04_RepresentativeTrials.csv'));

fprintf('\nREPRESENTATIVE TRIALS\n');
disp(representatives);

%% ============================================================
% 7. FIGURE E04-01
% REPRESENTATIVE MEASURED-CURRENT TRAJECTORIES
% ============================================================

f1 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1150 780]);

tiledlayout(2,1, ...
    'TileSpacing','compact', ...
    'Padding','compact');

for j = 1:numel(loads)

    nexttile;
    hold on;

    for d = 1:numel(deadbands)

        D = deadbands(d);

        ix = ...
            representatives.Load_Ohm==loads(j) & ...
            abs(representatives.Deadband_mA-D)<1e-8;

        rep = representatives(ix,:);

        q = findTrajectory(X, ...
            loads(j),D,rep.Trial);

        assert(~isempty(q), ...
            'Representative trajectory not found.');

        elapsed = X(q).Time_s(:);
        measured = X(q).Current_mA(:);

        plot(elapsed,measured, ...
            'Color',colours(d,:), ...
            'LineWidth',0.85, ...
            'DisplayName',sprintf( ...
            'D=%.3f mA, T%02d', ...
            D,rep.Trial));

    end

    yline(reference_mA,'k--', ...
        'Reference: 10 mA', ...
        'HandleVisibility','off');

    xlabel('Elapsed time (s)');
    ylabel('Measured current (mA)');

    title(sprintf( ...
        '%d ohm: Representative PI trajectories', ...
        loads(j)));

    legend('Location','best');

    grid on;
    box on;

    set(gca,'FontSize',fontSize);

end

sgtitle( ...
    'E04-01: Hardware Measured-Current Trajectories');

%% ============================================================
% 8. FIGURE E04-02
% STEADY-STATE DAC SWITCHING RATE
% ============================================================

f2 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1050 560]);

tiledlayout(1,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

for j = 1:numel(loads)

    nexttile;
    hold on;

    for d = 1:numel(deadbands)

        D = deadbands(d);

        ix = ...
            T.Load_Ohm==loads(j) & ...
            abs(T.Deadband_mA-D)<1e-8;

        y = T.SteadyDACChangesPer_s(ix);

        % Deterministic horizontal jitter for
        % legibility only. It does not alter the data.
        offsets = linspace(-0.0007,0.0007,numel(y))';

        scatter(D+offsets,y,42, ...
            colours(d,:),'filled', ...
            'MarkerFaceAlpha',0.55);

        errorbar(D,mean(y),std(y), ...
            'ko','LineWidth',1.5, ...
            'MarkerFaceColor','w', ...
            'MarkerSize',8);

    end

    xlabel('Deadband (mA)');
    ylabel('Applied DAC changes/s');

    title(sprintf('%d ohm',loads(j)));

    xticks(deadbands);
    xlim([0.022 0.068]);

    grid on;
    box on;

    set(gca,'FontSize',fontSize);

end

sgtitle( ...
    'E04-02: Steady-State Applied DAC Switching');

%% ============================================================
% 9. FIGURE E04-03
% STEADY-STATE MEASURED-CURRENT RMSE
% ============================================================

f3 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1050 560]);

tiledlayout(1,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

for j = 1:numel(loads)

    nexttile;
    hold on;

    for d = 1:numel(deadbands)

        D = deadbands(d);

        ix = ...
            T.Load_Ohm==loads(j) & ...
            abs(T.Deadband_mA-D)<1e-8;

        y = T.SteadyRMSE_mA(ix);

        offsets = linspace( ...
            -0.0007,0.0007,numel(y))';

        scatter(D+offsets,y,42, ...
            colours(d,:),'filled', ...
            'MarkerFaceAlpha',0.55);

        errorbar(D,mean(y),std(y), ...
            'ko','LineWidth',1.5, ...
            'MarkerFaceColor','w', ...
            'MarkerSize',8);

    end

    xlabel('Deadband (mA)');
    ylabel('Measured-current RMSE (mA)');

    title(sprintf('%d ohm',loads(j)));

    xticks(deadbands);
    xlim([0.022 0.068]);

    grid on;
    box on;

    set(gca,'FontSize',fontSize);

end

sgtitle( ...
    'E04-03: Steady-State Feedback-Current RMSE');

%% ============================================================
% 10. FIGURE E04-04
% ACCURACY VERSUS DAC SWITCHING
% ============================================================

f4 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1000 650]);

hold on;

markers = {'o','s'};

for j = 1:numel(loads)

    for d = 1:numel(deadbands)

        D = deadbands(d);

        ix = ...
            rows.Load_Ohm==loads(j) & ...
            abs(rows.Deadband_mA-D)<1e-8;

        xx = rows.DACChangesPer_s(ix);
        yy = rows.SteadyRMSE_mA(ix);

        scatter(xx,yy,125, ...
            colours(d,:), ...
            markers{j}, ...
            'filled', ...
            'DisplayName',sprintf( ...
            '%d ohm, D=%.3f',loads(j),D));

        text(xx,yy,sprintf('  %.3f',D), ...
            'FontSize',9);

    end

end

xlabel('Steady applied DAC changes/s');
ylabel('Steady measured-current RMSE (mA)');

title('E04-04: Experimental Accuracy-Switching Tradeoff');

legend('Location','best');
grid on;
box on;

set(gca,'FontSize',fontSize);

%% ============================================================
% 11. FIGURE E04-05
% SIGNED AND ABSOLUTE BIAS
% ============================================================

f5 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1050 720]);

tiledlayout(2,1, ...
    'TileSpacing','compact', ...
    'Padding','compact');

fields = { ...
    'SignedBias_mA', ...
    'AbsoluteBias_mA'};

panelTitles = { ...
    'Signed tracking bias (target minus measured)', ...
    'Mean absolute steady-state bias across trials'};

for panel = 1:2

    nexttile;
    hold on;

    for j = 1:numel(loads)

        y = nan(numel(deadbands),1);

        for d = 1:numel(deadbands)

            ix = ...
                rows.Load_Ohm==loads(j) & ...
                abs(rows.Deadband_mA-deadbands(d))<1e-8;

            y(d) = rows.(fields{panel})(ix);

        end

        plot(deadbands,y,'-o', ...
            'LineWidth',1.6, ...
            'MarkerSize',7, ...
            'DisplayName',sprintf( ...
            '%d ohm',loads(j)));

    end

    xlabel('Deadband (mA)');
    ylabel('Current error (mA)');

    title(panelTitles{panel});

    legend('Location','best');

    xticks(deadbands);

    grid on;
    box on;

    set(gca,'FontSize',fontSize);

end

sgtitle('E04-05: Steady-State Tracking Bias');

%% ============================================================
% 12. FIGURE E04-06
% CORRECTED DAC COUNTER OCCUPANCY
% ============================================================

% Important:
% Every trial contributes to each condition mean.
% A Counter absent from a trial receives zero occupancy.

f6 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1100 600]);

tiledlayout(1,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

for j = 1:numel(loads)

    nexttile;
    hold on;

    for d = 1:numel(deadbands)

        D = deadbands(d);

        ix = ...
            O.Load_Ohm==loads(j) & ...
            abs(O.Deadband_mA-D)<1e-8;

        V = O(ix,:);

        if isempty(V)
            continue;
        end

        codes = unique(V.Counter);

        trialIDs = unique( ...
            T.Trial(T.Load_Ohm==loads(j) & ...
            abs(T.Deadband_mA-D)<1e-8));

        occupancyPct = zeros(numel(codes),1);

        for k = 1:numel(codes)

            trialOccupancy = ...
                zeros(numel(trialIDs),1);

            for tr = 1:numel(trialIDs)

                matched = ...
                    V.Trial==trialIDs(tr) & ...
                    V.Counter==codes(k);

                trialOccupancy(tr) = ...
                    sum(V.Occupancy(matched));

            end

            occupancyPct(k) = ...
                100*mean(trialOccupancy);

        end

        assert(abs(sum(occupancyPct)-100)<1e-6, ...
            'Mean Counter occupancy does not sum to 100%%.');

        plot(codes,occupancyPct,'-o', ...
            'LineWidth',1.5, ...
            'Color',colours(d,:), ...
            'DisplayName',sprintf('D=%.3f',D));

    end

    xlabel('Applied DAC Counter');
    ylabel('Mean steady-state occupancy (%)');

    title(sprintf('%d ohm',loads(j)));

    legend('Location','best');

    grid on;
    box on;

    set(gca,'FontSize',fontSize);

end

sgtitle( ...
    'E04-06: Trial-Averaged DAC Counter Occupancy');

%% ============================================================
% 13. FIGURE E04-07
% STEADY-STATE CURRENT-ERROR DISTRIBUTIONS
% ============================================================

% Plot empirical CDFs of signed tracking error.
%
% Each trial contributes equal total weight.
% Within each trial, the individual observations
% are weighted using their recorded time intervals.
%
% This preserves the distinction between trials
% while accounting for the nonuniform logging period.

f7 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1100 650]);

tiledlayout(1,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

cdfVerification = table();

for j = 1:numel(loads)

    nexttile;
    hold on;

    for d = 1:numel(deadbands)

        D = deadbands(d);

        trialErrors = [];
        trialWeights = [];

        conditionRows = T( ...
            T.Load_Ohm==loads(j) & ...
            abs(T.Deadband_mA-D)<1e-8,:);

        nTrials = height(conditionRows);

        assert(nTrials>=1, ...
            'No trials for E04 error distribution.');

        for tr = 1:nTrials

            trialNum = conditionRows.Trial(tr);

            q = findTrajectory( ...
                X,loads(j),D,trialNum);

            assert(~isempty(q), ...
                'Missing E04 trajectory for distribution.');

            elapsed = X(q).Time_s(:);
            error = X(q).Error_mA(:);

            % Final 20 seconds of the valid recording.
            steady = elapsed>= ...
                elapsed(end)-steadyDuration_s;

            tSteady = elapsed(steady);
            eSteady = error(steady);

            assert(numel(tSteady)>=2, ...
                'Insufficient steady-state samples.');

            assert(all(diff(tSteady)>0), ...
                'Nonmonotonic trajectory timestamps.');

            dt = diff(tSteady);

            finalDt = median(dt(dt>0));

            w = [dt;finalDt];

            % Equal total weight per hardware trial.
            w = w/sum(w)/nTrials;

            trialErrors = [ ...
                trialErrors;eSteady]; %#ok<AGROW>

            trialWeights = [ ...
                trialWeights;w]; %#ok<AGROW>

        end

        % Weighted empirical cumulative distribution.
        [sortedErrors,order] = sort(trialErrors);

        sortedWeights = trialWeights(order);

        cumulative = cumsum(sortedWeights);
        cumulative = cumulative/cumulative(end);

        stairs(sortedErrors,cumulative, ...
            'Color',colours(d,:), ...
            'LineWidth',1.6, ...
            'DisplayName',sprintf('D=%.3f mA',D));

        % Check agreement with the reported common-band
        % fraction, allowing for the slightly different
        % final-sample duration convention.
        cdfWithin = sum( ...
            trialWeights(abs(trialErrors)<= ...
            commonAccuracy_mA));

        tableWithin = mean(conditionRows.Within030);

        cdfVerification = [cdfVerification;table( ...
            loads(j),D,nTrials,cdfWithin,tableWithin, ...
            cdfWithin-tableWithin, ...
            'VariableNames',{ ...
            'Load_Ohm','Deadband_mA','Trials', ...
            'CDFWithin030','TrialMetricWithin030', ...
            'Difference'})]; %#ok<AGROW>

    end

    xline(-commonAccuracy_mA,'k--', ...
        'HandleVisibility','off');

    xline(commonAccuracy_mA,'k--', ...
        'HandleVisibility','off');

    xlabel('Tracking error: target minus measured (mA)');
    ylabel('Empirical cumulative probability');

    title(sprintf('%d ohm',loads(j)));

    legend('Location','best');

    ylim([0 1]);

    grid on;
    box on;

    set(gca,'FontSize',fontSize);

end

sgtitle( ...
    'E04-07: Steady-State Hardware Tracking-Error Distributions');

writetable(cdfVerification,fullfile( ...
    out,'E04_CDF_AccuracyCrosscheck.csv'));

%% ============================================================
% 14. FIGURE E04-08
% FRACTION WITHIN COMMON +/-0.030 mA BAND
% ============================================================

f8 = figure( ...
    'Visible','off', ...
    'Color','w', ...
    'Position',[100 100 1000 550]);

hold on;

for j = 1:numel(loads)

    y = nan(numel(deadbands),1);

    for d = 1:numel(deadbands)

        ix = ...
            rows.Load_Ohm==loads(j) & ...
            abs(rows.Deadband_mA-deadbands(d))<1e-8;

        y(d) = 100*rows.Within030(ix);

    end

    plot(deadbands,y,'-o', ...
        'LineWidth',1.6, ...
        'MarkerSize',8, ...
        'DisplayName',sprintf('%d ohm',loads(j)));

end

xlabel('Configured deadband (mA)');
ylabel('Time within +/-0.030 mA (%)');

title('E04-08: Common Measured-Current Accuracy Criterion');

xticks(deadbands);

legend('Location','best');

grid on;
box on;

set(gca,'FontSize',fontSize);

%% ============================================================
% 15. EXPORT ALL EIGHT FIGURES
% ============================================================

figs = {f1,f2,f3,f4,f5,f6,f7,f8};

names = { ...
    'E04_Fig01_RepresentativeCurrent', ...
    'E04_Fig02_Switching', ...
    'E04_Fig03_RMSE', ...
    'E04_Fig04_Tradeoff', ...
    'E04_Fig05_Bias', ...
    'E04_Fig06_CounterOccupancy', ...
    'E04_Fig07_ErrorDistribution', ...
    'E04_Fig08_TimeInBand'};

for k = 1:numel(figs)

    exportgraphics( ...
        figs{k}, ...
        fullfile(figDir,[names{k} '.png']), ...
        'Resolution',figureResolution);

    exportgraphics( ...
        figs{k}, ...
        fullfile(figDir,[names{k} '.pdf']), ...
        'ContentType','vector');

    close(figs{k});

    fprintf('Exported Figure E04-%02d\n',k);

end

%% ============================================================
% 16. OPTIONAL STAGE 2D-F SIMULATION COMPARISON
% ============================================================

simComparison = table();

% First check beside the E04 scripts.
simPath = fullfile(root,'F2_MainTrials.csv');

% Then check a Stage 2D-F result folder.
if ~isfile(simPath)

    alternativePath = fullfile( ...
        root,'Stage2D_F_Results','F2_MainTrials.csv');

    if isfile(alternativePath)
        simPath = alternativePath;
    end

end

if isfile(simPath)

    SIM = readtable(simPath);

    requiredSim = { ...
        'Controller', ...
        'NoiseModel', ...
        'Deadband_mA', ...
        'SteadyRMSE_mA', ...
        'SteadySwitchRate', ...
        'SteadyAbsBias_mA'};

    assert(all(ismember(requiredSim, ...
        SIM.Properties.VariableNames)), ...
        'Stage 2D-F simulation CSV schema mismatch.');

    for D = deadbands

        ix = ...
            string(SIM.Controller)== ...
                "Moderately faster" & ...
            string(SIM.NoiseModel)=="N2" & ...
            abs(SIM.Deadband_mA-D)<1e-8;

        if ~any(ix)
            warning( ...
                'Stage 2D-F missing D=%.3f.',D);
            continue;
        end

        newRow = table( ...
            D,nnz(ix), ...
            mean(SIM.SteadyRMSE_mA(ix)), ...
            mean(SIM.SteadySwitchRate(ix)), ...
            mean(SIM.SteadyAbsBias_mA(ix)), ...
            'VariableNames',{ ...
            'Deadband_mA', ...
            'SimulationTrials', ...
            'SimulationTrueRMSE_mA', ...
            'SimulationDACChangesPer_s', ...
            'SimulationAbsBias_mA'});

        simComparison = [ ...
            simComparison;newRow]; %#ok<AGROW>

    end

    fprintf('\nStage 2D-F simulation comparison imported.\n');

else

    warning( ...
        ['F2_MainTrials.csv not found. ' ...
         'Hardware report remains complete, ' ...
         'but simulation comparison is unavailable.']);

end

writetable(simComparison,fullfile( ...
    out,'E04_SimulationComparison.csv'));

%% ============================================================
% 17. FINAL TEXT REPORT
% ============================================================

txtPath = fullfile(out,'E04_FullReport.txt');

fid = fopen(txtPath,'w');

assert(fid>0, ...
    'Unable to create E04_FullReport.txt.');

fprintf(fid,'E04 HARDWARE DEADBAND COMPARISON\n');
fprintf(fid,'========================================\n\n');

fprintf(fid,'Generated: %s\n',datestr(now));
fprintf(fid,'MATLAB: %s\n\n',version);

fprintf(fid,'Recorded files: %d\n',height(A));
fprintf(fid,'Eligible trials: %d\n\n',height(T));

fprintf(fid, ...
    ['Primary accuracy observable: Arduino ' ...
     'measured feedback current.\n']);

fprintf(fid, ...
    ['It is not an independent true-current ' ...
     'measurement.\n\n']);

fprintf(fid, ...
    ['Comparisons use independent trials unless ' ...
     'experimental blocks are independently ' ...
     'documented.\n\n']);

fprintf(fid,'FINAL CONDITION COMPARISON\n\n');

for k = 1:height(rows)

    v = rows(k,:);

    fprintf(fid, ...
        ['R=%d ohm, D=%.3f mA, n=%d\n' ...
         '  RMSE: %.6f mA\n' ...
         '  Absolute bias: %.6f mA\n' ...
         '  Signed bias: %.6f mA\n' ...
         '  DAC changes/s: %.4f\n' ...
         '  Within +/-0.030 mA: %.2f%%\n\n'], ...
        v.Load_Ohm, ...
        v.Deadband_mA, ...
        v.Trials, ...
        v.SteadyRMSE_mA, ...
        v.AbsoluteBias_mA, ...
        v.SignedBias_mA, ...
        v.DACChangesPer_s, ...
        100*v.Within030);

end

fprintf(fid,'REPRESENTATIVE TRIAL SELECTION\n\n');

fprintf(fid, ...
    ['Representative trajectories were selected ' ...
     'by proximity to the condition median ' ...
     'steady-state RMSE.\n\n']);

for k = 1:height(representatives)

    v = representatives(k,:);

    fprintf(fid, ...
        ['R=%d ohm, D=%.3f, T%02d, ' ...
         'steady RMSE=%.6f mA\n'], ...
        v.Load_Ohm,v.Deadband_mA, ...
        v.Trial,v.SteadyRMSE_mA);

end

fprintf(fid,'\nSTATISTICAL METHODOLOGY\n\n');

fprintf(fid, ...
    ['Independent-trial bootstrap, %d replicates, ' ...
     'random seed %d.\n'], ...
    nBootstrap,bootstrapSeed);

fprintf(fid, ...
    ['Each hardware recording is the replication ' ...
     'unit, not each individual burst.\n\n']);

fprintf(fid,'FIGURE INVENTORY\n\n');

for k = 1:numel(names)
    fprintf(fid,'%02d: %s\n',k,names{k});
end

fprintf(fid,'\nSIMULATION COMPARISON\n\n');

if ~isempty(simComparison)

    fprintf(fid, ...
        'Stage 2D-F N2, moderately faster PI imported.\n');

else

    fprintf(fid, ...
        'Stage 2D-F trial CSV unavailable.\n');

end

fprintf(fid, ...
    ['Simulation RMSE uses modelled true current; ' ...
     'hardware RMSE uses measured feedback.\n']);

fprintf(fid, ...
    ['These observables must not be treated as ' ...
     'directly identical.\n']);

fclose(fid);

%% ============================================================
% 18. UPDATED MARKDOWN CHECKPOINT
% ============================================================

checkpoint = fullfile(out, ...
    'E04_Final_Verification_and_Design_Checkpoint.md');

fid = fopen(checkpoint,'w');

assert(fid>0, ...
    'Unable to create E04 checkpoint.');

fprintf(fid,'# E04 Hardware Deadband Comparison\n\n');

fprintf(fid,'Generated: %s\n\n',datestr(now));

fprintf(fid,'## Experimental objective\n\n');

fprintf(fid, ...
    ['Compare 0.030, 0.045 and 0.060 mA ' ...
     'deadbands using measured Arduino ' ...
     'feedback current at 100 and 4000 ohms.\n\n']);

fprintf(fid,'## Final numerical comparison\n\n');

fprintf(fid, ...
    ['| Load (ohm) | Deadband (mA) | Trials ' ...
     '| Steady RMSE (mA) | Absolute bias (mA) ' ...
     '| DAC changes/s | Within +/-0.030 mA |\n']);

fprintf(fid, ...
    '|---:|---:|---:|---:|---:|---:|---:|\n');

for k = 1:height(rows)

    v = rows(k,:);

    fprintf(fid, ...
        '| %d | %.3f | %d | %.6f | %.6f | %.4f | %.2f%% |\n', ...
        v.Load_Ohm,v.Deadband_mA, ...
        v.Trials,v.SteadyRMSE_mA, ...
        v.AbsoluteBias_mA, ...
        v.DACChangesPer_s, ...
        100*v.Within030);

end

fprintf(fid,'\n## Representative trajectories\n\n');

fprintf(fid, ...
    ['Figure E04-01 uses the trial closest to ' ...
     'the median steady-state RMSE for each ' ...
     'resistance/deadband condition.\n\n']);

for k = 1:height(representatives)

    v = representatives(k,:);

    fprintf(fid, ...
        '- %d ohm, D=%.3f: T%02d\n', ...
        v.Load_Ohm,v.Deadband_mA,v.Trial);

end

fprintf(fid,'\n## Error distributions\n\n');

fprintf(fid, ...
    ['Figure E04-07 shows the empirical ' ...
     'cumulative distribution of signed ' ...
     'steady-state current-tracking error.\n\n']);

fprintf(fid, ...
    ['The common +/-0.030 mA band is ' ...
     'independent of the configured controller ' ...
     'deadband.\n\n']);

fprintf(fid, ...
    ['Each hardware trial has equal total ' ...
     'weight in the condition-level CDF.\n\n']);

fprintf(fid,'## Counter occupancy\n\n');

fprintf(fid, ...
    ['Figure E04-06 uses trial-averaged occupancy. ' ...
     'Counters absent in a particular trial ' ...
     'contribute zero occupancy for that trial.\n\n']);

fprintf(fid,'## Statistical comparisons\n\n');

fprintf(fid, ...
    ['Independent-trial bootstrap with %d ' ...
     'replicates and random seed %d.\n\n'], ...
    nBootstrap,bootstrapSeed);

fprintf(fid, ...
    ['No paired-trial design is inferred ' ...
     'from matching trial numbers.\n\n']);

fprintf(fid,'## Simulation comparison\n\n');

if ~isempty(simComparison)

    fprintf(fid, ...
        ['Stage 2D-F N2 moderately faster PI ' ...
         'results are imported from F2_MainTrials.csv.\n\n']);

else

    fprintf(fid, ...
        ['Stage 2D-F comparison unavailable ' ...
         'because F2_MainTrials.csv was not found.\n\n']);

end

fprintf(fid, ...
    ['Stage 2D-F true-current RMSE and E04 ' ...
     'hardware feedback-current RMSE are ' ...
     'distinct observables.\n\n']);

fprintf(fid,'## Figure inventory\n\n');

for k = 1:numel(names)

    fprintf(fid, ...
        '%d. `%s.png` and `%s.pdf`\n', ...
        k,names{k},names{k});

end

fprintf(fid,'\n## Reproducibility\n\n');

fprintf(fid,'MATLAB version: %s\n\n',version);

fprintf(fid, ...
    ['Source: E04_ProcessedResults.mat, ' ...
     'generated by analyse_E04_deadband.m.\n\n']);

fprintf(fid, ...
    ['Report script: report_E04_deadband.m.\n\n']);

fprintf(fid, ...
    ['Original experimental CSVs are unchanged. ' ...
     'No firmware or PI gain changes were made.\n']);

fclose(fid);

%% ============================================================
% 19. FINAL VERIFICATION
% ============================================================

assert(height(rows)==6, ...
    'Expected exactly six load/deadband conditions.');

assert(height(representatives)==6, ...
    'Expected six representative trials.');

assert(numel(figs)==8, ...
    'Expected exactly eight main figures.');

assert(all(isfinite(rows.SteadyRMSE_mA)));

assert(all(rows.Within030>=0 & rows.Within030<=1));

assert(all(rows.DACChangesPer_s>=0));

% Check figure files were actually created.

for k = 1:numel(names)

    assert(isfile(fullfile(figDir, ...
        [names{k} '.png'])), ...
        'Missing exported PNG.');

    assert(isfile(fullfile(figDir, ...
        [names{k} '.pdf'])), ...
        'Missing exported PDF.');

end

fprintf('\n========================================\n');
fprintf('E04 REPORT COMPLETED\n');
fprintf('========================================\n');

fprintf('Condition summaries: %d\n',height(rows));
fprintf('Representative trials: %d\n', ...
    height(representatives));

fprintf('Figures exported: %d PNG + %d PDF\n', ...
    numel(names),numel(names));

fprintf('\nResults saved in:\n%s\n',out);

disp(rows);

%% ============================================================
% LOCAL FUNCTIONS
% ============================================================

function index = findTrajectory(X,R,D,trial)

    index = [];

    for k = 1:numel(X)

        if X(k).Load_Ohm==R && ...
                abs(X(k).Deadband_mA-D)<1e-8 && ...
                X(k).Trial==trial

            index = k;
            return;

        end

    end

end

function p = localPercentile(x,percentages)

    % Toolbox-independent linear-interpolation
    % percentile calculation.

    x = sort(x(isfinite(x)));

    n = numel(x);

    if n==0
        p = nan(size(percentages));
        return;
    end

    if n==1
        p = repmat(x,size(percentages));
        return;
    end

    p = zeros(size(percentages));

    for k = 1:numel(percentages)

        q = percentages(k)/100;

        pos = 1+(n-1)*q;

        lower = floor(pos);
        upper = ceil(pos);

        if lower==upper

            p(k) = x(lower);

        else

            fraction = pos-lower;

            p(k) = ...
                x(lower)*(1-fraction) + ...
                x(upper)*fraction;

        end

    end

end
