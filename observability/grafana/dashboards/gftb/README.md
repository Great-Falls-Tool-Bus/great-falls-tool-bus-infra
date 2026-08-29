# GFTB Grafana dashboards (TIN-3896)

Three checked-in Grafana dashboards for the Great Falls Tool Bus surfaces on the
shared honey substrate. Before this ticket, **zero** GFTB dashboards existed on
the estate Grafana.

| File | uid | Title | Covers |
|---|---|---|---|
| `gftb-web-serve.json` | `gftb-web-serve` | GFTB / Web Serve | Deployment `greatfallstoolbus-org` in namespace `greatfallstoolbus-org-production` |
| `gftb-mail-list-form.json` | `gftb-mail-list-form` | GFTB / Mail, List and Form | Mailman list engine, Postgres, form-handler and Anubis in `latoolb-us-production` |
| `gftb-arc-runners.json` | `gftb-arc-runners` | GFTB / ARC Runners | `great-falls-tool-bus-nix` scale set vs `tinyland-nix` in `arc-runners` / `arc-systems` |

All three carry the `gftb` tag so the estate can filter on it.

## These files are declarations, not an apply

Nothing in this directory contacts Grafana, and this repository holds **no
Grafana credential** (AGENTS.md hard rule: no secrets, no kubeconfigs, no
backend credentials in Git). Getting these dashboards onto the live instance is
an operator action, deliberately kept outside CI.

Offline shape validation is the only automated step:

```
just grafana-dashboards-validate
```

That runs `scripts/validate-grafana-dashboards.sh` and asserts, per file: the
JSON parses; `uid` is present and equals the filename stem; `title` is present;
`tags` contains `gftb`; every referenced datasource uid is one that actually
exists on the target Grafana; datasources are `{type, uid}` objects rather than
name strings or unresolved template refs; panel ids are unique and every panel
is titled; and every `$var` used in a query is declared in `templating`. It is
wired into `just check-hosted`, so it runs on the hosted PR validation lane.

## Proposed provisioning wiring (not yet applied)

This overlay has no Grafana provisioning path today, so the JSON lands under
`observability/grafana/dashboards/gftb/`. Two ways to get it live; **neither has
been executed, and both are operator decisions**:

1. **Manual import (lowest commitment, recommended first).** Grafana →
   Dashboards → New → Import → upload each JSON. Because each file carries a
   stable `uid` that matches its filename, re-importing an updated file updates
   the existing dashboard in place instead of forking a copy. This needs no
   substrate change and no new credential.

2. **Git-sync / file provisioning (durable).** The dashboards belong to the GFTB
   tenant but Grafana itself is substrate-side, owned by the Tinyland overlay —
   so the sidecar or provisioning config that reads this directory is a
   substrate change, not a GFTB overlay change. The same no-re-homing doctrine
   that governs runner attach applies: the dashboard *declarations* stay here
   with the consumer org; only the reader is configured substrate-side. A
   Grafana file provider pointed at a checkout of this directory, with
   `foldersFromFilesStructure` disabled and a fixed target folder, is the
   smallest version of that.

The estate has exactly one dashboard folder today (`Tinyland`, uid
`cfjsne11i3qpsc`). Whether GFTB dashboards land in it or in a new `GFTB` folder
is an operator call; the JSON does not pin a folder, so either works.

## Datasources

Discovered from the live Grafana (read-only) on 2026-08-18:

| uid | Name | Type | Used here? |
|---|---|---|---|
| `prometheus-mail` | Prometheus Mail | prometheus | **yes — the only datasource these dashboards query** |
| `PBFA97CFB590B2093` | Prometheus (default) | prometheus | no |
| `loki` | Loki | loki | no (see below) |
| `mimir` | Mimir | prometheus | no |
| `tempo` | Tempo | tempo | no |
| `pyroscope` | Pyroscope | pyroscope | no |

Two things about that table are counter-intuitive and worth writing down:

