#!/bin/bash

################################
# GLOBAL FAILURE HANDLER
################################
fail() {
    echo "❌ ERROR: $1"
    exit 1
}

run() {
    "$@"
    RC=$?
    if [ $RC -ne 0 ]; then
        fail "Command failed: $*"
    fi
}

step() {
   echo "===== $1 ====="
   shift
   "$@"
   RC=$?
   if [ $RC -ne 0 ]; then
      echo "❌ Step failed: $1"
      exit 1
   fi
}

################################
# LOAD ENV
################################
ENV_FILE="/opt/AlertEnterprise/configs/.env"

[ ! -f "$ENV_FILE" ] && fail "ENV file missing: $ENV_FILE"

source "$ENV_FILE" || fail "Failed to source ENV"

################################
# INPUT PARAMS
################################
S3_SRC_PATH="$1"
gitBranch="$2"
buildVersion="$3"
flywayFixed="$4"
ARTIFACTS_ARG="$5"

echo "DEBUG:"
echo "S3_SRC_PATH=$S3_SRC_PATH"
echo "gitBranch=$gitBranch"
echo "buildVersion=$buildVersion"

################################
# PRECHECK
################################
precheck() {

echo "========== PRECHECK START =========="

fail() {
   echo "❌ PRECHECK FAILED: $1"
   exit 1
}

################################
# SOFTWARE CHECK
################################
command -v java >/dev/null 2>&1 || fail "Java not installed"
command -v unzip >/dev/null 2>&1 || fail "unzip not installed"
command -v aws >/dev/null 2>&1 || fail "AWS CLI not installed"
command -v jq >/dev/null 2>&1 || fail "jq not installed"
command -v flyway >/dev/null 2>&1 || fail "flyway not installed"
command -v ss >/dev/null 2>&1 || fail "ss command missing"

################################
# IMPORTANT DIRECTORY CHECK
################################

[ -d "$CONFIG_PATH" ] || fail "CONFIG_PATH missing: $CONFIG_PATH"
[ -d "$INIT_APPS_PATH" ] || fail "INIT_APPS_PATH missing: $INIT_APPS_PATH"
[ -d "$BUILD_PATH" ] || fail "BUILD_PATH missing: $BUILD_PATH"
[ -d "$LOGS_PATH" ] || fail "LOGS_PATH missing: $LOGS_PATH"



################################
# DISK SPACE CHECK
################################
avail_gb=$(df -BG "$INIT_APPS_PATH" | awk 'NR==2 {gsub("G","",$4); print $4}')
[ "$avail_gb" -lt 3 ] && fail "Minimum 3 GB free space required on deployment mount"
################################
# JAVA WORKING CHECK
################################
java -version >/dev/null 2>&1 || fail "Java runtime not working"

echo "========== PRECHECK SUCCESS =========="

}

################################
# BUILD ARTIFACT LIST
################################
ARTIFACTS=()

IFS=',' read -ra SELECTED <<< "$ARTIFACTS_ARG"

for item in "${SELECTED[@]}"; do
    case "${item,,}" in
        application|agent)
            ARTIFACTS+=("$item")
            ;;
        *)
            fail "Invalid artifact value: $item"
            ;;
    esac
done

