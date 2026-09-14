#!/usr/bin/env bash
# external-model-example.sh
# Configures a MaaS-governed EXTERNAL model (e.g. GPT-5 via the OpenAI API) end-to-end
# and validates it through the real MaaS Gateway — RHOAI 3.5+ ONLY.
#
# This follows the rh-aiservices-bu/rhoai-maas-guide companion guide's Phase 8 procedure
# (https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/08-external-models.html),
# using the RHOAI 3.5+ two-resource CR shape (ExternalProvider + ExternalModel under
# inference.opendatahub.io/v1alpha1) — NOT the older single-resource
# maas.opendatahub.io/v1alpha1 ExternalModel (that's the RHOAI 3.4 shape; this script
# intentionally does not support it).
#
# IMPORTANT — distinct from the AI Playground: this publishes the model through MaaS
# governance (Gateway + API key + subscription/auth policy), the same way as a local
# LLMInferenceService. It does NOT add the model to the GenAI Playground's chat UI — that
# is a separate mechanism (editing the OGXServer's own llama-stack-config ConfigMap to add
# a remote::openai provider), not covered by this script.
#
# Also handles two things confirmed necessary/likely to bite on a fresh cluster:
#   - Sets OdhDashboardConfig.spec.dashboardConfig.externalModels=true (companion guide's
#     Dashboard UI section: without it, the dashboard doesn't properly surface external
#     models — confirmed this flag was entirely absent by default on this cluster).
#   - Detects and recovers from a known CRC-specific failure where maas-api's Postgres
#     schema goes missing (hostpath-provisioner storage churn) without maas-api itself
#     restarting to notice — auto-restarts maas-api and retries once if key-minting 500s
#     with the matching "relation ... does not exist" signature in its logs.
#
# TROUBLESHOOTING — "authType 'apikey' credentials not found" (500) or the request reaching
# OpenAI with no Authorization header at all (401 straight from OpenAI): the ai-gateway
# payload-processing pipeline's model-provider-resolver resolves an ExternalModel by its
# --model-name GLOBALLY BY NAME, not scoped to --namespace — confirmed live: creating a
# second ExternalModel with the same name (e.g. "gpt-5") in a different namespace silently
# hijacked resolution away from this script's copy, and even after deleting the colliding
# one, the resolver's internal store needed this script's own ExternalModel to be re-
# reconciled (e.g. `oc annotate externalmodel <name> -n <ns> force-reconcile="$(date +%s)"
# --overwrite`) before it picked this copy back up. If you're experimenting with multiple
# ExternalModels, use distinct --model-name values, or expect to need that same nudge.
#
# Prerequisites:
#   - RHOAI operator == 3.5.x (this script errors out on any other version)
#   - Base MaaS already configured and Ready (./setup-maas.sh already run — this script
#     checks DSC condition ModelsAsAServiceReady, not the deprecated ModelsAsServiceReady)
#   - At least one local model already deployed and working (per the companion guide's own
#     prerequisite — it validates the Gateway is functional before adding an external one)
#   - An OpenAI API key, provided either via $OPENAI_API_KEY or an existing Secret
#     (--existing-secret) already containing a data key "api-key"
#
# Usage:
#   OPENAI_API_KEY=sk-... ./external-model-example.sh [OPTIONS]
#   ./external-model-example.sh --existing-secret my-openai-secret [OPTIONS]
#
# Options:
#   --existing-secret NAME   Reuse an already-created Secret instead of creating one from
#                              $OPENAI_API_KEY (the Secret must already carry a data key
#                              "api-key" and live in the target namespace).
#   --model-name NAME        Model id at OpenAI and the name used for the CRs (default: gpt-5)
#   --namespace NAME         Namespace for ExternalProvider/ExternalModel/MaaSModelRef
#                              (default: maas-models — same namespace as the local model, so
#                              both share one GenAI Playground/project in the dashboard)
#   --help                   Show this message

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
DSC_NAME="${DSC_NAME:-default-dsc}"

# MaaSSubscription/MaaSAuthPolicy are CRD-fixed to this namespace (confirmed live: the
# example llama-3-8b-free/llama-3-8b-access objects live here, matching manifests/10-11's
# own documented constraint) — not configurable.
MAAS_GOVERNANCE_NS="models-as-a-service"

