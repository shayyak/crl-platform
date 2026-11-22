# Design: uploader and monitor (target: production grade)

Status: proposal, 2026-10-20. Nothing here has been executed yet; "production grade" is reached only when the
tests in section 6 pass in the owner's environment.

## 1. Roles

| Component | Job | Runs on | Writes to | Trust |
|---|---|---|---|---|
| Uploader (PowerShell) | Get each CRL the CA produced to both sites, never older than before, never broken | Each participating CA (Windows), Scheduled Task | S3 of both sites (own prefix only) | Trusts the CA publish folder and its own local state. Treats S3 content as untrusted. |
| Serving (Nginx) | Serve `http://publishN/<path>` from the site's S3, keep serving when S3 is down | OpenShift, each site | Nothing (cache on PVC) | Trusts its local S3 |
| Monitor (Python) | Prove that what clients receive is present, authentic, valid, current and identical on all sites | OpenShift CronJob, the *other* site | Splunk only | Trusts only the pinned CA certificates in its ConfigMap |

Principle: the uploader **prevents and repairs**, the monitor **detects**, Splunk detects that either of them stopped.

## 2. Uploader

### 2.1 Flow per run (v2.1, after removing checks the monitor already covers)

1. Log `run_start` with the script version.
2. Read every file with extension exactly `.crl` from the publish folder. Skip (`crl_rejected`) a file that
   does not parse or has no CRL number. Keep a private copy of the bytes read; upload only that copy.
3. Rollback protection from a local state file (`state\published.json`: highest CRL number published per S3
   key). Source number lower than recorded -> `crl_older_than_published`, exit 4. A corrupt state file stops
   the run (exit 1) rather than silently losing the protection.
4. Per site, independently: download the live object and compare SHA-256 with the source. Identical ->
   `unchanged`. Anything else (missing, junk, old, forged with a high number) -> upload the source with
   metadata. S3 content never blocks a repair.
5. Record the published numbers, log `run_end`, send all events to Splunk HEC.

Removed in v2.1 because the monitor or the platform already covers them: expiry / not-yet-valid / 24 h
warning (monitor), same-number-different-content (cannot happen in a CA-only folder), bootstrap conflict
(a wrong upload shows up in the monitor as `crl_number_decreased`), read-back and restore (SDK integrity +
monitor), `lkg/` (S3 versioning), mutex (task setting), Event Log (Splunk), `-ValidateOnly` (`-DryRun`).

Exit codes: 0 ok, 1 config/startup/state, 2 some sites failed, 3 all failed, 4 CRL rejected.

### 2.3 Hosting and hardening
- Scheduled Task with two triggers:
  (a) on CRL publication: Security log event 4872 ("published the certificate revocation list"), delayed 30 s.
      Requires "Audit Certification Services" and the CA audit filter for revoke/publish CRL events;
  (b) safety run every hour: retries uploads that failed (no next publication may come for days),
      repairs tampered S3 objects, and gives Splunk a regular `run_end` to alert on.
  "Do not start a new instance", "stop if running longer than 10 minutes",
  run as a dedicated non-admin service account (gMSA or local), "log on as a batch job".
