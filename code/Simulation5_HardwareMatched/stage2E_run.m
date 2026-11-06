
function stage2E_run
% STAGE 2E: Timing-matched PI simulation validation
%
% MATLAB R2025a. No additional toolboxes required.
%
% Folder structure:
%
% HardwareValidation/
%   E01 Noise Analysis/
%   E02 DAC Current Relation/
%   E03 PI Gain Tests/
%   Stage2E_TimingMatched/
%       stage2E_run.m
%
% All inputs are the original E01, E02 and E03 CSVs.
%
% Compares:
%   1. Empirical PI and model-derived faster PI
%   2. Logger-clock and scope-proxy-clock timing
%   3. Simulated measured feedback and E03 hardware
%   4. Settling in seconds and burst counts
%   5. Simulated distributions and five hardware trials
%
% No changes to the frozen Stage 2A through 2D models.

%% 1. Paths

root = fileparts(mfilename('fullpath'));

assert(~isempty(root), ...
    'Save stage2E_run.m before executing it.');

parent = fileparts(root);

E01 = fullfile(parent,'E01 Noise Analysis ');
E02 = fullfile(parent,'E02 DAC Current Relation');
E03 = fullfile(parent,'E03 PI Gain Tests');

assert(isfolder(E01), ...
    'E01 Noise Analysis folder not found.');

assert(isfolder(E02), ...
    'E02 DAC Current Relation folder not found.');

assert(isfolder(E03), ...
    'E03 PI Gain Tests folder not found.');

%% 2. Frozen configuration

cfg = struct();

cfg.loads = [100 220 560 1000 2000 4000];

cfg.controllers = ["Empirical","Faster"];
cfg.codes = ["E","F"];

cfg.kp = [5.000000,4.867577];
cfg.ki = [3.000000,9.758558];

cfg.reference_mA = 10;
cfg.deadband_mA = 0.030;
cfg.band1pct_mA = 0.100;

cfg.sustain_s = 2.0;

cfg.initialCounter = 215;
cfg.feedforward = 215;

cfg.trim = 25;
cfg.globalMax = 322;

% Monte Carlo configuration
cfg.nSeeds = 40;
cfg.blockBursts = 12;
cfg.seedBase = 20261103;

% Two timing representations
cfg.scopeShort_s = 0.076;
cfg.scopeLong_s = 0.089;

% Classifies the two recorded logger intervals.
cfg.clockDivider_s = 0.0865;

% E02 plateau identification
cfg.minPlateau = 5;
cfg.localWindows = [
    8 12
    7 13
    6 14
];

%% 3. Create a new results directory

timestamp = string(datetime( ...
    'now','Format','yyyyMMdd_HHmmss'));

runDir = fullfile( ...
    root,'Stage2E_Results',char(timestamp));

assert(~isfolder(runDir), ...
    'Results directory already exists.');

mkdir(runDir);

figDir = fullfile(runDir,'Figures');
mkdir(figDir);

%% 4. Reconstruct E01 and E02 plant calibration

nR = numel(cfg.loads);

noiseLib = cell(nR,2);

calibration = table();
plateauAudit = table();

for ir = 1:nR

    R = cfg.loads(ir);

    trialMeans = nan(1,2);

    % Two independent E01 open-loop recordings.
    for tr = 1:2

        filename = sprintf( ...
            'E01_R%04d_OL_T%02d.csv',R,tr);

        file = fullfile(E01,filename);

        assert(isfile(file), ...
            'Missing E01 file: %s',file);

        Z = readtable(file, ...
            'TextType','string', ...
            'VariableNamingRule','preserve');

        t = double(Z.time_ms)/1000;
        b = double(Z.burst);
        y = double(Z.measured_mA);

        good = ...
            upper(string(Z.mode))=="OPEN_LOOP" & ...
            upper(string(Z.stim_state))=="RUNNING" & ...
            upper(string(Z.fault_code))=="NONE" & ...
            double(Z.command_limited)==0 & ...
            double(Z.reference_limited)==0 & ...
            double(Z.counter_applied)== ...
                cfg.initialCounter & ...
            double(Z.counter_next)== ...
                cfg.initialCounter & ...
            abs(double(Z.effective_target_mA)-10)<0.001 & ...
            isfinite(y) & isfinite(t) & y>0;

        groups = continuousGroups( ...
            good,t,b,double(Z.counter_applied),0.5);

        pieces = {};
        acceptedY = [];

        for j = 1:numel(groups)

            ids = groups{j};

            if numel(ids)<24
                continue;
            end

            yy = y(ids);

            % Centre each contiguous fixed-command segment.
            pieces{end+1} = yy-mean(yy); %#ok<AGROW>

            acceptedY = [acceptedY;yy]; %#ok<AGROW>

        end

        assert( ...
            ~isempty(pieces) && numel(acceptedY)>100, ...
            'Insufficient E01 data at R=%d, T%02d.',R,tr);

        trialMeans(tr) = mean(acceptedY);

        noiseLib{ir,tr} = pieces;

    end

    % Equal weight for the two E01 trial means.
    anchor = mean(trialMeans);

    % Independently identify the local E02 slope.
    [slope,lo,hi,nPlateaus,nCodes,P] = ...
        localE02(E02,R,cfg);

    plateauAudit = [plateauAudit;P]; %#ok<AGROW>

    assert( ...
        isfinite(slope) && slope>0 && nCodes>=3, ...
        'E02 slope not identifiable at %d ohm.',R);

    calibration = [calibration;table( ...
        R,trialMeans(1),trialMeans(2),anchor, ...
        slope,lo,hi,nPlateaus,nCodes, ...
        'VariableNames',{ ...
        'Load_Ohm', ...
        'E01Mean_T01_mA', ...
        'E01Mean_T02_mA', ...
        'Iat215_mA', ...
        'LocalSlope_mA_per_Count', ...
        'WindowLow_mA', ...
        'WindowHigh_mA', ...
        'Plateaus', ...
        'Counters'})]; %#ok<AGROW>

