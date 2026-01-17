#!/bin/bash
set -e

################################
# LOAD ENV
################################
ENV_FILE="/opt/AlertEnterprise/configs/.env"

[ ! -f "$ENV_FILE" ] && echo "❌ ENV file missing: $ENV_FILE" && exit 1
source "$ENV_FILE"


export S3_SRC_PATH="$1"
export gitBranch="$2"
export buildVersion="$3"

echo "DEBUG:"
echo "S3_SRC_PATH=$S3_SRC_PATH"
echo "gitBranch=$gitBranch"
echo "buildVersion=$buildVersion"


################################
# BUILD ARTIFACTS LIST
################################
ARTIFACTS=()

if [ "$APPLICATION" = "true" ]; then
    ARTIFACTS+=("application")
fi

if [ "$AGENT" = "true" ]; then
    ARTIFACTS+=("agent")
fi

echo "DEBUG: APPLICATION=$APPLICATION"
echo "DEBUG: AGENT=$AGENT"
echo "DEBUG: ARTIFACTS=${ARTIFACTS[*]}"

if [ "${#ARTIFACTS[@]}" -eq 0 ]; then
    echo "❌ No artifacts selected. Set APPLICATION or AGENT to true"
    exit 1
fi

################################
# LOAD & EXPORT SECRETS
################################
[ -z "$SECRETS" ] && echo "❌ SECRETS is missing!" && exit 1

while read -r item; do
    key=$(jq -r 'keys[0]' <<< "$item")
    val=$(jq -r '.[keys[0]]' <<< "$item")
    export "$key=$val"
done < <(jq -c '.[]' <<< "$SECRETS")

if [ -z "$keystorePass" ]; then
    echo "❌ keystorePass not found in SECRETS"
    exit 1
fi

################################
# FUNCTIONS
################################
create_dirs() {
    echo "📁 Creating directories..."
    for dir in \
        "$APP_PATH" \
        "$INIT_APPS_PATH" \
        "$KEYSTORE_PATH" \
        "$CONFIG_PATH" \
        "$SCRIPTS_PATH" \
        "$TEMP_PATH" \
        "$CERT_DIR"\
        "$LOGS_PATH"
    do
        mkdir -p "$dir"
    done
}

stop_services() {
    echo "🛑 Stopping services..."

    ############################
    # APPLICATION
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Stopping API and JOB services"

        aeapps stop api
        aeapps stop job
    fi

    ############################
    # AGENT
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Stopping AGENT service"

        aeagent stop
    fi

    echo "✅ Service stop completed"
}


backup() {
    echo "📦 Starting backup process..."

    # Ensure APP_PATH exists
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ APP_PATH does not exist: $APP_PATH"
        return 1
    fi

    # Remove old bkp_2 if present
    if [ -d "$APP_PATH/bkp_2" ]; then
        ls -ld "$APP_PATH/bkp_2"
        rm -rf "$APP_PATH/bkp_2"
        echo "🗑️ Removed bkp_2"
    fi

    # Move bkp_1 → bkp_2
    if [ -d "$APP_PATH/bkp_1" ]; then
        ls -ld "$APP_PATH/bkp_1"
        mkdir -p "$APP_PATH/bkp_2"
        mv "$APP_PATH/bkp_1" "$APP_PATH/bkp_2/"
        echo "🔁 Moved bkp_1 to bkp_2"
    fi

    # Create new bkp_1 and move current apps into it
    # Create new bkp_1 and move current apps into it
if [ -d "$INIT_APPS_PATH" ] && [ "$(ls -A "$INIT_APPS_PATH")" ]; then
    echo "📁 Creating bkp_1"
    mkdir -p "$APP_PATH/bkp_1"

    cd "$INIT_APPS_PATH" || exit 1
    mv * "$APP_PATH/bkp_1/" 2>/dev/null || true

    echo "✅ Current apps backed up to bkp_1"
else
    echo "⚠️ No existing apps directory to backup"
fi

}

