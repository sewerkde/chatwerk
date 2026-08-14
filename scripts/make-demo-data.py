#!/usr/bin/env python3
"""Generates a fake CLAUDE_CONFIG_DIR with synthetic sessions for README screenshots.
No real data anywhere — invented projects, English prompts, plausible usage numbers."""
import json, os, sys, time, uuid
from datetime import datetime, timedelta, timezone

BASE = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/chatwerk-demo-data")
PROJECTS = os.path.join(BASE, "projects")
SESSIONS = os.path.join(BASE, "sessions")
os.makedirs(PROJECTS, exist_ok=True)
os.makedirs(SESSIONS, exist_ok=True)

J = lambda o: json.dumps(o, separators=(",", ":"))
NOW = datetime.now(timezone.utc)

def iso(dt): return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

def enc(cwd): return cwd.replace("/", "-")

def write_session(cwd, branch, title, exchanges, last_prompt, age_hours, model, usage_scale=1.0):
    sid = str(uuid.uuid4())
    d = os.path.join(PROJECTS, enc(cwd))
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, sid + ".jsonl")
    start = NOW - timedelta(hours=age_hours)
    lines = []
    t = start
    for i, (q, a) in enumerate(exchanges):
        lines.append(J({"parentUuid": None if i == 0 else f"u{i-1}", "cwd": cwd,
                        "gitBranch": branch, "type": "user", "isSidechain": False,
                        "message": {"role": "user", "content": q},
                        "timestamp": iso(t)}))
        t += timedelta(minutes=2)
        lines.append(J({"parentUuid": f"u{i}", "cwd": cwd, "type": "assistant",
                        "isSidechain": False,
                        "message": {"id": f"msg_{sid[:8]}_{i}", "role": "assistant",
                                    "model": model,
                                    "content": [{"type": "text", "text": a}],
                                    "usage": {"input_tokens": int(1200 * usage_scale),
                                              "output_tokens": int(2800 * usage_scale),
                                              "cache_read_input_tokens": int(240000 * usage_scale),
                                              "cache_creation_input_tokens": int(18000 * usage_scale),
                                              "cache_creation": {"ephemeral_1h_input_tokens": int(18000 * usage_scale),
                                                                 "ephemeral_5m_input_tokens": 0}}},
                        "timestamp": iso(t)}))
        t += timedelta(minutes=6)
    lines.append(J({"type": "ai-title", "aiTitle": title}))
    lines.append(J({"type": "last-prompt", "lastPrompt": last_prompt}))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    mtime = (NOW - timedelta(hours=age_hours) + timedelta(minutes=8 * len(exchanges))).timestamp()
    os.utime(path, (mtime, mtime))
    return sid

S = "claude-sonnet-4-6"
O = "claude-opus-4-8"

sessions = {}

sessions["checkout"] = write_session(
    "/Users/demo/Projects/acme-webshop", "fix/checkout-race",
    "Fix race condition in checkout flow",
    [("Two customers just got charged twice when they double-clicked Pay. I think our checkout endpoint isn't idempotent.",
      "You're right — `POST /checkout` creates a new payment intent on every call. Let's make it idempotent:\n\n1. Add an `idempotency_key` column with a unique index\n2. Generate the key client-side when the cart page loads\n3. Return the existing intent when the key matches\n\nI'll start with the migration:\n\n```sql\nALTER TABLE payments ADD COLUMN idempotency_key TEXT;\nCREATE UNIQUE INDEX idx_payments_idem ON payments(idempotency_key);\n```"),
     ("Looks good. Can you also add a test that fires two parallel requests?",
      "Added `checkout.race.spec.ts` — it sends two concurrent requests with the same key and asserts exactly one payment row exists. Both tests pass:\n\n```\nPASS  test/checkout.race.spec.ts\n  ✓ parallel requests create a single payment (312 ms)\n```")],
    "Can you also add a test that fires two parallel requests?", 0.4, O, 1.6)

sessions["webhooks"] = write_session(
    "/Users/demo/Projects/acme-webshop", "main",
    "Stripe webhook retry queue",
    [("Our Stripe webhooks fail silently when the DB is briefly down. Add a retry queue.",
      "I'll persist incoming webhook events first, then process them from a queue with exponential backoff. Plan:\n\n- `webhook_events` table (payload, status, attempts)\n- Worker polls pending events every 10s, backoff 1m → 2m → 4m, dead-letter after 5 tries\n- `/admin/webhooks/dead` endpoint to inspect failures"),
     ("Go ahead, and wire the dead-letter count into our Grafana dashboard.",
      "Done. The worker is in `src/webhooks/retry.worker.ts`, and the dead-letter gauge is exported as `webhook_dead_letter_total`. Dashboard panel added to `grafana/checkout.json`.")],
    "Wire the dead-letter count into Grafana too.", 3.0, S, 1.1)

