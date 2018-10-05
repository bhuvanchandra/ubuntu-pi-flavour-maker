#!/usr/bin/env bash

########################################################################
#
# Copyright (C) 2015 - 2017 Martin Wimpress <code@ubuntu-mate.org>
# Copyright (C) 2015 Rohith Madhavan <rohithmadhavan@gmail.com>
# Copyright (C) 2015 Ryan Finnie <ryan@finnie.org>
#
# See the included LICENSE file.
# 
########################################################################

set -ex

SALT_WHL="https://storage.googleapis.com/artifacts.rapyuta.io/salt-2017.7.0-py2-none-any.whl"
KEYSERVER="hkp://p80.pool.sks-keyservers.net:80"
DOCKER_GPG_KEY="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_PY_VER="3.1.3"
DOCKER_COMPOSE_VER="1.21.0"

trap exit_clean 1 2 3 6

exit_clean()
{
  echo "Caught Signal ... cleaning up."
  umount_system
  echo "Done cleanup ... quitting."
  exit 1
}

if [ -f build-settings.sh ]; then
    source build-settings.sh
else
    echo "ERROR! Could not source build-settings.sh."
    exit 1
fi

if [ $(id -u) -ne 0 ]; then
    echo "ERROR! Must be root."
    exit 1
fi

if [ -n "$LOCAL_MIRROR" ]; then
  MIRROR=$LOCAL_MIRROR
else
  MIRROR=http://ports.ubuntu.com/
fi

if [ -n "$LOCAL_ROS_MIRROR" ]; then
  ROS_MIRROR=$LOCAL_ROS_MIRROR
else
  ROS_MIRROR=http://packages.ros.org/ros/ubuntu
fi


function stop_and_start_dockerd_to_chroot()
{
  CHROOT=$1
  sudo systemctl stop docker
  dockerd -g ${CHROOT}/var/lib/docker &
}

function docker_pull()
{
  IMAGE_URL=$1
  NEW_TAG=$2

  docker pull $IMAGE_URL
  docker tag $IMAGE_URL $NEW_TAG
  docker rmi $IMAGE_URL -f
}

function  stop_and_start_dockerd_on_host()
{
  CHROOT=$1
  killall dockerd
#  sudo systemctl start docker
}


# Mount host system
function mount_system() {
    # In case this is a re-run move the cofi preload out of the way
    if [ -e $R/etc/ld.so.preload ]; then
        mv -v $R/etc/ld.so.preload $R/etc/ld.so.preload.disabled
    fi
    mount -t proc none $R/proc
    mount -t sysfs none $R/sys
    mount -o bind /dev $R/dev
    mount -o bind /dev/pts $R/dev/pts
    mount -o bind /dev/shm $R/dev/shm
    echo "nameserver 8.8.8.8" > $R/etc/resolv.conf
}

# Unmount host system
function umount_system() {
    umount -l $R/sys
    umount -l $R/proc
    umount -l $R/dev/pts
    umount -l $R/dev
    echo "" > $R/etc/resolv.conf
}

function sync_to() {
    local TARGET="${1}"
    if [ ! -d "${TARGET}" ]; then
        mkdir -p "${TARGET}"
    fi
    rsync -aHAXx --progress --delete ${R}/ ${TARGET}/
}

# Base debootstrap
function bootstrap() {
    # Required tools
    apt-get -y install binfmt-support debootstrap f2fs-tools \
    qemu-user-static rsync ubuntu-keyring whois ssl-cert

    # Use the same base system for all flavours.
    if [ ! -f "${R}/tmp/.bootstrap" ]; then
        if [ "${ARCH}" == "armv7l" ]; then
            debootstrap --verbose $RELEASE $R $MIRROR
        else
            qemu-debootstrap --verbose --arch=${CPU_ARCH} $RELEASE $R $MIRROR
        fi
        touch "$R/tmp/.bootstrap"
    fi
}

function generate_locale() {
    for LOCALE in $(chroot $R locale | cut -d'=' -f2 | grep -v : | sed 's/"//g' | uniq); do
        if [ -n "${LOCALE}" ]; then
            chroot $R locale-gen $LOCALE 
        fi
    done
}

# Set up initial sources.list
function apt_sources() {
    cat <<EOM >$R/etc/apt/sources.list
deb ${MIRROR} ${RELEASE} main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE} main restricted universe multiverse

deb ${MIRROR} ${RELEASE}-updates main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE}-updates main restricted universe multiverse

