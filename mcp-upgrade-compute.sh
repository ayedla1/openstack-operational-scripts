#!/bin/bash
printf "Make sure to run the script from salt-master node\n"
if  [[  $# == 0 ]];  then
      echo "Usage is: ./upgrade-compute.sh cmp001 cmp002.. cmp**"; exit;
elif [[ $# -gt 2 ]] && [[ $# -le 8 ]]; then
      echo "You are trying to Upgrade more than $# computes at the same time.Make sure before proceeding further"
      read -p "Are you sure you want to proceed?(y/N)" prompt
      if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]; then
         upgrade_compute
      else
         exit;
      fi
elif [[ $# -gt 8 ]]; then
      echo "Too Many arguments have passed. Upgrade of $# computes on a single stretch would cause heavy load and migration issues. Less than 3 compute node upgrade is recommended"; exit;
fi
echo "The Compute nodes that are going to be updated are: $@"

## This function is for silencing all alerts for a node in ALertManager
function silence_alerts_for_nodes(){
  echo "silencing all alerts from nodes $@ for 3 hours"
  url=$(sudo salt-call pillar.get linux:network:host:mon:address --out txt | awk '{print $2}')
  starts=$(date -u  '+%FT%T.%3NZ')
  end=$(date -u -d '+3 hour' '+%FT%T.%3NZ')
  for i in $@; do
     curl   http://$url:15011/api/v1/silences -X POST -d '{"comment": "silence","createdBy": "Upgrade Team","startsAt": "'"${starts}"'", "endsAt": "'"${end}"'","matchers": [{"isRegex": true,"name": "host","value": "'"${i}.*"'"}]}'; done
}
#silence_alerts_for_nodes

## Delete all the silences created By this upgrade script
function delete_silence_alerts_for_nodes(){
  echo "Deleting the silences created for the nodes by the script earlier....."
  curl http://$url:15011/api/v1/silences | jq -r  '.data[]|select(.createdBy == "Upgrade Script")|select(.status.state == "active")|.id' | xargs -I % curl -X DELETE http://$url:15011/api/v1/silence/%
}
#delete_silence_alerts_for_nodes

## This function is to disable nova-compute service for the compute nodes provided in the arguments
function disable_compute_service(){
   echo "Disbaling nova-compute  service for computes $@"
   for i in $@; do
      sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack compute service set --disable --disable-reason "Compute node upgrade"  '${i}' nova-compute'; done
}

## This function is to enable nova-compute service for the compute nodes provided in the arguments
function enable_compute_service(){
   echo "Enabling nova-compute service for computes $@"
   for i in $@; do
      sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack compute service set --enable   '${i}' nova-compute'; done
}

###This function is to live-migrate workloads from the compute that are going to be upgraded
function host_evacuate_live(){
    for i in $@;do
       sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack server list --all-projects --host '${i}' --status ACTIVE ; for j in $(openstack hypervisor list -c "Hypervisor Hostname" -f value | grep '${i}'); do echo "Instance count for $j :"; openstack hypervisor show $j -c running_vms -f value ; done'
      sudo salt -C ''"${i}*"'' cmd.run "virsh list --all |grep running"
       # sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; nova host-evacuate-live '${i}' '
    done

}
#host_evacuate_live

##Upgrade Compute nodes OS and enable services
function pipeline_upgrade_compute(){
   for i in $@;do
      ssh -q -o "ServerAliveInterval=240" -o "StrictHostKeyChecking=no" $i << EOF
        uptime
#     sudo salt-call -l quiet --state-verbose=false saltutil.sync_all
#     sudo salt-call -l quiet --state-verbose=false saltutil.refresh_pillar
#     sudo salt-call state.apply -l quiet --state-verbose=false linux.system.repo
#     sudo export DEBIAN_FRONTEND=noninteractive
#     sudo apt-get update
#     sudo apt-get -y upgrade
#     sudo apt-get -y --allow-downgrades dist-upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-overwrite"
#     sudo reboot
EOF
#sleep 1
#echo "Waiting for the server to accept ssh connection.. "
#while true; do
#    nc -i 1 -w 1 $i 22 > /dev/null
#    if [ $? -eq 0 ]; then
#    ssh -q -o "ServerAliveInterval=240" -o "StrictHostKeyChecking=no" ${1} << EOF
#        sudo salt-call state.apply -l quiet --state-verbose=false lldp,rsyslog,ntp,openssh,salt,logrotate,linux
#        sudo ceph -s
#        sudo salt-call state.apply -l quiet --state-verbose=false ceph
#        sudo salt-call state.apply -l quiet --state-verbose=false nova
#        sudo salt-call state.highstate
#EOF
#   fi
#done

   done

}
#pipeline_upgrade_compute

## Upgrade compute steps
function upgrade_compute(){
   silence_alerts_for_nodes
   disable_compute_service
   host_evacuate_live
   enable_compute_service
   pipeline_upgrade_compute
   delete_silence_alerts_for_nodes
}
