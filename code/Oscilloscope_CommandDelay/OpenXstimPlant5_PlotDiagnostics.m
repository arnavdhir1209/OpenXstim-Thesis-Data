function OpenXstimPlant5_PlotDiagnostics(staticResult,fastResult,slowResult,cfg)
% OpenXstimPlant5_PlotDiagnostics
%
% Keeps Stage 5 output compact:
%   01_MasterPerCurrentSummary.png
%   02_Current_5mA.png
%   ...
%   07_Current_50mA.png
%   08_HighCurrentNearZeroSpecialCase.png
%   09_ComplianceStateDiagnostics.png

currents = cfg.COMMAND_CURRENTS_mApp(:);

% Resolve the Stage 5 delay summary from fastResult.
% This avoids relying on an undefined caller-workspace variable.
DelaySummary = resolveDelaySummary(fastResult,cfg);

%% ========================================================================
% FIGURE 1: MASTER SUMMARY
% ========================================================================

fig = figure( ...
    'Name','Stage 5 per-current plant summary', ...
    'Color','w');

tiledlayout(2,3,'TileSpacing','compact','Padding','compact');

% -------------------------------------------------------------------------
% Static current scale
% -------------------------------------------------------------------------
nexttile;
hold on;
grid on;
box on;

S = staticResult.currentSummary;

errorbar( ...
    S.CommandCurrent_mA, ...
    S.MeanMeasuredIpp_mA, ...
    S.SDMeasuredIpp_mA, ...
    'o-','LineWidth',1.3);

mx = max([currents;S.MeanMeasuredIpp_mA],[],'omitnan');

plot([0 mx],[0 mx],':','LineWidth',1);

xlabel('Commanded current (mA p-p)');
ylabel('Measured early current (mA p-p)');
title('Static current scale');
legend('Per-current mean +/- SD','1:1','Location','northwest');

% -------------------------------------------------------------------------
% Physical fast regimes
% -------------------------------------------------------------------------
nexttile;
grid on;
box on;

R = fastResult.regimeCounts;

bar( ...
    R.CommandCurrent_mA, ...
    [R.FullReversalN R.NearZeroStartN R.PartialReversalN], ...
    'stacked');

xlabel('Commanded current (mA p-p)');
ylabel('Fast events');
title('Physical fast-transition regimes');
legend( ...
    'Full reversal','Near-zero start','Partial reversal', ...
    'Location','northwest');

% -------------------------------------------------------------------------
% Fast 10-90
% -------------------------------------------------------------------------
nexttile;
hold on;
grid on;
box on;

% Draw connected regime lines.
xFR = [];
yFR = [];
xNZ = [];
yNZ = [];

for k = 1:numel(currents)

    I = currents(k);
    B = fastResult.byCurrent(k);

    if B.fullReversal.identifiable
        xFR(end+1,1) = I; %#ok<AGROW>
        yFR(end+1,1) = B.fullReversal.best.t10_90_us; %#ok<AGROW>
    end

    if B.nearZeroStart.identifiable
        xNZ(end+1,1) = I; %#ok<AGROW>
        yNZ(end+1,1) = B.nearZeroStart.best.t10_90_us; %#ok<AGROW>
    end
end

if ~isempty(xFR)
    plot(xFR,yFR,'o-','LineWidth',1.2);
end

if ~isempty(xNZ)
    plot(xNZ,yNZ,'s--','LineWidth',1.2);
end

xlabel('Commanded current (mA p-p)');
ylabel('Fitted 10-90 time (us)');
title('Local fast dynamics');

lg = strings(0,1);
if ~isempty(xFR), lg(end+1) = "FULL_REVERSAL"; end
if ~isempty(xNZ), lg(end+1) = "NEAR_ZERO_START"; end

if ~isempty(lg)
    legend(lg,'Location','best');
end

% -------------------------------------------------------------------------
% Local delay
% -------------------------------------------------------------------------
ax = nexttile;
plotDelaySummary(ax,DelaySummary);

% -------------------------------------------------------------------------
% Droop rate
% -------------------------------------------------------------------------
nexttile;
hold on;
grid on;
box on;

DR = slowResult.droopSummary;
m = DR.Identifiable;

