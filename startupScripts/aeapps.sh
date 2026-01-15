#!/bin/bash
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin
ACTION=$1
APP_TYPE=$(echo "$2" | tr '[:upper:]' '[:lower:]')
source /opt/AlertEnterprise/configs/.env

# if [ "$APP_TYPE" = "API" ]; then
#     httPort=9000
#     confFile=conf/application.conf
# elif [ "$APP_TYPE" = "JOB" ]; then
#     httPort=9090
#     confFile=conf/jobserver.conf
# fi

echo "apptype : $APP_TYPE"


# Exit if SECRETS is empty or unset
[ -z "$SECRETS" ] && echo "SECRETS is missing!" && exit 1

# Export key-value pairs
while read -r item; do
    eval "$(echo "$item" | jq -r 'to_entries[] | "export \(.key)=\(.value)"')"
done < <(echo "$SECRETS" | jq -c '.[]')


########Finish#######################
# keystorePass=$(echo "$SECRETS" | jq -r '.keystorePass')
[ -z "$keystorePass" ] && echo "Missing keystorePass!" && exit 1

export KEYSTORE_PASS=${keystorePass}

#/=========changeable start ========
API_PATH="/opt/AlertEnterprise/apps/alert-api-server-1.0"
JOB_PATH="/opt/AlertEnterprise/apps/alert-job-server-1.0"

API_BIND_ADDRESS="0.0.0.0"
API_PORT=9000

host=$(hostname)
ts=$(date +%Y%m%d_%H%M%S)
heap_file_api="/tmp/heapdump_api__${host}_${ts}.hprof"
API_OOM_COMMAND="aws s3 mv ${heap_file_api} s3://${S3_HEAPDUMP_BUCKET}/api/ && kill -9 %p"

API_EXTRA_PARAMS=(
  -XX:MaxRAMPercentage=80.0
  -XX:+UseG1GC
  -XX:InitiatingHeapOccupancyPercent=10
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath="${heap_file_api}"
  "-XX:OnOutOfMemoryError=sh -c '$API_OOM_COMMAND'"
)

JOB_BIND_ADDRESS="0.0.0.0"
JOB_PORT=9090

heap_file_job="/tmp/heapdump_job__${host}_${ts}.hprof"
JOB_OOM_COMMAND="aws s3 mv ${heap_file_job} s3://${S3_HEAPDUMP_BUCKET}/job/ && kill -9 %p"

JOB_EXTRA_PARAMS=(
  -XX:MaxRAMPercentage=80.0
  -XX:+UseG1GC
  -XX:InitiatingHeapOccupancyPercent=10
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath="${heap_file_job}"
  "-XX:OnOutOfMemoryError=sh -c '$JOB_OOM_COMMAND'"
)


#APP_TYPE="API"   # When this script only for a API
#APP_TYPE="JOB"   # When this script only for a JOB

VALIDATE=true
LOGS_DIR="logs"
LOG_ACTION="backup" # Set this to "backup", "del", "delete", or leave it empty

#/=========changeable end ========

check_paths() {
  local path=$1
  if [[ "$path" == "API" ]]; then

    if [ ! -d "$API_PATH" ]; then
      echo "API directory $API_PATH does not exist."
      exit 1
    fi
  else

    if [ ! -d "$JOB_PATH" ]; then
      echo "Job directory $JOB_PATH does not exist."
      exit 1
    fi
  fi
}

stop_application() {
  local conf_file=$1
  pid=$(pgrep -f "$conf_file")
  if [ -n "$pid" ]; then
    echo "Stopping application (PID: $pid) gracefully..."
    kill -9 "$pid"
    echo "Application stopped successfully."
  else
    echo "Application is not running."
  fi
}

check_status2() {
  local conf_file=$1
  pid=$(pgrep -f "$conf_file")
  if [ -n "$pid" ]; then
    echo "Application is running with PID: $pid"
  else
    echo "Application is not running."
  fi
}

check_status() {
  local conf_file=$1
  local APPS_PATH=$2
  local RUNNING_PID_FILE="$APPS_PATH/RUNNING_PID"

  if [ -f "$RUNNING_PID_FILE" ]; then
    local pid=$(cat "$RUNNING_PID_FILE")
    if ps -p $pid >/dev/null 2>&1; then
      echo "Application is running with PID: $pid"
    else
      echo "RUNNING_PID $pid is found, but no process found in the system."
    fi
  else
    local pid=$(pgrep -f "$conf_file")
    if [ -n "$pid" ]; then
      local running_dir=$(readlink /proc/$pid/cwd)
      if [ "$running_dir" == "$APPS_PATH" ]; then
        echo "RUNNING_PID file not found, but application seems running with PID: $pid"
      else
        echo "RUNNING_PID file not found, but application seems running with PID: $pid from a different directory: $running_dir"
      fi
    else
      echo "Application is not running."
    fi
  fi
}