EXTERNAL_MODEL_NS="${EXTERNAL_MODEL_NS:-maas-models}"
PROVIDER_NAME="${PROVIDER_NAME:-openai}"
MODEL_NAME="${MODEL_NAME:-gpt-5}"
SECRET_NAME="${SECRET_NAME:-openai-api-key}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-${PROVIDER_NAME}-subs}"
TOKEN_RATE_LIMIT="${TOKEN_RATE_LIMIT:-10000}"
TOKEN_RATE_WINDOW="${TOKEN_RATE_WINDOW:-24h}"

OPERATOR_WAIT_TIMEOUT="${OPERATOR_WAIT_TIMEOUT:-180}"  # seconds

# Namespace maas-api actually runs in on RHOAI 3.5+ (confirmed live — NOT RHOAI_APP_NS).
AI_GATEWAY_INFRA_NS="${AI_GATEWAY_INFRA_NS:-redhat-ai-gateway-infra}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXISTING_SECRET=""

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --existing-secret) EXISTING_SECRET="$2"; shift 2 ;;
      --model-name)      MODEL_NAME="$2"; shift 2 ;;
      --namespace)       EXTERNAL_MODEL_NS="$2"; shift 2 ;;
      --help)
        cat <<'USAGE'
external-model-example.sh — Configures a MaaS-governed external model (default: GPT-5 via
OpenAI) end-to-end and validates it through the real MaaS Gateway. RHOAI 3.5+ only.

Usage:
  OPENAI_API_KEY=sk-... ./external-model-example.sh [OPTIONS]
  ./external-model-example.sh --existing-secret my-openai-secret [OPTIONS]

Options:
  --existing-secret NAME   Reuse an already-created Secret (must carry data key "api-key")
                            instead of creating one from $OPENAI_API_KEY.
  --model-name NAME        Model id at OpenAI / CR name (default: gpt-5)
  --namespace NAME         Namespace for ExternalProvider/ExternalModel/MaaSModelRef
                            (default: maas-models — same namespace as the local model, so
                            both share one GenAI Playground/project in the dashboard)
  --help                   Show this message

