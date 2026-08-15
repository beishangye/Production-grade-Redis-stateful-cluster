#!/bin/bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NODE2="minikube-m02"
NODE3="minikube-m03"

print(){ echo -e "$1"; }
die(){ print "${RED}$*${NC}"; exit 1; }

print "${BLUE}============================================================${NC}"
print "${BLUE} Redis Day13 部署${NC}"
print "${BLUE}============================================================${NC}"

kubectl cluster-info >/dev/null 2>&1 || die "Kubernetes API 不可用，请检查 kubectl 配置"

# Resolve node names dynamically in case user is NOT on minikube 3-node
# cluster: if NODE2/NODE3 don't exist, fall back to labeling the actual
# worker nodes (the ones that are NOT the master / control-plane).
if ! kubectl get node "${NODE2}" >/dev/null 2>&1 || ! kubectl get node "${NODE3}" >/dev/null 2>&1; then
  print "${YELLOW}[INFO] 未找到 ${NODE2}/${NODE3}，自动识别集群中实际的工作节点进行标签/污点设置...${NC}"
  WORKERS=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.node-role\.kubernetes\.io/controlplane}{"\n"}{end}' 2>/dev/null \
    | awk 'NF==1 {print $1}' \
    || true)
  # Fallback: also include nodes that don't have master/controlplane role label at all
  ALL_NON_MASTER=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r n; do
        roles=$(kubectl get node "$n" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)
        if ! echo "$roles" | grep -qE 'node-role\.kubernetes\.io/(controlplane|master)'; then
          echo "$n"
        fi
      done \
    | sort -u)
  ALL_WORKERS=$( (echo "$WORKERS"; echo "$ALL_NON_MASTER") | sed '/^$/d' | sort -u | head -n 3 )
  if [ -z "${ALL_WORKERS:-}" ]; then
    print "${YELLOW}[WARN] 无法识别工作节点，跳过节点标签 / 污点设置。${NC}"
    print "  Pod 反亲和仍然生效，只是无法优先调度到 SSD 节点。"
    unset NODE2 NODE3
  else
    NODE_LIST=( $ALL_WORKERS )
    NODE2="${NODE_LIST[0]:-}"
    NODE3="${NODE_LIST[1]:-${NODE_LIST[0]:-}}"
    print "  识别到 worker 节点：${ALL_WORKERS//$'\n'/, }"
    print "  使用 NODE2=${NODE2}  NODE3=${NODE3}"
  fi
fi

print "${YELLOW}[1/6] 节点标签与污点...${NC}"
if [ -n "${NODE2:-}" ] && kubectl get node "${NODE2}" >/dev/null 2>&1; then
  kubectl label node "${NODE2}" disk=ssd --overwrite 2>/dev/null || true
  kubectl taint node "${NODE2}" gpu=true:NoSchedule --overwrite 2>/dev/null || true
fi
if [ -n "${NODE3:-}" ] && kubectl get node "${NODE3}" >/dev/null 2>&1; then
  kubectl label node "${NODE3}" disk=hdd --overwrite 2>/dev/null || true
fi

print "${YELLOW}[2/6] 检查旧 StatefulSet...${NC}"
if kubectl get sts redis >/dev/null 2>&1; then
  echo "发现已有 StatefulSet redis，先删除 StatefulSet，不删除 PVC。"
  kubectl delete sts redis --wait=true || true
fi

print "${YELLOW}[3/6] 清理旧 Pod（如有）...${NC}"
kubectl delete pod -l app=redis --ignore-not-found=true --wait=true || true

print "${YELLOW}[4/6] 部署 ConfigMap + Service...${NC}"
kubectl apply -f 00-configmap.yaml
kubectl apply -f 01-headless-service.yaml

print "${YELLOW}[5/6] 部署 StatefulSet...${NC}"
kubectl apply -f 02-statefulset.yaml

