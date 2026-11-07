#!/usr/bin/env python3
"""
generate_subscription_data.py  |  Project 4D: Subscription revenue and LTV

Builds a SYNTHETIC streaming-style subscription business: 36 months
(2023-01 to 2025-12) of signups, billing, plan changes, pauses, cancellations
and marketing spend. It is inspired by subscription businesses in general and
does not contain or represent any real company's data or decisions.

Outputs (in --out, default ./data):
  customers.csv, subscription_months.csv, events.csv, marketing_spend.csv
  subscriptions.db   (the same four tables in SQLite, with indexes)

Only needs numpy (plus the Python standard library).
Run:  python3 generate_subscription_data.py            (about 10-20 seconds)
      python3 generate_subscription_data.py --customers 10000 --seed 7

DATA-GENERATING ASSUMPTIONS (documented on purpose: publish these in your
README so a reader knows what is built in and what is "discovered"):
  * Prices: Basic $7.99, Premium $19.99, Standard $13.99 rising to $15.99
    from 2025-03 for ALL Standard subscribers.
  * Promo: signups in Nov 2023 and Nov 2024 (and a few at other times) get
    50% off for their first 3 months; full price starts in month 4.
  * Monthly cancel risk depends on plan, acquisition channel, tenure (highest
    in months 2-3), country, device, a "promo cliff" in month 4, the 2025
    price rise, and an early-upgrade effect.
  * Mix shift: paid_social shrinks and referral grows over time.
  * Paused months bill $0. Data ends 2025-12, so recent cohorts are censored.
  * Channel costs (CAC) differ widely and drift upward for paid channels.
  * Gross margin is NOT in the data: choose and state your own (e.g. 70%).
"""
import argparse
import csv
import os
import sqlite3
import time

import numpy as np

T = 36                                    # months: index 0 = 2023-01 ... 35 = 2025-12
PLANS = ["Basic", "Standard", "Premium"]
PRICE = np.array([7.99, 13.99, 19.99])
HIKE_T = 26                               # 2025-03: Standard price rises
HIKE_PRICE = 15.99
CHANNELS = ["organic", "paid_social", "paid_search", "referral", "partnership"]
SHARE_START = np.array([0.30, 0.35, 0.17, 0.08, 0.10])
SHARE_END = np.array([0.30, 0.15, 0.15, 0.28, 0.12])
PLAN_BY_CHANNEL = np.array([  # P(Basic, Standard, Premium) at signup
    [0.30, 0.50, 0.20],       # organic
    [0.50, 0.40, 0.10],       # paid_social
    [0.40, 0.45, 0.15],       # paid_search
    [0.25, 0.50, 0.25],       # referral
    [0.35, 0.45, 0.20],       # partnership
])
CAC_BASE = np.array([8.0, 85.0, 70.0, 25.0, 40.0])
CAC_DRIFT = np.array([0.000, 0.012, 0.008, 0.002, 0.003])   # per-month increase
COUNTRIES = ["US", "GB", "CA", "DE", "BR", "IN"]
COUNTRY_P = np.array([0.38, 0.14, 0.10, 0.12, 0.14, 0.12])
COUNTRY_EFF = np.array([0.0, -0.05, 0.0, -0.10, 0.15, 0.20])
DEVICES = ["ios", "android", "web", "tv"]
DEVICE_P = np.array([0.30, 0.28, 0.17, 0.25])
DEVICE_EFF = np.array([0.0, 0.10, 0.05, -0.20])
PROMO_MONTHS = {10, 22}                   # Nov 2023, Nov 2024

BASE_LOGIT = -3.55
PLAN_EFF = np.array([0.35, 0.0, -0.30])
CHANNEL_EFF = np.array([0.0, 0.45, 0.15, -0.50, -0.25])


def month_str(i):
    return f"{2023 + i // 12}-{i % 12 + 1:02d}-01"


def weights():
    w = []
    for m in range(T):
        seasonal = {10: 0.35, 11: 0.15, 0: 0.25, 6: -0.10}.get(m % 12, 0.0)
        w.append(1.0 + 0.025 * m + seasonal)
    w = np.array(w)
    return w / w.sum()


def price_at(plan, t):
    p = PRICE[plan].copy()
    if t >= HIKE_T:
        p = np.where(plan == 1, HIKE_PRICE, p)
    return p


