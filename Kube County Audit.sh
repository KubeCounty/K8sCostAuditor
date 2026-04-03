#!/usr/bin/env bash
# =============================================================================
#  KubeCounty — Kubernetes Cost Audit Script
#  github.com/kubecounty/K8sCostAuditor
#
#  Usage:
#    chmod +x kubecounty-audit.sh
#    ./kubecounty-audit.sh
#    ./kubecounty-audit.sh --namespace my-namespace   # scope to one namespace
#    ./kubecounty-audit.sh --output report.txt        # save to file
#
#  Requirements: kubectl, jq
# =============================================================================

set -euo pipefail

# ── Colour codes ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Flags ─────────────────────────────────────────────────────────────────────
NAMESPACE="--all-namespaces"
NS_FLAG="-A"
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n) NAMESPACE="-n $2"; NS_FLAG="-n $2"; shift 2 ;;
    --output|-o)    OUTPUT_FILE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# If output file set, tee everything to it
if [[ -n "$OUTPUT_FILE" ]]; then
  exec > >(tee "$OUTPUT_FILE") 2>&1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
FINDINGS=()
FINDING_COUNT=0

header() {
  echo -e "\n${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BLUE}${BOLD}  $1${RESET}"
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

section() {
  echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"
  echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"
}

check() { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
flag()  { echo -e "  ${RED}✘${RESET}  $1"; }
info()  { echo -e "     ${BOLD}→${RESET} $1"; }

finding() {
  local severity="$1"; local message="$2"
  FINDING_COUNT=$((FINDING_COUNT + 1))
  FINDINGS+=("[$severity] $message")
  case $severity in
    CRITICAL) flag "$message" ;;
    WARN)     warn  "$message" ;;
    INFO)     info  "$message" ;;
  esac
}

require() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}ERROR: '$1' is required but not installed.${RESET}"
    exit 1
  fi
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
require kubectl
require jq

echo ""
echo -e "${BOLD}██╗  ██╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ ██╗   ██╗███╗   ██╗████████╗██╗   ██╗${RESET}"
echo -e "${BOLD}██║ ██╔╝██║   ██║██╔══██╗██╔════╝██╔════╝██╔═══██╗██║   ██║████╗  ██║╚══██╔══╝╚██╗ ██╔╝${RESET}"
echo -e "${BOLD}█████╔╝ ██║   ██║██████╔╝█████╗  ██║     ██║   ██║██║   ██║██╔██╗ ██║   ██║    ╚████╔╝ ${RESET}"
echo -e "${BOLD}██╔═██╗ ██║   ██║██╔══██╗██╔══╝  ██║     ██║   ██║██║   ██║██║╚██╗██║   ██║     ╚██╔╝  ${RESET}"
echo -e "${BOLD}██║  ██╗╚██████╔╝██████╔╝███████╗╚██████╗╚██████╔╝╚██████╔╝██║ ╚████║   ██║      ██║   ${RESET}"
echo -e "${BOLD}╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝   ╚═╝      ╚═╝  ${RESET}"
echo ""
echo -e "${BOLD}  Kubernetes Cost Audit Script${RESET}  |  github.com/kubecounty/K8sCostAuditor"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')  |  Context: $(kubectl config current-context 2>/dev/null || echo 'unknown')"
echo ""

# ── SECTION 1: Node Sizing ─────────────────────────────────────────────────────
header "1. NODE SIZING & INSTANCE TYPES"

section "Node inventory"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo -e "  Total nodes: ${BOLD}$NODE_COUNT${RESET}"
kubectl get nodes -o wide --no-headers 2>/dev/null | \
  awk '{printf "  %-40s %-15s %-15s %s\n", $1, $2, $6, $5}' | head -20

section "Node utilization (kubectl top nodes)"
if kubectl top nodes &>/dev/null; then
  kubectl top nodes 2>/dev/null
  # Flag nodes where CPU or memory appears low — requires metrics-server
  LOW_UTIL=$(kubectl top nodes --no-headers 2>/dev/null | awk '$3+0 < 40 {print $1, $3}')
  if [[ -n "$LOW_UTIL" ]]; then
    finding "WARN" "Nodes with CPU utilization below 40% detected — review for downsizing:"
    echo "$LOW_UTIL" | while read -r line; do info "$line"; done
  else
    check "No obviously under-utilized nodes detected"
  fi
