## deploy-magento

This repository contains a Docker-based infrastructure to install and run a Magento 2 (Community Edition) instance in containers. The project organizes shared services (MySQL, Redis, Elasticsearch, RabbitMQ, Nginx, Varnish, and a PHP-FPM application container) and includes scripts and configuration to simplify Magento installation.

This README documents the repository purpose, prerequisites, how to configure environment variables, main docker-compose components, the installation script, and maintenance/troubleshooting tips.

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Repository structure](#repository-structure)
- [Configuration - Environment variables](#configuration---environment-variables)
- [How to use](#how-to-use)
	- [Initial preparation](#initial-preparation)
	- [Automatic installation (script)](#automatic-installation-script)
- [Services description](#services-description)
- [PHP-FPM Dockerfile summary](#php-fpm-dockerfile-summary)
- [Best practices and permissions](#best-practices-and-permissions)
- [Backups and persistence](#backups-and-persistence)

## Overview

The goal is to provide a local or development environment to run Magento 2 with common dependencies pre-configured in containers. The repository centralizes configuration for:

- MySQL database
- Cache and session (Redis)
- Search (Elasticsearch)
- Messaging (RabbitMQ)
- Reverse proxy / SSL / manager (Nginx Proxy Manager)
- Web server (Nginx)
- HTTP cache (Varnish)
- PHP application container (PHP-FPM) with Composer and entrypoint scripts

## Prerequisites

- Install [Docker](https://docs.docker.com/engine/install/)
- Suitable hardware (see Magento/Adobe recommended [hardware guidance](https://experienceleague.adobe.com/en/docs/commerce-operations/performance-best-practices/hardware))
- Internet access to pull images and Composer dependencies
- Inform your keys in `instance/store/magento/auth.json` obtained from Adobe

## Repository structure

- `infrastructure/docker-compose.shared.yml` - compose file for shared services
- `infrastructure/php-fpm/` - Dockerfile, configuration and entrypoint for the PHP-FPM container
- `infrastructure/nginx/` - Nginx configuration files
- `infrastructure/mysql/conf.d/` - custom MySQL configuration
- `instance/store/magento/` - Magento source code (from Magento project)
- `scripts/install.sh` - script that automates build, deploy and initial Magento installation

## Configuration - Environment variables

The project loads environment variables from a `.env` file (located at `infrastructure/.env`) when executed via the script. Expected variables include (but are not limited to):

- MYSQL_ROOT_PASSWORD, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD
- MAGENTO_HOST, MAGENTO_PORT
- LANGUAGE, CURRENCY, TIMEZONE
- RABBITMQ_DEFAULT_USER, RABBITMQ_DEFAULT_PASSWORD
- NGINX_PROXY_ADMIN_USER_EMAIL, NGINX_PROXY_MANAGER_ADMIN_PASSWORD
- MAGENTO_ADMIN_USER, MAGENTO_ADMIN_PASSWORD, MAGENTO_ADMIN_EMAIL, MAGENTO_FIRSTNAME, MAGENTO_LASTNAME

Note: if the file does not exist, create `infrastructure/.env` based on variables used in `docker-compose.shared.yml` and `scripts/install.sh`. Some variables have defaults defined in `docker-compose.shared.yml`.

## How to use

### Initial preparation

1. Copy/edit the environment file:

	 - Create `infrastructure/.env` and set required variables (MySQL password, Magento host/port to expose, admin credentials, etc.).

2. Ensure Magento source code is present at `instance/store/magento`. This repository includes the Magento structure (`composer.json` is present). If dependencies are not installed, the `install.sh` script will run `composer install` inside the container.

3. Adjust local file permissions if necessary (on Linux you might need to ensure your user has read/write access for the folders mounted as volumes).

### Automatic installation (script)

The main installation script is `scripts/install.sh`. It performs the following high-level steps:

- Loads variables from `infrastructure/.env`.
- Builds the custom PHP-FPM image defined in `infrastructure/php-fpm/Dockerfile` (tag `magento-php:8.4-custom`).
- Brings up the shared services with `docker compose -f infrastructure/docker-compose.shared.yml up -d`.
- Executes inside the `magento-store` container the commands: `composer install`, `bin/magento setup:install` with parameters from `.env`, configures Redis/RabbitMQ, runs `setup:upgrade`, `di:compile`, `static-content:deploy`, reindexes, clears caches and creates the admin user.
- Adjusts ownership and permissions on Magento files (chown, chmod) and restarts Nginx and Varnish.

To use the script:

1. Make the script executable (if needed):

```bash
chmod +x scripts/install.sh
```

2. Run it:

```bash
./scripts/install.sh
```

The script will ask for confirmation before proceeding.

## Services description

- mysql: official `mysql:8.0` image. Database persisted under `infrastructure/mysql/data`.
- nginx: nginx mainline with custom configuration in `infrastructure/nginx`.
- redis: used for session and cache (image `redis:6.2-alpine`).
- elasticsearch: search service (image `docker.elastic.co/elasticsearch/elasticsearch:7.17.9`).
- rabbitmq: messaging (image `rabbitmq:3-management`) with management UI on port 15672.
- varnish: HTTP cache, mapped to host port 80 and using `infrastructure/varnish/default.vcl`.
- nginx-proxy: Nginx Proxy Manager to manage hosts and certificates (ports 81/443 mapped locally).
- store: built from `infrastructure/php-fpm`, mounts Magento code into `/var/www/store` and acts as the application container.

Each service is attached to the `magento-net` (bridge) network and many mount local volumes for persistence.

## PHP-FPM Dockerfile summary

The Dockerfile at `infrastructure/php-fpm/Dockerfile` uses `php:8.2-fpm` as a base and installs PHP extensions and system dependencies required to run Magento 2, such as `pdo_mysql`, `gd`, `zip`, `opcache`, `bcmath`, `intl`, `soap`, and more. It also installs Composer and copies an `entrypoint.sh` to manage cron and PHP-FPM.

Important: the build step in `scripts/install.sh` references this Dockerfile and creates the image `magento-php:8.4-custom`.

## Best practices and permissions

- The `install.sh` script sets `www-data:www-data` ownership for Magento files and applies `644`/`755` for files/directories respectively. On local development environments you may prefer to set ownership to your user to avoid permission issues when editing files on the host.
- Do not use default passwords in production. Configure TLS certificates and production-grade settings in Nginx/Proxy and limit exposed ports.

## Backups and persistence

- MySQL data lives under `infrastructure/mysql/data` (local volume). Regularly back up the database using `mysqldump` or snapshot tools; prefer logical dumps (`mysqldump`) for consistency.
- Elasticsearch, Redis and other services also have local data; adapt snapshot and backup routines as needed for your environment.