deb ${MIRROR} ${RELEASE}-security main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE}-security main restricted universe multiverse

deb ${MIRROR} ${RELEASE}-backports main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE}-backports main restricted universe multiverse
EOM

    cat <<EOM >$R/etc/apt/sources.list.d/ros-latest.list
deb ${ROS_MIRROR} xenial main
EOM
}

#TODO: may be use custom apt repo instead
function ubiquity_apt() {
    chroot $R apt-key adv --keyserver hkp://keyserver.ubuntu.com --recv-key C3032ED8
    chroot $R apt-get -y install apt-transport-https

    # Add the apt repo that has some binary builds
    cat <<EOM >$R/etc/apt/sources.list.d/ubiquity-latest.list
deb https://packages.ubiquityrobotics.com/ubuntu/ubiquity xenial main

deb https://packages.ubiquityrobotics.com/ubuntu/ubiquity xenial pi
EOM
    chroot $R apt-get update
}

function apt_upgrade() {
    # TODO: Check
    chroot $R apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 5523BAEEB01FA116
    chroot $R apt-get update
    chroot $R apt-get -y -u dist-upgrade
}

function apt_clean() {
    cat <<EOM >$R/etc/apt/sources.list
deb http://ports.ubuntu.com ${RELEASE} main restricted universe multiverse
deb-src http://ports.ubuntu.com  ${RELEASE} main restricted universe multiverse

deb http://ports.ubuntu.com ${RELEASE}-updates main restricted universe multiverse
deb-src http://ports.ubuntu.com  ${RELEASE}-updates main restricted universe multiverse

deb http://ports.ubuntu.com ${RELEASE}-security main restricted universe multiverse
deb-src http://ports.ubuntu.com  ${RELEASE}-security main restricted universe multiverse

deb http://ports.ubuntu.com ${RELEASE}-backports main restricted universe multiverse
deb-src http://ports.ubuntu.com ${RELEASE}-backports main restricted universe multiverse
EOM

    cat <<EOM >$R/etc/apt/sources.list.d/ros-latest.list
deb http://packages.ros.org/ros/ubuntu xenial main
EOM
    chroot $R apt-get -y autoremove
    chroot $R apt-get clean
}

# Install Ubuntu minimal
function ubuntu_minimal() {
    if [ ! -f "${R}/tmp/.minimal" ]; then
        chroot $R apt-get -y install ubuntu-minimal parted software-properties-common
        if [ "${FS}" == "f2fs" ]; then
            chroot $R apt-get -y install f2fs-tools
        fi
        touch "${R}/tmp/.minimal"
    fi
}

# Install Ubuntu standard
function ubuntu_standard() {
    if [ ! -f "${R}/tmp/.standard" ]; then
        chroot $R apt-get -y install ubuntu-standard
        touch "${R}/tmp/.standard"
    fi
}

function add_docker_gpg_key() {
  chroot $R apt-key adv --keyserver $KEYSERVER --recv-keys $DOCKER_GPG_KEY
}

function add_docker_deb_repo() {
  pre_reqs="apt-transport-https ca-certificates curl"
  chroot $R apt-get install -y -qq $pre_reqs

    # Add the apt repo that has some binary builds
    cat <<EOM >$R/etc/apt/sources.list.d/docker-ce.list
deb [arch=${CPU_ARCH}] https://download.docker.com/linux/ubuntu xenial stable
EOM
  add_docker_gpg_key
}

function install_docker() {
  add_docker_deb_repo
  chroot $R apt-get update
  chroot $R apt-get -y install docker-ce=17.12.1~ce-0~ubuntu
  chroot $R apt-mark hold docker-ce
}

function install_docker_py() {
  chroot $R pip install "docker==$DOCKER_PY_VER"
}

function install_docker_compose() {
  chroot $R pip install "docker_compose==$DOCKER_COMPOSE_VER"
}

function install_docker_runtime() {
  install_docker
  install_docker_py
  install_docker_compose
}

SALT_WHL="https://storage.googleapis.com/artifacts.rapyuta.io/salt-2017.7.0-py2-none-any.whl"

function install_salt() {
  chroot ${R} pip install $SALT_WHL
  # Force tornado version until the version is fixed in slat requirements
  chroot ${R} pip install "tornado>=4.2.1,<5.0"
  # Force pip version since pip >10.0.0 doesnot work well with salt
  chroot ${R} pip install "pip>=8.1.1,<10.0.0"
}

