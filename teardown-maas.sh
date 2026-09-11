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
  --full  Also uninstall cert-manager and RHCL/Kuadrant operators
          (Subscriptions, CSVs, OperatorGroups, namespaces)
  --yes   Skip the confirmation prompt
  --help  Show this message

Without --full the following are removed:
  - All LlamaStackDistribution, LLMInferenceService, and MaaSModelRef in maas-models
    (plus any leftover AuthPolicy/RateLimitPolicy/TokenRateLimitPolicy/RoleBinding
    from older versions of this script)
  - MaaSSubscription 'llama-3-8b-free' and MaaSAuthPolicy 'llama-3-8b-access'
    in models-as-a-service (the namespace itself is left in place — it's owned by RHOAI)
  - maas-api RBAC workaround (Role/RoleBinding/ClusterRole/ClusterRoleBinding) for the
    maas-api/maas-controller image version-skew bug
  - Namespace maas-models
  - DSC reverted (modelsAsService: Removed)
  - DSC llamastackoperator reverted (Removed) — only if no LlamaStackDistribution
    resources remain anywhere on the cluster (it's cluster-scoped and may be
    used outside MaaS)
  - Gateway maas-default-gateway and its external Route (openshift-ingress)
  - Authorino TLS patch reverted; Certificate + ClusterIssuer deleted
  - PostgreSQL (maas-db namespace + maas-db-config Secret)

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

# ─── Confirmation ─────────────────────────────────────────────────────────────
confirm() {
  if [[ "$YES" == "true" ]]; then return 0; fi
  echo
  echo -e "${YELLOW}${BOLD}WARNING: This will permanently delete MaaS resources.${NC}"
  echo -e "  Cluster : $(oc whoami --show-server 2>/dev/null || echo '<unknown>')"
  echo -e "  User    : $(oc whoami 2>/dev/null || echo '<unknown>')"
  if [[ "$FULL" == "true" ]]; then
    echo -e "  ${RED}--full: cert-manager and RHCL operators will also be uninstalled.${NC}"
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
  oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    --type=merge \
    -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Removed"}}}}}' \
    || log_warn "Could not patch DSC — check manually."
  log_ok "DataScienceCluster modelsAsService set to Removed."
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

delete_maas_gateway() {
  log_step "Deleting MaaS gateway"
  oc delete route maas-default-gateway -n openshift-ingress --ignore-not-found 2>/dev/null || true
  oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found 2>/dev/null || true
  oc delete configmap maas-default-gateway-config -n openshift-ingress --ignore-not-found 2>/dev/null || true
  log_ok "Gateway 'maas-default-gateway' and its Route deleted."
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
  echo -e "${BOLD}${CYAN}║          RHOAI 3 MaaS — Teardown                          ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

  confirm

  delete_model_workloads   # delete workloads before reverting DSC so controller can clean up
  delete_maas_api_rbac_workaround
  revert_dsc
  revert_llamastack_operator
  delete_maas_gateway
  revert_authorino_tls
  delete_postgresql

  if [[ "$FULL" == "true" ]]; then
    delete_cert_manager
    delete_rhcl
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