end

writetable(calibration, ...
    fullfile(runDir,'Stage2E_PlantCalibration.csv'));

writetable(plateauAudit, ...
    fullfile(runDir,'Stage2E_E02PlateauAudit.csv'));

%% 5. Verify the original deterministic Stage 2B model

% This must pass before evaluating the new simulation.
% It uses the frozen nominal 4 kOhm model.

fixedTime = (0:0.0825:60)';

expected = [10.3125 3.2175];

for c = 1:2

    [yy,uu] = simulatePI( ...
        fixedTime, ...
        zeros(size(fixedTime)), ...
        9.593752, ...
        0.0458338958, ...
        cfg.kp(c), ...
        cfg.ki(c), ...
        cfg);

    M = performance(fixedTime,yy,uu,cfg);

    assert( ...
        abs(M.Permanent_s-expected(c))<1e-7, ...
        'Frozen Stage 2B regression failed for %s.', ...
        cfg.codes(c));

end

fprintf('Frozen Stage 2B regression: PASS\n');

%% 6. Read actual E03 hardware trials

hardware = table();

schedules = struct( ...
    'File',{}, ...
    'Load_Ohm',{}, ...
    'SourceController',{}, ...
    'Trial',{}, ...
    'LoggerTime_s',{}, ...
    'ScopeTime_s',{});

for ir = 1:nR

    R = cfg.loads(ir);

    for c = 1:2

        for tr = 1:5

            filename = string(sprintf( ...
                'E03_R%04d_PI_%s_T%02d.csv', ...
                R,char(cfg.codes(c)),tr));

            sourceDir = fullfile( ...
                E03,char(cfg.controllers(c)));

            file = fullfile(sourceDir,char(filename));

            assert(isfile(file), ...
                'Missing E03 file: %s',file);

            Z = readtable(file, ...
                'TextType','string', ...
                'VariableNamingRule','preserve');

            valid = ...
                upper(string(Z.mode))=="PI_CONTROL" & ...
                upper(string(Z.stim_state))=="RUNNING" & ...
                upper(string(Z.fault_code))=="NONE" & ...
                double(Z.command_limited)==0 & ...
                double(Z.reference_limited)==0 & ...
                isfinite(double(Z.time_ms)) & ...
                isfinite(double(Z.measured_mA)) & ...
                isfinite(double(Z.counter_applied)) & ...
                abs(double(Z.effective_target_mA)-10)<0.001;

            idx = find(valid);

            assert(numel(idx)>=300, ...
                'Short or invalid E03 trial: %s',filename);

            assert(all(diff(idx)==1), ...
                'Split E03 RUNNING region: %s',filename);

            t = ( ...
                double(Z.time_ms(idx))- ...
                double(Z.time_ms(idx(1))))/1000;

            b = double(Z.burst(idx));
            y = double(Z.measured_mA(idx));
            u = double(Z.counter_applied(idx));

            nextCounter = double(Z.counter_next(idx));

            assert( ...
                all(diff(b)==1) && ...
                all(nextCounter(1:end-1)==u(2:end)), ...
                'Invalid E03 command indexing: %s',filename);

            dt = diff(t);

            assert(all(dt>0.065 & dt<0.11), ...
                'Unexpected logger interval in %s.',filename);

            % Reconstruct a 76/89 ms schedule preserving
            % the measured short/long interval sequence.
            dtScope = cfg.scopeShort_s*ones(size(dt));

            dtScope(dt>cfg.clockDivider_s) = ...
                cfg.scopeLong_s;

            tScope = [0;cumsum(dtScope)];

            assert(numel(tScope)==numel(t));

            M = performance(t,y,u,cfg);

            hardware = [hardware;table( ...
                R,cfg.controllers(c),tr,filename, ...
                M.First10RMSE_mA, ...
                M.Final20RMSE_mA, ...
                M.SteadySwitchesPer_s, ...
                M.FirstEntry_s, ...
                M.Sustained2s_s, ...
                M.Permanent_s, ...
                M.FirstEntry_Bursts, ...
                M.Sustained2s_Bursts, ...
                M.Permanent_Bursts, ...
                M.SustainedAchieved, ...
                M.PermanentAchieved, ...
                M.InitiallyWithin, ...
                'VariableNames',{ ...
                'Load_Ohm', ...
                'Controller', ...
                'Trial', ...
                'File', ...
                'First10RMSE_mA', ...
                'Final20RMSE_mA', ...
                'SteadySwitchesPer_s', ...
                'FirstEntry_s', ...
                'Sustained2s_s', ...
                'Permanent_s', ...
                'FirstEntry_Bursts', ...
                'Sustained2s_Bursts', ...
                'Permanent_Bursts', ...
                'SustainedAchieved', ...
                'PermanentAchieved', ...
                'InitiallyWithin'})]; %#ok<AGROW>

            schedules(end+1) = struct( ...
                'File',filename, ...
                'Load_Ohm',R, ...
                'SourceController',cfg.controllers(c), ...
                'Trial',tr, ...
                'LoggerTime_s',t, ...
                'ScopeTime_s',tScope); %#ok<AGROW>

        end

    end

