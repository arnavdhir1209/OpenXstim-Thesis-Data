
%% stage2B_finalize.m
% OpenXstim Stage 2B: Final verification and checkpoint
%
% Reads saved Stage 2B simulation results.
% Does NOT run Simulink or modify the working model.
%
% Final verification:
%  1. Explicit settling status
%  2. Anti-windup stress and recovery
%  3. DAC movement accounting
%
% Outputs:
%  Stage2B_performance_final.csv
%  Stage2B_antiwindup_summary.csv
%  Stage2B_final_verification.mat
%  Stage2B_Verification_Checkpoint.md
%
% No additional figures are generated.

clearvars;
clc;

%% 1. Locate saved Stage 2B results

scriptDir = fileparts(mfilename('fullpath'));

if isempty(scriptDir)
    scriptDir = pwd;
end

outputDir = fullfile(scriptDir, 'Stage2B_Results');

resultFile = fullfile(outputDir, ...
    'Stage2B_results.mat');

assert(isfile(resultFile), ...
    'Cannot find Stage2B_results.mat in Stage2B_Results.');

fprintf('\n========================================\n');
fprintf('STAGE 2B FINAL VERIFICATION\n');
fprintf('========================================\n');

fprintf('Loading saved simulation results...\n');

D = load(resultFile);

B = D.B;
R = D.R;
stress = D.stress;

metrics = D.metrics;

assert(size(R,1) == numel(B.names), ...
    'Controller count mismatch.');

assert(size(R,2) == size(B.features,1), ...
    'Configuration count mismatch.');

%% 2. Define settling-time requirements

% A settling event must be followed by at least
% one second of observed response.
%
% This prevents the final sample entering a tolerance
% band from being counted as sustained settling.

minimumObservation_s = 1.0;

settling1 = nan(height(metrics),1);
settlingDB = nan(height(metrics),1);

settled1 = false(height(metrics),1);
settledDB = false(height(metrics),1);

settling1Status = strings(height(metrics),1);
settlingDBStatus = strings(height(metrics),1);

%% 3. Recalculate settling times from trajectories

fprintf('\nCHECK 1: SETTLING STATUS\n');

for j = 1:numel(B.names)

    for c = 1:size(B.features,1)

        Q = R{j,c};

        t = Q.current.t(:);
        y = Q.current.y(:);

        assert(numel(t)==numel(y), ...
            'Current time and data lengths differ.');

        assert(all(isfinite(t)) && all(isfinite(y)), ...
            'Nonfinite current trajectory.');

        % Match row in saved performance table
        ix = find( ...
            metrics.Controller == string(B.names{j}) & ...
            metrics.Configuration == ...
            string(B.configNames{c}));

        assert(numel(ix)==1, ...
            'Cannot uniquely match performance row.');

        %% 1% settling

        [ts1,ok1] = settlingAudit( ...
            t,y,B.r,0.01*abs(B.r), ...
            minimumObservation_s);

        %% Firmware deadband settling

        [tsDB,okDB] = settlingAudit( ...
            t,y,B.r,B.deadband, ...
            minimumObservation_s);

        settling1(ix) = ts1;
        settlingDB(ix) = tsDB;

        settled1(ix) = ok1;
        settledDB(ix) = okDB;

        if ok1
            settling1Status(ix) = "Settled";
        else
            settling1Status(ix) = ...
                "Not settled within 60 s";
        end

        if okDB
            settlingDBStatus(ix) = "Settled";
        else
            settlingDBStatus(ix) = ...
                "Not settled within 60 s";
        end

        fprintf('%s | %s\n', ...
            B.names{j},B.configNames{c});

        fprintf('  1%%: %s\n',settling1Status(ix));

        fprintf('  Deadband: %s\n',settlingDBStatus(ix));

    end
end

%% 4. Replace ambiguous settling metrics

% Keep original values for auditability.

metrics.OriginalSettling1pct_s = ...
    metrics.Settling1pct_s;

metrics.OriginalSettlingDeadband_s = ...
    metrics.SettlingDeadband_s;

metrics.Settling1pct_s = settling1;
metrics.SettlingDeadband_s = settlingDB;

metrics.Settled1pct = settled1;
metrics.SettledDeadband = settledDB;

