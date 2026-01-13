#!/bin/sh
set -e

# Load environment variables
source /tmp/configs/.env

# Exit if SECRETS is empty or unset
[ -z "$SECRETS" ] && echo "SECRETS is missing!" && exit 1

# Export key-value pairs
while read -r item; do
    eval "$(echo "$item" | jq -r 'to_entries[] | "export \(.key)=\(.value)"')"
done < <(echo "$SECRETS" | jq -c '.[]')




create_dirs() {
    echo "Validating and creating base directories..."

    dirs=(
        "$INIT_APPS_PATH"
        "$KEYSTORE_PATH"
        "$CONF_PATH"
        "$SCRIPTS_PATH"
        "$TEMP_PATH"
        "$APPS_PATH"
        "$CERT_DIR"
    )

    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            echo "Directory already exists: $dir"
        else
            echo "Creating directory: $dir"
            mkdir -p "$dir"
        fi
    done
}

extract_zip() {
    echo "Extracting API build..."
    [[ -f "$ZIP_PATH" ]] || { echo "API zip not found at $ZIP_PATH"; exit 1; }
    unzip -qq "$ZIP_PATH" -d "$INIT_APPS_PATH"
}

copy_env_configs() {
    echo "Copying ENV configs..."

    # Copy override_env.conf always
    cp "$CONFIG_PATH/override_env.conf" "$APPS_PATH/conf/"

    cp -f "$CONFIG_PATH/log4j2.xml" "$APPS_PATH/conf/"

    # Copy keystore.conf only if Branch12 is set
    if [ -n "$Branch12" ]; then
        cp "$CONFIG_PATH/keystore.conf" "$APPS_PATH/conf/"
    fi
}


update_environment_conf() {
    local env_file="$APPS_PATH/conf/environment.conf"

    [[ -f "${env_file}.original" ]] || return

    cp "${env_file}.original" "$env_file"
    sed -i 's/\r$//' "$env_file"

    cat <<EOF >> "$env_file"
include "override_env"
EOF
}

sedFiles() {
    echo "Running sed command on override_env.conf"
    
    
    echo "Running sed command to replace {AEKEYSTOREFILE} with keystoreFile in both config files"

    sed -i "s|{AEKEYSTOREFILE}|${keystoreFile}|g" "${APPS_PATH}/conf/keystore.conf"

    echo "Running sed command to replace {AEKEYSTOREPASSWD} with KEYSTORE_KEY_PATH  in both keystore.conf"
    sed -i "s|{AEKEYSTOREPASSWD}|${KEYSTORE_KEY_PATH}|g" "${APPS_PATH}/conf/keystore.conf"

}     

setup_keystore() {
    echo "Keystore setup Start"

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

    if [ -n "$Branch12" ]; then
        echo "Creating new keystore of branch 12..."
        keytool -genseckey -keyalg AES -keysize 256 \
            -keystore "$keystoreFile" -storetype PKCS12 \
            -storepass "$keystorePass" -keypass "$keystorePass"
        new_keystore_setup

    elif [ -n "$Branch11" ]; then
        echo "Creating new keystore for branch 11..."
        keytool -genkeypair -dname "cn=Alert Enterprise, ou=Java, o=Oracle, c=US" -alias alert \
            -keystore "$keystoreFile" \
            -storepass "$keystorePass" -keypass "$keystorePass"
        old_keystore_setup
    fi

    echo "Keystore setup completed."
}

applicationStart() { 
    [ -z "$keystorePass" ] && echo "Missing keystorePass!" && exit 1
    export KEYSTORE_PASS="$keystorePass"    
    ulimit -n 65535
    timestamp=$(date +%F_%T)
    #hostname=$(hostname)

    cd "${APPS_PATH}"

    aeJVMParams=${myJVMParams:-"-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC"}

    mkdir -p /mnt/"$appType"
    echo "starting app...."
    exec java -cp "./lib/*" $aeJVMParams \
    -Dhttp.port="$httPort" \
    -Dconfig.file="$confFile" \
    -Dorg.owasp.esapi.resources=conf \
    -Dlogback.debug=true \
    -Dlog4j.configurationFile=conf/log4j2.xml \
    play.core.server.ProdServerStart 
}

main() {
    create_dirs
    extract_zip
    copy_env_configs
    update_environment_conf
    sedFiles
    setup_keystore
    applicationStart
}

main
