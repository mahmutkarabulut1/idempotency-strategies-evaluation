#!/usr/bin/env python3
"""Aggregate experiment results into the paper's tables and figures.

Reads a tidy CSV (results/aggregate.csv) with one row per
(scenario, strategy, run, metric, value) and produces:
  - tables/summary.csv         mean/median/std/p95/p99 + 95% CI per group
  - tables/comparison_matrix.csv
  - figures/*.png              throughput, p99, violation-rate, recovery, etc.

If results/aggregate.csv is absent it falls back to data/projections.csv
(clearly labelled ILLUSTRATIVE) so the figure pipeline can be demonstrated.
"""
import os
import re
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy import stats

HERE = os.path.dirname(__file__)
REAL = os.path.join(HERE, "..", "results", "aggregate.csv")
PROJ = os.path.join(HERE, "data", "projections.csv")
FIG = os.path.join(HERE, "..", "results", "figures")
TAB = os.path.join(HERE, "..", "results", "tables")
os.makedirs(FIG, exist_ok=True)
os.makedirs(TAB, exist_ok=True)

STRATEGY_ORDER = ["DB", "REDIS", "ZK", "KAFKA", "OUTBOX", "PAYLOAD_HASH"]


def load():
    if os.path.exists(REAL):
        print(f"[analyze] using MEASURED results: {REAL}")
        return pd.read_csv(REAL), False
    print(f"[analyze] measured results not found; using ILLUSTRATIVE projections: {PROJ}")
    return pd.read_csv(PROJ), True


def ci95(x):
    """95% Student-t CI. Lower bound is clamped at 0 because every metric in this
    study is non-negative (latency, throughput, rates, counts, recovery time); an
    unclamped t-interval can dip below zero at small n (e.g., n=2), which is not a
    physically meaningful bound and was flagged in review."""
    x = np.asarray(x, dtype=float)
    if len(x) < 2:
        return (np.nan, np.nan)
    se = stats.sem(x)
    h = se * stats.t.ppf(0.975, len(x) - 1)
    return (max(0.0, x.mean() - h), x.mean() + h)


def summarize(df):
    rows = []
    for (scn, strat, metric), g in df.groupby(["scenario", "strategy", "metric"]):
        vals = g["value"].values
        lo, hi = ci95(vals)
        rows.append({
            "scenario": scn, "strategy": strat, "metric": metric,
            "mean": np.mean(vals), "median": np.median(vals), "std": np.std(vals, ddof=1) if len(vals) > 1 else 0.0,
            "p95": np.percentile(vals, 95), "p99": np.percentile(vals, 99),
            "ci95_lo": lo, "ci95_hi": hi, "n": len(vals),
        })
    out = pd.DataFrame(rows)
    out.to_csv(os.path.join(TAB, "summary.csv"), index=False)
    return out


def _ordered(strats):
    return sorted(strats, key=lambda s: STRATEGY_ORDER.index(s) if s in STRATEGY_ORDER else 99)


