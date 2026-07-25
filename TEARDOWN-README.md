# RHOAI 3.4 MaaS — Teardown

Removes all resources created by `setup-maas.sh`.

---

## Usage

```bash
# Interactive — removes MaaS resources, leaves cert-manager and RHCL in place
./teardown-maas.sh

# Also uninstall cert-manager and RHCL operators
./teardown-maas.sh --full

# Non-interactive (CI / scripted use)
./teardown-maas.sh --yes
./teardown-maas.sh --full --yes
```

### Flags

| Flag | Description |
|---|---|
| `--full` | Also uninstall cert-manager and RHCL/Kuadrant operators (Subscriptions, CSVs, namespaces) |
| `--yes` | Skip the confirmation prompt |
| `--help` | Show usage |

### Environment variables

All variables default to the same values used by `setup-maas.sh`:

```bash
export RHOAI_OPERATOR_NS=redhat-ods-operator
export RHOAI_APP_NS=redhat-ods-applications
export CERT_MANAGER_NS=cert-manager-operator
export KUADRANT_NS=kuadrant-system
export MAAS_MODEL_NS=maas-models
export DSC_NAME=default-dsc
```

---

## What gets removed

### Default (without `--full`)

| Resource | Location |
|---|---|
| All `LlamaStackDistribution` resources | `maas-models` namespace |
| All `LLMInferenceService` resources | `maas-models` namespace |
| All `AuthPolicy` resources | `maas-models` namespace |
| All `RateLimitPolicy` resources | `maas-models` namespace |
| All `TokenRateLimitPolicy` resources | `maas-models` namespace |
| All `RoleBinding` resources | `maas-models` namespace |
| Namespace `maas-models` | cluster-scoped |
| DSC `modelsAsService` reverted to `Removed` | `redhat-ods-operator` namespace |
| DSC `llamastackoperator` reverted to `Removed` — **only if** no `LlamaStackDistribution` resources remain anywhere on the cluster (it's cluster-scoped and may back non-MaaS workloads); otherwise left `Managed` with a warning | `redhat-ods-operator` namespace |
| Gateway `maas-default-gateway` | `openshift-ingress` namespace |
| ConfigMap `maas-default-gateway-config` | `openshift-ingress` namespace |
| Authorino TLS patch reverted | `kuadrant-system` namespace |
| Certificate `authorino-tls` | `kuadrant-system` namespace |
| Secret `authorino-tls-secret` | `kuadrant-system` namespace |
| ClusterIssuer `maas-self-signed` | cluster-scoped |
| Secret `maas-db-config` | `redhat-ods-applications` namespace |
| Namespace `maas-db` (PostgreSQL) | cluster-scoped |

### With `--full` (additionally)

| Resource | Location |
|---|---|
| cert-manager Subscription + CSV + OperatorGroup | `cert-manager-operator` namespace |
| Namespace `cert-manager-operator` | cluster-scoped |
| RHCL Subscription + CSV | `openshift-operators` namespace |
| Kuadrant CR `kuadrant` | `kuadrant-system` namespace |
| Namespace `kuadrant-system` | cluster-scoped |

---

## What is NOT removed

| Resource | Reason |
|---|---|
| RHOAI operator and `DataScienceCluster` | Pre-existing; not created by `setup-maas.sh` |
| `cluster-monitoring-config` (openshift-monitoring) | May be shared with other workloads; delete manually if needed |
| Namespace `models-as-a-service` | Owned by the RHOAI operator; cleaned up automatically after DSC reconciles. Can get stuck `Terminating` if `maas-controller` is unhealthy when the `Tenant` CR's finalizer needs to run — see [Force-delete a stuck namespace](#force-delete-a-stuck-namespace) below |
| OLM CRDs (cert-manager, Kuadrant) | OLM leaves CRDs behind after operator removal; `setup-maas.sh` re-run handles this automatically by detecting CSV state rather than CRD presence |

---

## Teardown order

Steps run in reverse dependency order to avoid controller races:

1. **Delete model workloads** — `LlamaStackDistribution`, `LLMInferenceService`, and policies are deleted first so their controllers can clean up dependent resources (HTTPRoutes, certs) before the namespace is forcibly removed. The script waits 15 s between workload deletion and namespace deletion. Deleting the MaaS `LlamaStackDistribution` here first is what makes step 2b's cluster-wide check accurate.
2. **Revert DSC** — after workloads are gone so the `maas-controller` does not race to recreate them.
   - **2a.** `modelsAsService` → `Removed` unconditionally.
   - **2b.** `llamastackoperator` → `Removed` only if `oc get llamastackdistribution -A` now returns none; otherwise left `Managed` with a warning, since this DSC component is cluster-scoped and may be used outside MaaS.
3. **Delete MaaS gateway** — no longer needed once the DSC is reverted.
4. **Revert Authorino TLS** — patches the Authorino CR back to `tls.enabled: false`, then deletes the certificate and ClusterIssuer.
5. **Delete PostgreSQL** — `maas-db` namespace and the `maas-db-config` Secret in `redhat-ods-applications`.
6. *(--full)* **Delete cert-manager** — after all cert-manager-managed resources (Certificates, ClusterIssuer) are already gone.
7. *(--full)* **Delete RHCL/Kuadrant** — after the Kuadrant CR and all policies are gone.

---

## Manual cleanup (if needed)

### Remove OLM CRDs left behind after `--full`

```bash
# cert-manager CRDs
oc get crd | grep cert-manager.io | awk '{print $1}' | xargs oc delete crd

# Kuadrant CRDs
oc get crd | grep kuadrant.io | awk '{print $1}' | xargs oc delete crd
```

### Remove User Workload Monitoring config

Only do this if no other workloads depend on it:

```bash
oc delete configmap cluster-monitoring-config -n openshift-monitoring
```

### Force-delete a stuck namespace

If a namespace gets stuck in `Terminating`, it's usually because an object inside it
(commonly a CR like `Tenant` in `models-as-a-service`) has its own finalizer that never
got cleared — check what's still there before force-clearing:

```bash
# Identify what's still blocking deletion
oc api-resources --verbs=list --namespaced -o name \
  | xargs -n1 -I{} sh -c 'oc get {} -n <name> 2>/dev/null | grep -q . && echo {}'
```

A plain `oc patch namespace <name> --type=merge -p '{"spec":{"finalizers":[]}}'` against the
namespace's main endpoint does **not** reliably clear this — namespace finalizer removal
requires the `/finalize` subresource:

```bash
oc get namespace <name> -o json \
  | jq '.spec.finalizers = []' \
  | oc replace --raw "/api/v1/namespaces/<name>/finalize" -f -
```

**Caution:** this bypasses whatever cleanup the owning controller (e.g. `maas-controller` for
the `Tenant` CR) was supposed to do — it may leave orphaned cluster-scoped resources behind
(`ClusterRole`/`ClusterRoleBinding` labeled `maas.opendatahub.io/tenant-name=default-tenant`).
Check for and clean those up manually after forcing the deletion:

```bash
oc get clusterrole,clusterrolebinding -l maas.opendatahub.io/tenant-name=default-tenant
```
