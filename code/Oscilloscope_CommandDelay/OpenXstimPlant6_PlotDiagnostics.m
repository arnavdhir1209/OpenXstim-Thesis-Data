function OpenXstimPlant6_PlotDiagnostics( ...
    staticResult,fastResult,slowResult,R,cfg)
% OpenXstimPlant6_PlotDiagnostics
%
% Stage 6 plotting is intentionally split into:
%   A. meeting-ready evidence plots
%   B. engineering model-reduction diagnostics
%
% The figures are designed so the user has useful thesis-meeting material
% even if no fully unified model is ultimately accepted.

vis = onOff(cfg.SHOW_FIGURES);
currents = cfg.COMMAND_CURRENTS_mApp(:);

%% 1. MEETING SUMMARY ====================================================

fig=figure('Visible',vis,'Color','w','Position',[30 30 1550 950]);
tl=tiledlayout(fig,2,3,'TileSpacing','compact','Padding','compact');
title(tl,'Stage 6 OpenXstim model unification: evidence before Simulink implementation');

% Static
ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
S=staticResult.currentSummary;
errorbar(ax,S.CommandCurrent_mA,S.MeanMeasuredIpp_mA,S.SDMeasuredIpp_mA, ...
    'o','LineWidth',1.2,'DisplayName','Measured mean +/- SD');
xx=linspace(0,max(currents)*1.03,300).';
plot(ax,xx,R.static.gain*xx,'--','LineWidth',1.4,'DisplayName','Constant gain');
plot(ax,xx,R.static.quadratic(1)*xx+R.static.quadratic(2)*xx.^2, ...
    'LineWidth',1.6,'DisplayName','Quadratic through origin');
plot(ax,xx,xx,':','HandleVisibility','off');
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'Measured early current (mA p-p)');
title(ax,'Static amplitude scaling'); legend(ax,'Location','northwest');

% Fast local time trend
ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
for k=1:numel(currents)
    D=R.fast.data(k);
    if ~D.valid, continue; end
    if D.regime=="FULL_REVERSAL"
        plot(ax,D.current,D.localModel.t10_90_us,'o','MarkerSize',7, ...
            'HandleVisibility','off');
    else
        plot(ax,D.current,D.localModel.t10_90_us,'s','MarkerSize',7, ...
            'HandleVisibility','off');
    end
end
plot(ax,NaN,NaN,'o-','DisplayName','FULL_REVERSAL');
plot(ax,NaN,NaN,'s--','DisplayName','NEAR_ZERO_START');
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'Local fitted 10-90 time (us)');
title(ax,'Fast dynamics change mildly with current'); legend(ax,'Location','best');

% Delay
ax=nexttile(tl); plotDelayEvidence(ax,R.delay.delaySummary);

% Droop rate
ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
DR=slowResult.droopSummary; m=DR.Identifiable;
plot(ax,DR.CommandCurrent_mA(m),DR.Rate_per_ms(m),'o-','LineWidth',1.5, ...
    'DisplayName','Stage 5 local k');
yline(ax,R.droop.commonRate_per_ms,'--','DisplayName','Common k candidate');
if numel(R.droop.twoGroupRates_per_ms)>=2
    lowX=cfg.FULL_REVERSAL_CURRENTS_mApp;
    highX=cfg.NEAR_ZERO_START_CURRENTS_mApp;
    plot(ax,[min(lowX) max(lowX)],repmat(R.droop.twoGroupRates_per_ms(1),1,2), ...
        ':','LineWidth',1.5,'DisplayName','Full-reversal group k');
    plot(ax,[min(highX) max(highX)],repmat(R.droop.twoGroupRates_per_ms(2),1,2), ...
        '-.','LineWidth',1.5,'DisplayName','Near-zero group k');
end
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'Ordinary droop rate (1/ms)');
title(ax,'Ordinary pre-collapse droop'); legend(ax,'Location','best');

% Slow regime evidence
ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
for k=1:numel(currents)
    Scur=slowResult.byCurrent(k);
    if ~Scur.droop.identifiable, continue; end
    t=Scur.droop.time_us(:)/1000;
    y=Scur.droop.meanUsedWaveform(:);
    plot(ax,t,y,'LineWidth',1.1,'DisplayName',sprintf('%.0f mA',currents(k)));
