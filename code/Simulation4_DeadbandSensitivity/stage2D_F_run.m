
%% stage2D_F_run.m
% OpenXstim Stage 2D-F: Fine deadband sweep
%
% Reuses the frozen stage2C_sim.m recurrence.
% No firmware or existing Simulink model changes.
%
% Requires qualified Stage 2D-N noise data.
% Stops if accepted residual membership is incorrect.
%
% Runs:
% F1: Noise-free quantisation sweep
% F2: N1, N2, N3 noise models
% F3: Individual-recording sensitivity
% F4: Hypothetical offset sensitivity

clearvars;
clc;

%% 1. Paths and experiment settings

root = fileparts(mfilename('fullpath'));

if isempty(root)
    root = pwd;
end

noiseDir = fullfile(root,'NoiseAnalysis_Results');
outDir = fullfile(root,'Stage2D_F_Results');

if ~exist(outDir,'dir')
    mkdir(outDir);
end

assert(exist('stage2C_sim','file')==2, ...
    'Add your frozen Stage 2C folder to MATLAB path.');

matFile = fullfile(noiseDir,'Noise_ResidualModels.mat');
resFile = fullfile(noiseDir,'Noise_Residuals.csv');
auditFile = fullfile(noiseDir,'Noise_RowAudit.csv');
faultFile = fullfile(noiseDir,'Noise_FaultEvents.csv');

assert(isfile(matFile),'Missing qualified noise MAT file.');
assert(isfile(resFile),'Missing accepted residual CSV.');
assert(isfile(auditFile),'Missing row-level audit CSV.');
assert(isfile(faultFile),'Missing fault-event audit CSV.');

%% 2. Load qualified noise sources

S = load(matFile);

assert(isfield(S,'NoiseModels'), ...
    'NoiseModels not found in MAT file.');

R = S.NoiseModels.residuals;
Rcsv = readtable(resFile);
A = readtable(auditFile);
F = readtable(faultFile);

required = { ...
    'File','OriginalRow','Residual_mA'};

assert(all(ismember(required,R.Properties.VariableNames)));
assert(all(ismember(required,Rcsv.Properties.VariableNames)));

assert(height(R)==1088, ...
    'Expected exactly 1088 qualified residuals.');

assert(height(Rcsv)==height(R), ...
    'MAT and CSV residual counts disagree.');

% Construct normalized recording identifiers.
source = strings(height(R),1);
sourceCSV = strings(height(Rcsv),1);

for k = 1:height(R)
    source(k) = sourceName(R.File(k));
end

for k = 1:height(Rcsv)
    sourceCSV(k) = sourceName(Rcsv.File(k));
end

labels = ["B1","B2","1k"];
expectedCounts = [490 494 104];

for j = 1:3
    assert(nnz(source==labels(j))==expectedCounts(j), ...
        'Wrong accepted count for %s.',labels(j));
end

assert(all(ismember(source,labels)), ...
    'An unsupported recording entered noise data.');

% Exact identity comparison using source and row index.
keyMAT = source + ":" + string(R.OriginalRow);
keyCSV = sourceCSV + ":" + string(Rcsv.OriginalRow);

assert(numel(unique(keyMAT))==height(R), ...
    'Duplicate accepted source rows.');

[matched,loc] = ismember(keyMAT,keyCSV);

assert(all(matched) && ...
    numel(unique(loc))==height(R), ...
    'MAT and CSV residual membership differs.');

assert(all(abs( ...
    R.Residual_mA - Rcsv.Residual_mA(loc))<1e-10), ...
    'MAT and CSV residual values differ.');

%% 3. Validate accepted rows against audit

auditSource = strings(height(A),1);

for k = 1:height(A)
    auditSource(k) = sourceName(A.File(k));
end

auditKey = auditSource + ":" + ...
    string(A.OriginalRow);

assert(numel(unique(auditKey))==height(A), ...
    'Duplicate row audit keys.');

[matchedAudit,auditLoc] = ismember(keyMAT,auditKey);

assert(all(matchedAudit), ...
    'Accepted residual absent from row audit.');

assert(all( ...
    string(A.FinalDecision(auditLoc))=="ACCEPTED"), ...
    'Rejected observation entered residual model.');

% Verify excluded fault-associated source rows.
assert(height(F)>=1, ...
    'No fault-associated exclusion was recorded.');

assert(all(ismember( ...
    {'File','SegmentStartRow', ...
     'SegmentEndRow','ExcludedRows'}, ...
    F.Properties.VariableNames)));

assert(any(F.ExcludedRows==136), ...
    'The expected 136-row exclusion is missing.');

