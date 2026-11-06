
%% stage2D_run.m
% Stage 2D simulation runner
%
% Reuses frozen stage2C_sim.m.
% Does not edit Simulink, Stage 2C or Arduino firmware.
%
% Main experiments:
%   2D.0 Baseline regression
%   2D.1 Noise-free comparison
%   2D.2 Paired B2 measurement noise
%   2D.3 Operating-point shift sensitivity
%
% Produces no figures. stage2D_finalize generates four.

if ~exist('D2','var')
    stage2D_params;
end

%% 1. Construct the Stage 2C parameter structure

C = struct();

C.r = D2.reference;
C.I0 = D2.I0;
C.u0 = D2.u0;
C.x0 = D2.x0;
C.K = D2.K;

C.Ts = D2.Ts;
C.tShort = D2.tShort;
C.tLong = D2.tLong;

C.stopTime = D2.stopTime;
C.finalWindow = D2.finalWindow;

C.calibration = D2.calibration;
C.globalMax = D2.globalMax;
C.trim = D2.trim;
C.deadband = 0.03;

C.names = D2.names;
C.Kp = D2.Kp;
C.Ki = D2.Ki;

%% 2. Read B2 measurement residuals

T = readtable(D2.B2file);

valid = ...
    strcmpi(string(T.stim_state),'RUNNING') & ...
    isfinite(double(T.measured_mA)) & ...
    double(T.counter_applied)==215;

if ismember('fault_code',T.Properties.VariableNames)
    valid = valid & ...
        strcmpi(string(T.fault_code),'NONE');
end

B2current = double(T.measured_mA(valid));

assert(numel(B2current)>=100, ...
    'Insufficient valid B2 measurements.');

B2mean = mean(B2current);
residuals = B2current-B2mean;

fprintf('\nB2 residual analysis\n');
fprintf('Valid samples: %d\n',numel(residuals));
fprintf('Mean current: %.6f mA\n',B2mean);
fprintf('Residual SD: %.6f mA\n',std(residuals));

%% 3. Check the frozen nominal controller

assert(isequal(D2.deadbands,[0.03 0.05 0.08]));
assert(isequal(C.Kp,[5 4.942848 4.867577]));
assert(isequal(C.Ki,[3 4.879279 9.758558]));

fprintf('\n2D.0: Baseline regression\n');

for j = 1:3

    X = stage2C_sim(C,j,C.K,'fixed',0);

    % Accepted Stage 2B deadband settling results
    expected = [27.225 16.7475 8.415];

    ts = localSettling( ...
        X.t,X.true,C.r,0.03,1.0);

    assert(isfinite(ts) && ...
        abs(ts-expected(j))<=C.Ts*1.01, ...
        'Stage 2B regression failed: %s',C.names{j});

    verifyTrajectory(C,X);

end

fprintf('PASS: Frozen nominal regression.\n');

%% 4. Allocate output tables

noiseFree = table();
noiseTrials = table();
offsetTrials = table();

% Store one trajectory per deadband for Figure 4.
representative = cell(3,1);

%% 5. 2D.1: Noise-free comparison

fprintf('\n2D.1: Noise-free study\n');

for phase = 1:2

    mode = D2.phases{phase};

    for j = 1:3

        for b = 1:numel(D2.deadbands)

            C.deadband = D2.deadbands(b);

            X = stage2C_sim( ...
                C,j,C.K,mode,0);

            verifyTrajectory(C,X);

            M = localMetrics(D2,C,X);

            row = makeRow( ...
                C,j,C.deadband,mode,NaN,0,M);

            noiseFree = [noiseFree;row]; %#ok<AGROW>

        end

    end

end

%% 6. Prepare reproducible noise sequences

% Exact procedure from Stage 2C:
%   rng(seed,'twister')
%   sample B2 residuals with replacement
%
% Same sequence shared across every controller and
% deadband within the same seed.

noiseLength = ceil(C.stopTime/C.tShort)+8;

%% 7. 2D.2: Paired noise experiments

fprintf('2D.2: Paired measurement-noise study\n');

for s = 1:numel(D2.seeds)

    seed = D2.seeds(s);

    rng(seed,'twister');

    noise = residuals(randi( ...
        numel(residuals),noiseLength,1));

    for phase = 1:2

        mode = D2.phases{phase};

        for j = 1:3

            for b = 1:numel(D2.deadbands)

                C.deadband = D2.deadbands(b);

                X = stage2C_sim( ...
                    C,j,C.K,mode,noise);

                verifyTrajectory(C,X);

                % Confirm external noise was unchanged.
                assert(isequal( ...
                    X.noise,noise(1:numel(X.t))), ...
                    'Paired noise sequence mismatch.');

                M = localMetrics(D2,C,X);

                noiseTrials = [noiseTrials; ...
                    makeRow(C,j,C.deadband, ...
                    mode,seed,0,M)]; %#ok<AGROW>

                if s==1 && phase==1 && j==3
                    representative{b} = X;
                end

            end

        end

    end

end

assert(height(noiseTrials)==540, ...
    'Expected 540 nominal-plant noise configurations.');

