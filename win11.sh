#!/bin/bash
set -euo pipefail

usage() {
  cat << 'EOF'
Usage: win11.sh [options]

Modes:
  default                 Start from existing base disk (no ISOs; uses overlay clone)
  --install               Install/boot with ISOs attached

Options:
  --clean                 Remove generated artifacts (disk/vars/log; TPM state if safe)
  --net                   Create TAP and attach to bridge (enables VM networking)
  --scsi                  Use SCSI disks, faster but won't work with CML
  --tap-ifname IFNAME     TAP interface name (default: tap0)
  --bridge IFNAME         Bridge interface name (default: virbr0)
  --workdir DIR           Directory containing ISOs/disks (default: script directory)
  --tpm-dir DIR           Directory for swtpm socket/state (default: /tmp/tpm-dir)
  --iso FILE              Windows ISO path (default: Win11_24H2_English_x64.iso)
  --virtio-iso FILE       Virtio ISO path (default: virtio-win-0.1.285.iso)
  --disk FILE             QCOW2 disk filename (default: win11.qcow2)
  --disk-size SIZE        Disk size for new disk (default: 64G)
  --base-disk FILE        Base qcow2 for --start (default: --disk)
  --clone-disk FILE       Clone qcow2 overlay for --start (default: win11-clone.qcow2)
  --memory SIZE           VM memory (default: 8G)
  --cpus N                VM vCPUs (default: 4)
  --required-free-gb N    Minimum free GB in WORKDIR (default: 16)
  -h, --help              Show this help

Config:
  If present, the script sources ./config.env (next to the script).
  Environment variables and CLI flags override config.env.

Path handling:
  Paths may be absolute (/...) or ~/...; other paths are interpreted relative to WORKDIR.

AppArmor/disk space note:
  Consider moving WORKDIR to e.g. /var/windows and change ownership to allow
  r/w access (sudo mkdir -p /var/windows && sudo chown sysadmin /var/windows)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_free_space() {
  local required_gb="$1"
  local dir="$2"
  local required_kb=$((required_gb * 1024 * 1024))
  local available_kb
  available_kb=$(df -Pk "$dir" | awk 'NR==2 {print $4}')

  if ((available_kb < required_kb)); then
    local available_gb
    available_gb=$(awk -v kb="$available_kb" 'BEGIN { printf "%.2f", kb/1024/1024 }')
    echo "Error: insufficient disk space in $dir. Required: ${required_gb}GB, Available: ${available_gb}GB" >&2
    exit 1
  fi
}

clean_artifacts() {
  rm -f -- "$WORKDIR/$OVMF_VARS" "$WORKDIR/$DISK" "$WORKDIR/$CLONE_DISK" "$WORKDIR/win11-serial.log"

  case "$TPM_DIR" in
    "$WORKDIR"/* | /tmp/tpm-dir | /tmp/tpm-dir-*)
      rm -rf -- "$TPM_DIR"
      ;;
    *)
      echo "Note: not removing TPM_DIR outside WORKDIR: $TPM_DIR" >&2
      ;;
  esac
}

ensure_network() {
  if [ -z "$TAP_IFNAME" ] || [ -z "$BRIDGE_IFNAME" ]; then
    echo "Error: TAP_IFNAME/BRIDGE_IFNAME must not be empty" >&2
    exit 1
  fi

  if ! ip link show "$BRIDGE_IFNAME" > /dev/null 2>&1; then
    echo "Error: bridge interface not found: $BRIDGE_IFNAME" >&2
    exit 1
  fi

  if ! ip link show "$TAP_IFNAME" > /dev/null 2>&1; then
    sudo ip tuntap add dev "$TAP_IFNAME" mode tap user "$USER"
  fi

  sudo ip link set dev "$TAP_IFNAME" master "$BRIDGE_IFNAME"
  sudo ip link set dev "$TAP_IFNAME" up
}

expand_tilde_path() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${p#~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

resolve_path() {
  local p
  p="$(expand_tilde_path "$1")"
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *) printf '%s\n' "$WORKDIR/$p" ;;
  esac
}

# Optional config file next to the script.
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
fi

# Defaults (can be overridden by config/env/flags)
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
ISO="${ISO:-Win11_24H2_English_x64.iso}"
VIRTIO_ISO="${VIRTIO_ISO:-virtio-win-0.1.285.iso}"
DISK="${DISK:-win11.qcow2}"
DISK_SIZE="${DISK_SIZE:-64G}"
BASE_DISK="${BASE_DISK:-$DISK}"
CLONE_DISK="${CLONE_DISK:-win11-clone.qcow2}"
MEMORY="${MEMORY:-8G}"
CPUS="${CPUS:-4}"
REQUIRED_FREE_GB="${REQUIRED_FREE_GB:-16}"

TPM_DIR="${TPM_DIR:-/tmp/tpm-dir}"

OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.ms.fd}"
OVMF_VARS="${OVMF_VARS:-OVMF_VARS_WIN11.fd}"

# CPU_FLAG_DEFAULT=-host,-waitpkg,-hle,-rtm,-mpx
CPU_FLAG_DEFAULT=host,kvm=on,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_synic,hv_stimer,hv_reset,hv_vpindex,hv_runtime
CPU_FLAGS="${CPU_FLAGS:-$CPU_FLAG_DEFAULT}"

SCSI_MODE=0
START_MODE=1
CLEAN_ONLY=0
BASE_DISK_EXPLICIT=0
NET_MODE=0
TAP_IFNAME="${TAP_IFNAME:-tap0}"
BRIDGE_IFNAME="${BRIDGE_IFNAME:-virbr0}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install)
      START_MODE=0
      ;;
    --clean)
      CLEAN_ONLY=1
      ;;
    --scsi)
      SCSI_MODE=1
      ;;
    --net)
      NET_MODE=1
      ;;
    --tap-ifname)
      shift
      TAP_IFNAME="${1:-}"
      ;;
    --bridge)
      shift
      BRIDGE_IFNAME="${1:-}"
      ;;
    --workdir)
      shift
      WORKDIR="${1:-}"
      ;;
    --tpm-dir)
      shift
      TPM_DIR="${1:-}"
      ;;
    --iso)
      shift
      ISO="${1:-}"
      ;;
    --virtio-iso)
      shift
      VIRTIO_ISO="${1:-}"
      ;;
    --disk)
      shift
      DISK="${1:-}"
      if [ "$BASE_DISK_EXPLICIT" -eq 0 ]; then
        BASE_DISK="$DISK"
      fi
      ;;
    --disk-size)
      shift
      DISK_SIZE="${1:-}"
      ;;
    --base-disk)
      shift
      BASE_DISK="${1:-}"
      BASE_DISK_EXPLICIT=1
      ;;
    --clone-disk)
      shift
      CLONE_DISK="${1:-}"
      ;;
    --memory)
      shift
      MEMORY="${1:-}"
      ;;
    --cpus)
      shift
      CPUS="${1:-}"
      ;;
    --required-free-gb)
      shift
      REQUIRED_FREE_GB="${1:-}"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$WORKDIR" ]; then
  echo "Error: No WORKDIR provided" >&2
  exit 1
fi
if [ ! -d "$WORKDIR" ]; then
  echo "Error: WORKDIR does not exist: $WORKDIR" >&2
  exit 1
fi
if [ ! -w "$WORKDIR" ]; then
  echo "Error: WORKDIR is not writable: $WORKDIR" >&2
  echo "Tip: AppArmor tends to allow a dedicated location like /var/windows." >&2
  exit 1
fi

cd "$WORKDIR"
WORKDIR="$(pwd)"
if [ -z "$TPM_DIR" ]; then
  echo "Error: TPM_DIR is empty" >&2
  exit 1
fi

TPM_SOCK="$TPM_DIR/swtpm-sock"

ISO_PATH="$(resolve_path "$ISO")"
VIRTIO_ISO_PATH="$(resolve_path "$VIRTIO_ISO")"
BASE_DISK_PATH="$(resolve_path "$BASE_DISK")"
CLONE_DISK_PATH="$(resolve_path "$CLONE_DISK")"

if [ "$CLEAN_ONLY" -eq 1 ]; then
  clean_artifacts
  exit 0
fi

check_free_space "$REQUIRED_FREE_GB" "$WORKDIR"

if [ "$START_MODE" -eq 0 ]; then
  if [ ! -f "$ISO_PATH" ]; then
    echo "Error: Windows ISO not found: $ISO_PATH" >&2
    exit 1
  fi
  if [ ! -f "$VIRTIO_ISO_PATH" ]; then
    echo "Error: Virtio ISO not found: $VIRTIO_ISO_PATH" >&2
    exit 1
  fi
fi

if [ "$START_MODE" -eq 1 ]; then
  if [ ! -f "$BASE_DISK_PATH" ]; then
    echo "Error: base disk not found: $BASE_DISK_PATH" >&2
    exit 1
  fi
  if [ ! -f "$CLONE_DISK_PATH" ]; then
    echo "Creating clone overlay: $CLONE_DISK_PATH"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_DISK_PATH" "$CLONE_DISK_PATH"
  fi
else
  if [ ! -f "$DISK" ]; then
    echo "Creating disk image..."
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
  fi
fi

if [ ! -f "$OVMF_VARS" ]; then
  echo "Copying OVMF_VARS template..."
  cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$OVMF_VARS"
fi

mkdir -p "$TPM_DIR"
if [ ! -w "$TPM_DIR" ]; then
  echo "Error: TPM_DIR is not writable: $TPM_DIR" >&2
  echo "Tip: for AppArmor, TPM_DIR=/tmp/tpm-dir is usually allowed." >&2
  exit 1
fi
if [ ! -S "$TPM_SOCK" ]; then
  swtpm socket --tpm2 --ctrl "type=unixio,path=$TPM_SOCK" \
    --tpmstate "dir=$TPM_DIR" --daemon --log level=2
fi

if [ "$NET_MODE" -eq 1 ]; then
  ensure_network
fi

RUN_DISK="$DISK"
DISK_BOOTINDEX=2
if [ "$START_MODE" -eq 1 ]; then
  RUN_DISK="$CLONE_DISK_PATH"
  DISK_BOOTINDEX=1
fi

# CML compatible storage stack
BOOT_DISK_PCI=(
  -drive "file=$RUN_DISK,format=qcow2,if=none,id=disk0"
  -device "virtio-blk-pci,drive=disk0,bootindex=$DISK_BOOTINDEX"
)

# better storage stack but won't work as-is with CML as of today
BOOT_DISK_SCSI=(
  -object "iothread,id=iothread0"
  -drive file="$RUN_DISK",format=qcow2,if=none,id=disk0,discard=unmap,detect-zeroes=unmap
  -device "virtio-scsi-pci,id=scsi0,iothread=iothread0"
  -device "scsi-hd,drive=disk0,bootindex=$DISK_BOOTINDEX"
)

QEMU_ARGS=(
  -name windows11
  -machine type=q35,accel=kvm
  -cpu "$CPU_FLAGS"
  -smp "$CPUS"
  -m "$MEMORY"
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
  -drive if=pflash,format=raw,file="$OVMF_VARS"
  -netdev "tap,id=net0,ifname=$TAP_IFNAME,script=no,downscript=no"
  -device "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56"
  -chardev "socket,id=chrtpm,path=$TPM_DIR/swtpm-sock"
  -tpmdev "emulator,id=tpm0,chardev=chrtpm"
  -device "tpm-tis,tpmdev=tpm0"
  -device qemu-xhci
  -device usb-tablet
  -device "virtio-vga,max_outputs=1"
  -vnc :1
  -serial "file:win11-serial.log"
)

if [ "$START_MODE" -eq 0 ]; then
  QEMU_ARGS=("${QEMU_ARGS[@]}" "${BOOT_DISK_PCI[@]}")
else
  QEMU_ARGS=("${QEMU_ARGS[@]}" "${BOOT_DISK_SCSI[@]}")
fi

if [ "$START_MODE" -eq 0 ]; then
  QEMU_ARGS+=(
    -drive "file=$ISO_PATH,media=cdrom,if=none,id=cdrom0"
    -device "ide-cd,drive=cdrom0,bootindex=1"
    -drive "file=$VIRTIO_ISO_PATH,media=cdrom,if=none,id=cdrom1"
    -device "ide-cd,drive=cdrom1,bus=ide.1"
  )
fi

echo "VM starting... Connect VNC client to tcp/5901"
sudo /usr/bin/qemu-system-x86_64 "${QEMU_ARGS[@]}"