sessions["jwt"] = write_session(
    "/Users/demo/Projects/api-gateway", "feat/refresh-tokens",
    "Migrate auth to JWT refresh tokens",
    [("We still use 24h access tokens. Migrate to short-lived access + refresh token rotation.",
      "Here's the migration plan:\n\n1. Access tokens drop to 15 minutes\n2. Refresh tokens: 30 days, single-use, rotated on every refresh\n3. Reuse detection — if a rotated token is presented again, revoke the whole family\n\nStarting with the token service…"),
     ("What about the mobile app that's still on the old flow?",
      "Good catch. I added a compatibility window: the gateway accepts legacy 24h tokens until the `legacy_auth_sunset` feature flag flips, and responds with `X-Auth-Deprecated: true` so mobile can prompt for re-login. Mobile team needs to ship the new flow before the sunset date.")],
    "What about the mobile app that's still on the old flow?", 26, O, 1.4)

sessions["healthkit"] = write_session(
    "/Users/demo/Projects/ios-fitness-app", "bugfix/healthkit-sync",
    "HealthKit sync loses workouts",
    [("Some users report workouts missing after backgrounding the app mid-sync.",
      "The anchored query token is saved before the batch commit finishes — if iOS suspends us in between, the next sync skips that batch. Fix: persist `HKQueryAnchor` only after Core Data save succeeds, and make the sync task a `BGProcessingTask` so it can finish in the background."),
     ("Ship it, but log how often we actually get suspended mid-sync.",
      "Added an `os_signpost` interval around the batch commit plus a counter in our analytics. TestFlight build 42 is uploading now.")],
    "Log how often we get suspended mid-sync.", 30, S, 0.9)

sessions["indexes"] = write_session(
    "/Users/demo/Projects/data-pipeline", "main",
    "Optimize Postgres indexes for the reports page",
    [("The monthly report query takes 40 seconds now. EXPLAIN shows a seq scan on events.",
      "The composite index doesn't match the query's column order. `WHERE tenant_id = $1 AND created_at >= $2` needs `(tenant_id, created_at)` — you have `(created_at, tenant_id)`. Also the `ILIKE '%…%'` filter defeats any btree; I'd add a trigram index for that column:\n\n```sql\nCREATE INDEX CONCURRENTLY idx_events_tenant_time ON events(tenant_id, created_at);\nCREATE INDEX CONCURRENTLY idx_events_desc_trgm ON events USING gin(description gin_trgm_ops);\n```"),
     ("Run it on staging and compare.",
      "Staging results: 40.2s → 380ms for the monthly report, 12s → 90ms for the search endpoint. Rolled out with `CONCURRENTLY`, zero downtime.")],
    "Run it on staging and compare.", 76, O, 2.2)

sessions["terraform"] = write_session(
    "/Users/demo/Projects/api-gateway", "infra/staging-module",
    "Terraform module for the staging cluster",
    [("Extract our staging setup into a reusable Terraform module so preview envs are one apply away.",
      "Created `modules/preview-env` with inputs for name, node count and DNS zone. Each preview env gets its own namespace, ingress and a scaled-down Postgres. `terraform apply -var name=pr-123` brings one up in ~4 minutes.")],
    "Extract staging into a reusable Terraform module.", 100, S, 0.8)

sessions["darkmode"] = write_session(
    "/Users/demo/Projects/ios-fitness-app", "design/dark-audit",
    "Dark mode color audit",
    [("Several screens still hardcode white backgrounds. Audit all views for dark mode.",
      "Found 14 hardcoded `Color.white` / `UIColor.white` usages across 9 files. Replaced them with semantic colors (`systemBackground`, `secondarySystemBackground`) and added a snapshot test that renders every screen in both appearances.")],
    "Audit all views for dark mode.", 200, S, 0.7)

sessions["csv"] = write_session(
    "/Users/demo/Projects/data-pipeline", "refactor/importer",
    "Refactor the CSV importer",
    [("The CSV importer is 800 lines of spaghetti. Split it into parse → validate → load stages.",
      "Refactored into three composable stages with a shared `ImportContext`. Each stage is independently testable; the validator now reports ALL row errors instead of dying on the first one. 34 new unit tests, all green.")],
    "Split the importer into parse → validate → load.", 480, O, 1.0)

sessions["dotfiles"] = write_session(
    "/Users/demo/dotfiles", "main",
    "Tmux and zsh startup cleanup",
    [("My shell takes 2 seconds to start. Profile and fix my zshrc.",
      "`zprof` says 80% is nvm loading eagerly. I made it lazy-load on first use, deferred compinit with a cache, and moved the theme to starship. Cold start: 1.9s → 140ms.")],
    "Profile and fix my zshrc.", 700, S, 0.5)

# Live session records: one busy (working), one idle (your turn).
def live(pid, sid, status, cwd):
    with open(os.path.join(SESSIONS, f"{pid}.json"), "w") as f:
        f.write(J({"sessionId": sid, "pid": int(pid), "status": status, "cwd": cwd}))

busy_pid, idle_pid = sys.argv[2], sys.argv[3]
live(busy_pid, sessions["checkout"], "busy", "/Users/demo/Projects/acme-webshop")
live(idle_pid, sessions["webhooks"], "idle", "/Users/demo/Projects/acme-webshop")

print(json.dumps(sessions, indent=0))
