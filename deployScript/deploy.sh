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

download_build() {
    echo "📥 Downloading build artifacts..."

    mkdir -p builds

    ############################
    # APPLICATION
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Downloading APPLICATION artifacts"

        for a in api job ui DB; do
            SRC="${S3_SRC_PATH}/${gitBranch}/${buildVersion}/${a}.zip"

            echo "   ⬇️ $a.zip"
            if aws s3 cp "$SRC" builds/; then
                echo "   ✔ Downloaded $a.zip"
            else
                echo "   ⚠️ $a.zip not found, skipping"
            fi
        done
    fi

    ############################
    # AGENT
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Downloading AGENT artifacts"

        for a in agentserver agentDB; do
            SRC="${S3_SRC_PATH}/${gitBranch}/${buildVersion}/${a}.zip"

            echo "   ⬇️ $a.zip"
            if aws s3 cp "$SRC" builds/; then
                echo "   ✔ Downloaded $a.zip"
            else
                echo "   ⚠️ $a.zip not found, skipping"
            fi
        done
    fi

    echo "✅ Build download completed"
}



extract_zip() {
    echo "📦 Extracting artifacts..."

    # -------------------------
    # APPLICATION artifacts
    # -------------------------
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Extracting APPLICATION artifacts"

        for a in api job ui DB; do
            zip_file="$BUILD_PATH/$a.zip"

            if [ -f "$zip_file" ]; then
                echo "   ✔ Extracting $a.zip"
                unzip -qq "$zip_file" -d "$INIT_APPS_PATH"
            else
                echo "   ⚠️ $a.zip not found, skipping"
            fi
        done
    fi

    # -------------------------
    # AGENT artifacts
    # -------------------------
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Extracting AGENT artifacts"

        for a in agentserver agentDB; do
            zip_file="$BUILD_PATH/$a.zip"

            if [ -f "$zip_file" ]; then
                echo "   ✔ Extracting $a.zip"
                unzip -qq "$zip_file" -d "$INIT_APPS_PATH"
            else
                echo "   ⚠️ $a.zip not found, skipping"
            fi
        done
    fi
}


copy_env_configs() {
    echo "⚙️ Copying ENV configs..."

    ############################
    # APPLICATION
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        for a in api job; do
            echo "➡️ Copying configs for application: $a"

            APP_CONF_DIR="$INIT_APPS_PATH/alert-$a-server-1.0/conf"
            APPS_PATH="$INIT_APPS_PATH/alert-api-server-1.0"

            cp "$CONFIG_PATH/$a/override_env.conf" "$APP_CONF_DIR/"
            cp "$CONFIG_PATH/$a/log4j2.xml" "$APP_CONF_DIR/"

            Branch12="$APPS_PATH/conf/keystore.conf"
            Branch11="$APPS_PATH/lib/keystore-0.0.1-SNAPSHOT.jar"

            # ---- Branch 12 keystore handling ----
            if [ -f "$Branch12" ]; then
                echo "🔐 Updating keystore.conf for $a (Branch12)"

                cp "$CONFIG_PATH/$a/keystore.conf" "$APP_CONF_DIR/"

                sed -i "s|{AEKEYSTOREFILE}|$keystoreFile|g" \
                    "$APP_CONF_DIR/keystore.conf"

                sed -i "s|{AEKEYSTOREPASSWD}|$KEYSTORE_KEY_PATH|g" \
                    "$APP_CONF_DIR/keystore.conf"
            fi
        done
    fi

    ############################
    # AGENT
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Copying configs for agent"

        APP_CONF_DIR="$INIT_APPS_PATH/alert-agent-1.0/conf"
        APPS_PATH="$INIT_APPS_PATH/alert-agent-1.0"

        cp "$CONFIG_PATH/alert-agent-1.0/override_env.conf" "$APP_CONF_DIR/"
        cp "$CONFIG_PATH/alert-agent-1.0/log4j2.xml" "$APP_CONF_DIR/"

        Branch12="$APPS_PATH/conf/keystore.conf"
        Branch11="$APPS_PATH/lib/keystore-0.0.1-SNAPSHOT.jar"

        # ---- Branch 12 keystore handling ----
        if [ -f "$Branch12" ]; then
            echo "🔐 Updating keystore.conf for agent"

            cp "$CONFIG_PATH/alert-agent-1.0/keystore.conf" "$APP_CONF_DIR/"

            sed -i "s|{AEKEYSTOREFILE}|$keystoreFile|g" \
                "$APP_CONF_DIR/keystore.conf"

            sed -i "s|{AEKEYSTOREPASSWD}|$KEYSTORE_KEY_PATH|g" \
                "$APP_CONF_DIR/keystore.conf"
        fi
    fi
}


