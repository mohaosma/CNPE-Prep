# Testing Storage

This exercise shows how a Kubernetes `StorageClass` dynamically provisions
storage for a `PersistentVolumeClaim`, and how a Pod mounts that claim as a
volume.

## What we're testing

[`03-Storage.yaml`](./03-Storage.yaml) creates:

- A `StorageClass` named `db-class`
- A namespace: `storage-example`
- A `PersistentVolumeClaim` named `db-pvc` in that namespace
- A Pod named `myapp` that mounts the claim at `/data`

The `StorageClass` uses:

| Setting | Value |
|---------|-------|
| Provisioner | `rancher.io/local-path` |
| Reclaim policy | `Retain` |
| Volume expansion | `false` |
| Binding mode | `WaitForFirstConsumer` |

The important part: `WaitForFirstConsumer` means the PVC may stay `Pending`
until Kubernetes has a Pod that needs it. Once `myapp` is scheduled, the
local-path provisioner creates a backing `PersistentVolume`, the PVC becomes
`Bound`, and the Pod can mount it.

## Steps

### 1. Create the StorageClass, namespace, PVC, and Pod

```bash
kubectl apply -f 03-Storage.yaml
```

### 2. Confirm the StorageClass, PVC, and PersistentVolume

```bash
kubectl get sc,pvc,pv -n storage-example
```

Expected output:

```text
NAME                                             PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
storageclass.storage.k8s.io/db-class             rancher.io/local-path   Retain          WaitForFirstConsumer   false                  3m31s
storageclass.storage.k8s.io/standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  11m

NAME                           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/db-pvc   Bound    pvc-44f0942d-fd3e-4029-9afd-d70c600ff45b   1Gi        RWO            db-class       <unset>                 3m31s

NAME                                                        CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                    STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
persistentvolume/pvc-44f0942d-fd3e-4029-9afd-d70c600ff45b   1Gi        RWO            Retain           Bound    storage-example/db-pvc   db-class       <unset>                          54s
```

The `standard` StorageClass already exists in the kind cluster. The test
creates `db-class`, and the PVC uses `db-class` because `storageClassName` is
set explicitly in [`03-Storage.yaml`](./03-Storage.yaml).

The PV name from this run is
`pvc-44f0942d-fd3e-4029-9afd-d70c600ff45b`. Your cluster will create a
different PVC/PV ID each time you recreate the claim.

### 3. Check the Pod

```bash
kubectl get pod -n storage-example
```

Expected output includes a running Pod:

```text
NAME    READY   STATUS    RESTARTS   AGE
myapp   1/1     Running   0          3m31s
```

### 4. Confirm the Pod mounted the PVC

```bash
kubectl exec -n storage-example myapp -- df -h /data
```

Expected output shows `/data` is mounted from the dynamically provisioned
volume:

```text
Filesystem      Size  Used Avail Use% Mounted on
...             ...   ...  ...   ...  /data
```

### 5. Write a test file into the mounted volume

```bash
kubectl exec -n storage-example myapp -- sh -c 'echo storage-test > /data/test.txt'
kubectl exec -n storage-example myapp -- cat /data/test.txt
```

Expected output:

```text
storage-test
```

### 6. Confirm the PersistentVolume claim relationship

```bash
kubectl get pv pvc-44f0942d-fd3e-4029-9afd-d70c600ff45b
```

Expected output:

```text
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                    STORAGECLASS
pvc-44f0942d-fd3e-4029-9afd-d70c600ff45b   1Gi        RWO            Retain           Bound    storage-example/db-pvc   db-class
```

## Cleanup

```bash
kubectl delete namespace storage-example
kubectl delete storageclass db-class
```

Because the `StorageClass` uses `Retain`, the `PersistentVolume` may remain
after the namespace is deleted. If so, remove it manually after confirming it
belongs to this exercise:

```bash
kubectl get pv
kubectl delete pv <pv-name>
```
