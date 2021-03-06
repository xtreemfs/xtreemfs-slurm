#!/bin/bash

###############################################################################
# Author: Robert Bärhold
# Date: 18.05.2015
#
# Starting or stopping a distributed XtreemFS farm on slurm.
# It is also possible to clone a git repository or to cleanup the local
# xtreemfs folder on each allocated node.
#
# Call:
# 	./xtreemfs_slurm.sh [env.sh] (start|stop [-savelogs]|cleanup|clone)|
#
# Parameter:
# 	$1 [optional] -savelogs
 #		> only valid a "stop"
#
###############################################################################

shopt -s extglob

BASEDIR=$(dirname $0)

SOURCE_FILE=$BASEDIR/env.sh
if [[ "$1" = *.sh ]] && [[ -f "$1" ]]; then
  SOURCE_FILE="$1"
  shift
fi
source $SOURCE_FILE

LOCAL_DIR=""
SERVICE_PREFIX=""

# clones the git repository specified in the source file
function cloneGitHubRepository() {

  echo "Clone GitHub Repository"

  if [[ "$IS_CLONE_REPO" != "true" ]]; then
    return 0
  fi

  command -v git >/dev/null 2>&1 || {
    echo >&2 "Git is required to clone current GitHub repository. Aborting."
    exit 1
  }

  if [[ ! -z "$REPO_CLONE_LOCATION" ]] && [[ -d "$REPO_CLONE_LOCATION" ]]; then
    git clone "$GITHUB_REPO" "$REPO_CLONE_LOCATION"
  else
    echo "The given path $REPO_CLONE_LOCATION isn't a valid directory"
    exit 1
  fi

  return 0
}

# Checks generic variables and xtreemfs components and defines basic variables
function initializeEnvironment() {

  outputDebug "Setup: Checking variables and environment"

  if [[ -z $SLURM_JOB_ID ]]; then
    echo "You're not inside an executing SLURM allocation"
    echo "Please alloc SLURM nodes with an active SLURM shell (no '--no-shell' argument)"
    exit 1
  fi


  if [[ ! -d "$XTREEMFS_DIRECTORY" ]] || [[ ! -f "$XTREEMFS_DIRECTORY/java/xtreemfs-servers/target/xtreemfs.jar" ]]; then
    echo -n "XtreemFS Directory $XTREEMFS_DIRECTORY does not exist"
    echo " or doesn't include XtreemFS (missing ./java/xtreemfs-servers/target/xtreemfs.jar)."
    echo "Please adjust the SOURCE_FILE ($SOURCE_FILE) or the XTREEMFS_DIRECTORY ($XTREEMFS_DIRECTORY)."
    exit 1
  fi

  if [[ ! -e "$XTREEMFS_DIRECTORY/bin/mkfs.xtreemfs" ]] || [[ ! -e "$XTREEMFS_DIRECTORY/bin/rmfs.xtreemfs" ]] ||
     [[ ! -e "$XTREEMFS_DIRECTORY/bin/mount.xtreemfs" ]] || [[ ! -e "$XTREEMFS_DIRECTORY/bin/umount.xtreemfs" ]]; then
    echo "XtreemFS client hasn't been built correctly. One of the following files couldn't be found:"
    echo "mkfs.xtreemfs, rmfs.xtreemfs, mount.xtreemfs or umount.xtreemfs ."
    echo "Please run 'make client' inside the $XTREEMFS_DIRECTORY ."
    exit 1
  fi

  for var in $CURRENT_JOB_FOLDER_GENERIC $LOCAL_DIR_GENERIC $LOCAL_MOUNT_PATH_GENERIC $SERVICE_PREFIX_GENERIC $VOLUME_NAME_GENERIC; do
    echo "$var" | grep %JOBID% > /dev/null || {
      echo "%JOBID% parameter was not found in variable: $var"
      exit 1
    }
  done

  for var in $CONFIG_FILENAME_GENERIC $LOG_FILENAME_GENERIC $PID_FILENAME_GENERIC; do
    echo "$var" | grep %NAME% > /dev/null || {
      echo "%NAME% parameter was not found in variable: $var"
      exit 1
    }
  done

  LOCAL_DIR=$(substitudeJobID "$LOCAL_DIR_GENERIC")
  SERVICE_PREFIX=$(substitudeJobID "$SERVICE_PREFIX_GENERIC")

  return 0
}

