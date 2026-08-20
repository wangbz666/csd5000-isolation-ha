# CSD5000 双端口隔离配置工具

ScaleFlux CSD5000 双端口 NVMe 在**隔离模式**下的 namespace 划分脚本（Bash）。

- **脚本**：[`csd5000.sh`](csd5000.sh)
- **详细手册**：[`CSD5000_csd5000.sh使用手册.md`](CSD5000_csd5000.sh使用手册.md)（飞书/运维可直接复制）

在 **Port0 节点**上运行，需能 SSH 免密登录同 JBOF 的 Port1 节点。

## 三条功能

| 命令 | 作用 |
|------|------|
| `list` | 显示所有可操作的配对盘 |
| `split-all` / `split-one` | 对半独享（50/50） |
| `own-p0` / `own-p1` | 单盘整盘仅给一边 |

## 用法

```bash
# 1. 查看（只读）
./csd5000.sh list --port0 192.168.255.96 --port1 192.168.255.98

# 2. 全部盘对半（会删数据）
./csd5000.sh split-all --port0 192.168.255.96 --port1 192.168.255.98 --confirm

# 3. 单盘对半
./csd5000.sh split-one --port0 192.168.255.96 --port1 192.168.255.98 \
  --sn SF2451C0598H --confirm

# 4. 单盘整盘仅 Port0
./csd5000.sh own-p0 --port0 192.168.255.96 --port1 192.168.255.98 \
  --sn SF2525C8202H --confirm

# 5. 单盘整盘仅 Port1
./csd5000.sh own-p1 --port0 192.168.255.96 --port1 192.168.255.98 \
  --sn SF2539C1626H --confirm

# 6. 演练（不写入）
./csd5000.sh split-one ... --sn SFxxx --dry-run
```

## 首次准备（只需一次）

```bash
# 在 .96 上配置到 .98 的免密 SSH
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
ssh-copy-id root@192.168.255.98
```

## 已在 .96/.98 验证

盘 **SF2451C0598H** 对半配置成功：

- `.96` → `/dev/nvme2n1` **3.84TB**
- `.98` → `/dev/nvme7n1` **3.84TB**

## 旧脚本报错原因

1. **容量算错**：SOP 固定 `7501476528×2` 超过整盘 → Port1 报 `NS_INSUFFICIENT_CAPACITY`
2. **解析 bug**：`Port #0` 带空格导致 bash 算术报错
3. **新脚本**：自动 `tnvmcap/512` 对半，保证两半之和=整盘

## 注意

- `--confirm` 会删除 namespace，**数据不可恢复**
- **写操作前必须先 umount** 目标盘；脚本会自动检测挂载/占用，未卸载则拒绝执行
- 必须配对正确：`--port0 .96 --port1 .98`（同 JBOF 机箱）
- 配置后各节点自行 `mkfs` + `mount`