end

assert(height(hardware)==60);
assert(numel(schedules)==60);

%% 7. Verify hardware 4 kOhm timing regression

expectedHardware = [25.0344 12.3688];

for c = 1:2

    x = hardware.Sustained2s_s( ...
        hardware.Load_Ohm==4000 & ...
        hardware.Controller==cfg.controllers(c));

    assert( ...
        numel(x)==5 && all(isfinite(x)) && ...
        abs(mean(x)-expectedHardware(c))<0.002, ...
        'E03 4 kOhm timing regression failed.');

end

fprintf('E03 hardware timing regression: PASS\n');

writetable(hardware, ...
    fullfile(runDir,'Stage2E_HardwareTrialMetrics.csv'));

%% 8. Monte Carlo simulation

% There are 10 timing schedules per load:
% five empirical E03 recordings and five faster E03 recordings.
%
% For every schedule and random seed, the identical noise
% sequence is used for:
%   Empirical, logger clock
%   Faster, logger clock
%   Empirical, scope-proxy clock
%   Faster, scope-proxy clock
%
% This provides paired simulation conditions.
% It does NOT imply that the hardware trials are paired.

cols = { ...
    'Load_Ohm', ...
    'Controller', ...
    'Clock', ...
    'ScheduleFile', ...
    'ScheduleSourceController', ...
    'ScheduleTrial', ...
    'Seed', ...
    'First10RMSE_mA', ...
    'Final20RMSE_mA', ...
    'SteadySwitchesPer_s', ...
    'FirstEntry_s', ...
    'Sustained2s_s', ...
    'Permanent_s', ...
    'FirstEntry_Bursts', ...
    'Sustained2s_Bursts', ...
    'Permanent_Bursts', ...
    'SustainedAchieved', ...
    'PermanentAchieved', ...
    'InitiallyWithin', ...
    'Duration_s', ...
    'FractionWithin1pct', ...
    'InitialMeasuredError_mA'};

N = numel(schedules)*cfg.nSeeds*4;

allRows = cell(N,numel(cols));

row = 0;

sample = struct( ...
    'Controller',{}, ...
    'Clock',{}, ...
    'Time_s',{}, ...
    'Measured_mA',{}, ...
    'True_mA',{}, ...
    'AppliedCounter',{});

for ss = 1:numel(schedules)

    S = schedules(ss);

    ir = find(cfg.loads==S.Load_Ohm,1);

    plant = calibration( ...
        calibration.Load_Ohm==S.Load_Ohm,:);

    for seed = 1:cfg.nSeeds

        rng( ...
            cfg.seedBase+S.Load_Ohm*10000+ss*100+seed, ...
            'twister');

        epsNoise = resampleBlocks( ...
            noiseLib(ir,:), ...
            numel(S.LoggerTime_s), ...
            cfg.blockBursts);

        for clk = 1:2

            if clk==1

                clock = "Logger";
                t = S.LoggerTime_s;

            else

                clock = "ScopeProxy";
                t = S.ScopeTime_s;

            end

            for c = 1:2

                [y,u,trueI] = simulatePI( ...
                    t,epsNoise, ...
                    plant.Iat215_mA, ...
                    plant.LocalSlope_mA_per_Count, ...
                    cfg.kp(c),cfg.ki(c),cfg);

                M = performance(t,y,u,cfg);

                row = row+1;

                allRows(row,:) = { ...
                    S.Load_Ohm, ...
                    cfg.controllers(c), ...
                    clock, ...
                    S.File, ...
                    S.SourceController, ...
                    S.Trial, ...
                    seed, ...
                    M.First10RMSE_mA, ...
                    M.Final20RMSE_mA, ...
                    M.SteadySwitchesPer_s, ...
                    M.FirstEntry_s, ...
                    M.Sustained2s_s, ...
                    M.Permanent_s, ...
                    M.FirstEntry_Bursts, ...
                    M.Sustained2s_Bursts, ...
                    M.Permanent_Bursts, ...
                    M.SustainedAchieved, ...
                    M.PermanentAchieved, ...
                    M.InitiallyWithin, ...
                    t(end), ...
                    M.FractionWithin1pct, ...
                    10-y(1)};

                % Retain four illustrative 4 kOhm traces.
                if S.Load_Ohm==4000 && ...
                        S.SourceController=="Empirical" && ...
                        S.Trial==3 && seed==1

                    sample(end+1) = struct( ...
                        'Controller',cfg.controllers(c), ...
                        'Clock',clock, ...
                        'Time_s',t, ...
                        'Measured_mA',y, ...
                        'True_mA',trueI, ...
                        'AppliedCounter',u); %#ok<AGROW>

                end

            end

        end

    end

