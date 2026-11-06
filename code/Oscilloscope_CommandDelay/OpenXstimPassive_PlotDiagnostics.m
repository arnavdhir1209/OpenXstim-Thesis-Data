function OpenXstimPassive_PlotDiagnostics( ...
    modelTime_us,currentModel_mA,normalizedModel,chargeModel_uC, ...
    M,CurrentSummary,cfg)
% Compact Stage 4 diagnostics.

vis = onOff(cfg.SHOW_FIGURES);

valid = M.ValidPhase;
currents = unique(M.CommandCurrent_mA(valid));

%% ========================================================================
% 1. NORMALIZED PASSIVE PHASES BY CURRENT
% ========================================================================

fig1 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[40 40 1500 1000]);

tl = tiledlayout(fig1,3,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4 normalized passive phases by commanded current');

for k = 1:numel(currents)

    ax = nexttile(tl);

    m = ...
        valid & ...
        M.CommandCurrent_mA==currents(k);

    rows = find(m);

    showRows = evenlySpacedSelection( ...
        rows, ...
        cfg.MAX_TRACES_PER_CURRENT);

    hold(ax,'on');

    for q = 1:numel(showRows)

        plot(ax, ...
            modelTime_us/1000, ...
            normalizedModel(:,showRows(q)), ...
            'LineWidth',0.45, ...
            'HandleVisibility','off');
    end

    if any(m)

        plot(ax, ...
            modelTime_us/1000, ...
            mean(normalizedModel(:,m),2,'omitnan'), ...
            'k', ...
            'LineWidth',2, ...
            'DisplayName','Mean');
    end

    yline(ax,1,':','HandleVisibility','off');
    yline(ax,0.75,':','HandleVisibility','off');
    yline(ax,0.50,':','HandleVisibility','off');
    yline(ax,0.25,':','HandleVisibility','off');

    grid(ax,'on');

    xlabel(ax,'Time after passive-phase guard (ms)');
    ylabel(ax,'D(t)');

    title(ax,sprintf('%.3g mA p-p | N=%d',currents(k),nnz(m)));

    hold(ax,'off');
end

exportMaybe( ...
    fig1, ...
    fullfile(cfg.OUTPUT_FOLDER,"01_NormalizedPassivePhasesByCurrent.png"), ...
    cfg);

%% ========================================================================
% 2. POSITIVE / NEGATIVE POLARITY COMPARISON
% ========================================================================

fig2 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[50 50 1500 1000]);

tl = tiledlayout(fig2,3,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4 positive versus negative passive-phase means');

for k = 1:numel(currents)

    ax = nexttile(tl);

    mp = ...
        valid & ...
        M.CommandCurrent_mA==currents(k) & ...
        M.Polarity=="positive";

    mn = ...
        valid & ...
        M.CommandCurrent_mA==currents(k) & ...
        M.Polarity=="negative";

    hold(ax,'on');

    if any(mp)

        plot(ax, ...
            modelTime_us/1000, ...
            mean(normalizedModel(:,mp),2,'omitnan'), ...
            'LineWidth',1.8, ...
            'DisplayName','Positive');
    end

    if any(mn)

        plot(ax, ...
            modelTime_us/1000, ...
            mean(normalizedModel(:,mn),2,'omitnan'), ...
            'LineWidth',1.8, ...
            'DisplayName','Negative sign-corrected');
    end

    yline(ax,1,':','HandleVisibility','off');

    grid(ax,'on');

    xlabel(ax,'Time after passive-phase guard (ms)');
    ylabel(ax,'Mean D(t)');

    title(ax,sprintf('%.3g mA p-p',currents(k)));

    if k==1
        legend(ax,'Location','best');
    end

    hold(ax,'off');
end

exportMaybe( ...
    fig2, ...
    fullfile(cfg.OUTPUT_FOLDER,"02_PolarityComparisonByCurrent.png"), ...
    cfg);

%% ========================================================================
% 3. PASSIVE LOSS VS CURRENT
% ========================================================================

fig3 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[60 60 1400 850]);

tl = tiledlayout(fig3,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4 passive loss and collapse incidence versus current');

ax = nexttile(tl);

errorbar( ...
    ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.MeanEndNormalized, ...
    CurrentSummary.SDEndNormalized, ...
    'o-', ...
    'LineWidth',1.4);

yline(ax,1,':');
yline(ax,0.75,':');
yline(ax,0.50,':');
yline(ax,0.25,':');

grid(ax,'on');

xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'End normalized magnitude');
title(ax,'End-of-phase normalized current');

ax = nexttile(tl);

errorbar( ...
    ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.MeanCurrentLoss_pct, ...
    CurrentSummary.SDCurrentLoss_pct, ...
    'o-', ...
    'LineWidth',1.4);

grid(ax,'on');

xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Current loss (%)');
title(ax,'Mean within-phase current loss');

ax = nexttile(tl);
hold(ax,'on');

plot(ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.FractionCrossing75, ...
    'o-', ...
    'LineWidth',1.3, ...
    'DisplayName','Cross D=0.75');

plot(ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.FractionCrossing50, ...
    's-', ...
    'LineWidth',1.3, ...
    'DisplayName','Cross D=0.50');

plot(ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.FractionCrossing25, ...
    'd-', ...
    'LineWidth',1.3, ...
    'DisplayName','Cross D=0.25');

