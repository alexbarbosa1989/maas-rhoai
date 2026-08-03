#!/usr/bin/env bash
# maas-observability/teardown.sh
# Removes everything created by maas-observability/setup.sh.
#
# Usage:
#   ./teardown.sh [--full] [--purge-storage] [--yes]
#
# Options:
#   --full           Also uninstall the Tempo, OpenTelemetry, and Cluster Observability operators
#   --purge-storage  Also delete the Prometheus/Perses/Tempo PVCs (destroys collected
#                     metrics/trace data; left in place by default so a future setup.sh
#                     re-run rebinds to the same volumes)
#   --yes            Skip the confirmation prompt
#   --help           Show this message

set -uo pipefail

# ─── Configuration (must match setup.sh) ──────────────────────────────────────
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
RHOAI_MONITORING_NS="${RHOAI_MONITORING_NS:-redhat-ods-monitoring}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
MAAS_TENANT_NS="${MAAS_TENANT_NS:-models-as-a-service}"
MAAS_TENANT_NAME="${MAAS_TENANT_NAME:-default-tenant}"
GATEWAY_NS="${GATEWAY_NS:-openshift-ingress}"
DSCI_NAME="${DSCI_NAME:-default-dsci}"

TEMPO_NS="openshift-tempo-operator"
OTEL_NS="openshift-opentelemetry-operator"
COO_NS="openshift-cluster-observability-operator"

FULL=false
PURGE_STORAGE=false
YES=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --full)           FULL=true ;;
      --purge-storage)  PURGE_STORAGE=true ;;
      --yes)            YES=true ;;
      --help)
        cat <<'USAGE'
maas-observability/teardown.sh — Removes all resources created by maas-observability/setup.sh.

Usage:
  ./teardown.sh [--full] [--purge-storage] [--yes]

Options:
  --full           Also uninstall the Tempo, OpenTelemetry, and Cluster Observability operators
                    (Subscriptions, CSVs, OperatorGroups, namespaces)
  --purge-storage  Also delete the Prometheus/Perses/Tempo PVCs in redhat-ods-monitoring
                    (destroys any collected metrics/trace data)
  --yes            Skip the confirmation prompt
  --help           Show this message

Always removed:
  - Gateway telemetry: TelemetryPolicy 'maas-telemetry' and Istio Telemetry
    'latency-per-subscription' (openshift-ingress)
  - The PersesDashboard/PersesDatasource that maas-api creates directly when Tenant
    telemetry is enabled ('dashboard-3-maas-usage-admin', 'kuadrant-prometheus-datasource'
    in redhat-ods-applications) — these have no ownerReferences, so nothing else garbage
    collects them once telemetry is disabled
  - OdhDashboardConfig.spec.dashboardConfig.observabilityDashboard reverted to false
  - Tenant.spec.telemetry reverted (removed)
  - Kuadrant.spec.observability.enable reverted to false
  - DSCInitialization.spec.monitoring.metrics/traces reverted (removed) — the base
    monitoring.managementState/namespace fields (owned by RHOAI, not this module) are
    left untouched; this also triggers RHOAI's own Monitoring controller to tear down
    the MonitoringStack/Perses CRs and their pods

With --purge-storage, also removed:
  - The Prometheus/Perses/Tempo PVCs (redhat-ods-monitoring) left behind by the
    StatefulSets those operands created — Kubernetes does not auto-delete these, so
    without this flag a future setup.sh re-run rebinds to the same volumes and their
    existing data

With --full, also removed:
  - Tempo, OpenTelemetry, and Cluster Observability operators (Subscription, CSV,
    OperatorGroup, and their namespaces)

