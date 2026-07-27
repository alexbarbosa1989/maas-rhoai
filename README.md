# RHOAI 3.4 — Models-as-a-Service (MaaS) Automation

Automates the full MaaS configuration on **Red Hat OpenShift AI 3.4** as described in the official documentation:
[Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index)

---

## What MaaS does

MaaS lets a **platform team** deploy LLMs once and expose them as governed, subscription-based API endpoints through a single gateway hostname (`maas.<apps-domain>`). User teams (data scientists, developers) mint a MaaS API key and call `https://maas.<apps-domain>/<namespace>/<model-name>/v1/...`, automatically subject to:

| Feature | Mechanism |
|---|---|
| Publishing | `MaaSModelRef` — registers an `LLMInferenceService` (or `ExternalModel`) with MaaS |
| Authorization | `MaaSAuthPolicy` — grants groups/users API-gateway access to specific models |
| Quota / rate limiting | `MaaSSubscription` — token-rate-limit quotas per group/user, with priority tiers |
| Authentication | MaaS API keys (`sk-oai-...`) or OpenShift/OIDC bearer tokens for the management API |
| TLS | cert-manager + OpenShift service-serving certificates |

Underneath, these MaaS-native CRDs are enforced by RHCL (Kuadrant) `AuthPolicy`/`TokenRateLimitPolicy` objects that the platform manages automatically at the gateway level — you configure MaaS resources, not raw Kuadrant policies, for model governance.

---

## Architecture

```
Data Scientist / App
       │
       │  HTTPS — one hostname: maas.<apps-domain>
       │  (OpenShift bearer token for /maas-api/*, MaaS API key for inference)
       ▼
┌────────────────────────────────────────────────────────┐
│  Route: maas-default-gateway (openshift-ingress)       │
│  → maas-default-gateway Gateway (data-science-gateway- │
│    class), TLS: OpenShift service-serving cert         │
└───────────────────────┬──────────────────────────────────┘
                        │  enforced by Kuadrant/RHCL AuthPolicy +
                        │  Authorino (TLS gRPC, tokenreview/API-key validation)
          ┌─────────────┴──────────────┐
          ▼ /maas-api/*, /v1/models    ▼ /<namespace>/<model-name>/v1/*
┌───────────────────────┐    ┌────────────────────────────┐
│  maas-api             │    │  LLMInferenceService        │
│  (API keys, model     │    │  HTTPRoute (per model)      │
│  catalogue; requires  │    │  serving.kserve.io          │
│  PostgreSQL)          │    │  (kserve + llmisvc-ctrlr)   │
└───────────────────────┘    └────────────────────────────┘
          ▲                              ▲
          └──────────────┬───────────────┘
                        │  governed by
      MaaSModelRef (publish) · MaaSSubscription (quota) · MaaSAuthPolicy (access)
```

### Key components

| Component | Namespace | Purpose |
|---|---|---|
| RHOAI Operator | `redhat-ods-operator` | Manages all RHOAI components via DSC |
| llmisvc-controller | `redhat-ods-applications` | Reconciles `LLMInferenceService` CRs |
| model-serving-api | `redhat-ods-applications` | REST catalogue API for MaaS |
| maas-api | `redhat-ods-applications` | MaaS platform API (requires PostgreSQL) |
| maas-controller | `redhat-ods-applications` | Reconciles Tenant, MaaSModelRef, MaaSSubscription, and MaaSAuthPolicy CRs |
| maas-default-gateway | `openshift-ingress` | Gateway API entry point for model endpoints |
| cert-manager | `cert-manager-operator` | TLS certificate automation |
| Kuadrant / RHCL | `kuadrant-system` | Auth, rate-limiting, DNS, TLS policies |
| Authorino | `kuadrant-system` | Token review engine (must run with TLS) |
| PostgreSQL | `maas-db` | Backing store for maas-api |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift 4.19.9+ (ROSA supported) | Any flavour; cluster-admin access required |
| RHOAI 3.4.0+ installed | Operator + DSC + DSCI must exist |
| Red Hat Service Mesh 3.x | Already installed if using RHOAI 3.4 with KServe |
| `oc` CLI | Logged in as cluster-admin |
| Internet access | To pull operator images from `registry.redhat.io` |
| GPU nodes (for real workloads) | Optional for the example; required to run LLMs |

