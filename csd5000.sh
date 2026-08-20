#!/usr/bin/env bash
# CSD5000 双端口隔离配置（简化版 v2）
set -euo pipefail

PORT0="" PORT1="" SSH_USER="${SSH_USER:-root}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=15}"
CONFIRM=0 DRY_RUN=0 DISK_SN=""

log(){ echo "[$(date '+%H:%M:%S')] $*"; }
die(){ log "ERROR: $*"; exit 1; }
need_confirm(){ [[ "$CONFIRM" -eq 1 || "$DRY_RUN" -eq 1 ]] || die "请加 --confirm 或 --dry-run"; }
ssh0(){ ssh ${SSH_OPTS} "${SSH_USER}@${PORT0}" "$@"; }
ssh1(){ ssh ${SSH_OPTS} "${SSH_USER}@${PORT1}" "$@"; }

# 远端扫描，输出: SN|ctrl|cntlid|port|tnvmcap|blockdev
scan_host(){
  local h="$1"
  ssh ${SSH_OPTS} "${SSH_USER}@${h}" python3 <<'PY'
import subprocess,re,os,glob
for c in sorted(glob.glob("/dev/nvme[0-9]*")):
    if not re.match(r"/dev/nvme\d+$", c): continue
    idc=subprocess.getoutput("nvme id-ctrl %s 2>/dev/null" % c)
    if "ScaleFlux" not in idc: continue
    sn=re.search(r"^sn\s*:\s*(\S+)", idc, re.M)
    cid=re.search(r"^cntlid\s*:\s*(\S+)", idc, re.M)
    cap=re.search(r"^tnvmcap\s*:\s*(\d+)", idc, re.M)
    if not sn: continue
    pci=os.path.basename(subprocess.getoutput("readlink -f /sys/class/nvme/%s/device" % os.path.basename(c)))
    lnk=subprocess.getoutput("lspci -s %s -vvv 2>/dev/null | grep LnkCap | head -1" % pci)
    port="P0" if "Port #0" in lnk else ("P1" if "Port #1" in lnk else "?")
    blk=""
    cap_str=""
    for ln in subprocess.getoutput("nvme list 2>/dev/null").splitlines():
        if not ln.startswith("/dev/nvme") or sn.group(1) not in ln:
            continue
        parts = ln.split()
        if len(parts) >= 8:
            blk = parts[0]
            # 格式: ... 0.00 B / 3.84 TB → 取 "3.84TB"
            for i, p in enumerate(parts):
                if p in ("TB", "GB", "MB") and i > 0:
                    cap_str = parts[i-1] + p
                    break
            blk = blk + "(" + (cap_str or "?") + ")"
        break
    print("|".join([sn.group(1), c, cid.group(1) if cid else "", port, cap.group(1) if cap else "0", blk]))
PY
}

cmd_list(){
  log "Port0=${PORT0}  Port1=${PORT1}"
  log "======== 可操作 ScaleFlux 盘 ========"
  printf "%-16s %-10s %-10s %-8s %-14s %-14s %s\n" "SN" "P0_CTRL" "P1_CTRL" "TOTAL" "P0_NS" "P1_NS" "状态"
  local p0 p1; p0="$(scan_host "$PORT0")"; p1="$(scan_host "$PORT1")"
  declare -A A0 A1 C0 C1 B0 B1
  while IFS='|' read -r sn c _ p cap b; do [[ -n "$sn" ]] && { A0[$sn]=$c; C0[$sn]=$cap; B0[$sn]=$b; }; done <<< "$p0"
  while IFS='|' read -r sn c _ p cap b; do [[ -n "$sn" ]] && { A1[$sn]=$c; C1[$sn]=$cap; B1[$sn]=$b; }; done <<< "$p1"
  local n=0 sn
  for sn in $(printf '%s\n' "${!A0[@]}" | sort); do
    [[ -n "${A1[$sn]+x}" ]] || continue
    n=$((n+1))
    local cap="${C0[$sn]:-${C1[$sn]}}"
    local tb="?"; [[ "$cap" =~ ^[0-9]+$ ]] && tb="$(awk "BEGIN{printf \"%.2fTB\", $cap/1e12}")"
    local st="可配置"
    [[ -n "${B0[$sn]}" && -n "${B1[$sn]}" ]] && st="已对半(50/50)"
    [[ -n "${B0[$sn]}" && -z "${B1[$sn]}" ]] && st="仅P0有NS"
    [[ -z "${B0[$sn]}" && -n "${B1[$sn]}" ]] && st="仅P1有NS"
    printf "%-16s %-10s %-10s %-8s %-14s %-14s %s\n" "$sn" "${A0[$sn]}" "${A1[$sn]}" "$tb" "${B0[$sn]:--}" "${B1[$sn]:--}" "$st"
  done
  log "共 ${n} 块盘"
  log "说明: P0_NS 在 --port0 节点上, P1_NS 在 --port1 节点上 (隔离模式各看各的)"
}

