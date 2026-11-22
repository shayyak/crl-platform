# CRL distribution platform: summary

**What it does.** Distributes certificate revocation lists (CRLs) and CA certificates (AIA) from Active Directory Certificate
Services CAs to two sites (production and DR) through S3-compatible storage and an Nginx caching layer on OpenShift,
with an independent monitor that checks what clients actually see.

**My part (design, code, deployment):**
- **Publisher (PowerShell 7, Windows CA):** reads CRLs and CA certificates from the CA's folders, parses them with
  .NET X.509, uploads only what changed (byte comparison with the live object), refuses CRL rollback through a local
  state file, writes structured logs to Splunk HEC, and uses exit codes for scheduled-task monitoring.
- **Serving (Nginx on OpenShift, Helm):** a public, read-only cache with strict path validation, stale-on-error
  behaviour, graceful shutdown, and a configuration checksum that rolls the pods when the configuration changes.
- **Fetch (Kubernetes CronJob, Helm):** copies CRLs of other publishers into a site bucket, with a per-site
  configuration and TLS trust settings.
- **Monitor (Python, Helm CronJob):** checks presence, HTTP status, CRL structure, signature against the pinned CA,
  validity, CRL number monotonicity, and consistency between sites.
- **GitOps:** Argo CD ApplicationSet that creates one application per component per site from folders in Git;
  manual sync; deletion behaviour verified against the Argo documentation.
- **CI (GitLab):** PowerShell and Python lint, Helm lint and render per site, schema validation of rendered output,
  container image build on the default branch.
- **Documentation:** a system dossier with the decision log (each decision with its reason), storage map, runbooks
  (including CA key renewal), and a rebuild guide.

**Technologies:** PowerShell, Python, Helm, Kubernetes and OpenShift, Argo CD, Nginx, S3 (Ceph-style), Splunk HEC,
GitLab CI, Kaniko, kubeconform, ruff, PSScriptAnalyzer.

**Status:** code and configuration complete. Not yet verified in a live environment: run on a CA, cluster
deployment, monitor operation, CI pipeline and Splunk failure drills. These are listed in `docs/next-session.md`.