Does NOT add the model to the GenAI Playground chat UI — that's a separate mechanism
(editing the OGXServer's llama-stack-config ConfigMap). This script only covers the
MaaS-governance/Gateway path: ExternalProvider + ExternalModel (inference.opendatahub.io),
MaaSModelRef + MaaSSubscription + MaaSAuthPolicy (maas.opendatahub.io), then a real curl
through the Gateway with a minted API key.

Environment variables (all optional except OPENAI_API_KEY, shown with defaults):
  OPENAI_API_KEY=<required unless --existing-secret>
  EXTERNAL_MODEL_NS=maas-models        PROVIDER_NAME=openai   MODEL_NAME=gpt-5
  SECRET_NAME=openai-api-key          SUBSCRIPTION_NAME=openai-subs
  TOKEN_RATE_LIMIT=10000              TOKEN_RATE_WINDOW=24h
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
    log_error "'oc' CLI not found."; exit 1
  fi
  if ! oc whoami &>/dev/null; then
    log_error "Not logged in to an OpenShift cluster. Run 'oc login …' first."; exit 1
  fi
  log_ok "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

  if ! oc auth can-i create clusterrole --all-namespaces &>/dev/null; then
    log_error "Current user does not have cluster-admin privileges."; exit 1
  fi

  local rhoai_csv rhoai_version major minor
  rhoai_csv=$(oc get csv -n "$RHOAI_OPERATOR_NS" 2>/dev/null | awk '/rhods-operator/{print $1}' | head -1)
  [[ -z "$rhoai_csv" ]] && { log_error "RHOAI operator not found in '${RHOAI_OPERATOR_NS}'."; exit 1; }
  rhoai_version=$(echo "$rhoai_csv" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  major=$(echo "$rhoai_version" | cut -d. -f1)
  minor=$(echo "$rhoai_version" | cut -d. -f2)
  if [[ "$major" != "3" || "$minor" != "5" ]]; then
    log_error "This script only supports RHOAI 3.5.x (found ${rhoai_version})."
    log_error "The 3.4.x external-model shape (single maas.opendatahub.io ExternalModel) is"
    log_error "not implemented here — see the companion guide's Phase 8 doc for that path."
    exit 1
  fi
  log_ok "RHOAI operator found: ${rhoai_csv} (version ${rhoai_version})"

  if ! resource_exists dsc "$DSC_NAME" "$RHOAI_OPERATOR_NS"; then
    log_error "DataScienceCluster '${DSC_NAME}' not found. Run setup-maas.sh first."; exit 1
  fi

  local maas_ready
  maas_ready=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null)
  if [[ "$maas_ready" != "True" ]]; then
    log_error "DSC condition ModelsAsAServiceReady is not True (found '${maas_ready:-unset}')."
    log_error "Run ./setup-maas.sh first to bring up base MaaS before adding an external model."
    exit 1
  fi
  log_ok "Base MaaS is Ready (ModelsAsAServiceReady=True)."

  for crd in externalproviders.inference.opendatahub.io externalmodels.inference.opendatahub.io \
             maasmodelrefs.maas.opendatahub.io maassubscriptions.maas.opendatahub.io \
             maasauthpolicies.maas.opendatahub.io; do
    if ! oc get crd "$crd" &>/dev/null; then
      log_error "Required CRD '${crd}' not found on this cluster."; exit 1
    fi
  done
  log_ok "All required CRDs are registered."

  if [[ -z "$EXISTING_SECRET" && -z "${OPENAI_API_KEY:-}" ]]; then
    log_error "No OpenAI API key available. Provide one of the following before re-running:"
    echo
    echo -e "  ${BOLD}Option A — let this script create the Secret for you:${NC}"
    echo -e "     export OPENAI_API_KEY='sk-...'"
    echo -e "     ./external-model-example.sh"
    echo
    echo -e "  ${BOLD}Option B — create the Secret yourself first (key never touches this script's${NC}"
    echo -e "  ${BOLD}environment/history), then point this script at it:${NC}"
    echo -e "     oc create secret generic openai-api-key \\"
    echo -e "       -n ${EXTERNAL_MODEL_NS} \\"
    echo -e "       --from-literal=api-key='sk-...'"
    echo -e "     ./external-model-example.sh --existing-secret openai-api-key"
    echo
    echo -e "  Note: Option B requires the namespace ('${EXTERNAL_MODEL_NS}') to already exist —"
    echo -e "  run 'oc create namespace ${EXTERNAL_MODEL_NS}' first if it doesn't."
    echo
    exit 1
  fi

  # The companion guide's own prerequisite: at least one local model already deployed,
  # to confirm the Gateway itself is functional before layering an external model on top.
  if ! oc get llminferenceservice -A --no-headers 2>/dev/null | grep -q .; then
    log_warn "No LLMInferenceService found on the cluster. The companion guide recommends"
    log_warn "having at least one working local model first, to confirm the Gateway is"
    log_warn "functional — continuing anyway, but if the Gateway test at the end fails,"
    log_warn "check a local model's endpoint first to isolate the problem."
  fi
}

enable_external_models_dashboard_flag() {
  log_step "Step 2: Enabling externalModels in OdhDashboardConfig"
  # Per the companion guide's Dashboard UI section
  # (https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/08-external-models.html#dashboard-ui):
  # "To enable the external models tab in the dashboard, the externalModels: true flag must
  # be set in the OdhDashboardConfig ... Without this configuration, the tab will not appear."
  # Confirmed live: this flag was completely absent from spec.dashboardConfig on this cluster
  # (only disableTracking/genAiStudio were set) until we set it manually.

  if ! oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" &>/dev/null; then
    log_warn "OdhDashboardConfig 'odh-dashboard-config' not found in '${RHOAI_APP_NS}' — skipping."
    return 0
  fi

  local current
  current=$(oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    -o jsonpath='{.spec.dashboardConfig.externalModels}' 2>/dev/null)

  if [[ "$current" == "true" ]]; then
    log_ok "externalModels is already enabled — skipping patch."
    return 0
  fi

  log_info "Current externalModels: '${current:-unset}' → enabling"
  oc patch OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    --type=merge \
    --patch='{"spec":{"dashboardConfig":{"externalModels": true}}}'
  log_ok "externalModels enabled in OdhDashboardConfig."
}