metrics.Settling1pctStatus = settling1Status;
metrics.SettlingDeadbandStatus = settlingDBStatus;

% Quantised-only configurations must not be reported as
% settled merely because the last sample is within
% the deadband.

ixQuant = metrics.Configuration == "Quantised";

assert(~any(metrics.SettledDeadband(ixQuant)), ...
    ['Quantised-only case unexpectedly meets sustained ' ...
     'deadband settling. Inspect the trajectories.']);

fprintf('\nPASS: Settling-status audit completed.\n');

%% 5. Recalculate all DAC movement metrics

fprintf('\nCHECK 2: DAC MOVEMENT ACCOUNTING\n');

positive = zeros(height(metrics),1);
negative = zeros(height(metrics),1);
total = zeros(height(metrics),1);
net = zeros(height(metrics),1);
changes = zeros(height(metrics),1);
maxStep = zeros(height(metrics),1);

for j = 1:numel(B.names)

    for c = 1:size(B.features,1)

        Q = R{j,c};

        u = Q.applied.y(:);

        assert(numel(u)>=2, ...
            'Not enough DAC samples.');

        assert(all(isfinite(u)), ...
            'Nonfinite applied DAC command.');

        du = diff(u);

        %% Movement definitions

        inc = sum(du(du>0));

        dec = -sum(du(du<0));

        absMove = sum(abs(du));

        netMove = u(end)-u(1);

        nChanges = nnz(du~=0);

        largestStep = max(abs(du));

        %% Internal consistency

        assert(abs(inc-dec-netMove)<1e-8, ...
            'Positive/negative/net movement mismatch.');

        assert(abs(inc+dec-absMove)<1e-8, ...
            'Absolute movement mismatch.');

        assert(nChanges==nnz(diff(u)~=0), ...
            'DAC change count mismatch.');

        assert(abs(netMove-sum(du))<1e-8, ...
            'Net movement does not equal sum of changes.');

        %% Verify quantisation where enabled

        if B.features(c,1)==1

            assert(all(abs(u-round(u))<1e-9), ...
                'Quantised configuration has noninteger DAC.');

        end

        %% Match performance table row

        ix = find( ...
            metrics.Controller == string(B.names{j}) & ...
            metrics.Configuration == ...
            string(B.configNames{c}));

        assert(numel(ix)==1, ...
            'Performance table row mismatch.');

        positive(ix) = inc;
        negative(ix) = dec;
        total(ix) = absMove;
        net(ix) = netMove;
        changes(ix) = nChanges;
        maxStep(ix) = largestStep;

    end
end

%% Store consistently calculated movement metrics

metrics.PositiveDACMovement = positive;
metrics.NegativeDACMovement = negative;
metrics.TotalDACMovement = total;
metrics.NetDACMovement = net;
metrics.TotalDACChanges = changes;
metrics.MaxDACStep = maxStep;

fprintf('PASS: All movement metrics use applied Counter.\n');

%% 6. Anti-windup stress test

fprintf('\nCHECK 3: ANTI-WINDUP STRESS TEST\n');

noAW = stress{1};
withAW = stress{2};

% First condition: output limits enabled, AW disabled.
% Second condition: output limits enabled, AW enabled.

ff = min(max( ...
    round(B.r*B.calibration),0),B.globalMax);

lower = max(0,ff-B.trim);
upper = min(B.globalMax,ff+B.trim);

%% Verify both controllers respect identical limits

for q = 1:2

    u = stress{q}.applied.y(:);

    assert(all(u>=lower & u<=upper), ...
        'Stress-test command violated output limit.');

    assert(all(abs(u-round(u))<1e-9), ...
        'Stress-test command is not an integer.');

    next = stress{q}.next.y(:);

    nCheck = min(numel(u)-1,numel(next));

    assert(nCheck>0, ...
        'Insufficient samples to test command indexing.');

    assert(all(abs( ...
        u(2:nCheck+1)-next(1:nCheck))<1e-7), ...
        'Stress-test command indexing failed.');

end

fprintf('PASS: Both controllers respect command limits.\n');
fprintf('PASS: One-burst command indexing verified.\n');

%% 7. Check exact conditional integration logic

