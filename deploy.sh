#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NODE2="minikube-m02"
NODE3="minikube-m03"

print(){ echo -e "$1"; }

print "${BLUE}============================================================${NC}"
print "${BLUE} Redis Day13 部署${NC}"
print "${BLUE}============================================================${NC}"

kubectl cluster-info >/dev/null

print "${YELLOW}[1/6] 节点标签与污点...${NC}"
kubectl label node "${NODE2}" disk=ssd --overwrite 2>/dev/null || true
kubectl label node "${NODE3}" disk=hdd --overwrite 2>/dev/null || true
kubectl taint node "${NODE2}" gpu=true:NoSchedule --overwrite 2>/dev/null || true

print "${YELLOW}[2/6] 检查旧 StatefulSet...${NC}"
if kubectl get sts redis >/dev/null 2>&1; then
  echo "发现已有 StatefulSet redis，先删除 StatefulSet，不删除 PVC。"
  kubectl delete sts redis --wait=true
fi

print "${YELLOW}[3/6] 清理旧 Pod（如有）...${NC}"
kubectl delete pod -l app=redis --ignore-not-found=true --wait=true

print "${YELLOW}[4/6] 部署 ConfigMap + Service...${NC}"
kubectl apply -f 00-configmap.yaml
kubectl apply -f 01-headless-service.yaml

print "${YELLOW}[5/6] 部署 StatefulSet...${NC}"
kubectl apply -f 02-statefulset.yaml

print "${YELLOW}[6/6] 等待 3 个 Pod...${NC}"
kubectl wait --for=condition=ready pod/redis-0 --timeout=180s
kubectl wait --for=condition=ready pod/redis-1 --timeout=180s
kubectl wait --for=condition=ready pod/redis-2 --timeout=180s

sleep 3

print "${GREEN}============================================================${NC}"
print "${GREEN} 部署完成${NC}"
print "${GREEN}============================================================${NC}"

kubectl get pods -l app=redis -o wide

echo
echo "等待 Redis Cluster 自动初始化..."
for i in $(seq 1 60); do
  STATE=$(kubectl exec redis-0 -- redis-cli cluster info 2>/dev/null | awk -F: '/^cluster_state:/ {print $2}' | tr -d '\r' || true)
  if [ "$STATE" = "ok" ]; then
    echo "Redis Cluster 已初始化。"
    break
  fi
  sleep 2
done

kubectl exec redis-0 -- redis-cli cluster info || true
