
%% report_E03_PI_gains.m
% E03 PI gain validation: reporting and figures
% MATLAB R2025a
%
% Requires E03_ProcessedResults.mat created by
% analyse_E03_PI_gains.m
%
% No simulation or hardware analysis is rerun.

clearvars;
close all;
clc;

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir), scriptDir = pwd; end

outDir = fullfile(scriptDir,'E03_PI_Results');
figDir = fullfile(outDir,'Figures');

assert(isfile(fullfile( ...
    outDir,'E03_ProcessedResults.mat')), ...
    'Run analyse_E03_PI_gains.m first.');

if ~isfolder(figDir), mkdir(figDir); end

S = load(fullfile(outDir,'E03_ProcessedResults.mat'));

T = S.trialMetrics;
A = S.fileAudit;
X = S.trajectories;
O = S.dacOccupancy;
ST = S.settlingSummary;

assert(~isempty(T),'No eligible trials found.');

loads = sort(unique(T.Load_Ohm))';
controllers = ["Empirical","Faster"];

band = 0.030;

bootstrapSeed = 20261103;
nBootstrap = 2000;

fontSize = 10;
resolution = 240;

colours = lines(2);

%% 1. Condition-level summary

condition = table();

for R = loads

    for c = 1:2

        Q = T( ...
            T.Load_Ohm==R & ...
            T.Controller==controllers(c),:);

        if isempty(Q)
            continue;
        end

        condition = [condition;table( ...
            R,controllers(c),height(Q), ...
            mean(Q.InitialError_mA), ...
            std(Q.InitialError_mA), ...
            mean(Q.Early10RMSE_mA), ...
            std(Q.Early10RMSE_mA), ...
            mean(Q.Early30RMSE_mA), ...
            std(Q.Early30RMSE_mA), ...
            mean(Q.FullRMSE_mA), ...
            mean(Q.SteadyRMSE_mA), ...
            mean(Q.SteadyBias_mA), ...
            mean(Q.SteadySwitchRate), ...
            mean(Q.Within030), ...
            'VariableNames',{ ...
            'Load_Ohm','Controller','Trials', ...
            'InitialError_mA','InitialErrorSD_mA', ...
            'Early10RMSE_mA','Early10SD_mA', ...
            'Early30RMSE_mA','Early30SD_mA', ...
            'FullRMSE_mA','SteadyRMSE_mA', ...
            'SteadyBias_mA','SteadySwitchRate', ...
            'Within030'})]; %#ok<AGROW>

    end
end

writetable(condition,fullfile( ...
    outDir,'E03_ConditionSummary_Final.csv'));

%% 2. Independent-trial comparisons

metrics = { ...
    'Early10RMSE_mA', ...
    'Early30RMSE_mA', ...
    'Early10IAE_mAs', ...
    'Early30IAE_mAs', ...
    'FullRMSE_mA', ...
    'SteadyRMSE_mA', ...
    'SteadyAbsBias_mA', ...
    'SteadySwitchRate', ...
    'SteadyDACMovement', ...
    'Within030'};

comparisons = table();

rng(bootstrapSeed,'twister');

for R = loads

    empirical = T( ...
        T.Load_Ohm==R & ...
        T.Controller=="Empirical",:);

    faster = T( ...
        T.Load_Ohm==R & ...
        T.Controller=="Faster",:);

    if isempty(empirical) || isempty(faster)
        continue;
    end

    for m = 1:numel(metrics)

        field = metrics{m};

        a = empirical.(field);
        b = faster.(field);

        a = a(isfinite(a));
        b = b(isfinite(b));

        if isempty(a) || isempty(b)
            continue;
        end

        difference = mean(b)-mean(a);

        percentChange = NaN;

        if mean(a)~=0
            percentChange = ...
                100*difference/abs(mean(a));
        end

        draws = zeros(nBootstrap,1);

        for z = 1:nBootstrap

            x = a(randi(numel(a),numel(a),1));
            y = b(randi(numel(b),numel(b),1));

            draws(z) = mean(y)-mean(x);
        end

        ci = localPercentile(draws,[2.5 97.5]);

        comparisons = [comparisons;table( ...
            R,string(field), ...
            numel(a),numel(b), ...
            mean(a),mean(b),difference, ...
            percentChange,ci(1),ci(2), ...
            'VariableNames',{ ...
            'Load_Ohm','Metric', ...
            'EmpiricalTrials','FasterTrials', ...
            'EmpiricalMean','FasterMean', ...
            'FasterMinusEmpirical', ...
            'ChangePercent', ...
            'CI95_Lower','CI95_Upper'})]; %#ok<AGROW>

    end