end

assert(row==N,'Simulation output count mismatch.');

%% 9. Build typed simulation results

simulated = table();

for jj = 1:numel(cols)

    if ismember(jj,[2 3 4 5])

        simulated.(cols{jj}) = ...
            string(allRows(:,jj));

    else

        simulated.(cols{jj}) = ...
            cell2mat(allRows(:,jj));

    end

end

assert(height(simulated)==N);

writetable(simulated, ...
    fullfile(runDir,'Stage2E_SimulatedTrialMetrics.csv'));

fprintf('Simulation trajectories completed: %d\n', ...
    height(simulated));

%% 10. Distribution-level comparisons

summary = table();

for R = cfg.loads

    for c = 1:2

        hw = hardware( ...
            hardware.Load_Ohm==R & ...
            hardware.Controller==cfg.controllers(c),:);

        assert(height(hw)==5);

        for clock = ["Logger","ScopeProxy"]

            sim = simulated( ...
                simulated.Load_Ohm==R & ...
                simulated.Controller==cfg.controllers(c) & ...
                simulated.Clock==clock,:);

            assert(height(sim)==10*cfg.nSeeds);

            [sLo,sMed,sHi,sCovered] = compareMetric( ...
                sim.Sustained2s_s, ...
                hw.Sustained2s_s);

            [bLo,bMed,bHi,bCovered] = compareMetric( ...
                sim.Sustained2s_Bursts, ...
                hw.Sustained2s_Bursts);

            [rLo,rMed,rHi,rCovered] = compareMetric( ...
                sim.First10RMSE_mA, ...
                hw.First10RMSE_mA);

            [~,~,~,steadyCovered] = compareMetric( ...
                sim.Final20RMSE_mA, ...
                hw.Final20RMSE_mA);

            [~,~,~,switchCovered] = compareMetric( ...
                sim.SteadySwitchesPer_s, ...
                hw.SteadySwitchesPer_s);

            summary = [summary;table( ...
                R,cfg.controllers(c),clock, ...
                height(sim), ...
                mean(hw.SustainedAchieved), ...
                mean(sim.SustainedAchieved), ...
                mean(hw.PermanentAchieved), ...
                mean(sim.PermanentAchieved), ...
                mean(hw.Sustained2s_s,'omitnan'), ...
                sLo,sMed,sHi,sCovered, ...
                bLo,bMed,bHi,bCovered, ...
                mean(hw.First10RMSE_mA), ...
                rLo,rMed,rHi, ...
                rCovered,steadyCovered,switchCovered, ...
                'VariableNames',{ ...
                'Load_Ohm', ...
                'Controller', ...
                'Clock', ...
                'Simulations', ...
                'HardwareSustainedSuccess', ...
                'SimulationSustainedSuccess', ...
                'HardwarePermanentSuccess', ...
                'SimulationPermanentSuccess', ...
                'HardwareMeanSustained_s', ...
                'SimSustainedP05_s', ...
                'SimSustainedMedian_s', ...
                'SimSustainedP95_s', ...
                'HardwareTrialsInsideSim90_Sustained', ...
                'SimSustainedP05_Bursts', ...
                'SimSustainedMedian_Bursts', ...
                'SimSustainedP95_Bursts', ...
                'HardwareTrialsInsideSim90_Bursts', ...
                'HardwareMeanRMSE10_mA', ...
                'SimRMSE10P05_mA', ...
                'SimRMSE10Median_mA', ...
                'SimRMSE10P95_mA', ...
                'HardwareTrialsInsideSim90_RMSE10', ...
                'HardwareTrialsInsideSim90_FinalRMSE', ...
                'HardwareTrialsInsideSim90_Switching'})]; %#ok<AGROW>

        end

    end

end

writetable(summary, ...
    fullfile(runDir,'Stage2E_ConditionComparison.csv'));

%% 11. Figures

C = lines(2);

figureNames = { ...
    'Stage2E_Fig01_4k_RepresentativeFeedback', ...
    'Stage2E_Fig02_SustainedSeconds', ...
    'Stage2E_Fig03_SustainedBursts', ...
    'Stage2E_Fig04_TransientRMSE', ...
    'Stage2E_Fig05_HardwareCoverage'};

%% Figure 1: Measured and true simulated current

fig = figure( ...
    'Visible','off','Color','w', ...
    'Position',[100 100 1080 750]);

tiledlayout(2,2,'TileSpacing','compact');

clockList = ["Logger","ScopeProxy"];

for clk = 1:2

    for c = 1:2

        nexttile;

        ix = ...
            [sample.Controller]==cfg.controllers(c) & ...
            [sample.Clock]==clockList(clk);

        q = sample(ix);

        assert(numel(q)==1, ...
            'Representative simulation trace missing.');

        plot(q.Time_s,q.Measured_mA, ...
            'Color',C(c,:));

        hold on;

        plot(q.Time_s,q.True_mA, ...
            'k-','LineWidth',1.2);

        yline(10.1,'k:');
        yline(9.9,'k:');

        title(sprintf( ...
            '4 kOhm, %s, %s', ...
            char(cfg.controllers(c)),char(q.Clock)));

        xlabel('Time (s)');
        ylabel('Current (mA)');

        xlim([0 35]);

        grid on;

    end

