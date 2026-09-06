# Testing Networking, Services, and Ingress

This exercise shows how two Kubernetes `Service` objects expose two separate
`Deployment` workloads inside the cluster, and how one nginx `Ingress` routes
external HTTP traffic to the correct Service.

## What we're testing

[`04-netwroking-ingress-service.yaml`](./04-netwroking-ingress-service.yaml)
creates:

- A namespace: `networking-ingress-service-example`
- A Deployment named `nginx-deployment` running `nginx:latest`
- A Service named `nginx-service` routing to the nginx Pods
- A Deployment named `api-deployment` running `hashicorp/http-echo:1.0.0`
- A Service named `api-service` routing to the API echo Pods
- An Ingress named `nginx-ingress` using `ingressClassName: nginx`

The important part: the Ingress sits in front of both Services. Requests to
`/` go to nginx, and requests to `/api` go to the echo API, which returns
`hello from API`.

## Ingress controller requirement

This manifest needs the nginx ingress controller to be installed in the
cluster. The infra script installs it with Helm and exposes it through the kind
host port mapping:

| Host URL | NodePort | Use |
|----------|----------|-----|
| `http://localhost:8080` | `30080` | nginx ingress HTTP |
| `https://localhost:8443` | `30443` | nginx ingress HTTPS |

If the controller is missing, update the platform:

```bash
./00-infra/create-kind-platform.sh update
```

Confirm the controller exists:

```bash
kubectl get pods -n ingress-nginx
kubectl get ingressclass
```

Expected output includes an `ingress-nginx-controller` Pod and an IngressClass
named `nginx`.

## Steps

### 1. Create the namespace, Deployments, Services, and Ingress

```bash
kubectl apply -f 04-netwroking-ingress-service.yaml
```

### 2. Confirm the workloads and Services

```bash
kubectl get deploy,svc,pod -n networking-ingress-service-example
```

Expected output includes two ready Deployments, two ClusterIP Services, and one
running Pod for each Deployment:

```text
NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/nginx-deployment   1/1     1            1           30s
deployment.apps/api-deployment     1/1     1            1           30s

NAME                    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/nginx-service   ClusterIP   10.x.x.x        <none>        80/TCP    30s
service/api-service     ClusterIP   10.x.x.x        <none>        80/TCP    30s
```

### 3. Confirm the Ingress routes

```bash
kubectl get ingress -n networking-ingress-service-example
```

Expected output:

```text
NAME            CLASS   HOSTS   ADDRESS   PORTS   AGE
nginx-ingress   nginx   *                 80      30s
```

### 4. Test the nginx route

```bash
curl http://localhost:8080/
```

Expected output includes the nginx welcome page HTML.

### 5. Test the API route

```bash
curl http://localhost:8080/api
```

Expected output:

```text
hello from API
```

## Troubleshooting

If `curl http://localhost:8080/api` does not reach the Ingress, port-forward
the controller Service and try again:

```bash
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
curl http://localhost:8080/api
```

If the Ingress stays without an address, confirm the class and controller:

```bash
kubectl describe ingress nginx-ingress -n networking-ingress-service-example
kubectl get ingressclass nginx
kubectl get svc -n ingress-nginx
```

## Cleanup

```bash
kubectl delete namespace networking-ingress-service-example
```
