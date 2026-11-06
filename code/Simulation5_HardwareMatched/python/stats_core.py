"""Pure numerical functions for the OpenXstim supplementary thesis statistics.

Every function here is deterministic and free of file I/O so that it can be
unit tested. Conventions mirror the frozen MATLAB analyses
(analyse_E03_PI_gains.m, stage2E_run.m):

* tracking error e = reference - measured (the firmware error_mA sign);
* time weight of burst k is t[k+1] - t[k]; the final burst gets the median
  of the observed intervals;
* the final window is every burst with t >= t_end - window_s;
* the 1 % band is |e| <= 0.100 mA, evaluated in IEEE double precision exactly
  as MATLAB does (e = 10 - y);
* a sustained 2 s interval starts at the first in-band burst of a contiguous
  in-band run whose last burst is at least 2 s after its first burst.
"""

from __future__ import annotations

import numpy as np


# ---------------------------------------------------------------- weights

def time_weights(t):
    """Interval-to-next-burst weights with median final interval."""
    t = np.asarray(t, dtype=float)
    if t.size < 2:
        raise ValueError("need at least two timestamps")
    d = np.diff(t)
    if np.any(d <= 0):
        raise ValueError("timestamps must be strictly increasing")
    return np.concatenate([d, [np.median(d)]])


def final_window_mask(t, window_s=20.0):
    t = np.asarray(t, dtype=float)
    return t >= t[-1] - window_s


def first_window_mask(t, window_s=20.0):
    t = np.asarray(t, dtype=float)
    return t < t[0] + window_s


# ---------------------------------------------------------------- moments

def weighted_rmse(e, w):
    e = np.asarray(e, float)
    w = np.asarray(w, float)
    return float(np.sqrt(np.sum(w * e ** 2) / np.sum(w)))


def weighted_mean(x, w):
    x = np.asarray(x, float)
    w = np.asarray(w, float)
    return float(np.sum(w * x) / np.sum(w))


def weighted_sd_population(x, w):
    """Time-weighted SD with denominator sum(w) (no bias correction)."""
    m = weighted_mean(x, w)
    return float(np.sqrt(np.sum(np.asarray(w) * (np.asarray(x) - m) ** 2) / np.sum(w)))


def second_moment_identity_gap(e, w):
    """RMSE^2 - (bias^2 + var_w); zero to rounding when weights agree."""
    return weighted_rmse(e, w) ** 2 - (weighted_mean(e, w) ** 2 + weighted_sd_population(e, w) ** 2)


# ---------------------------------------------------------------- adjacency

def valid_adjacent_pairs(burst, t, max_gap_s=0.5):
    """Boolean array of length n-1: True where k and k+1 are consecutive bursts."""
    burst = np.asarray(burst)
    t = np.asarray(t, float)
    db = np.diff(burst)
    dt = np.diff(t)
    return (db == 1) & (dt > 0) & (dt <= max_gap_s)


def lag_acf(x, valid_pairs, lag=1, centre=None):
    """Autocorrelation at `lag` using only chains of valid adjacent pairs.

    r(lag) = sum over valid (k, k+lag) of (x_k - m)(x_{k+lag} - m)
             / sum over all k of (x_k - m)^2

    A (k, k+lag) pair is valid only if every intermediate adjacent pair is
    valid, so correlations never span a gap or reset. Returns (r, n_pairs).
    """
    x = np.asarray(x, float)
    v = np.asarray(valid_pairs, bool)
    m = x.mean() if centre is None else centre
    z = x - m
    den = np.sum(z ** 2)
    n = x.size
    if n <= lag or den == 0:
        return np.nan, 0
    # chain validity: all of v[k], ..., v[k+lag-1]
    ok = np.ones(n - lag, bool)
    for j in range(lag):
        ok &= v[j:n - lag + j]
    num = np.sum(z[:-lag][ok] * z[lag:][ok])
    return float(num / den), int(ok.sum())


# ---------------------------------------------------------------- settling

def in_band(y, reference=10.0, band=0.100):
    e = reference - np.asarray(y, float)
    return np.abs(e) <= band


def sustained_entry(t, inside, sustain_s=2.0):
    """First start of a contiguous in-band run lasting >= sustain_s.

    Returns (start_index, run_end_index, n_bursts_to_complete) or (None,...).
    n_bursts_to_complete counts bursts from the start to the first burst at
    or beyond start + sustain_s, inclusive.
    """
    t = np.asarray(t, float)
    inside = np.asarray(inside, bool)
    edges = np.diff(np.concatenate([[0], inside.astype(int), [0]]))
    starts = np.where(edges == 1)[0]
    ends = np.where(edges == -1)[0] - 1
    for s, e in zip(starts, ends):
        if t[e] - t[s] >= sustain_s - 1e-9:
            q = s + int(np.argmax(t[s:e + 1] >= t[s] + sustain_s - 1e-9))
            return int(s), int(e), int(q - s + 1)
    return None, None, None


