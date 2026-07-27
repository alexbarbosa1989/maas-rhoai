# RHOAI 3.4 MaaS — Teardown

Removes all resources created by `setup-maas.sh` and `deploy-example-workload.sh`.

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
| All `MaaSModelRef` resources | `maas-models` namespace |
| `MaaSSubscription` `llama-3-8b-free` and `MaaSAuthPolicy` `llama-3-8b-access` | `models-as-a-service` namespace (namespace itself is not deleted) |
| `maas-api` RBAC workaround (`Role`/`RoleBinding` `maas-api-authpolicies-workaround`, `ClusterRole`/`ClusterRoleBinding` `maas-api-apiservers-workaround`) for the `maas-api`/`maas-controller` image version-skew bug | `models-as-a-service` namespace / cluster-scoped |
| Any leftover `AuthPolicy`/`RateLimitPolicy`/`TokenRateLimitPolicy`/`RoleBinding` from older script versions | `maas-models` namespace |
| Namespace `maas-models` | cluster-scoped |
| DSC `modelsAsService` reverted to `Removed` | `redhat-ods-operator` namespace |
| DSC `llamastackoperator` reverted to `Removed` — **only if** no `LlamaStackDistribution` resources remain anywhere on the cluster (it's cluster-scoped and may back non-MaaS workloads); otherwise left `Managed` with a warning | `redhat-ods-operator` namespace |
| Gateway `maas-default-gateway` and its external Route | `openshift-ingress` namespace |
| ConfigMap `maas-default-gateway-config` | `openshift-ingress` namespace |
| Authorino TLS patch reverted; `serving-cert-secret-name` annotation removed from the Authorino Service | `kuadrant-system` namespace |
| Secret `authorino-server-cert` | `kuadrant-system` namespace |
| Leftover cert-manager resources from older script versions (`Certificate authorino-tls`, `Secret authorino-tls-secret`, `ClusterIssuer maas-self-signed`) | `kuadrant-system` namespace / cluster-scoped |
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

1. **Delete model workloads** — `LlamaStackDistribution`, `LLMInferenceService`, and `MaaSModelRef` are deleted first so their controllers can clean up dependent resources (HTTPRoutes, certs) before the namespace is forcibly removed; the `MaaSSubscription`/`MaaSAuthPolicy` in `models-as-a-service` are deleted by name at the same step (different namespace, not touched by the `maas-models` namespace deletion). The script waits 15 s between workload deletion and namespace deletion. Deleting the MaaS `LlamaStackDistribution` here first is what makes step 3b's cluster-wide check accurate.
2. **Remove the `maas-api` RBAC workaround** — the `Role`/`RoleBinding`/`ClusterRole`/`ClusterRoleBinding` `setup-maas.sh` adds to work around the `maas-api`/`maas-controller` image version-skew bug (see `README.md` Troubleshooting).
3. **Revert DSC** — after workloads are gone so the `maas-controller` does not race to recreate them.
   - **3a.** `modelsAsService` → `Removed` unconditionally.
   - **3b.** `llamastackoperator` → `Removed` only if `oc get llamastackdistribution -A` now returns none; otherwise left `Managed` with a warning, since this DSC component is cluster-scoped and may be used outside MaaS.
4. **Delete MaaS gateway** — the external Route and the Gateway itself, no longer needed once the DSC is reverted.
5. **Revert Authorino TLS** — patches the Authorino CR back to `tls.enabled: false`, then deletes the certificate and ClusterIssuer.
6. **Delete PostgreSQL** — `maas-db` namespace and the `maas-db-config` Secret in `redhat-ods-applications`.
7. *(--full)* **Delete cert-manager** — after all cert-manager-managed resources (Certificates, ClusterIssuer) are already gone.
8. *(--full)* **Delete RHCL/Kuadrant** — after the Kuadrant CR and all policies are gone.

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