def simulate(n_customers, seed):
    rng = np.random.default_rng(seed)
    per_month = np.floor(weights() * n_customers).astype(int)
    per_month[-1] += n_customers - per_month.sum()

    signup = np.repeat(np.arange(T), per_month)
    n = len(signup)
    channel = np.zeros(n, dtype=int)
    plan0 = np.zeros(n, dtype=int)
    promo = np.zeros(n, dtype=bool)
    for t in range(T):
        sel = np.where(signup == t)[0]
        share = SHARE_START + (SHARE_END - SHARE_START) * (t / (T - 1))
        ch = rng.choice(5, size=len(sel), p=share / share.sum())
        channel[sel] = ch
        for c in range(5):
            cs = sel[ch == c]
            plan0[cs] = rng.choice(3, size=len(cs), p=PLAN_BY_CHANNEL[c])
        p_promo = 0.55 if t in PROMO_MONTHS else 0.04
        if t in PROMO_MONTHS:
            p_promo = np.where(channel[sel] == 3, 0.25, 0.55)   # fewer promo users via referral
        promo[sel] = rng.random(len(sel)) < p_promo
    country = rng.choice(len(COUNTRIES), size=n, p=COUNTRY_P)
    device = rng.choice(len(DEVICES), size=n, p=DEVICE_P)

    status = np.zeros(n, dtype=int)       # 0 not started, 1 active, 2 paused, 3 churned
    plan = plan0.copy()
    tenure = np.zeros(n, dtype=int)
    pause_left = np.zeros(n, dtype=int)
    early_up = np.zeros(n, dtype=bool)

    rows, events = [], []                 # rows: (cust_idx, t, plan, status, mrr, tenure)

    def log(idx, t, etype, frm, to):
        for k in range(len(idx)):
            events.append((idx[k], t, etype, frm[k], to[k], tenure[idx[k]]))

    for t in range(T):
        # --- existing customers ---
        live = (signup < t) & ((status == 1) | (status == 2))
        tenure[live] += 1
        just_resumed = np.zeros(n, dtype=bool)

        paused = live & (status == 2)
        pause_left[paused] -= 1
        ending = np.where(paused & (pause_left <= 0))[0]
        if len(ending):
            resume = rng.random(len(ending)) < 0.70
            r = ending[resume]
            c = ending[~resume]
            status[r] = 1
            just_resumed[r] = True
            log(r, t, "resume", plan[r], plan[r])
            status[c] = 3
            log(c, t, "cancel", plan[c], plan[c])

        act_idx = np.where(live & (status == 1) & ~just_resumed)[0]
        if len(act_idx):
            ten = tenure[act_idx]
            pl = plan[act_idx]
            logit = (BASE_LOGIT + PLAN_EFF[pl] + CHANNEL_EFF[channel[act_idx]]
                     + COUNTRY_EFF[country[act_idx]] + DEVICE_EFF[device[act_idx]])
            logit += np.where(ten <= 3, 0.6, np.where(ten <= 6, 0.2, np.where(ten <= 12, 0.0, -0.4)))
            logit += np.where(promo[act_idx] & (ten == 4), 1.1, 0.0)           # promo cliff
            logit += np.where(promo[act_idx] & (ten <= 3), -0.2, 0.0)          # happy while discounted
            if t >= HIKE_T:                                                     # price rise
                logit += np.where(pl == 1, 0.55 if t < HIKE_T + 3 else 0.15, 0.0)
            logit += np.where(early_up[act_idx], -0.45, 0.0)                    # early upgraders stick
            churn = rng.random(len(act_idx)) < 1.0 / (1.0 + np.exp(-logit))
            ch_i = act_idx[churn]
            status[ch_i] = 3
            log(ch_i, t, "cancel", plan[ch_i], plan[ch_i])

            stay = act_idx[~churn]
            u = rng.random(len(stay))
            pause_now = stay[u < 0.006]
            status[pause_now] = 2
            pause_left[pause_now] = rng.integers(1, 4, size=len(pause_now))
            log(pause_now, t, "pause", plan[pause_now], plan[pause_now])

            rest = stay[u >= 0.006]
            v = rng.random(len(rest))
            pl = plan[rest]
            ten = tenure[rest]
            p_up_basic = np.where(ten <= 3, 0.035, 0.012)
            p_dn_std = 0.018 if HIKE_T <= t < HIKE_T + 3 else 0.009
            up = ((pl == 0) & (v < p_up_basic)) | ((pl == 1) & (v < 0.007))
            dn = ((pl == 1) & (v >= 0.007) & (v < 0.007 + p_dn_std)) | ((pl == 2) & (v < 0.008))
            up_i, dn_i = rest[up], rest[dn]
            old_up, old_dn = plan[up_i].copy(), plan[dn_i].copy()
            plan[up_i] += 1
            plan[dn_i] -= 1
            early_up[up_i[(plan[up_i] == 1) & (tenure[up_i] <= 3)]] = True
            log(up_i, t, "upgrade", old_up, plan[up_i])
            log(dn_i, t, "downgrade", old_dn, plan[dn_i])

        # --- new signups ---
        new_i = np.where(signup == t)[0]
        status[new_i] = 1
        tenure[new_i] = 1
        log(new_i, t, "signup", plan[new_i], plan[new_i])

        # --- billing rows for this month ---
        bill = np.where((status == 1) | (status == 2))[0]
        base_price = price_at(plan[bill], t)
        disc = np.where(promo[bill] & (tenure[bill] <= 3), 0.5, 1.0)
        mrr = np.where(status[bill] == 1, np.round(base_price * disc, 2), 0.0)
        rows.append((bill, np.full(len(bill), t), plan[bill].copy(), status[bill].copy(), mrr, tenure[bill].copy()))

    # --- marketing spend ---
    spend = []
    new_by = np.zeros((T, 5), dtype=int)
    for c in range(5):
        new_by[:, c] = np.bincount(signup[channel == c], minlength=T)
    for t in range(T):
        for c in range(5):
            cac = CAC_BASE[c] * (1 + CAC_DRIFT[c] * t)
            spend.append((month_str(t), CHANNELS[c], round(float(new_by[t, c] * cac * rng.lognormal(0, 0.07)), 2)))

    return dict(n=n, signup=signup, channel=channel, plan0=plan0, promo=promo, country=country,
                device=device, rows=rows, events=events, spend=spend, new_by=new_by)


