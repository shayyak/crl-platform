# ADR-0005: The uploader discovers CRLs and CA certificates from the CA directory

- Status: proposed (agreed in principle by the project owner; evidence pending)
- Date: 2026-10-11
- Builds on: ADR-0003, ADR-0004

## Context

The uploader runs on the CA server, and the platform will run in many
environments with different CRL sets (some have delta CRLs, some do not; some
have CA certificates from several key generations). Asking operators to list
CRL files and trusted CA certificates per environment is error prone and goes
stale after a CA renewal.

## Decision

The uploader scans the CA's output directory (default `CertEnroll`, path
configurable):

- every `*.crl` file is a CRL to publish; base or delta is read from the file
  content, not from its name;
- every CA certificate (`*.crt`, any key generation) forms the trusted list
  passed to the validator;
- files that cannot be used are logged as problems and never abort the run;
- configuration only says where to publish, not what to publish.

The S3 object key is the file name; mapping of special characters (`+`,
parentheses) is decided with the serving layer.

## Consequences

- No per-environment CRL or CA lists to maintain; a renewed CA is picked up
  automatically.
- Whoever can write to the CA output directory can influence what is trusted
  by the uploader. This is accepted: that person already controls the CA.
- A stale CRL of an expired CA generation must not cause permanent failures:
  the uploader skips and logs it (to be implemented in step 3).

## Assumptions to verify on a real CA

1. CRLs and CA certificates are written to `CertEnroll` (confirmed by the
   owner as the default for these environments).
2. The CA keeps refreshing CRLs for old key generations while their
   certificates are valid.
3. File naming for delta CRLs and key generations matches the patterns above.
4. `+` and parentheses in the request path work through the serving layer
   (step 5) and real Windows clients (step 10).

## Evidence plan

Run discovery against a copy of a real `CertEnroll` directory; check the
file list and the problem list by eye; run the validator on the real CRLs.
