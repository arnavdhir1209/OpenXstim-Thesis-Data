
%% stage2C_run.m
% Stage 2C: Timing, noise and plant-gain robustness
%
% Preserves Stage 1, Stage 2A and Stage 2B.
% Generates four figures, CSV tables and a MAT archive.

if ~exist('C','var')
    stage2C_params;
end

assert(exist('stage2B_step','file')==2, ...
    'Add the Stage 2B folder to the MATLAB path.');

assert(~isempty(C.B2file) && isfile(C.B2file), ...
    'Set C.B2file to the original B2 CSV.');

%% Read B2 open-loop noise observations

T = readtable(C.B2file);

valid = ...
    strcmpi(string(T.stim_state),'RUNNING') & ...
    isfinite(T.measured_mA) & ...
    T.counter_applied==215;

if ismember('fault_code',T.Properties.VariableNames)

    valid = valid & ...
        strcmpi(string(T.fault_code),'NONE');

end

res = double(T.measured_mA(valid));

assert(numel(res)>=100, ...
    'Insufficient valid B2 measurements.');

res = res-mean(res);

fprintf('B2 samples: %d\n',numel(res));
fprintf('B2 residual SD: %.6f mA\n',std(res));

%% 2C.0: Stage 2B baseline regression

expected = [27.225,16.7475,8.415];

X0 = cell(3,1);

for j = 1:3

    X0{j} = stage2C_sim( ...
        C,j,C.K,'fixed',0);

    M = reportMetrics(C,X0{j});

    assert( ...
        abs(M.DeadbandSettling_s-expected(j)) ...
        <=C.Ts*1.01, ...
        'Stage 2B regression failed: %s',C.names{j});

    % Check every burst against frozen Stage 2B logic.

    for k = 1:numel(X0{j}.t)

        if k==1
            xPrev = C.x0;
        else
            xPrev = X0{j}.integral(k-1);
        end

        [y,~,ed,~,xi,un,~,~,~,freeze] = ...
            stage2B_step( ...
                X0{j}.applied(k), ...
                xPrev,k-1, ...
                C.Kp(j),C.Ki(j), ...
                C.K,C.I0,C.u0,C.r,C.Ts, ...
                C.calibration,C.globalMax, ...
                C.trim,C.deadband, ...
                1,1,1,1,0);

        assert( ...
            abs(y-X0{j}.true(k))<1e-9 && ...
            abs(ed-X0{j}.adjusted(k))<1e-9 && ...
            abs(xi-X0{j}.integral(k))<1e-9 && ...
            abs(un-X0{j}.next(k))<1e-9 && ...
            logical(freeze)==X0{j}.frozen(k), ...
            'Firmware check failed at burst %d',k);

    end

end

fprintf('PASS: Stage 2B regression and firmware equivalence.\n');

%% 2C.1: Sampling-time experiment

modes = {'fixed','shortFirst','longFirst'};

timingRows = table();
timeRuns = cell(3,3);

for j = 1:3

    for a = 1:3

        Q = stage2C_sim(C,j,C.K,modes{a},0);

        if a>1

            d = diff(Q.t);

            if a==2
                firstInterval = C.tShort;
            else
                firstInterval = C.tLong;
            end

            otherInterval = ...
                C.tShort+C.tLong-firstInterval;

            assert(abs(d(1)-firstInterval)<1e-10);

            assert(all( ...
                abs(d(1:2:end)-firstInterval)<1e-9));

            assert(all( ...
                abs(d(2:2:end)-otherInterval)<1e-9));

        end

        timeRuns{j,a} = Q;

        M = reportMetrics(C,Q);

        timingRows = [timingRows; ...
            metricsRow(C,M,j,modes{a},NaN,C.K)];

    end

end

fprintf('PASS: Alternating physical sampling times.\n');

%% 2C.2: Noise sensitivity
% Same noise realisation across all three controllers.

nSeeds = numel(C.seeds);

noiseRows = table();
combinedRows = table();

exampleNoise = cell(3,1);

