#!/bin/bash
set -e

# 确保脚本无论从哪个目录运行都能正常工作
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# 定义关键文件和目录的绝对路径
DOCKER_COMPOSE_SHARED_FILE="$PROJECT_ROOT/docker/docker-compose.shared.yml"
DOCKERFILE_PHP_FPM_FILE="$PROJECT_ROOT/docker/php-fpm/Dockerfile"
MAGENTO_PATH="$PROJECT_ROOT/source/store/magento"
ENV_FILE="$PROJECT_ROOT/docker/.env"

# 检查必要文件是否存在
check_required_files() {
    local missing_files=()
    
    if [ ! -f "$DOCKER_COMPOSE_SHARED_FILE" ]; then
        missing_files+=("$DOCKER_COMPOSE_SHARED_FILE")
    fi
    
    if [ ! -f "$DOCKERFILE_PHP_FPM_FILE" ]; then
        missing_files+=("$DOCKERFILE_PHP_FPM_FILE")
    fi
    
    if [ ! -f "$ENV_FILE" ]; then
        missing_files+=("$ENV_FILE")
    fi
    
    if [ ${#missing_files[@]} -ne 0 ]; then
        echo -e "${RED}错误：缺少必要的文件：${NC}"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        exit 1
    fi
}

# 加载环境变量
load_env_variables() {
    if [ -f "$ENV_FILE" ]; then
        echo -e "${GREEN}加载环境变量...${NC}"
        set -o allexport
        source "$ENV_FILE"
        set +o allexport
    else
        echo -e "${RED}错误：环境变量文件 $ENV_FILE 不存在${NC}"
        exit 1
    fi
}

# 检查Magento源码是否存在，不存在则下载
check_or_download_magento() {
    if [ ! -d "$MAGENTO_PATH" ] || [ -z "$(ls -A "$MAGENTO_PATH")" ]; then
        echo -e "${YELLOW}未检测到Magento源码，准备下载...${NC}"
        
        # 创建目录
        mkdir -p "$MAGENTO_PATH"
        
        # 国内镜像源下载Magento源码
        MAGENTO_VERSION="2.4.6-p8"
        MAGENTO_DOWNLOAD_URL="https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"
        
        echo -e "${GREEN}从 $MAGENTO_DOWNLOAD_URL 下载Magento $MAGENTO_VERSION...${NC}"
        if ! curl -L --retry 3 --output "$PROJECT_ROOT/magento.tar.gz" "$MAGENTO_DOWNLOAD_URL"; then
            echo -e "${RED}下载失败，尝试使用国内镜像...${NC}"
            # 使用GitHub镜像站
            MAGENTO_DOWNLOAD_URL="https://hub.fastgit.xyz/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"
            if ! curl -L --retry 3 --output "$PROJECT_ROOT/magento.tar.gz" "$MAGENTO_DOWNLOAD_URL"; then
                echo -e "${RED}镜像下载也失败，请手动下载并放置到 $MAGENTO_PATH${NC}"
                exit 1
            fi
        fi
        
        # 解压源码
        echo -e "${GREEN}解压Magento源码...${NC}"
        tar -zxf "$PROJECT_ROOT/magento.tar.gz" -C "$PROJECT_ROOT"
        mv "$PROJECT_ROOT/magento2-$MAGENTO_VERSION"/* "$MAGENTO_PATH/"
        rm -rf "$PROJECT_ROOT/magento.tar.gz" "$PROJECT_ROOT/magento2-$MAGENTO_VERSION"
        
        echo -e "${GREEN}Magento源码准备完成${NC}"
    else
        echo -e "${GREEN}检测到已存在Magento源码，跳过下载${NC}"
    fi
}

# 控制台颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色（重置）

# 容器和目录名称
DOCKER_CONTAINER_NAME='magento-store'
DOCKER_MAGENTO_DIR='/var/www/store'
DOCKER_MYSQL_NAME='magento-mysql'
DOCKER_ELASTICSEARCH_NAME='magento-elasticsearch'
DOCKER_REDIS_NAME='magento-redis'
DOCKER_REBBITMQ_NAME='magento-rabbitmq'

echo "
    ____              __          __ __   __  ___                            __       
   /  _/____   _____ / /_ ____ _ / // /  /  |/  /____ _ ____ _ ___   ____   / /_ ____ 
   / / / __ \ / ___// __// __  // // /  / /|_/ // __  // __  // _ \ / __ \ / __// __ /
 _/ / / / / /(__  )/ /_ / /_/ // // /  / /  / // /_/ // /_/ //  __// / / // /_ / /_/ /
/___//_/ /_//____/ \__/ \__,_//_//_/  /_/  /_/ \__,_/ \__, / \___//_/ /_/ \__/ \____/ 
                                                     /____/                                     
"
echo -ne "🔧 ${GREEN}您已启动Magento 2安装模式，是否要继续？(是/否): ${NC}"
read response

if [[ ! "$response" =~ ^(是|y|Y|yes|Yes)$ ]]; then
    echo -e "${RED}操作被用户取消。${NC}"
    exit 1
fi

# 检查必要文件
check_required_files

# 加载环境变量
load_env_variables

# 检查或下载Magento源码
check_or_download_magento

# 配置国内Docker镜像加速
configure_docker_mirror() {
    echo -e "${GREEN}配置Docker国内镜像加速...${NC}"
    DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
    if [ -f "$DOCKER_DAEMON_JSON" ]; then
        if ! grep -q "registry-mirrors" "$DOCKER_DAEMON_JSON"; then
            jq '. += {"registry-mirrors": ["https://docker.mirrors.ustc.edu.cn", "https://hub-mirror.c.163.com", "https://mirror.baidubce.com"]}' "$DOCKER_DAEMON_JSON" > "$DOCKER_DAEMON_JSON.tmp" && mv "$DOCKER_DAEMON_JSON.tmp" "$DOCKER_DAEMON_JSON"
            systemctl restart docker
        fi
    else
        sudo tee "$DOCKER_DAEMON_JSON" <<EOF
{
  "registry-mirrors": ["https://docker.mirrors.ustc.edu.cn", "https://hub-mirror.c.163.com", "https://mirror.baidubce.com"]
}
EOF
        systemctl restart docker
    fi
}

# 尝试配置Docker镜像加速（需要root权限）
if [ "$(id -u)" -eq 0 ]; then
    configure_docker_mirror
else
    echo -e "${YELLOW}非root用户，跳过Docker镜像配置，建议手动配置以提高下载速度${NC}"
fi

# 构建PHP-FPM镜像，使用国内源
echo -e "${GREEN}构建PHP-FPM镜像，使用国内源...${NC}"
docker build \
    --build-arg ALPINE_MIRROR=mirrors.ustc.edu.cn \
    --build-arg DEBIAN_MIRROR=mirrors.ustc.edu.cn \
    -t magento-php:8.4-custom \
    -f "$DOCKERFILE_PHP_FPM_FILE" \
    "$PROJECT_ROOT/docker/php-fpm"

echo -e "✅ ${GREEN}使用Docker Compose启动共享容器...${NC}"
docker compose -f "$DOCKER_COMPOSE_SHARED_FILE" up -d

# 等待数据库就绪
echo -e "${GREEN}等待数据库就绪...${NC}"
until docker exec $DOCKER_MYSQL_NAME mysqladmin ping -u$MYSQL_USER -p$MYSQL_PASSWORD --silent; do
    echo -e "${YELLOW}数据库尚未就绪，等待5秒...${NC}"
    sleep 5
done

# 等待Elasticsearch就绪
echo -e "${GREEN}等待Elasticsearch就绪...${NC}"
until docker exec $DOCKER_ELASTICSEARCH_NAME curl -s "http://localhost:9200/_cluster/health" | grep -q "green"; do
    echo -e "${YELLOW}Elasticsearch尚未就绪，等待5秒...${NC}"
    sleep 5
done

echo -e "🔧 ${GREEN}开始在magento-store容器内安装商店... ${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  # 配置Composer国内源
  composer config -g repo.packagist composer https://packagist.phpcomposer.com
  
  cd $DOCKER_MAGENTO_DIR && \
  composer install -n && \
  php -d memory_limit=-1 bin/magento setup:install \
    --base-url=$MAGENTO_HOST:$MAGENTO_PORT \
    --db-host=$DOCKER_MYSQL_NAME \
    --db-name=$MYSQL_DATABASE \
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

echo -e "✅ ${GREEN}在Magento文件中添加www-data组。${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  php bin/magento setup:upgrade && \
  php bin/magento setup:di:compile && \
  php bin/magento setup:static-content:deploy -f && \
  php bin/magento indexer:reindex && \
  php bin/magento cache:clean && \
  php bin/magento cache:flush
"

echo -e "✅ ${GREEN}安装Cron... ${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  php bin/magento cron:remove && \
  php bin/magento cron:install && \
  php bin/magento cron:run
"

echo -e "✅ ${GREEN}在Magento文件中添加www-data组。${NC}"
# 检查并设置适当的权限
if [ "$(uname)" = "Linux" ]; then
    sudo chown -R www-data:www-data "$MAGENTO_PATH"
else
    # 非Linux系统可能不需要www-data用户
    chmod -R 775 "$MAGENTO_PATH"
fi

echo -e "✅ ${GREEN}为Magento文件夹和文件添加权限。${NC}"
find "$MAGENTO_PATH" -type f -exec chmod 644 {} \;
find "$MAGENTO_PATH" -type d -exec chmod 755 {} \;

echo -e "✅ ${GREEN}清除缓存 ${NC}"
docker restart magento-nginx
docker restart magento-varnish

echo -e "✅ ${GREEN}为Magento创建管理员用户${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  php bin/magento admin:user:create \
    --admin-user=$MAGENTO_ADMIN_USER \
    --admin-password=$MAGENTO_ADMIN_PASSWORD \
    --admin-email=$MAGENTO_ADMIN_EMAIL \
    --admin-firstname=$MAGENTO_FIRSTNAME \
    --admin-lastname=$MAGENTO_LASTNAME
"

echo -e "${GREEN}✅ 安装完成！您可以通过 $MAGENTO_HOST:$MAGENTO_PORT 访问您的Magento商店${NC}"