end

writetable(comparisons,fullfile( ...
    outDir,'E03_ControllerComparisons.csv'));

%% 3. Settling summary

settlingStats = table();

for R = loads

    for c = controllers

        for b = [0.03 0.05 0.10 0.20]

            Q = ST( ...
                ST.Load_Ohm==R & ...
                ST.Controller==c & ...
                abs(ST.Band_mA-b)<1e-9,:);

            if isempty(Q)
                continue;
            end

            achieved = isfinite(Q.Hold2s_s);

            meanTime = NaN;

            if any(achieved)
                meanTime = mean(Q.Hold2s_s(achieved));
            end

            settlingStats = [settlingStats;table( ...
                R,c,b,height(Q), ...
                nnz(achieved), ...
                nnz(achieved)/height(Q),meanTime, ...
                'VariableNames',{ ...
                'Load_Ohm','Controller','Band_mA', ...
                'Trials','SettledTrials', ...
                'SuccessFraction','MeanHold2s_s'})]; ...
                %#ok<AGROW>

        end
    end
end

writetable(settlingStats,fullfile( ...
    outDir,'E03_SettlingConditionSummary.csv'));

%% 4. Representative trials

% Select trial nearest median 30-second RMSE.
representatives = table();

for R = loads

    for c = controllers

        Q = T( ...
            T.Load_Ohm==R & T.Controller==c,:);

        if isempty(Q)
            continue;
        end

        med = median(Q.Early30RMSE_mA);

        [~,i] = min(abs(Q.Early30RMSE_mA-med));

        representatives = [representatives; ...
            Q(i,{'File','Load_Ohm', ...
            'Controller','Trial', ...
            'Early30RMSE_mA'})]; %#ok<AGROW>

    end
end

writetable(representatives,fullfile( ...
    outDir,'E03_RepresentativeTrials.csv'));

%% 5. Figure E03-1: Representative transients

f1 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1100 800]);

tiledlayout(2,2,'TileSpacing','compact');

importantLoads = [100 4000];

for j = 1:2

    R = importantLoads(j);

    nexttile;
    hold on;

    for c = 1:2

        Q = representatives( ...
            representatives.Load_Ohm==R & ...
            representatives.Controller==controllers(c),:);

        ix = locateTrajectory(X,R, ...
            controllers(c),Q.Trial);

        assert(~isempty(ix));

        plot(X(ix).Time_s,X(ix).Current_mA, ...
            'Color',colours(c,:), ...
            'DisplayName',controllers(c), ...
            'LineWidth',0.85);

    end

    yline(10,'k--','HandleVisibility','off');

    xlim([0 30]);

    xlabel('Elapsed time (s)');
    ylabel('Measured current (mA)');
    title(sprintf('%d ohm: measured current',R));

    legend('Location','best');
    grid on;
    set(gca,'FontSize',fontSize);

    nexttile;
    hold on;

    for c = 1:2

        Q = representatives( ...
            representatives.Load_Ohm==R & ...
            representatives.Controller==controllers(c),:);

        ix = locateTrajectory(X,R, ...
            controllers(c),Q.Trial);

        stairs(X(ix).Time_s,X(ix).AppliedCounter, ...
            'Color',colours(c,:), ...
            'DisplayName',controllers(c));

    end

    xlim([0 30]);

    xlabel('Elapsed time (s)');
    ylabel('Applied DAC Counter');
    title(sprintf('%d ohm: command response',R));

    legend('Location','best');
    grid on;
    set(gca,'FontSize',fontSize);

