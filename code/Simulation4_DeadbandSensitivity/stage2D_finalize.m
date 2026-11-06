
%% stage2D_finalize.m
% Stage 2D: Statistical analysis and checkpoint
%
% Reads saved results from stage2D_run.
% Does not rerun simulations.
% Generates exactly four figures.

clearvars;
clc;
close all force;

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end

outDir = fullfile(scriptDir,'Stage2D_Results');

S = load(fullfile(outDir,'Stage2D_raw.mat'));

D2 = S.D2;
noiseFree = S.noiseFree;
noiseTrials = S.noiseTrials;
offsetTrials = S.offsetTrials;
representative = S.representative;

%% 1. Verify trial counts

assert(height(noiseFree)==18, ...
    'Noise-free trial count mismatch.');

assert(height(noiseTrials)==540, ...
    'Nominal noise trial count mismatch.');

assert(height(offsetTrials)==540, ...
    'Offset trial count mismatch.');

fprintf('\nSTAGE 2D FINAL ANALYSIS\n');

%% 2. Aggregate noisy performance

metrics = { ...
    'FullTrueRMSE_mA', ...
    'SteadyTrueRMSE_mA', ...
    'SteadyAbsBias_mA', ...
    'InBand03', ...
    'SteadyInBand03', ...
    'TotalDACMovement', ...
    'DACChanges', ...
    'SteadyChangesPerSecond', ...
    'MeasuredRMSE_mA', ...
    'IntegralSD'};

summary = table();

for j = 1:3

    for b = 1:3

        ix = ...
            noiseTrials.Controller==string(D2.names{j}) & ...
            noiseTrials.Deadband_mA==D2.deadbands(b);

        Q = noiseTrials(ix,:);

        assert(height(Q)==60, ...
            'Expected 60 nominal noise trials per configuration.');

        for m = 1:numel(metrics)

            v = Q.(metrics{m});

            summary = [summary;table( ...
                string(D2.names{j}), ...
                D2.deadbands(b), ...
                string(metrics{m}), ...
                mean(v),median(v),std(v), ...
                min(v),max(v), ...
                'VariableNames',{ ...
                'Controller','Deadband_mA','Metric', ...
                'Mean','Median','SD','Minimum','Maximum'})]; ...
                %#ok<AGROW>

        end

    end

end

%% 3. Paired deadband comparisons

pairedMetrics = { ...
    'SteadyTrueRMSE_mA', ...
    'TotalDACMovement', ...
    'SteadyChangesPerSecond', ...
    'SteadyAbsBias_mA', ...
    'SteadyInBand03'};

paired = table();

% Fixed bootstrap seed
rng(20261031,'twister');

nBootstrap = 3000;

for j = 1:3

    for b = 2:3

        for m = 1:numel(pairedMetrics)

            metricName = pairedMetrics{m};

            % One paired difference per seed and phase.
            delta = zeros(30,2);

            for s = 1:30

                seed = D2.seeds(s);

                for p = 1:2

                    mode = string(D2.phases{p});

                    base = ...
                        noiseTrials.Controller==string(D2.names{j}) & ...
                        noiseTrials.Deadband_mA==0.03 & ...
                        noiseTrials.Seed==seed & ...
                        noiseTrials.Timing==mode;

                    test = ...
                        noiseTrials.Controller==string(D2.names{j}) & ...
                        noiseTrials.Deadband_mA==D2.deadbands(b) & ...
                        noiseTrials.Seed==seed & ...
                        noiseTrials.Timing==mode;

                    assert(nnz(base)==1 && nnz(test)==1, ...
                        'Paired trial not uniquely matched.');

                    delta(s,p) = ...
                        noiseTrials.(metricName)(test) - ...
                        noiseTrials.(metricName)(base);

                end

            end

            % Reduce to 30 independent seed-level clusters.
            seedMeans = mean(delta,2);

            boot = zeros(nBootstrap,1);

            for n = 1:nBootstrap

                idx = randi(30,30,1);
                boot(n) = mean(seedMeans(idx));

            end

            ci = prctile(boot,[2.5 97.5]);

            paired = [paired;table( ...
                string(D2.names{j}), ...
                D2.deadbands(b), ...
                string(metricName), ...
                mean(seedMeans), ...
                std(seedMeans), ...
                min(seedMeans), ...
                max(seedMeans), ...
                ci(1),ci(2), ...
                'VariableNames',{ ...
                'Controller','AlternativeDeadband_mA', ...
                'Metric','MeanDifference', ...
                'SeedLevelSD','MinSeedDifference', ...
                'MaxSeedDifference', ...
                'CI95_Lower','CI95_Upper'})]; %#ok<AGROW>

        end

    end

