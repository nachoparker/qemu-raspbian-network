# qemu-raspbian-network
Launch a raspbian image on qemu with network connectivity

```
git clone https://github.com/nachoparker/qemu-raspbian-network.git
cd qemu-raspbian-network
wget https://downloads.raspberrypi.org/raspbian_lite_latest -O raspbian_lite_latest.zip
unzip raspbian_lite_latest.zip
sudo ./qemu-pi.sh *-raspbian-jessie-lite.img
```

Note that it is recommended to use `qemu-arm` not older than 2.8.0 (see code)

See details on https://ownyourbits.com/2017/02/06/raspbian-on-qemu-with-network-access/
