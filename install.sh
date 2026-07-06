#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="gateway-api-envoy"
DEFAULT_NAMESPACE="envoy-gateway-system"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_WAIT_TIMEOUT="10m"
DEFAULT_GATEWAY_CLASS="eg"
DEFAULT_GATEWAY_NAME="edge-gateway"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

NAMESPACE="${DEFAULT_NAMESPACE}"
REGISTRY="${DEFAULT_REGISTRY}"
REGISTRY_USER=""
REGISTRY_PASS=""
GATEWAY_IMAGE=""
ENVOY_PROXY_IMAGE=""
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
YES=0
DRY_RUN=0
SKIP_IMAGE_PREPARE=0
INSTALL_BOOTSTRAP=1
DELETE_NAMESPACE=0
GATEWAY_CLASS="${DEFAULT_GATEWAY_CLASS}"
GATEWAY_NAME="${DEFAULT_GATEWAY_NAME}"
GATEWAY_NAMESPACE="default"
CONTROLLER_REPLICAS="1"
HELM_BIN="${HELM:-helm}"
KUBECTL_BIN="${KUBECTL:-kubectl}"
DOCKER_BIN="${DOCKER:-docker}"
HELM_ARGS=()
KUBECTL_ARGS=()
EXTRA_SET_ARGS=()
WORKDIR=""

usage() {
  cat <<USAGE
Usage:
  ./gateway-api-envoy-<version>-<arch>.run install [options]
  ./gateway-api-envoy-<version>-<arch>.run status [options]
  ./gateway-api-envoy-<version>-<arch>.run uninstall [options]
  ./gateway-api-envoy-<version>-<arch>.run help

Actions:
  install      Load/push images, install Envoy Gateway, and optionally create GatewayClass/Gateway.
  status       Show Envoy Gateway, Gateway API, and bootstrap resource status.
  uninstall    Remove bootstrap resources and uninstall Envoy Gateway Helm release.
  help         Show this help.

Options:
  -n, --namespace <ns>            Controller namespace. Default: ${DEFAULT_NAMESPACE}
  --registry <repo-prefix>        Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>          Target registry username.
  --registry-pass <pass>          Target registry password.
  --gateway-image <image>         Override Envoy Gateway controller image.
  --envoy-proxy-image <image>     Override managed Envoy Proxy data-plane image.
  --skip-image-prepare            Skip docker load/tag/push. Use when images already exist.
  --controller-replicas <n>       Envoy Gateway controller replicas. Default: ${CONTROLLER_REPLICAS}
  --gateway-class <name>          GatewayClass to create. Default: ${DEFAULT_GATEWAY_CLASS}
  --gateway-name <name>           Gateway to create. Default: ${DEFAULT_GATEWAY_NAME}
  --gateway-namespace <ns>        Gateway namespace. Default: default.
  --no-bootstrap                  Install controller only; do not create GatewayClass/Gateway.
  --set <key=value>               Extra Helm --set-string value, repeatable.
  --wait-timeout <duration>       Helm/kubectl wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --dry-run                       Render Helm chart and bootstrap YAML without applying.
  --delete-namespace              During uninstall, delete controller namespace.
  --kubeconfig <path>             Pass kubeconfig to kubectl and helm.
  --context <name>                Pass kube context to kubectl and helm.
  -y, --yes                       Do not ask for confirmation.
  -h, --help                      Show this help.

Notes:
  - This package installs a complete Envoy Gateway stack, not just Gateway API CRDs.
  - Envoy Gateway Helm chart installs Gateway API CRDs and Envoy Gateway CRDs by default.
  - The default bootstrap creates an HTTP Gateway listening on port 80 and allowing routes from all namespaces.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --gateway-image) GATEWAY_IMAGE="${2:-}"; shift 2 ;;
    --envoy-proxy-image) ENVOY_PROXY_IMAGE="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    --controller-replicas) CONTROLLER_REPLICAS="${2:-}"; shift 2 ;;
    --gateway-class) GATEWAY_CLASS="${2:-}"; shift 2 ;;
    --gateway-name) GATEWAY_NAME="${2:-}"; shift 2 ;;
    --gateway-namespace) GATEWAY_NAMESPACE="${2:-}"; shift 2 ;;
    --no-bootstrap) INSTALL_BOOTSTRAP=0; shift ;;
    --set) EXTRA_SET_ARGS+=(--set-string "${2:-}"); shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --delete-namespace) DELETE_NAMESPACE=1; shift ;;
    --kubeconfig) KUBECTL_ARGS+=(--kubeconfig "${2:-}"); HELM_ARGS+=(--kubeconfig "${2:-}"); shift 2 ;;
    --context) KUBECTL_ARGS+=(--context "${2:-}"); HELM_ARGS+=(--kube-context "${2:-}"); shift 2 ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi
