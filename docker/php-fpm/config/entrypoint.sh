#!/bin/bash

# 启动cron服务
cron start

# 执行默认命令（php-fpm）
exec "$@"