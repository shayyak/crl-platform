# crl-monitor

One file, `crl_monitor.py`. Every 5 minutes (OpenShift CronJob, in the cluster of the other site) it checks
every CRL in the list on every publish endpoint and reports to Splunk HEC. Design:
`docs/design-uploader-and-monitor.md` section 4; decision: `docs/adr/0007-python-monitor-on-openshift.md`.

## What it checks
Per CRL and endpoint: HTTP 200 · a real CRL (an empty body fails too) · signed by the CA named in the list
(certificates pinned in a ConfigMap, never taken from the publish) · not expired · ThisUpdate not in the
future · not close to expiry (17 h, 168 h for paths containing `root`) · CRL number never lower than before on
that endpoint · not served from a stale cache (`X-Cache-Status: STALE`).
Across endpoints: the same CRL number (warning after 30 minutes).
The list itself: unreadable or empty is an error; added / removed lines are reported.

A non-urgent error is reported as a pending warning first and becomes an error on the second run in a row.
A bad signature and a decreasing number are errors immediately.

## Develop and test
```
cd monitor
python -m venv .venv && . .venv/bin/activate
pip install --require-hashes -r requirements.txt
pip install ruff
ruff check monitor
```
Tests build their own PKI in memory (nothing expires) and also verify the real openssl-generated CRLs in
`../tests/fixtures`. Regenerate `requirements.txt` with `pip-compile --generate-hashes --strip-extras pyproject.toml`.

Run once by hand: `python crl_monitor.py --config config.yaml`

## Inputs
- `config.yaml` and `crl-list.txt`: ConfigMap `crl-monitor-config` (rendered from `monitor/chart/crl-monitor/templates/configmap.yaml`, values in `values.yaml`).
- CA certificates: ConfigMap `crl-monitor-ca`, one key `<ca-name>.pem` per CA holding every key generation.
- HEC token: Secret `crl-monitor-hec` (file) or `SPLUNK_HEC_TOKEN`.
- TLS trust for Splunk: ConfigMap `crl-monitor-tls`, key `ca-bundle.pem` (internal roots + intermediates);
  `splunk.verifyTls` points to it. Python does not use the OS trust store.
- State: PVC `crl-monitor-state` (high-water marks per endpoint and path, list snapshot, failure streaks).

List format, one CRL per line: `<full path from the server root> <CA name>`; `#` starts a comment.

## Exit codes
0 run completed (findings are in the events) · 1 configuration error · 3 run completed but Splunk delivery failed.

## Events and runbook
Every finding: `event=crl_monitor_finding` with `check`, `severity`, `target`, `path`, `httpStatus`, `crlNumber`,
`uploader` (object metadata, when present), `consecutive`, `pending`. Every run ends with
`event=crl_monitor_run_completed` (`status`, counts); Splunk alerts when it stops arriving.

| check | severity | Meaning | First action |
|---|---|---|---|
| `http_unavailable` | error (after 2 runs) | no 200 from this endpoint | is the Nginx route/pod up? is the object in S3 at the right key? |
| `stale_cache` | error (after 2 runs) | Nginx serves an old copy because it cannot read S3 | S3 read permission / network from Nginx to S3 |
| `not_a_crl` | error (after 2 runs) | junk or empty body served | check the S3 object; the uploader repairs it on its next run |
| `signature_invalid` | error, immediate | not signed by the CA named in the list | possible forgery or wrong file on that path: inspect `uploader` metadata and S3 versions |
| `crl_number_decreased` | error, immediate | an older CRL than before on this endpoint | replay or restore: check S3 versions; the uploader repairs within an hour |
| `expired` / `not_yet_valid` | error (after 2 runs) | outside its validity | CA publication; CA clock |
| `expires_soon` | warning | under 17 h (168 h for `root` paths) | CA publication schedule; for the root, plan the offline CRL signing |
| `sites_diverged` | warning | endpoints serve different numbers for > 30 min | one site did not get the latest CRL. The only check that catches this for CRLs published by the old path (no uploader to report a failure) and after an emergency revocation, when the old CRL is still far from expiry |
| `list_invalid` / `ca_certs_invalid` | error, immediate | ConfigMap content is wrong | fix the ConfigMap; nothing is checked until then |
| `list_entry_added` / `list_entry_removed` | info / warning | the list changed | confirm the change was intended |
| `state_corrupt` | warning | state file unreadable, started fresh | none |
