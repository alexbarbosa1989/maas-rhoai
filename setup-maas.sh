#!/usr/bin/env bash
# setup-maas.sh
# Complete, standalone MaaS platform setup using the rh-aiservices-bu "rhoai-maas-guide"
# companion guide's Gateway approach (openshift-default GatewayClass, LoadBalancer Service
# on cloud platforms, passthrough Route on non-cloud, reuses the cluster's existing default
# ingress TLS cert). This is the only supported MaaS setup procedure in this repo — an
# earlier ClusterIP+Route/data-science-gateway-class approach was retired because its
# Gateway listener could never expose a real external hostname, which permanently broke the
# dashboard's AI Hub page.
#
# CONFIRMED LIVE (RHOAI 3.5.0, ROSA + CRC): maas-api's tenant/hostname-resolution endpoint
# (/maas-api/v1/tenants — what the dashboard's AI Hub / "AI asset endpoints" page depends
# on) requires the Gateway's own status/listeners to expose a real external hostname. This
# script's Gateway template (manifests/07-gateway.yaml.tmpl) sets
# `hostname: maas.<cluster-domain>` directly on its listeners, so on platforms where the
# Gateway actually reaches Programmed=True (cloud platforms with a LoadBalancer, or
# non-cloud with a working MetalLB — installed automatically, see below), the AI Hub page
# works correctly.
#
# PLATFORM DETECTION IS ALWAYS AUTOMATIC, NEVER PROMPTED: cloud vs. non-cloud is read from
# `oc get infrastructure cluster -o jsonpath='{.status.platform}'` (the same field the
# upstream rhoai-maas-guide tells readers to check manually) — this script just acts on it
# instead of asking the reader to branch by hand. On non-cloud platforms (None/BareMetal/
# OpenStack/VSphere — this includes CRC), MetalLB is installed and configured automatically
# (install_metallb, Step 7) unless --skip-metallb is passed; on cloud platforms it's skipped
# entirely since a native LoadBalancer already exists. The MetalLB address pool itself
# defaults to an auto-derived single address (first node's own InternalIP + 1 on the last
# octet — the same formula the upstream guide uses), overridable via --metallb-ip-range for
# networks where that derived address isn't actually free.
#
# KNOWN ISSUE if MetalLB is skipped or fails on a non-cloud platform: the Gateway's Service
# is always type LoadBalancer regardless of platform, so without a working LoadBalancer
# provider it can stay Programmed=False indefinitely — this is upstream issue
# https://github.com/opendatahub-io/models-as-a-service/issues/331, not a bug in this
# script.
#
# References:
#   Procedure: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/02-platform-config.html
#   Manifests: https://github.com/rh-aiservices-bu/rhoai-maas-guide/tree/main/manifests/02-platform-config
#
# Usage:
#   ./setup-maas.sh [--skip-operators] [--extra-gateway-namespace NS] [--help]

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager-operator}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
MAAS_MODEL_NS="${MAAS_MODEL_NS:-maas-models}"
DSC_NAME="${DSC_NAME:-default-dsc}"
GATEWAY_NS="openshift-ingress"

# Namespace maas-api runs in on RHOAI 3.5+ (confirmed live — NOT RHOAI_APP_NS). Only used
# by the 3.5+ verify/enable branches below.
AI_GATEWAY_INFRA_NS="${AI_GATEWAY_INFRA_NS:-redhat-ai-gateway-infra}"

OPERATOR_WAIT_TIMEOUT="${OPERATOR_WAIT_TIMEOUT:-600}"   # seconds
POD_WAIT_TIMEOUT="${POD_WAIT_TIMEOUT:-300}"             # seconds
GATEWAY_WAIT_TIMEOUT="${GATEWAY_WAIT_TIMEOUT:-120}"     # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

# MetalLB address pool — empty means auto-derive (first node's InternalIP + 1 on the last
# octet, a single-address pool), matching the rh-aiservices-bu rhoai-maas-guide's own
# formula exactly. Override for networks where that derived address isn't actually free.
METALLB_NS="${METALLB_NS:-metallb-system}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"

SKIP_OPERATORS=false
SKIP_CERT_MANAGER=false
SKIP_RHCL=false
SKIP_KUADRANT=false
SKIP_METALLB=false
EXTRA_GATEWAY_NAMESPACES=()

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-operators)    SKIP_OPERATORS=true; shift ;;
      --skip-cert-manager) SKIP_CERT_MANAGER=true; shift ;;
      --skip-rhcl)         SKIP_RHCL=true; shift ;;
      --skip-kuadrant)     SKIP_KUADRANT=true; shift ;;
      --skip-metallb)      SKIP_METALLB=true; shift ;;
      --metallb-ip-range)
        if [[ $# -lt 2 ]]; then
          log_error "--metallb-ip-range requires a value (e.g. 192.168.130.99-192.168.130.99)"
          exit 1
        fi
        METALLB_IP_RANGE="$2"; shift 2 ;;
      --extra-gateway-namespace)
        EXTRA_GATEWAY_NAMESPACES+=("$2"); shift 2 ;;
      --help)
        cat <<'USAGE'
