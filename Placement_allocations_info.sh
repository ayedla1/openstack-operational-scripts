#!/bin/bash
echo "This script will compare the placement API allocations and actual no.of VM's on the compute nodes. If the count doesn't match please enter the ID that exists in allocation list but not in Vm list of compute node and the script will automatically update the allocation to right compute."
sleep 1s
source ~/keystonercv3
host=$(openstack endpoint list --service placement --interface internal | awk '{print $14}' | sed 2d |sed /^$/d)
echo " Issuing token...."
a=$(openstack token issue | awk '{print $4}' | sed -n 5p)
#echo "$a"
echo "Token issued...."
#echo "STARTING COMPARING ALLOCATIONS AND VM'S ON ALL COMPUTE NODES"
echo "List of hypervisors"
#for i in $(nova hypervisor-list | awk '{print  $4}' | sed 2d |sort -n)
#do
nova hypervisor-list | awk '{print  $4}' | sed 2d |sort -n
read -p "Enter the Name of the hypervisor that you want to check and press enter>> " h
b1=$(nova hypervisor-list | grep $h | awk '{print  $2}' | sed 2d)
#echo "curl -X GET -H 'OpenStack-API-Version: placement 1.11' -H 'content-type: application/json' -H 'X-Auth-Token: '"$a"'' http://$host:8778/resource_providers/$b/allocations |python -m json.tool"
echo "BELOW ARE THE ALLOCATIONS FOR COMPUTE   ---------$h--------- "
curl -s -X GET -H 'OpenStack-API-Version: placement 1.11' -H 'content-type: application/json' -H 'X-Auth-Token: '"$a"'' $host/resource_providers/$b1/allocations |python -m json.tool| grep -i -B1 resources | grep "[0-9]" | sed 's/.\{3\}$//g' | sed 's/"//g' | sort -n
count1=$(curl -s -X GET -H 'OpenStack-API-Version: placement 1.11' -H 'content-type: application/json' -H 'X-Auth-Token: '"$a"'' $host/resource_providers/$b1/allocations |python -m json.tool| grep -i -B1 resources | grep "[0-9]" | sed 's/.\{3\}$//g' | sed 's/"//g'|wc -l)
echo "Total no.of allocations $count1"
echo "Please verify the ID's of VM's with the above ouput"
c=$(nova hypervisor-list |awk '{print $2, $4}' | sed 2d |grep  $h |awk '{print $2}')
echo "GETTING THE LIST OF VM'S ON  $c ...."
#sleep 2s
nova hypervisor-servers $c | awk '{print $2}' |sed 2d | sort -n
count2=$(nova hypervisor-servers $c | awk '{print $2}' |column -t |sed 1d | wc -l)
echo "Total no.of VM's on hypervisor $count2"
if [ $count1 = $count2 ]
then
echo "The count of placement-api allocations matched the count of VM's on hypervisor. No issues found"
else
#diff <(curl -s -X GET -H 'OpenStack-API-Version: placement 1.11' -H 'content-type: application/json' -H 'X-Auth-Token: '"$a"'' http://$host:8778/resource_providers/$b1/allocations |python -m json.tool| grep -i -B1 resources | grep "[0-9]" | sed 's/.\{3\}$//g' | sed 's/"//g' | sort -n) <(nova hypervisor-servers $c | awk '{print $2}' |sed 2d | sort -n)
read -p "Enter the ID of the VM you found that doesn't exist on the hypervisor but present in placement allocations >>>" d
e=$(nova show $d |grep -i hypervisor_hostname | awk '{print $4}')
echo "The VM  originally exists on hypervisor $e"
curl -s -X GET -H 'OpenStack-API-Version: placement 1.11' -H 'content-type: application/json' -H 'X-Auth-Token: '"$a"'' $host/resource_providers/$b1/allocations |python -m json.tool |grep -A4 $d
echo "Please enter the values from the above ouput"
read -p "Enter the value of VCPU from above output and press enter >>" VCPU
read -p "Enter the value of MEMORY_MB from above output and press enter >>" MEMORY_MB
read -p "Enter the value of DISK_GB from above output and press enter >>" DISK_GB
project_id=$(nova show $d | grep -ie tenant_id | awk '{print $4}')
user_id=$(nova show $d | grep -ie user_id | awk '{print $4}')
uuid=$(nova hypervisor-list | grep $e | awk '{print  $2}' | sed 2d)
curl -s -X  PUT http://$host:8778/allocations/$d -H 'OpenStack-API-Version: placement 1.11' -H 'content-type: application/json' -H 'X-Auth-Token: '"$a"'' -d '{ "allocations": [{"resource_provider": {"uuid": "'$uuid'"}, "resources": {"VCPU": '$VCPU', "MEMORY_MB": '$MEMORY_MB', "DISK_GB": '$DISK_GB'}}], "project_id": "'$project_id'", "user_id":"'$user_id'"}'
echo "Allocations are updated to VM $d"
fi
#done
openstack token revoke $a