end
xlabel(ax,'Time after passive-phase guard (ms)'); ylabel(ax,'Normalized current D(t)');
title(ax,'Two slow behaviours are visible'); ylim(ax,[0 1.03]);
legend(ax,'Location','southwest','NumColumns',2);

% Architecture summary
ax=nexttile(tl); axis(ax,'off');
text(ax,0.02,0.92,"Stage 6 recommendations",'FontWeight','bold','FontSize',12);
lines=[ ...
    "Static: " + R.static.recommended; ...
    "Fast: " + R.fast.recommended; ...
    "Delay: transition-class specific"; ...
    "Droop: " + R.droop.recommended; ...
    "Collapse: " + R.collapse.recommended; ...
    "30/50 mA fast responses remain flagged as PHYSICAL NEAR_ZERO_START"; ...
    "Stage 7: implement accepted common/grouped laws in Simulink"];
for q=1:numel(lines)
    text(ax,0.03,0.82-0.11*(q-1),lines(q),'Interpreter','none','FontSize',10.5);
end

saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"01_Stage6MeetingSummary.png"),cfg);

%% 2. STATIC SCALE ========================================================

fig=figure('Visible',vis,'Color','w','Position',[40 40 1350 600]);
tl=tiledlayout(fig,1,2,'TileSpacing','compact','Padding','compact');

ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
errorbar(ax,S.CommandCurrent_mA,S.MeanMeasuredIpp_mA,S.SDMeasuredIpp_mA, ...
    'o','LineWidth',1.3,'DisplayName','Measured current');
plot(ax,xx,R.static.gain*xx,'--','LineWidth',1.5,'DisplayName','Constant gain');
plot(ax,xx,R.static.quadratic(1)*xx+R.static.quadratic(2)*xx.^2, ...
    'LineWidth',1.7,'DisplayName','Quadratic through origin');
plot(ax,xx,xx,':','DisplayName','1:1');
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'Measured early current (mA p-p)');
title(ax,'Static-scale candidates'); legend(ax,'Location','northwest');

ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
resGain=R.static.measuredIpp_mA-R.static.predGain_mA;
resQuad=R.static.measuredIpp_mA-R.static.predQuadratic_mA;
plot(ax,R.static.commandCurrent_mA,resGain,'o-','DisplayName','Constant gain residual');
plot(ax,R.static.commandCurrent_mA,resQuad,'s-','DisplayName','Quadratic residual');
yline(ax,0,':','HandleVisibility','off');
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'Measured - predicted (mA p-p)');
title(ax,'Residual structure'); legend(ax,'Location','best');

sgtitle(fig,[ ...
    'Static scaling is empirical, not proof of intrinsic nonlinear gain' newline ...
    'Finite output impedance, load heating and calibration effects remain plausible']);
saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"02_StaticScaleUnification.png"),cfg);

%% 3. FAST DYNAMICS =======================================================

fig=figure('Visible',vis,'Color','w','Position',[35 35 1500 900]);
tl=tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');

t=R.fast.time_us;

ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
for k=1:numel(currents)
    D=R.fast.data(k);
    if D.valid
        plot(ax,t,D.y,'LineWidth',1,'DisplayName',sprintf('%.0f mA %s',D.current,D.regime));
    end
end
xline(ax,0,'--','HandleVisibility','off');
yline(ax,0.1,':','HandleVisibility','off'); yline(ax,0.9,':','HandleVisibility','off');
xlabel(ax,'Time from Stage 3 gradient peak (us)'); ylabel(ax,'Normalized current');
title(ax,'Physical fast responses used by Stage 6');
legend(ax,'Location','southeast','Interpreter','none','NumColumns',2);

ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
plotFastModelComparison(ax,R.fast,R.fast.allCommon.selected.model,"All-current common");
title(ax,sprintf('All-current common candidate | %s',R.fast.allCommon.selected.family), ...
    'Interpreter','none');

ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
plotFastGroup(ax,R.fast,"FULL_REVERSAL",R.fast.fullReversalCommon.selected.model);
title(ax,sprintf('FULL_REVERSAL common candidate | %s', ...
    R.fast.fullReversalCommon.selected.family),'Interpreter','none');

ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
plotFastGroup(ax,R.fast,"NEAR_ZERO_START",R.fast.nearZeroCommon.selected.model);
title(ax,sprintf('NEAR_ZERO_START common candidate | %s', ...
    R.fast.nearZeroCommon.selected.family),'Interpreter','none');

