#!/usr/bin/env bash
# setup-maas.sh
# Automates the configuration of Models-as-a-Service (MaaS) on Red Hat OpenShift AI 3.4.
# Reference: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index
#
# Usage:
#   ./setup-maas.sh [--skip-operators] [--help]
#
# Options:
#   --skip-operators   Skip cert-manager and RHCL operator installation (use if already installed)
#   --help             Show this message
#
# This script installs and configures the MaaS platform layer only. To deploy the
# example model, governance policies, and LlamaStack playground, run
# ./deploy-example-workload.sh afterwards.

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager-operator}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
MAAS_MODEL_NS="${MAAS_MODEL_NS:-maas-models}"
DSC_NAME="${DSC_NAME:-default-dsc}"
DSCI_NAME="${DSCI_NAME:-default-dsci}"

OPERATOR_WAIT_TIMEOUT="${OPERATOR_WAIT_TIMEOUT:-600}"   # seconds
POD_WAIT_TIMEOUT="${POD_WAIT_TIMEOUT:-300}"             # seconds
KUADRANT_WAIT_TIMEOUT="${KUADRANT_WAIT_TIMEOUT:-300}"   # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

SKIP_OPERATORS=false
SKIP_CERT_MANAGER=false
SKIP_RHCL=false

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --skip-operators)   SKIP_OPERATORS=true ;;
      --skip-cert-manager) SKIP_CERT_MANAGER=true ;;
      --skip-rhcl)        SKIP_RHCL=true ;;
      --help)
        cat <<'USAGE'
setup-maas.sh — Automates MaaS configuration on Red Hat OpenShift AI 3.4.
Reference: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index

Usage:
  ./setup-maas.sh [OPTIONS]

Options:
  --skip-operators    Skip both cert-manager and RHCL installation
  --skip-cert-manager Skip cert-manager installation only
  --skip-rhcl         Skip RHCL/Kuadrant installation only
  --help              Show this message

Note: Each operator step auto-detects whether it is already installed by checking
for its CRDs (certificates.cert-manager.io, kuadrants.kuadrant.io). The --skip-*
flags force-bypass even that detection.

This script installs and configures the MaaS platform layer only (operators, gateway,
Authorino TLS, PostgreSQL, DSC/dashboard flags). It does not deploy any model. Run
./deploy-example-workload.sh afterwards to deploy the example LLMInferenceService,
governance policies, and LlamaStack playground.

Environment variables (all optional, shown with defaults):
  RHOAI_OPERATOR_NS=redhat-ods-operator   RHOAI_APP_NS=redhat-ods-applications
  CERT_MANAGER_NS=cert-manager-operator   KUADRANT_NS=kuadrant-system
  MAAS_MODEL_NS=maas-models               DSC_NAME=default-dsc
  OPERATOR_WAIT_TIMEOUT=600               POD_WAIT_TIMEOUT=300
USAGE
        exit 0 ;;
      *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
  done
}

# ─── Steps ────────────────────────────────────────────────────────────────────
# (approve_installplan_for_sub, wait_for_csv, wait_for_condition, wait_for_pods,
#  apply_manifest, resource_exists are defined in lib/common.sh)

check_prerequisites() {
  log_step "Step 1: Checking prerequisites"

  # oc CLI
  if ! command -v oc &>/dev/null; then
    log_error "'oc' CLI not found. Install OpenShift CLI and retry."
    exit 1
  fi
  log_ok "oc CLI found: $(oc version --client 2>/dev/null | head -1)"

  # Cluster connectivity
  if ! oc whoami &>/dev/null; then
    log_error "Not logged in to an OpenShift cluster. Run 'oc login …' first."
    exit 1
  fi
  log_ok "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

  # cluster-admin
  if ! oc auth can-i create clusterrole --all-namespaces &>/dev/null; then
    log_error "Current user does not have cluster-admin privileges."
    exit 1
  fi
  log_ok "cluster-admin privileges confirmed."

  # RHOAI operator
  local rhoai_csv
  rhoai_csv=$(oc get csv -n "$RHOAI_OPERATOR_NS" 2>/dev/null \
    | awk '/rhods-operator/{print $1}' | head -1)
  if [[ -z "$rhoai_csv" ]]; then
    log_error "Red Hat OpenShift AI operator not found in namespace '${RHOAI_OPERATOR_NS}'."
    log_error "Install RHOAI 3.4 before running this script."
    exit 1
  fi
  local rhoai_version
  rhoai_version=$(echo "$rhoai_csv" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  log_ok "RHOAI operator found: ${rhoai_csv} (version ${rhoai_version})"

  # RHOAI minimum version check (3.4). Also exported (not `local`) as RHOAI_MAJOR/RHOAI_MINOR
  # so later steps (Step 10) can branch LlamaStack-vs-OGX behavior on the same detection.
  RHOAI_MAJOR=$(echo "$rhoai_version" | cut -d. -f1)
  RHOAI_MINOR=$(echo "$rhoai_version" | cut -d. -f2)
  if (( RHOAI_MAJOR < 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR < 4) )); then
    log_error "MaaS with LLMInferenceService requires RHOAI >= 3.4 (found ${rhoai_version})."
    exit 1
  fi

  # DSC exists
  if ! resource_exists dsc "$DSC_NAME" "$RHOAI_OPERATOR_NS"; then
    log_error "DataScienceCluster '${DSC_NAME}' not found in '${RHOAI_OPERATOR_NS}'."
    exit 1
  fi
  log_ok "DataScienceCluster '${DSC_NAME}' exists."

  # Manifests directory
  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    log_error "Manifests directory not found: ${MANIFESTS_DIR}"
    exit 1
  fi
  log_ok "Manifests directory found: ${MANIFESTS_DIR}"
}