else
  finding "INFO" "metrics-server not available — install it to get kubectl top nodes data"
fi

section "Single-node pools check"
POOLS=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.cloud\.google\.com/gke-nodepool}{"\n"}{end}' 2>/dev/null | \
  grep -v '^$' | sort | uniq -c | awk '$1==1 {print $2}' || true)
if [[ -n "$POOLS" ]]; the
  finding "WARN" "Single-node pools found (no redundancy, blocks scale-down): $POOLS"
else
  check "No single-node pools detected"
fi

section "Spot / preemptible node usage"
SPOT=$(kubectl get nodes -o json 2>/dev/null | \
  jq -r '.items[] | select(.metadata.labels["cloud.google.com/gke-spot"]=="true" or
    .metadata.labels["eks.amazonaws.com/capacityType"]=="SPOT" or
    .metadata.labels["kubernetes.azure.com/scalesetpriority"]=="spot") | .metadata.name' 2>/dev/null || true)
if [[ -n "$SPOT" ]]; then
  check "Spot/preemptible nodes in use:"
  echo "$SPOT" | while read -r n; do info "$n"; done
else
  finding "INFO" "No spot/preemptible nodes detected — consider for non-critical workloads to reduce cost"
fi


# ── SECTION 2: Resource Requests & Limits ─────────────────────────────────────
header "2. RESOURCE REQUESTS & LIMITS"

