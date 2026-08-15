# Screenshots Placeholder

将部署后的截图放到本目录，文件名对应下方描述。推荐 PNG 格式，宽度 ~1200px 最佳。

| 文件名 | 截图内容 | 优先级 | 参考命令 |
|--------|----------|--------|----------|
| `01-verify-all-pass.png` | `./verify.sh` 完整输出，重点展示 10 个 `✅ PASS` + 汇总 `PASS:10 FAIL:0` + 最下方的 `🎉 所有核心测试通过！` | 🥇 最高 | `./verify.sh` |
| `02-pods-pvc-cluster.png` | 三条命令连续执行的输出：<br>1. `kubectl get pods -l app=redis -o wide` — NODE 列 3 个值各不相同<br>2. `kubectl get pvc -l app=redis` — 3 个 Bound<br>3. `kubectl exec redis-0 -- redis-cli cluster info` — cluster_state:ok / known_nodes:3 / slots_assigned:16384 | 🥇 最高 | 依次执行三条 |
| `03-deploy-progress.png` | `./deploy.sh` 的 6 步彩色输出，到 `[6/6] 等待 3 个 Pod...` + 最后 `🎉 部署完成` + `kubectl get pods` 列表 | 🥈 高 | `./deploy.sh` |
| `04-persistence-test.png` | 数据持久化测试输出：<br>1. `kubectl exec redis-0 -- redis-cli -c set foo bar` → OK<br>2. `kubectl delete pod redis-0` <br>3. 等待 Ready 后 `kubectl exec redis-0 -- redis-cli -c get foo` → bar | 🥈 高 | verify.sh 第 9 项或手动跑 |
| `05-partition-canary.png` | Partition 灰度结果：<br>verify.sh 第 10 项输出，`redis-0 revision = xxx`、`redis-1 revision = xxx`、`redis-2 revision = yyy`，显示 0 和 1 相同、2 不同（只有 2 更新了） | 🥉 中 | verify.sh 第 10 项 |
| `06-cluster-nodes.png` | `kubectl exec redis-0 -- redis-cli cluster nodes` 的输出，3 行 master + slots 范围分布 | 🥉 中 | `kubectl exec redis-0 -- redis-cli cluster nodes` |

> 💡 进阶加分项：录一个 `deploy.sh → verify.sh` 的终端 GIF（30-60 秒），存为 `demo.gif`，替换 README 最上方的静态图。推荐工具：Windows 下用 [ScreenToGif](https://www.screentogif.com/) 或 [LICEcap](https://www.cockos.com/licecap/)；Mac 下用 [Kap](https://getkap.co/)。
