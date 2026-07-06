# apps_gateway-api

Gateway API offline `.run` installer package.

This package is a **CRD-only** offline installer for Kubernetes Gateway API. Gateway API itself is an API specification and a set of Kubernetes CRDs; it is **not** a gateway controller and does **not** run data-plane pods by itself.

## Version

- Gateway API: `v1.5.1`
- package type: CRD-only / architecture-independent payload
- release artifact shape: multi-arch `.run` files for normal offline delivery conventions
- included channels:
  - `standard-install.yaml`
  - `experimental-install.yaml`

## What this package installs

The `standard` channel is the default and is enough for most HTTP/gRPC ingress use cases:

- `GatewayClass`
- `Gateway`
- `HTTPRoute`
- `GRPCRoute`
- `ReferenceGrant`

The `experimental` channel contains the standard CRDs plus experimental APIs, for example TCP/TLS/UDP route or policy resources depending on the upstream Gateway API release.

## What this package does not install

This package does **not** install a Gateway API implementation/controller. You still need one of the Gateway API implementations, for example Envoy Gateway, Cilium, Istio, NGINX Gateway Fabric, Traefik, HAProxy Ingress, Gloo Gateway, or kgateway.

The normal order is:

1. Install Gateway API CRDs with this package.
2. Install a Gateway API implementation/controller.
3. Confirm that a `GatewayClass` exists.
4. Create a `Gateway` that references the `GatewayClass`.
5. Create `HTTPRoute`, `GRPCRoute`, or other Route resources that attach to the Gateway.

## Repository layout

```text
apps_gateway-api/
  VERSION
  build.sh
  install.sh
  images/
    image.json              # [] because Gateway API CRDs contain no container images
  upstream/
    .gitkeep                # optional local release assets go here
  .github/workflows/
    offline-run-packages.yml
```

Generated directories are ignored by git:

```text
.build/
dist/
```

## Build locally

Build host requirements:

- Linux shell
- `curl` when downloading upstream Gateway API release assets
- `tar`
- `sha256sum`

No `jq`, Python, Docker, Helm, or Kubernetes cluster is required for packaging.

Build both offline installer labels:

```bash
bash build.sh --arch all
```

Build a single installer label:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Use a different upstream Gateway API version:

```bash
bash build.sh --arch all --version 1.5.1
```

Use pre-downloaded release assets under `upstream/`:

```text
upstream/standard-install.yaml
upstream/experimental-install.yaml
```

```bash
bash build.sh --arch all --use-local-assets
```

Artifacts are written to `dist/`:

```text
dist/gateway-api-1.5.1-amd64.run
dist/gateway-api-1.5.1-amd64.run.sha256
dist/gateway-api-1.5.1-arm64.run
dist/gateway-api-1.5.1-arm64.run.sha256
```

> The CRD payload is architecture-independent. The `amd64` and `arm64` suffixes exist so offline package release artifacts match the same multi-architecture convention as image-carrying Kubernetes packages.

## Install in an offline Kubernetes environment

Target host requirements:

- `bash`
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`
- `kubectl` with cluster-admin permission for CRD installation
- optional `sha256sum`, only for checking the `.sha256` file before running the installer

The target host does **not** need `jq`, Python, Docker, Helm, or internet access.

Install standard CRDs:

```bash
sha256sum -c gateway-api-1.5.1-amd64.run.sha256
chmod +x gateway-api-1.5.1-amd64.run
./gateway-api-1.5.1-amd64.run install -y
```

Install experimental CRDs:

```bash
./gateway-api-1.5.1-amd64.run install --channel experimental -y
```

Install with an explicit kubeconfig/context:

```bash
./gateway-api-1.5.1-amd64.run install \
  --kubeconfig /etc/kubernetes/admin.conf \
  --context my-cluster \
  --channel standard \
  -y
```

The installer uses server-side apply by default because Gateway API CRD manifests are large. If there is a field ownership conflict during an upgrade:

```bash
./gateway-api-1.5.1-amd64.run install --channel standard --force-conflicts -y
```

Dry-run against the target apiserver:

```bash
./gateway-api-1.5.1-amd64.run install --channel standard --dry-run -y
```

Compatibility flags such as `--registry`, `--registry-user`, `--registry-pass`, and `--skip-image-prepare` are accepted as no-ops. This keeps the installer compatible with the broader offline `.run` convention even though this package has no images.

## Status

```bash
./gateway-api-1.5.1-amd64.run status
```

Equivalent manual checks:

```bash
kubectl get crd | grep gateway.networking
kubectl api-resources --api-group=gateway.networking.k8s.io
kubectl get gatewayclass
kubectl get gateways -A
kubectl get httproutes -A
kubectl get grpcroutes -A
```

## Uninstall

Safe uninstall does not delete CRDs:

```bash
./gateway-api-1.5.1-amd64.run uninstall -y
```

Actually deleting CRDs is dangerous because Kubernetes will also delete all custom resources of those CRD types, such as `Gateway`, `HTTPRoute`, and `GRPCRoute`. Use this only when you are sure:

```bash
./gateway-api-1.5.1-amd64.run uninstall --channel standard --delete-crds -y
```

## Example usage after installing a controller

Check GatewayClass:

```bash
kubectl get gatewayclass
```

Example application:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:v1.10
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: default
spec:
  selector:
    app: whoami
  ports:
  - name: http
    port: 80
    targetPort: 80
```

Example Gateway. Replace `YOUR_GATEWAY_CLASS` with the GatewayClass created by your controller:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: default
spec:
  gatewayClassName: YOUR_GATEWAY_CLASS
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
```

Example HTTPRoute:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whoami
  namespace: default
spec:
  parentRefs:
  - name: shared-gateway
    namespace: default
  hostnames:
  - whoami.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: whoami
      port: 80
```

Apply:

```bash
kubectl apply -f whoami.yaml
kubectl apply -f gateway.yaml
kubectl apply -f httproute.yaml
```

Check whether the route is accepted:

```bash
kubectl describe gateway shared-gateway
kubectl describe httproute whoami
kubectl get gateway shared-gateway -o yaml
kubectl get httproute whoami -o yaml
```

For access, use the external address or NodePort exposed by your chosen Gateway API controller. This package only installs the CRDs, so it does not create a LoadBalancer, NodePort, or proxy pod.

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds two artifacts:

- `gateway-api-run-amd64`
- `gateway-api-run-arm64`

Triggers:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.

## Validation checklist

```bash
bash -n build.sh install.sh
bash build.sh --arch amd64
bash build.sh --arch arm64
(cd dist && sha256sum -c gateway-api-*-amd64.run.sha256)
(cd dist && sha256sum -c gateway-api-*-arm64.run.sha256)
./dist/gateway-api-*-amd64.run help
./dist/gateway-api-*-arm64.run help
```

In a Kubernetes test cluster:

```bash
./dist/gateway-api-1.5.1-amd64.run install --dry-run -y
./dist/gateway-api-1.5.1-amd64.run install -y
./dist/gateway-api-1.5.1-amd64.run status
```
