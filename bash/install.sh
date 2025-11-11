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
MAGENTO_VERSION="2.4.6-p8"  # 与composer.json版本匹配
AUTH_JSON_PATH="$PROJECT_ROOT/source/store/magento/auth.json"  # 认证文件路径

# 检查并安装PHP（Composer依赖）
install_php_if_missing() {
    echo -e "${GREEN}检查PHP是否安装...${NC}"
    if ! command -v php &> /dev/null; then
        echo -e "${YELLOW}未检测到PHP，开始安装PHP-cli（Composer依赖）...${NC}"
        
        # 检测是否有sudo或是否为root
        check_sudo_availability
        local SUDO_CMD=$SUDO_AVAILABLE

        # Debian/Ubuntu系统安装PHP
        $SUDO_CMD apt update -y
        $SUDO_CMD apt install -y php-cli php-json php-mbstring php-curl php-xml  # 增加xml扩展
        
        # 验证安装
        if ! command -v php &> /dev/null; then
            echo -e "${RED}错误：PHP安装失败，请手动安装PHP后重试${NC}"
            exit 1
        fi
        echo -e "${GREEN}PHP安装成功${NC}"
    else
        echo -e "${GREEN}已检测到PHP，跳过安装${NC}"
    fi
}

# 检查sudo是否可用（全局函数）
check_sudo_availability() {
    if command -v sudo &> /dev/null && [ "$(id -u)" -ne 0 ]; then
        SUDO_AVAILABLE="sudo"  # 非root且有sudo
    else
        SUDO_AVAILABLE=""  # root用户或无sudo
    fi
}

# 检查必要文件（不含auth.json，单独处理）
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