ylim(ax,[0 1.05]);
grid(ax,'on');

xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Fraction of phases');
title(ax,'Threshold-crossing incidence');
legend(ax,'Location','best');

hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

plot(ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.FractionDroopOnly, ...
    'o-', ...
    'LineWidth',1.3, ...
    'DisplayName','Droop only');

plot(ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.FractionPartialCollapse, ...
    's-', ...
    'LineWidth',1.3, ...
    'DisplayName','Partial collapse');

plot(ax, ...
    CurrentSummary.CommandCurrent_mA, ...
    CurrentSummary.FractionStrongCollapse, ...
    'd-', ...
    'LineWidth',1.3, ...
    'DisplayName','Strong collapse');

ylim(ax,[0 1.05]);
grid(ax,'on');

xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Fraction of phases');
title(ax,'Descriptive passive regime');
legend(ax,'Location','best');

hold(ax,'off');

exportMaybe( ...
    fig3, ...
    fullfile(cfg.OUTPUT_FOLDER,"03_PassiveLossVsCurrent.png"), ...
    cfg);

%% ========================================================================
% 4. TIME + CHARGE TO THRESHOLDS
% ========================================================================

fig4 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[70 70 1400 850]);

tl = tiledlayout(fig4,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4 time-domain versus charge-domain current-loss thresholds');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax,M.CommandCurrent_mA,M.TimeTo75_us/1000,12,'filled');
grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Time to D=0.75 (ms)');
title(ax,'Time to 75% current');
hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax,M.CommandCurrent_mA,M.ChargeTo75_uC,12,'filled');
grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Charge to D=0.75 (uC)');
title(ax,'Delivered charge to 75% current');
hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax,M.CommandCurrent_mA,M.TimeTo50_us/1000,12,'filled');
grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Time to D=0.50 (ms)');
title(ax,'Time to 50% current');
hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax,M.CommandCurrent_mA,M.ChargeTo50_uC,12,'filled');
grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Charge to D=0.50 (uC)');
title(ax,'Delivered charge to 50% current');
hold(ax,'off');

exportMaybe( ...
    fig4, ...
    fullfile(cfg.OUTPUT_FOLDER,"04_TimeAndChargeToThresholds.png"), ...
    cfg);

%% ========================================================================
% 5. PULSE NUMBER EVOLUTION
% ========================================================================

fig5 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[80 80 1400 850]);

tl = tiledlayout(fig5,2,1, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4 passive loss versus pulse number');

ax = nexttile(tl);
hold(ax,'on');

for k = 1:numel(currents)

    m = ...
        valid & ...
        M.CommandCurrent_mA==currents(k) & ...
        M.Polarity=="positive";

    scatter(ax, ...
        M.PulseNumber(m), ...
        M.EndNormalized(m), ...
        18, ...
        'DisplayName',sprintf('%.3g mA',currents(k)));
end

grid(ax,'on');

xlabel(ax,'Pulse number');
ylabel(ax,'End D(t)');
title(ax,'Positive phases');
legend(ax,'Location','bestoutside');

hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

for k = 1:numel(currents)

    m = ...
        valid & ...
        M.CommandCurrent_mA==currents(k) & ...
        M.Polarity=="negative";

    scatter(ax, ...
        M.PulseNumber(m), ...
        M.EndNormalized(m), ...
        18, ...
        'DisplayName',sprintf('%.3g mA',currents(k)));
end

grid(ax,'on');

xlabel(ax,'Pulse number');
ylabel(ax,'End D(t)');
title(ax,'Negative phases');

hold(ax,'off');

exportMaybe( ...
    fig5, ...
    fullfile(cfg.OUTPUT_FOLDER,"05_PulseNumberEvolution.png"), ...
    cfg);

%% ========================================================================
% 6. LINK PASSIVE END STATE TO NEXT FAST-TRANSITION REGIME
% ========================================================================

fig6 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[90 90 1400 850]);

nextRegimes = unique(M.NextPhysicalRegime);

nextRegimes = nextRegimes( ...
    strlength(nextRegimes)>0 & ...
    nextRegimes~="NOT_IN_STAGE3A_AUDIT" & ...
    nextRegimes~="STAGE3A_NOT_LOADED");

hold on;

for q = 1:numel(nextRegimes)

    rg = nextRegimes(q);

    m = ...
        valid & ...
        M.NextPhysicalRegime==rg;

    if ~any(m)
        continue;
    end

    scatter( ...
        M.CommandCurrent_mA(m), ...
        M.EndNormalized(m), ...
        20, ...
        'filled', ...
        'DisplayName',strrep(rg,'_',' '));
end

yline(0.75,':','HandleVisibility','off');
yline(0.50,':','HandleVisibility','off');
yline(0.25,':','HandleVisibility','off');

grid on;

xlabel('Commanded current (mA p-p)');
ylabel('Passive phase end D(t)');
title('Stage 4 end state versus next Stage 3A transition regime');

legend('Location','best');

hold off;

exportMaybe( ...
    fig6, ...
    fullfile(cfg.OUTPUT_FOLDER,"06_LinkToNextTransitionRegime.png"), ...
    cfg);

end

%% ========================================================================
% HELPERS
% ========================================================================

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

        exportgraphics( ...
            fig, ...
            filePath, ...
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
