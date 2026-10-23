# WIP: Clean Windows 11 install in QEMU with `autounattend.xml`

> [!WARNING]
> This is a work in progress and is not yet integrated with `win11.sh`.
> The examples below use `virtio-blk-pci` and `-cpu host`; the main script also
> supports SCSI via `--scsi` and defaults to `host,kvm=on,hv-passthrough`.
> The display-driver example uses QXL, while the main script uses
> `virtio-vga,max_outputs=1`. The XML also uses `wcm:*` attributes without
> declaring the `wcm` namespace and must be corrected before use.

## 0. Downloads

<https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise>

### 1. Create the virtual USB thumbdrive

```bash
dd if=/dev/zero of=autounattend.img bs=1M count=1
mkfs.fat -F 32 autounattend.img
mkdir /tmp/usbmnt
mount -o loop autounattend.img /tmp/usbmnt
cp autounattend.xml /tmp/usbmnt/
umount /tmp/usbmnt
```

To update later, just mount, edit, unmount.

---

### 2. autounattend.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="windowsPE">

    <!-- Load storage driver so setup can see the virtio disk -->
    <component name="Microsoft-Windows-PnpCustomizationsWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>E:\amd64\w11</Path>
        </PathAndCredentials>
        <!-- network driver, optional but useful during setup -->
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>E:\NetKVM\w11\amd64</Path>
        </PathAndCredentials>
        <!-- QXL/virtio-gpu display driver, optional -->
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>E:\qxldod\w11\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>

  </settings>

  <settings pass="specialize">

    <!-- Disable BitLocker auto-encryption -->
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>

  </settings>

</unattend>
```

---

### 3. QEMU command

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -m 4096 \
  -cpu host \
  \
  -drive file=windows11.qcow2,format=qcow2,if=none,id=hd \
  -device virtio-blk-pci,drive=hd \
  \
  -cdrom windows11.iso \
  -drive file=virtio-win.iso,format=raw,if=none,id=virtiocd \
  -device ide-cd,drive=virtiocd \
  -boot order=d \
  \
  -device qemu-xhci \
  -drive file=autounattend.img,format=raw,if=none,id=usbstick \
  -device usb-storage,drive=usbstick
```

---

### Notes

- The virtio ISO is attached as a second CD-ROM — `E:` is the typical drive letter it gets in WinPE, but if drivers aren't found, hit Shift+F10 and check with `diskpart` / `list volume`
- Display driver (`qxldod`) requires `-vga qxl` or `-device qxl-vga` in your QEMU command to be useful
- After install, run `virtio-win-guest-tools.exe` from the virtio ISO for balloon, serial, RNG and other guest utilities
- To update `autounattend.xml`: mount the image, edit, unmount — no need to touch the ISO or VM