create_namespace() {
  log_step "Step 3: Creating namespace '${EXTERNAL_MODEL_NS}'"

  if resource_exists namespace "$EXTERNAL_MODEL_NS"; then
    log_warn "Namespace '${EXTERNAL_MODEL_NS}' already exists — skipping creation."
  else
    oc create namespace "$EXTERNAL_MODEL_NS"
    log_ok "Namespace '${EXTERNAL_MODEL_NS}' created."
  fi

  # maas.opendatahub.io/gateway-access=true is what this repo's Gateway (setup-maas.sh's
  # configure_maas_gateway, manifests/07-gateway.yaml.tmpl) checks via its Selector-based
  # allowedRoutes — confirmed live.
  oc label namespace "$EXTERNAL_MODEL_NS" maas.opendatahub.io/gateway-access="true" --overwrite &>/dev/null
  log_ok "Namespace '${EXTERNAL_MODEL_NS}' labeled for Gateway access."
}

create_secret() {
  log_step "Step 4: Configuring the provider credential Secret"

  if [[ -n "$EXISTING_SECRET" ]]; then
    SECRET_NAME="$EXISTING_SECRET"
    if ! resource_exists secret "$SECRET_NAME" "$EXTERNAL_MODEL_NS"; then
      log_error "--existing-secret '${SECRET_NAME}' not found in '${EXTERNAL_MODEL_NS}'."
      exit 1
    fi
    log_ok "Using existing Secret '${SECRET_NAME}'."
  else
    oc create secret generic "$SECRET_NAME" \
      -n "$EXTERNAL_MODEL_NS" \
      --from-literal=api-key="$OPENAI_API_KEY" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    log_ok "Secret '${SECRET_NAME}' created/updated with data key 'api-key'."
  fi

  # Mandatory per the companion guide: without this label, credential injection into the
  # Gateway request path silently fails and every call 401s. RHOAI 3.5+ label only — this
  # script doesn't support the 3.4.x inference.networking.k8s.io/bbr-managed variant.
  oc label secret "$SECRET_NAME" -n "$EXTERNAL_MODEL_NS" \
    inference.llm-d.ai/ipp-managed="true" --overwrite
  log_ok "Secret '${SECRET_NAME}' labeled inference.llm-d.ai/ipp-managed=true."
}

create_external_provider_and_model() {
  log_step "Step 5: Creating ExternalProvider + ExternalModel (inference.opendatahub.io)"

  cat <<EOF | oc apply -f -
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalProvider
metadata:
  name: ${PROVIDER_NAME}
  namespace: ${EXTERNAL_MODEL_NS}
spec:
  provider: ${PROVIDER_NAME}
  endpoint: api.openai.com
  auth:
    type: apikey
    secretRef:
      name: ${SECRET_NAME}
---
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: ${MODEL_NAME}
  namespace: ${EXTERNAL_MODEL_NS}
spec:
  modelName: ${MODEL_NAME}
  externalProviderRefs:
    - ref:
        name: ${PROVIDER_NAME}
      targetModel: ${MODEL_NAME}
      apiFormat: openai-chat
      path: /v1/chat/completions
EOF

  log_info "Waiting for ExternalProvider '${PROVIDER_NAME}' to be Ready…"
  wait_for_condition "externalprovider/${PROVIDER_NAME}" "$EXTERNAL_MODEL_NS" \
    "Ready" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "ExternalProvider not Ready."; exit 1; }

  log_info "Waiting for ExternalModel '${MODEL_NAME}' to be Ready…"
  wait_for_condition "externalmodel/${MODEL_NAME}" "$EXTERNAL_MODEL_NS" \
    "Ready" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "ExternalModel not Ready."; exit 1; }
}

