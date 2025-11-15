#!/bin/bash
set -e  # 任何命令失败立即退出

# ==================== 配置参数（请根据实际环境修改） ====================
MAGENTO_PATH="/opt/magento/source/store/magento"  # Magento安装目录
DOCKER_CONTAINER_NAME="magento-store"             # Magento容器名
DOCKER_MYSQL_NAME="magento-mysql"                 # MySQL容器名
DOCKER_MAGENTO_DIR="/var/www/store"               # 容器内Magento目录
TARGET_VERSION="2.4.6-p13"                        # 目标版本
BACKUP_DIR_BASE="/opt/magento/backups"            # 备份根目录
# ======================================================================

# 控制台颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 初始化路径
BACKUP_DIR="$BACKUP_DIR_BASE/upgrade_${TARGET_VERSION}_$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/tmp/magento_upgrade_${TARGET_VERSION}"
MYSQL_ROOT_USER="root"
MYSQL_ROOT_PASSWORD=""

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请用root用户运行（执行 'su -'）${NC}"
        exit 1
    fi
}

# 获取MySQL root密码
get_mysql_root_password() {
    echo -e "${GREEN}检测MySQL root密码...${NC}"
    if docker exec "$DOCKER_MYSQL_NAME" mysql -u"$MYSQL_ROOT_USER" -e "SELECT 1;" 2>/dev/null; then
        MYSQL_ROOT_PASSWORD=""
        echo -e "${YELLOW}MySQL root无密码登录成功${NC}"
        return 0
    fi
    for pwd in "root" "123456"; do
        if docker exec "$DOCKER_MYSQL_NAME" mysql -u"$MYSQL_ROOT_USER" -p"$pwd" -e "SELECT 1;" 2>/dev/null; then
            MYSQL_ROOT_PASSWORD="$pwd"
            echo -e "${YELLOW}使用默认密码登录成功${NC}"
            return 0
        fi
    done
    echo -e "${YELLOW}请输入MySQL root密码（若未设置直接回车）：${NC}"
    read -r input_pwd
    MYSQL_ROOT_PASSWORD="$input_pwd"
    if ! docker exec "$DOCKER_MYSQL_NAME" mysql -u"$MYSQL_ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" 2>/dev/null; then
        echo -e "${RED}错误：root密码不正确${NC}"
        exit 1
    fi
}

# 修复数据库凭据
fix_db_credentials() {
    echo -e "${GREEN}修复数据库凭据...${NC}"
    local sql_commands=""
    local user_exists
    user_exists=$(docker exec "$DOCKER_MYSQL_NAME" mysql -u"$MYSQL_ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -NBe "SELECT 1 FROM mysql.user WHERE User='$MYSQL_USER' AND Host='%'" 2>/dev/null)
    
    if [ "$user_exists" != "1" ]; then
        sql_commands+="CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'; "
        echo -e "${YELLOW}已创建用户 $MYSQL_USER@%${NC}"
    else
        sql_commands+="ALTER USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'; "
        echo -e "${YELLOW}已更新用户密码${NC}"
    fi

    sql_commands+="GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'%'; "
    sql_commands+="GRANT PROCESS ON *.* TO '$MYSQL_USER'@'%'; "
    sql_commands+="FLUSH PRIVILEGES; "

    if ! docker exec "$DOCKER_MYSQL_NAME" mysql -u"$MYSQL_ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -e "$sql_commands" 2>/dev/null; then
        echo -e "${RED}执行SQL命令失败${NC}"
        exit 1
    fi

    if docker exec "$DOCKER_MYSQL_NAME" mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" "$MYSQL_DATABASE" 2>/dev/null; then
        echo -e "${GREEN}数据库凭据修复成功${NC}"
    else
        echo -e "${RED}凭据修复后仍无法连接${NC}"
        exit 1
    fi
}

# 验证MySQL容器
verify_mysql_container() {
    echo -e "${GREEN}验证MySQL容器...${NC}"
    if ! docker ps -a --filter "name=$DOCKER_MYSQL_NAME" --format '{{.Names}}' | grep -q "$DOCKER_MYSQL_NAME"; then
        echo -e "${RED}错误：MySQL容器 $DOCKER_MYSQL_NAME 不存在${NC}"
        exit 1
    fi
    if ! docker ps --filter "name=$DOCKER_MYSQL_NAME" --format '{{.Names}}' | grep -q "$DOCKER_MYSQL_NAME"; then
        echo -e "${YELLOW}启动MySQL容器...${NC}"
        docker start "$DOCKER_MYSQL_NAME" || {
            echo -e "${RED}启动容器失败${NC}"
            exit 1
        }
        sleep 10
    fi
}

# 检查依赖
check_and_install_dependencies() {
    echo -e "${GREEN}检查依赖...${NC}"
    local dependencies=("curl" "tar" "docker" "docker-compose")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${YELLOW}安装 $dep...${NC}"
            case $dep in
                "docker") 
                    apt-get update -y && apt-get install -y ca-certificates curl gnupg lsb-release
                    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
                    apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io
                    usermod -aG docker $USER && newgrp docker
                    ;;
                "docker-compose") 
                    COMPOSE_VERSION="v2.24.1"
                    curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                    chmod +x /usr/local/bin/docker-compose && ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
                    ;;
                *) apt-get install -y "$dep" ;;
            esac
        fi
    done
}

