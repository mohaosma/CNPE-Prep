#!/usr/bin/env bash

# Create a local kind platform cluster and install the CNPE practice stack.
# The script is intentionally verbose and version-pinned so failed installs are
# easier to reproduce and debug.
set -Eeuo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-cnpe-prep}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.4}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
HELM_VERSION="${HELM_VERSION:-3.16.4}"
PORT_FORWARD_ADDRESS="${PORT_FORWARD_ADDRESS:-auto}"
PORT_FORWARD_URL_HOST="${PORT_FORWARD_URL_HOST:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT_FORWARD_STATE_DIR="${PORT_FORWARD_STATE_DIR:-$REPO_ROOT/.infra-port-forwards}"
PORT_FORWARD_LOG_DIR="${PORT_FORWARD_LOG_DIR:-$PORT_FORWARD_STATE_DIR/logs}"
HELM_BIN_DIR="${HELM_BIN_DIR:-$REPO_ROOT/.infra-bin/helm-v$HELM_VERSION}"
HELM="${HELM:-$HELM_BIN_DIR/helm}"

# Helm chart versions. Override any of these environment variables to test a
# different component version without editing the script.
CILIUM_CHART_VERSION="${CILIUM_CHART_VERSION:-1.16.5}"
OPENCOST_CHART_VERSION="${OPENCOST_CHART_VERSION:-1.43.2}"
PROM_STACK_CHART_VERSION="${PROM_STACK_CHART_VERSION:-66.3.1}"
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-1.24.4}"
ARGO_CD_CHART_VERSION="${ARGO_CD_CHART_VERSION:-7.7.11}"
ARGO_WORKFLOWS_CHART_VERSION="${ARGO_WORKFLOWS_CHART_VERSION:-0.45.11}"
ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.39.6}"
CROSSPLANE_CHART_VERSION="${CROSSPLANE_CHART_VERSION:-1.17.2}"
GATEKEEPER_CHART_VERSION="${GATEKEEPER_CHART_VERSION:-3.17.1}"
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.2.7}"
ISTIO_CHART_VERSION="${ISTIO_CHART_VERSION:-1.24.1}"

# Cilium native-routing lab values based on chapter05/cilium-native-auto-node-routes.yaml.
# Override these without editing the script when experimenting with different pools.
CILIUM_MULTI_POOL_CIDR="${CILIUM_MULTI_POOL_CIDR:-10.10.0.0/16}"
CILIUM_MULTI_POOL_MASK_SIZE="${CILIUM_MULTI_POOL_MASK_SIZE:-27}"
CILIUM_NATIVE_ROUTING_CIDR="${CILIUM_NATIVE_ROUTING_CIDR:-10.0.0.0/8}"

# Tekton does not publish an official Helm chart for core Pipelines. Use the
# official release manifest and keep it pinned like the Helm charts above.
TEKTON_PIPELINES_VERSION="${TEKTON_PIPELINES_VERSION:-v0.65.1}"

REQUIRED_TOOLS=(
  curl
  docker
  kind
  kubectl
  tar
  awk
)

log() {
  printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  log "$*"
  "$@"
}

usage() {
  cat <<EOF
Usage:
  $0 up       Create or reconcile the kind platform cluster.
  $0 update   Re-apply this script idempotently to the existing cluster.
  $0 down       Delete the kind cluster and generated local tool cache.
  $0 connect    Start admin portal port-forwards in the background.
  $0 disconnect Stop admin portal port-forwards started by connect.

Environment overrides:
  CLUSTER_NAME=$CLUSTER_NAME
  KIND_NODE_IMAGE=$KIND_NODE_IMAGE
  HELM_VERSION=$HELM_VERSION
  PORT_FORWARD_ADDRESS=$PORT_FORWARD_ADDRESS
  PORT_FORWARD_URL_HOST=$PORT_FORWARD_URL_HOST
  PORT_FORWARD_STATE_DIR=$PORT_FORWARD_STATE_DIR
EOF
}

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || fail "Missing required tool: kubectl"
  kubectl version --client=true >/dev/null || fail "kubectl is installed but not usable."
}