---

## Quick start

```bash
# 1. Clone / download this repository
cd maas-rhoai

# 2. Log in to the cluster
oc login https://api.<cluster>.<domain>:443 \
  --username cluster-admin --password <password>

# 3. Run the automation (installs everything end-to-end)
./setup-maas.sh

# 4. Optionally deploy the example LLMInferenceService, MaaS governance
#    (MaaSModelRef/MaaSSubscription/MaaSAuthPolicy), and LlamaStack playground
./deploy-example-workload.sh
```

### Flags

`setup-maas.sh`:

| Flag | Description |
|---|---|
| `--skip-operators` | Skip cert-manager and RHCL installation (already installed) |
| `--help` | Show usage |

`deploy-example-workload.sh` (run after `setup-maas.sh`):

| Flag | Description |
|---|---|
| `--skip-llamastack` | Skip deploying the LlamaStackDistribution (GenAI Playground) |
| `--hardware-profile-name NAME` | GPU HardwareProfile to annotate the LLMInferenceService with (overrides auto-detection) |
| `--help` | Show usage |

### Environment variables

Override any default by exporting the variable before running the script:

```bash
export RHOAI_OPERATOR_NS=redhat-ods-operator   # RHOAI operator namespace
export RHOAI_APP_NS=redhat-ods-applications    # RHOAI application namespace
export CERT_MANAGER_NS=cert-manager-operator   # cert-manager namespace
export KUADRANT_NS=kuadrant-system             # Kuadrant namespace
export MAAS_MODEL_NS=maas-models               # Namespace for model deployments
export DSC_NAME=default-dsc                    # DataScienceCluster name
export OPERATOR_WAIT_TIMEOUT=600               # Seconds to wait for operators
export POD_WAIT_TIMEOUT=300                    # Seconds to wait for pods
export KUADRANT_WAIT_TIMEOUT=300               # Seconds to wait for Kuadrant Ready

# deploy-example-workload.sh only:
export MODEL_WAIT_TIMEOUT=600                  # Seconds to wait for the example model/LlamaStack pod
export HARDWARE_PROFILE_NAME=                  # GPU HardwareProfile to use (same as --hardware-profile-name)
```

---

## What the script does (step by step)

### Step 1 — Preflight checks
Validates `oc` CLI, cluster login, cluster-admin privileges, RHOAI ≥ 3.4, and the manifests directory.

### Step 2 — Install cert-manager
Deploys the **Red Hat cert-manager operator** (`openshift-cert-manager-operator`) from the `redhat-operators` catalogue into the `cert-manager-operator` namespace. cert-manager is required for TLS certificate automation (Authorino TLS, gateway certs).

```
manifests/01-cert-manager-namespace.yaml
manifests/02-cert-manager-operatorgroup.yaml
manifests/03-cert-manager-subscription.yaml
```

> **Note on Manual InstallPlan clusters:** Some OpenShift clusters enforce `Manual` InstallPlan approval globally. The script detects and auto-approves pending InstallPlans for all subscriptions it creates.

### Step 3 — Install Red Hat Connectivity Link (RHCL)
Installs **RHCL v1.4.0** (based on Kuadrant) as a cluster-scoped operator in `openshift-operators`, then creates a `Kuadrant` instance in `kuadrant-system`. This triggers deployment of:

- **Authorino** — JWT / K8s token review engine (patched to TLS in Step 5)
- **Limitador** — in-memory rate limiting counter
- **DNS Operator** — manages DNSRecord resources

```
manifests/04-rhcl-subscription.yaml
manifests/05-kuadrant-namespace.yaml
manifests/06-kuadrant-cr.yaml
```

New CRDs provided by RHCL:

| CRD | Purpose |
|---|---|
| `authpolicies.kuadrant.io` | AuthN/AuthZ policy attached to an HTTPRoute |
| `ratelimitpolicies.kuadrant.io` | Request rate-limit policy |
| `tokenratelimitpolicies.kuadrant.io` | LLM-token quota policy (prompt + completion) |
| `tlspolicies.kuadrant.io` | Automated TLS via cert-manager |
| `dnspolicies.kuadrant.io` | Automated DNS record management |
| `apikeys.devportal.kuadrant.io` | API key lifecycle management |

### Step 4 — Create MaaS Gateway
Creates the **Gateway API `Gateway`** resource that the MaaS controller expects at `openshift-ingress/maas-default-gateway`. RHOAI does **not** auto-create this; without it the `Tenant/default-tenant` reconciliation fails.

The gateway uses `data-science-gateway-class` (whose controller is the built-in `openshift.io/gateway-controller`) and references a ConfigMap (`maas-default-gateway-config`) that instructs OpenShift to auto-generate a TLS certificate for the gateway's service via the `service.beta.openshift.io/serving-cert-secret-name` annotation. It carries two annotations required by the official docs: `opendatahub.io/managed: "false"` (so the ODH Model Controller doesn't override MaaS-managed auth policies) and `security.opendatahub.io/authorino-tls-bootstrap: "true"` (triggers an `EnvoyFilter` for TLS between the Gateway and Authorino).

The Gateway's own backing Service is `ClusterIP` — it has no external IP by itself. This step also creates an OpenShift `Route` (`maas-default-gateway` in `openshift-ingress`, host `maas.<apps-domain>`) so the gateway — and everything behind it, including `maas-api` and every published model — is reachable from outside the cluster.

```
manifests/06b-maas-gateway-configmap.yaml   # ConfigMap triggering OCP TLS cert generation
manifests/06c-maas-gateway.yaml             # Gateway resource (openshift-ingress namespace)
manifests/06g-maas-gateway-route.yaml       # External Route (host templated with the cluster's apps domain)
```

### Step 5 — Enable Authorino TLS
RHCL deploys Authorino with TLS **disabled** by default. MaaS requires Authorino's gRPC listener to use TLS, and — because the Gateway carries the `security.opendatahub.io/authorino-tls-bootstrap` annotation (Step 4), which makes `maas-controller` create an `EnvoyFilter` that trusts the cluster's **internal service-ca** for the Envoy↔Authorino connection — Authorino's own server cert must be issued by that same CA, not a self-signed one. This step:

1. Annotates the `authorino-authorino-authorization` Service with `service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert`, so OpenShift's service-ca operator issues a cert into that Secret
2. Patches the `Authorino` CR to enable TLS and point `certSecretRef` at `authorino-server-cert`
3. Sets `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` on the Authorino deployment so its own outbound HTTPS calls (e.g. `maas-api` API-key validation) also trust the cluster CA

> Using a self-signed cert-manager cert here instead (an earlier version of this script did) causes the Envoy↔Authorino gRPC handshake to fail with `gRPC status code is not OK`, and every MaaS API call — including minting API keys — returns a generic 500.

### Step 6 — Deploy PostgreSQL
`maas-api` requires a PostgreSQL database. This step deploys a single-replica PostgreSQL 15 StatefulSet in a dedicated `maas-db` namespace using the OpenShift internal image registry, and creates the `maas-db-config` Secret in `redhat-ods-applications` containing the connection URL.

```
manifests/06d-maas-postgresql.yaml   # Namespace, Secret, StatefulSet, Service, DB config Secret
```

> For production, replace this with a managed PostgreSQL instance (RDS, CrunchyData Postgres Operator, etc.) and update the `DB_CONNECTION_URL` in the Secret accordingly.

### Step 7 — Enable User Workload Monitoring
MaaS uses OpenShift User Workload Monitoring for Showback/FinOps dashboards. This step creates (or verifies) the `cluster-monitoring-config` ConfigMap in `openshift-monitoring` with `enableUserWorkload: true`.

```
manifests/06f-user-workload-monitoring.yaml
```

### Step 8 — Enable MaaS in the DataScienceCluster
Patches the `DataScienceCluster` to set:

```yaml
spec:
  components:
    kserve:
      modelsAsService:
        managementState: Managed
```

