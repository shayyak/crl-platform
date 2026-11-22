# Open questions

Nothing here is decided. Each item needs an answer (and usually an ADR) before the
step that depends on it.

| # | Question | Needed by step | Status |
|---|----------|----------------|--------|
| 1 | Is the new design actually better than improved IIS/DFS? | 5 | open |
| 2 | Which S3-compatible service is used, and what is its HA/SLA? | 7 | open |
| 3 | Sidecar vs caching proxy vs CronJob | 5 | open |
| 4 | Sync frequency and freshness policy | 5 | open |
| 5 | How is the uploader triggered on the CA? | 6 | open |
| 6 | Is Delta CRL enabled on the CA? | 2 | open |
| 7 | Are CDP URLs in existing certificates preserved? | 5 | open |
| 8 | Do Windows clients fail over between CDP URLs as expected? | 10 | open |
| 9 | Site failover design (two sites) | 9 | proposed in ADR-0002, evidence pending |
| 10 | Success metrics (propagation time target, availability) | 3 | open |
| 11 | Which PowerShell version and execution policy run on the CA servers? | 2 | open |
| 12 | May pinned AWS tooling be placed on the CA server, and how is it delivered? | 3 | open |
| 13 | Is a Splunk Universal Forwarder (or other log agent) present on the CA server? | 3 | open |
| 14 | Can GitLab runners run a PowerShell container with Pester, to test without a Windows host? | 0 | open |
| 15 | CA failover: what is the DR recovery time, does the DR CA keep the same keys, and does the CRL number continue upward after a restore? | 3 | open |
| 16 | Is the uploader deployed and configured on the DR CA, and is it guaranteed that only one CA runs it at a time? | 3 | open |

## Deferred explanations (owner asked for these at the end of the project)

- Full rebuild guide for another network (see docs/documentation-rule.md).
- Why the uploader is ~480 lines, and what the cost would be of a ~150 line version
  (no staging/lkg, no CRL number comparison, no lock): partial or older-over-newer writes.
- Deployment hardening runbook for the uploader host (owner asked for this at the end): one folder
  (e.g. D:\CrlPublisher with logs\ and secrets\), a dedicated non-admin service account, least-privilege
  NTFS ACLs (service account: Read&Execute on the folder, Modify on secrets\ and logs\), creating the DPAPI
  credential files as the service account on the same host, and permission verification steps.
