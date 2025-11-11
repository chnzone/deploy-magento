#!/bin/bash

# Garante que paths são relativos ao script, não ao terminal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carrega variáveis do .env
set -o allexport
source ./infrastructure/.env
set +o allexport

# Cores para o Console
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color (reset)
DOCKER_CONTAINER_NAME='magento-store'
DOCKER_MAGENTO_DIR='/var/www/store'
DOCKER_MYSQL_NAME='magento-mysql'
DOCKER_ELASTICSEARCH_NAME='magento-elasticsearch'
DOCKER_REDIS_NAME='magento-redis'
DOCKER_REBBITMQ_NAME='magento-rabbitmq'
MAGENTO_PATH='./instance/store/magento'
DOCKER_COMPOSE_SHARED_FILE="./infrastructure/docker-compose.shared.yml"
DOCKERFILE_PHP_FPM_FILE="./infrastructure/php-fpm/Dockerfile"

echo "
    ____              __          __ __   __  ___                            __       
   /  _/____   _____ / /_ ____ _ / // /  /  |/  /____ _ ____ _ ___   ____   / /_ ____ 
   / / / __ \ / ___// __// __  // // /  / /|_/ // __  // __  // _ \ / __ \ / __// __ /
 _/ / / / / /(__  )/ /_ / /_/ // // /  / /  / // /_/ // /_/ //  __// / / // /_ / /_/ /
/___//_/ /_//____/ \__/ \__,_//_//_/  /_/  /_/ \__,_/ \__, / \___//_/ /_/ \__/ \____/ 
                                                     /____/                                     
"
echo -ne "🔧 ${GREEN}You have started the Magento 2 Installation mode, do you want to continue? (y/n): ${NC}"
read response

if [[ ! "$response" =~ ^(s|S|sim|Sim|y|Y|yes|Yes)$ ]]; then
    echo -e "${RED}Operação cancelada pelo usuário.${NC}"
    exit 1
fi

if [ ! -f "$DOCKER_COMPOSE_SHARED_FILE" ] || [ ! -f "$DOCKERFILE_PHP_FPM_FILE" ]; then
    echo -e "${RED}Erro: Dockerfile ou docker-compose.shared não foi encontrado.${NC}"
    exit 1
fi

docker build -t magento-php:8.4-custom -f $DOCKERFILE_PHP_FPM_FILE ./infrastructure/php-fpm

echo -e "✅ ${GREEN}Spinning up shared containers with Docker Compose...${NC}"
docker compose -f "$DOCKER_COMPOSE_SHARED_FILE" up -d

echo -e "🔧 ${GREEN}Starting Store installation inside the magento-store container... ${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  cd $DOCKER_MAGENTO_DIR && \
  composer install -n && \
  php -d memory_limit=-1 bin/magento setup:install \
    --base-url=$MAGENTO_HOST:$MAGENTO_PORT \
    --db-host=$DOCKER_MYSQL_NAME \
    --db-name=$MYSQL_DATABASE\
    --db-user=$MYSQL_USER \
    --db-password=$MYSQL_PASSWORD \
    --language=$LANGUAGE \
    --currency=$CURRENCY \
    --timezone=$TIMEZONE \
    --use-rewrites=1 \
    --search-engine=$SEARCH_ENGINE \
    --elasticsearch-host=$DOCKER_ELASTICSEARCH_NAME && \

  php bin/magento setup:config:set -n\
    --session-save=redis \
    --session-save-redis-host=$DOCKER_REDIS_NAME \
    --session-save-redis-port=6379 \
    --session-save-redis-db=2 && \

  php bin/magento setup:config:set -n\
    --cache-backend=redis \
    --cache-backend-redis-server=$DOCKER_REDIS_NAME \
    --cache-backend-redis-db=0 && \

  php bin/magento setup:config:set -n\
    --page-cache=redis \
    --page-cache-redis-server=magento-redis \
    --page-cache-redis-db=1 && \

  php bin/magento setup:config:set -n\
    --amqp-host=$DOCKER_REBBITMQ_NAME \
    --amqp-port=5672 \
    --amqp-user=$RABBITMQ_DEFAULT_USER \
    --amqp-password=$RABBITMQ_DEFAULT_PASSWORD \
    --amqp-virtualhost=/ 
"

echo -e "✅ ${GREEN}Adding www-data group in Magento files. ${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  php bin/magento setup:upgrade && \
  php bin/magento setup:di:compile && \
  php bin/magento setup:static-content:deploy -f && \
  php bin/magento indexer:reindex && \
  php bin/magento cache:clean && \
  php bin/magento cache:flush
"

echo -e "✅ ${GREEN} Installing Cron... ${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  php bin/magento cron:remove && \
  php bin/magento cron:install && \
  php bin/magento cron:run
"

echo -e "✅ ${GREEN}Adding www-data group in Magento files.${NC}"
chown -R www-data:www-data $MAGENTO_PATH

echo -e "✅ ${GREEN}Adding permissions to Magento folders and files. ${NC}"
find $MAGENTO_PATH -type f -exec chmod 644 {} \;
find $MAGENTO_PATH -type d -exec chmod 755 {} \;

echo -e "✅ ${GREEN}Clear cache ${NC}"
docker restart magento-nginx
docker restart magento-varnish

echo -e "✅ ${GREEN}Create Admin user to Magento${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  php bin/magento admin:user:create \
    --admin-user=$MAGENTO_ADMIN_USER \
    --admin-password=$MAGENTO_ADMIN_PASSWORD \
    --admin-email=$MAGENTO_ADMIN_EMAIL \
    --admin-firstname=$MAGENTO_FIRSTNAME \
    --admin-lastname=$MAGENTO_LASTNAME
"

echo "✅ Installation complete!"
