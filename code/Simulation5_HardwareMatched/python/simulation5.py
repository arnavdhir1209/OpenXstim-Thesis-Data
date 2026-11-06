"""Simulation 5 (hardware matched simulation), Python implementation used in the thesis.

Independent reimplementation of the MATLAB Stage 2E simulation (code/Simulation5_HardwareMatched/stage2E_run.m).
For each Experiment 3 recording it replays the logged update times (logger clock) and an oscilloscope clock
(alternating 76 and 89 ms), with the plant calibrated from Experiment 1 (current at Counter 215, mean of two
recordings) and Experiment 2 (local slope over 8 to 12 mA), and noise resampled in 12 burst blocks from the
Experiment 1 residuals. 60 schedules x 40 seeds x 2 clocks x 2 controllers.

Usage, from the release root:
    python code/Simulation5_HardwareMatched/python/simulation5.py --data . --out Simulation5_HardwareMatched
Requires numpy and pandas. Run time is several minutes.
"""
import argparse
from pathlib import Path
import numpy as np, pandas as pd
import stats_core as sc

SEED = 20261103
REF = 10.0
LOADS = [100, 220, 560, 1000, 2000, 4000]
LOADNAME = {100: "100R", 220: "220R", 560: "560R", 1000: "1k", 2000: "2k", 4000: "4k"}
CTRL = ["Empirical", "Faster"]


def load_e03(root):
    """Qualified Experiment 3 trajectories: rows with stim_state RUNNING, mode PI_CONTROL, fault NONE and a valid
    measurement; time is measured from the first qualified row. This reproduces the qualification of analyse_E03_PI_gains.m."""
    recs = []
    for R in LOADS:
        for c in CTRL:
            for tr in range(1, 6):
                Z = pd.read_csv(root / f"Experiment3_ControllerComparison/Experiment3_{c}PI_{LOADNAME[R]}_rec{tr:02d}.csv")
                g = Z[(Z.stim_state == "RUNNING") & (Z["mode"] == "PI_CONTROL") & (Z.fault_code == "NONE") & Z.measured_mA.notna()]
                recs.append(dict(Load=R, Controller=c, Trial=tr, t=(g.time_ms - g.time_ms.iloc[0]).to_numpy() / 1000,
                                 y=g.measured_mA.to_numpy(float)))
    return recs


def continuous_groups(good, t, b, u, max_gap=0.5):
    groups, cur = [], []
    for k in range(len(good)):
        if not good[k]:
            if cur: groups.append(cur); cur = []
            continue
        if not cur:
            cur = [k]
        elif k == cur[-1] + 1 and b[k] == b[k - 1] + 1 and t[k] > t[k - 1] and t[k] - t[k - 1] <= max_gap and u[k] == u[k - 1]:
            cur.append(k)
        else:
            groups.append(cur); cur = [k]
    if cur: groups.append(cur)
    return groups


def stage2e_plant(root):
    rows, noise = [], {}
    for R in LOADS:
        means, lib = [], []
        for tr in (1, 2):
            Z = pd.read_csv(root / f"Experiment1_OpenLoopBaseline/Experiment1_OpenLoop_{LOADNAME[R]}_rec{tr:02d}.csv")
            t, b, y = Z.time_ms.to_numpy() / 1000, Z.burst.to_numpy(), Z.measured_mA.to_numpy(float)
            good = ((Z["mode"].str.upper() == "OPEN_LOOP") & (Z.stim_state.str.upper() == "RUNNING") &
                    (Z.fault_code.str.upper() == "NONE") & (Z.command_limited == 0) & (Z.reference_limited == 0) &
                    (Z.counter_applied == 215) & (Z.counter_next == 215) & ((Z.effective_target_mA - 10).abs() < 0.001) &
                    np.isfinite(y) & (y > 0)).to_numpy()
            pieces, acc = [], []
            for ids in continuous_groups(good, t, b, Z.counter_applied.to_numpy()):
                if len(ids) < 24: continue
                yy = y[ids]; pieces.append(yy - yy.mean()); acc.append(yy)
            acc = np.concatenate(acc); means.append(acc.mean()); lib.append(pieces)
        noise[R] = lib
        K, lo, hi, nP, nC, xr = local_e02_stage2e(root, R)
        rows.append(dict(Load_Ohm=R, E01Mean_T01_mA=means[0], E01Mean_T02_mA=means[1], Iat215_mA=np.mean(means),
                         LocalSlope_mA_per_Count=K, WindowLow_mA=lo, WindowHigh_mA=hi, Plateaus=nP, Counters=nC,
                         CounterMin=xr[0], CounterMax=xr[1]))
    return pd.DataFrame(rows), noise


