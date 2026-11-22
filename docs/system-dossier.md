# System dossier: newpublish, CRL distribution to two sites

> **Read first: learn GitOps, Argo CD, Helm and Kubernetes properly, and understand when an ApplicationSet fits
> (including for microservices) and when it does not. See chapter 0 before anything else.**

| | |
|---|---|
| System | newpublish: publishing and serving AD CS CRLs to two independent sites |
| Owner | project owner |
| Versions | Uploader 2.4.0 · Monitor 1.1.0 · Helm charts crl-nginx, crl-fetch, crl-monitor · Nginx 1.24 |
| Last updated | 2026-11-22 (section 5 describes the 2.2.1 behaviour; later changes are in the decision log, chapter 18) |
| Status | The uploader runs on a CA server against a test bucket. Nginx, fetch and the monitor are written and tested locally; not yet deployed to OpenShift. Version 2.4.0 and the CI pipeline have not been run yet |

## 0. Before anything: what to learn (the owner's request)

> **The first recommendation of this document: learn GitOps, Argo CD, Helm and Kubernetes/OpenShift in depth.**
> The system is built on them. Operating it, diagnosing it and making any future change needs real control of
> these tools, not only of the files in this project.

### 0.1 Suggested learning path, in order

| # | Topic | What you should know at the end | Why it matters here |
|---|---|---|---|
| 1 | **Kubernetes / OpenShift basics** | Pod, Deployment, ReplicaSet, Service, Route, ConfigMap, Secret, namespace, labels and selectors, requests and limits, quota | Nginx and the monitor are made of these |
| 2 | **Kubernetes: availability** | probes (readiness, liveness, startup), rolling update, PodDisruptionBudget, anti-affinity, preStop and SIGTERM, eviction, ephemeral storage | Why 3 pods, why the probes do not check S3, why preStop |
| 3 | **Kubernetes: security** | securityContext, NetworkPolicy, ServiceAccount and RBAC, readOnlyRootFilesystem | Hardening of the pods |
| 4 | **Helm** | chart, values and value layers, templates and `_helpers.tpl`, `include`, `required`, `default`, `helm template` and `lint`, checksum annotations | The Nginx chart |
| 5 | **GitOps: the principle** | Git as the source of truth, desired state versus live state, reconciliation, drift, review through merge requests | Why we deploy only through Git |
| 6 | **Argo CD** | Application; manual sync versus `automated`; prune (removes only Argo-managed resources that were removed from Git, not resources created by hand); selfHeal (exists only with `automated`); polling versus webhook; Synced versus Healthy; AppProject; app of apps; ApplicationSet and its generators; retry; preserveResourcesOnDeletion | The whole deployment layer (appendix B) |
| 7 | **PKI / CRL** | CRL, delta CRL, CDP, NextUpdate, CRL Number, AIA, chain validation | Why the system is built this way (chapter 3) |

**Best way to learn:** build and break things in a test environment. The failure drills (chapter 15) are exactly that.
Official sources: the Kubernetes docs (kubernetes.io/docs), OpenShift (docs.openshift.com), Helm (helm.sh/docs),
Argo CD (argo-cd.readthedocs.io), and OpenGitOps (opengitops.dev) for the principles.

### 0.2 ApplicationSet: when yes and when no (the owner's emphasis)

**An ApplicationSet is a generator (a list of items with values) plus a template (what an Application looks like).
Each item becomes one Application.**

**When yes:**
- The same component in several sites, clusters or environments, where the difference is the **values** (values,
  cluster, namespace). **This is Nginx here.**
- One central Argo that manages several clusters.
- Microservices whose Application **structure** is the same and only the values differ: chart, path, repo, namespace
  as parameters of the generator.
- The same components in several environments: `matrix`.
- You want every new cluster or folder to get an Application automatically.

**When no:**
- Components that differ in structure (another chart, another deployment method, another placement rule). The template
  fills up with conditions and becomes harder to read than separate files.
- A **monitoring** component. It always stays outside the ApplicationSet of what it monitors, because it is a separate
  failure domain: a broken commit or template must not stop both at once. **This is the monitor here.**
- A few fixed Applications that differ from each other, where simplicity matters more than consistency.

**Microservices, when more than the values differ:**

| The difference | Solution |
|---|---|
| Values (chart, repo, namespace) | Parameters of the generator |
| The same services in several environments | `matrix` |
| A few exceptions with an unusual structural field | `templatePatch` (up to 2 or 3 exceptions) |
| Groups with different structures | One ApplicationSet per group |
| A completely different service | A separate Application |

**Generators, which one:** list (a few fixed items; adding one means editing the ApplicationSet), git files (**ours**:
one file per item holding the values; adding one means adding a file, and the template is untouched), git directories
(enough when the folder name is the value), cluster (every registered cluster), matrix and merge (combinations).
Full details: appendix B.5 to B.7. Sync, prune, selfHeal and webhooks: appendix B.8.

**The rule:** an ApplicationSet is justified as long as the **structure** of the Application is shared and only the
**values** change. Force uniformity only between things that really are alike.

---

## 1. Introduction

### 1.1 Purpose of this document

This is the single complete reference for understanding, installing and operating the system. It is written so that
a person who was not on the project can:
1. Understand what each component does, why it is built that way, and what each setting protects against.
2. **Build everything from scratch on another network** (chapter 11), following `docs/documentation-rule.md`.
3. Operate the system and diagnose faults (chapters 12, 13 and 20).
4. Know exactly what was tested, what was not, and which assumptions still need checking (chapters 18 and 19).

### 1.2 How to read it

- **Start with chapter 0** (what to learn, and when an ApplicationSet fits).
- To understand the design: chapters 3 to 9 (principle, architecture, each component).
- To install: chapters 10 and 11.
- During a fault: chapter 20 (diagnosis), then chapter 12 (runbook for each event).
- Terms: chapter 22. YAML and Helm files: appendix A. Argo CD: appendix B. One page for the desk: `docs/cheat-sheet.md`.

Technical terms stay in English, as they appear in the files and on the screens.

### 1.3 Status by component

| Component | Written | Tested locally | Running in the real environment |
|---|---|---|---|
| Uploader | yes | yes, 33 tests (PowerShell 7) | yes, on a CA server, bucket `crl-test` (PowerShell 5.1, without PSScriptAnalyzer) |
| S3 (public bucket, tenant) | no | no | yes: anonymous read returns 200, anonymous write returns AccessDenied |
| Nginx and Helm | yes | yes, 33 behaviour checks, shutdown, rendering and schema | no |
| Monitor | yes | yes, 32 tests and ruff | no (image not built yet) |
| Splunk alerts | no | no | no |

---

## 2. Requirements and goals

### 2.1 The owner's requirements

| # | Requirement | How it is met |
|---|---|---|
| R1 | A CRL is available to clients even when one component is down | Two sites, 3 pods per site, a cache that serves stale copies, two CDP URLs |
| R2 | Never serve an old CRL from the cache | Freshness of one minute with revalidation; stale only while S3 does not answer, and marked STALE |
| R3 | Make sure every CRL really belongs to its CA | The monitor verifies the signature against pinned certificates |
| R4 | Early warning before expiry | 17 hours; 168 hours for paths with `root` |
| R5 | Senior-engineer best practice, no unnecessary additions | Deliberate simplification (chapter 18.2); two external reviews; every decision has a reason |
| R6 | All settings outside the code; no secrets in clear text | `config.json` with DPAPI; Helm values and ConfigMaps; Secret |
| R7 | Complete documentation that allows a rebuild on another network | This document |
| R8 | Know whether someone changed code or configuration | **Postponed until after the rollout** (chapter 19) |

### 2.2 Targets (pending the owner's approval)

| Target | Proposed value | What guarantees it today |
|---|---|---|
| Availability of distribution | 99.99% | Two sites and client failover; not measured yet |
| Time from publishing until a client can get the new CRL | up to 5 minutes | 30 s (trigger) plus the run plus up to one minute (cache). Not measured yet |
| Time of the warning before expiry | 16 to 17 hours | `expires_soon` at 17 h |

**Inherent limit:** a client that has already stored a CRL does not see a new revocation until its copy expires
(according to the delta's validity). This is built into CRLs. Immediate revocation needs OCSP, a separate project if
it is ever required.

---

## 3. The principle behind everything

- **A CRL is a document signed by the CA, valid until the NextUpdate inside it.** A client (for example Windows)
  downloads the CRL, keeps it in its own cache, and uses it until it expires, without asking again.
- **So a short outage in distribution is usually not noticed.** There is one real risk: NextUpdate arrives and the
  client cannot get a new, valid CRL. Then the revocation check fails, and according to the application's policy the
  connection is blocked.
- **A CRL is public by definition.** It holds no secret. Its protection is the signature, not secrecy. A client never
  accepts a forged CRL as valid, because it checks the signature. So the risk of a broken CRL is **availability**, not
  trust.

Every decision in the system is meant to make sure that a client always finds a valid CRL, and that when a problem
starts to approach, we know in advance.

---

## 4. Architecture

```
Publishing path (write)                      Serving path (read)
───────────────────                          ──────────────────
AD CS (CA) writes the CRL to a folder
        │
Publish-Crl.ps1 (on the CA)
   ├── signed PUT ─► S3 site Shay ◄── anonymous GET ── Nginx ×3 (OpenShift) ◄── http://publish1.com ◄─┐
   └── signed PUT ─► S3 site Guy  ◄── anonymous GET ── Nginx ×3 (OpenShift) ◄── http://publish2.com ◄─┴─ clients
                                                         ▲
                       Monitor (Python, CronJob in the other site) ─┘ ──► Splunk ──► alerts
```

| Component | Where it runs | Role | Why it is there |
|---|---|---|---|
| AD CS | the CA server (Windows) | signs CRLs | it is the only source of truth |
| Uploader | the CA server | uploads every CRL to the S3 of both sites and fixes any difference | only there is direct access to the files the CA writes, on the Windows host that already exists |
| S3 | one per site | storage only | two independent sites, with no sync between them |
| Nginx | OpenShift, in each site | serves clients over HTTP, with a cache | a layer that keeps the service up when S3 is down |
| Monitor | OpenShift, in the **other** site | checks the two addresses the way a client does | a monitor in the same site would fail together with what it is supposed to detect |
| Splunk | already in the organisation | receives events and alerts | the existing alerting tool |

**The two paths are separate on purpose.** A failure on the publishing path does not stop serving (the last CRL keeps
being served, and it is valid for hours or days). A failure in serving at one site does not affect the other site.

**The certificates carry two CDP URLs** (publish1 and publish2; verified 2026-10-22). Windows tries them in order, so
the fallback between sites happens on the client itself, with no load balancer and no DNS failover.

**Important:** only some of the CAs go through the uploader for now. The rest stay on the old path. The monitor
checks all of them.

---

## 5. The uploader (`src/Publish-Crl.ps1`, version 2.2.1)

### 5.1 What it does, step by step

1. Reads `config.json` and checks that every required field exists (a missing field means exit 1 with the field name).
2. Forces TLS 1.2 on all connections.
3. Loads the PSPKI and AWS.Tools.S3 modules (a missing module means exit 1).
4. Reads every file whose extension is **exactly** `.crl` from the source folder. For each file:
   - It is read into memory, and **the copy that was read** is saved in a temporary folder. Only that copy is uploaded.
     If the CA writes to the file in the middle of the run, what gets uploaded is what was checked.
   - It is parsed by PSPKI. If it is not a CRL, or has no CRL Number, it is logged as `crl_rejected` and not uploaded.
5. Compares each CRL with the highest number already uploaded before (a local state file). A lower number means
   `crl_older_than_published`, and it is not uploaded. A missing state file gives a `state_missing` warning. A corrupt
   state file stops the run (exit 1).
6. For each site separately, for each CRL:
   - Downloads the existing object from S3 and computes its SHA-256.
   - Identical to the source: `unchanged`, nothing is touched.
   - Different, missing, or unreadable: uploads the source with its metadata.
7. Updates the state file (atomic write).
8. Writes every event as a JSON line to the local log, and at the end sends all the events to the Splunk HEC in one request.
9. Deletes the temporary folder and exits with an exit code.

**What it does not check, and why:** the signature and validity of the CRL. The monitor checks those, on what clients
actually receive. Only the CA writes to the source folder, and a broken CRL would be rejected by the client anyway
(see chapter 3). This decision was checked in two external reviews.

### 5.2 Every setting in `config.json`

The file sits next to the script (`D:\CrlPublisher\config.json` in production; `C:\CrlPublisher\config.json` on the test
server). It holds no secrets.

| Setting | Example | Why it exists | What it protects against, or what happens without it |
|---|---|---|---|
| `environment` | `prod` | appears in every event | separates test and production events in Splunk |
| `sourceDirectory` | `D:\CrlPublish` | the folder the CA publishes to (CDP "Publish CRLs to this location") | without it there is nothing to upload. On the test server: `C:\Windows\System32\CertSrv\CertEnroll` |
| `keyPrefix` | `shay/eos` | the path in S3, the same as the path in the client's URL | a path mismatch means the client asks for a file that does not exist (404) |
| `logDirectory` | `D:\CrlPublisher\logs` | the local log | evidence of every run, even when Splunk is not available |
| `logRetentionDays` | `30` | deletes old logs | a full disk |
| `stateFile` | `D:\CrlPublisher\state\published.json` | the highest number uploaded for each file | **protection against rollback**: a CA restored from an old backup would otherwise publish an old CRL |
| `s3Attempts` | `3` | attempts per S3 call | a brief network fault does not fail the run |
| `sites[].name` | `shay` | site name | appears in the events |
| `sites[].endpoint` | `https://s3.shay.local` | the S3 address of the site | |
| `sites[].bucket` | `publish` | the bucket (a signed request does not need the tenant: S3 derives it from the key) | |
| `sites[].region` | `us-east-1` | required by the SDK for signing | on an internal S3 the value usually does not matter |
| `sites[].forcePathStyle` | `true` | the address style `endpoint/bucket/key` | most internal S3 services do not support `bucket.endpoint` |
| `sites[].credentialFile` | `D:\CrlPublisher\secrets\shay.cred` | the write key of the site, protected with DPAPI | **required**. No keys in clear text and no environment variables (removed in 2.2.0) |
| `hec.url` | `https://splunk.../services/collector/event` | the HEC address. **The same URL the old script used** (port 443 here) | |
| `hec.tokenFile` | `D:\CrlPublisher\secrets\hec.token` | the HEC token, protected with DPAPI | **required** |
| `hec.index` | (not set) | **recommended to leave out.** Without it, events go to the default index of the token | an index that does not exist is dropped **silently** when HEC sits behind a forwarder (this happened on 2026-10-21) |
| `hec.sourcetype` | `crl:publisher` | for searching in Splunk | |
| `hec.source` | `Publish-Crl` | | |
| `hec.timeoutSec` | `10` | the maximum time to send | a run stuck on Splunk |

### 5.3 Secrets

| Secret | File | Format | Who can read it |
|---|---|---|---|
| S3 key for each site | `secrets\<site>.cred` | `Export-Clixml` of a PSCredential: user name = access key, password = secret | **only the account that created the file, on this machine** (DPAPI) |
| HEC token | `secrets\hec.token` | `ConvertFrom-SecureString` (DPAPI); the token only, without the word Splunk | the same |

**Why DPAPI:** the file is encrypted with a key that belongs to the Windows account. Copying it to another machine,
or reading it as another account, gives garbage. No file holds a secret in clear text, and no external vault is needed.
**Limit:** a local administrator on the server can in principle impersonate the account. This is accepted, because a
local administrator on the CA already controls the CA.

**Creating the secrets for the service account (gMSA):** a gMSA cannot log on by itself, so
`uploader/install/Protect-Secrets.ps1` runs **as the gMSA** through a temporary scheduled task. An administrator writes
`secrets\input.json` with the keys in clear text; the script creates the DPAPI files, writes `protect-secrets.log`
with the account name, and **deletes input.json in every case** (also on failure).

**On the test server today:** `C:\CrlPublisher\secrets\sou.cred` and `hec.token` were created with your personal account.
Before production: delete them and create them again as the gMSA. A token that was exposed in the past must be replaced
(see chapters 13.5 and 19).

### 5.4 S3 permissions the uploader needs

Only **GetObject** and **PutObject**, on the CA's prefix only. **No ListBucket and no Delete.**
- Without List: since 2.2.0, whether an object exists is checked with a direct download. 404 means it does not exist.
  403 means "denied". Some products answer 403 for a missing file when List is not allowed, so the uploader uploads in
  that case. A real permission problem fails on upload and is reported.
- Without Delete: a stolen key cannot delete CRLs. Versioning on the bucket allows recovery of an overwritten object.

### 5.5 Metadata on every object

| Field (`x-amz-meta-`) | Content | Why |
|---|---|---|
| `run-id` | the run identifier | links an object to the run in the log and in Splunk |
| `crl-number-hex` | the CRL number | the monitor reports it |
| `sha256` | the hash of the content | fast comparison during an investigation |
| `source-host` | the CA server name | for internal investigation. **Nginx hides it from clients** (the bucket is public) |
| `uploader-version` | the script version | |

The Content-Type of every object is `application/pkix-crl`.

### 5.6 Retries

Only failures that may pass by themselves are retried: no HTTP answer (network, DNS, TLS, timeout), 408, 429, and 5xx.
Errors 400, 403 and 404 fail **immediately** with the reason (waiting does not help). The back-off is 400 ms, 800 ms,
and so on, with a random jitter of up to 300 ms. The same rule applies to sending to Splunk (3 attempts).

### 5.7 Logs and events

- **Local log:** `logDirectory\publish-crl-YYYYMMDD.log`, one JSON line per event. If the log cannot be written, one
  warning is raised and the run continues.
- **Splunk:** all the events of the run, sent at the end in one request.
- **Every error includes the full exception chain** (outer to inner) and **the server's answer** (for example the reason
  for a 400 from Splunk).

| Event | Level | Meaning | First action |
|---|---|---|---|
| `run_start` | info | the run begins | |
| `publish` | info or error | result for each CRL and each site. `result` = `published`, `unchanged`, `dryrun` or `failed`; `live` = what S3 had: `identical`, `different`, `missing` or `denied` | on `failed`, read `error` (403 = key or permission; 0 or connection = network or TLS) |
| `run_end` | info | summary and `exitCode` | Splunk alerts when it does not arrive for 75 minutes |
| `crl_rejected` | error | a file that is not a valid CRL | if the CA was writing the file at that moment, the next run fixes it; otherwise check the file |
| `no_valid_crl_in_directory` | error | nothing to publish | the CDP setting or folder permissions |
| `crl_older_than_published` | error | the source is older than what was already published | a CA restore? A deliberate decision. To accept it, remove that key from the state file |
| `state_missing` | warn | no state file; the rollback protection starts from zero | expected once, on the first run. Afterwards, find out why it disappeared |
| `site_unavailable` | error | no keys for the site | the `.cred` file or the account |
| `retry` | warn | a temporary fault, retrying | only a concern if frequent |
| `hec_failed` | error (local log only) | Splunk did not accept the events | `httpStatus`: 0 = network or TLS, 400 = index or format, 401 or 403 = token |
| `fatal` | error | configuration, module, folder, or a corrupt state file | read `error` |

**Important:** "Success" from HEC means "received", not "stored in the index". An event that is dropped after it was
received cannot be detected by the script. The missing `run_end` alert in Splunk catches that case.

### 5.8 Exit codes

| Code | Meaning |
|---|---|
| 0 | everything is fine |
| 1 | configuration, startup, or a corrupt state file |
| 2 | some uploads failed |
| 3 | all uploads failed |
| 4 | a CRL was rejected (others may have been published) |

### 5.9 The scheduled task (`uploader/install/Publish-Crl.task.xml`)