update_environment_conf() {
    echo "📝 Updating environment.conf..."

    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        for a in api job; do
            env_file="$INIT_APPS_PATH/alert-$a-server-1.0/conf/environment.conf"
            [ -f "$env_file.original" ] || continue
            cp "$env_file.original" "$env_file"
            sed -i 's/\r$//' "$env_file"
            printf "\n" >> "$env_file"
            echo 'include "override_env"' >> "$env_file"
        done
    fi

    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        env_file="$INIT_APPS_PATH/alert-agent-1.0/conf/environment.conf"
        [ -f "$env_file.original" ] || return
        cp "$env_file.original" "$env_file"
        sed -i 's/\r$//' "$env_file"
        printf "\n" >> "$env_file"
        echo 'include "override_env"' >> "$env_file"
    fi
}

setup_keystore() {
    echo "Keystore setup Start"

    # -------------------------------
    # Select application type
    # -------------------------------
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        APPS_PATH="${INIT_APPS_PATH}/alert-api-server-1.0"
        Branch12="${APPS_PATH}/conf/keystore.conf"
        Branch11="${APPS_PATH}/lib/keystore-0.0.1-SNAPSHOT.jar"
    else
        APPS_PATH="${INIT_APPS_PATH}/alert-agent-1.0"
        Branch12="${APPS_PATH}/conf/keystore.conf"
        Branch11="${APPS_PATH}/lib/keystore-0.0.1-SNAPSHOT.jar"
    fi


    # -------------------------------
    # New keystore setup (Branch 12)
    # -------------------------------
    new_keystore_setup() {
        printf "%s" "$keystorePass" > "$KEYSTORE_KEY_PATH"

        echo "$KEYSTORE_SECRETS" | jq -c '.[]' | while read -r item; do
            key=$(echo "$item" | jq -r 'keys[0]')
            val=$(echo "$item" | jq -r '.[keys[0]]')
            echo "Running for $key"

            cd "$APPS_PATH/lib" || exit 1
            java -cp "./*" \
                -Dlog4j.configurationFile=../conf/log4j2.xml \
                -Dcrypto.configurationFile=../conf/keystore.conf \
                com.alnt.cryptoutil.Main key_upsert "$key" "$val" || exit 1
        done

        rm -f "$KEYSTORE_KEY_PATH"
    }

    # -------------------------------
    # Old keystore setup (Branch 11)
    # -------------------------------
    old_keystore_setup() {
        jq -c '.KEYSTORE_SECRETS[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(echo "$item" | jq -r 'keys[0]')
            val=$(echo "$item" | jq -r '.[keys[0]]')
            echo "Running for $key"

            cd "$APPS_PATH/lib" || exit 1
            java -jar keystore-0.0.1-SNAPSHOT.jar \
                "$keystoreFile" \
                "$keystorePass" \
                "$val" "$key" || exit 1
        done
        echo "Keystore setup for branch 11 completed."
    }

    # -------------------------------
    # Decide which keystore logic to run
    # -------------------------------
    if [ -f "$Branch12" ]; then
        echo "Creating new keystore of branch 12..."

        if [ ! -f "$keystoreFile" ]; then
            keytool -genseckey -keyalg AES -keysize 256 \
                -keystore "$keystoreFile" -storetype PKCS12 \
                -storepass "$keystorePass" -keypass "$keystorePass"
            new_keystore_setup
        fi

    elif [ -f "$Branch11" ]; then
        echo "Creating new keystore for branch 11..."

        if [ ! -f "$keystoreFile" ]; then
            keytool -genkeypair \
                -dname "cn=Alert Enterprise, ou=Java, o=Oracle, c=US" \
                -alias alert \
                -keystore "$keystoreFile" \
                -storepass "$keystorePass" -keypass "$keystorePass"
            old_keystore_setup
        fi
    fi

    echo "Keystore setup completed."
}