- Folder `D:\CrlPublisher`: script read-only for the service account; `secrets\`, `logs\`, `state\` modify for
  the service account only; admins full control.
- Publish folder: written by the CA only (CDP "Publish CRLs to this location"); read for the service account.
- Script signed, execution policy AllSigned, deployed from GitLab only. FIM alert on script and config change.
- S3 key per CA and per site: `PutObject/GetObject` on its own prefix, no delete,
  restricted to the CA's IP. Verify the internal S3 supports prefix and IP conditions.
- Emergency revocation: `certutil -crl` fires the event trigger; propagation in about a minute.

### 2.4 Changes versus the earlier script (v1)
| Change | Why |
|---|---|
| Local state for rollback protection; repair on any SHA difference | Forged high-number CRL in S3 no longer blocks self-repair |
| Exact `.crl` extension match | `-Filter *.crl` also matches longer extensions |
| Remove `staging/` | PUT is atomic; less code and fewer S3 calls |
| Event trigger (4872) + hourly safety run | Upload right after every publication; retries and repairs between publications |

## 3. Serving layer (Nginx)
- `proxy_cache` in front of the local S3, ~60 s validity, background update, cache lock,
  `proxy_cache_use_stale error timeout updating http_5xx`, `inactive=30d`, cache on a PVC.
- `add_header X-Cache-Status $upstream_cache_status;` (used by the monitor).
- Deny `staging/` and `lkg/`; `Content-Type: application/pkix-crl`; pass `x-amz-meta-*` headers through.
- Delta names contain `+`. Clients request it literally; some S3 implementations decode `+` in a path as a
  space, so Nginx must send `%2B` to S3. Verify with a delta CRL before go-live.
- Anonymous read on CRL prefixes from the OpenShift network only (Nginx does not sign S3 requests).
- Readiness probe, several replicas per site, non-root image pinned by digest.

## 4. Monitor

### 4.1 Inputs
- ConfigMap: target hosts (`publish1.com`, `publish2.com`), the CRL list file, pinned CA certificates,
  expiry rules (`defaultHours: 17`, `root -> 168`), thresholds. How the list gets into the ConfigMap is
  decided later (owner, 2026-10-20).
- Secrets: HEC token; optional Splunk search token (check 12).
- State on a PVC: high-water mark per path, last list hash and entries, consecutive-failure counters.
  Written atomically; a corrupt state file raises a warning and starts fresh, never blocks the run.

### 4.2 Checks
List (once per run, from the ConfigMap file):
1. Unreadable, unparseable, unknown CA name **or empty** -> error (an empty list is never "all OK").
2. (dropped: the list is no longer fetched from the hosts)
3. Lines added since last run -> info; lines removed -> warning.

Per CRL, per host:
4. HTTP 200 (status recorded).
5. Parses as a CRL (an empty body fails here too).
6. Signature valid against the pinned certificate of the CA named on that line.
7. ThisUpdate not in the future; NextUpdate not passed.
8. Less than 17 h to NextUpdate (168 h when the path contains `root`) -> warning.
9. CRL number not lower than the high-water mark -> otherwise error, immediately.
10. `X-Cache-Status: STALE` on consecutive runs -> error (Nginx cannot read S3 and serves old copies).

Across hosts:
11. Same path with a different CRL number for more than 30 minutes -> warning.
    Why it stays (owner review, 2026-10-20): when the uploader fails to reach a site it reports that itself,
    but most CRLs are still published by the old path with no uploader to report anything, and an Nginx
    that keeps serving an old copy without marking it STALE is invisible to every other check. After an
    off-schedule publication (emergency revocation) the old CRL is still valid for days, so the expiry
    warning stays silent; only this comparison catches a site that did not receive it, within 30 minutes.
    Revisit once every CA publishes through the uploader.

Optional, phase 2:
12. Served number equals the latest number the uploader reported in Splunk, within 30 minutes
    (only for CRLs published by the uploader). Catches a wrong `keyPrefix` immediately.

### 4.3 Alert behaviour
- Every request: timeout and 3 retries.
- Error only after 2 consecutive failing runs, except signature failure and decreasing number (immediate).
- A cleared problem emits `resolved`.
- Every failure event: host, path, check, reason, HTTP status, CRL number, hours remaining.
- Every run ends with `crl_monitor_run_completed` (status, counts, duration), whatever the outcome.
  Splunk alerts when it stops arriving (configured by the owner); same for the uploader's `run_end`.

### 4.4 Hosting and hardening
- Python 3 + `cryptography` + `requests`; image pinned by digest and scanned.
- CronJob every 5 minutes, `concurrencyPolicy: Forbid`, `activeDeadlineSeconds`, runs in the other site's cluster.
- Non-root, read-only root filesystem (PVC is the only writable mount), NetworkPolicy egress to the publish
  hosts and Splunk only.
- Requires a new ADR replacing ADR-0006 (PowerShell only).

### 4.5 Kept deliberately simple (owner, 2026-10-20)
One file (`monitor/crl_monitor.py`), one command (a run). Kept: every check above, the consecutive-failure
grace, HTTP and Splunk retries, uploader metadata in findings, high-water marks raised only by
signature-verified CRLs, several key generations per CA name (one PEM bundle). Dropped as extras: the
`check` and `validate-config` commands, DER/directory certificate formats, detailed config validation,
"resolved" events, a body size cap, strict type checking.

Uploader touches: S3 object metadata (above), retry with backoff on every S3 call, script version in
`run_start`. Detecting changes to the code is a separate, open topic (docs/readiness-gaps.md).

## 5. Infrastructure prerequisites
- S3 versioning on both sites (the rollback for bad objects); no delete permission for writers.
- Per-CA, per-site write keys restricted by prefix and source IP.
- Splunk: alert on missing `run_end` per uploader and missing `crl_monitor_run_completed` per site.
- Rotate the HEC token that was exposed earlier.

## 6. Definition of done (what makes it production grade)
- Uploader: Pester tests with the openssl fixtures and mocked S3 cmdlets covering every branch of 2.1;
  PSScriptAnalyzer clean; CI green in GitLab.
- Monitor: pytest with the fixtures (valid, expired, wrong signature, wrong CA, junk, empty, decreasing number,
  delta, list empty/changed, stale cache header); CI green; image scan clean.
- Failure drills in the test environment, each one observed in Splunk with the expected event:
  S3 down at one site; junk in S3; old CRL in S3; forged high-number CRL in S3; Nginx down; Nginx without S3
  read access; uploader task disabled; monitor pod killed; list line removed; emergency revocation end to end.
- Runbook: one entry per alert type (meaning, first checks, fix).
- Documentation sufficient to rebuild on another network (docs/documentation-rule.md).
