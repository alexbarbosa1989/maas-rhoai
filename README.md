# RHOAI Models-as-a-Service (MaaS) Automation

Automates the full MaaS configuration on **Red Hat OpenShift AI 3.4.x and 3.5+**, following
the rh-aiservices-bu [rhoai-maas-guide](https://rh-aiservices-bu.github.io/rhoai-maas-guide/)
companion guide's Gateway approach and the official documentation:
[Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index).

## DISCLAIMER: this is not a official Red Hat procedure. It was build only for learning purposes
---

## What MaaS does

MaaS lets a **platform team** deploy LLMs once and expose them as governed, subscription-based API endpoints through a single gateway hostname (`maas.<apps-domain>`). User teams (data scientists, developers) mint a MaaS API key and call `https://maas.<apps-domain>/<namespace>/<model-name>/v1/...`, automatically subject to:

| Feature | Mechanism |
|---|---|
| Publishing | `MaaSModelRef` — registers an `LLMInferenceService` (or `ExternalModel`) with MaaS |
| Authorization | `MaaSAuthPolicy` — grants groups/users API-gateway access to specific models |
| Quota / rate limiting | `MaaSSubscription` — token-rate-limit quotas per group/user, with priority tiers |
| Authentication | MaaS API keys (`sk-oai-...`) or OpenShift/OIDC bearer tokens for the management API |
| TLS | cert-manager + the cluster's own ingress/service-serving certificates |

Underneath, these MaaS-native CRDs are enforced by RHCL (Kuadrant) `AuthPolicy`/`TokenRateLimitPolicy` objects that the platform manages automatically at the gateway level — you configure MaaS resources, not raw Kuadrant policies, for model governance.

---

## Architecture

```
Data Scientist / App
       │
       │  HTTPS — one hostname: maas.<apps-domain>
       │  (OpenShift bearer token for /maas-api/*, MaaS API key for inference)
       ▼
┌──────────────────────────────────────────────────────────┐
│  Gateway: maas-default-gateway (openshift-ingress)       │
│  gatewayClassName: openshift-default                      │
│  TLS: cluster's existing default ingress certificate      │
│  Service: LoadBalancer (cloud-native, or MetalLB on       │
│    non-cloud — auto-installed) + passthrough Route on     │
│    non-cloud platforms                                    │
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

`maas-api`'s namespace differs by RHOAI version: `redhat-ods-applications` on 3.4.x,
`redhat-ai-gateway-infra` on 3.5+ (the script and its Troubleshooting docs branch on this
automatically — RHOAI version is auto-detected, never asked).

### Key components

| Component | Namespace | Purpose |
|---|---|---|
| RHOAI Operator | `redhat-ods-operator` | Manages all RHOAI components via DSC |
| llmisvc-controller | `redhat-ods-applications` | Reconciles `LLMInferenceService` CRs |
| model-serving-api | `redhat-ods-applications` | REST catalogue API for MaaS |
| maas-api | `redhat-ods-applications` (3.4.x) / `redhat-ai-gateway-infra` (3.5+) | MaaS platform API (requires PostgreSQL) |
| maas-controller | `redhat-ods-applications` | Reconciles Tenant, MaaSModelRef, MaaSSubscription, and MaaSAuthPolicy CRs |
| maas-default-gateway | `openshift-ingress` | Gateway API entry point for model endpoints (`openshift-default` GatewayClass) |
| MetalLB | `metallb-system` | LoadBalancer provider for the Gateway's Service, auto-installed on non-cloud platforms only |
| cert-manager | `cert-manager-operator` | TLS certificate automation |
| Kuadrant / RHCL | `kuadrant-system` | Auth, rate-limiting, DNS, TLS policies |
| Authorino | `kuadrant-system` | Token review engine (must run with TLS) |
| PostgreSQL | `maas-db` | Backing store for maas-api |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift 4.19.9+ (ROSA, self-managed, CRC all supported) | Any flavour; cluster-admin access required |
| RHOAI 3.4.0+ or 3.5+ installed | Operator + DSC + DSCI must exist; version auto-detected |
| A LoadBalancer provider | Native on cloud platforms (AWS/Azure/GCP/IBM Cloud); on every other platform (bare-metal, on-prem, SNO, CRC) the script installs and configures **MetalLB automatically** unless `--skip-metallb` is passed |
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

# 3. Run the automation (installs everything end-to-end, including MetalLB on non-cloud)
./setup-maas.sh

# 4. Optionally deploy an example workload: an LLMInferenceService (llama-3.1-8B FP8,
#    needs a GPU node) plus its MaaS governance (MaaSModelRef/MaaSSubscription/
#    MaaSAuthPolicy) — publishes it behind the gateway with a working quota/auth
#    policy, ready to call. Prints copy-paste-ready commands to mint an API key and
#    call the model when it finishes.
./deploy-example-workload.sh
```

`deploy-example-workload.sh` is deliberately a separate script from `setup-maas.sh` — the
platform layer (operators, gateway, Authorino TLS, DSC/dashboard flags) is close to one-shot,
while this example workload is something you'll likely redeploy, tweak, or tear down
independently many times. Re-running it is idempotent. It auto-detects a GPU
`HardwareProfile` in your cluster, or creates a minimal one named `nvidia-gpu` if none
exists; pass `--hardware-profile-name <name>` to use a specific one instead, or see
`./deploy-example-workload.sh --help`. Once it
completes, see [Deploying your own model](#deploying-your-own-model) below to walk through
the same steps by hand for a model of your own, or [Call the API, §3](#3-call-the-api) for
the exact `curl` commands against the example model it just deployed.

### Flags

`setup-maas.sh`:

| Flag | Description |
|---|---|
| `--skip-operators` | Skip both cert-manager and RHCL operator installation |
| `--skip-cert-manager` | Skip cert-manager installation only |
| `--skip-rhcl` | Skip RHCL operator installation only (Kuadrant CR/Authorino TLS still runs) |
| `--skip-kuadrant` | Skip Kuadrant CR creation and Authorino TLS config entirely |
| `--skip-metallb` | Skip MetalLB install (non-cloud platforms only; use if already installed, or using a different LoadBalancer provider) |
| `--metallb-ip-range RANGE` | Override the auto-derived MetalLB address pool (default: first node's own InternalIP + 1 on the last octet) |
| `--extra-gateway-namespace NS` | Label an additional namespace for Gateway route binding (repeatable) |
| `--help` | Show usage |

`deploy-example-workload.sh` (run after `setup-maas.sh`):

| Flag | Description |
|---|---|
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
export AI_GATEWAY_INFRA_NS=redhat-ai-gateway-infra  # maas-api namespace on RHOAI 3.5+
export METALLB_NS=metallb-system               # MetalLB operator namespace (non-cloud only)
export METALLB_IP_RANGE=                       # MetalLB address pool (empty = auto-derive)
export OPERATOR_WAIT_TIMEOUT=600               # Seconds to wait for operators
export POD_WAIT_TIMEOUT=300                    # Seconds to wait for pods
export GATEWAY_WAIT_TIMEOUT=120                # Seconds to wait for the Gateway to be Programmed

# deploy-example-workload.sh only:
export MODEL_WAIT_TIMEOUT=600                  # Seconds to wait for the example model/LlamaStack pod
export HARDWARE_PROFILE_NAME=                  # GPU HardwareProfile to use (same as --hardware-profile-name)
```

---

## What the script does (summary)

`setup-maas.sh` runs 17 steps end-to-end: prerequisites → cert-manager → RHCL → Kuadrant +
Authorino TLS → User Workload Monitoring → **MetalLB (non-cloud only, Step 7)** →
`openshift-default` GatewayClass → Gateway (LoadBalancer Service, hostname
`maas.<apps-domain>` set directly on the listener) → namespace labeling for route binding →
passthrough Route (non-cloud only) → PostgreSQL → MaaS enabled in the DSC
(`kserve.modelsAsService` on 3.4.x, `aigateway`/`aigateway.modelsAsAService` on 3.5+) →
GenAI Studio → Playground backend (`llamastackoperator` on 3.4.x, `ogx` on 3.5+) →
component verification → model namespace creation.

Platform detection (cloud vs. non-cloud, which decides whether MetalLB is installed) is
always automatic — read from `oc get infrastructure cluster -o jsonpath='{.status.platform}'`
— never prompted.

---

## Repository layout

```
maas-rhoai/
├── setup-maas.sh                              # Platform bootstrap (operators, gateway, MetalLB, DSC, dashboard flags)
├── deploy-example-workload.sh                 # Example model + MaaS governance (ModelRef/Subscription/AuthPolicy)
├── external-model-example.sh                  # Configures a MaaS-governed EXTERNAL model (e.g. GPT-5/OpenAI), RHOAI 3.5+
├── teardown-maas.sh                           # Removes everything the above create
├── maas-observability/                        # Optional: usage/showback dashboard add-on — see maas-observability/README.md
├── README.md                                  # This file
├── TEARDOWN-README.md                         # Detailed teardown reference (flags, removal tables, manual cleanup recipes)
├── lib/
│   └── common.sh                              # Shared logging / oc-polling helpers, sourced by all scripts
└── manifests/
    ├── 01-cert-manager-namespace.yaml         # cert-manager-operator namespace
    ├── 02-cert-manager-operatorgroup.yaml     # OperatorGroup for cert-manager
    ├── 03-cert-manager-subscription.yaml      # cert-manager subscription (stable-v1)
    ├── 01-kuadrant-namespace.yaml             # kuadrant-system namespace
    ├── 02-authorino-service-annotation.yaml   # Authorino Service, annotated for service-ca TLS
    ├── 03-kuadrant-cr.yaml                    # Kuadrant instance (triggers sub-components)
    ├── 04-rhcl-subscription.yaml              # RHCL subscription (stable)
    ├── 04-uwm-configmap.yaml                  # Enables OpenShift User Workload Monitoring
    ├── 05-gatewayclass.yaml                   # openshift-default GatewayClass
    ├── 06-gateway-resources-configmap.yaml    # ConfigMap raising the Gateway's Envoy memory limit
    ├── 06d-maas-postgresql.yaml               # PostgreSQL for maas-api + DB config Secret
    ├── 06h-maas-api-rbac-workaround.yaml      # Workaround for maas-api/maas-controller image version-skew, RHOAI 3.4.x only (see Troubleshooting)
    ├── 07-gateway.yaml.tmpl                   # maas-default-gateway Gateway resource (single HTTPS listener)
    ├── 07-model-namespace.yaml                # maas-models namespace
    ├── 08-example-llminferenceservice.yaml    # Example LLMInferenceService (llama-3.1-8B FP8, OCI)
    ├── 08-route.yaml.tmpl                     # Passthrough Route exposing the gateway (non-cloud platforms only)
    ├── 09-example-maas-modelref.yaml          # MaaSModelRef publishing the model to MaaS
    ├── 09-metallb-namespace.yaml              # MetalLB operator namespace/OperatorGroup/Subscription (non-cloud only)
    ├── 10-example-maas-subscription.yaml      # MaaSSubscription (token quota + owner groups/users)
    ├── 10-metallb-instance.yaml               # MetalLB CR (deploys controller + speaker pods)
    ├── 11-example-maas-auth-policy.yaml       # MaaSAuthPolicy (API-gateway access grant)
    ├── 11-metallb-pool.yaml.tmpl              # MetalLB IPAddressPool + L2Advertisement
    ├── 13-llamastack-distribution.yaml        # LlamaStack distribution for the GenAI Playground (3.4.x)
    └── 14-ogx-server.yaml                     # OGXServer for the GenAI Playground (3.5+)
```

---

## Deploying your own model

After the platform is configured, deploying a new LLM is a three-step process: create the
`LLMInferenceService`, publish it to MaaS with the three MaaS-native CRDs, then call it.

The example below uses the exact same names/values as the `llama-3-8b` model that
`deploy-example-workload.sh` deploys (see `manifests/08-example-llminferenceservice.yaml`
through `11-example-maas-auth-policy.yaml`) — so every command here is copy-paste-safe
against a cluster that already ran that script, and doubles as a working reference you can
diff your own model's names against. **To deploy a genuinely different model**, replace
`llama-3-8b` (and `llama-3-8b-free` / `llama-3-8b-access`) throughout with your own model's
name — just make sure the same name is used consistently across all four resources below and
in the API calls, since a mismatch (e.g. minting a key against a subscription name that
doesn't exist) fails with an easy-to-miss error — see
[Minting an API key returns no `.key` field](#minting-an-api-key-returns-no-key-field-jq--r-key-prints-null)
in Troubleshooting.

### 1. Create the LLMInferenceService

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: llama-3-8b
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
    name: llama-3-8b
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
          cpu: "1"
          memory: 4Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "1"
          memory: 8Gi
          nvidia.com/gpu: "1"
```

> **Key spec notes** (derived from the RHOAI dashboard-created structure):
> - Resources go in `spec.template.containers[].resources`, **not** in `spec.worker`
> - `spec.router.gateway.refs` must point to the `maas-default-gateway` in `openshift-ingress`
> - `spec.model.name` is the model identifier exposed in the OpenAI API `model` field
> - `VLLM_ADDITIONAL_ARGS` controls vLLM startup flags; adjust `--max-model-len` for your GPU VRAM

```bash
oc apply -f llama-3-8b.yaml
# Monitor status
oc get llminferenceservice llama-3-8b -n maas-models -w
# Check the HTTPRoute created by the controller
oc get httproute -n maas-models
```

### 2. Publish it to MaaS

Three MaaS-native custom resources, applied in order — matching
`manifests/09-example-maas-modelref.yaml` through `11-example-maas-auth-policy.yaml`:

```bash
# MaaSModelRef — publishes the model
oc apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: llama-3-8b
  namespace: maas-models
spec:
  modelRef:
    kind: LLMInferenceService
    name: llama-3-8b
EOF

# MaaSSubscription — token quota and eligible groups/users (must live in models-as-a-service)
oc apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: llama-3-8b-free
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: system:authenticated
  modelRefs:
    - name: llama-3-8b
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
  name: llama-3-8b-access
  namespace: models-as-a-service
spec:
  subjects:
    groups:
      - name: system:authenticated
  modelRefs:
    - name: llama-3-8b
      namespace: maas-models
EOF
```

Verify:
```bash
oc get maasmodelref llama-3-8b -n maas-models -o jsonpath='{.status.phase}'   # expect: Ready
oc get maasauthpolicy llama-3-8b-access -n models-as-a-service -o jsonpath='{.status.phase}'   # expect: Active
```

### 3. Call the API

Inference goes through the single MaaS gateway hostname, authenticated with a **MaaS API
key** (not a raw OpenShift bearer token) — mint one against the management API first. The
`subscription` field below must exactly match an existing `MaaSSubscription` name
(`oc get maassubscription -A`) — see the Troubleshooting note linked above if this ever
mints a key that comes back `null`:

```bash
APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_URL="https://maas.${APPS_DOMAIN}"
TOKEN=$(oc whoami -t)

# Mint an API key scoped to your subscription
API_KEY=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"my-key","subscription":"llama-3-8b-free","expiresIn":"30d"}' | jq -r .key)

# List models available to you — each has a catalog id shaped
# publishers/<namespace>/models/<model-name>; use that id (not the bare model
# name) in the call below
curl -sk -H "Authorization: Bearer ${API_KEY}" "${MAAS_URL}/maas-api/v1/models" | jq

# Call the model via the unified endpoint (model selected by the "model" field
# in the body, not by a path segment) — confirmed more reliable than the
# namespaced /<namespace>/<model-name>/v1/... path, which can intermittently
# return a 200 with an empty body due to a Kuadrant WASM rate-limit-reporting
# race (see Troubleshooting)
curl -sk -H "Authorization: Bearer ${API_KEY}" \
  "${MAAS_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "publishers/maas-models/models/llama-3-8b",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

---

## Teardown

`teardown-maas.sh` removes everything `setup-maas.sh` (and `deploy-example-workload.sh`) created. See **[TEARDOWN-README.md](TEARDOWN-README.md)** for full detail.

```bash
./teardown-maas.sh            # interactive, prompts for confirmation
./teardown-maas.sh --yes      # skip the confirmation prompt
./teardown-maas.sh --full     # also uninstall cert-manager, RHCL/Kuadrant, the openshift-default GatewayClass, and MetalLB
```

### What gets removed

- All `LlamaStackDistribution`/`OGXServer`, `LLMInferenceService`, and `MaaSModelRef` resources in `maas-models`, then the `maas-models` namespace itself
- Namespace `models-as-a-service` (owned by RHOAI/`maas-controller`) — including every `MaaSSubscription`/`MaaSAuthPolicy` inside it, not just the example's (confirmed this is **not** cleaned up automatically after DSC revert, despite RHOAI owning it)
- Namespace `ai-tenants` (another `maas-controller`-generated namespace)
- `Config/default`'s `maas.opendatahub.io/default-aitenant-bootstrapped` annotation, cleared — **critical**: `maas-controller` only ever bootstraps the default tenant (and, transitively, deploys `maas-api` itself) **once per cluster**, gated by this flag. Since deleting the two namespaces above destroys the underlying `MaasTenantConfig`/`AITenant` objects, leaving this flag `true` would permanently prevent any future `setup-maas.sh` run from ever re-provisioning them — confirmed live, even a full DSC `Removed`→`Managed` cycle does not help once this flag is stuck.
- Namespace `redhat-ai-gateway-infra` (holds `maas-api` itself on RHOAI 3.5+, owned by a *different* operator, `ai-gateway-operator` — confirmed live that reverting the DSC field does **not** trigger it to clean up on its own). No-op on 3.4.x, where this namespace never existed.
- DSC MaaS setting reverted: `kserve.modelsAsService` (3.4.x) or `aigateway`/`aigateway.modelsAsAService` (3.5+) — version auto-detected
- `genAiStudio` reverted to `false` in `OdhDashboardConfig`
- DSC Playground backend reverted to `Removed`: `llamastackoperator` (3.4.x) or `ogx` (3.5+) — **conditionally**, only if no `LlamaStackDistribution`/`OGXServer` resources remain cluster-wide (both are cluster-scoped and may back workloads outside MaaS)
- Gateway `maas-default-gateway`, its Route (`maas-default-gateway-https`), and its ConfigMap (`maas-gateway-options`), all in `openshift-ingress`
- Authorino TLS patch reverted; Secret `authorino-server-cert` deleted (plus any leftover cert-manager `Certificate`/`ClusterIssuer` from older versions of this script)
- PostgreSQL (`maas-db` namespace + `maas-db-config` Secret)

`models-as-a-service`, `ai-tenants`, and `redhat-ai-gateway-infra` are each deleted with
`--wait=false`, then swept after a 15s grace period for any `maas.opendatahub.io` resource
still stuck `Terminating` inside — confirmed live that `MaaSSubscription`/`MaaSAuthPolicy`/
`MaaSTenantConfig`/`AITenant` can all carry a `maas-controller`-owned cleanup finalizer that
never clears once whatever they referenced (model, provider, tenant) is already gone; the
script force-clears those automatically rather than leaving the namespace stuck forever.
This full teardown→setup cycle (including the bootstrap-marker reset) has been verified
live end-to-end with zero manual intervention required.

With `--full`, cert-manager, RHCL/Kuadrant, the `openshift-default` GatewayClass, and MetalLB (operator, CR, IPAddressPool) are also uninstalled — the MetalLB removal is a harmless no-op on cloud platforms, where it was never installed.

### Not removed in either mode

- RHOAI operator and the DataScienceCluster itself (pre-existing)
- `cluster-monitoring-config` (may be used by other workloads)

If `models-as-a-service`, `ai-tenants`, or `redhat-ai-gateway-infra` still stay stuck
`Terminating` despite the automatic finalizer sweep (their own namespace finalizer, not a
resource inside them), see
[TEARDOWN-README.md](TEARDOWN-README.md#force-delete-a-stuck-namespace) for the force-delete procedure.

---

## Optional: usage/showback dashboard

`maas-observability/` is a separately-lifecycled add-on (Technology Preview) that enables the
RHOAI dashboard's per-user/subscription/model token-usage and rate-limit dashboard, on top of
an already-running base platform. Not required for MaaS itself — see
[maas-observability/README.md](maas-observability/README.md) for setup and details.

---

## Troubleshooting

### Gateway stuck `Programmed: False` on a non-cloud platform
Almost always a missing or misconfigured LoadBalancer provider. Check the backing Service:
```bash
oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
```
`EXTERNAL-IP` stuck at `<pending>` means MetalLB isn't installed/running, or has no
`IPAddressPool` covering it. This is also a known upstream issue independent of MetalLB:
https://github.com/opendatahub-io/models-as-a-service/issues/331

### maas-api in CrashLoopBackOff
Check the logs first — the namespace differs by RHOAI version:
```bash
oc get pods -n maas-db
oc logs -n redhat-ods-applications -l app.kubernetes.io/name=maas-api --tail=50   # 3.4.x
oc logs -n redhat-ai-gateway-infra -l app.kubernetes.io/name=maas-api --tail=50   # 3.5+
```

**Cause 1 — PostgreSQL not yet reachable, or its schema went missing** (e.g. CRC
hostpath-provisioner storage churn recreating the `maas-db` PVC empty without `maas-api`
noticing). Restart to force a reconnect/re-migration:
```bash
oc rollout restart deployment/maas-api -n redhat-ods-applications   # 3.4.x
oc rollout restart deployment/maas-api -n redhat-ai-gateway-infra   # 3.5+
```

**Cause 2 — RBAC forbidden error (`maasauthpolicies is forbidden ... cannot list
resource`), RHOAI 3.4.x only.** A version-skew bug: `maas-api`'s Deployment uses the mutable
tag `quay.io/opendatahub/maas-api:latest`, while `maas-controller` (which generates its RBAC)
is pinned to a fixed digest. `setup-maas.sh` applies a defensive workaround automatically
(`manifests/06h-maas-api-rbac-workaround.yaml`) as soon as `models-as-a-service` exists. If
you still see this, re-apply manually:
```bash
oc apply -f manifests/06h-maas-api-rbac-workaround.yaml
oc rollout restart deployment/maas-api -n redhat-ods-applications
```

### Authorino TLS errors / MaaS auth not working
```bash
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='{.spec.listener.tls}' | python3 -m json.tool
oc get secret authorino-server-cert -n kuadrant-system
```
`certSecretRef.name` must be `authorino-server-cert` (issued by the OpenShift service-ca
operator). If it's a different, self-signed secret, every MaaS API call will 500 with
`gRPC status code is not OK` in the gateway's Envoy logs.

### Inference call returns `200` with an empty body
Confirmed live: the namespaced inference path (`/<namespace>/<model-name>/v1/chat/completions`)
can intermittently return `HTTP 200` with zero bytes of body — check with
`curl -w '%{size_download}\n'`, since a `200` status code alone doesn't guarantee a real
response on this path. The gateway pod's own logs show why, at the same timestamps:
```bash
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --since=2m \
  | grep -i "invalid context_id"
```
This is a race in Kuadrant's Envoy WASM shim: `TokenRateLimitPolicy` needs to read
`/usage/total_tokens` out of the response body to report token consumption to Limitador,
via an async gRPC call keyed by a `context_id`. Under some timing conditions that gRPC
callback can't find a matching context, and whatever continuation is supposed to release
the buffered response body to the client never fires — response headers had already gone
out, so the client sees a "successful" `200` with nothing behind it. Not fixable from this
repo; it's upstream in RHCL/Kuadrant's WASM shim.

**Workaround**: use the unified `/v1/chat/completions` endpoint instead (model selected via
the `model` field in the body, catalog id shaped `publishers/<namespace>/models/<model-name>`
— see [Deploying your own model, §3](#3-call-the-api)), which does not go through the same
HTTPRoute/TokenRateLimitPolicy path and was not observed to reproduce this in repeated
testing. If you must use the namespaced path, retry on an empty body — the race is
timing-dependent, and a retry typically succeeds.

### Minting an API key returns no `.key` field (`jq -r .key` prints `null`)
The `subscription` field in the `POST /maas-api/v1/api-keys` request body must exactly
match an existing `MaaSSubscription` name:
```bash
oc get maassubscription -A
```
An unresolvable subscription returns a `400` with no `.key` field
(`{"code":"invalid_subscription", ...}`) — `jq -r .key` on that prints the literal string
`null`, which easily reads as "nothing happened."

### Dashboard shows `http://` instead of `https://` for a model's endpoint
Fixed in `manifests/07-gateway.yaml.tmpl` (single HTTPS listener) — a Gateway created before
that fix still needs a manual patch: remove any `HTTP`/port-80 listener bound to the same
hostname as the `HTTPS` one.

### GenAI Playground chat fails with "Server disconnected without sending a response"
`LLMInferenceService` workload pods always serve TLS on port 8000, but a
`LlamaStackDistribution` created through the RHOAI **dashboard** generates its vLLM provider
`base_url` with `http://`, causing every inference call to fail. Fix: change `base_url` from
`http://` to `https://` in the LlamaStack instance's `llama-stack-config` ConfigMap, then
restart its deployment:
```bash
oc get configmap llama-stack-config -n maas-models -o jsonpath='{.data.config\.yaml}' \
  | sed 's|base_url: http://|base_url: https://|g' > /tmp/llama-stack-config-fixed.yaml
oc create configmap llama-stack-config -n maas-models \
  --from-file=config.yaml=/tmp/llama-stack-config-fixed.yaml --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment/lsd-genai-playground -n maas-models
```

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

- [rh-aiservices-bu/rhoai-maas-guide](https://rh-aiservices-bu.github.io/rhoai-maas-guide/) — the upstream procedure this repo's setup-maas.sh follows
- [RHOAI — Govern LLM access with MaaS](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index)
- [Red Hat Connectivity Link (Kuadrant) documentation](https://docs.kuadrant.io)
- [KServe LLMInferenceService API](https://kserve.github.io/website/latest/reference/api/)
- [OpenShift cert-manager operator](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
- [MetalLB documentation](https://metallb.universe.tf/)
- [Gateway API specification](https://gateway-api.sigs.k8s.io/)