lookup(){
  local sn="$1" line0 line1
  line0="$(scan_host "$PORT0" | grep "^${sn}|" || true)"
  line1="$(scan_host "$PORT1" | grep "^${sn}|" || true)"
  [[ -n "$line0" && -n "$line1" ]] || die "SN ${sn} 未在两侧同时找到"
  IFS='|' read -r _ P0_CTRL P0_CID _ P0_CAP _ <<< "$line0"
  IFS='|' read -r _ P1_CTRL P1_CID _ P1_CAP _ <<< "$line1"
  DISK_CAP="${P0_CAP:-$P1_CAP}"
  [[ "$DISK_CAP" =~ ^[0-9]+$ && "$DISK_CAP" -gt 0 ]] || die "${sn} 容量无效: ${DISK_CAP}"
  DISK_SEC=$(( DISK_CAP / 512 ))
}

# 写操作前检查：namespace 块设备不得挂载或被进程占用
check_ctrl_idle(){
  local host="$1" ctrl="$2" label="$3"
  local busy
  busy="$(ssh ${SSH_OPTS} "${SSH_USER}@${host}" python3 - "$ctrl" <<'PY'
import glob, os, subprocess, sys
ctrl = sys.argv[1]
busy = []
for nd in sorted(glob.glob(ctrl + "n*")):
    if not os.path.exists(nd):
        continue
    mp = subprocess.getoutput("findmnt -n -o TARGET %s 2>/dev/null" % nd).strip()
    if mp:
        busy.append("%s 已挂载于 %s" % (nd, mp))
        continue
    if subprocess.call("fuser -s %s" % nd, shell=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
        busy.append("%s 正被进程占用 (fuser %s)" % (nd, nd))
if busy:
    print("\n".join(busy))
PY
)"
  [[ -z "$busy" ]] || die "${label} (${host}) 块设备仍在使用，请先 umount / 停业务后再执行:\\n${busy}"
}

check_sn_idle(){
  local sn="$1"
  lookup "$sn"
  check_ctrl_idle "$PORT0" "$P0_CTRL" "Port0"
  check_ctrl_idle "$PORT1" "$P1_CTRL" "Port1"
}

do_action(){
  local host="$1" act="$2" ctrl="$3" cid="$4" nsid="$5" sec="$6"
  ssh ${SSH_OPTS} "${SSH_USER}@${host}" python3 - "$act" "$ctrl" "$cid" "$nsid" "$sec" "$DRY_RUN" <<'PY'
import glob,subprocess,sys,os
act,ctrl,cid,nsid,sec,dry=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],int(sys.argv[5]),sys.argv[6]
flbaf=0
def run(c, must_ok=True, timeout=30):
    print("+",c)
    if dry=="1":
        return
    try:
        subprocess.run(c, shell=True, check=must_ok, timeout=timeout)
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: 命令超时 (%ds): %s\\n" % (timeout, c))
        if must_ok:
            sys.exit(124)
    except subprocess.CalledProcessError as e:
        if must_ok:
            raise
def reset_ctrl(ctrl):
    print("+ timeout 20 nvme reset "+ctrl+" (失败不中断)")
    if dry=="1":
        return
    subprocess.run("timeout 20 nvme reset "+ctrl, shell=True)