# copies the dummy configurations and adjusts several parameter inside the configuration files
function prepareConfigs() {

  if [[ "$GENERATE_CONFIGS" == true ]]; then
    outputDebug "Preparing configurations for DIR, MRC and OSD*"
  else
    outputDebug "Using given configurations for DIR, MRC and OSD*"
    return 0
  fi

  CURRENT_JOB_FOLDER=$(substitudeJobID "$CURRENT_JOB_FOLDER_GENERIC")
  mkdir -p "$CURRENT_JOB_FOLDER/config"

  ## DIR
  DIR_CONFIG_FILE="$CURRENT_JOB_FOLDER/config/$(substitudeName "$CONFIG_FILENAME_GENERIC" "DIR")"
  cp "$XTREEMFS_DIRECTORY/etc/xos/xtreemfs/dirconfig.properties" "$DIR_CONFIG_FILE"

  substitudeProperty "$DIR_CONFIG_FILE" "uuid" "uuid = $SERVICE_PREFIX-DIR"
  substitudeProperty "$DIR_CONFIG_FILE" "babudb.baseDir" "babudb.baseDir = $LOCAL_DIR/dir/datebase"
  substitudeProperty "$DIR_CONFIG_FILE" "babudb.logDir" "babudb.logDir = $LOCAL_DIR/dir/db-log"

  substitudeProperty "$DIR_CONFIG_FILE" "policy_dir" "policy_dir = $XTREEMFS_DIRECTORY/etc/xos/xtreemfs/policies"

  substitudeProperty "$DIR_CONFIG_FILE" "#debug.level =" "debug.level = $DEBUG_DIR_LEVEL"
  substitudeProperty "$DIR_CONFIG_FILE" "#debug.categories =" "debug.categories = $DEBUG_DIR_CATEGORIES"

  DIR_HOSTNAME="${XTREEMFS_NODES[@]:0:1}"

  ## MRC

  MRC_CONFIG_FILE="$CURRENT_JOB_FOLDER/config/$(substitudeName "$CONFIG_FILENAME_GENERIC" "MRC")"
  cp "$XTREEMFS_DIRECTORY/etc/xos/xtreemfs/mrcconfig.properties" "$MRC_CONFIG_FILE"

  substitudeProperty "$MRC_CONFIG_FILE" "dir_service.host" "dir_service.host = $DIR_HOSTNAME"
  substitudeProperty "$MRC_CONFIG_FILE" "uuid" "uuid = $SERVICE_PREFIX-MRC"
  substitudeProperty "$MRC_CONFIG_FILE" "babudb.baseDir" "babudb.baseDir = $LOCAL_DIR/mrc/datebase"
  substitudeProperty "$MRC_CONFIG_FILE" "babudb.logDir" "babudb.logDir = $LOCAL_DIR/mrc/db-log"

  substitudeProperty "$MRC_CONFIG_FILE" "#debug.level =" "debug.level = $DEBUG_MRC_LEVEL"
  substitudeProperty "$MRC_CONFIG_FILE" "#debug.categories =" "debug.categories = $DEBUG_MRC_CATEGORIES"

  substitudeProperty "$MRC_CONFIG_FILE" "policy_dir" "policy_dir = $XTREEMFS_DIRECTORY/etc/xos/xtreemfs/policies"
  substitudeProperty "$MRC_CONFIG_FILE" "ssl.service_creds =" "ssl.service_creds = $XTREEMFS_DIRECTORY/etc/xos/xtreemfs/truststore/certs/mrc.p12"
  substitudeProperty "$MRC_CONFIG_FILE" "ssl.trusted_certs =" "ssl.trusted_certs = $XTREEMFS_DIRECTORY/etc/xos/xtreemfs/truststore/certs/trusted.jks"

  ## OSDs
  for (( counter=1; $counter <= $(( $NUMBER_OF_NODES - ($SKIP_NODE_COUNT + 1) )); counter++ )) {

    OSDNAME="OSD${counter}"

    OSD_CONFIG_FILE="$CURRENT_JOB_FOLDER/config/$(substitudeName "$CONFIG_FILENAME_GENERIC" "$OSDNAME")"
    cp "$XTREEMFS_DIRECTORY/etc/xos/xtreemfs/osdconfig.properties" "$OSD_CONFIG_FILE"

    substitudeProperty "$OSD_CONFIG_FILE" "dir_service.host" "dir_service.host = $DIR_HOSTNAME"
    substitudeProperty "$OSD_CONFIG_FILE" "uuid" "uuid = $SERVICE_PREFIX-$OSDNAME"
    substitudeProperty "$OSD_CONFIG_FILE" "object_dir" "object_dir = $LOCAL_DIR/$OSDNAME/objs"

    substitudeProperty "$OSD_CONFIG_FILE" "#debug.level =" "debug.level = $DEBUG_OSD_LEVEL"
    substitudeProperty "$OSD_CONFIG_FILE" "#debug.categories =" "debug.categories = $DEBUG_OSD_CATEGORIES"

    substitudeProperty "$OSD_CONFIG_FILE" "policy_dir" "policy_dir = $XTREEMFS_DIRECTORY/etc/xos/xtreemfs/policies"
    substitudeProperty "$OSD_CONFIG_FILE" "ssl.service_creds =" "ssl.service_creds = $XTREEMFS_DIRECTORY/etc/xos/xtreemfs/truststore/certs/osd.p12"
    substitudeProperty "$OSD_CONFIG_FILE" "ssl.trusted_certs =" "ssl.trusted_certs = $XTREEMFS_DIRECTORY/etc/xos/xtreemfs/truststore/certs/trusted.jks"
  }

  return 0
}