- **`prometheus-mail` is misnamed.** Despite the name it is the *cluster-wide*
  Prometheus: it is the datasource that carries kube-state-metrics, kepler,
  node_exporter and nut-exporter for the whole honey cluster. Its full scrape
  job list is `kepler`, `kube-state-metrics`, `node-bumble`, `node-honey`,
  `node-relay`, `node-sting`, `nut-exporter`, `prometheus`, `rspamd`. Every GFTB
  namespace (`greatfallstoolbus-org-production`, `latoolb-us-production`,
  `arc-runners`, `arc-systems`) is visible only here.
- **The default Prometheus is not the cluster.** `PBFA97CFB590B2093` scrapes an
  application stack (`alloy`, `caddy`, `loki`, `mimir`, `prometheus`,
  `pyroscope`, `sveltekit`, `tempo`) with no GFTB namespace in it. `mimir`
  returns no metric names at all. Pointing a GFTB panel at the default
  datasource silently yields nothing.

**Loki holds no GFTB logs.** The Loki datasource has log streams for exactly one
namespace: `tinyland-staging`. There is nothing for
`greatfallstoolbus-org-production`, `latoolb-us-production`, `arc-runners` or
`arc-systems`. That is why the log-derived panels the ticket anticipated (form
endpoint rate, challenge failures, mail queue events) are **text panels naming
the gap** rather than LogQL queries that would render permanently empty.

## Panel inventory

Row headers are in **bold**. Every expression below was run against the live
cluster Prometheus before being committed.

### gftb-web-serve — GFTB / Web Serve

Template constants: `$namespace` = `greatfallstoolbus-org-production`,
`$deployment` = `greatfallstoolbus-org`.

| # | Panel | Type | Signal |
|---|---|---|---|
| | **Rollout state** | row | |
| 1 | Replicas ready | stat | `kube_deployment_status_replicas_ready` |
| 2 | Replicas desired | stat | `kube_deployment_spec_replicas` |
| 3 | Replicas available | stat | `kube_deployment_status_replicas_available` |
| 4 | Replicas unavailable | stat | `kube_deployment_status_replicas_unavailable` |
| 5 | Distinct image digests serving | stat | `count(count by (image_id) (kube_pod_container_info))` — >1 means a rollout is mid-flight or straddling digests |
| 6 | Container restarts (24h) | stat | `increase(kube_pod_container_status_restarts_total[24h])` |
| 7 | Replica history | timeseries | desired / ready / available / updated / unavailable |
| 8 | Deployment conditions | table | `kube_deployment_status_condition == 1` (Available, Progressing, ReplicaFailure) |
| | **Pods, restarts and readiness** | row | |
| 9 | Container restarts per hour | timeseries | `increase(kube_pod_container_status_restarts_total[1h])` |
| 10 | Pod age | timeseries | `time() - kube_pod_start_time` |
| 11 | Pod readiness and placement | table | `kube_pod_status_ready`, `kube_pod_info` |
| 12 | Container waiting / last-terminated reasons | table | `kube_pod_container_status_waiting_reason`, `..._last_terminated_reason` |
| | **Image provenance** | row | |
| 13 | Serving image digest per pod | table | `kube_pod_container_info` — `image_spec` (requested) vs `image_id` (resolved) |
| | **Resource envelope** | row | |
| 14 | Container requests and limits | table | `kube_pod_container_resource_requests` / `..._limits` |
| | **HTTP edge: signal not exported yet** | row | |
| 15 | HTTP request rate, latency and 5xx by route | text | **gap panel** — see below |

### gftb-mail-list-form — GFTB / Mail, List and Form

Template constant: `$namespace` = `latoolb-us-production`. Covers the
`mailman-core`, `mailman-postgres`, `form-handler`, `anubis` and
`anubis-archive` Deployments.

