# newpublish: one-page cheat sheet

## Five rules

1. **A signed CRL is valid until NextUpdate.** An old copy that is still valid is better than an error. A broken CRL is
   rejected by the client, so availability suffers, not trust.
2. **The CA is the source of truth.** Every other copy is a copy. The uploader compares bytes and repairs S3 on every run.
3. **Two independent sites.** No replication. Two CDP URLs; the client moves between them by itself.
4. **Each component checks only itself.** Probes do not check S3. The monitor checks the chain from outside, from the other site.
5. **Silence is not health.** Splunk alerts when `run_end` / `crl_monitor_run_completed` does not arrive.

## The path of a CRL

`certutil -crl` -> event 4872 -> +30 s uploader -> S3 (both sites) -> Nginx (up to 1 minute) -> client (when its copy expires)

## Numbers to remember

| | |
|---|---|
| Cache freshness | 1 minute; STALE when S3 does not answer |
| Alert before expiry | 17 hours (Root: 1 week) |
| Uploader | on event + every hour; alert if no `run_end` for 75 minutes |
| Monitor | every 5 minutes; error after 2 runs (signature or number decrease: immediately) |
| Nginx | 3 pods, readiness 10 s, liveness 30 s, preStop 10 s |

## During an incident, in this order

1. `curl -sI http://publish1.com/<path>.crl` and read `X-Cache-Status`: HIT is normal, MISS came from S3, **STALE means S3 is unreachable**.
2. `oc get pods -l app=crl-nginx`: READY 1/1 on all 3? How many restarts?
3. `oc logs deploy/crl-nginx`: `status` is what the client got, `s3Status` is what S3 returned.
4. Uploader: the local log, lines that are not `info`: look at `error` and `httpStatus`.
5. Splunk: `index=* sourcetype="crl:publisher"` or `"crl:monitor"`; one run: `index=* "<runId>"`.
6. The runbook for the event: system dossier, chapter 12.

| You see | Probable cause |
|---|---|
| STALE or 502 | S3 is down, the bucket is not public, or the CA bundle (`files/ca-bundle.pem`) lacks an intermediate |
| 404 and the file is in S3 | tenant, bucket or `keyPrefix` does not match the URL |
| exit 3 or `failed` with 403 | S3 key problem |
| `hec_failed` with 0, 400 or 401 | TLS on the network path, index format, or the token |
| `crl_older_than_published` | CA restore: a manual decision |
| `signature_invalid` | **suspected forgery**, or a new key generation that was not added to the monitor |

## Never

Disable certificate checks. Probe S3 from the probes. Delete the whole state file. Run the uploader by hand in
parallel with the scheduled task. Put a file that is not a CRL in the bucket (it is public).
