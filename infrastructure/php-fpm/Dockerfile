FROM php:8.2-fpm

# Instala extensões PHP e dependências do sistema
RUN apt-get update && \
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
        cron && \
    docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp && \                 
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
        sockets && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Instala Composer
RUN curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer && \
    chmod +x /usr/local/bin/composer

# Customiza o entrypoint padrão para habilitar a execução simultânea do cron e do PHP-FPM
COPY ./config/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
