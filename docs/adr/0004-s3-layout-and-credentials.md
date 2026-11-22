# ADR-0004: S3 layout and credentials

- Status: proposed (agreed in principle by the project owner; evidence pending)
- Date: 2026-10-11
- Builds on: ADR-0002, ADR-0003

## Context

Facts reported by the project owner about the internal S3 service:

- Authentication is by access key and secret key.
- The HTTPS certificate is issued by the organisation's internal CA.
- Permissions can be restricted per bucket only, not per prefix.
- A read-only user cannot be created.
- The CA server can reach the S3 service at both sites.
- Each site has its own S3 service; there is no replication between them.
- The platform will run in many environments.

## Decision

1. **Bucket per environment and per CA, at each site.** Because the bucket is
   the only permission boundary, it is the unit of blast-radius control: a
   leaked key can affect only that environment's CRLs.
2. **Fixed object keys inside the bucket**, no per-file or per-component
   buckets:
   - live key per CRL (what serving reads)
   - `lkg/` last-known-good copy
   - `staging/` candidate written and verified before it replaces the live key
   The serving layer requests only its configured live keys.
   Naming of Delta CRL keys (they contain `+`) is decided in step 2.
3. **Credentials.** Where the service allows, use separate key pairs for the
   uploader and for the serving layer (for audit and independent rotation),
   even though both can write. Secrets are never stored in plain text: on the
   CA server they are protected by Windows (for example Credential Manager
   under a gMSA); in OpenShift they are Secrets. A rotation procedure is
   required because the keys are static and long lived.
4. **TLS.** The internal CA certificate is loaded explicitly; certificate
   verification is never disabled.

## Accepted risk

Any holder of a valid key can modify the bucket. The most damaging case is not
a forged CRL (clients verify the CA signature) but a **replay of an older,
validly signed CRL**, which would hide a recent revocation until the old CRL's
`NextUpdate`.

Mitigations (none requires a read-only user):

- The external checker verifies at every endpoint that the CRL Number never
  decreases and equals the CRL Number at the CA; a rollback raises an alert
  within minutes.
- Per-environment buckets limit the blast radius.
- Protected secret storage and planned rotation.

## Assumptions to verify

1. More than one key pair per bucket can be issued.
2. Whether anonymous read from the internal network is allowed. If it is, the
   serving layer needs no secret at all.
3. Object overwrite is atomic for readers (a reader never sees a partial
   object) on this S3 implementation.

## Evidence plan

Overwrite and partial-read test against the real service (step 3); rollback
detection test in the checker (step 9).
