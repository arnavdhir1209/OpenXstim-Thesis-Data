
%% stage2A_run.m
% Stage 2A: Ideal discrete PI controller comparison
%
% Includes:
%  Figure 1: Current tracking
%  Figure 2: DAC command and integral action
%  Figure 3: Pole plot with magnified dominant-pole inset
%
% Does not modify the Stage 1 model.

if ~exist('S2','var')
    stage2A_params;
end

if ~bdIsLoaded(S2.model)
    load_system(S2.model);
end

stage2A_math_check;

m = S2.model;

set_param(m,'StopTime',num2str(S2.stopTime,17));

nC = numel(S2.names);

R = cell(nC,1);
comparisons = table();

% Store poles for the pole-location figure
allPoles = cell(nC,1);

%% 1. Run nominal simulations

for j = 1:nC

    set_param([m '/Kp'], ...
        'Gain',num2str(S2.Kp(j),17));

    set_param([m '/KiTs'], ...
        'Gain',num2str(S2.Ki(j)*S2.Ts,17));

    set_param([m '/Plant_gain'], ...
        'Gain',num2str(S2.K,17));

    out = sim(m);

    R{j} = readSignals(out);

    %% Independent discrete recurrence

    D = directSimulation( ...
        S2,S2.Kp(j),S2.Ki(j),S2.K, ...
        numel(R{j}.current.y));

    assert(max(abs( ...
        R{j}.current.y-D.current))<1e-7, ...
        'Current response mismatch.');

    assert(max(abs( ...
        R{j}.applied.y-D.applied))<1e-7, ...
        'DAC command indexing mismatch.');

    assert(max(abs( ...
        R{j}.integral.y-D.integral))<1e-7, ...
        'Integral update mismatch.');

    %% Verify one-burst command latency

    a = R{j}.applied.y;
    n = R{j}.next.y;

    assert(all(abs(a(2:end)-n(1:end-1))<1e-7), ...
        'One-burst command indexing failed.');

    assert(abs(R{j}.integral.y(1))<1e-10, ...
        'First integral update was not skipped.');

    %% Calculate performance

    t = R{j}.current.t;
    y = R{j}.current.y;
    u = R{j}.applied.y;

    e = S2.r-y;

    settling1 = settlingTime(t,y,S2.r,0.01);
    settling01 = settlingTime(t,y,S2.r,0.001);

    overshoot = max(0,max(y)-S2.r);

    rmse = sqrt(mean(e.^2));
    iae = sum(abs(e))*S2.Ts;

    kp = S2.Kp(j);
    ki = S2.Ki(j);
    K = S2.K;

    A = [
        -K*(kp+ki*S2.Ts), 1;
        -K*ki*S2.Ts,      1
    ];

    poles = sort(eig(A));
    allPoles{j} = poles;

    comparisons = [comparisons;table( ...
        string(S2.names{j}),kp,ki, ...
        poles(1),poles(2), ...
        settling1,settling01, ...
        overshoot,min(u),max(u), ...
        rmse,iae,y(end), ...
        'VariableNames',{ ...
        'Controller','Kp','Ki', ...
        'Pole1','Pole2', ...
        'Settling1pct_s','Settling0p1pct_s', ...
        'Overshoot_mA', ...
        'MinCounter','MaxCounter', ...
        'RMSE_mA','IAE_mA_s', ...
        'FinalCurrent_mA'})]; %#ok<AGROW>

end

%% 2. Restore empirical controller gains

set_param([m '/Kp'], ...
    'Gain',num2str(S2.Kp(1),17));

set_param([m '/KiTs'], ...
    'Gain',num2str(S2.Ki(1)*S2.Ts,17));

%% 3. Figure 1: Current tracking

f1 = figure( ...
    'Color','w', ...
    'Name','Stage 2A Current Tracking', ...
    'Position',[100 100 1000 550]);

hold on;

for j = 1:nC

    plot( ...
        R{j}.current.t, ...
        R{j}.current.y, ...
        'LineWidth',1.6, ...
        'DisplayName',S2.names{j});

end

yline(S2.r,'k--', ...
    'DisplayName','10 mA reference');

xlabel('Time (s)');
ylabel('Burst-averaged current (mA)');

title('Ideal Discrete PI Current Regulation');

legend('Location','southeast');
grid on;
box on;

%% 4. Figure 2: Control effort

