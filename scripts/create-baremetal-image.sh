#!/bin/bash

# script to create a Ubuntu bare metal image
# NobodyCam 0.0.0 Pre-alpha
# Others 0.1.0 Beta
#
# This builds an image in /tmp, and moves it into $IMG_PATH upon success.

set -e
set -o xtrace

# Setup
ARCH=${ARCH:-$(dpkg --print-architecture)}
IMG_PATH=${IMG_PATH:-/home/stack/devstack/files}
KERNEL_VER=${KERNEL_VER:-$(uname -r)}
CLOUD_IMAGES=${CLOUD_IMAGES:-http://cloud-images.ubuntu.com/}
RELEASE=${RELEASE:-precise}
BASE_IMAGE_FILE=${BASE_IMAGE_FILE:-$RELEASE-server-cloudimg-$ARCH-root.tar.gz}
OUTPUT_IMAGE_FILE=${OUTPUT_IMAGE_FILE:-bm-node-image.$KERNEL_VER.img}
FS_TYPE=${FS_TYPE:-ext4}
IMAGE_SIZE=${IMAGE_SIZE:-1} # N.B. This size is in GB

# Ensure we have sudo before we do long running things that will bore the user.
# Also, great band.
sudo echo

BASE_DIR=$(dirname $0)

TMP_BUILD_DIR=$(mktemp -t -d image.XXXXXXXX)
if [ $? -ne 0 ] ; then
    echo "Failed to create tmp directory"
    exit 1
fi

function unmount_image () {
    # unmount from the chroot
    sudo umount -f $TMP_BUILD_DIR/mnt/dev || true
    sudo umount -f $TMP_BUILD_DIR/mnt/tmp/in_target.d || true
    # give it a second (ok really 5) to umount
    sleep 5
    # oh ya don't want to forget to unmount the image
    sudo umount -f $TMP_BUILD_DIR/mnt || true
}

function cleanup () {
    unmount_image
    rm -rf $TMP_BUILD_DIR
}
trap cleanup ERR

echo Building in $TMP_BUILD_DIR


if [ ! -f $IMG_PATH/$BASE_IMAGE_FILE ] ; then
   echo "Fetching Base Image"
   wget $CLOUD_IMAGES/$RELEASE/current/$BASE_IMAGE_FILE -O $IMG_PATH/$BASE_IMAGE_FILE.tmp
   mv $IMG_PATH/$BASE_IMAGE_FILE.tmp $IMG_PATH/$BASE_IMAGE_FILE
fi

# TODO: this really should rename the old file
if [ -f  $IMG_PATH/$OUTPUT_IMAGE_FILE ] ; then
   echo "Old Image file Found REMOVING"
   rm -f $IMG_PATH/$OUTPUT_IMAGE_FILE
fi

# Create the file that will be our image
dd if=/dev/zero of=$TMP_BUILD_DIR/image bs=1M count=0 seek=$(( ${IMAGE_SIZE} * 1024 ))

mkfs -F -t $FS_TYPE $TMP_BUILD_DIR/image

# mount the image file
mkdir $TMP_BUILD_DIR/mnt
sudo mount -o loop $TMP_BUILD_DIR/image $TMP_BUILD_DIR/mnt
if [ $? -ne 0 ] ; then
    echo "Failed to mount image"
    exit 1
fi

# Extract the base image
sudo tar -C $TMP_BUILD_DIR/mnt -xzf $IMG_PATH/$BASE_IMAGE_FILE

# Configure Image
# Setup resolv.conf so we can chroot to install some packages
if [ -L $TMP_BUILD_DIR/mnt/etc/resolv.conf ] ; then
    sudo unlink $TMP_BUILD_DIR/mnt/etc/resolv.conf
fi

if [ -f $TMP_BUILD_DIR/mnt/etc/resolv.conf ] ; then
    sudo rm -f $TMP_BUILD_DIR/mnt/etc/resolv.conf
fi

# Recreate resolv.conf
sudo touch $TMP_BUILD_DIR/mnt/etc/resolv.conf
sudo chmod 777 $TMP_BUILD_DIR/mnt/etc/resolv.conf
echo nameserver 8.8.8.8>$TMP_BUILD_DIR/mnt/etc/resolv.conf

# we'll prob need something from /dev so lets mount it
sudo mount --bind /dev $TMP_BUILD_DIR/mnt/dev

# If we have a network proxy, use it.
if [ -n "$http_proxy" ] ; then
    sudo dd of=$TMP_BUILD_DIR/mnt/etc/apt/apt.conf.d/60img-build-proxy << _EOF_
Acquire::http::Proxy "$http_proxy";
_EOF_
fi

# Generate locales to avoid perl setting locales warnings
sudo chroot $TMP_BUILD_DIR/mnt locale-gen en_US en_US.UTF-8

# Ensure that hooks can enable PPAs
sudo chroot $TMP_BUILD_DIR/mnt apt-get -y install python-software-properties

# If we can find a directory of hooks to run in the target filesystem, bind mount it
# into the target and then execute run-parts in a chroot
if [ -d ${BASE_DIR}/in_target.d ] ; then
  sudo mkdir $TMP_BUILD_DIR/mnt/tmp/in_target.d
  sudo mount --bind ${BASE_DIR}/in_target.d $TMP_BUILD_DIR/mnt/tmp/in_target.d
  sudo chroot $TMP_BUILD_DIR/mnt run-parts -v /tmp/in_target.d
  sudo umount -f $TMP_BUILD_DIR/mnt/tmp/in_target.d
fi

# Now some quick hacks to prevent 4 minutes of pause while booting
if [ -f $TMP_BUILD_DIR/mnt/etc/init/cloud-init-nonet.conf ] ; then
    sudo rm -f $TMP_BUILD_DIR/mnt/etc/init/cloud-init-nonet.conf

# Now Recreate the file we just removed
sudo dd of=$TMP_BUILD_DIR/mnt/etc/init/cloud-init-nonet.conf << _EOF_ 
# cloud-init-no-net
start on mounted MOUNTPOINT=/ and stopped cloud-init-local
stop on static-network-up
task

console output

script
   # /run/network/static-network-up-emitted is written by
   # upstart (via /etc/network/if-up.d/upstart). its presense would
   # indicate that static-network-up has already fired.
	EMITTED="/run/network/static-network-up-emitted"
   [ -e "$EMITTED" -o -e "/var/$EMITTED" ] && exit 0

   [ -f /var/lib/cloud/instance/obj.pkl ] && exit 0

   start networking >/dev/null

   short=1; long=5;
   sleep ${short}
   echo $UPSTART_JOB "waiting ${long} seconds for a network device."
   sleep ${long}
   echo $UPSTART_JOB "gave up waiting for a network device."
   : > /var/lib/cloud/data/no-net
end script
# EOF
_EOF_
fi

# One more hack
if [ -f $TMP_BUILD_DIR/mnt/etc/init/failsafe.conf ] ; then
    sudo rm -f $TMP_BUILD_DIR/mnt/etc/init/failsafe.conf
fi

# Now Recreate the file we just removed
sudo dd of=$TMP_BUILD_DIR/mnt/etc/init/failsafe.conf << _EOF_ 
# failsafe

description "Failsafe Boot Delay"
author "Clint Byrum <clint@ubuntu.com>"

start on filesystem and net-device-up IFACE=lo
stop on static-network-up or starting rc-sysinit

emits failsafe-boot

console output

script
	# Determine if plymouth is available
	if [ -x /bin/plymouth ] && /bin/plymouth --ping ; then
		PLYMOUTH=/bin/plymouth
	else
		PLYMOUTH=":"
	fi

    # The point here is to wait for 2 minutes before forcibly booting 
    # the system. Anything that is in an "or" condition with 'started 
    # failsafe' in rc-sysinit deserves consideration for mentioning in
    # these messages. currently only static-network-up counts for that.

	sleep 2

    # Plymouth errors should not stop the script because we *must* reach
    # the end of this script to avoid letting the system spin forever
    # waiting on it to start.
	$PLYMOUTH message --text="Waiting for network configuration..." || :
	sleep 1

	$PLYMOUTH message --text="Waiting up to 5 more seconds for network configuration..." || :
	sleep 1
	$PLYMOUTH message --text="Booting system without full network configuration..." || :

    # give user 1 second to see this message since plymouth will go
    # away as soon as failsafe starts.
	sleep 1
    exec initctl emit --no-wait failsafe-boot
end script

post-start exec	logger -t 'failsafe' -p daemon.warning "Failsafe of 120 seconds reached."
_EOF_

# that should do it for the hacks
# Undo our proxy support
sudo rm -f $TMP_BUILD_DIR/mnt/etc/apt/apt.conf.d/60img-build-proxy
# Now remove the resolv.conf we created above
sudo rm -f $TMP_BUILD_DIR/mnt/etc/resolv.conf
# The we need to recreate it as a link
sudo ln -sf ../run/resolvconf/resolv.conf $TMP_BUILD_DIR/mnt/etc/resolv.conf

unmount_image
cp $TMP_BUILD_DIR/image $IMG_PATH/$OUTPUT_IMAGE_FILE
rm -r $TMP_BUILD_DIR

echo "Image file $IMG_PATH/$OUTPUT_IMAGE_FILE created..."

