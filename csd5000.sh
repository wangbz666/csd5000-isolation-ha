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

# 整盘归属迁移：优先 detach+attach（不 delete / 不 reset），避免双端口固件卡死
move_own(){
  local sn="$1" dest="$2"   # dest=p0|p1
  check_sn_idle "$sn"
  local src_host src_ctrl src_cid dst_host dst_ctrl dst_cid
  if [[ "$dest" == "p1" ]]; then
    src_host="$PORT0"; src_ctrl="$P0_CTRL"; src_cid="$P0_CID"
    dst_host="$PORT1"; dst_ctrl="$P1_CTRL"; dst_cid="$P1_CID"
    log "${sn}: 整盘迁移到 Port1（detach P0 → attach P1，不 delete/reset）"
  else
    src_host="$PORT1"; src_ctrl="$P1_CTRL"; src_cid="$P1_CID"
    dst_host="$PORT0"; dst_ctrl="$P0_CTRL"; dst_cid="$P0_CID"
    log "${sn}: 整盘迁移到 Port0（detach P1 → attach P0，不 delete/reset）"
  fi

  ssh ${SSH_OPTS} "${SSH_USER}@${src_host}" python3 - "$src_ctrl" "$src_cid" "$DRY_RUN" <<'PY'
import glob, os, subprocess, sys
ctrl, cid, dry = sys.argv[1], sys.argv[2], sys.argv[3]
def run(c, timeout=15):
    print("+", c)
    if dry == "1":
        return 0
    try:
        return subprocess.run(c, shell=True, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: 超时: %s\n" % c)
        sys.exit(124)
# detach all attached ns from this controller
attached = subprocess.getoutput("nvme list-ns %s 2>/dev/null" % ctrl)
for line in attached.splitlines():
    # formats like: [   0]:0x1
    if "0x" not in line and ":" not in line:
        continue
    ns = line.split(":")[-1].strip()
    if ns.startswith("0x"):
        ns = str(int(ns, 16))
    if not ns.isdigit():
        continue
    why = subprocess.getoutput("findmnt -n -o TARGET %sn%s 2>/dev/null" % (ctrl, ns)).strip()
    if why:
        sys.stderr.write("ERROR: %sn%s 已挂载于 %s\n" % (ctrl, ns, why))
        sys.exit(2)
    rc = run("timeout 15 nvme detach-ns -n %s -c %s %s" % (ns, cid, ctrl))
    if rc != 0:
        sys.stderr.write("ERROR: detach-ns 失败 exit=%d\n" % rc)
        sys.exit(rc or 1)
print("OK detach")
PY

  ssh ${SSH_OPTS} "${SSH_USER}@${dst_host}" python3 - "$dst_ctrl" "$dst_cid" "$DISK_SEC" "$DRY_RUN" <<'PY'
import subprocess, sys, os, time
ctrl, cid, sec, dry = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
def run(c, timeout=15):
    print("+", c)
    if dry == "1":
        return 0
    try:
        return subprocess.run(c, shell=True, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: 超时: %s\n" % c)
        sys.exit(124)
# prefer attach existing allocated NS
alloc = subprocess.getoutput("nvme list-ns -a %s 2>/dev/null" % ctrl)
nsid = None
for line in alloc.splitlines():
    if "0x" in line or ":" in line:
        ns = line.split(":")[-1].strip()
        if ns.startswith("0x"):
            nsid = str(int(ns, 16))
            break
        if ns.isdigit():
            nsid = ns
            break
if nsid:
    rc = run("timeout 15 nvme attach-ns -n %s -c %s %s" % (nsid, cid, ctrl))
    if rc != 0:
        sys.stderr.write("ERROR: attach-ns 失败 exit=%d\n" % rc)
        sys.exit(rc or 1)
else:
    # no allocated NS: create once (still no reset)
    rc = run("timeout 20 nvme create-ns -s %d -c %d -f 0 %s" % (sec, sec, ctrl))
    if rc != 0:
        sys.exit(rc or 1)
    rc = run("timeout 15 nvme attach-ns -n 1 -c %s %s" % (cid, ctrl))
    if rc != 0:
        sys.exit(rc or 1)
run("timeout 10 nvme ns-rescan %s" % ctrl, timeout=12)
time.sleep(1)
blk = ctrl + "n1"
if dry != "1" and not os.path.exists(blk):
    # wait briefly for udev
    for _ in range(10):
        time.sleep(0.5)
        if os.path.exists(blk):
            break
if dry != "1" and not os.path.exists(blk):
    sys.stderr.write("ERROR: attach 后未出现块设备 %s\n" % blk)
    sys.exit(1)
print("OK attach", blk if dry != "1" else "(dry-run)")
PY
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