sgtitle(fig,[ ...
    'Fast-model unification test' newline ...
    'Physical regime is kept separate from firmware transition class']);
saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"03_FastDynamicsUnification.png"),cfg);

%% 4. DELAY ===============================================================

fig=figure('Visible',vis,'Color','w','Position',[45 45 1450 850]);
tl=tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');

classes=["pos_to_neg","neg_to_pos","neg_to_zero","zero_to_pos"];
for q=1:numel(classes)
    ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
    plotDelayClass(ax,R.delay,classes(q));
end
sgtitle(fig,[ ...
    'Delay unification by firmware transition class' newline ...
    'High-current near-zero starts retain pos_to_neg / neg_to_pos firmware timing']);
saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"04_DelayUnification.png"),cfg);

%% 5. DROOP ===============================================================

fig=figure('Visible',vis,'Color','w','Position',[50 50 1450 850]);
tl=tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');

ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
plot(ax,DR.CommandCurrent_mA(m),DR.Rate_per_ms(m),'o-','LineWidth',1.5, ...
    'DisplayName','Local Stage 5 k');
yline(ax,R.droop.commonRate_per_ms,'--','LineWidth',1.5,'DisplayName','Common k');
xxI=linspace(min(currents),max(currents),200);
plot(ax,xxI,R.droop.linearCurrentCoeff(1)+R.droop.linearCurrentCoeff(2)*xxI, ...
    ':','LineWidth',1.7,'DisplayName','Linear k(I)');
plot(ax,[5 20],repmat(R.droop.twoGroupRates_per_ms(1),1,2),'-.','LineWidth',1.5, ...
    'DisplayName','Full-reversal group');
plot(ax,[30 50],repmat(R.droop.twoGroupRates_per_ms(2),1,2),'-.','LineWidth',1.5, ...
    'DisplayName','Near-zero group');
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'k (1/ms)');
title(ax,'Candidate droop grouping laws'); legend(ax,'Location','best');

ax=nexttile(tl); plotCandidateBars(ax,R.droop.candidates(2:end,:), ...
    'Architecture','MeanCurrentRMSE','Mean current RMSE');
title(ax,'Pre-collapse model-reduction error');

ax=nexttile(tl,[1 2]); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
for k=1:numel(currents)
    D=R.droop.data(k);
    if ~D.valid, continue; end
    plot(ax,D.t,D.y,'LineWidth',1,'DisplayName',sprintf('%.0f mA measured',D.current));
end
xlabel(ax,'Time after passive-phase guard (ms)'); ylabel(ax,'Normalized current D(t)');
title(ax,'Measured slow responses retained as evidence'); ylim(ax,[0 1.03]);
legend(ax,'Location','eastoutside','NumColumns',1);

sgtitle(fig,[ ...
    'Ordinary-droop unification test' newline ...
    'Common, smooth current-dependent and two-group laws are compared before Simulink']);
saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"05_DroopUnification.png"),cfg);

%% 6. SLOW BEHAVIOUR BY CURRENT ==========================================

fig=figure('Visible',vis,'Color','w','Position',[30 30 1500 1000]);
tl=tiledlayout(fig,3,2,'TileSpacing','compact','Padding','compact');