for s = 1:nSeeds

    rng(C.seeds(s),'twister');

    noiseDraw = res(randi( ...
        numel(res), ...
        ceil(C.stopTime/C.tShort)+8,1));

    %% Isolated noise experiment

    for j = 1:3

        X = stage2C_sim( ...
            C,j,C.K,'fixed',noiseDraw);

        M = reportMetrics(C,X);

        noiseRows = [noiseRows; ...
            metricsRow(C,M,j, ...
            'B2_bootstrap',C.seeds(s),C.K)];

        if s==1
            exampleNoise{j} = X;
        end

    end

    %% 2C.4: Combined robustness experiment

    for g = 1:numel(C.Kcases)

        for phase = 1:2

            if phase==1
                mode = 'shortFirst';
            else
                mode = 'longFirst';
            end

            for j = 1:3

                X = stage2C_sim( ...
                    C,j,C.Kcases(g),mode,noiseDraw);

                M = reportMetrics(C,X);

                combinedRows = [combinedRows; ...
                    metricsRow(C,M,j,mode, ...
                    C.seeds(s),C.Kcases(g))];

            end

        end

    end

end

fprintf('PASS: %d paired noise seeds evaluated.\n',nSeeds);

%% 2C.3: Gain-only sensitivity

gainRows = table();

gainRuns = cell(3,numel(C.Kcases));

for g = 1:numel(C.Kcases)

    for j = 1:3

        Q = stage2C_sim( ...
            C,j,C.Kcases(g),'fixed',0);

        gainRuns{j,g} = Q;

        M = reportMetrics(C,Q);

        gainRows = [gainRows; ...
            metricsRow(C,M,j,'gainOnly', ...
            NaN,C.Kcases(g))];

        % Linearised pole stability check
        K = C.Kcases(g);
        kp = C.Kp(j);
        ki = C.Ki(j);

        A = [
            -K*(kp+ki*C.Ts),1;
            -K*ki*C.Ts,     1
        ];

        assert(all(abs(eig(A))<1), ...
            'Linearised system unstable.');

    end

end

fprintf('PASS: Gain-only pole stability checks.\n');

%% Reproducibility check

rng(C.seeds(1),'twister');

checkNoise = res(randi( ...
    numel(res), ...
    ceil(C.stopTime/C.tShort)+8,1));

Xcheck = stage2C_sim( ...
    C,1,C.K,'fixed',checkNoise);

assert( ...
    isequal(Xcheck.applied,exampleNoise{1}.applied) && ...
    isequal(Xcheck.measured,exampleNoise{1}.measured), ...
    'Random-seed reproducibility failed.');

fprintf('PASS: Reproducible random noise sequence.\n');

%% Figure 1: Timing sensitivity

close all;

f1 = figure( ...
    'Color','w', ...
    'Name','2C Timing', ...
    'Visible','off');

tiledlayout(3,1,'TileSpacing','compact');

for j = 1:3

    nexttile;
    hold on;

    for a = 1:3

        Q = timeRuns{j,a};

        stairs(Q.t,Q.true, ...
            'LineWidth',1, ...
            'DisplayName',modes{a});

    end

    yline(C.r,'k:','HandleVisibility','off');

    title(C.names{j});
    ylabel('Current (mA)');
    grid on;

    if j==1
        legend('Location','southeast');
    end

end

xlabel('Physical elapsed time (s)');

%% Figure 2: Measurement noise and DAC switching

f2 = figure( ...
    'Color','w', ...
    'Name','2C Noise', ...
    'Visible','off');

tiledlayout(2,1,'TileSpacing','compact');

nexttile;
hold on;

for j = 1:3

    Q = exampleNoise{j};

    plot(Q.t,Q.true, ...
        'LineWidth',1.1, ...
        'DisplayName',[C.names{j} ' true']);

end

plot(exampleNoise{1}.t, ...
    exampleNoise{1}.measured,':', ...
    'DisplayName','Empirical measured');

yline(C.r,'k--','HandleVisibility','off');

ylabel('Current (mA)');
title('One paired B2-noise realisation');
grid on;
legend;

nexttile;
hold on;

for j = 1:3

    Q = exampleNoise{j};

    stairs(Q.t,Q.applied, ...
        'LineWidth',1, ...
        'DisplayName',C.names{j});

end

xlabel('Time (s)');
ylabel('Applied Counter');
grid on;
legend;

%% Figure 3: Plant-gain sensitivity

f3 = figure( ...
    'Color','w', ...
    'Name','2C Gain', ...
    'Visible','off');