end

sgtitle( ...
    'Stage 2E: Simulated feedback and modelled true current');

exportBoth(fig,figDir,figureNames{1});

%% Figures 2 and 3: Sustained time in seconds and bursts

for choice = 1:2

    fig = figure( ...
        'Visible','off','Color','w', ...
        'Position',[100 100 1100 740]);

    tiledlayout(2,1,'TileSpacing','compact');

    for c = 1:2

        nexttile;
        hold on;

        for ir = 1:nR

            R = cfg.loads(ir);

            H = hardware( ...
                hardware.Load_Ohm==R & ...
                hardware.Controller==cfg.controllers(c),:);

            for clk = 1:2

                clock = clockList(clk);

                V = summary( ...
                    summary.Load_Ohm==R & ...
                    summary.Controller==cfg.controllers(c) & ...
                    summary.Clock==clock,:);

                if choice==1

                    lo = V.SimSustainedP05_s;
                    hi = V.SimSustainedP95_s;
                    med = V.SimSustainedMedian_s;

                    points = H.Sustained2s_s;

                else

                    lo = V.SimSustainedP05_Bursts;
                    hi = V.SimSustainedP95_Bursts;
                    med = V.SimSustainedMedian_Bursts;

                    points = H.Sustained2s_Bursts;

                end

                xx = ir+(clk-1.5)*0.19;

                plot([xx xx],[lo hi],'-', ...
                    'Color',C(clk,:), ...
                    'LineWidth',3);

                scatter(xx,med,42,C(clk,:),'filled');

            end

            scatter( ...
                ir+linspace(-0.07,0.07,5)', ...
                points,18,'k','filled', ...
                'MarkerFaceAlpha',0.65);

        end

        xticks(1:nR);
        xticklabels(string(cfg.loads));

        xlabel('Resistance (ohm)');

        if choice==1

            ylabel('Sustained 1% entry time (s)');

        else

            ylabel('Sustained 1% entry (bursts)');

        end

        title(char(cfg.controllers(c)));
        grid on;

    end

    if choice==1

        sgtitle( ...
            'Simulation P05 to P95 and five hardware trials');

        exportBoth(fig,figDir,figureNames{2});

    else

        sgtitle( ...
            'Sustained 1% regulation in burst counts');

        exportBoth(fig,figDir,figureNames{3});

    end

end

%% Figure 4: First 10-second RMSE

fig = figure( ...
    'Visible','off','Color','w', ...
    'Position',[100 100 1000 600]);

hold on;

for c = 1:2

    H = hardware( ...
        hardware.Controller==cfg.controllers(c),:);

    means = zeros(nR,1);

    for ir = 1:nR

        means(ir) = mean( ...
            H.First10RMSE_mA( ...
            H.Load_Ohm==cfg.loads(ir)));

    end

    plot(1:nR,means,'-o', ...
        'Color',C(c,:), ...
        'DisplayName',char( ...
        cfg.controllers(c)+" hardware"));

    S = summary( ...
        summary.Controller==cfg.controllers(c) & ...
        summary.Clock=="Logger",:);

    scatter( ...
        1:nR,S.SimRMSE10Median_mA, ...
        65,C(c,:),'s', ...
        'DisplayName',char( ...
        cfg.controllers(c)+" simulation"));

end

xticks(1:nR);
xticklabels(string(cfg.loads));

xlabel('Resistance (ohm)');
ylabel('First 10 s feedback RMSE (mA)');

title('Stage 2E: Hardware versus simulated feedback RMSE');

legend('Location','best');
grid on;

exportBoth(fig,figDir,figureNames{4});

%% Figure 5: Hardware coverage by load

fig = figure( ...
    'Visible','off','Color','w', ...
    'Position',[100 100 1100 570]);

tiledlayout(1,2,'TileSpacing','compact');

for c = 1:2

    nexttile;

    Q = summary( ...
        summary.Controller==cfg.controllers(c),:);

    mat = zeros(nR,2);

    for ir = 1:nR

        for clk = 1:2

            V = Q( ...
                Q.Load_Ohm==cfg.loads(ir) & ...
                Q.Clock==clockList(clk),:);

            mat(ir,clk) = ...
                V.HardwareTrialsInsideSim90_Sustained;

        end

    end

    bar(1:nR,mat);

    xticks(1:nR);
    xticklabels(string(cfg.loads));

    ylim([0 5]);

    xlabel('Resistance (ohm)');

    ylabel( ...
        'Hardware trials within simulated central 90%');

    title(char(cfg.controllers(c)));

    legend({'Logger','Scope proxy'}, ...
        'Location','best');

    grid on;

end

sgtitle( ...
    'Stage 2E: Descriptive hardware timing coverage');

exportBoth(fig,figDir,figureNames{5});

%% 12. Save archive

save(fullfile(runDir,'Stage2E_Results.mat'), ...
    'cfg','calibration','hardware','simulated', ...
    'summary','plateauAudit','sample','-v7.3');