Not removed in any mode:
  - The MaaS platform itself (../setup-maas.sh / ../teardown-maas.sh)
  - TempoMonolithic/data-science-tempomonolithic — owned by RHOAI's own Monitoring CR,
    expected to be cascade-deleted by the platform's own controller once traces are
    disabled (may lag behind the other reverts; not managed directly by this script)
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
  echo -e "${YELLOW}${BOLD}WARNING: This will remove the MaaS observability dashboard configuration.${NC}"
  echo -e "  Cluster : $(oc whoami --show-server 2>/dev/null || echo '<unknown>')"
  echo -e "  User    : $(oc whoami 2>/dev/null || echo '<unknown>')"
  if [[ "$FULL" == "true" ]]; then
    echo -e "  ${RED}--full: Tempo, OpenTelemetry, and Cluster Observability operators will also be uninstalled.${NC}"
  fi
  if [[ "$PURGE_STORAGE" == "true" ]]; then
    echo -e "  ${RED}--purge-storage: Prometheus/Perses/Tempo PVCs will be deleted (collected data lost).${NC}"
  fi
  echo
  read -rp "Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || { echo "Aborted."; exit 0; }
}

# ─── Teardown steps ───────────────────────────────────────────────────────────

delete_gateway_telemetry() {
  log_step "Deleting gateway telemetry"
  oc delete telemetrypolicy maas-telemetry -n "$GATEWAY_NS" --ignore-not-found 2>/dev/null || true
  oc delete telemetry.telemetry.istio.io latency-per-subscription -n "$GATEWAY_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Gateway telemetry CRs deleted."
}

# maas-api creates these directly (in reaction to Tenant.spec.telemetry.enabled) with no
# ownerReferences, so nothing else garbage collects them once telemetry is disabled again —
# confirmed live: they survive a plain revert_maas_telemetry with no reconciliation activity
# in maas-api's own logs.
delete_orphaned_perses_resources() {
  log_step "Deleting orphaned Perses dashboard/datasource created by maas-api"
  oc delete persesdashboard dashboard-3-maas-usage-admin -n "$RHOAI_APP_NS" --ignore-not-found 2>/dev/null || true
  oc delete persesdatasource kuadrant-prometheus-datasource -n "$RHOAI_APP_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Orphaned PersesDashboard/PersesDatasource deleted."
}

revert_observability_dashboard() {
  log_step "Reverting OdhDashboardConfig observabilityDashboard flag"
  if ! oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" &>/dev/null; then
    log_warn "OdhDashboardConfig not found — skipping."
    return 0
  fi
  oc patch OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" --type=merge \
    -p '{"spec":{"dashboardConfig":{"observabilityDashboard":false}}}' \
    2>/dev/null || log_warn "Could not patch OdhDashboardConfig — check manually."
  log_ok "observabilityDashboard reverted to false."
}

revert_maas_telemetry() {
  log_step "Reverting Tenant telemetry configuration"
  if ! oc get tenants.maas.opendatahub.io "$MAAS_TENANT_NAME" -n "$MAAS_TENANT_NS" &>/dev/null; then
    log_warn "Tenant '${MAAS_TENANT_NAME}' not found — skipping."
    return 0
  fi
  oc patch tenants.maas.opendatahub.io "$MAAS_TENANT_NAME" -n "$MAAS_TENANT_NS" --type=merge \
    -p '{"spec":{"telemetry":null}}' \
    2>/dev/null || log_warn "Could not patch Tenant telemetry — check manually."
  log_ok "Tenant telemetry configuration removed."
}

revert_kuadrant_observability() {
  log_step "Reverting Kuadrant observability"
  if ! oc get kuadrant kuadrant -n "$KUADRANT_NS" &>/dev/null; then
    log_warn "Kuadrant CR not found — skipping."
    return 0
  fi
  oc patch kuadrant kuadrant -n "$KUADRANT_NS" --type=merge \
    -p '{"spec":{"observability":{"enable":false}}}' \
    2>/dev/null || log_warn "Could not patch Kuadrant observability — check manually."
  log_ok "Kuadrant observability.enable reverted to false."
}

revert_dsci_monitoring() {
  log_step "Reverting DSCI metrics/traces storage configuration"
  if ! oc get dsci "$DSCI_NAME" &>/dev/null; then
    log_warn "DSCI '${DSCI_NAME}' not found — skipping."
    return 0
  fi
  # Only clear the metrics/traces sub-fields this module added — leave
  # spec.monitoring.managementState/namespace alone, they predate this module and are
  # owned by the base RHOAI install.
  oc patch dsci "$DSCI_NAME" --type=merge -p '{
    "spec": {
      "monitoring": {
        "metrics": {
          "replicas": null,
          "storage": null
        },
        "traces": null
      }
    }
  }' 2>/dev/null || log_warn "Could not patch DSCI monitoring — check manually."
  log_ok "DSCI metrics/traces storage configuration removed."
}