# Install meta packages
function install_meta() {
    local META="${1}"
    local RECOMMENDS="${2}"
    if [ "${RECOMMENDS}" == "--no-install-recommends" ]; then
        echo 'APT::Install-Recommends "false";' > $R/etc/apt/apt.conf.d/99noinstallrecommends
    else
        local RECOMMENDS=""
    fi

    cat <<EOM >$R/usr/local/bin/${1}.sh
#!/bin/bash
service dbus start
apt-get -f install
dpkg --configure -a
apt-get -y install ${RECOMMENDS} ${META}^
service dbus stop
EOM
    chmod +x $R/usr/local/bin/${1}.sh
    chroot $R /usr/local/bin/${1}.sh

    rm $R/usr/local/bin/${1}.sh

    if [ "${RECOMMENDS}" == "--no-install-recommends" ]; then
        rm $R/etc/apt/apt.conf.d/99noinstallrecommends
    fi
}

function create_groups() {
    chroot $R groupadd -f --system gpio
    chroot $R groupadd -f --system i2c
    chroot $R groupadd -f --system input
    chroot $R groupadd -f --system spi
    chroot $R groupadd -f ssl-cert

    # Create adduser hook
    cp files/adduser.local $R/usr/local/sbin/adduser.local
    chmod +x $R/usr/local/sbin/adduser.local
}

# Create default user
function create_user() {
    local DATE=$(date +%m%H%M%S)
    local PASSWD=$(mkpasswd -m sha-512 ${USERNAME} ${DATE})

    chroot $R adduser --gecos "Ubuntu User" --add_extra_groups --disabled-password ${USERNAME}

    chroot $R usermod -a -G sudo -p ${PASSWD} ${USERNAME}
}

function configure_ssh() {
    chroot $R apt-get -y install openssh-server sshguard
    cp files/sshdgenkeys.service $R/lib/systemd/system/
    mkdir -p $R/etc/systemd/system/ssh.service.wants
    chroot $R /bin/systemctl enable sshdgenkeys.service
    # chroot $R /bin/systemctl disable ssh.service
    chroot $R /bin/systemctl disable sshguard.service
}

function configure_network() {
    # Set up hosts
    echo ${IMAGE_HOSTNAME} >$R/etc/hostname
    cat <<EOM >$R/etc/hosts
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

127.0.1.1       ${IMAGE_HOSTNAME} ${IMAGE_HOSTNAME}.local
EOM

    # Set up interfaces
    cat <<EOM >$R/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

# The loopback network interface
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOM

#TODO: Check
    # Add entries to DNS in AP mode
    #cat <<EOM >$R/etc/NetworkManager/dnsmasq-shared.d/hosts.conf
#address=/robot.ubiquityrobotics.com/10.42.0.1
#address=/ubiquityrobot/10.42.0.1
#EOM

}

