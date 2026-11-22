# ADR-0002: Two independent sites, uploader writes to both (no S3 replication)

- Status: proposed (agreed in principle by the project owner; evidence pending)
- Date: 2026-10-11

## Context

CRLs are distributed from two sites (Shay and Guy). Each site has its own
internal S3 service and its own OpenShift cluster. The two S3 services are
not replicated with each other. Existing certificates carry the CDP URLs
`publish1.com` (Shay) and `publish2.com` (Guy); these URLs must not change.

The production CA is located at Shay. Its uploader writes to the Shay bucket
and to the Guy bucket. OpenShift workloads at Shay read only the Shay bucket;
OpenShift workloads at Guy read only the Guy bucket.

Goal: losing a whole site must not stop CRL distribution, and no single
component may be a single point of failure for distribution.

## Options considered

1. **Replicated S3 across sites.** Pros: one write, storage handles copy.
   Cons: not available here; adds a cross-site dependency.
2. **Single S3 used by both sites.** Pros: simplest. Cons: the S3 becomes a
   single point of failure for both sites. Rejected.
3. **Shared-nothing sites, uploader writes to both S3 services (chosen).**
   Pros: each site is fully self-contained; site loss cannot affect the other.
   Cons: the uploader must write twice and the sites can drift apart.

## Decision

Each site is self-contained: its own S3 bucket, its own serving pods, serving
only from its local S3. The uploader writes the validated CRL to both S3
services as two independent operations, each with its own retries, result
and log entry. A success at one site is never reported as success at both.

Clients use the CDP list in the certificate (`publish1.com`, then
`publish2.com`) as the failover mechanism between sites.

## Consequences

- A failed write to one site leaves that site serving an older CRL until the
  write succeeds. This must be detected: alert when the CRL Number differs
  between sites for longer than a defined threshold.
- The CA is still a single point for producing new CRLs. If the CA is down,
  both sites keep serving the last CRL only until its `NextUpdate`. CRL
  validity and overlap must exceed the CA recovery time. CA disaster recovery
  is out of scope for this project but is recorded as a risk.
- Per-site configuration must be parameterised (needed anyway for many
  environments).

## Assumptions to verify (not yet proven)

1. Windows clients move to the next CDP URL when the first site is
   unreachable, within an acceptable time. To be measured in step 10.
2. Each site's S3 meets the stated high SLA independently.
3. The uploader can reach both S3 endpoints from the CA server.

## Evidence

Pending: failure test "one site down", measured client failover time, and a
test where the write to one site fails while the other succeeds.
