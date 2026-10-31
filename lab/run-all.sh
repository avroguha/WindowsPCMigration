#!/bin/bash
# Runs ON pve. The whole lab migration, start to finish, once both VMs are provisioned:
#   old VM: install apps (elevated), create settings + export (user)
#   new VM: restore with nothing installed, install two apps, restore, install the rest, restore + verify
# Transcripts are printed from the share after each step (showlog.py lives in the share container).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OLD=9311; NEW=9312; CT=9313; LOGS=/srv/pcmig/logs
step() { # vmid mode script args...
  local vm=$1 mode=$2 script=$3; shift 3
  echo; echo "########## VM $vm ($mode): $script $* ##########"
  bash "$HERE/run-on-vm.sh" $vm $mode "$script" "$@" || { echo "STEP FAILED"; return 1; }
}
show() { # log name [lines]
  echo "----- $1"; pct exec $CT -- python3 /srv/pcmig/showlog.py "$LOGS/$1" "${2:-60}"
}
case "${1:-all}" in
  old)
    step $OLD elevated 'lab\old-pc.ps1' -Phase install && show MIG-OLD-old-install.log 20
    step $OLD user 'lab\old-pc.ps1' -Phase settings && show MIG-OLD-old-settings.log 70 ;;
  new)
    step $NEW user 'lab\new-pc.ps1' -Phase restore1 && show MIG-NEW-new-restore1.log 90
    step $NEW elevated 'lab\new-pc.ps1' -Phase install1 && show MIG-NEW-new-install1.log 12
    step $NEW user 'lab\new-pc.ps1' -Phase restore2 && show MIG-NEW-new-restore2.log 60
    step $NEW elevated 'lab\new-pc.ps1' -Phase install2 && show MIG-NEW-new-install2.log 12
    step $NEW user 'lab\new-pc.ps1' -Phase restore3 && show MIG-NEW-new-restore3.log 90
    echo "NEW-RUN-FINISHED" ;;
  all) bash "$0" old && bash "$0" new ;;
  *) echo "usage: $0 old|new|all" ;;
esac