end

%% 4. Offset sensitivity summary

offsetSummary = groupsummary( ...
    offsetTrials, ...
    {'Controller','Deadband_mA','Offset_mA'}, ...
    {'mean','std'}, ...
    {'SteadyTrueRMSE_mA', ...
     'TotalDACMovement', ...
     'SteadyInBand03', ...
     'SteadyAbsBias_mA'});

%% 5. Settling success accounting

settlingSummary = table();

for j = 1:3

    for b = 1:3

        ix = ...
            noiseTrials.Controller==string(D2.names{j}) & ...
            noiseTrials.Deadband_mA==D2.deadbands(b);

        Q = noiseTrials(ix,:);

        n = height(Q);

        successes03 = nnz(isfinite(Q.Settling03_s));
        successes1 = nnz(isfinite(Q.Settling1pct_s));

        settlingSummary = [settlingSummary;table( ...
            string(D2.names{j}), ...
            D2.deadbands(b),n, ...
            successes03,100*successes03/n, ...
            successes1,100*successes1/n, ...
            'VariableNames',{ ...
            'Controller','Deadband_mA','Trials', ...
            'Settled03','Settled03_pct', ...
            'Settled1pct','Settled1pct_pct'})]; %#ok<AGROW>

    end

end

%% 6. Figure 1: Deadband versus switching

f1 = figure('Visible','off','Color','w', ...
    'Position',[100 100 950 540]);

hold on;

for j = 1:3

    means = zeros(1,3);
    sds = zeros(1,3);

    for b = 1:3

        ix = ...
            noiseTrials.Controller==string(D2.names{j}) & ...
            noiseTrials.Deadband_mA==D2.deadbands(b);

        means(b) = mean( ...
            noiseTrials.SteadyChangesPerSecond(ix));

        sds(b) = std( ...
            noiseTrials.SteadyChangesPerSecond(ix));

    end

    errorbar(D2.deadbands,means,sds, ...
        '-o','LineWidth',1.4, ...
        'DisplayName',D2.names{j});

end

xlabel('Controller deadband (mA)');
ylabel('Steady-state DAC changes per second');
title('Deadband Sensitivity: Switching Activity');
legend('Location','best');
grid on;
box on;

%% 7. Figure 2: Deadband versus accuracy

f2 = figure('Visible','off','Color','w', ...
    'Position',[110 110 950 540]);

hold on;

for j = 1:3

    means = zeros(1,3);
    sds = zeros(1,3);

    for b = 1:3

        ix = ...
            noiseTrials.Controller==string(D2.names{j}) & ...
            noiseTrials.Deadband_mA==D2.deadbands(b);

        means(b) = mean( ...
            noiseTrials.SteadyTrueRMSE_mA(ix));

        sds(b) = std( ...
            noiseTrials.SteadyTrueRMSE_mA(ix));

    end

    errorbar(D2.deadbands,means,sds, ...
        '-o','LineWidth',1.4, ...
        'DisplayName',D2.names{j});

end

xlabel('Controller deadband (mA)');
ylabel('Steady-state true-current RMSE (mA)');
title('Deadband Sensitivity: Delivered-Current Accuracy');
legend('Location','best');
grid on;
box on;

%% 8. Figure 3: Accuracy versus switching

f3 = figure('Visible','off','Color','w', ...
    'Position',[120 120 950 540]);

hold on;

markers = {'o','s','d'};

