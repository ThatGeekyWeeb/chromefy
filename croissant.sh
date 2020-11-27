#!/usr/bin/env bash

#Script to install ChromeOS on top of ChromiumOS
#Can be used to install on a disk drive or applied to a ChromiumOS image
#If installing to a disk drive, you must run it from a different drive/USB

#Parameters:
#1 - ChromiumOS image, drive (ex: /dev/sda) or system partition (ex: /dev/sda3) (If partition: manually resize it to 4GB before running the script)
#2 - ChromeOS image file to be installed
#3 - [Optional] ChromeOS image from older device with TPM1.2 (ex: caroline image file) (needed for TPM2 images like eve to be able to login)

flag_vtpm=false
flag_tpm1=false
flag_disk=false

if [ $(whoami) != "root" ]; then echo "Please run with sudo"; exit 1; fi
if [ -z "$2" ]; then echo "Missing parameters"; exit 1; fi
if [ -b "$1" ]; then flag_image=false; elif [ -f "$1" ]; then flag_image=true; else echo "Invalid image or partition: $1"; exit 1; fi

if [ ! -d /home/chronos ]; then mkdir /home/chronos; fi
if [ ! -d /home/chronos/image ]; then mkdir /home/chronos/image; fi
if [ ! -d /home/chronos/local ]; then mkdir /home/chronos/local; fi
if [ ! -d /home/chronos/tpm1image ]; then mkdir /home/chronos/tpm1image; fi
if [ ! -d /home/chronos/RAW ]; then mkdir /home/chronos/RAW; fi

