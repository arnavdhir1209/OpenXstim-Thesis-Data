
%% stage2B_run.m
% OpenXstim Stage 2B: Firmware-aware discrete PI comparison
%
% Updated version:
%   1. Progressive controller configurations
%   2. Sample-by-sample recurrence verification
%   3. Improved DAC movement metrics
%   4. Settling time within the firmware deadband
%   5. Clean, labelled figures
%   6. Automated anti-windup stress verification
%
% Does not modify Stage 1 or Stage 2A.
% Does not change controller gains or firmware equations.

close all force;

originalFigureVisibility = ...
    get(groot,'DefaultFigureVisible');

set(groot,'DefaultFigureVisible','off');

%% 1. Load configuration and model

if ~exist('B','var')
    stage2B_params;
end

if ~bdIsLoaded(B.model)
    load_system(B.model);
end

m = B.model;

set_param(m, ...
    'StopTime',num2str(B.stopTime,17));

assert( ...
    abs(str2double(get_param(m,'FixedStep'))-B.Ts)<1e-12, ...
    'Sampling period differs from Stage 2B configuration.');

N = numel(B.names);
C = size(B.features,1);

R = cell(N,C);
metrics = table();

%% 2. Normal experiments: No plant disturbance

assignin('base','B2B_disturbance', ...
    [0 0; B.stopTime+B.Ts 0]);

fprintf('\n========================================\n');
fprintf('STAGE 2B: PROGRESSIVE PI VERIFICATION\n');
fprintf('========================================\n');

for j = 1:N

    fprintf('\nController: %s\n',B.names{j});

    set_param([m '/Kp'], ...
        'Value',num2str(B.Kp(j),17));

    set_param([m '/Ki'], ...
        'Value',num2str(B.Ki(j),17));

    set_param([m '/Plant_gain'], ...
        'Value',num2str(B.K,17));

    for c = 1:C

        fprintf('  Configuration: %s\n', ...
            B.configNames{c});

        f = B.features(c,:);

        setFeatures(m,f);

        out = sim(m);

        R{j,c} = readOutput(out);

        %% Independent MATLAB recurrence comparison

        t = R{j,c}.current.t;

        D = referenceRun( ...
            B,j,f,t,zeros(numel(t),1));

        fields = { ...
            'current', ...
            'error', ...
            'adjusted_error', ...
            'p_term', ...
            'integral', ...
            'applied', ...
            'next', ...
            'clamped', ...
            'integral_frozen'};

        for q = 1:numel(fields)

            nm = fields{q};

            deviation = max(abs( ...
                R{j,c}.(nm).y-D.(nm)));

            assert( ...
                deviation<1e-7, ...
                '%s, config %d: %s mismatch: %.3g', ...
                B.names{j},c,nm,deviation);

        end

        %% Verify command timing

        a = R{j,c}.applied.y;
        n = R{j,c}.next.y;

        assert( ...
            abs(a(1)-B.u0)<1e-10, ...
            'Initial applied DAC Counter mismatch.');

        assert( ...
            all(abs(a(2:end)-n(1:end-1))<1e-7), ...
            'One-burst command delay violated.');

        %% Quantisation check

        if f(1)==1

            assert( ...
                all(a==round(a)), ...
                'Non-integer applied Counter.');

        end

        %% Command-bound check

        if f(3)==1

            ff = min(max( ...
                round(B.r*B.calibration),0), ...
                B.globalMax);

            lower = max(0,ff-B.trim);
            upper = min(B.globalMax,ff+B.trim);

            assert( ...
                all(a>=lower & a<=upper), ...
                'Applied command outside firmware bounds.');

        end

        %% First update check

        assert( ...
            abs(R{j,c}.integral.y(1))<1e-10, ...
            'First integral update was not skipped.');

        %% Calculate performance metrics

        metrics = [metrics; ...
            metricsRow(B,R{j,c},j,c)]; %#ok<AGROW>

    end
end

%% 3. Stage 2A ideal regression test

base = metrics(metrics.Configuration=="Ideal",:);

fprintf('\n========================================\n');
fprintf('STAGE 2A IDEAL REGRESSION CHECK\n');
fprintf('========================================\n');

disp(base(:,{ ...
    'Controller', ...
    'Settling1pct_s', ...
    'SettlingDeadband_s', ...
    'FullRMSE_mA'}));

expected = [10.8075 6.6825 3.3825];

for j = 1:N

    ix = base.Controller==string(B.names{j});

    assert( ...
        abs(base.Settling1pct_s(ix)-expected(j)) ...
        <B.Ts*1.01, ...
        'Stage 2A settling-time regression failed.');