require_tools() {
  log "Checking required local tools"
  for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing required tool: $tool"
  done

  docker info >/dev/null 2>&1 || fail "Docker is installed but not reachable. Start Docker and retry."
  kubectl version --client=true >/dev/null || fail "kubectl is installed but not usable."
  kind version >/dev/null || fail "kind is installed but not usable."
}

install_pinned_helm() {
  local os arch tmp_dir archive extracted_helm

  if [[ -x "$HELM" ]] && "$HELM" version --short | grep -q "v$HELM_VERSION"; then
    log "Using pinned Helm $HELM_VERSION at $HELM"
    return
  fi

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) fail "Unsupported architecture for pinned Helm download: $arch" ;;
  esac

  tmp_dir="$(mktemp -d)"
  archive="$tmp_dir/helm.tar.gz"

  log "Downloading Helm v$HELM_VERSION for ${os}-${arch}"
  curl -fsSL -o "$archive" "https://get.helm.sh/helm-v${HELM_VERSION}-${os}-${arch}.tar.gz"
  tar -xzf "$archive" -C "$tmp_dir"

  extracted_helm="$tmp_dir/${os}-${arch}/helm"
  [[ -x "$extracted_helm" ]] || fail "Downloaded Helm archive did not contain an executable helm binary."

  mkdir -p "$HELM_BIN_DIR"
  cp "$extracted_helm" "$HELM"
  chmod +x "$HELM"
  rm -rf "$tmp_dir"

  "$HELM" version --short | grep -q "v$HELM_VERSION" || fail "Pinned Helm version check failed."
}

create_cluster() {
  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    log "Kind cluster '$CLUSTER_NAME' already exists; reusing it"
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_PATH"
    return
  fi

  log "Creating kind cluster '$CLUSTER_NAME' with CNI disabled for Cilium"
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
      - containerPort: 30443
        hostPort: 8443
        protocol: TCP
  - role: worker
  - role: worker
EOF

  kubectl cluster-info --context "kind-$CLUSTER_NAME"
}

add_helm_repos() {
  log "Adding Helm repositories"
  "$HELM" repo add cilium https://helm.cilium.io
  "$HELM" repo add opencost https://opencost.github.io/opencost-helm-chart
  "$HELM" repo add prometheus-community https://prometheus-community.github.io/helm-charts
  "$HELM" repo add grafana https://grafana.github.io/helm-charts
  "$HELM" repo add argo https://argoproj.github.io/argo-helm
  "$HELM" repo add crossplane-stable https://charts.crossplane.io/stable
  "$HELM" repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
  "$HELM" repo add kyverno https://kyverno.github.io/kyverno/
  "$HELM" repo add istio https://istio-release.storage.googleapis.com/charts
  "$HELM" repo update
}

wait_namespace_pods_ready() {
  local namespace="$1"
  local timeout="${2:-10m}"
  local deadline not_ready

  log "Waiting for pods in namespace '$namespace'"
  deadline=$((SECONDS + $(timeout_to_seconds "$timeout")))

  while (( SECONDS < deadline )); do
    not_ready="$(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.metadata.labels.batch\.kubernetes\.io/job-name}{"\t"}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' | awk -F '\t' '$3 != "" { next } $2 == "Succeeded" { next } $2 != "Running" { print; next } $0 ~ /false/ { print }')"
    if [[ -z "$not_ready" ]]; then
      kubectl get pods -n "$namespace"
      return
    fi
    sleep 5
  done

  kubectl get pods -n "$namespace" -o wide
  fail "Pods in namespace '$namespace' were not ready before timeout $timeout."
}

wait_deployment_ready() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-10m}"

  log "Waiting for deployment '$namespace/$deployment'"
  kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"
}

verify_api() {
  local resource="$1"

  log "Verifying Kubernetes API resource '$resource'"
  kubectl get "$resource" >/dev/null
}

timeout_to_seconds() {
  local timeout="$1"

  case "$timeout" in
    *s) printf '%s\n' "${timeout%s}" ;;
    *m) printf '%s\n' "$(( ${timeout%m} * 60 ))" ;;
    *h) printf '%s\n' "$(( ${timeout%h} * 3600 ))" ;;
    *) printf '%s\n' "$timeout" ;;
  esac
}

