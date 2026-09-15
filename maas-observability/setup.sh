#!/usr/bin/env bash
# maas-observability/setup.sh
# Enables the RHOAI MaaS usage/showback observability dashboard (Technology Preview) on
# top of an already-configured MaaS platform (../setup-maas.sh).
#
# References:
#   Official: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index#maas-observability_maas-deploy
#   Companion (operator manifests + DSCI patch source): https://github.com/rh-aiservices-bu/rhoai-maas-guide
#
# Usage:
#   ./setup.sh [--skip-operators] [--help]
#
# Options:
#   --skip-operators   Skip installing the Tempo/OpenTelemetry/Cluster Observability
#                       operators (use if already installed on the cluster)
#   --help              Show this message
#
# This script is independent of ../setup-maas.sh/../teardown-maas.sh — it only reads
# from resources they create (Kuadrant, the MaaS Gateway) and does not modify them.

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
MAAS_TENANT_NS="${MAAS_TENANT_NS:-models-as-a-service}"
MAAS_TENANT_NAME="${MAAS_TENANT_NAME:-default-tenant}"
GATEWAY_NS="${GATEWAY_NS:-openshift-ingress}"
GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
DSCI_NAME="${DSCI_NAME:-default-dsci}"

TEMPO_NS="openshift-tempo-operator"
OTEL_NS="openshift-opentelemetry-operator"
COO_NS="openshift-cluster-observability-operator"

OPERATOR_WAIT_TIMEOUT="${OPERATOR_WAIT_TIMEOUT:-600}"   # seconds
DSCI_WAIT_TIMEOUT="${DSCI_WAIT_TIMEOUT:-300}"            # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

SKIP_OPERATORS=false

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --skip-operators) SKIP_OPERATORS=true ;;
      --help)
        cat <<'USAGE'
maas-observability/setup.sh — Enables the MaaS usage/showback observability dashboard.

Usage:
  ./setup.sh [OPTIONS]

Options:
  --skip-operators   Skip installing the Tempo/OpenTelemetry/Cluster Observability
                      operators (use if already installed on the cluster)
  --help              Show this message

Prerequisites: ../setup-maas.sh must have already been run (this script checks for
the Kuadrant CR and the maas-default-gateway Gateway and aborts if either is missing).

Environment variables (all optional, shown with defaults):
  RHOAI_OPERATOR_NS=redhat-ods-operator   RHOAI_APP_NS=redhat-ods-applications
  KUADRANT_NS=kuadrant-system             MAAS_TENANT_NS=models-as-a-service
  MAAS_TENANT_NAME=default-tenant         GATEWAY_NS=openshift-ingress
  GATEWAY_NAME=maas-default-gateway       DSCI_NAME=default-dsci
  OPERATOR_WAIT_TIMEOUT=600               DSCI_WAIT_TIMEOUT=300
USAGE
        exit 0 ;;
      *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
  done
}

# ─── Steps ────────────────────────────────────────────────────────────────────
# (approve_installplan_for_sub, wait_for_csv, wait_for_condition, wait_for_pods,
#  apply_manifest, resource_exists are defined in ../lib/common.sh)