# calls the start script remotely on each cumuslus node
function startServer() {
  DIR_HOSTNAME="${XTREEMFS_NODES[@]:0:1}"
  srun -k -N1-1 --nodelist=$DIR_HOSTNAME $BASEDIR/xtreemfs_slurm_rstart.sh "$SOURCE_FILE" "DIR" "DIR"
  stopOnStartError $?

  MRC_HOSTNAME="${XTREEMFS_NODES[@]:$SKIP_NODE_COUNT:1}"
  srun -k -N1-1 --nodelist=$MRC_HOSTNAME $BASEDIR/xtreemfs_slurm_rstart.sh "$SOURCE_FILE" "MRC" "MRC"
  stopOnStartError $?

  counter=1
  for osd_hostname in "${XTREEMFS_NODES[@]:$(( $SKIP_NODE_COUNT + 1 )):$(( $NUMBER_OF_NODES - ($SKIP_NODE_COUNT + 1) ))}"; do
    OSDNAME="OSD${counter}"
    srun -k -N1-1 --nodelist=$osd_hostname $BASEDIR/xtreemfs_slurm_rstart.sh "$SOURCE_FILE" "OSD" "$OSDNAME"
    stopOnStartError $?
    counter=$(($counter+1))
  done

  return 0
}

function stopOnStartError(){

  if [[ "$1" == "1" ]]; then
    echo "An error occured during startup. XtreemFS will be stopped and the logs will be saved."
    stop "-savelogs"
    exit 1
  fi
}

# deletes the local job folder on each slurm node
function cleanUp() {

  echo "Cleanup job folder incl. mount point"

  for slurm_host in "${XTREEMFS_NODES[@]}"; do
    outputDebug "Cleaning... $slurm_host of JOB: $JOB_ID"
    srun -k -N1-1 --nodelist="$slurm_host" rm -r "$LOCAL_DIR"
  done

  return 0
}

