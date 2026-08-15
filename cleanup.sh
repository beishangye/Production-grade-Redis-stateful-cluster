#!/bin/bash
set -uo pipefail

echo "============================================================"
echo "清理 Redis Day13 实验"
echo "============================================================"

kubectl delete pod redis-verify --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl delete statefulset redis --ignore-not-found=true --wait=true 2>/dev/null || true
kubectl delete svc redis-svc redis-nodeport --ignore-not-found=true 2>/dev/null || true
kubectl delete configmap redis-conf --ignore-not-found=true 2>/dev/null || true

# StatefulSet 删除不会自动删除 volumeClaimTemplates 创建的 PVC，单独删除。
kubectl delete pvc -l app=redis --ignore-not-found=true 2>/dev/null || true

# ----------------------------------------------------------------
# Clean node labels / taints added by deploy.sh.
# Instead of hardcoding minikube-m02/m03 (which only works for the
# exact 3-node minikube layout), find all nodes that have the labels
# / taints we set, and remove them. This works on ANY cluster.
# ----------------------------------------------------------------

# 1) disk label: any node with label "disk=ssd" or "disk=hdd"
echo "清理节点 disk=ssd / disk=hdd 标签..."
DISK_NODES=$(kubectl get nodes -l disk -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)
if [ -n "$DISK_NODES" ]; then
  while IFS= read -r node; do
    [ -z "$node" ] && continue
    echo "  - 节点 $node 移除 disk 标签"
    kubectl label nodes "$node" disk- 2>/dev/null || true
  done <<< "$DISK_NODES"
else
  echo "  (未找到带 disk= 标签的节点，跳过)"
fi

# 2) gpu taint: any node with taint gpu=true:NoSchedule
echo "清理节点 gpu=true:NoSchedule 污点..."
TAINT_NODES=$(kubectl get nodes -o json 2>/dev/null \
  | python3 -c '
import json,sys
nodes=json.load(sys.stdin)
for n in nodes.get("items",[]):
  for t in n.get("spec",{}).get("taints",[]):
    if t.get("key")=="gpu" and t.get("value")=="true" and t.get("effect")=="NoSchedule":
      print(n["metadata"]["name"])
      break
' 2>/dev/null || true)
if [ -z "$TAINT_NODES" ]; then
  # python3 might not be available; fallback to the common default nodes
  for fallback in minikube-m02; do
    if kubectl get node "$fallback" >/dev/null 2>&1; then
      # Double-check by reading node describe-like output (taints line)
      if kubectl describe node "$fallback" 2>/dev/null | grep -q "gpu.*true.*NoSchedule"; then
        TAINT_NODES="$fallback"
      fi
    fi
  done
fi
if [ -n "$TAINT_NODES" ]; then
  while IFS= read -r node; do
    [ -z "$node" ] && continue
    echo "  - 节点 $node 移除 gpu=true:NoSchedule 污点"
    kubectl taint nodes "$node" gpu=true:NoSchedule- 2>/dev/null || true
  done <<< "$TAINT_NODES"
else
  echo "  (未找到带 gpu=true:NoSchedule 污点的节点，跳过)"
fi

echo
echo "清理完成。"