kind_control_plane_ip_from_kubernetes() {
  kubectl get nodes \
    -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
}

kind_control_plane_ip_from_docker() {
  local container="${CLUSTER_NAME}-control-plane"
  local ip

  ip="$(docker inspect -f '{{range $name, $network := .NetworkSettings.Networks}}{{if eq $name "kind"}}{{$network.IPAddress}}{{end}}{{end}}' "$container" 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "$container" 2>/dev/null | awk 'NF { print; exit }' || true)"
  fi

  printf '%s\n' "$ip"
}

resolve_cilium_k8s_service_host() {
  local control_plane_ip docker_ip

  control_plane_ip="$(kind_control_plane_ip_from_kubernetes)"
  docker_ip="$(kind_control_plane_ip_from_docker)"

  if [[ -z "$control_plane_ip" ]]; then
    control_plane_ip="$docker_ip"
  fi

  [[ -n "$control_plane_ip" ]] || fail "Could not determine kind control-plane IP for Cilium."

  if [[ -n "$docker_ip" && "$control_plane_ip" != "$docker_ip" ]]; then
    printf 'WARN: Kubernetes control-plane InternalIP is %s, Docker reports %s; using Kubernetes InternalIP.\n' "$control_plane_ip" "$docker_ip" >&2
  fi

  printf '%s\n' "$control_plane_ip"
}

install_cilium() {
  local control_plane_ip cilium_values

  control_plane_ip="$(resolve_cilium_k8s_service_host)"
  cilium_values="$(mktemp)"

  cat >"$cilium_values" <<EOF
ipam:
  mode: multi-pool
  operator:
    autoCreateCiliumPodIPPools:
      default:
        ipv4:
          cidrs:
            - "$CILIUM_MULTI_POOL_CIDR"
          maskSize: $CILIUM_MULTI_POOL_MASK_SIZE
routingMode: native
endpointRoutes:
  enabled: true
autoDirectNodeRoutes: true
ipv4NativeRoutingCIDR: "$CILIUM_NATIVE_ROUTING_CIDR"
kubeProxyReplacement: true
k8sServiceHost: "$control_plane_ip"
k8sServicePort: 6443
EOF

  log "Installing Cilium native routing with Kubernetes API server $control_plane_ip:6443"
  log "Cilium pod pool: $CILIUM_MULTI_POOL_CIDR, node mask: $CILIUM_MULTI_POOL_MASK_SIZE, native routing CIDR: $CILIUM_NATIVE_ROUTING_CIDR"

  "$HELM" upgrade --install cilium cilium/cilium \
    --version "$CILIUM_CHART_VERSION" \
    --namespace kube-system \
    --values "$cilium_values" \
    --wait \
    --timeout 15m

  rm -f "$cilium_values"

  wait_namespace_pods_ready kube-system 15m
  kubectl -n kube-system get pods -l k8s-app=cilium
}

install_opencost() {
  kubectl create namespace opencost --dry-run=client -o yaml | kubectl apply -f -

  "$HELM" upgrade --install opencost opencost/opencost \
    --version "$OPENCOST_CHART_VERSION" \
    --namespace opencost \
    --set opencost.exporter.defaultClusterId="$CLUSTER_NAME" \
    --set opencost.prometheus.internal.enabled=false \
    --set opencost.prometheus.external.url=http://kube-prometheus-stack-prometheus.monitoring:9090 \
    --wait \
    --timeout 10m

  wait_deployment_ready opencost opencost 10m
}

install_observability() {
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  "$HELM" upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version "$PROM_STACK_CHART_VERSION" \
    --namespace monitoring \
    --set grafana.adminPassword=admin \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --wait \
    --timeout 15m

  # Prometheus covers metrics, alerting, and Grafana dashboards. Tempo adds a
  # trace backend so the observability requirement is complete.
  "$HELM" upgrade --install tempo grafana/tempo \
    --version "$TEMPO_CHART_VERSION" \
    --namespace monitoring \
    --wait \
    --timeout 10m

  wait_namespace_pods_ready monitoring 15m
}