################################
# DOWNLOAD BUILD ARTIFACTS
################################
download_build() {
    echo "📥 Downloading build artifacts..."
    mkdir -p builds

    download_artifact() {
        local artifact="$1"
        local src="${S3_SRC_PATH}/${gitBranch}/${buildVersion}/${artifact}.zip"

        echo "⬇️ Downloading ${artifact}.zip"
        if aws s3 cp "$src" builds/; then
            echo "✔ Downloaded ${artifact}.zip"
        else
            echo "⚠️ ${artifact}.zip not found, skipping"
        fi
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
# EXTRACT ARTIFACTS (STANDARDIZED)
################################
extract_zip() {
    echo "📦 Extracting artifacts..."

    extract_artifact() {
        local artifact="$1"
        local zip_file="${BUILD_PATH}/${artifact}.zip"

        if [ -f "$zip_file" ]; then
            echo "✔ Extracting ${artifact}.zip"
            unzip -qq "$zip_file" -d "$INIT_APPS_PATH"
        else
            echo "⚠️ ${artifact}.zip not found, skipping"
        fi
    }

    ################################
    # APPLICATION artifacts
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Extracting APPLICATION artifacts"

        for artifact in api job ui DB; do
            extract_artifact "$artifact"
        done
    fi

    ################################
    # AGENT artifacts
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Extracting AGENT artifacts"

        for artifact in agentserver agentDB; do
            extract_artifact "$artifact"
        done
    fi
}


################################
# COPY ENV CONFIGS (STANDARDIZED)
################################
copy_env_configs() {
    echo "⚙️ Copying ENV configs..."

    copy_configs() {
        local service="$1"
        local app_conf_dir="$2"
        local config_src="$3"
        local apps_path="$4"

        echo "➡️ Copying configs for ${service^^}"

        cp "${config_src}/override_env.conf" "${app_conf_dir}/"
        cp "${config_src}/log4j2.xml" "${app_conf_dir}/"

        # ---- Branch 12 keystore handling ----
        if [ -f "${apps_path}/conf/keystore.conf" ]; then
            echo "🔐 Updating keystore.conf for ${service^^}"

            cp "${config_src}/keystore.conf" "${app_conf_dir}/"

            sed -i "s|{AEKEYSTOREFILE}|${keystoreFile}|g" \
                "${app_conf_dir}/keystore.conf"

            sed -i "s|{AEKEYSTOREPASSWD}|${KEYSTORE_KEY_PATH}|g" \
                "${app_conf_dir}/keystore.conf"
        fi
    }

    ################################
    # APPLICATION (API + JOB)
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        copy_configs \
            "api" \
            "${INIT_APPS_PATH}/alert-api-server-1.0/conf" \
            "${CONFIG_PATH}/api" \
            "${INIT_APPS_PATH}/alert-api-server-1.0"

        copy_configs \
            "job" \
            "${INIT_APPS_PATH}/alert-job-server-1.0/conf" \
            "${CONFIG_PATH}/job" \
            "${INIT_APPS_PATH}/alert-api-server-1.0"
    fi

    ################################
    # AGENT
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        copy_configs \
            "agent" \
            "${INIT_APPS_PATH}/alert-agent-1.0/conf" \
            "${CONFIG_PATH}/alert-agent-1.0" \
            "${INIT_APPS_PATH}/alert-agent-1.0"
    fi
}


################################
# UPDATE environment.conf
################################
update_environment_conf() {
    echo "📝 Updating environment.conf..."

    update_env() {
        local service="$1"
        local env_file="$2"

        local ORIGINAL="${env_file}.original"

        [ -f "$ORIGINAL" ] || {
            echo "⚠️ Missing ${ORIGINAL}, skipping ${service}"
            return
        }

        cp "$ORIGINAL" "$env_file"
        sed -i 's/\r$//' "$env_file"

        printf "\n" >> "$env_file"
        grep -q '^include "override_env"' "$env_file" || \
            echo 'include "override_env"' >> "$env_file"

        echo "✔ Updated environment.conf for ${service^^}"
    }

    ################################
    # APPLICATION (API + JOB)
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        update_env "api" \
            "$INIT_APPS_PATH/alert-api-server-1.0/conf/environment.conf"

        update_env "job" \
            "$INIT_APPS_PATH/alert-job-server-1.0/conf/environment.conf"
    fi

    ################################
    # AGENT
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        update_env "agent" \
            "$INIT_APPS_PATH/alert-agent-1.0/conf/environment.conf"
    fi
}

################################
# KEYSTORE SETUP (STANDARDIZED)
################################
setup_keystore() {
    echo "🔐 Keystore setup started"

    [ -z "$keystorePass" ] && { echo "❌ keystorePass missing"; exit 1; }
    [ -z "$keystoreFile" ] && { echo "❌ keystoreFile missing"; exit 1; }

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
                echo "❌ Unknown service: $service"
                exit 1
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

        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Inserting key: $key (branch12)"
            cd "$APPS_PATH/lib" || exit 1

            java -cp "./*" \
                -Dlog4j.configurationFile=../conf/log4j2.xml \
                -Dcrypto.configurationFile=../conf/keystore.conf \
                com.alnt.cryptoutil.Main key_upsert "$key" "$val" || exit 1
        done

        rm -f "$KEYSTORE_KEY_PATH"
    }

    insert_secrets_branch11() {
        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Inserting key: $key (branch11)"
            cd "$APPS_PATH/lib" || exit 1

            java -jar keystore-0.0.1-SNAPSHOT.jar \
                "$keystoreFile" \
                "$keystorePass" \
                "$val" "$key" || exit 1
        done
    }

    ################################
    # Create keystore
    ################################
    create_keystore_branch12() {
        keytool -genseckey -keyalg AES -keysize 256 \
            -keystore "$keystoreFile" \
            -storetype PKCS12 \
            -storepass "$keystorePass" \
            -keypass "$keystorePass"
    }

    create_keystore_branch11() {
        keytool -genkeypair \
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
        echo "❌ No keystore mechanism found"
        exit 1
    fi

    echo "✅ Keystore setup completed"
}


################################
# SCRIPT LINKS SETUP
################################
scriptlinks() {
    echo "🔗 Setting up script links..."
    mkdir -p "$SCRIPTS_PATH"

    setup_script() {
        local service="$1"
        local script_name="$2"
        local binary_name="$3"

        local SRC="/tmp/scripts/startupScripts/${script_name}"
        local DEST="${SCRIPTS_PATH}/${script_name}"
        local LINK="/usr/bin/${binary_name}"

        echo "➡️ Setting up ${service^^} scripts"

        if [ ! -f "$DEST" ]; then
            cp "$SRC" "$DEST"
            chmod +x "$DEST"
            echo "✔ Copied ${script_name}"
        fi

        if [ ! -L "$LINK" ]; then
            ln -s "$DEST" "$LINK"
            echo "✔ Linked ${binary_name} → ${LINK}"
        fi
    }

    ############################
    # APPLICATION
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        setup_script "application" "aeapps.sh" "aeapps"
    fi

    ############################
    # AGENT
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        setup_script "agent" "aeagent.sh" "aeagent"
    fi

    echo "✅ Script links setup completed"
}


################################
# APPLICATION / AGENT START
################################
applicationStart() {
    [ -z "$keystorePass" ] && echo "❌ Missing keystorePass!" && exit 1

    export KEYSTORE_PASS="$keystorePass"
    ulimit -n 65535

    start_service() {
        local service="$1"
        local http_port="$2"
        local conf_file="$3"
        local app_dir="$4"

        local LOG_FILE="${LOGS_PATH}/${service}.log"
        local JVM_PARAMS="${myJVMParams:-"-XX:+UseContainerSupport -XX:MaxRAMPercentage=35.0 -XX:+UseG1GC"}"

        echo "⬇️ Starting ${service^^}"
        cd "$app_dir" || { echo "❌ Directory not found: $app_dir"; exit 1; }

        mkdir -p "/mnt/${service}"

        nohup java -cp "./lib/*" ${JVM_PARAMS} \
            -Dhttp.port="${http_port}" \
            -Dconfig.file="${conf_file}" \
            -Dorg.owasp.esapi.resources=conf \
            -Dlogback.debug=true \
            -Dlog4j.configurationFile=conf/log4j2.xml \
            play.core.server.ProdServerStart \
            > "${LOG_FILE}" 2>&1 &

        echo "✅ ${service^^} started on port ${http_port}"
    }

    ################################
    # APPLICATION (API + JOB)
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        start_service "api" 9000 "conf/application.conf" \
            "${INIT_APPS_PATH}/alert-api-server-1.0"

        start_service "job" 9090 "conf/jobserver.conf" \
            "${INIT_APPS_PATH}/alert-job-server-1.0"
    fi

    ################################
    # AGENT
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        start_service "agent" 9095 "conf/application.conf" \
            "${INIT_APPS_PATH}/alert-agent-1.0"
    fi

    echo "🎉 All requested services started successfully"
}


flyway_run() {
    echo "🛫 Starting Flyway migrations..."
    mkdir -p "$LOGS_PATH/flyway"

    set -o pipefail

    run_flyway() {
        local service="$1"
        local locations="$2"
        local logfile="$3"
        local dbSchema="$4"

        echo "➡️ Running Flyway for ${service^^} DB"

        flyway \
            -user="$flywayUser" \
            -password="$flywayPass" \
            -url="$dbURL" \
            -schemas="$dbSchema" \
            -locations="$locations" \
            migrate \
            2>&1 | tee -a "$logfile"

        echo "✅ Flyway completed for ${service^^} DB"
    }

    # -------- Application DB --------
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        run_flyway \
            "application" \
            "filesystem:$INIT_APPS_PATH/db/migration/default/postgre,filesystem:$INIT_APPS_PATH/db/migration/default/postgreDML" \
            "$LOGS_PATH/flyway/flyway_application.log" \
            "$dbSchema_api"
    fi

    # -------- Agent DB --------
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        run_flyway \
            "agent" \
            "filesystem:$INIT_APPS_PATH/agentdb/migration/default/postgre,filesystem:$INIT_APPS_PATH/agentdb/migration/default/postgreDML" \
            "$LOGS_PATH/flyway/flyway_agent.log" \
            "$dbSchema_agent"
    fi

    echo "🎉 Flyway migrations finished successfully"
}


validate() {
    local max_retries=20
    local sleep_time=30

    check_port() {
        local service="$1"
        local port="$2"
        local retry_count=0

        while ! netstat -tuln | grep -q ":${port}\b"; do
            if (( retry_count >= max_retries )); then
                echo "❌ ${service} not up on port ${port} after $((max_retries * sleep_time))s"
                exit 1
            fi
            ((retry_count++))
            echo "Waiting for ${service} on port ${port}... (Attempt ${retry_count}/${max_retries})"
            sleep "${sleep_time}"
        done

        echo "✅ ${service} is up and running on port ${port}"
    }

    # -------- Application services --------
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        check_port "api" 9000
        check_port "job" 9090
    fi

    # -------- Agent service --------
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        check_port "agent" 9095
    fi
}



################################
# MAIN
################################
main() {
    create_dirs
    stop_services
    download_build
    backup
    extract_zip
    copy_env_configs
    update_environment_conf
    setup_keystore
    scriptlinks
    applicationStart
    flyway_run
    validate
}

main