def e02_segments(root, R, version="stage2e"):
    Z = pd.read_csv(root / f"Experiment2_OpenLoopSweep/Experiment2_OpenLoopSweep_{LOADNAME[R]}_rec01.csv")
    n = len(Z)
    t, b = Z.time_ms.to_numpy() / 1000, Z.burst.to_numpy()
    u, y = Z.counter_applied.to_numpy(float), Z.measured_mA.to_numpy(float)
    fault = ((Z.fault_code.str.upper() != "NONE") | (Z.stim_state.str.upper() == "FAULT_LATCHED")).to_numpy()
    pre = np.zeros(n, bool)
    for k in np.where(fault & ~np.r_[False, fault[:-1]])[0]:
        for j in range(max(0, k - 5), k):
            if t[k] >= t[j] and t[k] - t[j] <= 0.5: pre[j] = True
    good = ((Z["mode"].str.upper() == "OPEN_LOOP") & (Z.stim_state.str.upper() == "RUNNING")).to_numpy() & ~fault & ~pre & \
        (Z.command_limited == 0).to_numpy() & (Z.reference_limited == 0).to_numpy() & \
        (Z.requested_mA <= 15).to_numpy() & (Z.effective_target_mA <= 15).to_numpy() & \
        np.isfinite(u) & np.isfinite(y) & (y > 0) & (u >= 0) & (u <= 322)
    segs = []
    for s, ids in enumerate(continuous_groups(good, t, b, u)):
        yy = y[ids]; N = len(ids)
        acc, reason = False, "SHORT"
        if N >= 5:
            m = np.median(yy[1:]); mad = np.median(np.abs(yy[1:] - m))
            step_bad = abs(yy[0] - m) > max(0.25, 6 * 1.4826 * mad)
            sl = np.polyfit(t[ids] - t[ids[0]], yy, 1)[0]
            drift = abs(sl * (t[ids[-1]] - t[ids[0]]))
            med = np.median(yy)
            collapse = np.any((yy[:-1] < 0.55 * med) & (yy[1:] < 0.55 * med))
            reason = "POST_STEP" if step_bad else "DRIFT" if drift > max(0.30, 0.04 * med) else "COLLAPSE" if collapse else "ACCEPTED"
            acc = reason == "ACCEPTED"
        segs.append(dict(Load_Ohm=R, Segment=s + 1, Counter=int(u[ids[0]]), Bursts=N, Mean_mA=yy.mean(),
                         SD_mA=yy.std(ddof=1) if N > 1 else np.nan, Accepted=acc, Reason=reason))
    return pd.DataFrame(segs)


def local_e02_stage2e(root, R, windows=((8, 12), (7, 13), (6, 14)), min_plateau=5):
    A = e02_segments(root, R)
    Q = A[A.Accepted & (A.Bursts >= min_plateau)]
    for lo, hi in windows:
        W = Q[(Q.Mean_mA >= lo) & (Q.Mean_mA <= hi)]
        x = np.unique(W.Counter)
        if x.size < 3 or x.max() - x.min() < 10: continue
        my = np.array([W.Mean_mA[W.Counter == c].mean() for c in x])
        return np.polyfit(x, my, 1)[0], lo, hi, len(W), x.size, (int(x.min()), int(x.max()))
    return np.nan, np.nan, np.nan, 0, 0, (np.nan, np.nan)


