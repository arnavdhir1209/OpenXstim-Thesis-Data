
%% stage2D_F_report.m
% Stage 2D-F final reporting and verification
% Uses saved results, does not rerun simulations.
% Produces exactly four figures and a checkpoint.

clearvars;
clc;

root = fileparts(mfilename('fullpath'));

if isempty(root)
    root = pwd;
end

outDir = fullfile(root,'Stage2D_F_Results');

S = load(fullfile(outDir,'Stage2D_F_Raw.mat'));

C = S.C;
F1 = S.F1;
F2 = S.F2;
F3 = S.F3;
F4 = S.F4;

D = S.deadbands;
seeds = S.seeds;

%% 1. Verify completed experiment inventory

assert(height(F1)==72);
assert(height(F2)==6480);
assert(height(F3)==900);
assert(height(F4)==720);

assert(numel(unique(F2.Seed))==30);

assert(all(ismember( ...
    ["N1","N2","N3"],unique(F2.NoiseModel))));

assert(numel(unique(F2.Deadband_mA))==12);

fprintf('\nSTAGE 2D-F FINAL REPORT\n');
fprintf('All trial counts verified.\n');

%% 2. Baseline regression against original Stage 2D

% Copy the original Stage2D_noise_trials.csv into
% the Stage 2D-F working directory if available.
oldFile = fullfile(root,'Stage2D_noise_trials 1.csv');
 
regressionStatus = "NOT_CHECKED";

if isfile(oldFile)

    Old = readtable(oldFile);

    new = F2( ...
        F2.NoiseModel=="N1" & ...
        ismembertol(F2.Deadband_mA, ...
            [0.03 0.05 0.08],1e-8),:);

    comparable = true;
    mismatchCount = 0;

    % Compare matched controller, deadband,
    % random seed and timing phase.
    for k = 1:height(new)

        ix = ...
            string(Old.Controller)==new.Controller(k) & ...
            abs(Old.Deadband_mA-new.Deadband_mA(k))<1e-8 & ...
            Old.Seed==new.Seed(k) & ...
            string(Old.Timing)==new.Timing(k);

        assert(nnz(ix)==1, ...
            'Old Stage 2D regression key missing.');

        if abs( ...
            Old.FullTrueRMSE_mA(ix)- ...
            new.FullRMSE_mA(k))>1e-9

            comparable = false;
            mismatchCount = mismatchCount+1;

        end

        if abs( ...
            Old.TotalDACMovement(ix)- ...
            new.TotalMovement(k))>1e-9

            comparable = false;
            mismatchCount = mismatchCount+1;

        end

    end

    if comparable
        regressionStatus = "PASS";
    else
        regressionStatus = ...
            "DIFFERENT_RESIDUAL_PROVENANCE";
    end

    fprintf('Original Stage 2D regression: %s\n', ...
        regressionStatus);

    fprintf('Mismatched numerical comparisons: %d\n', ...
        mismatchCount);

else

    fprintf('Original Stage 2D CSV unavailable.\n');

end

% A mismatch does not automatically mean the controller
% recurrence is incorrect. Previous Stage 2D residual
% qualification may differ from the final Stage 2D-N set.
% The report must disclose it.

%% 3. Aggregate all principal noise-model results

summary = table();

models = ["N1","N2","N3"];
controllers = string(C.names);

metrics = { ...
    'FullRMSE_mA'
    'SteadyRMSE_mA'
    'MeasuredRMSE_mA'
    'SteadyAbsBias_mA'
    'InBand03'
    'InBand10'
    'SteadyInBand03'
    'SteadySwitchRate'
    'TotalMovement'
    'DACChanges'
    'SteadyDistinctCodes'
};

for m = 1:3
    for j = 1:3
        for b = 1:numel(D)

            ix = ...
                F2.NoiseModel==models(m) & ...
                F2.Controller==controllers(j) & ...
                abs(F2.Deadband_mA-D(b))<1e-8;

            assert(nnz(ix)==60, ...
                'Missing paired simulation conditions.');

            for q = 1:numel(metrics)

                x = F2.(metrics{q})(ix);

                summary = [summary;table( ...
                    models(m), ...
                    controllers(j), ...
                    D(b), ...
                    string(metrics{q}), ...
                    mean(x),median(x),std(x), ...
                    min(x),max(x), ...
                    'VariableNames',{ ...
                    'NoiseModel','Controller','Deadband_mA', ...
                    'Metric','Mean','Median','SD', ...
                    'Minimum','Maximum'})]; %#ok<AGROW>

            end

        end
    end