def bar(summary, scenario, metric, ylabel, fname, illustrative, logy=False):
    sub = summary[(summary.scenario == scenario) & (summary.metric == metric)]
    if sub.empty:
        return
    strategies = _ordered(sub.strategy.unique())
    means = [sub[sub.strategy == s]["mean"].values[0] for s in strategies]
    # Asymmetric error bars, clamped so the lower whisker never dips below zero.
    # Every metric in this study (latency, throughput, rates, counts, recovery
    # time) is physically non-negative, so we pass the lower error as the distance
    # to the CI lower bound (already clamped at 0 in ci95) and the upper error as
    # the distance to the CI upper bound. NaN (n<2) -> 0 so a single-rep cell
    # renders without a misleading whisker.
    lo_err, hi_err, ns = [], [], []
    for s in strategies:
        row = sub[sub.strategy == s].iloc[0]
        lo, hi, m = row["ci95_lo"], row["ci95_hi"], row["mean"]
        if pd.isna(lo) or pd.isna(hi):
            lo_err.append(0.0)
            hi_err.append(0.0)
        else:
            lo_err.append(max(0.0, m - lo))  # clamp CI lower bound at 0
            hi_err.append(max(0.0, hi - m))
        ns.append(int(row["n"]))

    is_violation = (metric == "violation_rate")
    fig, ax = plt.subplots(figsize=(7, 4))
    if is_violation:
        # DSEVR is exactly 0.0 for every strategy in every scenario (the
        # uniqueness/idempotency constraint admits at most one side effect). A
        # symmetric CI whisker would extend below zero, which is meaningless for a
        # rate, so we draw flat bars at 0 with no whiskers, clamp the axis to a
        # non-negative [0, 1] range, and annotate the zero result explicitly.
        bars = ax.bar(strategies, means, color="#3b6ea5")
        ax.set_ylim(0, 1.0)
        ax.axhline(0.0, color="#888", linewidth=1)
        ax.annotate("DSEVR = 0 for all strategies",
                    xy=(0.5, 0.5), xycoords="axes fraction",
                    ha="center", va="center", fontsize=12, color="#444",
                    bbox=dict(boxstyle="round", fc="#f0f0f0", ec="#bbb"))
    else:
        bars = ax.bar(strategies, means, yerr=[lo_err, hi_err], capsize=4, color="#3b6ea5")
        if not logy:
            # Clamp the visible y-axis at 0 so a non-negative metric never renders
            # a below-zero region, with the top at the max bar+CI (the max value).
            top = max((m + h) for m, h in zip(means, hi_err)) if means else 1.0
            ax.set_ylim(0, top * 1.15 if top > 0 else 1.0)
    ax.set_ylabel(ylabel)
    ax.set_title(f"{scenario}: {ylabel}" + ("  [ILLUSTRATIVE]" if illustrative else ""))
    if logy:
        ax.set_yscale("log")
    # Annotate the replication count per bar so single-rep cells are not mistaken
    # for replicated ones.
    for rect, nrep in zip(bars, ns):
        ax.annotate(f"n={nrep}", (rect.get_x() + rect.get_width() / 2, rect.get_height()),
                    ha="center", va="bottom", fontsize=8, color="#444")
    plt.xticks(rotation=20)
    plt.tight_layout()
    plt.savefig(os.path.join(FIG, fname), dpi=150)
    plt.close()


_LAT_RE = re.compile(r"l(?:at)?(\d+)", re.IGNORECASE)


def latency_sweep(df, illustrative):
    """Render p99-vs-injected-latency and DSEVR-vs-latency line charts for E3 when
    the run column encodes the injected level as 'l<ms>...' (e.g. 'l100-r1'),
    written by scripts/exp_latency_sweep.sh. With a single level present, the bar
    fallback (fig_p99_latency.png) is used instead, so a one-point pilot still plots."""
    e3 = df[df.scenario == "E3"].copy()
    if e3.empty:
        return
    e3["lat"] = e3["run"].astype(str).str.extract(_LAT_RE.pattern, expand=False)
    e3 = e3.dropna(subset=["lat"])
    if e3.empty or e3["lat"].astype(float).nunique() < 2:
        return False  # not a sweep; the single-point bar fallback handles it
    e3["lat"] = e3["lat"].astype(float)
    for metric, ylabel, fname in (
        ("p99", "p99 latency (ms)", "fig_p99_latency_sweep.png"),
        ("violation_rate", "DSEVR", "fig_dsevr_latency_sweep.png"),
    ):
        m = e3[e3.metric == metric]
        if m.empty:
            continue
        fig, ax = plt.subplots(figsize=(7, 4.2))
        for strat in _ordered(m.strategy.unique()):
            g = m[m.strategy == strat].groupby("lat")["value"].mean().sort_index()
            ax.plot(g.index, g.values, marker="o", label=strat)
        ax.set_xlabel("Injected latency (ms)")
        ax.set_ylabel(ylabel)
        ax.set_title(f"E3 latency sweep: {ylabel}" + ("  [ILLUSTRATIVE]" if illustrative else ""))
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(FIG, fname), dpi=150)
        plt.close()
        print(f"[analyze] wrote sweep figure {fname}")
    return True