function configure_ros() {
    chroot $R update-locale LANG=C LANGUAGE=C LC_ALL=C LC_MESSAGES=POSIX

    chroot $R apt-get -y install python-rosinstall python-wstool
    chroot $R rosdep init
#FIXME: do we really need the below line
    chroot $R rm -rf /var/lib/apt/lists/*    
    chroot $R apt-get update
    
    #echo "source /opt/ros/kinetic/setup.bash" >> $R/home/$USERNAME/.bashrc
    chroot $R su $USERNAME -c "mkdir -p /home/${USERNAME}/catkin_ws/src"

    # It doesn't exsist yet, but we are sourcing it in anyway
    #echo "source /home/$USERNAME/catkin_ws/devel/setup.bash" >> $R/home/$USERNAME/.bashrc
    chroot $R su $USERNAME -c "rosdep update"

    chroot $R su $USERNAME -c 'cd /home/$USERNAME/catkin_ws/src'
    # chroot $R su $USERNAME -c 'git clone https://github.com/rapyuta/io_tutorials.git'
    chroot $R sh -c "cd /home/${USERNAME}/catkin_ws; rosdep update; rosdep install --from-paths src --ignore-src --rosdistro=kinetic -y"
    
    # Make sure that permissions are still sane
    chroot $R chown -R $USERNAME:$USERNAME /home/$USERNAME
    chroot $R su $USERNAME -c "bash -c 'cd /home/$USERNAME/catkin_ws; source /opt/ros/kinetic/setup.bash; catkin_make;'"
#TODO: check catkin build
#    chroot $R su $USERNAME -c "bash -c 'catkin build'"

    # Setup ros environment variables in a file
    chroot $R mkdir -p /etc/rapyuta
    cat <<EOM >$R/etc/rapyuta/env.sh
#!/bin/sh
export ROS_HOSTNAME=\$(hostname).local
export ROS_MASTER_URI=http://\$ROS_HOSTNAME:11311
EOM
    chroot $R chmod +x /etc/rapyuta/env.sh
    chroot $R chmod a+r /etc/rapyuta/env.sh

    # Make sure that the ros environment will be sourced for all users
#    echo "source /etc/rapyuta/env.sh" >> $R/home/$USERNAME/.bashrc
#    echo "source /etc/rapyuta/env.sh" >> $R/root/.bashrc

  #cp files/magni-base.sh $R/usr/sbin/magni-base
    #chroot $R chmod +x /usr/sbin/magni-base

    cat <<EOM >$R/etc/systemd/system/roscore.service 
[Unit]
After=NetworkManager.service time-sync.target
[Service]
Type=forking
User=rapyuta
# Start roscore as a fork and then wait for the tcp port to be opened
ExecStart=/bin/sh -c ". /opt/ros/kinetic/setup.sh; . /etc/rapyuta/env.sh; roscore & while ! echo exit | nc localhost 11311 > /dev/null; do sleep 1; done"
[Install]
WantedBy=multi-user.target
EOM
    
    if [ ${ROSCORE_AUTOSTART} -eq 1 ]; then
        chroot $R /bin/systemctl enable roscore.service
    else
        chroot $R /bin/systemctl disable roscore.service
    fi

}

function disable_services() {
    # Disable brltty because it spams syslog with SECCOMP errors
    if [ -e $R/sbin/brltty ]; then
        chroot $R /bin/systemctl disable brltty.service
    fi

    # Disable ntp because systemd-timesyncd will take care of this.
    if [ -e $R/etc/init.d/ntp ]; then
        chroot $R /bin/systemctl disable ntp
        chmod a-x $R/usr/sbin/ntpd
        cp files/prefer-timesyncd.service $R/lib/systemd/system/
        chroot $R /bin/systemctl enable prefer-timesyncd.service
    fi

    # Disable irqbalance because it is of little, if any, benefit on ARM.
    if [ -e $R/etc/init.d/irqbalance ]; then
        chroot $R /bin/systemctl disable irqbalance
    fi

    # Disable TLP because it is redundant on ARM devices.
    if [ -e $R/etc/default/tlp ]; then
        sed -i s'/TLP_ENABLE=1/TLP_ENABLE=0/' $R/etc/default/tlp
        chroot $R /bin/systemctl disable tlp.service
        chroot $R /bin/systemctl disable tlp-sleep.service
    fi

    # Disable apport because these images are not official
    if [ -e $R/etc/default/apport ]; then
        sed -i s'/enabled=1/enabled=0/' $R/etc/default/apport
        chroot $R /bin/systemctl disable apport.service
        chroot $R /bin/systemctl disable apport-forward.socket
    fi

    # Disable whoopsie because these images are not official
    if [ -e $R/usr/bin/whoopsie ]; then
        chroot $R /bin/systemctl disable whoopsie.service
    fi

    # Disable mate-optimus
    if [ -e $R/usr/share/mate/autostart/mate-optimus.desktop ]; then
        rm -f $R/usr/share/mate/autostart/mate-optimus.desktop || true
    fi
}

function configure_hardware() {
    local FS="${1}"
    if [ "${FS}" != "ext4" ] && [ "${FS}" != 'f2fs' ]; then
        echo "ERROR! Unsupport filesystem requested. Exitting."
        exit 1
    fi

    # Install the RPi PPA
    chroot $R apt-add-repository -y ppa:ubuntu-pi-flavour-makers/ppa
    chroot $R apt-add-repository -y ppa:ubuntu-raspi2/ppa-rpi3
    chroot $R apt-get update
    chroot $R apt-add-repository -y ppa:ubuntu-raspi2/ppa
    chroot $R apt-get update

    # Firmware Kernel installation
    chroot $R apt-get -y install linux-firmware libraspberrypi-bin \
    libraspberrypi-dev libraspberrypi-doc libraspberrypi0 u-boot-rpi rpi-update

    chroot $R rpi-update

    # Raspberry Pi 3 WiFi firmware. Supplements what is provided in linux-firmware
    cp -v firmware/* $R/lib/firmware/brcm/
    chown root:root $R/lib/firmware/brcm/*

# install custom build kernel, modules and dtbs
    cp -v files/kernel8.img $R/boot/
    cp -rv files/overlays $R/boot/ 
    cp -v files/dtbs/* $R/boot/
    tar xvfj files/4.14.54-v8.tar.bz2 -C $R/lib/modules/
    cp -v files/config.armv8.txt $R/boot/config.txt


    if [ "${GUI}" -eq "1" ]; then
        # Install fbturbo drivers on non composited desktop OS
        # fbturbo causes VC4 to fail
        if [ "${GUI}" -eq 1]; then
            chroot $R apt-get -y install xserver-xorg-video-fbturbo
        fi


        # omxplayer
        # - Requires: libpcre3 libfreetype6 fonts-freefont-ttf dbus libssl1.0.0 libsmbclient libssh-4
        cp deb/omxplayer_0.3.7-git20160923-dfea8c9_armhf.deb $R/tmp/omxplayer.deb
        chroot $R apt-get -y install /tmp/omxplayer.deb
    fi

    if [ "${HEADLESS}" -eq 0 ]; then
        # Install fbturbo drivers on non composited desktop OS
        # fbturbo causes VC4 to fail
        if [ "${GUI}" -eq 1]; then
            chroot $R apt-get -y install xserver-xorg-video-fbturbo
        fi

        # omxplayer
        # - Requires: libpcre3 libfreetype6 fonts-freefont-ttf dbus libssl1.0.0 libsmbclient libssh-4
        cp deb/omxplayer_0.3.7-git20160923-dfea8c9_armhf.deb $R/tmp/omxplayer.deb
        chroot $R apt-get -y install /tmp/omxplayer.deb
    fi

    # Install Raspberry Pi system tweaks
    chroot $R apt-get -y install fbset raspberrypi-sys-mods

    # Enable hardware random number generator
    chroot $R apt-get -y install rng-tools

    # copies-and-fills
    # Create /spindel_install so cofi doesn't segfault when chrooted via qemu-user-static
    #touch $R/spindle_install
    #cp deb/raspi-copies-and-fills_0.5-1_armhf.deb $R/tmp/cofi.deb
    #chroot $R apt-get -y install /tmp/cofi.deb

    # Add /root partition resize
    if [ "${FS}" == "ext4" ]; then
        CMDLINE_INIT="init=/usr/lib/raspi-config/init_resize.sh"
        # Add the first boot filesystem resize, init_resize.sh is
        # shipped in raspi-config.
        cp files/resize2fs_once	$R/etc/init.d/
        chroot $R /bin/systemctl enable resize2fs_once        
    else
        CMDLINE_INIT=""
    fi
    chroot $R apt-get -y install raspi-config

    # Add /boot/config.txt
    #cp files/config.txt $R/boot/

    # Add /boot/cmdline.txt
    echo "dwc_otg.lpm_enable=0 console=ttyAMA0,115200n8 console=tty1 root=/dev/mmcblk0p2 rootfstype=${FS} elevator=deadline fsck.repair=yes rootwait quiet splash plymouth.ignore-serial-consoles ${CMDLINE_INIT}" > $R/boot/cmdline.txt

    # Set up fstab
    cat <<EOM >$R/etc/fstab
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p2  /               ${FS}   defaults,noatime  0       1
/dev/mmcblk0p1  /boot/          vfat    defaults          0       2
EOM
}

function install_software() {

    # Raspicam needs to be after configure_hardware
    #chroot $R apt-get -y install ros-kinetic-raspicam-node
    # NOTE: this package is only available for armv7

    #chroot $R apt-get -y install pifi
    #mkdir -p $R/etc/pifi
    #cp files/default_ap.em $R/etc/pifi/default_ap.em

    # FIXME - Replace with meta packages(s)
    # Install some useful utils
    chroot $R apt-get -y install \
    vim nano htop minicom network-manager

    chroot $R systemctl enable network-manager
   
# Python
    chroot $R apt-get -y install \
    python-minimal \
    python-pip \
    python-setuptools
}

function clean_up() {
    rm -f $R/etc/apt/*.save || true
    rm -f $R/etc/apt/sources.list.d/*.save || true
    rm -f $R/etc/resolvconf/resolv.conf.d/original
    rm -f $R/run/*/*pid || true
    rm -f $R/run/*pid || true
    rm -f $R/run/cups/cups.sock || true
    rm -f $R/run/uuidd/request || true
    rm -f $R/etc/*-
    rm -rf $R/tmp/*
    rm -f $R/var/crash/*
    rm -f $R/var/lib/urandom/random-seed

    # Build cruft
    rm -f $R/var/cache/debconf/*-old || true
    rm -f $R/var/lib/dpkg/*-old || true
    rm -f $R/var/cache/bootstrap.log || true
    truncate -s 0 $R/var/log/lastlog || true
    truncate -s 0 $R/var/log/faillog || true

    # SSH host keys
    rm -f $R/etc/ssh/ssh_host_*key
    rm -f $R/etc/ssh/ssh_host_*.pub

    # Clean up old Raspberry Pi firmware and modules
    rm -f $R/boot/.firmware_revision || true
    rm -rf $R/boot.bak || true
    rm -rf $R/lib/modules.bak || true

    # Potentially sensitive.
    rm -f $R/root/.bash_history
    rm -f $R/root/.ssh/known_hosts

    # Remove bogus home directory
    # if [ -d $R/home/${SUDO_USER} ]; then
    #     rm -rf $R/home/${SUDO_USER} || true
    # fi

    # Machine-specific, so remove in case this system is going to be
    # cloned.  These will be regenerated on the first boot.
    rm -f $R/etc/udev/rules.d/70-persistent-cd.rules
    rm -f $R/etc/udev/rules.d/70-persistent-net.rules
    rm -f $R/etc/NetworkManager/system-connections/*
    [ -L $R/var/lib/dbus/machine-id ] || rm -f $R/var/lib/dbus/machine-id
    echo '' > $R/etc/machine-id

    # Enable cofi
    if [ -e $R/etc/ld.so.preload.disabled ]; then
        mv -v $R/etc/ld.so.preload.disabled $R/etc/ld.so.preload
    fi

    rm -rf $R/tmp/.bootstrap || true
    rm -rf $R/tmp/.minimal || true
    rm -rf $R/tmp/.standard || true
    rm -rf $R/spindle_install || true   
}

function make_raspi3_image() {
    # Build the image file
    local FS="${1}"
    local GB=${2}

    if [ "${FS}" != "ext4" ] && [ "${FS}" != 'f2fs' ]; then
        echo "ERROR! Unsupport filesystem requested. Exitting."
        exit 1
    fi

    if [ ${GB} -ne 4 ] && [ ${GB} -ne 8 ] && [ ${GB} -ne 16 ]; then
        echo "ERROR! Unsupport card image size requested. Exitting."
        exit 1
    fi

    if [ ${GB} -eq 4 ]; then
        SEEK=3750
        SIZE=7546880
        SIZE_LIMIT=3685
    elif [ ${GB} -eq 8 ]; then
        SEEK=7680
        SIZE=15728639
        SIZE_LIMIT=7615
    elif [ ${GB} -eq 16 ]; then
        SEEK=15360
        SIZE=31457278
        SIZE_LIMIT=15230
    fi

    # If a compress version exists, remove it.
    rm -f "${BASEDIR}/${IMAGE}.bz2" || true

    dd if=/dev/zero of="${BASEDIR}/${IMAGE}" bs=1M count=1
    dd if=/dev/zero of="${BASEDIR}/${IMAGE}" bs=1M count=0 seek=${SEEK}

    sfdisk -f "$BASEDIR/${IMAGE}" <<EOM
unit: sectors
1 : start=     2048, size=   131072, Id= c, bootable
2 : start=   133120, size=  ${SIZE}, Id=83
3 : start=        0, size=        0, Id= 0
4 : start=        0, size=        0, Id= 0
EOM

    BOOT_LOOP="$(losetup -o 1M --sizelimit 64M -f --show ${BASEDIR}/${IMAGE})"
    ROOT_LOOP="$(losetup -o 65M --sizelimit ${SIZE_LIMIT}M -f --show ${BASEDIR}/${IMAGE})"
    mkfs.vfat -n PI_BOOT -S 512 -s 16 -v "${BOOT_LOOP}"
    if [ "${FS}" == "ext4" ]; then
        mkfs.ext4 -L PI_ROOT -m 0 "${ROOT_LOOP}"
    else
        mkfs.f2fs -l PI_ROOT -o 1 "${ROOT_LOOP}"
    fi
    MOUNTDIR="${BUILDDIR}/mount"
    mkdir -p "${MOUNTDIR}"
    mount "${ROOT_LOOP}" "${MOUNTDIR}"
    mkdir -p "${MOUNTDIR}/boot"
    mount "${BOOT_LOOP}" "${MOUNTDIR}/boot"
    rsync -a --progress "$R/" "${MOUNTDIR}/"
    umount -l "${MOUNTDIR}/boot"
    umount -l "${MOUNTDIR}"
    losetup -d "${ROOT_LOOP}"
    losetup -d "${BOOT_LOOP}"
}

function make_raspi2_image() {
    # Build the image file
    local FS="${1}"
    local SIZE_IMG="${2}"
    local SIZE_BOOT="64MiB"

    if [ "${FS}" != "ext4" ] && [ "${FS}" != 'f2fs' ]; then
        echo "ERROR! Unsupport filesystem requested. Exitting."
        exit 1
    fi

    # Remove old images.
    rm -f "${IMAGEDIR}/${IMAGE}" || true

    # Create an empty file file.
    dd if=/dev/zero of="${IMAGEDIR}/${IMAGE}" bs=1MB count=1
    dd if=/dev/zero of="${IMAGEDIR}/${IMAGE}" bs=1MB count=0 seek=$(( ${SIZE_IMG} * 1000 ))

    # Initialising: msdos
    parted -s ${IMAGEDIR}/${IMAGE} mktable msdos
    echo "Creating /boot partition"
    parted -a optimal -s ${IMAGEDIR}/${IMAGE} mkpart primary fat32 1 "${SIZE_BOOT}"
    echo "Creating /root partition"
    parted -a optimal -s ${IMAGEDIR}/${IMAGE} mkpart primary ext4 "${SIZE_BOOT}" 100%

    PARTED_OUT=$(parted -s ${IMAGEDIR}/${IMAGE} unit b print)
    BOOT_OFFSET=$(echo "${PARTED_OUT}" | grep -e '^ 1'| xargs echo -n \
    | cut -d" " -f 2 | tr -d B)
    BOOT_LENGTH=$(echo "${PARTED_OUT}" | grep -e '^ 1'| xargs echo -n \
    | cut -d" " -f 4 | tr -d B)

    ROOT_OFFSET=$(echo "${PARTED_OUT}" | grep -e '^ 2'| xargs echo -n \
    | cut -d" " -f 2 | tr -d B)
    ROOT_LENGTH=$(echo "${PARTED_OUT}" | grep -e '^ 2'| xargs echo -n \
    | cut -d" " -f 4 | tr -d B)

    BOOT_LOOP=$(losetup --show -f -o ${BOOT_OFFSET} --sizelimit ${BOOT_LENGTH} ${IMAGEDIR}/${IMAGE})
    ROOT_LOOP=$(losetup --show -f -o ${ROOT_OFFSET} --sizelimit ${ROOT_LENGTH} ${IMAGEDIR}/${IMAGE})
    echo "/boot: offset ${BOOT_OFFSET}, length ${BOOT_LENGTH}"
    echo "/:     offset ${ROOT_OFFSET}, length ${ROOT_LENGTH}"

    mkfs.vfat -n BOOT -S 512 -s 16 -v "${BOOT_LOOP}"
    if [ "${FS}" == "ext4" ]; then
        mkfs.ext4 -L RFS -m 0 -O ^huge_file "${ROOT_LOOP}"
    else
        mkfs.f2fs -l RFS -o 1 "${ROOT_LOOP}"
    fi

    MOUNTDIR="${BUILDDIR}/mount"
    mkdir -p "${MOUNTDIR}"
    mount -v "${ROOT_LOOP}" "${MOUNTDIR}" -t "${FS}"
    mkdir -p "${MOUNTDIR}/boot"
    mount -v "${BOOT_LOOP}" "${MOUNTDIR}/boot" -t vfat
    #rsync -aHAXx "$R/" "${MOUNTDIR}/"
    rsync --info=progress2 -aHAXx "$R/" "${MOUNTDIR}/"
    sync
    umount -l "${MOUNTDIR}/boot"
    umount -l "${MOUNTDIR}"
    losetup -d "${ROOT_LOOP}"
    losetup -d "${BOOT_LOOP}"

    chmod a+r ${IMAGEDIR}/${IMAGE}
}

function write_image_name() {
    cat <<EOM >./latest_image
${IMAGEDIR}/${IMAGE}
EOM
    chmod a+r ./latest_image
}

function make_hash() {
    local FILE="${1}"
    local HASH="sha256"
    local KEY="FFEE1E5C"
    if [ ! -f ${FILE}.${HASH}.sign ]; then
        if [ -f ${FILE} ]; then
            ${HASH}sum ${FILE} > ${FILE}.${HASH}
            sed -i -r "s/ .*\/(.+)/  \1/g" ${FILE}.${HASH}
            gpg --default-key ${KEY} --armor --output ${FILE}.${HASH}.sign --detach-sig ${FILE}.${HASH}
        else
            echo "WARNING! Didn't find ${FILE} to hash."
        fi
    else
        echo "Existing signature found, skipping..."
    fi
}

function make_tarball() {
    if [ ${MAKE_TARBALL} -eq 1 ]; then
        rm -f "${IMAGEDIR}/${TARBALL}" || true
        tar -cSf "${IMAGEDIR}/${TARBALL}" $R
        make_hash "${IMAGEDIR}/${TARBALL}"
    fi
}

function compress_image() {
    if [ ! -e "${IMAGEDIR}/${IMAGE}.xz" ]; then
        echo "Compressing to: ${IMAGEDIR}/${IMAGE}.xz"
        xz ${IMAGEDIR}/${IMAGE}
    fi
   # make_hash "${IMAGEDIR}/${IMAGE}.xz"
}

function ros_packages() {
    wget https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -O - | chroot $R apt-key add -

    chroot $R apt-get update
    chroot $R apt-get -y install ros-kinetic-ros-base ros-kinetic-robot-upstart
}

function stage_01_base() {
    R="${BASE_R}"
    # bootstrap
    mount_system
    generate_locale
    apt_sources
    apt_upgrade
    ubiquity_apt
    ubuntu_minimal
    #ubuntu_standard
    ros_packages
    install_docker
    apt_clean
    umount_system
    sync_to "${DESKTOP_R}"
}

function stage_02_desktop() {
    R="${BASE_R}"
    mount_system
    apt_sources
    chroot $R apt-get update

    if [ "${GUI}" -eq 1 ]; then
        install_meta lubuntu-core --no-install-recommends
        install_meta lubuntu-desktop --no-install-recommends
    else
        echo "Skipping desktop install for ${FLAVOUR}"
    fi

    create_groups
    create_user
    configure_ssh
    configure_network
    configure_ros
    disable_services
    apt_upgrade
    apt_clean
    umount_system
    clean_up
    sync_to ${BASE_R}
    make_tarball
}

function stage_03_raspi2() {
    R=${BASE_R}
    mount_system
    apt_sources
    chroot $R apt-get update
    configure_hardware ${FS_TYPE}
    install_software
    install_docker_py
    install_docker_compose
    install_salt
    apt_upgrade
    apt_clean
    clean_up
    umount_system
    make_raspi2_image ${FS_TYPE} ${FS_SIZE}
}

function stage_04_corrections() {
    R=${BASE_R}
    mount_system
    apt_sources

    if [ "${RELEASE}" == "xenial" ]; then
      # Upgrade Xorg using HWE.
      chroot $R apt-get install -y --install-recommends \
      xserver-xorg-core-hwe-16.04 \
      xserver-xorg-input-all-hwe-16.04 \
      xserver-xorg-input-evdev-hwe-16.04 \
      xserver-xorg-input-synaptics-hwe-16.04 \standard
      xserver-xorg-input-wacom-hwe-16.04 \
      xserver-xorg-video-all-hwe-16.04 \
      xserver-xorg-video-fbdev-hwe-16.04 \
      xserver-xorg-video-vesa-hwe-16.04
    fi

    # Insert other corrections here.

    chmod a+r -R $R/etc/apt/sources.list.d/
standard
    apt_clean
    clean_up
    umount_system
    make_raspi2_image ${FS_TYPE} ${FS_SIZE}
}


REGISTRY=docker-registry-default.apps.v39.rapyuta.io
NAMESPACE=v7-eta-rapyuta-images
# Jobs
stage_01_base
#systemctl stop docker
#dockerd -g ${R}/var/lib/docker &
#docker_pull $REGISTRY/$NAMESPACE/ros-base-kinetic-arm32v7 ros-base-kinetic-arm32v7
#docker_pull $REGISTRY/$NAMESPACE/telegraf-arm32v7 telegraf-arm32v7
#docker_pull $REGISTRY/$NAMESPACE/devicemanager-client-arm32v7 dm-client-arm32v7
#docker_pull $REGISTRY/$NAMESPACE/cloud-bridge-arm32v7 cloud-bridge-kinetic-arm32v7
#docker_pull rrdockerhub/io-tutorials-arm32v7 io-tutorials-arm32v7
#killall dockerd
#systemctl start docker
stage_02_desktop
stage_03_raspi2
#stage_04_corrections
write_image_name
compress_image