install_cert_manager() {
  log_step "Step 2: Installing cert-manager operator"

  # Detect by CSV — CRD alone is not enough (OLM leaves CRDs behind after uninstall).
  local phase
  phase=$(oc get csv -A 2>/dev/null | awk '/cert-manager-operator/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "cert-manager already installed and CSV is Succeeded — skipping."
    return 0
  fi
  [[ -n "$phase" ]] && log_warn "cert-manager CSV found but phase is '${phase}' — reinstalling."

  apply_manifest "${MANIFESTS_DIR}/01-cert-manager-namespace.yaml"
  apply_manifest "${MANIFESTS_DIR}/02-cert-manager-operatorgroup.yaml"
  apply_manifest "${MANIFESTS_DIR}/03-cert-manager-subscription.yaml"

  approve_installplan_for_sub "$CERT_MANAGER_NS" "openshift-cert-manager-operator"

  wait_for_csv "$CERT_MANAGER_NS" "cert-manager-operator" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "cert-manager CSV failed. Aborting."; exit 1; }

  wait_for_pods "cert-manager" "app.kubernetes.io/instance=cert-manager" "$POD_WAIT_TIMEOUT" \
    || { log_error "cert-manager pods not running. Aborting."; exit 1; }
  log_ok "cert-manager operator is ready."
}