[[ -n "${NAMESPACE}" ]] || die "namespace cannot be empty"
[[ -n "${REGISTRY}" ]] || die "registry cannot be empty"
[[ -n "${GATEWAY_CLASS}" ]] || die "gateway class cannot be empty"
[[ -n "${GATEWAY_NAME}" ]] || die "gateway name cannot be empty"
[[ -n "${GATEWAY_NAMESPACE}" ]] || die "gateway namespace cannot be empty"

k() { "${KUBECTL_BIN}" "${KUBECTL_ARGS[@]}" "$@"; }
h() { "${HELM_BIN}" "${HELM_ARGS[@]}" "$@"; }
d() { "${DOCKER_BIN}" "$@"; }

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
  [[ -f "${WORKDIR}/charts/gateway-helm.tgz" ]] || die "payload missing charts/gateway-helm.tgz"
  [[ -f "${WORKDIR}/images/image-index.tsv" ]] || die "payload missing images/image-index.tsv"
}

package_meta_value() {
  local key="$1"
  [[ -f "${WORKDIR}/meta/package.env" ]] || return 0
  awk -F= -v k="${key}" '$1 == k { print substr($0, length(k) + 2); exit }' "${WORKDIR}/meta/package.env"
}

resolve_images() {
  if [[ -z "${GATEWAY_IMAGE}" ]]; then
    GATEWAY_IMAGE="${REGISTRY%/}/envoyproxy/gateway:$(package_meta_value ENVOY_GATEWAY_VERSION)"
  fi
  if [[ -z "${ENVOY_PROXY_IMAGE}" ]]; then
    ENVOY_PROXY_IMAGE="${REGISTRY%/}/envoyproxy/$(basename "$(package_meta_value DEFAULT_ENVOY_PROXY_IMAGE)")"
  fi
  [[ -n "${GATEWAY_IMAGE}" ]] || die "failed to resolve gateway image"
  [[ -n "${ENVOY_PROXY_IMAGE}" ]] || die "failed to resolve envoy proxy image"
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} Envoy Gateway in namespace '${NAMESPACE}'."
  [[ "${INSTALL_BOOTSTRAP}" == "1" ]] && echo "Bootstrap GatewayClass/Gateway: ${GATEWAY_CLASS}/${GATEWAY_NAMESPACE}/${GATEWAY_NAME}"
  if [[ "${ACTION}" == "uninstall" && "${DELETE_NAMESPACE}" == "1" ]]; then
    echo "WARNING: namespace ${NAMESPACE} will also be deleted."
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

retarget_ref() {
  local ref="$1" default_registry suffix
  default_registry="$(package_meta_value DEFAULT_REGISTRY)"
  default_registry="${default_registry:-${DEFAULT_REGISTRY}}"
  if [[ "${ref}" == "${default_registry}/"* ]]; then
    suffix="${ref#${default_registry}/}"
  else
    suffix="${ref#*/}"
  fi
  printf '%s/%s\n' "${REGISTRY%/}" "${suffix}"
}

prepare_images() {
  if [[ "${SKIP_IMAGE_PREPARE}" == "1" ]]; then
    info "skip image preparation; expecting controller=${GATEWAY_IMAGE}, data-plane=${ENVOY_PROXY_IMAGE}"
    return 0
  fi
  need "${DOCKER_BIN}"
  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "--registry-user and --registry-pass must be set together"
    info "docker login ${REGISTRY}"
    printf '%s' "${REGISTRY_PASS}" | d login "${REGISTRY}" -u "${REGISTRY_USER}" --password-stdin
  fi

  local line name tar_name load_ref default_target_ref platform pull dockerfile target_ref
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == name\|tar_name\|* ]] && continue
    IFS='|' read -r name tar_name load_ref default_target_ref platform pull dockerfile <<< "${line}"
    [[ -n "${tar_name}" ]] || continue
    [[ -f "${WORKDIR}/images/${tar_name}" ]] || die "missing image tar: images/${tar_name}"
    target_ref="$(retarget_ref "${default_target_ref}")"
    info "docker load ${tar_name}"
    d load -i "${WORKDIR}/images/${tar_name}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      info "docker tag ${load_ref} ${target_ref}"
      d tag "${load_ref}" "${target_ref}"
    fi
    info "docker push ${target_ref}"
    d push "${target_ref}"
  done < "${WORKDIR}/images/image-index.tsv"
}