end

fprintf('PASS: Stage 2A settling times reproduced.\n');

%% 4. Figure 1: Ideal vs firmware-aware response

f1 = figure( ...
    'Color','w', ...
    'Name','2B Ideal vs Firmware PI', ...
    'Position',[100 100 1050 750]);

tiledlayout(3,1,'TileSpacing','compact');

for j = 1:N

    nexttile;
    hold on;

    plot( ...
        R{j,1}.current.t, ...
        R{j,1}.current.y, ...
        'LineWidth',1.4, ...
        'DisplayName','Ideal');

    stairs( ...
        R{j,end}.current.t, ...
        R{j,end}.current.y, ...
        'LineWidth',1.1, ...
        'DisplayName','Firmware-aware');

    yline(B.r,'k:', ...
        'DisplayName','10 mA reference');

    ylabel('Current (mA)');
    title(B.names{j});

    grid on;
    box on;

    if j==1
        legend('Location','southeast');
    end

    if j==N
        xlabel('Time (s)');
    end

end

%% 5. Figure 2: Integer DAC commands

f2 = figure( ...
    'Color','w', ...
    'Name','2B Integer DAC Behaviour', ...
    'Position',[120 90 1050 680]);

tiledlayout(2,1,'TileSpacing','compact');

for panel = 1:2

    nexttile;
    hold on;

    for j = 1:N

        stairs( ...
            R{j,end}.applied.t, ...
            R{j,end}.applied.y, ...
            'LineWidth',1.2, ...
            'DisplayName',B.names{j});

    end

    ylabel('Applied DAC Counter');

    grid on;
    box on;

    if panel==1

        title('Full 60-second response');

        legend('Location','best');

    else

        xlim([B.stopTime-B.finalWindow B.stopTime]);

        title('Steady-state DAC behaviour');

        xlabel('Time (s)');

        legend('Location','best');

    end

end

%% 6. Figure 3: Steady-state current and deadband

f3 = figure( ...
    'Color','w', ...
    'Name','2B Steady State and Deadband', ...
    'Position',[130 90 1050 550]);

hold on;

for j = 1:N

    stairs( ...
        R{j,end}.current.t, ...
        R{j,end}.current.y, ...
        'LineWidth',1.3, ...
        'DisplayName',B.names{j});

end

% Explicitly labelled reference lines

yline( ...
    B.r,'k--', ...
    'DisplayName','10 mA reference');

yline( ...
    B.r+B.deadband,'k:', ...
    'DisplayName','Upper deadband (+0.03 mA)');

yline( ...
    B.r-B.deadband,'k:', ...
    'DisplayName','Lower deadband (-0.03 mA)');

xlim([B.stopTime-B.finalWindow B.stopTime]);

xlabel('Time (s)');
ylabel('Current (mA)');

title('Steady-state Current and Firmware Deadband');

legend('Location','best');

grid on;
box on;

%% 7. Synthetic saturation experiment

fprintf('\n========================================\n');
fprintf('ANTI-WINDUP STRESS EXPERIMENT\n');
fprintf('========================================\n');

% Temporary additive current disturbance.
% NOT physical voltage-compliance saturation.

assignin('base','B2B_disturbance',[ ...
    0,0;
    B.stressStart,B.stressAmplitude;
    B.stressEnd,0;
    B.stopTime+B.Ts,0]);

% Use the moderately faster controller
stressController = 3;

set_param([m '/Kp'], ...
    'Value',num2str(B.Kp(stressController),17));

set_param([m '/Ki'], ...
    'Value',num2str(B.Ki(stressController),17));

set_param([m '/Plant_gain'], ...
    'Value',num2str(B.K,17));

stress = cell(2,1);

for q = 1:2

    % q=1: Anti-windup disabled
    % q=2: Anti-windup enabled
    %
    % Both retain quantisation, deadband and command limits.

    f = [1 1 1 (q==2)];

    setFeatures(m,f);

    stress{q} = readOutput(sim(m));

    t = stress{q}.current.t;

    disturbance = B.stressAmplitude * ...
        double(t>=B.stressStart & t<B.stressEnd);

    %% Independent stress recurrence

    D = referenceRun( ...
        B,stressController,f,t,disturbance);

    stressFields = { ...
        'current', ...
        'error', ...
        'adjusted_error', ...
        'p_term', ...
        'integral', ...
        'applied', ...
        'next', ...
        'clamped', ...
        'integral_frozen'};

    for k = 1:numel(stressFields)

        nm = stressFields{k};

        deviation = max(abs( ...
            stress{q}.(nm).y-D.(nm)));

        assert( ...
            deviation<1e-7, ...
            'Stress experiment %d: %s mismatch.', ...
            q,nm);

    end

