#!/usr/bin/env bash
# deploy-example-workload.sh
# LLMInferenceService and its MaaS governance (MaaSModelRef, MaaSSubscription,
# MaaSAuthPolicy) — nothing OGX-specific. Once the model is published to MaaS,
# create the GenAI Playground from the RHOAI dashboard and let the platform
# auto-provision its OGXServer (and, on 3.5, a companion pgvector RAG store);
# delete it from the dashboard the same way to tear it down again for repeat testing.
#
# This is a separate script from setup-maas.sh on purpose: the platform layer
# (operators, gateway, Authorino TLS, DSC/dashboard flags) is close to one-shot,
# while this example workload is something you'll likely redeploy, tweak, or
# tear down independently many times.
#
# Usage:
#   ./deploy-example-workload.sh [--hardware-profile-name NAME] [--help]
#
# Options:
#   --hardware-profile-name NAME GPU HardwareProfile to use (overrides auto-detection)
#   --help                       Show this message

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
MAAS_MODEL_NS="${MAAS_MODEL_NS:-maas-models}"
DSC_NAME="${DSC_NAME:-default-dsc}"

MODEL_WAIT_TIMEOUT="${MODEL_WAIT_TIMEOUT:-600}"   # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

HARDWARE_PROFILE_NAME="${HARDWARE_PROFILE_NAME:-}"
RESOLVED_HW_PROFILE=""

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hardware-profile-name)
        if [[ $# -lt 2 ]]; then
          log_error "--hardware-profile-name requires a value"
          exit 1
        fi
        HARDWARE_PROFILE_NAME="$2"
        shift 2 ;;
      --help)
        cat <<'USAGE'
deploy-example-workload.sh — Deploys the example MaaS workload (model + MaaS governance
only) on top of a platform configured by setup-maas.sh.

This script deliberately does NOT create an OGXServer or GenAI Playground itself — create
the Playground from the RHOAI dashboard once the model below is published, and the platform
auto-provisions its OGXServer (RHOAI 3.5 also auto-provisions a companion pgvector RAG
store). Delete it from the dashboard the same way to tear it down again for repeat testing.

Usage:
  ./deploy-example-workload.sh [OPTIONS]

Options:
  --hardware-profile-name NAME  GPU HardwareProfile to annotate the LLMInferenceService with.
                                 Overrides auto-detection; use this if your cluster has no
                                 'local-gpu' HardwareProfile (the manifest's default) or you
                                 want a specific one. Same effect as env var HARDWARE_PROFILE_NAME.
  --help                        Show this message

Deploys, in order:
  1. LLMInferenceService 'llama-3-8b' (manifests/08)
  2. MaaSModelRef, MaaSSubscription, MaaSAuthPolicy (manifests/09-11) — publishes the
     model to MaaS and grants system:authenticated users a 100k-tokens/24h quota

Once published, the model is callable externally via the MaaS gateway's unified endpoint at
https://maas.<apps-domain>/v1/chat/completions (model selected by the "model" field in the
body, catalog id "publishers/maas-models/models/llama-3-8b"), authenticated with a MaaS API
key (not a raw OpenShift token) — see the summary printed at the end for the exact commands
to mint one.

HardwareProfile resolution order for step 1 (opendatahub.io/hardware-profile-name annotation):
  1. --hardware-profile-name / HARDWARE_PROFILE_NAME, if set
  2. First HardwareProfile in RHOAI_APP_NS with an nvidia.com/gpu identifier, if any
  3. Creates a minimal HardwareProfile named 'nvidia-gpu' in RHOAI_APP_NS (cpu, memory,
     nvidia.com/gpu identifiers) and uses that — the annotation is informational only;
     scheduling is driven by the resource requests in the manifest.

Prerequisites (created by setup-maas.sh):
  - Namespace 'maas-models' must exist
  - DSC component kserve.modelsAsService (3.4) or aigateway.modelsAsAService (3.5+) must
    be Managed

Environment variables (all optional, shown with defaults):
  RHOAI_APP_NS=redhat-ods-applications   MAAS_MODEL_NS=maas-models
  DSC_NAME=default-dsc                   MODEL_WAIT_TIMEOUT=600
  HARDWARE_PROFILE_NAME=<unset>
USAGE
        exit 0 ;;
      *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

# ─── Steps ────────────────────────────────────────────────────────────────────

check_prerequisites() {
  log_step "Step 1: Checking prerequisites"

  if ! command -v oc &>/dev/null; then
    log_error "'oc' CLI not found. Install OpenShift CLI and retry."
    exit 1
  fi

  if ! oc whoami &>/dev/null; then
    log_error "Not logged in to an OpenShift cluster. Run 'oc login …' first."
    exit 1
  fi
  log_ok "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

  if ! resource_exists namespace "$MAAS_MODEL_NS"; then
    log_error "Namespace '${MAAS_MODEL_NS}' not found. Run ./setup-maas.sh first."
    exit 1
  fi

  # RHOAI 3.5 moved MaaS from kserve.modelsAsService to its own top-level
  # aigateway.modelsAsAService component (field name confirmed as-is, double-A,
  # via `oc get dsc -o json` on a live 3.5.0 cluster). Accept either so this
  # script works against 3.4 (kserve.modelsAsService) and 3.5+ (aigateway).
  local maas_state_kserve maas_state_aigateway
  maas_state_kserve=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null)
  maas_state_aigateway=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null)
  if [[ "$maas_state_kserve" != "Managed" && "$maas_state_aigateway" != "Managed" ]]; then
    log_error "DSC '${DSC_NAME}' has neither kserve.modelsAsService nor aigateway.modelsAsAService"
    log_error "set to Managed (kserve.modelsAsService='${maas_state_kserve:-unset}', aigateway.modelsAsAService='${maas_state_aigateway:-unset}')."
    log_error "Run ./setup-maas.sh first."
    exit 1
  fi
  log_ok "MaaS platform prerequisites satisfied (kserve.modelsAsService='${maas_state_kserve:-unset}', aigateway.modelsAsAService='${maas_state_aigateway:-unset}')."

  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    log_error "Manifests directory not found: ${MANIFESTS_DIR}"
    exit 1
  fi
}