| Setting | Value | Why |
|---|---|---|
| trigger 1 | event 4872 in the Security log, delay 30 seconds | the CA published a CRL, so the upload happens within about half a minute (emergency revocation). The delay gives the CA time to finish writing |
| trigger 2 | every hour (at minute 07) | a safety net: a missed event, S3 repair, and a regular `run_end` for the dead man's switch |
| account | `DOMAIN\gmsa-crlpub$` | a service account with no password to manage; only "Log on as a batch job"; not an administrator |
| `RunLevel` | `LeastPrivilege` | no elevated rights |
| `MultipleInstancesPolicy` | `IgnoreNew` | never two runs at the same time on the same state |
| `ExecutionTimeLimit` | 10 minutes | a stuck run is stopped |
| `StartWhenAvailable` | true | a missed run (server was off) runs as soon as possible |
| `-ExecutionPolicy Bypass` | | no signature requirement (decision of 2026-11-02). The script is protected by the folder ACL |

Prerequisites for the trigger: `auditpol /set /subcategory:"Certification Services" /success:enable` and
`certutil -setreg CA\AuditFilter 127`, then restart CertSvc.

### 5.10 Folder permissions (production, chapter 11, step 8)

| Folder | Administrators | SYSTEM (the CA) | gMSA |
|---|---|---|---|
| `D:\CrlPublisher` (script and configuration) | Full | Full | Read and execute |
| `secrets`, `logs`, `state` | Full | Full | Modify |
| `D:\CrlPublish` (the source) | Full | Modify | Read |

**What this protects against:** the gMSA cannot change the script or the configuration, and it cannot write a CRL.
Only the CA writes to the source.

### 5.11 What TLS requires on the CA server

Windows downloads a missing intermediate by itself (AIA), so it was enough to import the S3 root certificate into the
computer's Trusted Root store. (Fixed on 2026-10-21: "could not establish trust".) The same applies to Splunk if its
certificate comes from a CA that the server does not know.

---

## 6. S3

| Topic | Setting | Why |
|---|---|---|
| one bucket per site | separate, **no replication** between sites | replication would carry corruption or deletion from one site to the other. The uploader writes to both separately |
| name | test: `crl-test`. Production: **`publish`**, the same name in both sites (separate S3 systems; the only difference in the configuration is `endpoint`). Owner's decision, 2026-10-25 | |
| purpose | **CRLs only**, never other files | the bucket is public for reading, so every file in it is exposed |
| reading | **public** (GetObject) | a CRL is public by definition. This way Nginx needs no key (fewer components in the most critical layer). This is also the default of AWS Private CA (`PUBLIC_READ`) |
| writing | only with the uploader's key | tested: an anonymous PUT returns AccessDenied (2026-10-22) |
| List | preferably blocked | not required: the CRL names are in the certificates anyway |
| Versioning | enable in production | allows recovery of an overwritten object |
| key per CA and per site | write and read only under that CA's prefix, no Delete | a leaked key affects one CA only |
| several CAs in the same folder | allowed (for example `iii/bbb/sha.crl` from CA1 and `iii/bbb/gaa.crl` from CA2). The `keyPrefix` is the same and the files differ. **File names must be unique** (AD CS: the CA name plus the suffix) | two CAs with the same file name would overwrite each other on every run. Isolation between keys is by the file name prefix (`iii/bbb/sha*`), if the product supports it |
| anonymous address | `https://<endpoint>/<tenant>:<bucket>/<key>` | our S3 is multi-tenant. In a signed request the tenant is derived from the key; an anonymous request must name it (tested 2026-10-22) |
| `+` in a name (delta CRL) | Nginx sends `%2B` | S3 may read `+` in a path as a space. **Not yet tested against the real S3** |

Rejected alternative: a private bucket, and Nginx with a read key (rclone sync to disk). It is kept as a fallback if
security forbids a public bucket (ADR-0008).

---

## 7. The serving layer: Nginx on OpenShift

### 7.1 How a request travels

1. A client requests `http://publish1.com/shay/eos/shay.crl`.
2. The OpenShift router forwards it to the Service, and the Service forwards it to one of the 3 pods that are **ready** (readiness).
3. Nginx: only GET and HEAD of `*.crl` pass; everything else gets 404 or 405 and never reaches S3.
4. A fresh copy exists (less than a minute old): it is returned at once (`HIT`).
   An old copy exists: it is returned at once, and in the background Nginx asks S3 "has it changed?" (304 = no).
   No copy exists: it is downloaded from S3, stored, and returned (`MISS`).
5. S3 is not working: the last copy is returned with `X-Cache-Status: STALE`, and the monitor raises an alert.

### 7.2 Files

| File | Content |
|---|---|
| `serving/chart/crl-nginx/files/nginx.conf` | all the behaviour. The same for every site; Helm fills in host, tenant and bucket |
| `serving/chart/crl-nginx/values.yaml` | every setting with its default |
| `values-<site>.yaml` | the values of one site (host, tenant, bucket, route) |
| `files/ca-bundle.pem` (in the chart) | the organisation's bundle of CA certificates (PEM), one for all sites. It is created inside the network, because PEM is blocked in transfers |
| `templates/*.yaml` | the objects in OpenShift |
| `serving/tests/` | tests: behaviour (33), graceful shutdown, chart rendering |

### 7.3 Every setting in `nginx.conf`

**General settings**

| Setting | Value | Why |
|---|---|---|
| `worker_processes` | `2` | **not auto**: inside a container, auto counts every core of the node (for example 32 workers), uses memory and can exceed the limit. Two is far more than enough |
| `pid` | `/tmp/nginx.pid` | the pod's filesystem is read-only except `/tmp` and the cache |
| `error_log` | `/dev/stderr warn` | errors appear in `oc logs` |
| `worker_connections` | `1024` | connections per worker; more than needed |
| `*_temp_path` | `/tmp/...` | the defaults point to paths that cannot be written |
| `log_format crl` and `access_log /dev/stdout` | JSON | one line per request: time, client, path, status, cache, S3 status, response times. Goes to Splunk |
| `server_tokens off` | | no version in headers or error pages |
| `sendfile on` | | efficient sending from disk |
| `keepalive_timeout` | `30s` | the client connection stays open for another request |

**The cache**

| Setting | Value | Why |
|---|---|---|
| `proxy_cache_path` | `/var/cache/nginx/crl` | on the pod's volume |
| `keys_zone` | `crl:10m` | memory for the index (tens of thousands of files) |
| `max_size` | `512m` | **deliberately lower than the volume (1 Gi)**: overflowing the volume makes OpenShift evict the pod |
| `inactive` | `7d` | a copy that nobody requested for 7 days is removed |
| `use_temp_path` | `off` | write directly into the cache |

**Path handling**

| Setting | What it does | Why |
|---|---|---|
| `map $request_uri $crl_path` | the path as the client sent it, without the query string | `$uri` is already decoded (real spaces), and sending it to S3 breaks the request |
| `map $crl_path $s3_path` | `+` becomes `%2B` (once) | delta CRL; S3 may read `+` as a space |

**S3**

| Setting | Value | Why |
|---|---|---|
| `upstream s3` and `server <host>:443` | the S3 address | |
| `keepalive 8` | | up to 8 open TLS connections to S3, with no new handshake per request |
| `proxy_pass` | `https://s3/<tenant>:<bucket>$s3_path` | the anonymous address with the tenant |
| `proxy_http_version 1.1` and `Connection ""` | | required for keepalive |
| `proxy_set_header Host` | the S3 name | not `publish1.com` |
| `proxy_ssl_server_name on` and `proxy_ssl_name` | SNI | S3 returns the correct certificate |
| `proxy_ssl_verify on` | | **without this, anyone could impersonate S3** |
| `proxy_ssl_verify_depth 4` | | the maximum chain length |
| `proxy_ssl_trusted_certificate` | `/etc/nginx/s3-ca/ca.pem` | **the whole chain** (roots and intermediates). Nginx (OpenSSL) does **not** download a missing intermediate from AIA the way Windows does |
| `proxy_connect_timeout` | `3s` | S3 does not answer: a fast switch to the stored copy |
| `proxy_send` and `proxy_read_timeout` | `10s` | |
| `proxy_next_upstream off` | | with one server, a retry only delays; the cache covers it |

**Protection at the entrance**

| Setting | What | Why |
|---|---|---|
| `if ($request_method !~ ^(GET|HEAD)$) { return 405; }` | read only | write attempts |
| `if ($request_uri ~* "(\.\.|%2e|%2f|%5c|\x5c|//)") { return 404; }` | `..`, encoded dot, slash or backslash, `\`, `//` | "walking" the paths into another tenant, bucket or file. (A bug was found and fixed here: a wrong escape disabled the `//` check.) |
| `location ~ "...\.crl$"` | only `.crl`, only allowed characters, at most one `+` | exposing files that are not CRLs |
| `location / { return 404; }` | everything else | |
| `location = /healthz` | `ok`, no S3, no log line | OpenShift's liveness checks |

**Cache rules**

| Setting | Value | Why |
|---|---|---|
| `proxy_cache_key` | `$crl_path` | the same copy for every host and query string |
| `proxy_cache_valid 200` | `1m` | **the longest time a client gets an old CRL after a new one is published** (even in an emergency revocation) |
| `proxy_cache_valid 404` | `10s` | a new file appears quickly |
| `proxy_cache_revalidate on` | | asks "changed?" (If-None-Match) instead of downloading again |
| `proxy_cache_background_update on` | | the client does not wait for the check |
| `proxy_cache_lock on` and `5s` | | only one request goes to S3 for a file that is not cached, even when a thousand clients arrive together |
| `proxy_cache_use_stale` | `error timeout updating http_500 http_502 http_503 http_504 http_403 http_404` | **the line that keeps the service up when S3 fails**: in each of these cases the last copy is served |
| `proxy_ignore_headers` | `Cache-Control Expires Set-Cookie Vary` | our rules, not S3's |

**What the client receives**

