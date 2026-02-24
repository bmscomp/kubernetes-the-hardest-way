#!/usr/bin/env bash

# Export KUBECONFIG to use local admin config so kubectl commands work
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin"
export KUBECONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../configs" && pwd)/admin.kubeconfig"

START_TIME=$(date +%s)

COMPONENTS=(
  "API Server"
  "etcd"
  "scheduler"
  "controller-manager"
  "worker-sigma"
  "worker-gamma"
)

IDX_API=0
IDX_ETCD=1
IDX_SCHED=2
IDX_CM=3
IDX_SIGMA=4
IDX_GAMMA=5

STATUS=()
DONE_ELAPSED=()

for ((i=0; i<${#COMPONENTS[@]}; i++)); do
  STATUS[$i]="Waiting"
  DONE_ELAPSED[$i]=""
done

# Hide cursor
tput civis 
clear

# Handle Ctrl+C gracefully to restore the cursor
trap "tput cnorm; echo ''; exit" INT TERM EXIT

format_time() {
  local secs=$1
  printf "%02d:%02d" $((secs / 60)) $((secs % 60))
}

draw_grid() {
  tput cup 0 0 
  echo "======================================================================"
  echo " Kubernetes The Hardest Way — Cluster Boot Dashboard"
  echo "======================================================================"
  echo ""
  printf "%-25s | %-15s | %-10s\n" "COMPONENT" "STATUS" "ELAPSED"
  echo "--------------------------+-----------------+------------"
  
  local i
  for ((i=0; i<${#COMPONENTS[@]}; i++)); do
    local comp="${COMPONENTS[$i]}"
    local stat="${STATUS[$i]}"
    local color="\e[33m"
    if [[ "$stat" == "Active" || "$stat" == "Registered" ]]; then color="\e[32m"; fi
    if [[ "$stat" == "Polling" ]]; then color="\e[36m"; fi
    
    local elapsed=""
    if [[ -n "${DONE_ELAPSED[$i]}" ]]; then
      elapsed="${DONE_ELAPSED[$i]}"
    else
      local current=$(date +%s)
      local diff=$((current - START_TIME))
      elapsed=$(format_time $diff)
    fi
    
    printf "%-25s | ${color}%-15s\e[0m | %-10s\n" "$comp" "$stat" "$elapsed"
  done
  echo ""
  local total_elapsed=$(( $(date +%s) - START_TIME ))
  echo "Total elapsed: $(format_time $total_elapsed)"
  echo "Press Ctrl+C to cancel."
}

all_done=false

while [ "$all_done" = false ]; do
  CURRENT_TIME=$(date +%s)
  all_done=true
  
  # 1. Check API Server
  if [[ "${STATUS[$IDX_API]}" != "Active" ]]; then
    all_done=false
    STATUS[$IDX_API]="Polling"
    # Using curl to check port 6443 directly, with a strict max time
    if curl -k -s --max-time 2 -o /dev/null -w "%{http_code}" https://127.0.0.1:6443/version | grep -q "200"; then
      STATUS[$IDX_API]="Active"
      DONE_ELAPSED[$IDX_API]=$(format_time $((CURRENT_TIME - START_TIME)))
    fi
  fi
  
  # 2. Check Core Components (Only if API Server is Active)
  CS_OUTPUT=""
  if [[ "${STATUS[$IDX_API]}" == "Active" ]]; then
    CS_OUTPUT=$(kubectl get cs --request-timeout="2s" 2>/dev/null || true)
  fi

  for comp_idx in $IDX_ETCD $IDX_SCHED $IDX_CM; do
    if [[ "${STATUS[$comp_idx]}" != "Active" ]]; then
      all_done=false
      if [[ "${STATUS[$IDX_API]}" == "Active" ]]; then
        STATUS[$comp_idx]="Polling"
        search_name="${COMPONENTS[$comp_idx]}"
        if [[ "$comp_idx" == "$IDX_ETCD" ]]; then search_name="etcd-0"; fi
        
        if echo "$CS_OUTPUT" | grep -qiE "$search_name.*(Healthy|ok)"; then
          STATUS[$comp_idx]="Active"
          DONE_ELAPSED[$comp_idx]=$(format_time $((CURRENT_TIME - START_TIME)))
        fi
      fi
    fi
  done
  
  # 3. Check Worker Nodes
  NODES_OUTPUT=""
  if [[ "${STATUS[$IDX_API]}" == "Active" ]]; then
    NODES_OUTPUT=$(kubectl get nodes --request-timeout="2s" 2>/dev/null || true)
  fi

  for comp_idx in $IDX_SIGMA $IDX_GAMMA; do
    if [[ "${STATUS[$comp_idx]}" != "Registered" ]]; then
      all_done=false
      if [[ "${STATUS[$IDX_API]}" == "Active" ]]; then
        STATUS[$comp_idx]="Polling"
        node_name="sigma"
        if [ "$comp_idx" = "$IDX_GAMMA" ]; then node_name="gamma"; fi

        if echo "$NODES_OUTPUT" | grep -q "$node_name"; then
          STATUS[$comp_idx]="Registered"
          DONE_ELAPSED[$comp_idx]=$(format_time $((CURRENT_TIME - START_TIME)))
        fi
      fi
    fi
  done

  draw_grid
  
  if [ "$all_done" = true ]; then
    echo -e "\n\e[32m✔ All components are online and registered!\e[0m"
    echo "You can now run 'make network' to install Cilium."
    break
  fi

  sleep 2
done

tput cnorm # Restore cursor
echo ""
