# ADR-0007: Monitor in Python on OpenShift (amends ADR-0006)

- Status: accepted (owner decision, 2026-10-20)
- Date: 2026-10-20
- Amends: ADR-0006 decision 1 (the monitor and external checker). The uploader stays PowerShell.

## Context

The monitor must check what clients actually receive and must not share a failure domain with what it
checks. The owner decided that the CA is the only Windows server in the platform and everything else runs
on OpenShift. A pod is Linux; PSPKI is Windows-only, and without it PowerShell has no reliable CRL parser
or CRL signature check.

## Options considered

1. PowerShell + PSPKI on a dedicated Windows server: reuses the existing script; keeps a Windows server
   alive only for monitoring; CI testing of PSPKI code is awkward.
2. Python + `cryptography` as a CronJob on OpenShift: CRL parsing and signature verification are
   first-class and documented; runs like every other workload; testable in CI with generated CRLs.
3. bash + openssl CronJob: no dependencies, but error handling, state and Splunk batching become fragile.

## Decision

Option 2. The monitor is a Python package (`monitor/`), built as a non-root container image and run as a
CronJob in the cluster of the *other* site. The uploader remains PowerShell on the CA (ADR-0006 still applies
to it).

## Consequences

- Two languages in the repository; each component has its own quality gate (Pester/PSScriptAnalyzer for the
  uploader, pytest/ruff for the monitor).
- The monitor is one file, `monitor/crl_monitor.py` (simplified on 2026-10-20 at the owner's request).
- The uploader is a single script that can be dot-sourced for tests (`tests/Publish-Crl.Tests.ps1`);
  the unused module skeleton `src/CrlPublisher/` from ADR-0006 decision 3 was removed.
- The existing PowerShell monitor (`CheckCRLExpiration`) keeps running until the new monitor is in production.
- The monitor reads its CRL list and the pinned CA certificates from a ConfigMap; how the list is maintained
  is decided later.

## Evidence

Monitor test suite (pytest) passes in the authoring environment, including real openssl-generated CRLs
from `tests/fixtures`.
