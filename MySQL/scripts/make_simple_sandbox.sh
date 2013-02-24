#!/bin/bash

# Copyright 2013 Grant Allen, gxallen@gmail.com
# Licenced under the Apache Licence v2.0, www.apache.org/licenses

#Common functions
usage() {
  echo "${0} <mysql-install-path> [network-interface]"
  echo " "
  echo "A script to make Galera-enabled MySQL sandbox instances on a single host"
  echo " "
  echo "Prerequisites:"
  echo "--------------"
  echo "libaio1"
  echo "psmisc"
  echo "galera-x.y.z-<arch>.{deb|rpm} (from launchpad.net/galera , at least v23 or later)"
  echo " "
  echo "Parameters:"
  echo "-----------"
  echo "mysql-install-path:  The path to the Galera-enabled MySQL binaries on your system"
  echo "network-interface:  (Optional) specific network interface to be probed for IP address.  Defaults to eth0"
  echo " "
  echo "The script makes use of various global variables which can be changed to suit your environment."
  exit 0
}

err() {
  echo "[ERROR] [$(date +'%Y-%m-%dT%H:%M:%S%z')]: ${@}" >&2
  exit 1
}

info() {
  echo "[INFO] [$(date +'%Y-%m-%dT%H:%M:%S%z')]: ${@}" >&2
}

# Globals

SANDBOX_BASE="/home/${USER}/galerasandbox"
SANDBOX_TMP="/tmp"
SANDBOX_INSTANCES=3
BASE_PORT=4000 # Note, we'll avoid MySQL default in case normal instances are also running on this host
WSREP_BASE_PORT=5000 # Note, as we'll add instance count to this for real port, and instance count plus WSREP_RECEIVE_PORT_OFFSET for receiver port
WSREP_RECEIVE_PORT_OFFSET=100 # offset used to calculate receiver ports
RUN_MYSQL_AS="${USER}"
MY_INTERFACE="eth0"
SYSTEM_ARCH=$( uname -m)

# There are many more possible wsrep library loctions, but these are the common ones for Galera
WSREPLIB1="/usr/lib/galera/libgalera_smm.so"
WSREPLIB2="/usr/lib32/galera/libgalera_smm.so"
WSREPLIB3="/usr/lib64/galera/libgalera_smm.so"

declare -r SANDBOX_BASE
declare -r SANDBOX_TMP
declare -r SANDBOX_INSTANCES
declare -r BASE_PORT
declare -r WSREP_BASE_PORT
declare -r RUN_MYSQL_AS
declare -r SYSTEM_ARCH
declare -r WSREPLIB1
declare -r WSREPLIB2
declare -r WSREPLIB3


# Main script

# Check command line args for path to MySQL install and optional interface override
if [[ ${1} = "" ]] ; then
  usage
else
  info "Using MySQL binaries in ${1}"
  MYSQL_INSTALL_DIR=${1}
fi

if [[ ${2} = "" ]] ; then
  info "Using default network interface ${MY_INTERFACE}"
else
  info "Using specified network interface ${2}"
  MY_INTERFACE=${2}
fi


# Dynamically determine architecture and library
wsrep_provider_lib="unknown"
info "Detecting system architecture - system reports via uname it is ${SYSTEM_ARCH}"
if [[ ${SYSTEM_ARCH} = "x86_64" ]] ; then
  info "System reports it is 64-bit"
  if [[ -f ${WSREPLIB1} ]] && [[ $( file /usr/lib/galera/libgalera_smm.so | awk '{print $3}' ) = "64-bit" ]] ; then 
    info "Found 64-bit ${WSREPLIB1}"
    wsrep_provider_lib=${WSREPLIB1}
  fi
  if [[ -f ${WSREPLIB3} ]] && [[ $( file /usr/lib64/galera/libgalera_smm.so | awk '{print $3}' ) = "64-bit" ]] ; then 
    info "Found 64-bit ${WSREPLIB3}"
    wsrep_provider_lib=${WSREPLIB3}
  fi
else
  info "System reports it is 32-bit"
  if [[ -f ${WSREPLIB1} ]] && [[ $( file /usr/lib/galera/libgalera_smm.so | awk '{print $3}' ) = "32-bit" ]] ; then 
    info "Found 32-bit ${WSREPLIB1}"
    wsrep_provider_lib=${WSREPLIB1}
  fi
  if [[ -f ${WSREPLIB1} ]] && [[ $( file /usr/lib32/galera/libgalera_smm.so | awk '{print $3}' ) = "32-bit" ]] ; then 
    info "Found 32-bit ${WSREPLIB2}"
    wsrep_provider_lib=${WSREPLIB2}
  fi
