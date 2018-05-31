#!/bin/sh

#install tools
sudo apt-get -y install rsync dosfstools parted kpartx exfat-fuse

#mount device
mount_point=/mnt
if [ ! -d $mount_point ]; then
        mkdir -p $mount_point
fi

if [ -z $1 ]; then
        echo "no argument, assume the mount device is /dev/sda1 ? Y/N"
        read key
        if [ "$key" = "y" -o "$key" = "Y" ]; then
                sudo mount -o uid=1000 /dev/sda1 $mount_point
        else
                backup_self=1
        fi
else
        sudo mount -o uid=1000 $1 $mount_point
fi

if [ -z $backup_self -a -z "`grep $mount_point /etc/mtab`" ]; then
        echo "mount fail, exit now"
        exit 0
fi 

img=$mount_point/rpi_`hostname`_`date +%Y%m%d_%H%M`.img

echo ===================== part 1, create a new blank img ===============================
# New img file
bootsz=`df -P | grep /boot | awk '{print $2}'`
rootsz=`df -P | grep /dev/root | awk '{print $3}'`
totalsz=`echo $bootsz $rootsz | awk '{print int(($1+$2)*1.3)}'`
sudo dd if=/dev/zero of=$img bs=1K count=$totalsz

# format virtual disk
bootstart=`sudo fdisk -l /dev/mmcblk0 | grep mmcblk0p1 | awk '{print $2}'`
bootend=`sudo fdisk -l /dev/mmcblk0 | grep mmcblk0p1 | awk '{print $3}'`
rootstart=`sudo fdisk -l /dev/mmcblk0 | grep mmcblk0p2 | awk '{print $2}'`
echo "boot: $bootstart >>> $bootend, root: $rootstart >>> end"
sudo parted $img --script -- mklabel msdos
sudo parted $img --script -- mkpart primary fat32 ${bootstart}s ${bootend}s
sudo parted $img --script -- mkpart primary ext4 ${rootstart}s -1
loopdevice=`sudo losetup -f --show $img`
loopdev_num=`sudo kpartx -va $loopdevice | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
device=/dev/mapper/$loopdev_num
sleep 5
sudo mkfs.vfat ${device}p1 -n boot
sudo mkfs.ext4 ${device}p2


echo ===================== part 2, fill the data to img =================================
# mount partitions
mountb=$mount_point/backup_boot/
mountr=$mount_point/backup_root/
mkdir -p $mountb $mountr
# backup /boot
sudo mount -t vfat ${device}p1 $mountb
sudo cp -rfp /boot/* $mountb
sync
echo "...Boot partition done"
# backup /root
sudo mount -t ext4 ${device}p2 $mountr
if [ -f /etc/dphys-swapfile ]; then
        SWAPFILE=`cat /etc/dphys-swapfile | grep ^CONF_SWAPFILE | cut -f 2 -d=`
        if [ "$SWAPFILE" = "" ]; then
                SWAPFILE=/var/swap
        fi
        EXCLUDE_SWAPFILE="--exclude $SWAPFILE"
fi
sudo rsync --force -rltWDEgop --delete --stats --progress \
        $EXCLUDE_SWAPFILE \
        --exclude '/dev' \
        --exclude '/media' \
        --exclude '/mnt' \
        --exclude '/proc' \
        --exclude '/run' \
        --exclude '/sys' \
        --exclude '/tmp' \
        --exclude '/var/tmp' \
        --exclude 'lost\+found' \
        --exclude '$mount_point' \
        \/ $mountr
# special dirs 
for i in dev media mnt proc run sys; do
        sudo mkdir $mountr/$i
done
sudo mkdir $mountr/tmp
sudo chmod a+w $mountr/tmp
sudo mkdir $mountr/var/tmp
sudo chmod 777 $mountr/var/tmp

# reset network setting
sudo rm -f $mountr/etc/udev/rules.d/70-persistent-net.rules

sync 
echo "...Root partition done"

# replace PARTUUID
opartuuidb=`blkid -o export /dev/mmcblk0p1 | grep PARTUUID`
opartuuidr=`blkid -o export /dev/mmcblk0p2 | grep PARTUUID`
npartuuidb=`blkid -o export ${device}p1 | grep PARTUUID`
npartuuidr=`blkid -o export ${device}p2 | grep PARTUUID`
sudo sed -i "s/$opartuuidr/$npartuuidr/g" $mountb/cmdline.txt
sudo sed -i "s/$opartuuidb/$npartuuidb/g" $mountr/etc/fstab
sudo sed -i "s/$opartuuidr/$npartuuidr/g" $mountr/etc/fstab

sudo umount $mountb
sudo umount $mountr

# umount loop device
sudo kpartx -d $loopdevice
sudo losetup -d $loopdevice
if [ -z $backup_self ]; then
        sudo umount $mount_point
fi
rm -rf $mountb $mountr
echo ===== All done. You can un-plug the backup device===================================