plot( ...
    DR.CommandCurrent_mA(m), ...
    DR.Rate_per_ms(m), ...
    'o-','LineWidth',1.3);

xlabel('Commanded current (mA p-p)');
ylabel('Selected ordinary-droop rate (1/ms)');
title('Pre-collapse passive droop');

% -------------------------------------------------------------------------
% Collapse
% -------------------------------------------------------------------------
nexttile;
hold on;
grid on;
box on;

CR = slowResult.collapseSummary;

m = CR.Identifiable;

if any(m)

    plot( ...
        CR.CommandCurrent_mA(m), ...
        CR.CrossValidationRMSE(m), ...
        'o-','LineWidth',1.3);

    for q = find(m).'

        text( ...
            CR.CommandCurrent_mA(q), ...
            CR.CrossValidationRMSE(q), ...
            "  " + CR.SelectedCoordinate(q), ...
            'Interpreter','none', ...
            'FontSize',8);
    end
end

xlabel('Commanded current (mA p-p)');
ylabel('Held-out collapse RMSE');
title('Compliance-collapse model');

sgtitle('Stage 5 per-current OpenXstim plant identification');

saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"01_MasterPerCurrentSummary.png"),cfg);

%% ========================================================================
% FIGURES 2-7: ONE FIGURE PER CURRENT
% ========================================================================

