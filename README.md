# RHOAI 3.4 — Models-as-a-Service (MaaS) Automation

Automates the full MaaS configuration on **Red Hat OpenShift AI 3.4** as described in the official documentation:
[Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index)

---

## What MaaS does

MaaS lets a **platform team** deploy LLMs once and expose them as governed API endpoints. User teams (data scientists, developers) call those endpoints with their OpenShift credentials and are automatically subject to:

| Feature | Mechanism |
|---|---|
| Authentication | K8s token review (OpenShift SA/user tokens) or OIDC |
| Authorization | Kubernetes SubjectAccessReview (RBAC) |
| Rate limiting | RHCL `RateLimitPolicy` (requests/window per user) |
| Token quotas | RHCL `TokenRateLimitPolicy` (LLM tokens/day per user) |
| TLS | cert-manager + OpenShift service-serving certificates |

---

## Architecture

```
Data Scientist / App
        │
        │  HTTPS + Bearer token
        ▼
┌──────────────────────────────────────────────────┐
│  maas-default-gateway (openshift-ingress)        │
│  Gateway API / data-science-gateway-class        │
│  TLS: OpenShift service-serving cert             │
└──────────────────┬───────────────────────────────┘
                   │
          ┌────────▼────────┐
          │  Kuadrant/RHCL  │  Authorino (TLS gRPC)
          │  AuthPolicy     │  tokenreview + SAR
          │  RateLimitPolicy│  Limitador counter
          └────────┬────────┘
                   │
          ┌────────▼────────────────────────┐
          │  LLMInferenceService            │  serving.kserve.io/v1alpha2
          │  (kserve + llmisvc-controller)  │
          └─────────────────────────────────┘
```

### Key components

| Component | Namespace | Purpose |
|---|---|---|
| RHOAI Operator | `redhat-ods-operator` | Manages all RHOAI components via DSC |
| llmisvc-controller | `redhat-ods-applications` | Reconciles `LLMInferenceService` CRs |
| model-serving-api | `redhat-ods-applications` | REST catalogue API for MaaS |
| maas-api | `redhat-ods-applications` | MaaS platform API (requires PostgreSQL) |
| maas-controller | `redhat-ods-applications` | Manages Tenant / MaaSAuthPolicy CRs |
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
| RHOAI 3.4.1 installed | Operator + DSC + DSCI must exist |
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

# 4. Optionally deploy the example LLMInferenceService, governance policies,
#    RBAC, and LlamaStack playground
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

The gateway uses `data-science-gateway-class` and references a ConfigMap (`maas-default-gateway-config`) that instructs OpenShift to auto-generate a TLS certificate for the gateway's LoadBalancer service via the `service.beta.openshift.io/serving-cert-secret-name` annotation.

```
manifests/06b-maas-gateway-configmap.yaml   # ConfigMap triggering OCP TLS cert generation
manifests/06c-maas-gateway.yaml             # Gateway resource (openshift-ingress namespace)
```

### Step 5 — Enable Authorino TLS
RHCL deploys Authorino with TLS **disabled** by default. MaaS requires Authorino's gRPC listener to use TLS. This step:

1. Creates a self-signed `ClusterIssuer` (`maas-self-signed`) via cert-manager
2. Issues a `Certificate` (`authorino-tls`) in `kuadrant-system` with DNS SANs for `authorino.kuadrant-system.svc`
3. Patches the `Authorino` CR to enable TLS and point to the generated secret

```
manifests/06e-authorino-tls.yaml   # ClusterIssuer + Certificate
```

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
- `AuthPolicy` — K8s token review + SubjectAccessReview
- `RateLimitPolicy` — 10 req/10 s per user, 100 req/10 s global
- `TokenRateLimitPolicy` — 100 000 tokens/day per user
- `RoleBinding` — grants `view` ClusterRole to group `maas-users`
- `LlamaStackDistribution` for the GenAI Playground, unless `--skip-llamastack` is passed

> **GPU requirement:** The example model requires a GPU node with FP8 support (NVIDIA H100/H200 recommended). Resources are sized to the cluster HardwareProfile: 2–4 CPU, 4–8 GiB memory, 1 GPU. On clusters without a matching GPU node the pod will remain Pending — the HTTPRoute and governance policies are still created and verifiable.
>
> **Pull secret:** The OCI modelcar image is pulled from `registry.redhat.io` using the cluster's global pull secret — no HuggingFace token or additional Secret is required.

---

## Repository layout

