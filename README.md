## deploy-magento

本仓库包含一个基于Docker的部署方案，用于在容器中安装和运行Magento 2（社区版）。该项目组织了共享服务（MySQL、Redis、Elasticsearch、RabbitMQ、Nginx、Varnish和PHP-FPM应用容器），并包含bash脚本和配置以简化Magento安装。

本README文档说明了仓库的用途、先决条件、如何配置环境变量、主要的docker-compose组件、安装脚本以及维护/故障排除提示。

## 目录

- [概述](#概述)
- [先决条件](#先决条件)
- [仓库结构](#仓库结构)
- [配置 - 环境变量](#配置---环境变量)
- [使用方法](#使用方法)
  - [初始准备](#初始准备)
  - [自动安装（脚本）](#自动安装脚本)
- [服务说明](#服务说明)
- [PHP-FPM Dockerfile摘要](#php-fpm-dockerfile摘要)
- [最佳实践和权限](#最佳实践和权限)
- [备份和持久化](#备份和持久化)

## 概述

目标是提供一个本地或开发环境，通过预配置的容器运行Magento 2。该仓库集中配置了：

- MySQL数据库
- 缓存和会话（Redis）
- 搜索（Elasticsearch）
- 消息队列（RabbitMQ）
- 反向代理/SSL/管理器（Nginx Proxy Manager）
- Web服务器（Nginx）
- HTTP缓存（Varnish）
- PHP应用容器（PHP-FPM），带有Composer和入口点bash脚本

## 先决条件

- 安装[Docker](https://docs.docker.com/engine/install/)
- 合适的硬件（参见Magento/Adobe推荐的[硬件指南](https://experienceleague.adobe.com/en/docs/commerce-operations/performance-best-practices/hardware)）
- 互联网访问，用于拉取镜像和Composer依赖
- 在`source/store/magento/auth.json`中填入从Adobe获取的密钥

## 仓库结构

- `docker/docker-compose.shared.yml` - 共享服务的compose文件
- `docker/php-fpm/` - PHP-FPM容器的Dockerfile、配置和入口点
- `docker/nginx/` - Nginx配置文件
- `docker/mysql/conf.d/` - 自定义MySQL配置
- `source/store/magento/` - Magento源代码（来自Magento项目）
- `bash/install.sh` - 自动化构建、部署和初始Magento安装的脚本

## 配置 - 环境变量

通过脚本执行时，项目从`.env`文件（位于`docker/.env`）加载环境变量。预期的变量包括（但不限于）：

- MYSQL_ROOT_PASSWORD, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD
- MAGENTO_HOST, MAGENTO_PORT
- LANGUAGE, CURRENCY, TIMEZONE
- RABBITMQ_DEFAULT_USER, RABBITMQ_DEFAULT_PASSWORD
- NGINX_PROXY_ADMIN_USER_EMAIL, NGINX_PROXY_MANAGER_ADMIN_PASSWORD
- MAGENTO_ADMIN_USER, MAGENTO_ADMIN_PASSWORD, MAGENTO_ADMIN_EMAIL, MAGENTO_FIRSTNAME, MAGENTO_LASTNAME

注意：如果该文件不存在，请根据`docker-compose.shared.yml`和`bash/install.sh`中使用的变量创建`docker/.env`。有些变量在`docker-compose.shared.yml`中定义了默认值。

## 使用方法

### 初始准备

1. 复制/编辑环境文件：

   - 创建`docker/.env`并设置必要的变量（MySQL密码、要暴露的Magento主机/端口、管理员凭据等）。

2. 确保Magento源代码存在于`source/store/magento`。本仓库包含Magento结构（`composer.json`已存在）。如果依赖未安装，`install.sh`脚本将在容器内运行`composer install`。

3. 必要时调整本地文件权限（在Linux上，您可能需要确保您的用户对挂载为卷的文件夹有读写权限）。

### 自动安装（脚本）

主要的安装脚本是`bash/install.sh`。它执行以下高级步骤：

- 从`docker/.env`加载变量。
- 构建在`docker/php-fpm/Dockerfile`中定义的自定义PHP-FPM镜像（标签`magento-php:8.4-custom`）。
- 使用`docker compose -f docker/docker-compose.shared.yml up -d`启动共享服务。
- 在`magento-store`容器内执行命令：`composer install`、带有`.env`中参数的`bin/magento setup:install`、配置Redis/RabbitMQ、运行`setup:upgrade`、`di:compile`、`static-content:deploy`、重新索引、清除缓存并创建管理员用户。
- 调整Magento文件的所有权和权限（chown、chmod）并重启Nginx和Varnish。

使用脚本：

1. 使脚本可执行（如果需要）：

```bash
chmod +x bash/install.sh