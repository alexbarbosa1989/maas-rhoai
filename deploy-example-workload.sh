#!/usr/bin/env bash
# deploy-example-workload.sh
# Deploys the example MaaS workload on top of a platform already configured by
# setup-maas.sh: an LLMInferenceService, governance policies (AuthPolicy,
# RateLimitPolicy, TokenRateLimitPolicy), an RBAC viewer binding, and (optionally)
# a LlamaStackDistribution for the RHOAI GenAI Playground.
#
# This is a separate script from setup-maas.sh on purpose: the platform layer
# (operators, gateway, Authorino TLS, DSC/dashboard flags) is close to one-shot,
# while this example workload is something you'll likely redeploy, tweak, or
# tear down independently many times.
#
# Usage:
#   ./deploy-example-workload.sh [--skip-llamastack] [--hardware-profile-name NAME] [--help]
#
# Options:
#   --skip-llamastack            Skip deploying the LlamaStackDistribution (GenAI Playground)
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

SKIP_LLAMASTACK=false
HARDWARE_PROFILE_NAME="${HARDWARE_PROFILE_NAME:-}"
RESOLVED_HW_PROFILE=""

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-llamastack) SKIP_LLAMASTACK=true; shift ;;
      --hardware-profile-name)
        if [[ $# -lt 2 ]]; then
          log_error "--hardware-profile-name requires a value"
          exit 1
        fi
        HARDWARE_PROFILE_NAME="$2"
        shift 2 ;;
      --help)
        cat <<'USAGE'
deploy-example-workload.sh — Deploys the example MaaS workload (model, governance
policies, RBAC, LlamaStack playground) on top of a platform configured by setup-maas.sh.

Usage:
  ./deploy-example-workload.sh [OPTIONS]

Options:
  --skip-llamastack             Skip deploying the LlamaStackDistribution (GenAI Playground)
  --hardware-profile-name NAME  GPU HardwareProfile to annotate the LLMInferenceService with.
                                 Overrides auto-detection; use this if your cluster has no
                                 'local-gpu' HardwareProfile (the manifest's default) or you
                                 want a specific one. Same effect as env var HARDWARE_PROFILE_NAME.
  --help                        Show this message

Deploys, in order:
  1. LLMInferenceService 'llama-3-8b' (manifests/08)
  2. AuthPolicy, RateLimitPolicy, TokenRateLimitPolicy (manifests/09-11)
  3. RoleBinding granting 'view' to group maas-users (manifests/12)
  4. LlamaStackDistribution for the GenAI Playground (manifests/13), unless --skip-llamastack

HardwareProfile resolution order for step 1 (opendatahub.io/hardware-profile-name annotation):
  1. --hardware-profile-name / HARDWARE_PROFILE_NAME, if set
  2. First HardwareProfile in RHOAI_APP_NS with an nvidia.com/gpu identifier, if any
  3. Falls back to the manifest default ('local-gpu') with a warning — the annotation is
     informational only; scheduling is driven by the resource requests in the manifest.

Prerequisites (created by setup-maas.sh):
  - Namespace 'maas-models' must exist
  - DSC component kserve.modelsAsService must be Managed

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

  local maas_state
  maas_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null)
  if [[ "$maas_state" != "Managed" ]]; then
    log_error "DSC '${DSC_NAME}' kserve.modelsAsService is '${maas_state:-unset}', not Managed. Run ./setup-maas.sh first."
    exit 1
  fi
  log_ok "MaaS platform prerequisites satisfied."

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
      RESOLVED_HW_PROFILE="local-gpu"
      log_warn "No GPU HardwareProfile found in '${RHOAI_APP_NS}' and none provided via --hardware-profile-name."
      log_warn "Falling back to manifest default '${RESOLVED_HW_PROFILE}' — this annotation is informational"
      log_warn "only (scheduling is driven by resource requests), but won't match a real profile in the dashboard."
      log_warn "Pass --hardware-profile-name <name> once you've created one, or after checking:"
      log_warn "  oc get hardwareprofile -n ${RHOAI_APP_NS}"
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

apply_governance_policies() {
  log_step "Step 3: Applying governance policies (AuthPolicy, RateLimitPolicy, TokenRateLimitPolicy)"
  apply_manifest "${MANIFESTS_DIR}/09-example-auth-policy.yaml"
  apply_manifest "${MANIFESTS_DIR}/10-example-ratelimit-policy.yaml"
  apply_manifest "${MANIFESTS_DIR}/11-example-token-ratelimit-policy.yaml"
  log_ok "Governance policies applied."
}

grant_rbac() {
  log_step "Step 4: Granting user/group access to the model namespace"
  apply_manifest "${MANIFESTS_DIR}/12-example-rbac-viewer.yaml"
  log_ok "RBAC viewer binding applied."
}

deploy_llamastack() {
  if [[ "$SKIP_LLAMASTACK" == "true" ]]; then
    log_step "Step 5: Deploying LlamaStack for the GenAI Playground"
    log_warn "--skip-llamastack: skipping."
    return 0
  fi

  log_step "Step 5: Deploying LlamaStack for the GenAI Playground"
  log_info "The GenAI Playground talks to LlamaStack, not directly to the LLMInferenceService."

  local apply_out
  apply_out=$(apply_manifest "${MANIFESTS_DIR}/13-llamastack-distribution.yaml")
  echo "$apply_out"

  # LlamaStack reads its config at startup and does not hot-reload — if the ConfigMap
  # content changed on an already-existing resource ("configured", not "created" or
  # "unchanged"), the running pod is stale and won't pick up the new config until
  # restarted.
  if echo "$apply_out" | grep -q "^configmap/llama-stack-config configured"; then
    log_info "llama-stack-config ConfigMap changed — restarting deployment to pick it up…"
    oc rollout restart deployment/lsd-genai-playground -n "$MAAS_MODEL_NS" 2>&1

    # On resource-constrained single-node clusters, maxUnavailable rounds to 0 for a
    # 1-replica deployment, deadlocking the rollout: the new pod can't schedule while
    # the old pod holds the CPU. Break the deadlock by deleting the old pod once a new
    # one is Pending.
    local deadline=$(( $(date +%s) + MODEL_WAIT_TIMEOUT ))
    local deadlock_fix_applied=false
    while true; do
      if oc rollout status deployment/lsd-genai-playground -n "$MAAS_MODEL_NS" --timeout=5s 2>&1 \
          | grep -q "successfully rolled out"; then
        log_ok "LlamaStack deployment rolled out with updated config."
        break
      fi
      if [[ "$deadlock_fix_applied" == "false" ]]; then
        local pending_new running_old
        pending_new=$(oc get pods -n "$MAAS_MODEL_NS" -l app=llama-stack 2>/dev/null | grep -c Pending || true)
        running_old=$(oc get pods -n "$MAAS_MODEL_NS" -l app=llama-stack 2>/dev/null | grep -c Running || true)
        if (( pending_new > 0 && running_old > 0 )); then
          local old_pod
          old_pod=$(oc get pods -n "$MAAS_MODEL_NS" -l app=llama-stack 2>/dev/null | awk '/Running/{print $1}' | head -1)
          if [[ -n "$old_pod" ]]; then
            log_warn "CPU deadlock detected (new pod Pending, old pod Running) — deleting old pod '${old_pod}' to free resources."
            oc delete pod "$old_pod" -n "$MAAS_MODEL_NS" 2>&1
            deadlock_fix_applied=true
          fi
        fi
      fi
      if (( $(date +%s) > deadline )); then
        log_warn "Timed out waiting for LlamaStack rollout — check manually: oc get pods -n ${MAAS_MODEL_NS} -l app=llama-stack"
        break
      fi
      sleep 5
    done
  else
    wait_for_pods "$MAAS_MODEL_NS" "app=llama-stack" "$MODEL_WAIT_TIMEOUT" \
      || log_warn "LlamaStack pod not confirmed Running — check manually: oc get pods -n ${MAAS_MODEL_NS} -l app=llama-stack"
  fi

  log_ok "LlamaStackDistribution applied."
}

print_summary() {
  log_step "Example workload deployment — Summary"

  local domain
  domain=$(oc get gatewayconfig default-gateway -n "$RHOAI_APP_NS" \
    -o jsonpath='{.status.domain}' 2>/dev/null || echo "<domain>")

  local model_ready llamastack_state
  model_ready=$(oc get llminferenceservice llama-3-8b -n "$MAAS_MODEL_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "N/A")
  llamastack_state="skipped"
  [[ "$SKIP_LLAMASTACK" != "true" ]] && llamastack_state=$(oc get pods -n "$MAAS_MODEL_NS" -l app=llama-stack \
    --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo 0)

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║          MaaS Example Workload — Summary                     ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  LLMInferenceService 'llama-3-8b' Ready   ${model_ready}"
  echo -e "  HardwareProfile used                      ${RESOLVED_HW_PROFILE}"
  echo -e "  Governance policies (AuthPolicy/RLP/TRLP) applied"
  echo -e "  RBAC viewer binding                       applied"
  if [[ "$SKIP_LLAMASTACK" == "true" ]]; then
    echo -e "  LlamaStack (GenAI Playground)             skipped (--skip-llamastack)"
  else
    echo -e "  LlamaStack (GenAI Playground)              ${llamastack_state} pod(s) Running"
  fi
  echo
  echo -e "  ${BOLD}Inspect resources:${NC}"
  echo -e "     oc get llminferenceservice -n ${MAAS_MODEL_NS}"
  echo -e "     oc get authpolicy,ratelimitpolicy,tokenratelimitpolicy -n ${MAAS_MODEL_NS}"
  echo -e "     oc get httproute -n ${MAAS_MODEL_NS}"
  [[ "$SKIP_LLAMASTACK" != "true" ]] && echo -e "     oc get llamastackdistribution -n ${MAAS_MODEL_NS}"
  echo
  echo -e "  ${BOLD}Call the model API with an OpenShift bearer token:${NC}"
  echo -e "     TOKEN=\$(oc whoami -t)"
  echo -e "     curl -H \"Authorization: Bearer \$TOKEN\" \\"
  echo -e "       https://llama-3-8b-maas-models.${domain}/v1/chat/completions \\"
  echo -e "       -d '{\"model\":\"llama-3-1-8b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
  echo
  echo -e "  Re-run this script any time to reapply the workload (all steps are idempotent)."
  echo -e "  To remove it: oc delete -f manifests/08-example-llminferenceservice.yaml -f manifests/09-example-auth-policy.yaml \\"
  echo -e "                   -f manifests/10-example-ratelimit-policy.yaml -f manifests/11-example-token-ratelimit-policy.yaml \\"
  echo -e "                   -f manifests/12-example-rbac-viewer.yaml -f manifests/13-llamastack-distribution.yaml"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║     RHOAI 3.4 MaaS — Example Workload Deployment             ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites
  deploy_llminferenceservice
  apply_governance_policies
  grant_rbac
  deploy_llamastack
  print_summary
}

main "$@"