install_argo() {
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

  "$HELM" upgrade --install argo-cd argo/argo-cd \
    --version "$ARGO_CD_CHART_VERSION" \
    --namespace argocd \
    --wait \
    --timeout 15m

  "$HELM" upgrade --install argo-workflows argo/argo-workflows \
    --version "$ARGO_WORKFLOWS_CHART_VERSION" \
    --namespace argo \
    --wait \
    --timeout 15m

  "$HELM" upgrade --install argo-rollouts argo/argo-rollouts \
    --version "$ARGO_ROLLOUTS_CHART_VERSION" \
    --namespace argo-rollouts \
    --wait \
    --timeout 10m

  wait_namespace_pods_ready argocd 15m
  wait_namespace_pods_ready argo 15m
  wait_namespace_pods_ready argo-rollouts 10m
}

install_tekton() {
  kubectl apply -f "https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_PIPELINES_VERSION}/release.yaml"
  wait_namespace_pods_ready tekton-pipelines 10m
  verify_api taskruns.tekton.dev
  verify_api pipelineruns.tekton.dev
}

install_crossplane() {
  kubectl create namespace crossplane-system --dry-run=client -o yaml | kubectl apply -f -

  "$HELM" upgrade --install crossplane crossplane-stable/crossplane \
    --version "$CROSSPLANE_CHART_VERSION" \
    --namespace crossplane-system \
    --wait \
    --timeout 10m

  wait_namespace_pods_ready crossplane-system 10m
  verify_api providers.pkg.crossplane.io
}

install_gatekeeper() {
  kubectl create namespace gatekeeper-system --dry-run=client -o yaml | kubectl apply -f -

  "$HELM" upgrade --install gatekeeper gatekeeper/gatekeeper \
    --version "$GATEKEEPER_CHART_VERSION" \
    --namespace gatekeeper-system \
    --wait \
    --timeout 10m

  wait_namespace_pods_ready gatekeeper-system 10m
  verify_api constrainttemplates.templates.gatekeeper.sh
}

install_kyverno() {
  kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -

  "$HELM" upgrade --install kyverno kyverno/kyverno \
    --version "$KYVERNO_CHART_VERSION" \
    --namespace kyverno \
    --set policyReportsCleanup.enabled=false \
    --set cleanupJobs.admissionReports.enabled=false \
    --set cleanupJobs.clusterAdmissionReports.enabled=false \
    --set cleanupJobs.ephemeralReports.enabled=false \
    --set cleanupJobs.clusterEphemeralReports.enabled=false \
    --wait \
    --timeout 10m

  wait_namespace_pods_ready kyverno 10m
  verify_api clusterpolicies.kyverno.io
}

install_istio() {
  kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace istio-ingress --dry-run=client -o yaml | kubectl apply -f -

  "$HELM" upgrade --install istio-base istio/base \
    --version "$ISTIO_CHART_VERSION" \
    --namespace istio-system \
    --wait \
    --timeout 10m

  "$HELM" upgrade --install istiod istio/istiod \
    --version "$ISTIO_CHART_VERSION" \
    --namespace istio-system \
    --wait \
    --timeout 10m

  "$HELM" upgrade --install istio-ingress istio/gateway \
    --version "$ISTIO_CHART_VERSION" \
    --namespace istio-ingress \
    --set service.type=NodePort \
    --set service.ports[0].name=status-port \
    --set service.ports[0].port=15021 \
    --set service.ports[0].targetPort=15021 \
    --set service.ports[1].name=http2 \
    --set service.ports[1].port=80 \
    --set service.ports[1].targetPort=80 \
    --set service.ports[1].nodePort=30080 \
    --set service.ports[2].name=https \
    --set service.ports[2].port=443 \
    --set service.ports[2].targetPort=443 \
    --set service.ports[2].nodePort=30443 \
    --wait \
    --timeout 10m

  wait_namespace_pods_ready istio-system 10m
  wait_namespace_pods_ready istio-ingress 10m
  verify_api gateways.networking.istio.io
}