deploy_llminferenceservice() {
  log_step "Step 2: Deploying example LLMInferenceService"
  log_warn "The example uses llama-3.1-8B-Instruct FP8 from registry.redhat.io (RHEL AI 1.5 modelcar)."
  log_warn "Actual pod scheduling requires a GPU node with FP8 support (NVIDIA H100/H200 recommended)."

  RESOLVED_HW_PROFILE="$HARDWARE_PROFILE_NAME"
  if [[ -n "$RESOLVED_HW_PROFILE" ]]; then
    log_ok "Using HardwareProfile '${RESOLVED_HW_PROFILE}' (explicitly provided)."
  else
    RESOLVED_HW_PROFILE=$(detect_gpu_hardware_profile "$RHOAI_APP_NS")
    if [[ -n "$RESOLVED_HW_PROFILE" ]]; then
      log_ok "Auto-detected GPU HardwareProfile '${RESOLVED_HW_PROFILE}' in '${RHOAI_APP_NS}'."
    else
      RESOLVED_HW_PROFILE="nvidia-gpu"
      log_warn "No GPU HardwareProfile found in '${RHOAI_APP_NS}' and none provided via --hardware-profile-name."
      log_info "Creating HardwareProfile '${RESOLVED_HW_PROFILE}' in '${RHOAI_APP_NS}' (cpu, memory, nvidia.com/gpu)…"
      if ! create_gpu_hardware_profile "$RHOAI_APP_NS" "$RESOLVED_HW_PROFILE"; then
        exit 1
      fi
      log_ok "Created HardwareProfile '${RESOLVED_HW_PROFILE}' in '${RHOAI_APP_NS}'."
    fi
  fi

  local out
  if ! out=$(sed "s|opendatahub.io/hardware-profile-name:.*|opendatahub.io/hardware-profile-name: ${RESOLVED_HW_PROFILE}|" \
      "${MANIFESTS_DIR}/08-example-llminferenceservice.yaml" | oc apply -f - 2>&1); then
    log_error "Failed to apply LLMInferenceService: ${out}"
    exit 1
  fi
  echo "$out"

  log_info "Waiting for LLMInferenceService to initialise (may take several minutes)…"
  local deadline=$(( $(date +%s) + MODEL_WAIT_TIMEOUT ))
  while true; do
    local ready
    ready=$(oc get llminferenceservice llama-3-8b -n "$MAAS_MODEL_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$ready" == "True" ]]; then
      log_ok "LLMInferenceService 'llama-3-8b' is Ready."
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      log_warn "LLMInferenceService not Ready within $((MODEL_WAIT_TIMEOUT / 60)) minutes — check pod status:"
      oc get pods -n "$MAAS_MODEL_NS" 2>/dev/null
      log_warn "Continuing — governance policies and RBAC below target this service regardless of pod readiness."
      return 0
    fi
    sleep 15
  done
}