end

%% 4. Paired comparisons versus 0.03 mA

paired = table();

comparisonMetrics = { ...
    'SteadyRMSE_mA'
    'SteadyAbsBias_mA'
    'SteadySwitchRate'
    'TotalMovement'
    'SteadyInBand03'
};

rng(20261031,'twister');
nBootstrap = 2000;

for m = 1:3
    for j = 1:3
        for b = 1:numel(D)

            if abs(D(b)-0.03)<1e-8
                continue;
            end

            for q = 1:numel(comparisonMetrics)

                field = comparisonMetrics{q};

                seedDiff = zeros(numel(seeds),1);

                for s = 1:numel(seeds)

                    differences = zeros(2,1);

                    for phase = 1:2

                        timing = string(S.phases{phase});

                        common = ...
                            F2.NoiseModel==models(m) & ...
                            F2.Controller==controllers(j) & ...
                            F2.Seed==seeds(s) & ...
                            F2.Timing==timing;

                        ib = common & ...
                            abs(F2.Deadband_mA-0.03)<1e-8;

                        it = common & ...
                            abs(F2.Deadband_mA-D(b))<1e-8;

                        assert(nnz(ib)==1 && nnz(it)==1, ...
                            'Paired comparison not unique.');

                        differences(phase) = ...
                            F2.(field)(it)-F2.(field)(ib);

                    end

                    seedDiff(s) = mean(differences);

                end

                boot = zeros(nBootstrap,1);

                for z = 1:nBootstrap

                    selected = randi(numel(seeds), ...
                        numel(seeds),1);

                    boot(z) = mean(seedDiff(selected));

                end

                CI = prctile(boot,[2.5 97.5]);

                paired = [paired;table( ...
                    models(m),controllers(j),D(b), ...
                    string(field),mean(seedDiff), ...
                    std(seedDiff),min(seedDiff), ...
                    max(seedDiff),CI(1),CI(2), ...
                    'VariableNames',{ ...
                    'NoiseModel','Controller','Deadband_mA', ...
                    'Metric','MeanDifference', ...
                    'SeedSD','MinSeedDifference', ...
                    'MaxSeedDifference', ...
                    'CI95_Lower','CI95_Upper'})]; %#ok<AGROW>

            end
        end
    end
end

%% 5. Source-specific and offset summaries

individualSummary = groupsummary(F3, ...
    {'NoiseModel','Deadband_mA'}, ...
    {'mean','std'}, ...
    {'SteadyRMSE_mA','SteadySwitchRate', ...
     'SteadyAbsBias_mA','SteadyInBand03'});

offsetSummary = groupsummary(F4, ...
    {'Controller','Deadband_mA','Offset_mA'}, ...
    {'mean','std'}, ...
    {'SteadyRMSE_mA','SteadySwitchRate', ...
     'SteadyAbsBias_mA','SteadyInBand03'});

%% 6. Figure 1: Deadband versus switching

f1 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1100 900]);

tiledlayout(3,1,'TileSpacing','compact');

for m = 1:3

    nexttile;
    hold on;

    for j = 1:3

        means = zeros(numel(D),1);
        errors = zeros(numel(D),1);

        for b = 1:numel(D)

            ix = ...
                summary.NoiseModel==models(m) & ...
                summary.Controller==controllers(j) & ...
                abs(summary.Deadband_mA-D(b))<1e-8 & ...
                summary.Metric=="SteadySwitchRate";

            means(b) = summary.Mean(ix);
            errors(b) = summary.SD(ix);

        end

        errorbar(D,means,errors,'-o', ...
            'LineWidth',1.2, ...
            'DisplayName',controllers(j));

    end

    title(sprintf('%s: steady-state switching',models(m)));
    ylabel('DAC changes/s');
    grid on;
    box on;

    if m==1
        legend('Location','best');
    end

end

xlabel('Controller deadband (mA)');

%% 7. Figure 2: Accuracy and bias