fprintf('PASS: 540 nominal noise configurations.\n');

%% 8. 2D.3: Operating-point sensitivity

fprintf('2D.3: Operating-point sensitivity\n');

for s = 1:numel(D2.offsetSeeds)

    seed = D2.offsetSeeds(s);

    rng(seed,'twister');

    noise = residuals(randi( ...
        numel(residuals),noiseLength,1));

    for phase = 1:2

        mode = D2.phases{phase};

        for oi = 1:numel(D2.offsets)

            offset = D2.offsets(oi);

            C.I0 = D2.I0+offset;

            for j = 1:3

                for b = 1:numel(D2.deadbands)

                    C.deadband = D2.deadbands(b);

                    X = stage2C_sim( ...
                        C,j,C.K,mode,noise);

                    verifyTrajectory(C,X);

                    M = localMetrics(D2,C,X);

                    offsetTrials = [offsetTrials; ...
                        makeRow(C,j,C.deadband, ...
                        mode,seed,offset,M)]; %#ok<AGROW>

                end

            end

        end

    end

end

assert(height(offsetTrials)==540, ...
    'Expected 540 operating-point sensitivity cases.');

%% 9. Stage 2C matched regression when CSV is available

regressionStatus = "Not independently compared";

if isfile(D2.stage2Ccsv)

    old = readtable(D2.stage2Ccsv);

    % Match the 0.03 mA nominal plant cases against
    % Stage 2C combined results at the nominal gain.

    old = old( ...
        abs(old.PlantGain-D2.K)<1e-10,:);

    new = noiseTrials( ...
        noiseTrials.Deadband_mA==0.03,:);

    assert(height(old)==180 && height(new)==180, ...
        'Stage 2C comparison rows missing.');

    for k = 1:height(new)

        ix = ...
            old.Controller==new.Controller(k) & ...
            old.Condition==new.Timing(k) & ...
            old.Seed==new.Seed(k);

        assert(nnz(ix)==1, ...
            'Stage 2C comparison key missing.');

        assert(abs( ...
            old.TrueRMSE_mA(ix)- ...
            new.FullTrueRMSE_mA(k))<1e-10, ...
            'Stage 2C regression RMSE mismatch.');

        assert( ...
            old.TotalMovement(ix)== ...
            new.TotalDACMovement(k), ...
            'Stage 2C regression movement mismatch.');

    end

    regressionStatus = "Matched against Stage 2C CSV";
    fprintf('PASS: 180 Stage 2C matched regression rows.\n');

else

    warning(['2C_combined_trials.csv not found. ' ...
        'Baseline equivalence not independently audited.']);

end

%% 10. Save raw outputs and metadata

writetable(noiseFree,fullfile( ...
    D2.outputDir,'Stage2D_noise_free.csv'));

writetable(noiseTrials,fullfile( ...
    D2.outputDir,'Stage2D_noise_trials.csv'));

writetable(offsetTrials,fullfile( ...
    D2.outputDir,'Stage2D_offset_trials.csv'));

save(fullfile(D2.outputDir,'Stage2D_raw.mat'), ...
    'D2','residuals','B2mean','noiseFree', ...
    'noiseTrials','offsetTrials', ...
    'representative','regressionStatus','-v7.3');

fprintf('\nStage 2D simulations completed.\n');
fprintf('Regression status: %s\n',regressionStatus);
fprintf('Output directory: %s\n',D2.outputDir);

%% ============================================================
% Local helper functions
% ============================================================

function verifyTrajectory(C,X)

    ff = min(max(round(C.r*C.calibration),0), ...
        C.globalMax);

    lo = max(0,ff-C.trim);
    hi = min(C.globalMax,ff+C.trim);

    assert(X.applied(1)==C.u0);
    assert(X.integral(1)==C.x0);

    assert(all(X.applied==round(X.applied)));
    assert(all(X.applied>=lo & X.applied<=hi));

    assert(all(X.applied(2:end)==X.next(1:end-1)));

    assert(max(abs( ...
        X.measured-X.true-X.noise))<1e-10);

    assert(max(abs( ...
        X.true- ...
        (C.I0+C.K*(X.applied-C.u0))))<1e-10);

    assert(abs(X.t(end)-sum(X.dt))<1e-9);

    % Verify actual elapsed-time integral increments.
    for k = 2:numel(X.t)

        d = C.Ki(1); %#ok<NASGU>
        assert(abs( ...
            X.dt(k)-(X.t(k)-X.t(k-1)))<1e-10);

    end

    % Verify exact full-error deadband.
    expectedEd = X.error;

    expectedEd(abs(X.error)<=C.deadband)=0;

    assert(max(abs( ...
        expectedEd-X.adjusted))<1e-10);

end

