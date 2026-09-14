#!/usr/bin/env bash
# teardown-maas.sh
# Removes all resources created by setup-maas.sh.
#
# Usage:
#   ./teardown-maas.sh [--full] [--yes]
#
# Options:
#   --full  Also uninstall cert-manager and RHCL operators
#   --yes   Skip the confirmation prompt
#   --help  Show this message

set -uo pipefail

# ─── Configuration (must match setup-maas.sh) ─────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager-operator}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
MAAS_MODEL_NS="${MAAS_MODEL_NS:-maas-models}"
DSC_NAME="${DSC_NAME:-default-dsc}"

FULL=false
YES=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --full) FULL=true ;;
      --yes)  YES=true ;;
      --help)
        cat <<'USAGE'
teardown-maas.sh — Removes all resources created by setup-maas.sh.

Usage:
  ./teardown-maas.sh [--full] [--yes]

Options:
  --full  Also uninstall cert-manager, RHCL/Kuadrant, the openshift-default GatewayClass,
          and MetalLB (Subscriptions, CSVs, OperatorGroups, namespaces)
  --yes   Skip the confirmation prompt
  --help  Show this message

RHOAI version is auto-detected from the rhods-operator CSV, same as setup-maas.sh, and
determines which DSC fields get reverted below (3.4.x vs 3.5+ differ in field names).

Without --full the following are removed:
  - All LlamaStackDistribution, LLMInferenceService, and MaaSModelRef in maas-models
    (plus any leftover AuthPolicy/RateLimitPolicy/TokenRateLimitPolicy/RoleBinding
    from older versions of this script)
  - MaaSSubscription 'llama-3-8b-free' and MaaSAuthPolicy 'llama-3-8b-access'
    in models-as-a-service (the namespace itself is left in place — it's owned by RHOAI)
  - maas-api RBAC workaround (Role/RoleBinding/ClusterRole/ClusterRoleBinding) for the
    maas-api/maas-controller image version-skew bug (RHOAI 3.4.x only; no-op on 3.5+)
  - Namespace maas-models
  - DSC MaaS setting reverted: modelsAsService (3.4.x) or aigateway/modelsAsAService (3.5+)
  - genAiStudio reverted to false in OdhDashboardConfig
  - DSC Playground backend reverted (Removed): llamastackoperator (3.4.x) or ogx (3.5+)
    — only if no LlamaStackDistribution/OGXServer resources remain anywhere on the
    cluster (both are cluster-scoped and may be used outside MaaS)
  - Gateway maas-default-gateway, its Route (maas-default-gateway-https), and its
    ConfigMap (maas-gateway-options), all in openshift-ingress
  - Authorino TLS patch reverted; Certificate + ClusterIssuer deleted
  - PostgreSQL (maas-db namespace + maas-db-config Secret)

Only with --full:
  - cert-manager and RHCL/Kuadrant operators
  - openshift-default GatewayClass
  - MetalLB (IPAddressPool/L2Advertisement, MetalLB CR, operator) — harmless no-op on
    cloud platforms, where it was never installed

Not removed in either mode:
  - RHOAI operator and DataScienceCluster (pre-existing)
  - cluster-monitoring-config (may be used by other workloads)
  - models-as-a-service namespace (RHOAI cleans it up after DSC revert)
USAGE
        exit 0 ;;
      *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
  done
}

# ─── Version detection ─────────────────────────────────────────────────────────
# Mirrors setup-maas.sh's check_prerequisites() detection exactly, so revert_dsc() and
# revert_llamastack_or_ogx() branch on the same RHOAI_MAJOR/RHOAI_MINOR the setup script
# used to decide which fields to set in the first place (kserve.modelsAsService vs
# aigateway.modelsAsAService, llamastackoperator vs ogx). Global (not local) on purpose —
# read by every revert_* function below.
detect_rhoai_version() {
  local rhoai_csv rhoai_version
  rhoai_csv=$(oc get csv -n "$RHOAI_OPERATOR_NS" 2>/dev/null \
    | awk '/rhods-operator/{print $1}' | head -1)
  if [[ -z "$rhoai_csv" ]]; then
    log_warn "RHOAI operator CSV not found in '${RHOAI_OPERATOR_NS}' — cannot detect version."
    log_warn "Assuming RHOAI >= 3.5 (aigateway/ogx fields) for DSC reverts; adjust manually if wrong."
    RHOAI_MAJOR=3
    RHOAI_MINOR=5
    return 0
  fi
  rhoai_version=$(echo "$rhoai_csv" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  RHOAI_MAJOR=$(echo "$rhoai_version" | cut -d. -f1)
  RHOAI_MINOR=$(echo "$rhoai_version" | cut -d. -f2)
  log_ok "Detected RHOAI ${rhoai_version} (${rhoai_csv})."
}

rhoai_is_35_plus() {
  (( RHOAI_MAJOR > 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR >= 5) ))
}

