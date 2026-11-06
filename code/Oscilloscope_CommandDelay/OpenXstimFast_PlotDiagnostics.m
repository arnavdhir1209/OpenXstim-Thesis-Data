function OpenXstimFast_PlotDiagnostics( ...
    fastTime_us, ...
    Y, ...
    M, ...
    CurrentSummary, ...
    Symmetry, ...
    Yall, ...
    A, ...
    TransitionTypeSummary, ...
    cfg)
% Create existing Stage 3 diagnostics plus transition-type comparisons.

valid = M.ValidEvent;
currents = unique(M.CommandCurrent_mA);

allValid = A.ValidEvent;
allCurrents = unique(A.CommandCurrent_mA);

transitionClasses = [ ...
    "zero_to_pos", ...
    "pos_to_neg", ...
    "neg_to_pos", ...
    "neg_to_zero"];

vis = onOff(cfg.SHOW_FIGURES);

%% 1. NORMALIZED TRANSITIONS BY CURRENT ==================================

fig1 = figure( ...
    'Visible',vis,'Color','w','Position',[40 40 1450 1000]);

tl = tiledlayout(fig1,3,2, ...
    'TileSpacing','compact','Padding','compact');

title(tl,'Stage 3 normalized fast bipolar transitions by commanded current');

for k = 1:numel(currents)

    ax = nexttile(tl);

    m = valid & M.CommandCurrent_mA==currents(k);
    rows = find(m);

    hold(ax,'on');

    showRows = evenlySpacedSelection(rows,cfg.MAX_TRACES_PER_CURRENT_PLOT);

    for j = 1:numel(showRows)

        plot(ax,fastTime_us,Y(:,showRows(j)), ...
            'LineWidth',0.35,'HandleVisibility','off');
    end

    if any(m)

        plot(ax,fastTime_us,mean(Y(:,m),2,'omitnan'), ...
            'k','LineWidth',2,'DisplayName','Mean');
    end

    addNormalizedGuides(ax);

    grid(ax,'on');
    ylim(ax,[-.15 1.20]);

    xlabel(ax,'Time from Stage 2 gradient peak (us)');
    ylabel(ax,'Normalized current');

    title(ax,sprintf('%.3g mA p-p | valid N = %d', ...
        currents(k),nnz(m)));

    hold(ax,'off');
end

exportMaybe(fig1, ...
    fullfile(cfg.OUTPUT_FOLDER,"01_NormalizedFastTransitionsByCurrent.png"), ...
    cfg);

%% 2. DIRECTION SYMMETRY =================================================

fig2 = figure( ...
    'Visible',vis,'Color','w','Position',[50 50 1450 1000]);

tl = tiledlayout(fig2,3,2, ...
    'TileSpacing','compact','Padding','compact');

title(tl,'Stage 3 direction symmetry: +I -> -I versus -I -> +I');

for k = 1:numel(currents)

    ax = nexttile(tl);

    pn = ...
        valid & M.CommandCurrent_mA==currents(k) & ...
        M.TransitionClass=="pos_to_neg";

    np = ...
        valid & M.CommandCurrent_mA==currents(k) & ...
        M.TransitionClass=="neg_to_pos";

    hold(ax,'on');

    if any(pn)

        plot(ax,fastTime_us,mean(Y(:,pn),2,'omitnan'), ...
            'LineWidth',1.8,'DisplayName','+I -> -I');
    end

    if any(np)

        plot(ax,fastTime_us,mean(Y(:,np),2,'omitnan'), ...
            'LineWidth',1.8,'DisplayName','-I -> +I');
    end

    yline(ax,0,':','HandleVisibility','off');
    yline(ax,1,':','HandleVisibility','off');
    xline(ax,0,'--','HandleVisibility','off');

    s = Symmetry.CommandCurrent_mA==currents(k);

    grid(ax,'on');
    ylim(ax,[-.15 1.20]);

    xlabel(ax,'Time from gradient peak (us)');
    ylabel(ax,'Normalized current');

    title(ax,sprintf('%.3g mA p-p | RMSE %.4f', ...
        currents(k),Symmetry.MeanCurveRMSE(s)));

    if k==1
        legend(ax,'Location','best');
    end

    hold(ax,'off');
end