create_maas_governance() {
  log_step "Step 6: Publishing via MaaSModelRef + MaaSSubscription + MaaSAuthPolicy"
  # Subscription/AuthPolicy use the full schema confirmed live against the llama-3-8b
  # example (owner.groups / modelRefs[].tokenRateLimits / priority) rather than the
  # companion guide's simplified prose example — this shape is the one we've actually
  # proven to reconcile successfully on this cluster.

  cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${MODEL_NAME}
  namespace: ${EXTERNAL_MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: ${MODEL_NAME}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${MAAS_GOVERNANCE_NS}
spec:
  owner:
    groups:
      - name: system:authenticated
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${EXTERNAL_MODEL_NS}
      tokenRateLimits:
        - limit: ${TOKEN_RATE_LIMIT}
          window: ${TOKEN_RATE_WINDOW}
  priority: 10
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${MODEL_NAME}-access
  namespace: ${MAAS_GOVERNANCE_NS}
spec:
  subjects:
    groups:
      - name: system:authenticated
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${EXTERNAL_MODEL_NS}
EOF

  log_info "Waiting for MaaSModelRef '${MODEL_NAME}' to reach phase Ready…"
  local deadline=$(( $(date +%s) + OPERATOR_WAIT_TIMEOUT ))
  while true; do
    local phase
    phase=$(oc get maasmodelref "$MODEL_NAME" -n "$EXTERNAL_MODEL_NS" \
      -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == "Ready" ]] && { log_ok "MaaSModelRef '${MODEL_NAME}' is Ready."; break; }
    if (( $(date +%s) > deadline )); then
      log_error "MaaSModelRef never reached Ready (last phase: '${phase:-unknown}')."
      oc get maasmodelref "$MODEL_NAME" -n "$EXTERNAL_MODEL_NS" -o yaml 2>/dev/null | tail -30
      exit 1
    fi
    sleep 5
  done

  # MaaSModelRef reaching Ready does NOT mean the MaaSSubscription's own rate-limiting
  # policy has finished reconciling into Kuadrant yet — confirmed live: calling the Gateway
  # immediately after this point can 403 with "subscription rate limiting policies are not
  # ready" even though MaaSModelRef, ExternalProvider, and ExternalModel are all Ready.
  # Wait for both the subscription's own Ready condition AND its per-model
  # tokenRateLimitStatuses entry (the literal thing the 403 message refers to).
  log_info "Waiting for MaaSSubscription '${SUBSCRIPTION_NAME}' to be Ready…"
  local sub_deadline=$(( $(date +%s) + OPERATOR_WAIT_TIMEOUT ))
  while true; do
    local sub_ready trl_ready
    sub_ready=$(oc get maassubscription "$SUBSCRIPTION_NAME" -n "$MAAS_GOVERNANCE_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    trl_ready=$(oc get maassubscription "$SUBSCRIPTION_NAME" -n "$MAAS_GOVERNANCE_NS" \
      -o jsonpath="{.status.tokenRateLimitStatuses[?(@.model==\"${MODEL_NAME}\")].ready}" 2>/dev/null)
    if [[ "$sub_ready" == "True" && "$trl_ready" == "true" ]]; then
      log_ok "MaaSSubscription '${SUBSCRIPTION_NAME}' is Ready (rate limit policy accepted)."
      break
    fi
    if (( $(date +%s) > sub_deadline )); then
      log_error "MaaSSubscription never reached Ready (Ready='${sub_ready:-unknown}', tokenRateLimitReady='${trl_ready:-unknown}')."
      oc get maassubscription "$SUBSCRIPTION_NAME" -n "$MAAS_GOVERNANCE_NS" -o yaml 2>/dev/null | tail -30
      exit 1
    fi
    sleep 5
  done
}

test_via_gateway() {
  log_step "Step 7: Testing via the real MaaS Gateway (not the OGX Playground)"

  local apps_domain maas_gw token api_key
  apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
  maas_gw="https://maas.${apps_domain}"
  token=$(oc whoami -t)

  log_info "Minting a MaaS API key against subscription '${SUBSCRIPTION_NAME}'…"
  api_key=$(curl -sk -X POST "${maas_gw}/maas-api/v1/api-keys" \
    -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -d "{\"name\":\"external-model-example\",\"subscription\":\"${SUBSCRIPTION_NAME}\",\"expiresIn\":\"1h\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null)

  if [[ -z "$api_key" ]]; then
    # Known CRC-specific failure mode (diagnosed live on this exact cluster): the
    # maas-postgresql PVC can silently get recreated empty (CRC hostpath-provisioner
    # storage churn, e.g. across a VM pause/resume) without maas-api ever restarting to
    # notice — it keeps believing its schema is applied from its last startup, but the
    # actual DB has zero tables, so every /maas-api/v1/api-keys call 500s with
    # {"error":"Failed to create API key"}. maas-api's own migration logic re-applies the
    # schema cleanly on a fresh connect, so a restart is the fix — confirmed live.
    log_warn "Key minting failed — checking for the known empty-database symptom…"
    local maas_api_pod db_error
    maas_api_pod=$(oc get pods -n "$AI_GATEWAY_INFRA_NS" -o name 2>/dev/null \
      | grep "maas-api-" | grep -v cleanup | head -1)
    db_error=$(oc logs -n "$AI_GATEWAY_INFRA_NS" "${maas_api_pod#pod/}" --tail=200 2>/dev/null \
      | grep -c "does not exist" || true)

    if [[ -n "$maas_api_pod" && "$db_error" -gt 0 ]]; then
      log_warn "Confirmed: maas-api's database is missing its schema (relation ... does not exist)."
      log_info "Restarting maas-api in '${AI_GATEWAY_INFRA_NS}' to re-apply migrations…"
      oc rollout restart deployment/maas-api -n "$AI_GATEWAY_INFRA_NS"
      oc rollout status deployment/maas-api -n "$AI_GATEWAY_INFRA_NS" --timeout="${POD_WAIT_TIMEOUT:-120}s" \
        || { log_error "maas-api rollout did not complete. Check it manually."; exit 1; }

      # `oc rollout status` only confirms Kubernetes-level readiness (the readiness probe
      # passed) — it does NOT guarantee the app has finished reconnecting to Postgres and
      # re-applying its schema. Confirmed live: a single immediate retry can still land in
      # that gap and fail, while a retry moments later against the same pod succeeds. Retry
      # a few times with a short backoff instead of gambling on one immediate attempt.
      local mint_attempt
      for mint_attempt in 1 2 3; do
        log_info "Retrying key minting (attempt ${mint_attempt}/3)…"
        sleep 5
        api_key=$(curl -sk -X POST "${maas_gw}/maas-api/v1/api-keys" \
          -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
          -d "{\"name\":\"external-model-example\",\"subscription\":\"${SUBSCRIPTION_NAME}\",\"expiresIn\":\"1h\"}" \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null)
        [[ -n "$api_key" ]] && break
      done
    fi
  fi

  if [[ -z "$api_key" ]]; then
    log_error "Failed to mint a MaaS API key, including after a maas-api restart."
    log_error "Check maas-api logs manually: oc logs -n ${AI_GATEWAY_INFRA_NS} deployment/maas-api"
    exit 1
  fi
  log_ok "API key minted."

  # Per the companion guide: external models use the PLAIN model name in the request body
  # and are called at the Gateway root, unlike local models which need
  # /<namespace>/<model-name>/v1/chat/completions.
  log_info "Sending a real chat completion through ${maas_gw}/v1/chat/completions…"
  local response
  # max_completion_tokens, not the legacy max_tokens — GPT-5/o-series reject max_tokens
  # with a 400 ("Unsupported parameter", confirmed live). Also sized generously (200, not
  # 20-50) because reasoning tokens count against this budget too — confirmed live that a
  # low budget can be entirely consumed by reasoning before any visible content is emitted
  # (finish_reason: "length" with empty content).
  response=$(curl -sk "${maas_gw}/v1/chat/completions" \
    -H "Authorization: Bearer ${api_key}" -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_completion_tokens\":200}" \
    -w "\nHTTP_STATUS:%{http_code}\n")

  echo "$response"
  if echo "$response" | grep -q "HTTP_STATUS:200"; then
    log_ok "Gateway call succeeded — external model is live and governed end-to-end."
  else
    log_error "Gateway call did not return 200 — check the response above."
    log_error "Common causes: Secret missing inference.llm-d.ai/ipp-managed=true label,"
    log_error "or the ExternalProvider/ExternalModel not yet Ready."
    exit 1
  fi
}

print_summary() {
  log_step "External model setup complete — Summary"

  local apps_domain maas_gw
  apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "<apps-domain>")
  maas_gw="https://maas.${apps_domain}"

  echo
  echo -e "  ${BOLD}Resource${NC}                                    ${BOLD}Namespace${NC}"
  echo -e "  ─────────────────────────────────────────────────────────────"
  echo -e "  ExternalProvider/${PROVIDER_NAME}                    ${EXTERNAL_MODEL_NS}"
  echo -e "  ExternalModel/${MODEL_NAME}                          ${EXTERNAL_MODEL_NS}"
  echo -e "  MaaSModelRef/${MODEL_NAME}                           ${EXTERNAL_MODEL_NS}"
  echo -e "  MaaSSubscription/${SUBSCRIPTION_NAME}                ${MAAS_GOVERNANCE_NS}"
  echo -e "  MaaSAuthPolicy/${MODEL_NAME}-access                  ${MAAS_GOVERNANCE_NS}"
  echo
  echo -e "  ${BOLD}Note:${NC} this model is published through the MaaS Gateway only — it will"
  echo -e "  NOT appear in the GenAI Playground chat UI (that's a separate mechanism; see"
  echo -e "  the header comment of this script)."
  echo
  echo -e "  ${BOLD}Verify it's listed in the MaaS API model catalog:${NC}"
  echo -e "     curl -sk \"${maas_gw}/maas-api/v1/models\" \\"
  echo -e "       -H \"Authorization: Bearer \$(oc whoami -t)\" | python3 -m json.tool"
  echo -e "     # look for: \"id\": \"${MODEL_NAME}\", \"kind\": \"ExternalModel\", \"ready\": true"
  echo
  echo -e "  ${BOLD}Mint a MaaS API key and call the model directly:${NC}"
  echo -e "     API_KEY=\$(curl -sk -X POST \"${maas_gw}/maas-api/v1/api-keys\" \\"
  echo -e "       -H \"Authorization: Bearer \$(oc whoami -t)\" -H \"Content-Type: application/json\" \\"
  echo -e "       -d '{\"name\":\"my-key\",\"subscription\":\"${SUBSCRIPTION_NAME}\",\"expiresIn\":\"1h\"}' \\"
  echo -e "       | python3 -c \"import sys,json; print(json.load(sys.stdin)['key'])\")"
  echo -e "     curl -sk \"${maas_gw}/v1/chat/completions\" \\"
  echo -e "       -H \"Authorization: Bearer \$API_KEY\" -H \"Content-Type: application/json\" \\"
  echo -e "       -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_completion_tokens\":200}'"
  echo -e "     # note: plain model name and no /<namespace>/<model>/ prefix — unlike local models"
  echo
  echo -e "  To remove everything this script created:"
  echo -e "     oc delete maasauthpolicy ${MODEL_NAME}-access -n ${MAAS_GOVERNANCE_NS}"
  echo -e "     oc delete maassubscription ${SUBSCRIPTION_NAME} -n ${MAAS_GOVERNANCE_NS}"
  echo -e "     oc delete maasmodelref ${MODEL_NAME} -n ${EXTERNAL_MODEL_NS}"
  echo -e "     oc delete externalmodel ${MODEL_NAME} -n ${EXTERNAL_MODEL_NS}"
  echo -e "     oc delete externalprovider ${PROVIDER_NAME} -n ${EXTERNAL_MODEL_NS}"
  echo -e "     oc delete secret ${SECRET_NAME} -n ${EXTERNAL_MODEL_NS}   # skip if --existing-secret was used"
  echo -e "     oc delete namespace ${EXTERNAL_MODEL_NS}                  # only if nothing else uses it"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║   RHOAI 3.5 MaaS — External Model Example (GPT-5 / OpenAI)   ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites
  enable_external_models_dashboard_flag
  create_namespace
  create_secret
  create_external_provider_and_model
  create_maas_governance
  test_via_gateway
  print_summary
}

main "$@"