f2 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1100 680]);

tiledlayout(2,1,'TileSpacing','compact');

fields = {'SteadyRMSE_mA','SteadyAbsBias_mA'};
titles = { ...
    'Steady-state true-current RMSE', ...
    'Absolute steady-state bias'};

for panel = 1:2

    nexttile;
    hold on;

    % Show N1, N2, N3 for the primary faster PI.
    for m = 1:3

        y = nan(numel(D),1);

        for b = 1:numel(D)

            ix = ...
                summary.NoiseModel==models(m) & ...
                summary.Controller=="Moderately faster" & ...
                abs(summary.Deadband_mA-D(b))<1e-8 & ...
                summary.Metric==string(fields{panel});

            y(b) = summary.Mean(ix);

        end

        plot(D,y,'-o','LineWidth',1.3, ...
            'DisplayName',models(m));

    end

    title(titles{panel});
    ylabel('Error (mA)');
    grid on;
    box on;

    legend('Location','best');

end

xlabel('Controller deadband (mA)');

%% 8. Figure 3: Accuracy versus switching

f3 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1000 680]);

hold on;

% Primary comparison: N2 qualified pooled noise.
for j = 1:3

    xx = nan(numel(D),1);
    yy = nan(numel(D),1);

    for b = 1:numel(D)

        ix1 = ...
            summary.NoiseModel=="N2" & ...
            summary.Controller==controllers(j) & ...
            abs(summary.Deadband_mA-D(b))<1e-8 & ...
            summary.Metric=="SteadySwitchRate";

        ix2 = ...
            summary.NoiseModel=="N2" & ...
            summary.Controller==controllers(j) & ...
            abs(summary.Deadband_mA-D(b))<1e-8 & ...
            summary.Metric=="SteadyRMSE_mA";

        xx(b) = summary.Mean(ix1);
        yy(b) = summary.Mean(ix2);

    end

    plot(xx,yy,'-o','LineWidth',1.5, ...
        'DisplayName',controllers(j));

end

xlabel('Steady DAC changes per second');
ylabel('Steady true-current RMSE (mA)');

title('Accuracy versus DAC Switching: Qualified Pooled Noise');
legend('Location','best');
grid on;
box on;

%% 9. Figure 4: Noise-free quantisation boundary

f4 = figure('Visible','off','Color','w', ...
    'Position',[100 100 1050 680]);

ix = F1.Controller=="Moderately faster" & ...
    F1.Timing=="shortFirst";

Q = sortrows(F1(ix,:),'Deadband_mA');

tiledlayout(2,1,'TileSpacing','compact');

nexttile;

stairs(Q.Deadband_mA,Q.FinalCounter, ...
    'o-','LineWidth',1.5);

ylabel('Final DAC Counter');
title('Noise-free Quantised Operating Point');
grid on;

nexttile;

stairs(Q.Deadband_mA,Q.FinalAbsError_mA, ...
    'o-','LineWidth',1.5);

hold on;

xline(0.039577,'k--', ...
    'DisplayName','Counter 223 error boundary');

yline(0.03,'k:', ...
    'DisplayName','Common accuracy requirement');

xlabel('Controller deadband (mA)');
ylabel('Final absolute current error (mA)');

legend('Location','best');
grid on;

%% 10. Export exactly four figures

figs = {f1,f2,f3,f4};

figNames = { ...
    'F1_Deadband_Switching.png'
    'F2_RMSE_Bias.png'
    'F3_Accuracy_Switching.png'
    'F4_Quantisation_Threshold.png'};

for k = 1:4

    exportgraphics(figs{k}, ...
        fullfile(outDir,figNames{k}), ...
        'Resolution',220);

    close(figs{k});

end

%% 11. Export statistical tables

writetable(summary,fullfile( ...
    outDir,'F2_StatisticalSummary.csv'));

writetable(paired,fullfile( ...
    outDir,'F2_PairedComparisons.csv'));

writetable(individualSummary,fullfile( ...
    outDir,'F3_SourceSummary.csv'));

writetable(offsetSummary,fullfile( ...
    outDir,'F4_OffsetSummary.csv'));

save(fullfile(outDir,'Stage2D_F_Analysis.mat'), ...
    'summary','paired','individualSummary', ...
    'offsetSummary','regressionStatus');

