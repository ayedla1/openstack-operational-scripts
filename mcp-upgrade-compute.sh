#!/bin/bash
############
# SCRIPT IS STILL NOT COMPLETE AND ALSO UNDER TESTING
############
printf "Make sure to run the script from salt-master node\n"
printf "Recommended to run the script in a  SCREEN or TMUX session\n"
if [[ $(id -u) -eq 0 ]]
then
  echo "Run the script under your user.Please don't run as root"
  exit 1
fi
exec > >(tee -ia /tmp/script.log)
#version=$(sudo salt-call pillar.get _param:mcp_minor_version --out=txt | awk '{print $2}' |cut -d '.' -f 3) 2> /dev/null
#if [[ $version -gt 9 ]]; then
#printf "It seems you are using MCP version 2019.2.9 or above\n"
#printf "Please update the script by adding your API token to JENKINS_API_TOKEN variable which can be found on Line 17 in script.\n"
#printf "To get the Jenkins API token Go to Jenkins UI>>admin>>configure>>legacy_api_token\n"
JENKINS_API_TOKEN=
#fi

######## Trap unexpected signals ######
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'echo "Script was stopped.\"${last_command}\" command  with exit code $? ."; exit_status' EXIT
trap 'echo "Crucial script running.Press Ctrl-Z to stop and resume later"' HUP INT QUIT