check_prerequisites() {
  log_step "Step 1: Checking prerequisites"

  if ! command -v oc &>/dev/null; then
    log_error "'oc' CLI not found. Install OpenShift CLI and retry."
    exit 1
  fi
  log_ok "oc CLI found: $(oc version --client 2>/dev/null | head -1)"

  if ! oc whoami &>/dev/null; then
    log_error "Not logged in to an OpenShift cluster. Run 'oc login …' first."
    exit 1
  fi
  log_ok "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

  if ! oc auth can-i create clusterrole --all-namespaces &>/dev/null; then
    log_error "Current user does not have cluster-admin privileges."
    exit 1
  fi
  log_ok "cluster-admin privileges confirmed."

  if ! resource_exists dsci "$DSCI_NAME"; then
    log_error "DSCInitialization '${DSCI_NAME}' not found. Is RHOAI installed?"
    exit 1
  fi
  log_ok "DSCInitialization '${DSCI_NAME}' exists."

  detect_rhoai_version

  if ! resource_exists kuadrant kuadrant "$KUADRANT_NS"; then
    log_error "Kuadrant CR not found in '${KUADRANT_NS}'. Run ../setup-maas.sh first."
    exit 1
  fi
  log_ok "Kuadrant CR found in '${KUADRANT_NS}'."

  if ! resource_exists gateway "$GATEWAY_NAME" "$GATEWAY_NS"; then
    log_error "Gateway '${GATEWAY_NAME}' not found in '${GATEWAY_NS}'. Run ../setup-maas.sh first."
    exit 1
  fi
  log_ok "Gateway '${GATEWAY_NAME}' found in '${GATEWAY_NS}'."

  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    log_error "Manifests directory not found: ${MANIFESTS_DIR}"
    exit 1
  fi
  log_ok "Manifests directory found: ${MANIFESTS_DIR}"
}

install_tempo_operator() {
  log_step "Step 2: Installing Tempo operator"

  local phase
  phase=$(oc get csv -n "$TEMPO_NS" 2>/dev/null | awk '/tempo-operator/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "Tempo operator already installed and CSV is Succeeded — skipping."
    return 0
  fi
  [[ -n "$phase" ]] && log_warn "Tempo CSV found but phase is '${phase}' — reinstalling."

  apply_manifest "${MANIFESTS_DIR}/operators/tempo/namespace.yaml"
  apply_manifest "${MANIFESTS_DIR}/operators/tempo/operatorgroup.yaml"
  apply_manifest "${MANIFESTS_DIR}/operators/tempo/subscription.yaml"

  approve_installplan_for_sub "$TEMPO_NS" "tempo-product"

  wait_for_csv "$TEMPO_NS" "tempo-operator" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "Tempo operator CSV failed. Aborting."; exit 1; }
  log_ok "Tempo operator is ready."
}

install_opentelemetry_operator() {
  log_step "Step 3: Installing Red Hat build of OpenTelemetry operator"

  local phase
  phase=$(oc get csv -n "$OTEL_NS" 2>/dev/null | awk '/opentelemetry-operator/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "OpenTelemetry operator already installed and CSV is Succeeded — skipping."
    return 0
  fi
  [[ -n "$phase" ]] && log_warn "OpenTelemetry CSV found but phase is '${phase}' — reinstalling."

  apply_manifest "${MANIFESTS_DIR}/operators/opentelemetry/namespace.yaml"
  apply_manifest "${MANIFESTS_DIR}/operators/opentelemetry/operatorgroup.yaml"
  apply_manifest "${MANIFESTS_DIR}/operators/opentelemetry/subscription.yaml"

  approve_installplan_for_sub "$OTEL_NS" "opentelemetry-product"

  wait_for_csv "$OTEL_NS" "opentelemetry-operator" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "OpenTelemetry operator CSV failed. Aborting."; exit 1; }
  log_ok "OpenTelemetry operator is ready."
}