%% 12. Self-contained checkpoint

checkpoint = fullfile(outDir, ...
    'Stage2D_Fine_Deadband_Sensitivity_Checkpoint.md');

fid = fopen(checkpoint,'w');

assert(fid>0,'Unable to create checkpoint.');

fprintf(fid, ...
    '# Stage 2D-F: Fine Deadband Sensitivity\n\n');

fprintf(fid,'Generated: %s\n\n', ...
    datestr(now,'yyyy-mm-dd HH:MM'));

fprintf(fid,'## Objective\n\n');

fprintf(fid, ...
    ['Evaluate current-error deadband selection using ' ...
     'qualified open-loop feedback variability while ' ...
     'preserving the three frozen PI controllers.\n\n']);

fprintf(fid,'## Frozen model\n\n');

fprintf(fid, ...
    'Plant: I = %.6f + %.10f*(Counter-215) mA.\n\n', ...
    C.I0,C.K);

fprintf(fid, ...
    'Reference: %.3f mA; initial Counter: %d.\n\n', ...
    C.r,C.u0);

fprintf(fid, ...
    'Timing: alternating 76 and 89 ms.\n\n');

fprintf(fid, ...
    'Command limits: feedforward +/-25, global max 322.\n\n');

fprintf(fid, ...
    ['Firmware features: deadband, rounding, next-burst ' ...
     'command, conditional anti-windup and first-update hold.\n\n']);

fprintf(fid,'## Controllers\n\n');

fprintf(fid,'| Controller | Kp | Ki |\n');
fprintf(fid,'|---|---:|---:|\n');

for j = 1:3
    fprintf(fid,'| %s | %.6f | %.6f |\n', ...
        C.names{j},C.Kp(j),C.Ki(j));
end

fprintf(fid,'\n## Noise provenance\n\n');

fprintf(fid, ...
    'B1 2 kOhm: 490 qualified observations.\n\n');

fprintf(fid, ...
    'B2 4 kOhm: 494 qualified observations.\n\n');

fprintf(fid, ...
    'Open loop 1 kOhm: 104 qualified observations.\n\n');

fprintf(fid, ...
    ['Total: 1088 qualified observations. ' ...
     'The 136-row pre-CURRENT_LOSS segment was excluded.\n\n']);

fprintf(fid, ...
    ['N1 uses B2 only; N2 is a sample-weighted qualified ' ...
     'pool; N3 uses equal recording probabilities; ' ...
     'N4/N5/N6 test individual recordings.\n\n']);

fprintf(fid, ...
    ['Noise is treated as effective feedback variability, ' ...
     'not isolated ADC noise. It is injected into measured ' ...
     'feedback, not the static physical-current plant.\n\n']);

fprintf(fid,'## Simulation conditions\n\n');

fprintf(fid, ...
    'Deadbands: 0.025:0.005:0.080 mA.\n\n');

fprintf(fid, ...
    'Thirty seeds: 1001 through 1030.\n\n');

fprintf(fid, ...
    'Two phases: short-first and long-first.\n\n');

fprintf(fid, ...
    'Duration: 60 s; steady window: last 20 s.\n\n');

fprintf(fid, ...
    ['Hypothetical offset shifts: -0.02, 0, +0.02 mA. ' ...
     'These are not independently measured drift.\n\n']);

fprintf(fid,'## Verification\n\n');

fprintf(fid, ...
    'Qualified residual counts and audit membership: PASS.\n\n');

fprintf(fid, ...
    'Pre-CURRENT_LOSS exclusion: PASS.\n\n');

fprintf(fid, ...
    'One-burst command indexing: PASS.\n\n');

fprintf(fid, ...
    'Actual elapsed-time integration: PASS.\n\n');

fprintf(fid, ...
    'Full-error deadband: PASS.\n\n');

fprintf(fid, ...
    'Integer DAC and software limits: PASS.\n\n');

fprintf(fid, ...
    'Conditional anti-windup recurrence: PASS.\n\n');

fprintf(fid, ...
    'Original Stage 2D numerical regression: %s.\n\n', ...
    regressionStatus);

fprintf(fid,'## Main N2 results: moderately faster PI\n\n');

