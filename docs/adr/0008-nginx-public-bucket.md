# ADR-0008: Serving layer — Nginx caching proxy in front of a public-read bucket

Date: 2026-10-22. Status: accepted (owner).

## Context
Clients fetch CRLs over HTTP from `publish1.com` / `publish2.com`. The internal S3 has no anonymous-by-IP
access, only "public". Two patterns exist in industry:
1. Public-read bucket (AWS Private CA default `S3ObjectAcl=PUBLIC_READ`), clients or a CDN read it directly.
2. Locked bucket (Block Public Access) with one authorised reader in front (AWS: CloudFront + OAC;
   Microsoft AD CS: static files on web servers).

## Decision
Pattern 1. One bucket per site, **dedicated to CRLs only**, public **read** (GetObject; no List if the product
allows). Writes only with the uploader's key. Nginx on OpenShift in front of each site's S3:
- HTTP only (no HTTPS, avoids the revocation loop); only GET/HEAD of `*.crl`, everything else 404.
- Cache: `proxy_cache_valid 200 1m` + revalidate (ETag/If-Modified-Since), background update, cache lock.
- Serve stale on error/timeout/5xx/403 (up to 7 days), header `X-Cache-Status` (monitor check `stale_cache`).
- 404 cached 10 s. Clients get `Cache-Control: max-age=60`.
- `+` in delta CRL names sent to S3 as `%2B` (to verify against the internal S3).
- 2+ replicas on different nodes, PodDisruptionBudget, readiness probe.

## Anonymous URL format (verified 2026-10-22)
The internal S3 is multi-tenant: anonymous requests must name the tenant, path-style
`https://<endpoint>/<tenant>:<bucket>/<key>` (signed requests infer it from the key). Nginx uses this form.

## Why
A CRL is public by definition and signed; reading it is not a risk. No key in Nginx, fewer moving parts.
Lessons from the S3 outage of 2017 (cache in front, second region) are covered by the Nginx cache and the two
independent sites.

## Fallback
If security forbids a public bucket: locked bucket, an `rclone` sidecar per Nginx pod syncs CRLs to local
disk with a read-only key, Nginx serves static files (needs its own freshness monitoring).
