# RHOAI MaaS — Teardown

Removes all resources created by `setup-maas.sh` and `deploy-example-workload.sh`. RHOAI
version (3.4.x vs 3.5+) is auto-detected from the `rhods-operator` CSV, the same way
`setup-maas.sh` does — this determines which DSC fields and Playground-backend component
get reverted.

---

## Usage

```bash
# Interactive — removes MaaS resources, leaves cert-manager/RHCL/GatewayClass/MetalLB in place
./teardown-maas.sh

# Also uninstall cert-manager, RHCL, the openshift-default GatewayClass, and MetalLB
./teardown-maas.sh --full

# Non-interactive (CI / scripted use)
./teardown-maas.sh --yes
./teardown-maas.sh --full --yes
```

### Flags

| Flag | Description |
|---|---|
| `--full` | Also uninstall cert-manager, RHCL/Kuadrant, the `openshift-default` GatewayClass, and MetalLB (Subscriptions, CSVs, OperatorGroups, namespaces) |
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
| `maas-api` RBAC workaround (`Role`/`RoleBinding` `maas-api-authpolicies-workaround`, `ClusterRole`/`ClusterRoleBinding` `maas-api-apiservers-workaround`) for the `maas-api`/`maas-controller` image version-skew bug | `models-as-a-service` namespace / cluster-scoped |
| Any leftover `AuthPolicy`/`RateLimitPolicy`/`TokenRateLimitPolicy`/`RoleBinding` from older script versions | `maas-models` namespace |
| Namespace `maas-models` | cluster-scoped |
| Namespace `models-as-a-service` (owned by RHOAI/`maas-controller`) — includes every `MaaSSubscription`/`MaaSAuthPolicy` inside it, not just the example's; confirmed **not** cleaned up automatically after DSC revert | cluster-scoped |
| Namespace `ai-tenants` (another `maas-controller`-generated namespace) | cluster-scoped |
| `Config/default`'s `maas.opendatahub.io/default-aitenant-bootstrapped` annotation, cleared | cluster-scoped |
| Namespace `redhat-ai-gateway-infra` (holds `maas-api` itself on RHOAI 3.5+, owned by `ai-gateway-operator` — a different operator than `maas-controller`; confirmed **not** cleaned up on DSC revert either). No-op on 3.4.x. | cluster-scoped |
| DSC MaaS setting reverted to `Removed`: `kserve.modelsAsService` (3.4.x) or `aigateway.managementState` + `aigateway.modelsAsAService.managementState` together (3.5+) — version auto-detected | `redhat-ods-operator` namespace |
| `genAiStudio` reverted to `false` in `OdhDashboardConfig` | `redhat-ods-applications` namespace |
| DSC Playground backend reverted to `Removed`: `llamastackoperator` (3.4.x) or `ogx` (3.5+) — **only if** no `LlamaStackDistribution`/`OGXServer` resources remain anywhere on the cluster (both are cluster-scoped and may back non-MaaS workloads); otherwise left `Managed` with a warning | `redhat-ods-operator` namespace |
| Gateway `maas-default-gateway`, its Route (`maas-default-gateway-https`), and its ConfigMap (`maas-gateway-options`) | `openshift-ingress` namespace |
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
| GatewayClass `openshift-default` | cluster-scoped |
| MetalLB `IPAddressPool`/`L2Advertisement` `maas-gateway-pool`, `MetalLB` CR, operator Subscription + CSV | `metallb-system` namespace |
| Namespace `metallb-system` | cluster-scoped |

MetalLB removal is a harmless no-op (`--ignore-not-found` throughout) on cloud platforms,
where it was never installed in the first place.

### Why the `Config/default` annotation matters (critical, not cosmetic)

`maas-controller` only ever bootstraps the default `MaasTenantConfig`/`AITenant` objects —
and, transitively, deploys `maas-api` itself into `redhat-ai-gateway-infra` — **once per
cluster**, gated by the `maas.opendatahub.io/default-aitenant-bootstrapped` annotation on
the cluster-scoped `Config/default` resource. Deleting `models-as-a-service`/`ai-tenants`
(above) destroys those objects. If this annotation were left at `"true"`, no future
`setup-maas.sh` run would ever re-trigger bootstrap again — confirmed live: even a full DSC
`Removed`→`Managed` cycle leaves `ModelsAsAServiceReady` reporting `True` throughout while
`maas-api` never gets redeployed and the tenant namespaces never get their objects back.
This would permanently break MaaS on the cluster until someone found and manually cleared
this exact annotation. Clearing it as part of teardown is what makes the next
`setup-maas.sh` run actually rebuild everything correctly — verified live, full cycle,
zero manual intervention required.

---

## What is NOT removed

| Resource | Reason |
|---|---|
| RHOAI operator and `DataScienceCluster` | Pre-existing; not created by `setup-maas.sh` |
| `cluster-monitoring-config` (openshift-monitoring) | May be shared with other workloads; delete manually if needed |
| OLM CRDs (cert-manager, Kuadrant, MetalLB) | OLM leaves CRDs behind after operator removal; `setup-maas.sh` re-run handles this automatically by detecting CSV state rather than CRD presence |