def ns_in_use(nd):
    mp=subprocess.getoutput("findmnt -n -o TARGET %s 2>/dev/null" % nd).strip()
    if mp:
        return "已挂载于 %s" % mp
    if subprocess.call("fuser -s %s" % nd, shell=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
        return "正被进程占用"
    return ""
def delete_ns(nd):
    why=ns_in_use(nd)
    if why:
        sys.stderr.write("ERROR: %s %s，拒绝 delete-ns\\n" % (nd, why))
        sys.exit(2)
    cmd="timeout 30 nvme delete-ns "+nd
    print("+",cmd)
    if dry=="1":
        return
    try:
        rc=subprocess.run(cmd, shell=True, timeout=35).returncode
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: delete-ns %s 超时。请检查对端节点或做 Slot 下电恢复\\n" % nd)
        sys.exit(124)
    if rc!=0:
        sys.stderr.write("ERROR: delete-ns %s 失败 (exit %d)。若已挂载请先 umount\\n" % (nd, rc))
        sys.exit(rc)
for nd in glob.glob(ctrl+"n*"):
    if os.path.exists(nd): delete_ns(nd)
if act=="noop": sys.exit(0)
if act in ("p0","own0"):
    run("nvme create-ns -s %d -c %d -f %d %s" % (sec,sec,flbaf,ctrl))
    run("nvme attach-ns -n %s -c %s %s" % (nsid,cid,ctrl))
    reset_ctrl(ctrl)
elif act=="p1":
    run("nvme create-ns -s %d -c %d -f %d %s" % (sec,sec,flbaf,ctrl))
    run("nvme attach-ns -n 2 -c %s %s" % (cid,ctrl))
    reset_ctrl(ctrl)
elif act=="own1":
    run("nvme create-ns -s %d -c %d -f %d %s" % (sec,sec,flbaf,ctrl))
    run("nvme attach-ns -n 1 -c %s %s" % (cid,ctrl))
    reset_ctrl(ctrl)
print("OK")
PY
}

wipe_both(){
  local sn="$1"
  check_sn_idle "$sn"
  do_action "$PORT0" noop "$P0_CTRL" "$P0_CID" 1 0
  do_action "$PORT1" noop "$P1_CTRL" "$P1_CID" 2 0
}

