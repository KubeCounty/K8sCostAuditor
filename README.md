# Kubernetes Cost Audit Checklist

**KubeCounty — Kubernetes Infrastructure Consulting**  
Run the automated version of this checklist with one command:

```bash
bash <(curl -s https://raw.githubusercontent.com/kubecounty/K8sCostAuditor/main/k8s_audit.sh)
```

> Want the findings interpreted by an LLM? Run with `--output json` and pipe the result into your AI tool of choice.

---

## How to Use This Checklist

| Symbol | Meaning |
|--------|---------|
| ✅ | Pass — no action needed |
| ⚠️ | Review — may need attention |
| 🔴 | Fix now — actively costing you money |

Fill in the **Status** and **Notes** columns as you work through each section. The summary table at the bottom is for your final report.

---

## Cluster Info

| Field | Value |
|-------|-------|
| Company | |
| Cluster(s) | |
| Cloud Provider | |
| Date | |
| Auditor | |

---

## 1. Node Sizing & Instance Types

| # | Check | Command | Status | Notes |
|---|-------|---------|--------|-------|
| 1.1 | List all node pools and instance types | `kubectl get nodes -o wide` | | |
| 1.2 | Check actual CPU/memory utilization per node — target 60–80% | `kubectl top nodes` | | |
| 1.3 | Find nodes with consistent utilization below 40% | `kubectl top nodes --sort-by=cpu` | | |
| 1.4 | Confirm spot/preemptible instances are used for non-critical workloads | `kubectl get nodes -o json \| jq '.items[].metadata.labels'` | | |
| 1.5 | Check reserved instance or committed use discount coverage | `kubectl get nodes -o jsonpath='{.items[*].spec.providerID}'` | | |
| 1.6 | Verify no single-node pools exist without justification | `kubectl get nodes -l <pool-label> --show-labels` | | |
| 1.7 | Identify ARM-compatible workloads that could shift to cheaper ARM nodes | `kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.nodeSelector}{"\n"}{end}'` | | |

---

## 2. Resource Requests & Limits

| # | Check | Command | Status | Notes |
|---|-------|---------|--------|-------|
| 2.1 | Confirm every pod has CPU and memory **requests** set | `kubectl get pods -A -o json \| jq '[.items[] \| select(.spec.containers[].resources.requests == null)] \| length'` | | |
| 2.2 | Confirm every pod has CPU and memory **limits** set | `kubectl get pods -A -o json \| jq '[.items[] \| select(.spec.containers[].resources.limits == null)] \| length'` | | |
| 2.3 | Compare actual usage vs requested resources | `kubectl top pods -A --sort-by=cpu` | | |
| 2.4 | Check for OOMKilled containers — signals limits too low | `kubectl get pods -A -o json \| jq '.items[] \| select(.status.containerStatuses[]?.lastState.terminated.reason=="OOMKilled") \| .metadata.name'` | | |
| 2.5 | Check LimitRange objects per namespace | `kubectl get limitrange -A` | | |
| 2.6 | Check ResourceQuota per namespace | `kubectl get resourcequota -A` | | |
| 2.7 | Review VPA recommendations if VPA is installed | `kubectl get vpa -A` | | |

---

## 3. Idle Namespaces & Orphaned Workloads

| # | Check | Command | Status | Notes |
|---|-------|---------|--------|-------|
| 3.1 | List pod counts per namespace | `kubectl get pods -A --field-selector=status.phase=Running \| awk '{print $1}' \| sort \| uniq -c` | | |
| 3.2 | Identify namespaces with zero running pods | `kubectl get pods -A --field-selector=status.phase=Running \| awk '{print $1}' \| sort -u` | | |
| 3.3 | Find deployments with 0 replicas | `kubectl get deployments -A \| awk '$3==0'` | | |
| 3.4 | Find completed/failed jobs still consuming quota | `kubectl get jobs -A --field-selector=status.conditions[0].type=Complete` | | |
| 3.5 | Find orphaned PVCs not bound to a running pod | `kubectl get pvc -A \| grep -v Bound` | | |
| 3.6 | List Released PersistentVolumes still provisioned | `kubectl get pv \| grep Released` | | |
| 3.7 | Identify dev/staging namespaces running 24/7 | `kubectl get deployments -n <staging-ns> -o wide` | | |

---

## 4. Autoscaling Configuration

