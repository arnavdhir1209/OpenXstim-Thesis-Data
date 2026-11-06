
%% build_openxstim_B2B4.m
% Build an editable burst-level discrete PI model.

if ~exist('P','var') || ~isfield(P,'B2')
    openxstim_B2B4_params;
end

m = P.model;

if bdIsLoaded(m)
    close_system(m, 0);
end

new_system(m);

set_param(m, ...
    'SolverType', 'Fixed-step', ...
    'Solver', 'FixedStepDiscrete', ...
    'FixedStep', num2str(P.Ts,17), ...
    'StopTime', num2str(P.stopTime,17), ...
    'StartTime', '0', ...
    'ReturnWorkspaceOutputs', 'on');

add = @(lib,name,pos) ...
    add_block(lib,[m '/' name],'Position',pos);

wire = @(src,dst) ...
    add_line(m,src,dst,'autorouting','on');

%% Reference and error

add('simulink/Sources/Constant', ...
    'Reference',[30 140 110 180]);

set_param([m '/Reference'], ...
    'Value',num2str(P.r,17));

add('simulink/Math Operations/Sum', ...
    'Error',[155 137 190 181]);

set_param([m '/Error'],'Inputs','+-');

%% PI enable

add('simulink/Math Operations/Gain', ...
    'Enable_PI',[220 136 305 181]);

set_param([m '/Enable_PI'], ...
    'Gain',num2str(P.enablePI,17));

%% Approximate controller deadband

add('simulink/Math Operations/Abs', ...
    'Absolute_error',[325 232 375 265]);

add('simulink/Sources/Constant', ...
    'Deadband_mA',[325 300 395 333]);

set_param([m '/Deadband_mA'], ...
    'Value',num2str(P.deadband,17));

add('simulink/Logic and Bit Operations/Relational Operator', ...
    'Outside_deadband',[420 234 475 270]);

set_param([m '/Outside_deadband'], ...
    'Operator','>');

add('simulink/Math Operations/Product', ...
    'Active_error',[515 137 555 181]);

%% Proportional controller

add('simulink/Math Operations/Gain', ...
    'Kp',[590 55 675 100]);

set_param([m '/Kp'], ...
    'Gain',num2str(P.Kp,17));

%% Integral controller

% First B4 RUNNING sample has dt_ms = 0.
% Integral accumulation begins at the next sample.

add('simulink/Sources/Step', ...
    'Integrator_start',[590 285 665 325]);

set_param([m '/Integrator_start'], ...
    'Time',num2str(P.Ts/2,17), ...
    'Before','0', ...
    'After','1');

add('simulink/Math Operations/Product', ...
    'Integral_active_error',[605 150 650 190]);

add('simulink/Math Operations/Gain', ...
    'Ki_Ts',[685 151 770 195]);

set_param([m '/Ki_Ts'], ...
    'Gain',num2str(P.Ki*P.Ts,17));

add('simulink/Discrete/Unit Delay', ...
    'Integral_state',[800 300 875 342]);

set_param([m '/Integral_state'], ...
    'SampleTime',num2str(P.Ts,17), ...
    'InitialCondition',num2str(P.xI0,17));

add('simulink/Math Operations/Sum', ...
    'Integral_updated',[810 151 850 198]);

set_param([m '/Integral_updated'], ...
    'Inputs','++');

%% Feedforward

add('simulink/Math Operations/Gain', ...
    'Feedforward',[145 30 245 72]);

set_param([m '/Feedforward'], ...
    'Gain',num2str(P.Cff,17));

%% Next command and applied command

add('simulink/Math Operations/Sum', ...
    'Next_raw',[930 130 975 201]);

set_param([m '/Next_raw'], ...
    'Inputs','+++');

add('simulink/Math Operations/Rounding Function', ...
    'Next_counter',[1010 143 1100 190]);

set_param([m '/Next_counter'], ...
    'Operator','round');

add('simulink/Discrete/Unit Delay', ...
    'Applied_counter',[1135 135 1245 196]);

set_param([m '/Applied_counter'], ...
    'SampleTime',num2str(P.Ts,17), ...
    'InitialCondition',num2str(P.u0,17));

%% Plant from B2 baseline and B4 local slope

add('simulink/Sources/Constant', ...
    'Anchor_counter',[1125 250 1200 280]);

set_param([m '/Anchor_counter'], ...
    'Value',num2str(P.anchorCounter,17));

add('simulink/Math Operations/Sum', ...
    'Counter_delta',[1290 138 1330 186]);

