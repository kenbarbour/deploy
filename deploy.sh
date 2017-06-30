#!/bin/bash
##
## Usage: _PROG_ SOURCEPATH [options]
##      | _PROG_ -h|--help
##
## Deploys directory at SOURCEPATH to each space-separated SSH host in SERVERS
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
args=$(getopt -l "app:,dest:,exec:,log:,servers:,help" -o "a:d:e:l:s:h" -- "$@")
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
    --slack)
      SLACKTARGET="$2"
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
SOURCEPATH=$1
shift


# Defaults
APP_NAME=${APP_NAME:-$(basename ${SOURCEPATH})}
DESTPATH=${DESTPATH:-"/var/www/html/${APP_NAME}"}
SERVERS=${SERVERS:-"127.0.0.1"}
LOG=${LOG:-~/logs/deploy/${APP_NAME}.log}

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

# Start deploying
log "Starting deploy process for ${APP_NAME}"

# Check that SOURCEPATH exists
if [ ! -d "${SOURCEPATH}" ]; then
  error "Directory ${SOURCEPATH} does not exist" ${EXIT_DNE}
fi
log "Deploying from directory ${SOURCEPATH}"

# Do Deployfile
if [ -f "${SOURCEPATH}/Deployfile" ]; then
  pushd ${SOURCEPATH} > /dev/null
  . Deployfile
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
  rsync -rz -e "ssh -p $PORT" --delete $SOURCEPATH/ $HOST:$DESTPATH/ >> "${LOG}" 2>&1

  if [ $? -ne 0 ]; then
    error "Error copying sources to host $HOST:$PORT" ${EXIT_RSYNC}
    exit 2
  fi

  if [ $EXEC ]; then
    log 'Executing command:'
    ssh -p $PORT $HOST:$DESTPATH "${EXEC}"
  fi
done

error "Die last minute"
if [ "$(type -t deploy_post_hook)" = function ]; then
  log "Running deploy_post_hook"
  deploy_post_hook
fi
log "Deployment successful for ${APP_NAME}"
exit ${EXIT_NORMAL}