########### Input arguments ############
function start_script(){
if  [[  $# == 0 ]];  then
      echo "Usage is: ./upgrade-compute.sh cmp001 cmp002.. cmp**"; exit;
elif [[ $# -ge 2 ]] && [[ $# -le 4 ]]; then
      echo "You are trying to Upgrade  $# computes at the same time. Make sure before proceeding further"
         echo "The Compute nodes that are going to be updated are: $* "
         for i in "$@"; do
           pre_compute_upgrade "${i}"
         done
         migration_status "$@"
         compute_upgrade "$@"
         post_compute_upgrade "$@"
elif [[ $# -gt 5 ]]; then
      echo "Too Many arguments have passed. Upgrade of $# computes on a single stretch would cause heavy load and migration issues."; exit;
else
      echo "The Compute nodes that are going to be updated are: $* "
      for i in "$@"; do
        pre_compute_upgrade "${i}"
      done
      migration_status "$@"
      compute_upgrade "$@"
      post_compute_upgrade "$@"
fi
}

########### Create log files speific to arguments provided ###########
function create_log_file(){
echo " Creating log files for each node in /tmp/ "
  for i in "$@"; do
     touch /tmp/${i}.log
     done
echo "Upgrade of $* is in progress ..... [1%]"
}

########## Delete log files created by the script ##########
function delete_log_file(){
   echo "Deleting log files generated by the script"
   for i in "$@";do
     rm -f /tmp/"${i}".log
   done
}

########## Save log files created by script #######
function save_log_file(){
   mkdir /tmp/upgrade-compute-script.log-"$(date  +%Y%m%d-%H%M)"
   cd /tmp/upgrade-compute-script.log-"$(date  +%Y%m%d-%H%M)"
   for i in "$@"; do
      mv /tmp/"${i}".log .
      mv /tmp/"${i}"_*  .   &> /dev/null
    #  tar -cvzf ${i}.tar.gz ${i}.log
   done
   cd &> /dev/null
   echo "Logs related to each compute node can be found in /tmp/upgrade-compute-script.log-$(date  +%Y%m%d-%H%M)"
   echo "Upgrade of $* is Completed ..... [100%]"
}

########### This function is for silencing all alerts for a node in AlertManager ###############
function silence_alerts_for_nodes(){
  echo "silencing all alerts from nodes $* for 3 hours"
  url=$(sudo salt-call pillar.get linux:network:host:mon:address --out txt | awk '{print $2}')
  starts=$(date -u  '+%FT%T.%3NZ')
  end=$(date -u -d '+3 hour' '+%FT%T.%3NZ')
  for i in "$@"; do
     {
     echo "------- Silencing all alerts for node ${i} -------"
     curl -s   http://"$url":15011/api/v1/silences -X POST -d '{"comment": "silence","createdBy": "Upgrade Script","startsAt": "'"${starts}"'", "endsAt": "'"${end}"'","matchers": [{"isRegex": true,"name": "host","value": "'"${i}.*"'"}]}'
     } >>  /tmp/"${i}".log
  done
  echo "Upgrade of $* is in progress ..... [10%]"
}

############ Delete all the silences created By this upgrade script ###############
function delete_silence_alerts_for_nodes(){
  for i ; do {
  echo " Deleting the silence created for the node ${i} by the script earlier "
  curl -s http://"$url":15011/api/v1/silences | jq -r  '.data[]|select(.createdBy == "Upgrade Script")|select(.status.state == "active")|.id' | xargs -I {} curl -X DELETE http://"$url":15011/api/v1/silence/{}
   }  &>>  /tmp/"${i}".log
 done
  echo "Upgrade of $* is in progress ..... [85%]"
}

############## This function is to disable nova-compute service for the compute nodes #############
function disable_compute_service(){
   echo " Disbaling nova-compute  service for computes $* "
   for i in "$@"; do {
      echo "--------- Disabling nova-compute  service for compute ${i} --------"
      sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack compute service set --disable --disable-reason "Compute node upgrade"  '"${i}"' nova-compute; nova service-list'
   } >>  /tmp/"${i}".log
   done
   echo "Upgrade of $* is in progress ..... [15%]"
}

############## This function is to enable nova-compute service for the compute nodes #############
function enable_compute_service(){
   echo " Enabling nova-compute service for computes $* "
   for i in "$@"; do {
      echo "-------- Enabling nova-compute service for compute ${i} ------"
      sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack compute service set --enable   '"${i}"' nova-compute; nova service-list'
    } >>  /tmp/"${i}".log
    done
  echo "Upgrade of $* is in progress ..... [95%]"
}

############### This function is to live-migrate workloads from the compute that are going to be upgraded ############
function live_migrate_instances(){
    echo " live-migrating instances from computes "
    for i in "$@";do
      {
        echo " ------ Checking  instances on compute ${i} -------"
        sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack server list --all-projects --host '"${i}"'  --fit-width; for j in $(openstack hypervisor list -c "Hypervisor Hostname" -f value | grep '"${i}"'); do echo "Instance count for $j :"; openstack hypervisor show $j -c running_vms -f value ; done'
        echo "------ Checking instances in  ACTIVE state on compute ${i} -------"
        ActiveVMs=$(sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack server list --all-projects --host '"${i}"' --status ACTIVE --fit-width | awk '"'NR>2 $2{print \$2}'"' ' |sed 1d  2> /dev/null)
        if [[ -z "${ActiveVMs}" ]]; then
          echo "--- There are no Active instances on compute ${i} ----"
        else
          for Instance in $ActiveVMs; do
             echo ----$Instance----
             sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; echo ----live migrating '"${Instance}"'------; nova live-migration --block-migrate '"${Instance}"' '
          done
        fi
       }  >>  /tmp/"${i}".log
    done
    echo "Upgrade of $* is in progress ..... [50%]"
}

############## This function is used to check the migration status of instances ##########################
function migration_status(){
   echo "Checking the status of migration of instances"
   for i in "$@";do
   {
   count=0
   while true; do
   MigratingVms=$(sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack server list --all-projects --host '"${i}"' --status MIGRATING --fit-width | awk '"'NR>2 $2{print \$2}'"' ' |sed 1d  2> /dev/null)
        if [[ -z "${MigratingVms}" ]]; then
          echo "--- There are no Migrating instances on compute ${i} ----"
          echo "$MigratingVms"
          break
        elif [[ $count -gt 36 ]]; then
          echo "--- Waited for 12 hours to complete the migration and it is still not complete on ${i} ---"
          echo "--- Skipping migration of ${i} --"
          break
        else
          let count++
          echo "waiting for 20 more minutes to let the migration complete"
          echo "$MigratingVms"
          sleep 20m
        fi
   done
   }&  >> /tmp/"${i}".log
   done
   wait
}
################################################################################################################
#This function is to verify the VM's status which are not in ACTIVE state
#This function is currently not used in script but can be reserved for future purposes
#if in case any actions are needed to be performed on VM's in specific status
#################################################################################################################
function check_instances_status(){
for i in "$@" ; do
 echo " Checking instance status in ${i} "
 {
 sudo salt -C 'ctl01*' cmd.run '. /root/keystonercv3;
        for status in $(openstack server list --all-projects --host '${i}' -c ID -c Status  --print-empty | grep -vi active | awk '"'NR >2 $4{print \$4}'"') ;do
           if [ "$status" = "SUSPENDED" ]; then
              for instance in $(openstack server list --all-projects --host '${i}' -c ID -c Status  --print-empty | grep -i suspended | awk '"'$2{print \$2}'"');do
                echo " ---- Resuming $instance ----" >> /tmp/resumed_instances_'"${i}"'
                nova resume $instance
              done
           elif [ "$status" = "SHUTOFF" ]; then
              for instance in $(openstack server list --all-projects --host '${i}' -c ID -c Status  --print-empty | grep -i shutoff |awk '"'$2{print \$2}'"') ; do
              	 echo " ---- Migrating $instance -----"
              	 nova migrate --poll $instance
              	 nova resize-confirm $instance
              done
           elif [ "$status" = "PAUSED" ];then
              for instance in $(openstack server list --all-projects --host '${i}' -c ID -c Status  --print-empty | grep -i paused |awk '"'$2{print \$2}'"') ; do
                 echo " ---- Unpausing $instance -----"
                 echo "${instance}" >> /tmp/unpaused_instances_'"${i}"'
                 nova unpause $instance
              done
            fi
        done'
} &1>> /tmp/${i}.log
done
wait
echo "Upgrade of $* is in progress ..... [20%]"
}
###############################################################################################################

###############################################################################################################
#This function is used to upgrade without Jenkins Pipeline
#Please verify it before you use
#You can modify the states to run as you need
# $services variable in the script gives what states need to be run on compute
##############  Upgrade Compute nodes OS and enable services #################################################
function pipeline_upgrade_compute(){
max_computes=4
if [[ $# -le ${max_computes} ]];then
   for i in "$@";do
    {
      if [[ -n $(sudo salt -C ''"${i}"*'' cmd.run "virsh list --all |grep -i running" 2> /dev/null) ]]; then       ## change to -z after testing
      services=$(sudo salt -C ''"${i}"*'' pillar.items __reclass__:applications --out=json |jq 'values |.[] | values |.[] | .[]' | tr -d '"' | tr '\n' ' ')
      ssh -q -o "ServerAliveInterval=240" -o "StrictHostKeyChecking=no" "${i}" << EOF
      trap 'echo "Crucial script running.Press Ctrl-Z to stop and resume later"' HUP INT QUIT
      uptime
      #sleep 2m
      if [[ -z "$(contrail-status)" ]]; then
         echo "contrail is not present"
      fi
     sudo salt-call -l quiet --state-verbose=false saltutil.sync_all
     sudo salt-call -l quiet --state-verbose=false saltutil.refresh_pillar
     sudo salt-call state.apply -l quiet --state-verbose=false linux.system.repo
     sudo export DEBIAN_FRONTEND=noninteractive
     sudo apt-get update
     sudo apt-get -y upgrade
     sudo apt-get -y -q --allow-downgrades -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
     sudo touch /run/is_rebooted
      sudo echo "$(hostname)" is being rebooted
     sudo reboot
EOF
sleep 1
echo "Waiting for the server to accept ssh connection.. "
while true; do
    nc -i 1 -w 1 "${i}" 22 > /dev/null
    if [ $? -eq 0 ]; then
    ssh -q -o "ServerAliveInterval=240" -o "StrictHostKeyChecking=no" "${1}" << EOF
         echo "${services}"
         if [[ "$services" == *"rsyslog"* && *"openssh"* && *"linux"* && *"salt"* && *"ntp"* && *"logrotate"* ]]; then
#        sudo salt-call state.apply -l quiet --state-verbose=false rsyslog,ntp,openssh,salt,logrotate,linux
#        sudo salt-call state.apply -l quiet --state-verbose=false nova
         fi
#        sudo salt-call state.highstate
EOF
   fi
done
     else
      echo "Still Instances are running on '${i}': $(sudo salt -C ''"${i}"\*'' cmd.run 'virsh list --all --uuid')" >>  /tmp/"${i}"_upgrade_fail
     fi
    }&  >> /tmp/$i.log
  done
  wait
else
echo "Maximum  are only "${max_computes}" computes to upgrade"
fi
echo "Upgrade of $* is in progress ..... [80%]"
}
###############################################################################################################

################## Jenkins pipeline to upgrade compute #############
function jenkins_pipeline(){
max_computes=4
if [[ $# -le ${max_computes} ]];then
for i in "$@";do
{
if [[ -z $(sudo salt -C ''"${i}"*'' cmd.run "virsh list --all |grep -i running" 2> /dev/null |sed 1d) ]]; then
echo "Run Jenkins piplines"
host=$(sudo salt "cid01*" pillar.get jenkins:client:master:host --out=txt|awk '{print $2}')
user=$(sudo salt "cid01*" pillar.get jenkins:client:master:username --out=txt|awk '{print $2}')
password=$(sudo salt "cid01*" pillar.get jenkins:client:master:password --out=txt|awk '{print $2}')
port=$(sudo salt "cid01*" pillar.get jenkins:client:master:port --out=txt|awk '{print $2}')
SALT_MASTER_CREDENTIALS=$(sudo salt "cid01*" pillar.get jenkins:client:job:deploy-upgrade-compute:param:SALT_MASTER_CREDENTIALS:default --out=text|awk '{print $2}' )
SALT_MASTER_URL=$(sudo salt "cid01*" pillar.get jenkins:client:job:deploy-upgrade-compute:param:SALT_MASTER_URL:default --out=text |awk '{print $2}' )
TARGET_SERVERS="$@"
OS_DIST_UPGRADE=true
OS_UPGRADE=true
INTERACTIVE=false

generate_post_data()
{
  cat <<EOF
json={"parameter": [
{"name":"INTERACTIVE", "value":"${INTERACTIVE}"},
{"name":"OS_DIST_UPGRADE", "value":"${OS_DIST_UPGRADE}"},
{"name":"OS_UPGRADE", "value":"${OS_UPGRADE}"},
{"name":"SALT_MASTER_CREDENTIALS", "value":"${SALT_MASTER_CREDENTIALS}"},
{"name":"SALT_MASTER_URL", "value":"${SALT_MASTER_URL}"},
{"name":"TARGET_SERVERS", "value":"${TARGET_SERVERS}*"}]}
EOF
}

echo "Update compute pipeline run"
job_url=https://$host:$port/job/deploy-upgrade-compute
job_status_url=${job_url}/lastBuild/api/json
grep_return_code=0
#crumb=$(curl -s -X WGET  --user $user:$password  https://$host:$port/crumbIssuer/api/json | jq -r '.crumb')
#curl -s -k -H "Jenkins-Crumb:$crumb" -X POST --user $user:$password  $job_url/build --data-urlencode "$(generate_post_data)"
curl -s -k -X POST --user "${user}":"${JENKINS_API_TOKEN}"  $job_url/build --data-urlencode "$(generate_post_data)"
while [ $grep_return_code -eq 0 ]
do
sleep 20m
echo "checking build status..."
curl --silent $job_status_url | grep result
result=$(curl --silent $job_status_url | grep result)
if [[ "$result" = "SUCCESS" ]] || [[ "$result" = "FAILURE" ]]; then
echo "Update of "$@" finished"
break
else
echo "Still Running..."
fi
grep_return_code=$?
done
else
echo "Still Instances are running on '${i}': $(sudo salt -C ''"${i}"\*'' cmd.run 'virsh list --all --uuid')" >>  /tmp/"${i}"_upgrade_fail
fi
} &  >> /tmp/$i.log
done
wait
else
echo "Maximum  are only "${max_computes}" computes to upgrade"
fi

echo "Upgrade of $* is in progress ..... [80%]"
}

####### Exit status #######
function exit_status(){
  compute_disabled=$(sudo salt -C '*ctl01*' cmd.run '. /root/keystonercv3; openstack compute service list | grep -i disabled' 2> /dev/null )
  if [[ -n $compute_disabled ]]; then
  echo "$compute_disabled"
  fi
  silence_stillPresent=$(curl -s http://"$url":15011/api/v1/silences | jq -r  '.data[]|select(.createdBy == "Upgrade Script")|select(.status.state == "active")|.id')
  if [[ -n $silence_stillPresent ]]; then
  echo " ---- ID of silences created by the Script and are still not deleted ---"
  echo "$silence_stillPresent"
  fi
  pidof -x upgrade-compute.sh
}

############# Upgrade compute ##############
function pre_compute_upgrade(){
   create_log_file  "$@"
   silence_alerts_for_nodes  "$@"
   disable_compute_service  "$@"
   live_migrate_instances  "$@"
}
function compute_upgrade(){
   jenkins_pipeline "$@"
}
function post_compute_upgrade(){
   delete_silence_alerts_for_nodes   "$@"
   enable_compute_service   "$@"
   save_log_file  "$@"
}
start_script "$@"
exit