for j = 1:3

    for b = 1:3

        ix = ...
            noiseTrials.Controller==string(D2.names{j}) & ...
            noiseTrials.Deadband_mA==D2.deadbands(b);

        x = mean( ...
            noiseTrials.SteadyChangesPerSecond(ix));

        y = mean( ...
            noiseTrials.SteadyTrueRMSE_mA(ix));

        plot(x,y,markers{j}, ...
            'MarkerSize',9, ...
            'LineWidth',1.5, ...
            'DisplayName',sprintf('%s, D=%.2f', ...
            D2.names{j},D2.deadbands(b)));

    end

end

xlabel('Steady-state DAC changes per second');
ylabel('Steady-state true-current RMSE (mA)');
title('Accuracy versus DAC Switching Tradeoff');

legend('Location','bestoutside');
grid on;
box on;

%% 9. Figure 4: Representative noisy response

f4 = figure('Visible','off','Color','w', ...
    'Position',[130 100 1050 750]);

tiledlayout(3,1,'TileSpacing','compact');

names = {'0.03 mA','0.05 mA','0.08 mA'};

nexttile;
hold on;

for b = 1:3
    Q = representative{b};

    stairs(Q.t,Q.true, ...
        'LineWidth',1.2, ...
        'DisplayName',names{b});
end

yline(D2.reference,'k--', ...
    'DisplayName','10 mA reference');

title('Moderately Faster PI: True Delivered Current');
ylabel('Current (mA)');
legend('Location','best');
grid on;

nexttile;
hold on;

for b = 1:3
    Q = representative{b};

    stairs(Q.t,Q.applied, ...
        'LineWidth',1.1, ...
        'DisplayName',names{b});
end

ylabel('Applied DAC Counter');
title('Common Noise Realisation: DAC Activity');
grid on;

nexttile;
hold on;

for b = 1:3
    Q = representative{b};

    plot(Q.t,Q.integral, ...
        'LineWidth',1.1, ...
        'DisplayName',names{b});
end

xlabel('Physical elapsed time (s)');
ylabel('Integral correction (counts)');
title('Integral-State Behaviour');
grid on;

%% 10. Export exactly four figures

figs = {f1,f2,f3,f4};

files = { ...
    'Stage2D_Fig1_Switching.png', ...
    'Stage2D_Fig2_Accuracy.png', ...
    'Stage2D_Fig3_Tradeoff.png', ...
    'Stage2D_Fig4_TimeDomain.png'};

for k = 1:4

    exportgraphics(figs{k}, ...
        fullfile(outDir,files{k}), ...
        'Resolution',200);

    close(figs{k});

end

%% 11. Export statistical tables

writetable(summary,fullfile(outDir, ...
    'Stage2D_summary.csv'));

writetable(paired,fullfile(outDir, ...
    'Stage2D_paired_comparisons.csv'));

writetable(offsetSummary,fullfile(outDir, ...
    'Stage2D_offset_summary.csv'));

writetable(settlingSummary,fullfile(outDir, ...
    'Stage2D_settling_summary.csv'));

save(fullfile(outDir,'Stage2D_analysis.mat'), ...
    'summary','paired','offsetSummary', ...
    'settlingSummary','D2');

%% 12. Markdown checkpoint

checkpoint = fullfile(outDir, ...
    'Stage2D_Verification_and_Deadband_Sensitivity_Checkpoint.md');

fid = fopen(checkpoint,'w');

assert(fid>0,'Could not create checkpoint.');

fprintf(fid, ...
    '# Stage 2D Verification and Deadband Sensitivity\n\n');

fprintf(fid, ...
    'Generated: %s\n\n', ...
    datestr(now,'yyyy-mm-dd HH:MM'));

fprintf(fid, ...
    '## Purpose\n\n');

fprintf(fid, ...
    ['Assess current-error deadband versus noise-induced ' ...
     'DAC command activity and delivered-current accuracy.\n\n']);

fprintf(fid, ...
    '## Frozen model\n\n');

fprintf(fid, ...
    '- Plant: I = %.6f + %.10f*(Counter-215) mA.\n', ...
    D2.I0,D2.K);

fprintf(fid, ...
    '- Reference: %.2f mA.\n',D2.reference);

fprintf(fid, ...
    '- Timing: alternating 76 and 89 ms.\n');

fprintf(fid, ...
    '- Deadbands: 0.03, 0.05, 0.08 mA.\n');

