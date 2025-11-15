#!/bin/bash
set -euo pipefail  # 严格模式：未定义变量报错、命令失败立即退出

# ==============================================
# 环境配置与常量定义
# ==============================================
# 颜色输出常量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 项目路径（根据实际目录结构调整）
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKER_DIR="$PROJECT_ROOT/docker"
MAGENTO_PATH="$PROJECT_ROOT/source/store/magento"
AUTH_JSON_PATH="$PROJECT_ROOT/source/store/auth.json"

# 从.env文件加载配置（若存在）
if [ -f "$DOCKER_DIR/.env" ]; then
    source "$DOCKER_DIR/.env"
fi

# 默认配置（.env未定义时使用）
MAGENTO_VERSION="${MAGENTO_VERSION:-2.4.6-p8}"
MAGENTO_DOMAIN="${MAGENTO_DOMAIN:-magento.local}"
DB_HOST="${DB_HOST:-mysql}"
DB_NAME="${DB_NAME:-magento}"
DB_USER="${DB_USER:-magento}"
DB_PASSWORD="${DB_PASSWORD:-magento}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"


# ==============================================
# 辅助函数
# ==============================================
# 清理Magento目录（确保为空）
clean_magento_dir() {
    if [ -d "$MAGENTO_PATH" ]; then
        echo -e "${YELLOW}清理Magento目录残留文件...${NC}"
        rm -rf "$MAGENTO_PATH"/*
    fi
}

# 校验tar.gz文件有效性（大小+格式+解压测试）
is_valid_tar_gz() {
    local file="$1"
    # 1. 检查文件大小（至少50MB，Magento源码包通常>100MB）
    if [ $(stat -c%s "$file" 2>/dev/null || echo 0) -lt 52428800 ]; then
        echo -e "${RED}文件无效：大小不足50MB${NC}"
        return 1
    fi
    # 2. 检查gzip文件头（0x1f8b）
    if ! head -c 2 "$file" | hexdump -C | grep -q "1f 8b"; then
        echo -e "${RED}文件无效：不是gzip格式${NC}"
        return 1
    fi
    # 3. 测试解压（快速校验）
    if ! tar -tzf "$file" >/dev/null 2>&1; then
        echo -e "${RED}文件无效：解压测试失败${NC}"
        return 1
    fi
    return 0
}

# 解压源码包（适配不同源的目录结构）
extract_magento_tar() {
    local tar_file="$1"
    local target_dir="$2"
    local temp_extract="$PROJECT_ROOT/temp_extract"

    rm -rf "$temp_extract"
    mkdir -p "$temp_extract"

    # 解压到临时目录
    echo -e "${YELLOW}解压源码包...${NC}"
    if ! tar -zxf "$tar_file" -C "$temp_extract"; then
        echo -e "${RED}解压失败：文件可能损坏${NC}"
        return 1
    fi

    # 定位源码根目录（处理不同源的目录层级差异）
    local extract_root=$(find "$temp_extract" -maxdepth 1 -type d ! -name "$(basename "$temp_extract")" | head -n 1)
    if [ -z "$extract_root" ]; then
        echo -e "${RED}未找到源码根目录${NC}"
        return 1
    fi

    # 移动到目标目录
    mv "$extract_root"/* "$target_dir/"
    rm -rf "$temp_extract"
    return 0
}

# 检查代理连通性（国内场景优先）
check_proxy_connectivity() {
    echo -e "${GREEN}检查GitHub代理连通性...${NC}"
    local test_proxy="https://gh-proxy.com/https://github.com"
    if ! curl -s --connect-timeout 10 "$test_proxy" >/dev/null; then
        echo -e "${YELLOW}警告：代理源访问不畅，可能影响下载速度${NC}"
        sleep 2
    fi
}

# 验证auth.json有效性（Composer备选方案用）
validate_auth_json() {
    if [ ! -f "$AUTH_JSON_PATH" ]; then
        echo -e "${YELLOW}未找到auth.json，Composer方案不可用${NC}"
        return 1
    fi
    # 简单校验格式（至少包含repo.magento.com的凭据）
    if ! grep -q "repo.magento.com" "$AUTH_JSON_PATH"; then
        echo -e "${YELLOW}auth.json缺少Magento仓库配置，Composer方案不可用${NC}"
        return 1
    fi
    return 0
}

# Composer安装（备选方案）
composer_create_project() {
    echo -e "${YELLOW}使用Composer安装Magento $MAGENTO_VERSION...${NC}"
    cd "$MAGENTO_PATH" || return 1

    # 复制auth.json到当前目录
    cp "$AUTH_JSON_PATH" "$MAGENTO_PATH/auth.json"

    # 执行Composer安装（使用国内镜像加速）
    if composer config -g repo.packagist composer https://packagist.phpcomposer.com && \
       composer create-project --repository-url=https://repo.magento.com/ magento/project-community-edition . "$MAGENTO_VERSION" --no-interaction; then
        return 0
    else
        echo -e "${RED}Composer安装失败${NC}"
        return 1
    fi
}


# ==============================================
# 核心函数：下载Magento源码（优先代理源）
# ==============================================
download_from_github() {
    local TEMP_TAR="$PROJECT_ROOT/magento_temp.tar.gz"
    local download_success=0

    # 清理历史文件
    rm -f "$TEMP_TAR"
    mkdir -p "$MAGENTO_PATH"
    clean_magento_dir

    # 下载源列表：国内代理优先，官方源最后
    local MAGENTO_TAR_URLS=(
        "https://gh-proxy.com/https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"  # 代理1（优先）
        "https://mirror.ghproxy.com/https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"  # 代理2
        "https://gitcode.net/mirrors/magento/magento2/-/archive/$MAGENTO_VERSION/magento2-$MAGENTO_VERSION.tar.gz"  # 代理3（镜像）
        "https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz"  # 官方源（最终备选）
    )

    # 预检查代理
    check_proxy_connectivity

    # 循环尝试下载源
    for url in "${MAGENTO_TAR_URLS[@]}"; do
        # 代理源重试3次，官方源重试1次
        local max_retries=1
        if [[ $url == *"proxy"* || $url == *"gitcode.net"* ]]; then
            max_retries=3
        fi

        # 单源多次重试
        for ((retry=1; retry<=$max_retries; retry++)); do
            echo -e "${YELLOW}尝试从 $url 下载（第 $retry 次）...${NC}"
            # 下载参数：长超时+自动重试
            if curl -L --http1.1 --retry 2 --connect-timeout 30 --max-time 180 --output "$TEMP_TAR" "$url"; then
                if is_valid_tar_gz "$TEMP_TAR"; then
                    echo -e "${GREEN}从 $url 下载成功！${NC}"
                    if extract_magento_tar "$TEMP_TAR" "$MAGENTO_PATH"; then
                        download_success=1
                        break 2  # 退出双层循环
                    fi
                fi
            else
                echo -e "${YELLOW}下载失败（状态码 $?），重试...${NC}"
            fi
        done
    done

    # 清理临时文件
    rm -f "$TEMP_TAR"
    return $((1 - download_success))
}


# ==============================================
# 核心函数：检查并准备Magento源码
# ==============================================
check_or_download_magento() {
    if [ -d "$MAGENTO_PATH" ] && [ -f "$MAGENTO_PATH/composer.json" ]; then
        echo -e "${GREEN}检测到已存在完整的Magento源码，跳过下载${NC}"
        return 0
    fi

    echo -e "${YELLOW}未检测到完整源码，启动第一方案：GitHub代理源下载...${NC}"
    if download_from_github; then
        echo -e "${GREEN}第一方案（GitHub）执行成功${NC}"
        # 复制auth.json到源码目录（后续Composer依赖可能需要）
        if [ -f "$AUTH_JSON_PATH" ]; then
            cp "$AUTH_JSON_PATH" "$MAGENTO_PATH/auth.json"
        fi
        return 0
    fi

    echo -e "${YELLOW}第一方案失败，启动备选方案：Composer安装...${NC}"
    if validate_auth_json && composer_create_project; then
        echo -e "${GREEN}备选方案（Composer）执行成功${NC}"
        return 0
    fi

    # 所有方案失败
    echo -e "${RED}所有安装方案均失败！请手动下载源码到 $MAGENTO_PATH${NC}"
    echo -e "${RED}官方下载地址：https://github.com/magento/magento2/archive/refs/tags/$MAGENTO_VERSION.tar.gz${NC}"
    exit 1
}


# ==============================================
# 核心函数：Docker环境部署
# ==============================================
deploy_docker_environment() {
    echo -e "${GREEN}开始部署Docker环境...${NC}"
    cd "$DOCKER_DIR" || exit 1

    # 构建自定义PHP镜像（含国内源加速）
    echo -e "${YELLOW}构建PHP-FPM镜像...${NC}"
    docker-compose -f docker-compose.shared.yml build php-fpm

    # 启动所有服务（MySQL、Redis、Elasticsearch等）
    echo -e "${YELLOW}启动Docker服务...${NC}"
    docker-compose -f docker-compose.shared.yml up -d

    # 等待MySQL就绪（最多等待60秒）
    echo -e "${YELLOW}等待MySQL初始化...${NC}"
    for ((i=0; i<30; i++)); do
        if docker exec "$(docker-compose -f docker-compose.shared.yml ps -q mysql)" mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
            echo -e "${GREEN}MySQL已就绪${NC}"
            break
        fi
        sleep 2
    done
}


# ==============================================
# 核心函数：安装Magento（容器内执行）
# ==============================================
install_magento_in_container() {
    echo -e "${GREEN}开始在容器内安装Magento...${NC}"
    local php_container=$(docker-compose -f "$DOCKER_DIR/docker-compose.shared.yml" ps -q php-fpm)

    # 容器内执行Magento安装命令
    docker exec "$php_container" bash -c "
        cd /var/www/html && \
        php bin/magento setup:install \
            --base-url=http://$MAGENTO_DOMAIN \
            --db-host=$DB_HOST \
            --db-name=$DB_NAME \
            --db-user=$DB_USER \
            --db-password=$DB_PASSWORD \
            --admin-firstname=Admin \
            --admin-lastname=User \
            --admin-email=$ADMIN_EMAIL \
            --admin-user=$ADMIN_USER \
            --admin-password=$ADMIN_PASSWORD \
            --language=en_US \
            --currency=USD \
            --timezone=UTC \
            --use-rewrites=1 \
            --search-engine=elasticsearch7 \
            --elasticsearch-host=elasticsearch \
            --elasticsearch-port=9200 \
            --cache-backend=redis \
            --cache-backend-redis-server=redis \
            --cache-backend-redis-db=0 \
            --session-save=redis \
            --session-save-redis-server=redis \
            --session-save-redis-db=1 \
            --queue-backend=amqp \
            --queue-backend-amqp-host=rabbitmq \
            --queue-backend-amqp-port=5672 \
            --queue-backend-amqp-user=guest \
            --queue-backend-amqp-password=guest \
            --queue-backend-amqp-virtualhost=/
    "

    # 配置Varnish缓存
    echo -e "${YELLOW}配置Varnish缓存...${NC}"
    docker exec "$php_container" bash -c "
        cd /var/www/html && \
        php bin/magento config:set system/full_page_cache/caching_application 2 && \
        php bin/magento setup:config:set --http-cache-hosts=varnish
    "

    # 编译代码与部署静态资源
    echo -e "${YELLOW}编译代码与部署静态资源...${NC}"
    docker exec "$php_container" bash -c "
        cd /var/www/html && \
        php bin/magento setup:di:compile && \
        php bin/magento setup:static-content:deploy -f && \
        chown -R www-data:www-data .
    "

    # 启用开发者模式（可选，根据需求调整）
    docker exec "$php_container" bash -c "cd /var/www/html && php bin/magento deploy:mode:set developer"
}


# ==============================================
# 主流程执行
# ==============================================
main() {
    echo -e "${GREEN}===== 开始部署Magento $MAGENTO_VERSION ====="
    echo -e "部署目录: $PROJECT_ROOT"
    echo -e "域名: $MAGENTO_DOMAIN${NC}"

    # 步骤1：准备源码
    check_or_download_magento

    # 步骤2：部署Docker环境
    deploy_docker_environment

    # 步骤3：容器内安装Magento
    install_magento_in_container

    # 完成提示
    echo -e "${GREEN}===== Magento部署完成！====="
    echo -e "后台地址: http://$MAGENTO_DOMAIN/admin"
    echo -e "管理员账号: $ADMIN_USER"
    echo -e "管理员密码: $ADMIN_PASSWORD${NC}"
}

# 启动主流程
main