# CNPE-Prep

## Local kind platform

| Command | Use |
| --- | --- |
| `./00-infra/create-kind-platform.sh up` | Create or reconcile the local kind platform cluster. |
| `./00-infra/create-kind-platform.sh connect` | Start local admin portal port-forwards after the cluster is ready. |
| `./00-infra/create-kind-platform.sh disconnect` | Stop admin portal port-forwards. |
| `./00-infra/create-kind-platform.sh update` | Re-apply the platform stack to the existing cluster. |
| `./00-infra/create-kind-platform.sh down` | Delete the kind cluster and generated local tool cache. |