set_param([m '/Counter_delta'], ...
    'Inputs','+-');

add('simulink/Math Operations/Gain', ...
    'Plant_gain',[1365 141 1465 184]);

set_param([m '/Plant_gain'], ...
    'Gain',num2str(P.Kplant,17));

add('simulink/Sources/Constant', ...
    'B2_baseline_mA',[1365 245 1465 278]);

set_param([m '/B2_baseline_mA'], ...
    'Value',num2str(P.anchorCurrent,17));

add('simulink/Math Operations/Sum', ...
    'True_current',[1510 135 1550 191]);

set_param([m '/True_current'], ...
    'Inputs','++');

%% Current measurement variability

add('simulink/Sources/From Workspace', ...
    'B2_noise',[1410 345 1515 380]);

set_param([m '/B2_noise'], ...
    'VariableName','B2_noise_input', ...
    'Interpolate','off', ...
    'OutputAfterFinalValue','Holding final value');

add('simulink/Math Operations/Gain', ...
    'Noise_enable',[1560 341 1640 385]);

set_param([m '/Noise_enable'], ...
    'Gain',num2str(P.noiseEnabled,17));

add('simulink/Math Operations/Sum', ...
    'Measured_current',[1690 139 1730 189]);

set_param([m '/Measured_current'], ...
    'Inputs','++');

%% Signal connections

wire('Reference/1','Error/1');
wire('Reference/1','Feedforward/1');

wire('Error/1','Enable_PI/1');

wire('Enable_PI/1','Absolute_error/1');

wire('Absolute_error/1','Outside_deadband/1');

wire('Deadband_mA/1','Outside_deadband/2');

wire('Enable_PI/1','Active_error/1');

wire('Outside_deadband/1','Active_error/2');

wire('Active_error/1','Kp/1');

wire('Active_error/1','Integral_active_error/1');

wire('Integrator_start/1','Integral_active_error/2');

wire('Integral_active_error/1','Ki_Ts/1');

wire('Ki_Ts/1','Integral_updated/1');

wire('Integral_state/1','Integral_updated/2');

wire('Integral_updated/1','Integral_state/1');

wire('Feedforward/1','Next_raw/1');

wire('Kp/1','Next_raw/2');

wire('Integral_updated/1','Next_raw/3');

wire('Next_raw/1','Next_counter/1');

wire('Next_counter/1','Applied_counter/1');

wire('Applied_counter/1','Counter_delta/1');

wire('Anchor_counter/1','Counter_delta/2');

wire('Counter_delta/1','Plant_gain/1');

wire('Plant_gain/1','True_current/1');

wire('B2_baseline_mA/1','True_current/2');

wire('True_current/1','Measured_current/1');

wire('B2_noise/1','Noise_enable/1');

wire('Noise_enable/1','Measured_current/2');

wire('Measured_current/1','Error/2');

%% Log signals

logNames = {
    'reference_mA'
    'measured_mA'
    'true_mA'
    'error_mA'
    'counter_applied'
    'counter_next'
    'proportional_counts'
    'integral_counts'
};

sources = {
    'Reference/1'
    'Measured_current/1'
    'True_current/1'
    'Error/1'
    'Applied_counter/1'
    'Next_counter/1'
    'Kp/1'
    'Integral_updated/1'
};

for j = 1:numel(logNames)

    blk = ['Log_' logNames{j}];
    yy = 50 + 70*(j-1);

    add('simulink/Sinks/To Workspace', ...
        blk,[1840 yy 1995 yy+35]);

    set_param([m '/' blk], ...
        'VariableName',logNames{j}, ...
        'SaveFormat','Timeseries');

    wire(sources{j},[blk '/1']);
end

%% Current scope

add('simulink/Signal Routing/Mux', ...
    'Current_traces',[1785 660 1795 730]);

set_param([m '/Current_traces'],'Inputs','2');

add('simulink/Sinks/Scope', ...
    'Current_scope',[1850 672 1895 718]);

wire('Reference/1','Current_traces/1');

wire('Measured_current/1','Current_traces/2');

wire('Current_traces/1','Current_scope/1');

%% Arrange and save

try
    Simulink.BlockDiagram.arrangeSystem(m);
catch
    % Keep explicitly assigned positions if needed.
end

save_system(m,[m '.slx']);

open_system(m);

fprintf('Saved %s.slx\n',m);
fprintf('Sample period: %.6f s\n',P.Ts);