% Uses the recorded adjusted error and previous
% integral state to independently reconstruct the
% anti-windup decision.
%
% The firmware suppresses outward integration when
% the tentative command exceeds the permitted bounds.

for q = 1:2

    Q = stress{q};

    eD = Q.adjusted_error.y(:);
    x = Q.integral.y(:);
    frozen = Q.integral_frozen.y(:);

    applied = Q.applied.y(:);

    N = numel(x);

    assert(numel(eD)==N && numel(frozen)==N, ...
        'Anti-windup log lengths mismatch.');

    % The stress simulation uses the third controller.
    kp = B.Kp(3);
    ki = B.Ki(3);

    previousIntegral = B.x0;

    for k = 1:N

        %% First update skips integration

        if k==1
            deltaI = 0;
        else
            deltaI = ki*B.Ts*eD(k);
        end

        tentativeIntegral = previousIntegral+deltaI;

        tentativeCommand = ...
            ff+kp*eD(k)+tentativeIntegral;

        pushingUpper = ...
            tentativeCommand>upper && deltaI>0;

        pushingLower = ...
            tentativeCommand<lower && deltaI<0;

        %% Expected conditional integration decision

        if q==2

            shouldFreeze = pushingUpper || pushingLower;

        else

            % Anti-windup disabled.
            shouldFreeze = false;

        end

        if shouldFreeze
            expectedIntegral = previousIntegral;
        else
            expectedIntegral = tentativeIntegral;
        end

        %% Assertions

        assert(abs(x(k)-expectedIntegral)<1e-6, ...
            ['Integral update mismatch at ' ...
             'stress case %d, sample %d.'],q,k);

        assert(logical(frozen(k))==shouldFreeze, ...
            ['Freeze decision mismatch at ' ...
             'stress case %d, sample %d.'],q,k);

        previousIntegral = x(k);

    end

    assert(all(isfinite(applied)), ...
        'Stress-test applied command contains nonfinite data.');

end

fprintf('PASS: Exact conditional integration verified.\n');

%% 8. Verify outward freeze and inward unwinding

t = withAW.current.t(:);

stressWindow = ...
    t>=B.stressStart & t<B.stressEnd;

recoveryWindow = t>=B.stressEnd;

assert(any(withAW.integral_frozen.y(stressWindow)>0.5), ...
    'Anti-windup never froze integration.');

assert(~any(noAW.integral_frozen.y>0.5), ...
    'Anti-windup disabled but freeze flag activated.');

assert(any(diff( ...
    withAW.integral.y(recoveryWindow))<-1e-9), ...
    'Conditional integrator did not unwind.');

assert(any(noAW.applied.y(stressWindow)==upper), ...
    'No-AW controller never reached saturation.');

assert(any(withAW.applied.y(stressWindow)==upper), ...
    'AW controller never reached saturation.');

fprintf('PASS: Outward freeze and inward unwinding verified.\n');

%% 9. Calculate anti-windup stress metrics

labels = [
    "No anti-windup"
    "Conditional anti-windup"
];

maximumIntegral = zeros(2,1);
timeAtUpper = zeros(2,1);
recoveryTime = nan(2,1);
peakAfterRemoval = zeros(2,1);

for q = 1:2

    Q = stress{q};

    t = Q.current.t(:);
    y = Q.current.y(:);
    u = Q.applied.y(:);
    x = Q.integral.y(:);

    during = ...
        t>=B.stressStart & t<B.stressEnd;

    after = t>=B.stressEnd;

    %% Maximum integral state during stress

    maximumIntegral(q) = max(x(during));

    %% Time at upper limit during disturbance

    % Fixed-step approximation:
    % number of samples at upper limit times Ts.

    timeAtUpper(q) = ...
        nnz(u(during)==upper)*B.Ts;

    %% Recovery time from disturbance removal

    tAfter = t(after);
    yAfter = y(after);

    [absoluteRecovery, recovered] = settlingAudit( ...
        tAfter,yAfter,B.r,B.deadband, ...
        minimumObservation_s);

    if recovered
        recoveryTime(q) = ...
            absoluteRecovery-B.stressEnd;
    end

    %% Peak current after removal

    peakAfterRemoval(q) = max(yAfter);

end

