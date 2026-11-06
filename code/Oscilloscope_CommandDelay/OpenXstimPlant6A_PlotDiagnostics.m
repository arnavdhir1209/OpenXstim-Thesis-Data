function OpenXstimPlant6A_PlotDiagnostics(stats,cfg)
% OpenXstimPlant6A_PlotDiagnostics
%
% Compact figures for Stage 6A statistical model-reduction evidence.

vis = onOff(cfg.SHOW_FIGURES);

%% 1. OVERALL MODEL-REDUCTION EVIDENCE ===================================

fig = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[50 50 1500 900]);

tl = tiledlayout(fig,2,1, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Stage 6A statistical evidence for model reduction');

E = stats.evidenceTable;

ax = nexttile(tl);
hold(ax,'on');
grid(ax,'on');
box(ax,'on');

if ~isempty(E)

    n = height(E);
    x = 1:n;

    delta = E.DeltaCandidateMinusReference;
    lo = E.DeltaCI95_Lower;
    hi = E.DeltaCI95_Upper;

    errorbar( ...
        ax,x,delta,delta-lo,hi-delta, ...
        'o', ...
        'LineWidth',1.2, ...
        'MarkerSize',6);

    yline(ax,0,':','HandleVisibility','off');

    xticks(ax,x);
    xticklabels(ax,shortEvidenceLabels(E));
    xtickangle(ax,30);

    ylabel(ax,'Candidate minus reference RMSE');
    title(ax,'Paired bootstrap 95% CI for RMSE difference');
end

hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');
grid(ax,'on');
box(ax,'on');

if ~isempty(E)

    n = height(E);
    x = 1:n;

    bar(ax,x,E.BootstrapProbabilityWithinSimplicityMargin);

    yline(ax,0.95,':','95% probability','HandleVisibility','off');

    xticks(ax,x);
    xticklabels(ax,shortEvidenceLabels(E));
    xtickangle(ax,30);

    ylim(ax,[0 1.05]);

    ylabel(ax,'Bootstrap probability');
    title(ax,'Probability candidate is within Stage 6 simplicity margin');
end

hold(ax,'off');

exportMaybe( ...
    fig, ...
    fullfile(cfg.OUTPUT_FOLDER,"01_ModelReductionEvidence.png"), ...
    cfg);

%% 2. STATIC =============================================================

plotSubsystemArchitecture( ...
    stats.static, ...
    'Static scale: leave-one-current-out RMSE uncertainty', ...
    fullfile(cfg.OUTPUT_FOLDER,"02_StaticScaleStatistics.png"), ...
    cfg);

%% 3. FAST ===============================================================

plotSubsystemArchitecture( ...
    stats.fast, ...
    'Fast dynamics: current-level RMSE uncertainty', ...
    fullfile(cfg.OUTPUT_FOLDER,"03_FastDynamicsStatistics.png"), ...
    cfg);

%% 4. DELAY ==============================================================

plotDelayStatistics( ...
    stats.delay, ...
    fullfile(cfg.OUTPUT_FOLDER,"04_DelayStatistics.png"), ...
    cfg);

%% 5. DROOP ==============================================================

plotSubsystemArchitecture( ...
    stats.droop, ...
    'Ordinary droop: current-level RMSE uncertainty', ...
    fullfile(cfg.OUTPUT_FOLDER,"05_DroopStatistics.png"), ...
    cfg);

%% 6. COLLAPSE ===========================================================

plotSubsystemArchitecture( ...
    stats.collapse, ...
    'Compliance collapse: current-level RMSE uncertainty', ...
    fullfile(cfg.OUTPUT_FOLDER,"06_CollapseStatistics.png"), ...
    cfg);

%% 7. EXACT SIGN-FLIP P VALUES ==========================================

fig = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[90 90 1500 850]);

tl = tiledlayout(fig,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Exact paired sign-flip tests, Holm-adjusted within subsystem');

plotPairwiseP(nexttile(tl),stats.static.pairwise,'Static');
plotPairwiseP(nexttile(tl),stats.fast.pairwise,'Fast dynamics');
plotPairwiseP(nexttile(tl),stats.droop.pairwise,'Ordinary droop');
plotPairwiseP(nexttile(tl),stats.collapse.pairwise,'Compliance collapse');

exportMaybe( ...
    fig, ...
    fullfile(cfg.OUTPUT_FOLDER,"07_PairwiseExactTests.png"), ...
    cfg);

end

%% ========================================================================
% SUBSYSTEM ARCHITECTURE FIGURE
% ========================================================================

function plotSubsystemArchitecture(A,superTitle,path,cfg)

if isempty(A) || ~isfield(A,'architecture') || isempty(A.architecture)
    return;
end

vis = onOff(cfg.SHOW_FIGURES);

fig = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[70 70 1450 850]);

