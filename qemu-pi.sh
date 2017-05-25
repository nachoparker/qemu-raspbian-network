#!/bin/bash

# Run a raspbian image in qemu with network access
# Tested with 2017-01-11-raspbian-jessie.img (and lite)
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# Usage:
#   qemu-pi.sh 2017-01-11-raspbian-jessie.img # or any other image
#
# Notes:
#   If NO_NETWORK=0 it will include your network interface on a bridge
#     with the same gateway and routes, and restore it when exiting qemu
#
#   If NO_NETWORK=1 (default), that configuration will have to be done manually
#     in order to obtain network access inside raspbian
#
#   It requires a modified kernel image for qemu. (variable $KERNEL)
#
#   It enables SSH on the image
#
#   For the network bridge configuration, this needs to be in /etc/sudoers
#      Cmnd_Alias      QEMU=/usr/bin/ip,/usr/bin/modprobe,/usr/bin/brctl
#      %kvm     ALL=NOPASSWD: QEMU

IMG=$1
KERNEL=kernel-qemu-4.4.34-jessie

NO_NETWORK=1            # set to 1 to skip network configuration
IFACE=enp3s0            # interface that we currently use for internet
BRIDGE=br0              # name for the bridge we will create to share network with the raspbian img
MAC='52:54:be:36:42:a9' # comment this line for random MAC (maybe annoying if on DHCP)
BINARY_PATH=/usr/bin    # path prefix for binaries
NO_GRAPHIC=0            # set to 1 to start in no graphic mode

# sanity checks
test -f $IMG && test -f $KERNEL || { echo "$IMG or $KERNEL not found"; exit; }

[[ "$IFACE" == "" ]] || [[ "$BRIDGE" == "" ]] && NO_NETWORK=1

# some more checks
[[ "$NO_NETWORK" != "1" ]] && {
    IP=$( ip a | grep "global $IFACE" | grep -oP '\d{1,3}(.\d{1,3}){3}' | head -1 )
    [[ "$IP" == "" ]]      && { echo "no IP found for $IFACE"; NO_NETWORK=1; }
    type brctl &>/dev/null || { echo "brctl is not installed"; NO_NETWORK=1; }
    modprobe tun &>/dev/null
    grep -q tun <(lsmod)   || { echo "need tun module"       ; NO_NETWORK=1; }
}

# network configuration
[[ "$NO_NETWORK" != "1" ]] && {
  test -f /etc/qemu-ifup   && cp -nav /etc/qemu-ifup   /etc/qemu-ifup.bak
  test -f /etc/qemu-ifdown && cp -nav /etc/qemu-ifdown /etc/qemu-ifdown.bak

  cat > /etc/qemu-ifup <<EOF
#!/bin/sh
echo "Executing /etc/qemu-ifup"
echo "Bringing up \$1 for bridged mode..."
sudo $BINARY_PATH/ip link set \$1 up promisc on
echo "Adding \$1 to $BRIDGE..."
sudo $BINARY_PATH/brctl addif $BRIDGE \$1
sleep 2
EOF

  cat > /etc/qemu-ifdown <<EOF
#!/bin/sh
echo "Executing /etc/qemu-ifdown"
sudo $BINARY_PATH/ip link set \$1 down
sudo $BINARY_PATH/brctl delif $BRIDGE \$1
sudo $BINARY_PATH/ip link delete dev \$1
EOF

  chmod 750 /etc/qemu-ifdown /etc/qemu-ifup
  chown root:kvm /etc/qemu-ifup /etc/qemu-ifdown

  IPFW=$( sysctl net.ipv4.ip_forward | cut -d= -f2 )
  sysctl net.ipv4.ip_forward=1

  ROUTES=$( ip r | grep $IFACE                       )
  BRROUT=$( echo "$ROUTES" | sed "s=$IFACE=$BRIDGE=" )
  brctl addbr $BRIDGE
  brctl addif $BRIDGE $IFACE
  ip l set up dev $BRIDGE
  ip r flush dev $IFACE
  ip a a $IP dev $BRIDGE
  echo "$BRROUT" | tac | while read l; do ip r a $l; done

  precreationg=$(ip tuntap list | cut -d: -f1 | sort)
  ip tuntap add user $USER mode tap
  postcreation=$(ip tuntap list | cut -d: -f1 | sort)
  TAPIF=$(comm -13 <(echo "$precreationg") <(echo "$postcreation"))
  [[ "$MAC" == "" ]] && printf -v MAC "52:54:%02x:%02x:%02x:%02x" \
    $(( $RANDOM & 0xff)) $(( $RANDOM & 0xff )) $(( $RANDOM & 0xff)) $(( $RANDOM & 0xff ))

  NET_ARGS="-net nic,macaddr=$MAC -net tap,ifname=$TAPIF"
}