exportMaybe(fig2, ...
    fullfile(cfg.OUTPUT_FOLDER,"02_DirectionSymmetryByCurrent.png"), ...
    cfg);

%% 3. FAST METRICS ========================================================

fig3 = figure( ...
    'Visible',vis,'Color','w','Position',[60 60 1400 900]);

tl = tiledlayout(fig3,2,2, ...
    'TileSpacing','compact','Padding','compact');

title(tl,'Stage 3 fast-transition metrics versus commanded current');

ax = nexttile(tl);

errorbar(ax,CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.MeanT10_90_us,CurrentSummary.SDT10_90_us, ...
    'o-','LineWidth',1.4);

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'10-90 time (us)');
title(ax,'Fast 10-90 transition time');

ax = nexttile(tl);
hold(ax,'on');

errorbar(ax,CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.MeanT10_us,CurrentSummary.SDT10_us, ...
    'o-','LineWidth',1.2,'DisplayName','t10');

errorbar(ax,CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.MeanT50_us,CurrentSummary.SDT50_us, ...
    's-','LineWidth',1.2,'DisplayName','t50');

errorbar(ax,CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.MeanT90_us,CurrentSummary.SDT90_us, ...
    'd-','LineWidth',1.2,'DisplayName','t90');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Time from gradient peak (us)');
title(ax,'Normalized crossing locations');
legend(ax,'Location','best');
hold(ax,'off');

ax = nexttile(tl);

errorbar(ax,CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.MeanOvershoot_pct,CurrentSummary.SDOvershoot_pct, ...
    'o-','LineWidth',1.4);

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Fast overshoot (%)');
title(ax,'Fast normalized overshoot');

ax = nexttile(tl);

plot(ax,CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.ValidFraction,'o-','LineWidth',1.4);

ylim(ax,[0 1.05]);
grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Valid event fraction');
title(ax,'Normalization acceptance rate');

exportMaybe(fig3, ...
    fullfile(cfg.OUTPUT_FOLDER,"03_FastMetricsVsCurrent.png"), ...
    cfg);

%% 4. CROSS-CURRENT BIPOLAR MEAN =========================================

fig4 = figure( ...
    'Visible',vis,'Color','w','Position',[70 70 1200 760]);

hold on;

for k = 1:numel(currents)

    m = valid & M.CommandCurrent_mA==currents(k);

    if any(m)

        plot(fastTime_us,mean(Y(:,m),2,'omitnan'), ...
            'LineWidth',1.6, ...
            'DisplayName',sprintf('%.3g mA p-p',currents(k)));
    end
end

addNormalizedGuides(gca);

grid on;
ylim([-.15 1.20]);

xlabel('Time from Stage 2 gradient peak (us)');
ylabel('Mean normalized current');
title('Cross-current comparison of mean fast response');
legend('Location','best');

hold off;

exportMaybe(fig4, ...
    fullfile(cfg.OUTPUT_FOLDER,"04_CrossCurrentMeanResponses.png"), ...
    cfg);

%% 5. QC ==================================================================

fig5 = figure( ...
    'Visible',vis,'Color','w','Position',[80 80 1350 850]);

tl = tiledlayout(fig5,2,2, ...
    'TileSpacing','compact','Padding','compact');

title(tl,'Stage 3 fast normalization QC');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax,M.CommandCurrent_mA,M.BaselineNormalizedMean,14,'filled');
yline(ax,0,':');
yline(ax,+cfg.BASELINE_TOL,'--');
yline(ax,-cfg.BASELINE_TOL,'--');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Normalized pre-level mean');
title(ax,'Pre-transition normalization');
hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax,M.CommandCurrent_mA,M.FinalNormalizedMean,14,'filled');
yline(ax,1,':');
yline(ax,1+cfg.FINAL_TOL,'--');
yline(ax,1-cfg.FINAL_TOL,'--');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Early post-transition normalized mean');
title(ax,'Immediate post-transition normalization');
hold(ax,'off');

ax = nexttile(tl);

scatter(ax,M.CommandCurrent_mA,M.LocalStepMagnitude_mA,14,'filled');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Local physical step magnitude (mA)');
title(ax,'Local output step magnitude');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax,M.CommandCurrent_mA,M.PreFitR2,14,'filled', ...
    'DisplayName','Pre fit');