```
maas-rhoai/
├── setup-maas.sh                              # Platform bootstrap (operators, gateway, DSC, dashboard flags)
├── deploy-example-workload.sh                 # Example model, governance policies, RBAC, LlamaStack playground
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
    ├── 06e-authorino-tls.yaml                 # ClusterIssuer + Certificate for Authorino TLS
    ├── 06f-user-workload-monitoring.yaml      # Enables OpenShift User Workload Monitoring
    ├── 07-model-namespace.yaml                # maas-models namespace
    ├── 08-example-llminferenceservice.yaml    # Example LLMInferenceService (llama-3.1-8B FP8, OCI)
    ├── 09-example-auth-policy.yaml            # AuthPolicy for the example model
    ├── 10-example-ratelimit-policy.yaml       # RateLimitPolicy (req/s per user)
    ├── 11-example-token-ratelimit-policy.yaml # TokenRateLimitPolicy (tokens/day per user)
    ├── 12-example-rbac-viewer.yaml            # RoleBinding: group maas-users → view
    └── 13-llamastack-distribution.yaml        # LlamaStack distribution for the GenAI Playground
```

---

## Deploying your own model

After the platform is configured, deploying a new LLM is a three-step process.

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

### 2. Apply governance policies

Once the `HTTPRoute` is created (name matches the `LLMInferenceService` name):

```bash
# Auth policy (replace 'my-llm' with your HTTPRoute name)
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: my-llm-auth
  namespace: maas-models
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-llm
  rules:
    authentication:
      k8s-token:
        kubernetesTokenReview:
          audiences: []
    authorization:
      namespace-access:
        kubernetesSubjectAccessReview:
          user:
            valueFrom:
              authJSON: auth.identity.user.username
          resourceAttributes:
            namespace:
              value: maas-models
            group:
              value: serving.kserve.io
            resource:
              value: llminferenceservices
            verb:
              value: get
EOF

# Rate-limit policy
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: my-llm-rate-limit
  namespace: maas-models
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-llm
  limits:
    per-user-rps:
      rates:
      - limit: 10
        window: 10s
      counters:
      - expression: auth.identity.user.username
EOF
```

### 3. Grant user access

```bash
# Grant the 'data-scientists' group read access to the model namespace
oc adm policy add-role-to-group view data-scientists -n maas-models
```

### 4. Call the API

```bash
TOKEN=$(oc whoami -t)
DOMAIN=$(oc get gatewayconfig default-gateway -n redhat-ods-applications \
  -o jsonpath='{.status.domain}')

curl -k -H "Authorization: Bearer $TOKEN" \
  "https://my-llm-maas-models.${DOMAIN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3-1-8b-instruct",
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

- All `LlamaStackDistribution`, `LLMInferenceService`, `AuthPolicy`, `RateLimitPolicy`, `TokenRateLimitPolicy`, and `RoleBinding` resources in `maas-models`, then the `maas-models` namespace itself
- DSC `kserve.modelsAsService` reverted to `Removed`
- DSC `llamastackoperator` reverted to `Removed` — **conditionally**: since `llamastackoperator` is a cluster-scoped DSC component that may back LlamaStack workloads outside MaaS, the script first deletes the MaaS `LlamaStackDistribution` and then checks `oc get llamastackdistribution -A` cluster-wide. It only reverts the operator to `Removed` if none remain; otherwise it logs a warning and leaves it `Managed`.
- Gateway `maas-default-gateway` (and its ConfigMap) in `openshift-ingress`
- Authorino TLS patch reverted; `Certificate` and `ClusterIssuer` deleted
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
Most likely PostgreSQL is not yet reachable. Check:
```bash
oc get pods -n maas-db
oc logs -n redhat-ods-applications -l app.kubernetes.io/name=maas-api --tail=50
```
If PostgreSQL was recently fixed, delete the pod to skip exponential backoff:
```bash
oc delete pod -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
```

### Authorino TLS errors / MaaS auth not working
```bash
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='{.spec.listener.tls}' | python3 -m json.tool
oc get secret authorino-tls-secret -n kuadrant-system
oc logs -n kuadrant-system -l app=authorino --tail=50
```

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

### AuthPolicy not enforcing
```bash
oc get authpolicy -n maas-models
oc describe authpolicy <name> -n maas-models
oc logs -n kuadrant-system -l app=authorino --tail=50
```

### AuthPolicy rejected: `kubernetesSubjectAccessReview.groups` must be of type array
The RHCL `AuthPolicy` v1 CRD deprecated the object-style `groups.valueFrom.authJSON` selector in
favor of a top-level `authorizationGroups` field (also `groups` itself is now typed as a static
string array, not a selector object). `manifests/09-example-auth-policy.yaml` uses the current
`user.selector` / `authorizationGroups.selector` syntax — if you copy this pattern elsewhere, use:
```yaml
kubernetesSubjectAccessReview:
  user:
    selector: auth.identity.user.username
  authorizationGroups:
    selector: auth.identity.user.groups
```
not the older `valueFrom: { authJSON: ... }` form.

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
