%% stage2B_verify.m | Unit tests for Arduino-equivalent update logic
if ~exist('B','var'), stage2B_params; end
step=@(u,x,idx,eDist,flags) stage2B_step(u,x,idx,5,3, ...
    B.K,B.I0,B.u0,10,B.Ts,21.5,322,25,0.03, ...
    flags(1),flags(2),flags(3),flags(4),eDist);
% Exact 0.03 inclusive deadband is tested via crafted current offset.
% At 10 mA, the offset to produce error E is 10-I0-E.
% The implementation uses <=0.03 as firmware; the floating-point
% unit tests use a point just inside each boundary to avoid 1-ulp noise.
for err=[-0.029999,0,0.029999]
    d=10-B.I0-err;
    [~,~,ed]=step(215,0,1,d,[1 1 1 1]);
    assert(abs(ed)<1e-9,'Deadband boundary test failed');
end
err=0.0301; d=10-B.I0-err;
[~,~,ed]=step(215,0,1,d,[1 1 1 1]);
assert(abs(ed-err)<1e-9, 'Deadband must retain full error outside region');
% First burst integral skip
[~,~,~,~,xNew,uNext]=step(215,0,0,0,[1 1 1 1]);
assert(xNew==0 && uNext==217,'First burst behaviour incorrect');
% Rounding: positive half away from zero
assert(round(216.5)==217,'MATLAB rounding differs');


%% Force upper saturation for anti-windup verification

% Use a deliberately large synthetic disturbance to ensure
% that the proposed command exceeds the 240-count limit.
%
% This is a unit test, not a physical hardware scenario.

testDisturbance = -7;

% Anti-windup disabled, command saturation retained
[~,~,~,~,xNoAW,uNoAW] = step( ...
    240,0,1,testDisturbance,[1 1 1 0]);

% Anti-windup enabled, same command saturation
[~,~,~,~,xAW,uAW,~,~,~,frozen] = stage2B_step( ...
    240,0,1,5,3,B.K,B.I0,B.u0,10,B.Ts, ...
    21.5,322,25,0.03, ...
    1,1,1,1,testDisturbance);

fprintf('Without anti-windup: Counter = %.0f, Integral = %.4f\n', ...
    uNoAW,xNoAW);

fprintf('With anti-windup:    Counter = %.0f, Integral = %.4f\n', ...
    uAW,xAW);

% Both cases must retain software command saturation
assert(uNoAW==240 && uAW==240, ...
    'Output clamp failed');

% Without anti-windup, integral grows.
% With anti-windup, outward integration is rejected.
assert(xNoAW>0 && abs(xAW)<1e-10 && frozen, ...
    'Upper anti-windup failed');

% Anti-windup must allow unwinding when deltaI moves inward.
[~,~,~,~,xUnwind,~,~,~,~,frozen] = stage2B_step( ...
    240,12,1,5,3,B.K,B.I0,B.u0,10,B.Ts,21.5,322,25,0.03, ...
    1,1,1,1,1);
assert(xUnwind<12 && ~frozen,'Integral unwinding failed');
% Initial nominal operating command limits
assert(322==floor(15*21.5),'Global bound wrong');
assert(max(0,215-25)==190 && min(322,215+25)==240, ...
    'Trim bounds wrong');
fprintf('PASS: Stage 2B core deadband, startup, rounding, limits and anti-windup tests.\n');
