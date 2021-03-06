#!/bin/bash
echo "This script can be ran on any ceph node and this works on ceph Luminous version. Results may vary depending on your ceph version"
echo "Collecting ceph cluster data"
a=$(hostname)
b=$(date +"%m-%d-%y")
c=$(hostname -d | cut -d "." -f 1)
mkdir -p cephinfo.$a
cd cephinfo.$a
#sudo lshw > lshw_$a.$c.txt
#sudo dmidecode >dmidecode_$a.$c.txt
#sudo lspci -v >lspci_$a.$c.txt
#DISK=$(lsblk |grep disk |awk '{ print $1 }' )
#for I in $DISK; do smartctl --all /dev/$I >smart-$I_$a.$c.txt; done
#sudo cat /sys/class/thermal/thermal_zone*/temp > temps_$a.$c.txt
sudo cat /etc/lsb-release >lsb-release_$a.$c.txt
#sudo dpkg -l >pkg_versions_$a.txt

echo "Collecting ceph  version ..."
sudo ceph tell osd.* version >>osdversion.$c.txt
echo "Collecting monitor version..."
sudo ceph tell mon.* version >>monversion.$c.txt
echo "Collecting ceph configuration .."
sudo cat /etc/ceph/ceph.conf > cephconfig.$c.txt
echo "Collecting ceph cluster present status..."
sudo ceph -s  > cephstatus.$c.txt
echo "Collecting ceph health detail ...."
sudo ceph health detail >  cephhealthdetail.$c.txt
echo "Collecting monmap..."
sudo ceph mon dump  -o monmap.$c.txt
echo "Collecting ceph df ..."
sudo ceph df   -o ceph_df.$c.txt
echo "Collecting ceph osd df ..."
sudo ceph osd df  -o ceph_osd_df.$c.txt
echo "Collecting ceph osd dump ..."
sudo ceph osd dump  -o ceph_osd_dump.$c.txt
echo "Collecting rados df ..."
sudo rados df  > rados_df.$c.txt
echo "Collecting ceph report ..."
sudo ceph report -o ceph_report.$c.txt
echo "Compiling crush map ..."
sudo ceph osd getcrushmap -o compiledmap
sudo crushtool -d  compiledmap -o crushmap.$c.txt
echo "Collecting ceph auth list..."
sudo ceph auth list  | sed 's/AQ[^=]*==/KEY/g' > ceph_auth_ls.$c.txt

cd ..
sudo tar -cjvf cephdata.$c.$b.tar.bz2 cephinfo.$a
sudo rm -r cephinfo.$a