install_rhcl() {
  log_step "Step 3: Installing Red Hat Connectivity Link (RHCL) operator"

  # Detect by CSV — CRD alone is not enough (OLM leaves CRDs behind after uninstall).
  local phase
  phase=$(oc get csv -n openshift-operators 2>/dev/null | awk '/rhcl/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "RHCL already installed and CSV is Succeeded — skipping."
  else
    [[ -n "$phase" ]] && log_warn "RHCL CSV found but phase is '${phase}' — reinstalling."
    apply_manifest "${MANIFESTS_DIR}/04-rhcl-subscription.yaml"
    # RHCL bundles sub-operators (Authorino, Limitador, dns-operator, Service Mesh upgrade).
    # OLM may create the InstallPlan as Manual even when subscription requests Automatic.
    approve_installplan_for_sub "openshift-operators" "rhcl-operator"
    wait_for_csv "openshift-operators" "rhcl-operator" "$OPERATOR_WAIT_TIMEOUT" \
      || { log_error "RHCL CSV failed. Aborting."; exit 1; }
    log_ok "RHCL operator CSV is Succeeded."

    log_info "Waiting for Kuadrant CRD to be registered…"
    local crd_deadline=$(( $(date +%s) + 120 ))
    until oc get crd kuadrants.kuadrant.io &>/dev/null; do
      if (( $(date +%s) > crd_deadline )); then
        log_error "Kuadrant CRD not available after 120s. RHCL may not have installed correctly."
        oc get csv -n openshift-operators 2>/dev/null | grep -E "rhcl|kuadrant|authorino|limitador"
        exit 1
      fi
      sleep 5
    done
    log_ok "Kuadrant CRD is available."
  fi

  # Namespace + CR creation always runs — both are idempotent.
  apply_manifest "${MANIFESTS_DIR}/05-kuadrant-namespace.yaml"

  if resource_exists kuadrant kuadrant "$KUADRANT_NS"; then
    log_warn "Kuadrant CR already exists — skipping creation."
  else
    apply_manifest "${MANIFESTS_DIR}/06-kuadrant-cr.yaml"
    log_info "Kuadrant CR created. Waiting for sub-components to start…"
  fi

  wait_for_condition "kuadrant/kuadrant" "$KUADRANT_NS" "Ready" "$KUADRANT_WAIT_TIMEOUT" \
    || { log_error "Kuadrant not Ready. Aborting."; exit 1; }
  log_ok "Kuadrant is Ready in '${KUADRANT_NS}'."
}

configure_maas_gateway() {
  log_step "Step 4: Creating MaaS Gateway API gateway"
  # The maas-controller's default-tenant expects a Gateway named maas-default-gateway
  # in openshift-ingress. RHOAI does not create it automatically.

  # Security (access.redhat.com/solutions/7145755): 06c-maas-gateway.yaml uses a
  # Selector-based allowedRoutes, not "All" — "All" lets any namespace on the cluster
  # attach an HTTPRoute and hijack MaaS traffic. Label the MaaS infra namespace before the
  # Gateway is created/reconciled below, or maas-controller's own internal maas-api-route
  # (used by the dashboard's API Keys page) won't attach. create_model_namespace() labels
  # MAAS_MODEL_NS the same way when it creates that namespace.
  oc label namespace "$RHOAI_APP_NS" maas-gateway-access="true" --overwrite &>/dev/null
  log_ok "Namespace '${RHOAI_APP_NS}' labeled maas-gateway-access=true."

  if resource_exists gateway maas-default-gateway "openshift-ingress"; then
    log_warn "Gateway 'maas-default-gateway' already exists — skipping creation."

    # Upgrade path: a Gateway created by an older version of this script may still carry
    # the insecure allowedRoutes.namespaces.from: All default. Reconcile it here so
    # re-running the script on an existing install picks up the fix. type=merge replaces
    # spec.listeners wholesale (it's a list), so the patch must restate the full listener,
    # not just allowedRoutes, or port/protocol/tls would be dropped.
    local allowed_from
    allowed_from=$(oc get gateway maas-default-gateway -n openshift-ingress \
      -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}' 2>/dev/null)
    if [[ "$allowed_from" == "All" ]]; then
      log_warn "Existing Gateway uses allowedRoutes.namespaces.from: All (route-hijacking exposure — access.redhat.com/solutions/7145755)."
      log_warn "Patching to Selector. Any namespace not labeled maas-gateway-access=true will lose route access until labeled."
      oc patch gateway maas-default-gateway -n openshift-ingress --type=merge -p '{
        "spec": {
          "listeners": [{
            "name": "https",
            "port": 443,
            "protocol": "HTTPS",
            "allowedRoutes": {
              "namespaces": {
                "from": "Selector",
                "selector": {"matchLabels": {"maas-gateway-access": "true"}}
              }
            },
            "tls": {
              "mode": "Terminate",
              "certificateRefs": [{"group": "", "kind": "Secret", "name": "maas-default-gateway-service-tls"}]
            }
          }]
        }
      }'
      log_ok "Gateway 'maas-default-gateway' patched to Selector-based allowedRoutes."
    fi
  else
    apply_manifest "${MANIFESTS_DIR}/06b-maas-gateway-configmap.yaml"
    apply_manifest "${MANIFESTS_DIR}/06c-maas-gateway.yaml"
    log_info "Waiting for Gateway 'maas-default-gateway' to be Programmed…"
    local deadline=$(( $(date +%s) + 120 ))
    until [[ "$(oc get gateway maas-default-gateway -n openshift-ingress \
                  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]]; do
      if (( $(date +%s) > deadline )); then
        log_error "Gateway 'maas-default-gateway' not Programmed after 120s."
        oc describe gateway maas-default-gateway -n openshift-ingress 2>/dev/null | tail -15
        exit 1
      fi
      sleep 5
    done
    log_ok "Gateway 'maas-default-gateway' is Programmed."
  fi

  # Expose the gateway externally. RHOAI does not create this Route automatically;
  # without it, maas-api and every model endpoint are only reachable from inside the
  # cluster network.
  if resource_exists route maas-default-gateway "openshift-ingress"; then
    log_warn "Route 'maas-default-gateway' already exists — skipping."
  else
    local apps_domain
    apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    sed "s|maas\.APPS_DOMAIN_PLACEHOLDER|maas.${apps_domain}|" \
      "${MANIFESTS_DIR}/06g-maas-gateway-route.yaml" | oc apply -f -

    log_info "Waiting for Route 'maas-default-gateway' to be admitted…"
    local deadline=$(( $(date +%s) + 60 ))
    until [[ "$(oc get route maas-default-gateway -n openshift-ingress \
                  -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null)" == "True" ]]; do
      if (( $(date +%s) > deadline )); then
        log_error "Route 'maas-default-gateway' not admitted after 60s."
        oc describe route maas-default-gateway -n openshift-ingress 2>/dev/null | tail -15
        exit 1
      fi
      sleep 5
    done
    log_ok "Route 'maas-default-gateway' admitted at https://maas.${apps_domain}"
  fi
}

configure_authorino_tls() {
  log_step "Step 5: Configuring Authorino TLS (required by MaaS auth layer)"

  if oc get authorino authorino -n "$KUADRANT_NS" \
      -o jsonpath='{.spec.listener.tls.certSecretRef.name}' 2>/dev/null | grep -q "^authorino-server-cert$"; then
    log_warn "Authorino TLS already enabled with the service-ca cert — skipping."
    return 0
  fi

  # The Gateway's security.opendatahub.io/authorino-tls-bootstrap annotation makes
  # maas-controller create an EnvoyFilter that trusts the cluster's internal service-ca
  # for its connection to Authorino. Authorino's own server cert must therefore be issued
  # by that same service-ca (not a self-signed one), or the Envoy↔Authorino gRPC TLS
  # handshake fails with "gRPC status code is not OK" and every MaaS API call 500s.
  oc annotate service authorino-authorino-authorization -n "$KUADRANT_NS" \
    service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
    --overwrite

  log_info "Waiting for Authorino TLS Secret to be issued by the service-ca operator…"
  local deadline=$(( $(date +%s) + 120 ))
  until oc get secret authorino-server-cert -n "$KUADRANT_NS" &>/dev/null; do
    if (( $(date +%s) > deadline )); then
      log_error "Authorino TLS Secret not issued after 120s."
      oc describe service authorino-authorino-authorization -n "$KUADRANT_NS" 2>/dev/null | tail -10
      exit 1
    fi
    sleep 5
  done
  log_ok "Authorino TLS Secret issued."

  oc patch authorino authorino -n "$KUADRANT_NS" --type=merge -p '{
    "spec": {
      "listener": {
        "tls": {
          "enabled": true,
          "certSecretRef": {"name": "authorino-server-cert"}
        }
      }
    }
  }'
  # Lets Authorino's own outbound HTTPS calls (e.g. maas-api API-key validation) trust
  # certs signed by the same cluster service-ca.
  oc -n "$KUADRANT_NS" set env deployment/authorino \
    SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca.crt
  log_ok "Authorino patched with TLS configuration."
  # Use rollout status rather than pod polling — the patch triggers a rolling restart,
  # so there is a window where the old pod is terminating and the new one hasn't appeared
  # yet; wait_for_pods would see 0 running pods and time out prematurely.
  log_info "Waiting for Authorino deployment rollout to complete…"
  oc rollout status deployment/authorino -n "$KUADRANT_NS" \
    --timeout="${POD_WAIT_TIMEOUT}s" \
    || { log_error "Authorino deployment rollout failed. Aborting."; exit 1; }
  log_ok "Authorino is Running with TLS enabled."
}

deploy_postgresql() {
  log_step "Step 6: Deploying PostgreSQL for MaaS API"

  # Check the StatefulSet (the workload), not the Secret — the Secret can exist
  # without the StatefulSet if it was manually deleted, which would be a silent failure.
  if resource_exists statefulset maas-postgresql "maas-db"; then
    log_warn "StatefulSet 'maas-postgresql' already exists — skipping PostgreSQL deployment."
    # Ensure the DB config Secret is present even if somehow missing.
    if ! resource_exists secret maas-db-config "$RHOAI_APP_NS"; then
      log_warn "Secret 'maas-db-config' missing — re-applying manifest to restore it."
      apply_manifest "${MANIFESTS_DIR}/06d-maas-postgresql.yaml"
    fi
    return 0
  fi

  apply_manifest "${MANIFESTS_DIR}/06d-maas-postgresql.yaml"

  wait_for_pods "maas-db" "app=maas-postgresql" "$POD_WAIT_TIMEOUT" \
    || { log_error "PostgreSQL pod not Running. Aborting."; exit 1; }
  log_ok "PostgreSQL is Running and 'maas-db-config' Secret created."
}

configure_monitoring() {
  log_step "Step 7: Enabling User Workload Monitoring"

  if resource_exists configmap cluster-monitoring-config "openshift-monitoring"; then
    log_warn "cluster-monitoring-config already exists — skipping."
    return 0
  fi

  apply_manifest "${MANIFESTS_DIR}/06f-user-workload-monitoring.yaml"
  log_ok "User Workload Monitoring enabled."
}

# Works around a maas-api/maas-controller version-skew bug (see 06h-maas-api-rbac-workaround.yaml
# for the full explanation). No-ops if the models-as-a-service namespace doesn't exist yet.
# Restarts maas-api only if it isn't currently Running, so a healthy pod is left undisturbed.
apply_maas_api_rbac_workaround() {
  resource_exists namespace models-as-a-service || return 0
  apply_manifest "${MANIFESTS_DIR}/06h-maas-api-rbac-workaround.yaml"
  if resource_exists deployment maas-api "$RHOAI_APP_NS"; then
    local available
    available=$(oc get deployment maas-api -n "$RHOAI_APP_NS" \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
    if [[ "${available:-0}" -lt 1 ]]; then
      log_info "maas-api not currently available — restarting to pick up the RBAC workaround…"
      oc rollout restart deployment/maas-api -n "$RHOAI_APP_NS" &>/dev/null || true
    fi
  fi
}

enable_maas_in_dsc() {
  log_step "Step 8: Enabling MaaS (modelsAsService) in the DataScienceCluster"
  # RHOAI 3.4.x only — spec.components.kserve.modelsAsService is deprecated starting
  # 3.5 (preserved for backward compatibility through 3.6 per the DSC CRD schema, but its
  # CEL rule is one-directional: Managed→Removed is allowed, Removed→Managed is BLOCKED).
  # main()'s version dispatch below selects enable_maas_in_dsc_aigateway() instead on 3.5+.

  local current_state
  current_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null)

  if [[ "$current_state" == "Managed" ]]; then
    log_warn "modelsAsService is already Managed — skipping patch."
    apply_maas_api_rbac_workaround
    return 0
  fi

  log_info "Current modelsAsService.managementState: '${current_state:-unset}' → Managed"
  oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    --type=merge \
    -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Managed"}}}}}'

  log_info "Waiting for DataScienceCluster to reconcile…"
  local deadline=$(( $(date +%s) + OPERATOR_WAIT_TIMEOUT ))
  local dashboard_fix_applied=false
  local maas_api_rbac_patch_applied=false
  while true; do
    local ready
    ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$ready" == "True" ]]; then
      log_ok "DataScienceCluster '${DSC_NAME}' is Ready."
      break
    fi

    # See apply_maas_api_rbac_workaround (defined above) for why this is needed: without
    # it, maas-api can crash-loop forbidden to watch maasauthpolicies, blocking
    # ModelsAsServiceReady (and thus DSC Ready) indefinitely. No-ops until the
    # models-as-a-service namespace exists, so keep retrying each loop iteration.
    if [[ "$maas_api_rbac_patch_applied" == "false" ]] && resource_exists namespace models-as-a-service; then
      apply_maas_api_rbac_workaround
      maas_api_rbac_patch_applied=true
    fi

    # Detect Dashboard rolling-update deadlock: happens on resource-constrained nodes where
    # maxUnavailable=0 (25% of 2 rounds down) prevents terminating an old pod to free CPU
    # for the new one. Fix: switch to maxUnavailable=1, maxSurge=0 so old pod is killed first.
    if [[ "$dashboard_fix_applied" == "false" ]]; then
      local dash_ready
      dash_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
        -o jsonpath='{.status.conditions[?(@.type=="DashboardReady")].status}' 2>/dev/null)
      if [[ "$dash_ready" == "False" ]]; then
        local dash_progressing
        dash_progressing=$(oc get deployment rhods-dashboard -n "$RHOAI_APP_NS" \
          -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)
        if [[ "$dash_progressing" == "ProgressDeadlineExceeded" ]]; then
          log_warn "Dashboard rollout deadlocked (ProgressDeadlineExceeded) — likely insufficient CPU headroom for rolling update on this node."
          log_warn "Applying fix: maxUnavailable=1, maxSurge=0 to allow old pod to be replaced first."
          oc patch deployment rhods-dashboard -n "$RHOAI_APP_NS" --type=merge \
            -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":1,"maxSurge":0}}}}' \
            && dashboard_fix_applied=true \
            || log_warn "Could not patch Dashboard deployment strategy — will keep waiting."
        fi
      fi
    fi

    if (( $(date +%s) > deadline )); then
      log_error "Timed out waiting for DSC to become Ready."
      oc describe dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" 2>/dev/null | tail -30
      return 1
    fi
    sleep 10
  done

  # Verify MaaS dependency warning is informational only (cert-manager + RHCL are now installed)
  local maas_cond
  maas_cond=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="KserveLLMInferenceServiceDependencies")].status}' \
    2>/dev/null)
  if [[ "$maas_cond" == "True" ]]; then
    log_ok "KserveLLMInferenceServiceDependencies condition is True — all dependencies met."
  else
    local msg
    msg=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="KserveLLMInferenceServiceDependencies")].message}' \
      2>/dev/null)
    log_warn "KserveLLMInferenceServiceDependencies: ${msg:-unknown}."
    log_warn "Continuing — this may resolve as operators finish initialising."
  fi
}

