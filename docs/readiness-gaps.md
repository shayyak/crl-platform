# Readiness gaps

Snapshot at ADR-0003 (2026-10-11): design 8.5/10, production readiness 3/10.
This is the owner-agreed list of what stands between the design and production.
Review it at the start of every step.

| # | Gap | Closes with | Target step | Status |
|---|-----|-------------|-------------|--------|
| 1 | No Threat Model (uploader on a Tier 0 CA server; no read-only S3 user, replay of an old CRL accepted risk per ADR-0004) | Short written threat model | 8 | open |
| 2 | No runbooks or recovery limits written | Runbook per failure in ADR-0003 | 9 | open |
| 3 | Serving layer undecided (caching proxy vs sidecar) | Decided 2026-10-19: Nginx caching proxy in front of the local S3; an ADR is still to be written | 5 | decided, ADR pending |
| 4 | No propagation-time measurement | Measurement harness | 6 | open |
| 5 | No failure-test results | The failure tests in ADR-0003, recorded | 10 | open |
| 6 | Windows CDP failover not verified | Real client test | 10 | open |
| 7 | No justification versus improved IIS/DFS | Comparison in an ADR | 5 | open |
| 8 | CA recovery is owned by an existing DR system (confirmed by the owner). Open point: behaviour of the uploader after a CA failover or restore (the CRL number can go backwards; the uploader must also exist on the DR CA) | Document the failover procedure and a logged break-glass override for the CRL-number check | 3, 9 | open |
| 9 | Targets (99.99%, 5 minutes, 16 hours) not confirmed | Owner confirmation | 3 | open |
| 10 | Behaviour of old-generation CRLs and delta file naming on the real CA not verified (ADR-0005) | Run discovery on a copy of a real CertEnroll directory | 3 | open |
| 11 | `+` and parentheses in CDP request paths not verified through Nginx/S3 and real clients | Serving-layer test and client test | 5, 10 | open |
| 12 | The PowerShell CRL reader will be tested only on openssl-generated fixtures until real AD CS CRLs are available | Run the validator on real CRL files | 2, 3 | partly closed: the owner's real CRL parsed with PSPKI on 2026-10-17 |
| 13 | No PowerShell runtime in the authoring environment and no test host for the owner: all PowerShell code is unverified until it runs in CI or on Windows | First green `build/Invoke-Checks.ps1` run; `-DryRun` on the real CA before any upload | 0 onward | open |
| 14 | Delivery of the S3 tooling to the CA server (module approval, signing, execution policy) undecided (ADR-0006) | Security review and ADR | 3, 8 | open |

## Gaps to 10/10 (owner review, 2026-10-20)

Rating if everything works as designed: **8/10**. What separates it from 10:

| # | Gap | Why it matters | Closes with | Status |
|---|-----|----------------|-------------|--------|
| 15 | Most CAs still publish through the old path (no uploader, no rollback protection, no self-repair) | Two pipelines to run; the old one has none of the new guarantees | Move the remaining CAs to the uploader, one at a time | open |
| 16 | Windows behaviour when the first CDP URL returns a broken CRL is unknown (same as gap 6) | If clients do not fall through to the second URL, two sites add less availability than assumed | Client test with one site serving junk | open |
| 17 | The monitor's CRL list is maintained by hand | A new CA key generation must be added manually; a forgotten entry is only caught near expiry | Decide how the list reaches the ConfigMap (generated or reviewed in GitLab) | open |
| 18 | Both sites' S3 write keys live on the CA | Compromising the CA gives write access to both sites | Prefix- and IP-restricted keys, S3 versioning, no delete permission; accepted residual risk | open |
| 19 | Emergency revocation reaches a client only when its cached CRL expires (delta validity) | Inherent to CRLs | OCSP (Online Responder) as a separate project, if needed | accepted |
| 20 | Failure drills not performed | "Works as designed" is an assumption until each failure is seen in Splunk | The drills in docs/design-uploader-and-monitor.md section 6 | open |

## Detecting changes to the code and configuration (owner requirement, 2026-10-20)

The owner wants to know whenever someone changes code or configuration outside the normal path.
**Status: not designed yet. Owner decision 2026-10-20: review this topic as its own step after the rollout.**
Candidate controls:

| What | Detection | Prevention | Status |
|---|---|---|---|
| Uploader script on each CA | To be designed (a self-reported hash was removed on 2026-10-20: the script cannot vouch for itself) | Authenticode signing with execution policy AllSigned; deployed from GitLab only; folder ACL (service account read-only) | open |
| Uploader `config.json` and `state\published.json` | File-integrity monitoring (FIM/EDR) on `D:\CrlPublisher` | Folder ACL | open |
| CA publish folder | FIM on the folder (writes by anyone other than the CA) | ACL: CA only | open |
| Monitor image | Image pinned by digest in the CronJob; any change is a manifest change | Built and pushed by CI only | digest pinning in manifests; CI build open |
| Monitor ConfigMaps (config, CRL list, CA certificates) and CronJob | List changes reported by the monitor (`list_entry_added/removed`); OpenShift audit log for ConfigMap/CronJob edits | GitOps from GitLab with review; RBAC limiting who can edit the namespace | list events implemented; GitOps and RBAC open |
| S3 objects | Uploader metadata on every object (`run-id`, `source-host`) shown in monitor findings; S3 access logs | Per-CA keys, no delete, versioning | metadata implemented; access logs and versioning open |
| Repository | Merge requests with review; protected branches | CI gates must pass | open |

Related open review item (docs/next-session.md): whether the monitor's list-change events stay depends on how
the list is managed.
