#!/bin/bash
set -e

################################
# INPUT
################################
ARTIFACTS="$1"

[ -z "$ARTIFACTS" ] && echo "❌ ARTIFACTS argument missing" && exit 1

IFS=',' read -ra ITEMS <<< "$ARTIFACTS"

################################
# LOAD ENV
################################
ENV_FILE="/opt/AlertEnterprise/configs/.env"

[ ! -f "$ENV_FILE" ] && echo "❌ ENV file missing: $ENV_FILE" && exit 1

source "$ENV_FILE"

[ -z "$SECRETS" ] && echo "❌ SECRETS is missing!" && exit 1

# Export secrets
echo "$SECRETS" | jq -c '.[]' | while read -r item; do
    key=$(echo "$item" | jq -r 'keys[0]')
    val=$(echo "$item" | jq -r '.[keys[0]]')
    export "$key=$val"
done

################################
# FUNCTIONS
################################
create_dirs() {
    echo "📁 Creating directories..."

    for dir in \
        "$APP_PATH" \
        "$INIT_APPS_PATH" \
        "$KEYSTORE_PATH" \
        "$CONF_PATH" \
        "$SCRIPTS_PATH" \
        "$TEMP_PATH" \
        "$CERT_DIR"
    do
        mkdir -p "$dir"
    done
}

extract_zip() {
    echo "📦 Extracting artifacts..."

    if [ "${ITEMS[0]}" = "application" ]; then
        for a in api job ui DB; do
            unzip -qq "$BUILD_PATH/$a.zip" -d "$INIT_APPS_PATH"
        done
    fi

    if [ "${ITEMS[0]}" = "agent" ]; then
        for a in agentserver agentDB; do
            unzip -qq "$BUILD_PATH/$a.zip" -d "$INIT_APPS_PATH"
        done
    fi
}

copy_env_configs() {
    echo "⚙️ Copying ENV configs..."

    if [ "${ITEMS[0]}" = "application" ]; then
        for a in api job; do
            cp "$CONFIG_PATH/$a/override_env.conf" \
               "$INIT_APPS_PATH/alert-$a-server-1.0/conf/"
            cp "$CONFIG_PATH/$a/log4j2.xml" \
               "$INIT_APPS_PATH/alert-$a-server-1.0/conf/"
        done
    fi

    if [ "${ITEMS[0]}" = "agent" ]; then
        cp "$CONFIG_PATH/agentserver/override_env.conf" \
           "$INIT_APPS_PATH/alert-agent-1.0/conf/"
        cp "$CONFIG_PATH/agentserver/log4j2.xml" \
           "$INIT_APPS_PATH/alert-agent-1.0/conf/"
    fi
}

update_environment_conf() {
    echo "📝 Updating environment.conf..."

    if [ "${ITEMS[0]}" = "application" ]; then
        for a in api job; do
            env_file="$INIT_APPS_PATH/alert-$a-server-1.0/conf/environment.conf"
            [ -f "$env_file.original" ] || continue
            cp "$env_file.original" "$env_file"
            sed -i 's/\r$//' "$env_file"
            echo 'include "override_env"' >> "$env_file"
        done
    fi

    if [ "${ITEMS[0]}" = "agent" ]; then
        env_file="$INIT_APPS_PATH/alert-agent-1.0/conf/environment.conf"
        [ -f "$env_file.original" ] || return
        cp "$env_file.original" "$env_file"
        sed -i 's/\r$//' "$env_file"
        echo 'include "override_env"' >> "$env_file"
    fi
}

setup_keystore() {
    echo "Keystore setup Start"

    # -------------------------------
    # Select application type
    # -------------------------------
    if [ "${ITEMS[0]}" = "application" ]; then
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

        if [ -z "$keystoreFile" ]; then
            keytool -genseckey -keyalg AES -keysize 256 \
                -keystore "$keystoreFile" -storetype PKCS12 \
                -storepass "$keystorePass" -keypass "$keystorePass"
            new_keystore_setup
        fi

    elif [ -f "$Branch11" ]; then
        echo "Creating new keystore for branch 11..."

        if [ -z "$keystoreFile" ]; then
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
    if [ "${ITEMS[0]}" = "application" ]; then
        echo "⬇️ starting application"

        for a in api job; do
            if [ "$a" = "api" ]; then
                httPort=9000
                confFile=conf/application.conf
            else
                httPort=9090
                confFile=conf/jobserver.conf
            fi

            cd "${INIT_APPS_PATH}/alert-${APP_TYPE_CODE}-server-1.0/"

            aeJVMParams=${myJVMParams:-"-XX:+UseContainerSupport -XX:MaxRAMPercentage=35.0 -XX:+UseG1GC"}

            mkdir -p /mnt/"$a"
            echo "starting app...."

            exec java -cp "./lib/*" $aeJVMParams \
                -Dhttp.port="$httPort" \
                -Dconfig.file="$confFile" \
                -Dorg.owasp.esapi.resources=conf \
                -Dlogback.debug=true \
                -Dlog4j.configurationFile=conf/log4j2.xml \
                play.core.server.ProdServerStart
        done
    fi

    ################################
    # AGENT
    ################################
    if [ "${ITEMS[0]}" = "agent" ]; then
        echo "⬇️ starting AGENT"

        for a in agentserver; do
            httPort=9095
            confFile=conf/application.conf

            cd "${INIT_APPS_PATH}/alert-${APP_TYPE_CODE}-server-1.0/"

            aeJVMParams=${myJVMParams:-"-XX:+UseContainerSupport -XX:MaxRAMPercentage=35.0 -XX:+UseG1GC"}

            mkdir -p /mnt/"$a"
            echo "starting app...."

            exec java -cp "./lib/*" $aeJVMParams \
                -Dhttp.port="$httPort" \
                -Dconfig.file="$confFile" \
                -Dorg.owasp.esapi.resources=conf \
                -Dlogback.debug=true \
                -Dlog4j.configurationFile=conf/log4j2.xml \
                play.core.server.ProdServerStart
        done
    fi
}

################################
# MAIN
################################
main() {
    create_dirs
    extract_zip
    copy_env_configs
    update_environment_conf
    setup_keystore
    applicationStart
}

main