| # | Check | Command | Status | Notes |
|---|-------|---------|--------|-------|
| 4.1 | List all HPAs and their current vs desired replica state | `kubectl get hpa -A` | | |
| 4.2 | Check HPA min replicas — confirm floor isn't too high | `kubectl get hpa -A -o jsonpath='{range .items[*]}{.metadata.name}{" min:"}{.spec.minReplicas}{"\n"}{end}'` | | |
| 4.3 | Verify Cluster Autoscaler or Karpenter is active | `kubectl get pods -n kube-system \| grep cluster-autoscaler` | | |
| 4.4 | Check Cluster Autoscaler logs for scale-down blockers | `kubectl logs -n kube-system deployment/cluster-autoscaler \| grep 'scale down'` | | |
| 4.5 | Verify PodDisruptionBudgets are not blocking scale-down | `kubectl get pdb -A` | | |
| 4.6 | Check for workloads with static replicas that never scale | `kubectl get deployments -A \| awk '$3==$4 && $3>1'` | | |
| 4.7 | Check HPA events for rapid up/down oscillation | `kubectl describe hpa <name> -n <namespace> \| grep Events` | | |

---

## 5. Storage & Persistent Volumes

| # | Check | Command | Status | Notes |
|---|-------|---------|--------|-------|
| 5.1 | List all PersistentVolumes and their status | `kubectl get pv -o wide` | | |
| 5.2 | Identify Released or Failed PVs — still billed | `kubectl get pv \| grep -E 'Released\|Failed'` | | |
| 5.3 | Check StorageClass for each PV — is the tier appropriate? | `kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.storageClassName}{"\n"}{end}'` | | |
| 5.4 | Check actual data usage vs provisioned PV size | `kubectl exec -it <pod> -- df -h /data` | | |
| 5.5 | List orphaned PVCs not attached to any pod | `kubectl get pvc -A \| grep -v Bound` | | |
| 5.6 | Review volume snapshot policies for orphaned snapshots | `kubectl get volumesnapshot -A` | | |

---

## 6. Networking & Egress Costs

| # | Check | Command | Status | Notes |
|---|-------|---------|--------|-------|
| 6.1 | List all LoadBalancer services — each has a fixed monthly cost | `kubectl get svc -A --field-selector spec.type=LoadBalancer` | | |
| 6.2 | Identify LoadBalancer services with no active traffic | `kubectl get svc -A -o json \| jq '.items[] \| select(.spec.type=="LoadBalancer") \| {name:.metadata.name, ingress:.status.loadBalancer.ingress}'` | | |
| 6.3 | Check if a shared Ingress controller can replace multiple LBs | `kubectl get ingress -A` | | |
| 6.4 | Identify cross-AZ pod communication | `kubectl get nodes -o json \| jq '.items[].metadata.labels["topology.kubernetes.io/zone"]'` | | |
| 6.5 | Check for NodePort services exposed unnecessarily | `kubectl get svc -A --field-selector spec.type=NodePort` | | |
| 6.6 | Review ExternalName services routing to external APIs | `kubectl get svc -A \| grep ExternalName` | | |

---

## 7. Tooling, Add-ons & Licensing

| # | Check | Command | Status | Notes |
|---|-------|---------|--------|-------|
| 7.1 | List all installed Helm releases | `helm list -A` | | |
| 7.2 | Check for operators consuming significant cluster resources | `kubectl top pods -A --sort-by=memory \| head -20` | | |
| 7.3 | Audit service mesh usage — are all features actively used? | `kubectl get pods -n istio-system` | | |
| 7.4 | Check container image registry — are old tags being pruned? | `kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' \| sort \| uniq` | | |
| 7.5 | Identify redundant tooling solving the same problem | `helm list -A \| sort` | | |
| 7.6 | Check if paid monitoring has a viable open-source alternative | `kubectl get pods -n monitoring` | | |

---

## Audit Summary

| Area | Finding | Est. Savings | Priority |
|------|---------|-------------|----------|
| Node Sizing | | | |
| Resource Requests/Limits | | | |
| Idle Namespaces | | | |
| Autoscaling | | | |
| Storage | | | |
| Egress & Networking | | | |
| Tooling / Add-ons | | | |

---

## Recommended Next Steps

1. 
2. 
3. 

---

## Automate This Checklist

Every check in this document is scripted. Run the full audit against any cluster:

```bash
bash <(curl -s https://raw.githubusercontent.com/kubecounty/K8sCostAuditor/main/k8s_audit.sh)
```

Save findings to a file:

```bash
bash <(curl -s https://raw.githubusercontent.com/kubecounty/K8sCostAuditor/main/k8s_audit.sh) --output audit-report.txt
```

Output as JSON for LLM analysis:

```bash
bash <(curl -s https://raw.githubusercontent.com/kubecounty/K8sCostAuditor/main/k8s_audit.sh) --output findings.json
```

---

*Built by [KubeCounty](www.youtube.com/@KubeCounty) — Kubernetes Infrastructure Consulting*  
*Found this useful? Follow on [TikTok](https://www.tiktok.com/@malchielurias) or [LinkedIn](https://www.linkedin.com/in/malchiel-urias/)*