delete_tempo_operator() {
  log_step "Removing Tempo operator"
  local csv
  csv=$(oc get csv -n "$TEMPO_NS" 2>/dev/null | awk '/tempo-operator/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n "$TEMPO_NS" --ignore-not-found 2>/dev/null || true
  oc delete subscription tempo-product -n "$TEMPO_NS" --ignore-not-found 2>/dev/null || true
  oc delete operatorgroup -n "$TEMPO_NS" --all --ignore-not-found 2>/dev/null || true
  oc delete namespace "$TEMPO_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Tempo operator removed."
}

delete_opentelemetry_operator() {
  log_step "Removing OpenTelemetry operator"
  local csv
  csv=$(oc get csv -n "$OTEL_NS" 2>/dev/null | awk '/opentelemetry-operator/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n "$OTEL_NS" --ignore-not-found 2>/dev/null || true
  oc delete subscription opentelemetry-product -n "$OTEL_NS" --ignore-not-found 2>/dev/null || true
  oc delete operatorgroup -n "$OTEL_NS" --all --ignore-not-found 2>/dev/null || true
  oc delete namespace "$OTEL_NS" --ignore-not-found 2>/dev/null || true
  log_ok "OpenTelemetry operator removed."
}

delete_coo() {
  log_step "Removing Cluster Observability Operator"
  local csv
  csv=$(oc get csv -n "$COO_NS" 2>/dev/null | awk '/cluster-observability-operator/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n "$COO_NS" --ignore-not-found 2>/dev/null || true
  oc delete subscription cluster-observability-operator -n "$COO_NS" --ignore-not-found 2>/dev/null || true
  oc delete operatorgroup -n "$COO_NS" --all --ignore-not-found 2>/dev/null || true
  oc delete namespace "$COO_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Cluster Observability Operator removed."
}

purge_observability_storage() {
  log_step "Purging Prometheus/Perses/Tempo storage (--purge-storage)"
  # StatefulSet-managed PVCs aren't deleted when their owning CR/StatefulSet is removed —
  # select by the operator that manages each one rather than hardcoding PVC names (which
  # are ordinal-based and would break if replica counts ever change).
  local deleted
  deleted=$(oc get pvc -n "$RHOAI_MONITORING_NS" \
    -l 'app.kubernetes.io/managed-by in (prometheus-operator,perses-operator,tempo-operator)' \
    -o name 2>/dev/null)
  if [[ -z "$deleted" ]]; then
    log_warn "No matching PVCs found in '${RHOAI_MONITORING_NS}' — skipping."
    return 0
  fi
  echo "$deleted" | while read -r pvc; do
    oc delete "$pvc" -n "$RHOAI_MONITORING_NS" --ignore-not-found 2>/dev/null || true
  done
  log_ok "Observability storage purged."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║       MaaS Observability Dashboard — Teardown                 ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

  confirm

  delete_gateway_telemetry
  delete_orphaned_perses_resources
  revert_observability_dashboard
  revert_maas_telemetry
  revert_kuadrant_observability
  revert_dsci_monitoring

  if [[ "$FULL" == "true" ]]; then
    delete_tempo_operator
    delete_opentelemetry_operator
    delete_coo
  fi

  if [[ "$PURGE_STORAGE" == "true" ]]; then
    purge_observability_storage
  fi

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║                    Teardown complete                          ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  if [[ "$FULL" != "true" ]]; then
    log_info "Tempo/OpenTelemetry/COO operators were left in place (pass --full to remove them)."
  fi
  if [[ "$PURGE_STORAGE" != "true" ]]; then
    log_info "Prometheus/Perses/Tempo PVCs were left in place (pass --purge-storage to delete them)."
  fi
  log_warn "'TempoMonolithic/data-science-tempomonolithic' is owned by RHOAI's own Monitoring CR"
  log_warn "  and may take a bit longer to be cascade-deleted by the platform controller."
}

main "$@"