end

sgtitle('E03-1: Representative PI Transient Responses');

%% 6. Figure E03-2: Mean trajectories

f2 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1100 500]);

hold on;

R = 4000;
gridTime = (0:0.2:30)';

for c = 1:2

    selection = find( ...
        [X.Load_Ohm]==R & ...
        string({X.Controller})==controllers(c));

    curves = nan(numel(gridTime),numel(selection));

    for k = 1:numel(selection)

        q = selection(k);

        curves(:,k) = interp1( ...
            X(q).Time_s,X(q).Current_mA, ...
            gridTime,'linear',NaN);

    end

    meanCurve = mean(curves,2,'omitnan');
    sdCurve = std(curves,0,2,'omitnan');

    valid = isfinite(meanCurve) & isfinite(sdCurve);

    t = gridTime(valid);
    mu = meanCurve(valid);
    sigma = sdCurve(valid);

    fill([t;flipud(t)], ...
        [mu-sigma;flipud(mu+sigma)], ...
        colours(c,:), ...
        'FaceAlpha',0.12, ...
        'EdgeColor','none', ...
        'HandleVisibility','off');

    plot(t,mu, ...
        'Color',colours(c,:), ...
        'LineWidth',1.7, ...
        'DisplayName',controllers(c));

end

yline(10,'k--','HandleVisibility','off');

xlabel('Elapsed time (s)');
ylabel('Measured current (mA)');

title(['E03-2: 4 kOhm Trial-Aligned Mean ' ...
       'Current, with +/-1 SD']);

legend('Location','best');
grid on;

% Interpolation is for illustration only.
% Primary metrics use actual timestamps.

%% 7. Figure E03-3: Early RMSE

f3 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1100 760]);

tiledlayout(2,1,'TileSpacing','compact');

fields = {'Early10RMSE_mA','Early30RMSE_mA'};

for panel = 1:2

    nexttile;
    hold on;

    for c = 1:2

        y = nan(numel(loads),1);

        for j = 1:numel(loads)

            ix = condition.Load_Ohm==loads(j) & ...
                condition.Controller==controllers(c);

            if panel==1
                y(j) = condition.Early10RMSE_mA(ix);
            else
                y(j) = condition.Early30RMSE_mA(ix);
            end
        end

        plot(loads,y,'-o','LineWidth',1.6, ...
            'Color',colours(c,:), ...
            'DisplayName',controllers(c));

        % Individual trial values
        scatter(T.Load_Ohm(T.Controller==controllers(c)), ...
            T.(fields{panel})(T.Controller==controllers(c)), ...
            14,colours(c,:),'filled', ...
            'MarkerFaceAlpha',0.22, ...
            'HandleVisibility','off');

    end

    xlabel('Resistance (ohm)');
    ylabel('Measured-current RMSE (mA)');

    title(sprintf('First %d seconds',panel*20-10));

    legend('Location','best');
    grid on;

end

sgtitle('E03-3: Early Tracking Error');

%% 8. Figure E03-4: Settling success

f4 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1000 550]);

hold on;

for c = 1:2

    y = nan(numel(loads),1);

    for j = 1:numel(loads)

        ix = ...
            settlingStats.Load_Ohm==loads(j) & ...
            settlingStats.Controller==controllers(c) & ...
            abs(settlingStats.Band_mA-0.10)<1e-8;

        y(j) = settlingStats.SuccessFraction(ix);
    end

    plot(loads,100*y,'-o', ...
        'Color',colours(c,:), ...
        'LineWidth',1.5, ...
        'DisplayName',controllers(c));

