#!/bin/bash

PLAIN_TXT="${1:-}"

fail() {
    echo "[Error] $1"
    exit 1
}

[ -z "$PLAIN_TXT" ] && fail "Usage: $0 <plain_text>"

bPath="/opt/AlertEnterprise"
appPath="${bPath}/apps/alert-api-server-1.0"
keystoreJarFile="${appPath}/lib/keystore-0.0.1-SNAPSHOT.jar"
ENV_FILE="/opt/AlertEnterprise/configs/.env"

[ ! -f "$ENV_FILE" ] && fail "ENV file missing: $ENV_FILE"

source "$ENV_FILE"

[ -z "${SECRETS:-}" ] && fail "SECRETS missing"

# Load SECRETS JSON values as env vars
while read -r item; do
    key=$(jq -r 'keys[0]' <<< "$item")
    val=$(jq -r '.[keys[0]]' <<< "$item")
    export "$key=$val"
done < <(jq -c '.[]' <<< "$SECRETS")

[ -z "${keystorePass:-}" ] && fail "keystorePass missing"

passphrase=$(jq -r '.[] | ."aes.encryption.passphrase" // empty' <<< "$KEYSTORE_SECRETS")

if [ -e "$keystoreJarFile" ]; then
    echo "[Info] Found Build 11 style..."

    [ -z "$passphrase" ] && fail "passphrase missing"

    output=$(java -jar -Dpassphrase="$passphrase" \
        "${appPath}/lib/crpyto-1.0.jar" "$PLAIN_TXT")

    encrypted_value=$(echo "$output" | grep "Encrypted String" | awk -F':' '{print $2}' | xargs)

    echo "aeEncrypted Value: $encrypted_value"

else
    echo "[Info] Found Build 12 style..."
    echo "Creating temp password file"

    mkdir -p "${bPath}/temp"
    printf "%s" "${keystorePass}" > "${bPath}/temp/.key"

    encrypted_value=$(java -cp "${appPath}/lib/*" \
        -Dlog4j.configurationFile="${appPath}/conf/log4j2.xml" \
        -Dcrypto.configurationFile="${appPath}/conf/keystore.conf" \
        com.alnt.cryptoutil.Main encrypt "$PLAIN_TXT")

    echo "Removing temp password file"
    rm -f "${bPath}/temp/.key"

    echo "aeEncrypted Value: $encrypted_value"
fi