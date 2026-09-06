# Testing LimitRange

This exercise shows how a Kubernetes `LimitRange` sets default CPU and memory
values for containers, and how it rejects Pods that request resources outside
the allowed range.

## What we're testing

[`02-LimitRange.yaml`](./02-LimitRange.yaml) creates:

- A namespace: `limit-range-example`
- A `LimitRange` named `limit-range-example` in that namespace

The `LimitRange` applies these rules to every container in the namespace:

| Setting | CPU | Memory |
|---------|-----|--------|
| Default limit | `500m` | `500Mi` |
| Default request | `200m` | `300Mi` |
| Minimum allowed | `100m` | `100Mi` |
| Maximum allowed | `1` | `3Gi` |

The important part: every container must stay within the minimum and maximum
values. If a Pod asks for more than the maximum, Kubernetes rejects it before
the Pod is created.

## Steps

### 1. Create the namespace and LimitRange

```bash
kubectl apply -f 02-LimitRange.yaml
```

### 2. Confirm the LimitRange rules

```bash
kubectl describe limitrange limit-range-example -n limit-range-example
```

Expected output includes the configured defaults, minimums, and maximums:

```text
Type       Resource  Min    Max  Default Request  Default Limit
----       --------  ---    ---  ---------------  -------------
Container  cpu       100m   1    200m             500m
Container  memory    100Mi  3Gi  300Mi            500Mi
```

### 3. Create a Pod that passes the LimitRange

[`02-limitrange-pass-pod.yaml`](./02-limitrange-pass-pod.yaml) creates a Pod
named `pod-pass` with:

- CPU request: `200m`
- CPU limit: `500m`
- Memory request: `200Mi`
- Memory limit: `500Mi`

These values are inside the allowed range, so the Pod should be accepted.

```bash
kubectl apply -f 02-limitrange-pass-pod.yaml
```

### 4. Verify the passing Pod is running

```bash
kubectl get pod -n limit-range-example
```

Expected output:

```text
NAME       READY   STATUS    RESTARTS   AGE
pod-pass   1/1     Running   0          11s
```

### 5. Try to create a Pod that fails the LimitRange

[`02-limitrange-failing-pod.yaml`](./02-limitrange-failing-pod.yaml) creates a
Pod named `pod-fail` with a CPU limit of `2`.

That should fail because the `LimitRange` allows a maximum CPU limit of `1`.

```bash
kubectl apply -f 02-limitrange-failing-pod.yaml
```

Expected result:

```text
Error from server (Forbidden): error when creating "02-limitrange-failing-pod.yaml": pods "pod-fail" is forbidden: maximum cpu usage per Container is 1, but limit is 2
```

### 6. Confirm only the passing Pod exists

```bash
kubectl get pod -n limit-range-example
```

Expected output:

```text
NAME       READY   STATUS    RESTARTS   AGE
pod-pass   1/1     Running   0          11s
```

`pod-fail` should not appear because Kubernetes rejected it during admission.

## Cleanup

```bash
kubectl delete namespace limit-range-example
```
