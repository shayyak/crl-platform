# Serving layer — Nginx in front of S3

Decision and reasoning: `docs/adr/0008-nginx-public-bucket.md`. Full explanation of every setting:
`docs/system-dossier.md`. One Helm release per site, in that site's cluster.

## Files
- `chart/crl-nginx/files/nginx.conf` — the whole behaviour. Host, tenant and bucket are placeholders filled by Helm.
- `chart/crl-nginx/values.yaml` — every setting with its default; `values-sou.example.yaml` — a site file.
- `chart/crl-nginx/templates/` — ConfigMaps (nginx.conf, S3 CA bundle), Deployment (3 replicas, graceful stop,
  probes, resources), PodDisruptionBudget, Service, Route (HTTP). No NetworkPolicy (public content; add one that allows the router if
  the namespace has default-deny).
- Checks: the chart is linted and rendered per site in CI (`.gitlab-ci.yml`, job `charts-lint`); `nginx -t` on the rendered config is still to be run on the cluster (see `docs/next-session.md`).

## What it guarantees
| Situation | Clients get |
|---|---|
| Normal | the CRL, at most 1 minute old (cached, revalidated against S3 in the background) |
| New CRL uploaded | the new CRL within about 1 minute |
| S3 down / 5xx / 403 / 404 / timeout / TLS failure | the last copy, header `X-Cache-Status: STALE` (monitor alerts) |
| S3 down and this pod never had the file (e.g. just restarted) | error; the other replicas and the other site still serve |
| Rolling update, node drain | no errors: new pod ready before an old one stops; graceful stop finishes requests |
| Anything but GET/HEAD of `*.crl` | 404 / 405 |

Known limits: the cache is per pod and is lost on restart. The S3 host name is resolved when nginx starts; if its
IP changes, `oc rollout restart deploy/crl-nginx`. Nginx does not fetch missing intermediates (AIA): `ca.pem`
must hold the whole chain.

## Deploy (production: sou = production, cen = DR)
Deployed by Argo CD only (argocd/apps/crl-platform-appset.yaml): one Application per site (`crl-nginx-<site>`), Helm
release `crl-nginx`, sync is MANUAL (press Sync on the Application). Layout in Git:
- `sites/<site>/site.yaml`: site, cluster (name in Argo CD), namespace. Read by Argo CD only.
- `sites/<site>/values.yaml`: S3 host, tenant, bucket, route host. Read by Helm.
- `chart/crl-nginx/files/ca-bundle.pem`: the organisation's CA bundle (PEM, created inside the network). It must
  contain the S3 TLS chain of **both** sites (roots and intermediates). Check what S3 sends:
  `openssl s_client -connect <host>:443 -servername <host> -showcerts </dev/null`.

Check after a sync:
1. `oc get pods -l app=crl-nginx -o wide` ✔ 3 Running, READY 1/1, on different nodes.
2. `curl -sI http://<route host>/<keyPrefix>/<name>.crl` ✔ `200`, `X-Cache-Status: MISS`; again ✔ `HIT`.
3. `oc logs deploy/crl-nginx` ✔ JSON access lines with `"status":200` and `"s3Status":"200"`.

By hand, without Argo (lab only): `helm upgrade --install crl-nginx chart/crl-nginx -f sites/sou/values.yaml`.
Any change of a value or of the CA bundle rolls the pods (checksum annotations).
