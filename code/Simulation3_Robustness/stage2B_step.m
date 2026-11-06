function [I,e,ed,pTerm,xUpdated,uNext,lower,upper,isClamped, ...
    wasFrozen,deltaI] = stage2B_step(u,x,idx,kp,ki,K,I0,u0, ...
    r,Ts,calibration,globalMax,trim,deadband, ...
    quantOn,deadbandOn,limitsOn,awOn,disturbance)
%#codegen
% Deterministic, single-burst firmware-aware update, no state hidden here.
% u is command APPLIED to current burst; return command for NEXT burst.
% For constant 10 mA reference the encoder Counter is 215.
% round() matches roundf() for these nonnegative firmware commands.
I = I0 + K*(u-u0) + disturbance;
% Firmware encoder value, bounded once globally at start.
req = round(r*calibration);
ff = min(max(req,0),globalMax);
rEff = ff/calibration;
e = rEff-I;
ed = e;
if deadbandOn~=0 && abs(e)<=deadband
    ed=0;
end
pTerm=kp*ed;
lower=0; upper=globalMax;
if limitsOn~=0
    lower=max(0,ff-trim); upper=min(globalMax,ff+trim);
end
% Firmware ignores integral update on first completed burst.
deltaI=0;
if idx>0
    deltaI=ki*min(Ts,0.5)*ed;
end
trial=x+deltaI;
trialCommand=ff+pTerm+trial;
wasFrozen=false;
if limitsOn~=0 && awOn~=0
    pushingUpper=(trialCommand>upper && deltaI>0);
    pushingLower=(trialCommand<lower && deltaI<0);
    if pushingUpper || pushingLower
        trial=x;
        wasFrozen=true;
    end
end
xUpdated=trial;
raw=ff+pTerm+xUpdated;
if limitsOn~=0
    bounded=min(max(raw,lower),upper);
else
    bounded=raw;
end
isClamped=(abs(bounded-raw)>1e-10);
if quantOn~=0
    uNext=round(bounded);
else
    uNext=bounded;
end
end