for k = 1:height(F)

    src = sourceName(F.File(k));

    ix = source==src & ...
        R.OriginalRow>=F.SegmentStartRow(k) & ...
        R.OriginalRow<=F.SegmentEndRow(k);

    assert(~any(ix), ...
        'Fault-associated observations entered noise model.');

end

assert(all(isfinite(R.Residual_mA)), ...
    'Nonfinite accepted noise residuals.');

% Residuals are independently centered by source.
noiseSources = cell(3,1);

for j = 1:3
    v = double(R.Residual_mA(source==labels(j)));
    noiseSources{j} = v;
end

fprintf('\nQUALIFIED NOISE VERIFICATION\n');

for j = 1:3
    fprintf('%s: %d samples, SD %.6f mA\n', ...
        labels(j),numel(noiseSources{j}), ...
        std(noiseSources{j}));
end

fprintf('Total qualified samples: %d\n',height(R));

pooled = vertcat(noiseSources{:});

fprintf('Pooled residual RMS: %.6f mA\n', ...
    sqrt(mean(pooled.^2)));

assert(abs(sqrt(mean(pooled.^2))-0.042074)<0.002, ...
    'Pooled variability differs from expected value.');

fprintf('PASS: Qualified noise membership and fault exclusions.\n');

%% 4. Frozen controller configuration

C = struct();

C.r = 10;
C.I0 = 9.593752;
C.u0 = 215;
C.x0 = 0;
C.K = 0.0458338958;

C.Ts = 0.0825;
C.tShort = 0.076;
C.tLong = 0.089;

C.stopTime = 60;
C.finalWindow = 20;

C.calibration = 21.5;
C.globalMax = 322;
C.trim = 25;

C.names = { ...
    'Empirical', ...
    'Conservative', ...
    'Moderately faster'};

C.Kp = [5 4.942848 4.867577];
C.Ki = [3 4.879279 9.758558];

deadbands = 0.025:0.005:0.080;
deadbands = round(deadbands,6);

seeds = 1001:1030;
phases = {'shortFirst','longFirst'};

decisionDeadbands = [0.03 0.04 0.05 0.06 0.08];
offsetDeadbands = [0.03 0.04 0.05 0.08];
offsets = [-0.02 0 0.02];

% Enough noise observations for either timing schedule.
noiseLength = ceil(C.stopTime/C.tShort)+10;

%% 5. F1: Noise-free quantisation

fprintf('\nF1: Noise-free sweep\n');

f1 = struct([]);
counter = 0;

for j = 1:3
    for b = 1:numel(deadbands)
        for p = 1:2

            C.deadband = deadbands(b);

            X = stage2C_sim( ...
                C,j,C.K,phases{p},0);

            verifyRun(C,X,j);

            counter = counter+1;

            f1 = [f1, resultRow( ...
                C,X,j,"NoiseFree", ...
                deadbands(b),phases{p}, ...
                NaN,0)];

        end
    end
end

F1 = struct2table(f1);

%% 6. F2: Main noise-model sweep

fprintf('F2: N1, N2 and N3 noise sweeps\n');

f2 = struct([]);
counter = 0;

% One reproducible random draw per seed and noise model.
% Exactly the same generated sequence is supplied to
% every controller/deadband/timing combination.

for seed = seeds

    for model = 1:3

        noise = makeNoise( ...
            noiseSources,model,seed,noiseLength);

        for p = 1:2
            for j = 1:3
                for b = 1:numel(deadbands)

                    C.deadband = deadbands(b);

                    X = stage2C_sim( ...
                        C,j,C.K,phases{p},noise);

                    verifyRun(C,X,j);

                    assert(isequal( ...
                        X.noise,noise(1:numel(X.t))), ...
                        'Paired noise mismatch.');

                    counter = counter+1;

                    f2 = [f2, resultRow( ...
                        C,X,j,"N"+string(model), ...
                        deadbands(b),phases{p}, ...
                        seed,0)];

                end
            end
        end

    end

end

F2 = struct2table(f2);

assert(height(F2)==6480, ...
    'Main trial count mismatch.');

%% 7. F3: Individual recording sensitivity

fprintf('F3: Individual recording sensitivity\n');

f3 = struct([]);
counter = 0;

for seed = seeds

    for src = 1:3

        noise = makeNoise( ...
            noiseSources,3+src,seed,noiseLength);

        for p = 1:2
            for b = 1:numel(decisionDeadbands)

                C.deadband = decisionDeadbands(b);

                X = stage2C_sim( ...
                    C,3,C.K,phases{p},noise);

                verifyRun(C,X,3);

                counter = counter+1;

                f3 = [f3, resultRow( ...
                    C,X,3,"N"+string(3+src), ...
                    C.deadband,phases{p},seed,0)];

            end
        end
    end
end

F3 = struct2table(f3);