| # | Panel | Type | Signal |
|---|---|---|---|
| | **List, mail and form workload health** | row | |
| 1 | Deployments below desired | stat | `kube_deployment_status_replicas_unavailable > 0` |
| 2 | Pods not Ready | stat | `kube_pod_status_ready{condition="true"} == 0` |
| 3 | Container restarts (24h) | stat | `increase(kube_pod_container_status_restarts_total[24h])` |
| 4 | PVCs not Bound | stat | `kube_persistentvolumeclaim_status_phase{phase!="Bound"}` |
| 5 | Running pods | stat | `kube_pod_status_phase{phase="Running"}` |
| 6 | Replicas ready vs desired, per deployment | timeseries | `kube_deployment_status_replicas_ready` vs `kube_deployment_spec_replicas` |
| 7 | Container restarts per hour | timeseries | `increase(kube_pod_container_status_restarts_total[1h])` |
| 8 | Pod state and placement | table | `kube_pod_status_phase`, `kube_pod_info` |
| 9 | Container waiting / last-terminated reasons | table | waiting + last-terminated reason (OOMKilled on mailman-core is the classic failure) |
| | **Image provenance and storage** | row | |
| 10 | Serving image digest per container | table | `kube_pod_container_info` |
| 11 | PersistentVolumeClaims | table | `kube_persistentvolumeclaim_status_phase`, `..._resource_requests_storage_bytes` |
| | **Mail queue, delivery and list traffic: signal not exported yet** | row | |
| 12 | Postfix / Mailman delivery signals | text | **gap panel** |
| 13 | Contact-form endpoint and Anubis challenge signals | text | **gap panel** |

### gftb-arc-runners — GFTB / ARC Runners

No template variables; namespaces are pinned in the expressions. Scale set is
derived from the pod name (`<scaleset>-<5-char-hash>-runner-<id>`) with
`label_replace`, because kube-state-metrics label metrics (`kube_pod_labels`)
are **not** enabled on this cluster — there is no label to group by.

