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
ENV_FILE_STATIC="/opt/AlertEnterprise/configs/.env_static"

[ ! -f "$ENV_FILE_STATIC" ] && fail "ENV file missing: $ENV_FILE_STATIC"

source "$ENV_FILE_STATIC" || fail "Failed to source ENV"

################################
# INPUT PARAMS
################################
S3_SRC_PATH="$1"
gitBranch="$2"
buildVersion="$3"
ARTIFACTS_ARG="$4"

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
# CREATE DIRS
################################
create_dirs() {
    echo "Creating directories"
    run mkdir -p "$APP_PATH" "$INIT_APPS_PATH" "$KEYSTORE_PATH" \
        "$CONFIG_PATH" "$SCRIPTS_PATH" "$TEMP_PATH" "$CERT_DIR" \
        "$LOGS_PATH" "$BUILD_PATH"
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

        for artifact in api; do
            download_artifact "$artifact"
        done
    fi

    ################################
    # AGENT artifacts
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Downloading AGENT artifacts"

        for artifact in agentserver; do
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
    for a in api; do extract_artifact "$a"; done
fi

if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
    for a in agentserver; do extract_artifact "$a"; done
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
}

[[ " ${ARTIFACTS[*]} " == *" agent "* ]] && {
    update_env "agent" \
    "$INIT_APPS_PATH/alert-agent-1.0/conf/environment.conf"
}

return 0

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

otherScriptlinks() {

    echo "🔗 Setting other script links"

    mkdir -p "$SCRIPTS_PATH" || fail "Script path create failed"

    setup_script() {

        appdir="$1"
        script="$2"
        bin="$3"

        SRC="/tmp/scripts/otherScripts/${script}"
        DEST="${SCRIPTS_PATH}/${script}"
        LINK="/usr/bin/${bin}"

        [ ! -f "$SRC" ] && fail "Startup script missing: $SRC"

        cp "$SRC" "$DEST" || fail "Script copy failed"

        sed -i "s|{basePath}|$APP_PATH|g" "$DEST"
        sed -i "s|{applicationDirectoryName}|$appdir|g" "$DEST"

        chmod +x "$DEST" || fail "chmod failed"

        ln -sf "$DEST" "$LINK" || fail "symlink failed"
    }

    for file in aeEncrypter.sh setup.sh
    do
        # remove .sh extension for symlink name
        bin="${file%.sh}"

        if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then

            setup_script "alert-api-server-1.0" "$file" "$bin"

        elif [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then

            setup_script "alert-agent-1.0" "$file" "$bin"

        fi
    done

    echo "✅ Script links done"
}

################################
# MAIN
################################
main() {
step "Create dirs" create_dirs
step "Precheck" precheck

step "Download build" download_build
step "Backup" backup
step "Extract" extract_zip
step "Copy configs" copy_env_configs
step "Update env" update_environment_conf
step "Script links" scriptlinks
step "Other Script links" otherScriptlinks
echo "env pre-requisite done"

}

main