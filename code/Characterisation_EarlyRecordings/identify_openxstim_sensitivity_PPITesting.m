%% identify_openxstim_sensitivity.m
% Standalone DAC-current sensitivity study. Place beside the CSV files.
% Does NOT modify the Simulink model.
clearvars; close all; clc;
root = fileparts(mfilename('fullpath'));
if isempty(root), root = pwd; end
% Put generated outputs in a dedicated folder under the working directory.
outputDir = fullfile(pwd, 'DAC_Sensitivity_Results');
if ~exist(outputDir, 'dir')
    mkdir(outputDir);
end
files = { ...
 'Open Loop DAC sweep 1k.csv', 1000, 'OPEN_LOOP'; ...
 'Open Loop 1k.csv',           1000, 'OPEN_LOOP'; ...
 'PI_Control DAC Sweep 1k.csv',1000,'PI_CONTROL'; ...
 'B1 2k 10mA.csv',            2000, 'OPEN_LOOP'; ...
 'B3 2k 10mA.csv',            2000, 'PI_CONTROL'; ...
 'B2 4k 10mA.csv',            4000, 'OPEN_LOOP'; ...
 'B4 4k 10mA.csv',            4000, 'PI_CONTROL'};

% A local operating region for your 10 mA control target.
localCounterRange = [195 235];
minDistinct = 2;

result = table(); detail = struct([]);
figure('Name','DAC-to-current sensitivity by load','Color','w');
tiledlayout(1,3,'TileSpacing','compact');
loads = [1000 2000 4000];
for q = 1:numel(loads)
    nexttile; hold on; grid on;
    xlabel('Applied DAC Counter'); ylabel('Measured current (mA)');
    title(sprintf('%g kOhm',loads(q)/1000));
end

for j=1:size(files,1)
    filename = files{j,1}; R = files{j,2}; modeExpected = files{j,3};
    fullpath = fullfile(root,filename);
    if ~isfile(fullpath)
        warning('Missing %s. Skipping.',filename); continue;
    end
    T = readtable(fullpath);
    needed = {'stim_state','mode','counter_applied','measured_mA'};
    assert(all(ismember(needed,T.Properties.VariableNames)), ...
        'Expected columns absent in %s',filename);
    valid = strcmpi(string(T.stim_state),'RUNNING') & ...
            strcmpi(string(T.mode),modeExpected) & ...
            isfinite(double(T.counter_applied)) & ...
            isfinite(double(T.measured_mA));
    if ismember('fault_code',T.Properties.VariableNames)
        valid = valid & strcmpi(string(T.fault_code),'NONE');
    end
    if ismember('command_limited',T.Properties.VariableNames)
        valid = valid & double(T.command_limited)==0;
    end
    if ismember('reference_limited',T.Properties.VariableNames)
        valid = valid & double(T.reference_limited)==0;
    end
    u=double(T.counter_applied(valid)); y=double(T.measured_mA(valid));
    before=numel(u);
    if isempty(u), warning('No valid samples in %s',filename); continue; end

    % Screen extreme readings relative to others at the SAME DAC command.
    % Requires at least five observations at that command.
    keep=true(size(u)); codes=unique(u);
    for c=codes(:)'
        ix=find(u==c);
        if numel(ix)<5, continue; end
        med=median(y(ix)); mad0=median(abs(y(ix)-med));
        threshold=max(0.25,6*1.4826*mad0); % mA
        keep(ix)=abs(y(ix)-med)<=threshold;
    end
    u=u(keep);y=y(keep);
    excluded=before-numel(u);
    codes=unique(u); nCodes=numel(codes);
    groupMean=zeros(nCodes,1); groupMedian=zeros(nCodes,1);
    groupN=zeros(nCodes,1);
    for k=1:nCodes
       z=y(u==codes(k));
       groupMean(k)=mean(z);groupMedian(k)=median(z);groupN(k)=numel(z);
    end

    slope=NaN; intercept=NaN; R2=NaN;
    slopeGrouped=NaN; localSlope=NaN;
    if nCodes>=minDistinct
       coeff=polyfit(u,y,1);
       slope=coeff(1);intercept=coeff(2);
       pred=polyval(coeff,u);
       denom=sum((y-mean(y)).^2);
       if denom>0,R2=1-sum((y-pred).^2)/denom;end
       coeffG=polyfit(codes,groupMedian,1);
       slopeGrouped=coeffG(1);
       m=u>=localCounterRange(1) & u<=localCounterRange(2);
       if numel(unique(u(m)))>=minDistinct
           coeffL=polyfit(u(m),y(m),1);
           localSlope=coeffL(1);
       end
    end

    label=string(filename);
    result=[result;table(label,R,string(modeExpected),numel(u),nCodes,excluded, ...
        slope,slopeGrouped,localSlope,intercept,R2, ...
        'VariableNames',{'File','Load_Ohm','Mode','Samples','DistinctCodes', ...
        'Excluded','SlopeRaw_mA_per_count','SlopeGroupMedian', ...
        'SlopeLocal','Intercept_mA','R2'})]; %#ok<AGROW>

    detail(end+1).file=filename; %#ok<SAGROW>
    detail(end).loadOhm=R; detail(end).mode=modeExpected;
    detail(end).codes=codes;detail(end).medianCurrent=groupMedian;
    detail(end).meanCurrent=groupMean;detail(end).counts=groupN;

    tile=find(loads==R); nexttile(tile);
    if strcmp(modeExpected,'OPEN_LOOP'), lineStyle='o-'; else, lineStyle='s--'; end
    plot(codes,groupMedian,lineStyle,'DisplayName',erase(filename,'.csv'));
    legend('Location','best','Interpreter','none');
end

disp(' ');disp('PER-DATASET DAC SENSITIVITY');disp(result);
writetable(result,fullfile(outputDir,'dac_sensitivity_results.csv'));
save(fullfile(outputDir,'dac_sensitivity_results.mat'), ...
    'result','detail','localCounterRange');
exportgraphics(gcf,fullfile(outputDir,'dac_sensitivity_by_load.png'), ...
    'Resolution',200);

% Print a clear interpretation with no unsupported pooled slope.
fprintf('\nMAIN INTERPRETATION\n');
for R=loads
    ix=result.Load_Ohm==R & result.Mode=="OPEN_LOOP" & ...
       result.DistinctCodes>=2;
    if any(ix)
        subset=result(ix,:);
        [~,k]=max(subset.DistinctCodes);
        fprintf('%g kOhm: strongest open-loop sweep = %s, K=%.6f mA/count (%d codes)\n', ...
           R/1000,subset.File(k),subset.SlopeRaw_mA_per_count(k),subset.DistinctCodes(k));
    else
        fprintf('%g kOhm: no multi-code open-loop fit available.\n',R/1000);
    end
end
fprintf('\nDo not pool loads or use closed-loop slopes as independent validation.\n');
fprintf('Results saved in the script folder.\n');