# calls the stop script remotely on each slurm node, passing the savelogs flag if activated
function stopServerAndSaveLogs() {

  SAVE_LOGS=""
  if [[ ! -z "$1" ]] && [[ "$1" == "-savelogs" ]]; then
    outputDebug "Saving logs is active"
    SAVE_LOGS="-savelogs"
  fi

  counter=1
  for osd_hostname in "${XTREEMFS_NODES[@]:$(( $SKIP_NODE_COUNT + 1 )):$(( $NUMBER_OF_NODES - ($SKIP_NODE_COUNT + 1) ))}"; do
    OSDNAME="OSD${counter}"
    srun -k -N1-1 --nodelist=$osd_hostname $BASEDIR/xtreemfs_slurm_rstop.sh "$SOURCE_FILE" "$OSDNAME" "$SAVE_LOGS"
    counter=$(($counter+1))
  done

  MRC_HOSTNAME="${XTREEMFS_NODES[@]:$SKIP_NODE_COUNT:1}"
  srun -k -N1-1 --nodelist=$MRC_HOSTNAME $BASEDIR/xtreemfs_slurm_rstop.sh "$SOURCE_FILE" "MRC" "$SAVE_LOGS"

  DIR_HOSTNAME="${XTREEMFS_NODES[@]:0:1}"
  srun -k -N1-1 --nodelist=$DIR_HOSTNAME $BASEDIR/xtreemfs_slurm_rstop.sh "$SOURCE_FILE" "DIR" "$SAVE_LOGS"

  return 0
}

# unmounts the volume, deletes the volumes and stops and deletes the XtreemFS farm setup
function stop() {

  initializeEnvironment

  MRC_HOSTNAME="${XTREEMFS_NODES[@]:$SKIP_NODE_COUNT:1}"
  VOLUME_NAME=$(substitudeJobID "$VOLUME_NAME_GENERIC")
  LOCAL_MOUNT_PATH=$(substitudeJobID "$LOCAL_MOUNT_PATH_GENERIC")
  CURRENT_JOB_FOLDER=$(substitudeJobID "$CURRENT_JOB_FOLDER_GENERIC")

  echo "Stopping XtreemFS $JOB_ID on slurm..."

  # stop watchdog
  for slurm_host in "${XTREEMFS_NODES[@]}"; do
   srun -k -N1-1 --nodelist=$slurm_host $BASEDIR/xtreemfs_slurm_rstop.sh "$SOURCE_FILE" "watchdog"
  done

  for slurm_host in "${XTREEMFS_NODES[@]}"; do
    if [[ ! -z "$1" ]] && [[ "$1" == "-savelogs" ]] && [[ "$DEBUG_CLIENT_ACTIVE" == true ]]; then
      mkdir -p "$CURRENT_JOB_FOLDER/savedLogs"
      srun -k -N1-1 --nodelist="$slurm_host" cp "$LOCAL_DIR/$slurm_host-client.log" "$CURRENT_JOB_FOLDER/savedLogs/$slurm_host-client.log"
    fi

    srun -k -N1-1 --nodelist="$slurm_host" $XTREEMFS_DIRECTORY/bin/umount.xtreemfs "$LOCAL_MOUNT_PATH"
  done

  $XTREEMFS_DIRECTORY/cpp/build/rmfs.xtreemfs -f $MRC_HOSTNAME/$VOLUME_NAME

  stopServerAndSaveLogs $1
  cleanUp

  return 0
}