end

xlabel('Resistance (ohm)');
ylabel('Trials with sustained 2 s settling (%)');

title('E03-4: Sustained Settling within +/-0.100 mA');

legend('Location','best');
ylim([0 105]);
grid on;

%% 9. Figure E03-5: Full and steady RMSE

f5 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1050 710]);

tiledlayout(2,1,'TileSpacing','compact');

fields = {'FullRMSE_mA','SteadyRMSE_mA'};

for panel = 1:2

    nexttile;
    hold on;

    for c = 1:2

        values = nan(size(loads));

        for j = 1:numel(loads)

            ix = ...
                condition.Load_Ohm==loads(j) & ...
                condition.Controller==controllers(c);

            values(j) = condition.(fields{panel})(ix);
        end

        plot(loads,values,'-o', ...
            'Color',colours(c,:), ...
            'LineWidth',1.5, ...
            'DisplayName',controllers(c));

    end

    xlabel('Resistance (ohm)');
    ylabel('Measured-current RMSE (mA)');

    title(fields{panel},'Interpreter','none');

    legend('Location','best');
    grid on;
end

sgtitle('E03-5: Full-Run and Steady-State Regulation');

%% 10. Figure E03-6: Switching activity

f6 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1000 550]);

hold on;

for c = 1:2

    values = nan(size(loads));

    for j = 1:numel(loads)

        ix = ...
            condition.Load_Ohm==loads(j) & ...
            condition.Controller==controllers(c);

        values(j) = condition.SteadySwitchRate(ix);
    end

    plot(loads,values,'-o', ...
        'LineWidth',1.5, ...
        'Color',colours(c,:), ...
        'DisplayName',controllers(c));

end

xlabel('Resistance (ohm)');
ylabel('Steady applied DAC changes/s');
title('E03-6: Steady DAC Switching Activity');

legend('Location','best');
grid on;

%% 11. Figure E03-7: Integral contribution

f7 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1000 560]);

hold on;

for c = 1:2

    Q = representatives( ...
        representatives.Load_Ohm==4000 & ...
        representatives.Controller==controllers(c),:);

    ix = locateTrajectory(X,4000, ...
        controllers(c),Q.Trial);

    plot(X(ix).Time_s,X(ix).ITerm, ...
        'LineWidth',1.2, ...
        'Color',colours(c,:), ...
        'DisplayName',controllers(c));

end

xlabel('Elapsed time (s)');
ylabel('Logged integral contribution (counts)');

title('E03-7: Integral Correction at 4 kOhm');

legend('Location','best');
grid on;

%% 12. Figure E03-8: Faster PI advantage by load

f8 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1050 560]);

improvement = nan(size(loads));

for j = 1:numel(loads)

    ix = comparisons.Load_Ohm==loads(j) & ...
        comparisons.Metric=="Early30RMSE_mA";

    improvement(j) = ...
        -comparisons.FasterMinusEmpirical(ix);
end

bar(loads,improvement);

yline(0,'k-');

xlabel('Resistance (ohm)');
ylabel('Reduction in first 30 s RMSE (mA)');

title('E03-8: Faster PI Transient Benefit by Load');

grid on;

%% 13. Figure E03-9: Initial error vs gain benefit

f9 = figure('Visible','off','Color','w', ...
    'Position',[100 100 900 550]);

hold on;

for j = 1:numel(loads)

    Q = T(T.Load_Ohm==loads(j),:);

    meanInitial = mean(abs(Q.InitialError_mA));

    scatter(meanInitial,improvement(j),85,'filled');

    text(meanInitial,improvement(j), ...
        sprintf('  %d ohm',loads(j)));

end

xlabel('Mean absolute initial error (mA)');
ylabel('Faster PI first-30-s RMSE reduction (mA)');

title('E03-9: Initial Error and Observed Benefit');

grid on;

