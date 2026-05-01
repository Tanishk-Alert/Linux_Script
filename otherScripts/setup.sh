#!/bin/bash

set -euo pipefail

basePath="/opt/AlertEnterprise"
ENV_FILE="${basePath}/configs/.env_variable"
randomKeysHighLevel=true
unattended=true

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

keystorePass="${keystorePass:-}"
passphrase="${passphrase:-}"

prompt_input() {
    read -r -p "$1 [Default is $2]: " input_var
    echo "${input_var:-$2}"
}

prompt_nd_input() {
    read -r -p "$1: " input_var
    echo "$input_var"
}

generate_passphrase() {
    if [[ "${randomKeysHighLevel}" == true ]]; then
        LC_ALL=C tr -dc 'A-Za-z0-9@#$%^&*()_+=-' < /dev/urandom | head -c 64
    else
        openssl rand -base64 48
    fi
}   

keystore_pass() {
    if [[ "${randomKeysHighLevel}" == true ]]; then
        LC_ALL=C tr -dc 'A-Za-z0-9@#$%^&*()_+=-' < /dev/urandom | head -c 16
    else
        openssl rand -base64 16
    fi
}



# Backup existing .env_variable
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}.env_variable file already exists.${NC}"
    read -r -p "Do you want recreate and backup current .env_variable? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        cp -p "$ENV_FILE" "${ENV_FILE}_$(date +%Y%m%d_%H%M%S)"
        rm -f "$ENV_FILE"
    else
        echo "Keeping existing file."
        exit 0
    fi
fi

echo "Creating .env_variable file..."


    if [ "$unattended" = "true" ]; then
        keystorePass="$(keystore_pass)"
        aes_encryption_passphrase="$(generate_passphrase)"
        PLAY_HTTP_SECRET_KEY="$(generate_passphrase)"
        PLAY_HTTP_GUARDIAN_SECRET_KEY="$(generate_passphrase)"
        PLAY_HTTP_GUARDIAN_REFRESH_SECRET_KEY="$(generate_passphrase)"
        PLAY_HTTP_TFA_KEY="$(generate_passphrase)"
        PLAY_HTTP_CSQ_KEY="$(generate_passphrase)"
        PLAY_HTTP_RNK_KEY="$(generate_passphrase)"
        HOTP_SECRET_KEY="$(generate_passphrase)"

    else
        # ======================================================
        #             Interactive secret generation
        # ======================================================
        while true; do
            keystorePass="$(prompt_input "Enter Keystore Password" "$(keystore_pass)")"
            aes_encryption_passphrase="$(prompt_input "AES encryption passphrase" "$(generate_passphrase)")"
            PLAY_HTTP_SECRET_KEY="$(prompt_input "PLAY_HTTP_SECRET_KEY" "$(generate_passphrase)")"
            PLAY_HTTP_GUARDIAN_SECRET_KEY="$(prompt_input "PLAY_HTTP_GUARDIAN_SECRET_KEY" "$(generate_passphrase)")"
            PLAY_HTTP_GUARDIAN_REFRESH_SECRET_KEY="$(prompt_input "PLAY_HTTP_GUARDIAN_REFRESH_SECRET_KEY" "$(generate_passphrase)")"
            PLAY_HTTP_TFA_KEY="$(prompt_input "PLAY_HTTP_TFA_KEY" "$(generate_passphrase)")"
            PLAY_HTTP_CSQ_KEY="$(prompt_input "PLAY_HTTP_CSQ_KEY" "$(generate_passphrase)")"
            PLAY_HTTP_RNK_KEY="$(prompt_input "PLAY_HTTP_RNK_KEY" "$(generate_passphrase)")"
            HOTP_SECRET_KEY="$(prompt_input "HOTP_SECRET_KEY" "$(generate_passphrase)")"

            log info "Generated Secrets Summary:"
            printf "%s\n" \
                "keystorePass=$keystorePass" \
                "aes.encryption.passphrase=$aes_encryption_passphrase" \
                "PLAY_HTTP_SECRET_KEY=$PLAY_HTTP_SECRET_KEY" \
                "PLAY_HTTP_GUARDIAN_SECRET_KEY=$PLAY_HTTP_GUARDIAN_SECRET_KEY" \
                "PLAY_HTTP_GUARDIAN_REFRESH_SECRET_KEY=$PLAY_HTTP_GUARDIAN_REFRESH_SECRET_KEY" \
                "PLAY_HTTP_TFA_KEY=$PLAY_HTTP_TFA_KEY" \
                "PLAY_HTTP_CSQ_KEY=$PLAY_HTTP_CSQ_KEY" \
                "PLAY_HTTP_RNK_KEY=$PLAY_HTTP_RNK_KEY" \
                "HOTP_SECRET_KEY=$HOTP_SECRET_KEY"

            printf "Proceed? (y/n): "
            IFS= read -r yn

            case "$yn" in
                y|Y|yes|YES) break ;;
                *) log warn "Re-entering secrets..." ;;
            esac
        done
    fi
    # ======================================================
    #            Build keystore_entries (multi-line)
    # ======================================================
   keystore_entries=$(cat <<EOF
KEYSTORE_SECRETS='[
  {"PLAY_HTTP_SECRET_KEY":"$aes_encryption_passphrase"},
  {"PLAY_HTTP_GUARDIAN_SECRET_KEY":"$aes_encryption_passphrase"},
  {"PLAY_HTTP_GUARDIAN_REFRESH_SECRET_KEY":"$aes_encryption_passphrase"},
  {"PLAY_HTTP_TFA_KEY":"$aes_encryption_passphrase"},
  {"PLAY_HTTP_CSQ_KEY":"$aes_encryption_passphrase"},
  {"PLAY_HTTP_RNK_KEY":"$aes_encryption_passphrase"},
  {"HOTP_SECRET_KEY":"$aes_encryption_passphrase"},
  {"PLAY_HTTP_NFC_KEY":"$aes_encryption_passphrase"},
  {"aes.encryption.passphrase":"$aes_encryption_passphrase"}
]'
EOF
)