scriptlinks() {
    echo "🔗 Setting up script links..."

    mkdir -p "$SCRIPTS_PATH"

    ############################
    # APPLICATION
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Setting up application scripts"

        if [ ! -f "$SCRIPTS_PATH/aeapps.sh" ]; then
            cp "/tmp/scripts/startupScripts/aeapps.sh" "$SCRIPTS_PATH/"
            chmod +x "$SCRIPTS_PATH/aeapps.sh"
            echo "✔ Copied aeapps.sh"
        fi

        if [ ! -L "/usr/bin/aeapps" ]; then
            ln -s "$SCRIPTS_PATH/aeapps.sh" /usr/bin/aeapps
            echo "✔ Linked aeapps → /usr/bin/aeapps"
        fi
    fi

    ############################
    # AGENT
    ############################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Setting up agent scripts"

        if [ ! -f "$SCRIPTS_PATH/aeagent.sh" ]; then
            cp "/tmp/scripts/startupScripts/aeagent.sh" "$SCRIPTS_PATH/"
            chmod +x "$SCRIPTS_PATH/aeagent.sh"
            echo "✔ Copied aeagent.sh"
        fi

        if [ ! -L "/usr/bin/aeagent" ]; then
            ln -s "$SCRIPTS_PATH/aeagent.sh" /usr/bin/aeagent
            echo "✔ Linked aeagent → /usr/bin/aeagent"
        fi
    fi

    echo "✅ Script links setup completed"
}


################################
# APPLICATION START (AS REQUESTED)
################################
applicationStart() { 
    [ -z "$keystorePass" ] && echo "Missing keystorePass!" && exit 1

    export KEYSTORE_PASS="$keystorePass"    
    ulimit -n 65535
    timestamp=$(date +%F_%T)

    ################################
    # APPLICATION
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "⬇️ starting application"

        for a in api job; do
            if [ "$a" = "api" ]; then
                httPort=9000
                confFile=conf/application.conf
            else
                httPort=9090
                confFile=conf/jobserver.conf
            fi

            APP_DIR="${INIT_APPS_PATH}/alert-${a}-server-1.0"
            LOG_FILE="${LOGS_PATH}/${a}.log"

            cd "$APP_DIR" || exit 1

            aeJVMParams=${myJVMParams:-"-XX:+UseContainerSupport -XX:MaxRAMPercentage=35.0 -XX:+UseG1GC"}

            mkdir -p /mnt/"$a"
            echo "starting app...."

            nohup java -cp "./lib/*" $aeJVMParams \
                -Dhttp.port="$httPort" \
                -Dconfig.file="$confFile" \
                -Dorg.owasp.esapi.resources=conf \
                -Dlogback.debug=true \
                -Dlog4j.configurationFile=conf/log4j2.xml \
                play.core.server.ProdServerStart \
                > "$LOG_FILE" 2>&1 &
        done
    fi

    ################################
    # AGENT
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "⬇️ starting AGENT"

        for a in agent; do
            httPort=9095
            confFile=conf/application.conf

            APP_DIR="${INIT_APPS_PATH}/alert-${a}-1.0"
            LOG_FILE="${LOGS_PATH}/${a}.log"

            cd "$APP_DIR" || exit 1

            aeJVMParams=${myJVMParams:-"-XX:+UseContainerSupport -XX:MaxRAMPercentage=35.0 -XX:+UseG1GC"}

            mkdir -p /mnt/"$a"
            echo "starting app...."

            nohup java -cp "./lib/*" $aeJVMParams \
                -Dhttp.port="$httPort" \
                -Dconfig.file="$confFile" \
                -Dorg.owasp.esapi.resources=conf \
                -Dlogback.debug=true \
                -Dlog4j.configurationFile=conf/log4j2.xml \
                play.core.server.ProdServerStart \
                > "$LOG_FILE" 2>&1 &
        done
    fi
    
    echo "🎉 api and job started successfully"
}

flyway_run() {
    echo "🛫 Running Flyway migrations..."

    mkdir -p "$LOGS_PATH/flyway"

    ################################
    # APPLICATION DB
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Running Flyway for APPLICATION DB"

        flyway \
            -user="$flywayUser" \
            -password="$flywayPass" \
            -url="$dbURL" \
            -schemas="$dbSchema" \
            -locations="filesystem:$INIT_APPS_PATH/db/migration/default/postgre,filesystem:$INIT_APPS_PATH/db/migration/default/postgreDML" \
            migrate \
            2>&1 | tee -a "$LOGS_PATH/flyway/flyway_application.log"
    fi

    ################################
    # AGENT DB
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Running Flyway for AGENT DB"

        flyway \
            -user="$flywayUser" \
            -password="$flywayPass" \
            -url="$dbURL" \
            -schemas="$dbSchema" \
            -locations="filesystem:$INIT_APPS_PATH/agentdb/migration/default/postgre,filesystem:$INIT_APPS_PATH/agentdb/migration/default/postgreDML" \
            migrate \
            2>&1 | tee -a "$LOGS_PATH/flyway/flyway_agent.log"
    fi

    echo "✅ Flyway migration completed"
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
}

main
