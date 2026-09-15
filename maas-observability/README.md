# MaaS Observability Dashboard (optional)

Enables the RHOAI 3.4 Models-as-a-Service **usage/showback observability dashboard**
(Technology Preview) — token consumption, request counts, error rates, and rate-limit
violations, broken down by user/subscription/model, with CSV export for cost attribution.

This is a separately-lifecycled add-on to the base MaaS platform (`../setup-maas.sh`), not a
required part of it. Nothing here is applied unless you run `./setup.sh`.

> **Technology Preview**: not supported with production SLAs and might not be functionally
> complete. Designed for internal showback reporting, not billing-grade metering — for
> production chargeback, query the Limitador metrics endpoint directly.

References:
- [RHOAI 3.4 — Govern LLM access with Models-as-a-Service, §1.18](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index)
- [RHOAI 3.4 — Managing observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai)
- [rh-aiservices-bu/rhoai-maas-guide, Phase 7: Observability](https://github.com/rh-aiservices-bu/rhoai-maas-guide) (source of the operator manifests and DSCI patch used here)

## Prerequisites

- `../setup-maas.sh` has already been run successfully (this script checks for the Kuadrant CR
  and the `maas-default-gateway` Gateway and aborts if either is missing).
- Cluster-admin privileges.
- The three observability operators (Tempo, Red Hat build of OpenTelemetry, Cluster
  Observability Operator) are installed automatically by `setup.sh` unless already present.

## Quick start

```bash
oc login ...
./setup.sh
```

## Flags

```
./setup.sh [--skip-operators] [--help]
```

- `--skip-operators` — skip installing Tempo/OpenTelemetry/COO (use if already installed).

## What the script does (step by step)

### Step 1 — Preflight checks
Confirms `oc` CLI, cluster login, cluster-admin, and that `../setup-maas.sh` has already been
run (Kuadrant CR + MaaS Gateway present).

### Step 2 — Install Tempo operator
Provides the `TempoStack` CRD required by RHOAI's Monitoring controller for distributed
tracing. Installed via `manifests/operators/tempo/` (namespace, OperatorGroup, Subscription;
Automatic install-plan approval).

### Step 3 — Install Red Hat build of OpenTelemetry operator
Provides the `OpenTelemetryCollector` CRD. Without it the Monitoring controller fails with
*"OpenTelemetryCollector operator must be installed for OpenTelemetry configuration"*.

### Step 4 — Install Cluster Observability Operator (COO)
Provides the Perses CRDs (`Perses`, `PersesDatasource`, `PersesDashboard`) that back the
Observability Dashboard tab in the RHOAI UI. RHOAI version is auto-detected (same approach
as `../setup-maas.sh`) to pick one of two subscriptions:

- **RHOAI < 3.4.3**: pinned to `v1.4.0` with **Manual** install-plan approval
  (`manifests/operators/coo/subscription.yaml`) — avoids a regression in newer COO releases.
  `setup.sh` auto-approves the resulting InstallPlan via `approve_installplan_for_sub`
  (from `../lib/common.sh`).
- **RHOAI 3.4.3+**: tracks the `stable` channel's latest CSV with **Automatic** approval
  (`manifests/operators/coo/subscription-latest.yaml`) — RHOAI 3.4.3+ is confirmed
  compatible with newer COO releases, so the pin is no longer needed.

This only takes effect on a fresh COO install — if COO is already installed and its CSV is
already `Succeeded`, this step skips entirely regardless of which subscription it would
have chosen (same idempotent-skip behavior as every other operator install in this repo).

### Step 5 — Enable DSCI monitoring
Patches `DSCInitialization/default-dsci` with `spec.monitoring.metrics` (5Gi storage, 90-day
retention) and `spec.monitoring.traces` (0.1 sample ratio, PV backend, 2160h retention). This
triggers RHOAI's observability cascade (MonitoringStack, ThanosQuerier, Perses, tracing).
Without this the dashboard has no data source.

### Step 6 — Enable Kuadrant observability
Patches `Kuadrant/kuadrant` → `spec.observability.enable: true`, which creates a `PodMonitor`
so Prometheus scrapes token-consumption/rate-limit metrics from Limitador.

### Step 7 — Enable MaaS gateway telemetry
Patches `Tenant/default-tenant` → `spec.telemetry.enabled: true`. `captureUser` is **true by
default** — required for the Usage tab's per-user filtered queries to return any data at all
(without it, `maas-controller` never adds a `user` label mapping to `TelemetryPolicy`, so every
per-user query the dashboard runs comes back empty.
Set it back to `false` if you'd rather trade that off for lower Prometheus cardinality — see
[Disabling per-user metrics](#disabling-per-user-metrics) below.

This alone is what activates gateway-side telemetry collection — `maas-controller` (part of
the RHOAI application, not this script) auto-generates `TelemetryPolicy/maas-telemetry`
(Kuadrant) and `Telemetry/latency-per-subscription` (Istio) the moment this flag is true. This
module used to apply its own copies of those two CRs directly; that step was removed because
`maas-controller` owns and reconciles them regardless (confirmed live: it recreates them within
~45s of deletion), making a separate apply redundant. 

### Step 8 — Enable the dashboard tab
Patches `OdhDashboardConfig/odh-dashboard-config` → `spec.dashboardConfig.observabilityDashboard:
true`, which surfaces Observe & monitor → Dashboard → **Usage** tab in the RHOAI UI.

### Step 9 — Verify
Checks all 3 operator CSVs are `Succeeded`, that `maas-controller` has created both telemetry
CRs (polls up to 60s, since creation is asynchronous), that all 3 CR patches took effect, and
lists any `MaaSSubscription` missing `spec.tokenMetadata.organizationId`/`costCenter`

## Disabling per-user metrics

`captureUser: true` is the default (see Step 7 above). To turn it back off — trading away
per-user breakdown in the Usage tab for lower Prometheus cardinality:

```bash
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service \
  --type=merge -p '{"spec":{"telemetry":{"metrics":{"captureUser":false}}}}'
```

## Viewing the dashboard

RHOAI Dashboard → **Observe & monitor** → **Dashboard** → **Usage** tab. Data appears once
users start making requests to MaaS models; use the Time period dropdown (5 minutes–14 days,
or custom) and the User/Subscription/Model filters. Export to CSV for finance/showback.

## Teardown

```bash
./teardown.sh          # reverts the 4 CR patches, deletes the 2 maas-controller-owned telemetry CRs
./teardown.sh --full   # also uninstalls Tempo/OpenTelemetry/COO operators
```

See `./teardown.sh --help` for the full list of what gets removed in each mode. The base MaaS
platform (`../setup-maas.sh`/`../teardown-maas.sh`) is never touched by either script here.

## Repository layout

```
maas-observability/
├── setup.sh                                     # This module's setup script
├── teardown.sh                                   # This module's teardown script
├── README.md                                     # This file
└── manifests/
    └── operators/
        ├── tempo/{namespace,operatorgroup,subscription}.yaml
        ├── opentelemetry/{namespace,operatorgroup,subscription}.yaml
        └── coo/{namespace,operatorgroup,subscription,subscription-latest}.yaml
            # subscription.yaml: pinned v1.4.0, Manual approval (RHOAI < 3.4.3)
            # subscription-latest.yaml: stable channel, Automatic approval (RHOAI 3.4.3+)
```

(No `telemetry/` manifests here — `TelemetryPolicy`/`Telemetry` are auto-created by
`maas-controller`, not applied by this module. See Step 7 above.)

## Troubleshooting

### COO InstallPlan stuck, CSV never appears
COO's Subscription uses `installPlanApproval: Manual`. `setup.sh` calls
`approve_installplan_for_sub` automatically, but if it times out, approve manually:
```bash
oc get installplan -n openshift-cluster-observability-operator
oc patch installplan <name> -n openshift-cluster-observability-operator \
  --type=merge -p '{"spec":{"approved":true}}'
```

### DSCI never reaches phase `Ready`
```bash
oc describe dsci default-dsci
```
Check for errors related to storage provisioning (the `metrics.storage`/`traces.storage`
PVCs need a default StorageClass) or missing operator CRDs (confirms Steps 2–4 completed):
```bash
oc get crd tempostacks.tempo.grafana.com
oc get crd opentelemetrycollectors.opentelemetry.io
oc get crd perses.perses.dev
```

### Usage tab shows no data
- Confirm `Kuadrant.spec.observability.enable` and `Tenant.spec.telemetry.enabled` are both
  `true` (Step 9's verification output, or re-check with `oc get`).
- Confirm every `MaaSSubscription` you expect to see data for has `spec.tokenMetadata.
  organizationId`/`costCenter` set (Step 9's verification lists any that don't).
- No data is expected until users actually make requests to MaaS models — send a test chat
  completion request, then re-check.
- The Usage tab does **not** read from the Tempo/OTel/COO stack this script installs (that
  stack backs the "Cluster"/"Models" tabs). It reads from a separate PersesDatasource,
  `kuadrant-prometheus-datasource` (namespace `redhat-ods-applications`, auto-created by
  `maas-api`), which targets `https://thanos-querier.openshift-monitoring.svc:9092?namespace=kuadrant-system`
  — the platform Thanos Querier, which federates both platform Prometheus (`prometheus-k8s`)
  and User Workload Monitoring (`prometheus-user-workload`). Confirm that datasource is
  `Available`:
  ```bash
  oc get persesdatasource kuadrant-prometheus-datasource -n redhat-ods-applications -o jsonpath='{.status.conditions}'
  ```
- **Which Prometheus actually scrapes `kuadrant-limitador-monitor` depends on a namespace
  label, not UWM's `enableUserWorkload` setting.** `kuadrant-system` carries
  `openshift.io/cluster-monitoring=true` (set by RHCL, not this module) — User Workload
  Monitoring's Prometheus explicitly *excludes* namespaces with that label
  (`podMonitorNamespaceSelector: NotIn ["true"]`), while the *platform* Prometheus
  (`prometheus-k8s`) explicitly *includes* them. So the `PodMonitor` this script's
  `enable_kuadrant_observability` step triggers is scraped by `prometheus-k8s`, not
  `prometheus-user-workload` — verified live via `prometheus-k8s`'s `/api/v1/targets`
  (`podMonitor/kuadrant-system/kuadrant-limitador-monitor/0`, status `up`). Functionally this
  doesn't matter for the dashboard (Thanos Querier federates both), but if you're debugging by
  querying a specific Prometheus instance directly, query `prometheus-k8s`
  (`openshift-monitoring`), not `prometheus-user-workload`.
- Query `authorized_calls` the same way the dashboard does, to confirm Prometheus is scraping
  independent of the dashboard UI:
  ```bash
  TOKEN=$(oc whoami -t)
  # run from inside the cluster (e.g. `oc debug node/<node>` or any in-cluster pod) —
  # the Service has no external Route
  curl -sk -H "Authorization: Bearer ${TOKEN}" \
    'https://thanos-querier.openshift-monitoring.svc:9092/api/v1/query?namespace=kuadrant-system&query=authorized_calls'
  ```

#### No data on CRC / OpenShift Local specifically
CRC ships with `baselineCapabilitySet: "None"` — its `openshift-monitoring` namespace is
**empty by default** (no `cluster-monitoring-operator` pod, no Thanos Querier service at all),
regardless of the `cluster-monitoring-config`/`enableUserWorkload: true` ConfigMap that
`../setup-maas.sh` applies (that ConfigMap is inert without the platform monitoring operator
actually running to read it). Since the Usage tab's datasource depends on that platform
Thanos Querier, the dashboard will show no data on a stock CRC cluster even though every CR
this module is responsible for (`PodMonitor`, `Tenant`/`Kuadrant`/`OdhDashboardConfig` flags,
and the `maas-controller`-generated `TelemetryPolicy`) is correctly configured — verified via
`oc get` against each resource directly. This is a CRC-only gap; a real OpenShift cluster with
platform monitoring enabled (the default) is not affected.

**Fix for CRC**: enable the platform monitoring stack via the CRC config flag, then restart:
```bash
crc config set enable-cluster-monitoring true
crc stop
crc start
```
Verified live: this brings up `cluster-monitoring-operator`, `prometheus-k8s`, `thanos-querier`,
and (with `enableUserWorkload: true` already set by `../setup-maas.sh`) `prometheus-user-workload`
in `openshift-user-workload-monitoring` — confirm with:
```bash
oc get clusteroperator monitoring
oc get pods -n openshift-user-workload-monitoring
```
Once both are healthy, re-run `./setup.sh` (or just wait — the `PodMonitor` this script already
created will start getting scraped without re-applying anything) and retry the verification
steps above.

#### Scraping confirmed working, but still no data: check Limitador's own `/metrics`
Even after fixing the CRC monitoring gap above, we hit a case during full end-to-end
verification (real traffic through a `TokenRateLimitPolicy`-`Enforced` route) where Limitador
emitted *no* `authorized_calls`/`authorized_hits`/`limited_calls` at all — only the two static
`limitador_up`/`datastore_partitioned` gauges, regardless of how many successful requests were
sent. If you hit this, check Limitador's own metrics directly before assuming the PodMonitor/
scraping is at fault:
```bash
LIM_POD=$(oc get pod -n kuadrant-system -l app=limitador -o jsonpath='{.items[0].metadata.name}')
oc exec -n kuadrant-system "$LIM_POD" -- curl -s http://localhost:8080/metrics
```

**Root cause:** it isn't a scraping or Limitador problem — it's a bug in the `TelemetryPolicy`
that `maas-controller` (part of RHOAI itself, not this module) auto-generates once `Tenant.
spec.telemetry.enabled` is true. Its `organization_id`/`cost_center` label expressions
reference `auth.identity.subscription_info.organizationId`/`costCenter` unconditionally, but
those are **optional** fields (`MaaSSubscription.spec.tokenMetadata`). When a subscription
doesn't set them, the CEL expression throws `CelError::Resolve { NoSuchKey(...) }` in the
gateway's wasm filter (check the gateway pod's logs for this string) — and that error aborts
the *entire* wasm task for the request, which also carries the `ratelimit-report` call to
Limitador. So any subscription without `tokenMetadata` silently never reports usage to
Limitador at all, while the actual inference request still succeeds (the wasm filter fails
open) — completely invisible to an end user, and easy to misdiagnose as a Limitador or
Prometheus problem.

**This is not fixable from this repository.** `maas-controller` owns the `TelemetryPolicy`'s
`spec.metrics.default.labels` via Kubernetes Server-Side Apply and actively reconciles it —
verified live: deleting the object outright gets it recreated within ~45s; hand-patching the
CEL to be `has()`-guarded (which does fix the underlying bug — confirmed functionally correct
in isolated testing) gets silently reverted within ~17s by `maas-controller`'s own reconcile
loop. There is no supported way to durably change this object from outside `maas-controller`
itself. (This module used to apply its own copy of this CR for exactly this reason, hoping to
own it — that didn't work either, and the step was removed; see Step 7 above.)

**Actual fix — set `tokenMetadata` on the subscription, not the `TelemetryPolicy`:**
```bash
oc patch maassubscription <name> -n <namespace> --type=merge \
  -p '{"spec":{"tokenMetadata":{"organizationId":"<org-id>","costCenter":"<cost-center>"}}}'
```
This works because `MaaSSubscription` isn't touched by `maas-controller`'s `TelemetryPolicy`
reconciliation — it's a durable, data-side fix. Verified live: within one request after
patching, `authorized_calls`/`authorized_hits` appear in Limitador's `/metrics`, correctly
labeled, and the Usage tab populates. `setup.sh`'s Step 9 lists any `MaaSSubscription` missing
this field.

**Already fixed upstream, not yet GA:** confirmed via
[PR #1276](https://github.com/opendatahub-io/models-as-a-service/pull/1276)/
[#1311](https://github.com/opendatahub-io/models-as-a-service/pull/1311)/
[#1312](https://github.com/opendatahub-io/models-as-a-service/pull/1312) in
`opendatahub-io/models-as-a-service` — the exact `has()`-guard fix, already merged (including a
`release-3.4` backport). It lands in RHOAI **3.4.4**, which is not yet released — current GA is
**3.4.2**. Until you're on a build that includes the fix, the `tokenMetadata` workaround above
is required.

### Cardinality / Prometheus growth from `captureUser`
`captureUser` is on by default (Step 7) — see [Disabling per-user
metrics](#disabling-per-user-metrics) above if a large user base is growing the Prometheus
database more than you'd like.