function cleanup_chromefy {
    sync
    umount /home/chronos/image 2>/dev/null
    umount /home/chronos/local 2>/dev/null
    umount /home/chronos/tpm1image 2>/dev/null
    losetup -d "$chromium_image" 2>/dev/null
    losetup -d "$chromeos_image" 2>/dev/null
    losetup -d "$chromeos_tpm1_image" 2>/dev/null
    rm -rf /home/chronos/RAW/* &>/dev/null
}

function abort_chromefy {
    echo "aborting...";
    cleanup_chromefy
    exit 1
}

function read_choice {
    while read choice; do
        case "$choice" in 
            [yY]|[yY][eE][sS] ) choice=true; break;;
            [nN]|[nN][oO] ) choice=false; break;;
            * ) echo "Invalid choice" && cleanup_chromefy; exit 1;;
        esac
    done
}

#Checks if images are valid and mounts them
if [ "$flag_image" = true ]; then
    chromium_image=$(losetup --show -fP "$1")
    mount "$chromium_image"p3 /home/chronos/local -o loop,rw  2>/dev/null
    if [ ! $? -eq 0 ]; then echo "Image $1 does not have a system partition (corrupted?)"; abort_chromefy; fi
fi

if [ ! -f "$2" ]; then echo "Image $2 not found"; abort_chromefy; fi
chromeos_image=$(losetup --show -fP "$2")
mount "$chromeos_image"p3 /home/chronos/image -o loop,ro  2>/dev/null
if [ ! $? -eq 0 ]; then echo "Image $2 does not have a system partition (corrupted?)"; abort_chromefy; fi

if [ ! -z "$3" ]; then
    if tar -tf "$3" &>/dev/null && ! tar -ztf "$3" &>/dev/null; then
        flag_vtpm=true
    else
        flag_tpm1=true
        if [ ! -f "$3" ]; then echo "Image $3 not found"; abort_chromefy; fi
        chromeos_tpm1_image=$(losetup --show -fP "$3")
        mount "$chromeos_tpm1_image"p3 /home/chronos/tpm1image -o loop,ro  2>/dev/null
        if [ ! $? -eq 0 ]; then echo "Image $3 does not have a system partition (corrupted?)"; abort_chromefy; fi
    fi
fi

#Checks if disk or partition
PART_LIST=$(sfdisk -lq "$chromium_image" 2>/dev/null)
PART_GRUB=$(echo "$PART_LIST" | grep "^""$chromium_image""[^:]" | awk '{print $1}' | grep [^0-9]12$)
PART_B=$(echo "$PART_LIST" | grep "^""$chromium_image""[^:]" | awk '{print $1}' | grep [^0-9]5$)
PART_A=$(echo "$PART_LIST" | grep "^""$chromium_image""[^:]" | awk '{print $1}' | grep [^0-9]3$)
PART_STATE=$(echo "$PART_LIST" | grep "^""$chromium_image""[^:]" | awk '{print $1}' | grep [^0-9]1$)
if [ "$flag_image" = false ]; then
    if [ ! -z "$PART_LIST" ]; then
        flag_disk=true
	umount "$1"?* 2>/dev/null
        if [ $(sudo sfdisk --part-type "$1" 3 2>/dev/null) != "3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC" ]
            then echo "Invalid device (Chromium/Chrome not installed)"; abort_chromefy
        fi
    else
        PART_A="$1"
    fi
fi

#Checks VTPM support if third parameter is a tar file (TPM emulator)
if [ "$flag_image" = false ]; then mount "$PART_A" /home/chronos/local; fi
KERNEL_LOCAL=$(ls /lib/modules/ | egrep "^([0-9]{1,}\.)+[0-9]{1,}[^ ]*$" | tail -1)
KERNEL_CHROMIUM=$(ls /home/chronos/local/lib/modules/ | egrep "^([0-9]{1,}\.)+[0-9]{1,}[^ ]*$" | tail -1)
VTPM_BUILTIN=$(cat /home/chronos/local/lib/modules/"$KERNEL_CHROMIUM"/modules.builtin 2>/dev/null | grep tpm_vtpm_proxy.ko)
VTPM_MODULE=$(cat /home/chronos/local/lib/modules/"$KERNEL_CHROMIUM"/modules.dep 2>/dev/null | grep tpm_vtpm_proxy.ko)
if [ "$flag_vtpm" = true ] && [ -z "$VTPM_BUILTIN" ] && [ -z "$VTPM_MODULE" ]; then
    echo "This Chromium image does not support VTPM proxy, use different image or TPM replacement method"; abort_chromefy
fi
if [ "$flag_vtpm" = true ]; then
    tar -xvf "$3" -C /home/chronos/RAW/
fi

#Backups ChromiumOS /lib directory if needed
chromium_root_dir=""
flag_linux=true
choice=false
if [ "$choice" = false ]; then
    chromium_root_dir="/home/chronos/RAW"
    flag_linux=false
    mkdir -p /home/chronos/RAW/usr/lib64
    cp -av /home/chronos/local/{lib,boot} /home/chronos/RAW/
    if [ ! $? -eq 0 ]; then echo "Error while copying ChromiumOS files locally (insufficent disk space?)"; abort_chromefy; fi
fi
umount /home/chronos/local 2>/dev/null


#Increases ROOT_A partition's size (if flashing on image)
choice=false

#Mounts ChromiumOS system partition
if [ "$flag_image" = false ]; then
    umount "$PART_A" 2>/dev/null
    yes | mkfs.ext4 "$PART_A"
    mount "$PART_A" /home/chronos/local
    if [ ! $? -eq 0 ]; then echo "Partition $PART_A inexistent"; abort_chromefy; fi
else
    mount "$PART_A" /home/chronos/local -o loop,rw,sync  2>/dev/null
    if [ ! $? -eq 0 ]; then echo "Something went wrong while changing $1 partition table (corrupted?)"; abort_chromefy; fi
fi

#Copies all ChromeOS system files
cp -av /home/chronos/image/* /home/chronos/local
umount /home/chronos/image

#Copies modules and certificates from ChromiumOS
rm -rf /home/chronos/local/lib/firmware
rm -rf /home/chronos/local/lib/modules/ 
cp -av "$chromium_root_dir"/{lib,boot} /home/chronos/local/
cp -nav "$chromium_root_dir"/usr/lib64/{dri,va} /home/chronos/local/usr/lib64/ #Extra GPU drivers
rm -rf /home/chronos/local/etc/modprobe.d/alsa*.conf
echo; echo "Leave selinux on enforcing? (Won't break SafetyNet without developer mode, but might cause issues with android apps)"
echo "Answer no if unsure (y/n)"
read_choice
if [ "$choice" = false ]; then sed '0,/enforcing/s/enforcing/permissive/' -i /home/chronos/local/etc/selinux/config; fi

#Fix for TPM2 images (must pass third parameter) (TPM replacement method)
if [ "$flag_tpm1" = true ]; then
	#Remove TPM 2.0 services
	rm -rf /home/chronos/local/etc/init/{attestationd,cr50-metrics,cr50-result,cr50-update,tpm_managerd,trunksd,u2fd}.conf

	#Copy TPM 1.2 file from tpm1image
	cp -av /home/chronos/tpm1image/etc/init/{chapsd,cryptohomed,cryptohomed-client,tcsd,tpm-probe}.conf /home/chronos/local/etc/init/
	cp -av /home/chronos/tpm1image/etc/tcsd.conf /home/chronos/local/etc/
	cp -av /home/chronos/tpm1image/usr/bin/{tpmc,chaps_client} /home/chronos/local/usr/bin/
	cp -av /home/chronos/tpm1image/usr/lib64/libtspi.so{,.1{,.2.0}} /home/chronos/local/usr/lib64/
	cp -av /home/chronos/tpm1image/usr/sbin/{chapsd,cryptohome,cryptohomed,cryptohome-path,tcsd} /home/chronos/local/usr/sbin/
	cp -av /home/chronos/tpm1image/usr/share/cros/init/{tcsd-pre-start,chapsd}.sh /home/chronos/local/usr/share/cros/init/
    cp -av /home/chronos/tpm1image/etc/dbus-1/system.d/{Cryptohome,org.chromium.Chaps}.conf /home/chronos/local/etc/dbus-1/system.d/
    if [ ! -f /home/chronos/local/usr/lib64/libecryptfs.so ] && [ -f /home/chronos/tpm1image/usr/lib64/libecryptfs.so ]; then
        cp -av /home/chronos/tpm1image/usr/lib64/libecryptfs* /home/chronos/local/usr/lib64/
        cp -av /home/chronos/tpm1image/usr/lib64/ecryptfs /home/chronos/local/usr/lib64/
    fi

	#Add tss user and group
	echo 'tss:!:207:root,chaps,attestation,tpm_manager,trunks,bootlockboxd' | tee -a /home/chronos/local/etc/group
	echo 'tss:!:207:207:trousers, TPM and TSS operations:/var/lib/tpm:/bin/false' | tee -a /home/chronos/local/etc/passwd
    
    umount /home/chronos/tpm1image
fi

#Fix for TPM2 images (must pass third parameter) (TPM emulation method)
if [ "$flag_vtpm" = true ]; then
    cp -av /home/chronos/RAW/swtpm/usr/sbin/* /home/chronos/local/usr/sbin
    cp -av /home/chronos/RAW/swtpm/usr/lib64/* /home/chronos/local/usr/lib64
    
    cd /home/chronos/local/usr/lib64 || echo "Folder missing !!!" && exit 1
    ln -s libswtpm_libtpms.so.0.0.0 libswtpm_libtpms.so.0
    ln -s libswtpm_libtpms.so.0 libswtpm_libtpms.so
    ln -s libtpms.so.0.6.0 libtpms.so.0
    ln -s libtpms.so.0 libtpms.so
    ln -s libtpm_unseal.so.1.0.0 libtpm_unseal.so.1
    ln -s libtpm_unseal.so.1 libtpm_unseal.so
    
    cat >/home/chronos/local/etc/init/_vtpm.conf <<EOL
    start on started boot-services

    script
        mkdir -p /var/lib/trunks
        modprobe tpm_vtpm_proxy
        swtpm chardev --vtpm-proxy --tpm2 --tpmstate dir=/var/lib/trunks --ctrl type=tcp,port=10001
        swtpm_ioctl --tcp :10001 -i
    end script
EOL
fi

#Fix ChromeOS installer (Automatically skip postinstall and fix UUIDs)
read -r -d '' CHROMEOS_INSTALL_FIX_GRUB <<'EOF'
  do_post_install; sync; cleanup; trap - EXIT
  echo; echo "Changing GRUB UUIDs..."; umount /home/chronos/local 2>/dev/null; mkdir -p /home/chronos/local 2>/dev/null; DST="${DST}"
  EFIPART=`flock "${DST}" sfdisk -lq "${DST}" 2>/dev/null | grep "^""${DST}""[^:]" | awk '{print $1}' | grep [^0-9]12$`
  mount "$EFIPART" /home/chronos/local 2>/dev/null
  OLD_UUID=`cat /home/chronos/local/efi/boot/grub.cfg | grep -m 1 "PARTUUID=" | awk -v FS="(PARTUUID=)" '{print $2}' | awk '{print $1}'`
  OLD_UUID_LEGACY=`cat /home/chronos/local/syslinux/usb.A.cfg | grep -m 1 "PARTUUID=" | awk -v FS="(PARTUUID=)" '{print $2}' | awk '{print $1}'`
  PARTUUID=`flock "${DST}" sfdisk --part-uuid "${DST}" 3`; sed -i "s/$OLD_UUID/$PARTUUID/" /home/chronos/local/efi/boot/grub.cfg
  sed -i "s/$OLD_UUID_LEGACY/$PARTUUID/" /home/chronos/local/syslinux/usb.A.cfg
  sync; umount /home/chronos/local 2>/dev/null; rmdir /home/chronos/local 2>/dev/null
  echo "EFI: Partition UUID $OLD_UUID changed to $PARTUUID"; echo "Legacy: Partition UUID $OLD_UUID_LEGACY changed to $PARTUUID"; echo
EOF
CHROMEOS_INSTALL_FIX_GRUB="${CHROMEOS_INSTALL_FIX_GRUB//\\/\\\\}"
CHROMEOS_INSTALL_FIX_GRUB="${CHROMEOS_INSTALL_FIX_GRUB//$'\n'/\\n}"
sed -i 's/DEFINE_boolean skip_postinstall ${FLAGS_FALSE}/DEFINE_boolean skip_postinstall ${FLAGS_TRUE}/g' /home/chronos/local/usr/sbin/chromeos-install
sed -i "s/^[ \t]*do_post_install[ \t]*\$/${CHROMEOS_INSTALL_FIX_GRUB////\\/}/g" /home/chronos/local/usr/sbin/chromeos-install

#Expose the internal camera to android container
internal_camera=$(dmesg | grep uvcvideo -m 1 | awk -F '[()]' '{print $2}')
original_camera=$(sed -nr 's,^camera0.module0.usb_vid_pid=(.*),\1,p'  /home/chronos/local/etc/camera/camera_characteristics.conf)
if [ ! -z "$internal_camera" ] && [ ! -z "$original_camera" ]
  then
    sudo sed -i -e "s/${original_camera%:*}/${internal_camera%:*}/" -e "s/${original_camera##*:}/${internal_camera##*:}/" /home/chronos/local/lib/udev/rules.d/50-camera.rules
    sudo sed -i "s/$original_camera/$internal_camera/" /home/chronos/local/etc/camera/camera_characteristics.conf
fi

cleanup_chromefy
echo
if [ "$flag_image" = false ]; then
    echo "ChromeOS installed, you can now reboot"
else 
    echo "ChromeOS image created: this is for personal use only, distribute at your own risk"
fi