%% 13. Generate Markdown checkpoint

fid = fopen(fullfile( ...
    runDir,'Stage2E_Checkpoint.md'),'w');

assert(fid>0, ...
    'Unable to create Stage 2E checkpoint.');

fprintf(fid, ...
    '# Stage 2E: Timing-Matched Simulation Validation\n\n');

fprintf(fid,'Generated: %s\n\n', ...
    char(string(datetime('now'))));

fprintf(fid,'## Method\n\n');

fprintf(fid, ...
    ['Six E01-anchored affine plants with independently ' ...
     'qualified E02 local slopes. E01 residuals were ' ...
     'resampled in contiguous 12-burst blocks, with ' ...
     'an E01 trial selected per simulation realisation. ' ...
     'One applied Counter update follows each burst. ' ...
     'Integer rounding, a 0.030 mA controller deadband, ' ...
     'conditional anti-windup and Counter trim 190 to ' ...
     '240 were retained.\n\n']);

fprintf(fid, ...
    ['The controller uses unrounded simulated feedback. ' ...
     'The performance analysis uses feedback rounded ' ...
     'to 0.001 mA to emulate CSV reporting precision.\n\n']);

fprintf(fid, ...
    ['Each of the 60 E03 schedules was simulated using ' ...
     '%d noise seeds, both PI gain sets and two clocks. ' ...
     'Logger time was reconstructed from E03 time_ms. ' ...
     'The scope-proxy clock maps the short and long ' ...
     'logged intervals to 76 and 89 ms. The same ' ...
     'noise realisation was reused across both ' ...
     'controllers and clocks.\n\n'], ...
    cfg.nSeeds);

fprintf(fid,'## Model calibration\n\n');

fprintf(fid, ...
    ['| R (ohm) | I at Counter 215 (mA) ' ...
     '| K (mA/Counter) | E02 window |\n']);

fprintf(fid,'|---:|---:|---:|---|\n');

for ir = 1:nR

    Q = calibration(ir,:);

    fprintf(fid, ...
        '| %d | %.6f | %.8f | %.0f to %.0f mA |\n', ...
        Q.Load_Ohm, ...
        Q.Iat215_mA, ...
        Q.LocalSlope_mA_per_Count, ...
        Q.WindowLow_mA, ...
        Q.WindowHigh_mA);

end

fprintf(fid, ...
    '\n## Observed versus simulated sustained 1%% times\n\n');

fprintf(fid, ...
    ['| R (ohm) | Controller | Clock ' ...
     '| Hardware mean (s) | Simulation median (s) ' ...
     '| Simulation P05 to P95 (s) ' ...
     '| Hardware inside interval (of 5) |\n']);

fprintf(fid,'|---:|---|---|---:|---:|---|---:|\n');

for k = 1:height(summary)

    Q = summary(k,:);

    fprintf(fid, ...
        '| %d | %s | %s | %.3f | %.3f | %.3f to %.3f | %d |\n', ...
        Q.Load_Ohm, ...
        char(Q.Controller), ...
        char(Q.Clock), ...
        Q.HardwareMeanSustained_s, ...
        Q.SimSustainedMedian_s, ...
        Q.SimSustainedP05_s, ...
        Q.SimSustainedP95_s, ...
        Q.HardwareTrialsInsideSim90_Sustained);

end

fprintf(fid,'\n## Verification\n\n');

fprintf(fid, ...
    ['The frozen 4 kOhm deterministic Stage 2B 1%% ' ...
     'settling regression (10.3125 s empirical, ' ...
     '3.2175 s faster) passed.\n\n']);

fprintf(fid, ...
    ['The raw E03 4 kOhm 2-second sustained timing ' ...
     'regression (25.0344 s empirical, 12.3688 s ' ...
     'faster across five hardware trials) passed.\n\n']);

fprintf(fid, ...
    'Original source CSV files were not modified.\n\n');

fprintf(fid,'## Limitations\n\n');

fprintf(fid, ...
    ['E01 open-loop residuals include combined ' ...
     'burst-level measurement and plant variability, ' ...
     'not pure sensor noise. The model is static and ' ...
     'locally affine, and cannot reproduce output ' ...
     'compliance or unmodelled load-history effects. ' ...
     'ScopeProxy is a reconstructed 76/89 ms sequence, ' ...
     'not an oscilloscope-synchronised recording.\n\n']);

fprintf(fid, ...
    ['Five E03 hardware recordings per controller ' ...
     'and load are unpaired. Only simulated controller ' ...
     'comparisons share noise and timing schedules. ' ...
     'Central-percentile coverage of five hardware ' ...
     'trials is descriptive, not a formal model ' ...
     'validation test.\n']);

fclose(fid);

%% 14. Completion

fprintf('\nStage 2E completed.\n');

fprintf('Simulated trajectories: %d\n', ...
    height(simulated));

fprintf('Hardware recordings: %d\n', ...
    height(hardware));

fprintf('Output: %s\n',runDir);

disp(summary( ...
    summary.Load_Ohm==4000, ...
    {'Controller','Clock', ...
     'HardwareMeanSustained_s', ...
     'SimSustainedMedian_s', ...
     'HardwareTrialsInsideSim90_Sustained'}));