[ ${#ARTIFACTS[@]} -eq 0 ] && fail "No artifacts selected"

################################
# LOAD SECRETS
################################
[ -z "$SECRETS" ] && fail "SECRETS missing"

while read -r item; do
    key=$(jq -r 'keys[0]' <<< "$item")
    val=$(jq -r '.[keys[0]]' <<< "$item")
    export "$key=$val"
done < <(jq -c '.[]' <<< "$SECRETS")

[ -z "$keystorePass" ] && fail "keystorePass missing"

################################
# CREATE DIRS
################################
create_dirs() {
    echo "Creating directories"
    run mkdir -p "$APP_PATH" "$INIT_APPS_PATH" "$KEYSTORE_PATH" \
        "$CONFIG_PATH" "$SCRIPTS_PATH" "$TEMP_PATH" "$CERT_DIR" \
        "$LOGS_PATH" "$BUILD_PATH"
}

################################
# STOP SERVICES
################################
stop_services() {

    ################################
    # APPLICATION SERVICES
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then

        if [ ! -d "$INIT_APPS_PATH/alert-api-server-1.0" ]; then
            echo "ℹ️ API path not found → skipping"
        else
            echo "🛑 Stopping API service"
            aeapps stop api
            [ $? -ne 0 ] && fail "Failed stopping API"
        fi

        if [ ! -d "$INIT_APPS_PATH/alert-job-server-1.0" ]; then
            echo "ℹ️ JOB path not found → skipping"
        else
            echo "🛑 Stopping JOB service"
            aeapps stop job
            [ $? -ne 0 ] && fail "Failed stopping JOB"
        fi
    fi

    ################################
    # AGENT SERVICE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then

        if [ ! -d "$INIT_APPS_PATH/agent-server-1.0" ]; then
            echo "ℹ️ AGENT path not found → skipping"
        else
            echo "🛑 Stopping AGENT service"
            aeagent stop
            [ $? -ne 0 ] && fail "Failed stopping AGENT"
        fi
    fi
}

################################
# DOWNLOAD BUILDS
################################
download_build() {
    echo "📥 Downloading build artifacts..."

    mkdir -p builds
    [ $? -ne 0 ] && fail "BUILD directory creation failed"

    download_artifact() {
        local artifact="$1"
        local src="${S3_SRC_PATH}/${gitBranch}/${buildVersion}/${artifact}.zip"

        echo "⬇️ Downloading ${artifact}.zip"

        aws s3 cp "$src" "$BUILD_PATH"/
        rc=$?

        [ $rc -ne 0 ] && fail "Download failed for ${artifact}"

        echo "✔ Downloaded ${artifact}.zip"
    }

    ################################
    # APPLICATION artifacts
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Downloading APPLICATION artifacts"

        for artifact in api job ui DB; do
            download_artifact "$artifact"
        done
    fi

    ################################
    # AGENT artifacts
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Downloading AGENT artifacts"

        for artifact in agentserver agentDB; do
            download_artifact "$artifact"
        done
    fi

    echo "✅ Build download completed"
}

################################
# BACKUP
################################
backup() {

[ ! -d "$APP_PATH" ] && fail "APP_PATH missing"

[ -d "$APP_PATH/bkp_2" ] && run rm -rf "$APP_PATH/bkp_2"

if [ -d "$APP_PATH/bkp_1" ]; then
    if [ "$(find "$APP_PATH/bkp_1" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        run mkdir -p "$APP_PATH/bkp_2"
        run mv "$APP_PATH"/bkp_1/* "$APP_PATH"/bkp_2/
    fi
fi

if [ -d "$INIT_APPS_PATH" ] && [ "$(ls -A "$INIT_APPS_PATH")" ]; then
    run mkdir -p "$APP_PATH/bkp_1"
    cd "$INIT_APPS_PATH" || fail "cd failed"
    run mv * "$APP_PATH/bkp_1/"
fi

}

################################
# EXTRACT
################################
extract_zip() {

extract_artifact() {
    artifact="$1"
    zip_file="${BUILD_PATH}/${artifact}.zip"

    [ ! -f "$zip_file" ] && fail "$artifact zip missing"

    if [[ "${artifact,,}" == *db* ]]; then
        run unzip -qq "$zip_file" -d "${INIT_APPS_PATH}/${artifact}"
    else
        run unzip -qq "$zip_file" -d "${INIT_APPS_PATH}"
    fi
}

if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
    for a in api job ui DB; do extract_artifact "$a"; done
fi

if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
    for a in agentserver agentDB; do extract_artifact "$a"; done
fi

}

################################
# COPY ENV CONFIGS (STANDARDIZED)
################################
copy_env_configs() {

echo "⚙️ Copying ENV configs..."

copy_configs() {

    service="$1"
    app_conf_dir="$2"
    config_src="$3"
    apps_path="$4"

    echo "➡️ Copying configs for ${service^^}"

    [ ! -d "$app_conf_dir" ] && fail "Conf dir missing: $app_conf_dir"
    [ ! -d "$config_src" ] && fail "Config source missing: $config_src"

    cp "${config_src}/override_env.conf" "${app_conf_dir}/"
    [ $? -ne 0 ] && fail "override_env.conf copy failed for $service"

    cp "${config_src}/log4j2.xml" "${app_conf_dir}/"
    [ $? -ne 0 ] && fail "log4j2.xml copy failed for $service"

    if [ -f "${apps_path}/conf/keystore.conf" ]; then

        cp "${config_src}/keystore.conf" "${app_conf_dir}/"
        [ $? -ne 0 ] && fail "keystore.conf copy failed for $service"

        sed -i "s|{AEKEYSTOREFILE}|${keystoreFile}|g" \
            "${app_conf_dir}/keystore.conf"
        [ $? -ne 0 ] && fail "keystoreFile sed failed"

        sed -i "s|{AEKEYSTOREPASSWD}|${KEYSTORE_KEY_PATH}|g" \
            "${app_conf_dir}/keystore.conf"
        [ $? -ne 0 ] && fail "keystorePass sed failed"

    fi
}

[[ " ${ARTIFACTS[*]} " == *" application "* ]] && {

    copy_configs "api" \
        "${INIT_APPS_PATH}/alert-api-server-1.0/conf" \
        "${CONFIG_PATH}/api" \
        "${INIT_APPS_PATH}/alert-api-server-1.0"

    copy_configs "job" \
        "${INIT_APPS_PATH}/alert-job-server-1.0/conf" \
        "${CONFIG_PATH}/job" \
        "${INIT_APPS_PATH}/alert-api-server-1.0"
}

[[ " ${ARTIFACTS[*]} " == *" agent "* ]] && {

    copy_configs "agent" \
        "${INIT_APPS_PATH}/alert-agent-1.0/conf" \
        "${CONFIG_PATH}/agent" \
        "${INIT_APPS_PATH}/alert-agent-1.0"
}

echo "✅ ENV configs copied"

}


################################
# UPDATE environment.conf
################################
update_environment_conf() {

echo "📝 Updating environment.conf..."

update_env() {

    service="$1"
    env_file="$2"
    ORIGINAL="${env_file}.original"

    [ ! -f "$ORIGINAL" ] && fail "${ORIGINAL} missing for $service"

    cp "$ORIGINAL" "$env_file"
    [ $? -ne 0 ] && fail "environment.conf copy failed for $service"

    sed -i 's/\r$//' "$env_file"
    [ $? -ne 0 ] && fail "CRLF cleanup failed for $service"

    grep -q '^include "override_env"' "$env_file"
    if [ $? -ne 0 ]; then
        echo '' >> "$env_file"
        echo 'include "override_env"' >> "$env_file"
    fi

    echo "✔ environment.conf updated for ${service^^}"
}

[[ " ${ARTIFACTS[*]} " == *" application "* ]] && {
    update_env "api" \
    "$INIT_APPS_PATH/alert-api-server-1.0/conf/environment.conf"

    update_env "job" \
    "$INIT_APPS_PATH/alert-job-server-1.0/conf/environment.conf"
}

[[ " ${ARTIFACTS[*]} " == *" agent "* ]] && {
    update_env "agent" \
    "$INIT_APPS_PATH/alert-agent-1.0/conf/environment.conf"
}

return 0

}

################################
# KEYSTORE SETUP (STANDARDIZED)
################################
setup_keystore() {
    echo "🔐 Keystore setup started"

    [ -z "$keystorePass" ] && fail "keystorePass missing"
    [ -z "$keystoreFile" ] && fail "keystoreFile missing"

    echo "$KEYSTORE_SECRETS" | jq . >/dev/null 2>&1 \
    || fail "Invalid JSON in KEYSTORE_SECRETS"

    ################################
    # Select service paths
    ################################
    select_app_paths() {
        local service="$1"

        case "$service" in
            application)
                APPS_PATH="${INIT_APPS_PATH}/alert-api-server-1.0"
                ;;
            agent)
                APPS_PATH="${INIT_APPS_PATH}/alert-agent-1.0"
                ;;
            *)
                fail "Unknown service: $service"
                ;;
        esac

        BRANCH12_CONF="${APPS_PATH}/conf/keystore.conf"
        BRANCH11_JAR="${APPS_PATH}/lib/keystore-0.0.1-SNAPSHOT.jar"
    }

    ################################
    # Insert secrets (generic)
    ################################
    insert_secrets_branch12() {
        printf "%s" "$keystorePass" > "$KEYSTORE_KEY_PATH"
        [ $? -ne 0 ] && fail "Failed writing keystore password file"

        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Inserting key: $key (branch12)"
            cd "$APPS_PATH/lib" || fail "cd failed"

            run java -cp "./*" \
                -Dlog4j.configurationFile=../conf/log4j2.xml \
                -Dcrypto.configurationFile=../conf/keystore.conf \
                com.alnt.cryptoutil.Main key_upsert "$key" "$val"
        done

        run rm -f "$KEYSTORE_KEY_PATH"
    }

    insert_secrets_branch11() {
        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Inserting key: $key (branch11)"
            cd "$APPS_PATH/lib" || fail "cd failed"

            run java -jar keystore-0.0.1-SNAPSHOT.jar \
                "$keystoreFile" \
                "$keystorePass" \
                "$val" "$key"
        done
    }

    ################################
    # Create keystore
    ################################
    create_keystore_branch12() {
        run keytool -genseckey -keyalg AES -keysize 256 \
            -keystore "$keystoreFile" \
            -storetype PKCS12 \
            -storepass "$keystorePass" \
            -keypass "$keystorePass"
    }

    create_keystore_branch11() {
        run keytool -genkeypair \
            -dname "cn=Alert Enterprise, ou=Java, o=Oracle, c=US" \
            -alias alert \
            -keystore "$keystoreFile" \
            -storepass "$keystorePass" \
            -keypass "$keystorePass"
    }

    ################################
    # Decide service
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        SERVICE="application"
    elif [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        SERVICE="agent"
    else
        echo "⚠️ No service selected for keystore setup"
        return
    fi

    select_app_paths "$SERVICE"

    ################################
    # Branch detection + execution
    ################################
    if [ -f "$BRANCH12_CONF" ]; then
        echo "🧭 Detected Branch 12 keystore"

        if [ ! -f "$keystoreFile" ]; then
            create_keystore_branch12
            insert_secrets_branch12
        else
            echo "ℹ️ Keystore already exists, skipping creation"
        fi

    elif [ -f "$BRANCH11_JAR" ]; then
        echo "🧭 Detected Branch 11 keystore"

        if [ ! -f "$keystoreFile" ]; then
            create_keystore_branch11
            insert_secrets_branch11
        else
            echo "ℹ️ Keystore already exists, skipping creation"
        fi
    else
        fail "No keystore mechanism found"
    fi

    echo "✅ Keystore setup completed"
}


################################
# SCRIPT LINKS SETUP
################################
scriptlinks() {

echo "🔗 Setting script links"

mkdir -p "$SCRIPTS_PATH" || fail "Script path create failed"

setup_script() {

service="$1"
script="$2"
bin="$3"

SRC="/tmp/scripts/startupScripts/${script}"
DEST="${SCRIPTS_PATH}/${script}"
LINK="/usr/bin/${bin}"

[ ! -f "$SRC" ] && fail "Startup script missing: $SRC"

cp "$SRC" "$DEST"
[ $? -ne 0 ] && fail "Script copy failed"

chmod +x "$DEST"
[ $? -ne 0 ] && fail "chmod failed"

ln -sf "$DEST" "$LINK"
[ $? -ne 0 ] && fail "symlink failed"

}

[[ " ${ARTIFACTS[*]} " == *" application "* ]] && \
setup_script "application" "aeapps.sh" "aeapps"

[[ " ${ARTIFACTS[*]} " == *" agent "* ]] && \
setup_script "agent" "aeagent.sh" "aeagent"

echo "✅ Script links done"

}

uiSetup() {


if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
    echo "ui setup not required for agent"
    return 0
fi

if [ -d "${INIT_APPS_PATH}/production/AlertUI" ]; then
    mv "${INIT_APPS_PATH}/production/AlertUI" "${INIT_APPS_PATH}/"
    [ $? -ne 0 ] && fail "UI move failed"
else
    fail "AlertUI directory missing"
fi

if [ -d "${INIT_APPS_PATH}/production" ]; then
    rm -rf "${INIT_APPS_PATH}/production"
    [ $? -ne 0 ] && fail "Production cleanup failed"
fi

echo "✅ UI setup completed"

}

################################
# START SERVICES
################################
applicationStart() {

export KEYSTORE_PASS="$keystorePass"

if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
    aeapps start api
    [ $? -ne 0 ] && fail "API start failed"

    aeapps start job
    [ $? -ne 0 ] && fail "JOB start failed"
fi

if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
    aeagent start
    [ $? -ne 0 ] && fail "AGENT start failed"
fi

}

################################
# VALIDATE PORTS
################################
validate() {

check_port() {
    service="$1"
    port="$2"
    retry=0

    while true; do
        ss -tuln | grep -q ":$port"
        if [ $? -eq 0 ]; then
            echo "$service up"
            return
        fi

        retry=$((retry+1))
        [ $retry -ge 10 ] && fail "$service not started on $port"
        sleep 30
    done
}

[[ " ${ARTIFACTS[*]} " == *" application "* ]] && {
    check_port api 9000
    check_port job 9090
}

[[ " ${ARTIFACTS[*]} " == *" agent "* ]] && check_port agent 9095

return 0

}

################################
# FLYWAY
################################
flyway_run() {

mkdir -p "$LOGS_PATH/flyway"

################################
# DB MIGRATION PATHS (VERY IMPORTANT)
################################

if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
    [ -d "$DB_PATH" ] || fail "Application DB_PATH missing: $DB_PATH"
    [ -d "${DB_PATH}DML" ] || fail "Application DB DML path missing: ${DB_PATH}DML"
fi

if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
    [ -d "$DB_PATH_AGENT" ] || fail "Agent DB_PATH missing: $DB_PATH_AGENT"
    [ -d "${DB_PATH_AGENT}DML" ] || fail "Agent DB DML path missing: ${DB_PATH_AGENT}DML"
fi

run_flyway() {

service="$1"
locations="$2"
logfile="$3"
schema="$4"

flyway repair \
-user="$flywayUser" \
-password="$flywayPass" \
-url="$dbURL" \
-schemas="$schema" \
-locations="$locations"

set -o pipefail

flyway migrate \
-user="$flywayUser" \
-password="$flywayPass" \
-url="$dbURL" \
-schemas="$schema" \
-locations="$locations" \
2>&1 | tee "$logfile"

RC_FLYWAY=$?

echo "flyway exit code: $RC_FLYWAY"
# RC_FLYWAY=${PIPESTATUS[0]}
# RC_TEE=${PIPESTATUS[1]}

# Defensive defaulting
# RC_FLYWAY=${RC_FLYWAY:-1}
# RC_TEE=${RC_TEE:-1}

if [ "$RC_FLYWAY" -ne 0 ]; then
    fail "Flyway migration FAILED"
fi

# if [ "$RC_TEE" -ne 0 ]; then
#     fail "Flyway logging FAILED"
# fi

grep -q "Successfully" "$logfile" \
|| echo "⚠ Flyway success message not found (non-fatal)"

}

[[ " ${ARTIFACTS[*]} " == *" application "* ]] && \
run_flyway application "filesystem:${DB_PATH}" "$LOGS_PATH/flyway/flyway_application.log" "$dbSchemaApp"

[[ " ${ARTIFACTS[*]} " == *" agent "* ]] && \
run_flyway agent "filesystem:${DB_PATH_AGENT}" "$LOGS_PATH/flyway/flyway_agent.log" "$dbSchemaAgent"

lastcommand=$?

echo "checkagent flway exit code : $lastcommand"

return 0

}

################################
# MAIN
################################
main() {
step "Create dirs" create_dirs
step "Precheck" precheck

if [[ "${flywayFixed,,}" == "true" ]]; then
    echo "Flyway only mode"
    step "Flyway" flyway_run
    exit 0
fi
step "Stop services" stop_services
step "Download build" download_build
step "Backup" backup
step "Extract" extract_zip
step "Copy configs" copy_env_configs
step "Update env" update_environment_conf
step "Keystore" setup_keystore
step "Script links" scriptlinks
step "UI setup" uiSetup
step "Start services" applicationStart
step "Validate" validate
step "Flyway" flyway_run

echo "✅ DEPLOY SUCCESS"

}

main