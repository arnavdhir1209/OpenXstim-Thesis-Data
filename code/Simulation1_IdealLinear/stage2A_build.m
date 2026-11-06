
%% stage2A_build.m
% Build an ideal linear Stage 2A model.
% Does not overwrite Stage 1.

if ~exist('S2','var')
    stage2A_params;
end

m = S2.model;

if bdIsLoaded(m)
    close_system(m,0);
end

new_system(m);

set_param(m, ...
    'SolverType','Fixed-step', ...
    'Solver','FixedStepDiscrete', ...
    'FixedStep',num2str(S2.Ts,17), ...
    'StopTime',num2str(S2.stopTime,17), ...
    'StartTime','0', ...
    'ReturnWorkspaceOutputs','on');

add = @(lib,n,pos) ...
    add_block(lib,[m '/' n],'Position',pos);

ln = @(a,b) ...
    add_line(m,a,b,'autorouting','on');

%% Reference and error

add('simulink/Sources/Constant', ...
    'Reference',[40 55 110 85]);

set_param([m '/Reference'], ...
    'Value',num2str(S2.r,17));

add('simulink/Math Operations/Sum', ...
    'Error',[142 132 172 169]);

set_param([m '/Error'],'Inputs','+-');

%% Proportional action

add('simulink/Math Operations/Gain', ...
    'Kp',[205 112 270 150]);

set_param([m '/Kp'], ...
    'Gain',num2str(S2.Kp(1),17));

%% Integral action with first-update hold

add('simulink/Sources/Step', ...
    'Integral_enable_after_first', ...
    [205 240 275 274]);

set_param([m '/Integral_enable_after_first'], ...
    'Time',num2str(S2.Ts/2,17), ...
    'Before','0', ...
    'After','1', ...
    'SampleTime',num2str(S2.Ts,17));

add('simulink/Math Operations/Product', ...
    'Active_error',[310 175 347 215]);

add('simulink/Math Operations/Gain', ...
    'KiTs',[378 173 455 214]);

set_param([m '/KiTs'], ...
    'Gain',num2str(S2.Ki(1)*S2.Ts,17));

add('simulink/Math Operations/Sum', ...
    'Integral_updated',[493 174 523 212]);

set_param([m '/Integral_updated'], ...
    'Inputs','++');

add('simulink/Discrete/Unit Delay', ...
    'Integral_previous',[486 290 568 334]);

set_param([m '/Integral_previous'], ...
    'InitialCondition',num2str(S2.x0,17), ...
    'SampleTime',num2str(S2.Ts,17));

%% Feedforward and next command

add('simulink/Sources/Constant', ...
    'Feedforward',[450 35 525 65]);

set_param([m '/Feedforward'], ...
    'Value',num2str(S2.ff,17));

add('simulink/Math Operations/Sum', ...
    'Next_counter',[615 125 655 198]);

set_param([m '/Next_counter'], ...
    'Inputs','+++');

add('simulink/Discrete/Unit Delay', ...
    'Applied_counter',[697 138 782 181]);

set_param([m '/Applied_counter'], ...
    'InitialCondition',num2str(S2.u0,17), ...
    'SampleTime',num2str(S2.Ts,17));

%% Static affine plant

add('simulink/Sources/Constant', ...
    'Anchor_counter',[697 254 772 284]);

set_param([m '/Anchor_counter'], ...
    'Value',num2str(S2.u0,17));

add('simulink/Math Operations/Sum', ...
    'Counter_delta',[820 138 860 180]);

set_param([m '/Counter_delta'], ...
    'Inputs','+-');

add('simulink/Math Operations/Gain', ...
    'Plant_gain',[897 138 986 180]);

set_param([m '/Plant_gain'], ...
    'Gain',num2str(S2.K,17));

add('simulink/Sources/Constant', ...
    'Anchor_current',[890 250 980 285]);

set_param([m '/Anchor_current'], ...
    'Value',num2str(S2.I0,17));

add('simulink/Math Operations/Sum', ...
    'Plant_current',[1030 138 1070 181]);

set_param([m '/Plant_current'], ...
    'Inputs','++');

%% Connections

ln('Reference/1','Error/1');
ln('Plant_current/1','Error/2');

ln('Error/1','Kp/1');
ln('Error/1','Active_error/1');

ln('Integral_enable_after_first/1', ...
   'Active_error/2');

ln('Active_error/1','KiTs/1');

ln('KiTs/1','Integral_updated/1');
ln('Integral_previous/1','Integral_updated/2');
ln('Integral_updated/1','Integral_previous/1');

ln('Feedforward/1','Next_counter/1');
ln('Kp/1','Next_counter/2');
ln('Integral_updated/1','Next_counter/3');

ln('Next_counter/1','Applied_counter/1');

ln('Applied_counter/1','Counter_delta/1');
ln('Anchor_counter/1','Counter_delta/2');

ln('Counter_delta/1','Plant_gain/1');
ln('Plant_gain/1','Plant_current/1');
ln('Anchor_current/1','Plant_current/2');

%% Log signals

names = {
    's2_reference'
    's2_current'
    's2_error'
    's2_applied'
    's2_next'
    's2_p'
    's2_integral'
};

sources = {
    'Reference/1'
    'Plant_current/1'
    'Error/1'
    'Applied_counter/1'
    'Next_counter/1'
    'Kp/1'
    'Integral_updated/1'
};

for j = 1:numel(names)

    nm = ['Log_' names{j}];

    add('simulink/Sinks/To Workspace', ...
        nm, ...
        [1140 40+65*(j-1) 1300 72+65*(j-1)]);

    set_param([m '/' nm], ...
        'VariableName',names{j}, ...
        'SaveFormat','Timeseries');

    ln(sources{j},[nm '/1']);

end

%% Arrange and save separate model

try
    Simulink.BlockDiagram.arrangeSystem(m);
catch
    % Retain manually assigned positions.
end

save_system(m,fullfile(pwd,[m '.slx']));

open_system(m);

fprintf('Created model %s.slx\n',m);
