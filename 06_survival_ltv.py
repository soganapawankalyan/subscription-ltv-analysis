#!/usr/bin/env python3
"""
Project 4D - survival curves and 5-year LTV projection (Python half).

Reads the CSVs written by generate_subscription_data.py (data/*.csv).
Needs: numpy, pandas, matplotlib.   Install once:  pip install pandas matplotlib

What it does
  1. Builds one row per customer: months subscribed (T) and whether they cancelled.
     Customers still subscribed in Dec 2025 are CENSORED (we don't know their end).
  2. Kaplan-Meier survival curves by channel, plan and promo flag.
  3. Projects gross-profit LTV to 12 / 24 / 60 months per channel:
        observed hazard up to month 24, then a constant tail hazard
        (average monthly churn in months 13-24) from month 25 onward.
  4. Bootstraps customers (default 300 resamples) for 90% intervals.
  5. Writes charts + CSVs to results/.

Assumptions (state them in the README):
  - Gross margin 70% (an assumption, not data).  Change GM below.
  - The tail hazard stays constant after month 24: an extrapolation, not an observation.
  - Paused months count as subscribed (revenue 0); only a cancel ends the lifetime.
  - Revenue per subscribed month is estimated per channel and tenure band
    (months 1-3, 4-12, 13+) and held fixed in the bootstrap.
  - Undiscounted LTV is shown at 12/24/60 months; the 60-month figure is also shown
    discounted at 10% a year.
"""
import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

GM = 0.70
OBS_H = 24           # last month we trust the KM curve for
TAIL_FROM, TAIL_TO = 13, 24
H_MAX = 60
DISC_ANNUAL = 0.10
BANDS = [(1, 3), (4, 12), (13, 999)]
CHANNELS = ["referral", "partnership", "organic", "paid_search", "paid_social"]

# reference palette, categorical slots 1-5 (light mode); adjacent-pair validated
COL = {"organic": "#2a78d6", "paid_social": "#eb6834", "referral": "#1baf7a",
       "paid_search": "#eda100", "partnership": "#e87ba4"}
PLAN_COL = {"Basic": "#2a78d6", "Standard": "#eb6834", "Premium": "#1baf7a"}
INK, INK2, GRID, BG = "#0b0b0b", "#52514e", "#e6e5e1", "#fcfcfb"


def km_survival(dur, event, h):
    """S(t)=P(T>t) for t=0..h.  dur = months subscribed, event = 1 if cancelled."""
    over = dur > h                       # lifetimes beyond the horizon: still alive at h
    dur = np.where(over, h + 1, dur)
    event = np.where(over, 0, event)
    n = np.bincount(dur, minlength=h + 2)
    d = np.bincount(dur[event == 1], minlength=h + 2)
    at_risk = n[::-1].cumsum()[::-1]          # number with T >= t
    haz = np.divide(d, at_risk, out=np.zeros(len(d)), where=at_risk > 0)
    s = np.ones(h + 1)
    for t in range(1, h + 1):
        s[t] = s[t - 1] * (1 - haz[t])
    return s, haz, at_risk


