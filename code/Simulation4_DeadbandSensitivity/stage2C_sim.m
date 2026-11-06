
function X = stage2C_sim(C,controller,K,timing,noise)
% Event-scheduled firmware-aware PI simulation.
%
% timing:
%   'fixed'
%   'shortFirst'
%   'longFirst'
%
% One sample represents one completed stimulation burst.
% The next command is applied to the following burst.
%
% The noise enters the feedback measurement only.

assert(controller>=1 && ...
       controller<=numel(C.Kp));

assert(K>0 && isfinite(K));

%% Generate actual sampling times

t = 0;

while true

    k = numel(t);

    switch timing

        case 'fixed'
            dt = C.Ts;

        case 'shortFirst'

            if mod(k,2)==1
                dt = C.tShort;
            else
                dt = C.tLong;
            end

        case 'longFirst'

            if mod(k,2)==1
                dt = C.tLong;
            else
                dt = C.tShort;
            end

        otherwise
            error('Unknown timing mode: %s',timing);

    end

    nextTime = t(end)+dt;

    if nextTime > C.stopTime+1e-10
        break;
    end

    t(end+1,1) = nextTime; %#ok<AGROW>

end

N = numel(t);

%% Prepare noise sequence

if isscalar(noise) && noise==0
    noise = zeros(N,1);
end

noise = noise(:);

assert(numel(noise)>=N, ...
    'Insufficient supplied noise samples.');

noise = noise(1:N);

%% Allocate outputs

X.t = t(:);
X.dt = zeros(N,1);

X.true = zeros(N,1);
X.measured = zeros(N,1);

X.error = zeros(N,1);
X.adjusted = zeros(N,1);

X.applied = zeros(N,1);
X.next = zeros(N,1);

X.integral = zeros(N,1);

X.frozen = false(N,1);
X.clamped = false(N,1);

X.noise = noise;

%% Firmware feedforward and bounds

ff = min(max(round(C.r*C.calibration),0), ...
    C.globalMax);

rEff = ff/C.calibration;

L = max(0,ff-C.trim);
U = min(C.globalMax,ff+C.trim);

%% Initial controller states

u = C.u0;
x = C.x0;

%% Execute one burst at a time

for k = 1:N

    % First burst has no previous update interval.
    if k>1
        dt = t(k)-t(k-1);
    else
        dt = 0;
    end

    %% True delivered current

    y = C.I0+K*(u-C.u0);

    %% Noisy feedback measurement

    ym = y+noise(k);

    %% Tracking error

    e = rEff-ym;

    %% Firmware deadband

    ed = e;

    if abs(e)<=C.deadband
        ed = 0;
    end

    %% Integral increment using ACTUAL elapsed time

    d = C.Ki(controller)*min(dt,0.5)*ed;

    xTrial = x+d;

    %% Conditional anti-windup decision

    trial = ff+C.Kp(controller)*ed+xTrial;

    freeze = ...
        (trial>U && d>0) || ...
        (trial<L && d<0);

    if freeze
        xNew = x;
    else
        xNew = xTrial;
    end

    %% Final command

    raw = ff+C.Kp(controller)*ed+xNew;

    bounded = min(max(raw,L),U);

    uNext = round(bounded);

    %% Store outputs for current burst

    X.dt(k) = dt;

    X.true(k) = y;
    X.measured(k) = ym;

    X.error(k) = e;
    X.adjusted(k) = ed;

    X.applied(k) = u;
    X.next(k) = uNext;

    X.integral(k) = xNew;

    X.frozen(k) = freeze;
    X.clamped(k) = abs(raw-bounded)>1e-10;

    %% Advance to next burst

    x = xNew;
    u = uNext;

end

%% Essential verification assertions

assert(X.applied(1)==C.u0);
assert(X.integral(1)==C.x0);

assert(all( ...
    X.applied(2:end)==X.next(1:end-1)));

assert(all(X.applied==round(X.applied)));

assert(all(X.applied>=L & X.applied<=U));

assert(all(isfinite(X.true)));
assert(all(isfinite(X.measured)));

assert(all(abs( ...
    X.measured-X.true-X.noise)<1e-10));

assert(abs(X.t(end)-sum(X.dt))<1e-9);

end
