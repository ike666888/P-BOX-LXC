#!/bin/bash

# ================= 配置区域 =================
BACKUP_URL="https://github.com/ike666888/P-BOX-LXC/releases/download/v2.7.2/p-box-lxc.tar.zst"
# ===========================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}    P-Box 智能部署脚本 (v2.7.4)              ${NC}"
echo -e "${GREEN}=============================================${NC}"

# --- 0. 环境检测 (PVE vs 普通 Linux) ---
if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "${YELLOW}检测结果：当前环境不是 Proxmox VE (PVE)${NC}"
    echo -e "---------------------------------------------"
    echo -e "${GREEN}1.${NC} 安装 P-BOX 官方版 (适用于 Ubuntu/Debian/CentOS 等)"
    echo -e "${GREEN}2.${NC} 退出脚本"
    echo -e "---------------------------------------------"
    read -p "请输入选项 [1-2]: " CHOICE

    case $CHOICE in
        1)
            echo -e "\n${YELLOW}正在启动官方安装脚本...${NC}"
            curl -fsSL https://raw.githubusercontent.com/p-box2025/P-BOX/main/install.sh | sudo bash
            exit 0
            ;;
        *)
            echo -e "${GREEN}已退出。${NC}"
            exit 0
            ;;
    esac
fi

# ================= 以下是 PVE 专属逻辑 =================

echo -e "${GREEN}检测结果：当前环境为 Proxmox VE，即将开始部署旁路网关。${NC}"
sleep 2

# 1. 检查 & 开启 TUN
if [ ! -c /dev/net/tun ]; then
    echo -e "${YELLOW}正在加载 TUN 模块...${NC}"
    modprobe tun
fi
if [ ! -c /dev/net/tun ]; then
    echo -e "${RED}错误：无法加载 TUN 模块，请检查 PVE 内核。${NC}"
    exit 1
fi

# 2. 检查 & 开启 BBR
# 先尝试开启，后续会在结尾进行最终验证
if ! grep -q "tcp_congestion_control = bbr" /etc/sysctl.conf; then
    echo -e "${YELLOW}正在开启 BBR 加速...${NC}"
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

# 3. 网络环境检测
HOST_GW=$(ip route | grep default | awk '{print $3}')
SUBNET=$(echo $HOST_GW | cut -d'.' -f1-3)
echo -e "\n${YELLOW}网络环境检测：${NC} 检测到主路由 IP：${GREEN}${HOST_GW}${NC}"

# 4. 用户交互
while true; do
    read -p "请输入容器 ID [默认 200]: " CT_ID
    CT_ID=${CT_ID:-200}
    if pct status $CT_ID >/dev/null 2>&1; then
        echo -e "${RED}错误：ID $CT_ID 已存在，请换一个。${NC}"
    else
        break
    fi
done

read -p "请输入静态 IP [默认 ${SUBNET}.200]: " USER_IP
USER_IP=${USER_IP:-"${SUBNET}.200"}
if [[ "$USER_IP" != *"/"* ]]; then USER_IP="${USER_IP}/24"; fi

read -p "请输入网关 IP [默认 ${HOST_GW}]: " USER_GW
USER_GW=${USER_GW:-$HOST_GW}

# 5. 下载备份
BACKUP_FILE="/var/lib/vz/dump/p-box-import.tar.zst"
if [ -f "$BACKUP_FILE" ]; then rm -f "$BACKUP_FILE"; fi

echo -e "\n${YELLOW}正在下载系统镜像...${NC}"
wget -O "$BACKUP_FILE" "$BACKUP_URL" -q --show-progress
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查网络或 GitHub 连接。${NC}"
    rm -f "$BACKUP_FILE"
    exit 1
fi

# 6. 恢复容器
echo -e "\n${YELLOW}正在解压并恢复容器...${NC}"
pct restore $CT_ID "$BACKUP_FILE" --storage local-lvm --unprivileged 1 --force --unique >/dev/null 2>&1
RESTORE_STATUS=$?

if [ $RESTORE_STATUS -ne 0 ]; then
    echo -e "${YELLOW}未找到 local-lvm 存储，尝试使用 local 存储...${NC}"
    pct restore $CT_ID "$BACKUP_FILE" --storage local --unprivileged 1 --force --unique
    RESTORE_STATUS=$?
fi

# 恢复完成后立即删除备份文件 (无论成功失败都建议清理，但为了保险仅在逻辑后清理)
if [ -f "$BACKUP_FILE" ]; then
    rm -f "$BACKUP_FILE"
    echo -e "${GREEN} -> 已清理临时下载的备份文件。${NC}"
fi

if [ $RESTORE_STATUS -ne 0 ]; then
    echo -e "${RED}恢复失败，请检查 PVE 存储空间。${NC}"
    exit 1
fi

# 7. 系统配置
echo -e "${YELLOW}正在配置网络与权限...${NC}"
pct set $CT_ID -net0 name=eth0,bridge=vmbr0,ip=$USER_IP,gw=$USER_GW
pct set $CT_ID -features nesting=1
pct set $CT_ID -nameserver "223.5.5.5 1.1.1.1"

# 注入 TUN 权限
CONF_FILE="/etc/pve/lxc/$CT_ID.conf"
if ! grep -q "lxc.cgroup2.devices.allow" "$CONF_FILE"; then
cat <<EOF >> "$CONF_FILE"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
fi

# 8. 启动
echo -e "${YELLOW}正在启动容器...${NC}"
pct start $CT_ID
sleep 5
pct exec $CT_ID -- bash -c "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1"

# 9. 最终验证与展示
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [[ "$CURRENT_ALGO" == "bbr" ]]; then
    BBR_MSG="${GREEN}✅ 已开启 (BBR)${NC}"
else
    BBR_MSG="${RED}❌ 未开启 (当前: $CURRENT_ALGO)${NC}"
fi

REAL_IP=$(echo $USER_IP | cut -d'/' -f1)
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN} 🎉 安装成功！ ${NC}"
echo -e " BBR 状态:    ${BBR_MSG}"
echo -e " 管理面板:    ${YELLOW}http://${REAL_IP}:8383${NC}"
echo -e " Root 密码:   ${YELLOW}aa123123${NC}"
echo -e "${GREEN}=============================================${NC}"
