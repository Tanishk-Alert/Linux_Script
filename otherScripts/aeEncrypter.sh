#!/bin/bash

PLAIN_TXT=$1
bPath="{basePath}"
appPath=${bPath}/apps/{applicationDirectoryName}
keystoreJarFile="${appPath}/lib/keystore-0.0.1-SNAPSHOT.jar"
ENV_FILE="/opt/AlertEnterprise/configs/.env"

[ ! -f "$ENV_FILE" ] && fail "ENV file missing: $ENV_FILE"

source "$ENV_FILE" 


[ -z "$keystorePass" ] && { echo "[Error] keystorePass missing!"; exit 1; }

if [ -e "$keystoreJarFile" ]; then
    echo "[Info] found Build 11 style..."
    
    [ -z "$passphrase" ] && { echo "[Error] passphrase missing!"; exit 1; }

    java -jar -Dpassphrase="$passphrase" "${appPath}/lib/crpyto-1.0.jar" "$PLAIN_TXT"
    output=$(java -jar -Dpassphrase="$passphrase" "${appPath}/lib/crpyto-1.0.jar" "$PLAIN_TXT")
    encrypted_value=$(echo "$output" | grep "Encrypted String" | awk -F':' '{print $2}' | tr -d ' ')
    echo "aeEncrypted Value: $encrypted_value"
else
    echo "[Info] found Build 12 style..."
    echo "Creating temp password file"
    printf "%s" "${keystorePass}" > ${bPath}/temp/.key
    encrypted_value=$(java -cp "${appPath}/lib/*" -Dlog4j.configurationFile=${appPath}/conf/log4j2.xml -Dcrypto.configurationFile=${bPath}/conf/keystore.conf com.alnt.cryptoutil.Main encrypt "${PLAIN_TXT}")
    echo "Removing temp password file"
    rm -f ${bPath}/temp/.key
    echo "aeEncrypted Value: $encrypted_value"
fi


