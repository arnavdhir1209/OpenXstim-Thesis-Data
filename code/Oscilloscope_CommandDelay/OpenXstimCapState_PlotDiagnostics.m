function OpenXstimCapState_PlotDiagnostics( ...
    P,C,ChargeTraces,ThresholdSummary,GlobalSummary,cfg)
% Stage 4A capacitor-state diagnostic figures.
%
% Included captures are used for every scientific aggregate/diagnostic.
% Excluded captures remain visible only in the packet-level audit panel.

vis = onOff(cfg.SHOW_FIGURES);

captureMask = C.IncludedInChargeAnalysis;
phaseMask = P.ValidPhase & P.IncludedInChargeAnalysis;

currents = unique(C.CommandCurrent_mA(captureMask));

%% ========================================================================
% 1. REPRESENTATIVE CONTINUOUS CHARGE STATE BY CURRENT
% ========================================================================

fig1 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[40 40 1500 1000]);

tl = tiledlayout(fig1,3,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4A continuous signed charge-state proxy across the packet');

for k = 1:numel(currents)

    Icmd = currents(k);

    captureRows = find( ...
        C.CommandCurrent_mA==Icmd & ...
        C.IncludedInChargeAnalysis);

    spans = C.ChargeSpan_uC(captureRows);
    medSpan = median(spans,'omitnan');

    [~,ii] = min(abs(spans-medSpan));

    chosenCaptureID = C.CaptureID(captureRows(ii));

    tr = findTrace(ChargeTraces,chosenCaptureID);

    ax = nexttile(tl);

    yyaxis(ax,'left');

    plot(ax, ...
        tr.time_ms, ...
        tr.current_mA, ...
        'LineWidth',0.8);

    ylabel(ax,'Measured current (mA)');

    yyaxis(ax,'right');

    plot(ax, ...
        tr.time_ms, ...
        tr.qCentered_uC, ...
        'LineWidth',1.3);

    yline(ax,0,':','HandleVisibility','off');

    ylabel(ax,'Centered signed charge proxy (uC)');

    grid(ax,'on');

    xlabel(ax,'Time from first physical response (ms)');

    title(ax,sprintf( ...
        '%.3g mA p-p | Capture %d | q span %.2f uC', ...
        Icmd, ...
        chosenCaptureID, ...
        max(tr.qCentered_uC)-min(tr.qCentered_uC)));
end

exportMaybe( ...
    fig1, ...
    fullfile(cfg.OUTPUT_FOLDER,"01_ContinuousChargeStateByCurrent.png"), ...
    cfg);

%% ========================================================================
% 2. THRESHOLD STATE CLUSTERING
% ========================================================================

fig2 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[50 50 1450 900]);

tl = tiledlayout(fig2,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4A phase-local charge versus continuous oriented charge state');

plotThresholdPanel(nexttile(tl),P,0.75,false);
plotThresholdPanel(nexttile(tl),P,0.75,true);

plotThresholdPanel(nexttile(tl),P,0.50,false);
plotThresholdPanel(nexttile(tl),P,0.50,true);

exportMaybe( ...
    fig2, ...
    fullfile(cfg.OUTPUT_FOLDER,"02_ThresholdStateClustering.png"), ...
    cfg);

%% ========================================================================
% 3. COLLAPSE KNEE STATE
% ========================================================================

fig3 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[60 60 1450 850]);

tl = tiledlayout(fig3,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4A compliance-knee timing and continuous charge state');

m = ...
    phaseMask & ...
    isfinite(P.KneeTime_us);

ax = nexttile(tl);
scatterByPolarity(ax, ...
    P.CommandCurrent_mA(m), ...
    P.KneeTime_us(m)/1000, ...
    P.Polarity(m));
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Knee time (ms)');
title(ax,'Detected collapse-knee time');

ax = nexttile(tl);
scatterByPolarity(ax, ...
    P.CommandCurrent_mA(m), ...
    P.OrientedStateKnee_uC(m), ...
    P.Polarity(m));
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Oriented centered q at knee (uC)');
title(ax,'Charge-state proxy at collapse knee');

ax = nexttile(tl);
scatterByPolarity(ax, ...
    P.CommandCurrent_mA(m), ...
    P.KneeCurrentNormalized(m), ...
    P.Polarity(m));
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'D at knee');
title(ax,'Normalized current at detected knee');

