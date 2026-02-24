#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

G="\e[32m"
R="\e[31m"
Y="\e[33m"
C="\e[36m"
D="\e[90m"
B="\e[1m"
N="\e[0m"

COLS=$(tput cols 2>/dev/null || echo 80)

rule() {
  printf "  ${D}"
  printf '%.0s─' $(seq 1 $((COLS - 4)))
  printf "${N}\n"
}

clear_screen() {
  printf "\e[2J\e[H"
}

render() {
  clear_screen

  local now
  now=$(date '+%H:%M:%S')

  echo ""
  echo -e "  ${C}${B}☸ Cluster Health${N}  ${D}$now${N}  ${D}(Ctrl-C to exit)${N}"
  echo ""

  rule
  printf "  ${B}%-12s  %-8s  %-6s  %-6s  %-10s  %s${N}\n" \
    "NODE" "STATUS" "CPU" "MEM" "PODS" "VERSION"
  rule

  while IFS= read -r line; do
    local name status roles age version
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    roles=$(echo "$line" | awk '{print $3}')
    age=$(echo "$line" | awk '{print $4}')
    version=$(echo "$line" | awk '{print $5}')

    local cpu_pct="--" mem_pct="--"
    local top_line
    top_line=$(kubectl top node "$name" --no-headers 2>/dev/null || echo "")
    if [ -n "$top_line" ]; then
      cpu_pct=$(echo "$top_line" | awk '{print $3}')
      mem_pct=$(echo "$top_line" | awk '{print $5}')
    fi

    local pod_count
    pod_count=$(kubectl get pods -A --field-selector="spec.nodeName=$name" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    local color="$G"
    if echo "$status" | grep -q "NotReady"; then
      color="$R"
    elif echo "$status" | grep -q "SchedulingDisabled"; then
      color="$Y"
    fi

    printf "  ${color}%-12s${N}  ${color}%-8s${N}  %-6s  %-6s  %-10s  ${D}%s${N}\n" \
      "$name" "$status" "$cpu_pct" "$mem_pct" "$pod_count" "$version"
  done <<< "$(kubectl get nodes --no-headers 2>/dev/null)"

  rule
  echo ""

  echo -e "  ${B}SYSTEM PODS${N}"
  echo ""
  printf "  ${B}%-20s  %-14s  %-10s  %-8s  %s${N}\n" \
    "NAMESPACE" "POD" "STATUS" "RESTARTS" "AGE"
  rule

  kubectl get pods -A --no-headers --sort-by=.metadata.namespace 2>/dev/null | while IFS= read -r line; do
    local ns name ready status restarts age
    ns=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    ready=$(echo "$line" | awk '{print $3}')
    status=$(echo "$line" | awk '{print $4}')
    restarts=$(echo "$line" | awk '{print $5}')
    age=$(echo "$line" | awk '{print $6}')

    local short_name="${name:0:30}"
    [ ${#name} -gt 30 ] && short_name="${short_name}…"

    local color="$G"
    case "$status" in
      Running) color="$G" ;;
      Completed) color="$D" ;;
      Pending|ContainerCreating|Init*) color="$Y" ;;
      *) color="$R" ;;
    esac

    printf "  %-20s  ${color}%-14s${N}  ${color}%-10s${N}  %-8s  ${D}%s${N}\n" \
      "$ns" "$short_name" "$status" "$restarts" "$age"
  done

  rule
  echo ""

  local total_pods running_pods
  total_pods=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  running_pods=$(kubectl get pods -A --no-headers --field-selector=status.phase=Running 2>/dev/null | wc -l | tr -d ' ')
  local total_nodes ready_nodes
  total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep " Ready " | wc -l | tr -d ' ')

  printf "  ${B}Nodes:${N} ${G}%s${N}/%s ready" "$ready_nodes" "$total_nodes"
  printf "    ${B}Pods:${N} ${G}%s${N}/%s running\n" "$running_pods" "$total_pods"
  echo ""
}

if [ "${1:-}" = "--once" ]; then
  render
  exit 0
fi

trap 'printf "\e[?25h"; exit 0' INT TERM
printf "\e[?25l"

while true; do
  render
  sleep 5
done