assert(height(F3)==900, ...
    'Individual recording trial count mismatch.');

%% 8. F4: Hypothetical operating-point shifts

fprintf('F4: Hypothetical offset sensitivity\n');

f4 = struct([]);
counter = 0;

for seed = seeds(1:10)

    % Use the sample-weighted qualified pool.
    noise = makeNoise( ...
        noiseSources,2,seed,noiseLength);

    for p = 1:2
        for oi = 1:numel(offsets)

            C.I0 = 9.593752+offsets(oi);

            for j = 1:3
                for b = 1:numel(offsetDeadbands)

                    C.deadband = offsetDeadbands(b);

                    X = stage2C_sim( ...
                        C,j,C.K,phases{p},noise);

                    verifyRun(C,X,j);

                    counter = counter+1;

                    f4 = [f4, resultRow( ...
                        C,X,j,"N2",C.deadband, ...
                        phases{p},seed,offsets(oi))];

                end
            end
        end
    end
end

F4 = struct2table(f4);

assert(height(F4)==720, ...
    'Offset trial count mismatch.');

C.I0 = 9.593752;

%% 9. Save reproducible results

writetable(F1,fullfile(outDir,'F1_NoiseFree.csv'));
writetable(F2,fullfile(outDir,'F2_MainTrials.csv'));
writetable(F3,fullfile(outDir,'F3_IndividualSources.csv'));
writetable(F4,fullfile(outDir,'F4_OffsetTrials.csv'));

save(fullfile(outDir,'Stage2D_F_Raw.mat'), ...
    'C','deadbands','seeds','phases', ...
    'noiseSources','F1','F2','F3','F4', ...
    'R','F','-v7.3');

fid = fopen(fullfile(outDir,'Verification_Log.txt'),'w');

fprintf(fid,'Stage 2D-F simulation verification\n');
fprintf(fid,'Date: %s\n',datestr(now));
fprintf(fid,'MATLAB: %s\n',version);
fprintf(fid,'Qualified residuals: %d\n',height(R));
fprintf(fid,'Fault-associated segments: %d\n',height(F));
fprintf(fid,'F1 trials: %d\n',height(F1));
fprintf(fid,'F2 trials: %d\n',height(F2));
fprintf(fid,'F3 trials: %d\n',height(F3));
fprintf(fid,'F4 trials: %d\n',height(F4));
fprintf(fid,'All executed trajectory checks passed.\n');
fprintf(fid,'Regression against old Stage 2D CSV: pending report.\n');

fclose(fid);

fprintf('\nStage 2D-F simulations completed.\n');
fprintf('Output folder: %s\n',outDir);

%% ============================================================
% Local functions
% ============================================================

function name = sourceName(file)

    [~,stem,~] = fileparts(char(file));

    stem = lower(regexprep(stem, ...
        '\s*\(\d+\)$',''));

    if startsWith(stem,'b1 2k')
        name = "B1";
    elseif startsWith(stem,'b2 4k')
        name = "B2";
    elseif contains(stem,'open loop 1k')
        name = "1k";
    else
        name = "UNKNOWN";
    end

end

function noise = makeNoise(sources,model,seed,N)

    rng(seed,'twister');

    n = cellfun(@numel,sources);

    if model==1
        % Preserve original B2 randi procedure.
        noise = sources{2}(randi(n(2),N,1));

    elseif model==2
        % Sample-weighted qualified pool.
        pool = vertcat(sources{:});
        noise = pool(randi(numel(pool),N,1));

    elseif model==3
        % Equal probability for each recording.
        sourceDraw = randi(3,N,1);
        noise = zeros(N,1);

        for i = 1:3
            ix = sourceDraw==i;
            noise(ix) = sources{i}( ...
                randi(n(i),nnz(ix),1));
        end

    elseif model>=4 && model<=6
        % N4, N5, N6 represent B1, B2, 1k.
        i = model-3;
        noise = sources{i}(randi(n(i),N,1));

    else
        error('Unknown noise model.');
    end

    noise = noise(:);

end

