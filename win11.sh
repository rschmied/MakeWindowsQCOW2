#!/bin/bash
set -e

# === Configurable variables ===
ISO="Win11_24H2_English_x64.iso"
VIRTIO_ISO="virtio-win-0.1.271.iso"
MEMORY="8G"
CPUS=4

# === no change needed ===
DISK="win11.qcow2"
DISK_SIZE="64G"
TPM_DIR="tpm-win11"
TPM_LOCK_FILE="$TPM_DIR/swtpm.lock"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.ms.fd"
OVMF_VARS="OVMF_VARS_WIN11.fd"
CPU_FLAGS="Westmere,-waitpkg,-hle,-rtm,-mpx"

# === Create disk if it doesn't exist ===
if [ ! -f "$DISK" ]; then
    echo "Creating disk image..."
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
fi

# === Create writable OVMF_VARS copy ===
if [ ! -f "$OVMF_VARS" ]; then
    echo "Copying OVMF_VARS template..."
    cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$OVMF_VARS"
fi

# === Setup TPM emulator ===
mkdir -p "$TPM_DIR"
if [ ! -f "$TPM_LOCK_FILE" ]; then
    swtpm socket --tpm2 --ctrl type=unixio,path=$TPM_DIR/swtpm-sock \
        --tpmstate dir=$TPM_DIR --daemon --log level=2
fi

# === configure the network interface ===
# (
#     sleep 5
#     echo -e "press return to allow network (may need to auth): "
#     read
#     echo "network config"
#     sudo ip link set dev tap0 master virbr0
#     sudo ip link set dev tap0 up
# ) &

# === Launch VM ===
sudo /usr/bin/qemu-system-x86_64 \
    -name windows11 \
    -machine type=q35,accel=kvm \
    -cpu $CPU_FLAGS \
    -smp $CPUS \
    -m $MEMORY \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$DISK",format=qcow2,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0,bootindex=2 \
    -drive file="$ISO",media=cdrom,if=none,id=cdrom0 \
    -device ide-cd,drive=cdrom0,bootindex=1 \
    -drive file="$VIRTIO_ISO",media=cdrom,if=none,id=cdrom1 \
    -device ide-cd,drive=cdrom1,bus=ide.1 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0 \
    -chardev socket,id=chrtpm,path=$TPM_DIR/swtpm-sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -serial file:win11-serial.log \
    -device qemu-xhci \
    -device usb-tablet \
    -device qxl-vga,ram_size=134217728,vram_size=67108864,vgamem_mb=64 \
    -vnc :1