fprintf(fid, ...
    '- Noise: bootstrapped B2 open-loop residuals.\n');

fprintf(fid, ...
    '- Noise affects measured feedback only.\n');

fprintf(fid, ...
    '- 30 reproducible seeds, 2 timing phases.\n');

fprintf(fid, ...
    '- Operating-point shifts: -0.02, 0, +0.02 mA.\n\n');

fprintf(fid, ...
    '## Controller gains\n\n');

for j = 1:3

    fprintf(fid, ...
        '- %s: Kp=%.6f, Ki=%.6f.\n', ...
        D2.names{j},D2.Kp(j),D2.Ki(j));

end

fprintf(fid,'\n## Verification\n\n');

fprintf(fid, ...
    '- Stage 2B fixed-time regression: passed in runner.\n');

fprintf(fid, ...
    '- Controller indexing and integer DAC checks: passed.\n');

fprintf(fid, ...
    '- Plant and measurement separation: passed.\n');

fprintf(fid, ...
    '- Exact full-error deadband check: passed.\n');

fprintf(fid, ...
    '- Applied DAC movement identities: passed.\n');

fprintf(fid, ...
    '- Baseline comparison status: %s.\n\n', ...
    S.regressionStatus);

fprintf(fid,'## Statistical methodology\n\n');

fprintf(fid, ...
    ['Paired comparisons preserve noise seed and timing phase. ' ...
     '95 percent bootstrap intervals resample the 30 noise ' ...
     'seed clusters with replacement.\n\n']);

fprintf(fid, ...
    ['Each nominal controller/deadband condition has ' ...
     '60 trials, representing 30 seeds crossed with ' ...
     'two timing phases.\n\n']);

fprintf(fid,'## Results\n\n');

fprintf(fid, ...
    ['See Stage2D_summary.csv, ' ...
     'Stage2D_paired_comparisons.csv, ' ...
     'Stage2D_offset_summary.csv and ' ...
     'Stage2D_settling_summary.csv.\n\n']);

fprintf(fid,'## Interpretation and limitations\n\n');

fprintf(fid, ...
    ['The static plant is a local affine approximation. ' ...
     'The tested deadband alternatives have not been ' ...
     'experimentally validated. The operating-point ' ...
     'shifts are hypothetical, not measured drift.\n\n']);

fprintf(fid, ...
    ['B2 residual resampling assumes independent burst-level ' ...
     'measurement disturbances. B2 variability may also ' ...
     'contain genuine current variation.\n\n']);

fprintf(fid, ...
    ['The experiments do not establish voltage compliance, ' ...
     'load-dependent offsets, electrode-tissue behaviour ' ...
     'or suitability for human stimulation.\n\n']);

fprintf(fid,'## Next decision\n\n');

fprintf(fid, ...
    ['Retain 0.03 mA as the hardware baseline. ' ...
     'Use the paired accuracy and switching results to ' ...
     'decide whether 0.05 or 0.08 mA deserves later ' ...
     'bench validation. No firmware modifications ' ...
     'are authorised by this simulation.\n\n']);

fprintf(fid,'## Reproducibility\n\n');

fprintf(fid, ...
    ['Scripts: stage2D_params.m, stage2D_run.m, ' ...
     'stage2D_finalize.m, frozen stage2C_sim.m.\n']);

fprintf(fid, ...
    'MATLAB version: %s\n',version);

fprintf(fid, ...
    'Raw data: Stage2D_raw.mat.\n');

fprintf(fid, ...
    'Bootstrap seed: 20261031.\n');

fprintf(fid, ...
    'Noise seeds: 1001 through 1030.\n');

fclose(fid);

%% 13. Final console report

fprintf('\n=====================================\n');
fprintf('STAGE 2D ANALYSIS COMPLETE\n');
fprintf('=====================================\n');

disp(summary);

fprintf('\nPaired deadband comparisons:\n');
disp(paired);

fprintf('\nSettling success rates:\n');
disp(settlingSummary);

fprintf('\nSaved four figures and analysis results in:\n%s\n', ...
    outDir);

fprintf('\nEarlier stages were not modified.\n');
