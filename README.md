# apps_gateway-api

Gateway API offline `.run` installer package.

This package is a **CRD-only** offline installer for Kubernetes Gateway API. Gateway API itself is an API specification and a set of Kubernetes CRDs; it is **not** a gateway controller and does **not** run data-plane pods by itself.

## Version

- Gateway API: `v1.5.1`
- package type: CRD-only / architecture-independent
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

The `experimental` channel contains the standard CRDs plus experimental APIs, for example TCP/TLS/UDP route or policy resources depending on the upstream release.

## Build locally

Build host requirements:

- Linux shell
- `curl`
- `tar`
- `sha256sum`

No `jq`, Python, Docker, or Helm is required.

Build:

```bash
bash build.sh
```

Use a different upstream version:

```bash
bash build.sh --version 1.5.1
```

Use pre-downloaded release assets under `upstream/`:

```text
upstream/standard-install.yaml
upstream/experimental-install.yaml
```

```bash
bash build.sh --use-local-assets
```

Artifacts are written to `dist/`:

```text
dist/gateway-api-1.5.1.run
dist/gateway-api-1.5.1.run.sha256
```

## Install in an offline environment

Target host requirements:

- `bash`
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`
- `kubectl`
- optional `sha256sum`, only for checking the `.sha256` file before running the installer

The target host does **not** need `jq`, Python, Docker, Helm, or internet access.

Install standard CRDs:

```bash
sha256sum -c gateway-api-1.5.1.run.sha256
chmod +x gateway-api-1.5.1.run
./gateway-api-1.5.1.run install -y
```

Install experimental CRDs:

```bash
./gateway-api-1.5.1.run install --channel experimental -y
```

The installer uses server-side apply by default because upstream Gateway API release notes recommend it for large CRD manifests, especially the experimental channel.

If there is field ownership conflict during an upgrade:

```bash
./gateway-api-1.5.1.run install --channel standard --force-conflicts -y
```

## Status

```bash
./gateway-api-1.5.1.run status
```

Equivalent manual checks:

```bash
kubectl get crd | grep gateway.networking
kubectl get gatewayclass
kubectl get gateways -A
kubectl get httproutes -A
```

## Uninstall

Safe uninstall does not delete CRDs:

```bash
./gateway-api-1.5.1.run uninstall -y
```

Actually deleting CRDs is dangerous because Kubernetes will also delete all custom resources of those CRD types, such as `Gateway`, `HTTPRoute`, and `GRPCRoute`. Use this only when you are sure:

```bash
./gateway-api-1.5.1.run uninstall --channel standard --delete-crds -y
```

## How to use Gateway API

Gateway API is the API layer. You still need a Gateway API implementation/controller to make traffic actually flow.

Good implementation choices include:

- Envoy Gateway
- Cilium
- Istio
- NGINX Gateway Fabric
- Traefik
- HAProxy Ingress
- Gloo Gateway
- kgateway

The normal order is:

1. Install Gateway API CRDs with this package.
2. Install a Gateway API implementation/controller.
3. Confirm that a `GatewayClass` exists.
4. Create a `Gateway` that references the `GatewayClass`.
5. Create `HTTPRoute`, `GRPCRoute`, or other Route resources that attach to the Gateway.

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

The workflow `.github/workflows/offline-run-packages.yml` builds `gateway-api-<version>.run` and `.sha256` on:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.