# ─── Confirmation ─────────────────────────────────────────────────────────────
confirm() {
  if [[ "$YES" == "true" ]]; then return 0; fi
  echo
  echo -e "${YELLOW}${BOLD}WARNING: This will permanently delete MaaS resources.${NC}"
  echo -e "  Cluster : $(oc whoami --show-server 2>/dev/null || echo '<unknown>')"
  echo -e "  User    : $(oc whoami 2>/dev/null || echo '<unknown>')"
  if [[ "$FULL" == "true" ]]; then
    echo -e "  ${RED}--full: cert-manager, RHCL, GatewayClass, and MetalLB will also be uninstalled.${NC}"
  fi
  echo
  read -rp "Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || { echo "Aborted."; exit 0; }
}

# ─── Teardown steps ───────────────────────────────────────────────────────────

delete_model_workloads() {
  log_step "Deleting model workloads in '${MAAS_MODEL_NS}'"
  if ! oc get namespace "$MAAS_MODEL_NS" &>/dev/null; then
    log_warn "Namespace '${MAAS_MODEL_NS}' not found — skipping."
    return 0
  fi
  # Delete workloads first so the controller can clean up dependent resources
  # (HTTPRoutes, certs) before the namespace is forcibly removed.
  oc delete llamastackdistribution --all -n "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true
  oc delete llminferenceservice --all -n "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true
  oc delete maasmodelref --all -n "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true
  # Leftover cleanup for clusters that ran an older version of deploy-example-workload.sh
  # (pre-MaaSModelRef, when governance was bespoke Kuadrant policies per model).
  oc delete authpolicy --all -n "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true
  oc delete ratelimitpolicy --all -n "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true
  oc delete tokenratelimitpolicy --all -n "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding --all -n "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true

  # MaaSSubscription/MaaSAuthPolicy live in models-as-a-service (fixed by the CRD, not
  # maas-models), and that namespace is owned by RHOAI — delete only the named example
  # resources, not the namespace itself.
  oc delete maassubscription llama-3-8b-free -n models-as-a-service --ignore-not-found 2>/dev/null || true
  oc delete maasauthpolicy llama-3-8b-access -n models-as-a-service --ignore-not-found 2>/dev/null || true

  log_info "Waiting 15 s for controller to clean up dependent resources…"
  sleep 15
  oc delete namespace "$MAAS_MODEL_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Namespace '${MAAS_MODEL_NS}' deleted."
}

delete_maas_api_rbac_workaround() {
  log_step "Removing maas-api RBAC workaround (version-skew fix)"
  oc delete role maas-api-authpolicies-workaround -n models-as-a-service --ignore-not-found 2>/dev/null || true
  oc delete rolebinding maas-api-authpolicies-workaround -n models-as-a-service --ignore-not-found 2>/dev/null || true
  oc delete clusterrole maas-api-apiservers-workaround --ignore-not-found 2>/dev/null || true
  oc delete clusterrolebinding maas-api-apiservers-workaround --ignore-not-found 2>/dev/null || true
  log_ok "maas-api RBAC workaround resources removed."
}