for k = 1:numel(currents)

    I = currents(k);

    F = fastResult.byCurrent(k);
    S = slowResult.byCurrent(k);

    fig = figure( ...
        'Name',sprintf('Stage 5 %.0f mA p-p',I), ...
        'Color','w');

    tiledlayout(2,2,'TileSpacing','compact','Padding','compact');

    % ---------------------------------------------------------------------
    % Fast waveforms and fitted models
    % ---------------------------------------------------------------------
    nexttile;
    hold on;
    grid on;
    box on;

    t = fastResult.time_us;

    legendEntries = strings(0,1);

    if F.fullReversal.N>0 && ~isempty(F.fullReversal.meanWaveform)

        plot(t,F.fullReversal.meanWaveform,'LineWidth',1.3);
        legendEntries(end+1) = "FULL_REVERSAL mean"; %#ok<AGROW>

        if F.fullReversal.identifiable
            plot(t,fastCurve(F.fullReversal.best,t),'--','LineWidth',1.5);
            legendEntries(end+1) = "FULL_REVERSAL fit"; %#ok<AGROW>
        end
    end

    if F.nearZeroStart.N>0 && ~isempty(F.nearZeroStart.meanWaveform)

        plot(t,F.nearZeroStart.meanWaveform,'LineWidth',1.3);
        legendEntries(end+1) = "NEAR_ZERO_START mean"; %#ok<AGROW>

        if F.nearZeroStart.identifiable
            plot(t,fastCurve(F.nearZeroStart.best,t),'--','LineWidth',1.5);
            legendEntries(end+1) = "NEAR_ZERO_START fit"; %#ok<AGROW>
        end
    end

    if F.startupZeroToPos.N>0 && ~isempty(F.startupZeroToPos.meanWaveform)

        plot(t,F.startupZeroToPos.meanWaveform,':','LineWidth',1.4);
        legendEntries(end+1) = "literal 0 -> +I mean"; %#ok<AGROW>
    end

    xline(0,'--');

    yline(0.1,':');
    yline(0.5,':');
    yline(0.9,':');
    yline(1.0,':');

    xlim([cfg.FAST_FIT_START_US-4 cfg.FAST_FIT_END_US+4]);
    ylim([-0.15 1.15]);

    xlabel('Time from Stage 3 gradient peak (us)');
    ylabel('Normalized current');
    title(sprintf('%.0f mA p-p fast physical regimes',I));

    if ~isempty(legendEntries)
        legend(legendEntries,'Location','southeast');
    end

    % ---------------------------------------------------------------------
    % Fast candidate CV
    % ---------------------------------------------------------------------
    nexttile;
    grid on;
    box on;

    primary = [];

    if F.fullReversal.identifiable
        primary = F.fullReversal;
    elseif F.nearZeroStart.identifiable
        primary = F.nearZeroStart;
    end

    if ~isempty(primary)

        C = primary.candidateSummary;

        bar(categorical(C.Model),C.CrossValidationRMSE);

        ylabel('Held-out event RMSE');
        title(primary.label + " candidate models");

    else

        axis off;

        text( ...
            0.05,0.55, ...
            sprintf('No primary fast model identifiable at %.0f mA.',I), ...
            'Units','normalized', ...
            'FontSize',11);
    end

    % ---------------------------------------------------------------------
    % Slow phase, presentation comparison
    %
    % This panel is deliberately time-domain and presentation friendly.
    % It does NOT change the Stage 5 selected model.
    % ---------------------------------------------------------------------
    nexttile;
    hold on;
    grid on;
    box on;

    if S.droop.identifiable

        P = buildSlowPresentationFits(S);

        plot( ...
            P.time_ms, ...
            P.measured, ...
            'LineWidth',1.7, ...
            'DisplayName','Measured mean phase');

        plot( ...
            P.time_ms, ...
            P.linear, ...
            '--', ...
            'LineWidth',1.5, ...
            'DisplayName',sprintf('Linear droop, k = %.4f /ms',P.k_per_ms));

        plot( ...
            P.time_ms, ...
            P.exponential, ...
            ':', ...
            'LineWidth',1.6, ...
            'DisplayName','Exponential droop, same initial rate');

        if P.piecewiseAvailable

            plot( ...
                P.time_ms, ...
                P.piecewise, ...
                '-.', ...
                'LineWidth',1.7, ...
                'DisplayName','Piecewise linear + exponential');

            xline( ...
                P.changeTime_ms, ...
                ':', ...
                'Collapse knee', ...
                'HandleVisibility','off', ...
                'LabelVerticalAlignment','bottom');
        end

        xlabel('Time after passive-phase guard (ms)');
        ylabel('Normalized current D(t)');
        title('Slow-phase model comparison');

        xlim([0 max(P.time_ms)]);
        ylim([0 1.03]);

        legend('Location','best');

    else

        axis off;

        text( ...
            0.05,0.55, ...
            "Slow-phase model not identifiable: " + S.droop.reason, ...
            'Units','normalized', ...
            'Interpreter','none');
    end

    % ---------------------------------------------------------------------
    % Full slow-response presentation view
    %
    % For ordinary-droop-only currents, show the selected Stage 5 droop.
    % For compliance-affected currents, show a simple time-domain piecewise
    % approximation so the measured collapse is easy to interpret.
    %
    % The actual Stage 5 compliance-state model remains unchanged and is
    % moved to the separate diagnostic figure below.
    % ---------------------------------------------------------------------
    nexttile;
    hold on;
    grid on;
    box on;

    if S.droop.identifiable

        P = buildSlowPresentationFits(S);

        plot( ...
            P.time_ms, ...
            P.measured, ...
            'LineWidth',1.8, ...
            'DisplayName','Measured mean phase');

        if S.collapse.identifiable && P.piecewiseAvailable

            plot( ...
                P.time_ms, ...
                P.piecewise, ...
                '--', ...
                'LineWidth',2.0, ...
                'DisplayName','Piecewise presentation fit');

            plot( ...
                P.time_ms, ...
                P.linear, ...
                ':', ...
                'LineWidth',1.2, ...
                'DisplayName','Ordinary droop only');

            xline( ...
                P.changeTime_ms, ...
                ':', ...
                'Estimated collapse knee', ...
                'HandleVisibility','off', ...
                'LabelVerticalAlignment','bottom');

            title(sprintf( ...
                'Full slow response | collapse after %.3f ms', ...
                P.changeTime_ms));

        else

            plot( ...
                P.time_ms, ...
                droopCurve(S.droop.best,P.time_ms), ...
                '--', ...
                'LineWidth',2.0, ...
                'DisplayName','Selected Stage 5 droop model');

            title('Full slow response | no identified compliance model');
        end

        xlabel('Time after passive-phase guard (ms)');
        ylabel('Normalized current D(t)');

        xlim([0 max(P.time_ms)]);
        ylim([0 1.03]);

        legend('Location','best');

    else

        axis off;

        text( ...
            0.05,0.55, ...
            "Slow-phase response not identifiable: " + S.droop.reason, ...
            'Units','normalized', ...
            'Interpreter','none');
    end

    sgtitle(sprintf('Stage 5 local plant model | %.0f mA p-p',I));

    fileName = sprintf("%02d_Current_%02dmA.png",k+1,round(I));

    saveFigure( ...
        fig, ...
        fullfile(cfg.OUTPUT_FOLDER,fileName), ...
        cfg);