print "${YELLOW}[6/6] 等待 3 个 Pod Ready（每 pod 最多 180s）...${NC}"
for POD in redis-0 redis-1 redis-2; do
  echo "  等待 ${POD} Ready..."
  if ! kubectl wait --for=condition=ready "pod/${POD}" --timeout=180s >/dev/null 2>&1; then
    echo "  ${POD} 尚未 Ready，继续检查 STATUS 字段（可能仍在启动中）："
    kubectl get pod "$POD" -o wide || true
    READY=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
    RESTARTS=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)
    if [ "$READY" != true ] && [ -n "$RESTARTS" ] && [ "$RESTARTS" -ge 3 ] 2>/dev/null; then
      print "${RED}  ${POD} 可能有问题（RESTARTS=${RESTARTS}）。诊断建议：${NC}"
      echo "    kubectl describe pod ${POD}"
      echo "    kubectl logs ${POD} --previous"
    fi
  else
    echo "  ${POD} Ready ✓"
  fi
done

sleep 5

print "${GREEN}============================================================${NC}"
print "${GREEN} 部署完成${NC}"
print "${GREEN}============================================================${NC}"

kubectl get pods -l app=redis -o wide

echo
echo "等待 Redis Cluster 自动初始化（最多 120s）..."
LAST_RESTARTS=-1
CRASHLOOP_DETECTED=0
for i in $(seq 1 60); do
  # Only exec cluster info if redis-0 container is actually ready;
  # otherwise we get "container not found" errors during CrashLoop.
  READY=$(kubectl get pod redis-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  RESTARTS=$(kubectl get pod redis-0 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

  if [ "$READY" = true ]; then
    STATE=$(kubectl exec redis-0 -- redis-cli cluster info 2>/dev/null \
      | awk -F: '/^cluster_state:/ {print $2}' | tr -d '\r' | xargs || true)
    SLOTS=$(kubectl exec redis-0 -- redis-cli cluster info 2>/dev/null \
      | awk -F: '/^cluster_slots_assigned:/ {print $2}' | tr -d '\r' | xargs || true)
    NODES=$(kubectl exec redis-0 -- redis-cli cluster info 2>/dev/null \
      | awk -F: '/^cluster_known_nodes:/ {print $2}' | tr -d '\r' | xargs || true)
    if [ $((i % 5)) -eq 0 ]; then
      echo "  等待中 ($((i*2))s) state=${STATE:-<pending>} nodes=${NODES:-?} slots=${SLOTS:-?}"
    fi
    if [ "${STATE:-}" = "ok" ]; then
      echo
      print "${GREEN}✅ Redis Cluster 已初始化：${NODES} 节点 / ${SLOTS} slots${NC}"
      break
    fi
  else
    if [ $((i % 5)) -eq 0 ]; then
      echo "  等待中 ($((i*2))s) redis-0 Ready=false RESTARTS=${RESTARTS}"
    fi
    if [ -n "$RESTARTS" ] && [ "${LAST_RESTARTS}" -ge 0 ] && [ "$RESTARTS" -gt "$LAST_RESTARTS" ]; then
      CRASHLOOP_DETECTED=$((CRASHLOOP_DETECTED + 1))
    fi
    LAST_RESTARTS=$RESTARTS
    if [ "$CRASHLOOP_DETECTED" -ge 3 ]; then
      echo
      print "${RED}⚠️  检测到 redis-0 持续重启（CrashLoopBackOff 倾向）。${NC}"
      print "${YELLOW}诊断命令：${NC}"
      echo "    kubectl describe pod redis-0"
      echo "    kubectl logs redis-0"
      echo "    kubectl logs redis-0 --previous"
      echo "  不会中断部署流程，2 分钟内仍在等待 cluster_state=ok..."
      CRASHLOOP_DETECTED=0
    fi
  fi
  sleep 2
done

echo
echo "当前 cluster info（redis-0）："
if [ "$(kubectl get pod redis-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)" = true ]; then
  kubectl exec redis-0 -- redis-cli cluster info 2>/dev/null || true
else
  echo "  (redis-0 未 Ready，跳过 cluster info 查询。请运行 ./verify.sh 或查看 kubectl logs redis-0)"
fi

echo
print "${GREEN}部署脚本结束。下一步建议：${NC}"
echo "  ./verify.sh    # 运行 10 项自动验收"
echo "  ./cleanup.sh   # 完全清理（包括 PVC）"