# Sets RHOAI_MAJOR/RHOAI_MINOR/RHOAI_PATCH (global, not local — read by
# rhoai_supports_coo_latest() below) from the rhods-operator CSV, same approach
# ../setup-maas.sh uses for its own version-gated branching.
detect_rhoai_version() {
  local rhoai_csv rhoai_version
  rhoai_csv=$(oc get csv -n "$RHOAI_OPERATOR_NS" 2>/dev/null \
    | awk '/rhods-operator/{print $1}' | head -1)
  if [[ -z "$rhoai_csv" ]]; then
    log_warn "RHOAI operator CSV not found in '${RHOAI_OPERATOR_NS}' — cannot detect version."
    log_warn "Assuming pre-3.4.3 (pinned COO v1.4.0) for install_coo(); override by editing"
    log_warn "manifests/operators/coo/subscription-latest.yaml usage manually if this is wrong."
    RHOAI_MAJOR=0; RHOAI_MINOR=0; RHOAI_PATCH=0
    return 0
  fi
  rhoai_version=$(echo "$rhoai_csv" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  RHOAI_MAJOR=$(echo "$rhoai_version" | cut -d. -f1)
  RHOAI_MINOR=$(echo "$rhoai_version" | cut -d. -f2)
  RHOAI_PATCH=$(echo "$rhoai_version" | cut -d. -f3)
  log_ok "Detected RHOAI ${rhoai_version} (${rhoai_csv})."
}

# True from RHOAI 3.4.3 onward (and any 3.5+/future major) — the version confirmed to have
# the COO regression fixed that subscription.yaml's v1.4.0 pin otherwise works around.
rhoai_supports_coo_latest() {
  (( RHOAI_MAJOR > 3 )) && return 0
  (( RHOAI_MAJOR == 3 && RHOAI_MINOR > 4 )) && return 0
  (( RHOAI_MAJOR == 3 && RHOAI_MINOR == 4 && RHOAI_PATCH >= 3 )) && return 0
  return 1
}

install_coo() {
  log_step "Step 4: Installing Cluster Observability Operator (COO)"

  local phase
  phase=$(oc get csv -n "$COO_NS" 2>/dev/null | awk '/cluster-observability-operator/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "COO already installed and CSV is Succeeded — skipping."
    return 0
  fi
  [[ -n "$phase" ]] && log_warn "COO CSV found but phase is '${phase}' — reinstalling."

  apply_manifest "${MANIFESTS_DIR}/operators/coo/namespace.yaml"
  apply_manifest "${MANIFESTS_DIR}/operators/coo/operatorgroup.yaml"

  if rhoai_supports_coo_latest; then
    log_info "RHOAI ${RHOAI_MAJOR}.${RHOAI_MINOR}.${RHOAI_PATCH} >= 3.4.3 — tracking COO's stable channel latest (Automatic approval, no version pin)."
    apply_manifest "${MANIFESTS_DIR}/operators/coo/subscription-latest.yaml"
  else
    log_info "RHOAI ${RHOAI_MAJOR}.${RHOAI_MINOR}.${RHOAI_PATCH} < 3.4.3 — using the pinned COO v1.4.0 (Manual approval) to avoid the known regression on newer COO releases."
    apply_manifest "${MANIFESTS_DIR}/operators/coo/subscription.yaml"
  fi

  # No-op if the subscription above already resolved to Automatic approval — this only
  # does something for the pinned (Manual) path.
  approve_installplan_for_sub "$COO_NS" "cluster-observability-operator"

  wait_for_csv "$COO_NS" "cluster-observability-operator" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "COO CSV failed. Aborting."; exit 1; }
  log_ok "Cluster Observability Operator is ready."
}

enable_dsci_monitoring() {
  log_step "Step 5: Enabling metrics/traces storage in DSCInitialization"

  local current_size
  current_size=$(oc get dsci "$DSCI_NAME" \
    -o jsonpath='{.spec.monitoring.metrics.storage.size}' 2>/dev/null)

  if [[ "$current_size" == "5Gi" ]]; then
    log_ok "DSCI monitoring metrics storage already configured — skipping patch."
  else
    log_info "Patching DSCI '${DSCI_NAME}' with metrics/traces storage configuration…"
    oc patch dsci "$DSCI_NAME" --type=merge -p '{
      "spec": {
        "monitoring": {
          "namespace": "redhat-ods-monitoring",
          "metrics": {
            "replicas": 1,
            "storage": {
              "size": "5Gi",
              "retention": "90d"
            }
          },
          "traces": {
            "sampleRatio": "0.1",
            "storage": {
              "backend": "pv",
              "retention": "2160h"
            }
          }
        }
      }
    }'
  fi

  log_info "Waiting for DSCI '${DSCI_NAME}' to reach phase Ready…"
  local deadline=$(( $(date +%s) + DSCI_WAIT_TIMEOUT ))
  until [[ "$(oc get dsci "$DSCI_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; do
    if (( $(date +%s) > deadline )); then
      log_error "DSCI '${DSCI_NAME}' not Ready after ${DSCI_WAIT_TIMEOUT}s."
      oc describe dsci "$DSCI_NAME" 2>/dev/null | tail -20
      exit 1
    fi
    sleep 10
  done
  log_ok "DSCI '${DSCI_NAME}' is Ready."
}

enable_kuadrant_observability() {
  log_step "Step 6: Enabling Kuadrant observability"

  local current
  current=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
    -o jsonpath='{.spec.observability.enable}' 2>/dev/null)

  if [[ "$current" == "true" ]]; then
    log_ok "Kuadrant observability already enabled — skipping."
    return 0
  fi

  log_info "Current observability.enable: '${current:-unset}' → true"
  oc patch kuadrant kuadrant -n "$KUADRANT_NS" \
    --type=merge -p '{"spec":{"observability":{"enable":true}}}'
  log_ok "Kuadrant observability enabled (creates the Limitador PodMonitor)."
}

enable_maas_telemetry() {
  log_step "Step 7: Enabling MaaS gateway telemetry in the Tenant CR"

  local current
  current=$(oc get tenants.maas.opendatahub.io "$MAAS_TENANT_NAME" -n "$MAAS_TENANT_NS" \
    -o jsonpath='{.spec.telemetry.enabled}' 2>/dev/null)

  if [[ "$current" == "true" ]]; then
    log_ok "Tenant telemetry already enabled — skipping."
    return 0
  fi

  log_info "Current telemetry.enabled: '${current:-unset}' → true"
  # Need to disable captureOrganization, and group due to <https://redhat.atlassian.net/browse/CONNLINK-1300>
  oc patch tenants.maas.opendatahub.io "$MAAS_TENANT_NAME" -n "$MAAS_TENANT_NS" \
    --type=merge -p '{
      "spec": {
        "telemetry": {
          "enabled": true,
          "metrics": {
            "captureOrganization": false,
            "captureUser": true,
            "captureGroup": false,
            "captureModelUsage": true
          }
        }
      }
    }'
  log_ok "Tenant telemetry enabled (captureUser=true by default — see README for how to change)."
}

