#!/bin/bash
# Debian 12 显示IP + 标注优先 + 一键切换v4/v6优先

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 必须root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请用 sudo 运行！${NC}"
    exit 1
fi

GAI_FILE="/etc/gai.conf"
BACKUP_FILE="/etc/gai.conf.bak.default"

# 获取IP
CURRENT_IPV4=$(curl -s -4 ip.sb 2>/dev/null)
CURRENT_IPV6=$(curl -s -6 ip.sb 2>/dev/null)

# 判断当前优先使用的IP
USED_IP=$(curl -w "%{remote_ip}" -s -o /dev/null "https://www.cloudflare.com")
IS_V6=false
if [[ "$USED_IP" == *":"* ]]; then
    IS_V6=true
fi

# ====================== 显示 IP（直接在后面标注优先） ======================
echo -e "${BLUE}====================================================${NC}"
echo -e "${PURPLE}              当前公网 IP 信息${NC}"
echo -e "${BLUE}====================================================${NC}"

echo -n -e "${GREEN}IPv4：${NC}$CURRENT_IPV4"
if [ "$IS_V6" = false ]; then
    echo -e " ${YELLOW}[优先]${NC}"
else
    echo ""
fi

echo -n -e "${GREEN}IPv6：${NC}"
if [ -z "$CURRENT_IPV6" ]; then
    echo -n "无IPv6网络"
else
    echo -n "$CURRENT_IPV6"
fi
if [ "$IS_V6" = true ]; then
    echo -e " ${YELLOW}[优先]${NC}"
else
    echo ""
fi

echo -e "${BLUE}====================================================${NC}"
echo ""

# ====================== 切换菜单 ======================
echo -e "${YELLOW}1) IPv4 优先${NC}"
echo -e "${YELLOW}2) IPv6 优先${NC}"
echo -e "${YELLOW}3) 恢复系统默认配置${NC}"
echo -n "请选择 [1-3]："
read CHOICE

# 备份
backup_config() {
    [ ! -f "$BACKUP_FILE" ] && cp "$GAI_FILE" "$BACKUP_FILE"
}

# IPv4 优先
set_ipv4() {
    backup_config
    sed -i 's/^precedence ::ffff:0:0\/96  10/#precedence ::ffff:0:0\/96  10/g' "$GAI_FILE"
    sed -i 's/^precedence 2000::\/3    10/#precedence 2000::\/3    10/g' "$GAI_FILE"
    sed -i '/precedence ::ffff:0:0\/96  100/d' "$GAI_FILE"
    echo "precedence ::ffff:0:0/96  100" >> "$GAI_FILE"
    echo -e "${GREEN}✅ 已切换：IPv4 优先${NC}"
}

# IPv6 优先
set_ipv6() {
    backup_config
    sed -i '/precedence ::ffff:0:0\/96  100/d' "$GAI_FILE"
    sed -i 's/^#precedence ::ffff:0:0\/96  10/precedence ::ffff:0:0\/96  10/g' "$GAI_FILE"
    sed -i 's/^#precedence 2000::\/3    10/precedence 2000::\/3    10/g' "$GAI_FILE"
    echo -e "${GREEN}✅ 已切换：IPv6 优先${NC}"
}

# 恢复默认
restore_default() {
    [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$GAI_FILE"
    echo -e "${GREEN}✅ 已恢复系统默认配置${NC}"
}

case $CHOICE in
    1) set_ipv4 ;;
    2) set_ipv6 ;;
    3) restore_default ;;
    *) echo -e "${RED}❌ 无效选项${NC}" && exit 1 ;;
esac

echo -e "${BLUE}👉 配置立即生效，无需重启！${NC}"