def write_outputs(sim, out):
    os.makedirs(out, exist_ok=True)
    n = sim["n"]
    cust = [(i + 1, month_str(sim["signup"][i]), CHANNELS[sim["channel"][i]], COUNTRIES[sim["country"][i]],
             DEVICES[sim["device"][i]], PLANS[sim["plan0"][i]], int(sim["promo"][i])) for i in range(n)]
    sm = []
    for bill, tt, pl, st, mrr, ten in sim["rows"]:
        for k in range(len(bill)):
            sm.append((int(bill[k]) + 1, month_str(int(tt[k])), PLANS[pl[k]], "active" if st[k] == 1 else "paused",
                       float(mrr[k]), int(ten[k])))
    ev = [(j + 1, int(e[0]) + 1, month_str(e[1]), e[2], PLANS[e[3]], PLANS[e[4]], int(e[5]))
          for j, e in enumerate(sorted(sim["events"], key=lambda e: (e[1], e[0])))]

    tables = {
        "customers": (["customer_id", "signup_month", "channel", "country", "device", "signup_plan", "promo_signup"], cust),
        "subscription_months": (["customer_id", "month", "plan", "status", "mrr", "tenure_month"], sm),
        "events": (["event_id", "customer_id", "event_month", "event_type", "from_plan", "to_plan", "tenure_month"], ev),
        "marketing_spend": (["month", "channel", "spend_usd"], sim["spend"]),
    }
    for name, (cols, data) in tables.items():
        with open(os.path.join(out, name + ".csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(cols)
            w.writerows(data)

    db_path = os.path.join(out, "subscriptions.db")
    if os.path.exists(db_path):
        os.remove(db_path)
    con = sqlite3.connect(db_path)
    ddl = {
        "customers": "customer_id INTEGER PRIMARY KEY, signup_month TEXT, channel TEXT, country TEXT, device TEXT, signup_plan TEXT, promo_signup INTEGER",
        "subscription_months": "customer_id INTEGER, month TEXT, plan TEXT, status TEXT, mrr REAL, tenure_month INTEGER",
        "events": "event_id INTEGER PRIMARY KEY, customer_id INTEGER, event_month TEXT, event_type TEXT, from_plan TEXT, to_plan TEXT, tenure_month INTEGER",
        "marketing_spend": "month TEXT, channel TEXT, spend_usd REAL",
    }
    for name, (cols, data) in tables.items():
        con.execute(f"CREATE TABLE {name} ({ddl[name]})")
        con.executemany(f"INSERT INTO {name} VALUES ({','.join('?' * len(cols))})", data)
    con.execute("CREATE INDEX ix_sm_cust ON subscription_months(customer_id)")
    con.execute("CREATE INDEX ix_sm_month ON subscription_months(month)")
    con.execute("CREATE INDEX ix_ev_cust ON events(customer_id)")
    con.commit()
    con.close()
    return {k: len(v[1]) for k, v in tables.items()}


def summary(sim, gross_margin=0.70):
    """Sanity checks on the built-in patterns (printed after generation)."""
    n = sim["n"]
    ch = sim["channel"]
    allrows = {k: np.concatenate([r[i] for r in sim["rows"]]) for i, k in enumerate(["c", "t", "plan", "st", "mrr", "ten"])}
    ev = sim["events"]
    ev_c = np.array([e[0] for e in ev]); ev_t = np.array([e[1] for e in ev])
    ev_type = np.array([e[2] for e in ev]); ev_ten = np.array([e[5] for e in ev]); ev_from = np.array([e[3] for e in ev])
    cancel = ev_type == "cancel"
    print("\n=== Sanity summary (not part of your deliverable) ===")
    active_end = ((allrows["t"] == T - 1)).sum()
    print(f"customers {n:,} | billing rows {len(allrows['c']):,} | on the books in 2025-12: {active_end:,}")
    print(f"MRR 2025-12: ${allrows['mrr'][allrows['t'] == T - 1].sum():,.0f} | MRR 2023-12: ${allrows['mrr'][allrows['t'] == 11].sum():,.0f}")
    at_risk_t = np.bincount(allrows["t"], minlength=T)
    canc_t = np.bincount(ev_t[cancel], minlength=T)
    for yr in range(3):
        ts = [t for t in range(max(1, 12 * yr), 12 * yr + 12)]
        print(f"blended monthly churn {2023 + yr}: {canc_t[ts].sum() / at_risk_t[[t - 1 for t in ts]].sum() * 100:.2f}%")
    print("monthly churn by channel (all months):")
    for c, name in enumerate(CHANNELS):
        in_c = ch[allrows["c"]] == c
        risk = ((allrows["t"] <= T - 2) & in_c).sum()
        canc = (cancel & (ch[ev_c] == c)).sum()
        print(f"   {name:12s} {canc / risk * 100:.2f}%")
    # promo cliff: hazard at tenure 4 vs tenure 3 among decisions
    for flag, label in [(True, "promo"), (False, "non-promo")]:
        pm = sim["promo"] == flag
        risk4 = ((allrows["ten"] == 3) & pm[allrows["c"]] & (allrows["st"] == 1)).sum()
        c4 = (cancel & (ev_ten == 4) & pm[ev_c]).sum()
        print(f"cancel rate entering month 4 ({label}): {c4 / risk4 * 100:.1f}%")
    # price rise
    std_rows = allrows["plan"] == 1
    def std_rate(ts):
        risk = sum(((allrows["t"] == t - 1) & std_rows).sum() for t in ts)
        c = sum((cancel & (ev_t == t) & (ev_from == 1)).sum() for t in ts)
        return c / risk * 100
    print(f"Standard churn: before rise (2024-09..2025-02) {std_rate(range(20, 26)):.2f}% | after (2025-03..2025-05) {std_rate(range(26, 29)):.2f}%")
    # 12-month revenue per signup by channel vs CAC
    print("12-month gross profit per signup vs CAC (cohorts with 12 observed months, margin %.0f%%):" % (gross_margin * 100))
    obs = sim["signup"] <= T - 12
    for c, name in enumerate(CHANNELS):
        m = (ch == c) & obs
        rev = np.zeros(n)
        sel = (allrows["ten"] <= 12)
        np.add.at(rev, allrows["c"][sel], allrows["mrr"][sel])
        cac = CAC_BASE[c] * (1 + CAC_DRIFT[c] * np.mean(sim["signup"][m]))
        gp = rev[m].mean() * gross_margin
        print(f"   {name:12s} gross profit ${gp:6.2f}  CAC ~${cac:5.2f}  ratio {gp / cac:4.1f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--customers", type=int, default=25000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="data")
    ap.add_argument("--no-summary", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    sim = simulate(a.customers, a.seed)
    counts = write_outputs(sim, a.out)
    print(f"Wrote {a.out}/ in {time.time() - t0:.1f}s: " + ", ".join(f"{k} {v:,}" for k, v in counts.items()))
    if not a.no_summary:
        summary(sim)


if __name__ == "__main__":
    main()