for k=1:numel(currents)
    ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
    Scur=slowResult.byCurrent(k);
    if ~Scur.droop.identifiable
        axis(ax,'off'); continue;
    end
    t=Scur.droop.time_us(:)/1000;
    y=Scur.droop.meanUsedWaveform(:);
    plot(ax,t,y,'LineWidth',1.6,'DisplayName','Measured mean phase');

    % Common candidate
    plot(ax,t,1-R.droop.commonRate_per_ms*t,'--','LineWidth',1.2, ...
        'DisplayName','Common ordinary droop');

    % Recommended candidate
    krec=recommendedDroopRate(R.droop,currents(k));
    plot(ax,t,1-krec*t,':','LineWidth',1.5,'DisplayName','Recommended ordinary droop');

    title(ax,sprintf('%.0f mA p-p',currents(k)));
    xlabel(ax,'Time after passive-phase guard (ms)'); ylabel(ax,'D(t)');
    ylim(ax,[0 1.03]);
    if k==1 || k==4
        legend(ax,'Location','best');
    end
end
sgtitle(fig,[ ...
    'Slow response evidence by current' newline ...
    'Ordinary droop is shown separately from later compliance collapse']);
saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"06_SlowBehaviourByCurrent.png"),cfg);

%% 7. COLLAPSE ============================================================

fig=figure('Visible',vis,'Color','w','Position',[40 40 1500 900]);
tl=tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');

collapseCurrents=[20 30 50];
for k=1:numel(collapseCurrents)
    I=collapseCurrents(k);
    idx=find(currents==I,1);
    ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
    D=R.collapse.data(idx);
    if ~D.valid
        axis(ax,'off'); continue;
    end
    scatter(ax,D.x,D.y,7,'filled','MarkerFaceAlpha',0.13, ...
        'DisplayName','Observed attenuation');
    xs=linspace(min(D.x),max(D.x),400).';
    plot(ax,xs,collapseUnifiedCurve(R.collapse.commonStretched.model,xs,I), ...
        '--','LineWidth',1.4,'DisplayName','All-current common stretched');
    plot(ax,xs,collapseUnifiedCurve(R.collapse.currentThresholdStretched.model,xs,I), ...
        ':','LineWidth',1.6,'DisplayName','Exploratory q0(I) stretched');
    if ismember(I,cfg.STRONG_COLLAPSE_CURRENTS_mApp) && ...
            isstruct(R.collapse.strongCollapseCommon) && ...
            isfield(R.collapse.strongCollapseCommon,'model')
        plot(ax,xs,collapseUnifiedCurve(R.collapse.strongCollapseCommon.model,xs,I), ...
            'LineWidth',1.7,'DisplayName','30/50 common strong-collapse');
    end
    xlabel(ax,'Continuous oriented charge state (uC)'); ylabel(ax,'Collapse attenuation C');
    title(ax,sprintf('%.0f mA p-p',I)); ylim(ax,[0 1.03]); legend(ax,'Location','best');
end

ax=nexttile(tl); plotCandidateBars(ax,R.collapse.candidates(2:end,:), ...
    'Architecture','MeanCurrentRMSE','Mean current RMSE');
title(ax,'Collapse architecture comparison');

sgtitle(fig,[ ...
    'Compliance-collapse model reduction' newline ...
    '20 mA transition regime is explicitly tested separately from 30/50 mA strong collapse']);
saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"07_CollapseUnification.png"),cfg);

%% 8. ARCHITECTURE SUMMARY ===============================================

fig=figure('Visible',vis,'Color','w','Position',[100 100 1250 700]);
ax=axes(fig); axis(ax,'off');

text(ax,0.05,0.92,'Candidate Stage 7 plant architecture','FontSize',18,'FontWeight','bold');
text(ax,0.05,0.82, ...
    'Command current  ->  static scale  ->  firmware-class delay  ->  fast dynamics  ->  ordinary droop  ->  compliance attenuation', ...
    'FontSize',12,'Interpreter','none');

text(ax,0.05,0.70,"Static scale",'FontWeight','bold','FontSize',12);
text(ax,0.25,0.70,R.static.recommended,'Interpreter','none','FontSize',12);

text(ax,0.05,0.60,"Delay",'FontWeight','bold','FontSize',12);
text(ax,0.25,0.60,"transition-class specific; literal startup and -I -> 0 boundary separate", ...
    'Interpreter','none','FontSize',12);

text(ax,0.05,0.50,"Fast dynamics",'FontWeight','bold','FontSize',12);
text(ax,0.25,0.50,R.fast.recommended,'Interpreter','none','FontSize',12);