end

%% ========================================================================
% FIGURE 8: HIGH-CURRENT SPECIAL CASE
% ========================================================================

fig = figure( ...
    'Name','Stage 5 high-current near-zero-start special case', ...
    'Color','w');

tiledlayout(1,2,'TileSpacing','compact','Padding','compact');

highCurrents = [30 50];

for h = 1:numel(highCurrents)

    I = highCurrents(h);

    k = find(currents==I,1);

    nexttile;
    hold on;
    grid on;
    box on;

    if isempty(k)
        axis off;
        continue;
    end

    F = fastResult.byCurrent(k);

    leg = strings(0,1);

    if F.nearZeroStart.N>0

        plot( ...
            fastResult.time_us, ...
            F.nearZeroStart.meanWaveform, ...
            'LineWidth',1.5);

        leg(end+1) = sprintf('internal NEAR_ZERO_START N=%d',F.nearZeroStart.N); %#ok<AGROW>
    end

    if F.nearZeroStart.identifiable

        plot( ...
            fastResult.time_us, ...
            fastCurve(F.nearZeroStart.best,fastResult.time_us), ...
            '--','LineWidth',1.6);

        leg(end+1) = "near-zero selected fit"; %#ok<AGROW>
    end

    if F.startupZeroToPos.N>0

        plot( ...
            fastResult.time_us, ...
            F.startupZeroToPos.meanWaveform, ...
            ':','LineWidth',1.6);

        leg(end+1) = sprintf('literal 0 -> +I N=%d',F.startupZeroToPos.N); %#ok<AGROW>
    end

    xline(0,'--');
    yline(0.1,':');
    yline(0.5,':');
    yline(0.9,':');
    yline(1.0,':');

    xlim([cfg.FAST_FIT_START_US-4 cfg.FAST_FIT_END_US+4]);
    ylim([-0.15 1.15]);

    xlabel('Time from Stage 3 gradient peak (us)');
    ylabel('Normalized current');

    title(sprintf('%.0f mA p-p',I));

    if ~isempty(leg)
        legend(leg,'Location','southeast');
    end
end

sgtitle(sprintf([ ...
    'High-current special case: internal near-zero starts versus literal packet startup\n' ...
    'Do not merge their firmware-delay interpretation']));

saveFigure( ...
    fig, ...
    fullfile(cfg.OUTPUT_FOLDER,"08_HighCurrentNearZeroSpecialCase.png"), ...
    cfg);

%% ========================================================================
% FIGURE 9: COMPLIANCE-STATE DIAGNOSTICS
%
% This keeps the less intuitive charge-state representation available for
% engineering diagnosis without making it the main presentation graphic.
% ========================================================================

fig = figure( ...
    'Name','Stage 5 compliance-state diagnostics', ...
    'Color','w');

tiledlayout(2,3,'TileSpacing','compact','Padding','compact');

for k = 1:numel(currents)

    I = currents(k);
    S = slowResult.byCurrent(k);

    nexttile;
    hold on;
    grid on;
    box on;

    if S.collapse.identifiable

        x = S.collapse.diagnosticX(:);
        y = S.collapse.diagnosticObserved(:);

        good = isfinite(x) & isfinite(y);
        x = x(good);
        y = y(good);

        scatter( ...
            x,y,8,'filled', ...
            'MarkerFaceAlpha',0.18, ...
            'DisplayName','Observed collapse attenuation');

        [xs,~] = sort(x);

        plot( ...
            xs, ...
            collapseCurve(S.collapse.best,xs), ...
            'LineWidth',1.8, ...
            'DisplayName','Selected Stage 5 state model');

        xlabel( ...
            S.collapse.best.coordinate + " state (uC)", ...
            'Interpreter','none');

        ylabel('Collapse attenuation C');

        title(sprintf( ...
            '%.0f mA | %s', ...
            I,S.collapse.best.modelName), ...
            'Interpreter','none');

        ylim([0 1.05]);
        legend('Location','best');

    else

        axis off;

        text( ...
            0.5,0.55, ...
            sprintf('%.0f mA p-p\nNo identified compliance-collapse model',I), ...
            'HorizontalAlignment','center', ...
            'Units','normalized', ...
            'FontSize',11);
    end
