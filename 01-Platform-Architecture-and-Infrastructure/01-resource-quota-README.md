# Testing ResourceQuota

This exercise shows how a Kubernetes `ResourceQuota` limits the number of
Pods (and other resources) that can be created in a namespace, and what
happens when a Deployment tries to exceed that limit.

## What we're testing

[`01-resource-quota.yaml`](./01-resource-quota.yaml) creates:

- A namespace: `resource-quota-example`
- A `ResourceQuota` named `quota-name` in that namespace, capping it to:
  | Resource                 | Limit  |
  |---------------------------|--------|
  | `pods`                    | 2      |
  | `requests.cpu`             | 500m   |
  | `requests.memory`          | 500Mi  |
  | `limits.cpu`               | 1      |
  | `limits.memory`            | 1Gi    |
  | `persistentvolumeclaims`   | 2      |
  | `requests.storage`         | 5Gi    |

The important part: once a `ResourceQuota` sets CPU/memory limits for a
namespace, **every Pod created in it must explicitly declare its own
`requests`/`limits`** — otherwise the API server rejects it. That's why the
test below creates the Deployment first and then patches it with resource
requests/limits, rather than setting them up front.

We'll deploy 4 replicas of nginx into this namespace and confirm that only
**2** Pods ever come up, because the quota caps `pods` at `2`.

## Steps

### 1. Create the namespace and the ResourceQuota

```bash
kubectl create -f 01-resource-quota.yaml
```

### 2. Create a Deployment with 4 replicas and add resource requests/limits

```bash
kubectl create deployment nginx-deployment -n resource-quota-example --image=nginx:latest --replicas=4 && \
kubectl set resources deployment nginx-deployment -n resource-quota-example --limits=cpu=200m,memory=256Mi --requests=cpu=100m,memory=128Mi
```

This is expected to create only 2 Pods, even though 4 replicas were
requested — the `ResourceQuota` blocks the other 2.

### 3. Check the ResourceQuota usage

```bash
kubectl describe ns resource-quota-example
```

The `pods` line shows `2/2` — the quota is fully used, which is why the
other 2 replicas never come up:

```
Name:         resource-quota-example
Labels:       kubernetes.io/metadata.name=resource-quota-example
Annotations:  <none>
Status:       Active

Resource Quotas
  Name:                   quota-name
  Resource                Used   Hard
  --------                ---    ---
  limits.cpu              400m   1
  limits.memory           512Mi  1Gi
  persistentvolumeclaims  0      2
  pods                    2      2
  requests.cpu            200m   500m
  requests.memory         256Mi  500Mi
  requests.storage        0      5Gi

No LimitRange resource.
```

### 4. Verify only 2 out of 4 Pods were created

```bash
kubectl get pod,deployment -n resource-quota-example
```

Expected output — the Deployment reports `2/4` ready, and only 2 Pods exist:

```
NAME                                    READY   STATUS    RESTARTS   AGE
pod/nginx-deployment-7587c64f8d-fhz79   1/1     Running   0          12s
pod/nginx-deployment-7587c64f8d-rgkqr   1/1     Running   0          12s

NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/nginx-deployment   2/4     2            2           12s
```

### 5. Confirm why: check the ReplicaSet events

```bash
kubectl describe replicaset -n resource-quota-example
```

You should see an event like this, showing Kubernetes refusing to create
the 3rd Pod because the quota's `pods: 2` limit was already reached:

```
Warning  FailedCreate  1s (x6 over 81s)  replicaset-controller  (combined from similar events): Error creating: pods "nginx-deployment-7587c64f8d-wzh2v" is forbidden: exceeded quota: quota-name, requested: pods=1, used: pods=2, limited: pods=2
```

## Cleanup

```bash
kubectl delete namespace resource-quota-example
```
