# ADR-0006: PowerShell-only toolchain (replaces the Python uploader decision)

- Status: proposed (owner decision on 2026-10-13: no Python anywhere in the project)
- Date: 2026-10-13
- Builds on: ADR-0003, ADR-0005

## Context

Earlier discussion assumed a Python uploader, and a Python prototype was built:
a CRL validator, directory discovery and a test PKI generator, with 44 passing
tests. The owner decided to drop Python and follow best practice throughout.

Facts that favour PowerShell: the uploader runs on the CA server (Tier 0),
where PowerShell is already present, so no runtime or package manager has to
be installed there. The existing monitor is a PowerShell script that uses
PSPKI.

## Decision

1. All project code is PowerShell: the uploader, CRL validation, and the
   monitoring and external checker. The earlier plan to port the monitor to
   Python is cancelled.
2. Code must run on **Windows PowerShell 5.1 and PowerShell 7**.
   `#Requires -Version 5.1`; no syntax that exists only in 7 (ternary, `??`,
   `&&`, `||`). PSScriptAnalyzer enforces this with `PSUseCompatibleSyntax`.
3. Structure: a module `CrlPublisher` (one function per file in `Public/` and
   `Private/`, explicit export list in the manifest) and a thin entry script
   `Publish-Crl.ps1` for the Scheduled Task.
4. Quality gates, run by `build/Invoke-Checks.ps1` and in CI: PSScriptAnalyzer
   (warnings fail the build) and Pester 5. Code uses `Set-StrictMode -Version
   Latest`, `$ErrorActionPreference = 'Stop'`, approved verbs, comment-based
   help, and `ShouldProcess` for state-changing functions.
5. Windows PowerShell 5.1 has no CRL parser, so the project contains a small
   DER reader built on System.Security.Cryptography. It is the riskiest piece
   of custom code and gets the strictest tests, including real AD CS CRLs.
6. S3 access uses the official AWS tooling, pinned to an exact version and
   vendored (delivered as a hash-verified artifact, never installed from the
   internet on the CA server). No hand-written request signing.
   Proposed, pending the checks in "Assumptions".
7. Script and module integrity: Authenticode signing, run under the
   execution policy the organisation requires.
8. Test data: static CRL and CA certificate fixtures generated once by a
   documented shell script using openssl, committed, with an expected-result
   manifest. Tests inject the clock, so fixtures never "expire". Real AD CS
   CRLs (public data, no secrets) are added when available.
9. CI: a GitLab pipeline runs the quality gates in a PowerShell container,
   if the organisation's runners allow it.

## Consequences

- **Verification gap.** The Python prototype was the only code executed and
  verified while building this project. The authoring environment has no
  PowerShell runtime (outbound access to its download source is blocked) and
  the owner has no test host. No PowerShell code is verified until it runs in
  CI or on a Windows machine, and no document may claim otherwise.
- Mitigations: pure functions with injected dependencies, golden fixtures, a
  read-only `-DryRun` mode, and a staged rollout (dry run on the real CA,
  then a test bucket, then production buckets).
- Supporting 5.1 limits the language features available.
- The Python prototype is archived outside the repository
  (`../crl-platform-python-prototype`) as a design reference. Its tests do not
  run against the PowerShell code.

## Assumptions to verify

1. Which PowerShell version and execution policy the CA servers use.
2. Whether the AWS module or SDK assemblies may be placed on a Tier 0 server,
   and how they are delivered.
3. The internal S3 works with the AWS SDK (custom endpoint, path-style
   addressing, certificate signed by the internal CA, which Windows already
   trusts).
4. GitLab runners can run a PowerShell container and reach a module source.
5. A Splunk Universal Forwarder (or other log agent) exists on the CA server.

## Evidence plan

First green run of `build/Invoke-Checks.ps1` (CI or Windows), then `-DryRun`
output from a real CA, then a test-bucket upload.