publish_maas_governance() {
  log_step "Step 3: Publishing to MaaS (MaaSModelRef, MaaSSubscription, MaaSAuthPolicy)"
  apply_manifest "${MANIFESTS_DIR}/09-example-maas-modelref.yaml"
  apply_manifest "${MANIFESTS_DIR}/10-example-maas-subscription.yaml"
  apply_manifest "${MANIFESTS_DIR}/11-example-maas-auth-policy.yaml"

  log_info "Waiting for MaaSModelRef 'llama-3-8b' to reach phase Ready…"
  local deadline=$(( $(date +%s) + 60 ))
  until [[ "$(oc get maasmodelref llama-3-8b -n "$MAAS_MODEL_NS" \
                -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; do
    if (( $(date +%s) > deadline )); then
      log_warn "MaaSModelRef not Ready within 60s — check manually: oc get maasmodelref llama-3-8b -n ${MAAS_MODEL_NS} -o yaml"
      break
    fi
    sleep 5
  done
  log_ok "MaaS governance published."
}

print_summary() {
  log_step "Example workload deployment — Summary"

  local apps_domain maas_url
  apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "<apps-domain>")
  maas_url="https://maas.${apps_domain}"

  local model_ready modelref_phase
  model_ready=$(oc get llminferenceservice llama-3-8b -n "$MAAS_MODEL_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "N/A")
  modelref_phase=$(oc get maasmodelref llama-3-8b -n "$MAAS_MODEL_NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║          MaaS Example Workload — Summary                     ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  LLMInferenceService 'llama-3-8b' Ready    ${model_ready}"
  echo -e "  HardwareProfile used                       ${RESOLVED_HW_PROFILE}"
  echo -e "  MaaSModelRef phase                         ${modelref_phase}"
  echo -e "  MaaSSubscription + MaaSAuthPolicy applied  (system:authenticated, 100k tokens/24h)"
  echo
  echo -e "  ${BOLD}Inspect resources:${NC}"
  echo -e "     oc get llminferenceservice -n ${MAAS_MODEL_NS}"
  echo -e "     oc get maasmodelref -n ${MAAS_MODEL_NS}"
  echo -e "     oc get maassubscription,maasauthpolicy -n models-as-a-service"
  echo
  echo -e "  ${BOLD}Call the model API (mint a MaaS API key, then use it):${NC}"
  echo -e "     TOKEN=\$(oc whoami -t)"
  echo -e "     API_KEY=\$(curl -sk -X POST ${maas_url}/maas-api/v1/api-keys \\"
  echo -e "       -H \"Authorization: Bearer \$TOKEN\" -H \"Content-Type: application/json\" \\"
  echo -e "       -d '{\"name\":\"my-key\",\"subscription\":\"llama-3-8b-free\",\"expiresIn\":\"1h\"}' | jq -r .key)"
  echo -e "     curl -sk -H \"Authorization: Bearer \$API_KEY\" -H \"Content-Type: application/json\" \\"
  echo -e "       ${maas_url}/v1/chat/completions \\"
  echo -e "       -d '{\"model\":\"publishers/${MAAS_MODEL_NS}/models/llama-3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
  echo
  echo -e "  ${BOLD}GenAI Playground:${NC} create it from the RHOAI dashboard now that the model is"
  echo -e "  published — the platform auto-provisions its OGXServer (and, on 3.5, a companion"
  echo -e "  pgvector RAG store). Delete it from the dashboard the same way to tear it down"
  echo -e "  again for repeat testing."
  echo
  echo -e "  Re-run this script any time to reapply the workload (all steps are idempotent)."
  echo -e "  To remove it: oc delete -f manifests/08-example-llminferenceservice.yaml -f manifests/09-example-maas-modelref.yaml \\"
  echo -e "                   -f manifests/10-example-maas-subscription.yaml -f manifests/11-example-maas-auth-policy.yaml"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║     RHOAI 3 MaaS — Example Workload Deployment              ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites
  deploy_llminferenceservice
  publish_maas_governance
  print_summary
}

main "$@"
