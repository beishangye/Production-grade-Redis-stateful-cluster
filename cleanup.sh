#!/bin/bash
set -e

echo "============================================================"
echo "清理 Redis Day13 实验"
echo "============================================================"

kubectl delete pod redis-verify --ignore-not-found=true
kubectl delete statefulset redis --ignore-not-found=true --wait=true
kubectl delete svc redis-svc redis-nodeport --ignore-not-found=true
kubectl delete configmap redis-conf --ignore-not-found=true

# StatefulSet 删除不会自动删除 volumeClaimTemplates 创建的 PVC，单独删除。
kubectl delete pvc -l app=redis --ignore-not-found=true

kubectl taint nodes minikube-m02 gpu=true:NoSchedule- 2>/dev/null || true
kubectl label nodes minikube-m02 disk- 2>/dev/null || true
kubectl label nodes minikube-m03 disk- 2>/dev/null || true

echo "清理完成。"