antiwindup = table( ...
    labels, ...
    maximumIntegral, ...
    timeAtUpper, ...
    recoveryTime, ...
    peakAfterRemoval, ...
    'VariableNames',{ ...
        'Configuration', ...
        'MaximumIntegral_counts', ...
        'TimeAtUpperLimit_s', ...
        'RecoveryTime_s', ...
        'PeakCurrentAfterRemoval_mA'});

%% 10. Verify recovery advantage

assert(all(isfinite(recoveryTime)), ...
    'One or both stress cases failed to recover.');

assert(recoveryTime(2)<recoveryTime(1), ...
    'Anti-windup did not improve recovery time.');

assert(maximumIntegral(2)<maximumIntegral(1), ...
    'Anti-windup did not reduce integral accumulation.');

fprintf('\nANTI-WINDUP NUMERICAL SUMMARY\n');
disp(antiwindup);

fprintf('PASS: Anti-windup numerical verification.\n');

%% 11. Final performance summary

fprintf('\nFULL FIRMWARE-AWARE PERFORMANCE\n');

ixFull = ...
    metrics.Configuration=="Full firmware PI";

disp(metrics(ixFull,{ ...
    'Controller', ...
    'Settling1pct_s', ...
    'SettlingDeadband_s', ...
    'SteadyMean_mA', ...
    'SteadyBias_mA', ...
    'PositiveDACMovement', ...
    'NegativeDACMovement', ...
    'TotalDACMovement', ...
    'NetDACMovement', ...
    'TotalDACChanges'}));

%% 12. Export CSV results

performancePath = fullfile(outputDir, ...
    'Stage2B_performance_final.csv');

awPath = fullfile(outputDir, ...
    'Stage2B_antiwindup_summary.csv');

writetable(metrics,performancePath);

writetable(antiwindup,awPath);

%% 13. Save verification workspace

save(fullfile(outputDir, ...
    'Stage2B_final_verification.mat'), ...
    'B','metrics','antiwindup', ...
    'minimumObservation_s');

%% 14. Generate Markdown checkpoint

checkpointPath = fullfile(outputDir, ...
    'Stage2B_Verification_Checkpoint.md');

fid = fopen(checkpointPath,'w');

assert(fid>0, ...
    'Unable to create checkpoint Markdown file.');

fprintf(fid,'# Stage 2B Verification and Model Baseline\n\n');

fprintf(fid, ...
    'Generated: %s\n\n', ...
    datestr(now,'yyyy-mm-dd HH:MM'));

fprintf(fid,'## Model parameters\n\n');

fprintf(fid,'- Reference: %.3f mA\n',B.r);
fprintf(fid,'- Plant gain: %.10f mA/count\n',B.K);
fprintf(fid,'- Plant anchor: %.6f mA at Counter %.0f\n', ...
    B.I0,B.u0);
fprintf(fid,'- Nominal sampling period: %.4f s\n',B.Ts);
fprintf(fid,'- Deadband: +/-%.3f mA\n',B.deadband);
fprintf(fid,'- Global Counter maximum: %.0f\n',B.globalMax);
fprintf(fid,'- Feedforward-relative trim: +/-%.0f counts\n\n', ...
    B.trim);

fprintf(fid,'## Controller gains\n\n');

fprintf(fid,'| Controller | Kp | Ki |\n');
fprintf(fid,'|---|---:|---:|\n');

for j = 1:numel(B.names)

    fprintf(fid,'| %s | %.6f | %.6f |\n', ...
        B.names{j},B.Kp(j),B.Ki(j));

end

fprintf(fid,'\n## Full firmware-aware results\n\n');

fprintf(fid, ...
    '| Controller | 1%% settling (s) | Deadband settling (s) | Final current (mA) | DAC changes |\n');

fprintf(fid,'|---|---:|---:|---:|---:|\n');

for j = 1:numel(B.names)

    ix = find( ...
        metrics.Controller==string(B.names{j}) & ...
        metrics.Configuration=="Full firmware PI");

    fprintf(fid,'| %s | %.4f | %.4f | %.6f | %d |\n', ...
        B.names{j}, ...
        metrics.Settling1pct_s(ix), ...
        metrics.SettlingDeadband_s(ix), ...
        metrics.SteadyMean_mA(ix), ...
        metrics.TotalDACChanges(ix));