function M = localMetrics(D2,C,X)

    t = X.t(:);
    y = X.true(:);
    ym = X.measured(:);
    u = X.applied(:);

    e = C.r-y;
    em = C.r-ym;

    w = diff([t;C.stopTime]);
    w = w/sum(w);

    steady = t>=C.stopTime-C.finalWindow;
    ws = w(steady);
    ws = ws/sum(ws);

    M.FullTrueRMSE_mA = sqrt(sum(w.*e.^2));

    M.SteadyTrueRMSE_mA = sqrt( ...
        sum(ws.*e(steady).^2));

    M.MeasuredRMSE_mA = sqrt(sum(w.*em.^2));

    M.SteadyBias_mA = sum( ...
        ws.*(y(steady)-C.r));

    M.SteadyAbsBias_mA = abs(M.SteadyBias_mA);

    M.MAE_mA = sum(w.*abs(e));

    M.Overshoot_mA = max(0,max(y)-C.r);

    M.InBand03 = sum(w(abs(e)<=0.03));
    M.InBand10 = sum(w(abs(e)<=0.1));

    M.SteadyInBand03 = sum( ...
        ws(abs(e(steady))<=0.03));

    M.WithinControllerDeadband = ...
        sum(w(abs(e)<=C.deadband));

    du = diff(u);

    M.PositiveDACMovement = sum(du(du>0));
    M.NegativeDACMovement = -sum(du(du<0));
    M.TotalDACMovement = sum(abs(du));
    M.NetDACMovement = u(end)-u(1);

    M.DACChanges = nnz(du~=0);
    M.MaxStep = max(abs(du));

    M.SteadyDistinctCodes = ...
        numel(unique(u(steady)));

    M.SteadyChangesPerSecond = ...
        nnz(diff(u(steady))~=0)/C.finalWindow;

    M.IntegralSD = std(X.integral(steady));

    M.Settling1pct_s = localSettling( ...
        t,y,C.r,0.1,D2.minimumHold_s);

    M.Settling03_s = localSettling( ...
        t,y,C.r,0.03,D2.minimumHold_s);

    % Trailing two-second moving average using
    % approximately one window of burst measurements.
    nWindow = max(1,round( ...
        D2.averageWindow_s/C.Ts));

    smoothed = movmean(y,[nWindow-1 0]);

    M.MovingAverageSettling_s = localSettling( ...
        t,smoothed,C.r,0.03,D2.minimumHold_s);

    M.FinalCounter = u(end);
    M.FinalCurrent_mA = y(end);

    M.CounterConstantFinal20s = ...
        numel(unique(u(steady)))==1;

    assert(abs( ...
        M.PositiveDACMovement- ...
        M.NegativeDACMovement- ...
        M.NetDACMovement)<1e-8);

    assert(abs( ...
        M.PositiveDACMovement+ ...
        M.NegativeDACMovement- ...
        M.TotalDACMovement)<1e-8);

end

function ts = localSettling(t,y,target,tol,minHold)

    inside = abs(y-target)<=tol;
    lastBad = find(~inside,1,'last');

    ts = NaN;

    if isempty(lastBad)
        idx = 1;
    elseif lastBad<numel(t)
        idx = lastBad+1;
    else
        return;
    end

    if t(end)-t(idx)>=minHold
        ts = t(idx);
    end

end

function row = makeRow(C,j,D,mode,seed,offset,M)

    row = table( ...
        string(C.names{j}),D,string(mode), ...
        seed,offset, ...
        M.FullTrueRMSE_mA, ...
        M.SteadyTrueRMSE_mA, ...
        M.MeasuredRMSE_mA, ...
        M.SteadyBias_mA, ...
        M.SteadyAbsBias_mA, ...
        M.MAE_mA, ...
        M.Overshoot_mA, ...
        M.InBand03, ...
        M.SteadyInBand03, ...
        M.InBand10, ...
        M.WithinControllerDeadband, ...
        M.PositiveDACMovement, ...
        M.NegativeDACMovement, ...
        M.TotalDACMovement, ...
        M.NetDACMovement, ...
        M.DACChanges, ...
        M.MaxStep, ...
        M.SteadyChangesPerSecond, ...
        M.SteadyDistinctCodes, ...
        M.IntegralSD, ...
        M.Settling1pct_s, ...
        M.Settling03_s, ...
        M.MovingAverageSettling_s, ...
        M.FinalCounter, ...
        M.FinalCurrent_mA, ...
        M.CounterConstantFinal20s, ...
        'VariableNames',{ ...
        'Controller','Deadband_mA','Timing', ...
        'Seed','Offset_mA', ...
        'FullTrueRMSE_mA', ...
        'SteadyTrueRMSE_mA', ...
        'MeasuredRMSE_mA', ...
        'SteadyBias_mA', ...
        'SteadyAbsBias_mA', ...
        'MAE_mA', ...
        'Overshoot_mA', ...
        'InBand03', ...
        'SteadyInBand03', ...
        'InBand10', ...
        'WithinControllerDeadband', ...
        'PositiveDACMovement', ...
        'NegativeDACMovement', ...
        'TotalDACMovement', ...
        'NetDACMovement', ...
        'DACChanges', ...
        'MaxStep', ...
        'SteadyChangesPerSecond', ...
        'SteadyDistinctCodes', ...
        'IntegralSD', ...
        'Settling1pct_s', ...
        'Settling03_s', ...
        'MovingAverageSettling_s', ...
        'FinalCounter', ...
        'FinalCurrent_mA', ...
        'CounterConstantFinal20s'});

end