# 整盘归属迁移：两侧先强制 detach，再只 attach 到目标端（不 delete / 不 reset）
# 修复点：
# 1) 旧逻辑只按 list-ns 从源端 detach，固件残留 attach 会导致对端 I/O Access Denied(sc=0x15)
# 2) exists(/dev/nvmeXn1) 会把残留普通文件误判为成功
# 3) 缺少小块 I/O 探测，mkfs 前才暴露问题
move_own(){
  local sn="$1" dest="$2"   # dest=p0|p1
  check_sn_idle "$sn"
  local src_host src_ctrl src_cid dst_host dst_ctrl dst_cid
  if [[ "$dest" == "p1" ]]; then
    src_host="$PORT0"; src_ctrl="$P0_CTRL"; src_cid="$P0_CID"
    dst_host="$PORT1"; dst_ctrl="$P1_CTRL"; dst_cid="$P1_CID"
    log "${sn}: 整盘迁移到 Port1（双侧 detach → 仅 P1 attach）"
  else
    src_host="$PORT1"; src_ctrl="$P1_CTRL"; src_cid="$P1_CID"
    dst_host="$PORT0"; dst_ctrl="$P0_CTRL"; dst_cid="$P0_CID"
    log "${sn}: 整盘迁移到 Port0（双侧 detach → 仅 P0 attach）"
  fi

  # Step A: 两侧都对 NS 做 detach（忽略 NOT_ATTACHED），清掉固件残留
  local h c cid
  for h in "$src_host" "$dst_host"; do
    if [[ "$h" == "$PORT0" ]]; then c="$P0_CTRL"; cid="$P0_CID"; else c="$P1_CTRL"; cid="$P1_CID"; fi
    log "detach on ${h} ctrl=${c} cid=${cid}"
    ssh ${SSH_OPTS} "${SSH_USER}@${h}" python3 - "$c" "$cid" "$DRY_RUN" <<'PY'
import os, stat, subprocess, sys
ctrl, cid, dry = sys.argv[1], sys.argv[2], sys.argv[3]

def run_cap(cmd, timeout=15):
    print("+", cmd)
    if dry == "1":
        return 0, ""
    try:
        p = subprocess.run(cmd, shell=True, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True)
        out = p.stdout or ""
        if out.strip():
            print(out.rstrip())
        return p.returncode, out
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: 超时: %s\n" % cmd)
        sys.exit(124)

def parse_nsids(text):
    ids = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        ns = line.split(":")[-1].strip()
        if ns.startswith("0x"):
            ns = str(int(ns, 16))
        if ns.isdigit() and ns not in ids:
            ids.append(ns)
    return ids

for nd in (ctrl + "n1", ctrl + "n2"):
    if os.path.exists(nd) and not stat.S_ISBLK(os.stat(nd).st_mode):
        print("+ rm stale non-block", nd)
        if dry != "1":
            os.remove(nd)

nsids = set(parse_nsids(subprocess.getoutput("nvme list-ns %s 2>/dev/null" % ctrl)))
nsids.update(parse_nsids(subprocess.getoutput("nvme list-ns -a %s 2>/dev/null" % ctrl)))
if not nsids:
    nsids.add("1")

for ns in sorted(nsids, key=lambda x: int(x)):
    blk = "%sn%s" % (ctrl, ns)
    mp = subprocess.getoutput("findmnt -n -o TARGET %s 2>/dev/null" % blk).strip()
    if mp:
        sys.stderr.write("ERROR: %s 已挂载于 %s，拒绝 detach\n" % (blk, mp))
        sys.exit(2)
    rc, out = run_cap("timeout 15 nvme detach-ns -n %s -c %s %s" % (ns, cid, ctrl))
    if rc == 0 or "NOT_ATTACHED" in out or "not attached" in out.lower():
        continue
    sys.stderr.write("ERROR: detach-ns nsid=%s 失败 exit=%d\n" % (ns, rc))
    sys.exit(rc or 1)

att = subprocess.getoutput("nvme list-ns %s 2>/dev/null" % ctrl).strip()
if dry != "1" and att:
    sys.stderr.write("ERROR: detach 后 %s 仍有 attached NS:\n%s\n" % (ctrl, att))
    sys.exit(6)
print("OK detach-side", ctrl)
PY
  done

  # Step B: 只 attach 到目标端
  log "attach on ${dst_host} ctrl=${dst_ctrl} cid=${dst_cid}"
  ssh ${SSH_OPTS} "${SSH_USER}@${dst_host}" python3 - "$dst_ctrl" "$dst_cid" "$DISK_SEC" "$DRY_RUN" <<'PY'
import os, stat, subprocess, sys, time
ctrl, cid, sec, dry = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

def run_cap(cmd, timeout=15):
    print("+", cmd)
    if dry == "1":
        return 0, ""
    try:
        p = subprocess.run(cmd, shell=True, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True)
        out = p.stdout or ""
        if out.strip():
            print(out.rstrip())
        return p.returncode, out
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: 超时: %s\n" % cmd)
        sys.exit(124)

def parse_nsids(text):
    ids = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        ns = line.split(":")[-1].strip()
        if ns.startswith("0x"):
            ns = str(int(ns, 16))
        if ns.isdigit() and ns not in ids:
            ids.append(ns)
    return ids

def is_blk(path):
    return os.path.exists(path) and stat.S_ISBLK(os.stat(path).st_mode)

for nd in (ctrl + "n1", ctrl + "n2"):
    if os.path.exists(nd) and not is_blk(nd):
        print("+ rm stale non-block", nd)
        if dry != "1":
            os.remove(nd)

alloc = parse_nsids(subprocess.getoutput("nvme list-ns -a %s 2>/dev/null" % ctrl))
nsid = alloc[0] if alloc else None
if nsid:
    rc, out = run_cap("timeout 15 nvme attach-ns -n %s -c %s %s" % (nsid, cid, ctrl))
    if rc != 0 and "ALREADY_ATTACHED" not in out:
        sys.stderr.write("ERROR: attach-ns 失败\n")
        sys.exit(rc or 1)
else:
    rc, _ = run_cap("timeout 20 nvme create-ns -s %d -c %d -f 0 %s" % (sec, sec, ctrl), timeout=25)
    if rc != 0:
        sys.exit(rc or 1)
    rc, out = run_cap("timeout 15 nvme attach-ns -n 1 -c %s %s" % (cid, ctrl))
    if rc != 0 and "ALREADY_ATTACHED" not in out:
        sys.exit(rc or 1)

run_cap("timeout 10 nvme ns-rescan %s" % ctrl, timeout=12)
time.sleep(1)
blk = ctrl + "n1"
if dry != "1":
    for _ in range(20):
        if is_blk(blk):
            break
        time.sleep(0.3)
    if not is_blk(blk):
        sys.stderr.write("ERROR: attach 后未出现块设备 %s\n" % blk)
        sys.exit(1)
    # I/O 探测：对端残留 attach 时常见 sc=0x15 Access Denied
    rc, out = run_cap("timeout 8 dd if=/dev/zero of=%s bs=4096 count=1 oflag=direct" % blk, timeout=10)
    if rc != 0:
        sys.stderr.write("ERROR: 块设备存在但 I/O 失败。常见原因：对端端口仍残留 attach (NVMe Access Denied)。\n")
        sys.stderr.write("请在对端执行: nvme list-ns <ctrl> 应为空，然后重跑 own-p*。\n")
        sys.exit(5)
print("OK attach", blk if dry != "1" else "(dry-run)")
PY

  # Step C: 源端 attached 必须为空
  log "验收：源端不应再有 attached NS"
  ssh ${SSH_OPTS} "${SSH_USER}@${src_host}" python3 - "$src_ctrl" "$DRY_RUN" <<'PY'
import subprocess, sys
ctrl, dry = sys.argv[1], sys.argv[2]
if dry == "1":
    print("OK source check skipped (dry-run)")
    sys.exit(0)
att = subprocess.getoutput("nvme list-ns %s 2>/dev/null" % ctrl).strip()
if att:
    sys.stderr.write("ERROR: 源端 %s 仍有 attached NS:\n%s\n" % (ctrl, att))
    sys.exit(6)
print("OK source detached", ctrl)
PY
  verify_one "$sn"
}