end

sgtitle([ ...
    'Stage 5 compliance-collapse state diagnostics' newline ...
    'Diagnostic only: the per-current presentation plots use time-domain slow-response views']);

saveFigure( ...
    fig, ...
    fullfile(cfg.OUTPUT_FOLDER,"09_ComplianceStateDiagnostics.png"), ...
    cfg);

end

%% ========================================================================
% DELAY PLOT HELPERS
% ========================================================================

function T = resolveDelaySummary(fastResult,cfg)
% Find the Stage 5 delay-summary table without depending on a variable in
% the caller workspace.
%
% Required columns:
%   CommandCurrent_mA
%   FastRegime
%   TransitionClass
%   MeanTransportDelay_us

required = [ ...
    "CommandCurrent_mA", ...
    "FastRegime", ...
    "TransitionClass", ...
    "MeanTransportDelay_us"];

% First search everything already stored inside fastResult.
T = findRequiredTable(fastResult,required,0,8);

if ~isempty(T)
    return;
end

% Fallback: search delay CSVs already written to the Stage 5 output folder.
if isfield(cfg,"OUTPUT_FOLDER") && isfolder(cfg.OUTPUT_FOLDER)

    files = dir(fullfile(cfg.OUTPUT_FOLDER,"*Delay*.csv"));

    for k = 1:numel(files)

        try
            candidate = readtable(fullfile(files(k).folder,files(k).name));

            if all(ismember(required,string(candidate.Properties.VariableNames)))
                T = candidate;
                return;
            end

        catch
        end
    end
end

T = table();

warning( ...
    ['Could not locate the Stage 5 delay summary inside fastResult or the ' ...
     'Stage 5 output folder. The delay panel will be left empty.']);
end

function T = findRequiredTable(v,required,depth,maxDepth)

T = table();

if depth>maxDepth
    return;
end

if istable(v)

    names = string(v.Properties.VariableNames);

    if all(ismember(required,names))
        T = v;
    end

    return;
end

if isstruct(v)

    for n = 1:numel(v)

        fields = fieldnames(v(n));

        for k = 1:numel(fields)

            try
                child = v(n).(fields{k});
            catch
                continue;
            end

            T = findRequiredTable(child,required,depth+1,maxDepth);

            if ~isempty(T)
                return;
            end
        end
    end

elseif iscell(v)

    for k = 1:numel(v)

        T = findRequiredTable(v{k},required,depth+1,maxDepth);

        if ~isempty(T)
            return;
        end
    end
end
end

function plotDelaySummary(ax,T)

cla(ax);
hold(ax,'on');
grid(ax,'on');
box(ax,'on');

if isempty(T) || height(T)==0

    axis(ax,[0 1 0 1]);

    text( ...
        ax,0.5,0.5, ...
        'Delay summary table not found', ...
        'HorizontalAlignment','center', ...
        'FontWeight','bold');

    title(ax,'Delay identified locally');
    hold(ax,'off');
    return;
end

fastRegime = string(T.FastRegime);
transitionClass = string(T.TransitionClass);

% Clean full reversal: +I -> -I
plotDelaySeries( ...
    ax,T, ...
    fastRegime=="FULL_REVERSAL" & transitionClass=="pos_to_neg", ...
    'o-', ...
    'full +I -> -I');

% Clean full reversal: -I -> +I
plotDelaySeries( ...
    ax,T, ...
    fastRegime=="FULL_REVERSAL" & transitionClass=="neg_to_pos", ...
    's-', ...
    'full -I -> +I');

% High-current near-zero start -> -I
plotDelaySeries( ...
    ax,T, ...
    fastRegime=="NEAR_ZERO_START" & transitionClass=="pos_to_neg", ...
    '^--', ...
    'near-zero -> -I');