helm_install_gateway() {
  local chart="${WORKDIR}/charts/gateway-helm.tgz"
  local -a args
  args=(
    --set-string "global.images.envoyGateway.image=${GATEWAY_IMAGE}"
    --set-string "global.images.envoyProxy.image=${ENVOY_PROXY_IMAGE}"
    --set-string "deployment.replicas=${CONTROLLER_REPLICAS}"
    --set crds.enabled=true
  )
  if [[ "${DRY_RUN}" == "1" ]]; then
    info "helm template eg ${chart}"
    h template eg "${chart}" -n "${NAMESPACE}" "${args[@]}" "${EXTRA_SET_ARGS[@]}" >/dev/null
    return 0
  fi
  info "helm upgrade --install eg ${chart}"
  h upgrade --install eg "${chart}" \
    -n "${NAMESPACE}" \
    --create-namespace \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    "${args[@]}" \
    "${EXTRA_SET_ARGS[@]}"
}

render_bootstrap() {
  cat <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${GATEWAY_CLASS}
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${GATEWAY_NAMESPACE}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
YAML
}

apply_bootstrap() {
  [[ "${INSTALL_BOOTSTRAP}" == "1" ]] || return 0
  if [[ "${DRY_RUN}" == "1" ]]; then
    info "render bootstrap GatewayClass/Gateway"
    render_bootstrap >/dev/null
    return 0
  fi
  info "apply default GatewayClass/Gateway bootstrap"
  render_bootstrap | k apply -f -
}

install_app() {
  need "${KUBECTL_BIN}"
  need "${HELM_BIN}"
  extract_payload
  resolve_images
  info "package ${PACKAGE_NAME} version=$(package_meta_value ENVOY_GATEWAY_VERSION) namespace=${NAMESPACE}"
  info "controller image=${GATEWAY_IMAGE}"
  info "data-plane image=${ENVOY_PROXY_IMAGE}"
  confirm
  prepare_images
  helm_install_gateway
  apply_bootstrap
  if [[ "${DRY_RUN}" == "1" ]]; then
    info "dry-run completed; no resources were changed"
    return 0
  fi
  k wait --timeout="${WAIT_TIMEOUT}" -n "${NAMESPACE}" deployment/envoy-gateway --for=condition=Available || true
  status_app
}

status_app() {
  need "${KUBECTL_BIN}"
  need "${HELM_BIN}"
  echo "Envoy Gateway Helm release:"
  h list -n "${NAMESPACE}" 2>/dev/null || true
  echo
  echo "Envoy Gateway controller pods:"
  k get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "Gateway API classes and gateways:"
  k get gatewayclass 2>/dev/null || true
  k get gateways.gateway.networking.k8s.io -A 2>/dev/null || true
  echo
  echo "HTTPRoutes:"
  k get httproutes.gateway.networking.k8s.io -A 2>/dev/null || true
  echo
  echo "Envoy Gateway extension resources:"
  k get envoyproxies.gateway.envoyproxy.io -A 2>/dev/null || true
}

uninstall_app() {
  need "${KUBECTL_BIN}"
  need "${HELM_BIN}"
  confirm
  if [[ "${INSTALL_BOOTSTRAP}" == "1" ]]; then
    info "delete bootstrap Gateway/GatewayClass"
    k delete gateway "${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" --ignore-not-found=true || true
    k delete gatewayclass "${GATEWAY_CLASS}" --ignore-not-found=true || true
  fi
  if h status eg -n "${NAMESPACE}" >/dev/null 2>&1; then
    info "helm uninstall eg"
    h uninstall eg -n "${NAMESPACE}" --wait --timeout "${WAIT_TIMEOUT}" || true
  fi
  if [[ "${DELETE_NAMESPACE}" == "1" ]]; then
    info "delete namespace ${NAMESPACE}"
    k delete namespace "${NAMESPACE}" --ignore-not-found=true
  else
    info "namespace ${NAMESPACE} kept"
  fi
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