hold on;

for j = 1:3

    ix = gainRows.Controller==string(C.names{j});

    plot( ...
        gainRows.PlantGain(ix), ...
        gainRows.TrueRMSE_mA(ix), ...
        '-o','LineWidth',1.3, ...
        'DisplayName',C.names{j});

end

xlabel('DAC-current gain (mA/count)');
ylabel('60 s true-current RMSE (mA)');

title('Gain-only sensitivity');
grid on;
legend;

%% Figure 4: Combined robustness summary

f4 = figure( ...
    'Color','w', ...
    'Name','2C Combined', ...
    'Visible','off');

tiledlayout(1,2,'TileSpacing','compact');

nexttile;
hold on;

for j = 1:3

    ix = combinedRows.Controller==string(C.names{j});

    boxchart( ...
        j*ones(nnz(ix),1), ...
        combinedRows.TrueRMSE_mA(ix));

end

xticks(1:3);
xticklabels(C.names);
xtickangle(20);

ylabel('True-current RMSE (mA)');
title('Combined: full-run error');
grid on;

nexttile;
hold on;

for j = 1:3

    ix = combinedRows.Controller==string(C.names{j});

    boxchart( ...
        j*ones(nnz(ix),1), ...
        combinedRows.TotalMovement(ix));

end

xticks(1:3);
xticklabels(C.names);
xtickangle(20);

ylabel('Total absolute DAC movement (counts)');
title('Combined: controller activity');
grid on;

%% Export CSV tables

writetable(timingRows, ...
    fullfile(C.outputDir,'2C_timing.csv'));

writetable(noiseRows, ...
    fullfile(C.outputDir,'2C_noise_trials.csv'));

writetable(gainRows, ...
    fullfile(C.outputDir,'2C_gain_only.csv'));

writetable(combinedRows, ...
    fullfile(C.outputDir,'2C_combined_trials.csv'));

%% Export exactly four figures

figs = {f1,f2,f3,f4};

figNames = { ...
    'Fig1_Timing', ...
    'Fig2_Noise', ...
    'Fig3_Gain', ...
    'Fig4_Combined'};

for k = 1:4

    exportgraphics( ...
        figs{k}, ...
        fullfile(C.outputDir,[figNames{k} '.png']), ...
        'Resolution',180);

end

for k = 1:4
    close(figs{k});
end

%% Save raw simulation results separately

save( ...
    fullfile(C.outputDir,'2C_raw_results.mat'), ...
    'C','res','X0','timeRuns', ...
    'exampleNoise','gainRuns', ...
    'timingRows','noiseRows', ...
    'gainRows','combinedRows','-v7.3');

%% Print combined results

fprintf('\nSTAGE 2C COMBINED ROBUSTNESS RESULTS\n');

for j = 1:3

    ix = combinedRows.Controller==string(C.names{j});

    vals = combinedRows.TrueRMSE_mA(ix);
    movement = combinedRows.TotalMovement(ix);

    fprintf('\n%s\n',C.names{j});

    fprintf('RMSE mean: %.6f mA\n',mean(vals));
    fprintf('RMSE median: %.6f mA\n',median(vals));
    fprintf('RMSE SD: %.6f mA\n',std(vals));
    fprintf('RMSE worst observed: %.6f mA\n',max(vals));

    fprintf('Median total DAC movement: %.2f counts\n', ...
        median(movement));

end

%% Save concise text report

fid = fopen( ...
    fullfile(C.outputDir,'Stage2C_summary.txt'),'w');

assert(fid>0,'Cannot create summary report.');

fprintf(fid,'Stage 2C robustness summary\n\n');

fprintf(fid, ...
    'Nominal plant gain: %.10f mA/count\n',C.K);

fprintf(fid, ...
    'Simulation duration: %.1f s\n',C.stopTime);

fprintf(fid, ...
    'Independent noise seeds: %d\n',numel(C.seeds));

fprintf(fid, ...
    'Timing alternation: 76 and 89 ms\n\n');

for j = 1:3

    ix = combinedRows.Controller==string(C.names{j});
    vals = combinedRows.TrueRMSE_mA(ix);

    fprintf(fid, ...
        '%s: mean RMSE %.6f mA, median %.6f mA, SD %.6f mA, worst %.6f mA\n', ...
        C.names{j},mean(vals),median(vals),std(vals),max(vals));