portal_forwards() {
  cat <<EOF
grafana|monitoring|svc/kube-prometheus-stack-grafana|3000:80|http|Grafana
prometheus|monitoring|svc/kube-prometheus-stack-prometheus|9090:9090|http|Prometheus
alertmanager|monitoring|svc/kube-prometheus-stack-alertmanager|9093:9093|http|Alertmanager
argocd|argocd|svc/argo-cd-argocd-server|8081:443|https|Argo CD
argo-workflows|argo|svc/argo-workflows-server|2746:2746|https|Argo Workflows
opencost|opencost|svc/opencost|9003:9090|http|OpenCost
EOF
}

port_forward_pid_file() {
  printf "%s/%s.pid\n" "$PORT_FORWARD_STATE_DIR" "$1"
}

port_forward_log_file() {
  printf "%s/%s.log\n" "$PORT_FORWARD_LOG_DIR" "$1"
}


tailscale_ipv4() {
  command -v tailscale >/dev/null 2>&1 || return
  tailscale ip -4 2>/dev/null | awk "NR == 1 { print; exit }"
}

resolve_port_forward_address() {
  local tailscale_ip

  if [[ "$PORT_FORWARD_ADDRESS" != "auto" ]]; then
    printf "%s\n" "$PORT_FORWARD_ADDRESS"
    return
  fi

  tailscale_ip="$(tailscale_ipv4)"
  if [[ -n "$tailscale_ip" ]]; then
    printf "127.0.0.1,%s\n" "$tailscale_ip"
  else
    printf "127.0.0.1\n"
  fi
}

print_portal_url_for_host() {
  local host="$1"
  local name namespace resource mapping scheme label local_port

  cat <<EOF

Admin portal URLs on $host:
EOF

  while IFS="|" read -r name namespace resource mapping scheme label; do
    local_port="${mapping%%:*}"
    printf "  %-16s %s://%s:%s\n" "$label" "$scheme" "$host" "$local_port"
  done < <(portal_forwards)
}

port_forward_process_matches() {
  local pid="$1"
  local resource="$2"
  local mapping="$3"
  local expected_address="${4:-}"
  local command_line

  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command_line" == *kubectl* && "$command_line" == *port-forward* && "$command_line" == *"$resource"* && "$command_line" == *"$mapping"* ]] || return
  [[ -z "$expected_address" || "$command_line" == *"$expected_address"* ]]
}

print_portal_urls() {
  local bind_address="$1"
  local hosts host tailscale_ip

  if [[ -n "$PORT_FORWARD_URL_HOST" ]]; then
    hosts="${PORT_FORWARD_URL_HOST//,/ }"
  elif [[ "$PORT_FORWARD_ADDRESS" == "auto" ]]; then
    tailscale_ip="$(tailscale_ipv4)"
    hosts="127.0.0.1"
    [[ -z "$tailscale_ip" ]] || hosts="$hosts $tailscale_ip"
  else
    hosts="${bind_address//,/ }"
  fi

  for host in $hosts; do
    print_portal_url_for_host "$host"
  done

  if [[ "$bind_address" == *"0.0.0.0"* && -z "$PORT_FORWARD_URL_HOST" ]]; then
    cat <<EOF

PORT_FORWARD_ADDRESS=0.0.0.0 listens on every interface. Replace 0.0.0.0 in the URLs with your host public or Tailscale IP.
EOF
  fi
}

