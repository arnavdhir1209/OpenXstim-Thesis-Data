
%% stage2A_math_check.m

if ~exist('S2','var')
    stage2A_params;
end

K = S2.K;
T = S2.Ts;

for j = 1:numel(S2.names)

    kp = S2.Kp(j);
    ki = S2.Ki(j);

    % Closed-loop state matrix
    A = [
        -K*(kp+ki*T), 1;
        -K*ki*T,      1
    ];

    % Characteristic polynomial
    coefficients = [
        1, ...
        -(1-K*(kp+ki*T)), ...
        -K*kp
    ];

    polesA = sort(eig(A));
    polesPoly = sort(roots(coefficients));

    % Independent equivalence check
    assert(max(abs(polesA-polesPoly)) < 1e-10, ...
        'State matrix and polynomial disagree.');

    % Discrete stability
    assert(all(abs(polesA)<1), ...
        'Nominal closed loop is unstable.');

    % Jury stability conditions
    assert( ...
        abs(K*kp)<1 && ...
        K*ki*T>0 && ...
        2-2*K*kp-K*ki*T>0, ...
        'Jury stability conditions failed.');

    fprintf( ...
        '%s: Kp=%.6f, Ki=%.6f\n', ...
        S2.names{j}, kp, ki);

    fprintf( ...
        'Poles: %.8f, %.8f\n', ...
        polesA(1), polesA(2));

end

% Verify analytical pole placement
targets = [0.985, 0.970];

for j = 2:3

    kp = S2.Kp(j);
    ki = S2.Ki(j);

    coefficients = [
        1, ...
        -(1-K*(kp+ki*T)), ...
        -K*kp
    ];

    actual = sort(roots(coefficients));
    desired = sort([-0.23;targets(j-1)]);

    assert(max(abs(actual-desired))<1e-10, ...
        'Pole placement does not recover target.');

end

fprintf('Mathematical verification passed.\n');
