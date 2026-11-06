%% stage2B_params.m | Independent Stage 2B settings
B = struct();
B.model = 'OpenXstim_Stage2B_Firmware';
B.Ts=0.0825; B.stopTime=60; B.r=10; B.I0=9.593752;
B.K=0.0458338958; B.u0=215; B.x0=0;
B.calibration=21.5; B.maxTestCurrent=15;
B.globalMax=floor(B.calibration*B.maxTestCurrent); % 322
B.trim=25; B.deadband=0.03;
B.names={'Empirical','Conservative','Moderately faster'};
B.Kp=[5,4.942848,4.867577];
B.Ki=[3,4.879279,9.758558];
% Feature switches [round, deadband, clamp, antiwindup]
B.configNames={'Ideal','Quantised','Quantised + deadband', ...
    'Quantised + deadband + limits','Full firmware PI'};
B.features=[0 0 0 0;1 0 0 0;1 1 0 0;1 1 1 0;1 1 1 1];
B.outputDir=fullfile(pwd,'Stage2B_Results');
if ~exist(B.outputDir,'dir'), mkdir(B.outputDir); end
% Stress: 2 mA temporary additive measurement/plant-current offset.
% This is a synthetic plant disturbance, not voltage compliance.
B.stressAmplitude=-2; B.stressStart=10; B.stressEnd=25;
B.finalWindow=20;
fprintf('Stage 2B: Ts = %.4f s, K = %.10f mA/count, global limit = %.0f\n', ...
    B.Ts,B.K,B.globalMax);