This activates the MaaS platform layer. The RHOAI operator then deploys `maas-controller` and `maas-api`, and creates the `Tenant/default-tenant` CR in `models-as-a-service`.

While waiting for the DSC to become Ready, this step also applies
`manifests/06h-maas-api-rbac-workaround.yaml` as soon as `models-as-a-service` exists —
see [maas-api in CrashLoopBackOff](#maas-api-in-crashloopbackoff) in Troubleshooting for why
this is necessary (a version-skew bug between `maas-api`'s mutable `:latest` image tag and
the pinned `maas-controller` that generates its RBAC).

### Step 9 — Enable GenAI Studio
Patches `OdhDashboardConfig/odh-dashboard-config` to set `spec.dashboardConfig.genAiStudio: true`, which surfaces the GenAI Studio section (including the GenAI Playground) in the RHOAI dashboard.

### Step 10 — Enable LlamaStack operator
Patches the `DataScienceCluster` to set:

```yaml
spec:
  components:
    llamastackoperator:
      managementState: Managed
```

The GenAI Playground needs both this **and** Step 9's `genAiStudio` flag — `genAiStudio` alone only unlocks the UI section; without the LlamaStack operator Managed, the playground has no distribution to connect to. Waits for DSC condition `LlamaStackOperatorReady: True`.

### Step 11 — Verify MaaS components
Waits for and checks that the following are all Running:

- `model-serving-api` (REST catalogue, port 8443)
- `llmisvc-controller-manager`
- `maas-api` (requires PostgreSQL connectivity)
- `maas-controller`
- `GatewayConfig/default-gateway` (condition: `GatewayConfigReady`)
- DSC condition: `ModelsAsServiceReady: True`

### Step 12 — Create model namespace
Creates the `maas-models` namespace with the `opendatahub.io/dashboard: "true"` label so it appears in the RHOAI dashboard.

### Step 13 (optional) — Deploy example resources
Not part of `setup-maas.sh` — run `./deploy-example-workload.sh` separately once the platform is up. Deploys:

- `llama-3-8b` LLMInferenceService (llama-3.1-8B-Instruct FP8, OCI modelcar from `registry.redhat.io/rhelai1`)
- `MaaSModelRef` — publishes the model to MaaS (discoverable via `GET /maas-api/v1/models`)
- `MaaSSubscription` — grants `system:authenticated` a 100,000-tokens/24h quota
- `MaaSAuthPolicy` — grants `system:authenticated` API-gateway access to the model
- `LlamaStackDistribution` for the GenAI Playground, unless `--skip-llamastack` is passed

> **GPU requirement:** The example model requires a GPU node with FP8 support (NVIDIA H100/H200 recommended). Resources are sized to the cluster HardwareProfile: 2–4 CPU, 4–8 GiB memory, 1 GPU. On clusters without a matching GPU node the pod will remain Pending — the HTTPRoute and MaaS governance (MaaSModelRef/MaaSSubscription/MaaSAuthPolicy) are still created and verifiable.
>
> **Pull secret:** The OCI modelcar image is pulled from `registry.redhat.io` using the cluster's global pull secret — no HuggingFace token or additional Secret is required.

---

## Repository layout

```
maas-rhoai/
├── setup-maas.sh                              # Platform bootstrap (operators, gateway, DSC, dashboard flags)
├── deploy-example-workload.sh                 # Example model, MaaS governance (ModelRef/Subscription/AuthPolicy), LlamaStack playground
├── teardown-maas.sh                           # Removes everything the above create
├── fix-lsd-genai-playground.sh                # Repairs a dashboard-created LlamaStackDistribution's vLLM TLS scheme (see LSD-WORKAROUND.md)
├── README.md                                  # This file
├── TEARDOWN-README.md                         # Detailed teardown reference (flags, removal tables, manual cleanup recipes)
├── LSD-WORKAROUND.md                          # GenAI Playground vLLM TLS bug: root cause + fix
├── lib/
│   └── common.sh                              # Shared logging / oc-polling helpers, sourced by all 3 scripts
└── manifests/
    ├── 01-cert-manager-namespace.yaml         # cert-manager-operator namespace
    ├── 02-cert-manager-operatorgroup.yaml     # OperatorGroup for cert-manager
    ├── 03-cert-manager-subscription.yaml      # cert-manager subscription (stable-v1)
    ├── 04-rhcl-subscription.yaml              # RHCL subscription (stable)
    ├── 05-kuadrant-namespace.yaml             # kuadrant-system namespace
    ├── 06-kuadrant-cr.yaml                    # Kuadrant instance (triggers sub-components)
    ├── 06b-maas-gateway-configmap.yaml        # ConfigMap for gateway TLS cert annotation
    ├── 06c-maas-gateway.yaml                  # maas-default-gateway Gateway resource
    ├── 06d-maas-postgresql.yaml               # PostgreSQL for maas-api + DB config Secret
    ├── 06f-user-workload-monitoring.yaml      # Enables OpenShift User Workload Monitoring
    ├── 06g-maas-gateway-route.yaml            # External Route exposing the gateway (host templated)
    ├── 06h-maas-api-rbac-workaround.yaml      # Workaround for maas-api/maas-controller image version-skew (see Troubleshooting)
    ├── 07-model-namespace.yaml                # maas-models namespace
    ├── 08-example-llminferenceservice.yaml    # Example LLMInferenceService (llama-3.1-8B FP8, OCI)
    ├── 09-example-maas-modelref.yaml          # MaaSModelRef publishing the model to MaaS
    ├── 10-example-maas-subscription.yaml      # MaaSSubscription (token quota + owner groups/users)
    ├── 11-example-maas-auth-policy.yaml       # MaaSAuthPolicy (API-gateway access grant)
    └── 13-llamastack-distribution.yaml        # LlamaStack distribution for the GenAI Playground
```

---

## Deploying your own model

After the platform is configured, deploying a new LLM is a three-step process: create the
`LLMInferenceService`, publish it to MaaS with the three MaaS-native CRDs, then call it.

### 1. Create the LLMInferenceService

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: my-llm
  namespace: maas-models
  annotations:
    opendatahub.io/hardware-profile-name: local-gpu
    opendatahub.io/hardware-profile-namespace: redhat-ods-applications
    opendatahub.io/model-type: generative
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/genai-asset: "true"
spec:
  model:
    name: my-llm
    uri: oci://registry.redhat.io/rhelai1/modelcar-llama-3-1-8b-instruct-fp8-dynamic:1.5
  replicas: 1
  router:
    gateway:
      refs:
      - name: maas-default-gateway
        namespace: openshift-ingress
    route: {}
    scheduler: {}
  template:
    containers:
    - name: main
      env:
      - name: VLLM_ADDITIONAL_ARGS
        value: --max-model-len=16000 --enable-auto-tool-choice --tool-call-parser=llama3_json
      resources:
        requests:
          cpu: "2"
          memory: 4Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "4"
          memory: 8Gi
          nvidia.com/gpu: "1"
```

> **Key spec notes** (derived from the RHOAI dashboard-created structure):
> - Resources go in `spec.template.containers[].resources`, **not** in `spec.worker`
> - `spec.router.gateway.refs` must point to the `maas-default-gateway` in `openshift-ingress`
> - `spec.model.name` is the model identifier exposed in the OpenAI API `model` field
> - `VLLM_ADDITIONAL_ARGS` controls vLLM startup flags; adjust `--max-model-len` for your GPU VRAM

```bash
oc apply -f my-llm.yaml
# Monitor status
oc get llminferenceservice my-llm -n maas-models -w
# Check the HTTPRoute created by the controller
oc get httproute -n maas-models
```

### 2. Publish it to MaaS

Three MaaS-native custom resources, applied in order (see §1.17.2 of the official docs):

```bash
# MaaSModelRef — publishes the model (replace 'my-llm' throughout)
oc apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: my-llm
  namespace: maas-models
spec:
  modelRef:
    kind: LLMInferenceService
    name: my-llm
EOF

# MaaSSubscription — token quota and eligible groups/users (must live in models-as-a-service)
oc apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: my-llm-free
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: data-scientists
  modelRefs:
    - name: my-llm
      namespace: maas-models
      tokenRateLimits:
        - limit: 100000
          window: 24h
  priority: 10
EOF

# MaaSAuthPolicy — grants the same groups/users API-gateway access (independent
# resource — keep subjects in sync with the subscription's owner if either changes)
oc apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: my-llm-access
  namespace: models-as-a-service
spec:
  subjects:
    groups:
      - name: data-scientists
  modelRefs:
    - name: my-llm
      namespace: maas-models
EOF
```

Verify:
```bash
oc get maasmodelref my-llm -n maas-models -o jsonpath='{.status.phase}'   # expect: Ready
oc get maasauthpolicy my-llm-access -n models-as-a-service -o jsonpath='{.status.phase}'   # expect: Active
```

### 3. Call the API

Inference goes through the single MaaS gateway hostname, authenticated with a **MaaS API
key** (not a raw OpenShift bearer token) — mint one against the management API first:

```bash
APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_URL="https://maas.${APPS_DOMAIN}"
TOKEN=$(oc whoami -t)

# Mint an API key scoped to your subscription
API_KEY=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"my-key","subscription":"my-llm-free","expiresIn":"30d"}' | jq -r .key)

