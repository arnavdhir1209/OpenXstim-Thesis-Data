function OpenXstimFastOutlier_PlotDiagnostics( ...
    tFast_us,Y,A,CaptureAudit,RegimeSummary,cfg)
% Plot supporting Stage 3A diagnostics without modifying Stage 3.

vis = onOff(cfg.SHOW_FIGURES);

currents = unique(A.CommandCurrent_mA);

%% ========================================================================
% FIGURE 1: EVENT OUTLIER + STATE AUDIT
% ========================================================================

fig1 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[40 40 1450 950]);

tl = tiledlayout( ...
    fig1,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 3A fast-event outlier and physical-state audit');

% ------------------------------------------------------------------------
% 1A t10-90
% ------------------------------------------------------------------------

ax = nexttile(tl);
hold(ax,'on');

normal = ...
    A.IsBipolar & ...
    ~A.MetricOutlier & ...
    A.ValidEvent;

flagged = ...
    A.IsBipolar & ...
    A.MetricOutlier & ...
    A.ValidEvent;

scatter(ax, ...
    A.CommandCurrent_mA(normal), ...
    A.T10_90_us(normal), ...
    14, ...
    'filled', ...
    'DisplayName','Not metric-outlier');

if any(flagged)

    scatter(ax, ...
        A.CommandCurrent_mA(flagged), ...
        A.T10_90_us(flagged), ...
        38, ...
        'x', ...
        'LineWidth',1.5, ...
        'DisplayName','Metric outlier');
end

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'10-90 time (us)');
title(ax,'Event-level fast timing');
legend(ax,'Location','best');

hold(ax,'off');

% ------------------------------------------------------------------------
% 1B waveform RMSE
% ------------------------------------------------------------------------

ax = nexttile(tl);
hold(ax,'on');

normal = ...
    A.IsBipolar & ...
    ~A.WaveformOutlier & ...
    isfinite(A.WaveformRMSEToGroupMedian);

flagged = ...
    A.IsBipolar & ...
    A.WaveformOutlier & ...
    isfinite(A.WaveformRMSEToGroupMedian);

scatter(ax, ...
    A.CommandCurrent_mA(normal), ...
    A.WaveformRMSEToGroupMedian(normal), ...
    14, ...
    'filled', ...
    'DisplayName','Not waveform-outlier');

if any(flagged)

    scatter(ax, ...
        A.CommandCurrent_mA(flagged), ...
        A.WaveformRMSEToGroupMedian(flagged), ...
        38, ...
        'x', ...
        'LineWidth',1.5, ...
        'DisplayName','Waveform outlier');
end

grid(ax,'on');
xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'RMSE to same-current/type median');
title(ax,'Normalized waveform shape');
legend(ax,'Location','best');

hold(ax,'off');

% ------------------------------------------------------------------------
% 1C pre/post state
% ------------------------------------------------------------------------

ax = nexttile(tl);
hold(ax,'on');

classes = ["pos_to_neg","neg_to_pos"];

for d = 1:numel(classes)

    m = ...
        A.IsBipolar & ...
        string(A.TransitionClass)==classes(d);

    scatter(ax, ...
        A.PreStateMagnitudeRatio(m), ...
        A.PostStateMagnitudeRatio(m), ...
        16, ...
        'filled', ...
        'DisplayName',prettyTransition(classes(d)));
end

xline(ax,cfg.FULL_STATE_MIN,'--','HandleVisibility','off');
yline(ax,cfg.FULL_STATE_MIN,'--','HandleVisibility','off');

xline(ax,cfg.NEAR_ZERO_MAX,':','HandleVisibility','off');
yline(ax,cfg.NEAR_ZERO_MAX,':','HandleVisibility','off');

grid(ax,'on');

xlabel(ax,'Pre-state magnitude / expected half-current');
ylabel(ax,'Post-state magnitude / expected half-current');
title(ax,'Physical operating state at bipolar commands');

legend(ax,'Location','best');

hold(ax,'off');