| Setting | Why |
|---|---|
| `Content-Type: application/pkix-crl` (replaces S3's) | the standard type, also for files that were uploaded through the old path |
| `Cache-Control: public, max-age=60` | an intermediate proxy will not keep an old copy. (Windows itself keeps the CRL until NextUpdate) |
| `X-Cache-Status` | HIT, MISS, STALE, UPDATING or REVALIDATED. The monitor alerts on STALE |
| hiding `Server`, `x-amz-request-id`, `x-amz-id-2`, `x-rgw-object-type`, and S3's Cache-Control, Expires and Set-Cookie | so the backend is not exposed |
| hiding `x-amz-meta-source-host` | the **CA server name** is not exposed. The rest of the metadata stays for the monitor |

### 7.4 Helm: `values.yaml`

| Value | Default | Why |
|---|---|---|
| `s3.host` | required | the S3 name of the site, without https:// and without a port |
| `s3.tenant` | required | |
| `s3.bucket` | required | |
| `s3.caBundle` | empty | empty = the chart uses `files/ca-bundle.pem`: **the organisation bundle, one for all sites** (PEM, roots and intermediates). A value here is only for a site that needs a different bundle; it overrides. With no bundle at all, Helm refuses |
| `route.host` | empty | empty = OpenShift generates a name (testing). Production: `publish1.com` and `publish2.com` |
| `replicas` | `3` | N+1: one pod remains during maintenance and during one more failure |
| `image` | `ubi9/nginx-124:latest` | the official Red Hat image, no build. **In production: `@sha256:...`** |
| `resources.requests.cpu` | `100m` | guaranteed |
| `resources.limits.cpu` | `"1"` | **the organisation's policy requires a limit.** A full core: Nginx with 2 workers that serves from the cache needs far less; a low limit would cause throttling (slowdown) under load. Empty = no limit, for clusters that allow it |
| `resources.requests` and `limits.memory` | `128Mi` and `256Mi` | in practice 20 to 60 MB; the limit protects the node from a leak |
| `resources.requests` and `limits.ephemeralStorage` | `1Gi` and `2Gi` | the cache sits on the node's disk; without a declaration the pod is evicted first when the disk fills |

Helm **refuses to render** when a required value is missing, with a clear message.

### 7.5 The objects in OpenShift

**ConfigMaps:** `crl-nginx` (the prepared `nginx.conf`), `crl-nginx-s3-ca` (`ca.pem`).

**Deployment `crl-nginx`**

| Setting | Value | Why |
|---|---|---|
| `strategy` | `RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 1` | during an update, the new pod is ready **before** the old one goes down. A broken configuration takes nothing down |
| annotations `checksum/config` and `checksum/ca` | a hash of the configuration and of the certificates | **every change rolls the pods automatically**; nobody can forget a restart |
| `automountServiceAccountToken` | `false` | no API token to steal if the pod is compromised |
| `terminationGracePeriodSeconds` | `30` | time for a graceful shutdown |
| `securityContext` (pod) | `runAsNonRoot`, `seccompProfile: RuntimeDefault` | no root; system calls are restricted |
| `podAntiAffinity` (preferred, by hostname) | | the pods run on different nodes. "Preferred" so that scheduling does not get stuck when no node is free |
| `command` | `nginx -c /etc/nginx/conf/nginx.conf -g 'daemon off;'` | bypasses the image's start script; the whole configuration is ours |
| `imagePullPolicy` | `IfNotPresent` | a node that already has the image does not depend on the registry |
| `lifecycle.preStop` | `sleep 10; nginx -s quit`, then wait for the end | **graceful shutdown.** OpenShift sends SIGTERM, and Nginx reads it as a fast shutdown that cuts connections. The hook waits until the router stops sending requests, and then `quit` finishes the open requests. **Proven in testing**: with SIGTERM the request was cut (000); with quit it completed (200) |
| `readinessProbe` | `/healthz` every 5 s, timeout 2 s, 2 failures | a pod that is not ready leaves the Service (it is not restarted). **It does not check S3**, because otherwise an S3 outage would remove every pod exactly when the cache must serve |
| `livenessProbe` | `/healthz` every 10 s, timeout 2 s, 3 failures | a stuck pod is restarted. More tolerant than readiness: remove quickly, kill only when there is no other option. It does not check S3 either (otherwise every pod restarts and the cache is lost) |
| (no startupProbe) | | Nginx starts in under a second |

| `securityContext` (container) | `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `drop ALL` | an intruder cannot change files or gain privileges |
| volumes | `conf` and `s3-ca` (ConfigMaps, read only); `cache` 1 Gi, `tmp` 256 Mi, `logs` 64 Mi (emptyDir) | an emptyDir is deleted with the pod: **the cache does not survive a restart** (risk 3, chapter 19.1) |

**PodDisruptionBudget**

`maxUnavailable: 1`. During **planned** maintenance (drain, upgrade), OpenShift takes down at most one pod at a time,
and waits for it to come back before taking down the next. This was chosen over `minAvailable: 2`, because it works
with any number of replicas and does not block a drain completely (minAvailable 2 with 2 replicas would block it).
It does not protect against unplanned failure. For that we have 3 pods, spreading, and a second site.

**Service:** a fixed internal address. It spreads traffic only across the ready pods, port 8080.

**Route:** the external address. **Deliberately without `tls`.** A CDP must be served over HTTP: verifying TLS requires a
revocation check, which requires a CRL (a loop). `disable_cookies` means the router adds no cookie (not needed for a CRL).

**No NetworkPolicy (removed 2026-10-25, the owner's decision):** the content is public, and the pods hold no secret.
Restricting access to the router alone added no real protection. **If the namespace has a default-deny policy**, add a
policy that allows traffic from the router to port 8080, or the service is unreachable.

### 7.6 HPA: why not

An HPA adds pods according to CPU. It does **not give availability** (availability means the minimum that always runs,
plus spreading, plus the PDB). The load is small and almost entirely served from the cache, and it is too slow for the
wave of downloads right after NextUpdate. If CPU becomes consistently high in the future: an HPA with `minReplicas: 3`.

### 7.7 Resources for the project quota (per site; each site is a separate cluster)

| Type | requests | limits | Calculation | Why this margin |
|---|---|---|---|---|
| CPU | 1 | 4 | 4 pods (3 + 1 during an update) × 100m = 400m; limit 4 × 1 | a diagnostic pod (`oc debug`), an update that got stuck (old and new pods together), growth to 4 pods |
| Memory | 1 Gi | 2 Gi | 4 × 128 Mi = 512 Mi; limit 4 × 256 Mi = 1 Gi | the same |
| Disk (ephemeral-storage) | 4 Gi | 8 Gi | 4 × 1 Gi; limit 4 × 2 Gi | **generous**: set without measurement. Reduce it after measuring the size of the CRLs (MASTER OPEN LIST) |
| pods | 10 | | 4 plus a margin | |

Owner's decision, 2026-10-26: request these numbers; the disk will be reduced after measurement. The quota must match
the chart's requests and limits, or the pods will not start. Expected real use: about 200 to 400 m CPU and 150 to 250 MB
of memory for 3 pods.
Monitor (a separate project, when we get there): CPU 100m/500m, memory 128Mi/256Mi, disk 256Mi/512Mi, PVC 1Gi.

---

## 8. The monitor (`monitor/crl_monitor.py`, version 1.1.0)

### 8.1 What it does

Every 5 minutes, in the **other** site: it downloads every CRL in the list from publish1 and from publish2, **the way a
client does**, and checks:

| Check | Severity | Meaning | Why |
|---|---|---|---|
| `http_unavailable` | error (after 2 runs) | no 200 received | a site is not serving |
| `stale_cache` | error (after 2 runs) | `X-Cache-Status: STALE` | the site's S3 is not reachable from Nginx |
| `not_a_crl` | error (after 2 runs) | the content is not a CRL (including empty) | a broken file in S3 |
| `signature_invalid` | error **immediately** | not signed by the CA in the list | forgery, or a wrong file at the path |
| `not_yet_valid` | error (after 2 runs) | ThisUpdate is in the future | the CA's clock jumped (under test; open decision) |
| `expired` | error (after 2 runs) | NextUpdate has passed | the CA did not publish |
| `expires_soon` | warning | less than 17 hours left (168 for paths with `root`) | **early warning**: time to fix it before clients are affected |
| `crl_number_decreased` | error **immediately** | the number is lower than one seen before at the same address | an old CRL was served (replay or restore) |
| `sites_diverged` | warning | the two addresses serve different numbers for more than 30 minutes | a site did not receive the update. The only check that catches this for CRLs on the old path |
| `list_invalid` / `ca_certs_invalid` | error immediately | a wrong ConfigMap | nothing is checked until it is fixed |
| `list_entry_added` / `removed` | info / warning | the list changed | removing a line is the easy way to hide a broken CRL (under test; open decision) |
| `state_corrupt` | warning | the state file is unreadable, starts again | |

**Escalation:** an ordinary error is reported as a pending warning on the first run, and as an error only on the second
run in a row (to avoid noise). A wrong signature and a decreasing number raise the alarm at once.
**Pinned certificates:** checked against the CA certificates in the ConfigMap, **never** against what the server sends.
**High-water mark per address:** a site that lags behind is not a replay (a bug found in testing and fixed in the design).
At the end of every run: `crl_monitor_run_completed` (status and counts). Splunk alerts when it does not arrive.

### 8.2 Settings (`monitor/chart/crl-monitor/values.yaml` and `templates/configmap.yaml`)

| Setting | Value | Why |
|---|---|---|
| `environment`, `site` | `prod`, `guy` | appear in the events; `site` = the cluster the monitor runs in |
| `targets` | publish1, publish2 (http) | exactly what clients receive |
| `listFile` | `crl-list.txt` | one line per CRL: `<full path> <CA name>`. How the list is maintained is an open decision |
| `caDir` | `/etc/crl-monitor-ca` | ConfigMap `crl-monitor-ca`: one file `<ca>.pem` per CA, **all key generations** of that CA |
| `stateFile` | `/var/lib/crl-monitor/state.json` (PVC) | high-water marks, failure sequences, a snapshot of the list |
| `expiryWarning` | 17 h, and `root` gets 168 h | 17 hours is enough to react even at night; a week for an offline Root that needs a signing ceremony |
| `http` | timeout 10 s, 3 attempts | |
| `alerting` | 2 runs, 30 min gap between sites, 5 min clock skew | |
| `splunk.url` | **the same URL as the uploader** (443 here) | fixed 2026-10-24 (it was 8088) |
| `splunk.verifyTls` | `/etc/crl-monitor-tls/ca-bundle.pem` | **Python does not use the operating system's trust store**. Without the bundle the internal CA is not recognised (proven in testing). Fixed 2026-10-24 |
| `splunk.index` | (not set) | same as in the uploader |

### 8.3 The objects in OpenShift

| Object | Settings | Why |
|---|---|---|
| CronJob | `*/5`, `concurrencyPolicy: Forbid`, `startingDeadlineSeconds: 120`, `backoffLimit: 0`, `activeDeadlineSeconds: 240` | never two runs on the same state; a stuck run is stopped before the next one; the next scheduled run is the retry |
| PVC | 64 Mi, RWO | the state survives between runs |
| Secret `crl-monitor-hec` | a file, mode 0400 | the token is not in an environment variable or the configuration |
| ConfigMap `crl-monitor-tls` | `ca-bundle.pem` | trust for Splunk's TLS |
| ConfigMaps `crl-monitor-config` and `crl-monitor-ca` | | configuration and list; pinned certificates |
| securityContext | non-root, read-only root filesystem, drop ALL, no API token | |
| NetworkPolicy | ingress: nothing. egress: DNS, publish1 and publish2 (80 and 443), Splunk (443) | a compromised monitor cannot reach anywhere else. **The IP addresses must be replaced** |
| image | UBI python-312, non-root, dependencies with hashes (`--require-hashes`) | supply chain |

**Note for Python 3.13 and later:** it rejects certificates without an Authority Key Identifier (strict X.509). The image
is 3.12 today. Before any upgrade, check Splunk's TLS certificate.

### 8.4 Exit codes

0: the run completed (findings are in the events). 1: configuration. 3: sending to Splunk failed.

---

## 9. Splunk

| Source | sourcetype | index |
|---|---|---|
| Uploader | `crl:publisher` | the token's default index (search with `index=*`) |
| Monitor | `crl:monitor` | the same |
| Nginx | OpenShift logs (JSON) | confirm forwarding (open work) |

**Alerts to configure (step 4 in the rollout):**

| Alert | Why |
|---|---|
| no `run_end` from a CA host for 75 minutes | **dead man's switch**: an uploader that stopped running looks like silence otherwise |
| `run_end` with an `exitCode` other than 0 | |
| `event=state_missing` (except the first time) | the rollback protection was reset |
| no `crl_monitor_run_completed` for 15 minutes | the monitor's dead man's switch |
| every `crl_monitor_finding` with `severity=error` | |

**Alerts on the health of the Nginx pods (from OpenShift events, already forwarded to Splunk):**

| Alert | Event | Why |
|---|---|---|
| a pod in a crash loop | `reason=BackOff` ("Back-off restarting failed container") on a pod of `crl-nginx`, for more than 5 minutes | a persistent problem; `oc logs <pod> --previous` |
| frequent restarts | `reason=Unhealthy` with "Liveness probe failed", more than 3 in 15 minutes | an early warning before the pods go down |
| a pod out of rotation | `reason=Unhealthy` with "Readiness probe failed" in a row for more than 10 minutes | a live pod that does not serve |
| a pod that does not start | `reason=FailedScheduling` or `Failed` (ErrImagePull, ImagePullBackOff) | no room, or no image |

Field names depend on how the cluster forwards events (for example `involvedObject.name`, `reason`, `message`). Adjust
them to a real event.

**Future note: move to Prometheus (OpenShift's built-in monitoring).** Events show **what happened**, not **the current
state**: they do not say "how many pods are ready right now". The most accurate alert is on the symptom: `ready < 3` for
10 minutes, and `ready = 0` at once. That needs metrics. Prometheus ships ready-made alerts (`KubeDeploymentReplicasMismatch`,
`KubePodCrashLooping`) that can be sent to Splunk through Alertmanager (webhook). Until then: the event alerts above, and
the monitor's `http_unavailable` check for the symptom seen from outside.

---

## 10. Prerequisites and versions

### 10.1 The CA server

| Item | Requirement | Note |
|---|---|---|
| system | Windows Server with AD CS | |
| PowerShell | Windows PowerShell 5.1 | `#Requires -Version 5.1` |
| modules | PSPKI; AWS.Tools.Common and AWS.Tools.S3 | installed for all users (`C:\Program Files\WindowsPowerShell\Modules`), from the internal repository |
| service account | gMSA (`gmsa-crlpub$`) with "Log on as a batch job" only | needs a KDS root key in the domain |
| Audit | Certification Services: Success; `CA\AuditFilter 127` | for event 4872 |
| CDP folder | `D:\CrlPublish` set on the CA as "Publish CRLs/Delta CRLs to this location" | |
| network | HTTPS to the S3 of both sites; HTTPS to the Splunk HEC | |
| TLS trust | the root (and intermediates) of the S3 and Splunk certificates in the computer's certificate store | Windows fills in a missing intermediate through AIA |
| ~~code signing~~ | dropped 2026-11-02 | the protection is an ACL on `D:\CrlPublisher` |

### 10.2 S3 (per site)

| Item | Requirement |
|---|---|
| bucket | dedicated to CRLs, public **for reading only**, List blocked if possible |
| Versioning | enabled |
| write key | per CA: Get and Put on its own prefix, no Delete, and if possible only from the CA's IP address |
| anonymous address | `https://<endpoint>/<tenant>:<bucket>/<key>` |
| TLS | the S3 certificate chain is included in the organisation bundle (`files/ca-bundle.pem` for Nginx) |

### 10.3 OpenShift (per site)

| Item | Requirement |
|---|---|
| version | Kubernetes 1.30 API or later (checked against the 1.30 schema) |
| tools | `oc`, `helm` 3 |
| nodes | 3 worker nodes or more (for 3 pods on different nodes) |
| quota for Nginx | requests.cpu 500m, limits.cpu 4, requests.memory 512Mi, limits.memory 1Gi, requests.ephemeral-storage 4Gi, limits.ephemeral-storage 8Gi, pods 5 |
| images | `registry.access.redhat.com/ubi9/nginx-124` (or an internal mirror); the monitor image in the organisation's registry |
| router | label `policy-group.network.openshift.io/ingress` on the router's namespace (the default in OpenShift 4) |
| DNS | `publish1.com` (Shay) and `publish2.com` (Guy) point to the router of their site |
| monitor | PVC (RWO, 64 Mi); egress to DNS, publish1 and publish2 (80), and Splunk (443) |

### 10.4 Dependency versions

| Component | Version |
|---|---|
| Nginx | 1.24 (`ubi9/nginx-124`) |
| Python (monitor image) | 3.12 (UBI python-312). **3.13 and later reject certificates without an AKI** |
| cryptography / requests / PyYAML / urllib3 / certifi | 50.0.2 / 2.34.2 / 6.0.3 / 2.8.0 / 2026.10.19 (`requirements.txt`, with hashes) |
| Pester | removed from CI on 2026-11-22. Last tested locally with 5.6.1 |
| PSScriptAnalyzer (CI) | 1.24.0 |
| CI images | `mcr.microsoft.com/powershell:lts-ubuntu-22.04`, `python:3.12-slim`, `alpine/helm`, `kubeconform`, Kaniko |

### 10.5 Values that differ between environments

| Value | Where it is set |
|---|---|
| site names, endpoints, buckets, credential file paths | `config.json` (uploader) |
| `keyPrefix` | `config.json`; must match the path in the certificates' CDP |
| `sourceDirectory` | `config.json` |
| HEC URL | `config.json` and ConfigMap `crl-monitor-config` |
| S3 host, tenant and bucket for Nginx | `values-<site>.yaml` |
| organisation CA bundle | `serving/chart/crl-nginx/files/ca-bundle.pem` (or `s3.caBundle` for a site that needs another) |
| `route.host` | `values-<site>.yaml` |
| image digest | `values.yaml` (`image`) of each chart |
| targets, CRL list, CA certificates, site | the monitor's ConfigMaps (`monitor/chart/crl-monitor/values.yaml`) |
| IP addresses in the monitor's NetworkPolicy | `monitor/sites/<site>/values.yaml` |
| gMSA name and domain | Task XML, ACL, Protect-Secrets |

---

## 11. Building from scratch on a new network

Each step: what to do, what you should see, and how to undo it. Stop at the first step that does not match, and report
the output. Replace the examples: `DOMAIN`, `gmsa-crlpub`, `CA01`, `shay/eos`, the bucket names, hosts and tenant.

### Step 0: prepare the code on the new network

1. Move the project folder (or the zip) and verify the hash of every file, after whitespace is removed:
   `$t = (Get-Content <file> -Raw) -replace '\s',''; [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t))) -replace '-',''`
   Expected: the same hash as the one that was delivered.
2. CI (if GitLab is available): `.gitlab-ci.yml` runs PSScriptAnalyzer, a PowerShell parse check, ruff, `helm lint`,
   `helm template` and kubeconform, and builds the monitor image on the default branch. Expected: green. In a closed
   environment, point Install-Module and the images at internal mirrors.

### Step 1: uploader checks on a workstation (no S3)

1. `Get-Module -ListAvailable Pester`. Expected: 5.x. (Pester is no longer part of CI, so this step is optional.)
2. Run the local checks with PSScriptAnalyzer: `Invoke-ScriptAnalyzer -Path uploader -Recurse -Settings uploader\PSScriptAnalyzerSettings.psd1`. Expected: no findings.

### Step 2: a test S3 bucket

1. Bucket `crl-test` (dedicated), with versioning.
2. A test write key (Get and Put).
3. Make the bucket public for reading.
4. Expected from a workstation, without a key: `Invoke-WebRequest 'https://<endpoint>/<tenant>:crl-test/<key>'` returns 200
   once an object exists (step 3), and `-Method Put` returns 403.
Undo: remove the public access, or delete the bucket.

### Step 3: the uploader against the test bucket (on the CA, with a personal account)

1. Folder `C:\CrlPublisher` (or `D:\`) with `logs`, `state` and `secrets`. Copy `Publish-Crl.ps1` and verify its hash.
2. TLS trust: import the root (and intermediates) of S3 and Splunk into the **computer's** Trusted Root and Intermediate stores.
   Expected: `Invoke-WebRequest https://<s3>` does not return "could not establish trust".
3. Secrets under the personal account (testing only):
   `Get-Credential | Export-Clixml C:\CrlPublisher\secrets\sou.cred` (user = access key, password = secret);
   `Read-Host -AsSecureString | ConvertFrom-SecureString | Set-Content C:\CrlPublisher\secrets\hec.token`.
4. `config.json` from `src\config.example.json`: one site (`sou`), `bucket: crl-test`, `sourceDirectory` = the CDP folder,
   `keyPrefix` = the path in the CDP, `hec.url` = **the same URL the existing script uses**, without `hec.index`.
5. `.\Publish-Crl.ps1 -ConfigPath C:\CrlPublisher\config.json -DryRun; $LASTEXITCODE`
   Expected: `state_missing`, `result=dryrun` or `unchanged`, exit 0.
6. Without `-DryRun`. Expected: `published live=missing`, exit 0; the objects in S3; `state\published.json` created.
7. Run again. Expected: `unchanged live=identical`, and no `state_missing`.
8. Overwrite an object in S3 with another file, then run. Expected: `published live=different`, and the correct file is back.
9. `'junk' | Set-Content <sourceDirectory>\junk.crl`, then run. Expected: `crl_rejected`, exit 4. **Delete junk.crl at once.**
10. Splunk: `index=* sourcetype="crl:publisher" earliest=-1h`. Expected: the events (in the token's default index).
Undo: delete the folder and the objects in the bucket.


### Step 4: Nginx in a test project

1. `oc new-project crl-serving-test` (plus the quota from 10.3).
2. `values-sou.yaml` from `values-sou.example.yaml`: `s3.host` (without https://), `s3.tenant`, `s3.bucket: crl-test`.
3. The organisation bundle (PEM) goes to `serving/chart/crl-nginx/files/ca-bundle.pem`. Make sure it includes the S3 chain
   (root and intermediates). What S3 sends: `openssl s_client -connect <host>:443 -servername <host> -showcerts </dev/null`.
4. `helm lint serving/chart/crl-nginx -f ../../sites/sou/values.yaml`. Expected: 0 errors.
5. `helm upgrade --install crl-nginx serving/chart/crl-nginx -f ../../sites/sou/values.yaml`
6. `oc get pods -l app=crl-nginx -o wide`. Expected: 3 Running, READY 1/1, on different nodes.
7. `oc get route crl-nginx` gives the host. `curl -sI http://<host>/<keyPrefix>/<file>.crl`. Expected: 200,
   `X-Cache-Status: MISS`, `Content-Type: application/pkix-crl`, and no `x-amz-meta-source-host`. Repeat: `HIT`.
8. **Delta CRL** (`<name>+.crl`): `curl -sI http://<host>/<keyPrefix>/<name>+.crl`. Expected: 200.
9. `oc logs deploy/crl-nginx`. Expected: JSON lines with `"status":200`.
10. Update without errors: while `while true; do curl -s -o /dev/null -w '%{http_code}\n' http://<host>/...; done` runs,
    run `oc rollout restart deploy/crl-nginx`. Expected: only 200.
Undo: `helm uninstall crl-nginx`.

### Step 5: the monitor in a test project

1. Build the image from `monitor/` (CI or podman), push it, and record the digest.
2. `oc new-project crl-monitor-test`
3. `oc create secret generic crl-monitor-hec --from-literal=hec-token=<token>`
4. `oc create configmap crl-monitor-tls --from-file=ca-bundle.pem` (the TLS chain of Splunk).
5. CA certificates: on the CA, `certutil -ca.cert ca.cer` and `certutil -encode ca.cer ca.pem`; paste into `crl-monitor-ca`
   (the key is the CA name, for example `ca-shay.pem`; every key generation goes under that same key).
6. In `values.yaml` of the chart (or the site values): `targets` (for testing, the route from step 4), `crlList` with one or two
   real paths, and `splunk.url`.
7. The digest goes into the chart's `image`; the IP addresses into `monitor/sites/<site>/values.yaml`. Then
   `helm template monitor/chart/crl-monitor --values monitor/sites/<site>/values.yaml | oc apply -f -`.
8. `oc create job --from=cronjob/crl-monitor m1 && oc logs job/m1`. Expected: no `crl_monitor_finding`, and the last line is
   `crl_monitor_run_completed` with `"status":"ok"`, exit 0.
9. Add a path that does not exist to the list, run twice. Expected: `http_unavailable` with `pending:true`, then an error. Remove it.
10. Splunk: `index=* sourcetype="crl:monitor"`. Expected: the same events.
Undo: `oc delete project crl-monitor-test`.

### Step 6: Splunk alerts

1. No `event=run_end` from a CA host for 75 minutes. 2. `run_end` with `exitCode!=0`. 3. `event=state_missing`.
4. No `crl_monitor_run_completed` for any `site` for 15 minutes. 5. `crl_monitor_finding` with `severity=error`.
Expected: every alert is tested in a drill from chapter 15.

### Step 7: S3 for production (with the S3 team)

A dedicated public bucket for each site, versioning, a key for each CA and site (a prefix, no Delete, an IP restriction if possible).
Write down what the product does not support.

### Step 8: the CA for production

1. gMSA: `New-ADServiceAccount -Name gmsa-crlpub -DNSHostName gmsa-crlpub.DOMAIN -PrincipalsAllowedToRetrieveManagedPassword CA01$`;
   on the CA, `Install-ADServiceAccount gmsa-crlpub`. Expected: `Test-ADServiceAccount gmsa-crlpub` returns True.
2. "Log on as a batch job" for `DOMAIN\gmsa-crlpub$` (through GPO or secpol). No other rights.
3. Folders and ACLs (administrator):
   ```
   mkdir D:\CrlPublisher\secrets, D:\CrlPublisher\logs, D:\CrlPublisher\state, D:\CrlPublish
   icacls D:\CrlPublisher /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "DOMAIN\gmsa-crlpub$:(OI)(CI)RX"
   icacls D:\CrlPublisher\secrets /grant "DOMAIN\gmsa-crlpub$:(OI)(CI)M"
   icacls D:\CrlPublisher\logs    /grant "DOMAIN\gmsa-crlpub$:(OI)(CI)M"
   icacls D:\CrlPublisher\state   /grant "DOMAIN\gmsa-crlpub$:(OI)(CI)M"
   icacls D:\CrlPublish /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)M" "DOMAIN\gmsa-crlpub$:(OI)(CI)R"
   ```
4. CDP: `certutil -setreg CA\CRLPublicationURLs "+65:D:\CrlPublish\%3%8%9.crl"` (or in the console: "Publish CRLs" and
   "Publish Delta CRLs"), then `net stop certsvc && net start certsvc`, then `certutil -crl`. Expected: `.crl` files in `D:\CrlPublish`.
5. Audit: `auditpol /set /subcategory:"Certification Services" /success:enable`, `certutil -setreg CA\AuditFilter 127`,
   restart CertSvc, then `certutil -crl`. Expected: event 4872 in the Security log.
6. Modules for all users: PSPKI, AWS.Tools.Common, AWS.Tools.S3.
7. Copy to `D:\CrlPublisher`: `Publish-Crl.ps1` (signed), `Protect-Secrets.ps1`, `Publish-Crl.task.xml`, `config.json`
   (`sourceDirectory = D:\CrlPublish`, `keyPrefix`, **still the test bucket for both sites**).
8. **Delete the personal secrets and every environment variable that was set during testing.**
Undo: remove the extra CDP and delete the folders.

### Step 9: secrets as the gMSA

1. An administrator creates `D:\CrlPublisher\secrets\input.json` (the format is at the top of `Protect-Secrets.ps1`).
2. ```
   $a = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -File D:\CrlPublisher\Protect-Secrets.ps1'
   $p = New-ScheduledTaskPrincipal -UserId 'DOMAIN\gmsa-crlpub$' -LogonType Password
   Register-ScheduledTask -TaskName CrlSecrets -Action $a -Principal $p
   Start-ScheduledTask CrlSecrets
   ```
3. Expected: `protect-secrets.log` says `OK as DOMAIN\gmsa-crlpub$`; the `.cred` files and `hec.token` exist; `input.json` is deleted.
4. `Unregister-ScheduledTask CrlSecrets -Confirm:$false`.

### Step 10: the task, still on the test bucket

1. Replace the account and the paths in the XML.
2. `Register-ScheduledTask -TaskName Publish-Crl -Xml (Get-Content -Raw D:\CrlPublisher\Publish-Crl.task.xml) -User 'DOMAIN\gmsa-crlpub$'`
3. `Start-ScheduledTask Publish-Crl`. Expected: `Get-ScheduledTaskInfo` shows `LastTaskResult 0`, and `published` in the log.
4. `certutil -crl`. Expected: a new run within about a minute (event 4872).
Undo: `Unregister-ScheduledTask Publish-Crl`.

### Step 11: moving to production

1. Step 9 again, with the production keys of both sites.
2. `config.json`: the endpoint and bucket of each site.
3. `Start-ScheduledTask Publish-Crl`. Expected: exit 0, `published` for both sites; a second run gives `unchanged`.
4. Nginx in each site: step 4 with the production bucket, `route.host` = publish1.com or publish2.com, and the image pinned by digest.
5. DNS for publish1 and publish2 points to the router of each site.
6. The monitor **in the other site**: step 5 with the full list, targets publish1 and publish2, and the real IP addresses.
   Expected: `status: ok`.
7. Keep the old script (CheckCRLExpiration) until the new monitor has been quiet and correct for a long period.
8. The failure drills from chapter 15, each one observed in Splunk.

---

### 11.x Renewing a CA generation (procedure)

**Why this procedure:** a new generation has three things that must be available before anything is issued from it: a CRL
signed with the new key, the CA certificate for chain discovery (AIA), and the CA certificate in NTAuth and in the clients'
trust stores. Any of them can be delayed without anyone noticing, so the procedure goes through them in order.

1. **Renewal.** Perform the renewal following the CA's own procedure.
2. **Manual CRL.** Run `certutil -crl` at once, and do not wait for the cycle. This creates a CRL of the new generation and raises event 4872.
3. **Check that the task worked.** The uploader log should contain `publish` with `kind=crl`, and the new CRL should be in S3
   through the public address.
4. **CA certificate (AIA).** Make sure the new generation's `*.crt` file is in `certEnrollDirectory`, and that the task uploaded it
   (`kind=cert`). Run the task by hand if needed.
5. **NTAuth and trust stores.** Make sure the new generation's certificate is in the domain's NTAuth store, and that it is
   distributed to the clients' trust stores. Without this, smart card logon fails even when the CRL is valid.
6. **Only then issue from the new generation.** The gate: steps 1 to 5 have passed.

**What the procedure does not include, and why:** the task's hourly cycle is a safety net only. It does not replace the manual
publish, because it can miss a window of up to an hour.

---

## 12. Runbooks: what to do for each alert

Structure: what it means, first checks, the fix, and what **not** to do.

**R-01 · no `run_end` from a CA for 75 minutes**
- Meaning: the uploader did not run, or ran and did not reach Splunk.
- Checks: `Get-ScheduledTaskInfo Publish-Crl` (LastRunTime, LastTaskResult); today's local log; whether there are `hec_failed` events.
- Fix: the task is disabled, so enable it. It runs but `hec_failed`: Splunk, TLS or URL (R-05). It does not run at all: the gMSA account,
  the batch-logon right, the server.
- Do not: run it by hand from a console while the task is running (two runs on the same state), or run it with `schtasks /run /tn Publish-Crl`.

**R-02 · `exitCode=2` or `3` (uploads failed)**
- Checks: `publish result=failed` lines in the log: `httpStatus` and `error`.
- 403: a wrong, expired or unauthorised key (`.cred`, the S3 team). 0 or connection: network, DNS, TLS (trust in the root). 5xx: S3 itself.
- Do not: disable the certificate check.

**R-03 · `exitCode=4` or `crl_rejected`**
- A file in the source folder is not a valid CRL. If the CA wrote it at exactly that second, the next run is fine. Otherwise: who wrote
  to that folder? Only the CA should.

**R-04 · `crl_older_than_published`**
- The source is older than what was already published. Almost always: a CA restored from a backup, or a move to DR.
- This is a **manual decision**: make sure the situation is real. If you accept the old CRL, remove its key from `state\published.json`
  and run again. Better: publish a new CRL from the CA (a higher number) with `certutil -crl`.
- Do not: delete the whole state file.

**R-05 · `hec_failed`**
- `httpStatus`: 0 = network or TLS (URL, trust in Splunk's root); 400 = index or format (read `response`); 401 or 403 = the token.
- The events are in the local log, so nothing was lost.

**R-06 · `state_missing` (not on the first run)**
- The rollback protection was reset. Find out: a restore? a cleanup? permissions on the `state` folder?
- Check in the monitor that there is no `crl_number_decreased`, and that the numbers at both addresses are the latest.

**R-07 · `fatal`**
- The `error` explains it: a missing configuration (the field name), a module that is not installed, a folder that does not exist,
  or a corrupt state file (restore it or delete it by hand after checking).

**M-01 · `http_unavailable`**
- One address does not return 200. `curl -sI` the address; `oc get pods` in that site; the route; DNS. A 404 means the file is not in S3
  at this path (keyPrefix? tenant? bucket?), or the CRL does not go through the uploader (the old path).

**M-02 · `stale_cache`**
- Nginx is serving a copy because S3 is not working. `oc logs deploy/crl-nginx`: `s3Status` (empty = no connection; 403 = the bucket is not
  public; 404 = the object disappeared; 5xx = S3). TLS: the bundle (`files/ca-bundle.pem`) lacks a new intermediate or root.
- Deadline to fix: the NextUpdate of the CRL being served.

**M-03 · `not_a_crl`**
- The content in S3 is corrupt. The uploader fixes it on the next run (within an hour); run the task at once if the CRL goes through
  the uploader. Otherwise, it is the old path.

**M-04 · `signature_invalid`** (immediate)
- **Suspected forgery**, or a wrong file at the path. Check the uploader metadata in the finding (run-id, sha256); the object versions in S3;
  whether a new key generation was added to a CA that was not added to `crl-monitor-ca` (procedure 13.3). Run the uploader (it returns the correct file).

**M-05 · `crl_number_decreased`** (immediate)
- An old CRL is being served. Check the versions in S3; whether the CA was restored; run the uploader.

**M-06 · `expired` or `expires_soon`**
- The CA did not publish a new CRL. On the CA: is CertSvc running, `certutil -crl`, did the uploader upload (R-01). For an offline Root:
  a signing ceremony. `expires_soon` gives 17 hours (a week for the Root): act before it becomes `expired`.

**M-07 · `sites_diverged`**
- The two addresses serve different numbers for more than 30 minutes. For a CRL that goes through the uploader: check
  `publish result=failed` for one site. For the old path: the old publish to one site failed.

**M-08 · `list_invalid` or `ca_certs_invalid`**
- The ConfigMap is wrong (a line that is not valid, an unknown CA, a broken PEM). **Nothing is checked until it is fixed.**

**M-09 · `list_entry_removed`**
- A line was removed from the list. Make sure it was intentional (removing a line is the easy way to hide a broken CRL).

**M-10 · no `crl_monitor_run_completed` for 15 minutes**
- `oc get cronjob,jobs` in the monitor's site; `oc logs job/<last>`. Exit 3 = Splunk (TLS bundle, URL, token, NetworkPolicy on 443).
  Exit 1 = configuration.

**N-01 · Nginx pods do not start**
- `oc describe pod` and `oc logs`: `nginx -t` fails (configuration), S3's DNS name does not resolve, `ImagePullBackOff` (registry or digest),
  a missing ConfigMap. During an update, the old pods keep serving (maxUnavailable 0).

---

## 13. Routine procedures

### 13.1 Emergency revocation
1. Revoke in the CA console. 2. `certutil -crl`. 3. Event 4872: the uploader runs within about 30 seconds. Expected: `published` for both sites.
4. Within a minute Nginx serves the new one. Expected: a number check, using the monitor (`crlNumber`) or a download and `certutil -dump`.
5. Only after both addresses serve the new number, on critical servers: `certutil -urlcache crl delete`.
Remember: other clients will see the revocation only when their stored copy expires.

### 13.2 Adding a new CA to the uploader
1. A CDP is added to the source folder of that CA (or a new CA server: chapter 11, steps 8 to 11).
2. A S3 key for the new prefix in each site. 3. The `keyPrefix` in that CA's configuration equals the path in the CDP.
4. The monitor: the CA certificates go to `crl-monitor-ca`, and the paths to `crl-list.txt`. 5. Expected: `published`, and the monitor reports `status: ok`.

### 13.3 Renewing a CA key (a new generation)
1. **Before** the renewal: add the new generation's certificate to the **same** key in `crl-monitor-ca` (the old one stays).
2. AD CS adds a CRL with a suffix such as `(1)`: add the new paths to `crl-list.txt`.
3. The uploader discovers the new files by itself. Expected: `published` for the new files, and the monitor reports no `signature_invalid`.

### 13.4 Replacing the S3 key
1. A new key from the S3 team. 2. `input.json`, then step 9 (Protect-Secrets as the gMSA). 3. `Start-ScheduledTask Publish-Crl`. Expected: exit 0.
4. Revoke the old key.

### 13.5 Replacing the HEC token
1. A new token from the Splunk team. 2. Uploader: step 9 with `hecToken` only. 3. Monitor:
   `oc create secret generic crl-monitor-hec --from-literal=hec-token=<new> --dry-run=client -o yaml | oc apply -f -`.
4. Expected: events in Splunk from both. 5. Revoke the old one. **A token that was exposed in the past must be replaced before production.**

### 13.6 Replacing the TLS certificate of S3 (or of the CA that signed it)
1. **Before** the replacement: add the new root or intermediate to `files/ca-bundle.pem` (next to the old ones), commit it, and Argo rolls the pods.
2. `helm upgrade --install ...`. The pods roll by themselves (checksum).
3. On the CA server: import the new root into the certificate store. 4. After the replacement, the old ones can be removed.
Without this: Nginx serves STALE, and the uploader fails on TLS.

### 13.7 Changing a setting in Nginx
Change `values-<site>.yaml` or `files/nginx.conf`, then `helm lint`, then `helm upgrade --install`. A gradual update without errors.
Rollback: `helm rollback crl-nginx <revision>`.

### 13.8 Updating the Nginx image
A new digest in `values.yaml`, then `helm upgrade`. Check that the nginx version is the same (or run `serving/tests` again on the new version).

### 13.9 Retiring a CRL
Remove it from `crl-list.txt` (the monitor reports `list_entry_removed`, which is expected). An object left in S3 keeps being served.
If it is deleted, Nginx keeps serving a stale copy as long as someone requests it (the copy is removed after 7 days without requests).

---

## 14. Resilience: what happens when each component fails

| Fails | What clients see | Who notices, and how fast | How long there is to fix it |
|---|---|---|---|
| an Nginx pod | nothing (it leaves the Service within about 10 seconds) | OpenShift starts a new one | n/a |
| a node | nothing (the pods run on other nodes) | OpenShift | n/a |
| an update or a drain | nothing (the new pod is ready before the old one goes down; graceful shutdown; PDB) | n/a | n/a |
| S3 of a site | nothing (STALE) | the monitor's `stale_cache`, in 5 to 10 minutes | until the NextUpdate |
| S3's TLS certificate was replaced without updating the bundle | nothing (STALE) | the monitor's `stale_cache` | until the NextUpdate |
| a whole site | Windows moves to the second CDP address | the monitor (in the other site) reports `http_unavailable` | until the NextUpdate |
| Uploader or CA server | nothing at once | Splunk: no `run_end` for 75 minutes; the monitor's `expires_soon` 17 hours before | 17 hours from the alert (a week for the Root) |
| Splunk | nothing | no reports, so the alerts themselves do not fire | local logs are kept |
| the monitor | nothing | Splunk: no `crl_monitor_run_completed` | n/a |
| a file replaced in S3 | up to a minute of a broken file | the monitor's `signature_invalid` at once | the uploader fixes it within an hour |
| a CA restored from a backup | nothing (the uploader refuses) | `crl_older_than_published` at once | a manual decision |
| the state file deleted, and an old CRL in the source | an old CRL may be published | `state_missing` at once; the monitor's `crl_number_decreased` | |


**For a client to get no CRL**, both sites must fail at the same time: the whole site is unreachable, **or** S3 is down and all the
pods have restarted. Even then, clients that already stored a CRL keep working until its NextUpdate.

---

## 15. Failure drills (Definition of Done)

"It works as designed" is an assumption until every failure has been observed in practice in Splunk. **The project is not DONE
until all 13 drills have been run and observed in Splunk.** In the test environment:

| # | Drill | Expected |
|---|---|---|
| D1 | Block one site's S3 from Nginx (NetworkPolicy or a wrong address) | clients get 200 with STALE; monitor `stale_cache` |
| D2 | Garbage in an S3 object | monitor `not_a_crl`; the uploader repairs it |
| D3 | An old CRL in an S3 object | `crl_number_decreased`; the uploader repairs it |
| D4 | A forged CRL with a high number in S3 | `signature_invalid` at once; the uploader repairs it |
| D5 | Delete all Nginx pods in one site | Windows moves to the second CDP; `http_unavailable` |
| D6 | Make the bucket non-public | STALE (403); `stale_cache` |
| D7 | Disable the task | the missing `run_end` alert after 75 minutes |
| D8 | Disable the monitor's CronJob | the alert after 15 minutes |
| D9 | Remove a line from the list | `list_entry_removed` |
| D10 | An emergency revocation, end to end | the new number in both addresses within about 2 minutes |
| D11 | `oc rollout restart` under load | only 200 |
| D12 | `oc adm drain` on a node with a pod | the service is not affected; the PDB keeps 2 pods |
| D13 | Windows client: the first site serves a broken CRL | **unknown** whether Windows moves to the second address. To be checked |

---

## 16. Security and threat model

**Assets:** the CA's signing key (out of scope: protected by the CA itself); the availability of a valid CRL; the integrity of the
content served; the write keys for S3; the HEC token.
**Trust boundaries:** the CA (tier 0), then S3 (not trusted), then Nginx (not trusted for content, trusted for availability), then the
client (verifies the signature). The monitor stands outside the chain and checks it.
**Basic assumption:** breaking into the CA server is outside what this system can defend against, because the attacker can sign by themselves.

### 16.1 Threat and protection

| Threat | Protection |
|---|---|
| forged CRL | the CA's signature (the client checks it); the monitor against pinned certificates |
| a file replaced in S3 | the uploader does not trust S3 and repairs any difference; the monitor alerts at once |
| an old CRL (replay or restore) | local state in the uploader; the high-water mark in the monitor |
| S3 key theft | DPAPI (only the account on the server); a key per CA and site, only its prefix, no Delete; versioning |
| anonymous write to the bucket | public for **reading only** (tested) |
| information disclosure | a bucket for CRLs only; Nginx hides internal headers and the CA server name |
| impersonating S3 to Nginx | `proxy_ssl_verify on` against the bundle, plus the name check (`proxy_ssl_name`) |
| access to other files through Nginx | only `.crl`, only GET and HEAD, blocking `..`, encodings, `//` and `\` |
| a compromised pod | non-root, read-only, drop ALL, seccomp, no API token |
| a compromised uploader | a gMSA without administrator rights; it cannot change the script or write to the source |
| changes to code or configuration | ACL on the folder (no code signing, 2026-11-02); **change detection is postponed until after the rollout** |
| a misleading silence | a dead man's switch in Splunk for both components |

---

## 17. Storage map: every setting and every secret

**Secrets register:** for each secret, record its name, location, who created it, and the date. **Never the value.** Secrets in the
cluster: `crl-fetch-s3` (sou, cen; creation date: ___) and `crl-monitor-hec`. Nginx has no secret, because the bucket is public for reading.

| What | Where | Who changes it |
|---|---|---|
| uploader script | `D:\CrlPublisher\Publish-Crl.ps1` | administrator |
| uploader configuration | `D:\CrlPublisher\config.json` | administrator |
| S3 keys | `D:\CrlPublisher\secrets\<site>.cred` (DPAPI) | the gMSA through `Protect-Secrets.ps1` |
| HEC token (uploader) | `D:\CrlPublisher\secrets\hec.token` (DPAPI) | the same |
| uploader state | `D:\CrlPublisher\state\published.json` | the uploader |
| uploader logs | `D:\CrlPublisher\logs\publish-crl-YYYYMMDD.log` | the uploader |
| scheduled task | Task Scheduler: `Publish-Crl` (source: `uploader/install/Publish-Crl.task.xml`) | administrator |
| CRL source | `D:\CrlPublish` (the CA's CDP) | the CA only |
| TLS trust on the CA server | the computer's certificate store: Trusted Root and Intermediate | administrator |
| Nginx configuration | Git: `serving/chart/crl-nginx/files/nginx.conf`, into ConfigMap `crl-nginx` | Helm |
| site values for Nginx | Git: `values-<site>.yaml`, into ConfigMap `crl-nginx` | Helm |
| CA bundle (Nginx and fetch) | Git: `common/ca-bundle.values.yaml` (`caBundle`; created inside the network), plus a copy in `files/ca-bundle.pem` in the chart, into ConfigMaps `crl-nginx-s3-ca` and `crl-fetch-ca` (key `ca.pem`) | Helm (Argo) |
| fetch targets | Git: `fetch/chart/crl-fetch/files/targets.yaml`, into ConfigMap `crl-fetch-config` | Helm (Argo) |
| S3 keys for fetch (write) | Secret `crl-fetch-s3` in each namespace (keys `accessKey`, `secretKey`). Git holds only the name | by hand in the console. Argo does not manage it |
| monitor configuration and CRL list | ConfigMap `crl-monitor-config` | `oc apply` |
| pinned CA certificates | ConfigMap `crl-monitor-ca` | `oc apply` |
| Splunk TLS chain for the monitor | ConfigMap `crl-monitor-tls` | `oc create configmap` |
| HEC token (monitor) | Secret `crl-monitor-hec` | `oc create secret` |
| monitor state | PVC `crl-monitor-state` | the monitor |
| buckets and S3 keys | the S3 system | the S3 team |
| DNS for publish1 and publish2 | the organisation's DNS | the network team |
| CDP addresses | the CA's settings (`certutil -getreg CA\CRLPublicationURLs`) and inside each certificate | the CA administrator |

---

## 18. Decision log and fixes since the start of the project

### 18.1 Architecture decisions

| Decision | Why | Rejected alternative |
|---|---|---|
| two independent sites; the uploader writes to both (ADR-0002) | a failure or corruption does not pass from one site to the other | S3 replication |
| the uploader discovers CRLs from the CA's folder (ADR-0005) | no manual list to maintain | a list in the configuration |
| the uploader in PowerShell on the CA (ADR-0006) | Windows and PSPKI already exist there; Python would add a runtime to the most sensitive server | Python on the CA |
| the monitor in Python on OpenShift, one file (ADR-0007) | the rest of the system runs on OpenShift; the cryptography library | PowerShell |
| trigger on event 4872, plus every hour | an emergency revocation within about 30 seconds, plus a safety net | a schedule alone, or the event alone |
| S3 is not trusted; repair by bytes | detects any replacement | trust in ETag or metadata |
| rollback protection from local state | S3 is not trusted, so the state cannot come from it | a number read from S3 |
| public bucket for CRLs, with an Nginx cache (ADR-0008) | a CRL is public; no key in Nginx; like AWS Private CA | a private bucket with signing, or rclone |
| one-minute cache, and stale on any error | an emergency revocation within a minute; availability when S3 fails | no cache, or a long cache |
| HTTP to clients | avoids the TLS-to-CRL loop | HTTPS |
| 3 fixed pods, no HPA | availability comes from the minimum; the load is small | HPA |
| the monitor in the other site | it does not fail together with what it checks | a local monitor |
| warning at 17 h, and 168 h for the Root | time to react; a signing ceremony for an offline Root | |
| `sites_diverged` kept | most CRLs are still on the old path | |
| Splunk as a dead man's switch | "silent" does not mean "healthy" | |

### 18.2 What was removed to simplify (at the owner's request: "I do not want things for nothing")

Uploader: validity checks, number reuse, bootstrap, read-back after upload, last-known-good and staging in S3, a mutex, the Event Log,
`-ValidateOnly`, the AKI and SKI check (only the CA writes to the source), a self-hash of the script ("not best practice"; change
detection will be designed after the rollout), and environment variables for secrets (2.2.0).
Monitor: the empty_body, content_type and crl_number_missing checks, extra commands, extra certificate formats, resolved events, mypy.
Consolidated into one file.

### 18.3 Fixes in order

| When | Component | What | Why, or what found it |
|---|---|---|---|
| design | monitor | the high-water mark per address | a test showed that a lagging site was wrongly taken for a replay |
| design | uploader | `.keys` on a hashtable | a PowerShell trap |
| 2026-10-21 | CA server | import the S3 root into Trusted Root | "could not establish trust" |
| 2026-10-21 | uploader 2.1.1 | the whole exception chain on every error | the question "why doesn't the script say why" |
| 2026-10-21 | uploader 2.2.0 | existence check without ListBucket (GetObject, and 404 or 403) | exit 3; least privilege |
| 2026-10-21 | uploader 2.2.0 | retries only for temporary faults | a 403 was retried three times for no reason |
| 2026-10-21 | uploader 2.2.0 | the server's answer in the error (for example "Incorrect index") | Splunk returned 400 with no reason in the log |
| 2026-10-21 | uploader 2.2.0 | `hec_failed` in the local log | a Splunk failure was only a warning on screen |
| 2026-10-21 | uploader 2.2.0 | secrets only with DPAPI; BigInteger; reads | simplification |
| 2026-10-21 | Pester tests | a root-level `BeforeEach` is not valid in Pester 5 | **the tests never ran**; found on the first run |
| 2026-10-21 | uploader | `$null = Import-Module` | extra output could break the exit code |
| 2026-10-21 | uploader 2.2.1 | the `state_missing` warning | an external review: deleting the state plus an old CRL means a silent rollback |
| 2026-10-21 | configuration | the HEC URL as in the old script (443) | "remote certificate is invalid": the request went to the wrong endpoint |
| 2026-10-21 | configuration | removed `hec.index` | the index `pki` did not exist, so events were dropped silently |
| 2026-10-22 | S3 | public bucket, tenant in the address | `NoSuchBucket` on an anonymous read |
| 2026-10-22 | Nginx | escaping of the backslash | it disabled the `//` block |
| 2026-10-22 | Nginx | one correct Content-Type | hiding it alone left no Content-Type |
| 2026-10-22 | Nginx | site values moved out of nginx.conf | at the owner's request; now in Helm |
| 2026-10-24 | Nginx | `worker_processes 2` | auto = one worker per node core |
| 2026-10-24 | Nginx | hiding `x-amz-meta-source-host` | the CA server name was exposed through the public bucket |
| 2026-10-24 | Nginx | `max_size 512m` | equal to the volume = risk of eviction |
| 2026-10-24 | Helm | full chart; `openshift.yaml` removed | one source; automatic update on change |
| 2026-10-24 | Helm | preStop + quit | **proven**: SIGTERM cuts requests |
| 2026-10-24 | Helm | 3 pods, PDB maxUnavailable 1, resources including ephemeral-storage, probe timeouts | availability; eviction |
| 2026-10-25 | Nginx | the cache stays an emptyDir (not a PVC as recorded in 19.10) | a PVC hurts availability when a node fails; clients already move between two sites (19.3b) |
| 2026-10-25 | Helm | Nginx NetworkPolicy removed | public content and no secret in the pods: restricting to the router added no real protection |
| 2026-10-27 | Argo CD | a "deployment registry" was considered (one ApplicationSet, an item for each component by site, the monitor as a Helm chart). **Rejected:** the monitor must have a failure domain separate from what it monitors. A broken template or commit in a shared ApplicationSet stops the deployments of Nginx and of the monitor together (a correlated failure). The rules for placement and pace of change also differ. Nginx = ApplicationSet; monitor = a separate Application under the same root. Reconsider a registry if more data path components are added | |
| 2026-10-27 | Argo CD | **AppProject not used**: the `default` project | the owner has no permission to create an AppProject; only his team uses this instance, so there is no other team to protect it from. The file is kept in `argocd/optional` |
| 2026-11-15 | Helm | **mounting files into a pod: directory versus file.** A volume that mounts a directory (`/etc/crl-fetch/config`, `/etc/crl-fetch/ca`) does not need `subPath`, and changes to the ConfigMap reach a running pod. A volume that mounts an **existing file** (`/etc/hosts`) needs `subPath`, because without it Kubernetes tries to mount a directory in its place. With `subPath` active, changes to the ConfigMap do not reach a running pod | in a CronJob every run is a new pod, so this makes no difference. Kept as an explanation for whoever adds files later |
| 2026-11-19 | Nginx | **Nginx also serves `.crt` (AIA) and `.xml`, not only `.crl`.** Content-Type by extension: `application/pkix-crl`, `application/pkix-cert`, `application/xml` | the owner confirmed that certificates and XML are public, so the rule "the public bucket holds CRLs only" does not apply to them. Changes: the location regex, the extension map, and the `run_tests.sh` checks. Not run yet |
| 2026-11-19 | CA | **with every new CA generation, publish a CRL by hand (`certutil -crl`) right after the renewal, before issuing from it.** | the CA's publishing cycle is scheduled, so the new generation's CRL may only appear at the end of the cycle. Without a CRL of the new generation, certificates issued from it cannot be checked for revocation. The manual publish raises event 4872, and the task uploads the CRL to S3 within minutes. The procedure was added to chapter 11 |
| 2026-11-19 | uploader | **the uploader also uploads CA certificates (AIA) from `certEnrollDirectory`, to the same `keyPrefix` and the same S3.** | the file name in the folder is `HOST_NAME.crt`, and the key is everything after the first underscore (`SERVER01_CA01.crt` becomes `CA01.crt`). The comparison is byte for byte, like the CRLs. A certificate does not enter the rollback state (it is meant for CRLs). A file that does not parse as X.509, or two files with the same name, is rejected. Version 2.4.0 |
| 2026-11-22 | CI | **the CI replaces the old tests (Pester and pytest) with static checks and a build, and adds the monitor.** | the old tests pointed to files that had been deleted (`build/Invoke-Checks.ps1`, `monitor/tests`), so the pipeline was broken. Now: lint for PowerShell (PSScriptAnalyzer and a syntax check) and Python (ruff), `helm lint` and `helm template` for each site, `kubeconform` on the output and on the monitor manifests, and the monitor image build (Kaniko) on the default branch only. Deployment stays outside CI: Argo CD for the charts, `oc apply` for the monitor. The pipeline has not run yet |
| 2026-11-22 | Monitor | **the monitor is a Helm chart (`monitor/chart/crl-monitor`), with a folder per site (`monitor/sites/sou`, `cen`), and is deployed through the same ApplicationSet as the other services.** | the raw YAML in `deploy/openshift` was not deployed by Argo CD and had no site parameter. Now there is an Application per site (`crl-monitor-sou`, `crl-monitor-cen`), and the NetworkPolicy is set per site from its own CIDRs. The secret stays out of Git |
| 2026-11-16 | Repo | **the path of the scheduled task file: `uploader/install/Publish-Crl.task.xml`** (not `deploy/windows/`). All references in the documentation were updated | the files were moved into `uploader/` on 11-09, but the documentation kept the old path. **Transfer of files:** the owner confirmed that XML files may be sent as plain text (not only as `.b64.txt`), because the transfer route was sorted out. The old rule still applies to PEM certificates |
| 2026-11-11 | fetch | **no `s3.keyPrefix` and no `S3_KEY_PREFIX`: the full path in the bucket is set for each target in `targets.yaml` (`key`)** | the owner's decision: there are many prefixes, so one prefix per site does not fit, and the script handles it. Removed from `values.yaml` and `cronjob.yaml`. **The script's responsibility:** write exactly to each target's `key`, and do not overwrite the files that the uploader writes (`mam/`, `ica/`) |
| 2026-11-11 | Helm | **single values for a pod: `env` directly in the template, not through a ConfigMap.** A ConfigMap is only for files | the result is the same, and a ConfigMap only adds an object. Its advantage (changing values without touching the deployment) does not matter in GitOps, nor in a CronJob, where every run is a new pod. Move to a ConfigMap only when there are ten variables or more, or several components that need the same values. The full rule: appendix A.8 |
| 2026-11-11 | Argo CD | **`preserveResourcesOnDeletion: true` stays, in the ApplicationSet's `spec.syncPolicy`. Checked and active** | **What it does:** the controller does not add `resources-finalizer` to the Applications it creates. So deleting the ApplicationSet deletes the Applications from Argo, but the resources in the cluster (Deployment, Service, Route, ConfigMaps) stay and keep running. When the ApplicationSet comes back, the Applications are created again and adopt the resources without a restart. **What it does not do:** it does not remove a marker that already exists on an Application. It does not protect against deleting an Application from the UI in Foreground or Background mode, because then Argo itself adds the marker just before deleting. **Deletion rules:** ApplicationSet: protected for every deletion mode, and the preferred way is `oc delete applicationset <name> -n <argo-ns> --cascade=orphan`. Application in the UI: **Non-cascading only**, unless the service really is being removed. **Check:** in the `publish-root` tree, open the Application, then Live Manifest, then `metadata.finalizers` (the Manifest tab shows only `spec`) |
| 2026-11-11 | Secrets | **creating `crl-fetch-s3`: by hand in the console, once in each namespace (sou, cen)** | Workloads, Secrets, Create, Key/value secret. Name `crl-fetch-s3`, keys `accessKey` and `secretKey` (the names are the defaults in the chart's `values.yaml`). **Why the console:** the values are not saved in the terminal's history, unlike `oc create secret --from-literal`. **The flow:** `existingSecret` in `fetch/sites/<site>/values.yaml`, then `secretKeyRef` in `cronjob.yaml`, then the environment variables `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, which the S3 library reads on its own. **Rules:** no label `app=crl-fetch` (the cleanup command deletes by label); no space or line break at the end of a value; Argo does not manage the secret, so Sync and Prune do not touch it; replacing keys means updating the secret, and the next run already uses the new ones (every run is a new pod), with no Sync needed; a missing secret stops the pod from starting (`secret not found`), on purpose. Recorded in the secrets register (chapter 17) |
| 2026-11-11 | fetch | **CA in the CronJob: all three variables stay** (`AWS_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`), all pointing to `/etc/crl-fetch/ca/ca.pem` | the owner's decision, to be safe: if a fetch target moves to HTTPS, its verification is already in place. `AWS_CA_BUNDLE` is needed in any case, for the upload to S3 over HTTPS. The fetch itself is HTTP on port 80 today. **Known caveat:** `SSL_CERT_FILE` replaces Python's whole certificate store. So an HTTPS target with a public-CA certificate will fail, unless its CA is added to the bundle in `common/ca-bundle.values.yaml` |
| 2026-11-11 | Argo CD | **(open, proposed) `applicationsSync: create-update` in the ApplicationSet, and `FailOnSharedResource=true` in the template** | `create-update`: deleting a `site.yaml` by mistake in Git does not delete the application. The cost: taking a site down really does require deleting the application by hand. Argo admins may need to allow this in the controller. `FailOnSharedResource`: the sync fails if a resource already belongs to another application, because two components now share a namespace. Considered and set aside for now: `Delete=false` or `Prune=false` on a single resource, `ignoreApplicationDifferences`, and `preservedFields` |
| 2026-11-11 | CA bundle | **two CA ConfigMaps in each namespace, on purpose:** `crl-nginx-s3-ca` and `crl-fetch-ca`, with the same content and from the same source | each chart is independent and holds its own ConfigMaps. Three alternatives were considered and rejected: (a) one ConfigMap that Nginx creates and fetch uses: fetch would depend on Nginx, and deleting or renaming Nginx's ConfigMap would break fetch. (b) both applications create a ConfigMap with the same name: Argo sees two applications on one object, and they overwrite each other. (c) a third application only for the ConfigMap: another chart and another application for one file. **The cost of the choice:** a few KB duplicated in the cluster, without double maintenance, because Git has one source. An update is one change in one file in `common/`, then Sync for both applications |
| 2026-11-11 | Argo CD | **incident:** deleting the ApplicationSet from the root tree also deleted the Deployment and the ConfigMaps in the cluster, despite `preserveResourcesOnDeletion` | **What the setting does (checked against the official documentation):** it sits in the ApplicationSet's `spec.syncPolicy`, and it stops the controller from adding `resources-finalizer.argocd.argoproj.io` to the Applications it creates. Without the marker, deleting an Application does not delete its resources. The setting does not remove a marker that already exists. **Possible causes:** (1) the setting was missing or in the wrong place in the version that ran; (2) the marker stayed on the Applications from before the setting, or from a deletion in the UI; (3) a behaviour of the Argo version. **Check:** `oc get applications -n <argo-ns> -o custom-columns=NAME:.metadata.name,FIN:.metadata.finalizers`. **Lesson:** to delete an ApplicationSet without touching what is under it: `oc delete applicationset <name> -n <argo-ns> --cascade=orphan`. But if a marker remains on an Application, deleting that Application later still deletes its resources. **Checked after recreation:** the setting is active, and the new Applications have no `finalizers`. So the marker was on the old Applications (created before the setting, or handled in the UI). **Rule:** in the UI, delete an Application only with Non-cascading, because a cascading deletion adds the marker and deletes the resources, even with the setting in place |
| 2026-11-09 | Argo CD | **generic name for the ApplicationSet: `crl-platform`** (file `argocd/apps/crl-platform-appset.yaml`), instead of `crl-nginx` | the ApplicationSet serves several components. The change creates a new object: the root deletes the old one (and with it its applications, while the resources stay thanks to `preserveResourcesOnDeletion`), and the new one creates the applications with the same names and adopts the resources. The owner deletes the old applications himself. Check afterwards: 4 Applications, and Nginx's pods were not restarted |
| 2026-11-09 | fetch | **new component, crl-fetch:** a full Helm chart (`fetch/chart/crl-fetch`) that creates an hourly CronJob (`17 * * * *`), which fetches CRLs from other publication points (`files/targets.yaml`) and uploads them to the site's bucket. Forbid (never two runs together), startingDeadline 10 min, activeDeadline 15 min, backoffLimit 1, history 3 and 3. Resources: CPU 100m/400m (ratio 4), memory 256Mi = 256Mi, disk 256Mi/512Mi. Hardening: runAsNonRoot, readOnlyRootFilesystem, drop ALL, no token. `fetch/app` was created with empty files (the code will come from the owner) | the owner's request. The same structure as serving: `<component>/chart/<chart>` and `<component>/sites/<site>`, so the relative paths are identical. Checked: rendering and kubeconform, and `required` stops without an image, without a CA, and without the secret name |
| 2026-11-09 | Argo CD | **one ApplicationSet for several components:** a generator with two paths (`serving/sites/*/site.yaml`, `fetch/sites/*/site.yaml`). The name `{{ .app }}-{{ .site }}`, the chart `{{ .chart }}`, and releaseName `{{ .app }}`. `app` and `chart` were added to each `site.yaml`. The ApplicationSet name stays `crl-nginx` | a rename would make Argo delete and create again. Nginx's output stays the same (`crl-nginx-sou`, release `crl-nginx`), so nothing was deleted or recreated. Checked by simulation: 4 unique Applications, all paths exist and stay inside the repo (B.12) |
| 2026-11-09 | CA bundle | **one source: `common/ca-bundle.values.yaml`** (`caBundle` at the top level, fixed from `s3.caBundle` on 11-09), passed to every component as the first values file. `ignoreMissingValueFiles: true`: until the file exists, each chart uses its own `files/ca-bundle.pem`, and with neither the chart stops (`required`). `.gitignore`: an exception for `**/files/ca-bundle.pem` | one copy in Git instead of one per chart. In the cluster there is still a ConfigMap per component (one owner per object, and a change reaches every component). A better option if available: a CA bundle that the OpenShift trusted-bundle injection provides (`config.openshift.io/inject-trusted-cabundle`), to be checked with the cluster administrators. The file contains PEM, so it is created inside the network |
| 2026-11-09 | Secrets | **secrets are created and managed in the cluster, not in Git:** the chart holds only the name (`s3.existingSecret: crl-fetch-s3`) and a `secretKeyRef` for the environment variables `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. There is no Secret YAML file | **good:** no secrets in Git, Argo does not touch them (it neither deletes nor overwrites them), and a missing secret fails loudly (`CreateContainerConfigError`). **Downsides:** not declarative. In DR or on a new cluster they must be created again by hand, and replacing them is manual, with no history. **Compensation:** record for each secret its name, namespace, keys, who creates it and when it is replaced (never the value). Long term: External Secrets from an organisational vault, if one exists |
| 2026-11-08 | Argo CD | **the monitor goes into the same ApplicationSet** as the other services, once the generator moves to the services structure. This changes the earlier rule ("monitoring always outside the ApplicationSet") | the owner's decision. **The risk the old rule protected against:** a failure in the ApplicationSet (a broken template, a corrupt site file) also stops the monitor. **The coverage:** monitoring of the monitor. The monitor sends a heartbeat to Splunk on every run, and a dead-man alert in Splunk fires when the heartbeat disappears. Splunk is outside Argo, so the alert works even when the monitor itself is not running |
| 2026-11-03 | Uploader 2.3.0 | **secrets in clear text directly in the configuration file, optional.** For each site: `accessKey` and `secretKey` (if present, `credentialFile` is ignored). For Splunk: `hec.token` (if present, `tokenFile` is ignored). Without these fields: DPAPI as before | the owner's request: deploy on many networks without the encryption step, which must run under the account of the uploader. **The risk:** the secrets are readable by anyone who reads `config.json`. **Protections:** (1) every run writes `warn plaintext_secrets` (with the site names, not the values) to the log and to Splunk. (2) An ACL on `config.json`: Administrators and the uploader's account only. (3) **A configuration file with secrets does not enter Git** (Git holds only `config.example.json`). **Exit condition:** at the end of the rollout, run Protect-Secrets.ps1 for each CA, remove the fields from the configuration, and check that the warning is gone. Tested: 38 Pester tests (5 new) and a run with a configuration file holding visible secrets. Earlier that day a mode with a flag and separate visible files was tried and dropped |
| 2026-11-02 | Uploader | **no code signing.** In the Task: `-ExecutionPolicy Bypass` instead of `AllSigned`. The script and the configuration are protected by **an ACL on `D:\CrlPublisher`**: Administrators = Full, the uploader's account = Read and execute on the script and the configuration, Modify only on the state and log folders. Nobody else writes there | the execution policy is **not a security boundary** (anyone can run `-ExecutionPolicy Bypass`). The only benefit of AllSigned: the Task refuses to run a script that was changed. But whoever can change the script while the ACL is correct is already an administrator, and can change the Task itself too. The cost: a code-signing certificate, and re-signing on every change. Bypass rather than RemoteSigned: a file that was transferred is sometimes marked as downloaded, and RemoteSigned blocks it silently |
| 2026-11-02 | structure | **one network, one namespace, two sites: sou = production, cen = DR.** An ApplicationSet with a simple generator (`serving/sites/*/site.yaml`), two Applications (`crl-nginx-<site>`), release `crl-nginx`, one values file per site. The network folders and the network list were removed | the owner's decision. A matrix was unnecessary with no two lists to combine. An ApplicationSet rather than two plain Applications: production and DR are the same thing with different values, a shared change (such as a sync policy) lives in one place, and a new site = one folder. **Learned on the way:** the same host on several Routes on one router is refused (`HostAlreadyClaimed`), even across namespaces. It is possible only with a separate router (shard) for each network. The owner's cluster has a router for each namespace |
| 2026-11-02 | Argo CD | **manual sync** for the six Nginx applications: `automated` (prune, selfHeal) removed from the ApplicationSet's template. The root stays automatic | the owner's request: check changes before they apply. The applications are still created and deleted according to Git, but they do not deploy until Sync is pressed. **The trade-off:** no self-heal (a manual change in the cluster stays until the next sync), each relevant change needs a click on each application, and prune happens only when chosen. Rejected: changes made in the UI (the ApplicationSet reverts any change to its applications), and `ignoreApplicationDifferences` on `/spec/syncPolicy` (allows enabling and disabling per application in the UI; needs Argo 2.9 or later; an option for later) |
| 2026-11-02 | Repo | the chart folder: **`serving/chart/`** (singular), as in GitLab. The path in the ApplicationSet: `path: serving/chart/crl-nginx` | the error `app path doesn't exist`: the path in the ApplicationSet was plural, and the folder in GitLab is singular. **The rule:** the path in the ApplicationSet must match the folder in GitLab exactly. `../../sites/...` in valueFiles is not affected |
| 2026-11-01 | Argo CD | **a matrix generator** instead of git files two levels deep: `serving/sites/*/site.yaml` (one file per site: site, cluster, namespace) × a list of networks (ai, bi, ci). The result is the same: 6 Applications with the same names | before this, the cluster and the namespace were written three times for each site (6 identical site.yaml files except for the network), and one wrong file would deploy a network to the wrong place. Now they are written once. **Downside accepted:** every network must exist in every site. A network that exists in only one site needs an exception (a separate generator or a selector). Checked: valid schema, the matrix simulation gives 6 unique names, and all values files exist |
| 2026-11-01 | OpenShift | **keep one project (namespace) per site**, for the three networks. Re-examined against 3 projects | enough as long as: (1) the routers of the networks are not split by namespace, (2) no security or regulatory requirement demands separation, (3) nobody needs access to one network only. **Moving to 3 projects is cheap:** in Git only the `namespace` changes in the six `site.yaml` files (the chart is already release-aware). Outside Git: the namespace, quota and RoleBinding for each network in each site, and the destinations in the optional AppProject |
| 2026-11-01 | Argo CD + Helm | **option A chosen:** an Application for each combination of site and network (6), from one ApplicationSet. A Helm release for each network (`crl-nginx-ai/bi/ci`), all three in the site's namespace. Generator: `serving/sites/*/*/site.yaml`. Name: `crl-nginx-<site>-<network>`. Values files in two layers: `sites/<site>/values.yaml` (the storage server, the tenant), then `sites/<site>/<network>/values.yaml` (bucket, route address) | separate failures: sync, status and rollback for each network. The chart has no loops. Rejected: one application per site with a loop in the chart, or with several sources (a mistake in one network stops all three, and the chart gets more complicated). A shared structure with different values = one ApplicationSet (chapter 0) |
| 2026-11-01 | Helm | the chart is release-aware: every resource name is `{{ .Release.Name }}` (and `-s3-ca`), and the label `app.kubernetes.io/instance: {{ .Release.Name }}` was added to the labels and selectors of the Deployment, Service, PDB and anti-affinity | without it, three networks in one namespace clash on names, and one network's Service picks up another network's pods (requests go to the wrong bucket). Checked with chart_test.sh: no shared name, each selector catches only its own network, and both the site values and the network values apply |
| 2026-11-01 | OpenShift | quota for each site's namespace (3 networks). When the chart is updated, Argo updates all three networks together: 3×(3+1) = 12 pods. requests: CPU 3, memory 3Gi, disk 12Gi. limits: CPU 12, memory 3Gi, disk 24Gi. pods: 12 | a smaller quota only delays the rollout (`maxUnavailable: 0`); it does not take the service down. The earlier quota (10 pods, CPU 1) is not enough for three networks |
| 2026-11-01 | cleanup | the deployment on the test site (`crl-nginx-sou` in `crl-serving-test`) stays after the old site.yaml is removed, because of `preserveResourcesOnDeletion`. **It must be deleted by hand** (or its namespace). A Deployment selector is immutable, so it could not have been moved in any case | a one-time step |
| 2026-11-01 | sites | the production sites are **sou** and **cen** (instead of the names shay and guy used in the design). **The test site was cancelled**, and work goes directly on production. Each site has 3 networks: **AI, BI, CI**. Each network has its own CA and its own bucket in the site's storage | the owner's decision. The structure per network (one application per network versus one application per site) **is still open**. One namespace per site, with 3 deployments (agreed 2026-11-01). The existing `crl-nginx-sou` deployment in `crl-serving-test` will be removed or moved once the structure is decided |
| 2026-10-29 | S3 | an incident in the test deployment: Nginx returned STALE and then 403. The cause: the test bucket was not public for reading. After it was made public, it works | **remember:** a 403 comes only from the storage, because Nginx itself never returns 403. Nginx returns 404 itself for any address that does not match the CRL pattern (in the log: empty cache and s3Status `-`). Without the List permission, storage returns 403 even for a key that does not exist. A public bucket = **CRLs only** |
| 2026-10-29 | transfer | after every manual copy of a configuration file, check **non-ASCII characters** too, not only the signature: `Select-String -Path <file> -Pattern '[^\x00-\x7F]'`. For our files (nginx.conf, YAML) the result must be **zero** lines | an incident: Nginx returned `unknown directive` for `worker_processes` on line 15, although the word looked correct. The likely cause is a hidden character from copying in a Hebrew-locale environment (a non-breaking space, a direction mark, a zero-width character). A signature check that ignores whitespace **does not catch** a non-breaking space. The original nginx.conf is ASCII only |
| 2026-10-29 | OpenShift | memory: request = limit = **256Mi** (it was 128Mi/256Mi) | the cluster's policy requires a 1:1 ratio for memory. We raised the request and did not lower the limit: Nginx uses tens of Mi, and the cache is on disk (an emptyDir without medium Memory), so 256Mi leaves a margin against OOMKill. **Quota during the rollout:** requests 4×256Mi = 1Gi = exactly the quota, limits 1Gi out of 2Gi. A side benefit: with request = limit, the pod is not the first to be evicted under node memory pressure |
| 2026-10-29 | OpenShift | the CPU request rose from 100m to **250m** (the limit stayed at 1) | the cluster has a LimitRange with a maximum limit/request ratio of 4. It was 1/100m = 10, so it was refused. 250m gives a ratio of 4 and keeps a full core for bursts. Memory (2) and disk (2) already met the conditions. **Quota:** during a rollout there are 4 pods (maxSurge 1): requests 4×250m = 1 = exactly the quota, limits 4×1 = 4 = exactly the quota. There is no margin, but with `maxUnavailable: 0` an excess only delays the rollout; it does not take a service down. The rejected alternative: a limit of 400m (a quota margin, but throttling under load after NextUpdate) |
| 2026-10-28 | Repo | (cancelled 2026-11-02) the chart folder in the plural, `serving/charts/` | replaced: in GitLab the folder is called `serving/chart/` |
| 2026-10-28 | Image | **open:** the image `ubi9/nginx-124:latest` must be frozen to a fixed version tag (or a digest) and come from the internal registry. Download from outside the network: `crane pull --platform linux/amd64 ... nginx-124.tar`, and check the SHA-256 after transfer | `latest` means every pull may bring a different version. The deployment is not reproducible. Waiting for the choice of an internal registry |
| 2026-10-27 | Argo CD | no webhook from GitLab, polling only (about 3 minutes) | a small delay in deploying a configuration change does not affect the CRL service. Fewer settings to maintain. A webhook can be added later (B.8) |
| 2026-10-27 | Argo CD | the name of the main Application: `publish-root` | the owner's request: `publish-root` is easily confused with a root CA or CRL. The name does not affect any other file (no object refers to it) |
| 2026-10-27 | Argo CD | **the test is also deployed in the production shape** (the owner's decision): root + AppProject `crl` + ApplicationSet; `site.yaml` in each site folder says which cluster and namespace; `preserveResourcesOnDeletion` means that deleting a folder by mistake does not take down the running Nginx | the same way in testing and in production = what was tested is what goes live |
| 2026-10-27 | Argo CD | Nginx and the monitor are **not** in the same ApplicationSet (the monitor is different and runs in one site: a plain Application); **yes** under the same root and the same AppProject; **yes** in the same repo (one system, one team, one change touches several components; each Application looks only at its own folder) | |
| 2026-10-27 | Argo CD | (updated: a **central** Argo manages both sites) the test: a single Application in `default`. Production: one root (app of apps) that contains the AppProject `crl`, an **ApplicationSet** for Nginx (an Application for each folder under `serving/sites/`, each going to its site's cluster), and an Application for the monitor | the Applications themselves are in Git and managed by Argo (no Application created by hand in the UI and forgotten); a new component = a commit; the AppProject limits the repo and the namespaces |
| 2026-10-26 | OpenShift | quota for each site: CPU 1/4, memory 1Gi/2Gi, disk 4Gi/8Gi, pods 10 (7.7) | the calculation: 4 pods plus a margin for diagnosis and a stuck update; disk to be reduced after measurement |
| 2026-10-25 | Helm | the CA bundle moved to `files/ca-bundle.pem` in the chart (the organisation bundle) | the same for all sites: one file to maintain; a site can override with `s3.caBundle` |
| 2026-10-25 | Helm | CPU limit 1 | the cluster's policy requires a limit; a full core so there is no slowdown under load |
| 2026-10-24 | monitor | HEC on 443, the CA bundle, NetworkPolicy on 443 | sending to Splunk would have failed |

### 18.4 What has actually been tested

| Component | Test | Result |
|---|---|---|
| Uploader | Pester (PowerShell 7, Pester 5.6.1) | 33/33 |
| Uploader | a full run with mocked modules | DryRun, published, unchanged, 403, 400 from Splunk |
| Uploader | **the CA server, the test bucket** | DryRun, published, unchanged, self-repair, junk rejected, events in Splunk |
| S3 | anonymous read and anonymous write | 200 and AccessDenied |
| Nginx | 33 behaviour checks against a mocked S3 | 33/33 |
| Nginx | shutdown | SIGTERM gives 000, quit gives 200 |
| Helm | rendering, kubeconform, `nginx -t`, missing values | passes (the Route checked by hand) |
| monitor | pytest and ruff | 32/32 |

**The project is not considered DONE until all 13 failure drills in chapter 15 have been run and observed in Splunk** (the owner's requirement, 2026-10-25).

**Not yet tested:** the uploader on Windows PowerShell 5.1 with PSScriptAnalyzer; a real `helm lint`; Nginx on OpenShift;
`+` against the real S3; the monitor on OpenShift; the Splunk alerts.

---

## 19. Remaining risks, open decisions, remaining work

### 19.1 The six risks

1. **A single CA.** Unavailable for longer than the CRL's validity means no layer helps. What exists: a warning 17 hours before.
2. **The uploader runs only on the CA.** Covered by the 75-minute alert.
3. **Nginx cache per pod, deleted on restart.** S3 down plus a restart means that pod does not serve; the others and the other site do.
   **Accepted as a risk (2026-10-25):** the emptyDir stays; see 19.3b.
4. **DNS for publish1 and publish2.** A wrong record bypasses every layer. An option: monitor DNS.
5. **CRLs on the old path.** The monitor sees gaps, but does not fix them.
6. **An offline Root.** No component signs on your behalf; the week-long warning is the only protection.

### 19.2 Open decisions

- `applicationsSync: create-update` and `FailOnSharedResource=true` (proposed 2026-11-11).
- `not_yet_valid` in the monitor: keep it or drop it.
- Change events in the monitor's list: keep them or drop them.
- How the CRL list gets into the ConfigMap.
- Change detection for code and configuration (uploader, configurations, images, ConfigMaps, S3): after the rollout.

### 19.3 Remaining work

- **Monitoring of fetch (the owner's request, 2026-11-11): know whether fetch has stopped sending.** Remind the owner when the monitoring and the Splunk alerts stage is reached.
- Nginx in the test (OpenShift), and a check of `+` against the real S3.
- Make sure OpenShift logs reach Splunk; images in an internal registry, pinned by digest.
- Uploader: Pester and PSScriptAnalyzer on 5.1; gMSA, ACL, CDP to `D:\CrlPublish`, audit for 4872.
- Delete the personal secrets from the server; **replace the HEC token that was exposed**.
- The monitor: image, a test project, ConfigMaps (list, certificates, bundle).
- Splunk alerts (chapter 9, chapter 11 step 6), including the pod health alerts from events.
- **Future:** Prometheus for state alerts (ready pods), instead of events alone.
- A production S3: a dedicated public bucket, versioning, a key for each prefix.
- Update `rollout.md` at the Nginx stage.

### 19.3a Monitor improvements (the owner's request, 2026-10-25)


| # | What | Why | Status |
|---|---|---|---|
| MON-1 | Pod health alerts from OpenShift events (BackOff, probes, FailedScheduling, image pull) | the monitor only sees "is it serving", not "how much redundancy is left" | planned (chapter 9) |
| MON-2 | Move to Prometheus and Alertmanager, with alerts into Splunk (`ready < desired`, `KubePodCrashLooping`) | alert on state, not on events | later |
| MON-3 | DNS monitoring of publish1 and publish2 | risk 4: a wrong record bypasses every layer | open |
| MON-4 | Nginx access logs in Splunk: rate of 404, 5xx and STALE per site | trends before a fault; strengthens `stale_cache` | confirm forwarding |
| MON-5 | Measure the distribution time (publish, then S3, then served) | the target "up to 5 minutes" is not measured | open |
| MON-6 | Alerts for the uploader and the monitor (chapter 9): actual configuration in Splunk | the dead man's switch does not exist yet | step 6 |

### 19.3b Decision: Nginx cache stays an emptyDir (2026-10-25)

On 2026-10-19, "cache on a PVC" was recorded. An emptyDir was built, and the deviation was not marked at the time. Four options
were considered, and the owner decided: **emptyDir**.
- **Reasoning:** the scenario (a site's S3 is down **and** a pod restarts) affects only the empty pod. The other two pods in the site keep
  serving STALE, and a client that gets an error moves to the second CDP address, an independent site with its own S3. Clients that
  already stored a CRL are not affected.
- **Rejected:** a PVC for each pod (an RWO disk gets stuck on a node that failed: minutes in which the pod cannot start anywhere, which hurts
  availability); the other site's S3 as a backup (closes the scenario, but creates a read dependency between the sites, which is unnecessary
  when the client already moves between them); a shared RWX cache (Nginx does not support several processes on the same cache directory).
- **What is still to verify:** that a Windows client moves to the second address when the first returns an HTTP error (part of drill D13).

### 19.4 Open questions (updated)

| # | Question | Status |
|---|---|---|
| Q1 | Is this solution better than an improved IIS/DFS? | no comparison was recorded (gap 7) |
| Q2 | The S3 product and its SLA | multi-tenant (most likely Ceph RGW); SLA unknown |
| Q3 | Sidecar, caching proxy, or CronJob | **decided**: Nginx caching proxy (ADR-0008) |
| Q4 | Frequency and freshness | **decided**: one minute, plus revalidate |
| Q5 | The uploader's trigger | **decided**: event 4872 plus hourly |
| Q6 | Is delta CRL active on the CA | a `+` is in the list; verify on every CA |
| Q7 | Keeping the CDP addresses in existing certificates | **verified**: publish1 and publish2 |
| Q8 | Does Windows move between CDP addresses | **not tested** (drill D13) |
| Q10 | Success metrics (publish times, availability) | proposed targets, not approved (2.2) |
| Q11 | PowerShell version and execution policy on the CA | 5.1 in practice; in the Task: `Bypass` (no signing, 2026-11-02) |
| Q12 | Delivering AWS.Tools to the CA | installed on the test server; the approval process for production is open |
| Q13 | Universal Forwarder on the CA | not needed (direct HEC) |
| Q14 | A GitLab runner with PowerShell | open |
| **Q15** | **DR of the CA**: recovery time, the same keys, and does the CRL number keep rising after a restore | **open and important**: if the number drops, the uploader refuses (R-04) |
| **Q16** | **The uploader on the DR CA**: installed? What guarantees that only one runs? | **open**: two uploaders with separate state means a conflict |

### 19.5 Assumptions that have not been verified

1. Windows moves to the second CDP when the first returns a broken CRL (not only when it does not answer).
2. The real S3 treats `%2B` as `+` in a path.
3. The OpenShift router stops sending to a pod that is going down in less than 10 seconds (the `sleep 10` in preStop).
4. OpenShift logs reach Splunk.
5. The uploader is clean under PSScriptAnalyzer and passes Pester on Windows PowerShell 5.1 (tested on 7).
6. A real `helm lint` passes (checked with a local renderer and kubeconform).
7. The Route was checked by hand (there is no public schema).
8. Splunk's TLS certificate includes an AKI (important for an upgrade to Python 3.13 or later).
9. File names with brackets (`(1)`) pass correctly through Nginx and S3 (allowed by the regex; not tested against S3).

### 19.6 Gaps from the old list that are still open

- **A written threat model:** chapter 16 is the base; to be approved with security.
- **Measuring the distribution time:** not done yet.
- **The CI does not run the serving tests** (nginx, chart): add a job.
- **Two write keys (both sites) on the CA:** a break-in to the CA means writes to both sites. Accepted as a risk: a key per prefix,
  no Delete, versioning, and the CA is Tier 0 anyway.
- **Old CRLs and delta names on a real CA:** run discovery on a copy of a real CertEnroll folder.

---

## 20. Operation and fault diagnosis

**The first tool:** `curl -sI http://publish1.com/<path>.crl`

| `X-Cache-Status` | Meaning |
|---|---|
| `HIT` | from the cache, everything is fine |
| `MISS` | it was not cached; it was fetched from S3 |
| `REVALIDATED` or `UPDATING` | checked with S3, or updating in the background |
| `STALE` | **S3 is not reachable**: check S3, the bundle, and the network |

**Nginx:** `oc logs deploy/crl-nginx`, in the fields `status` (what the client got) and `s3Status` (what S3 returned).
- 404 for the client but the file is in S3: tenant, bucket, or path (`keyPrefix` against the URL).
- 502 or STALE for everything: TLS to S3. A root or intermediate is missing from `files/ca-bundle.pem`.
- A pod does not start: `oc logs` shows the `nginx -t` error or S3's DNS failure.

**Uploader:** the local log, lines that are not `info`:
```powershell
Get-Content "D:\CrlPublisher\logs\publish-crl-$(Get-Date -Format yyyyMMdd).log" | ConvertFrom-Json |
  Where-Object level -ne 'info' | Format-List timestamp, event, site, key, live, httpStatus, error
```
A manual run: `.\Publish-Crl.ps1 -ConfigPath <config> -DryRun; $LASTEXITCODE` (it reads and compares, and does not write).
In production, run it through the Task: `schtasks /run /tn Publish-Crl` (this prevents a double run).

**Splunk:** `index=* sourcetype="crl:publisher"` or `sourcetype="crl:monitor"`; for one run: `index=* "<runId>"`.

**Emergency revocation:** revoke, then `certutil -crl`, then the uploader runs within about 30 seconds, then Nginx serves within a minute,
then the monitor confirms the new number at both addresses. Only then, on critical servers: `certutil -urlcache crl delete`.

---

## 21. File inventory

| File | Role |
|---|---|
| `README.md` | entry point; points to the system dossier |
| `src/Publish-Crl.ps1` | the uploader (2.2.1 in this dossier; see the note in the header) |
| `src/config.example.json` | template for `config.json` |
| `uploader/install/Publish-Crl.task.xml` | the Scheduled Task definition |
| `uploader/install/Protect-Secrets.ps1` | creating the DPAPI files as the gMSA |
| `tests/Publish-Crl.Tests.ps1` | 33 Pester tests (S3 mocked in memory); removed from the repository on 2026-11-22 |
| `tests/fixtures/` | CRLs and certificates generated with openssl (valid, broken, delta, EC, key generations); `manifest.json` |
| `tools/generate-fixtures.sh` | generates the fixtures (temporary keys, deleted afterwards) |
| `build/Invoke-Checks.ps1` | PSScriptAnalyzer and Pester; removed on 2026-11-22 |
| `PSScriptAnalyzerSettings.psd1` | analysis rules |
| `.gitlab-ci.yml` | CI: lint, validate and build (see 18.3, 2026-11-22) |
| `monitor/crl_monitor.py` | the monitor (1.1.0) |
| `monitor/tests/` | 32 pytest tests (PKI in memory and the fixtures); removed on 2026-11-22 |
| `monitor/requirements.txt`, `pyproject.toml` | dependencies with hashes; ruff |
| `monitor/Dockerfile` | the image (UBI python-312, non-root, `--require-hashes`) |
| `monitor/chart/crl-monitor/templates/configmap.yaml` (values in `values.yaml`) | configuration, CRL list, CA certificates |
| `monitor/chart/crl-monitor/templates/cronjob.yaml`, `pvc.yaml` | PVC and CronJob |
| `monitor/chart/crl-monitor/templates/networkpolicy.yaml` | restricted egress |
| `monitor/deploy/secret.example.yaml` | example of the HEC Secret (not applied) |
| `serving/chart/crl-nginx/` | Helm chart: `Chart.yaml`, `values.yaml`, `values-sou.example.yaml`, `files/nginx.conf`, `templates/` |
| `serving/tests/run_tests.sh` and `fake_s3.py` | 33 behaviour checks of nginx.conf against a mocked S3 (HTTPS) |
| `serving/tests/shutdown_test.sh` | proves the need for preStop |
| `serving/tests/chart_test.sh` and `helmlite/` | chart rendering, kubeconform, `nginx -t`, missing values |
| `docs/system-dossier.md` | **this document** |
| `docs/cheat-sheet.md` | one page: principles, numbers, diagnosis order |
| `argocd/root.yaml` | the root (app of apps), created by hand once |
| `argocd/optional/appproject.yaml` | AppProject `crl`: **not in use** (no permission; the team's instance only). For the future |
| `argocd/apps/crl-platform-appset.yaml` | the ApplicationSet: Nginx, fetch and monitor for each site |
| `serving/sites/<site>/site.yaml`, `values.yaml` | where to deploy, and the site's settings |
| `docs/adr/0001` to `0008` | architecture decisions |
| `docs/design-uploader-and-monitor.md` | detailed design and the Definition of Done |
| `docs/rollout.md` | the rollout steps (original; chapter 11 here is updated and complete) |
| `docs/uploader.md`, `monitor/README.md`, `serving/README.md` | guides for each component |
| `docs/readiness-gaps.md`, `docs/open-questions.md` | gaps and questions (summarised in chapter 19) |
| `docs/next-session.md` | the work log between sessions |
| `docs/documentation-rule.md` | the documentation requirement |

---

## 22. Glossary

| Term | Meaning |
|---|---|
| CA / AD CS | certification authority; the Windows certificate service |
| CRL | a list of revoked certificates, signed by the CA |
| Base / Delta CRL | the full list / only the changes since the base (the name has a `+`) |
| CRL Number | a running number that rises with every publication |
| ThisUpdate / NextUpdate | when the CRL was created / until when it is valid |
| CDP | the address in a certificate from which the CRL is downloaded |
| AIA | the address in a certificate from which the issuer's certificate is downloaded (Windows uses it; Nginx does not) |
| AKI / SKI | the key identifier of the issuer / of the certificate itself |
| OCSP | an online revocation check, per certificate (an alternative to CRL) |
| Root offline | a root CA disconnected from the network; its CRL is signed in a manual ceremony |
| replay | serving an old CRL again |
| high-water | the highest number seen so far |
| DPAPI | Windows encryption tied to the account and the machine |
| gMSA | a managed service account in the domain, with no password to handle |
| S3 / bucket / key / prefix | object storage / container / object name / path prefix |
| tenant | an "account" in a shared S3 system; a separate namespace |
| path-style | the address `endpoint/bucket/key` (compared with `bucket.endpoint/key`) |
| SigV4 | signing S3 requests with an access key and a secret |
| OAC | in AWS: the permission that lets CloudFront read a private bucket |
| CDN | a cache network in front of the content origin |
| HEC | Splunk's HTTP Event Collector |
| index / sourcetype | where data is stored / the type of event in Splunk |
| dead man's switch | an alert on the **absence** of a report |
| cache / TTL | a stored copy / how long it stays fresh |
| revalidate / 304 | the "has it changed?" check / the "not changed" answer |
| stale | a copy that is no longer fresh, served when the origin is not available |
| SNI | the server name sent when a TLS connection opens |
| pod / node / Deployment | a running container / a server in the cluster / the definition that keeps N pods |
| Service / Route | a fixed internal address / an external address (the router) |
| ConfigMap / Secret | configuration / secrets, attached to the pod as files |
| PVC / emptyDir | a persistent disk / a temporary disk deleted with the pod |
| readiness / liveness probe | "ready to take requests?" / "still alive?" |
| preStop / SIGTERM | an action before shutdown / the shutdown signal OpenShift sends |
| PDB | how many pods may be taken down during planned maintenance |
| HPA | automatically adding pods according to load |
| anti-affinity | spreading pods across different nodes |
| requests / limits | guaranteed resources / the maximum |
| ephemeral-storage | the node disk that the pod uses |
| NetworkPolicy | a firewall between pods |
| Helm / chart / values | a package manager / the template / the values for each environment |
| digest | the unchangeable identifier of an image (`@sha256:...`) |
| kubeconform | checks YAML against the Kubernetes schema |
| Pester / PSScriptAnalyzer | tests / static analysis for PowerShell |

---

## Appendix A. YAML and Helm: how to read the deployment files

### A.1 The five rules of YAML

```yaml
name: crl-nginx              # 1. key: value
labels:                      # 2. indentation = "inside" (spaces only, never a tab)
  app: crl-nginx
ports:                       # 3. a dash = an item in a list
  - name: http
    containerPort: 8080
resources: {cpu: 100m}       # 4. the same on one line: {} for maps, [] for lists
data:
  nginx.conf: |              # 5. | = multi-line text, kept as it is
    worker_processes 2;
---                          # separates two objects in one file
```
`#` starts a comment. Wrong indentation changes the meaning or breaks the file. It is the most common mistake.

### A.2 The skeleton of every object

```yaml
apiVersion: apps/v1     # the API version that defines the kind
kind: Deployment        # the kind
metadata:               # who it is: name, labels, annotations
  name: crl-nginx
spec:                   # the desired state
  replicas: 3
```
**`spec` is a desired state, not a command:** you write "3 pods", and OpenShift makes sure there are always 3.

### A.3 How the objects find each other

```
Route ──(name crl-nginx)──► Service ──(label app=crl-nginx)──► Pods ◄── the Deployment creates them with the label
PDB ──(label)──► Pods          Pod ──(name)──► ConfigMap crl-nginx / crl-nginx-s3-ca
```
There is no direct link: names and labels. A wrong label on a pod means the Service does not find it, which is an error for clients.
That is why all the labels come from one place (`crl-nginx.labels` in `_helpers.tpl`).
`volumes` defines "a disk called X and where its content comes from"; `volumeMounts` defines "where to show X inside the container".
The name connects them.

### A.4 Helm syntax

| Syntax | What it does | In our files |
|---|---|---|
| `{{ .Values.x }}` | a value from values | `replicas: {{ .Values.replicas }}` |
| `{{ include "n" . }}` | a fragment from `_helpers.tpl` | labels, the prepared nginx.conf |
| `\| nindent 4` | a new line with an indent of 4 | puts the fragment in place |
| `required "msg" .Values.x` | stops if empty | `s3.host`, `s3.caBundle` |
| `\| quote` | quotation marks | `cpu: "100m"` |
| `\| sha256sum` | a fingerprint | the checksum that rolls pods |
| `{{- with .Values.x }}...{{- end }}` | only if there is a value | `route.host`, `limits.cpu` |
| `{{-` and `-}}` | removes the whitespace around | clean YAML |
| `.Files.Get "files/nginx.conf"` | reads a file from the chart | nginx.conf |
| `\| replace "A" "B"` | replaces text | host, tenant, bucket |

### A.5 The files of the chart

| File | Content |
|---|---|
| `Chart.yaml` | name, version (raise it on every change), nginx version |
| `values.yaml` | every setting with its default |
| `values-<site>.yaml` | the site's values; overrides `values.yaml` |
| `templates/_helpers.tpl` | reusable fragments (not rendered: the name starts with `_`) |
| `templates/configmaps.yaml` | `crl-nginx` (the prepared nginx.conf) and `crl-nginx-s3-ca` (`ca.pem`) |
| `templates/deployment.yaml` | replicas, strategy, checksums, security, affinity, command, preStop, probes, resources, volumes |
| `templates/network.yaml` | PDB, Service, Route |
| `files/nginx.conf` | not YAML: Nginx's configuration file |

The order inside a Deployment: `replicas`, then `selector` (which pods are "mine"), then `strategy`, then `template` (the template for each pod:
labels, annotations, securityContext, affinity, containers [image, command, ports, lifecycle, probes, resources, securityContext, volumeMounts],
volumes).

### A.6 The monitor files (plain YAML, `oc apply`)

| File | Content |
|---|---|
| `configmap.yaml` | `crl-monitor-config` (`config.yaml` and `crl-list.txt`), `crl-monitor-ca` (`<ca>.pem`) |
| `cronjob.yaml` | a PVC for the state (survives between runs), and the CronJob: `schedule "*/5 * * * *"` (minute, hour, day of month, month, day of week), `Forbid`, `backoffLimit 0`, `activeDeadlineSeconds 240`, the pod |
| `networkpolicy.yaml` | egress only: DNS, publish1 and publish2, Splunk. **By IP**: replace the examples |
| `secret.example.yaml` | an example only; the Secret is created with a command, so the token is not saved in a file |

### A.7 Commands

| What | Command |
|---|---|
| install or update Nginx | `helm upgrade --install crl-nginx <chart> -f ../../sites/<site>/values.yaml` |
| see the final YAML without applying | `helm template crl-nginx <chart> -f ../../sites/<site>/values.yaml` |
| check | `helm lint` with the same parameters |
| go back to a previous version | `helm history crl-nginx`, then `helm rollback crl-nginx <rev>` |
| the monitor | `oc apply -f configmap.yaml -f cronjob.yaml -f networkpolicy.yaml` |
| see what runs | `oc get deploy,pods,svc,route,pdb -l app=crl-nginx` |
| a whole object | `oc get deploy crl-nginx -o yaml` |

---

### A.8 Value, ConfigMap, env, or Secret: how to decide (2026-11-11)

**They are not alternatives.** A value is an input to the chart: it exists only in Git and while Helm builds the YAML, and the pod never sees it.
A ConfigMap, an environment variable, and a Secret are the ways the pod receives a value at run time.

**When something becomes a value:** only if it differs between sites, or if it should change without touching the template. A fixed value is
written straight into the template or into a file.

**How the pod receives the value:**

| The application needs... | The way | In our system |
|---|---|---|
| one short value | `env` directly in the deployment or the CronJob | `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION` in fetch |
| a whole file | a ConfigMap attached as a file | `nginx.conf`, `targets.yaml`, `ca.pem` |
| a setting of OpenShift itself | a field directly on the resource | `replicas`, `resources`, `schedule`, `route.host` |
| a secret | a Secret created in the cluster, with only the name in Git | `crl-fetch-s3` |

**Why `env` directly and not a ConfigMap for single variables:** the result is the same, and a ConfigMap only adds a step in the middle and one
more object to manage and search during an incident. Its usual advantage, changing a value without touching the deployment, does not apply here:
every change goes through Git and the Argo sync anyway, and in a CronJob every run is a new pod. **When a ConfigMap is right for variables:** ten or
more (`envFrom`), or several components that need the same values.

**The flow, end to end** (`S3_BUCKET` in fetch):
1. `fetch/sites/sou/values.yaml`: `s3: {bucket: crl-bucket-sou}`.
2. `cronjob.yaml`: `- {name: S3_BUCKET, value: {{ required "s3.bucket is required" .Values.s3.bucket | quote }}}`. `required` stops the build if the
   value is missing; `quote` wraps it in quotation marks, so a value such as `123` is not read as a number.
3. Helm produces `- name: S3_BUCKET` and `value: "crl-bucket-sou"`.
4. In the script: `os.environ["S3_BUCKET"]`.

**The short rule:** it differs between sites: a value. A file: a ConfigMap. A single value: `env`. A secret: a Secret.

### A.9 `checksum/config` and `checksum/ca`: automatic rolling when the configuration changes (2026-11-19)

**What it is:** an annotation in the pod template, holding a fingerprint (SHA-256) of the content that the template renders:
```yaml
annotations:
  checksum/config: {{ include "crl-nginx.conf" . | sha256sum }}
  checksum/ca:     {{ include "crl-nginx.caBundle" . | sha256sum }}
```

**How it works:** Helm renders `nginx.conf` into the full text, including the replacements for the server, the tenant, and the bucket. `sha256sum`
computes a fixed-length hash of that text. The hash is written into the pod template. A change in the file changes the hash, so the template changes,
and Kubernetes rolls the pods: a new pod starts with the new configuration, and the old one goes down only after it (`maxUnavailable: 0`).

**Why it is needed:** Nginx reads its configuration only at start. Without the annotation, a change to `nginx.conf` would not take effect until a
manual restart, and the old pods would keep running the old configuration without anyone knowing.

**What it does not do:** the hash is computed from the template in Git, not from the ConfigMap in the cluster. So a manual edit of the ConfigMap does
not change it, and there is no automatic rolling. In that case use `oc rollout restart deployment/crl-nginx -n <namespace>`. A manual edit is a
deviation from Git that the next sync will overwrite, so the change must be made in Git.

**The two annotations:** `checksum/config` rolls when `nginx.conf` changes, and `checksum/ca` rolls when the CA bundle changes.

## Appendix B. Argo CD: how the deployment works

### B.1 What Argo does
Argo CD is a controller that keeps watching GitLab and makes sure OpenShift matches what is written there (GitOps). A change = a commit. A manual
change in OpenShift is reverted to what is in Git (self-heal). For us, one **central** Argo manages both sites, and it is shared with other teams.
Argo is not in the clients' path: if it goes down, the service keeps working, and only updates stop.

### B.2 Three layers
1. **The root** (`argocd/root.yaml`): the only object created by hand, once. It says "make sure everything in `argocd/apps` exists". Rebuilding means one root.
2. **What the root creates** (`argocd/apps/`):
   - **AppProject `crl`: not in use (2026-10-27).** The owner has no permission to create an AppProject on this Argo instance, and **only the
     owner's team uses the instance**, so there is no other team to protect it from. The Applications are in the `default` project. The file is kept in
     `argocd/optional/appproject.yaml` (outside `argocd/apps`, so the root does not try to create it).
     **What this means:** there is no technical limit on the repo, the target, or the object types; the protection is review in Git and the fact that
     the instance belongs to one team. **If the instance is ever shared with other teams:** ask the Argo administrators to create the AppProject from the file,
     and change the ApplicationSet to `project: crl`.
   - **ApplicationSet `crl-nginx`** (`crl-platform-appset.yaml`): an Application for each `serving/sites/*/site.yaml`: sou (production) and cen (DR). A new site is a folder.
   - (later) **Application `crl-monitor`**: the monitor runs in one site and differs from Nginx, so it is a plain Application, under the same root and the same fence.
3. **An automatically created Application** (`crl-nginx-<site>`): the chart plus `sites/<site>/values.yaml`, Helm release `crl-nginx`, with the cluster and namespace from `site.yaml`.

### B.3 Every setting in the files

| File | Setting | Meaning |
|---|---|---|

| Root | `path: argocd/apps` | what the root manages |
| Root | `destination: kubernetes.default.svc` plus the Argo namespace | the root creates Argo's own objects, which live in Argo |
| Root | `automated: prune and selfHeal` | a file that is deleted means its object is deleted; a manual edit is reverted |
| AppProject (not in use) | `sourceRepos`, `destinations`, `clusterResourceWhitelist: []`, `namespaceResourceWhitelist` | would limit the repo, the namespaces and the five kinds in the chart. Kept for the future |
| ApplicationSet | `generators.git.files: serving/sites/*/site.yaml` | one item per site (sou, cen) |
| ApplicationSet | `goTemplate` and `missingkey=error` | a missing value in `site.yaml` stops the run; it does not deploy half a configuration |
| ApplicationSet | `preserveResourcesOnDeletion: true` | deleting a folder or the ApplicationSet by mistake removes only the Application in Argo; Nginx keeps running |
| ApplicationSet | `template.name: crl-nginx-{{ .site }}` | the Application name (unique in Argo) |
| ApplicationSet | `releaseName: crl-nginx` | the Helm release name, which is the name of every resource in the namespace |
| ApplicationSet | `project: default` | no AppProject of our own (no permission; the team's instance only) |
| ApplicationSet | `path: serving/chart/crl-nginx` and `valueFiles: ../../sites/{{ .site }}/values.yaml` | the chart and the site's values |
| ApplicationSet | `destination: {{ .cluster }} / {{ .namespace }}` | from `site.yaml` |
| ApplicationSet | **no `automated`** (since 2026-11-02): manual sync | Argo shows OutOfSync and the diff, and applies nothing until Sync is pressed on the Application. No self-heal. Prune is ticked in the Sync dialog |
| ApplicationSet | `retry: 5, 30s doubling, up to 10m` | a temporary failure gets retried |
| `<site>/site.yaml` | `site`, `cluster`, `namespace` | **identity and target** (Argo reads them; Helm does not see them) |
| `<site>/values.yaml` | `s3.host`, `s3.tenant`, `s3.bucket`, `route.host` | the site's Nginx settings (Helm) |

### B.4 Decisions
- **Test in the production shape** (root and ApplicationSet): what is tested is what goes live. (2026-11-01: the test site was cancelled, and work moved to the production sites sou and cen.)
- **App of apps:** the instructions are in Git too. No manually created Application is forgotten or changed quietly; a rebuild starts from one root.
- **An ApplicationSet for Nginx:** one central Argo plus the same chart in each site is the classic case.
- **The monitor is a plain Application**, not in the ApplicationSet (it differs, and it runs in one site); the same root, the same fence.
- **One repo:** one system, one team; each Application looks only at its own folder.
- **AppProject not in use:** no permission, and the instance belongs to the team alone (see B.2). Accepted risk: no technical limit in Argo.

### B.5 Concepts
| Concept | Meaning | When |
|---|---|---|
| Repository | Argo's connection to Git (a deploy token with `read_repository`) | always |
| Cluster | Argo's connection to OpenShift | central Argo |
| Application | "what, from where, to where, how to sync" | the basic unit |
| Sync, prune, self-heal | deploy / delete leftovers / revert a manual change | production: all three |
| Synced versus Healthy | "identical to Git" versus "working". Two different things | check both |
| AppProject | a fence: repos, targets, object kinds | shared Argo; always in production |
| App of apps | an Application that creates Applications from a folder in Git | when the instructions should be in Git too |
| ApplicationSet | a template plus a list (list, git, cluster, matrix) | the same component in many sites or clusters |

### B.6 ApplicationSet generators

An ApplicationSet has two parts: the **generator**, which produces the list (items plus values for each item), and the **template**,
which describes the Application for each item. Each item becomes one Application.

**Ours: git files.** Each `serving/sites/*/site.yaml` is an item, and its fields (`site`, `cluster`, `namespace`) are the values.
This was chosen because each site needs several values (not only a name, so git directories do not fit), the values sit next to the
site's settings, and a new site does not require touching the ApplicationSet (unlike a list).

| Generator | Where the list comes from | Use |
|---|---|---|
| **list** | a list written inside the ApplicationSet | a few fixed items; adding one means editing the ApplicationSet |
| **cluster** | every cluster registered in Argo (can be filtered by label) | the same component in every cluster; a new cluster gets it automatically |
| **git directories** | folders in Git | a folder for each application or environment, when the folder name is enough |
| **git files** | JSON or YAML files in Git; their fields are the values | **ours**: values for each item, next to the code |
| **matrix** | the product of two generators | each component times each cluster |
| **merge** | combining generators by key, with overrides | defaults for all clusters plus exceptions for some |
| **SCM provider** | every repository in the GitLab or GitHub organisation | a new repo gets an Application (platforms) |
| **pull request** | every open merge request | a temporary preview environment per MR; removed when it closes |
| **cluster decision resource** | an external resource that decides which clusters | Open Cluster Management and ACM |
| **plugin** | an external service that returns the list | special cases (a CMDB, an internal API) |

### B.7 ApplicationSet when more than `values.yaml` differs (microservices)

| The difference between components | The solution |
|---|---|
| only `values.yaml` | an ApplicationSet, with a parameter for the values file (our case) |
| values: chart, path, repo, namespace, cluster | an ApplicationSet with more parameters in the generator (`{{ .repo }}`, `{{ .chart }}`); the structure is the same |
| the same components in several environments | `matrix` (components times clusters) |
| a few exceptions with an unusual **structural** field (manual sync, ignoreDifferences, multi-source) | a conditional `templatePatch` (Argo CD 2.10 or later). After two or three exceptions the template becomes hard to read and to check |
| groups with different structures (Helm or Kustomize, stateless or stateful, data path or monitoring) | one ApplicationSet per group: a simple template and a separate failure domain |
| a completely different component, or monitoring | a separate Application |

Rule: an ApplicationSet is justified as long as the **structure** of the Application is shared and only the **values** change.
Monitoring always stays outside the ApplicationSet of what it monitors.

### B.8 Sync: manual versus automatic, prune, selfHeal, webhook

**Who starts a sync:** with manual sync (no `automated`), Argo compares, marks OutOfSync, and applies only when Sync is pressed.
With `automated`, Argo starts the sync by itself.

| Option | What it answers | Manual | `automated` | Default |
|---|---|---|---|---|
| selfHeal | **when** Argo starts a sync by itself: also when the cluster changed, not only Git | does not exist. Pressing Sync gives the same result, but only when someone presses it | `selfHeal: true` | false |
| prune | **whether** the sync deletes | a Prune tick box in each Sync | `prune: true` (the decision is written in advance, because there is no person to tick it) | false: deletion is the most dangerous action |

**What handles what:**

| The situation | Who handles it |
|---|---|
| an Argo-managed resource edited by hand in the cluster (for example a ConfigMap) | selfHeal, or a manual sync |
| an Argo-managed resource removed from Git (for example a Route deleted from `network.yaml`) | prune |
| a resource created by hand outside Argo (`oc create`) | **nobody.** Argo did not mark it as its own, so prune does not delete it either |
| a field that is not written in Git at all | not restored. Argo fixes only what is defined in Git |
| a field added by hand to one of our resources that is not in Git (for example an extra volume in the Deployment pointing to a ConfigMap created by hand) | usually **stays**, and Argo may keep showing Synced. Argo enforces what is written in Git, and does not delete additions |

**Conclusion:** selfHeal protects what is defined in Git, and does not guarantee that the cluster has no manual additions. So the rule is:
changes only through Git, and nobody edits OpenShift by hand.

**The two prunes we have, and who deletes what.** There is no duplication: each prune works on a different layer.

| Object | Who deletes it | When |
|---|---|---|
| the ApplicationSet (and later the monitor's Application), that is, Argo objects | the prune in `root.yaml` | the file is deleted from `argocd/apps/` |
| the site's Application (`crl-nginx-sou`) | **the ApplicationSet itself**, not a prune | `site.yaml` is deleted. Because of `preserveResourcesOnDeletion: true`, Nginx keeps running |
| Nginx resources in the cluster (Deployment, Route, ConfigMap, PDB) | the prune in the ApplicationSet's template (applies to every site's Application) | the resource is removed from the chart |

- Prune acts only on **deletion**. A change to a file is applied even without prune.
- Each prune sees only its own layer: the root does not see the pods, and the site's Application does not see Argo's files.
- **If only one of them existed:** without prune in the template, a resource removed from the chart would keep running and be marked OutOfSync.
  Without prune in the root, an Argo object that was removed would be left orphaned.

**Webhook:** Argo notices a new commit in Git in two ways:
- **polling:** by default about every 3 minutes (`timeout.reconciliation`, 180 seconds). The ApplicationSet's git generator also checks about every 3 minutes.
- **webhook:** GitLab tells Argo immediately on push, and Argo refreshes at once.

A webhook does not replace `automated`. It only shortens the time until Argo **knows** about the change:
- **With `automated`:** push, and a sync right after it.
- **Without `automated`:** push, and an OutOfSync mark right after it. The sync still waits for a click.
- **selfHeal does not depend on the webhook.** Argo watches the cluster directly.

**Our decision:** no webhook, polling only. A delay of up to about 3 minutes in deploying a configuration change does not affect the CRL service.
A webhook needs a setting on the Argo side (a secret) and on the GitLab side, which is one more point to configure and maintain. If the delay becomes a problem,
a webhook can be added later without changing any file.

### B.9 First setup of a site (bootstrap): prerequisites and order

**Every step here is manual and one-time for each site. After them, everything comes from Git.**

| # | Step | Where | How to check it worked |
|---|---|---|---|
| 1 | Argo can read the repo: a deploy token with `read_repository` only, under Settings, Repositories, Connect Repo (HTTPS). An internal certificate is added under Settings, Certificates, **not** by skipping verification | GitLab and the Argo UI | the repo shows with status Successful |
| 2 | The target cluster is registered in Argo | Argo UI, Settings, Clusters | the row shows status Successful. The name in the Name column is the value of `cluster` in `site.yaml` |
| 3 | The namespace exists in the target cluster (with the quota) | OpenShift | the project exists |
| 4 | Argo is allowed to deploy to the namespace. **Central Argo (an external cluster):** a RoleBinding to the ClusterRole `admin` for the ServiceAccount the cluster was registered with (usually `argocd-manager` in `kube-system`). If the cluster row has a list of namespaces, add the namespace. **Argo in the same cluster:** the label `argocd.argoproj.io/managed-by=<ARGO_NAMESPACE>` | OpenShift (Import YAML) | no forbidden error during sync |
| 5 | The owner may create Applications in Argo (project default) | Argo UI | the New App button allows Create |
| 6 | The values in the files are filled in: `REPO_URL`, `ARGO_NAMESPACE`, `cluster`, `namespace`. The site's `values.yaml` exists | GitLab, branch `main` | searching for `REPO_URL`, `ARGO_NAMESPACE` or `SOU_CLUSTER` finds nothing |
| 7 | Create the root (once only, not for each site): New App, Edit as YAML, paste `root.yaml`, Create | Argo UI | `publish-root` appears: Synced, Healthy |
| 8 | Verify (within about 3 minutes): `crl-nginx`, then `crl-nginx-<site>`, then 3 pods. Two curl requests return MISS and then HIT. A delta with `+` works | Argo UI and curl | as in the deployment chapter |

**An additional site (shay, guy):** steps 1, 5 and 7 already exist. Repeat only 2, 3, 4 and 6 (new `site.yaml` and `values.yaml`), and then 8.

**The lesson (2026-10-28):** check steps 1 to 5 **before** creating the root. A root created without access to the repo is harmless: it only shows an error.
But it is the wrong order.

### B.10 The full structure of Argo and Helm, from zero (2026-11-01)

> **Update 2026-11-02, the current structure:** one network, one namespace per site, two sites: **sou (production)** and **cen (DR)**.
> A simple generator (`git.files: serving/sites/*/site.yaml`), with no matrix and no network folders. Two Applications:
> `crl-nginx-sou` and `crl-nginx-cen`. Helm release `crl-nginx`. In each site: `site.yaml` (site, cluster, namespace) and `values.yaml`
> (S3 host, tenant, bucket, route host). The chart stays release-aware (it also supports several releases in one namespace, if networks return).
> **The rest of this section, on networks, the matrix, and a third values layer, describes the plan of 2026-11-01 and is kept for reference.** The reasoning
> (names derived from releaseName, deep merge, the rule "each value sits next to what depends on it") still holds.

**Three layers:** Git holds the definitions (the source of truth). Argo reads Git and makes sure the clusters match it. Helm is the tool that Argo
runs: templates plus values produce Kubernetes resources.

```
Git  →  Argo  →  Helm (render)  →  OpenShift (sou, cen)
```

**The structure in GitLab**
```
argocd/
├── root.yaml                          ← the root (publish-root), created by hand once
├── apps/crl-platform-appset.yaml      ← the ApplicationSet (the root creates it)
└── optional/appproject.yaml           ← not in use (no permission)
serving/
├── chart/crl-nginx/
│   ├── Chart.yaml                     ← name and version
│   ├── values.yaml                    ← defaults for all 6 deployments
│   ├── files/nginx.conf               ← the configuration, with S3_HOST, S3_TENANT, S3_BUCKET to be replaced
│   ├── files/ca-bundle.pem            ← the CA certificates of the storage in both sites (created inside the network)
│   └── templates/
│       ├── _helpers.tpl               ← labels, configuration, certificates (stops on a missing value)
│       ├── configmaps.yaml            ← <release> (nginx.conf) and <release>-s3-ca
│       ├── deployment.yaml            ← 3 pods, rollout, checksum, anti-affinity, preStop, probes, resources, security
│       └── network.yaml               ← PDB, Service, Route (HTTP)
└── sites/
    ├── sou/site.yaml                  ← site, cluster, namespace (once per site)
    ├── sou/values.yaml                ← the site's storage server and tenant
    ├── sou/{ai,bi,ci}/values.yaml     ← bucket, route.host
    └── cen/...                        ← the same structure
```

**The order in practice**
1. Paste the root into Argo once. It creates everything in `argocd/apps/`, that is, the ApplicationSet.
2. The generator is a **matrix**: it runs two generators and creates **every combination** of them.
   - **git files:** every file that matches `serving/sites/*/site.yaml` (the asterisk = a site) is one item, with `site`, `cluster`, `namespace`. Today: 2.
   - **list:** the three networks, written once in the ApplicationSet: `network: ai/bi/ci`.
   - 2 × 3 = **6 combinations = 6 Applications**. Each combination has the values of both (`site`, `cluster`, `namespace`, `network`).
3. The values fill in the template (search and replace of `{{ .key }}`). The content of `site.yaml` (not the folder name) decides
   `site`, so it must match the folder name, because the values path is built from it.
4. Each Application runs Helm with three layers of values, and deploys to the cluster and namespace in `site.yaml`.
5. From then on: every commit reaches the cluster within about 3 minutes, and every manual change is reverted (B.8).

**How the names are derived.** The network is defined in one place, the list in the ApplicationSet, and everything else is derived from it:
```
list (network: ai) → releaseName: crl-nginx-ai → every resource: crl-nginx-ai (and crl-nginx-ai-s3-ca)
```

| | Name | Unique where | Why |
|---|---|---|---|
| Application | `crl-nginx-sou-ai` | in all of Argo | one Argo manages two sites |
| Release and resources | `crl-nginx-ai` | in the site's namespace | each cluster has only 3 networks |

**Why the name is not in the values file:** the release name is the identity of the installation in Helm (Helm does not allow two identical
names in a namespace), and the convention in every chart is to derive resource names from it. If the name were also in the values, it would be a
second source of truth that **could contradict** the first (for example `network: ai` but `name: crl-nginx-bi` from a copy mistake, and then a
collision with another network). **Identity** sits in `site.yaml` (Argo needs it before Helm runs), and **behaviour** (the bucket, the address) sits in the values.

**The values layers (9 files)**

| Layer | Files | Content | Why at this level |
|---|---|---|---|
| chart | 1 | replicas, image, resources, and more | the same in all 6 deployments |
| site | 2 | `s3.host`, `s3.tenant` | the same for the three networks in a site. Without this layer: the same value in 3 files, and a fix forgotten in one |
| network | 6 | `s3.bucket`, `route.host` | different in each deployment |

**How Helm merges several values files** (in order: the chart, then `valueFiles` in order. The later one wins):
1. A new key is added.
2. An existing key with a simple value is overwritten.
3. A key that is a map: Helm goes inside and continues merging key by key (a deep merge).
4. **A list is replaced entirely**, not appended to. Our values files have no lists.
5. An empty string does not delete a key. Only `null` deletes it.

Example: `s3` after the merge for sou/ai:
```yaml
s3:
  host: S3_HOST_SOU     # from the site
  tenant: TENANT_SOU    # from the site
  bucket: BUCKET_AI     # from the network
  caBundle: ""          # from the chart (nobody overrode it)
```

**The chart is release-aware:** every resource name is `{{ .Release.Name }}`, and the label `app.kubernetes.io/instance` goes into the
selectors of the Deployment, Service, PDB and anti-affinity. Without this, three networks in one namespace collide, and one network's Service picks up
another network's pods. Checked in `serving/tests/chart_test.sh`.

**Why one chart:** all 6 deployments are the same Nginx. What separates them is only the values.
**When a separate chart is right:** a different component, meaning a different image, a different resource kind (for example the monitor's CronJob),
templates that would fill up with conditions, or a separate lifecycle, owner or pace of change. **Several charts in one repo** is acceptable when they
belong to the same system and the same team (so the folder `serving/chart/` can hold several charts). **Not in the same repo:** different teams, a chart used by
many systems (published to a chart repository), or a very different pace of change. **The rule:** one chart per component, one repo per system and per team.

**Why the monitor is in the same repo:** it changes together with Nginx (a new network means an update to both, in the same MR, so that the monitor does not
fall behind). Same team, same permissions, one repo connection and one root. **Failure separation is achieved in Argo:** the monitor is a separate Application,
not part of the ApplicationSet, so a broken Nginx chart does not stop it. A separate repo only if another team is involved, if monitoring covers other
systems, or if access must be separated.

**Common changes**

| What you want | What you do in Git |
|---|---|
| add a network | a line in the network list in the ApplicationSet, plus `sites/<site>/<net>/values.yaml` **in each site** (missing in one site means the sync fails there) |
| add a site | `sites/<site>/site.yaml`, `sites/<site>/values.yaml`, and a `values.yaml` for each network. Plus bootstrap steps 2 to 4 (B.9) and the quota |
| change a network's bucket | `sites/<site>/<net>/values.yaml` |
| change a site's storage server | `sites/<site>/values.yaml` |
| change something in all deployments | `chart/crl-nginx/values.yaml` or the templates |
| remove a network | remove it from the list in the ApplicationSet (in all sites), then delete the resources by hand (`preserveResourcesOnDeletion`) |

### B.11 Deleting an application in the Argo UI (2026-11-02)

The deletion dialog offers a choice: **cascading** (Foreground or Background, the default) also deletes the resources in the cluster. **Non-cascading**
deletes only the Application in Argo, and the resources keep running.

| What is deleted | Cascading | Non-cascading |
|---|---|---|
| a Nginx application (`crl-nginx-<site>-<net>`) | the resources are deleted and the pods go down. The ApplicationSet creates the application again within seconds, and it deploys again. **A short service interruption on this network** | almost nothing: the application comes back and adopts the existing resources |
| the root (`publish-root`) | the ApplicationSet is deleted, and with it the 6 applications. **Nginx keeps running** (`preserveResourcesOnDeletion`), but without management | everything stays. The ApplicationSet keeps managing |

**The rule:** do not delete Nginx applications in the UI. To remove a network or a site, change Git (B.10). To recreate the root,
choose non-cascading deletion. Cascading deletion only when you really want the service removed.

### B.12 Important: the release name (releaseName), the application name, and the resource names, even with several services (2026-11-08)

**What a release name is:** Helm gives a name to each installation of a chart, to tell it apart from other installations of the same chart. Inside the chart,
every template reaches it through the built-in variable `{{ .Release.Name }}`. In our system, every resource is named after it.

**Where it is set:** in the ApplicationSet, in the `releaseName` field of the source. If the field is not written, Argo uses the application name.

**Two names, two places, one source:**

| Name | Set in | Template | Example | Unique where |
|---|---|---|---|---|
| the application in Argo | the ApplicationSet template, `metadata.name` | `'{{ .app }}-{{ .site }}'` | `crl-nginx-sou` | in all of Argo (it manages two sites) |
| the release name | the ApplicationSet template, `helm.releaseName` | `'{{ .app }}'` | `crl-nginx` | in the namespace |
| the name of each resource | the chart's templates, `metadata.name` | `{{ .Release.Name }}` | Deployment `crl-nginx` | in the namespace |

```
site.yaml (app: crl-nginx, site: sou)
   ├→ Application:  crl-nginx-sou        (Argo)
   └→ releaseName:  crl-nginx            (Argo passes it to Helm)
         └→ {{ .Release.Name }} → Deployment / Service / Route / ConfigMap / PDB = crl-nginx
```

**One service or several services:** with one service, the template knows who it is, so the name, the chart, and the release name are written into it as constants
(`crl-nginx-{{ .site }}`, `serving/chart/crl-nginx`, `crl-nginx`). With several services, all three become variables (`{{ .app }}`, `{{ .chart }}`), and each
`site.yaml` says which service it belongs to:

```yaml
# serving/sites/sou/site.yaml           # fetch/sites/sou/site.yaml
app: crl-nginx                          app: crl-fetch
chart: serving/chart/crl-nginx          chart: fetch/chart/crl-fetch
site: sou                               site: sou
cluster: SOU_CLUSTER                    cluster: SOU_CLUSTER
namespace: ...                          namespace: ...
```

**What changes in the move, and what does not:**
- **Changes:** the ApplicationSet (two paths for the generator, and three fields become variables), and two lines in each Nginx `site.yaml`.
- **Does not change:** the Nginx chart, including `deployment.yaml`. It is already written with `{{ .Release.Name }}`, and the release name comes out the same,
  `crl-nginx`. Also `valueFiles: '../../sites/{{ .site }}/values.yaml'` does not change, thanks to the identical structure of every service
  (`<service>/chart/<chart>` and `<service>/sites/<site>`).
- **The Nginx names are identical** (`crl-nginx-sou`, `crl-nginx`), so Argo does not delete or recreate them.
- **Order:** the two lines in Nginx's `site.yaml` and the change to the ApplicationSet are saved in the same commit. Otherwise, `missingkey=error`
  stops the creation of the Nginx applications.
- **A new service:** write a chart for it, with `name: {{ .Release.Name }}` in every template.

### B.13 Renaming the ApplicationSet, and the CA certificates: one source in Git, a ConfigMap per component (2026-11-09)

**Renaming (`crl-nginx` to `crl-platform`).** Argo identifies each object by its name. A new name is a **new object**, not the same object with another name.
During a sync of the root:
1. The root creates the new ApplicationSet.
2. The root deletes the old one (prune), because it is no longer in Git.
3. Deleting the old one deletes all its applications. Thanks to `preserveResourcesOnDeletion`, what runs in the cluster stays.
4. The new one creates the applications with the same names, and adopts the resources that are already running.

A service is not supposed to stop, but for a few minutes the applications disappear and are created again, and everything depends on
`preserveResourcesOnDeletion` working. So: do it in a quiet time, one change at a time. Check afterwards: 4 Applications, and the pods were not restarted
(their age was not reset). The file name changes nothing. In practice, the owner deleted the old applications himself.

**CA certificates: one in Git, one for each component in the cluster.**

| Where | How many | What |
|---|---|---|
| in Git | **one file** | `common/ca-bundle.values.yaml` (`s3.caBundle`), passed to each component as the first values file |
| in the cluster | **a ConfigMap for each component** | `crl-nginx-s3-ca`, `crl-fetch-ca` |

**Why not one shared ConfigMap in the cluster:**
1. **One owner per object.** Two applications that create the same ConfigMap fight over it (Argo warns), and deleting one deletes it for the other too.
2. **Automatic restart.** In Nginx, a change to the certificates changes the checksum, and the pods restart by themselves. A shared ConfigMap that nobody manages
   would not cause this. In fetch it makes no difference, because every run is a new pod that reads the current ConfigMap.
3. **A ConfigMap belongs to one namespace.** A component in another namespace cannot use it.

The real goal, one place to maintain, is achieved in Git. The duplication in the cluster is a few kilobytes, and it is managed automatically.
**If you really want one source:** OpenShift fills in the certificates itself (a ConfigMap with the label
`config.openshift.io/inject-trusted-cabundle: "true"`), if the organisation's CA certificates are in the cluster's trust list.
Then there are no certificates to maintain at all, neither in Git nor in the cluster. To be checked with the cluster administrators.