check_pid() {
  local pid_file=$1
  if [ -f "$pid_file" ]; then
    PID=$(cat "$pid_file")

    if ps -p $PID >/dev/null 2>&1; then
      echo "Application is already running with PID $PID."
      exit 0
    else
      echo "RUNNING_PID file found but no process found against PID $PID."
      echo "Deleting the RUNNING_PID file as PID was inside <$PID>."
      rm -f "$pid_file"
    fi
  else
    echo "RUNNING_PID file does not exist."
  fi
}

handle_logs() {
  local action=$1
  local backup_base_dir="backup_by_ae_script"
  local timestamp=$(date +"%Y%m%d_%H%M%S")
  local backup_dir="${backup_base_dir}/logs_backup_${timestamp}"

  case $action in
  backup)
    echo "Backing up logs directory to $backup_dir."
    mkdir -p "$backup_dir"
    cp -r "$LOGS_DIR"/* "$backup_dir"/
    ;;
  del | delete)
    echo "Deleting logs directory."
    rm -rf "$LOGS_DIR"
    ;;
  *)
    echo "Leaving logs directory as-is."
    ;;
  esac
  mkdir -p "$LOGS_DIR"
}
start_application() {
  local conf_file=$1
  local APPS_PATH=$2
  local -a EXTRA_PARMS=("${!3}")
  local APP_PORT=$4
  local APP_ADDRESS=$5

  cd "${APPS_PATH}"

  RUNNING_PID_FILE="RUNNING_PID"
  check_pid "$RUNNING_PID_FILE"
  handle_logs $LOG_ACTION
  echo "Running command:"

  exec nohup java -cp "./lib/*" "${EXTRA_PARMS[@]}" \
    -Dconfig.file=conf/${conf_file} \
    -Dhttp.port=${APP_PORT} \
    -Dhttp.address=${APP_ADDRESS} \
    -Dlogback.debug=true \
    -Dorg.owasp.esapi.resources=conf \
    -Dlog4j.configurationFile=conf/log4j2.xml \
    play.core.server.ProdServerStart >>"${APPS_PATH}/logs/consoleLogs" 2>&1 &

  PID=$!
  echo "Background process started with PID: $PID"

  if [ "$VALIDATE" = true ]; then
    echo "Validation is enabled."
    initial_check $PID ${APP_PORT}
  else
    echo "Validation is disabled."
  fi
}

initial_check() {
  local PID=$1
  local APP_PORT=$2
  duration=30
  interval=10
  iterations=$((duration / interval))
  echo "Apps checking Env Conf file.."
  for ((i = 0; i < iterations; i++)); do
    if ps -p $PID >/dev/null; then
      echo "Apps still checking Env Conf file.."
    else
      echo "Apps failed..."
      cat "${APPS_PATH}/logs/consoleLogs"
      cat "${APPS_PATH}/logs/app.log"
      exit 1
      break
    fi
    sleep $interval
  done
  echo "Env Conf file seems fine.."
  validate_service ${APP_PORT}
}

validate_service() {
  max_retries=20
  retry_count=0
  local port=$1

  while ! netstat -tuln | grep ":$port\s" >/dev/null 2>&1; do
    if [ "$retry_count" -ge "$max_retries" ]; then
      echo "Timeout: Port $port did not become available after $((max_retries * 30)) seconds."
      exit 1
    fi
    ((retry_count++))
    echo "The AE App is still starting up. Please wait... Retrying in 30 seconds... (Attempt $retry_count)"
    sleep 30
  done
  echo "The AE App is now up and running on port $port."
}

shopt -s nocasematch

echo "APP_TYPE is jjjjj : $APP_TYPE"
if [[ "$APP_TYPE" == "API" ]]; then
  check_paths "API"
  app_conf="application.conf"
  app_path="${API_PATH}"
  app_extra="API_EXTRA_PARAMS[@]"
  app_port="${API_PORT}"
  app_address="${API_BIND_ADDRESS}"

elif [[ "$APP_TYPE" == "JOB" ]]; then
  check_paths "JOB"
  app_conf="jobserver.conf"
  app_path="${JOB_PATH}"
  app_extra="JOB_EXTRA_PARAMS[@]"
  app_port="${JOB_PORT}"
  app_address="${JOB_BIND_ADDRESS}"
else
  echo "Usage: $0 {start|stop|restart|status|log|logs|exp} {API|JOB} "
  exit 1
fi
shopt -u nocasematch

case "$ACTION" in
start)
  start_application "${app_conf}" "${app_path}" "${app_extra}" $app_port "$app_address"
  ;;
stop)
  stop_application "${app_conf}"
  ;;
restart)
  stop_application "${app_conf}"
  sleep 2
  start_application "${app_conf}" "${app_path}" "${app_extra}" $app_port "$app_address"
  ;;
status)
  check_status "${app_conf}" "${app_path}"
  ;;
log)
  cat "${app_path}"/logs/app.log
  ;;
logs)
  tail -f "${app_path}"/logs/app.log
  ;;
*)
  echo "Usage: $0 {start|stop|restart|status|log|logs|exp} {API|JOB} "
  exit 1
  ;;
esac

exit 0