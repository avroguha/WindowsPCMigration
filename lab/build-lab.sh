#!/bin/bash
# Runs ON pve as root. Builds the two migration-lab Windows VMs and the Samba "mock OneDrive" container.
#   bash build-lab.sh create   - build unattend ISOs, create + start VMs 9301/9302 and CT 9303
#   bash build-lab.sh status   - IPs and provisioning state
#   bash build-lab.sh destroy  - remove everything
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
ISO_DIR=/var/lib/vz/template/iso
WIN_ISO=local:iso/Win11_25H2_English_x64_noTPM_2.iso
VIRTIO_ISO=local:iso/virtio-win.iso
STORE=ssd1tb
OLD_ID=9311; NEW_ID=9312; CT_ID=9313
CT_PASS='Lab-mig-ct-2026'
SMB_USER=mig; SMB_PASS='Lab-mig-share-2026'
HERE=$(cd "$(dirname "$0")" && pwd)

build_iso() { # name
  local name=$1; local work=/tmp/ua-$name
  rm -rf "$work"; mkdir -p "$work"
  sed "s/__COMPUTERNAME__/$name/" "$HERE/autounattend.template.xml" > "$work/autounattend.xml"
  genisoimage -quiet -o "$ISO_DIR/$name-unattend.iso" -V UNATTEND -J -r "$work" 2>&1 | grep -v -i warning || true
  ls -la "$ISO_DIR/$name-unattend.iso"
}

create_vm() { # id name
  local id=$1 name=$2
  qm create $id --name $name --memory 6144 --balloon 0 --cores 4 --cpu host --sockets 1 \
    --machine q35 --bios seabios \
    --ostype win11 --scsihw virtio-scsi-single --sata0 $STORE:64 \
    --ide2 $WIN_ISO,media=cdrom --ide0 local:iso/$name-unattend.iso,media=cdrom --ide1 $VIRTIO_ISO,media=cdrom \
    --net0 e1000,bridge=vmbr0 --boot order=ide2\;sata0 --agent enabled=1 --onboot 0 \
    --description "PC-migration lab ($name) - Windows 11 Pro unattended, user avro. Disposable."
  qm start $id
  # the Windows ISO asks "Press any key to boot from CD" - answer it for the first 40 s
  ( for i in $(seq 1 20); do sleep 2; qm sendkey $id ret >/dev/null 2>&1; done ) &
}

create_ct() {
  local tmpl
  tmpl=$(pveam list local | awk '/ubuntu-24.04-standard/ {print $1}' | tail -1)
  if [ -z "$tmpl" ]; then pveam update >/dev/null; pveam download local "$(pveam available --section system | awk '/ubuntu-24.04-standard/ {print $2}' | tail -1)"; tmpl=$(pveam list local | awk '/ubuntu-24.04-standard/ {print $1}' | tail -1); fi
  pct create $CT_ID "$tmpl" --hostname mig-share --cores 1 --memory 512 --rootfs $STORE:8 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --nameserver "192.168.5.1 1.1.1.1" --unprivileged 1 --onboot 0 \
    --password "$CT_PASS" --description "PC-migration lab - Samba share standing in for OneDrive. Disposable."
  pct start $CT_ID; sleep 6
  pct exec $CT_ID -- bash -c 'printf "nameserver 192.168.5.1\nnameserver 1.1.1.1\n" > /etc/resolv.conf'
  pct exec $CT_ID -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq samba >/dev/null'
  pct exec $CT_ID -- bash -c "useradd -M -s /usr/sbin/nologin $SMB_USER 2>/dev/null; (echo '$SMB_PASS'; echo '$SMB_PASS') | smbpasswd -s -a $SMB_USER; mkdir -p /srv/pcmig && chown $SMB_USER /srv/pcmig && chmod 770 /srv/pcmig"
  pct exec $CT_ID -- bash -c "cat >> /etc/samba/smb.conf <<EOF

[pcmig]
   path = /srv/pcmig
   browseable = yes
   writable = yes
   valid users = $SMB_USER
   create mask = 0660
   directory mask = 0770
EOF
systemctl restart smbd"
  echo "share: \\\\$(pct exec $CT_ID -- hostname -I | awk '{print $1}')\\pcmig  user $SMB_USER"
}

status() {
  for id in $OLD_ID $NEW_ID; do
    printf '%s: ' "$id"; qm status $id 2>/dev/null | tr '\n' ' '
    ip=$(qm guest cmd $id network-get-interfaces 2>/dev/null | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  for i in d:
    for a in i.get("ip-addresses",[]):
      if a["ip-address-type"]=="ipv4" and a["ip-address"].startswith("192.168.5."): print(a["ip-address"])
except Exception: pass' | head -1)
    printf 'ip=%s ' "${ip:-?}"
    if [ -n "$ip" ]; then qm guest exec $id -- cmd /c "type C:\provisioned.txt" 2>/dev/null | grep -q done && printf 'provisioned'; fi
    echo
  done
  printf 'CT %s: ' $CT_ID; pct status $CT_ID 2>/dev/null; pct exec $CT_ID -- hostname -I 2>/dev/null
}

case "${1:-}" in
  create)
    for id in $OLD_ID $NEW_ID $CT_ID; do if qm config $id >/dev/null 2>&1 || pct config $id >/dev/null 2>&1; then echo "ID $id is already in use - refusing"; exit 1; fi; done
    echo "== ISO root autounattend check (should be empty):"; isoinfo -i $ISO_DIR/Win11_25H2_English_x64_noTPM_2.iso -l 2>/dev/null | grep -i -E 'autounat|unattend' || echo "(none)"
    build_iso mig-old; build_iso mig-new
    create_vm $OLD_ID mig-old; create_vm $NEW_ID mig-new
    create_ct
    wait; status ;;
  status) status ;;
  destroy)
    for id in $OLD_ID $NEW_ID; do qm stop $id >/dev/null 2>&1; sleep 2; qm destroy $id --purge >/dev/null 2>&1 && echo "destroyed VM $id"; done
    pct stop $CT_ID >/dev/null 2>&1; pct destroy $CT_ID --purge >/dev/null 2>&1 && echo "destroyed CT $CT_ID"
    rm -f $ISO_DIR/mig-old-unattend.iso $ISO_DIR/mig-new-unattend.iso ;;
  *) echo "usage: $0 create|status|destroy" ;;
esac