section "Pods missing CPU or memory requests"
MISSING_REQUESTS=$(kubectl get pods $NS_FLAG -o json 2>/dev/null | jq -r '
  .items[] |
  . as $pod |
  .spec.containers[] |
  select(.resources.requests == null or .resources.requests == {}) |
  "\($pod.metadata.namespace)/\($pod.metadata.name) — container: \(.name)"
' 2>/dev/null || true)

if [[ -n "$MISSING_REQUESTS" ]]; then
  finding "CRITICAL" "Pods with no resource requests (scheduler is flying blind):"
  echo "$MISSING_REQUESTS" | while read -r line; do info "$line"; done
else
  check "All pods have resource requests set"
fi

section "Pods missing CPU or memory limits"
MISSING_LIMITS=$(kubectl get pods $NS_FLAG -o json 2>/dev/null | jq -r '
  .items[] |
  . as $pod |
  .spec.containers[] |
  select(.resources.limits == null or .resources.limits == {}) |
  "\($pod.metadata.namespace)/\($pod.metadata.name) — container: \(.name)"
' 2>/dev/null || true)

if [[ -n "$MISSING_LIMITS" ]]; then
  finding "CRITICAL" "Pods with no resource limits (one bad pod can starve the node):"
  echo "$MISSING_LIMITS" | while read -r line; do info "$line"; done
else
  check "All pods have resource limits set"
fi

section "OOMKilled containers (limits set too low)"
OOMKILLED=$(kubectl get pods $NS_FLAG -o json 2>/dev/null | jq -r '
  .items[] |
  . as $pod |
  (.status.containerStatuses // [])[] |
  select(.lastState.terminated.reason == "OOMKilled") |
  "\($pod.metadata.namespace)/\($pod.metadata.name) — container: \(.name)"
' 2>/dev/null || true)

if [[ -n "$OOMKILLED" ]]; then
  finding "CRITICAL" "OOMKilled containers detected — limits are too tight or requests too low:"
  echo "$OOMKILLED" | while read -r line; do info "$line"; done
else
  check "No OOMKilled containers found"
fi

section "LimitRange objects per namespace"
LR=$(kubectl get limitrange $NS_FLAG --no-headers 2>/dev/null | wc -l | tr -d ' ')
NS_TOTAL=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$LR" -eq 0 ]]; then
  finding "WARN" "No LimitRange objects found — pods can be created with no resource defaults"
else
  check "LimitRange objects found: $LR across $NS_TOTAL namespaces"
  kubectl get limitrange $NS_FLAG 2>/dev/null
fi

section "ResourceQuota per namespace"
RQ=$(kubectl get resourcequota $NS_FLAG --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RQ" -eq 0 ]]; then
  finding "WARN" "No ResourceQuota objects found — namespaces have no spend ceiling"
else
  check "ResourceQuota objects found: $RQ"
  kubectl get resourcequota $NS_FLAG 2>/dev/null
fi

section "VPA recommendations (if installed)"
if kubectl get vpa $NS_FLAG &>/dev/null 2>&1; then
  VPA_COUNT=$(kubectl get vpa $NS_FLAG --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$VPA_COUNT" -gt 0 ]]; then
    check "VPA objects found: $VPA_COUNT"
    kubectl get vpa $NS_FLAG 2>/dev/null
  else
    finding "INFO" "VPA CRD exists but no VPA objects configured — consider adding for rightsizing recommendations"
  fi
else
  finding "INFO" "VPA not installed — consider deploying in recommendation mode for rightsizing data"
fi


# ── SECTION 3: Idle Namespaces & Orphaned Workloads ───────────────────────────
header "3. IDLE NAMESPACES & ORPHANED WORKLOADS"

section "Pod counts per namespace"
echo -e "  ${BOLD}Running pods per namespace:${RESET}"
kubectl get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | \
  awk '{print $1}' | sort | uniq -c | sort -rn | \
  awk '{printf "  %5s pods  %s\n", $1, $2}'

section "Namespaces with zero running pods"
ALL_NS=$(kubectl get namespaces --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null)
ACTIVE_NS=$(kubectl get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
IDLE_NS=$(comm -23 <(echo "$ALL_NS" | sort) <(echo "$ACTIVE_NS" | sort) | grep -v -E '^(kube-system|kube-public|kube-node-lease)$' || true)
if [[ -n "$IDLE_NS" ]]; then
  finding "WARN" "Namespaces with no running pods — review for deletion:"
  echo "$IDLE_NS" | while read -r ns; do info "$ns"; done
else
  check "All non-system namespaces have running pods"
fi

section "Deployments with 0 replicas"
ZERO_REPLICAS=$(kubectl get deployments $NS_FLAG --no-headers 2>/dev/null | awk '$3==0 {print $1"/"$2}' || true)
if [[ -n "$ZERO_REPLICAS" ]]; then
  finding "WARN" "Deployments scaled to zero — intentional or forgotten?"
  echo "$ZERO_REPLICAS" | while read -r line; do info "$line"; done
else
  check "No zero-replica deployments found"
fi

section "Orphaned PersistentVolumeClaims"
ORPHAN_PVC=$(kubectl get pvc $NS_FLAG --no-headers 2>/dev/null | grep -v Bound | awk '{print $1"/"$2" ("$3")"}' || true)
if [[ -n "$ORPHAN_PVC" ]]; then
  finding "CRITICAL" "Unbound PVCs — storage provisioned but unused (still billed):"
  echo "$ORPHAN_PVC" | while read -r line; do info "$line"; done
else
  check "All PVCs are bound"
fi

section "Released PersistentVolumes"
RELEASED_PV=$(kubectl get pv --no-headers 2>/dev/null | grep -E 'Released|Failed' | awk '{print $1" ("$5", "$2")"}' || true)
if [[ -n "$RELEASED_PV" ]]; then
  finding "CRITICAL" "Released/Failed PVs — provisioned storage with no claim (you are paying for these):"
  echo "$RELEASED_PV" | while read -r line; do info "$line"; done
else
  check "No Released or Failed PersistentVolumes found"
fi

section "Completed / failed jobs"
DONE_JOBS=$(kubectl get jobs $NS_FLAG --no-headers 2>/dev/null | awk '$3>0 {print $1"/"$2}' | head -20 || true)
if [[ -n "$DONE_JOBS" ]]; then
  finding "INFO" "Completed jobs still present — consider setting TTL or cleaning up:"
  echo "$DONE_JOBS" | while read -r line; do info "$line"; done
else
  check "No stale completed jobs found"
fi


# ── SECTION 4: Autoscaling ────────────────────────────────────────────────────
header "4. AUTOSCALING CONFIGURATION"

section "HPA status"
HPA_COUNT=$(kubectl get hpa $NS_FLAG --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$HPA_COUNT" -eq 0 ]]; then
  finding "WARN" "No HPAs found — variable workloads with static replicas waste money during low traffic"
else
  check "HPAs configured: $HPA_COUNT"
  kubectl get hpa $NS_FLAG 2>/dev/null
fi

section "HPA min replicas review"
kubectl get hpa $NS_FLAG -o json 2>/dev/null | jq -r '
  .items[] |
  select(.spec.minReplicas > 3) |
  "WARN: \(.metadata.namespace)/\(.metadata.name) — minReplicas=\(.spec.minReplicas) (high floor, check if justified)"
' 2>/dev/null | while read -r line; do finding "WARN" "$line"; done || true

section "Cluster Autoscaler"
CA=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -i 'cluster-autoscaler\|karpenter' | awk '{print $1, $3}' || true)
if [[ -n "$CA" ]]; then
  check "Cluster autoscaler / Karpenter detected:"
  echo "$CA" | while read -r line; do info "$line"; done
else
  finding "WARN" "No Cluster Autoscaler or Karpenter found — nodes will not scale down automatically"
fi

section "PodDisruptionBudgets"
PDB_COUNT=$(kubectl get pdb $NS_FLAG --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PDB_COUNT" -gt 0 ]]; then
  check "PodDisruptionBudgets found: $PDB_COUNT — review for overly strict configs blocking scale-down"
  kubectl get pdb $NS_FLAG 2>/dev/null
else
  finding "INFO" "No PodDisruptionBudgets configured"
fi


# ── SECTION 5: Storage ────────────────────────────────────────────────────────
header "5. STORAGE & PERSISTENT VOLUMES"

section "PersistentVolume inventory"
PV_COUNT=$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo -e "  Total PVs: ${BOLD}$PV_COUNT${RESET}"
kubectl get pv --no-headers 2>/dev/null | \
  awk '{printf "  %-30s %-10s %-12s %-12s %s\n", $1, $2, $5, $6, $7}' | head -20

section "StorageClass usage"
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.storageClassName}{"\n"}{end}' 2>/dev/null | \
  awk '{print $2}' | sort | uniq -c | sort -rn | \
  while read -r count sc; do info "StorageClass '$sc' — $count PVs"; done

section "Volume snapshot inventory"
if kubectl get volumesnapshot $NS_FLAG &>/dev/null 2>&1; then
  VS=$(kubectl get volumesnapshot $NS_FLAG --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$VS" -gt 0 ]]; then
    finding "INFO" "Volume snapshots found: $VS — audit for orphaned or expired snapshots"
    kubectl get volumesnapshot $NS_FLAG 2>/dev/null
  else
    check "No volume snapshots found"
  fi
else
  info "VolumeSnapshot CRD not installed"
fi


# ── SECTION 6: Networking & Egress ───────────────────────────────────────────
header "6. NETWORKING & EGRESS COSTS"

section "LoadBalancer services (each has a fixed monthly cost)"
LB_SVCS=$(kubectl get svc $NS_FLAG --no-headers 2>/dev/null | grep LoadBalancer || true)
LB_COUNT=$(echo "$LB_SVCS" | grep -c LoadBalancer || true)
if [[ "$LB_COUNT" -gt 0 ]]; then
  finding "WARN" "LoadBalancer services found: $LB_COUNT — each carries a fixed cloud cost"
  echo "$LB_SVCS" | while read -r line; do info "$line"; done
  # Flag any with no external IP yet (pending = misconfigured or stale)
  PENDING=$(echo "$LB_SVCS" | awk '$5=="<pending>" {print $2"/"$1}' || true)
  if [[ -n "$PENDING" ]]; then
    finding "WARN" "LoadBalancers stuck in pending state (paying for broken LBs):"
    echo "$PENDING" | while read -r line; do info "$line"; done
  fi
else
  check "No LoadBalancer services found"
fi

section "Shared Ingress controller check"
INGRESS=$(kubectl get ingress $NS_FLAG --no-headers 2>/dev/null | wc -l | tr -d ' ')
INGRESS_CTRL=$(kubectl get pods $NS_FLAG --no-headers 2>/dev/null | grep -i 'ingress\|nginx\|traefik\|haproxy' | wc -l | tr -d ' ')
if [[ "$LB_COUNT" -gt 2 && "$INGRESS_CTRL" -eq 0 ]]; then
  finding "WARN" "Multiple LoadBalancers but no Ingress controller — a shared Ingress could reduce LB count"
else
  check "Ingress resources: $INGRESS | Ingress controller pods: $INGRESS_CTRL"
fi

section "NodePort services"
NP=$(kubectl get svc $NS_FLAG --no-headers 2>/dev/null | grep NodePort | awk '{print $1"/"$2}' || true)
if [[ -n "$NP" ]]; then
  finding "INFO" "NodePort services found — review if these should be Ingress-routed instead:"
  echo "$NP" | while read -r line; do info "$line"; done
else
  check "No unnecessary NodePort services found"
fi

section "Node availability zone distribution"
AZ_DIST=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' 2>/dev/null | \
  grep -v '^$' | sort | uniq -c || true)
if [[ -n "$AZ_DIST" ]]; then
  check "Node AZ distribution (uneven = potential cross-AZ egress cost):"
  echo "$AZ_DIST" | while read -r line; do info "$line"; done
else
  info "AZ topology labels not found on nodes"
fi


# ── SECTION 7: Tooling & Licensing ───────────────────────────────────────────
header "7. TOOLING, ADD-ONS & LICENSING"

section "Installed Helm releases"
if command -v helm &>/dev/null; then
  HELM_COUNT=$(helm list -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  check "Helm releases installed: $HELM_COUNT"
  helm list -A 2>/dev/null | awk '{printf "  %-30s %-20s %-10s %s\n", $1, $2, $9, $10}' | head -30
else
  finding "INFO" "Helm not installed locally — install to audit Helm releases"
fi

section "Top resource-consuming pods (all namespaces)"
if kubectl top pods -A &>/dev/null 2>&1; then
  check "Top 15 pods by memory:"
  kubectl top pods -A --sort-by=memory --no-headers 2>/dev/null | head -15 | \
    awk '{printf "  %-30s %-40s %8s %8s\n", $1, $2, $3, $4}'
else
  finding "INFO" "metrics-server not available — install to surface high-cost pods"
fi

section "Cost monitoring tooling"
KUBECOST=$(kubectl get pods -A --no-headers 2>/dev/null | grep -i 'kubecost\|opencost' | wc -l | tr -d ' ')
if [[ "$KUBECOST" -gt 0 ]]; then
  check "Cost monitoring tool (Kubecost/OpenCost) detected — $KUBECOST pods running"
else
  finding "INFO" "No Kubecost or OpenCost detected — strongly recommended for ongoing cost visibility"
  info "Install OpenCost (free): helm install opencost opencost/opencost -n opencost --create-namespace"
fi

section "Service mesh usage"
MESH=$(kubectl get pods -A --no-headers 2>/dev/null | grep -iE 'istio|linkerd|consul-connect' | wc -l | tr -d ' ')
if [[ "$MESH" -gt 0 ]]; then
  finding "INFO" "Service mesh detected ($MESH pods) — verify all features are actively used, mesh adds overhead"
else
  check "No service mesh detected"
fi


# ── FINDINGS SUMMARY ─────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BLUE}${BOLD}  AUDIT SUMMARY — $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

CRITICAL_COUNT=0; WARN_COUNT=0; INFO_COUNT=0
for f in "${FINDINGS[@]}"; do
  [[ "$f" == \[CRITICAL\]* ]] && CRITICAL_COUNT=$((CRITICAL_COUNT+1))
  [[ "$f" == \[WARN\]* ]]     && WARN_COUNT=$((WARN_COUNT+1))
  [[ "$f" == \[INFO\]* ]]     && INFO_COUNT=$((INFO_COUNT+1))
done

echo -e "  ${RED}${BOLD}Critical findings : $CRITICAL_COUNT${RESET}"
echo -e "  ${YELLOW}${BOLD}Warnings          : $WARN_COUNT${RESET}"
echo -e "  ${CYAN}${BOLD}Info / suggestions: $INFO_COUNT${RESET}"
echo ""

if [[ ${#FINDINGS[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}All findings:${RESET}"
  for f in "${FINDINGS[@]}"; do
    case $f in
      \[CRITICAL\]*) echo -e "  ${RED}✘${RESET} $f" ;;
      \[WARN\]*)     echo -e "  ${YELLOW}⚠${RESET} $f" ;;
      \[INFO\]*)     echo -e "  ${CYAN}→${RESET} $f" ;;
    esac
  done
fi

echo ""
echo -e "  ${BOLD}Need help interpreting these results?${RESET}"
echo -e "  DM @kubecounty on TikTok or LinkedIn for a full audit consultation."
echo -e "  github.com/kubecounty/K8sCostAuditor"
echo ""
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