text(ax,0.05,0.40,"Ordinary droop",'FontWeight','bold','FontSize',12);
text(ax,0.25,0.40,R.droop.recommended,'Interpreter','none','FontSize',12);

text(ax,0.05,0.30,"Compliance collapse",'FontWeight','bold','FontSize',12);
text(ax,0.25,0.30,R.collapse.recommended,'Interpreter','none','FontSize',12);

text(ax,0.05,0.17,[ ...
    'Important: 30/50 mA internal transitions keep their firmware +I/-I command class, ' ...
    'but are flagged as PHYSICAL NEAR_ZERO_START because compliance collapse changes the pre-state.'], ...
    'Interpreter','none','FontSize',11);

text(ax,0.05,0.08,[ ...
    'Stage 6 does not force one model. If common-model error is materially worse than grouped/local references, ' ...
    'Stage 7 should implement the required piecewise/current-dependent regimes.'], ...
    'Interpreter','none','FontSize',11);

saveFigure(fig,fullfile(cfg.OUTPUT_FOLDER,"08_ModelArchitectureSummary.png"),cfg);
end

%% HELPERS ================================================================

function plotFastModelComparison(ax,F,M,label)
for k=1:numel(F.data)
    D=F.data(k);
    if D.valid
        plot(ax,F.time_us,D.y,'LineWidth',0.9,'HandleVisibility','off');
    end
end
plot(ax,F.time_us,fastCurve(M,F.time_us),'k--','LineWidth',2,'DisplayName',label);
xline(ax,0,'--','HandleVisibility','off'); yline(ax,0.1,':','HandleVisibility','off'); yline(ax,0.9,':','HandleVisibility','off');
xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Normalized current');
legend(ax,'Location','southeast');
end

function plotFastGroup(ax,F,regime,M)
for k=1:numel(F.data)
    D=F.data(k);
    if D.valid && D.regime==regime
        plot(ax,F.time_us,D.y,'LineWidth',1,'DisplayName',sprintf('%.0f mA',D.current));
    end
end
if isfield(M,'modelName')
    plot(ax,F.time_us,fastCurve(M,F.time_us),'k--','LineWidth',2,'DisplayName','Common fit');
end
xline(ax,0,'--','HandleVisibility','off'); yline(ax,0.1,':','HandleVisibility','off'); yline(ax,0.9,':','HandleVisibility','off');
xlabel(ax,'Time from gradient peak (us)'); ylabel(ax,'Normalized current');
legend(ax,'Location','southeast');
end

function plotDelayEvidence(ax,T)
hold(ax,'on'); grid(ax,'on'); box(ax,'on');
series={ ...
    "pos_to_neg","+I -> -I"; ...
    "neg_to_pos","-I -> +I"; ...
    "neg_to_zero","-I -> 0 boundary"; ...
    "zero_to_pos","literal 0 -> +I"};
for q=1:size(series,1)
    m=string(T.TransitionClass)==series{q,1} & isfinite(T.MeanTransportDelay_us);
    if any(m)
        [x,ord]=sort(T.CommandCurrent_mA(m));
        y=T.MeanTransportDelay_us(m); y=y(ord);
        plot(ax,x,y,'o-','LineWidth',1.2,'DisplayName',series{q,2});
    end
end
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'Command to fast onset (us)');
title(ax,'Firmware-class delay remains structured'); legend(ax,'Location','best');
end

function plotDelayClass(ax,R,cls)
key=matlab.lang.makeValidName(cls);
if ~isfield(R.models,key)
    axis(ax,'off'); return;
end
M=R.models.(key);
plot(ax,M.x,M.y,'o','MarkerSize',7,'DisplayName','Stage 5 current means');
xx=linspace(min(M.x),max(M.x),200);
plot(ax,xx,repmat(M.constant,size(xx)),'--','DisplayName','Constant');
if all(isfinite(M.linearCoeff))
    plot(ax,xx,polyval(M.linearCoeff,xx),':','LineWidth',1.5,'DisplayName','Linear current');