def simulate_pi(t, noise, I0, K, kp, ki, ff=215, trim=25, gmax=322, db=0.030):
    N = t.size; meas = np.zeros(N); app = np.zeros(N)
    u, x = 215, 0.0
    lo, hi = max(0, ff - trim), min(gmax, ff + trim)
    for k in range(N):
        cur = I0 + K * (u - 215)
        fb = cur + noise[k]
        meas[k] = np.round(fb, 3); app[k] = u
        e = REF - fb
        ed = 0.0 if abs(e) <= db else e
        p = kp * ed
        delta = ki * min(t[k] - t[k - 1], 0.5) * ed if k > 0 else 0.0
        trial = x + delta
        raw = ff + p + trial
        if (raw > hi and delta > 0) or (raw < lo and delta < 0): trial = x
        x = trial
        u = int(np.round(min(max(ff + p + x, lo), hi)))   # MATLAB round = half away from zero; values never sit at .5 exactly
    return meas, app


def resample_blocks(two, N, block, rng):
    pieces = [p for p in two[rng.integers(2)] if p.size >= block]
    L = np.array([p.size for p in pieces]); eps = np.zeros(N); pos = 0
    while pos < N:
        pick = int(np.searchsorted(np.cumsum(L), rng.random() * L.sum()))
        src = pieces[min(pick, len(pieces) - 1)]
        st = rng.integers(src.size - block + 1); take = min(block, N - pos)
        eps[pos:pos + take] = src[st:st + take]; pos += take
    return eps


def run(root, out, nseeds=40):
    e03 = load_e03(root)
    plant, noise = stage2e_plant(root)
    plant.to_csv(out / "Simulation5_PlantCalibration_Python.csv", index=False)
    kp, ki = {"Empirical": 5.0, "Faster": 4.867577}, {"Empirical": 3.0, "Faster": 9.758558}
    rows = []
    rng = np.random.default_rng(SEED)
    for ss, r in enumerate(e03):
        P = plant[plant.Load_Ohm == r["Load"]].iloc[0]
        t_log = r["t"]; dt = np.diff(t_log)
        t_sc = np.r_[0, np.cumsum(np.where(dt > 0.0865, 0.089, 0.076))]
        for seed in range(nseeds):
            eps = resample_blocks(noise[r["Load"]], t_log.size, 12, rng)
            for clk, t in (("Logger", t_log), ("Scope", t_sc)):
                for c in CTRL:
                    y, u = simulate_pi(t, eps, P.Iat215_mA, P.LocalSlope_mA_per_Count, kp[c], ki[c])
                    w = sc.time_weights(t); e = REF - y
                    s, _, _ = sc.sustained_entry(t, sc.in_band(y))
                    fm = sc.final_window_mask(t)
                    rows.append(dict(R=r["Load"], Controller=c, Clock=clk, Schedule=ss, Seed=seed,
                                     RMSE10=sc.weighted_rmse(e[t < 10], w[t < 10]),
                                     RMSES=sc.weighted_rmse(e[fm], w[fm]),
                                     Sustained=t[s] if s is not None else np.nan,
                                     SustainedBurst=s if s is not None else np.nan))
    P = pd.DataFrame(rows)
    P.to_csv(out / "Simulation5_Python_RunLevel.csv", index=False)
    return plant, P


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=".", help="release root folder")
    ap.add_argument("--out", default="Simulation5_HardwareMatched")
    ap.add_argument("--seeds", type=int, default=40)
    A = ap.parse_args(); out = Path(A.out); out.mkdir(parents=True, exist_ok=True)
    run(Path(A.data), out, A.seeds)