% High-current near-zero start -> +I
plotDelaySeries( ...
    ax,T, ...
    fastRegime=="NEAR_ZERO_START" & transitionClass=="neg_to_pos", ...
    'v--', ...
    'near-zero -> +I');

% Literal packet startup: 0 -> +I
plotDelaySeries( ...
    ax,T, ...
    fastRegime=="LITERAL_ZERO_TO_POS" & transitionClass=="zero_to_pos", ...
    'd:', ...
    'literal 0 -> +I');

% Physical packet-end boundary: -I -> 0
plotDelaySeries( ...
    ax,T, ...
    fastRegime=="NEG_TO_ZERO_BOUNDARY" & transitionClass=="neg_to_zero", ...
    'p-.', ...
    'boundary -I -> 0');

xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Command to fast onset (us)');
title(ax,'Delay identified locally');

if ~isempty(findobj(ax,'Type','line'))
    legend(ax,'Location','best','Interpreter','none');
end

hold(ax,'off');
end

function plotDelaySeries(ax,T,mask,lineSpec,label)

mask = mask & isfinite(T.MeanTransportDelay_us);

if ~any(mask)
    return;
end

x = T.CommandCurrent_mA(mask);
y = T.MeanTransportDelay_us(mask);

[x,ord] = sort(x);
y = y(ord);

plot( ...
    ax,x,y,lineSpec, ...
    'LineWidth',1.4, ...
    'MarkerSize',7, ...
    'DisplayName',label);
end

%% ========================================================================
% PREDICTION HELPERS
% ========================================================================

function y = fastCurve(M,t)

x = t(:)-M.theta_us;
y = zeros(size(x));

a = x>=0;
xa = x(a);

switch string(M.modelName)

    case "FOP"

        y(a) = 1-exp(-xa/M.tau_us);

    case "TWO_POLE"

        t1 = M.tau1_us;
        t2 = M.tau2_us;

        if abs(t1-t2)<1e-5*max(t1,t2)

            tau = .5*(t1+t2);
            y(a) = 1-exp(-xa/tau).*(1+xa/tau);

        else

            y(a) = ...
                1-(t2*exp(-xa/t2)-t1*exp(-xa/t1))/(t2-t1);
        end

    case "SECOND_ORDER"

        wn = M.wn_rad_per_us;
        z = M.zeta;

        if z<1-1e-5

            wd = wn*sqrt(1-z^2);

            y(a) = ...
                1-exp(-z*wn*xa).* ...
                (cos(wd*xa)+z/sqrt(1-z^2)*sin(wd*xa));

        elseif z>1+1e-5

            q = sqrt(z^2-1);
            r1 = -wn*(z-q);
            r2 = -wn*(z+q);

            y(a) = ...
                1+(r2*exp(r1*xa)-r1*exp(r2*xa))/(r1-r2);

        else

            y(a) = ...
                1-exp(-wn*xa).*(1+wn*xa);
        end
end

end

function P = buildSlowPresentationFits(S)
% buildSlowPresentationFits
%
% Creates presentation-only time-domain curves from the already identified
% Stage 5 slow data. These curves do not replace or modify the saved Stage 5
% plant model.
%
% Linear and exponential curves use the Stage 5 ordinary-droop rate.
% A piecewise linear-to-exponential curve is fitted only when Stage 5 has
% already identified compliance collapse for that current.

t = S.droop.time_us(:)/1000;
y = S.droop.meanUsedWaveform(:);

good = isfinite(t) & isfinite(y);
t = t(good);
y = y(good);

P = struct();
P.time_ms = t;
P.measured = y;

k = S.droop.best.rate_per_ms;

if ~isfinite(k) || k<=0
    denom = sum(t.^2);
    if denom>0
        k = max(1e-6,sum(t.*(1-y))/denom);
    else
        k = 1e-3;
    end
end

P.k_per_ms = k;
P.linear = 1-k*t;
P.exponential = exp(-k*t);

P.piecewiseAvailable = false;
P.changeTime_ms = NaN;
P.tau_ms = NaN;
P.piecewise = NaN(size(t));
P.piecewiseRMSE = NaN;