end

%% 8. Automated anti-windup verification

fprintf('\nANTI-WINDUP VERIFICATION\n');

noAW = stress{1};
withAW = stress{2};

t = withAW.current.t;

stressWindow = ...
    t>=B.stressStart & t<B.stressEnd;

recoveryWindow = t>=B.stressEnd;

ff = min(max( ...
    round(B.r*B.calibration),0), ...
    B.globalMax);

lower = max(0,ff-B.trim);
upper = min(B.globalMax,ff+B.trim);

%% Test 1: Both configurations respect limits

assert( ...
    all(noAW.applied.y>=lower & ...
        noAW.applied.y<=upper), ...
    'No-AW command violates limits.');

assert( ...
    all(withAW.applied.y>=lower & ...
        withAW.applied.y<=upper), ...
    'AW command violates limits.');

fprintf('PASS: Both configurations respect output limits.\n');

%% Test 2: Both actually reach saturation

assert( ...
    any(noAW.applied.y(stressWindow)==upper), ...
    'No-AW controller never reached saturation.');

assert( ...
    any(withAW.applied.y(stressWindow)==upper), ...
    'AW controller never reached saturation.');

fprintf('PASS: Both configurations reached upper saturation.\n');

%% Test 3: Anti-windup freeze activates

assert( ...
    any(withAW.integral_frozen.y(stressWindow)>0.5), ...
    'Anti-windup freeze never activated.');

assert( ...
    ~any(noAW.integral_frozen.y>0.5), ...
    'Freeze activated with anti-windup disabled.');

fprintf('PASS: Conditional integral freeze activated.\n');

%% Test 4: Integral accumulation comparison

peakNoAW = max(noAW.integral.y(stressWindow));
peakAW = max(withAW.integral.y(stressWindow));

assert( ...
    peakNoAW>peakAW, ...
    'Anti-windup did not reduce integral accumulation.');

fprintf('Peak integral without AW: %.3f counts\n', ...
    peakNoAW);

fprintf('Peak integral with AW:    %.3f counts\n', ...
    peakAW);

%% Test 5: Integral unwinding

xRecovery = withAW.integral.y(recoveryWindow);

assert( ...
    any(diff(xRecovery)<-1e-9), ...
    'AW integrator did not unwind.');

fprintf('PASS: Integral unwinding observed.\n');

%% Test 6: Recovery after disturbance removal

tNo = noAW.current.t(recoveryWindow);
yNo = noAW.current.y(recoveryWindow);

tAW = withAW.current.t(recoveryWindow);
yAW = withAW.current.y(recoveryWindow);

recoveryNoAW = settlingTimeLocal( ...
    tNo,yNo,B.r,B.deadband);

recoveryAW = settlingTimeLocal( ...
    tAW,yAW,B.r,B.deadband);

assert( ...
    isfinite(recoveryNoAW), ...
    'No-AW controller did not recover.');

assert( ...
    isfinite(recoveryAW), ...
    'AW controller did not recover.');

assert( ...
    recoveryAW<recoveryNoAW, ...
    'Anti-windup did not improve recovery time.');

fprintf('Recovery with AW: %.3f s\n', ...
    recoveryAW-B.stressEnd);

fprintf('Recovery without AW: %.3f s\n', ...
    recoveryNoAW-B.stressEnd);

fprintf('PASS: Anti-windup stress verification completed.\n');

%% 9. Figure 4: Anti-windup validation

f4 = figure( ...
    'Color','w', ...
    'Name','2B Anti-windup Stress Test', ...
    'Position',[150 90 1050 850]);

labels = { ...
    'No anti-windup', ...
    'Conditional anti-windup'};

fields = {'current','applied','integral'};

titles = { ...
    'Current Response During Saturation and Recovery', ...
    'Applied DAC Command with Software Limits', ...
    'Integral Accumulation and Anti-windup Behaviour'};

ylabels = { ...
    'Current (mA)', ...
    'Applied Counter', ...
    'Integral State (counts)'};

tiledlayout(3,1,'TileSpacing','compact');

for k = 1:3

    nexttile;
    hold on;

    for q = 1:2

        stairs( ...
            stress{q}.(fields{k}).t, ...
            stress{q}.(fields{k}).y, ...
            'LineWidth',1.2, ...
            'DisplayName',labels{q});

    end

    % Disturbance interval markers
    xline(B.stressStart,'k:', ...
        'HandleVisibility','off');

    xline(B.stressEnd,'k:', ...
        'HandleVisibility','off');

    if k==1

        yline(B.r,'k--', ...
            'DisplayName','10 mA reference');

    elseif k==2

        yline(upper,'k:', ...
            'HandleVisibility','off');

    end

    title(titles{k});
    ylabel(ylabels{k});

    if k==1
        legend('Location','best');
    end

    if k==3
        xlabel('Time (s)');
    end

    grid on;
    box on;

