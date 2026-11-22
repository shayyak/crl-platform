# crl-platform

**Start here: `docs/system-dossier.md`** (system dossier, Hebrew): every setting, where it is stored, why it was chosen,
what it protects against, the full rebuild guide and the runbooks.

Platform for distributing AD CS certificate revocation lists (CRLs) and CA certificates (AIA) to two sites through
S3-compatible storage, an Nginx serving layer on OpenShift, and an independent monitor.

## Components

| Path | What | How it reaches production |
|---|---|---|
| `uploader/` | PowerShell publisher on each CA server (`src/Publish-Crl.ps1`, v2.4.0): uploads CRLs and CA certificates to S3, rollback protection, Splunk HEC logs | Scheduled task on the CA (`install/Publish-Crl.task.xml`) |
| `serving/` | Nginx caching proxy in front of one site's S3 (Helm chart `crl-nginx`) | Argo CD ApplicationSet, manual sync |
| `fetch/` | CronJob that copies CRLs of other publishers into the site bucket (Helm chart `crl-fetch`) | Argo CD ApplicationSet, manual sync |
| `monitor/` | Python checker: presence, signature, validity, number, cross-site consistency (Helm chart `crl-monitor`) | Argo CD ApplicationSet, manual sync |
| `argocd/` | ApplicationSet (one Application per component per site) and the app-of-apps root | Applied once to the Argo namespace |
| `docs/` | Dossier (the reference), decision log, next-session notes | — |

Sites: `sou` = production, `cen` = DR. Adding a site or a component: see the header of
`argocd/apps/crl-platform-appset.yaml`.

## Quality gates

`.gitlab-ci.yml` runs on every push and merge request:

- **lint:** PSScriptAnalyzer and a PowerShell parse check (uploader); ruff (monitor).
- **validate:** `helm lint` and `helm template` for each chart and each site; kubeconform on the rendered output.
- **build:** the monitor image (Kaniko), default branch only.

Deployment is not in CI: Argo CD deploys the charts from Git after a manual sync.

## Status

Code and configuration are complete for all components. Not yet run against a real environment: the uploader on a CA,
the Nginx chart on the cluster, the monitor and the CI pipeline. See `docs/next-session.md` for the verification list.