# 验证auth.json是否包含有效的repo.magento.com凭据
validate_auth_json() {
    # 检查文件是否存在
    if [ ! -f "$AUTH_JSON_PATH" ]; then
        echo -e "${YELLOW}未检测到auth.json文件，无法使用Composer方案${NC}"
        return 1  # 凭据无效
    fi

    # 检查文件是否包含repo.magento.com配置
    if ! grep -q "repo.magento.com" "$AUTH_JSON_PATH"; then
        echo -e "${YELLOW}auth.json中未找到repo.magento.com配置，无法使用Composer方案${NC}"
        return 1  # 凭据无效
    fi

    # 检查username和password是否被填充（非占位符）
    # 不依赖jq，使用基础文本匹配避免jq缺失问题
    if grep -q "<公钥>" "$AUTH_JSON_PATH" || grep -q "<私钥>" "$AUTH_JSON_PATH"; then
        echo -e "${YELLOW}auth.json中repo.magento.com的公钥/私钥未填写，无法使用Composer方案${NC}"
        return 1  # 凭据无效
    fi

    # 所有检查通过
    echo -e "${GREEN}auth.json验证通过，可使用Composer方案${NC}"
    return 0  # 凭据有效
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

# 清理目录（保留目录但清空内容）
clean_magento_dir() {
    if [ -d "$MAGENTO_PATH" ]; then
        echo -e "${YELLOW}清理非空目录 $MAGENTO_PATH 中的内容...${NC}"
        # 保留目录但删除所有内容（包括隐藏文件）
        rm -rf "$MAGENTO_PATH"/* "$MAGENTO_PATH"/.[!.]* "$MAGENTO_PATH"/..?* 2>/dev/null
    fi
}

# 检测下载的tar文件是否有效
is_valid_tar_gz() {
    local file="$1"
    # 检查文件大小（至少10MB，防止空文件或错误页面）
    if [ $(stat -c%s "$file") -lt 10485760 ]; then  # 10MB=10*1024*1024
        return 1
    fi
    # 检查文件头部是否为gzip格式（gzip文件头部为0x1f8b）
    if ! head -c 2 "$file" | hexdump -C | grep -q "1f 8b"; then
        return 1
    fi
    return 0
}

# 检测composer.json是否存在，不存在则自动下载源码
check_or_download_magento() {
    # 检查源码目录是否存在且包含composer.json
    if [ ! -d "$MAGENTO_PATH" ] || [ ! -f "$MAGENTO_PATH/composer.json" ]; then
        echo -e "${YELLOW}未检测到完整的Magento源码，准备下载版本 $MAGENTO_VERSION...${NC}"
        
        # 创建源码目录（若不存在）
        mkdir -p "$MAGENTO_PATH"
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误：无法创建Magento源码目录 $MAGENTO_PATH${NC}"
            exit 1
        fi

        # 清理目录（解决"目录非空"问题）
        clean_magento_dir

        # 验证auth.json凭据是否有效
        local use_composer=0
        if validate_auth_json; then
            use_composer=1
        else
            use_composer=0
        fi

        # 方案1：仅当凭据有效时使用Composer下载
        if [ $use_composer -eq 1 ]; then
            # 检查并安装Composer
            echo -e "${GREEN}检查Composer是否安装...${NC}"
            if command -v composer &> /dev/null; then
                COMPOSER_CMD="composer"
            else
                # 临时安装Composer（依赖已安装的PHP）
                echo -e "${YELLOW}未检测到Composer，开始临时安装...${NC}"
                curl -sS --http1.1 https://mirrors.aliyun.com/composer/composer.phar -o /tmp/composer.phar
                chmod +x /tmp/composer.phar
                COMPOSER_CMD="/tmp/composer.phar"
                
                # 验证Composer是否可用
                if ! $COMPOSER_CMD --version &> /dev/null; then
                    echo -e "${YELLOW}Composer安装失败，切换到GitHub镜像方案${NC}"
                    use_composer=0
                fi
            fi

            # 尝试Composer下载
            if [ $use_composer -eq 1 ]; then
                # 配置国内Composer镜像加速
                $COMPOSER_CMD config -g repo.packagist composer https://mirrors.aliyun.com/composer/

                echo -e "${GREEN}尝试通过Composer创建项目...${NC}"
                if ! $COMPOSER_CMD create-project --no-install magento/project-community-edition="$MAGENTO_VERSION" "$MAGENTO_PATH" --no-interaction; then
                    echo -e "${YELLOW}Composer下载失败，切换到GitHub镜像方案${NC}"
                    use_composer=0
                fi
            fi
        fi

        # 方案2：当Composer不可用或失败时，使用GitHub镜像下载
        if [ $use_composer -eq 0 ]; then
            echo -e "${YELLOW}使用GitHub镜像方案下载源码...${NC}"
            
            # 国内镜像列表（按优先级排序）
            MAGENTO_TAR_URLS=(
                "https://gh-proxy.com/https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"
                "https://gitcode.net/mirrors/magento/magento2/-/archive/$MAGENTO_VERSION/magento2-$MAGENTO_VERSION.tar.gz"  # GitCode镜像
                "https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"  # 官方源（备用）
            )
            TEMP_TAR="$PROJECT_ROOT/magento_temp.tar.gz"
            local download_success=0

            # 循环尝试镜像源
            for url in "${MAGENTO_TAR_URLS[@]}"; do
                echo -e "${YELLOW}尝试从 $url 下载...${NC}"
                # 清理之前的错误文件
                rm -f "$TEMP_TAR"
                # 下载源码包（增加超时和重试）
                if curl -L --http1.1 --retry 3 --connect-timeout 30 --output "$TEMP_TAR" "$url"; then
                    # 校验文件有效性
                    if is_valid_tar_gz "$TEMP_TAR"; then
                        echo -e "${GREEN}从 $url 下载成功！${NC}"
                        download_success=1
                        break
                    else
                        echo -e "${YELLOW}$url 下载的文件无效，尝试下一个镜像...${NC}"
                    fi
                else
                    echo -e "${YELLOW}$url 下载失败，尝试下一个镜像...${NC}"
                fi
            done

            # 所有镜像都失败
            if [ $download_success -eq 0 ]; then
                echo -e "${RED}所有镜像源下载失败，请手动下载以下文件并放置到 $PROJECT_ROOT 后重试：${NC}"
                echo "  https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"
                exit 1
            fi

            # 解压源码
            echo -e "${GREEN}解压源码包...${NC}"
            mkdir -p "$PROJECT_ROOT/temp_magento"
            if ! tar -zxf "$TEMP_TAR" -C "$PROJECT_ROOT/temp_magento"; then
                echo -e "${RED}解压失败，文件可能损坏，请手动解压${NC}"
                exit 1
            fi
            # 移动源码到目标目录（处理可能的目录名差异）
            mv "$PROJECT_ROOT/temp_magento"/*/* "$MAGENTO_PATH/"  # 适配不同镜像的目录结构
            rm -rf "$TEMP_TAR" "$PROJECT_ROOT/temp_magento"
        fi

        # 如果auth.json存在，复制到源码目录（无论哪种方案）
        if [ -f "$AUTH_JSON_PATH" ]; then
            cp "$AUTH_JSON_PATH" "$MAGENTO_PATH/auth.json"
        fi
        echo -e "${GREEN}Magento源码准备完成${NC}"
    else
        echo -e "${GREEN}检测到已存在完整的Magento源码，跳过下载${NC}"
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

# 检查sudo是否可用（全局变量SUDO_AVAILABLE）
check_sudo_availability

# 检查并安装PHP（解决Composer依赖）
install_php_if_missing

# 检查必要文件（不含auth.json，单独处理）
check_required_files

# 加载环境变量
load_env_variables

# 检测并自动下载Magento源码（根据auth.json状态选择方案）
check_or_download_magento

# 配置国内Docker镜像加速（适配无sudo环境）
configure_docker_mirror() {
    echo -e "${GREEN}配置Docker国内镜像加速...${NC}"
    DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
    # 仅在有足够权限时配置（root或有sudo）
    if [ -n "$SUDO_AVAILABLE" ] || [ "$(id -u)" -eq 0 ]; then
        if [ -f "$DOCKER_DAEMON_JSON" ]; then
            if ! grep -q "registry-mirrors" "$DOCKER_DAEMON_JSON"; then
                # 不依赖jq，避免jq缺失问题
                echo -e "${YELLOW}手动添加Docker镜像加速配置...${NC}"
                $SUDO_AVAILABLE sed -i '$ d' "$DOCKER_DAEMON_JSON"  # 删除最后一行
                $SUDO_AVAILABLE echo '  "registry-mirrors": ["https://docker.mirrors.ustc.edu.cn", "https://hub-mirror.c.163.com", "https://mirror.baidubce.com"]' >> "$DOCKER_DAEMON_JSON"
                $SUDO_AVAILABLE echo '}' >> "$DOCKER_DAEMON_JSON"
                $SUDO_AVAILABLE systemctl restart docker
            fi
        else
            $SUDO_AVAILABLE tee "$DOCKER_DAEMON_JSON" <<EOF
{
  "registry-mirrors": ["https://docker.mirrors.ustc.edu.cn", "https://hub-mirror.c.163.com", "https://mirror.baidubce.com"]
}
EOF
            $SUDO_AVAILABLE systemctl restart docker
        fi
    else
        echo -e "${YELLOW}无权限配置Docker镜像加速，可能影响下载速度${NC}"
    fi
}

# 尝试配置Docker镜像加速
configure_docker_mirror

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
  composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/
  
  cd $DOCKER_MAGENTO_DIR && \
  composer install -n && \
  php -d memory_limit=-1 bin/magento setup:install \
    --base-url=$MAGENTO_SHOPURI \
    --backend-frontname=$BACKEND_FRONTNAME \
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

echo -e "✅ ${GREEN}执行Magento配置命令...${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  cd $DOCKER_MAGENTO_DIR && \
  php bin/magento setup:upgrade && \
  php bin/magento setup:di:compile && \
  php bin/magento setup:static-content:deploy -f && \
  php bin/magento indexer:reindex && \
  php bin/magento cache:clean && \
  php bin/magento cache:flush
"

echo -e "✅ ${GREEN}安装Cron任务... ${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  cd $DOCKER_MAGENTO_DIR && \
  php bin/magento cron:remove && \
  php bin/magento cron:install && \
  php bin/magento cron:run
"

echo -e "✅ ${GREEN}设置Magento文件权限...${NC}"
# 适配无sudo环境的权限设置
if [ "$(uname)" = "Linux" ]; then
    # 检查是否有足够权限修改所有者（root或www-data）
    if [ -n "$SUDO_AVAILABLE" ] || [ "$(id -u)" -eq 0 ]; then
        $SUDO_AVAILABLE chown -R www-data:www-data "$MAGENTO_PATH"
    else
        echo -e "${YELLOW}无权限修改文件所有者，尝试仅设置权限位...${NC}"
    fi
else
    # 非Linux系统
    chmod -R 775 "$MAGENTO_PATH"
fi

# 细化权限设置（不依赖sudo，确保当前用户可执行）
find "$MAGENTO_PATH" -type f -exec chmod 644 {} \; 2>/dev/null
find "$MAGENTO_PATH" -type d -exec chmod 755 {} \; 2>/dev/null
chmod -R 777 "$MAGENTO_PATH/var" "$MAGENTO_PATH/generated" "$MAGENTO_PATH/pub/media" "$MAGENTO_PATH/pub/static" 2>/dev/null

echo -e "✅ ${GREEN}重启相关服务清除缓存...${NC}"
docker restart magento-nginx
docker restart magento-varnish

echo -e "✅ ${GREEN}创建Magento管理员用户...${NC}"
docker exec -it $DOCKER_CONTAINER_NAME bash -c "
  cd $DOCKER_MAGENTO_DIR && \
  php bin/magento admin:user:create \
    --admin-user=$MAGENTO_ADMIN_USER \
    --admin-password=$MAGENTO_ADMIN_PASSWORD \
    --admin-email=$MAGENTO_ADMIN_EMAIL \
    --admin-firstname=$MAGENTO_FIRSTNAME \
    --admin-lastname=$MAGENTO_LASTNAME
"

echo -e "${GREEN}✅ 安装完成！您可以通过 $MAGENTO_HOST:$MAGENTO_PORT 访问您的Magento商店${NC}"
echo -e "${GREEN}管理员地址：$MAGENTO_HOST:$MAGENTO_PORT/admin${NC}"
