#!/usr/bin/env bash

# ====================================================================
# Script: setup_mysql_and_generate_schema.sh
# Description: Sets up a MySQL Docker container and automatically generates the database schema based on provided entities.
# Author: Simon Beckmann
# Date: 2024-10-30
# ====================================================================

# Exit immediately if a command exits with a non-zero status and treat unset variables as an error.
set -euo pipefail

# ----------------------------
# Configuration Parameters
# ----------------------------

IMAGE="mysql:9.1.0"  # Pin to a specific stable version
CONTAINER_NAME="mysql_db"
DATA_DIR="$HOME/docker/mysql/data"
ENV_FILE="$HOME/docker/mysql/.env"
NETWORK_NAME="mysql_network"
DEFAULT_PORT=3306
COMPOSE_FILE="docker-compose.yml"
APP_PROPERTIES_FILE="application.properties"
SQL_SCRIPT="init_db.sql"

# Colors for UI/UX
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

# ----------------------------
# Entity Definitions
# ----------------------------

# Array of entity names
ENTITY_NAMES=(
    "User"
    "Role"
    "AffectedProduct"
    "AttackVectorCategory"
    "AttackVector"
    "Country"
    "Geolocation"
    "GlobalThreat"
    "ThreatActorType"
    "ThreatActor"
    "ThreatCategory"
    "Vulnerability"
)

# Array of corresponding properties
ENTITY_PROPERTIES=(
    "id:BIGINT:PRIMARY_KEY username:VARCHAR(255) password:VARCHAR(255) email:VARCHAR(255)"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) description:TEXT"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) vendor:VARCHAR(255)"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) description:TEXT"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) severity_level:INT category_id:BIGINT:FOREIGN_KEY:AttackVectorCategory(id)"
    "id:BIGINT:PRIMARY_KEY code:VARCHAR(10) name:VARCHAR(255)"
    "id:BIGINT:PRIMARY_KEY ip_address:VARCHAR(45) region:VARCHAR(255) city:VARCHAR(255) latitude:DOUBLE longitude:DOUBLE country_id:BIGINT:FOREIGN_KEY:Country(id)"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) description:TEXT first_detected:DATE severity_level:INT data_retention_until:DATE"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) description:TEXT"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) origin_country:VARCHAR(255) first_observed:DATE type_id:BIGINT:FOREIGN_KEY:ThreatActorType(id)"
    "id:BIGINT:PRIMARY_KEY name:VARCHAR(255) description:TEXT"
    "id:BIGINT:PRIMARY_KEY cve_id:VARCHAR(20) description:TEXT published_date:DATE severity_score:DOUBLE"
)

# Relationship definitions (many-to-many)
RELATIONSHIPS=(
    "User:Role:user_roles:user_id:role_id"
)

# ----------------------------
# Function Definitions
# ----------------------------

# Function to check if Docker is installed
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker is not installed. Please install Docker from https://www.docker.com/get-started${RESET}"
        exit 1
    fi
}

# Function to check if Docker Compose is available
check_docker_compose() {
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo -e "${RED}Docker Compose is not available. Please install it from https://docs.docker.com/compose/install/${RESET}"
        exit 1
    fi
}

# Function to find an available port starting from DEFAULT_PORT
find_available_port() {
    PORT=$DEFAULT_PORT
    while :; do
        if ! nc -z localhost "$PORT" &> /dev/null; then
            echo -e "${GREEN}Found available port: $PORT${RESET}"
            break
        fi
        ((PORT++))
        if [ "$PORT" -gt 65535 ]; then
            echo -e "${RED}No available ports found.${RESET}"
            exit 1
        fi
    done
}

# Function to generate a secure password and read existing ENV_FILE
generate_password() {
    if [ -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}Existing .env file found. Using existing credentials.${RESET}"
        source "$ENV_FILE"
        DB_NAME=${MYSQL_DATABASE}
        ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
        PORT=${MYSQL_PORT}
    else
        ROOT_PASSWORD=$(openssl rand -base64 16)
        DB_NAME="myappdb"
        echo "MYSQL_ROOT_PASSWORD=${ROOT_PASSWORD}" > "$ENV_FILE"
        echo "MYSQL_DATABASE=${DB_NAME}" >> "$ENV_FILE"
        echo "MYSQL_PORT=${PORT}" >> "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi
}

# Function to create necessary directories with proper permissions
create_directories() {
    echo -e "${CYAN}Creating data directory at $DATA_DIR...${RESET}"
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
}