if ~S.collapse.identifiable || numel(t)<20
    return;
end

% The full-phase mean can contain the ordinary droop followed by the
% compliance collapse. Fit a deliberately simple, continuous representation:
%
%   before tc: D = 1-k*t
%   after tc : D = D(tc)*exp(-(t-tc)/tau)
%
% k is kept at the Stage 5 ordinary-droop value. Only tc and tau are fitted.
% This makes the graphic interpretable and prevents the presentation fit
% from changing the underlying ordinary-droop identification.

tMax = max(t);

if ~isfinite(tMax) || tMax<=0
    return;
end

% Initial knee guess from a visible departure below ordinary droop.
ordinary = 1-k*t;
departure = ordinary-y;

idx = find( ...
    y<0.90 & departure>0.03, ...
    1,'first');

if isempty(idx)
    idx = find(y<0.80,1,'first');
end

if isempty(idx)
    tc0 = 0.65*tMax;
else
    tc0 = t(idx);
end

tcLo = max(0.05*tMax,min(t)*0);
tcHi = 0.95*tMax;

tc0 = min(max(tc0,tcLo+eps),tcHi-eps);

frac0 = (tc0-tcLo)/max(tcHi-tcLo,eps);
frac0 = min(max(frac0,1e-4),1-1e-4);

p0 = [
    log(frac0/(1-frac0))
    log(max(0.10*tMax,0.02))
];

obj = @(p) piecewisePresentationObjective(p,t,y,k,tcLo,tcHi);

options = optimset( ...
    'Display','off', ...
    'MaxIter',1500, ...
    'MaxFunEvals',4000, ...
    'TolX',1e-9, ...
    'TolFun',1e-10);

[pFit,~] = fminsearch(obj,p0,options);

sigmoid = 1/(1+exp(-pFit(1)));
tc = tcLo + (tcHi-tcLo)*sigmoid;
tau = exp(pFit(2));

piecewise = piecewiseSlowCurve(t,k,tc,tau);

P.piecewiseAvailable = all(isfinite(piecewise));
P.changeTime_ms = tc;
P.tau_ms = tau;
P.piecewise = piecewise;

if P.piecewiseAvailable
    P.piecewiseRMSE = sqrt(mean((y-piecewise).^2,'omitnan'));
end

end

function value = piecewisePresentationObjective(p,t,y,k,tcLo,tcHi)

sigmoid = 1/(1+exp(-p(1)));
tc = tcLo + (tcHi-tcLo)*sigmoid;
tau = exp(p(2));

yhat = piecewiseSlowCurve(t,k,tc,tau);

good = isfinite(y) & isfinite(yhat);

if nnz(good)<10
    value = 1e6;
    return;
end

value = mean((y(good)-yhat(good)).^2);

% Mild penalties against implausible presentation fits.
if tau<0.005 || tau>5
    value = value+10;
end

if 1-k*tc<=0
    value = value+100;
end

end

function y = piecewiseSlowCurve(t,k,tc,tau)

t = t(:);
y = NaN(size(t));

before = t<=tc;
after = ~before;

y(before) = 1-k*t(before);

yAtChange = max(1e-6,1-k*tc);

y(after) = ...
    yAtChange .* ...
    exp(-(t(after)-tc)/tau);

end

function y = droopCurve(M,t_ms)

switch string(M.modelName)

    case "LINEAR"

        y = 1-M.rate_per_ms*t_ms;

    case "EXP"

        y = exp(-M.rate_per_ms*t_ms);

    otherwise

        y = NaN(size(t_ms));
end

end

function y = collapseCurve(C,x)

z = max(x(:)-C.q0,0);

switch string(C.modelName)

    case "SHIFTED_EXP"

        y = exp(-C.k*z);

    case "STRETCHED_EXP"

        y = exp(-(z/C.scale).^C.power);

    otherwise

        y = NaN(size(z));
end

end

function saveFigure(fig,path,cfg)

if cfg.SAVE_PLOTS
    exportgraphics(fig,path,'Resolution',cfg.FIGURE_RESOLUTION_DPI);
end

if ~cfg.SHOW_FIGURES
    close(fig);
end

end
