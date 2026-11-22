# ADR-0003: Target architecture and failure modes

- Status: proposed (agreed in principle by the project owner; evidence pending)
- Date: 2026-10-11
- Builds on: ADR-0002 (two independent sites, dual write)
- Open gaps: see `docs/readiness-gaps.md`

## Context

Replace the current CRL distribution path (CA to GitLab, hourly pull by IIS
publish servers) with a platform that is self-contained per site, observable,
and rolled out across many environments. Existing CDP URLs
(`publish1.com`, `publish2.com`) stay unchanged. The internal S3 service has a
high SLA and is not replicated between sites. An hourly external monitor
already alerts when a CRL is within 16 hours of expiry.

## Decision

### Components and responsibilities

```
Site Shay                                      Site Guy
CA (AD CS) -> C:\CRL
Uploader (PowerShell, gMSA, validate once)
   |-- write -----------------------------+-- write (cross-site)
   v                                      v
S3 Shay                                S3 Guy
   v                                      v
OpenShift Shay: Nginx x3               OpenShift Guy: Nginx x3
   |                                      |
publish1.com                           publish2.com
       \______ clients (CDP list) ______/

External checker (independent): probes every serving endpoint of both sites,
compares CRL Number across sites, ships results to Splunk.
```

| Component | Responsibility | Not responsible for |
|-----------|----------------|---------------------|
| CA | Create and sign CRLs | Distribution |
| Uploader | Validate once, write to both S3 services, report per destination | Serving |
| S3 (per site) | Source of truth for that site | Cross-site replication |
| Serving pods | Serve the CRL, stateless, read local S3 only | Validation of CRL content |
| External checker | Observe what clients see, alert | Fixing anything |

The serving layer (caching proxy in front of S3 versus sidecar sync) is **not
decided here**; it is decided by measurement in step 5 (ADR to follow).

### Risk classes, each with its own detection

1. Expiry or staleness: covered by the existing 16 hour alert plus a
   cross-site CRL Number comparison.
2. Availability (404, site down): needs detection within minutes, by probing
   every serving endpoint individually (not only the round-robin name).
3. Revocation freshness (emergency revoke): needs a documented break-glass
   path to publish and verify quickly. The expiry alert does not cover this.

### Failure modes and handling

| Failure | Effect | Handling |
|---------|--------|----------|
| Shay site down (CA down too) | No new CRLs; both sites serve last CRL until `NextUpdate` | CRL validity and overlap longer than CA recovery time plus the alert budget; runbook; CA recovery is owned by the existing DR system (readiness gap 8) |
| Uploader fails | S3 keeps an old CRL | Alert when S3 CRL is older than the CA local file; non-zero exit code; monitor that the task ran |
| Write to Guy fails | Guy serves an older CRL | Independent retries per destination; alert on CRL Number skew |
| Corrupt CRL uploaded | Overwrite replaces a good copy | Validate before upload; write to a staging key, verify, then copy to the final key; keep a last-known-good key |
| Site S3 down | Cached serving continues; a restarted pod may have no CRL | Readiness requires a CRL; spread pods; clients fail over to the other site |
| OpenShift cluster down | A whole site stops serving | Clients use the other CDP URL (to be measured) |
| Pod or node loss | Reduced capacity | At least 3 replicas, anti-affinity, PodDisruptionBudget, probes |
| Stale served copy | Old CRL served although S3 is newer | Short cache TTL; checker compares served bytes to the S3 object |
| S3 credentials expire | Uploader fails suddenly | Planned rotation; separate alert for auth errors versus network errors |
| Clients do not fail over | A site failure becomes a client failure | Test in step 10; if needed, add a load balancer per name |
| Monitoring disappears | False quiet | Dead man's switch on the checker |
| Clock skew | Wrong validity decisions | Time sync checks on the CA and the clusters |
| Bad manual change | Outage after a change | GitOps with review, pinned versions, rollback |

### Proposed targets (to be confirmed and measured)

- Availability of each CDP URL: 99.99%, measured by external probes.
- Propagation: new CRL present at all serving endpoints within 5 minutes of
  publication at the CA (p99).
- Response budget: 16 hours from the expiry alert to resolution.

## Consequences

- More moving parts than an improved IIS/DFS setup; justified only if the
  measurements in the evidence plan show better availability or operability.
- Every environment needs per-environment configuration, no hardcoded values.
- The CA remains a single producer of CRLs.

## Assumptions to verify

1. Windows clients fail over between CDP URLs acceptably (step 10).
2. Each site S3 meets its SLA on its own.
3. The CA server can reach both S3 endpoints.
4. The proposed targets are acceptable to the organisation.

## Evidence plan

Propagation-time measurement (step 6), one-site-down test, failed-write-to-one-
site test, corrupt-CRL test, restart-with-S3-down test, and a real Windows
client check (step 10). Results are recorded, not just marked as passed.
