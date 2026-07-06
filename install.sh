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
DRY_RUN=0
SKIP_IMAGE_PREPARE=0
REGISTRY=""
REGISTRY_USER=""
REGISTRY_PASS=""
KUBECTL_BIN="${KUBECTL:-kubectl}"
KUBECTL_ARGS=()
WORKDIR=""

usage() {
  cat <<USAGE
Usage:
  ./gateway-api-<version>-<arch>.run install [options]
  ./gateway-api-<version>-<arch>.run status [options]
  ./gateway-api-<version>-<arch>.run uninstall [options]
  ./gateway-api-<version>-<arch>.run help

Actions:
  install      Install or upgrade Gateway API CRDs.
  status       Show Gateway API CRD and resource status.
  uninstall    Safe by default. Delete CRDs only when --delete-crds is set.
  help         Show this help.

Options:
  --channel <standard|experimental>  CRD channel to install. Default: standard.
  --wait-timeout <duration>          CRD Established wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --client-side                      Use normal kubectl apply instead of server-side apply.
  --force-conflicts                  Add --force-conflicts when using server-side apply.
  --dry-run                          Run kubectl apply with --dry-run=server.
  --delete-crds                      During uninstall, actually delete Gateway API CRDs.
  --kubeconfig <path>                Pass an explicit kubeconfig to kubectl.
  --context <name>                   Pass an explicit kube context to kubectl.
  --registry <repo-prefix>           Accepted for offline-run compatibility; no-op for this CRD-only package.
  --registry-user <user>             Accepted for offline-run compatibility; no-op for this CRD-only package.
  --registry-pass <pass>             Accepted for offline-run compatibility; no-op for this CRD-only package.
  --skip-image-prepare               Accepted for offline-run compatibility; no-op for this CRD-only package.
  -y, --yes                          Do not ask for confirmation.
  -h, --help                         Show this help.

Notes:
  - This installer contains Gateway API CRDs only. It does not install a gateway controller or data-plane proxy.
  - Use standard for GatewayClass, Gateway, HTTPRoute, GRPCRoute, and ReferenceGrant.
  - Use experimental only when your selected controller explicitly needs experimental resources.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
warn() { echo "WARNING: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --client-side) SERVER_SIDE=0; shift ;;
    --force-conflicts) FORCE_CONFLICTS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --delete-crds) DELETE_CRDS=1; shift ;;
    --kubeconfig) KUBECTL_ARGS+=(--kubeconfig "${2:-}"); shift 2 ;;
    --context) KUBECTL_ARGS+=(--context "${2:-}"); shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi
case "${CHANNEL}" in standard|experimental) ;; *) die "--channel must be standard or experimental" ;; esac
if [[ "${SERVER_SIDE}" != "1" && "${FORCE_CONFLICTS}" == "1" ]]; then
  die "--force-conflicts requires server-side apply; remove --client-side"
fi

k() {
  "${KUBECTL_BIN}" "${KUBECTL_ARGS[@]}" "$@"
}

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
  [[ -f "${WORKDIR}/images/image-index.tsv" ]] || die "payload missing images/image-index.tsv"
}

package_meta_value() {
  local key="$1"
  [[ -f "${WORKDIR}/meta/package.env" ]] || return 0
  awk -F= -v k="${key}" '$1 == k { print substr($0, length(k) + 2); exit }' "${WORKDIR}/meta/package.env"
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
    in_crd && /^[[:space:]]*name:[[:space:]]/ {
      name=$2
      gsub(/\"/, "", name)
      print name
      in_crd=0
    }
  ' "${manifest}"
}

kubectl_apply_args() {
  if [[ "${SERVER_SIDE}" == "1" ]]; then
    printf '%s\n' "--server-side=true"
    if [[ "${FORCE_CONFLICTS}" == "1" ]]; then
      printf '%s\n' "--force-conflicts"
    fi
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '%s\n' "--dry-run=server"
  fi
}

prepare_images() {
  if [[ -n "${REGISTRY}" || -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" || "${SKIP_IMAGE_PREPARE}" == "1" ]]; then
    info "image preparation skipped: Gateway API package is CRD-only and contains no container images"
  fi
}

print_package() {
  local version arch platform
  version="$(package_meta_value VERSION)"
  arch="$(package_meta_value ARCH)"
  platform="$(package_meta_value PLATFORM)"
  info "package ${PACKAGE_NAME} version=${version:-unknown} arch=${arch:-unknown} platform=${platform:-unknown} channel=${CHANNEL}"
}

install_app() {
  need "${KUBECTL_BIN}"
  extract_payload
  print_package
  confirm
  prepare_images

  local manifest
  local -a args
  manifest="$(manifest_file)"
  mapfile -t args < <(kubectl_apply_args)

  info "kubectl ${KUBECTL_ARGS[*]:-} apply ${args[*]:-} -f ${manifest}"
  k apply "${args[@]}" -f "${manifest}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    info "dry-run completed; no resources were changed"
    return 0
  fi

  info "waiting for Gateway API CRDs to be Established"
  while read -r crd; do
    [[ -n "${crd}" ]] || continue
    k wait --for condition=Established "crd/${crd}" --timeout="${WAIT_TIMEOUT}"
  done < <(crds_in_manifest "${manifest}")

  status_app
}

status_app() {
  need "${KUBECTL_BIN}"
  echo "Gateway API CRDs:"
  k get crd 2>/dev/null | awk 'NR == 1 || $1 ~ /\.gateway\.networking\.k8s\.io$/ || $1 ~ /\.gateway\.networking\.x-k8s\.io$/ { print }' || true
  echo
  echo "Gateway API resources:"
  k api-resources --api-group=gateway.networking.k8s.io 2>/dev/null || true
  echo
  echo "GatewayClasses:"
  k get gatewayclass 2>/dev/null || true
  echo
  echo "Gateways across all namespaces:"
  k get gateways.gateway.networking.k8s.io -A 2>/dev/null || true
  echo
  echo "HTTPRoutes across all namespaces:"
  k get httproutes.gateway.networking.k8s.io -A 2>/dev/null || true
  echo
  echo "GRPCRoutes across all namespaces:"
  k get grpcroutes.gateway.networking.k8s.io -A 2>/dev/null || true
}

uninstall_app() {
  need "${KUBECTL_BIN}"
  if [[ "${DELETE_CRDS}" != "1" ]]; then
    echo "Safe uninstall: Gateway API CRDs are kept."
    echo "To delete them, run: $0 uninstall --channel ${CHANNEL} --delete-crds -y"
    echo "WARNING: deleting CRDs also deletes all corresponding Gateway API custom resources."
    return 0
  fi

  extract_payload
  print_package
  confirm

  local manifest
  manifest="$(manifest_file)"
  info "kubectl ${KUBECTL_ARGS[*]:-} delete -f ${manifest} --ignore-not-found=true"
  k delete -f "${manifest}" --ignore-not-found=true
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