end

fprintf(fid, ...
    '\nThe plant-gain study is gain-only, not a fully identified load model.\n');

fprintf(fid, ...
    'B2 residual resampling assumes independent noise samples.\n');

fprintf(fid, ...
    'No physical compliance limit or human-use safety validation is included.\n');

fclose(fid);

fprintf('\nStage 2C results saved in:\n%s\n',C.outputDir);

%% Local metric functions

function M = reportMetrics(C,X)

    y = X.true(:);
    ym = X.measured(:);
    t = X.t(:);
    u = X.applied(:);

    err = C.r-y;
    em = C.r-ym;

    % Time-weight statistics by actual elapsed intervals.
    w = diff([t;C.stopTime]);

    assert(all(w>=0));

    w = w/sum(w);

    M.TrueRMSE_mA = sqrt(sum(w.*err.^2));

    M.MeasuredRMSE_mA = sqrt(sum(w.*em.^2));

    steady = t>=C.stopTime-C.finalWindow;

    ws = w(steady);
    ws = ws/sum(ws);

    M.SteadyRMSE_mA = ...
        sqrt(sum(ws.*err(steady).^2));

    M.Bias_mA = ...
        sum(ws.*(y(steady)-C.r));

    M.PeakOvershoot_mA = ...
        max(0,max(y)-C.r);

    du = diff(u);

    M.PositiveMovement = sum(du(du>0));
    M.NegativeMovement = -sum(du(du<0));

    M.TotalMovement = sum(abs(du));
    M.NetMovement = u(end)-u(1);

    M.DACChanges = nnz(du~=0);
    M.MaxStep = max(abs(du));

    M.SteadyDistinctCodes = ...
        numel(unique(u(steady)));

    M.SteadyChangeRate = ...
        nnz(diff(u(steady))~=0)/C.finalWindow;

    M.IntegralSD = std(X.integral(steady));

    M.InBandFraction = ...
        sum(w(abs(err)<=C.deadband));

    %% Entry-and-remain deadband settling

    outside = abs(err)>C.deadband;

    lastBad = find(outside,1,'last');

    M.DeadbandSettling_s = NaN;

    if isempty(lastBad)

        idx = 1;

    elseif lastBad<numel(t)

        idx = lastBad+1;

    else

        idx = [];

    end

    % Require at least 1 s of subsequent observation.
    if ~isempty(idx) && C.stopTime-t(idx)>=1.0

        M.DeadbandSettling_s = t(idx);

    end

    %% DAC movement consistency

    assert(abs( ...
        M.PositiveMovement-M.NegativeMovement- ...
        M.NetMovement)<1e-8);

    assert(abs( ...
        M.TotalMovement-M.PositiveMovement- ...
        M.NegativeMovement)<1e-8);

end

function row = metricsRow(C,M,j,condition,seed,K)

    row = table( ...
        string(C.names{j}), ...
        string(condition), ...
        seed,K, ...
        M.TrueRMSE_mA, ...
        M.MeasuredRMSE_mA, ...
        M.SteadyRMSE_mA, ...
        M.Bias_mA, ...
        M.PeakOvershoot_mA, ...
        M.DeadbandSettling_s, ...
        M.InBandFraction, ...
        M.PositiveMovement, ...
        M.NegativeMovement, ...
        M.TotalMovement, ...
        M.NetMovement, ...
        M.DACChanges, ...
        M.MaxStep, ...
        M.SteadyDistinctCodes, ...
        M.SteadyChangeRate, ...
        M.IntegralSD, ...
        'VariableNames',{ ...
            'Controller', ...
            'Condition', ...
            'Seed', ...
            'PlantGain', ...
            'TrueRMSE_mA', ...
            'MeasuredRMSE_mA', ...
            'SteadyRMSE_mA', ...
            'Bias_mA', ...
            'Overshoot_mA', ...
            'DeadbandSettling_s', ...
            'InBandFraction', ...
            'PositiveMovement', ...
            'NegativeMovement', ...
            'TotalMovement', ...
            'NetMovement', ...
            'DACChanges', ...
            'MaxStep', ...
            'SteadyDistinctCodes', ...
            'SteadyChangeRate', ...
            'IntegralSD'});
end