setup-maas.sh — Complete, standalone MaaS platform setup using the rh-aiservices-bu
rhoai-maas-guide companion guide's Gateway approach (openshift-default GatewayClass,
LoadBalancer/passthrough-Route, reuses the cluster's default ingress TLS cert).

Fully self-contained: installs everything needed (operators, Gateway, Authorino TLS,
PostgreSQL, DSC/dashboard flags, model namespace) in one run.

Usage:
  ./setup-maas.sh [OPTIONS]

Options:
  --skip-operators                Skip both cert-manager and RHCL operator installation
  --skip-cert-manager              Skip cert-manager installation only
  --skip-rhcl                      Skip RHCL operator installation only (Kuadrant CR/
                                    Authorino TLS config still runs — use --skip-kuadrant
                                    to skip that too)
  --skip-kuadrant                  Skip Kuadrant CR creation and Authorino TLS config
                                    (use if already configured from a prior run)
  --skip-metallb                   Skip MetalLB install (non-cloud platforms only; use if
                                    already installed/configured, or if using a different
                                    LoadBalancer provider entirely)
  --metallb-ip-range RANGE         Override the auto-derived MetalLB address pool (e.g.
                                    192.168.130.99-192.168.130.99). Default: first node's
                                    own InternalIP + 1 on the last octet (single address) —
                                    matches the rhoai-maas-guide's own formula. Override this
                                    if that derived address isn't actually free on your
                                    network. Same effect as env var METALLB_IP_RANGE.
  --extra-gateway-namespace NS     Label an additional namespace
                                    maas.opendatahub.io/gateway-access=true (repeatable).
                                    redhat-ods-applications and the model namespace are
                                    always labeled.
  --help                           Show this message

Note: Each operator step auto-detects whether it is already installed by checking for its
CRDs. The --skip-* flags force-bypass even that detection.

Deploys, in order: cert-manager + RHCL operators, Kuadrant CR + Authorino TLS,
User Workload Monitoring, MetalLB (non-cloud platforms only — skipped entirely on
AWS/Azure/GCP/IBM Cloud), openshift-default GatewayClass, the MaaS Gateway (+ passthrough
Route on non-cloud platforms), PostgreSQL, DSC modelsAsService/aigateway enablement,
GenAI Studio + OGX/LlamaStack dashboard flags, component verification, and the MaaS model
namespace. Does not deploy any model — run deploy-example-workload.sh afterwards.

Platform (cloud vs. non-cloud) is auto-detected via
`oc get infrastructure cluster -o jsonpath='{.status.platform}'` — never prompted for.

Environment variables (all optional, shown with defaults):
  RHOAI_OPERATOR_NS=redhat-ods-operator   RHOAI_APP_NS=redhat-ods-applications
  CERT_MANAGER_NS=cert-manager-operator   KUADRANT_NS=kuadrant-system
  MAAS_MODEL_NS=maas-models               DSC_NAME=default-dsc
  AI_GATEWAY_INFRA_NS=redhat-ai-gateway-infra
  METALLB_NS=metallb-system               METALLB_IP_RANGE=<auto-derived>
  OPERATOR_WAIT_TIMEOUT=600               POD_WAIT_TIMEOUT=300
  GATEWAY_WAIT_TIMEOUT=120
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

  local rhoai_csv
  rhoai_csv=$(oc get csv -n "$RHOAI_OPERATOR_NS" 2>/dev/null \
    | awk '/rhods-operator/{print $1}' | head -1)
  if [[ -z "$rhoai_csv" ]]; then
    log_error "Red Hat OpenShift AI operator not found in namespace '${RHOAI_OPERATOR_NS}'."
    log_error "Install RHOAI before running this script."
    exit 1
  fi
  local rhoai_version
  rhoai_version=$(echo "$rhoai_csv" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  RHOAI_MAJOR=$(echo "$rhoai_version" | cut -d. -f1)
  RHOAI_MINOR=$(echo "$rhoai_version" | cut -d. -f2)
  log_ok "RHOAI operator found: ${rhoai_csv} (version ${rhoai_version})"

  if (( RHOAI_MAJOR < 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR < 4) )); then
    log_error "MaaS with LLMInferenceService requires RHOAI >= 3.4 (found ${rhoai_version})."
    exit 1
  fi

  if ! resource_exists dsc "$DSC_NAME" "$RHOAI_OPERATOR_NS"; then
    log_error "DataScienceCluster '${DSC_NAME}' not found in '${RHOAI_OPERATOR_NS}'."
    exit 1
  fi
  log_ok "DataScienceCluster '${DSC_NAME}' exists."

  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    log_error "Manifests directory not found: ${MANIFESTS_DIR}"
    exit 1
  fi
  log_ok "Manifests directory found."
}