end

%% ============================================================
% Local helper functions
% ============================================================

function groups = continuousGroups(good,t,b,u,maxGap)

    groups = {};
    current = [];

    for k = 1:numel(good)

        if ~good(k)

            if ~isempty(current)

                groups{end+1} = current; %#ok<AGROW>
                current = [];

            end

            continue;

        end

        if isempty(current)

            current = k;

        elseif k==current(end)+1 && ...
                b(k)==b(k-1)+1 && ...
                t(k)>t(k-1) && ...
                t(k)-t(k-1)<=maxGap && ...
                u(k)==u(k-1)

            current(end+1,1) = k; %#ok<AGROW>

        else

            groups{end+1} = current; %#ok<AGROW>
            current = k;

        end

    end

    if ~isempty(current)
        groups{end+1} = current;
    end

end

function [K,lo,hi,nP,nC,A] = localE02(folder,R,cfg)

    filename = fullfile( ...
        folder,sprintf('E02_R%04d_OL_T01.csv',R));

    assert(isfile(filename), ...
        'Missing E02 CSV: %s',filename);

    Z = readtable(filename, ...
        'TextType','string', ...
        'VariableNamingRule','preserve');

    n = height(Z);

    t = double(Z.time_ms)/1000;
    b = double(Z.burst);

    u = double(Z.counter_applied);
    y = double(Z.measured_mA);

    isFault = ...
        upper(string(Z.fault_code))~="NONE" | ...
        upper(string(Z.stim_state))=="FAULT_LATCHED";

    pre = false(n,1);

    for k = find(isFault & ...
            ~[false;isFault(1:end-1)])'

        for j = max(1,k-5):k-1

            if isfinite(t(k)) && isfinite(t(j)) && ...
                    t(k)>=t(j) && ...
                    t(k)-t(j)<=0.5

                pre(j) = true;

            end

        end

    end

    good = ...
        upper(string(Z.mode))=="OPEN_LOOP" & ...
        upper(string(Z.stim_state))=="RUNNING" & ...
        ~isFault & ~pre & ...
        double(Z.command_limited)==0 & ...
        double(Z.reference_limited)==0 & ...
        double(Z.requested_mA)<=15 & ...
        double(Z.effective_target_mA)<=15 & ...
        isfinite(u) & isfinite(y) & ...
        y>0 & u>=0 & u<=322;

    groups = continuousGroups(good,t,b,u,0.5);

    A = table();

    for s = 1:numel(groups)

        ids = groups{s};

        yy = y(ids);

        N = numel(ids);
        mu = mean(yy);

        accepted = false;
        reason = "SHORT";

        if N>=cfg.minPlateau

            m = median(yy(2:end));

            madValue = median(abs(yy(2:end)-m));

            stepBad = ...
                abs(yy(1)-m)> ...
                max(0.25,6*1.4826*madValue);

            slope = polyfit( ...
                t(ids)-t(ids(1)),yy,1);

            drift = abs( ...
                slope(1)*(t(ids(end))-t(ids(1))));

            collapse = any( ...
                (yy(1:end-1)<0.55*median(yy)) & ...
                (yy(2:end)<0.55*median(yy)));

            if stepBad

                reason = "POST_STEP";

            elseif drift>max(0.30,0.04*median(yy))

                reason = "DRIFT";

            elseif collapse

                reason = "COLLAPSE";

            else

                accepted = true;
                reason = "ACCEPTED";

            end

        end

        A = [A;table( ...
            R,s,u(ids(1)),N,mu,accepted,reason, ...
            'VariableNames',{ ...
            'Load_Ohm', ...
            'Segment', ...
            'Counter', ...
            'Bursts', ...
            'Mean_mA', ...
            'Accepted', ...
            'Reason'})]; %#ok<AGROW>

    end

    Q = A(A.Accepted,:);

    K = NaN;
    lo = NaN;
    hi = NaN;
    nP = 0;
    nC = 0;

    for w = 1:size(cfg.localWindows,1)

        low = cfg.localWindows(w,1);
        high = cfg.localWindows(w,2);

        W = Q( ...
            Q.Mean_mA>=low & ...
            Q.Mean_mA<=high,:);

        x = unique(W.Counter);

        if numel(x)<3 || max(x)-min(x)<10
            continue;
        end

        meanY = zeros(numel(x),1);

        for k = 1:numel(x)

            meanY(k) = mean( ...
                W.Mean_mA(W.Counter==x(k)));

        end

        p = polyfit(x,meanY,1);

        K = p(1);

        lo = low;
        hi = high;

        nP = height(W);
        nC = numel(x);

        break;

    end

end

function epsNoise = resampleBlocks(twoTrials,N,block)

    % Select one of the two E01 trials.
    tr = randi(2);

    pieces = twoTrials{tr};

    lengths = cellfun(@numel,pieces);

    ok = find(lengths>=block);

    assert(~isempty(ok), ...
        'No E01 residual segment is sufficiently long.');

    pieces = pieces(ok);
    lengths = lengths(ok);

    epsNoise = zeros(N,1);

    pos = 1;

    while pos<=N

        % Select a contiguous segment proportionally
        % to its available sample count.
        pick = find( ...
            cumsum(lengths)>=rand*sum(lengths), ...
            1,'first');

        source = pieces{pick};

        start = randi(numel(source)-block+1);

        take = min(block,N-pos+1);

        epsNoise(pos:pos+take-1) = ...
            source(start:start+take-1);

        pos = pos+take;

    end