end
if isfinite(M.splitLow) && isfinite(M.splitHigh)
    low=xx<=20; high=xx>=30;
    plot(ax,xx(low),repmat(M.splitLow,1,nnz(low)),'-.','LineWidth',1.5,'DisplayName','Full-reversal regime');
    plot(ax,xx(high),repmat(M.splitHigh,1,nnz(high)),'-.','LineWidth',1.5,'HandleVisibility','off');
end
xlabel(ax,'Commanded current (mA p-p)'); ylabel(ax,'Command to fast onset (us)');
title(ax,sprintf('%s | recommended: %s',prettyTransition(cls),M.recommended),'Interpreter','none');
legend(ax,'Location','best');
end

function s=prettyTransition(cls)
switch string(cls)
    case "pos_to_neg", s="+I -> -I";
    case "neg_to_pos", s="-I -> +I";
    case "neg_to_zero", s="-I -> 0 boundary";
    case "zero_to_pos", s="literal 0 -> +I startup";
    otherwise, s=string(cls);
end
end

function plotCandidateBars(ax,T,nameVar,valueVar,ylabelText)
if isempty(T), axis(ax,'off'); return; end
labels=categorical(string(T.(nameVar)));
bar(ax,labels,T.(valueVar));
grid(ax,'on'); box(ax,'on'); ylabel(ax,ylabelText);
xtickangle(ax,20);
end

function k=recommendedDroopRate(D,I)
switch string(D.recommended)
    case "COMMON_LINEAR"
        k=D.commonRate_per_ms;
    case "LINEAR_CURRENT"
        k=D.linearCurrentCoeff(1)+D.linearCurrentCoeff(2)*I;
    case "TWO_GROUP_LINEAR"
        if I<=20, k=D.twoGroupRates_per_ms(1); else, k=D.twoGroupRates_per_ms(2); end
    otherwise
        idx=find([D.data.current]==I,1);
        if isempty(idx), k=D.commonRate_per_ms; else, k=D.data(idx).localRate; end
end
end

function y=fastCurve(M,t)
x=t(:)-M.theta_us; y=zeros(size(x)); a=x>=0; xa=x(a);
switch string(M.modelName)
    case "FOP"
        y(a)=1-exp(-xa/M.tau_us);
    case "TWO_POLE"
        t1=M.tau1_us; t2=M.tau2_us;
        if abs(t1-t2)<1e-5*max(t1,t2)
            tau=.5*(t1+t2); y(a)=1-exp(-xa/tau).*(1+xa/tau);
        else
            y(a)=1-(t2*exp(-xa/t2)-t1*exp(-xa/t1))/(t2-t1);
        end
    case "SECOND_ORDER"
        wn=M.wn_rad_per_us; z=M.zeta;
        if z<1-1e-5
            wd=wn*sqrt(1-z^2);
            y(a)=1-exp(-z*wn*xa).*(cos(wd*xa)+z/sqrt(1-z^2)*sin(wd*xa));
        elseif z>1+1e-5
            q=sqrt(z^2-1); r1=-wn*(z-q); r2=-wn*(z+q);
            y(a)=1+(r2*exp(r1*xa)-r1*exp(r2*xa))/(r1-r2);
        else
            y(a)=1-exp(-wn*xa).*(1+wn*xa);
        end
end
end

function y=collapseUnifiedCurve(M,x,current)
x=x(:);
switch string(M.modelName)
    case "SHIFTED_EXP"
        z=max(x-M.q0,0); y=exp(-M.k*z);
    case "STRETCHED_EXP"
        z=max(x-M.q0,0); y=exp(-(z/M.scale).^M.power);
    case "Q0_LINEAR_STRETCHED_EXP"
        q0=M.q0Intercept+M.q0Slope*current;
        z=max(x-q0,0); y=exp(-(z/M.scale).^M.power);
    otherwise
        y=NaN(size(x));
end
end

function saveFigure(fig,path,cfg)
if cfg.SAVE_PLOTS
    drawnow;
    try
        exportgraphics(fig,path,'Resolution',cfg.FIGURE_RESOLUTION_DPI,'BackgroundColor','white');
    catch
        saveas(fig,path);
    end
end
if ~cfg.SHOW_FIGURES, close(fig); end
end

function s=onOff(tf)
if tf, s='on'; else, s='off'; end
end