revert_dsc() {
  log_step "Reverting DataScienceCluster MaaS setting to 'Removed'"
  if ! oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" &>/dev/null; then
    log_warn "DSC '${DSC_NAME}' not found — skipping."
    return 0
  fi

  if rhoai_is_35_plus; then
    # RHOAI 3.5+: MaaS lives under spec.components.aigateway.modelsAsAService (double-A),
    # gated by the PARENT aigateway.managementState — setup-maas.sh's
    # enable_maas_in_dsc_aigateway() sets both together, so revert both together too;
    # nothing else in this repo's flow depends on aigateway being Managed independent of
    # MaaS. kserve.modelsAsService (the 3.4.x field, preserved on the CRD through 3.6) is
    # left alone here — it was never set by this codebase's 3.5+ path.
    oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      --type=merge \
      -p '{"spec":{"components":{"aigateway":{"managementState":"Removed","modelsAsAService":{"managementState":"Removed"}}}}}' \
      || log_warn "Could not patch DSC — check manually."
    log_ok "DataScienceCluster aigateway/modelsAsAService set to Removed."
  else
    # RHOAI 3.4.x: spec.components.kserve.modelsAsService. Its CEL rule is one-directional
    # (Managed→Removed allowed, Removed→Managed blocked) — reverting here is safe and is
    # exactly the direction the rule permits.
    oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      --type=merge \
      -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Removed"}}}}}' \
      || log_warn "Could not patch DSC — check manually."
    log_ok "DataScienceCluster modelsAsService set to Removed."
  fi
}

revert_genai_studio() {
  log_step "Reverting GenAI Studio flag in OdhDashboardConfig"
  if ! oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" &>/dev/null; then
    log_warn "OdhDashboardConfig 'odh-dashboard-config' not found — skipping."
    return 0
  fi
  oc patch OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    --type=merge --patch='{"spec":{"dashboardConfig":{"genAiStudio": false}}}' \
    || log_warn "Could not patch OdhDashboardConfig — check manually."
  log_ok "genAiStudio set to false in OdhDashboardConfig."
}

revert_llamastack_operator() {
  log_step "Reverting DataScienceCluster llamastackoperator setting"
  if ! oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" &>/dev/null; then
    log_warn "DSC '${DSC_NAME}' not found — skipping."
    return 0
  fi
  # llamastackoperator is cluster-scoped: only disable it if no LlamaStackDistribution
  # workloads remain anywhere on the cluster (there may be ones outside MaaS).
  local remaining
  remaining=$(oc get llamastackdistribution -A --no-headers 2>/dev/null | wc -l)
  if (( remaining > 0 )); then
    log_warn "${remaining} LlamaStackDistribution resource(s) still exist cluster-wide — leaving llamastackoperator Managed."
    return 0
  fi
  oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    --type=merge \
    -p '{"spec":{"components":{"llamastackoperator":{"managementState":"Removed"}}}}' \
    || log_warn "Could not patch DSC — check manually."
  log_ok "DataScienceCluster llamastackoperator set to Removed."
}

revert_ogx_operator() {
  log_step "Reverting DataScienceCluster ogx setting (RHOAI 3.5+ Playground backend)"
  if ! oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" &>/dev/null; then
    log_warn "DSC '${DSC_NAME}' not found — skipping."
    return 0
  fi
  # Same guard as llamastackoperator above, mirrored for OGX's own workload CR
  # (ogxserver.ogx.io, cluster-scoped) — don't disable the operator out from under a
  # server that isn't MaaS's.
  local remaining
  remaining=$(oc get ogxserver -A --no-headers 2>/dev/null | wc -l)
  if (( remaining > 0 )); then
    log_warn "${remaining} OGXServer resource(s) still exist cluster-wide — leaving ogx Managed."
    return 0
  fi
  oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    --type=merge \
    -p '{"spec":{"components":{"ogx":{"managementState":"Removed"}}}}' \
    || log_warn "Could not patch DSC — check manually."
  log_ok "DataScienceCluster ogx set to Removed."
}

delete_maas_gateway() {
  log_step "Deleting MaaS gateway"
  oc delete route maas-default-gateway-https -n openshift-ingress --ignore-not-found 2>/dev/null || true
  oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found 2>/dev/null || true
  oc delete configmap maas-gateway-options -n openshift-ingress --ignore-not-found 2>/dev/null || true
  log_ok "Gateway 'maas-default-gateway' and its Route/ConfigMap deleted."
}

delete_gatewayclass() {
  log_step "Removing openshift-default GatewayClass"
  oc delete gatewayclass openshift-default --ignore-not-found 2>/dev/null || true
  log_ok "GatewayClass 'openshift-default' removed."
}