def sustained_entry_matlab_e03(t, e, band, seconds):
    """Literal port of sustainedBandEntry() from analyse_E03_PI_gains.m."""
    t = np.asarray(t, float)
    e = np.asarray(e, float)
    for k in range(t.size):
        later = np.where(t >= t[k] + seconds)[0]
        if later.size == 0:
            break
        q = later[0]
        if np.all(np.abs(e[k:q + 1]) <= band):
            return float(t[k]), int(k)
    return np.nan, None


# ---------------------------------------------------------------- occupancy

def counter_occupancy(u, w, valid_pairs):
    """Occupancy and step statistics for an applied-command sequence.

    Mode: largest time-weighted occupancy; ties go to the smallest Counter
    (MATLAB max over sorted unique codes returns the first).
    """
    u = np.asarray(u, float)
    w = np.asarray(w, float)
    codes = np.unique(u)
    occ_t = np.array([w[u == c].sum() for c in codes]) / w.sum()
    occ_b = np.array([(u == c).sum() for c in codes]) / u.size
    mode = codes[int(np.argmax(occ_t))]
    d = np.abs(u - mode)

    def frac(mask, weights):
        return float(weights[mask].sum() / weights.sum())

    ones = np.ones_like(u)
    du = np.diff(u)[np.asarray(valid_pairs, bool)]
    changes = du[du != 0]
    a = np.abs(changes)
    out = {
        "ModeCounter": int(mode),
        "DistinctCounters": int(codes.size),
        "TimeFrac_AtMode": frac(d == 0, w),
        "TimeFrac_ModePlusMinus1": frac(d == 1, w),
        "TimeFrac_WithinPlusMinus1": frac(d <= 1, w),
        "TimeFrac_2OrMoreFromMode": frac(d >= 2, w),
        "BurstFrac_AtMode": frac(d == 0, ones),
        "BurstFrac_ModePlusMinus1": frac(d == 1, ones),
        "BurstFrac_WithinPlusMinus1": frac(d <= 1, ones),
        "BurstFrac_2OrMoreFromMode": frac(d >= 2, ones),
        "ValidTransitions": int(du.size),
        "CounterChanges": int(changes.size),
        "TotalMovement_counts": float(a.sum()),
        "MeanAbsStep_GivenChange": float(a.mean()) if a.size else np.nan,
        "MedianAbsStep_GivenChange": float(np.median(a)) if a.size else np.nan,
        "FracChanges_Exactly1": float(np.mean(a == 1)) if a.size else np.nan,
        "FracChanges_2OrMore": float(np.mean(a >= 2)) if a.size else np.nan,
        "Reversals": int(np.sum(np.sign(changes[1:]) != np.sign(changes[:-1]))) if changes.size > 1 else 0,
    }
    out["ReversalFraction"] = (out["Reversals"] / (changes.size - 1)) if changes.size > 1 else np.nan
    return out, dict(zip(codes.astype(int), occ_t)), dict(zip(codes.astype(int), occ_b))


# ---------------------------------------------------------------- bootstrap

def bootstrap_diff_of_means(a, b, n_boot, rng):
    """Percentile CI of mean(b) - mean(a); recordings resampled within group."""
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    ia = rng.integers(0, a.size, size=(n_boot, a.size))
    ib = rng.integers(0, b.size, size=(n_boot, b.size))
    d = b[ib].mean(axis=1) - a[ia].mean(axis=1)
    return d


def percentile_ci(d, level=0.95):
    lo, hi = np.percentile(d, [100 * (1 - level) / 2, 100 * (1 + level) / 2])
    return float(lo), float(hi)


# ---------------------------------------------------------------- regression

def ols_with_se(x, y):
    """Unweighted OLS y = a + b x with classical standard errors."""
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    n = x.size
    X = np.column_stack([np.ones(n), x])
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    r = y - X @ beta
    dof = n - 2
    s2 = float(r @ r / dof) if dof > 0 else np.nan
    cov = s2 * np.linalg.inv(X.T @ X) if dof > 0 else np.full((2, 2), np.nan)
    return {
        "Intercept": float(beta[0]), "Slope": float(beta[1]),
        "SE_Intercept": float(np.sqrt(cov[0, 0])), "SE_Slope": float(np.sqrt(cov[1, 1])),
        "Cov": cov, "ResidualRMS": float(np.sqrt(np.mean(r ** 2))),
        "ResidualSE": float(np.sqrt(s2)) if dof > 0 else np.nan,
        "DoF": dof, "N": n,
        "R2": float(1 - (r @ r) / np.sum((y - y.mean()) ** 2)),
    }


def prediction_se_at(fit, x0):
    """SE of the fitted line value at x0 (e.g. Counter 215)."""
    v = np.array([1.0, x0])
    return float(np.sqrt(v @ fit["Cov"] @ v))
