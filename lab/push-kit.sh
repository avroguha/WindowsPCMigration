#!/bin/bash
# Runs on the laptop (Git Bash). Copies the current kit - engine scripts, catalog, the built exe, the lab scripts -
# into the lab share (CT 9313, \\192.168.5.217\pcmig\kit) through pve, replacing what is there.
#   bash lab/push-kit.sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
VER=$(tr -d ' \r\n' < "$HERE/VERSION")
EXE="$HERE/dist/PCMigration-$VER.exe"
[ -f "$EXE" ] || { echo "build first: $EXE is missing (Build-Exe.ps1)"; exit 1; }
STAGE=$(mktemp -d)
mkdir -p "$STAGE/kit/lab"
for f in MigrationCommon.psm1 catalog.json Export-Profile.ps1 Compare-Software.ps1 Import-Profile.ps1 UI-Probe.ps1 Export.cmd Compare-Software.cmd Import.cmd README.md VERSION "Start Migration.cmd"; do cp "$HERE/$f" "$STAGE/kit/"; done
cp "$EXE" "$STAGE/kit/PCMigration.exe"
cp "$HERE"/lab/*.ps1 "$HERE"/lab/*.cmd "$STAGE/kit/lab/"
tar -C "$STAGE" -cf "$STAGE/kit.tar" kit
SSH="ssh -i $HOME/.ssh/nexus_lab -o BatchMode=yes root@192.168.5.137"
scp -q -i "$HOME/.ssh/nexus_lab" "$STAGE/kit.tar" root@192.168.5.137:/tmp/pcmig-kit.tar
$SSH "pct push 9313 /tmp/pcmig-kit.tar /tmp/kit.tar >/dev/null && pct exec 9313 -- bash -c 'rm -rf /srv/pcmig/kit && tar --no-same-owner -xf /tmp/kit.tar -C /srv/pcmig && chown -R mig /srv/pcmig/kit && chmod -R u+rwX,g+rwX /srv/pcmig/kit && rm /tmp/kit.tar && cat /srv/pcmig/kit/VERSION && ls /srv/pcmig/kit | wc -l'"
rm -rf "$STAGE"
echo "kit $VER pushed to \\\\192.168.5.217\\pcmig\\kit"