def project(dur, event, rev_per_alive, h_max=H_MAX):
    """Survival to h_max (KM to OBS_H, constant tail after) and LTV curve."""
    s, haz, _ = km_survival(dur, event, OBS_H)
    tail = np.nanmean(haz[TAIL_FROM:TAIL_TO + 1])
    full = np.empty(h_max + 1)
    full[:OBS_H + 1] = s
    for t in range(OBS_H + 1, h_max + 1):
        full[t] = full[t - 1] * (1 - tail)
    # month k is paid if customer is still there: prob = S(k-1)
    k = np.arange(1, h_max + 1)
    arpu = np.array([rev_per_alive[next(i for i, (a, b) in enumerate(BANDS) if a <= m <= b)] for m in k])
    gp = GM * full[k - 1] * arpu
    return full, tail, np.cumsum(gp), gp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data")
    ap.add_argument("--out", default="results")
    ap.add_argument("--boot", type=int, default=300)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rng = np.random.default_rng(a.seed)

    cust = pd.read_csv(f"{a.data}/customers.csv")
    sm = pd.read_csv(f"{a.data}/subscription_months.csv")
    ev = pd.read_csv(f"{a.data}/events.csv")
    spend = pd.read_csv(f"{a.data}/marketing_spend.csv")

    # ---- one row per customer ------------------------------------------------
    life = sm.groupby("customer_id").tenure_month.max().rename("T")
    canc = set(ev.loc[ev.event_type == "cancel", "customer_id"])
    df = cust.set_index("customer_id").join(life)
    df["event"] = df.index.isin(canc).astype(int)
    df["T"] = df["T"].astype(int)
    assert df["T"].min() >= 1 and len(df) == len(cust)

    # revenue per customer per tenure band (sum of mrr and count of subscribed months)
    sm["band"] = pd.cut(sm.tenure_month, [0, 3, 12, 10**6], labels=False)
    g = sm.groupby(["customer_id", "band"]).mrr.agg(["sum", "count"]).unstack(fill_value=0)
    rev = g["sum"].reindex(df.index, fill_value=0).to_numpy()
    cnt = g["count"].reindex(df.index, fill_value=0).to_numpy()

    # ---- 1. Kaplan-Meier curves ---------------------------------------------
    rows = []
    for dim, col in [("channel", "channel"), ("plan", "signup_plan"), ("promo", "promo_signup")]:
        for val, sub in df.groupby(col):
            s, _, atr = km_survival(sub["T"].to_numpy(), sub["event"].to_numpy(), 36)
            for t in range(0, 37):
                rows.append((dim, str(val), t, s[t], int(atr[t]) if t < len(atr) else 0))
    km = pd.DataFrame(rows, columns=["dimension", "group", "t", "survival", "at_risk"])
    km.to_csv(f"{a.out}/km_curves.csv", index=False)

    def km_chart(dim, colors, fname, title, order):
        fig, ax = plt.subplots(figsize=(8, 4.6), dpi=160, facecolor=BG)
        ax.set_facecolor(BG)
        for grp in order:
            d = km[(km.dimension == dim) & (km.group == grp) & (km.at_risk >= 100)]
            ax.plot(d.t, d.survival * 100, color=colors[grp], lw=2, label=grp.replace("_", " "))
            ax.text(d.t.iloc[-1] + 0.4, d.survival.iloc[-1] * 100, grp.replace("_", " "),
                    color=INK2, fontsize=8, va="center")
        ax.set_xlim(0, 40); ax.set_ylim(0, 100)
        ax.set_xlabel("Months since signup", color=INK2, fontsize=9)
        ax.set_ylabel("Still subscribed (%)", color=INK2, fontsize=9)
        ax.set_title(title, loc="left", color=INK, fontsize=11, fontweight="bold")
        ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
        for s_ in ("top", "right", "left"):
            ax.spines[s_].set_visible(False)
        ax.spines["bottom"].set_color(GRID)
        ax.tick_params(colors=INK2, labelsize=8, length=0)
        ax.legend(frameon=False, fontsize=8, labelcolor=INK2, loc="upper right")
        fig.text(0.01, 0.01, "Kaplan-Meier; curve stops where fewer than 100 customers remain at risk. Synthetic data.",
                 fontsize=7, color=INK2)
        fig.tight_layout(rect=(0, 0.03, 1, 1))
        fig.savefig(f"{a.out}/{fname}", facecolor=BG); plt.close(fig)

    km_chart("channel", COL, "py_km_by_channel.png", "Retention by acquisition channel", CHANNELS)
    km_chart("plan", PLAN_COL, "py_km_by_plan.png", "Retention by signup plan", ["Premium", "Standard", "Basic"])

    # ---- 2. LTV projection by channel ---------------------------------------
    cac = (spend.groupby("channel").spend_usd.sum() / df.groupby("channel").size()).to_dict()
    monthly_disc = (1 + DISC_ANNUAL) ** (1 / 12) - 1
    disc = 1 / (1 + monthly_disc) ** np.arange(0, H_MAX)   # month k discounted by k-1 months

    def ltv_for(idx, mask):
        d = df["T"].to_numpy()[idx]; e = df["event"].to_numpy()[idx]
        r = rev[idx].sum(axis=0); c = cnt[idx].sum(axis=0)
        rpa = np.divide(r, c, out=np.zeros(3), where=c > 0)
        full, tail, cum, gp = project(d, e, rpa)
        return full, tail, cum, gp, rpa

    out, ci_rows = [], []
    curves = {}
    for ch in CHANNELS:
        idx = np.where(df.channel.to_numpy() == ch)[0]
        full, tail, cum, gp, rpa = ltv_for(idx, None)
        curves[ch] = cum
        boots = np.empty((a.boot, 4))
        for b in range(a.boot):
            ii = rng.choice(idx, size=len(idx), replace=True)
            f2, t2, c2, g2, _ = ltv_for(ii, None)
            boots[b] = [c2[11], c2[23], c2[59], (g2 * disc).sum()]
        lo, hi = np.percentile(boots, [5, 95], axis=0)
        pay = next((i + 1 for i, v in enumerate(cum) if v >= cac[ch]), None)
        out.append(dict(
            channel=ch, customers=len(idx), cac=round(cac[ch], 2),
            tail_monthly_churn_pct=round(tail * 100, 2),
            ltv_12m=round(cum[11], 2), ltv_24m=round(cum[23], 2),
            ltv_60m=round(cum[59], 2), ltv_60m_lo=round(lo[2], 2), ltv_60m_hi=round(hi[2], 2),
            ltv_60m_discounted=round((gp * disc).sum(), 2),
            ltv_to_cac_12m=round(cum[11] / cac[ch], 2), ltv_to_cac_24m=round(cum[23] / cac[ch], 2),
            ltv_to_cac_60m=round(cum[59] / cac[ch], 2),
            ltv_to_cac_60m_lo=round(lo[2] / cac[ch], 2), ltv_to_cac_60m_hi=round(hi[2] / cac[ch], 2),
            payback_month=pay,
            share_of_60m_ltv_beyond_month_24=round(100 * (cum[59] - cum[23]) / cum[59], 1),
        ))
    res = pd.DataFrame(out)
    res.to_csv(f"{a.out}/py_ltv_by_channel.csv", index=False)
    pd.DataFrame(curves).assign(month=np.arange(1, H_MAX + 1)).to_csv(
        f"{a.out}/py_cum_gross_profit_curves.csv", index=False)

    # ---- 3. chart: cumulative gross profit vs CAC ---------------------------
    fig, ax = plt.subplots(figsize=(8, 4.8), dpi=160, facecolor=BG)
    ax.set_facecolor(BG)
    for ch in CHANNELS:
        ax.plot(np.arange(1, H_MAX + 1), curves[ch], color=COL[ch], lw=2)
        ax.axhline(cac[ch], color=COL[ch], lw=1, ls=(0, (4, 3)), alpha=0.8)
        ax.text(H_MAX + 0.6, curves[ch][-1], ch.replace("_", " "), color=INK2, fontsize=8, va="center")
    ax.axvline(OBS_H, color=INK2, lw=0.8)
    ax.text(OBS_H + 0.5, ax.get_ylim()[1] * 0.97, "extrapolated →", color=INK2, fontsize=8, va="top")
    ax.set_xlim(0, 72); ax.set_xlabel("Months since signup", color=INK2, fontsize=9)
    ax.set_ylabel("Cumulative gross profit per signup ($)", color=INK2, fontsize=9)
    ax.set_title("Payback: solid line = gross profit, dashed = that channel's CAC",
                 loc="left", color=INK, fontsize=11, fontweight="bold")
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for s_ in ("top", "right", "left"):
        ax.spines[s_].set_visible(False)
    ax.spines["bottom"].set_color(GRID); ax.tick_params(colors=INK2, labelsize=8, length=0)
    fig.text(0.01, 0.01, f"Margin {GM:.0%} assumed. Beyond month {OBS_H} churn is held constant at each channel's months 13-24 average. Synthetic data.",
             fontsize=7, color=INK2)
    fig.tight_layout(rect=(0, 0.03, 1, 1)); fig.savefig(f"{a.out}/py_payback_curves.png", facecolor=BG); plt.close(fig)

    # ---- 4. chart: 60-month LTV:CAC with intervals --------------------------
    r = res.sort_values("ltv_to_cac_60m")
    fig, ax = plt.subplots(figsize=(8, 3.8), dpi=160, facecolor=BG)
    ax.set_facecolor(BG)
    y = np.arange(len(r))
    ax.barh(y, r.ltv_to_cac_60m, color=[COL[c] for c in r.channel], height=0.5)
    ax.errorbar(r.ltv_to_cac_60m, y, xerr=[r.ltv_to_cac_60m - r.ltv_to_cac_60m_lo, r.ltv_to_cac_60m_hi - r.ltv_to_cac_60m],
                fmt="none", ecolor=INK2, elinewidth=1, capsize=3)
    for yi, v, hi in zip(y, r.ltv_to_cac_60m, r.ltv_to_cac_60m_hi):
        ax.text(hi + 0.4, yi, f"{v:.1f}x", va="center", color=INK, fontsize=8)
    ax.axvline(3, color=INK2, lw=0.8, ls=(0, (4, 3)))
    ax.text(3.2, -0.62, "3x rule of thumb", color=INK2, fontsize=7.5, va="center")
    if "organic" in list(r.channel):
        oi = list(r.channel).index("organic")
        ax.text(0.4, oi, "organic CAC is only partly tracked, so this ratio is overstated", color="#ffffff",
                fontsize=7.5, va="center")
    ax.set_ylim(-0.9, len(r) - 0.4)
    ax.set_yticks(y); ax.set_yticklabels([c.replace("_", " ") for c in r.channel], color=INK2, fontsize=9)
    ax.set_xlabel("60-month gross-profit LTV : CAC (whiskers = 90% bootstrap interval; excludes the tail-churn assumption)", color=INK2, fontsize=8)
    ax.set_title("Which channels earn back their cost?", loc="left", color=INK, fontsize=11, fontweight="bold")
    for s_ in ("top", "right", "left"):
        ax.spines[s_].set_visible(False)
    ax.spines["bottom"].set_color(GRID); ax.tick_params(colors=INK2, labelsize=8, length=0)
    ax.grid(axis="x", color=GRID, lw=0.8); ax.set_axisbelow(True)
    fig.tight_layout(); fig.savefig(f"{a.out}/py_ltv_cac_60m.png", facecolor=BG); plt.close(fig)

    with open(f"{a.out}/py_summary.json", "w") as f:
        json.dump(dict(gross_margin=GM, observed_horizon_months=OBS_H, horizon_months=H_MAX,
                       discount_rate_annual=DISC_ANNUAL, bootstrap=a.boot, channels=out), f, indent=2)

    pd.set_option("display.width", 200)
    print(res[["channel", "cac", "tail_monthly_churn_pct", "ltv_12m", "ltv_24m", "ltv_60m",
               "ltv_60m_lo", "ltv_60m_hi", "ltv_to_cac_60m", "payback_month"]].to_string(index=False))
    print("\nKM 12-month / 24-month retention (%):")
    for dim in ("channel", "plan", "promo"):
        t = km[(km.dimension == dim) & km.t.isin([12, 24])].pivot(index="group", columns="t", values="survival") * 100
        print(t.round(1).to_string()); print()


if __name__ == "__main__":
    main()