%% 14. Figure E03-10: Historical simulation context

f10 = figure('Visible','off','Color','w', ...
    'Position',[100 100 920 560]);

hold on;

ixE = condition.Load_Ohm==4000 & ...
    condition.Controller=="Empirical";

ixF = condition.Load_Ohm==4000 & ...
    condition.Controller=="Faster";

hardware = [ ...
    condition.Early30RMSE_mA(ixE), ...
    condition.Early30RMSE_mA(ixF)];

bar(1:2,hardware);

xticks([1 2]);
xticklabels({'Empirical','Faster'});

ylabel('First 30 s hardware RMSE (mA)');

title(['E03-10: Measured 4 kOhm Tracking ' ...
       '(Simulation Is a Separate Observable)']);

grid on;

% Do not invent or recreate the earlier simulated
% current trajectory. The numerical simulation
% comparison is documented in the report.

%% 15. Export ten figures

figs = {f1,f2,f3,f4,f5,f6,f7,f8,f9,f10};

names = { ...
    'E03_Fig01_RepresentativeTransient', ...
    'E03_Fig02_MeanTransient', ...
    'E03_Fig03_TransientRMSE', ...
    'E03_Fig04_Settling', ...
    'E03_Fig05_FullSteadyRMSE', ...
    'E03_Fig06_DACSwitching', ...
    'E03_Fig07_IntegralTerm', ...
    'E03_Fig08_LoadBenefit', ...
    'E03_Fig09_InitialErrorBenefit', ...
    'E03_Fig10_HardwareContext'};

for k = 1:numel(figs)

    exportgraphics(figs{k}, ...
        fullfile(figDir,[names{k} '.png']), ...
        'Resolution',resolution);

    exportgraphics(figs{k}, ...
        fullfile(figDir,[names{k} '.pdf']), ...
        'ContentType','vector');

    close(figs{k});

    fprintf('Exported E03 Figure %02d\n',k);

end

%% 16. Optional Stage 2D-F comparison

simComparison = table();

simPath = fullfile(scriptDir,'F2_MainTrials.csv');

if isfile(simPath)

    SIM = readtable(simPath);

    for c = 1:2

        if c==1
            simController = "Empirical";
        else
            simController = "Moderately faster";
        end

        ix = ...
            string(SIM.Controller)==simController & ...
            string(SIM.NoiseModel)=="N2" & ...
            abs(SIM.Deadband_mA-0.030)<1e-8;

        if ~any(ix)
            continue;
        end

        simComparison = [simComparison;table( ...
            controllers(c), ...
            mean(SIM.FullRMSE_mA(ix)), ...
            mean(SIM.SteadyRMSE_mA(ix)), ...
            mean(SIM.SteadySwitchRate(ix)), ...
            'VariableNames',{ ...
            'Controller','SimFullTrueRMSE_mA', ...
            'SimSteadyTrueRMSE_mA', ...
            'SimSteadySwitchRate'})]; %#ok<AGROW>
    end

else

    fprintf(['Stage 2D-F comparison omitted: ' ...
             'F2_MainTrials.csv not supplied.\n']);
end

writetable(simComparison,fullfile( ...
    outDir,'E03_SimulationComparison.csv'));

%% 17. Statistical summary

fid = fopen(fullfile(outDir, ...
    'E03_StatisticalSummary.txt'),'w');

assert(fid>0,'Cannot create statistical summary.');

fprintf(fid,'E03 PI GAIN VALIDATION\n\n');

fprintf(fid,'Trials: %d\n',height(T));

fprintf(fid,'Bootstrap: %d independent-trial resamples\n', ...
    nBootstrap);

fprintf(fid,'Seed: %d\n\n',bootstrapSeed);