own_p0(){ local sn="$1"; lookup "$sn"; move_own "$sn" p0; }
own_p1(){ local sn="$1"; lookup "$sn"; move_own "$sn" p1; }

split_one(){
  local sn="$1" h0 h1
  lookup "$sn"
  h0=$((DISK_SEC/2))
  h1=$((DISK_SEC-h0))
  log "${sn}: 对半  P0=${h0}  P1=${h1} sectors"
  wipe_both "$sn"
  do_action "$PORT0" p0 "$P0_CTRL" "$P0_CID" 1 "$h0"
  do_action "$PORT1" p1 "$P1_CTRL" "$P1_CID" 2 "$h1"
}

verify_one(){ local sn="$1"; log "验收 ${sn}:"; ssh0 "nvme list|grep -F '${sn}'||echo '  P0: 无'"; ssh1 "nvme list|grep -F '${sn}'||echo '  P1: 无'"; }

split_all(){
  need_confirm
  local sns=() sn p0 p1; p0="$(scan_host "$PORT0")"; p1="$(scan_host "$PORT1")"
  declare -A H; while IFS='|' read -r s _; do H[$s]=1; done <<< "$p1"
  while IFS='|' read -r s _; do [[ -n "${H[$s]+x}" ]] && sns+=("$s"); done <<< "$p0"
  log "预检 ${#sns[@]} 块盘（挂载/占用）..."
  for sn in "${sns[@]}"; do check_sn_idle "$sn"; done
  log "将全部 ${#sns[@]} 块盘设为对半独享"
  for sn in "${sns[@]}"; do split_one "$sn"; verify_one "$sn"; done
}

usage(){
  cat <<EOF
用法:
  $0 list      --port0 IP --port1 IP
  $0 split-all --port0 IP --port1 IP [--confirm|--dry-run]
  $0 split-one --port0 IP --port1 IP --sn SN [--confirm|--dry-run]
  $0 own-p0    --port0 IP --port1 IP --sn SN [--confirm|--dry-run]
  $0 own-p1    --port0 IP --port1 IP --sn SN [--confirm|--dry-run]

在 Port0 节点运行，需能 ssh 到 Port1（建议 ssh-copy-id）。
EOF
}

main(){
  local cmd=""; [[ $# -gt 0 ]] || { usage; exit 1; }
  cmd="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port0) PORT0="$2"; shift 2;;
      --port1) PORT1="$2"; shift 2;;
      --sn) DISK_SN="$2"; shift 2;;
      --confirm) CONFIRM=1; shift;;
      --dry-run) DRY_RUN=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "未知: $1";;
    esac
  done
  [[ -n "$PORT0" && -n "$PORT1" ]] || die "需要 --port0 和 --port1"
  case "$cmd" in
    list) cmd_list;;
    split-all) split_all;;
    split-one) need_confirm; [[ -n "$DISK_SN" ]] || die "需要 --sn"; split_one "$DISK_SN"; verify_one "$DISK_SN";;
    own-p0) need_confirm; [[ -n "$DISK_SN" ]] || die "需要 --sn"; own_p0 "$DISK_SN"; verify_one "$DISK_SN";;
    own-p1) need_confirm; [[ -n "$DISK_SN" ]] || die "需要 --sn"; own_p1 "$DISK_SN"; verify_one "$DISK_SN";;
    *) usage; exit 1;;
  esac
}
main "$@"
