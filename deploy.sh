#!/bin/bash
##
## Usage: _PROG_ SOURCEPATH [options]
##      | _PROG_ -h|--help
##
## Deploys directory at SOURCEPATH to each space-separated SSH host in SERVERS.
## If SOURCEPATH contains a file named Deployfile, it is run.
##
##  Options:
##    -a|--app PARAM        APP_NAME to use (default basename SOURCEPATH)
##    -d|--dest PARAM       Destination on servers
##                            (default /var/www/html/APP_NAME)
##    -e|--exec CMD         command to execute on server after deploying
##    -l|--log PARAM        Log directory 
##    -s|--servers PARAM    Space separated list of SSH Hosts
##
##    -h|--help             Display this help message
##    --rsync FLAGS         Additional rsync flags
##
##  Deployfile:
##    Deployfile is run within the SOURCEPATH directory. 
##  The following variables are available within a Deployfile script:
##    * APP_NAME : string name of the App that is being deployed
##    * SOURCEPATH : path on the local machine to the source
##    * DESTPATH : path on each server to serve from
##    * SERVERS : space separated list of SSH Hosts
##    * RSYNC_FLAGS : string of additional rsync flags
##    * LOG : path to the log
##    * EXEC : command to execute on each server after a deployment
##
##  If the Deployfile can optionally define the following functions:
##    deploy_post_hook() : executed after deploy finishes running successfully
##    deploy_error_hook(message) : executed when deploy encounters an error
##  

prog="$0"
me=`basename "$prog"`
usage() {
  grep '^##' "$prog" | sed -e 's/^##\s\?//' -e "s/_PROG_/$me/" 1>&2
}

readonly EXIT_NORMAL=0
readonly EXIT_INVALID=1
readonly EXIT_DNE=2
readonly EXIT_EXEC=3
readonly EXIT_RSYNC=4


# Parse Arguments
args=$(getopt -l "app:,dest:,exec:,log:,servers:,rsync:,help" -o "a:d:e:l:s:h" -- "$@")
eval set -- "$args"
while [ $# -ge 1 ]; do
  case "$1" in
    --)
      # No more options left
      shift
      break
      ;;
    -a|--app)
      APP_NAME="$2"
      shift
      ;;
    -d|--dest)
      DESTPATH="$2"
      shift
      ;;
    -e|--exec)
      EXEC="$2"
      shift
      ;;
    -l|--log)
      LOG="$2"
      shift
      ;;
    -s|--servers)
      SERVERS="$2"
      shift
      ;;
    --rsync)
      RSYNC_FLAGS="$2"
      shift
      ;;
    -h|--help)
      usage
      exit ${EXIT_NORMAL}
      shift
      ;;
    *)
      echo "Unknown argument $1" 1>&2
      usage
      exit ${EXIT_INVALID}
      ;;
      
  esac
  shift
done


# Get SOURCEPATH (required)
if [ $# -lt 1 ]; then
  echo "Missing required argument SOURCEPATH" 1>&2
  usage
  exit $EXIT_INVALID
fi
SOURCEPATH=$(readlink -f $1)
shift


log() {
  echo $1
  if [ ! -z "$LOG" ]; then
    echo "[$(date +"%Y-%m-%d %T")] $1" >> "$LOG"
  fi
}

error() {
  log "ERROR: $1"
  log "Deployment failed."
  if [ "$(type -t deploy_post_hook)" = function ]; then
    log "Running deploy_error_hook"
    deploy_error_hook $1
  fi
  exit $2
}


# Check that SOURCEPATH exists and setup variable defaults
if [ ! -d "${SOURCEPATH}" ]; then
  error "Directory ${SOURCEPATH} does not exist" ${EXIT_DNE}
fi
APP_NAME=${APP_NAME:-$(basename $(readlink -f ${SOURCEPATH}))}
DESTPATH=${DESTPATH:-"/var/www/html/${APP_NAME}"}
SERVERS=${SERVERS:-"127.0.0.1"}
LOG=${LOG:-~/logs/deploy/${APP_NAME}.log}
RSYNC_FLAGS=${RSYNC_FLAGS:-""}

# Start deploying
log "Starting deploy process for directory: ${SOURCEPATH}"

# Do Deployfile
if [ -f "${SOURCEPATH}/Deployfile" ]; then
  pushd ${SOURCEPATH} > /dev/null
  . ./Deployfile
  DEPLOYFILE_STATUS="$?"
  popd > /dev/null
  if [ "${DEPLOYFILE_STATUS}" -ne 0 ]; then
    error "Deployfile returned exit status ${DEPLOYFILE_STATUS}" ${EXIT_EXEC}
  fi
fi

# rsync to servers
log "Beginning rsync to ${DESTPATH}"
for SERVER in $SERVERS
do
  IFS=':'
  read HOST PORT <<< "$SERVER"
  if [ -z "$PORT" ]
  then
    PORT=22
  fi
  
  log "  rsyncing ${HOST} ${DESTPATH} (port ${PORT})"
  rsync -rz ${RSYNC_FLAGS} \
    --log-file="${LOG}" \
    --exclude='Deployfile' \
    -e "ssh -p $PORT" --delete \
    $SOURCEPATH/ $HOST:$DESTPATH/ >> "${LOG}" 2>&1
  #echo "rsync -rz -e \"ssh -p $PORT\" --delete $SOURCEPATH/ $HOST:$DESTPATH/"

  if [ $? -ne 0 ]; then
    error "Error copying sources to host $HOST:$PORT" ${EXIT_RSYNC}
    exit 2
  fi

  if [ $EXEC ]; then
    log 'Executing command:'
    ssh -p $PORT $HOST "cd ${DESTPATH} ; ${EXEC}"
  fi
done

# Execute deploy_post_hook and exit
if [ "$(type -t deploy_post_hook)" = function ]; then
  log "Running deploy_post_hook"
  deploy_post_hook
fi
log "Deployment successful for ${APP_NAME}"
exit ${EXIT_NORMAL}