end

fprintf(fid,'\n## Settling verification\n\n');

fprintf(fid, ...
    ['Settling requires entry into the tolerance band, ' ...
     'remaining inside it, and at least %.2f s of ' ...
     'subsequent observation.\n\n'], ...
     minimumObservation_s);

fprintf(fid, ...
    ['Quantised-only responses that continue switching ' ...
     'across the deadband are reported as ' ...
     '"Not settled within 60 s".\n\n']);

fprintf(fid,'## Anti-windup stress verification\n\n');

fprintf(fid, ...
    'Synthetic current disturbance: %.3f mA from %.1f to %.1f s.\n\n', ...
    B.stressAmplitude,B.stressStart,B.stressEnd);

fprintf(fid, ...
    '| Configuration | Maximum integral (counts) | Time at upper limit (s) | Recovery (s) | Peak after removal (mA) |\n');

fprintf(fid,'|---|---:|---:|---:|---:|\n');

for q = 1:2

    fprintf(fid, ...
        '| %s | %.4f | %.4f | %.4f | %.6f |\n', ...
        labels(q), ...
        maximumIntegral(q), ...
        timeAtUpper(q), ...
        recoveryTime(q), ...
        peakAfterRemoval(q));

end

fprintf(fid,'\n## Verification status\n\n');

fprintf(fid,'- Normal Stage 2B recurrence: previously passed.\n');
fprintf(fid,'- Settling-status audit: passed.\n');
fprintf(fid,'- DAC movement accounting: passed.\n');
fprintf(fid,'- Applied command bounds: passed.\n');
fprintf(fid,'- One-burst command indexing: passed.\n');
fprintf(fid,'- Conditional anti-windup freeze: passed.\n');
fprintf(fid,'- Integral unwinding: passed.\n');
fprintf(fid,'- Recovery verification: passed.\n\n');

fprintf(fid,'## Known limitations\n\n');

fprintf(fid, ...
    ['Stage 2B uses a deterministic static plant, ' ...
     'fixed 82.5 ms timing and a constant 10 mA reference. ' ...
     'It excludes measurement noise, alternating 76/89 ms ' ...
     'feedback timing, physical voltage compliance, ' ...
     'and detailed analogue transients.\n\n']);

fprintf(fid, ...
    ['The synthetic anti-windup disturbance is a software ' ...
     'test and is not a measured hardware response.\n\n']);

fprintf(fid, ...
    ['No controller gains were modified. ' ...
     'All three candidates remain available for Stage 2C.\n']);

fclose(fid);

%% 15. Final report

fprintf('\n========================================\n');
fprintf('STAGE 2B FINAL VERIFICATION PASSED\n');
fprintf('========================================\n');

fprintf('Saved:\n');
fprintf('  Stage2B_performance_final.csv\n');
fprintf('  Stage2B_antiwindup_summary.csv\n');
fprintf('  Stage2B_final_verification.mat\n');
fprintf('  Stage2B_Verification_Checkpoint.md\n');

fprintf('\nOutput folder:\n%s\n',outputDir);

fprintf('\nNo Simulink models or figures were modified.\n');

%% ============================================================
% LOCAL FUNCTION: Settling audit
% ============================================================

function [ts,settled] = settlingAudit( ...
    t,y,target,tolerance,minObservation)

    t = double(t(:));
    y = double(y(:));

    ts = NaN;
    settled = false;

    assert(numel(t)==numel(y), ...
        'Settling time/data length mismatch.');

    assert(all(diff(t)>0), ...
        'Settling timestamps must be strictly increasing.');

    inside = abs(y-target)<=tolerance;

    % Last sample outside the tolerance
    lastBad = find(~inside,1,'last');

    if isempty(lastBad)

        firstGood = 1;

    elseif lastBad==numel(t)

        return;

    else

        firstGood = lastBad+1;

    end

    % Require meaningful observation time after entry.
    observedDuration = t(end)-t(firstGood);

    if observedDuration < minObservation
        return;
    end

    % All samples from this point to the end must be inside.
    if ~all(inside(firstGood:end))
        return;
    end

    ts = t(firstGood);
    settled = true;

end