enable_observability_dashboard() {
  log_step "Step 8: Enabling the observability dashboard tab in OdhDashboardConfig"

  if ! oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" &>/dev/null; then
    log_warn "OdhDashboardConfig 'odh-dashboard-config' not found in '${RHOAI_APP_NS}' — skipping."
    return 0
  fi

  local current
  current=$(oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    -o jsonpath='{.spec.dashboardConfig.observabilityDashboard}' 2>/dev/null)

  if [[ "$current" == "true" ]]; then
    log_ok "observabilityDashboard is already enabled — skipping."
    return 0
  fi

  log_info "Current observabilityDashboard: '${current:-unset}' → enabling"
  oc patch OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    --type=merge \
    --patch='{"spec":{"dashboardConfig":{"observabilityDashboard": true}}}'
  log_ok "observabilityDashboard enabled in OdhDashboardConfig."
}

verify_observability_components() {
  log_step "Step 9: Verifying observability components"

  local tempo_csv otel_csv coo_csv
  tempo_csv=$(oc get csv -n "$TEMPO_NS" 2>/dev/null | awk '/tempo-operator/{print $NF}' | head -1)
  otel_csv=$(oc get csv -n "$OTEL_NS" 2>/dev/null | awk '/opentelemetry-operator/{print $NF}' | head -1)
  coo_csv=$(oc get csv -n "$COO_NS" 2>/dev/null | awk '/cluster-observability-operator/{print $NF}' | head -1)

  [[ "$tempo_csv" == "Succeeded" ]] && log_ok "Tempo operator: Succeeded" \
    || log_warn "Tempo operator CSV: ${tempo_csv:-not found}"
  [[ "$otel_csv" == "Succeeded" ]] && log_ok "OpenTelemetry operator: Succeeded" \
    || log_warn "OpenTelemetry operator CSV: ${otel_csv:-not found}"
  [[ "$coo_csv" == "Succeeded" ]] && log_ok "COO: Succeeded" \
    || log_warn "COO CSV: ${coo_csv:-not found}"

  # maas-controller auto-creates both of these itself once Tenant.spec.telemetry.enabled
  # is true (Step 7) — this script never applies them directly. Confirmed live: deleting
  # either one causes maas-controller to recreate it within ~45s via Server-Side Apply, so
  # poll briefly rather than checking only once immediately after Step 7.
  local telemetry_wait_deadline=$(( $(date +%s) + 60 ))
  until resource_exists telemetrypolicies.extensions.kuadrant.io maas-telemetry "$GATEWAY_NS" \
      || (( $(date +%s) > telemetry_wait_deadline )); do
    sleep 5
  done
  if resource_exists telemetrypolicies.extensions.kuadrant.io maas-telemetry "$GATEWAY_NS"; then
    log_ok "TelemetryPolicy 'maas-telemetry' exists in '${GATEWAY_NS}' (auto-created by maas-controller)."
  else
    log_warn "TelemetryPolicy 'maas-telemetry' not found in '${GATEWAY_NS}' after 60s — maas-controller should create this automatically once Tenant telemetry is enabled."
  fi

  if resource_exists telemetry.telemetry.istio.io latency-per-subscription "$GATEWAY_NS"; then
    log_ok "Istio Telemetry 'latency-per-subscription' exists in '${GATEWAY_NS}' (auto-created by maas-controller)."
  else
    log_warn "Istio Telemetry 'latency-per-subscription' not found in '${GATEWAY_NS}'."
  fi

  # Known upstream gap (opendatahub-io/models-as-a-service maas-controller): the
  # TelemetryPolicy it generates references auth.identity.subscription_info.organizationId/
  # costCenter unconditionally. Those are optional MaaSSubscription.spec.tokenMetadata
  # fields — if unset, the CEL evaluation error silently drops the ratelimit-report call to
  # Limitador for that subscription (request still succeeds; usage is just never counted).
  # See ../KCS-MAAS-TELEMETRY-COSTCENTER-CEL.md for the full root cause and workaround.
  local subs_missing_metadata
  subs_missing_metadata=$(oc get maassubscription -A -o json 2>/dev/null \
    | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in data.get('items', []):
    tm = item.get('spec', {}).get('tokenMetadata')
    if not tm or not tm.get('organizationId') or not tm.get('costCenter'):
        print(f\"{item['metadata']['namespace']}/{item['metadata']['name']}\")
" 2>/dev/null)
  if [[ -n "$subs_missing_metadata" ]]; then
    log_warn "MaaSSubscription(s) without tokenMetadata.organizationId/costCenter set (Usage tab will show zero data for these until set):"
    echo "$subs_missing_metadata" | while read -r s; do log_warn "  - ${s}"; done
    log_warn "Fix: oc patch maassubscription <name> -n <namespace> --type=merge -p '{\"spec\":{\"tokenMetadata\":{\"organizationId\":\"<org>\",\"costCenter\":\"<cc>\"}}}'"
  fi

  local kuadrant_obs tenant_telemetry dashboard_flag
  kuadrant_obs=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
    -o jsonpath='{.spec.observability.enable}' 2>/dev/null)
  tenant_telemetry=$(oc get tenants.maas.opendatahub.io "$MAAS_TENANT_NAME" -n "$MAAS_TENANT_NS" \
    -o jsonpath='{.spec.telemetry.enabled}' 2>/dev/null)
  dashboard_flag=$(oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    -o jsonpath='{.spec.dashboardConfig.observabilityDashboard}' 2>/dev/null)

  [[ "$kuadrant_obs" == "true" ]] && log_ok "Kuadrant observability.enable: true" \
    || log_warn "Kuadrant observability.enable: ${kuadrant_obs:-false}"
  [[ "$tenant_telemetry" == "true" ]] && log_ok "Tenant telemetry.enabled: true" \
    || log_warn "Tenant telemetry.enabled: ${tenant_telemetry:-false}"
  [[ "$dashboard_flag" == "true" ]] && log_ok "OdhDashboardConfig observabilityDashboard: true" \
    || log_warn "OdhDashboardConfig observabilityDashboard: ${dashboard_flag:-false}"
}

print_summary() {
  log_step "Setup complete — Summary"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║      MaaS Observability Dashboard — Configuration Summary     ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  ${YELLOW}Technology Preview:${NC} not supported with production SLAs; designed for"
  echo -e "  internal showback reporting, not billing-grade metering."
  echo
  echo -e "  ${BOLD}View it:${NC} RHOAI Dashboard → Observe & monitor → Dashboard → Usage tab"
  echo -e "  $(oc get route rhods-dashboard -n "$RHOAI_APP_NS" \
    -o jsonpath='https://{.spec.host}' 2>/dev/null || echo 'see: oc get route -n redhat-ods-applications')"
  echo
  echo -e "  ${BOLD}Per-user metrics are ON by default${NC} (captureUser=true) — required for the"
  echo -e "  Usage tab's per-user filtered queries to return data"
  echo
  echo -e "  ${RED}${BOLD}Required for the Usage tab to show any data (on RHOAI <= 3.4.2):${NC} every"
  echo -e "  MaaSSubscription needs spec.tokenMetadata.organizationId/costCenter set (Step 9 above"
  echo -e "  lists any that don't). Fixed upstream for RHOAI 3.4.4+ (maas-controller PR #1276/#1311)"
  echo -e "     oc patch maassubscription <name> -n <namespace> --type=merge \\"
  echo -e "       -p '{\"spec\":{\"tokenMetadata\":{\"organizationId\":\"<org>\",\"costCenter\":\"<cc>\"}}}'"
  echo
  echo -e "  ${BOLD}Quick metric check${NC} — the dashboard's Usage tab reads from the platform"
  echo -e "  Thanos Querier (kuadrant-prometheus-datasource), not the Tempo/OTel/COO stack this"
  echo -e "  script installs. Query it the same way the dashboard does:"
  echo -e "     TOKEN=\$(oc whoami -t)"
  echo -e "     curl -sk -H \"Authorization: Bearer \${TOKEN}\" \\"
  echo -e "       'https://thanos-querier.openshift-monitoring.svc:9092/api/v1/query?namespace=${KUADRANT_NS}&query=authorized_calls'"
  echo -e "  (run from inside the cluster, e.g. via 'oc debug', since that Service has no external Route)"
  echo -e "  Requires OpenShift platform monitoring to be running — not the case on a stock CRC/"
  echo -e "  OpenShift Local cluster. See README.md Troubleshooting if this returns nothing."
  echo
  echo -e "  Data appears once users start making requests to MaaS models."
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║   RHOAI 3.4 MaaS — Observability Dashboard Automation Setup   ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites

  if [[ "$SKIP_OPERATORS" == "true" ]]; then
    log_warn "--skip-operators: skipping Tempo/OpenTelemetry/COO installation."
  else
    install_tempo_operator          # Step 2
    install_opentelemetry_operator  # Step 3
    install_coo                     # Step 4
  fi

  enable_dsci_monitoring          # Step 5
  enable_kuadrant_observability   # Step 6
  enable_maas_telemetry           # Step 7
  enable_observability_dashboard  # Step 8
  verify_observability_components # Step 9

  print_summary
}

main "$@"