scatter(ax,M.CommandCurrent_mA,M.PostFitR2,14, ...
    'DisplayName','Post fit');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Local linear-fit R^2');
title(ax,'Local trend-fit quality');
legend(ax,'Location','best');

hold(ax,'off');

exportMaybe(fig5, ...
    fullfile(cfg.OUTPUT_FOLDER,"05_NormalizationQC.png"), ...
    cfg);

%% 6. TRANSITION TYPE COMPARISON AT EACH CURRENT ==========================

fig6 = figure( ...
    'Visible',vis,'Color','w','Position',[90 40 1500 1000]);

tl = tiledlayout(fig6,3,2, ...
    'TileSpacing','compact','Padding','compact');

title(tl, ...
    'Stage 3 transition-type comparison at each commanded current');

for k = 1:numel(allCurrents)

    ax = nexttile(tl);

    Icmd = allCurrents(k);

    hold(ax,'on');

    for d = 1:numel(transitionClasses)

        cls = transitionClasses(d);

        m = ...
            allValid & ...
            A.CommandCurrent_mA==Icmd & ...
            A.TransitionClass==cls;

        if ~any(m)
            continue;
        end

        plot(ax,fastTime_us, ...
            mean(Yall(:,m),2,'omitnan'), ...
            'LineWidth',1.6, ...
            'DisplayName',sprintf('%s  N=%d', ...
            prettyTransition(cls),nnz(m)));
    end

    addNormalizedGuides(ax);

    grid(ax,'on');
    ylim(ax,[-.15 1.20]);

    xlabel(ax,'Time from gradient peak (us)');
    ylabel(ax,'Mean normalized current');

    title(ax,sprintf('%.3g mA p-p',Icmd));

    if k==1
        legend(ax,'Location','best');
    end

    hold(ax,'off');
end

exportMaybe(fig6, ...
    fullfile(cfg.OUTPUT_FOLDER, ...
    "06_TransitionTypeComparisonByCurrent.png"), ...
    cfg);

%% 7. CROSS-CURRENT COMPARISON FOR EACH TRANSITION TYPE ==================

fig7 = figure( ...
    'Visible',vis,'Color','w','Position',[100 50 1450 900]);

tl = tiledlayout(fig7,2,2, ...
    'TileSpacing','compact','Padding','compact');

title(tl, ...
    'Stage 3 current dependence separated by transition type');

for d = 1:numel(transitionClasses)

    ax = nexttile(tl);

    cls = transitionClasses(d);

    hold(ax,'on');

    for k = 1:numel(allCurrents)

        Icmd = allCurrents(k);

        m = ...
            allValid & ...
            A.CommandCurrent_mA==Icmd & ...
            A.TransitionClass==cls;

        if ~any(m)
            continue;
        end

        plot(ax,fastTime_us, ...
            mean(Yall(:,m),2,'omitnan'), ...
            'LineWidth',1.6, ...
            'DisplayName',sprintf('%.3g mA p-p  N=%d', ...
            Icmd,nnz(m)));
    end

    addNormalizedGuides(ax);

    grid(ax,'on');
    ylim(ax,[-.15 1.20]);

    xlabel(ax,'Time from gradient peak (us)');
    ylabel(ax,'Mean normalized current');

    title(ax,prettyTransition(cls));

    legend(ax,'Location','best');

    hold(ax,'off');
end

exportMaybe(fig7, ...
    fullfile(cfg.OUTPUT_FOLDER, ...
    "07_CrossCurrentComparisonByTransitionType.png"), ...
    cfg);

%% 8. TRANSITION METRICS BY TYPE AND CURRENT =============================

fig8 = figure( ...
    'Visible',vis,'Color','w','Position',[110 60 1450 900]);

tl = tiledlayout(fig8,2,2, ...
    'TileSpacing','compact','Padding','compact');

title(tl, ...
    'Stage 3 fast metrics by transition type and commanded current');

% 10-90 time
ax = nexttile(tl);
hold(ax,'on');

for d = 1:numel(transitionClasses)

    cls = transitionClasses(d);

    m = TransitionTypeSummary.TransitionClass==cls;

    errorbar(ax, ...
        TransitionTypeSummary.CommandCurrent_mA(m), ...
        TransitionTypeSummary.MeanT10_90_us(m), ...
        TransitionTypeSummary.SDT10_90_us(m), ...
        'o-', ...
        'LineWidth',1.2, ...
        'DisplayName',prettyTransition(cls));