fi

if [[ ${wsrep_provider_lib} = "unknown" ]] ; then
  err "No WSREP provider library found.  Please see the prerequisites for running this script."
else
  info "Using WSREP provider ${wsrep_provider_lib}"
fi


# mysql_install_db install script must be called from the base of the mysql install (stupid hack)
cd ${MYSQL_INSTALL_DIR}


# Determine IP
# TODO: Test if interface actually exists
info "Dermining IP Address for interface ${MY_INTERFACE}"
sandbox_ip=$( /sbin/ifconfig ${MY_INTERFACE} | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}' | grep -v 127.0)
info "Using IP ${sandbox_ip} for interface ${MY_INTERFACE}"


# Make directories
info "Making sandbox directories"
loopcount=1
while [ ${loopcount} -le ${SANDBOX_INSTANCES} ]
do
  mkdir -p ${SANDBOX_BASE}/mysql${loopcount}
  mkdir -p ${SANDBOX_BASE}/mysql${loopcount}/data
  #next two lines probably not needed now basedir is set correctly in my.cnf
  mkdir -p ${SANDBOX_BASE}/mysql${loopcount}/share
  cp ${MYSQL_INSTALL_DIR}/share/english/errmsg.sys ${SANDBOX_BASE}/mysql${loopcount}/share
  loopcount=`expr ${loopcount} + 1`
done


# Make wsrep_urls value for all my.cnf files
sandbox_wsrep_urls="gcomm://"
info "Configuring cluster URLs"
loopcount=1
while [ ${loopcount} -le ${SANDBOX_INSTANCES} ]
do
  mywsrepport=`expr ${WSREP_BASE_PORT} + ${loopcount}`
  sandbox_wsrep_urls="gcomm://${sandbox_ip}:${mywsrepport},${sandbox_wsrep_urls}"
  loopcount=`expr ${loopcount} + 1`
done


# Make my.cnf files
info "Making my.cnf files"
loopcount=1
while [ ${loopcount} -le ${SANDBOX_INSTANCES} ]
do
  myport=`expr ${BASE_PORT} + ${loopcount}`
  mywsrepport=`expr ${WSREP_BASE_PORT} + ${loopcount}`
  mywsrepreceiveport=`expr ${WSREP_BASE_PORT} + ${WSREP_RECEIVE_PORT_OFFSET} + ${loopcount}`
  cat >> ${SANDBOX_BASE}/mysql${loopcount}/my.cnf << EOF
[client]
port		= ${myport}
socket		= ${SANDBOX_TMP}/mysqld${loopcount}.sock

# This was formally known as [safe_mysqld]. Both versions are currently parsed.
[mysqld_safe]
wsrep_urls = ${sandbox_wsrep_urls}
socket		= ${SANDBOX_TMP}/mysqld${loopcount}.sock
nice		= 0

[mysqld]
#
# * Basic Settings
#
user		= ${RUN_MYSQL_AS}
pid-file	= ${SANDBOX_TMP}/mysqld${loopcount}.pid
socket		= ${SANDBOX_TMP}/mysqld${loopcount}.sock
port		= ${myport}
basedir		= ${MYSQL_INSTALL_DIR}
datadir		= ${SANDBOX_BASE}/mysql${loopcount}/data
tmpdir		= ${SANDBOX_TMP}
plugin-dir    = ${MYSQL_INSTALL_DIR}/lib/plugin
lc-messages-dir	= ${SANDBOX_BASE}/mysql${loopcount}/share
log-error = ${SANDBOX_BASE}/mysql${loopcount}/mysql${loopcount}.err
skip-external-locking
key_buffer		= 16M
max_allowed_packet	= 16M
thread_stack		= 192K
thread_cache_size       = 8
# Specific settings for Galera config
server-id=1
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
innodb_locks_unsafe_for_binlog=1
log-bin=mysql-bin
#wsrep_cluster_address=gcomm://
wsrep_sst_auth=oqsandbox:oqsandbox
wsrep_provider=${wsrep_provider_lib}
wsrep_provider_options="gmcast.listen_addr=tcp://${sandbox_ip}:${mywsrepport}"
#second set of wsrep options
wsrep_sst_receive_address=${sandbox_ip}:${mywsrepreceiveport}
wsrep_node_incoming_address=${sandbox_ip}
wsrep_slave_threads=2
wsrep_cluster_name=oqsandbox
wsrep_sst_method=rsync
wsrep_node_name=node${loopcount}

# This replaces the startup script and checks MyISAM tables if needed
# the first time they are touched
myisam-recover         = BACKUP