end

function [measured,applied,trueI] = ...
        simulatePI(t,noise,I0,K,kp,ki,cfg)

    N = numel(t);

    measured = zeros(N,1);
    applied = zeros(N,1);
    trueI = zeros(N,1);

    u = cfg.initialCounter;
    x = 0;

    lo = max(0,cfg.feedforward-cfg.trim);
    hi = min(cfg.globalMax,cfg.feedforward+cfg.trim);

    for k = 1:N

        % Physical plant approximation.
        current = I0+K*(u-cfg.initialCounter);

        % Feedback measurement, including sampled E01 noise.
        feedback = current+noise(k);

        % MATLAB model of 0.001 mA CSV reporting precision.
        measured(k) = round(feedback,3);

        trueI(k) = current;
        applied(k) = u;

        % PI acts on the unrounded feedback measurement.
        e = cfg.reference_mA-feedback;

        if abs(e)<=cfg.deadband_mA
            ed = 0;
        else
            ed = e;
        end

        p = kp*ed;

        % First integral-update hold.
        delta = 0;

        if k>1
            delta = ki*min(t(k)-t(k-1),0.5)*ed;
        end

        trial = x+delta;

        raw = cfg.feedforward+p+trial;

        % Conditional anti-windup.
        if (raw>hi && delta>0) || ...
                (raw<lo && delta<0)

            trial = x;

        end

        x = trial;

        % Integer command applies to the next burst.
        u = round(min(max( ...
            cfg.feedforward+p+x,lo),hi));

    end

end

function M = performance(t,y,u,cfg)

    assert(numel(t)==numel(y));
    assert(numel(y)==numel(u));

    t = t(:);
    y = y(:);
    u = u(:);

    % Same time-weighting convention as E03 Python audit.
    w = [diff(t);median(diff(t))];

    assert(all(w>0));

    e = cfg.reference_mA-y;

    early = t<10;
    last = t>=t(end)-20;

    M.First10RMSE_mA = sqrt( ...
        sum(w(early).*e(early).^2)/sum(w(early)));

    M.Final20RMSE_mA = sqrt( ...
        sum(w(last).*e(last).^2)/sum(w(last)));

    M.SteadySwitchesPer_s = ...
        nnz(diff(u(last))~=0)/sum(w(last));

    in = abs(e)<=cfg.band1pct_mA;

    M.FractionWithin1pct = sum(w(in))/sum(w);

    M.InitiallyWithin = in(1);

    M.FirstEntry_s = NaN;
    M.Sustained2s_s = NaN;
    M.Permanent_s = NaN;

    M.FirstEntry_Bursts = NaN;
    M.Sustained2s_Bursts = NaN;
    M.Permanent_Bursts = NaN;

    first = find(in,1,'first');

    if ~isempty(first)

        M.FirstEntry_s = t(first);
        M.FirstEntry_Bursts = first-1;

    end

    % Identify contiguous sequences entirely inside 1%.
    edges = diff([false;in;false]);

    starts = find(edges==1);
    ends = find(edges==-1)-1;

    % First uninterrupted 2-second interval.
    for j = 1:numel(starts)

        if t(ends(j))-t(starts(j))>= ...
                cfg.sustain_s-1e-9

            M.Sustained2s_s = t(starts(j));

            M.Sustained2s_Bursts = starts(j)-1;

            break;

        end

    end

    % Permanent settling through the recording end.
    if ~isempty(starts) && ...
            ends(end)==numel(t) && ...
            t(end)-t(starts(end))>=cfg.sustain_s-1e-9

        M.Permanent_s = t(starts(end));

        M.Permanent_Bursts = starts(end)-1;

    end

    M.SustainedAchieved = ...
        isfinite(M.Sustained2s_s);

    M.PermanentAchieved = ...
        isfinite(M.Permanent_s);

end

function [lo,med,hi,inside] = ...
        compareMetric(simulated,hardware)

    v = simulated(isfinite(simulated));
    h = hardware(isfinite(hardware));

    lo = quantileBasic(v,5);
    med = quantileBasic(v,50);
    hi = quantileBasic(v,95);

    inside = nnz(h>=lo & h<=hi);

end

function v = quantileBasic(x,p)

    % Toolbox-independent interpolated percentile.

    x = sort(x(isfinite(x)));

    n = numel(x);

    if n==0

        v = NaN;
        return;

    end

    if n==1

        v = x(1);
        return;

    end

    k = 1+(n-1)*p/100;

    a = floor(k);
    b = ceil(k);

    if a==b

        v = x(a);

    else

        v = x(a)*(b-k)+x(b)*(k-a);

    end

end

function exportBoth(fig,folder,name)

    exportgraphics(fig, ...
        fullfile(folder,[name '.png']), ...
        'Resolution',240);

    exportgraphics(fig, ...
        fullfile(folder,[name '.pdf']), ...
        'ContentType','vector');

    close(fig);

end