# Function to create a Docker network if not exists
create_network() {
    if ! docker network inspect "$NETWORK_NAME" &> /dev/null; then
        echo -e "${CYAN}Creating Docker network ($NETWORK_NAME)...${RESET}"
        docker network create "$NETWORK_NAME"
    else
        echo -e "${GREEN}Docker network ($NETWORK_NAME) already exists.${RESET}"
    fi
}

# Function to check and remove existing container
check_existing_container() {
    if docker container inspect "$CONTAINER_NAME" &> /dev/null; then
        if docker ps -q -f name="^${CONTAINER_NAME}$" &> /dev/null; then
            echo -e "${YELLOW}Stopping existing container ($CONTAINER_NAME)...${RESET}"
            docker stop "$CONTAINER_NAME"
        fi
        echo -e "${YELLOW}Removing existing container ($CONTAINER_NAME)...${RESET}"
        docker rm "$CONTAINER_NAME"
    fi
}

# Function to create Docker Compose file
create_docker_compose() {
    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'

services:
  mysql:
    image: $IMAGE
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    ports:
      - "${PORT}:3306"
    environment:
      - MYSQL_ROOT_PASSWORD=${ROOT_PASSWORD}
      - MYSQL_DATABASE=${DB_NAME}
    volumes:
      - "$DATA_DIR:/var/lib/mysql"
      - "./$SQL_SCRIPT:/docker-entrypoint-initdb.d/$SQL_SCRIPT"
    networks:
      - $NETWORK_NAME
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p${ROOT_PASSWORD}"]
      interval: 30s
      timeout: 10s
      retries: 5

networks:
  $NETWORK_NAME:
    external: true
EOF
    echo -e "${GREEN}Docker Compose file ($COMPOSE_FILE) created successfully.${RESET}"
}