# # Password prompts
# if [ -z "${keystorePass:-}" ]; then
#     read -r -p "Please enter keystore password: " keystorePass
# fi

# if [ -z "${passphrase:-}" ]; then
#     read -r -p "Please enter passphrase: " passphrase
# fi

KEYSTORE_PASS="$keystorePass"

declare -A db_opts=(
 [1]="org.postgresql.Driver 5432 postgre postgreDML jdbc:postgresql://{host}:{port}/{dbname} com.alnt.platform.base.persistence.dialect.PostgreSQL10DialectAE TRANSACTION_READ_UNCOMMITTED"
 [2]="oracle.jdbc.OracleDriver 1521 oracle oracleDML jdbc:oracle:thin:@{host}:{port}:{dbname} com.alnt.platform.base.persistence.dialect.Oracle12cDialectAE TRANSACTION_READ_COMMITTED"
 [3]="com.microsoft.sqlserver.jdbc.SQLServerDriver 1433 sqlserver sqlserverDML jdbc:sqlserver://{host}:{port};databaseName={dbname} com.alnt.platform.base.persistence.dialect.SQLServer2012DialectAE TRANSACTION_READ_UNCOMMITTED"
)

while true; do

echo "1. PostgreSQL"
echo "2. Oracle"
echo "3. MS-SQL"
read -r -p "Choice: " db_choice

[[ "$db_choice" =~ ^[1-3]$ ]] || continue

config_line="${db_opts[$db_choice]}"

IFS=" " read -r \
DB_DRIVER DB_PORT_DEFAULT SQL_DDL_FILE SQL_DML_FILE \
DB_URL_TEMPLATE HIBERNATE_DIALECT DB_TRANSACTION <<< "$config_line"

DB_HOST=$(prompt_input "DB Host" "localhost")
DB_PORT=$(prompt_input "DB Port" "$DB_PORT_DEFAULT")
DB_NAME=$(prompt_input "DB Name" "aehscdb")
DB_SCHEMA=$(prompt_input "DB Schema" "aehsc")
DB_USER=$(prompt_input "DB Username" "alert")

read -r -p "Encrypted DB password available? (y/n): " x
if [[ "$x" =~ ^[Yy]$ ]]; then
    DB_PASSWORD=$(prompt_nd_input "Enter Plaintext DB Password" "")
    DB_Encrypted=""

    if [ -z "$DB_PASSWORD" ]; then
        log warn "Blank DB password received"
    else
        log info "Encrypting DB password..."
        DB_Encrypted=$(aeEncrypter "$DB_PASSWORD" | awk -F': ' '/aeEncrypted Value:/ {print $2}')
        log debug "Encrypted Value ${DB_Encrypted}"
        log ok "DB password encrypted"
else
    DB_PASSWORD=$(prompt_nd_input "Enter DB password")
    DB_Encrypted="$DB_PASSWORD"
fi

# Agent DB optional
read -r -p "Configure Agent DB user? (y/n): " agent_ans
if [[ "$agent_ans" =~ ^[Yy]$ ]]; then
    DB_AGENT_USERNAME=$(prompt_nd_input "Agent DB Username")
    DB_AGENT_ENCODED=$(prompt_nd_input "Agent DB Encrypted Password")
else
    DB_AGENT_USERNAME=""
    DB_AGENT_ENCODED=""
fi

