
%% stage2C_params.m
% Frozen Stage 2C parameters.
% Does not modify Stage 1, Stage 2A or Stage 2B.

C = struct();

% Reference and initial conditions
C.r = 10;
C.I0 = 9.593752;
C.u0 = 215;
C.x0 = 0;

% Independent open-loop plant identification
C.K = 0.0458338958;

% Oscilloscope-derived timing
C.Ts = 0.0825;
C.tShort = 0.076;
C.tLong = 0.089;

% Simulation horizon
C.stopTime = 60;
C.finalWindow = 20;

% Verified firmware constants
C.calibration = 21.5;
C.globalMax = 322;
C.trim = 25;
C.deadband = 0.03;

% Frozen controllers
C.names = {
    'Empirical'
    'Conservative'
    'Moderately faster'
};

C.Kp = [5, 4.942848, 4.867577];
C.Ki = [3, 4.879279, 9.758558];

% Independent open-loop gain estimates
C.Kcases = [
    0.04484619
    0.0458338958
    0.04615394
    0.04650156
];

% 30 reproducible, paired noise trials
C.seeds = 1001:1030;

% Paths
C.scriptDir = fileparts(mfilename('fullpath'));

if isempty(C.scriptDir)
    C.scriptDir = pwd;
end

C.outputDir = fullfile(C.scriptDir, ...
    'Stage2C_Results');

if ~exist(C.outputDir, 'dir')
    mkdir(C.outputDir);
end

% Automatically locate B2 if placed alongside scripts.
C.B2file = '';

files = dir(fullfile(C.scriptDir, ...
    'B2 4k 10mA*.csv'));

if ~isempty(files)
    C.B2file = fullfile( ...
        files(1).folder, files(1).name);
end

fprintf('Stage 2C nominal Ts: %.4f s\n', C.Ts);

fprintf('Noise trials: %d paired seeds\n', ...
    numel(C.seeds));
