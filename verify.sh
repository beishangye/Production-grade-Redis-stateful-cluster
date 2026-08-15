#!/bin/bash
set -uo pipefail

NAMESPACE="default"
STS_NAME="redis"
SERVICE_NAME="redis-svc"
APP_LABEL="app=redis"
POD0="redis-0"
POD1="redis-1"
POD2="redis-2"
PASS=0
FAIL=0
WARN=0
TEST_KEY="qos_test_$(date +%s)"
TEST_VALUE="redis_persistence_test_$(date +%s)"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
pass(){ echo -e "${GREEN}✅ PASS: $1${NC}"; PASS=$((PASS+1)); }
fail(){ echo -e "${RED}❌ FAIL: $1${NC}"; FAIL=$((FAIL+1)); }
warn(){ echo -e "${YELLOW}⚠️  WARN: $1${NC}"; WARN=$((WARN+1)); }
title(){ echo; echo '============================================================'; echo "$1"; echo '============================================================'; }

trap 'kubectl delete pod redis-dns-test-$BASHPID --ignore-not-found=true >/dev/null 2>&1 || true' EXIT

title '[0/10] 环境检查'
kubectl cluster-info >/dev/null 2>&1 || { fail 'Kubernetes API 不可用'; exit 1; }
kubectl get sts "$STS_NAME" >/dev/null 2>&1 || { fail 'StatefulSet redis 不存在'; exit 1; }
echo 'Kubernetes API 正常'
echo 'StatefulSet redis 存在'

# 1 Pod

