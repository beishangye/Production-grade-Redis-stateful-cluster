# Production-grade Redis Stateful Cluster（生产级 Redis 有状态集群）

基于 Kubernetes **StatefulSet** 部署的 **3 节点 Redis Cluster**，包含完整的生产级配置：持久化存储、健康探针、节点亲和/反亲和、优雅启停、自动集群初始化、灰度发布（Partition）以及一键部署 / 验证 / 清理脚本。

---

## ✨ 特性

- **Redis 7.2 Cluster**：3 主节点，16384 Slots 全分配，原生 Gossip 总线（16379）
- **StatefulSet**：稳定的 Pod 命名（redis-0/1/2）、有序启动、独立稳定 DNS
- **Headless Service**：每个 Pod 拥有可解析的稳定域名（`redis-N.redis-svc`）
- **持久化存储**：每个 Pod 独立 PVC（5Gi），AOF 持久化，Pod 重建数据不丢失
- **健康探针**：Readiness + Liveness 双探针，基于 `redis-cli PING`
- **调度策略**：
  - Pod 反亲和（必填）：3 个 Pod 分散在不同节点，避免单点故障
  - 节点亲和（优先）：优先调度到 SSD 节点
  - 容忍 Taint：可调度到带有 `gpu=true:NoSchedule` 的节点
- **优雅启停**：`preStop` 钩子在 Pod 终止前执行 `SAVE`，`terminationGracePeriodSeconds=30`
- **自动集群初始化**：`redis-0` 作为 Bootstrap 节点，等待 redis-1/2 就绪后自动 `redis-cli --cluster create`
- **灰度发布**：支持 StatefulSet RollingUpdate Partition 灰度
- **一键脚本**：`deploy.sh`（部署）、`verify.sh`（10 项自动验收）、`cleanup.sh`（清理）

---

## 📁 项目结构

```
.
├── 00-configmap.yaml         # Redis 配置模板（ConfigMap）
├── 01-headless-service.yaml  # Headless Service + NodePort
├── 02-statefulset.yaml       # 3 节点 Redis StatefulSet（核心）
├── 03-verify-pod.yaml        # 手动 DNS 验证 Pod
├── deploy.sh                 # 一键部署脚本
├── verify.sh                 # 10 项自动验收测试脚本
└── cleanup.sh                # 清理脚本
```

---

## 🚀 快速开始

### 前置条件

- Kubernetes 集群（推荐 Minikube 3 节点，或任意 K8s 1.24+）
- `kubectl` 已配置并连接集群
- 集群需配置默认 StorageClass（用于 PVC 自动绑定）

#### Minikube 快速启动（推荐）

```bash
# 启动 3 节点 Minikube
minikube start --nodes 3 --cpus 2 --memory 2g
```

---

### 一键部署

```bash
# 赋予脚本执行权限
chmod +x *.sh

# 执行一键部署
./deploy.sh
```

`deploy.sh` 会依次完成：

| 步骤 | 内容 |
|------|------|
| 1 | 节点标签与 Taint：minikube-m02 打 `disk=ssd` + `gpu=true:NoSchedule`，minikube-m03 打 `disk=hdd` |
| 2 | 删除旧 StatefulSet（保留 PVC） |
| 3 | 清理旧 Pod |
| 4 | 部署 ConfigMap + Headless Service + NodePort |
| 5 | 部署 StatefulSet（3 副本） |
| 6 | 等待 3 个 Pod Ready，然后等待 Redis Cluster 自动初始化 |

---

## ✅ 自动验收（10 项）

```bash
./verify.sh
```

`verify.sh` 包含 **10 项核心验证**，全部通过才算部署成功：

| # | 验证项 | 说明 |
|---|--------|------|
| 0 | 环境检查 | K8s API 可用、StatefulSet 存在 |
| 1 | Pod 状态 | 3 个 Pod 全部 Running + Ready |
| 2 | Pod 分散 | 3 个 Pod 调度到不同节点（反亲和生效） |
| 3 | Headless Service | `redis-svc` 的 clusterIP=None |
| 4 | PVC 绑定 | 3 个 PVC 全部 Bound |
| 5 | Readiness Probe | 正确配置 redis-cli 探针 |
| 6 | Liveness Probe | 正确配置 redis-cli 探针 |
| 7 | Redis Cluster 状态 | `cluster_state=ok`、3 节点、16384 Slots 全分配 |
| 8 | StatefulSet DNS 解析 | 临时 Pod 解析 `redis-0/1/2.redis-svc.default.svc.cluster.local` |
| 9 | 数据持久化 | 写入 KV → 删除 Pod → 等待重建 → 验证数据仍在 |
| 10 | Partition 灰度 | Patch `partition=2` → 验证只有 redis-2 更新、redis-0/1 保持旧版本 |

