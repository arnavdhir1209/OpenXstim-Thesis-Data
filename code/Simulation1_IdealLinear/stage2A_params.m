
%% stage2A_params.m
% Independent Stage 2A configuration.
% No Stage 1 files changed.

S2 = struct();

S2.model = 'OpenXstim_Stage2A_Linear';

% Oscilloscope timing
S2.Ts = 0.0825;

% Reference and initial conditions
S2.r = 10;          % mA
S2.u0 = 215;        % applied DAC Counter
S2.x0 = 0;          % integral state, counts
S2.ff = 215;        % feedforward, counts

% Independently identified plant
S2.I0 = 9.593752;       % mA at Counter 215
S2.K = 0.0458338958;    % mA/count

% Gain-only sensitivity cases
S2.Kcases = [
    0.04484619
    0.0458338958
    0.04615394
    0.04650156
];

S2.stopTime = 60;

S2.names = {
    'Empirical'
    'Conservative'
    'Moderately faster'
};

% Existing empirical PI
kp0 = 5;
ki0 = 3;

% Pole-placement targets
pCons = [0.985, -0.23];
pFast = [0.970, -0.23];

% Calculate gains from exact PI polynomial
kpCons = -prod(pCons)/S2.K;
kiCons = prod(1-pCons)/(S2.K*S2.Ts);

kpFast = -prod(pFast)/S2.K;
kiFast = prod(1-pFast)/(S2.K*S2.Ts);

S2.Kp = [kp0, kpCons, kpFast];
S2.Ki = [ki0, kiCons, kiFast];

% Separate output directory
S2.outputDir = fullfile(pwd,'Stage2A_Results');

if ~exist(S2.outputDir,'dir')
    mkdir(S2.outputDir);
end

fprintf('Nominal plant gain: %.10f mA/count\n',S2.K);
fprintf('Nominal sample time: %.4f s\n',S2.Ts);

disp(table( ...
    string(S2.names(:)), ...
    S2.Kp(:), ...
    S2.Ki(:), ...
    'VariableNames',{'Controller','Kp','Ki'}));
