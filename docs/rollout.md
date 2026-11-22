# Rollout guide, from zero to production (small steps)

> Superseded by `docs/system-dossier.md` chapter 11 (adds the Nginx/Helm phase, the public bucket with tenant,
> the monitor TLS bundle and rollback per step). Kept for history.

Each step says what to do and what you should see (✔). Stop at the first step that does not match and report
the output. Replace the example names: `DOMAIN`, `gmsa-crlpub`, `CA01`, `shay/eos`, bucket and host names.

Not in this guide (separate steps of the project): building the Nginx serving layer, and detecting changes to
code and configuration (docs/readiness-gaps.md, last section).

## Phase 1 — Uploader tests on your workstation (no S3)
1. Unzip the project, e.g. to `C:\work\crl-platform`.
2. `Get-Module -ListAvailable Pester` ✔ version 5.x (otherwise install it from the internal repository).
3. `Invoke-Pester -Path C:\work\crl-platform\tests\Publish-Crl.Tests.ps1 -Output Detailed` ✔ 18 passed, 0 failed.

## Phase 2 — Uploader against the test bucket (workstation, your own user)
4. Copy `src\Publish-Crl.ps1` over the old one in `D:\CrlPublisher`.
5. In `D:\CrlPublisher\config.json` add `"keyPrefix": "shay/eos"` (the URL directory clients request),
   `"stateFile": "D:\\CrlPublisher\\state\\published.json"`, `"s3Attempts": 3`. Remove `caCertFiles`.
6. In bucket `crl-test` delete what is left under `staging/` and `lkg/`.
7. `.\Publish-Crl.ps1 -ConfigPath D:\CrlPublisher\config.json -DryRun; $LASTEXITCODE` ✔ `result=dryrun`, exit 0.
8. Same without `-DryRun` ✔ `result=published`, exit 0; object at `shay/eos/<file>.crl` with metadata
   `run-id`, `crl-number-hex`, `sha256`, `source-host`.
9. Run again ✔ `result=unchanged`, exit 0; `D:\CrlPublisher\state\published.json` exists.
10. Overwrite the object in S3 with any other file, run ✔ `result=published`, the real CRL is back.
11. Put a text file `junk.crl` in the source folder, run ✔ `crl_rejected`, exit 4. Delete `junk.crl`.
12. Splunk `index=* sourcetype="crl:publisher"` ✔ `run_start`, `publish`, `run_end`.

## Phase 3 — Monitor in a test project on OpenShift
13. Build the image from `monitor/` (podman or GitLab CI), push it, note the digest.
14. `oc new-project crl-monitor-test`
15. `oc create secret generic crl-monitor-hec --from-literal=hec-token=<token>` and the TLS trust for Splunk:
    `oc create configmap crl-monitor-tls --from-file=ca-bundle.pem` (internal roots + intermediates, PEM).
    In `configmap.yaml` set `splunk.url` to the same HEC URL the uploader uses.
16. On the CA: `certutil -ca.cert ca.cer` then `certutil -encode ca.cer ca.pem`. Paste `ca.pem` into the
    `crl-monitor-ca` ConfigMap in `monitor/chart/crl-monitor/values.yaml` (key = CA name, e.g. `ca-shay.pem`).
    If the CA has older key generations still valid, paste their certificates into the same key.
17. In the same file: `targets` (the existing publish servers are fine for a test) and a short `crl-list.txt`
    with one or two real paths, e.g. `/shay/eos/shay.crl  ca-shay`.
18. Put the digest into `cronjob.yaml`; `oc apply -f configmap.yaml -f cronjob.yaml`.
19. `oc create job --from=cronjob/crl-monitor m1` then `oc logs job/m1`
    ✔ no `crl_monitor_finding`, last line `crl_monitor_run_completed` with `"status":"ok"`.
20. Add a path that does not exist to the list, apply, run two manual jobs
    ✔ first `http_unavailable` with `"pending":true`, then as `error`. Remove the line.
21. Splunk `index=* sourcetype="crl:monitor"` ✔ the same events.

## Phase 4 — Splunk alerts
22. Uploader: no `event=run_end` from a CA host for 75 minutes; any `run_end` with `exitCode` not 0;
    any `event=state_missing` (expected once, on the first run).
23. Monitor: no `event=crl_monitor_run_completed` per `site` for 15 minutes; any `crl_monitor_finding` with
    `severity=error`.

## Phase 5 — S3 for production (with the storage team)
24. One bucket per site (no replication). Enable **versioning**.
25. One access key per CA and per site: write and read only under that CA's prefix (e.g. `shay/eos/`), no
    delete, and if the product supports it, only from the CA's IP. Note what the product does not support.