for j = 1:height(comparisons)

    Q = comparisons(j,:);

    fprintf(fid, ...
        ['R=%d, %s: Delta=%.6f, ' ...
         '95%% CI [%.6f, %.6f]\n'], ...
        Q.Load_Ohm,char(Q.Metric), ...
        Q.FasterMinusEmpirical, ...
        Q.CI95_Lower,Q.CI95_Upper);

end

fclose(fid);

%% 18. Full human-readable report

fid = fopen(fullfile(outDir, ...
    'E03_FullReport.txt'),'w');

assert(fid>0,'Cannot create report.');

fprintf(fid,'E03 HARDWARE PI GAIN VALIDATION\n\n');
fprintf(fid,'Generated: %s\n',datestr(now));
fprintf(fid,'MATLAB: %s\n\n',version);

fprintf(fid,'Discovered files: %d\n',height(A));
fprintf(fid,'Eligible trials: %d\n\n',height(T));

fprintf(fid, ...
    ['Empirical: Kp=5.000000, Ki=3.000000.\n' ...
     'Faster: Kp=4.867577, Ki=9.758558.\n' ...
     'Numerical settings require firmware confirmation.\n\n']);

fprintf(fid, ...
    ['All experimental error metrics use the Arduino ' ...
     'feedback-current measurement.\n\n']);

for k = 1:height(condition)

    Q = condition(k,:);

    fprintf(fid, ...
        ['R=%d, %s (n=%d): ' ...
         'RMSE10=%.6f, RMSE30=%.6f, ' ...
         'RMSEsteady=%.6f, switching=%.4f/s\n'], ...
        Q.Load_Ohm,char(Q.Controller),Q.Trials, ...
        Q.Early10RMSE_mA, ...
        Q.Early30RMSE_mA, ...
        Q.SteadyRMSE_mA, ...
        Q.SteadySwitchRate);

end

fprintf(fid, ...
    ['\nThe comparison is unpaired unless experimental ' ...
     'blocking is independently documented.\n']);

fprintf(fid, ...
    ['Simulation true-current RMSE and measured ' ...
     'hardware feedback-current RMSE are distinct.\n']);

fclose(fid);

%% 19. Final Markdown checkpoint

fid = fopen(fullfile(outDir, ...
    'E03_Final_Verification_and_Design_Checkpoint.md'),'w');

assert(fid>0,'Cannot create Markdown checkpoint.');

fprintf(fid,'# E03: Hardware PI Gain Validation\n\n');

fprintf(fid,'Generated: %s\n\n',datestr(now));

fprintf(fid,'## Experimental objective\n\n');

fprintf(fid, ...
    ['Compare empirical and model-derived PI gains ' ...
     'at identical 0.030 mA deadband, with current ' ...
     'measured by the Arduino feedback system.\n\n']);

fprintf(fid,'## Controller configurations\n\n');

fprintf(fid,'| Controller | Kp | Ki |\n');
fprintf(fid,'|---|---:|---:|\n');
fprintf(fid,'| Empirical | 5.000000 | 3.000000 |\n');
fprintf(fid,'| Faster | 4.867577 | 9.758558 |\n\n');

fprintf(fid, ...
    ['These expected gains are not independently ' ...
     'established by the filename alone.\n\n']);

fprintf(fid,'## Hardware results\n\n');

fprintf(fid, ...
    ['| Load (ohm) | Controller | n ' ...
     '| First 10 s RMSE | First 30 s RMSE ' ...
     '| Steady RMSE | DAC changes/s |\n']);

fprintf(fid,'|---:|---|---:|---:|---:|---:|---:|\n');

for k = 1:height(condition)

    Q = condition(k,:);

    fprintf(fid, ...
        '| %d | %s | %d | %.6f | %.6f | %.6f | %.4f |\n', ...
        Q.Load_Ohm,char(Q.Controller),Q.Trials, ...
        Q.Early10RMSE_mA,Q.Early30RMSE_mA, ...
        Q.SteadyRMSE_mA,Q.SteadySwitchRate);

end

fprintf(fid,'\n## Statistical comparisons\n\n');

