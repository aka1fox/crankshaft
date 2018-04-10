#!/bin/bash

# adapted from ezpi4me - Raspberry Pi ME image creation script
# Written by Huan Truong <htruong@tnhh.net>, 2018
# This script is licensed under GNU Public License v3

IMAGE_FILE=2018-03-13-raspbian-stretch-lite.zip
IMAGE_FILE_UNZIPPED=2018-03-13-raspbian-stretch-lite.img
TODAY_EXT=$(date +"%Y-%m-%d")
IMAGE_FILE_CUSTOMIZED=${IMAGE:-"crankshaft-${TODAY_EXT}.img"}
IMAGE_URL=http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2018-03-13/2018-03-13-raspbian-stretch-lite.zip
IMAGE_SIZE_RAW=1858076672
IMAGE_ROOTPART_START=98304
TEMP_CHROOT_DIR=/mnt/raspbian-temp
DROP_IN=${DROP_IN:-0}
CUSTOM_SCRIPT=${CUSTOM_SCRIPT:-""}


#########################################################
# Support functions
#########################################################

bail_and_cleanup() {
    kpartx -d $1 
    # rm $2
}

check_command_ok() {
    if ! [ -x "$(command -v $1)" ]; then
        echo 'Error: $1 is not installed. Please install it.' >&2
        exit 1
    fi
}

check_root() {
    # make sure we're root
    if [ "$EUID" -ne 0 ]; then 
        echo "Please run this script as using sudo/as root, otherwise it can't continue."
        exit
    fi
}

check_dependencies() {
    check_command_ok kpartx
    # check_command_ok parted
    check_command_ok qemu-arm-static
    check_command_ok chroot
}

get_unzip_image() {
    #get raspberry image
    if [ -f ${IMAGE_FILE} ]; then
        echo "Image file ${IMAGE_FILE} is already here, skip download. To re-download, please remove it."
    else
        wget -O${IMAGE_FILE} ${IMAGE_URL}
    fi
    if ! [ -f ${IMAGE_FILE_UNZIPPED} ]; then
        unzip ${IMAGE_FILE}
    fi
    if ! [ -f ${IMAGE_FILE_CUSTOMIZED} ]; then
    	echo "Copying a big file..."
    	cp ${IMAGE_FILE_UNZIPPED} ${IMAGE_FILE_CUSTOMIZED}
    else
	echo "Skipping creation of ${IMAGE_FILE_CUSTOMIZED}, it's already there. To re-create, delete it."
    fi
}

resize_raw_image() {
    IMAGE_SIZE_ACTUAL=$(wc -c < "${IMAGE_FILE_CUSTOMIZED}")
    if [ ${IMAGE_SIZE_ACTUAL} -gt ${IMAGE_SIZE_RAW} ]; then
        echo "Image seems already resized, or something is wrong."
        echo "If the image doesn't work, try removing the .img and try again."
        return
    fi
    echo "Resizing image"
    
    #resize image
    dd if=/dev/zero bs=1M count=512 >> ${IMAGE_FILE_CUSTOMIZED}
    
    PART_NUM=2
    
    fdisk ${IMAGE_FILE_CUSTOMIZED} <<EOF
p
d
$PART_NUM
n
p
$PART_NUM
$IMAGE_ROOTPART_START

p
w
EOF

}

set_up_loopdevs() {
    # mount the resized partition
    kpartx -v -a ${IMAGE_FILE_CUSTOMIZED} | tee /tmp/kpartx-output.txt
    LOOPPARTSID=`cat /tmp/kpartx-output.txt | head -n1 | sed 's/add map //' | cut -f1 -d' ' | sed 's/p1$//'`

    #echo "-- LoopFS setup --\n${LOOPPARTSRET}"
    echo "The loop device is ${LOOPPARTSID}"
    sync
    sleep 2

    # it should have two partitions at /dev/mapper
    if ! [ -L /dev/mapper/${LOOPPARTSID}p1 ]; then
        echo "Couldn't find the loopdev partitions at /dev/mapper/${LOOPPARTSID}p1!"
        bail_and_cleanup /dev/${LOOPPARTSID} ${IMAGE_FILE_CUSTOMIZED}
        exit 1
    fi

    echo "Found the loopdev partitions at /dev/mapper/${LOOPPARTSID}!"
    LOOPDEVPARTS=/dev/mapper/${LOOPPARTSID}

    e2fsck -f ${LOOPDEVPARTS}p2

    resize2fs ${LOOPDEVPARTS}p2

    e2fsck -f ${LOOPDEVPARTS}p2

    mount_chroot_dirs ${LOOPDEVPARTS} ${LOOPPARTSID}

    # ld.so.preload fix
    sed -i 's/^/#CHROOT /g' ${TEMP_CHROOT_DIR}/etc/ld.so.preload

    # copy qemu binary
    cp `which qemu-arm-static` ${TEMP_CHROOT_DIR}/usr/bin/

    if [[ ${DROP_IN} -ne 0 ]]; then

        echo -e "Dropping you in the chroot shell."
        chroot ${TEMP_CHROOT_DIR} /bin/bash

    else 

        if [[ -n "${CUSTOM_SCRIPT}" ]]; then

            # eval the custom script

            eval ${CUSTOM_SCRIPT}

        else

            # make the image

            # extract libQt5
            tar -xvf prebuilt/libQt5_OpenGLES2.tar.xz -C ${TEMP_CHROOT_DIR}/

            # copy rest of CS stuff to the root home directory
            cp -a crankshaft/. ${TEMP_CHROOT_DIR}/root/

            sync
            sleep 1

            # phew, customize it
            chroot ${TEMP_CHROOT_DIR} /bin/bash /root/scripts/customize-image-pi.sh

            chroot ${TEMP_CHROOT_DIR} /bin/bash /root/scripts/read-only-fs.sh
            
        fi

    fi
    # undo ld.so.preload fix
    sed -i 's/^#CHROOT //g' ${TEMP_CHROOT_DIR}/etc/ld.so.preload
    
    umount_chroot_dirs

    zerofree ${LOOPDEVPARTS}p2

    umount_loop_dev /dev/${LOOPPARTSID}

    echo "If you reach here, it means the image is ready. :)"
}


mount_chroot_dirs() {
    echo "Mounting CHROOT directories"
    mkdir -p ${TEMP_CHROOT_DIR}
    
    mount -o rw ${1}p2 ${TEMP_CHROOT_DIR}
    mount -o rw ${1}p1 ${TEMP_CHROOT_DIR}/boot

    # mount binds
    mount --bind /dev ${TEMP_CHROOT_DIR}/dev/
    mount --bind /sys ${TEMP_CHROOT_DIR}/sys/
    mount --bind /proc ${TEMP_CHROOT_DIR}/proc/
    mount --bind /dev/pts ${TEMP_CHROOT_DIR}/dev/pts

    if  ! [ -f ${TEMP_CHROOT_DIR}/etc/ld.so.preload ]; then
        echo "I didn't see ${TEMP_CHROOT_DIR}/etc/ folder. Bailing!"
        umount_chroot_dirs
        umount_loop_dev /dev/$2
        exit 1
    fi
    
}

umount_chroot_dirs() {
    umount ${TEMP_CHROOT_DIR}/{dev/pts,dev,sys,proc,boot,}
    sync
}

umount_loop_dev() {
    kpartx -d $1
}

#########################################################


check_dependencies
check_root
get_unzip_image
resize_raw_image
set_up_loopdevs