| # | Panel | Type | Signal |
|---|---|---|---|
| | **Scale set utilisation** | row | |
| 1 | great-falls-tool-bus-nix runners | stat | `count(kube_pod_info{pod=~"great-falls-tool-bus-nix-.*-runner-.*"})`, thresholds against the max-4 posture |
| 2 | tinyland-nix runners | stat | same, hash-anchored so `-heavy`/`-kvm`/`-operator`/`-compute-expansion` are excluded |
| 3 | GFTB share of runner pods | stat | GFTB runners / all runners on the shared namespace |
| 4 | All runner pods (shared namespace) | stat | `count(kube_pod_info{pod=~".*-runner-.*"})` |
| 5 | GFTB listener restarts | stat | `kube_pod_container_status_restarts_total` on the GFTB listener |
| 6 | Runner pods per scale set | timeseries | `count by (scaleset) (label_replace(...))` |
| 7 | Live runner pods | table | `count by (scaleset, node) (label_replace(...))` |
| | **Queue pressure and scheduling** | row | |
| 8 | Pending runner pods | stat | `kube_pod_status_phase{phase="Pending"}` — queue-depth **proxy** |
| 9 | Unschedulable runner pods | stat | `kube_pod_status_unschedulable` |
| 10 | p95 runner ready latency | stat | `quantile(0.95, kube_pod_status_ready_time - kube_pod_start_time)` — job-wait **proxy** |
| 11 | p95 runner schedule latency | stat | `quantile(0.95, kube_pod_status_scheduled_time - kube_pod_start_time)` |
| 12 | Runner pods by phase | timeseries | `sum by (phase) (kube_pod_status_phase)` |
| 13 | Runner ready latency per pod | timeseries | per-pod start-to-Ready seconds |
| | **Memory envelope (PR #105: 16 GiB runner limit)** | row | |
| 14 | GFTB runner memory limit | stat | `kube_pod_container_resource_limits{resource="memory"}` on GFTB runners; green at 17179869184 (16 GiB) |
| 15 | Runners at the 16 GiB envelope | stat | count of runners at exactly 16 GiB |
| 16 | Committed runner memory (all scale sets) | stat | sum of every live runner's memory limit |
| 17 | Lowest node memory headroom | stat | `min(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` on honey + sting |
| 18 | Committed runner memory limits vs node allocatable | timeseries | limits joined to node via `kube_pod_info`, against `kube_node_status_allocatable` |
| 19 | Node memory available (runner hosts) | timeseries | `node_memory_MemAvailable_bytes` / `node_memory_MemTotal_bytes` |
| 20 | Memory limit per runner pod | table | per-pod declared envelope |
| 21 | GFTB listener health (arc-systems) | table | listener Ready + restart count (promoted readback wants one Ready, zero-restart pod) |
| | **ARC job accounting: signal not exported yet** | row | |
| 22 | Job queue depth, wait time and runner utilisation | text | **gap panel** |

## Signals that do not exist yet

These were requested and are **not charted**, because no metric or log stream
carries them on this estate. Each is named in a "signal not exported yet" text
panel on the relevant dashboard, together with the metric that *would* carry it.
No metric name has been invented anywhere in this JSON.

| Surface | Missing signal | Would come from | Why it is missing |
|---|---|---|---|
| Web | Ingress request rate / p50 / p95 by route | `nginx_ingress_controller_*` | `ingress-nginx` runs but is not scraped — and GFTB traffic arrives via the `cloudflared` tunnel, not that controller |
| Web | 5xx by route | `nginx_ingress_controller_requests{status=~"5.."}` | same |
| Web | Cloudflare Tunnel / Access errors | `cloudflared_tunnel_*`, CF Logpush/GraphQL | `cloudflared` exports nothing here; no Cloudflare datasource is configured |
| Web | Application request metrics | app `/metrics` | the adapter-node workload exposes `/health` only |
| Mail | Postfix queue depth, delivery, deferral | postfix_exporter | no postfix_exporter is deployed |
| Mail | Mailman list traffic, subscriber count | Mailman REST scrape | no exporter deployed |
| Form | Submit rate, 4xx/5xx | form-handler `/metrics` | form-handler exposes no metrics endpoint |
| Form | Anubis challenge issued/passed/failed, ALTCHA failures | `anubis_*` | `anubis` and `anubis-archive` run but are not scraped |
| ARC | Queue depth, assigned/idle/registered runners | `gha_*` listener metrics | ARC listeners expose metrics; no scrape job collects them |
| ARC | True job wait time, execution duration | `gha_job_*` | same |
| All | Per-pod memory and CPU **usage** | cAdvisor `container_memory_working_set_bytes` | no cAdvisor / kubelet-resource scrape job exists on this cluster |
| Mail | PVC filesystem utilisation | `kubelet_volume_stats_used_bytes` | kubelet volume stats are not scraped |

Two consequences worth stating plainly rather than burying:

- **Envelope headroom is declarative, not observed.** The ARC memory panels
  chart *declared limits* against *node-level* free memory. Nothing reports what
  an individual runner pod is actually using, so a runner walking up to its
  16 GiB ceiling cannot be seen before it is OOMKilled. The after-the-fact
  evidence is `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`.
- **Queue depth is a proxy.** Pending runner *pods* only appear once ARC has
  already decided to scale up. A job sitting in GitHub's queue before that
  decision is invisible on this dashboard.

Closing the cAdvisor and `gha_*` gaps means adding scrape jobs to the cluster
Prometheus. That is substrate-side work owned by the Tinyland overlay, not by
this GFTB overlay, and it is operator-gated.

### rspamd is deliberately not charted

The cluster Prometheus does carry `rspamd_scanned_total`, `rspamd_actions_total`,
`rspamd_spam_total` and `rspamd_ham_total` — but every series is labelled
`namespace="tinyland-dev-production"`, pod `rspamd-normal-*`. That is the
Tinyland substrate's scanner, not a GFTB tenant signal. Charting it on a GFTB
dashboard would attribute another tenant's mail volume to GFTB, so it is left
off.

## Privacy posture

`meta/spec/observability-shape-2026-06-05.md` is the estate's observability
shape: the launch site ships zero analytics, no PII or client IP may reach a
telemetry pipeline, and any future event collection is opt-in only. Every panel
in these three dashboards reads Kubernetes workload state and node metrics —
replica counts, restarts, image digests, memory limits. None reads request
content, user identity, or client addresses. Any future implementation that
fills the gaps above must keep panels outcome-shaped and IP-free.

## Maintaining these files

- Edit the JSON in place; keep `uid` equal to the filename stem, keep the `gftb`
  tag, and keep datasources in `{type, uid}` object form.
- Run `just grafana-dashboards-validate` before committing.
- If you add a panel, verify its expression against the live datasource first.
  A panel that renders empty forever is worse than an honest gap note — the
  whole point of the text panels is that a missing signal stays visible instead
  of masquerading as a healthy flat line.
- If a signal above becomes available, replace the corresponding row of the gap
  panel with the real chart and update the table in this README.
