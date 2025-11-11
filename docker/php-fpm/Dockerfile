FROM php:8.2-fpm

# 优化源配置：使用国内源并清理多余源文件
RUN set -eux; \
    DEBIAN_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2); \
    # 覆盖默认源文件（只保留国内源）
    echo "deb http://mirrors.huaweicloud.com/debian/ $DEBIAN_CODENAME main" > /etc/apt/sources.list; \
    echo "deb http://mirrors.huaweicloud.com/debian/ $DEBIAN_CODENAME-updates main" >> /etc/apt/sources.list; \
    echo "deb http://mirrors.huaweicloud.com/debian-security $DEBIAN_CODENAME-security main" >> /etc/apt/sources.list; \
    # 清理可能存在的其他源文件（避免干扰）
    rm -rf /etc/apt/sources.list.d/*; \
    # 更新源并安装依赖（增加超时参数，避免卡壳）
    apt-get update -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3; \
    apt-get install -y --no-install-recommends \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev \                    
        libzip-dev \
        libonig-dev \
        libicu-dev \
        libxml2-dev \
        libxslt1-dev \
        unzip \
        git \
        nano \
        cron; \
    # 后续的 php 扩展配置和安装（不变）
    docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp; \                 
    docker-php-ext-install \
        pdo \
        pdo_mysql \
        gd \
        zip \
        opcache \
        bcmath \
        intl \
        soap \
        xsl \
        sockets; \
    # 清理缓存（不变）
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# 直接从阿里云下载 composer.phar 并验证
RUN curl -sS --http1.1 -o /usr/local/bin/composer https://mirrors.aliyun.com/composer/composer.phar && \
    chmod +x /usr/local/bin/composer && \
    composer --version && \
    composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/

COPY ./config/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]