# List models available to you
curl -sk -H "Authorization: Bearer ${API_KEY}" "${MAAS_URL}/maas-api/v1/models" | jq

# Call the model — path is /<namespace>/<model-name>/v1/..., not /llm/<model-name>/v1/...
# (that's what the official docs describe, but it isn't wired up as an HTTPRoute on
# every RHOAI 3.4.x build — check `oc get httproute -n <namespace>` if this 404s for you)
curl -sk -H "Authorization: Bearer ${API_KEY}" \
  "${MAAS_URL}/maas-models/my-llm/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "my-llm",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

---

## Teardown

`teardown-maas.sh` removes everything `setup-maas.sh` (and `deploy-example-workload.sh`) created.

```bash
./teardown-maas.sh            # interactive, prompts for confirmation
./teardown-maas.sh --yes      # skip the confirmation prompt
./teardown-maas.sh --full     # also uninstall cert-manager and RHCL/Kuadrant operators
```

### What gets removed

- All `LlamaStackDistribution`, `LLMInferenceService`, and `MaaSModelRef` resources in `maas-models`, then the `maas-models` namespace itself
- `MaaSSubscription`/`MaaSAuthPolicy` for the example model in `models-as-a-service` (the namespace itself is left in place — it's owned by RHOAI)
- DSC `kserve.modelsAsService` reverted to `Removed`
- DSC `llamastackoperator` reverted to `Removed` — **conditionally**: since `llamastackoperator` is a cluster-scoped DSC component that may back LlamaStack workloads outside MaaS, the script first deletes the MaaS `LlamaStackDistribution` and then checks `oc get llamastackdistribution -A` cluster-wide. It only reverts the operator to `Removed` if none remain; otherwise it logs a warning and leaves it `Managed`.
- Gateway `maas-default-gateway`, its external `Route`, and its ConfigMap, all in `openshift-ingress`
- Authorino TLS patch reverted; `serving-cert-secret-name` annotation removed from the Authorino Service; Secret `authorino-server-cert` deleted (plus any leftover cert-manager `Certificate`/`ClusterIssuer` from older versions of this script)
- PostgreSQL (`maas-db` namespace + `maas-db-config` Secret)

With `--full`, the cert-manager and RHCL/Kuadrant operators (Subscriptions, CSVs, OperatorGroups, namespaces) are uninstalled as well.

### Not removed in either mode

- RHOAI operator and the DataScienceCluster itself (pre-existing)
- `cluster-monitoring-config` (may be used by other workloads)
- `models-as-a-service` namespace (RHOAI cleans it up after the DSC reconciles — can get stuck `Terminating` if `maas-controller` is unhealthy when the `Tenant` CR's finalizer needs to run; see [TEARDOWN-README.md](TEARDOWN-README.md#force-delete-a-stuck-namespace) for the force-delete procedure)

---

## Troubleshooting

### Tenant/default-tenant stuck in Pending phase
The `maas-controller` creates `default-tenant` referencing `openshift-ingress/maas-default-gateway`. If the gateway doesn't exist or is not Programmed, the tenant stays Pending.
```bash
oc describe tenant default-tenant -n models-as-a-service
oc get gateway maas-default-gateway -n openshift-ingress
```

### maas-api in CrashLoopBackOff
Check the logs first to tell which of the two known causes it is:
```bash
oc get pods -n maas-db
oc logs -n redhat-ods-applications -l app.kubernetes.io/name=maas-api --tail=50
```

**Cause 1 — PostgreSQL not yet reachable.** If the log shows connection errors to
`maas-db`, PostgreSQL likely isn't ready yet. Once it's up, delete the pod to skip
exponential backoff:
```bash
oc delete pod -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
```

**Cause 2 — RBAC forbidden error (`maasauthpolicies is forbidden ... cannot list
resource`).** This is a version-skew bug, not a config mistake: `maas-api`'s Deployment
(created by `maas-controller`'s bundled kustomize overlay) uses the mutable tag
`quay.io/opendatahub/maas-api:latest` with `imagePullPolicy: Always`, while
`maas-controller` — the component that generates `maas-api`'s RBAC — is pinned to a fixed
Red Hat digest. Whenever the pod is recreated (e.g. after a teardown/setup cycle), it
re-pulls whatever `:latest` currently is upstream; if that build is ahead of what the
pinned `maas-controller` grants (e.g. a new watch on `MaaSAuthPolicy`, or on the
cluster-scoped `apiservers.config.openshift.io` for the TLS profile — the latter is
non-fatal and just falls back to a default TLS profile), `maas-api` crash-loops instead
of starting, which blocks `ModelsAsServiceReady` and thus overall DSC `Ready`.

`setup-maas.sh` now applies a defensive workaround automatically
(`manifests/06h-maas-api-rbac-workaround.yaml`, granting `maas-api`'s ServiceAccount the
missing permissions directly) as soon as the `models-as-a-service` namespace exists during
Step 8, and force-restarts `maas-api` if it isn't yet available so it doesn't have to wait
out crash-loop backoff. If you still see this after an up-to-date `setup-maas.sh` run,
re-apply it manually and restart:
```bash
oc apply -f manifests/06h-maas-api-rbac-workaround.yaml
oc rollout restart deployment/maas-api -n redhat-ods-applications
```

### Authorino TLS errors / MaaS auth not working
```bash
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='{.spec.listener.tls}' | python3 -m json.tool
oc get secret authorino-server-cert -n kuadrant-system
oc logs -n kuadrant-system -l control-plane=controller-manager --tail=50
```
`certSecretRef.name` must be `authorino-server-cert` (issued by the OpenShift service-ca
operator). If it's a different, self-signed secret, every MaaS API call will 500 with
`gRPC status code is not OK` in the gateway's Envoy logs — the Envoy↔Authorino handshake
fails because the `EnvoyFilter` `maas-default-gateway-authn-ssl` only trusts the cluster's
internal service-ca, not an arbitrary self-signed one. Re-run `configure_authorino_tls()`'s
steps manually (see Step 5 above) to fix it.

### DSC stuck / ModelsAsServiceReady never True
```bash
oc describe dsc default-dsc -n redhat-ods-operator | tail -40
oc get pods -n redhat-ods-applications
```

### KserveLLMInferenceServiceDependencies = False
cert-manager or RHCL not fully ready yet. Wait a few minutes:
```bash
oc get dsc default-dsc -n redhat-ods-operator \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

### Kuadrant not Ready
```bash
oc describe kuadrant kuadrant -n kuadrant-system | tail -30
oc get pods -n kuadrant-system
```

### InstallPlan stuck in Manual approval
Some clusters enforce Manual approval for all InstallPlans. The script handles this automatically, but if needed:
```bash
oc get installplan -n openshift-operators
oc patch installplan <name> -n openshift-operators --type=merge -p '{"spec":{"approved":true}}'
```

### LLMInferenceService pod not scheduling
```bash
oc get llminferenceservice -n maas-models
oc get pods -n maas-models
oc describe pod -n maas-models <pod-name>
```
Common causes: no GPU node with FP8 support available, insufficient memory, OCI pull secret not configured for `registry.redhat.io`.

### MaaSAuthPolicy / MaaSSubscription not granting access
```bash
oc get maasmodelref,maasauthpolicy,maassubscription -A
oc get maasauthpolicy <name> -n models-as-a-service -o jsonpath='{.status.phase}'   # expect: Active
oc get maasmodelref <name> -n <namespace> -o jsonpath='{.status.phase}'             # expect: Ready
```
Authorization and subscription are independent resources — if you change a subscription's
groups/models, update the matching `MaaSAuthPolicy` too (they're not auto-synced). Check the
underlying gateway-level Kuadrant enforcement if both show healthy but requests still fail:
```bash
oc get authpolicy -n openshift-ingress
oc logs -n kuadrant-system -l control-plane=controller-manager --tail=50
```

### External API calls fail: "Application is not available" (503) or connection refused
This means the request never reached the MaaS gateway at all — either DNS for
`maas.<apps-domain>` doesn't resolve to your cluster, or the Route isn't admitted:
```bash
oc get route maas-default-gateway -n openshift-ingress
# STATUS should NOT show RouteNotAdmitted or Pending
```
If the Route shows `RouteNotAdmitted`, check whether it's colliding with a wildcard-route
policy issue (`oc logs -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default | grep wildcard`)
— `06g-maas-gateway-route.yaml` uses a single fixed hostname specifically to avoid needing
`WildcardsAllowed` on the cluster's `IngressController`, so this shouldn't happen; if it does,
something else already claimed that Route/host.

### Inference call returns 404: `/llm/<model-name>/v1/...`
The official docs describe `/llm/<model-name>/v1/...` as the inference path, but on some
RHOAI 3.4.x builds no `HTTPRoute` actually implements that prefix — check with
`oc get httproute -A -o json | jq -r '.items[].spec.rules[].matches[]?.path.value'`. The path
that's actually wired up is the one KServe generates for the `LLMInferenceService` itself:
`/<namespace>/<model-name>/v1/chat/completions` (e.g. `/maas-models/llama-3-8b/v1/chat/completions`
for the example model — this is what `deploy-example-workload.sh`'s summary and `setup-maas.sh`'s
"Next steps" print). Also make sure `-H "Content-Type: application/json"` is set — `maas-api`
returns a 400 "Unsupported Media Type" without it, which is easy to mistake for a routing issue.

### GenAI Playground chat fails with "Server disconnected without sending a response"
`LLMInferenceService` workload pods always serve TLS on port 8000 (via `SSLCertRefresher`), but a
`LlamaStackDistribution` created through the RHOAI **dashboard** generates its vLLM provider
`base_url` with `http://`, causing every inference call to fail. `manifests/13-llamastack-distribution.yaml`
already uses `https://` (fixed 2026-07-25), so this shouldn't happen via `./deploy-example-workload.sh`.
If you hit it on a dashboard-created LlamaStack instance, see [LSD-WORKAROUND.md](LSD-WORKAROUND.md)
or run `./fix-lsd-genai-playground.sh [NAMESPACE] [LSD_NAME]`.

### Check all MaaS component status at once
```bash
oc get dsc default-dsc -n redhat-ods-operator \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\n"}{end}'
oc get pods -n redhat-ods-applications -l app.kubernetes.io/part-of=maas
oc get pods -n kuadrant-system
oc get pods -n maas-db
oc get gateway maas-default-gateway -n openshift-ingress
oc get tenant default-tenant -n models-as-a-service
```

---

## References

- [RHOAI 3.4 — Govern LLM access with MaaS](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index)
- [Red Hat Connectivity Link (Kuadrant) documentation](https://docs.kuadrant.io)
- [KServe LLMInferenceService API](https://kserve.github.io/website/latest/reference/api/)
- [OpenShift cert-manager operator](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
- [Gateway API specification](https://gateway-api.sigs.k8s.io/)
