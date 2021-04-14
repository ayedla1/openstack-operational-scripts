#!/bin/bash
############
SCRIPT IS STILL NOT COMPLETE AND ALSO UNDER TESTING
############
printf "Make sure to run the script from salt-master node\n"
printf "Recommended to run the script in a  "SCREEN" or "TMUX" session\n"
read -p "you want to proceed?(y/N)" prompt
if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" || $prompt == "YES" ]]; then

############ Input arguments ############
function start_script(){
if  [[  $# == 0 ]];  then
      echo "Usage is: ./upgrade-compute.sh cmp001 cmp002.. cmp**"; exit;
elif [[ $# -gt 2 ]] && [[ $# -le 4 ]]; then
      echo "You are trying to Upgrade more than $# computes at the same time.Make sure before proceeding further"
      read -p "Are you sure you want to proceed?(y/N)" prompt
      if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" || $prompt == "YES" ]]; then
         echo "The Compute nodes that are going to be updated are: "$@""
         for i in "$@"; do                  #### this for loop can be removed if we need to upgrade computes in parallel ######
           upgrade_compute $i
         done
      else
         exit;
      fi
elif [[ $# -gt 8 ]]; then
      echo "Too Many arguments have passed. Upgrade of $# computes on a single stretch would cause heavy load and migration issues. Less than 3 compute node upgrade is recommended"; exit;
else
      echo "The Compute nodes that are going to be updated are: "$@""
      for i in "$@"; do                     #### this for loop can be removed if we need to upgrade computes in parallel ######
        upgrade_compute $i
      done
fi
}

########### Create log files speific to arguments provided ###########
function create_log_file(){
echo "------- Creating log files for each node in /tmp/----------"
  for i in "$@"; do
     touch /tmp/$i.log
     done
}

########## Delete log files created by the script ##########
function delete_log_file(){
read -p "Do you want to delete the log files generated by the script?(y/N)" prompt
if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" || $prompt == "YES" ]]; then
   echo "Deleting log files generated by the script"
   for i in "$@";do
     rm -f /tmp/$i.log
   done
else
   mkdir /tmp/upgrade-script.log-$(date -u +%F-%T)
   cd /tmp/upgrade-script.log-$(date -u +%F-%T)
   for i in "$@"; do
      tar -cvzf /tmp/$i.tar.gz /tmp/$i.log
      mv /tmp/$i.tar.gz .
      rm -f /tmp/$i.log
   done
   cd
fi
}

########### This function is for silencing all alerts for a node in AlertManager ###############
function silence_alerts_for_nodes(){
  echo "silencing all alerts from nodes "$@" for 3 hours"
  url=$(sudo salt-call pillar.get linux:network:host:mon:address --out txt | awk '{print $2}')
  starts=$(date -u  '+%FT%T.%3NZ')
  end=$(date -u -d '+3 hour' '+%FT%T.%3NZ')
  for i in "$@"; do
     echo "------- Silencing all alerts for node ${i} -------"
     {
     echo "------- Silencing all alerts for node ${i} -------"
     curl -s   http://$url:15011/api/v1/silences -X POST -d '{"comment": "silence","createdBy": "Upgrade Team","startsAt": "'"${starts}"'", "endsAt": "'"${end}"'","matchers": [{"isRegex": true,"name": "host","value": "'"${i}.*"'"}]}'
     } >> /tmp/$i.log
  done
}

############ Delete all the silences created By this upgrade script ###############
function delete_silence_alerts_for_nodes(){
echo "---------- Deleting the silences created for the nodes by the script earlier --------"
  for i ; do {
  echo "---------- Deleting the silences created for the nodes by the script earlier --------"
  curl -s http://$url:15011/api/v1/silences | jq -r  '.data[]|select(.createdBy == "Upgrade Script")|select(.status.state == "active")|.id' | xargs -I % curl -X DELETE http://$url:15011/api/v1/silence/%
   } >> /tmp/$i.log
 done
}

############## This function is to disable nova-compute service for the compute nodes #############
function disable_compute_service(){
   echo "---------- Disbaling nova-compute  service for computes "$@" --------"
   for i in "$@"; do {
      echo "--------- Disabling nova-compute  service for computes "$@" --------"
      sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack compute service set --disable --disable-reason "Compute node upgrade"  '${i}' nova-compute; nova service-list'
   } >> /tmp/$i.log
   done
}

############## This function is to enable nova-compute service for the compute nodes #############
function enable_compute_service(){
   echo "------- Enabling nova-compute service for computes "$@" -----"
   for i in "$@"; do {
      echo "-------- Enabling nova-compute service for computes "$@" ------"
      sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack compute service set --enable   '${i}' nova-compute; nova service-list'
    } >> /tmp/$i.log
    done
}

############### This function is to live-migrate workloads from the compute that are going to be upgraded ############
function host_evacuate_live(){
    echo "------- Running checks before live-migrating instances from computes --------"
    for i in "$@";do
      {
        echo "----- Checking all ACTIVE instances on compute $i -----"
        sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack server list --all-projects --host '${i}' --status ACTIVE --fit-width; for j in $(openstack hypervisor list -c "Hypervisor Hostname" -f value | grep '${i}'); do echo "Instance count for $j :"; openstack hypervisor show $j -c running_vms -f value ; done'
        echo "----- Checking instances in status other than ACTIVE on compute $i ----"
        sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack server list --all-projects --host '${i}'  --print-empty | grep -vi active'

      # echo " ----- List of  running instances on compute $i ----"
      # sudo salt -C ''${i}*'' cmd.run "virsh list --all |grep running"
       read -p "Are you sure you want to live-evacuate all instances on the computes?(y/N)" prompt
       if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" || $prompt == "YES" ]]; then
       echo " ------ Live evacuate all instances on compute $i ------"
       # sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; nova host-evacuate-live '${i}' '
       fi
       } | tee -a /tmp/${i}.log
 # sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; nova host-evacuate-live '${i}' '
    done

}

############## This function is to provide live-migration options ###############
#function live_migration(){

#}

##############  Upgrade Compute nodes OS and enable services ##################
function pipeline_upgrade_compute(){
   for i in "$@";do
      ssh -q -o "ServerAliveInterval=240" -o "StrictHostKeyChecking=no" $i << EOF
        uptime
      read -p "Are you sure you want to continue?(y/N)" prompt
      if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" || $prompt == "YES" ]]; then
      echo "---Test sucessfull----"
      fi
#     sudo salt-call -l quiet --state-verbose=false saltutil.sync_all
#     sudo salt-call -l quiet --state-verbose=false saltutil.refresh_pillar
#     sudo salt-call state.apply -l quiet --state-verbose=false linux.system.repo
#     sudo export DEBIAN_FRONTEND=noninteractive
#     sudo apt-get update
#     sudo apt-get -y upgrade
#     sudo apt-get -y --allow-downgrades dist-upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
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

############# Upgrade compute ##############
function upgrade_compute(){
   create_log_file  "$@"
   silence_alerts_for_nodes  "$@"
   disable_compute_service  "$@"
   host_evacuate_live  "$@"
   enable_compute_service   "$@"
   pipeline_upgrade_compute  "$@"
   delete_silence_alerts_for_nodes   "$@"
#   delete_log_file  "$@"
}
   start_script "$@"
else
   exit;
fi