fprintf(fid, ...
    ['The sign convention is Faster minus Empirical. ' ...
     'Negative RMSE differences indicate lower ' ...
     'measured error for the faster PI.\n\n']);

fprintf(fid, ...
    ['Confidence intervals use independent-trial ' ...
     'bootstrap resampling with %d replicates ' ...
     'and seed %d.\n\n'], ...
    nBootstrap,bootstrapSeed);

fprintf(fid,'## Settling and convergence\n\n');

fprintf(fid, ...
    ['Primary settling is evaluated on raw burst ' ...
     'measurements. First crossing, 2-second ' ...
     'sustained entry and permanent settling ' ...
     'are reported separately.\n\n']);

fprintf(fid, ...
    ['Absence of permanent settling inside a narrow ' ...
     'band does not necessarily indicate an ' ...
     'unsuccessful controller because the feedback ' ...
     'current exhibits measured variability.\n\n']);

fprintf(fid,'## Historical model comparison\n\n');

fprintf(fid, ...
    ['The nominal 4 kOhm model was ' ...
     'I=9.593752+0.0458338958*(u-215) mA.\n\n']);

fprintf(fid, ...
    ['Hardware RMSE uses measured feedback current, ' ...
     'not the simulated true-current variable.\n\n']);

fprintf(fid,'## Limitations\n\n');

fprintf(fid, ...
    ['The experiments measure Arduino feedback ' ...
     'current, not independently calibrated ' ...
     'true delivered current.\n\n']);

fprintf(fid, ...
    ['The trials are treated as independent unless ' ...
     'acquisition blocks are documented.\n\n']);

fprintf(fid, ...
    ['The actual Ki firmware setting has not been ' ...
     'independently verified by this analysis.\n\n']);

fprintf(fid, ...
    ['Trial-aligned mean trajectories use interpolation ' ...
     'for visualisation only.\n\n']);

fprintf(fid,'## Figure inventory\n\n');

for k = 1:numel(names)

    fprintf(fid, ...
        '%d. `%s.png` and `%s.pdf`\n', ...
        k,names{k},names{k});

end

fprintf(fid,'\n## Reproducibility\n\n');

fprintf(fid,'MATLAB version: %s\n\n',version);

fprintf(fid, ...
    ['Scripts: analyse_E03_PI_gains.m and ' ...
     'report_E03_PI_gains.m.\n\n']);

fprintf(fid, ...
    ['Primary data: E03 CSVs in Empirical/ ' ...
     'and Faster/. Original recordings unchanged.\n\n']);

fprintf(fid, ...
    ['Processed archive: E03_PI_Results/' ...
     'E03_ProcessedResults.mat.\n']);

fclose(fid);

%% 20. Final verification

assert(height(condition)==2*numel(loads));

assert(numel(figs)==10);

for k = 1:numel(names)

    assert(isfile(fullfile( ...
        figDir,[names{k} '.png'])));

    assert(isfile(fullfile( ...
        figDir,[names{k} '.pdf'])));

end

fprintf('\nE03 REPORT COMPLETED\n');

disp(condition);

%% ============================================================
% Local functions
% ============================================================

function ix = locateTrajectory(X,R,C,trial)

    ix = [];

    for k = 1:numel(X)

        if X(k).Load_Ohm==R && ...
                X(k).Controller==C && ...
                X(k).Trial==trial

            ix = k;
            return;
        end
    end

end

function p = localPercentile(x,percent)

    x = sort(x(isfinite(x)));

    n = numel(x);
    p = nan(size(percent));

    if n==0
        return;
    end

    for k = 1:numel(percent)

        if n==1
            p(k) = x(1);
            continue;
        end

        position = 1+(n-1)*percent(k)/100;

        lo = floor(position);
        hi = ceil(position);

        f = position-lo;

        p(k) = x(lo)*(1-f)+x(hi)*f;

    end

end