# Function to generate SQL script to create tables
generate_sql_script() {
    echo -e "${CYAN}Generating SQL script to initialize the database...${RESET}"
    echo "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;" > "$SQL_SCRIPT"
    echo "USE \`${DB_NAME}\`;" >> "$SQL_SCRIPT"

    # Generate table creation scripts
    for (( i=0; i<${#ENTITY_NAMES[@]}; i++ )); do
        entity_name=${ENTITY_NAMES[$i]}
        table_name=$(echo "$entity_name" | tr '[:upper:]' '[:lower:]')
        properties=${ENTITY_PROPERTIES[$i]}

        echo "Creating table: $table_name"

        echo "DROP TABLE IF EXISTS \`$table_name\`;" >> "$SQL_SCRIPT"
        echo "CREATE TABLE \`$table_name\` (" >> "$SQL_SCRIPT"

        IFS=' ' read -ra props <<< "$properties"
        prop_lines=()
        foreign_keys=()
        for (( j=0; j<${#props[@]}; j++ )); do
            prop=${props[$j]}
            IFS=':' read -ra prop_parts <<< "$prop"
            prop_name=${prop_parts[0]}
            prop_type=${prop_parts[1]}
            prop_constraint=${prop_parts[2]:-}

            sql_line="\`${prop_name}\` ${prop_type}"

            if [[ "$prop_constraint" == "PRIMARY_KEY" ]]; then
                sql_line+=" AUTO_INCREMENT PRIMARY KEY"
            elif [[ "$prop_constraint" == "FOREIGN_KEY" ]]; then
                foreign_table=$(echo "${prop_parts[3]}" | cut -d'(' -f1)
                foreign_column=$(echo "${prop_parts[3]}" | cut -d'(' -f2 | tr -d ')')
                lower_foreign_table=$(echo "$foreign_table" | tr '[:upper:]' '[:lower:]')
                foreign_key="FOREIGN KEY (\`${prop_name}\`) REFERENCES \`${lower_foreign_table}\`(\`${foreign_column}\`)"
                foreign_keys+=("$foreign_key")
            fi

            prop_lines+=("$sql_line")
        done

        # Output property lines
        for (( k=0; k<${#prop_lines[@]}; k++ )); do
            if [ $k -eq $((${#prop_lines[@]} - 1)) ] && [ ${#foreign_keys[@]} -eq 0 ]; then
                echo "  ${prop_lines[$k]}" >> "$SQL_SCRIPT"
            else
                echo "  ${prop_lines[$k]}," >> "$SQL_SCRIPT"
            fi
        done

        # Output foreign keys
        for (( k=0; k<${#foreign_keys[@]}; k++ )); do
            if [ $k -eq $((${#foreign_keys[@]} - 1)) ]; then
                echo "  ${foreign_keys[$k]}" >> "$SQL_SCRIPT"
            else
                echo "  ${foreign_keys[$k]}," >> "$SQL_SCRIPT"
            fi
        done

        echo ");" >> "$SQL_SCRIPT"
        echo "" >> "$SQL_SCRIPT"
    done

    # Generate many-to-many relationship tables
    for relationship in "${RELATIONSHIPS[@]}"; do
        IFS=':' read -ra rel_parts <<< "$relationship"
        entity_a=${rel_parts[0]}
        entity_b=${rel_parts[1]}
        table_name=${rel_parts[2]}
        column_a=${rel_parts[3]}
        column_b=${rel_parts[4]}

        lower_entity_a=$(echo "$entity_a" | tr '[:upper:]' '[:lower:]')
        lower_entity_b=$(echo "$entity_b" | tr '[:upper:]' '[:lower:]')

        echo "DROP TABLE IF EXISTS \`$table_name\`;" >> "$SQL_SCRIPT"
        echo "CREATE TABLE \`$table_name\` (" >> "$SQL_SCRIPT"
        echo "  \`${column_a}\` BIGINT NOT NULL," >> "$SQL_SCRIPT"
        echo "  \`${column_b}\` BIGINT NOT NULL," >> "$SQL_SCRIPT"
        echo "  PRIMARY KEY (\`${column_a}\`, \`${column_b}\`)," >> "$SQL_SCRIPT"
        echo "  FOREIGN KEY (\`${column_a}\`) REFERENCES \`${lower_entity_a}\`(id)," >> "$SQL_SCRIPT"
        echo "  FOREIGN KEY (\`${column_b}\`) REFERENCES \`${lower_entity_b}\`(id)" >> "$SQL_SCRIPT"
        echo ");" >> "$SQL_SCRIPT"
        echo "" >> "$SQL_SCRIPT"
    done

    echo -e "${GREEN}SQL script ($SQL_SCRIPT) generated successfully.${RESET}"
}

# Function to run Docker Compose
run_docker_compose() {
    echo -e "${CYAN}Starting MySQL container using Docker Compose...${RESET}"
    $DOCKER_COMPOSE_CMD up -d

    # Wait for MySQL to be ready
    echo -e "${CYAN}Waiting for MySQL to be ready...${RESET}"
    until docker exec "$CONTAINER_NAME" mysqladmin ping -h "localhost" -p"$ROOT_PASSWORD" --silent &> /dev/null; do
        sleep 2
    done
    echo -e "${GREEN}MySQL is ready.${RESET}"
}

# Function to generate application.properties file for Spring Boot
generate_application_properties() {
    cat > "$APP_PROPERTIES_FILE" <<EOF
spring.datasource.url=jdbc:mysql://localhost:${PORT}/${DB_NAME}?useSSL=false&serverTimezone=UTC
spring.datasource.username=root
spring.datasource.password=${ROOT_PASSWORD}
spring.datasource.driver-class-name=com.mysql.cj.jdbc.Driver

# JPA / Hibernate Settings
spring.jpa.database-platform=org.hibernate.dialect.MySQL8Dialect
spring.jpa.show-sql=false
spring.jpa.hibernate.ddl-auto=none
spring.jpa.properties.hibernate.format_sql=true
spring.jpa.properties.hibernate.use_sql_comments=false
spring.jpa.properties.hibernate.jdbc.lob.non_contextual_creation=true

# Connection Pool Configuration
spring.datasource.hikari.minimum-idle=5
spring.datasource.hikari.maximum-pool-size=20
spring.datasource.hikari.idle-timeout=30000
spring.datasource.hikari.max-lifetime=1800000
spring.datasource.hikari.connection-timeout=20000
spring.datasource.hikari.pool-name=MyHikariCP

# Logging Configuration
logging.level.root=INFO
logging.level.org.springframework.web=INFO
logging.level.org.hibernate.SQL=DEBUG
logging.file.path=${DATA_DIR}/logs
logging.file.name=${DATA_DIR}/logs/application.log
logging.pattern.console=%d{yyyy-MM-dd HH:mm:ss} - %msg%n
logging.pattern.file=%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n
EOF
    echo -e "${GREEN}Application properties file ($APP_PROPERTIES_FILE) created successfully.${RESET}"
}

# Function to initialize the setup
initialize() {
    check_docker
    check_docker_compose
    find_available_port
    generate_password
    create_directories
    create_network
    check_existing_container
    generate_sql_script
    create_docker_compose
    run_docker_compose
    generate_application_properties
    echo -e "${GREEN}MySQL Docker container setup completed successfully!${RESET}"
    echo -e "${YELLOW}Remember to add '${DATA_DIR}/logs', '$APP_PROPERTIES_FILE', and '$SQL_SCRIPT' to your .gitignore to prevent sensitive files from being tracked.${RESET}"
}

# Run the initialization
initialize