enable_maas_in_dsc_aigateway() {
  log_step "Step 8: Enabling MaaS (aigateway.modelsAsAService) in the DataScienceCluster"
  # RHOAI 3.5+ only. Confirmed live against a 3.5.0 cluster: MaaS moved from
  # spec.components.kserve.modelsAsService to spec.components.aigateway.modelsAsAService
  # (note the double-A — not a typo), gated by the PARENT aigateway.managementState, which
  # defaults to Removed if unset. Setting only the modelsAsAService submodule without the
  # parent silently no-ops (DSC status: AIGatewayReady=False/Removed,
  # ModelsAsAServiceReady=False/Removed, "Submodule ManagementState is set to Removed" —
  # even though the submodule's own spec value reads Managed). Both must be set.
  #
  # This also moves maas-api/maas-controller out of the old models-as-a-service namespace
  # into redhat-ai-gateway-infra and a namespaced ai-tenants layout — the 3.4.x
  # apply_maas_api_rbac_workaround (06h-maas-api-rbac-workaround.yaml, scoped to
  # deployment maas-api in RHOAI_APP_NS) does not apply here and is intentionally skipped.

  local aigw_state maas_state
  aigw_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.aigateway.managementState}' 2>/dev/null)
  maas_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null)

  if [[ "$aigw_state" == "Managed" && "$maas_state" == "Managed" ]]; then
    log_warn "aigateway and aigateway.modelsAsAService are already Managed — skipping patch."
  else
    log_info "Current aigateway.managementState: '${aigw_state:-unset}', modelsAsAService: '${maas_state:-unset}' → both Managed"
    oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      --type=merge \
      -p '{"spec":{"components":{"aigateway":{"managementState":"Managed","modelsAsAService":{"managementState":"Managed"}}}}}'
  fi

  log_info "Waiting for DataScienceCluster conditions 'AIGatewayReady' and 'ModelsAsAServiceReady'…"
  local deadline=$(( $(date +%s) + OPERATOR_WAIT_TIMEOUT ))
  local dashboard_fix_applied=false
  while true; do
    local aigw_ready maas_ready
    aigw_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="AIGatewayReady")].status}' 2>/dev/null)
    maas_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null)
    if [[ "$aigw_ready" == "True" && "$maas_ready" == "True" ]]; then
      log_ok "AIGatewayReady and ModelsAsAServiceReady are both True."
      break
    fi

    # Same dashboard rolling-update deadlock as the 3.4.x path (resource-constrained
    # nodes, maxUnavailable=0) — this is generic to the Dashboard component, not tied to
    # which MaaS field enabled it, so it's still worth checking here.
    if [[ "$dashboard_fix_applied" == "false" ]]; then
      local dash_ready
      dash_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
        -o jsonpath='{.status.conditions[?(@.type=="DashboardReady")].status}' 2>/dev/null)
      if [[ "$dash_ready" == "False" ]]; then
        local dash_progressing
        dash_progressing=$(oc get deployment rhods-dashboard -n "$RHOAI_APP_NS" \
          -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)
        if [[ "$dash_progressing" == "ProgressDeadlineExceeded" ]]; then
          log_warn "Dashboard rollout deadlocked (ProgressDeadlineExceeded) — likely insufficient CPU headroom for rolling update on this node."
          log_warn "Applying fix: maxUnavailable=1, maxSurge=0 to allow old pod to be replaced first."
          oc patch deployment rhods-dashboard -n "$RHOAI_APP_NS" --type=merge \
            -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":1,"maxSurge":0}}}}' \
            && dashboard_fix_applied=true \
            || log_warn "Could not patch Dashboard deployment strategy — will keep waiting."
        fi
      fi
    fi

    if (( $(date +%s) > deadline )); then
      log_error "Timed out waiting for AIGatewayReady/ModelsAsAServiceReady."
      oc describe dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" 2>/dev/null | tail -30
      return 1
    fi
    sleep 10
  done
}

