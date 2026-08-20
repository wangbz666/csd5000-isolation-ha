#!/bin/bash
# Recover SF2451C0548H (JBOF Physical Slot 15) - run on Port0 node after both nodes are up
set -euo pipefail
SN=SF2451C0548H
P0=192.168.255.96
P1=192.168.255.98
P0_PCI=0000:11:00.0
P1_PCI=0000:0a:00.0

log(){ echo "[$(date '+%H:%M:%S')] $*"; }

recover_pci(){
  local host=$1 pci=$2 label=$3
  log "$label: recover $pci on $host"
  ssh -o ConnectTimeout=10 root@$host "
    set -x
    # remove stale nvme for this pci
    for n in /sys/class/nvme/nvme*; do
      [[ \$(basename \$(readlink -f \$n/device)) == '$pci' ]] || continue
      echo 1 > \$n/device/remove 2>/dev/null || true
    done
    [[ -d /sys/bus/pci/devices/$pci ]] && echo 1 > /sys/bus/pci/devices/$pci/remove || true
    sleep 3
    echo 1 > /sys/bus/pci/rescan
    sleep 10
    lspci -s ${pci#0000:} -k | head -3
    for n in /sys/class/nvme/nvme*; do
      [[ \$(basename \$(readlink -f \$n/device)) == '$pci' ]] || continue
      D=/dev/\$(basename \$n)
      echo found \$D sn=\$(tr -d ' \\n' < \$n/serial) state=\$(cat \$n/state)
      timeout 20 nvme reset \$D 2>&1 || true
      nvme id-ctrl \$D 2>/dev/null | grep ^sn || true
    done
  "
}

log "=== recover $SN ==="
recover_pci $P1 $P1_PCI Port1
sleep 5
recover_pci $P0 $P0_PCI Port0
sleep 5

log "=== check SN on both sides ==="
ssh root@$P0 "nvme list | grep $SN || echo P0 missing; for d in /dev/nvme[0-9]; do nvme id-ctrl \$d 2>/dev/null | grep -q $SN && echo P0 ctrl=\$d; done"
ssh root@$P1 "nvme list | grep $SN || echo P1 missing; for d in /dev/nvme[0-9]; do nvme id-ctrl \$d 2>/dev/null | grep -q $SN && echo P1 ctrl=\$d; done"

log "=== if ctrl ok but no NS, recreate on P1 (example) ==="
log "Manual: ./csd5000.sh own-p1 --port0 $P0 --port1 $P1 --sn $SN --confirm"