function verifyRun(C,X,j)

    N = numel(X.t);

    ff = min(max(round(C.r*C.calibration),0), ...
        C.globalMax);

    lo = max(0,ff-C.trim);
    hi = min(C.globalMax,ff+C.trim);

    assert(X.applied(1)==C.u0);
    assert(X.integral(1)==C.x0);

    assert(all(X.applied==round(X.applied)));
    assert(all(X.applied>=lo & X.applied<=hi));
    assert(all(X.next>=lo & X.next<=hi));

    assert(all( ...
        X.applied(2:end)==X.next(1:end-1)));

    assert(all(abs( ...
        X.true-(C.I0+C.K*(X.applied-C.u0)))<1e-9));

    assert(all(abs( ...
        X.measured-X.true-X.noise)<1e-9));

    assert(all(abs( ...
        X.error-(C.r-X.measured))<1e-9));

    % Independent reconstruction of deadband,
    % integral update and conditional anti-windup.

    xOld = C.x0;

    for k = 1:N

        e = X.error(k);

        ed = e;

        if abs(e)<=C.deadband
            ed = 0;
        end

        assert(abs(ed-X.adjusted(k))<1e-9, ...
            'Deadband mismatch.');

        if k==1
            dt = 0;
        else
            dt = X.t(k)-X.t(k-1);
        end

        assert(abs(dt-X.dt(k))<1e-9, ...
            'Elapsed-time mismatch.');

        delta = C.Ki(j)*min(dt,0.5)*ed;
        xTrial = xOld+delta;

        trial = ff+C.Kp(j)*ed+xTrial;

        freeze = ...
            (trial>hi && delta>0) || ...
            (trial<lo && delta<0);

        if freeze
            xNew = xOld;
        else
            xNew = xTrial;
        end

        raw = ff+C.Kp(j)*ed+xNew;
        next = round(min(max(raw,lo),hi));

        assert(abs(X.integral(k)-xNew)<1e-8, ...
            'Integral recurrence mismatch.');

        assert(logical(X.frozen(k))==freeze, ...
            'Anti-windup decision mismatch.');

        assert(X.next(k)==next, ...
            'Next-command mismatch.');

        xOld = xNew;

    end

    du = diff(X.applied);

    assert(abs( ...
        sum(du(du>0))+sum(du(du<0))- ...
        (X.applied(end)-X.applied(1)))<1e-9);

end

function Q = resultRow(C,X,j,model,D,phase,seed,offset)

    t = X.t(:);
    y = X.true(:);
    ym = X.measured(:);
    u = X.applied(:);

    w = diff([t;C.stopTime]);
    assert(all(w>=-1e-10));
    w = max(w,0);
    w = w/sum(w);

    steady = t>=C.stopTime-C.finalWindow;

    ws = w(steady);
    ws = ws/sum(ws);

    err = y-C.r;
    errMeasured = ym-C.r;

    du = diff(u);

    steadyU = u(steady);

    % First entry with at least 1 second inside
    % the common 1% band.
    transient = NaN;

    for k = 1:numel(t)

        last = find(t<=t(k)+1,1,'last');

        if isempty(last) || t(last)-t(k)<0.99
            continue;
        end

        if all(abs(err(k:last))<=0.1)
            transient = t(k);
            break;
        end

    end

    % Strict entry-and-remain deadband settling.
    lastBad = find(abs(err)>0.03,1,'last');

    strictSettling = NaN;

    if isempty(lastBad)
        candidate = 1;
    elseif lastBad<numel(t)
        candidate = lastBad+1;
    else
        candidate = [];
    end

    if ~isempty(candidate) && ...
            t(end)-t(candidate)>=1

        strictSettling = t(candidate);

    end

    Q = struct( ...
        'Controller',string(C.names{j}), ...
        'NoiseModel',string(model), ...
        'Deadband_mA',D, ...
        'Timing',string(phase), ...
        'Seed',seed, ...
        'Offset_mA',offset, ...
        'FullRMSE_mA',sqrt(sum(w.*err.^2)), ...
        'SteadyRMSE_mA',sqrt(sum( ...
            ws.*err(steady).^2)), ...
        'MeasuredRMSE_mA',sqrt(sum( ...
            w.*errMeasured.^2)), ...
        'SteadyBias_mA',sum(ws.*err(steady)), ...
        'SteadyAbsBias_mA',abs(sum(ws.*err(steady))), ...
        'InBand03',sum(w(abs(err)<=0.03)), ...
        'InBand10',sum(w(abs(err)<=0.1)), ...
        'SteadyInBand03',sum( ...
            ws(abs(err(steady))<=0.03)), ...
        'EntryHold1pct_s',transient, ...
        'StrictSettling03_s',strictSettling, ...
        'SteadySwitchRate', ...
            nnz(diff(steadyU)~=0)/C.finalWindow, ...
        'TotalMovement',sum(abs(du)), ...
        'PositiveMovement',sum(du(du>0)), ...
        'NegativeMovement',-sum(du(du<0)), ...
        'DACChanges',nnz(du~=0), ...
        'SteadyDistinctCodes',numel(unique(steadyU)), ...
        'FinalCounter',u(end), ...
        'FinalCurrent_mA',y(end), ...
        'FinalAbsError_mA',abs(err(end)), ...
        'FinalInBand03',abs(err(end))<=0.03, ...
        'FinalCommandConstant', ...
            numel(unique(steadyU))==1);

end