enable_genai_studio() {
  log_step "Step 9: Enabling GenAI Studio in OdhDashboardConfig"

  if ! oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" &>/dev/null; then
    log_warn "OdhDashboardConfig 'odh-dashboard-config' not found in '${RHOAI_APP_NS}' — skipping."
    return 0
  fi

  local current
  current=$(oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    -o jsonpath='{.spec.dashboardConfig.genAiStudio}' 2>/dev/null)

  if [[ "$current" == "true" ]]; then
    log_ok "genAiStudio is already enabled — skipping."
    return 0
  fi

  log_info "Current genAiStudio: '${current:-unset}' → enabling"
  oc patch OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    --type=merge \
    --patch='{"spec":{"dashboardConfig":{"genAiStudio": true}}}'
  log_ok "genAiStudio enabled in OdhDashboardConfig."
}

enable_llamastack_operator() {
  log_step "Step 10: Enabling LlamaStack operator in the DataScienceCluster (required for GenAI Playground)"
  # The dashboard's GenAI Playground renders only if genAiStudio is enabled AND the
  # LlamaStack operator component is Managed. genAiStudio alone (Step 9) is not enough —
  # without this, the playground UI is hidden even though the flag is on.
  #
  # RHOAI 3.4.x only — LlamaStack is replaced by OGX starting 3.5EA1 (see
  # ogx-migration.md and enable_ogx_operator() below). This function is selected by
  # main()'s version dispatch, not called directly on 3.5+ clusters.

  local current_state
  current_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.llamastackoperator.managementState}' 2>/dev/null)

  if [[ "$current_state" == "Managed" ]]; then
    log_ok "llamastackoperator is already Managed — skipping patch."
    return 0
  fi

  log_info "Current llamastackoperator.managementState: '${current_state:-unset}' → Managed"
  oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    --type=merge \
    -p '{"spec":{"components":{"llamastackoperator":{"managementState":"Managed"}}}}'

  wait_for_condition "dsc/${DSC_NAME}" "$RHOAI_OPERATOR_NS" \
    "LlamaStackOperatorReady" "$OPERATOR_WAIT_TIMEOUT" \
    || log_warn "LlamaStackOperatorReady condition not confirmed — continuing (LlamaStackDistribution deploy in Step 13 will surface real failures)."
  log_ok "llamastackoperator enabled in DataScienceCluster."
}