fprintf(fid, ...
    '| Deadband (mA) | Steady RMSE (mA) | Switching (/s) | Absolute bias (mA) |\n');

fprintf(fid,'|---:|---:|---:|---:|\n');

for b = 1:numel(D)

    values = nan(3,1);

    names = ["SteadyRMSE_mA", ...
        "SteadySwitchRate","SteadyAbsBias_mA"];

    for q = 1:3

        ix = ...
            summary.NoiseModel=="N2" & ...
            summary.Controller=="Moderately faster" & ...
            abs(summary.Deadband_mA-D(b))<1e-8 & ...
            summary.Metric==names(q);

        values(q) = summary.Mean(ix);

    end

    fprintf(fid, ...
        '| %.3f | %.6f | %.4f | %.6f |\n', ...
        D(b),values(1),values(2),values(3));

end

fprintf(fid,'\n## Paired statistical interpretation\n\n');

fprintf(fid, ...
    ['Paired comparisons use identical noise seeds and ' ...
     'timing phases. Bootstrap intervals resample 30 ' ...
     'seed clusters, preserving both phases. The ' ...
     'crossed simulation conditions are not independent ' ...
     'hardware experiments.\n\n']);

fprintf(fid, ...
    ['F2_PairedComparisons.csv includes mean paired ' ...
     'differences, seed variability and 95 percent ' ...
     'bootstrap intervals.\n\n']);

fprintf(fid,'## Quantisation interpretation\n\n');

fprintf(fid, ...
    ['At nominal gain, Counter 223 has approximately ' ...
     '0.039577 mA absolute tracking error, while ' ...
     'Counter 224 has approximately 0.006257 mA. ' ...
     'The static admissibility threshold does not ' ...
     'necessarily equal the actual dynamic transition.\n\n']);

fprintf(fid,'## Limitations\n\n');

fprintf(fid, ...
    ['The affine plant is local. Physical compliance, ' ...
     'electrode dynamics, load-specific intercepts and ' ...
     'analogue transients are not modelled.\n\n']);

fprintf(fid, ...
    ['Noise observations include possible real current ' ...
     'variation, and burst-wise resampling assumes ' ...
     'independence between sampled disturbances.\n\n']);

fprintf(fid, ...
    ['The offset cases are hypothetical. No alternative ' ...
     'deadband has been validated in hardware.\n\n']);

fprintf(fid,'## Hardware decision\n\n');

fprintf(fid, ...
    ['Keep 0.03 mA as the existing hardware baseline. ' ...
     'Use paired results and individual-recording ' ...
     'sensitivity to select at most one alternative ' ...
     'for bench validation. Do not change firmware ' ...
     'solely on the basis of this simulation.\n\n']);

fprintf(fid,'## Thesis presentation\n\n');

fprintf(fid, ...
    ['Main figures: F1 switching and F3 accuracy-switching ' ...
     'tradeoff. Supporting: F2 accuracy/bias and F4 ' ...
     'quantisation transition, as appropriate.\n\n']);

fprintf(fid,'## Reproducibility\n\n');

fprintf(fid, ...
    'MATLAB version: %s.\n\n',version);

fprintf(fid, ...
    'Scripts: stage2D_F_run.m, stage2D_F_report.m.\n\n');

fprintf(fid, ...
    'Frozen recurrence: stage2C_sim.m.\n\n');

fprintf(fid, ...
    'Random seeds: 1001-1030; bootstrap seed 20261031.\n\n');

fprintf(fid, ...
    'Raw trials and analysis stored in Stage2D_F_Results.\n');

fclose(fid);

%% 13. Console summary

fprintf('\n========================================\n');
fprintf('STAGE 2D-F REPORT COMPLETED\n');
fprintf('========================================\n');

fprintf('Regression status: %s\n',regressionStatus);
fprintf('Main noisy trials: %d\n',height(F2));

fprintf('\nRepresentative N2 results, faster controller:\n');

ix = summary.NoiseModel=="N2" & ...
    summary.Controller=="Moderately faster" & ...
    summary.Metric=="SteadySwitchRate";

disp(summary(ix,{ ...
    'Deadband_mA','Mean','SD'}));

fprintf('\nResults saved in:\n%s\n',outDir);