## Phase 6 — The production CA
26. Service account (gMSA, recommended). The KDS root key must exist in the domain. As a domain admin:
    `New-ADServiceAccount -Name gmsa-crlpub -DNSHostName gmsa-crlpub.DOMAIN -PrincipalsAllowedToRetrieveManagedPassword CA01$`
27. On the CA: `Install-ADServiceAccount gmsa-crlpub` then `Test-ADServiceAccount gmsa-crlpub` ✔ `True`.
28. Give `DOMAIN\gmsa-crlpub$` the right "Log on as a batch job" (GPO or `secpol.msc`). Nothing else: not an admin.
29. Folders and permissions (as admin):
    ```
    mkdir D:\CrlPublisher\secrets, D:\CrlPublisher\logs, D:\CrlPublisher\state, D:\CrlPublish
    icacls D:\CrlPublisher /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "DOMAIN\gmsa-crlpub$:(OI)(CI)RX"
    icacls D:\CrlPublisher\secrets /grant "DOMAIN\gmsa-crlpub$:(OI)(CI)M"
    icacls D:\CrlPublisher\logs    /grant "DOMAIN\gmsa-crlpub$:(OI)(CI)M"
    icacls D:\CrlPublisher\state   /grant "DOMAIN\gmsa-crlpub$:(OI)(CI)M"
    icacls D:\CrlPublish /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)M" "DOMAIN\gmsa-crlpub$:(OI)(CI)R"
    ```
    (The CA service runs as SYSTEM, so only SYSTEM writes to `D:\CrlPublish`.)
30. Make the CA publish there too, base and delta. Either in the CA console (Extensions, CDP, Add
    `D:\CrlPublish\<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl`, tick "Publish CRLs to this location" and
    "Publish Delta CRLs to this location"), or:
    `certutil -setreg CA\CRLPublicationURLs "+65:D:\CrlPublish\%3%8%9.crl"`
    Then `net stop certsvc && net start certsvc` and `certutil -crl` ✔ the `.crl` files appear in `D:\CrlPublish`.
31. Auditing for the trigger: `auditpol /set /subcategory:"Certification Services" /success:enable` and
    `certutil -setreg CA\AuditFilter 127`, restart CertSvc, `certutil -crl` ✔ event 4872 in the Security log.
32. Modules for all users (from the internal repository) into `C:\Program Files\WindowsPowerShell\Modules`:
    PSPKI, AWS.Tools.Common, AWS.Tools.S3.
33. Copy into `D:\CrlPublisher`: `Publish-Crl.ps1`, `deploy\windows\Protect-Secrets.ps1`,
    `deploy\windows\Publish-Crl.task.xml`, and a `config.json` with `sourceDirectory = D:\CrlPublish`, the right
    `keyPrefix`, and **the test bucket** for both sites for now.

## Phase 7 — Secrets as the service account
34. As admin create `D:\CrlPublisher\secrets\input.json` with the test keys and the HEC token (format in the
    header of `Protect-Secrets.ps1`).
35. Run the helper once as the gMSA:
    ```
    $a = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -File D:\CrlPublisher\Protect-Secrets.ps1'
    $p = New-ScheduledTaskPrincipal -UserId 'DOMAIN\gmsa-crlpub$' -LogonType Password
    Register-ScheduledTask -TaskName CrlSecrets -Action $a -Principal $p
    Start-ScheduledTask CrlSecrets
    ```
36. ✔ `D:\CrlPublisher\secrets\protect-secrets.log` says `OK as DOMAIN\gmsa-crlpub$`, the `.cred` files and
    `hec.token` exist, `input.json` is gone. Then `Unregister-ScheduledTask CrlSecrets -Confirm:$false`.

## Phase 8 — The uploader task, still on the test bucket
37. In `Publish-Crl.task.xml` replace the account and paths. Then
    `Register-ScheduledTask -TaskName Publish-Crl -Xml (Get-Content -Raw D:\CrlPublisher\Publish-Crl.task.xml) -User 'DOMAIN\gmsa-crlpub$'`
38. `Start-ScheduledTask Publish-Crl`, wait a minute, `Get-ScheduledTaskInfo Publish-Crl`
    ✔ `LastTaskResult` 0; `D:\CrlPublisher\logs` shows `published`; objects in the test bucket.
39. Trigger test: `certutil -crl` ✔ within about a minute a new run in the log (started by event 4872).

## Phase 9 — Switch to production buckets
40. Repeat steps 34-36 with the production keys of both sites.
41. In `config.json` set the production endpoint and bucket of each site.
42. `Start-ScheduledTask Publish-Crl` ✔ exit 0, `published` for both sites; second run `unchanged`.
43. Monitor in the **other** site's cluster: as in phase 3, with the full CRL list, `networkpolicy.yaml` with
    the real IPs, and the production Splunk index ✔ `status: ok`.
44. Keep the old CheckCRLExpiration script running until the new monitor has been quiet and correct for a while.