end

%% 10. Report final firmware-aware metrics

fprintf('\n========================================\n');
fprintf('FULL FIRMWARE CONTROLLER RESULTS\n');
fprintf('========================================\n');

fullRows = metrics( ...
    metrics.Configuration=="Full firmware PI",:);

disp(fullRows(:,{ ...
    'Controller', ...
    'Kp', ...
    'Ki', ...
    'Settling1pct_s', ...
    'SettlingDeadband_s', ...
    'SteadyMean_mA', ...
    'SteadyBias_mA', ...
    'TotalDACMovement', ...
    'PositiveDACMovement', ...
    'NegativeDACMovement', ...
    'TotalDACChanges', ...
    'MaxDACStep'}));

fprintf('\nAll progressive configurations:\n');

disp(metrics);

%% 11. Export results

writetable(metrics, ...
    fullfile(B.outputDir,'Stage2B_performance.csv'));

figs = {f1,f2,f3,f4};

filenames = { ...
    'Stage2B_Fig1_Ideal_vs_Firmware.png', ...
    'Stage2B_Fig2_Integer_DAC.png', ...
    'Stage2B_Fig3_Steady_State.png', ...
    'Stage2B_Fig4_AntiWindup.png'};

% Diagnostic: disable figure exports

% for q = 1:numel(figs)
%
%     exportgraphics( ...
%         figs{q}, ...
%         fullfile(B.outputDir,filenames{q}), ...
%         'Resolution',200);
%
% end

fprintf('DEBUG: Figure export skipped successfully.\n');

fprintf('DEBUG: Starting MAT file save.\n');
drawnow;

save( ...
    fullfile(B.outputDir,'Stage2B_results.mat'), ...
    'B','R','stress','metrics', ...
    'recoveryAW','recoveryNoAW');

fprintf('DEBUG: MAT file save completed.\n');
drawnow;

%% 12. Restore neutral model configuration

assignin('base','B2B_disturbance', ...
    [0 0;B.stopTime+B.Ts 0]);

setFeatures(m,[0 0 0 0]);

set_param([m '/Kp'], ...
    'Value',num2str(B.Kp(1),17));

set_param([m '/Ki'], ...
    'Value',num2str(B.Ki(1),17));

set_param([m '/Plant_gain'], ...
    'Value',num2str(B.K,17));

fprintf('\n========================================\n');
fprintf('STAGE 2B VERIFICATION COMPLETED\n');
fprintf('========================================\n');

fprintf('PASS: All %d normal configurations verified.\n', ...
    N*C);

fprintf('PASS: Anti-windup stress verification completed.\n');

fprintf('Results saved in:\n%s\n',B.outputDir);

fprintf('DEBUG: Model settings restored.\n');
fprintf('DEBUG: Stage 2B runner reached the final line.\n');

set(groot,'DefaultFigureVisible', ...
    originalFigureVisibility);

%% ============================================================
% LOCAL HELPER FUNCTIONS
% ============================================================

function setFeatures(m,f)

    names = { ...
        'Enable_round', ...
        'Enable_deadband', ...
        'Enable_limits', ...
        'Enable_antiwindup'};

    for k = 1:4

        set_param( ...
            [m '/' names{k}], ...
            'Value',num2str(f(k)));

    end

end

%% Read Simulink outputs

function X = readOutput(out)

    fields = { ...
        'current', ...
        'error', ...
        'adjusted_error', ...
        'p_term', ...
        'integral', ...
        'applied', ...
        'next', ...
        'clamped', ...
        'integral_frozen'};

    X = struct();

    for k = 1:numel(fields)

        nm = fields{k};

        ts = out.get(['s2b_' nm]);

        X.(nm).t = double(ts.Time(:));
        X.(nm).y = double(ts.Data(:));

    end

end

%% Independent reference recurrence

