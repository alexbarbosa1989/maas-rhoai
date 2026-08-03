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
Observability Dashboard tab in the RHOAI UI. Pinned to `v1.4.0` with **Manual** install-plan
approval (avoids regressions in newer COO releases) — `setup.sh` auto-approves the resulting
InstallPlan via `approve_installplan_for_sub` (from `../lib/common.sh`).

### Step 5 — Enable DSCI monitoring
Patches `DSCInitialization/default-dsci` with `spec.monitoring.metrics` (5Gi storage, 90-day
retention) and `spec.monitoring.traces` (0.1 sample ratio, PV backend, 2160h retention). This
triggers RHOAI's observability cascade (MonitoringStack, ThanosQuerier, Perses, tracing).
Without this the dashboard has no data source.

### Step 6 — Enable Kuadrant observability
Patches `Kuadrant/kuadrant` → `spec.observability.enable: true`, which creates a `PodMonitor`
so Prometheus scrapes token-consumption/rate-limit metrics from Limitador.

### Step 7 — Enable MaaS gateway telemetry
Patches `Tenant/default-tenant` → `spec.telemetry.enabled: true`, activating the
`TelemetryPolicy`/Istio `Telemetry` collection path. `captureUser` is **false by default**
(privacy/cardinality — a large user base can significantly grow the Prometheus database); see
[Enabling per-user metrics](#enabling-per-user-metrics) below to turn it on.

### Step 8 — Enable the dashboard tab
Patches `OdhDashboardConfig/odh-dashboard-config` → `spec.dashboardConfig.observabilityDashboard:
true`, which surfaces Observe & monitor → Dashboard → **Usage** tab in the RHOAI UI.

### Step 9 — Apply gateway telemetry
Applies two CRs targeting `maas-default-gateway`:
- `TelemetryPolicy/maas-telemetry` (Kuadrant) — adds `model`/`user`/`subscription`/
  `organization_id`/`cost_center` labels to gateway metrics.
- `Telemetry/latency-per-subscription` (Istio) — tags request-duration metrics with the
  subscription from the `x-maas-subscription` header.

### Step 10 — Verify
Checks all 3 operator CSVs are `Succeeded`, both telemetry CRs exist, and all 3 CR patches
took effect.

## Enabling per-user metrics

```bash
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service \
  --type=merge -p '{"spec":{"telemetry":{"metrics":{"captureUser":true}}}}'
```

## Viewing the dashboard

RHOAI Dashboard → **Observe & monitor** → **Dashboard** → **Usage** tab. Data appears once
users start making requests to MaaS models; use the Time period dropdown (5 minutes–14 days,
or custom) and the User/Subscription/Model filters. Export to CSV for finance/showback.

## Teardown

```bash
./teardown.sh          # reverts the 4 CR patches, deletes the 2 telemetry CRs
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
    ├── operators/
    │   ├── tempo/{namespace,operatorgroup,subscription}.yaml
    │   ├── opentelemetry/{namespace,operatorgroup,subscription}.yaml
    │   └── coo/{namespace,operatorgroup,subscription}.yaml
    └── telemetry/
        ├── gateway-telemetry-policy.yaml          # Kuadrant TelemetryPolicy
        └── istio-gateway-telemetry.yaml           # Istio Telemetry CR
```

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
  `true` (Step 10's verification output, or re-check with `oc get`).
- No data is expected until users actually make requests to MaaS models — send a test chat
  completion request, then re-check.
- The Usage tab does **not** read from the Tempo/OTel/COO stack this script installs (that
  stack backs the "Cluster"/"Models" tabs). It reads from a separate PersesDatasource,
  `kuadrant-prometheus-datasource` (namespace `redhat-ods-applications`, auto-created by
  `maas-api`), which targets `https://thanos-querier.openshift-monitoring.svc:9092?namespace=kuadrant-system`
  — the **platform User Workload Monitoring** Thanos Querier, not the local MonitoringStack
  Prometheus. Confirm that datasource is `Available`:
  ```bash
  oc get persesdatasource kuadrant-prometheus-datasource -n redhat-ods-applications -o jsonpath='{.status.conditions}'
  ```
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
this script manages (`PodMonitor`, `TelemetryPolicy`, `Tenant`/`Kuadrant`/`OdhDashboardConfig`
flags) is correctly configured — verified via `oc get` against each resource directly. This is
a CRC-only gap; a real OpenShift cluster with platform monitoring enabled (the default) is not
affected.

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

### Cardinality / Prometheus growth after enabling `captureUser`
Revert with:
```bash
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service \
  --type=merge -p '{"spec":{"telemetry":{"metrics":{"captureUser":false}}}}'
```
