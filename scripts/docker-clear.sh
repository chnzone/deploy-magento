#!/bin/bash

# Cores para o Console
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

echo -ne "${GREEN}Deseja limpar toda a instalação do Docker? (s/n): ${NC}"
read response

if [[ ! "$response" =~ ^(s|S|sim|Sim|y|Y|yes|Yes)$ ]]; then
    echo -e "${RED}Operação cancelada pelo usuário.${NC}"
    exit 1
fi

echo -e "${YELLOW}⏸️  Pausando todos os containers...${NC}"
docker container pause $(docker ps -q)

echo -e "${RED}🗑️  Removendo todos os containers...${NC}"
docker container rm -f $(docker ps -aq)

echo -e "${RED}🧯 Removendo todas as imagens...${NC}"
docker image rm -f $(docker images -aq)

echo -e "${RED}🧹 Limpando volumes órfãos...${NC}"
docker volume prune -f

echo -e "${RED}📡 Limpando redes órfãs...${NC}"
docker network prune -f

echo -e "${RED}🗂️  Limpando builder cache...${NC}"
docker builder prune -af

echo -e "${GREEN}✅ Docker limpo com sucesso!${NC}"