测试结果示例：

```
✅ PASS: 3 个 Redis Pod 全部 Running 且 Ready
✅ PASS: 3 个 Redis Pod 分散在不同节点
✅ PASS: redis-svc 是 Headless Service
✅ PASS: 3 个 Redis PVC 全部 Bound
✅ PASS: Readiness Probe 已配置
✅ PASS: Liveness Probe 已配置
✅ PASS: Redis Cluster 正常：3 节点、16384 slots、cluster_state=ok
✅ PASS: redis-0/1/2 StatefulSet DNS 均可解析
✅ PASS: Redis 数据持久化成功
✅ PASS: Partition=2 生效：只有 redis-2 更新

PASS: 10
FAIL: 0
WARN: 0
🎉 所有核心测试通过！
```

---

## 🧪 常用操作

### 查看集群状态

```bash
# 查看 Pod
kubectl get pods -l app=redis -o wide

# 查看 PVC
kubectl get pvc -l app=redis

# 查看 Service
kubectl get svc -l app=redis

# 查看 StatefulSet
kubectl get sts redis -o wide
```

### 查看 Redis Cluster 信息

```bash
# Cluster 总览
kubectl exec redis-0 -- redis-cli cluster info

# 节点详情
kubectl exec redis-0 -- redis-cli cluster nodes
```

### 数据读写测试

```bash
# 写入（-c 表示 Cluster 模式，自动跳转正确的 Slot 节点）
kubectl exec redis-0 -- redis-cli -c set hello world

# 从任意节点读取（Cluster 模式自动转发）
kubectl exec redis-1 -- redis-cli -c get hello
```

### 手动 DNS 验证

```bash
kubectl apply -f 03-verify-pod.yaml
kubectl logs redis-verify
```

### 恢复 Partition 为正常全量滚动

`verify.sh` 的 Partition 测试会保留 `partition=2`，恢复为正常全量更新：

```bash
kubectl patch sts redis -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
```

---

## 🧹 清理

```bash
./cleanup.sh
```

会删除：
- `redis-verify` Pod
- StatefulSet `redis`
- Service `redis-svc`、`redis-nodeport`
- ConfigMap `redis-conf`
- 所有带 `app=redis` 标签的 PVC（⚠️ **数据会丢失**）
- 节点上的标签和 Taint

---

## 🔧 核心配置详解

### Redis 配置（00-configmap.yaml）

| 参数 | 值 | 说明 |
|------|----|------|
| `cluster-enabled` | yes | 启用 Cluster 模式 |
| `cluster-node-timeout` | 5000 | 节点超时 5s |
| `cluster-announce-ip` | `${POD_IP}` | 动态替换为 Pod IP（启动脚本 sed 替换） |
| `appendonly` | yes | 开启 AOF 持久化 |
| `appendfsync` | everysec | 每秒 fsync（性能与安全折中） |
| `maxmemory` | 256mb | 内存上限 |
| `maxmemory-policy` | allkeys-lru | 超限时 LRU 淘汰所有 key |
| `protected-mode` | no | 允许外部访问（生产建议改为 yes + 密码） |

### StatefulSet 关键配置（02-statefulset.yaml）

**Pod 反亲和（required）**：强制 3 个 Pod 不在同一节点
```yaml
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
          - key: app
            operator: In
            values: [redis]
      topologyKey: kubernetes.io/hostname
```

**资源限制**：
```yaml
requests: memory=256Mi, cpu=200m
limits:   memory=512Mi, cpu=500m
```

**优雅终止钩子**：
```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "redis-cli save 2>/dev/null || true; sleep 5"]
```

---

## 🔒 生产建议

本项目用于**学习和实验**，生产环境建议额外补充：

1. **Redis 密码**：`requirepass` + `masterauth`，存入 Secret 而非 ConfigMap
2. **主从副本**：当前是 3 主 0 从，生产建议 `--cluster-replicas 1`（3 主 3 从共 6 节点）
3. **TLS 加密**：启用 `tls-port`，证书通过 Secret 挂载
4. **备份策略**：定期 `redis-cli --cluster backup` 或 VolumeSnapshot
5. **监控告警**：Prometheus + redis_exporter，监控 `connected_clients`、`used_memory`、`cluster_state` 等
6. **PodDisruptionBudget**：保证升级/维护时最小可用副本数
7. **NetworkPolicy**：限制只有指定命名空间的 Service 可访问 6379

---

## 📄 License

MIT