% ------------------------------------------------------------------------
% 1D step ratio
% ------------------------------------------------------------------------

ax = nexttile(tl);
hold(ax,'on');

for d = 1:numel(classes)

    m = ...
        A.IsBipolar & ...
        string(A.TransitionClass)==classes(d);

    scatter(ax, ...
        A.CommandCurrent_mA(m), ...
        A.StepToMeasuredIppRatio(m), ...
        14, ...
        'filled', ...
        'DisplayName',prettyTransition(classes(d)));
end

yline(ax,1,':','Full measured p-p step','HandleVisibility','off');
yline(ax,0.5,':','Half measured p-p step','HandleVisibility','off');

grid(ax,'on');

xlabel(ax,'Commanded current (mA p-p)');
ylabel(ax,'Local step / measured early Ipp');
title(ax,'Physical transition amplitude relative to measured Ipp');

legend(ax,'Location','best');

hold(ax,'off');

exportMaybe( ...
    fig1, ...
    fullfile(cfg.OUTPUT_FOLDER,"01_EventOutlierAndStateAudit.png"), ...
    cfg);

%% ========================================================================
% FIGURE 2: CAPTURE CONSISTENCY
% ========================================================================

fig2 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[50 50 1450 1000]);

tl = tiledlayout( ...
    fig2,3,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 3A capture-level consistency across five repeats');

for k = 1:numel(currents)

    ax = nexttile(tl);

    m = CaptureAudit.CommandCurrent_mA==currents(k);

    C = CaptureAudit(m,:);

    hold(ax,'on');

    normal = ~C.CaptureOutlierQC;
    flagged = C.CaptureOutlierQC;

    plot(ax, ...
        C.CaptureWithinAttempt(normal), ...
        C.MeanT10_90_us(normal), ...
        'o-', ...
        'LineWidth',1.2, ...
        'DisplayName','Capture mean');

    if any(flagged)

        scatter(ax, ...
            C.CaptureWithinAttempt(flagged), ...
            C.MeanT10_90_us(flagged), ...
            70, ...
            'x', ...
            'LineWidth',2, ...
            'DisplayName','Capture outlier');
    end

    grid(ax,'on');

    xlabel(ax,'Capture within current');
    ylabel(ax,'Mean bipolar 10-90 time (us)');

    title(ax,sprintf( ...
        '%.3g mA p-p | full-reversal fraction %.2f to %.2f', ...
        currents(k), ...
        min(C.FullReversalFraction), ...
        max(C.FullReversalFraction)));

    if k==1
        legend(ax,'Location','best');
    end

    hold(ax,'off');
end

exportMaybe( ...
    fig2, ...
    fullfile(cfg.OUTPUT_FOLDER,"02_CaptureConsistency.png"), ...
    cfg);

%% ========================================================================
% FIGURE 3: PHYSICAL REGIMES BY CURRENT
% ========================================================================

fig3 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[60 60 1300 800]);

bipolar = A.IsBipolar;

regimes = [ ...
    "FULL_REVERSAL", ...
    "PARTIAL_REVERSAL", ...
    "NEAR_ZERO_TO_OPPOSITE", ...
    "OTHER_BIPOLAR_STATE", ...
    "STATE_SIGN_MISMATCH"];

counts = zeros(numel(currents),numel(regimes));

for k = 1:numel(currents)

    for r = 1:numel(regimes)

        counts(k,r) = nnz( ...
            bipolar & ...
            A.CommandCurrent_mA==currents(k) & ...
            A.PhysicalRegime==regimes(r));
    end
end

bar(currents,counts,'stacked');

grid on;

xlabel('Commanded current (mA p-p)');
ylabel('Number of observed bipolar events');

title('Stage 3A physical regime of nominal bipolar commands');

legend( ...
    strrep(regimes,'_',' '), ...
    'Location','best');

exportMaybe( ...
    fig3, ...
    fullfile(cfg.OUTPUT_FOLDER,"03_PhysicalRegimesByCurrent.png"), ...
    cfg);