install_cert_manager() {
  log_step "Step 2: Installing cert-manager operator"

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

install_rhcl_operator() {
  log_step "Step 3: Installing Red Hat Connectivity Link (RHCL) operator"

  local phase
  phase=$(oc get csv -n openshift-operators 2>/dev/null | awk '/rhcl/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "RHCL already installed and CSV is Succeeded — skipping."
    return 0
  fi
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
}

install_kuadrant() {
  if [[ "$SKIP_KUADRANT" == "true" ]]; then
    log_warn "--skip-kuadrant: skipping Kuadrant CR creation and Authorino TLS config."
    return 0
  fi

  log_step "Step 4: Configuring Kuadrant and Authorino"

  apply_manifest "${MANIFESTS_DIR}/01-kuadrant-namespace.yaml"
  apply_manifest "${MANIFESTS_DIR}/02-authorino-service-annotation.yaml"

  if resource_exists kuadrant kuadrant "$KUADRANT_NS"; then
    log_warn "Kuadrant CR already exists — skipping creation."
  else
    apply_manifest "${MANIFESTS_DIR}/03-kuadrant-cr.yaml"
  fi

  if ! wait_for_condition "kuadrant/kuadrant" "$KUADRANT_NS" "Ready" 120; then
    log_warn "Kuadrant not Ready after 120s — checking for MissingDependency (a known"
    log_warn "transient state fixed by restarting the operator pod once)…"
    local op_pod
    op_pod=$(oc get pods -n openshift-operators --no-headers 2>/dev/null \
      | awk '/kuadrant-operator/{print $1}' | head -1)
    if [[ -n "$op_pod" ]]; then
      log_info "Restarting kuadrant-operator pod '${op_pod}'…"
      oc delete pod -n openshift-operators "$op_pod" &>/dev/null || true
      wait_for_condition "kuadrant/kuadrant" "$KUADRANT_NS" "Ready" 180 \
        || { log_error "Kuadrant still not Ready after operator restart. Aborting."; exit 1; }
    else
      log_error "kuadrant-operator pod not found in openshift-operators. Aborting."
      exit 1
    fi
  fi
  log_ok "Kuadrant is Ready in '${KUADRANT_NS}'."

  log_step "Step 5: Configuring TLS between Gateway and Authorino"

  if oc get authorino authorino -n "$KUADRANT_NS" \
      -o jsonpath='{.spec.listener.tls.certSecretRef.name}' 2>/dev/null | grep -q "^authorino-server-cert$"; then
    log_warn "Authorino TLS already enabled with the service-ca cert — skipping."
    return 0
  fi

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

  oc patch authorino authorino -n "$KUADRANT_NS" --type=merge --patch '{
    "spec": {
      "listener": {
        "tls": {
          "enabled": true,
          "certSecretRef": {"name": "authorino-server-cert"}
        }
      }
    }
  }'
  # Follows the upstream rhoai-maas-guide's own choice of CA bundle file
  # (service-ca-bundle.crt, not service-ca.crt — both exist in the same mounted
  # openshift-service-ca ConfigMap).
  oc -n "$KUADRANT_NS" set env deployment/authorino \
    SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

  wait_for_condition "deployment/authorino" "$KUADRANT_NS" "Available" "$POD_WAIT_TIMEOUT" \
    || { log_error "Authorino deployment did not become Available. Aborting."; exit 1; }
  log_ok "Authorino is Available with TLS enabled."
}

enable_user_workload_monitoring() {
  log_step "Step 6: Enabling User Workload Monitoring"

  if resource_exists configmap cluster-monitoring-config "openshift-monitoring"; then
    log_warn "cluster-monitoring-config already exists — skipping (won't overwrite in case"
    log_warn "it already carries settings from another team)."
    return 0
  fi

  apply_manifest "${MANIFESTS_DIR}/04-uwm-configmap.yaml"

  wait_for_condition "deployment/prometheus-operator" "openshift-user-workload-monitoring" \
    "Available" "$POD_WAIT_TIMEOUT" \
    || log_warn "prometheus-operator not confirmed Available — continuing (monitoring is not on the critical path to a working Gateway)."
  log_ok "User Workload Monitoring enabled."
}

install_metallb() {
  log_step "Step 7: Installing MetalLB (non-cloud platforms only)"

  local platform_class
  platform_class=$(detect_platform_class)
  if [[ "$platform_class" == "cloud" ]]; then
    log_ok "Cloud platform detected ($(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null)) — MetalLB not needed, skipping."
    return 0
  fi

  if [[ "$SKIP_METALLB" == "true" ]]; then
    log_warn "--skip-metallb: skipping MetalLB install. The Gateway's LoadBalancer Service"
    log_warn "will stay <pending> unless an equivalent LoadBalancer provider already exists."
    return 0
  fi

  local phase
  phase=$(oc get csv -n "$METALLB_NS" 2>/dev/null | awk '/metallb-operator/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "MetalLB operator already installed and CSV is Succeeded — skipping install."
  else
    [[ -n "$phase" ]] && log_warn "MetalLB operator CSV found but phase is '${phase}' — reinstalling."
    apply_manifest "${MANIFESTS_DIR}/09-metallb-namespace.yaml"
    approve_installplan_for_sub "$METALLB_NS" "metallb-operator"
    wait_for_csv "$METALLB_NS" "metallb-operator" "$OPERATOR_WAIT_TIMEOUT" \
      || { log_error "MetalLB operator CSV failed. Aborting."; exit 1; }
    log_ok "MetalLB operator CSV is Succeeded."
  fi

  if resource_exists deployment controller "$METALLB_NS"; then
    log_warn "MetalLB controller already deployed — skipping MetalLB CR creation."
  else
    apply_manifest "${MANIFESTS_DIR}/10-metallb-instance.yaml"
    wait_for_condition "deployment/controller" "$METALLB_NS" "Available" "$POD_WAIT_TIMEOUT" \
      || { log_error "MetalLB controller deployment did not become Available. Aborting."; exit 1; }
    log_ok "MetalLB controller is Available."
  fi

  if resource_exists ipaddresspool maas-gateway-pool "$METALLB_NS"; then
    log_warn "IPAddressPool 'maas-gateway-pool' already exists — skipping."
    return 0
  fi

  if [[ -z "$METALLB_IP_RANGE" ]]; then
    # Formula matches the rh-aiservices-bu rhoai-maas-guide exactly (01-prerequisites.html,
    # "MetalLB Operator (Non-Cloud Clusters)"): first node's own InternalIP + 1 on the last
    # octet, used as a single-address pool. Works identically for a single-node cluster
    # (CRC, SNO) and a real multi-node bare-metal cluster — no topology-specific logic.
    # The guide's own warning applies: never reuse the node's own IP, and on a more complex
    # network, pass --metallb-ip-range / METALLB_IP_RANGE explicitly instead of trusting this.
    local node_ip
    node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -z "$node_ip" ]]; then
      log_error "Could not determine a node InternalIP to derive a MetalLB address pool from."
      log_error "Pass --metallb-ip-range <range> explicitly."
      exit 1
    fi
    local derived_ip
    derived_ip=$(echo "$node_ip" | awk -F. '{printf "%s.%s.%s.%d", $1, $2, $3, $4+1}')
    METALLB_IP_RANGE="${derived_ip}-${derived_ip}"
    log_warn "No --metallb-ip-range given — auto-derived '${METALLB_IP_RANGE}' from node IP"
    log_warn "'${node_ip}' + 1. This is a single address one octet above the node's own IP;"
    log_warn "confirm it's actually unused on your network before trusting this on anything"
    log_warn "but a simple single-node/CRC setup. Override with --metallb-ip-range if not."
  else
    log_info "Using explicit MetalLB address range: ${METALLB_IP_RANGE}"
  fi

  sed "s|METALLB_IP_RANGE_PLACEHOLDER|${METALLB_IP_RANGE}|g" \
    "${MANIFESTS_DIR}/11-metallb-pool.yaml.tmpl" | oc apply -f -
  log_ok "MetalLB IPAddressPool + L2Advertisement created (${METALLB_IP_RANGE})."

  log_info "Verifying MetalLB actually satisfies a LoadBalancer Service request…"
  oc create deployment metallb-selftest --image=registry.access.redhat.com/ubi9/ubi-minimal \
    --dry-run=client -o yaml -n default | oc apply -f - &>/dev/null
  oc expose deployment metallb-selftest --port=80 --type=LoadBalancer -n default &>/dev/null
  local test_deadline=$(( $(date +%s) + 60 ))
  local lb_ip=""
  until [[ -n "$lb_ip" ]]; do
    lb_ip=$(oc get svc metallb-selftest -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if (( $(date +%s) > test_deadline )); then
      log_warn "MetalLB self-test Service never got an address within 60s — MetalLB may not"
      log_warn "be fully functional yet. Continuing; Step 9's Gateway wait will surface this"
      log_warn "for real if it's still a problem."
      break
    fi
    sleep 5
  done
  [[ -n "$lb_ip" ]] && log_ok "MetalLB self-test succeeded — got address ${lb_ip}."
  oc delete deployment,service metallb-selftest -n default &>/dev/null || true
}

install_gatewayclass() {
  log_step "Step 8: Installing the openshift-default GatewayClass"

  if resource_exists gatewayclass openshift-default; then
    log_warn "GatewayClass 'openshift-default' already exists — skipping."
  else
    apply_manifest "${MANIFESTS_DIR}/05-gatewayclass.yaml"
  fi

  # GatewayClass is cluster-scoped; wait_for_condition's -n flag is harmless/ignored for it.
  wait_for_condition "gatewayclass/openshift-default" "$GATEWAY_NS" "Accepted" 120 \
    || { log_error "GatewayClass 'openshift-default' not Accepted. Aborting."; exit 1; }
  log_ok "GatewayClass 'openshift-default' is Accepted."
}

# Prints IsCloudPlatform-relevant info and echoes "cloud" or "non-cloud" on stdout.
detect_platform_class() {
  local platform
  platform=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null)
  case "$platform" in
    AWS|Azure|GCP|IBMCloud) echo "cloud" ;;
    *) echo "non-cloud" ;;
  esac
}