function D = referenceRun(B,j,f,t,dist)

    N = numel(t);

    u = B.u0;
    x = B.x0;

    fields = { ...
        'current', ...
        'error', ...
        'adjusted_error', ...
        'p_term', ...
        'integral', ...
        'applied', ...
        'next', ...
        'clamped', ...
        'integral_frozen'};

    D = struct();

    for k = 1:numel(fields)

        D.(fields{k}) = zeros(N,1);

    end

    for k = 1:N

        applied = u;

        [I,e,ed,p,xNew,uNext,~,~,clamped,frozen] = ...
            stage2B_step( ...
                u,x,k-1, ...
                B.Kp(j),B.Ki(j), ...
                B.K,B.I0,B.u0, ...
                B.r,B.Ts, ...
                B.calibration, ...
                B.globalMax, ...
                B.trim,B.deadband, ...
                f(1),f(2),f(3),f(4), ...
                dist(k));

        vals = [ ...
            I,e,ed,p,xNew,applied,uNext, ...
            double(clamped),double(frozen)];

        for q = 1:numel(fields)

            D.(fields{q})(k) = vals(q);

        end

        % Next command applied during following burst
        u = uNext;
        x = xNew;

    end

end

%% Performance metrics

function row = metricsRow(B,Q,j,c)

    y = Q.current.y(:);
    t = Q.current.t(:);
    u = Q.applied.y(:);

    e = B.r-y;

    %% Steady-state observation interval

    win = t>=B.stopTime-B.finalWindow;

    yc = y(win);
    uc = u(win);

    %% Settling times

    settling1 = settlingTimeLocal( ...
        t,y,B.r,0.01*B.r);

    settlingDB = settlingTimeLocal( ...
        t,y,B.r,B.deadband);

    %% Current tracking performance

    overshoot = max(0,max(y)-B.r);

    fullRMSE = sqrt(mean(e.^2));

    steadyMean = mean(yc);
    steadyBias = steadyMean-B.r;

    steadyRMSE = sqrt(mean((yc-B.r).^2));

    steadyPeakPeak = max(yc)-min(yc);

    %% DAC command movement

    du = diff(u);

    positiveMovement = sum(du(du>0));

    negativeMovement = -sum(du(du<0));

    totalMovement = sum(abs(du));

    netMovement = u(end)-u(1);

    totalChanges = sum(du~=0);

    if isempty(du)
        maxStep = 0;
    else
        maxStep = max(abs(du));
    end

    %% Verify DAC movement accounting

    assert( ...
        abs(positiveMovement-negativeMovement-netMovement) ...
        <1e-8, ...
        'DAC movement accounting failed.');

    assert( ...
        abs(totalMovement- ...
        (positiveMovement+negativeMovement))<1e-8, ...
        'Total DAC movement accounting failed.');

    %% Steady-state switching

    steadyChanges = sum(diff(uc)~=0);

    changeRate = steadyChanges/B.finalWindow;

    % Integer DAC codes are undefined in ideal mode.
    if B.features(c,1)==1

        distinctCodes = numel(unique(uc));

    else

        distinctCodes = NaN;

    end

    %% Assemble result table

    row = table( ...
        string(B.names{j}), ...
        string(B.configNames{c}), ...
        B.Kp(j),B.Ki(j), ...
        settling1, ...
        settlingDB, ...
        overshoot, ...
        fullRMSE, ...
        steadyMean, ...
        steadyBias, ...
        steadyRMSE, ...
        steadyPeakPeak, ...
        distinctCodes, ...
        steadyChanges, ...
        changeRate, ...
        positiveMovement, ...
        negativeMovement, ...
        totalMovement, ...
        netMovement, ...
        totalChanges, ...
        maxStep, ...
        min(u),max(u), ...
        'VariableNames',{ ...
            'Controller', ...
            'Configuration', ...
            'Kp', ...
            'Ki', ...
            'Settling1pct_s', ...
            'SettlingDeadband_s', ...
            'Overshoot_mA', ...
            'FullRMSE_mA', ...
            'SteadyMean_mA', ...
            'SteadyBias_mA', ...
            'SteadyRMSE_mA', ...
            'SteadyPeakPeak_mA', ...
            'SteadyDistinctCodes', ...
            'SteadyChanges', ...
            'ChangesPerSecond', ...
            'PositiveDACMovement', ...
            'NegativeDACMovement', ...
            'TotalDACMovement', ...
            'NetDACMovement', ...
            'TotalDACChanges', ...
            'MaxDACStep', ...
            'MinCommand', ...
            'MaxCommand'});

end

%% Entry-and-remain settling-time calculation

function ts = settlingTimeLocal(t,y,target,tolerance)

    t = t(:);
    y = y(:);

    outside = abs(y-target)>tolerance;

    lastBad = find(outside,1,'last');

    if isempty(lastBad)

        ts = t(1);

    elseif lastBad==numel(t)

        ts = NaN;

    else

        ts = t(lastBad+1);

    end

end