# prepare the image
SECTOR1=$( fdisk -l $IMG | grep FAT32 | awk '{ print $2 }' )
SECTOR2=$( fdisk -l $IMG | grep Linux | awk '{ print $2 }' )
OFFSET1=$(( SECTOR1 * 512 ))
OFFSET2=$(( SECTOR2 * 512 ))

# make 'boot' vfat partition available locally
mkdir -p tmpmnt
mount $IMG -o offset=$OFFSET1 tmpmnt
touch tmpmnt/ssh   # this enables ssh
umount tmpmnt

# make 'linux' ext4 partition available locally
mount $IMG -o offset=$OFFSET2 tmpmnt
cat > tmpmnt/etc/udev/rules.d/90-qemu.rules <<EOF
KERNEL=="sda", SYMLINK+="mmcblk0"
KERNEL=="sda?", SYMLINK+="mmcblk0p%n"
KERNEL=="sda2", SYMLINK+="root"
EOF

# Work around a known issue with qemu-arm, versatile board and raspbian for at least qemu-arm < 2.8.0
# This works but modifies the image so it is recommended to upgrade QEMU
# Ref: http://stackoverflow.com/questions/38837606/emulate-raspberry-pi-raspbian-with-qemu

QEMU_MAJOR=$( qemu-system-arm --version | grep -oP '\d+\.\d+\.\d+' | head -1 | cut -d. -f1 )
QEMU_MINOR=$( qemu-system-arm --version | grep -oP '\d+\.\d+\.\d+' | head -1 | cut -d. -f2 )

if [[ $QEMU_MAJOR == 2 ]] && [[ $QEMU_MINOR < 8 ]]; then sed -i '/^[^#].*libarmmem.so/s/^\(.*\)$/#\1/' tmpmnt/etc/ld.so.preload; fi
if [[ $QEMU_MAJOR <  2 ]]                         ; then sed -i '/^[^#].*libarmmem.so/s/^\(.*\)$/#\1/' tmpmnt/etc/ld.so.preload; fi

umount -l tmpmnt
rmdir tmpmnt &>/dev/null

# do it
qemu-system-arm -kernel $KERNEL -cpu arm1176 -m 256 -M versatilepb $NET_ARGS \
  $( [[ "$NO_GRAPHIC" != "1" ]] || printf %s '-nographic' ) \
  -no-reboot -append "root=/dev/sda2 panic=1 $( [[ "$NO_GRAPHIC" != "1" ]] || printf %s 'vga=normal console=ttyAMA0' )" -drive format=raw,file=$IMG \

# restore network to what it was
[[ "$NO_NETWORK" != "1" ]] && {
  ip l set down dev $TAPIF
  ip tuntap del $TAPIF mode tap
  sysctl net.ipv4.ip_forward="$IPFW"
  ip l set down dev $BRIDGE
  brctl delbr $BRIDGE
  echo "$ROUTES" | tac | while read l; do ip r a $l; done
}

# License
#
# This script is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this script; if not, write to the
# Free Software Foundation, Inc., 59 Temple Place, Suite 330,
# Boston, MA  02111-1307  USA