`models-as-a-service` and `ai-tenants` **are** removed (see the table above) — an earlier
version of this script left them for RHOAI to clean up automatically, but that turned out
not to happen in practice, so the script now deletes them directly, including an automatic
sweep for stuck `maas-controller` finalizers (see [Force-delete a stuck
namespace](#force-delete-a-stuck-namespace) below for the rare case where even that isn't
enough).

---

## Teardown order

Steps run in reverse dependency order to avoid controller races:

1. **Delete model workloads** — `LlamaStackDistribution`/`OGXServer`, `LLMInferenceService`, and `MaaSModelRef` are deleted first so their controllers can clean up dependent resources (HTTPRoutes, certs) before the `maas-models` namespace is forcibly removed (15 s grace period first). The same step then deletes `models-as-a-service` and `ai-tenants` — namespace deletion cascades to everything inside (`MaaSSubscription`, `MaaSAuthPolicy`, `MaaSTenantConfig`, `AITenant`), so nothing needs deleting by name first. Both are deleted with `--wait=false`, followed by another 15 s grace period, then an automatic sweep that force-clears the finalizer on any `maas.opendatahub.io` resource still stuck `Terminating` inside (confirmed live: a `MaaSSubscription`/`MaaSAuthPolicy`/`MaaSTenantConfig`/`AITenant` whose referenced model/tenant is already gone can carry a `maas-controller`-owned cleanup finalizer that never clears on its own). Deleting the `LlamaStackDistribution`/`OGXServer` here first is what makes step 5's cluster-wide check accurate. **Finally, this same step clears `Config/default`'s `maas.opendatahub.io/default-aitenant-bootstrapped` annotation** — see "Why the `Config/default` annotation matters" above; skipping this would permanently break re-provisioning on the next `setup-maas.sh` run.
2. **Remove the `maas-api` RBAC workaround** — the `Role`/`RoleBinding`/`ClusterRole`/`ClusterRoleBinding` `setup-maas.sh` adds to work around the `maas-api`/`maas-controller` image version-skew bug, RHOAI 3.4.x only (see `README.md` Troubleshooting).
3. **Revert DSC MaaS setting** — after workloads are gone so `maas-controller` does not race to recreate them. Branches by detected RHOAI version: 3.4.x reverts `kserve.modelsAsService` → `Removed` unconditionally (its CEL rule only permits this direction); 3.5+ reverts `aigateway.managementState` and `aigateway.modelsAsAService.managementState` together, since `setup-maas.sh` sets both together as a pair.
4. **Delete the `redhat-ai-gateway-infra` namespace** (RHOAI 3.5+ only) — holds `maas-api` itself, owned by `ai-gateway-operator` rather than `maas-controller`; confirmed live this operator does not clean up its own namespace when the DSC field above is reverted. Same `--wait=false` + finalizer-sweep pattern as step 1.
5. **Revert `genAiStudio`** in `OdhDashboardConfig`.
6. **Revert the Playground backend** — `llamastackoperator` (3.4.x) or `ogx` (3.5+) → `Removed`, only if no matching workload CR (`LlamaStackDistribution`/`OGXServer`) remains cluster-wide; otherwise left `Managed` with a warning, since this DSC component is cluster-scoped and may be used outside MaaS.
7. **Delete MaaS gateway** — the Gateway (`maas-default-gateway`), its Route (`maas-default-gateway-https`), and its ConfigMap (`maas-gateway-options`), no longer needed once the DSC is reverted.
8. **Revert Authorino TLS** — patches the Authorino CR back to `tls.enabled: false`, then deletes the certificate secret.
9. **Delete PostgreSQL** — `maas-db` namespace and the `maas-db-config` Secret in `redhat-ods-applications`.
10. *(--full)* **Delete cert-manager** — after all cert-manager-managed resources are already gone.
11. *(--full)* **Delete RHCL/Kuadrant** — after the Kuadrant CR and all policies are gone.
12. *(--full)* **Delete the `openshift-default` GatewayClass.**
13. *(--full)* **Delete MetalLB** — IPAddressPool/L2Advertisement, MetalLB CR, operator, namespace.

---

## Manual cleanup (if needed)

### Remove OLM CRDs left behind after `--full`

```bash
# cert-manager CRDs
oc get crd | grep cert-manager.io | awk '{print $1}' | xargs oc delete crd

# Kuadrant CRDs
oc get crd | grep kuadrant.io | awk '{print $1}' | xargs oc delete crd

# MetalLB CRDs
oc get crd | grep metallb.io | awk '{print $1}' | xargs oc delete crd
```

### Remove User Workload Monitoring config

Only do this if no other workloads depend on it:

```bash
oc delete configmap cluster-monitoring-config -n openshift-monitoring
```

### Force-delete a stuck namespace

`teardown-maas.sh` already sweeps `models-as-a-service`/`ai-tenants`/`redhat-ai-gateway-infra`
for stuck `maas.opendatahub.io` resource finalizers automatically (see Teardown order
above), so this should rarely be needed for those three specifically. If some other
namespace gets stuck in `Terminating`, it's usually because an object inside it (commonly
a CR like `MaaSTenantConfig`/`AITenant` in `models-as-a-service`/`ai-tenants`, if you're
running an older version of this script, or the namespace's own finalizer if even the
automatic sweep didn't help) has its own finalizer that never got cleared — check what's
still there before force-clearing:

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
