#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="gateway-api"
DEFAULT_CHANNEL="standard"
DEFAULT_WAIT_TIMEOUT="120s"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

CHANNEL="${DEFAULT_CHANNEL}"
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
SERVER_SIDE=1
FORCE_CONFLICTS=0
YES=0
DELETE_CRDS=0
WORKDIR=""

usage() {
  cat <<USAGE
Usage:
  ./gateway-api-<version>.run install [options]
  ./gateway-api-<version>.run status [options]
  ./gateway-api-<version>.run uninstall [options]
  ./gateway-api-<version>.run help

Actions:
  install      Install Gateway API CRDs.
  status       Show Gateway API CRD status.
  uninstall    Safe by default. Delete CRDs only when --delete-crds is set.
  help         Show this help.

Options:
  --channel <standard|experimental>  CRD channel to install. Default: standard.
  --wait-timeout <duration>          CRD Established wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --client-side                      Use normal kubectl apply instead of server-side apply.
  --force-conflicts                  Add --force-conflicts when using server-side apply.
  --delete-crds                      During uninstall, actually delete Gateway API CRDs.
  -y, --yes                          Do not ask for confirmation.
  -h, --help                         Show this help.

Notes:
  - This installer contains CRDs only. It does not install a Gateway API controller.
  - Use standard for GatewayClass, Gateway, HTTPRoute, GRPCRoute, and ReferenceGrant.
  - Use experimental only when your controller needs experimental resources such as TCPRoute, TLSRoute, UDPRoute, BackendTLSPolicy, or XListenerSet.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --client-side) SERVER_SIDE=0; shift ;;
    --force-conflicts) FORCE_CONFLICTS=1; shift ;;
    --delete-crds) DELETE_CRDS=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi
case "${CHANNEL}" in standard|experimental) ;; *) die "--channel must be standard or experimental" ;; esac

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  WORKDIR="$(mktemp -d -t ${PACKAGE_NAME}.XXXXXX)"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${WORKDIR}/manifests/standard-install.yaml" ]] || die "payload missing standard-install.yaml"
  [[ -f "${WORKDIR}/manifests/experimental-install.yaml" ]] || die "payload missing experimental-install.yaml"
}

manifest_file() {
  case "${CHANNEL}" in
    standard) printf '%s\n' "${WORKDIR}/manifests/standard-install.yaml" ;;
    experimental) printf '%s\n' "${WORKDIR}/manifests/experimental-install.yaml" ;;
  esac
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} Gateway API CRDs using channel '${CHANNEL}'."
  if [[ "${ACTION}" == "uninstall" && "${DELETE_CRDS}" == "1" ]]; then
    echo "WARNING: deleting CRDs also deletes all corresponding Gateway API custom resources."
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

crds_in_manifest() {
  local manifest="$1"
  awk '
    /^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$/ { in_crd=1; next }
    in_crd && /^[[:space:]]{2}name:[[:space:]]/ { print $2; in_crd=0 }
  ' "${manifest}"
}

kubectl_apply_args() {
  if [[ "${SERVER_SIDE}" == "1" ]]; then
    printf '%s\n' "--server-side=true"
    if [[ "${FORCE_CONFLICTS}" == "1" ]]; then
      printf '%s\n' "--force-conflicts"
    fi
  fi
}

install_app() {
  need kubectl
  extract_payload
  confirm
  local manifest args
  manifest="$(manifest_file)"
  mapfile -t args < <(kubectl_apply_args)
  info "kubectl apply ${args[*]} -f ${manifest}"
  kubectl apply "${args[@]}" -f "${manifest}"
  info "waiting for Gateway API CRDs to be Established"
  while read -r crd; do
    [[ -n "${crd}" ]] || continue
    kubectl wait --for condition=Established "crd/${crd}" --timeout="${WAIT_TIMEOUT}"
  done < <(crds_in_manifest "${manifest}")
  status_app
}

status_app() {
  need kubectl
  echo "Gateway API CRDs:"
  kubectl get crd | awk 'NR == 1 || $1 ~ /gateway\.networking(\.x-k8s)?\.io$/ { print }'
  echo
  echo "GatewayClasses:"
  kubectl get gatewayclass 2>/dev/null || true
  echo
  echo "Gateways across all namespaces:"
  kubectl get gateways.gateway.networking.k8s.io -A 2>/dev/null || true
  echo
  echo "HTTPRoutes across all namespaces:"
  kubectl get httproutes.gateway.networking.k8s.io -A 2>/dev/null || true
}

uninstall_app() {
  need kubectl
  extract_payload
  if [[ "${DELETE_CRDS}" != "1" ]]; then
    echo "Safe uninstall: Gateway API CRDs are kept."
    echo "To delete them, run: $0 uninstall --channel ${CHANNEL} --delete-crds -y"
    echo "WARNING: deleting CRDs also deletes all corresponding Gateway API custom resources."
    return 0
  fi
  confirm
  local manifest
  manifest="$(manifest_file)"
  info "kubectl delete -f ${manifest}"
  kubectl delete -f "${manifest}" --ignore-not-found=true
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