configure_maas_gateway() {
  log_step "Step 9: Creating the MaaS Gateway"

  local platform_class
  platform_class=$(detect_platform_class)
  log_info "Cluster platform class: ${platform_class} ($(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null))"

  if [[ "$platform_class" == "non-cloud" ]]; then
    if ! resource_exists deployment metallb-operator-controller-manager "metallb-system"; then
      log_warn "MetalLB not detected in 'metallb-system'. On non-cloud platforms, the"
      log_warn "openshift-default GatewayClass still creates a type: LoadBalancer Service"
      log_warn "for the Gateway — without a working LoadBalancer provider (MetalLB or"
      log_warn "equivalent) that Service stays <pending> and Gateway never reaches"
      log_warn "Programmed=True. This is a known upstream issue, not a bug in this script:"
      log_warn "https://github.com/opendatahub-io/models-as-a-service/issues/331"
      log_warn "If this cluster has no LoadBalancer provider at all (e.g. CRC), the wait"
      log_warn "below will very likely time out — re-run without --skip-metallb, or install"
      log_warn "a working LoadBalancer provider manually before continuing."
    fi
  fi

  resource_exists configmap maas-gateway-options "$GATEWAY_NS" \
    || apply_manifest "${MANIFESTS_DIR}/06-gateway-resources-configmap.yaml"

  if resource_exists gateway maas-default-gateway "$GATEWAY_NS"; then
    log_warn "Gateway 'maas-default-gateway' already exists — skipping creation."
  else
    local cluster_domain cert_name
    cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    cert_name=$(oc get ingresscontroller default -n openshift-ingress-operator \
      -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
    cert_name="${cert_name:-router-certs-default}"
    log_info "CLUSTER_DOMAIN=${cluster_domain}  CERT_NAME=${cert_name}"

    sed -e "s|CLUSTER_DOMAIN_PLACEHOLDER|${cluster_domain}|g" \
        -e "s|CERT_NAME_PLACEHOLDER|${cert_name}|g" \
      "${MANIFESTS_DIR}/07-gateway.yaml.tmpl" | oc apply -f -
  fi

  log_info "Waiting for Gateway 'maas-default-gateway' to be Programmed (timeout: ${GATEWAY_WAIT_TIMEOUT}s)…"
  local deadline=$(( $(date +%s) + GATEWAY_WAIT_TIMEOUT ))
  until [[ "$(oc get gateway maas-default-gateway -n "$GATEWAY_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]]; do
    if (( $(date +%s) > deadline )); then
      log_error "Gateway 'maas-default-gateway' not Programmed after ${GATEWAY_WAIT_TIMEOUT}s."
      if [[ "$platform_class" == "non-cloud" ]]; then
        log_error "Check the backing Service for a stuck <pending> LoadBalancer address:"
        log_error "  oc get svc -n ${GATEWAY_NS} -l gateway.networking.k8s.io/gateway-name=maas-default-gateway"
        log_error "See the MetalLB warning above — this is the most common cause here."
      fi
      oc describe gateway maas-default-gateway -n "$GATEWAY_NS" 2>/dev/null | tail -15
      exit 1
    fi
    sleep 5
  done
  log_ok "Gateway 'maas-default-gateway' is Programmed."
}

label_gateway_namespaces() {
  log_step "Step 10: Labeling namespaces for Gateway route binding"
  # maas-controller creates an internal maas-api-route HTTPRoute in RHOAI_APP_NS for the
  # dashboard's API Keys page — without this label it never attaches and the dashboard's
  # MaaS panel fails with "Error loading components".
  oc label namespace "$RHOAI_APP_NS" maas.opendatahub.io/gateway-access="true" --overwrite &>/dev/null
  log_ok "Namespace '${RHOAI_APP_NS}' labeled maas.opendatahub.io/gateway-access=true."

  # Guarded on length, not a bare "${arr[@]}" expansion: on bash < 4.4, expanding an
  # empty array under `set -u` throws "unbound variable" even though it was declared
  # (EXTRA_GATEWAY_NAMESPACES=()) — fixed upstream in bash 4.4, but confirmed to still
  # bite on older bash (e.g. RHEL 7/8 bastion hosts, macOS's stock /bin/bash 3.2).
  if (( ${#EXTRA_GATEWAY_NAMESPACES[@]} > 0 )); then
    for ns in "${EXTRA_GATEWAY_NAMESPACES[@]}"; do
      oc label namespace "$ns" maas.opendatahub.io/gateway-access="true" --overwrite &>/dev/null
      log_ok "Namespace '${ns}' labeled maas.opendatahub.io/gateway-access=true."
    done
  fi
}

create_passthrough_route() {
  local platform_class
  platform_class=$(detect_platform_class)
  if [[ "$platform_class" != "non-cloud" ]]; then
    log_step "Step 11: Passthrough Route (skipped — cloud platform, Gateway has a direct LoadBalancer address)"
    return 0
  fi

  log_step "Step 11: Creating passthrough Route (non-cloud platform)"

  if resource_exists route maas-default-gateway-https "$GATEWAY_NS"; then
    log_warn "Route 'maas-default-gateway-https' already exists — skipping."
  else
    local cluster_domain
    cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    sed "s|CLUSTER_DOMAIN_PLACEHOLDER|${cluster_domain}|g" \
      "${MANIFESTS_DIR}/08-route.yaml.tmpl" | oc apply -f -
  fi

  # oc wait --for=condition= does not work on Route objects (the Admitted condition is
  # nested under status.ingress[].conditions[], not the top-level status.conditions[] that
  # oc wait checks) — poll the jsonpath directly instead.
  log_info "Waiting for Route 'maas-default-gateway-https' to be admitted…"
  local deadline=$(( $(date +%s) + 60 ))
  until [[ "$(oc get route maas-default-gateway-https -n "$GATEWAY_NS" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null)" == "True" ]]; do
    if (( $(date +%s) > deadline )); then
      log_error "Route 'maas-default-gateway-https' not admitted after 60s."
      oc describe route maas-default-gateway-https -n "$GATEWAY_NS" 2>/dev/null | tail -15
      exit 1
    fi
    sleep 5
  done
  log_ok "Route 'maas-default-gateway-https' admitted."
}

deploy_postgresql() {
  log_step "Step 12: Deploying PostgreSQL for MaaS API"

  if resource_exists statefulset maas-postgresql "maas-db"; then
    log_warn "StatefulSet 'maas-postgresql' already exists — skipping PostgreSQL deployment."
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

# Works around a maas-api/maas-controller version-skew bug — RHOAI 3.4.x only (see
# 06h-maas-api-rbac-workaround.yaml; hardcodes maas-api's ServiceAccount as living in
# RHOAI_APP_NS, which is only true pre-3.5). No-ops if the models-as-a-service namespace
# doesn't exist yet, or on 3.5+ where maas-api lives in AI_GATEWAY_INFRA_NS instead.
apply_maas_api_rbac_workaround() {
  (( RHOAI_MAJOR > 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR >= 5) )) && return 0
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
  log_step "Step 13: Enabling MaaS (modelsAsService) in the DataScienceCluster"
  # RHOAI 3.4.x only — see enable_maas_in_dsc_aigateway() for the 3.5+ path. Field is
  # deprecated starting 3.5 (preserved for backward compatibility through 3.6 per the DSC
  # CRD schema), and its CEL rule is one-directional: Managed→Removed is allowed,
  # Removed→Managed is BLOCKED — so this function only ever applies on a genuinely 3.4.x
  # cluster (gated by main()'s version dispatch), never as a "fix" on 3.5+.

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

    if [[ "$maas_api_rbac_patch_applied" == "false" ]] && resource_exists namespace models-as-a-service; then
      apply_maas_api_rbac_workaround
      maas_api_rbac_patch_applied=true
    fi

    # Detect Dashboard rolling-update deadlock: happens on resource-constrained nodes where
    # maxUnavailable=0 prevents terminating an old pod to free CPU for the new one.
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
  log_step "Step 13: Enabling MaaS (aigateway.modelsAsAService) in the DataScienceCluster"
  # RHOAI 3.5+ only. Confirmed live: MaaS moved from spec.components.kserve.modelsAsService
  # to spec.components.aigateway.modelsAsAService (double-A, not a typo), gated by the
  # PARENT aigateway.managementState, which defaults to Removed if unset. Setting only the
  # modelsAsAService submodule without the parent silently no-ops — both must be set.

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
  log_step "Step 14: Enabling GenAI Studio in OdhDashboardConfig"

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
  log_step "Step 15: Enabling LlamaStack operator in the DataScienceCluster (required for GenAI Playground)"
  # RHOAI 3.4.x only — LlamaStack is replaced by OGX starting 3.5EA1 (see
  # enable_ogx_operator() below).

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
    || log_warn "LlamaStackOperatorReady condition not confirmed — continuing (a model deploy will surface real failures)."
  log_ok "llamastackoperator enabled in DataScienceCluster."
}

enable_ogx_operator() {
  log_step "Step 15: Enabling OGX component in the DataScienceCluster (required for GenAI Playground, RHOAI 3.5+)"
  # RHOAI 3.5EA1+ only — OGX ("Open GenAI Stack") replaces the LlamaStack operator.

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

  # The OGX component CR (kind OGX) is cluster-scoped — poll inline rather than assume a
  # namespaced resource.
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
  # $1: "true" on RHOAI 3.5+, "false"/unset on 3.4.x.
  local is_35_plus="${1:-false}"
  log_step "Step 16: Verifying all MaaS platform components"

  wait_for_pods "$RHOAI_APP_NS" "app.kubernetes.io/name=model-serving-api" "$POD_WAIT_TIMEOUT"
  wait_for_pods "$RHOAI_APP_NS" "control-plane=llmisvc-controller-manager" "$POD_WAIT_TIMEOUT"

  if [[ "$is_35_plus" == "true" ]]; then
    wait_for_pods "$AI_GATEWAY_INFRA_NS" "app.kubernetes.io/name=maas-api" "$POD_WAIT_TIMEOUT" \
      || { log_error "maas-api pod not Running in '${AI_GATEWAY_INFRA_NS}'. Check PostgreSQL/DB connectivity."; exit 1; }
    oc rollout status deployment/maas-api -n "$AI_GATEWAY_INFRA_NS" --timeout="${POD_WAIT_TIMEOUT}s" \
      || { log_error "maas-api not available in '${AI_GATEWAY_INFRA_NS}'. Check its logs."; exit 1; }
  else
    apply_maas_api_rbac_workaround
    wait_for_pods "$RHOAI_APP_NS" "app.kubernetes.io/name=maas-api" "$POD_WAIT_TIMEOUT" \
      || { log_error "maas-api pod not Running. Check PostgreSQL connectivity."; exit 1; }
    if ! oc rollout status deployment/maas-api -n "$RHOAI_APP_NS" --timeout="${POD_WAIT_TIMEOUT}s"; then
      log_warn "maas-api not yet available — restarting once to pick up the RBAC workaround…"
      oc rollout restart deployment/maas-api -n "$RHOAI_APP_NS"
      oc rollout status deployment/maas-api -n "$RHOAI_APP_NS" --timeout="${POD_WAIT_TIMEOUT}s" \
        || { log_error "maas-api still not available after restart. Check its logs for a forbidden/RBAC error."; exit 1; }
    fi
  fi

  wait_for_pods "$RHOAI_APP_NS" "control-plane=maas-controller" "$POD_WAIT_TIMEOUT"

  # GatewayConfig is cluster-scoped (confirmed live) and auto-provisioned by RHOAI's own
  # AIGateway component independent of which Gateway script is used — same check either way.
  wait_for_condition "gatewayconfig/default-gateway" "$RHOAI_APP_NS" \
    "GatewayConfigReady" "$POD_WAIT_TIMEOUT"

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
}

create_model_namespace() {
  log_step "Step 17: Creating MaaS model namespace '${MAAS_MODEL_NS}'"

  if resource_exists namespace "$MAAS_MODEL_NS"; then
    log_warn "Namespace '${MAAS_MODEL_NS}' already exists — skipping."
  else
    apply_manifest "${MANIFESTS_DIR}/07-model-namespace.yaml"
    log_ok "Namespace '${MAAS_MODEL_NS}' created."
  fi

  # This script's own Gateway (manifests/07-gateway.yaml.tmpl) selects on
  # maas.opendatahub.io/gateway-access — confirmed from the template directly; using the
  # wrong key here would silently break route binding.
  oc label namespace "$MAAS_MODEL_NS" maas.opendatahub.io/gateway-access="true" --overwrite &>/dev/null
  log_ok "Namespace '${MAAS_MODEL_NS}' labeled maas.opendatahub.io/gateway-access=true."

  log_info "To deploy models, create LLMInferenceService resources in '${MAAS_MODEL_NS}'."
  log_info "See: ${MANIFESTS_DIR}/08-example-llminferenceservice.yaml"
}

print_summary() {
  log_step "Setup complete — Summary"

  local cluster_domain
  cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
  local platform_class
  platform_class=$(detect_platform_class)

  local rhoai_is_35_plus=false
  (( RHOAI_MAJOR > 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR >= 5) )) && rhoai_is_35_plus=true

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║   MaaS Gateway Setup — rhoai-maas-guide approach (complete)   ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  ${BOLD}Component${NC}                          ${BOLD}Status${NC}"
  echo -e "  ─────────────────────────────────────────────────────"
  echo -e "  cert-manager operator              $(oc get csv -n "$CERT_MANAGER_NS" 2>/dev/null | awk '/cert-manager/{print $NF}' | head -1 || echo 'N/A')"
  echo -e "  RHCL operator                      $(oc get csv -n openshift-operators 2>/dev/null | awk '/rhcl/{print $NF}' | head -1 || echo 'N/A')"
  echo -e "  Kuadrant (${KUADRANT_NS})           $(oc get kuadrant kuadrant -n "$KUADRANT_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo 'N/A')"
  echo -e "  Authorino TLS                      $(oc get authorino authorino -n "$KUADRANT_NS" -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo 'N/A')"
  echo -e "  GatewayClass openshift-default      $(oc get gatewayclass openshift-default -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo 'N/A')"
  echo -e "  Gateway Programmed                  $(oc get gateway maas-default-gateway -n "$GATEWAY_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo 'N/A')"
  echo -e "  Platform class                       ${platform_class}"
  if [[ "$platform_class" == "non-cloud" ]]; then
    echo -e "  MetalLB operator                   $(oc get csv -n "$METALLB_NS" 2>/dev/null | awk '/metallb-operator/{print $NF}' | head -1 || echo 'N/A')"
    echo -e "  MetalLB IPAddressPool               $(oc get ipaddresspool maas-gateway-pool -n "$METALLB_NS" -o jsonpath='{.spec.addresses[0]}' 2>/dev/null || echo 'N/A')"
  fi
  if [[ "$platform_class" == "non-cloud" ]]; then
    echo -e "  Passthrough Route admitted           $(oc get route maas-default-gateway-https -n "$GATEWAY_NS" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || echo 'N/A')"
  fi
  echo -e "  PostgreSQL (maas-db)               $(oc get pods -n maas-db -l app=maas-postgresql --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo 0) pod(s) Running"

  if [[ "$rhoai_is_35_plus" == "true" ]]; then
    local maas_api_ready
    maas_api_ready=$(oc get pods -n "$AI_GATEWAY_INFRA_NS" -l "app.kubernetes.io/name=maas-api" \
      --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo 0)
    echo -e "  maas-api (${AI_GATEWAY_INFRA_NS})  ${maas_api_ready} pod(s) Running"
    echo -e "  ModelsAsAServiceReady               $(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null || echo 'N/A')"
    echo -e "  ogx (Playground backend, 3.5+)      $(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null || echo 'N/A')"
  else
    local maas_api_ready
    maas_api_ready=$(oc get pods -n "$RHOAI_APP_NS" -l "app.kubernetes.io/name=maas-api" \
      --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo 0)
    echo -e "  maas-api                           ${maas_api_ready} pod(s) Running"
    echo -e "  ModelsAsServiceReady               $(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}' 2>/dev/null || echo 'N/A')"
    echo -e "  llamastackoperator                 $(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" -o jsonpath='{.spec.components.llamastackoperator.managementState}' 2>/dev/null || echo 'N/A')"
  fi

  local genai_studio
  genai_studio=$(oc get OdhDashboardConfig odh-dashboard-config -n "$RHOAI_APP_NS" \
    -o jsonpath='{.spec.dashboardConfig.genAiStudio}' 2>/dev/null || echo "N/A")
  echo -e "  GenAI Studio (OdhDashboardConfig)  ${genai_studio}"
  echo -e "  Model namespace                    ${MAAS_MODEL_NS}"
  echo
  local gpu_profile
  gpu_profile=$(detect_gpu_hardware_profile "$RHOAI_APP_NS")
  if [[ -n "$gpu_profile" ]]; then
    echo -e "  GPU HardwareProfile detected: ${BOLD}${gpu_profile}${NC} (deploy-example-workload.sh will use it automatically)"
    echo
  else
    echo -e "  ${YELLOW}[WARN]${NC}  No GPU HardwareProfile found in '${RHOAI_APP_NS}'."
    echo -e "  Create one in the RHOAI dashboard, or pass one explicitly to deploy-example-workload.sh"
    echo -e "  with --hardware-profile-name <name> when you deploy the example model."
    echo
  fi
  echo -e "  ${BOLD}Verify TLS reachability:${NC}"
  echo -e "    curl -vsk https://maas.${cluster_domain} 2>&1 | grep -E \"SSL connection|Connected\""
  echo
  echo -e "  ${BOLD}Next steps:${NC}"
  echo -e "  1. Deploy the example model and MaaS governance:"
  echo -e "     ./deploy-example-workload.sh"
  echo
  echo -e "  2. Users mint a MaaS API key, then call the model through it:"
  echo -e "     TOKEN=\$(oc whoami -t)"
  echo -e "     API_KEY=\$(curl -sk -X POST https://maas.${cluster_domain}/maas-api/v1/api-keys \\"
  echo -e "       -H \"Authorization: Bearer \$TOKEN\" -H \"Content-Type: application/json\" \\"
  echo -e "       -d '{\"name\":\"my-key\",\"subscription\":\"llama-3-8b-free\",\"expiresIn\":\"1h\"}' | jq -r .key)"
  echo -e "     curl -sk -H \"Authorization: Bearer \$API_KEY\" -H \"Content-Type: application/json\" \\"
  echo -e "       https://maas.${cluster_domain}/${MAAS_MODEL_NS}/llama-3-8b/v1/chat/completions \\"
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
  echo -e "${BOLD}${CYAN}║   MaaS Gateway Setup — rhoai-maas-guide approach (complete)   ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites

  local rhoai_is_35_plus=false
  (( RHOAI_MAJOR > 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR >= 5) )) && rhoai_is_35_plus=true

  if [[ "$SKIP_OPERATORS" == "true" || "$SKIP_CERT_MANAGER" == "true" ]]; then
    log_warn "--skip-cert-manager: skipping cert-manager installation."
  else
    install_cert_manager
  fi

  if [[ "$SKIP_OPERATORS" == "true" || "$SKIP_RHCL" == "true" ]]; then
    log_warn "--skip-rhcl: skipping RHCL operator installation."
  else
    install_rhcl_operator
  fi

  install_kuadrant
  enable_user_workload_monitoring
  install_metallb
  install_gatewayclass
  configure_maas_gateway
  label_gateway_namespaces
  create_passthrough_route
  deploy_postgresql

  if [[ "$rhoai_is_35_plus" == "true" ]]; then
    enable_maas_in_dsc_aigateway
  else
    enable_maas_in_dsc
  fi

  enable_genai_studio

  if [[ "$rhoai_is_35_plus" == "true" ]]; then
    enable_ogx_operator
  else
    enable_llamastack_operator
  fi

  verify_maas_components "$rhoai_is_35_plus"
  create_model_namespace

  print_summary
}

main "$@"
