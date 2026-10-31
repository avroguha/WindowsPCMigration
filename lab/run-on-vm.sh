#!/bin/bash
# Runs ON pve. Executes a kit lab script inside a Windows lab VM as user avro, through the QEMU guest agent:
# the agent runs as SYSTEM, so a scheduled task is created for avro (interactive, optionally elevated) and run.
#   bash run-on-vm.sh <vmid> user|elevated <script-relative-to-share-kit> [args...]
# The script writes its transcript to \\share\logs\<COMPUTER>-...log; this waits for the task to finish and prints it.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
VMID=$1; MODE=$2; SCRIPT=$3; shift 3; ARGS="$*"
CT=9313; SHARE_DIR=/srv/pcmig
USER=avro; PASS='Lab-gBHeUD5OqT3mMm!7'
SHARE='\\192.168.5.217\pcmig'
TASK="miglab-$(date +%s)"
# user mode: stored password, no /it (schtasks /run answers "Element not found" for a non-elevated /it task);
# elevated mode: /it + highest privileges
RL=""; [ "$MODE" = elevated ] && RL="/it /rl HIGHEST"
# run-task.cmd on the share writes <TASK>.exit when the script ends. The task command ends with a throwaway
# token because schtasks drops the last character before the closing quote.
TR="cmd /c \"cmdkey /add:192.168.5.217 /user:mig /pass:Lab-mig-share-2026 & ${SHARE}\kit\lab\run-task.cmd ${TASK} ${SCRIPT} ${ARGS} & rem x\""
qm guest exec $VMID --timeout 60 -- schtasks /create /tn "$TASK" /tr "$TR" /sc once /st 00:00 /ru "$USER" /rp "$PASS" /f $RL >/dev/null
qm guest exec $VMID --timeout 60 -- schtasks /run /tn "$TASK" >/dev/null
echo "started $TASK on VM $VMID ($MODE): $SCRIPT $ARGS"
for i in $(seq 1 240); do   # up to 40 min
  if pct exec $CT -- test -f "$SHARE_DIR/logs/$TASK.exit"; then
    code=$(pct exec $CT -- cat "$SHARE_DIR/logs/$TASK.exit" | tr -d ' \r\n')
    echo "finished with exit code $code"
    qm guest exec $VMID --timeout 30 -- schtasks /delete /tn "$TASK" /f >/dev/null 2>&1
    pct exec $CT -- rm -f "$SHARE_DIR/logs/$TASK.exit"
    exit 0
  fi
  sleep 10
done
echo "TIMEOUT waiting for $TASK"; exit 1
