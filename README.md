# apps_gateway-api

Gateway API + Envoy Gateway offline `.run` installer package.

This package is not a CRD-only bundle. It installs a complete Gateway API implementation based on **Envoy Gateway**:

- Gateway API CRDs
- Envoy Gateway extension CRDs
- Envoy Gateway controller
- managed Envoy Proxy data plane image
- default `GatewayClass`
- default HTTP `Gateway`

Envoy Gateway manages Envoy Proxy as a Kubernetes Gateway API implementation. Gateway API resources dynamically provision and configure managed Envoy proxies.

## Version

- Envoy Gateway: `v1.8.2`
- Envoy Proxy data plane: `docker.io/envoyproxy/envoy:distroless-v1.38.3`
- packaged chart: `oci://docker.io/envoyproxy/gateway-helm`
- package type: Helm chart + offline images + bootstrap Gateway resources
- architectures: `amd64`, `arm64`

## Why Envoy Gateway

Gateway API CRDs alone only define the API surface. They do not reconcile `Gateway`, `HTTPRoute`, or `GRPCRoute`, and they do not create proxy pods or Services.

This package uses Envoy Gateway as the controller and data-plane implementation because it is Kubernetes Gateway API native and manages Envoy Proxy as the actual L7 data plane.

The official Envoy Gateway Helm chart installs Gateway API CRDs and Envoy Gateway CRDs by default, then installs the `envoy-gateway` controller. This package vendors that chart into the `.run` payload and packages the required container images for air-gapped environments.

## Repository layout

```text
apps_gateway-api/
  VERSION
  build.sh
  install.sh
  images/
    image.json
  upstream/
    .gitkeep
  .github/workflows/
    offline-run-packages.yml
```

Generated directories and release assets are ignored by git:

```text
.build/
dist/
upstream/*.tgz
```

## Packaged images

The package includes multi-architecture images for:

- `docker.io/envoyproxy/gateway:<version>`
- `docker.io/envoyproxy/envoy:distroless-v1.38.3`

The installer retags and pushes these images to the target registry, for example:

```text
sealos.hub:5000/kube4/envoyproxy/gateway:v1.8.2
sealos.hub:5000/kube4/envoyproxy/envoy:distroless-v1.38.3
```

## Build locally

Build both architectures:

```bash
bash build.sh --arch all
```

Build one architecture:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Build another Envoy Gateway version:

```bash
bash build.sh --arch all --version v1.8.2
```

Use a pre-downloaded Helm chart:

```text
upstream/gateway-helm-v1.8.2.tgz
```

```bash
bash build.sh --arch all --use-local-assets
```

For syntax/package smoke tests only, skip image tar packaging:

```bash
bash build.sh --arch amd64 --use-local-assets --skip-images
```

Artifacts are written to `dist/`:

```text
dist/gateway-api-envoy-v1.8.2-amd64.run
dist/gateway-api-envoy-v1.8.2-amd64.run.sha256
dist/gateway-api-envoy-v1.8.2-arm64.run
dist/gateway-api-envoy-v1.8.2-arm64.run.sha256
```

## Offline install

Install the full Envoy Gateway stack:

```bash
sha256sum -c gateway-api-envoy-v1.8.2-amd64.run.sha256
chmod +x gateway-api-envoy-v1.8.2-amd64.run
./gateway-api-envoy-v1.8.2-amd64.run install --registry sealos.hub:5000/kube4 -y
```

If images already exist in the target registry:

```bash
./gateway-api-envoy-v1.8.2-amd64.run install --registry sealos.hub:5000/kube4 --skip-image-prepare -y
```

Use an explicit kubeconfig/context:

```bash
./gateway-api-envoy-v1.8.2-amd64.run install --kubeconfig /etc/kubernetes/admin.conf --context my-cluster --registry sealos.hub:5000/kube4 -y
```

Render without applying:

```bash
./gateway-api-envoy-v1.8.2-amd64.run install --dry-run --skip-image-prepare -y
```

## What gets installed

Default install creates:

| Resource | Default |
| --- | --- |
| Controller namespace | `envoy-gateway-system` |
| Helm release | `eg` |
| Controller Deployment | `envoy-gateway` |
| GatewayClass | `eg` |
| Gateway namespace | `default` |
| Gateway | `edge-gateway` |
| Listener | HTTP `:80`, routes from all namespaces |

The default bootstrap can be changed:

```bash
./gateway-api-envoy-v1.8.2-amd64.run install --gateway-class eg --gateway-namespace gateway-system --gateway-name edge-gateway -y
```

Install only the controller and CRDs, without default Gateway bootstrap:

```bash
./gateway-api-envoy-v1.8.2-amd64.run install --no-bootstrap -y
```

Override images when the registry layout is different:

```bash
./gateway-api-envoy-v1.8.2-amd64.run install \
  --skip-image-prepare \
  --gateway-image registry.local/kube4/envoyproxy/gateway:v1.8.2 \
  --envoy-proxy-image registry.local/kube4/envoyproxy/envoy:distroless-v1.38.3 \
  -y
```

Pass extra Helm values:

```bash
./gateway-api-envoy-v1.8.2-amd64.run install --set deployment.replicas=2 --set config.envoyGateway.logging.level.default=debug -y
```

## Use it

Create an application Service, then attach an `HTTPRoute` to the default Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whoami
  namespace: default
spec:
  parentRefs:
  - name: edge-gateway
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

Check the route:

```bash
kubectl describe gateway edge-gateway -n default
kubectl describe httproute whoami -n default
kubectl get svc -A | grep envoy
```

## Status

```bash
./gateway-api-envoy-v1.8.2-amd64.run status
```

Equivalent manual checks:

```bash
helm list -n envoy-gateway-system
kubectl get pods -n envoy-gateway-system -o wide
kubectl get gatewayclass
kubectl get gateways -A
kubectl get httproutes -A
kubectl get envoyproxies.gateway.envoyproxy.io -A
```

## Uninstall

Uninstall controller and bootstrap resources, keeping the namespace:

```bash
./gateway-api-envoy-v1.8.2-amd64.run uninstall -y
```

Uninstall and delete the controller namespace:

```bash
./gateway-api-envoy-v1.8.2-amd64.run uninstall --delete-namespace -y
```

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds two artifacts:

- `gateway-api-envoy-run-amd64`
- `gateway-api-envoy-run-arm64`

Triggers:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.

## Validation checklist

```bash
bash -n build.sh install.sh
python3 -m json.tool images/image.json >/dev/null
bash build.sh --arch amd64
bash build.sh --arch arm64
(cd dist && sha256sum -c gateway-api-envoy-*-amd64.run.sha256)
(cd dist && sha256sum -c gateway-api-envoy-*-arm64.run.sha256)
./dist/gateway-api-envoy-*-amd64.run help
./dist/gateway-api-envoy-*-arm64.run help
```

In a Kubernetes test cluster:

```bash
./dist/gateway-api-envoy-v1.8.2-amd64.run install --dry-run --skip-image-prepare -y
./dist/gateway-api-envoy-v1.8.2-amd64.run install --registry sealos.hub:5000/kube4 -y
./dist/gateway-api-envoy-v1.8.2-amd64.run status
```
