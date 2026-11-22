# Next session checklist

Raise these first when the owner returns:

## 2026-10-27: test deployed the production way (owner decision)
Central Argo CD manages both sites. Built argocd/root.yaml (app of apps, the only manual object), argocd/apps/project.yaml
(AppProject crl: our repo, our namespaces, only the kinds the chart creates), argocd/apps/crl-platform-appset.yaml
(ApplicationSet, git files generator serving/sites/*/site.yaml, preserveResourcesOnDeletion, automated prune+selfHeal),
serving/sites/sou/site.yaml. All schema-valid; the generated Application simulated and valid. Placeholders:
ARGO_NAMESPACE, REPO_URL, SOU_CLUSTER. AppProject NOT used (owner has no permission; only the owner's team uses this Argo instance): project default;
file kept in argocd/optional/appproject.yaml. To verify: the owner can create the root Application, and the root may
create the ApplicationSet.

## WHERE WE STOPPED (2026-10-25, 19:20) - resume exactly here
GitLab project crl-platform (Web IDE, no git CLI): serving/chart/crl-nginx (8 files) uploaded; serving/sites/sou/values.yaml
done by the owner. The owner has NOT yet applied the CA-bundle change. Next, in order:
1. Web IDE: _helpers.tpl (new crl-nginx.caBundle), configmaps.yaml and deployment.yaml (one line each), new
   files/ca-bundle.pem (the organisation's PEM bundle, created inside the network); delete sites/sou/ca.pem if created.
2. Argo CD Application (openshift-gitops): path serving/chart/crl-nginx, valueFiles ../../sites/sou/values.yaml,
   destination namespace crl-serving-test; repo credentials to GitLab; namespace managed-by label if needed.
3. Sync; check 3 pods Ready on different nodes; curl MISS then HIT; delta (+) file; logs; rollout restart without errors.
Then: monitor, Splunk alerts (incl. pod health from events), 13 drills (DONE gate), production.


## MASTER OPEN LIST (2026-10-25) — nothing may be dropped; the project is not done until every line is closed or accepted

Decide now
- [x] D-PVC: decided 2026-10-25 — keep emptyDir (PVC hurts availability when a node dies; clients fail over between the two sites).
- [x] Q32: monitor NetworkPolicy kept (pod holds the HEC token; owner had no preference, author's recommendation).
- [x] Q33: YAML explanation added (dossier appendix A).
- [x] Q34: docs/cheat-sheet.md.
- [ ] Q35: PriorityClass (optional, depends on cluster policy).
Deferred by the owner
- [ ] Change detection for code/config (after rollout).
- [ ] Monitor not_yet_valid: keep/remove.  - [ ] Monitor list-change events: keep/remove.
- [ ] How the CRL list reaches the ConfigMap.  - [ ] Monitor check 12 (phase 2).  - [ ] Prometheus (future).
Security / hygiene (before production)
- [ ] Rotate the exposed HEC token (also hard-coded in CheckCRLExpiration).
- [ ] Remove owner's test secrets and env vars from the CA server.
- [x] Code signing: DROPPED 2026-11-02 (Bypass + folder ACLs).  - [ ] gMSA, ACLs, CDP D:\CrlPublish, audit 4872.
- [ ] Threat model + public bucket approved by security.  - [ ] AWS.Tools approval on the production CA.
Not verified in reality
- [ ] Uploader on PS 5.1 + PSScriptAnalyzer.  - [ ] real helm lint.  - [ ] "+" and "(1)" names vs real S3.
- [ ] Discovery on a real CertEnroll folder.  - [ ] Windows CDP failover on a BROKEN CRL (D13).
- [ ] Router stops sending within 10 s (preStop sleep).  - [ ] Splunk TLS cert has AKI (Python 3.13).
- [ ] Propagation time measured.  - [ ] Targets confirmed (99.99%, 5 min, 16-17 h).
Work not reached yet
- [ ] Nginx in a test project.  - [ ] Monitor image, deploy, ConfigMaps.
- [ ] REMIND OWNER (11-11): monitor crl-fetch too, so the owner knows if it stopped sending.
- [ ] Splunk alerts: uploader, monitor, pod health from events (MON-1).  - [ ] 13 failure drills (DONE gate).
- [ ] Production S3 (per-prefix keys, IP, versioning).  - [ ] Nginx logs to Splunk (MON-4).
- [ ] Image mirror + digest pinning.  - [ ] CI job for serving tests.  - [ ] DNS monitoring (MON-3).
- [ ] Propagation measurement (MON-5).
Transfer to the owner's network (pending)
- [ ] 3 files blocked by the inspection: tests/fixtures/crl/base-10-pem.crl and tests/fixtures/ca/issuing-gen2.crt (PEM
      text; needed only by monitor tests) and uploader/install/Publish-Crl.task.xml (needed at production step 10).
      Sent as base64 in crl-platform-3files.zip; owner postponed. Note: PEM files are blocked - create ca.pem inside the network.
- [ ] Owner workstation: full project restored in C:\work\crl-platform (78 files) - confirm.
- [ ] CI (.gitlab-ci.yml): not uploaded to GitLab for now (owner, 2026-10-25). Needs a runner, the images (mirror)
      and an internal PowerShell module repository; then enable. Also add the serving tests job.
- [ ] GitLab: only what Argo needs is uploaded first; upload the rest of the project later.
- [ ] OLD PATH: where do CAs without the uploader publish today? When publish1/2 point to Nginx, every CRL must be in
      the site bucket with the same paths, or it stops being served. Answer before the production switch.
- [ ] Several CAs share a folder (e.g. iii/bbb/sha.crl + gaa.crl): verify unique file names; S3 key isolation by
      file-name prefix (iii/bbb/sha*) if the product supports it.
- [ ] Right-size Nginx disk: measure total/largest CRL size, then shrink cache max_size, emptyDir sizes and
      ephemeral-storage (today 1Gi/2Gi per pod, quota 4Gi/8Gi - generous). Owner postponed 2026-10-26.
- [ ] Monitor CronJob: add ephemeral-storage requests/limits (quotas that require it reject pods without it).
Most important open question
- [ ] CA DR (Q15/Q16): CRL number after failover; uploader on the DR CA and single-runner guarantee. Before production.
Accepted risks (know them)
- Six residual risks; both write keys on the CA; revocation reaches clients only when their cached CRL expires (OCSP
  = separate project); most CAs still on the old path.


## Where we stopped (2026-10-20, 18:00)

- Owner has the zip in the internal network; uploader v2.1.0 verified identical (whitespace-insensitive hash
  `83B3CB7A...5B08BE`). 2026-10-21: v2.1.1 logs the full inner-exception chain on every error (owner asked why
  the script did not say why it failed); whitespace-insensitive hash `12153713...7A720CC`.
- Workstation: script replaced, `config.json` updated (keyPrefix, stateFile, s3Attempts), `crl-test` bucket
  cleaned (no staging/ lkg/). Pester 5 not installed (only 3.4) — automated tests postponed.
- **CA server, dry run:** folder `C:\CrlPublisher` (logs, state, secrets), script copied (hash matches),
  `config.json` with `sourceDirectory = C:\Windows\System32\CertSrv\CertEnroll`, site name `sou`
  (bucket `crl-test`), secrets as the owner's own DPAPI files `secrets\sou.cred` and `secrets\hec.token`.
- **Open error:** `-DryRun` on the CA server failed with "An error occurred while sending the request"
  (network/TLS/proxy). Next: read the log tail to see whether S3 or Splunk failed, then
  `Test-NetConnection <s3> -Port 443`, `Test-NetConnection <splunk> -Port 8088`, an `Invoke-WebRequest` TLS check
  with inner exceptions, and `netsh winhttp show proxy`.
- 2026-10-21: TLS to S3 fixed on the CA server (missing CA certificate). Dry run still exit 3 and HEC failing.
  Uploader v2.2.0: existence check without ListBucket (GetObject + 404/403), retries only transient errors,
  Splunk's reply text in errors, `hec_failed` in the local log, DPAPI files only (env vars removed), readability.
  Whitespace-insensitive hash: see the delivery message. The Pester suite was fixed (root-level BeforeEach is
  not allowed in Pester 5) and now runs: 32 passed on PowerShell 7 (Pester 5.6.1 built from source).
- 2026-10-21: two external reviews read. v2.2.1 adds `state_missing` (warn): losing the state file plus an old
  CRL in the source (CA restore) would otherwise silently reset rollback protection. Not done, by decision:
  signature check in the uploader, read-back after PUT, state max-merge for concurrent manual runs (Task
  prevents overlap). DryRun does not prove PutObject: the real run on the test bucket does.
- 2026-10-21 (CA server, v2.2.1, bucket crl-test): HEC URL fixed in config (the TLS error was the HEC
  endpoint); dry run OK; real run `published`; second run `unchanged`; repair test (object overwritten in S3)
  `published live=different`; junk test `crl_rejected` + `unchanged`. `hec.index: pki` did not exist and events were dropped silently (HEC on a forwarder);
  `index` removed from the config; events arrive in the token's default index (verified). Uploader phase 2
  done. Next: phase 3 (monitor) or Nginx.
- Cleanup later: the owner's own secrets on the CA server; any user-level env vars set during testing.
- After the dry run works: real runs on the test bucket, then **the Nginx serving layer** (owner's next topic).

- 2026-10-22: serving layer decided — public-read CRL-only bucket + Nginx cache (docs/adr/0008). Bucket crl-test public: anonymous read OK
  with tenant in the path (`/<tenant>:<bucket>/<key>`), anonymous write denied. Nginx written (`serving/`), 32
  local behaviour tests pass. Next: deploy to a test project (serving/README.md steps).

## Definition of done (owner, 2026-10-25)
The project is NOT done until all 13 failure drills (dossier chapter 15) are performed and seen in Splunk.
Owner policy: CPU limit is mandatory in OpenShift (chart default limits.cpu "1").

## 2026-10-25 (pod health)
OpenShift events already go to Splunk: alert on BackOff / Liveness+Readiness probe failed / FailedScheduling /
image pull failures for crl-nginx (dossier chapter 9). Future note: move to Prometheus (ready < desired, KubePodCrashLooping)
via Alertmanager webhook to Splunk.

## 2026-10-25
System dossier written: docs/system-dossier.md (Hebrew, 22 chapters: every setting, rebuild from zero with
verify/rollback per step, runbooks per alert, procedures, drills, threat model, decision and fix log, open
questions incl. CA DR Q15/Q16, unverified assumptions, file inventory, glossary). Replaces docs/handbook.md.
Keep it current with every change.

## Final documentation requirement (owner, 2026-10-24; extended 2026-10-26, 2026-10-27)

Owner 2026-10-27: the FIRST thing in the documentation must tell the owner to learn GitOps, Argo CD, Helm and
Kubernetes thoroughly, and must emphasise ApplicationSet: when to use it (incl. microservices), when not, with
explanations. Done as dossier chapter 0; keep it first.

Owner 2026-10-26 (repeated): explain EVERY decision we made together, however small - resources included.
Owner 2026-10-26: at the end, document every small thing we did, down to EVERY LINE of the YAML files (chart
templates, values, monitor manifests, Argo Application) and of nginx.conf, the uploader and the monitor: what each line
does and why, plus every decision with its explanation (dossier chapter 18 is the decision log).

At the end of the project, write full documentation that explains every detail down to the last setting:
every setting and where it is stored, what each component and setting is for, and what each one protects
against. Include the six residual risks and the open decisions.

## Full review 2026-10-22 — pending work (owner approves before changes)

Nginx fixes (already proposed): preStop graceful quit; worker_processes 2; resources incl. ephemeral-storage,
no CPU limit; 3 replicas + PDB minAvailable 2; finish and verify the Helm chart (then remove serving/openshift.yaml).

New findings:
- Monitor -> Splunk: ConfigMap still uses port 8088 and verifyTls: true. HEC is on 443 here, and Python
  `requests` does not use the Windows/system trust store: mount the internal CA bundle and set verifyTls to its
  path; NetworkPolicy egress port 8088 -> 443.
- Public bucket exposes x-amz-meta-source-host (the CA host name) to anyone: hide that header in Nginx
  (monitor keeps run-id, crl-number-hex, sha256).
- Delta CRL "+" against the real S3: test end to end (upload by uploader, fetch through Nginx).
- Nginx access logs: confirm OpenShift log forwarding reaches Splunk.
- Images: mirror ubi9/nginx-124 internally if needed; pin by digest (Nginx and monitor base image).
- rollout.md: add the Nginx phase (Helm) and the public-bucket/tenant steps.

## Done 2026-10-24
Nginx: worker_processes 2, x-amz-meta-source-host hidden, cache max_size 512m (below the 1Gi volume).
Helm chart complete (serving/chart/crl-nginx): 3 replicas, preStop graceful quit (proven: SIGTERM cuts an
in-flight request, quit completes it), resources incl. ephemeral-storage and no CPU limit, PDB maxUnavailable 1,
checksum annotations, timeouts on probes; serving/openshift.yaml removed. Tests: 33 behaviour, shutdown, chart
render + kubeconform (6/6, Route checked by hand) + nginx -t on the rendered config.
Monitor: HEC URL as the uploader's (443), CA bundle ConfigMap crl-monitor-tls + verifyTls path, NetworkPolicy 443;
new test proves the bundle is required (32 tests pass). Note: Python 3.13+ rejects certificates without an
Authority Key Identifier (strict X.509); the image uses 3.12 - check the internal Splunk certificate before upgrading.
Remaining from the 8: the "+" test against the real S3 (during the Nginx deployment).

## Residual risks — present to the owner at the end of the project (owner request, 2026-10-22)

1. Single CA: if it is down longer than the CRL validity, nothing downstream helps. Mitigation: 17 h warning.
2. The uploader runs in one place (the CA). Covered by the 75-minute missing-run_end alert.
3. Nginx cache is per pod and lost on restart: S3 down + pod restart = that pod cannot serve. Other pods and
   the other site still serve. Option: cache on a PVC (StatefulSet).
4. DNS of publish1/publish2: a wrong or missing record defeats every layer behind it. Option: monitor DNS.
5. CRLs not published through the uploader (old path): resilience depends on the old path; the monitor sees
   divergence but does not repair.
6. Offline root: nothing signs for you; the 168 h warning is the only guard.

Verified 2026-10-22: certificates carry two CDP URLs (publish1 and publish2) - client-side failover between sites.

## Standing items

0. PSScriptAnalyzer was not run (not available offline to the author): run `build/Invoke-Checks.ps1` on Windows.

1. **Run the uploader test suite on Windows** (nothing in PowerShell has been executed by the author):
   `Invoke-Pester -Path tests/Publish-Crl.Tests.ps1 -Output Detailed` and `build/Invoke-Checks.ps1`
   (PSScriptAnalyzer). Report every failure verbatim.
2. Then on the test workstation with the `crl-test` bucket: `-DryRun`, two real runs
   (expect `published` then `unchanged`, exit 0), and check the S3 object metadata (`x-amz-meta-*`).
   Note: `staging/` and `lkg/` are no longer used; delete leftover objects there by hand.
3. Permissions review (service account rights, folder ACLs, task settings): see docs/uploader.md "Install".
4. Rotate the Splunk HEC token that was exposed earlier (also hard-coded in the old CheckCRLExpiration script).

## Decisions taken (2026-10-19 / 20)

- Only some CAs move to the new uploader now; one uploader per CA, `keyPrefix` = URL directory.
- Uploader triggered by event 4872 + hourly safety run; rollback protection from a local state file;
  S3 content untrusted and always repaired to match the source; AKI/SKI check removed (publish folder is
  written by the CA only).
- Serving: Nginx caching proxy in front of the local S3 (CDN-like), cache on emptyDir per pod (changed from PVC
  on 2026-10-25, see dossier 19.3b), `X-Cache-Status` header.
- Monitor: Python on OpenShift (ADR-0007), runs in the other site's cluster, list + CA certs from ConfigMaps,
  expiry warning 17 h (168 h for paths containing `root`), Splunk alerts on missing `crl_monitor_run_completed`.

## Open

- Gaps to 10/10 and the change-detection plan: docs/readiness-gaps.md (gaps 15-20 and the last section).

- Kept after review: monitor `sites_diverged` (needed while most CRLs do not go through the uploader;
  revisit when every CA publishes through it).

- **To do after the rollout: design how we detect changes to code and configuration** (uploader script, configs,
  monitor image and ConfigMaps, S3). Candidates in docs/readiness-gaps.md, last section. The uploader's
  self-reported script hash was removed on 2026-10-20 (not best practice).
- Two items under review (owner, 2026-10-20), keep or remove:
  1. monitor `not_yet_valid` (ThisUpdate in the future): only if the CA clock jumps;
  2. monitor list-change events: redundant if the list is managed in GitLab with review.

- How the CRL list gets into the ConfigMap (owner: later).
- Optional monitor check 12 (served number vs. uploader's last report in Splunk) — phase 2.
- Whether the internal S3 supports per-prefix + source-IP key policies, versioning, anonymous read for Nginx,
  and how it treats `+` in object paths.
- Build the monitor image in the organisation's registry (the author has no container runtime) and deploy.

- [2026-10-28] OPEN: pin the Nginx image (no :latest), mirror it into the internal registry (crane pull -> tar -> transfer -> push), update values image. Waiting: which internal registry.

- [2026-10-29] OWNER REQUIREMENT (final step, do not skip): walk through the project WITH the owner, file by file,
  explaining every relevant line of every YAML (chart templates, values, site files, Argo files, monitor manifests),
  nginx.conf, the uploader and the monitor. In Hebrew, RTL-friendly. This is on top of the written line-by-line dossier.
- [2026-10-29] Applied in the project: serving/chart/ (plural), CPU request 250m (LimitRange ratio 4), publish-root,
  bootstrap order B.9. GitLab copy of the owner must match: path serving/chart/crl-nginx in the ApplicationSet,
  files/ca-bundle.pem created inside the network.
- [2026-11-01] DECISION: prod sites = sou + cen (replace shay/guy everywhere when files are updated). Test site dropped.
  3 networks per site: AI, BI, CI, each its own CA and bucket on the site's S3. One namespace per site, 3 Deployments.
  PENDING: option A (one Application per site x network = 6, one ApplicationSet) vs option B (one Application per site = 2,
  chart loops over networks). Recommended A. Chart must become release-aware (names + instance label); quota for 3 networks.
- [2026-11-01] DECIDED option A and IMPLEMENTED in the project (not yet in GitLab): chart release-aware; ApplicationSet
  serving/sites/*/*/site.yaml -> crl-nginx-<site>-<network>, releaseName crl-nginx-<network>, two valueFiles;
  serving/sites/{sou,cen}/values.yaml + {ai,bi,ci}/{site.yaml,values.yaml}; old sites/sou/site.yaml+values.yaml removed.
  Tests: chart_test.sh (multi-network checks) + run_tests.sh 33/33 pass. Placeholders to fill: S3_HOST_<SITE>,
  TENANT_<SITE>, <SITE>_CLUSTER, NAMESPACE_<SITE>, BUCKET_<NET>, ROUTE_HOST_<SITE>_<NET>.
  TODO: quota request per site (12 pods...), bootstrap B.9 steps 2-4 for cen, delete the old test deployment,
  ca-bundle.pem must hold both sites' S3 chains, uploader configs per CA (bucket per network), monitor for 6 URLs,
  replace shay/guy in docs.
- [2026-11-01] CHANGED to matrix generator: serving/sites/<site>/site.yaml (site, cluster, namespace) x list [ai,bi,ci]. Network folders hold only values.yaml.
- [2026-11-01] OPEN (owner idea): SAME hostname (e.g. publishay.com) in all 3 networks, each network's own DNS
  resolving it to its own deployment. One shared OpenShift router CANNOT do it (it routes by Host header; duplicate
  host = HostAlreadyClaimed, only one Route admitted). Possible with (1) a router (IngressController shard) per network,
  sharded by route label (chart: route.labels per network, one namespace) or by namespace label (3 namespaces), or
  (2) a Service type LoadBalancer per network with its own IP (needs LB support, e.g. MetalLB; no Route).
  Requires split DNS per network. Monitor must then test each network by IP + Host header.
  ASK cluster admins: router per network? LoadBalancer IPs available? Until then: distinct host per network (current files).
- [2026-11-02] FINAL DOC must include (explained to the owner in chat, write them line by line in the build-from-zero
  guide): Release.Name chain (list/site -> releaseName -> {{ .Release.Name }} -> resource names); ApplicationSet template
  fill = search/replace of {{ .key }}; matrix vs git-files generator (and .path.basename option, not applied);
  manual vs automated sync per Application (root syncs only the ApplicationSet; each app its own resources; Refresh vs
  Sync; diff before sync); where the bucket lives (Git values -> ConfigMap nginx.conf proxy_pass -> pod file; checksum
  rolls pods); ConfigMap template line by line (include, nindent, |, {{-, ---); 3 releases x 2 ConfigMaps and why the CA
  ConfigMap is duplicated (one owner per object); ephemeral-storage (what counts, request = scheduler accounting not a
  reservation, limit = eviction, per-volume sizeLimit, quota makes it mandatory, sizing math ~600Mi worst case, how to
  measure); emptyDir (lifecycle, survives container restart not pod deletion, why with readOnlyRootFilesystem,
  emptyDir vs PVC); volumes + volumeMounts linked by name; readiness vs liveness (numbers, what happens, failure table,
  why they do not check S3); Degraded vs Progressing; Kubernetes names lowercase (folders = list values exactly);
  chart/ singular path must match GitLab exactly; ephemeral-storage key with hyphen in templates (incident 2026-11-02).
- [2026-11-02] DECIDED: one network, one namespace per site, sou = production, cen = DR. ApplicationSet: simple git files
  generator serving/sites/*/site.yaml -> crl-nginx-sou, crl-nginx-cen; releaseName crl-nginx; one values.yaml per site.
  Manual sync on the generated Applications (automated removed); root stays automated. Old resources named crl-nginx-ai/bi/ci
  must be deleted by hand (preserveResourcesOnDeletion keeps them). Quota per site: back to one deployment
  (requests CPU 1, mem 1Gi, eph 4Gi; limits CPU 4, mem 1Gi, eph 8Gi; pods 4).
- [2026-11-02] OWNER REQUIREMENT (final package): keep uploader/install/Publish-Crl.task.xml in the project, PORTABLE for
  other networks: placeholders only for account + install path, clear header. Plan: add uploader/install/Install-PublishCrlTask.ps1
  that EMBEDS the XML (a .ps1 passes the transfer inspection; .xml is blocked), takes -Account (gMSA or user) and -InstallDir,
  fills them, registers the task (gMSA: no password; user: -Password), and prints the two triggers to verify. Also document
  the manual UI build (General / Triggers: 4872 + 30 s delay, daily 00:07 repeat 1 h / Actions / Conditions / Settings),
  and why: the 30 s delay (files finished writing; base + delta published seconds apart -> one run uploads both,
  IgnoreNew skips the second; extra runs are harmless thanks to the SHA-256 compare), the hourly run (missed event,
  transient failure, S3 self-repair, regular run_end for Splunk), 00:07 (off the top of the hour).
  Owner's import of the XML failed on 2026-11-02 (error not yet seen) -> task built by hand in the UI.
- [2026-11-03] PLANNED (owner characterising first, nothing changed): several sync microservices (sync things between the
  publish sites) into the SAME ApplicationSet. Proposed layout: serving/services/<service>/<site>/{site.yaml,values.yaml},
  site.yaml adds service + chart path; generator serving/services/*/*/site.yaml; name {{.service}}-{{.site}}; path {{.chart}};
  releaseName {{.service}}. A service on one site only = no folder on the other. Monitor stays a separate Application.
  Watch: dependencies/order between services (ApplicationSet syncs in parallel).
- [2026-11-03] Uploader 2.3.0: optional plain-text secrets IN config.json (site.accessKey/secretKey override credentialFile;
  hec.token overrides tokenFile). Logs warn plaintext_secrets every run (names only). EXIT CRITERION: after rollout to all
  networks -> Protect-Secrets.ps1 per CA, remove the fields, confirm the warning is gone in Splunk. A config.json with
  secrets must NEVER go to Git (only config.example.json). ACL config.json: Administrators + uploader account only.
- [2026-11-03] OWNER REQUIREMENT (end of project): SYNTHETIC EVENTS for every Splunk alert, so each alert is proven to
  fire. Build a small sender (PowerShell, same HEC format as the uploader; and one for the monitor's sourcetype) that
  emits each alerting event: uploader fatal / crl_rejected / crl_older_than_published / site_unavailable / publish
  result=failed / no_valid_crl_in_directory / state_missing / plaintext_secrets / hec_failed, and the "silence" case
  (no run_end for > N hours = dead-man's switch, done by NOT sending); monitor checks (expired, near expiry, STALE,
  divergence, unreachable, stale_cache...); pod/OpenShift events (CrashLoopBackOff, FailedCreate exceeded quota,
  ProgressDeadlineExceeded, HostAlreadyClaimed). Every synthetic event carries synthetic=true and
  environment=test-alerts (and its own host), so real dashboards can exclude it and nobody mistakes it for an incident.
  Matrix: event -> expected alert -> fired? (Splunk search) -> time to fire. NOTE: synthetic events prove the ALERTS;
  they do NOT replace the 13 failure drills (which prove the SYSTEM). DONE still requires the 13 drills seen in Splunk.
- [2026-11-08] FUTURE (owner): new microservices = (1) monitoring, (2) sync with a THIRD-PARTY organisation's publish
  points. Generator will change then (serving/services/<service>/<site>/site.yaml with chart path, see 2026-11-03 entry).
  DECIDED 2026-11-08 (owner): the MONITOR goes INTO the same ApplicationSet; covered by meta-monitoring (Splunk dead-man alert on the monitor's heartbeat, outside Argo). Third-party sync:
  its own secrets, egress (NetworkPolicy / firewall to the other org), TLS trust of the other org, and consider its own
  namespace (different trust boundary). Migration of crl-nginx-<site> to the new layout must keep the Application names
  or accept a one-time recreate (preserveResourcesOnDeletion keeps Nginx running).
- [2026-11-08] FINAL SUMMARY must EMPHASISE (owner): releaseName - what it is, where it is set (ApplicationSet
  helm.releaseName; default = Application name), how it becomes {{ .Release.Name }} and every resource name; Application
  name vs Deployment name; what changes when moving to several services (dossier B.12).
- [2026-11-08] Sent crl-platform-git-2026-11-08.zip (everything but tests + monitor) for GitLab. Before it: stale comments
  and examples updated (sou/cen, mam/ica, no networks), Chart.yaml 1.1.0, serving/README + main README refreshed,
  .gitignore blocks config.json. Uploader 2.3.0 hash now 212F25F0...ABAB143 (comment change only). Tests: chart 11 ok,
  nginx 33/33, Pester 38/38.
- [2026-11-08] LATER (owner: "CI afterwards"): CI will be needed for services with our own code + image (fetch, monitor):
  test, build, immutable tag (commit/semver, never latest), push to internal registry, then bump the tag in values via MR
  and Sync in Argo. Per-folder rules. Nginx: mirror only. Open: GitLab runners that build images, internal registry
  + push credentials, internal mirrors for pip/base image.
- [2026-11-09] BUILT fetch (chart crl-fetch 1.0.0, hourly CronJob, sites sou/cen, empty fetch/app files), ApplicationSet
  for several components (app/chart in site.yaml; name kept crl-nginx), common/ca-bundle.values.yaml (+ .example),
  .gitignore exception for **/files/ca-bundle.pem. Secrets: by name only (crl-fetch-s3, keys accessKey/secretKey),
  created in each site namespace by hand. TODO owner: fill image (chart values), targets.yaml, S3 placeholders,
  create the Secret per site, create common/ca-bundle.values.yaml inside the network, quota for fetch, the code in
  fetch/app (must read AWS_* env, S3_*, TARGETS_FILE, CA env). Secret register to write in the dossier.
- [2026-11-09] ApplicationSet renamed crl-platform (file crl-platform-appset.yaml; old crl-nginx-appset.yaml deleted in
  GitLab). CHECK: Argo resource tracking method (label vs annotation). Our charts use app.kubernetes.io/instance =
  release name in labels and selectors; Argo LABEL tracking writes the same label (= Application name) on top-level
  metadata. Selectors/pod labels are not touched, but annotation tracking (default in newer Argo) avoids any clash:
  ask the Argo admins (argocd-cm application.resourceTrackingMethod).
- [2026-11-09] FINAL SUMMARY must include dossier B.13 (owner): ApplicationSet rename = new object (create new, prune
  old, Applications deleted and recreated with the same names, resources kept); CA bundle = one file in Git, one
  ConfigMap per component in the cluster, and why not one shared ConfigMap; the injected trusted-cabundle option.

## Parked (2026-11-16): monitoring stack outside Splunk (maybe)
- Option under consideration: move monitoring to Loki + Grafana (+ Prometheus for metrics). Not decided, not started; Splunk stays for the first version and the 13 drills.
- If chosen: uploader keeps writing the local JSON log; a collector agent (Alloy/Promtail/Fluent Bit) ships it to Loki. Metrics: textfile (.prom) written at the end of each run, or Pushgateway, because the uploader is a scheduled task, not a long-running process.
- Direct push from the script (HEC-style) only as a short-term shortcut; the agent is the recommended path.
- Full-outage detection still needs a check outside the stack (external heartbeat or the platform team watching the monitoring).
- Decide only after the Splunk version is proven by the drills.

## Final documentation (required for DONE, written last)
- The project is not done until this exists (owner, 2026-11-16).
- Audience: team lead, who must read and explain the system. Plus a decision log for the owner to learn from.
- Part 1, readable doc for the team lead: each part of the system (CA and uploader, S3, Nginx, fetch, Argo CD, monitor, Splunk), its purpose, data flow, and what happens in a failure.
- Part 2, decision log: a card for every file in the project (purpose, dependencies, main decision, what may and may not be changed). Line-by-line explanation for the central files only: Publish-Crl.ps1, nginx.conf, cronjob.yaml, deployment.yaml, _helpers.tpl, the ApplicationSet. Value files get a table of every key.
- Before writing: verify every statement against the current code, not against older docs.

## Reminders (owner, 2026-11-16): AIA certificates, not only CRLs. Certificates are public by design (no secrets), so the CRL-only rule does not apply to them.
- [~] Uploader: CA certificates are now read from certEnrollDirectory (v2.4.0, written, NOT yet run: no PowerShell here). Test on a CA before relying on it. Original item: also publish the CA certificates (the AIA files, .crt) from the publish folder, for every CA that issues, to the same S3 per site. Today Publish-Crl.ps1 reads only *.crl. Check the uploader covers the AIA path, and that certificate objects get the same byte-identical check.
- [x] Nginx: serve .crt (AIA) as well as .crl, with Content-Type by extension (application/pkix-cert, application/xml). Done in files/nginx.conf and run_tests.sh; NOT yet run (nginx not installed in this workspace). Test on the CA/cluster before relying on it. Today nginx.conf serves only *.crl (location regex line ~74) and everything else is 404, so this is a change to the regex and the content-type map, and to the monitor.
- [ ] Clients fetch the AIA over HTTP like the CRL: test with certutil -URL against the public address.


## Left for the end (owner, 2026-11-19)
- [x] .gitlab-ci.yml: pytest and Pester jobs removed; replaced by lint, validate and build jobs (2026-11-22, not run yet).
- [x] (2026-11-22) Stale comments that point to deleted test files: serving/chart/crl-nginx/templates/deployment.yaml (shutdown_test.sh), serving/chart/crl-nginx/values-sou.example.yaml (chart_test.sh).
- [ ] READMEs and docs that mention tests: README.md, serving/README.md, monitor/README.md, and docs/.

## AIA naming per generation (owner, 2026-11-19)
- [ ] Verify in a lab: after a CA renewal, the new CA certificate file in CertEnroll has a different name from the old one, and a test certificate from the new generation points its AIA to that new name. Old certificates still point to the old name, which must stay in S3.
- Until verified, the uploader's no-overwrite safety (refuse to replace an existing certificate object with different content) is still the open item from the design discussion.



## Status 2026-11-22

- Done in code: uploader 2.4.0 (version line aligned), monitor as Helm chart with per-site Argo apps, CI rewritten, README and stale references cleaned.
- Not done and needs the real environment (cannot be done from the repo alone): run the uploader on a CA, nginx on the cluster (`nginx -t`, Content-Type of .crt/.xml), the monitor and the CI pipeline, the 13 failure drills observed in Splunk, synthetic events, token rotation, and the security sign-off.
- Not verified by reading: the Get-Opt empty-string note in the old list (the current code returns the value as is, so there is no reproduced bug).
