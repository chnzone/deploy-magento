#!/bin/bash
set -e

# 确保脚本无论从哪个目录运行都能正常工作
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# 控制台颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "
   ____  _                      ____                _               
  / ___|| |  ___   __ _  _ __  |  _ \   ___    ___ | | __ ___  _ __ 
 | |    | | / _ \ / _  ||  __| | | | | / _ \  / __|| |/ // _ \| '__|
 | |___ | ||  __/| (_| || |    | |_| || (_) || (__ |   <|  __/| |   
  \____||_| \___| \__,_||_|    |____/  \___/  \___||_|\_\\___||_|
"

echo -ne "${GREEN}是否要清除所有Docker安装？(是/否): ${NC}"
read response

if [[ ! "$response" =~ ^(是|y|Y|yes|Yes)$ ]]; then
    echo -e "${RED}操作被用户取消。${NC}"
    exit 1
fi

# 停止特定于本项目的容器（如果运行）
echo -e "${YELLOW}⏸️  停止项目相关容器...${NC}"
docker compose -f "$PROJECT_ROOT/docker/docker-compose.shared.yml" down -v || true

echo -e "${YELLOW}⏸️  暂停所有其他容器...${NC}"
docker container pause $(docker ps -q) 2>/dev/null || true

echo -e "${RED}🗑️  移除所有容器...${NC}"
docker container rm -f $(docker ps -aq) 2>/dev/null || true

echo -e "${RED}🧯 移除项目相关镜像...${NC}"
docker image rm -f magento-php:8.4-custom 2>/dev/null || true

echo -e "${RED}🧯 移除其他未使用的镜像...${NC}"
docker image prune -af 2>/dev/null || true

echo -e "${RED}🧹 清理残留卷...${NC}"
docker volume prune -f 2>/dev/null || true

echo -e "${RED}📡 清理残留网络...${NC}"
docker network prune -f 2>/dev/null || true

echo -e "${RED}🗂️  清理构建缓存...${NC}"
docker builder prune -af 2>/dev/null || true

# 清理Magento源码目录（可选）
echo -ne "${YELLOW}是否也要清除Magento源码目录？(是/否): ${NC}"
read clean_source

if [[ "$clean_source" =~ ^(是|y|Y|yes|Yes)$ ]]; then
    MAGENTO_PATH="$PROJECT_ROOT/source/store/magento"
    if [ -d "$MAGENTO_PATH" ]; then
        echo -e "${RED}🗑️  清除Magento源码目录...${NC}"
        rm -rf "$MAGENTO_PATH"/*
    fi
fi

echo -e "${GREEN}✅ Docker环境已成功清理！${NC}"