title '[1/10] Pod 全部 Running / Ready'
POD_COUNT=$(kubectl get pods -l "$APP_LABEL" --no-headers 2>/dev/null | wc -l)
echo "    当前 Pod 数量: $POD_COUNT"
ALL_READY=true
for p in "$POD0" "$POD1" "$POD2"; do
  S=$(kubectl get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  R=$(kubectl get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  echo "    $p -> STATUS=$S READY=$R"
  [ "$S" = Running ] && [ "$R" = true ] || ALL_READY=false
done
[ "$POD_COUNT" -eq 3 ] && [ "$ALL_READY" = true ] && pass '3 个 Redis Pod 全部 Running 且 Ready' || fail 'Redis Pod 未全部 Running/Ready'

# 2 spread

title '[2/10] Pod 分散部署'
N0=$(kubectl get pod "$POD0" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
N1=$(kubectl get pod "$POD1" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
N2=$(kubectl get pod "$POD2" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
echo "    $POD0 -> $N0"
echo "    $POD1 -> $N1"
echo "    $POD2 -> $N2"
[ -n "$N0" ] && [ "$N0" != "$N1" ] && [ "$N0" != "$N2" ] && [ "$N1" != "$N2" ] && pass '3 个 Redis Pod 分散在不同节点' || fail 'Redis Pod 没有分散到不同节点'

# 3 headless

title '[3/10] Headless Service'
CIP=$(kubectl get svc "$SERVICE_NAME" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
echo "    redis-svc clusterIP = ${CIP:-<none>}"
[ "$CIP" = None ] && pass 'redis-svc 是 Headless Service' || fail 'redis-svc 不是 Headless Service'

# 4 PVC

title '[4/10] PVC 已绑定'
TOTAL=$(kubectl get pvc -l "$APP_LABEL" --no-headers 2>/dev/null | wc -l)
BOUND=$(kubectl get pvc -l "$APP_LABEL" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c '^Bound$' || true)
echo "    PVC 总数: $TOTAL"
echo "    Bound 数量: $BOUND"
kubectl get pvc -l "$APP_LABEL" || true
[ "$TOTAL" -eq 3 ] && [ "$BOUND" -eq 3 ] && pass '3 个 Redis PVC 全部 Bound' || fail 'PVC 没有全部 Bound'

# 5 readiness

title '[5/10] Readiness Probe'
RP=$(kubectl get pod "$POD0" -o jsonpath='{.spec.containers[0].readinessProbe.exec.command}' 2>/dev/null || true)
echo "    redis-0 Readiness Probe: $RP"
echo "$RP" | grep -q redis-cli && pass 'Readiness Probe 已配置' || fail '没有正确检测到 Readiness Probe'

# 6 liveness

title '[6/10] Liveness Probe'
LP=$(kubectl get pod "$POD0" -o jsonpath='{.spec.containers[0].livenessProbe.exec.command}' 2>/dev/null || true)
echo "    redis-0 Liveness Probe: $LP"
echo "$LP" | grep -q redis-cli && pass 'Liveness Probe 已配置' || fail '没有正确检测到 Liveness Probe'

# 7 cluster

title '[7/10] Redis Cluster 状态'
CI=$(kubectl exec "$POD0" -- redis-cli cluster info 2>/dev/null || true)
echo "$CI"
STATE=$(echo "$CI" | awk -F: '/^cluster_state:/ {print $2}' | tr -d '\r' | xargs)
NODES=$(echo "$CI" | awk -F: '/^cluster_known_nodes:/ {print $2}' | tr -d '\r' | xargs)
SLOTS=$(echo "$CI" | awk -F: '/^cluster_slots_assigned:/ {print $2}' | tr -d '\r' | xargs)
SIZE=$(echo "$CI" | awk -F: '/^cluster_size:/ {print $2}' | tr -d '\r' | xargs)
if [ "$STATE" = ok ] && [ "$NODES" = 3 ] && [ "$SLOTS" = 16384 ] && [ "$SIZE" = 3 ]; then
  pass 'Redis Cluster 正常：3 节点、16384 slots、cluster_state=ok'
else
  fail 'Redis Cluster 状态异常'
fi
echo; echo 'Cluster Nodes:'; kubectl exec "$POD0" -- redis-cli cluster nodes 2>/dev/null || true

# 8 DNS

# ============================================================
# [8/10] StatefulSet DNS 解析
# ============================================================

title '[8/10] StatefulSet DNS 解析'

DNSPOD="redis-dns-test-$BASHPID"

info "创建临时 DNS 测试 Pod..."

kubectl run "$DNSPOD" \
  --image=busybox:1.36 \
  --restart=Never \
  --command -- \
  sh -c '
    set -e

    echo "============================================"
    echo "Redis StatefulSet DNS Test"
    echo "============================================"

    echo
    echo "[1/3] redis-0"
    nslookup redis-0.redis-svc.default.svc.cluster.local

    echo
    echo "[2/3] redis-1"
    nslookup redis-1.redis-svc.default.svc.cluster.local

    echo
    echo "[3/3] redis-2"
    nslookup redis-2.redis-svc.default.svc.cluster.local

    echo
    echo "DNS_TEST_SUCCESS"
  ' >/dev/null 2>&1

CREATE_RC=$?

if [ "$CREATE_RC" -ne 0 ]; then
    fail "DNS 测试 Pod 创建失败"

else

    # 等待测试 Pod 完成
    if kubectl wait \
      --for=jsonpath='{.status.phase}'=Succeeded \
      "pod/$DNSPOD" \
      --timeout=60s >/dev/null 2>&1; then

        DNSLOG=$(kubectl logs "$DNSPOD" 2>/dev/null || true)

        echo
        echo "$DNSLOG"

        # 不再统计 Address/Name 的文本数量
        # 直接检查测试程序是否明确返回成功标记
        if echo "$DNSLOG" | grep -q "DNS_TEST_SUCCESS"; then

            pass 'redis-0/1/2 StatefulSet DNS 均可解析'

        else

            fail 'StatefulSet DNS 解析失败'

        fi

    else

        echo
        yellow "DNS 测试 Pod 状态："
        kubectl get pod "$DNSPOD" -o wide 2>/dev/null || true

        echo
        yellow "DNS 测试 Pod 日志："
        kubectl logs "$DNSPOD" 2>/dev/null || true

        fail 'DNS 测试 Pod 未能正常完成'

    fi
fi

# 清理测试 Pod
kubectl delete pod "$DNSPOD" \
  --ignore-not-found=true \
  >/dev/null 2>&1 || true

# 9 persistence

title '[9/10] 数据持久化'
SET=$(kubectl exec "$POD0" -- redis-cli -c set "$TEST_KEY" "$TEST_VALUE" 2>/dev/null || true)
echo "    写入结果: $SET"
if [ "$SET" != OK ]; then
  fail 'Redis 写入测试失败'
else
  BEFORE=$(kubectl exec "$POD0" -- redis-cli -c get "$TEST_KEY" 2>/dev/null || true)
  echo "    删除 Pod 前读取: $BEFORE"
  kubectl delete pod "$POD0" --wait=false >/dev/null 2>&1 || true
  if kubectl wait --for=condition=Ready "pod/$POD0" --timeout=180s >/dev/null 2>&1; then
    sleep 5
    AFTER=$(kubectl exec "$POD0" -- redis-cli -c get "$TEST_KEY" 2>/dev/null || true)
    echo "    Pod 重建后读取: $AFTER"
    [ "$AFTER" = "$TEST_VALUE" ] && pass 'Redis 数据持久化成功' || fail 'Pod 重建后数据丢失'
  else
    fail 'redis-0 删除后没有恢复 Ready'
  fi
fi

# 10 partition

title '[10/10] Partition 灰度发布'
OLD_UPDATE=$(kubectl get sts "$STS_NAME" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)
OLD0=$(kubectl get pod "$POD0" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
OLD1=$(kubectl get pod "$POD1" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
TOKEN="partition-test-$(date +%s)"
kubectl patch sts "$STS_NAME" --type=merge -p "{\"spec\":{\"updateStrategy\":{\"type\":\"RollingUpdate\",\"rollingUpdate\":{\"partition\":2}},\"template\":{\"metadata\":{\"annotations\":{\"qos-test-partition\":\"$TOKEN\"}}}}}" >/dev/null 2>&1
NEW_UPDATE=""
for _ in $(seq 1 60); do
  NEW_UPDATE=$(kubectl get sts "$STS_NAME" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)
  [ -n "$NEW_UPDATE" ] && [ "$NEW_UPDATE" != "$OLD_UPDATE" ] && break
  sleep 1
done
for _ in $(seq 1 120); do
  P2R=$(kubectl get pod "$POD2" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
  P2READY=$(kubectl get pod "$POD2" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  [ "$P2R" = "$NEW_UPDATE" ] && [ "$P2READY" = true ] && break
  sleep 1
done
CUR0=$(kubectl get pod "$POD0" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
CUR1=$(kubectl get pod "$POD1" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
CUR2=$(kubectl get pod "$POD2" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
echo "    redis-0 revision = $CUR0"
echo "    redis-1 revision = $CUR1"
echo "    redis-2 revision = $CUR2"
if [ "$CUR0" = "$OLD0" ] && [ "$CUR1" = "$OLD1" ] && [ "$CUR2" = "$NEW_UPDATE" ]; then
  pass 'Partition=2 生效：只有 redis-2 更新'
else
  fail 'Partition 灰度验证失败'
fi

title '最终状态'
kubectl get pods -l app=redis -o wide
echo; kubectl get pvc -l app=redis
echo; kubectl get svc -l app=redis
echo; kubectl get sts redis
echo "Partition: $(kubectl get sts redis -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}' 2>/dev/null)"

title '测试结果汇总'
echo -e "${GREEN}PASS: $PASS${NC}"
echo -e "${RED}FAIL: $FAIL${NC}"
echo -e "${YELLOW}WARN: $WARN${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}🎉 所有核心测试通过！${NC}"
else
  echo -e "${RED}⚠️ 有 $FAIL 项测试失败。${NC}"
fi
exit "$FAIL"