ax = nexttile(tl);
scatterByPolarity(ax, ...
    P.CommandCurrent_mA(m), ...
    P.VoltageStateKneeProxy_V(m), ...
    P.Polarity(m));
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Centered voltage-state proxy (V)');
title(ax,'Exploratory C15 voltage-change proxy at knee');

exportMaybe( ...
    fig3, ...
    fullfile(cfg.OUTPUT_FOLDER,"03_CollapseKneeState.png"), ...
    cfg);

%% ========================================================================
% 4. PULSE NUMBER CHARGE STATE
% ========================================================================

fig4 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[70 70 1450 900]);

tl = tiledlayout(fig4,2,1, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4A continuous capacitor-state proxy versus pulse number');

ax = nexttile(tl);
hold(ax,'on');

for k = 1:numel(currents)

    m = ...
        phaseMask & ...
        P.CommandCurrent_mA==currents(k) & ...
        P.Polarity=="positive";

    scatter(ax, ...
        P.PulseNumber(m), ...
        P.OrientedStateStart_uC(m), ...
        16, ...
        'DisplayName',sprintf('%.3g mA',currents(k)));
end

grid(ax,'on');

xlabel(ax,'Pulse number');
ylabel(ax,'Oriented state at phase start (uC)');
title(ax,'Positive phases');

legend(ax,'Location','bestoutside');

hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

for k = 1:numel(currents)

    m = ...
        phaseMask & ...
        P.CommandCurrent_mA==currents(k) & ...
        P.Polarity=="negative";

    scatter(ax, ...
        P.PulseNumber(m), ...
        P.OrientedStateStart_uC(m), ...
        16, ...
        'DisplayName',sprintf('%.3g mA',currents(k)));
end

grid(ax,'on');

xlabel(ax,'Pulse number');
ylabel(ax,'Oriented state at phase start (uC)');
title(ax,'Negative phases');

legend(ax,'Location','bestoutside');

hold(ax,'off');

exportMaybe( ...
    fig4, ...
    fullfile(cfg.OUTPUT_FOLDER,"04_PulseNumberChargeState.png"), ...
    cfg);

%% ========================================================================
% 5. PACKET CHARGE BALANCE + AUDIT
% ========================================================================

fig5 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[80 80 1400 850]);

tl = tiledlayout(fig5,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4A packet-level charge-state characteristics');

included = C.IncludedInChargeAnalysis;
excluded = ~included;

ax = nexttile(tl);
hold(ax,'on');

scatter(ax, ...
    C.CommandCurrent_mA(included), ...
    C.ChargeSpan_uC(included), ...
    28, ...
    'filled', ...
    'DisplayName','Included');

if any(excluded)
    scatter(ax, ...
        C.CommandCurrent_mA(excluded), ...
        C.ChargeSpan_uC(excluded), ...
        60, ...
        'x', ...
        'LineWidth',1.5, ...
        'DisplayName','Excluded');
end

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'q max - q min (uC)');
title(ax,'Signed charge-state span');
legend(ax,'Location','best');
hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax, ...
    C.CommandCurrent_mA(included), ...
    C.VoltageSpanProxy_V(included), ...
    28, ...
    'filled', ...
    'DisplayName','Included');

if any(excluded)
    scatter(ax, ...
        C.CommandCurrent_mA(excluded), ...
        C.VoltageSpanProxy_V(excluded), ...
        60, ...
        'x', ...
        'LineWidth',1.5, ...
        'DisplayName','Excluded');
end

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Equivalent voltage span proxy (V)');
title(ax,'Charge span divided by C15');
legend(ax,'Location','best');
hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax, ...
    C.CommandCurrent_mA(included), ...
    C.NetPacketCharge_uC(included), ...
    28, ...
    'filled', ...
    'DisplayName','Included');

if any(excluded)
    scatter(ax, ...
        C.CommandCurrent_mA(excluded), ...
        C.NetPacketCharge_uC(excluded), ...
        60, ...
        'x', ...
        'LineWidth',1.5, ...
        'DisplayName','Excluded');
end

yline(ax,0,':','HandleVisibility','off');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Net signed packet charge (uC)');
title(ax,'Packet charge balance');
legend(ax,'Location','best');
hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');

scatter(ax, ...
    C.CommandCurrent_mA(included), ...
    C.BaselineCurrent_mA(included), ...
    28, ...
    'filled', ...
    'DisplayName','Included');

if any(excluded)
    scatter(ax, ...
        C.CommandCurrent_mA(excluded), ...
        C.BaselineCurrent_mA(excluded), ...
        60, ...
        'x', ...
        'LineWidth',1.5, ...
        'DisplayName','Excluded');