f2 = figure( ...
    'Color','w', ...
    'Name','Stage 2A Control Effort', ...
    'Position',[120 120 1000 700]);

tiledlayout(2,1,'TileSpacing','compact');

nexttile;
hold on;

for j = 1:nC

    stairs( ...
        R{j}.applied.t, ...
        R{j}.applied.y, ...
        'LineWidth',1.3, ...
        'DisplayName',S2.names{j});

end

ylabel('Applied DAC Counter');
title('Control Effort');
legend('Location','southeast');
grid on;
box on;

nexttile;
hold on;

for j = 1:nC

    plot( ...
        R{j}.integral.t, ...
        R{j}.integral.y, ...
        'LineWidth',1.3, ...
        'DisplayName',S2.names{j});

end

xlabel('Time (s)');
ylabel('Integral state (counts)');

grid on;
box on;

%% 5. Figure 3: Pole plot with magnified inset

f3 = figure( ...
    'Color','w', ...
    'Name','Stage 2A Closed-Loop Poles', ...
    'Position',[150 100 1100 700]);

% Consistent colours and symbols for all controllers
colors = lines(nC);
markers = {'o','s','d'};

% Main axes positioned to leave room for the inset
axMain = axes( ...
    'Parent',f3, ...
    'Position',[0.09 0.12 0.77 0.78]);

hold(axMain,'on');

% Draw unit circle
theta = linspace(0,2*pi,500);

plot(axMain, ...
    cos(theta),sin(theta), ...
    'k--','LineWidth',1.1, ...
    'DisplayName','Unit circle');

% Plot both poles for each controller
for j = 1:nC

    poles = allPoles{j};

    plot(axMain, ...
        real(poles),imag(poles), ...
        markers{j}, ...
        'Color',colors(j,:), ...
        'MarkerEdgeColor',colors(j,:), ...
        'MarkerFaceColor','w', ...
        'MarkerSize',9, ...
        'LineWidth',1.8, ...
        'DisplayName',S2.names{j});

end

axis(axMain,'equal');

xlim(axMain,[-1.10 1.10]);
ylim(axMain,[-1.10 1.10]);

xlabel(axMain,'Real(z)');
ylabel(axMain,'Imag(z)');

title(axMain, ...
    'Discrete-Time Closed-Loop Pole Locations');

legend(axMain, ...
    'Location','southwest');

grid(axMain,'on');
box(axMain,'on');

%% 5A. Highlight inset region on the main plot

% The inset focuses on the dominant positive poles.
% Draw a small rectangle around this portion of the real axis.

rectangle(axMain, ...
    'Position',[0.958 -0.025 0.052 0.05], ...
    'EdgeColor',[0.3 0.3 0.3], ...
    'LineStyle',':', ...
    'LineWidth',1.2);

%% 5B. Create magnified inset axes

% Inset position is specified in normalised figure coordinates.
% Change this one vector if you want to reposition the inset.

insetPosition = [0.46 0.48 0.39 0.28];

axInset = axes( ...
    'Parent',f3, ...
    'Units','normalized', ...
    'Position',insetPosition, ...
    'Color','w', ...
    'Box','on', ...
    'LineWidth',1.1);

hold(axInset,'on');

% Stability boundary at z = 1
xline(axInset,1, ...
    'k--', ...
    'LineWidth',1.1);

% Horizontal real axis
yline(axInset,0, ...
    'Color',[0.65 0.65 0.65], ...
    'LineWidth',0.8);

%% Plot dominant poles in inset

for j = 1:nC

    poles = allPoles{j};

    % Dominant pole is the one with largest magnitude.
    [~,idx] = max(abs(poles));

    pDominant = poles(idx);

    plot(axInset, ...
        real(pDominant),imag(pDominant), ...
        markers{j}, ...
        'Color',colors(j,:), ...
        'MarkerEdgeColor',colors(j,:), ...
        'MarkerFaceColor',colors(j,:), ...
        'MarkerSize',8, ...
        'LineWidth',1.5);

    % Annotate pole with its value
    % Vertical offsets prevent labels overlapping.
    offsets = [0.006, 0.003, -0.004];

    text(axInset, ...
        real(pDominant)+0.0005, ...
        offsets(j), ...
        sprintf('%.5f',real(pDominant)), ...
        'Color',colors(j,:), ...
        'FontSize',9, ...
        'FontWeight','bold', ...
        'HorizontalAlignment','center');

end