enable_ogx_operator() {
  log_step "Step 10: Enabling OGX component in the DataScienceCluster (required for GenAI Playground, RHOAI 3.5+)"
  # RHOAI 3.5EA1+ only — OGX ("Open GenAI Stack") replaces the LlamaStack operator as the
  # Playground backend. Same field-level detection logic as setup-maas-ogx.sh's
  # enable_ogx_operator/validate_ogx_components, verified live against a 3.5.0 cluster.
  # This function does NOT set llamastackoperator to Removed (that's a migration concern,
  # not an initial-setup one — see setup-maas-ogx.sh --keep-llamastack default behavior
  # if you need that on an existing 3.4→3.5 upgrade rather than a fresh 3.5 install).

  local current_state
  current_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null)

  if [[ "$current_state" == "Managed" ]]; then
    log_ok "ogx is already Managed — skipping patch."
  else
    log_info "Current ogx.managementState: '${current_state:-unset}' → Managed"
    oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      --type=merge \
      -p '{"spec":{"components":{"ogx":{"managementState":"Managed"}}}}'
    log_ok "ogx enabled in DataScienceCluster."
  fi

  wait_for_condition "dsc/${DSC_NAME}" "$RHOAI_OPERATOR_NS" \
    "OGXReady" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "OGXReady never reached True. Check the ogx-k8s-operator logs."; exit 1; }

  # The OGX component CR (kind OGX) is cluster-scoped, unlike llamastackoperator's
  # equivalent DSC condition alone — wait_for_condition assumes a namespaced resource,
  # so poll inline here (same approach as setup-maas-ogx.sh's validate_ogx_components).
  log_info "Waiting for the OGX component CR to report Ready…"
  local ogx_deadline=$(( $(date +%s) + OPERATOR_WAIT_TIMEOUT ))
  local ogx_name=""
  while true; do
    ogx_name=$(oc get ogx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$ogx_name" ]]; then
      local ogx_ready
      ogx_ready=$(oc get ogx "$ogx_name" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      [[ "$ogx_ready" == "True" ]] && { log_ok "OGX component CR '${ogx_name}' is Ready."; break; }
    fi
    if (( $(date +%s) > ogx_deadline )); then
      log_error "OGX component CR not Ready after ${OPERATOR_WAIT_TIMEOUT}s."
      oc get ogx 2>/dev/null
      exit 1
    fi
    sleep 10
  done

  wait_for_pods "$RHOAI_APP_NS" "app.kubernetes.io/name=ogx-k8s-operator" "$POD_WAIT_TIMEOUT" \
    || { log_error "ogx-k8s-operator-controller-manager pod not Running."; exit 1; }
  wait_for_pods "$RHOAI_APP_NS" "app.kubernetes.io/name=opendatahub-ogx-operator" "$POD_WAIT_TIMEOUT" \
    || { log_error "opendatahub-ogx-operator pod not Running."; exit 1; }
  log_ok "OGX operator pods are Running in '${RHOAI_APP_NS}'."
}

verify_maas_components() {
  # $1: "true" on RHOAI 3.5+ (set by main()'s version dispatch), "false"/unset on 3.4.x.
  # GatewayConfig is confirmed cluster-scoped on both (gatewayconfigs.services.platform.
  # opendatahub.io) — the "-n $RHOAI_APP_NS" below is accepted but has no effect either way.
  local is_35_plus="${1:-false}"
  log_step "Step 11: Verifying all MaaS platform components"

  # model-serving-api and llmisvc-controller-manager — confirmed unchanged on 3.5+ (same
  # namespace/labels, verified live), so no branching needed for these two.
  wait_for_pods "$RHOAI_APP_NS" "app.kubernetes.io/name=model-serving-api" "$POD_WAIT_TIMEOUT"
  wait_for_pods "$RHOAI_APP_NS" "control-plane=llmisvc-controller-manager" "$POD_WAIT_TIMEOUT"

  if [[ "$is_35_plus" == "true" ]]; then
    # maas-api moved out of RHOAI_APP_NS into a dedicated infra namespace on 3.5+
    # (confirmed live: redhat-ai-gateway-infra), alongside new payload-processing pods in
    # openshift-ingress. The 3.4.x maas-api RBAC-skew workaround (06h manifest, scoped to
    # deployment maas-api in RHOAI_APP_NS) has no evidence of applying to this new
    # architecture — intentionally not called here.
    local ai_gateway_infra_ns="${AI_GATEWAY_INFRA_NS:-redhat-ai-gateway-infra}"
    wait_for_pods "$ai_gateway_infra_ns" "app.kubernetes.io/name=maas-api" "$POD_WAIT_TIMEOUT" \
      || { log_error "maas-api pod not Running in '${ai_gateway_infra_ns}'. Check PostgreSQL/DB connectivity."; exit 1; }
    oc rollout status deployment/maas-api -n "$ai_gateway_infra_ns" --timeout="${POD_WAIT_TIMEOUT}s" \
      || { log_error "maas-api not available in '${ai_gateway_infra_ns}'. Check its logs."; exit 1; }
  else
    # Guaranteed application point for the maas-api RBAC workaround: Step 8's DSC-Ready
    # wait loop applies it opportunistically, but that loop can exit as soon as the DSC's
    # top-level Ready condition goes True — which can happen before maas-api's own
    # ModelsAsServiceReady-relevant crash-loop even surfaces (confirmed live: DSC Ready
    # flipped True on the very first check, before models-as-a-service/maas-api had
    # stabilized). By this point in Step 11 the namespace reliably exists, so apply it
    # unconditionally here as the real backstop.
    apply_maas_api_rbac_workaround

    # maas-api — MaaS platform API (needs PostgreSQL to be up first). wait_for_pods only
    # checks pod phase=Running, which a crash-looping pod can transiently satisfy between
    # restarts — so also confirm the Deployment's rollout actually completes. Using
    # `oc rollout status` (not a raw `oc wait` on pods) both prints its own progress lines
    # (so this doesn't look hung for minutes) and avoids getting stuck on an old,
    # about-to-be-replaced pod that still matches the label selector during a restart.
    wait_for_pods "$RHOAI_APP_NS" "app.kubernetes.io/name=maas-api" "$POD_WAIT_TIMEOUT" \
      || { log_error "maas-api pod not Running. Check PostgreSQL connectivity."; exit 1; }
    if ! oc rollout status deployment/maas-api -n "$RHOAI_APP_NS" --timeout="${POD_WAIT_TIMEOUT}s"; then
      log_warn "maas-api not yet available — restarting once to pick up the RBAC workaround…"
      oc rollout restart deployment/maas-api -n "$RHOAI_APP_NS"
      oc rollout status deployment/maas-api -n "$RHOAI_APP_NS" --timeout="${POD_WAIT_TIMEOUT}s" \
        || { log_error "maas-api still not available after restart. Check its logs for a forbidden/RBAC error."; exit 1; }
    fi
  fi

  # maas-controller — manages Tenant, MaaSAuthPolicy, etc. Confirmed unchanged on 3.5+
  # (still in RHOAI_APP_NS, same control-plane label).
  wait_for_pods "$RHOAI_APP_NS" "control-plane=maas-controller" "$POD_WAIT_TIMEOUT"

  # GatewayConfig should be Ready (cluster-scoped on both versions)
  wait_for_condition "gatewayconfig/default-gateway" "$RHOAI_APP_NS" \
    "GatewayConfigReady" "$POD_WAIT_TIMEOUT"

  # Final: DSC condition name differs by version (see enable_maas_in_dsc_aigateway for the
  # field-mapping background — ModelsAsServiceReady is the 3.4.x condition tied to the
  # deprecated kserve.modelsAsService field; ModelsAsAServiceReady is its 3.5+ replacement).
  if [[ "$is_35_plus" == "true" ]]; then
    wait_for_condition "dsc/${DSC_NAME}" "$RHOAI_OPERATOR_NS" \
      "ModelsAsAServiceReady" "$POD_WAIT_TIMEOUT" \
      || { log_error "ModelsAsAServiceReady never reached True. Check maas-controller logs."; exit 1; }
  else
    wait_for_condition "dsc/${DSC_NAME}" "$RHOAI_OPERATOR_NS" \
      "ModelsAsServiceReady" "$POD_WAIT_TIMEOUT" \
      || { log_error "ModelsAsServiceReady never reached True. Check maas-controller logs."; exit 1; }
  fi

  local domain
  domain=$(oc get gatewayconfig default-gateway -n "$RHOAI_APP_NS" \
    -o jsonpath='{.status.domain}' 2>/dev/null)
  log_ok "MaaS gateway domain: ${domain}"
  echo "$domain"
}

create_model_namespace() {
  log_step "Step 12: Creating MaaS model namespace '${MAAS_MODEL_NS}'"

  if resource_exists namespace "$MAAS_MODEL_NS"; then
    log_warn "Namespace '${MAAS_MODEL_NS}' already exists — skipping."
  else
    apply_manifest "${MANIFESTS_DIR}/07-model-namespace.yaml"
    log_ok "Namespace '${MAAS_MODEL_NS}' created."
  fi

  # Always (re)apply the label, even if the namespace pre-existed from an older version of
  # this script — required for its HTTPRoutes to attach to the Selector-based Gateway from
  # Step 4 (access.redhat.com/solutions/7145755).
  oc label namespace "$MAAS_MODEL_NS" maas-gateway-access="true" --overwrite &>/dev/null
  log_ok "Namespace '${MAAS_MODEL_NS}' labeled maas-gateway-access=true."

  # Patch namespace name in YAML uses the variable; no further action needed.
  log_info "To deploy models, create LLMInferenceService resources in '${MAAS_MODEL_NS}'."
  log_info "See: ${MANIFESTS_DIR}/08-example-llminferenceservice.yaml"
}

print_summary() {
  log_step "Setup complete — Summary"

  local domain
  domain=$(oc get gatewayconfig default-gateway -n "$RHOAI_APP_NS" \
    -o jsonpath='{.status.domain}' 2>/dev/null || echo "<domain>")

  local rhoai_is_35_plus=false
  (( RHOAI_MAJOR > 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR >= 5) )) && rhoai_is_35_plus=true

  local maas_state maas_ready maas_api_ns maas_label_title
  if [[ "$rhoai_is_35_plus" == "true" ]]; then
    maas_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null)
    maas_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null || echo "N/A")
    maas_api_ns="${AI_GATEWAY_INFRA_NS:-redhat-ai-gateway-infra}"
    maas_label_title="ModelsAsAServiceReady"
  else
    maas_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null)
    maas_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}' 2>/dev/null || echo "N/A")
    maas_api_ns="$RHOAI_APP_NS"
    maas_label_title="ModelsAsServiceReady"
  fi

  local kuadrant_ready
  kuadrant_ready=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "N/A")

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║          RHOAI MaaS — Configuration Summary                  ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  ${BOLD}Component${NC}                          ${BOLD}Status${NC}"
  echo -e "  ─────────────────────────────────────────────────────"
  local maas_api_ready maas_gw_prog
  maas_api_ready=$(oc get pods -n "$maas_api_ns" -l "app.kubernetes.io/name=maas-api" \
    --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo 0)
  maas_gw_prog=$(oc get gateway maas-default-gateway -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "N/A")

  echo -e "  cert-manager operator              $(oc get csv -n "$CERT_MANAGER_NS" 2>/dev/null | awk '/cert-manager/{print $NF}' | head -1 || echo 'N/A')"
  echo -e "  RHCL operator                      $(oc get csv -n openshift-operators 2>/dev/null | awk '/rhcl/{print $NF}' | head -1 || echo 'N/A')"
  echo -e "  Kuadrant (kuadrant-system)         Ready=${kuadrant_ready}"
  echo -e "  MaaS Gateway (openshift-ingress)   Programmed=${maas_gw_prog}"
  echo -e "  Authorino TLS                      $(oc get authorino authorino -n "$KUADRANT_NS" -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo 'N/A')"
  echo -e "  PostgreSQL (maas-db)               $(oc get pods -n maas-db -l app=maas-postgresql --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo 0) pod(s) Running"
  echo -e "  maas-api (${maas_api_ns})  ${maas_api_ready} pod(s) Running"
  echo -e "  ${maas_label_title}    ${maas_ready}"
  echo -e "  modelsAsService                    ${maas_state}"
  local genai_studio
  genai_studio=$(oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    -o jsonpath='{.spec.dashboardConfig.genAiStudio}' 2>/dev/null || echo "N/A")
  echo -e "  GenAI Studio (OdhDashboardConfig)  ${genai_studio}"
  if (( RHOAI_MAJOR > 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR >= 5) )); then
    local ogx_state ogx_ready
    ogx_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null || echo "N/A")
    ogx_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="OGXReady")].status}' 2>/dev/null || echo "N/A")
    echo -e "  ogx (Playground backend, 3.5+)     ${ogx_state} (OGXReady=${ogx_ready})"
  else
    local llamastack_state
    llamastack_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      -o jsonpath='{.spec.components.llamastackoperator.managementState}' 2>/dev/null || echo "N/A")
    echo -e "  llamastackoperator                 ${llamastack_state}"
  fi
  echo -e "  GatewayConfig domain               ${domain}"
  echo -e "  Model namespace                    ${MAAS_MODEL_NS}"
  echo
  local gpu_profile
  gpu_profile=$(detect_gpu_hardware_profile "$RHOAI_APP_NS")

  echo -e "  ${BOLD}Next steps:${NC}"
  if [[ -n "$gpu_profile" ]]; then
    echo -e "  GPU HardwareProfile detected: ${BOLD}${gpu_profile}${NC} (deploy-example-workload.sh will use it automatically)"
    echo
  else
    echo -e "  ${YELLOW}[WARN]${NC}  No GPU HardwareProfile found in '${RHOAI_APP_NS}'."
    echo -e "  Create one in the RHOAI dashboard, or pass one explicitly to deploy-example-workload.sh"
    echo -e "  with --hardware-profile-name <name> when you deploy the example model."
    echo
  fi
  echo -e "  1. Deploy the example model and MaaS governance (MaaSModelRef/Subscription/AuthPolicy):"
  echo -e "     ./deploy-example-workload.sh"
  echo
  local apps_domain
  apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "<apps-domain>")
  echo -e "  2. Users mint a MaaS API key, then call the model through it:"
  echo -e "     TOKEN=\$(oc whoami -t)"
  echo -e "     API_KEY=\$(curl -sk -X POST https://maas.${apps_domain}/maas-api/v1/api-keys \\"
  echo -e "       -H \"Authorization: Bearer \$TOKEN\" -H \"Content-Type: application/json\" \\"
  echo -e "       -d '{\"name\":\"my-key\",\"subscription\":\"llama-3-8b-free\",\"expiresIn\":\"1h\"}' | jq -r .key)"
  echo -e "     curl -sk -H \"Authorization: Bearer \$API_KEY\" -H \"Content-Type: application/json\" \\"
  echo -e "       https://maas.${apps_domain}/${MAAS_MODEL_NS}/llama-3-8b/v1/chat/completions \\"
  echo -e "       -d '{\"model\":\"llama-3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
  echo
  echo -e "  ${BOLD}RHOAI Dashboard:${NC}"
  echo -e "  $(oc get route rhods-dashboard -n "$RHOAI_APP_NS" \
    -o jsonpath='https://{.spec.host}' 2>/dev/null || echo 'see: oc get route -n redhat-ods-applications')"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║     RHOAI 3.4 — Models-as-a-Service Automation Setup        ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites

  if [[ "$SKIP_OPERATORS" == "true" || "$SKIP_CERT_MANAGER" == "true" ]]; then
    log_warn "--skip-cert-manager: skipping cert-manager installation."
  else
    install_cert_manager   # Step 2
  fi

  if [[ "$SKIP_OPERATORS" == "true" || "$SKIP_RHCL" == "true" ]]; then
    log_warn "--skip-rhcl: skipping RHCL/Kuadrant installation."
  else
    install_rhcl           # Step 3
  fi

  configure_maas_gateway    # Step 4
  configure_authorino_tls   # Step 5
  deploy_postgresql          # Step 6
  configure_monitoring       # Step 7
  # Step 8: spec.components.kserve.modelsAsService is deprecated starting RHOAI 3.5 in
  # favor of spec.components.aigateway.modelsAsAService — see enable_maas_in_dsc_aigateway()
  # for the field-mapping details. RHOAI_MAJOR/RHOAI_MINOR are set by check_prerequisites.
  local rhoai_is_35_plus=false
  (( RHOAI_MAJOR > 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR >= 5) )) && rhoai_is_35_plus=true

  if [[ "$rhoai_is_35_plus" == "true" ]]; then
    enable_maas_in_dsc_aigateway  # Step 8 (RHOAI 3.5+)
  else
    enable_maas_in_dsc            # Step 8 (RHOAI 3.4.x)
  fi

  enable_genai_studio        # Step 9

  # Step 10: LlamaStack (3.4.x) is fully replaced by OGX starting RHOAI 3.5EA1 — see
  # ogx-migration.md.
  if [[ "$rhoai_is_35_plus" == "true" ]]; then
    enable_ogx_operator         # Step 10 (RHOAI 3.5+)
  else
    enable_llamastack_operator  # Step 10 (RHOAI 3.4.x)
  fi

  verify_maas_components "$rhoai_is_35_plus"    # Step 11
  create_model_namespace     # Step 12

  print_summary
}

main "$@"