end

yline(ax,0,':','HandleVisibility','off');

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Pre-packet CH3 baseline (mA)');
title(ax,'Integration baseline audit');
legend(ax,'Location','best');

hold(ax,'off');

exportMaybe( ...
    fig5, ...
    fullfile(cfg.OUTPUT_FOLDER,"05_PacketChargeBalance.png"), ...
    cfg);

%% ========================================================================
% 6. ROBUST SPREAD COMPARISON
% ========================================================================

fig6 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[90 90 1300 750]);

tl = tiledlayout(fig6,1,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 4A does continuous state reduce threshold dispersion?');

ax = nexttile(tl);

plot(ax, ...
    GlobalSummary.ThresholdD, ...
    GlobalSummary.RobustSpreadPhaseLocal_uC, ...
    'o-', ...
    'LineWidth',1.5, ...
    'DisplayName','Phase-local charge');

hold(ax,'on');

plot(ax, ...
    GlobalSummary.ThresholdD, ...
    GlobalSummary.RobustSpreadOrientedCentered_uC, ...
    's-', ...
    'LineWidth',1.5, ...
    'DisplayName','Continuous oriented state');

grid(ax,'on');

xlabel(ax,'Normalized-current threshold D');
ylabel(ax,'Robust spread (uC)');
title(ax,'Absolute robust spread');
legend(ax,'Location','best');

hold(ax,'off');

ax = nexttile(tl);

plot(ax, ...
    GlobalSummary.ThresholdD, ...
    GlobalSummary.RelativeSpreadPhaseLocal, ...
    'o-', ...
    'LineWidth',1.5, ...
    'DisplayName','Phase-local charge');

hold(ax,'on');

plot(ax, ...
    GlobalSummary.ThresholdD, ...
    GlobalSummary.RelativeSpreadOrientedCentered, ...
    's-', ...
    'LineWidth',1.5, ...
    'DisplayName','Continuous oriented state');

grid(ax,'on');

xlabel(ax,'Normalized-current threshold D');
ylabel(ax,'Robust spread / |median|');
title(ax,'Relative robust spread');

legend(ax,'Location','best');

hold(ax,'off');

exportMaybe( ...
    fig6, ...
    fullfile(cfg.OUTPUT_FOLDER,"06_LocalVsContinuousChargeSpread.png"), ...
    cfg);

end

%% ========================================================================
% PLOT HELPERS
% ========================================================================

function plotThresholdPanel(ax,P,level,useContinuous)

switch round(level*100)

    case 75
        localField = "ChargeTo75_uC";
        stateField = "OrientedState75_uC";

    case 50
        localField = "ChargeTo50_uC";
        stateField = "OrientedState50_uC";

    otherwise
        error("Threshold panel only configured for D=0.75 or D=0.50.");
end

m = ...
    P.ValidPhase & ...
    P.IncludedInChargeAnalysis & ...
    isfinite(P.(localField)) & ...
    isfinite(P.(stateField));

if useContinuous
    y = P.(stateField);
    yLabel = 'Oriented centered q-state (uC)';
    ttl = sprintf('Continuous state at D=%.2f',level);
else
    y = P.(localField);
    yLabel = 'Phase-local delivered charge (uC)';
    ttl = sprintf('Phase-local charge to D=%.2f',level);
end

scatterByPolarity(ax, ...
    P.CommandCurrent_mA(m), ...
    y(m), ...
    P.Polarity(m));

xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,yLabel);
title(ax,ttl);

end

function scatterByPolarity(ax,x,y,polarity)

hold(ax,'on');

mp = polarity=="positive";
mn = polarity=="negative";

if any(mp)

    scatter(ax, ...
        x(mp), ...
        y(mp), ...
        18, ...
        'filled', ...
        'DisplayName','Positive');
end

if any(mn)

    scatter(ax, ...
        x(mn), ...
        y(mn), ...
        18, ...
        'DisplayName','Negative');
end

grid(ax,'on');

if any(mp) || any(mn)
    legend(ax,'Location','best');
end

hold(ax,'off');

end

function tr = findTrace(traceCells,captureID)

tr = struct();

for k = 1:numel(traceCells)

    if isempty(traceCells{k})
        continue;
    end

    if traceCells{k}.CaptureID==captureID
        tr = traceCells{k};
        return;
    end
end

error("Charge trace for CaptureID %d was not found.",captureID);

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