% Zoom around positive dominant poles
xlim(axInset,[0.960 1.005]);
ylim(axInset,[-0.012 0.012]);

xticks(axInset,0.96:0.01:1.00);
yticks(axInset,[-0.01 0 0.01]);

xlabel(axInset,'Real(z)','FontSize',9);

title(axInset, ...
    'Dominant Poles (Magnified)', ...
    'FontSize',10, ...
    'FontWeight','bold');

set(axInset, ...
    'FontSize',9, ...
    'Layer','top');

grid(axInset,'on');

% Keep the inset visually above the main axes.
uistack(axInset,'top');

%% 6. Export performance results

disp(comparisons);

writetable(comparisons, ...
    fullfile(S2.outputDir, ...
    'Stage2A_performance.csv'));

exportgraphics(f1, ...
    fullfile(S2.outputDir, ...
    'Stage2A_Fig1_Current.png'), ...
    'Resolution',200);

exportgraphics(f2, ...
    fullfile(S2.outputDir, ...
    'Stage2A_Fig2_Control.png'), ...
    'Resolution',200);

exportgraphics(f3, ...
    fullfile(S2.outputDir, ...
    'Stage2A_Fig3_Poles.png'), ...
    'Resolution',300);

% Vector PDF for thesis or LaTeX inclusion
exportgraphics(f3, ...
    fullfile(S2.outputDir, ...
    'Stage2A_Fig3_Poles.pdf'), ...
    'ContentType','vector');

%% 7. Gain-only sensitivity analysis

sensitivity = table();

for g = 1:numel(S2.Kcases)

    K = S2.Kcases(g);

    for j = 1:nC

        kp = S2.Kp(j);
        ki = S2.Ki(j);

        A = [
            -K*(kp+ki*S2.Ts), 1;
            -K*ki*S2.Ts,      1
        ];

        poles = eig(A);

        N = floor(S2.stopTime/S2.Ts)+1;

        D = directSimulation(S2,kp,ki,K,N);

        t = (0:N-1)'*S2.Ts;

        sensitivity = [sensitivity;table( ...
            K,string(S2.names{j}), ...
            max(abs(poles)), ...
            all(abs(poles)<1), ...
            settlingTime(t,D.current,S2.r,0.01), ...
            max(0,max(D.current)-S2.r), ...
            'VariableNames',{ ...
            'PlantGain','Controller', ...
            'MaxPoleMagnitude','Stable', ...
            'Settling1pct_s','Overshoot_mA'})]; %#ok<AGROW>

    end

end

writetable(sensitivity, ...
    fullfile(S2.outputDir, ...
    'Stage2A_gain_sensitivity.csv'));

save(fullfile(S2.outputDir,'Stage2A_results.mat'), ...
    'S2','R','comparisons','sensitivity','allPoles');

fprintf('\nStage 2A results saved in:\n%s\n', ...
    S2.outputDir);

%% Local helper functions

function Q = readSignals(out)

    names = {
        's2_reference'
        's2_current'
        's2_error'
        's2_applied'
        's2_next'
        's2_p'
        's2_integral'
    };

    fields = {
        'reference'
        'current'
        'error'
        'applied'
        'next'
        'p'
        'integral'
    };

    Q = struct();

    for ii = 1:numel(names)

        ts = out.get(names{ii});

        Q.(fields{ii}) = struct( ...
            't',double(ts.Time(:)), ...
            'y',double(ts.Data(:)));

    end

end

function D = directSimulation(S,kp,ki,K,N)

    u = S.u0;
    x = S.x0;

    D.current = zeros(N,1);
    D.applied = zeros(N,1);
    D.integral = zeros(N,1);

    for ii = 1:N

        y = S.I0+K*(u-S.u0);
        e = S.r-y;

        xNew = x;

        % Skip initial integral update
        if ii>1
            xNew = x+ki*S.Ts*e;
        end

        % Current update determines next command
        uNext = S.ff+kp*e+xNew;

        D.current(ii) = y;
        D.applied(ii) = u;
        D.integral(ii) = xNew;

        u = uNext;
        x = xNew;

    end

end

function ts = settlingTime(t,y,target,tolerance)

    inside = abs(y-target)<=tolerance*abs(target);

    lastBad = find(~inside,1,'last');

    if isempty(lastBad)

        ts = t(1);

    elseif lastBad==numel(t)

        ts = NaN;

    else

        ts = t(lastBad+1);

    end

end