end

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'10-90 time (us)');
title(ax,'Fast transition time');
legend(ax,'Location','best');
hold(ax,'off');

% Command-to-gradient-peak delay
ax = nexttile(tl);
hold(ax,'on');

for d = 1:numel(transitionClasses)

    cls = transitionClasses(d);

    m = TransitionTypeSummary.TransitionClass==cls;

    errorbar(ax, ...
        TransitionTypeSummary.CommandCurrent_mA(m), ...
        TransitionTypeSummary.MeanCommandToGradientPeak_us(m), ...
        TransitionTypeSummary.SDCommandToGradientPeak_us(m), ...
        'o-', ...
        'LineWidth',1.2, ...
        'DisplayName',prettyTransition(cls));
end

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Command-to-gradient-peak delay (us)');
title(ax,'Transport / execution delay by transition type');
legend(ax,'Location','best');
hold(ax,'off');

% Physical step relative to command
ax = nexttile(tl);
hold(ax,'on');

for d = 1:numel(transitionClasses)

    cls = transitionClasses(d);

    m = TransitionTypeSummary.TransitionClass==cls;

    errorbar(ax, ...
        TransitionTypeSummary.CommandCurrent_mA(m), ...
        TransitionTypeSummary.MeanStepToCommandRatio(m), ...
        TransitionTypeSummary.SDStepToCommandRatio(m), ...
        'o-', ...
        'LineWidth',1.2, ...
        'DisplayName',prettyTransition(cls));
end

yline(ax,1,':','Full p-p step','HandleVisibility','off');
yline(ax,0.5,':','Half step','HandleVisibility','off');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Local step magnitude / command p-p');
title(ax,'Physical transition amplitude');
legend(ax,'Location','best');
hold(ax,'off');

% Overshoot
ax = nexttile(tl);
hold(ax,'on');

for d = 1:numel(transitionClasses)

    cls = transitionClasses(d);

    m = TransitionTypeSummary.TransitionClass==cls;

    errorbar(ax, ...
        TransitionTypeSummary.CommandCurrent_mA(m), ...
        TransitionTypeSummary.MeanOvershoot_pct(m), ...
        TransitionTypeSummary.SDOvershoot_pct(m), ...
        'o-', ...
        'LineWidth',1.2, ...
        'DisplayName',prettyTransition(cls));
end

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Fast overshoot (%)');
title(ax,'Normalized fast overshoot');
legend(ax,'Location','best');
hold(ax,'off');

exportMaybe(fig8, ...
    fullfile(cfg.OUTPUT_FOLDER, ...
    "08_TransitionMetricsByTypeAndCurrent.png"), ...
    cfg);

end

%% HELPERS ================================================================

function addNormalizedGuides(ax)

yline(ax,0,':','HandleVisibility','off');
yline(ax,.1,':','HandleVisibility','off');
yline(ax,.5,':','HandleVisibility','off');
yline(ax,.9,':','HandleVisibility','off');
yline(ax,1,':','HandleVisibility','off');
xline(ax,0,'--','HandleVisibility','off');

end

function label = prettyTransition(cls)

switch string(cls)

    case "zero_to_pos"
        label = "0 -> +I";

    case "pos_to_neg"
        label = "+I -> -I";

    case "neg_to_pos"
        label = "-I -> +I";

    case "neg_to_zero"
        label = "-I -> 0";

    otherwise
        label = string(cls);
end

end

function idx = evenlySpacedSelection(rows,maxN)

rows = rows(:);

if numel(rows)<=maxN

    idx = rows;
    return;
end

p = round(linspace(1,numel(rows),maxN));
idx = rows(unique(p));

end

function exportMaybe(fig,filePath,cfg)

if cfg.SAVE_PLOTS

    drawnow;

    try

        exportgraphics(fig,filePath, ...
            'Resolution',cfg.FIGURE_RESOLUTION_DPI, ...
            'BackgroundColor','white');

    catch

        saveas(fig,filePath);
    end
end

if ~cfg.SHOW_FIGURES
    close(fig);
end

end

function s = onOff(tf)

if tf
    s = 'on';
else
    s = 'off';
end

end