%% ========================================================================
% FIGURE 4: RECOMMENDED VS NON-RECOMMENDED WAVEFORMS
% ========================================================================

fig4 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[70 40 1450 1000]);

tl = tiledlayout( ...
    fig4,3,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl, ...
    'Stage 3A recommended full-reversal fast responses versus excluded regimes');

for k = 1:numel(currents)

    ax = nexttile(tl);

    Icmd = currents(k);

    rec = ...
        A.CommandCurrent_mA==Icmd & ...
        A.RecommendedForFastModel;

    notRec = ...
        A.CommandCurrent_mA==Icmd & ...
        A.IsBipolar & ...
        A.ValidEvent & ...
        ~A.RecommendedForFastModel;

    hold(ax,'on');

    if any(rec)

        plot(ax, ...
            tFast_us, ...
            mean(Y(:,rec),2,'omitnan'), ...
            'LineWidth',2, ...
            'DisplayName',sprintf('Recommended N=%d',nnz(rec)));
    end

    rows = find(notRec);

    rows = evenlySpacedSelection( ...
        rows, ...
        cfg.MAX_NONRECOMMENDED_TRACES_PER_CURRENT);

    for q = 1:numel(rows)

        plot(ax, ...
            tFast_us, ...
            Y(:,rows(q)), ...
            'LineWidth',0.5, ...
            'HandleVisibility','off');
    end

    if any(notRec)

        plot(ax, ...
            tFast_us, ...
            mean(Y(:,notRec),2,'omitnan'), ...
            '--', ...
            'LineWidth',1.8, ...
            'DisplayName',sprintf('Not recommended N=%d',nnz(notRec)));
    end

    yline(ax,0,':','HandleVisibility','off');
    yline(ax,1,':','HandleVisibility','off');
    xline(ax,0,'--','HandleVisibility','off');

    grid(ax,'on');
    ylim(ax,[-0.15 1.20]);

    xlabel(ax,'Time from gradient peak (us)');
    ylabel(ax,'Normalized current');

    title(ax,sprintf('%.3g mA p-p',Icmd));

    legend(ax,'Location','best');

    hold(ax,'off');
end

exportMaybe( ...
    fig4, ...
    fullfile(cfg.OUTPUT_FOLDER,"04_RecommendedVsExcludedWaveforms.png"), ...
    cfg);

%% ========================================================================
% FIGURE 5: TRANSITION-TYPE STATE AUDIT
% ========================================================================

fig5 = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[80 60 1400 850]);

tl = tiledlayout( ...
    fig5,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 3A physical-state audit by transition type');

transitionClasses = [ ...
    "zero_to_pos", ...
    "pos_to_neg", ...
    "neg_to_pos", ...
    "neg_to_zero"];

for d = 1:numel(transitionClasses)

    ax = nexttile(tl);

    cls = transitionClasses(d);

    m = string(A.TransitionClass)==cls;

    hold(ax,'on');

    scatter(ax, ...
        A.CommandCurrent_mA(m), ...
        A.PreStateMagnitudeRatio(m), ...
        25, ...
        'filled', ...
        'DisplayName','Pre state');

    scatter(ax, ...
        A.CommandCurrent_mA(m), ...
        A.PostStateMagnitudeRatio(m), ...
        25, ...
        'DisplayName','Post state');

    yline(ax,cfg.FULL_STATE_MIN,'--', ...
        'Full-state threshold', ...
        'HandleVisibility','off');

    yline(ax,cfg.NEAR_ZERO_MAX,':', ...
        'Near-zero threshold', ...
        'HandleVisibility','off');

    grid(ax,'on');

    xlabel(ax,'Commanded current (mA p-p)');
    ylabel(ax,'Magnitude / expected half-current');

    title(ax,prettyTransition(cls));

    legend(ax,'Location','best');

    hold(ax,'off');
end

exportMaybe( ...
    fig5, ...
    fullfile(cfg.OUTPUT_FOLDER,"05_TransitionTypeStateAudit.png"), ...
    cfg);

end

%% ========================================================================
% HELPERS
% ========================================================================

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