tl = tiledlayout(fig,1,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,superTitle);

T = A.architecture;

ax = nexttile(tl);
hold(ax,'on');
grid(ax,'on');
box(ax,'on');

x = 1:height(T);

errorbar( ...
    ax, ...
    x, ...
    T.ObservedScore, ...
    T.ObservedScore-T.CI95_Lower, ...
    T.CI95_Upper-T.ObservedScore, ...
    'o', ...
    'LineWidth',1.3, ...
    'MarkerSize',7);

xticks(ax,x);
xticklabels(ax,replace(T.Architecture,"_"," "));
xtickangle(ax,25);

ylabel(ax,'RMSE');
title(ax,'Observed score with paired-bootstrap 95% CI');

hold(ax,'off');

ax = nexttile(tl);
hold(ax,'on');
grid(ax,'on');
box(ax,'on');

bar(ax,x,T.ProbabilityBest);

yline(ax,0.5,':','HandleVisibility','off');

xticks(ax,x);
xticklabels(ax,replace(T.Architecture,"_"," "));
xtickangle(ax,25);

ylim(ax,[0 1.05]);

ylabel(ax,'Bootstrap probability');
title(ax,'Probability architecture has lowest RMSE');

hold(ax,'off');

exportMaybe(fig,path,cfg);
end

%% ========================================================================
% DELAY FIGURE
% ========================================================================

function plotDelayStatistics(D,path,cfg)

if isempty(D) || ~isfield(D,'architecture') || isempty(D.architecture)
    return;
end

vis = onOff(cfg.SHOW_FIGURES);

classes = unique(D.architecture.TransitionClass,'stable');

fig = figure( ...
    'Visible',vis, ...
    'Color','w', ...
    'Position',[80 80 1500 900]);

tl = tiledlayout(fig,2,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

title(tl,'Delay architecture statistics using leave-one-current-out prediction');

for c = 1:min(4,numel(classes))

    cls = classes(c);

    T = D.architecture(D.architecture.TransitionClass==cls,:);

    ax = nexttile(tl);
    hold(ax,'on');
    grid(ax,'on');
    box(ax,'on');

    x = 1:height(T);

    errorbar( ...
        ax, ...
        x, ...
        T.ObservedScore, ...
        T.ObservedScore-T.CI95_Lower, ...
        T.CI95_Upper-T.ObservedScore, ...
        'o', ...
        'LineWidth',1.2);

    xticks(ax,x);
    xticklabels(ax,replace(T.Architecture,"_"," "));
    xtickangle(ax,25);

    ylabel(ax,'LOOCV delay RMSE (us)');
    title(ax,replace(cls,"_"," "));

    hold(ax,'off');
end

exportMaybe(fig,path,cfg);
end

%% ========================================================================
% P-VALUE FIGURE
% ========================================================================

function plotPairwiseP(ax,P,titleText)

grid(ax,'on');
box(ax,'on');

if isempty(P)
    axis(ax,'off');
    return;
end

p = P.HolmAdjustedExactSignFlipP;

bar(ax,1:height(P),-log10(max(p,eps)));

yline(ax,-log10(0.05),':','p = 0.05','HandleVisibility','off');

labels = P.ArchitectureA + " vs " + P.ArchitectureB;

xticks(ax,1:height(P));
xticklabels(ax,replace(labels,"_"," "));
xtickangle(ax,35);

ylabel(ax,'-log10 adjusted p');
title(ax,titleText);
end

%% ========================================================================
% LABELS / EXPORT
% ========================================================================

function labels = shortEvidenceLabels(E)

labels = strings(height(E),1);

for i = 1:height(E)

    s = E.Subsystem(i);

    if startsWith(s,"DELAY_")
        prefix = replace(extractAfter(s,"DELAY_"),"_"," ");
    else
        prefix = replace(s,"_"," ");
    end

    c = replace(E.CandidateArchitecture(i),"_"," ");
    r = replace(E.ReferenceArchitecture(i),"_"," ");

    labels(i) = prefix + ": " + c + " / " + r;
end
end

function exportMaybe(fig,path,cfg)

if cfg.SAVE_PLOTS
    exportgraphics( ...
        fig, ...
        path, ...
        'Resolution',cfg.FIGURE_RESOLUTION_DPI, ...
        'BackgroundColor','white');
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