# * Query Cache Configuration
query_cache_limit	= 1M
query_cache_size        = 16M
expire_logs_days	= 10
max_binlog_size         = 100M

[mysqldump]
quick
quote-names
max_allowed_packet	= 16M

[isamchk]
key_buffer		= 16M
EOF
  loopcount=`expr ${loopcount} + 1`
done


# Initialise mysql data dirs
info "Initialising MySQL data directories"
loopcount=1
while [ ${loopcount} -le ${SANDBOX_INSTANCES} ]
do
  ${MYSQL_INSTALL_DIR}/scripts/mysql_install_db --datadir=${SANDBOX_BASE}/mysql${loopcount}/data
  loopcount=`expr ${loopcount} + 1`
done


# Make useful scripts
info "making simple start and stop scripts"
loopcount=1
while [ ${loopcount} -le ${SANDBOX_INSTANCES} ]
do
  cat >> ${SANDBOX_BASE}/mysql${loopcount}/start.sh << EOF
export LD_LIBRARY_PATH=${MYSQL_INSTALL_DIR}/lib:${MYSQL_INSTALL_DIR}/lib/mysql:$LD_LIBRARY_PATH
export DYLD_LIBRARY_PATH=${MYSQL_INSTALL_DIR}_/lib:${MYSQL_INSTALL_DIR}/lib/mysql:$DYLD_LIBRARY_PATH
${MYSQL_INSTALL_DIR}/bin/mysqld_safe --defaults-file=${SANDBOX_BASE}/mysql${loopcount}/my.cnf --ledir=${MYSQL_INSTALL_DIR}/bin
EOF
  chmod u+x ${SANDBOX_BASE}/mysql${loopcount}/start.sh
  cat >> ${SANDBOX_BASE}/mysql${loopcount}/stop.sh << EOF
${MYSQL_INSTALL_DIR}/bin/mysqladmin --socket=${SANDBOX_TMP}/mysqld${loopcount}.sock -u root --password="" shutdown
EOF
  chmod u+x ${SANDBOX_BASE}/mysql${loopcount}/stop.sh
  cat >> ${SANDBOX_BASE}/startall.sh << EOF
  nohup ${SANDBOX_BASE}/mysql${loopcount}/start.sh &
EOF
  cat >> ${SANDBOX_BASE}/stopall.sh << EOF
  nohup ${SANDBOX_BASE}/mysql${loopcount}/stop.sh &
EOF
  loopcount=`expr ${loopcount} + 1`
done

chmod u+x ${SANDBOX_BASE}/startall.sh
chmod u+x ${SANDBOX_BASE}/stopall.sh


# Make permissions script
info "Making permission script"
cat >> ${SANDBOX_BASE}/initial_permissions.sql << EOF
use mysql;
grant all on *.* to oqsandbox@localhost identified by 'oqsandbox';
grant all on *.* to oqsandbox@'%' identified by 'oqsandbox';
flush privileges;
exit
EOF


# Start first instance
info "Starting first instance"
nohup ${SANDBOX_BASE}/mysql1/start.sh &
# give instance time to start
sleep 10


# Load permissions to first instance (note no point loading to other instances, as these will be overwritten)
${MYSQL_INSTALL_DIR}/bin/mysql --user=root --password="" --socket=${SANDBOX_TMP}/mysqld1.sock < ${SANDBOX_BASE}/initial_permissions.sql


# Start remaining instances
info "Configuring and starting second and subsequent instances"
loopcount=2
while [ ${loopcount} -le ${SANDBOX_INSTANCES} ]
do
  #note, next two lines not currently required with the use of wsrep_urls parameter
  #hard-coded 4001 base port needs changing to WSREP_BASE_PORT
  #sed -i 's/wsrep_cluster_address.*/wsrep_cluster_address=gcomm:\/\/${sandbox_ip}:4001/g' ${SANDBOX_BASE}/mysql${loopcount}/my.cnf
  echo "starting instance ${loopcount}"
  nohup ${SANDBOX_BASE}/mysql${loopcount}/start.sh &
  #Allow time for node to register and sync
  sleep 30
  loopcount=`expr ${loopcount} + 1`
done


# Stop first instance, assuming at least one other node is running
info "Stopping first instance to reset its cluster address to safe value"
${SANDBOX_BASE}/mysql1/stop.sh
sleep 3

# Set first node's cluster address - note, not currently required with the use of wsrep_urls parameter

# Restart first instance, now that it knows the cluster address
info "restarting first instance"
nohup sh ${SANDBOX_BASE}/mysql1/start.sh &
sleep 3

info "Setup complete!"