# starts the XtreemFS farm setup, creates a volume and mounts it to the specified location
function start() {

  initializeEnvironment

  DIR_HOSTNAME="${XTREEMFS_NODES[@]:0:1}"
  MRC_HOSTNAME="${XTREEMFS_NODES[@]:$SKIP_NODE_COUNT:1}"

  VOLUME_NAME=$(substitudeJobID "$VOLUME_NAME_GENERIC")
  LOCAL_MOUNT_PATH=$(substitudeJobID "$LOCAL_MOUNT_PATH_GENERIC")

  echo "Starting XtreemFS $JOB_ID on slurm..."

  prepareConfigs
  startServer

  $XTREEMFS_DIRECTORY/cpp/build/mkfs.xtreemfs $VOLUME_PARAMETER $MRC_HOSTNAME/$VOLUME_NAME
  stopOnStartError $?

  # create local mount path on each node
  for slurm_host in "${XTREEMFS_NODES[@]}"; do
    srun -k -N1-1 --nodelist="$slurm_host" mkdir -p $LOCAL_MOUNT_PATH
    stopOnStartError $?
  done

  # mount volume on each node
  for slurm_host in "${XTREEMFS_NODES[@]}"; do
    _MOUNT_OPTIONS="$MOUNT_OPTIONS"

    if [[ "$DEBUG_CLIENT_ACTIVE" == true ]]; then
      _MOUNT_OPTIONS="$_MOUNT_OPTIONS -d $DEBUG_CLIENT_LEVEL -l $LOCAL_DIR/$slurm_host-client.log"
    fi

    srun -k -N1-1 --nodelist="$slurm_host" $XTREEMFS_DIRECTORY/cpp/build/mount.xtreemfs $_MOUNT_OPTIONS $DIR_HOSTNAME/$VOLUME_NAME "$LOCAL_MOUNT_PATH"
    stopOnStartError $?
  done

  # start watchdog
  for slurm_host in "${XTREEMFS_NODES[@]}"; do
    srun -k -N1-1 --nodelist="$slurm_host" $BASEDIR/xtreemfs_slurm_rstart.sh "$SOURCE_FILE" "watchdog"
    stopOnStartError $?
  done

  dir_hostname_ip=$(nslookup "$DIR_HOSTNAME" | awk -F': *' '/Address:/&&NR>2{print $2;exit}')
  CURRENT_JOB_ENV_FILE=$(substitudeJobID "$CURRENT_JOB_ENV_FILE_GENERIC")

  echo "export WORK=\"$LOCAL_MOUNT_PATH\"" > "$CURRENT_JOB_ENV_FILE"

  # This variable is set for running a Hadoop cluster
  echo "export DEFAULT_VOLUME=\"xtreemfs://$dir_hostname_ip:32638/$VOLUME_NAME\"" >> "$CURRENT_JOB_ENV_FILE"
  echo "export NODES_FILESYSTEM=\"${XTREEMFS_NODES[@]:0:$NUMBER_OF_NODES}\"" >> "$CURRENT_JOB_ENV_FILE"
  echo "export NODES_REMAINING=\""${XTREEMFS_NODES[@]:$NUMBER_OF_NODES}"\"" >> "$CURRENT_JOB_ENV_FILE"

  outputSummary

  return 0
}

function outputSummary() {

  echo "DIR HOST: ${XTREEMFS_NODES[@]:0:1}"
  echo "MRC HOST: ${XTREEMFS_NODES[@]:$SKIP_NODE_COUNT:1}"

  counter=1
  for osd_hostname in ${XTREEMFS_NODES[@]:$(( $SKIP_NODE_COUNT + 1 )):$(( $NUMBER_OF_NODES - ($SKIP_NODE_COUNT + 1) ))}; do
    echo "OSD${counter} HOST: $osd_hostname"
    counter=$(($counter+1))
  done

  echo "VOLUME: $(substitudeJobID $VOLUME_NAME_GENERIC)"
  echo "MOUNT PATH: $(substitudeJobID $LOCAL_MOUNT_PATH_GENERIC)"
  echo "JOB ENV FILE: $(substitudeJobID $CURRENT_JOB_ENV_FILE_GENERIC)"

  return 0
}

result=0
case "$1" in
  start)
    start
    result=$?
    ;;
   stop)
    stop $2
    result=$?
    ;;
   cleanup)
    initializeEnvironment
    cleanUp
    result=$?
    ;;
   clone)
    cloneGitHubRepository
    result=$?
    ;;
   *)
    echo -e "Usage: $0 [env.sh] {start|stop [-savelogs]|cleanup|clone}\n"
    result=1
    ;;
esac

exit $result
