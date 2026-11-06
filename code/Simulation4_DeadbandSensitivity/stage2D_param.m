
%% stage2D_params.m
% OpenXstim Stage 2D configuration
% No modification to earlier stages.

D2 = struct();

D2.reference = 10;
D2.I0 = 9.593752;
D2.u0 = 215;
D2.x0 = 0;
D2.K = 0.0458338958;

D2.Ts = 0.0825;
D2.tShort = 0.076;
D2.tLong = 0.089;

D2.stopTime = 60;
D2.finalWindow = 20;

D2.calibration = 21.5;
D2.globalMax = 322;
D2.trim = 25;

D2.deadbands = [0.03 0.05 0.08];

D2.names = { ...
    'Empirical'; ...
    'Conservative'; ...
    'Moderately faster'};

D2.Kp = [5 4.942848 4.867577];
D2.Ki = [3 4.879279 9.758558];

D2.seeds = 1001:1030;
D2.offsetSeeds = 1001:1010;
D2.offsets = [-0.02 0 0.02];

D2.phases = {'shortFirst','longFirst'};

% Trailing moving-average convergence analysis.
% Approximate 2-second window using burst samples.
D2.averageWindow_s = 2.0;
D2.minimumHold_s = 1.0;

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end

D2.scriptDir = scriptDir;

D2.outputDir = fullfile( ...
    scriptDir,'Stage2D_Results');

if ~exist(D2.outputDir,'dir')
    mkdir(D2.outputDir);
end

% B2 can be located alongside this script.
found = dir(fullfile(scriptDir, ...
    'B2 4k 10mA*.csv'));

D2.B2file = '';

if ~isempty(found)
    D2.B2file = fullfile( ...
        found(1).folder,found(1).name);
end

% Optional: Stage 2C comparison CSV.
% Set manually if stored elsewhere.
D2.stage2Ccsv = fullfile( ...
    scriptDir,'2C_combined_trials.csv');

% Frozen parameters expected from Stage 2C.
D2.Kcases = [ ...
    0.04484619;
    0.0458338958;
    0.04615394;
    0.04650156];

assert(exist('stage2C_sim','file')==2, ...
    'Add the frozen Stage 2C directory to MATLAB path.');

assert(~isempty(D2.B2file) && isfile(D2.B2file), ...
    'Place B2 CSV beside stage2D_params.m.');

fprintf('\nStage 2D configuration loaded.\n');
fprintf('Deadbands: %.3f, %.3f, %.3f mA\n', ...
    D2.deadbands);
fprintf('PI controller gains remain frozen.\n');
fprintf('B2 input: %s\n',D2.B2file);