connect_port_forwards() {
  local name namespace resource mapping scheme label pid_file log_file pid failed bind_address

  require_kubectl
  mkdir -p "$PORT_FORWARD_STATE_DIR" "$PORT_FORWARD_LOG_DIR"
  failed=0
  bind_address="$(resolve_port_forward_address)"

  log "Starting admin portal port-forwards on $bind_address"

  while IFS="|" read -r name namespace resource mapping scheme label; do
    pid_file="$(port_forward_pid_file "$name")"
    log_file="$(port_forward_log_file "$name")"

    if [[ -f "$pid_file" ]]; then
      pid="$(<"$pid_file")"
      if [[ -n "$pid" ]] && port_forward_process_matches "$pid" "$resource" "$mapping" "$bind_address"; then
        printf "%s already running on %s with pid %s.\n" "$label" "$mapping" "$pid"
        continue
      fi
      if [[ -n "$pid" ]] && port_forward_process_matches "$pid" "$resource" "$mapping"; then
        kill "$pid" 2>/dev/null || true
        printf "Restarting %s with bind address %s.\n" "$label" "$bind_address"
      fi
      rm -f "$pid_file"
    fi

    if ! kubectl -n "$namespace" get "$resource" >/dev/null 2>&1; then
      printf "Skipping %s: %s/%s is not available.\n" "$label" "$namespace" "$resource" >&2
      failed=$((failed + 1))
      continue
    fi

    nohup kubectl -n "$namespace" port-forward --address "$bind_address" "$resource" "$mapping" >"$log_file" 2>&1 </dev/null &
    pid="$!"
    printf "%s\n" "$pid" >"$pid_file"
    sleep 1

    if port_forward_process_matches "$pid" "$resource" "$mapping" "$bind_address"; then
      printf "Started %s on %s with pid %s.\n" "$label" "$mapping" "$pid"
    else
      printf "Failed to start %s on %s. See %s.\n" "$label" "$mapping" "$log_file" >&2
      rm -f "$pid_file"
      failed=$((failed + 1))
    fi
  done < <(portal_forwards)

  print_portal_urls "$bind_address"

  if (( failed > 0 )); then
    fail "$failed admin portal port-forward(s) did not start. Check logs in $PORT_FORWARD_LOG_DIR."
  fi
}

disconnect_port_forwards() {
  local name namespace resource mapping scheme label pid_file pid stopped

  stopped=0

  if [[ ! -d "$PORT_FORWARD_STATE_DIR" ]]; then
    log "No admin portal port-forward state found at $PORT_FORWARD_STATE_DIR"
    return
  fi

  log "Stopping admin portal port-forwards"

  while IFS="|" read -r name namespace resource mapping scheme label; do
    pid_file="$(port_forward_pid_file "$name")"
    [[ -f "$pid_file" ]] || continue

    pid="$(<"$pid_file")"
    if [[ -n "$pid" ]] && port_forward_process_matches "$pid" "$resource" "$mapping"; then
      kill "$pid" 2>/dev/null || true
      printf "Stopped %s port-forward with pid %s.\n" "$label" "$pid"
      stopped=$((stopped + 1))
    else
      printf "Removed stale pid file for %s.\n" "$label"
    fi

    rm -f "$pid_file"
  done < <(portal_forwards)

  log "Stopped $stopped admin portal port-forward(s)"
}

print_summary() {
  log "Installed platform summary"
  kubectl get nodes -o wide
  kubectl get pods -A

  cat <<EOF

Access admin portals on localhost and Tailscale with:
  $SCRIPT_DIR/create-kind-platform.sh connect

Stop admin portal access with:
  $SCRIPT_DIR/create-kind-platform.sh disconnect

To listen on every host interface, including a public interface:
  PORT_FORWARD_ADDRESS=0.0.0.0 PORT_FORWARD_URL_HOST=your-host-ip $SCRIPT_DIR/create-kind-platform.sh connect

Default Grafana login:
  username: admin
  password: admin

Cluster:
  name: $CLUSTER_NAME
  kubeconfig: $KUBECONFIG_PATH
EOF
}

up_platform() {
  require_tools
  install_pinned_helm
  create_cluster
  add_helm_repos

  install_cilium
  install_observability
  install_opencost
  install_argo
  install_tekton
  install_crossplane
  install_gatekeeper
  install_kyverno
  install_istio

  print_summary
}

update_platform() {
  log "Updating platform by reconciling all configured components"
  up_platform
}

down_platform() {
  disconnect_port_forwards
  require_tools

  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    log "Deleting kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME"
  else
    log "Kind cluster '$CLUSTER_NAME' does not exist; nothing to delete"
  fi

  if [[ -d "$REPO_ROOT/.infra-bin" ]]; then
    log "Removing generated local tool cache '$REPO_ROOT/.infra-bin'"
    rm -rf "$REPO_ROOT/.infra-bin"
  fi
}

main() {
  local command="${1:-up}"

  case "$command" in
    up)
      up_platform
      ;;
    update)
      update_platform
      ;;
    down)
      down_platform
      ;;
    connect)
      connect_port_forwards
      ;;
    disconnect)
      disconnect_port_forwards
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"