REDIS_HOST=$(prompt_input "Redis Host" "localhost")
REDIS_PORT=$(prompt_input "Redis Port" "6379")
REDIS_USERNAME=$(prompt_input "Redis Username" "default")
REDIS_ENCODED=$(prompt_nd_input "Redis Password/Encrypted")

STAGING_REDIS_HOST="$REDIS_HOST"
STAGING_REDIS_USERNAME="$REDIS_USERNAME"
STAGING_REDIS_ENCODED="$REDIS_ENCODED"

MQ_HOST=$(prompt_input "MQ Host" "localhost")
MQ_USERNAME=$(prompt_input "MQ Username" "admin")
MQ_ENCODED=$(prompt_nd_input "MQ Password/Encrypted")

DOMAIN_NAME=$(prompt_input "Domain Name" "alertenterprise.com")

DB_URL=${DB_URL_TEMPLATE//\{host\}/$DB_HOST}
DB_URL=${DB_URL//\{port\}/$DB_PORT}
DB_URL=${DB_URL//\{dbname\}/$DB_NAME}

MQ_URL="tcp://${MQ_HOST}:61616?wireFormat.maxInactivityDuration=0"

# Derived values
DB_SCHEMA_APP="$DB_SCHEMA"
DB_SCHEMA_AGENT="$DB_SCHEMA"

DB_API_USERNAME="$DB_USER"
DB_API_ENCODED="$DB_Encrypted"

DB_JOB_USERNAME="$DB_USER"
DB_JOB_ENCODED="$DB_Encrypted"

FLYWAY_USER="$DB_USER"
FLYWAY_PASS="$DB_PASSWORD"

JOB_SERVER_URL=""

cat <<EOF > "$ENV_FILE"
# -------------------------
# Path Configuration
# -------------------------

APP_PATH=/opt/AlertEnterprise
CERT_DIR=\${APP_PATH}/certs
KEYSTORE_PATH=\${APP_PATH}/keystore
INIT_APPS_PATH=\${APP_PATH}/apps
SCRIPTS_PATH=\${APP_PATH}/scripts
TEMP_PATH=\${APP_PATH}/temp
KEYSTORE_KEY_PATH=\${APP_PATH}/temp/.key
KEYSTORE_FILE=\${KEYSTORE_PATH}/alertkeys
BUILD_PATH=\${APP_PATH}/builds
CONFIG_PATH=\${APP_PATH}/configs
LOGS_PATH=\${APP_PATH}/logs
DB_PATH=\${INIT_APPS_PATH}/DB/db/migration/default/${SQL_DDL_FILE}

JAVA_HOME=\$(readlink -f \$(which java) | sed 's:/bin/java::')
CACERTS_PATH=\${JAVA_HOME}/lib/security/cacerts

SECRETS='[
  {"dName":"$DOMAIN_NAME"},
  {"dbSchemaApp":"$DB_SCHEMA_APP"},
  {"dbDriver":"$DB_DRIVER"},
  {"dbTransaction":"$DB_TRANSACTION"},
  {"hibernateDialect":"$HIBERNATE_DIALECT"},
  {"dbSchemaAgent":"$DB_SCHEMA_AGENT"},
  {"dbURL":"$DB_URL"},
  {"dbApiUserName":"$DB_API_USERNAME"},
  {"dbApiEncoded":"$DB_API_ENCODED"},
  {"dbJobUserName":"$DB_JOB_USERNAME"},
  {"dbJobEncoded":"$DB_JOB_ENCODED"},
  {"dbAgentUserName":"$DB_AGENT_USERNAME"},
  {"dbAgentEncoded":"$DB_AGENT_ENCODED"},
  {"mqUrl":"$MQ_URL"},
  {"mqUserName":"$MQ_USERNAME"},
  {"mqEncoded":"$MQ_ENCODED"},
  {"redisHost":"$REDIS_HOST"},
  {"redisUsername":"$REDIS_USERNAME"},
  {"redisEncoded":"$REDIS_ENCODED"},
  {"stagingRedisHost":"$STAGING_REDIS_HOST"},
  {"stagingRedisUsername":"$STAGING_REDIS_USERNAME"},
  {"stagingRedisEncoded":"$STAGING_REDIS_ENCODED"},
  {"jobServerUrl":"$JOB_SERVER_URL"},
  {"keystorePass":"$KEYSTORE_PASS"},
  {"keystoreFile":"/opt/AlertEnterprise/keystore/alertkeys"},
  {"flywayUser":"$FLYWAY_USER"},
  {"flywayPass":"$FLYWAY_PASS"}
]'

EOF

{
    echo ""
    echo "$keystore_entries"
} >> "$ENV_FILE"

echo ".env_variable created successfully at $ENV_FILE"
break

done