# 检查Magento环境
check_magento_env() {
    echo -e "${GREEN}检查Magento环境...${NC}"
    if [ ! -d "$MAGENTO_PATH" ] || [ ! -f "$MAGENTO_PATH/composer.json" ]; then
        echo -e "${RED}错误：Magento目录无效${NC}"
        exit 1
    fi

    if ! docker ps --filter "name=$DOCKER_CONTAINER_NAME" --format '{{.Names}}' | grep -q "$DOCKER_CONTAINER_NAME"; then
        echo -e "${YELLOW}启动Magento容器...${NC}"
        docker start "$DOCKER_CONTAINER_NAME" || {
            echo -e "${RED}启动失败${NC}"
            exit 1
        }
        sleep 10
    fi

    ENV_FILE="$(dirname "$0")/../docker/.env"
    if [ -f "$ENV_FILE" ]; then
        echo -e "${GREEN}加载.env配置...${NC}"
        MYSQL_USER=$(grep MYSQL_USER "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
        MYSQL_PASSWORD=$(grep MYSQL_PASSWORD "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
        MYSQL_DATABASE=$(grep MYSQL_DATABASE "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
        MAGENTO_SHOPURI=$(grep MAGENTO_SHOPURI "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
    else
        echo -e "${YELLOW}使用默认数据库配置${NC}"
        MYSQL_USER="magento"
        MYSQL_PASSWORD="magento"
        MYSQL_DATABASE="magento"
        MAGENTO_SHOPURI="http://localhost"
    fi

    verify_mysql_container
    get_mysql_root_password
    if ! docker exec "$DOCKER_MYSQL_NAME" mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" "$MYSQL_DATABASE" 2>/dev/null; then
        echo -e "${YELLOW}数据库凭据无效，自动修复...${NC}"
        fix_db_credentials
    else
        echo -e "${GREEN}数据库凭据验证通过${NC}"
    fi
}

# 创建备份
create_backup() {
    echo -e "${GREEN}创建备份...${NC}"
    mkdir -p "$BACKUP_DIR" || {
        echo -e "${RED}创建备份目录失败${NC}"
        exit 1
    }

    echo -e "${YELLOW}备份文件系统...${NC}"
    mkdir -p "$BACKUP_DIR/magento_files"
    cp -r "$MAGENTO_PATH/app/etc" "$BACKUP_DIR/magento_files/" || echo -e "${YELLOW}警告：备份app/etc失败${NC}"
    cp -r "$MAGENTO_PATH/pub/media" "$BACKUP_DIR/magento_files/" || echo -e "${YELLOW}警告：备份pub/media失败${NC}"
    cp -r "$MAGENTO_PATH/app/code" "$BACKUP_DIR/magento_files/" || echo -e "${YELLOW}警告：备份app/code失败${NC}"
    cp -r "$MAGENTO_PATH/app/design" "$BACKUP_DIR/magento_files/" || echo -e "${YELLOW}警告：备份app/design失败${NC}"
    cp "$MAGENTO_PATH/composer.json" "$BACKUP_DIR/magento_files/" 2>/dev/null || true
    cp "$MAGENTO_PATH/composer.lock" "$BACKUP_DIR/magento_files/" 2>/dev/null || true

    echo -e "${YELLOW}备份数据库...${NC}"
    if ! docker exec "$DOCKER_MYSQL_NAME" mysqldump --no-tablespaces -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" > "$BACKUP_DIR/magento_db.sql" 2>/dev/null; then
        echo -e "${RED}数据库备份失败${NC}"
        exit 1
    fi

    echo -e "${GREEN}备份完成：$BACKUP_DIR${NC}"
}

# 下载源码（修复大小判断问题）
download_source() {
    echo -e "${GREEN}下载Magento $TARGET_VERSION 源码...${NC}"
    mkdir -p "$TEMP_DIR" || {
        echo -e "${RED}无法创建临时目录${NC}"
        exit 1
    }

    # 下载地址（增加多个代理备选）
    GITHUB_URL="https://github.com/magento/magento2/archive/refs/tags/$TARGET_VERSION.tar.gz"
    PROXY_URLS=(
        "https://gh-proxy.com/$GITHUB_URL"
        "https://mirror.ghproxy.com/$GITHUB_URL"
        "https://raw.githubusercontent.com.cnpmjs.org/$GITHUB_URL"  # 备选代理
        "$GITHUB_URL"  # 直接链接（最后尝试）
    )
    TAR_FILE="$TEMP_DIR/magento_$TARGET_VERSION.tar.gz"

    # 尝试多个代理下载（最多5次重试）
    download_success=0
    for proxy in "${PROXY_URLS[@]}"; do
        for i in {1..5}; do
            echo -e "${YELLOW}尝试从 $proxy 下载（第 $i 次）...${NC}"
            if curl -L --connect-timeout 60 --retry 3 "$proxy" -o "$TAR_FILE"; then
                download_success=1
                break 2  # 成功则退出双层循环
            fi
            sleep 5
        done
    done

    if [ $download_success -eq 0 ]; then
        echo -e "${RED}所有代理均下载失败，请手动下载：${NC}"
        echo -e "1. 下载地址：$GITHUB_URL"
        echo -e "2. 保存到：$TAR_FILE"
        echo -e "3. 下载完成后按回车继续"
        read -r  # 等待用户手动下载
    fi

    # 验证文件（改用解压验证，而非大小）
    echo -e "${GREEN}验证源码包...${NC}"
    if ! tar -tzf "$TAR_FILE" >/dev/null 2>&1; then
        echo -e "${RED}源码包损坏或不完整${NC}"
        exit 1
    fi

    # 解压源码
    echo -e "${GREEN}解压源码包...${NC}"
    tar -zxf "$TAR_FILE" -C "$TEMP_DIR" || {
        echo -e "${RED}解压失败${NC}"
        exit 1
    }

    SOURCE_DIR="$TEMP_DIR/magento2-$TARGET_VERSION"
    if [ ! -d "$SOURCE_DIR" ] || [ ! -f "$SOURCE_DIR/composer.json" ]; then
        echo -e "${RED}解压后目录无效${NC}"
        exit 1
    fi
    echo -e "${GREEN}源码下载和解压成功${NC}"
}

# 替换核心文件
replace_core_files() {
    echo -e "${GREEN}替换核心文件...${NC}"
    rm -rf "$MAGENTO_PATH/app/code/Magento" 2>/dev/null || true
    rm -rf "$MAGENTO_PATH/app/design/frontend/Magento" 2>/dev/null || true
    rm -rf "$MAGENTO_PATH/app/design/adminhtml/Magento" 2>/dev/null || true
    rm -rf "$MAGENTO_PATH/bin" 2>/dev/null || true
    rm -rf "$MAGENTO_PATH/lib" 2>/dev/null || true
    rm -rf "$MAGENTO_PATH/vendor/magento" 2>/dev/null || true
    cp -r "$SOURCE_DIR/app/code/Magento" "$MAGENTO_PATH/app/code/" || {
        echo -e "${RED}复制核心模块失败${NC}"
        exit 1
    }
    cp -r "$SOURCE_DIR/app/design/frontend/Magento" "$MAGENTO_PATH/app/design/frontend/" || {
        echo -e "${RED}复制前端主题失败${NC}"
        exit 1
    }
    cp -r "$SOURCE_DIR/app/design/adminhtml/Magento" "$MAGENTO_PATH/app/design/adminhtml/" || {
        echo -e "${RED}复制后台主题失败${NC}"
        exit 1
    }
    cp -r "$SOURCE_DIR/bin" "$MAGENTO_PATH/" || {
        echo -e "${RED}复制bin目录失败${NC}"
        exit 1
    }
    cp -r "$SOURCE_DIR/lib" "$MAGENTO_PATH/" || {
        echo -e "${RED}复制lib目录失败${NC}"
        exit 1
    }
    cp -f "$SOURCE_DIR/composer.json" "$MAGENTO_PATH/" || {
        echo -e "${RED}替换composer.json失败${NC}"
        exit 1
    }
    cp -f "$SOURCE_DIR/composer.lock" "$MAGENTO_PATH/" || {
        echo -e "${RED}替换composer.lock失败${NC}"
        exit 1
    }
}

# 恢复自定义数据
restore_custom_data() {
    echo -e "${GREEN}恢复自定义数据...${NC}"
    if [ -d "$BACKUP_DIR/magento_files/app/etc" ]; then
        rm -rf "$MAGENTO_PATH/app/etc"
        cp -r "$BACKUP_DIR/magento_files/app/etc" "$MAGENTO_PATH/" || {
            echo -e "${RED}恢复app/etc失败${NC}"
            exit 1
        }
    fi
    if [ -d "$BACKUP_DIR/magento_files/pub/media" ]; then
        rm -rf "$MAGENTO_PATH/pub/media"
        cp -r "$BACKUP_DIR/magento_files/pub/media" "$MAGENTO_PATH/pub/" || {
            echo -e "${YELLOW}警告：恢复pub/media失败${NC}"
        }
    fi
    if [ -d "$BACKUP_DIR/magento_files/app/code" ]; then
        cp -r "$BACKUP_DIR/magento_files/app/code/"* "$MAGENTO_PATH/app/code/" || {
            echo -e "${YELLOW}警告：恢复app/code失败${NC}"
        }
    fi
    if [ -d "$BACKUP_DIR/magento_files/app/design" ]; then
        cp -r "$BACKUP_DIR/magento_files/app/design/"* "$MAGENTO_PATH/app/design/" || {
            echo -e "${YELLOW}警告：恢复app/design失败${NC}"
        }
    fi
}

# 执行升级命令
run_upgrade_commands() {
    echo -e "${GREEN}执行升级命令...${NC}"
    docker exec -it "$DOCKER_CONTAINER_NAME" bash -c "
        cd $DOCKER_MAGENTO_DIR && \
        composer config -g repo.packagist composer https://packagist.phpcomposer.com && \
        composer install --no-interaction && \
        php -d memory_limit=-1 bin/magento maintenance:enable && \
        php -d memory_limit=-1 bin/magento setup:upgrade && \
        php -d memory_limit=-1 bin/magento setup:di:compile && \
        php -d memory_limit=-1 bin/magento setup:static-content:deploy -f && \
        php -d memory_limit=-1 bin/magento indexer:reindex && \
        php -d memory_limit=-1 bin/magento cache:clean && \
        php -d memory_limit=-1 bin/magento cache:flush && \
        php -d memory_limit=-1 bin/magento maintenance:disable
    " || {
        echo -e "${RED}升级命令执行失败${NC}"
        exit 1
    }
}

# 修复权限
fix_permissions() {
    echo -e "${GREEN}修复权限...${NC}"
    chown -R www-data:www-data "$MAGENTO_PATH" || {
        echo -e "${YELLOW}警告：修改所有者失败${NC}"
    }
    find "$MAGENTO_PATH" -type f -exec chmod 644 {} \; 2>/dev/null
    find "$MAGENTO_PATH" -type d -exec chmod 755 {} \; 2>/dev/null
    chmod -R 777 "$MAGENTO_PATH/var" "$MAGENTO_PATH/generated" "$MAGENTO_PATH/pub/media" "$MAGENTO_PATH/pub/static" 2>/dev/null
}

# 重启服务
restart_services() {
    echo -e "${GREEN}重启服务...${NC}"
    docker restart "$DOCKER_CONTAINER_NAME" || true
    docker restart magento-nginx || true
    docker restart magento-varnish || true
}

# 验证升级
verify_upgrade() {
    echo -e "${GREEN}验证升级...${NC}"
    local current_version
    current_version=$(docker exec "$DOCKER_CONTAINER_NAME" bash -c "cd $DOCKER_MAGENTO_DIR && php bin/magento --version | grep -oE '2\.4\.6-p13'")
    if [ "$current_version" != "$TARGET_VERSION" ]; then
        echo -e "${RED}版本验证失败${NC}"
        exit 1
    fi
    local frontend_check
    frontend_check=$(docker exec "$DOCKER_CONTAINER_NAME" curl -s -o /dev/null -w "%{http_code}" "$MAGENTO_SHOPURI")
    if [ "$frontend_check" -ne 200 ]; then
        echo -e "${YELLOW}警告：前台访问异常${NC}"
    else
        echo -e "${GREEN}前台访问正常${NC}"
    fi
}

# 清理临时文件
cleanup() {
    echo -e "${GREEN}清理临时文件...${NC}"
    rm -rf "$TEMP_DIR"
}

# 主流程
main() {
    check_root
    echo "
    ____             _     __  __           _       _   _             
   / __ \____ ______(_)___/ / / /___ ______(_)___  | | | |___  ___  ___
  / / / / __  / ___/ / __  / / / __  / ___/ / __ \ | | | / __|/ _ \/ __|
 / /_/ / /_/ / /  / / /_/ / / / /_/ / /  / / /_/ / | |_| \__ \  __/ (__ 
/_____/\__,_/_/  /_/\__,_/_/ /\__,_/_/  /_/ .___/  \___/|___/\___|\___/
                                        /_/                         
    "
    echo -ne "🔧 ${GREEN}即将升级到 $TARGET_VERSION，是否继续？(是/否): ${NC}"
    read -r response
    if [[ ! "$response" =~ ^(是|y|Y|yes|Yes)$ ]]; then
        echo -e "${RED}升级取消${NC}"
        exit 0
    fi

    check_and_install_dependencies
    check_magento_env
    create_backup
    download_source  # 修复后的下载逻辑
    replace_core_files
    restore_custom_data
    run_upgrade_commands
    fix_permissions
    restart_services
    verify_upgrade
    cleanup

    echo -e "
${GREEN}✅ 升级完成！${NC}
- 版本：$TARGET_VERSION
- 备份：$BACKUP_DIR
- 商店地址：$MAGENTO_SHOPURI
    "
}

main