delete_metallb() {
  log_step "Removing MetalLB (non-cloud platforms only — no-op if never installed)"
  oc delete l2advertisement maas-gateway-pool -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete ipaddresspool maas-gateway-pool -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete metallb metallb -n metallb-system --ignore-not-found 2>/dev/null || true
  local csv
  csv=$(oc get csv -n metallb-system 2>/dev/null | awk '/metallb-operator/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete subscription metallb-operator -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete namespace metallb-system --ignore-not-found 2>/dev/null || true
  log_ok "MetalLB removed."
}

revert_authorino_tls() {
  log_step "Reverting Authorino TLS"
  if oc get authorino authorino -n "$KUADRANT_NS" &>/dev/null; then
    oc patch authorino authorino -n "$KUADRANT_NS" --type=merge \
      -p '{"spec":{"listener":{"tls":{"enabled":false,"certSecretRef":null}}}}' \
      2>/dev/null || log_warn "Could not patch Authorino TLS — check manually."
    log_ok "Authorino TLS disabled."
  else
    log_warn "Authorino CR not found — skipping patch."
  fi
  oc annotate service authorino-authorino-authorization -n "$KUADRANT_NS" \
    service.beta.openshift.io/serving-cert-secret-name- 2>/dev/null || true
  oc delete secret authorino-server-cert -n "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  # Leftover cleanup for clusters that ran an older version of this script (cert-manager-based TLS).
  oc delete certificate authorino-tls -n "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  oc delete secret authorino-tls-secret -n "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  oc delete clusterissuer maas-self-signed --ignore-not-found 2>/dev/null || true
  log_ok "Authorino TLS cert resources deleted."
}

delete_postgresql() {
  log_step "Deleting PostgreSQL"
  oc delete secret maas-db-config -n "$RHOAI_APP_NS" --ignore-not-found 2>/dev/null || true
  oc delete namespace maas-db --ignore-not-found 2>/dev/null || true
  log_ok "PostgreSQL namespace 'maas-db' deleted."
}

delete_cert_manager() {
  log_step "Removing cert-manager operator"
  local csv
  csv=$(oc get csv -n "$CERT_MANAGER_NS" 2>/dev/null | awk '/cert-manager/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n "$CERT_MANAGER_NS" --ignore-not-found 2>/dev/null || true
  oc delete subscription openshift-cert-manager-operator -n "$CERT_MANAGER_NS" --ignore-not-found 2>/dev/null || true
  oc delete operatorgroup -n "$CERT_MANAGER_NS" --all --ignore-not-found 2>/dev/null || true
  oc delete namespace "$CERT_MANAGER_NS" --ignore-not-found 2>/dev/null || true
  log_ok "cert-manager operator removed."
}

delete_rhcl() {
  log_step "Removing RHCL/Kuadrant operator"
  oc delete kuadrant kuadrant -n "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  local csv
  csv=$(oc get csv -n openshift-operators 2>/dev/null | awk '/rhcl/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n openshift-operators --ignore-not-found 2>/dev/null || true
  oc delete subscription rhcl-operator -n openshift-operators --ignore-not-found 2>/dev/null || true
  oc delete namespace "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  log_ok "RHCL/Kuadrant operator removed."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║          RHOAI MaaS — Teardown                              ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

  detect_rhoai_version
  confirm

  delete_model_workloads   # delete workloads before reverting DSC so controller can clean up
  delete_maas_api_rbac_workaround
  revert_dsc
  revert_genai_studio
  if rhoai_is_35_plus; then
    revert_ogx_operator
  else
    revert_llamastack_operator
  fi
  delete_maas_gateway
  revert_authorino_tls
  delete_postgresql

  if [[ "$FULL" == "true" ]]; then
    delete_cert_manager
    delete_rhcl
    delete_gatewayclass
    delete_metallb
  fi

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║                    Teardown complete                         ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  if [[ "$FULL" != "true" ]]; then
    log_info "cert-manager and RHCL operators were left in place (pass --full to remove them)."
  fi
  log_warn "'cluster-monitoring-config' in openshift-monitoring was not removed"
  log_warn "  (may be used by other workloads — delete manually if needed)."
  log_warn "'models-as-a-service' namespace will be cleaned up by RHOAI after DSC reconciles."
}

main "$@"
