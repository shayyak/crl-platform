# Uploader (Publish-Crl.ps1) — install, operate, troubleshoot

Version 2.2.1. Every error event carries the full exception chain (outer --> inner) and the server's reply
(e.g. Splunk's reason for a 400). Design: `docs/design-uploader-and-monitor.md` section 2.
Status: Pester suite (32 tests) and an end-to-end run with stub modules pass on PowerShell 7 (author, 2026-10-21);
still to run on Windows PowerShell 5.1 with the real PSPKI and AWS.Tools.S3.

S3 permissions needed per site: **GetObject and PutObject** on the CA's prefix. No ListBucket, no Delete.
Secrets: DPAPI files only (`credentialFile` per site, `hec.tokenFile`), created as the account that runs the script.
Splunk index: leave `hec.index` out; events go to the token's default index. Set it only when the token is
allowed several indexes. A wrong index can be dropped silently when HEC runs on a forwarder (seen 2026-10-21).
Retries: only network errors, timeouts, 408, 429 and 5xx. A 403/404/400 fails at once with the reason.

## What it does
Triggered when the CA publishes a CRL (event 4872) and hourly. Reads every `*.crl` in the publish folder,
skips files that do not parse or have no CRL number, refuses anything older than what it published before
(local state file), and makes the live object at both sites byte-identical to the source, which also repairs
missing, junk, old or forged objects. Each object carries metadata `x-amz-meta-run-id`, `-crl-number-hex`,
`-sha256`, `-source-host`, `-uploader-version`. Dates, signatures and what clients receive are checked by the
monitor.

## Install on a CA (once)
1. Folder `D:\CrlPublisher` with `Publish-Crl.ps1` (signed), `config.json`, and subfolders `secrets`, `logs`,
   `state`. ACL: Administrators full control; service account Read & Execute on the folder, Modify on
   `secrets`, `logs`, `state` only. Enable S3 versioning on the buckets: it is the rollback for bad objects.
2. Publish folder (e.g. `D:\CrlPublish`): add it to the CA's CDP as "Publish CRLs to this location" (and
   "Publish Delta CRLs"). ACL: the CA (Local System) Modify; service account Read; nobody else writes.
3. Modules: PSPKI and AWS.Tools.S3 installed for all users (from the internal repository).
4. Auditing (for the event trigger): `auditpol /set /subcategory:"Certification Services" /success:enable`
   and `certutil -setreg CA\AuditFilter 127` (or at least the "revoke certificates and publish CRLs" bit),
   then restart CertSvc.
5. Secrets, **created while running as the service account** (DPAPI is per account):
   - `Protect-Secrets.ps1` (see uploader/install) writes the DPAPI files from input.json; the S3 keys go in `sites.<site>.credentialFile`.
   - `Read-Host -AsSecureString | ConvertFrom-SecureString | Set-Content D:\CrlPublisher\secrets\hec.token`
     (the token only, without the word "Splunk").
6. `config.json` from `src/config.example.json`; set `keyPrefix` to the URL directory clients use, e.g.
   `shay/eos` for `http://publish1.com/shay/eos/shay.crl`. Verify against the CA:
   `certutil -getreg CA\CRLPublicationURLs`.
8. Dry run: `-DryRun` -> `publish` events with `result=dryrun` or `unchanged`, exit 0 (this also proves
   modules, credentials and S3 access).
9. Scheduled Task: import `uploader/install/Publish-Crl.task.xml` (replace account and paths).
10. Splunk: alert when `sourcetype=crl:publisher event=run_end` is missing for more than 75 minutes per host,
    on `exitCode!=0`, and on `event=state_missing`.

## Exit codes
| Code | Meaning |
|---|---|
| 0 | all good |
| 1 | configuration or startup error, or an unreadable state file (`fatal`) |
| 2 | some uploads failed, others succeeded |
| 3 | all uploads failed |
| 4 | a CRL was rejected (others may still have been published) |

## Events and what to do
| Event (level) | Meaning | First action |
|---|---|---|
| `crl_rejected` (error) | a file in the publish folder does not parse or has no CRL number | if the CA was writing it, the next run fixes it; otherwise inspect the file |
| `no_valid_crl_in_directory` (error) | nothing to publish | check the CDP publish location and the folder ACL |
| `crl_older_than_published` (error) | source number below what was already published | CA restored from backup? Decide deliberately; to accept the older CRL remove its key from `state\published.json` |
| `fatal` (error) | config, module, folder or state-file problem | read `error`; a corrupt state file must be restored or deleted by hand |
| `site_unavailable` (error) | credentials for a site missing | check the `.cred` file / service account |
| `publish` with `result=failed` (error) | read or upload failed | see `error` (403 = key or permission, 0/connection = network/TLS) |
| `publish` field `live` | what was in S3 before: `identical`, `different`, `missing`, `denied` (could not read, uploaded anyway) | `denied` on every run: give the key GetObject |
| `state_missing` (warn) | the state file does not exist; rollback protection starts from zero | expected on the very first run only. Otherwise find out why it is gone (restore? cleanup?) and check that the published CRL numbers are the latest |
| `retry` (warn) | transient network/S3/Splunk error, retried | only a concern if frequent |
| `hec_failed` (error, local log only) | events did not reach Splunk | see `error` and `httpStatus`: 0 = network/TLS, 400 = index/format, 401/403 = token |

## Emergency revocation
Revoke, then `certutil -crl`. The event trigger runs the uploader within ~30 s; the monitor confirms both
sites serve the new number. Relying servers keep their cached CRL until it expires; purge on critical servers
with `certutil -urlcache crl delete` only after the monitor confirms the new CRL is served.

A manual run from a console while the task runs is not blocked; start manual runs through the task
(`schtasks /run /tn Publish-Crl`), whose "do not start a new instance" setting prevents overlap.