def saturation(illustrative):
    """Open-loop saturation knee chart. Reads results/saturation.csv (offered_rate,
    strategy,run,achieved_rps,error_rate,p99) emitted by scripts/exp_saturation.sh
    and plots achieved throughput vs offered rate, marking each strategy's 1%-error
    knee. Skipped silently if the campaign has not been run."""
    sat = os.path.join(HERE, "..", "results", "saturation.csv")
    if not os.path.exists(sat):
        return
    s = pd.read_csv(sat)
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for strat in _ordered(s.strategy.unique()):
        g = s[s.strategy == strat].groupby("offered_rate").agg(
            rps=("achieved_rps", "mean"), err=("error_rate", "mean")).sort_index()
        ax.plot(g.index, g["rps"], marker="o", label=strat)
        knee = g[g["err"] >= 0.01]
        if not knee.empty:
            x = knee.index[0]
            ax.scatter([x], [g.loc[x, "rps"]], color="red", zorder=5, marker="x", s=80)
    ax.set_xlabel("Offered rate (req/s)")
    ax.set_ylabel("Achieved throughput (req/s)")
    ax.set_title("E1 open-loop saturation (x = 1% error knee)"
                 + ("  [ILLUSTRATIVE]" if illustrative else ""))
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(FIG, "fig_saturation.png"), dpi=150)
    plt.close()
    print("[analyze] wrote fig_saturation.png")


def main():
    df, illustrative = load()
    summary = summarize(df)

    bar(summary, "E1", "throughput", "Throughput (req/s)", "fig_throughput.png", illustrative)
    bar(summary, "E1", "p99", "p99 latency (ms)", "fig_p99.png", illustrative)
    bar(summary, "E2", "violation_rate", "Duplicate side-effect violation rate", "fig_violation_burst.png", illustrative)
    bar(summary, "E4", "violation_rate", "Violation rate under partition", "fig_violation_partition.png", illustrative)
    bar(summary, "E5", "stale_locks", "Stale lock acquisitions (clock drift)", "fig_stale_locks.png", illustrative)
    bar(summary, "E4", "recovery_s", "Recovery time after partition (s)", "fig_recovery.png", illustrative)
    bar(summary, "E4", "error_rate", "Request error rate during partition", "fig_error_partition.png", illustrative)
    bar(summary, "E5", "premature_expirations", "Premature lock-lease expirations", "fig_premature.png", illustrative)
    bar(summary, "E5", "lock_timeouts", "Lock acquisition timeouts (timing stress)", "fig_lock_timeouts.png", illustrative)

    # Multi-point campaigns (rendered only when their data is present). When a
    # full latency sweep exists, plot it; otherwise fall back to a single-point
    # E3 p99 bar (the pilot 100 ms anchor) rather than averaging across levels.
    if not latency_sweep(df, illustrative):
        bar(summary, "E3", "p99", "p99 under latency injection (ms)", "fig_p99_latency.png", illustrative)
    saturation(illustrative)

    # Strategy comparison matrix: each column scoped to the scenario that defines
    # it (throughput/p99 from E1 baseline, violation_rate from E2 burst) so we do
    # not blend p99 across scenarios.
    def col(scenario, metric, label):
        s = summary[(summary.scenario == scenario) & (summary.metric == metric)]
        return s.set_index("strategy")["mean"].rename(label)

    parts = [c for c in (col("E1", "throughput", "throughput_e1"),
                         col("E1", "p99", "p99_ms_e1"),
                         col("E2", "violation_rate", "violation_rate_e2")) if not c.empty]
    if parts:
        matrix = pd.concat(parts, axis=1).reindex(_ordered(
            sorted(set().union(*[p.index for p in parts]))))
        matrix.to_csv(os.path.join(TAB, "comparison_matrix.csv"))
        print("[analyze] wrote tables/ and figures/ (illustrative=%s)" % illustrative)
        print(matrix.round(4).to_string())
    else:
        print("[analyze] no matrix columns available")


if __name__ == "__main__":
    main()
