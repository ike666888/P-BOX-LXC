#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== PVE P-BOX 自动部署脚本 ===${NC}"

# 0. 检查依赖
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}正在安装 jq 用于解析 GitHub API...${NC}"
    apt-get update && apt-get install -y jq
fi

# 1. 基础配置检测
NEXT_ID=$(pvesh get /cluster/nextid)
VM_NAME="P-BOX"
STORAGE="local-lvm" # 默认导入磁盘的存储位置，如果你的PVE没有local-lvm，请改为local
ISO_PATH="/var/lib/vz/template/iso"

echo -e "检测到下一个可用 VM ID: ${GREEN}${NEXT_ID}${NC}"

# 2. CPU 交互配置
HOST_CPU_CORES=$(nproc)
echo -e "\n=== CPU 配置 ==="
echo -e "当前宿主机逻辑核心数: ${GREEN}${HOST_CPU_CORES}${NC}"
while true; do
    read -p "请输入分配给 P-BOX 的核心数 (1-${HOST_CPU_CORES}): " VM_CORES
    if [[ "$VM_CORES" =~ ^[0-9]+$ ]] && [ "$VM_CORES" -ge 1 ] && [ "$VM_CORES" -le "$HOST_CPU_CORES" ]; then
        break
    else
        echo -e "${RED}输入无效，请输入有效的核心数。${NC}"
    fi
done

# 3. 内存交互配置
HOST_MEM_TOTAL_GB=$(free -g | awk '/^Mem:/{print $2}')
echo -e "\n=== 内存 配置 ==="
echo -e "当前宿主机总内存: ${GREEN}${HOST_MEM_TOTAL_GB} GB${NC}"
while true; do
    read -p "请输入分配给 P-BOX 的内存大小 (单位: GB): " VM_MEM_GB
    if [[ "$VM_MEM_GB" =~ ^[0-9]+$ ]] && [ "$VM_MEM_GB" -ge 1 ]; then
        VM_MEM_MB=$((VM_MEM_GB * 1024))
        break
    else
        echo -e "${RED}输入无效，请输入整数 GB。${NC}"
    fi
done

# 4. 获取 GitHub 最新 Release 并下载
REPO="p-box2025/P-BOX-OS"
echo -e "\n=== 镜像下载 (GitHub Latest) ==="
echo -e "正在获取 ${REPO} 的最新版本信息..."

LATEST_RELEASE_URL=$(curl -s https://api.github.com/repos/${REPO}/releases/latest | jq -r '.assets[] | select(.name | endswith(".img.gz") or endswith(".img") or endswith(".iso")) | .browser_download_url' | head -n 1)

if [ -z "$LATEST_RELEASE_URL" ]; then
    echo -e "${RED}错误: 未能找到有效的 .img.gz, .img 或 .iso 下载链接。请检查网络或 GitHub API 限制。${NC}"
    exit 1
fi

FILENAME=$(basename "$LATEST_RELEASE_URL")
FILE_PATH="${ISO_PATH}/${FILENAME}"

echo -e "发现最新镜像: ${GREEN}${FILENAME}${NC}"
echo -e "下载地址: ${LATEST_RELEASE_URL}"

if [ -f "$FILE_PATH" ]; then
    echo -e "${YELLOW}文件已存在，跳过下载。${NC}"
else
    wget -q --show-progress -O "$FILE_PATH" "$LATEST_RELEASE_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败。${NC}"
        exit 1
    fi
fi

# 5. 解压镜像
# 判断文件类型并解压，最终目标是得到 .img 文件
FINAL_IMG_PATH=""
echo -e "\n=== 处理镜像文件 ==="

if [[ "$FILENAME" == *.gz ]]; then
    echo "正在解压 .gz 文件..."
    # 解压到同目录，去掉 .gz 后缀
    gunzip -k -f "$FILE_PATH"
    FINAL_IMG_PATH="${FILE_PATH%.gz}"
elif [[ "$FILENAME" == *.zip ]]; then
    echo "正在解压 .zip 文件..."
    unzip -o "$FILE_PATH" -d "$ISO_PATH"
    # 假设 zip 里只有一个 img，或者是同名 img
    FINAL_IMG_PATH=$(find "$ISO_PATH" -maxdepth 1 -name "*.img" -type f -newermt "$(date -d '1 minute ago' '+%H:%M')" | head -n 1)
else
    FINAL_IMG_PATH="$FILE_PATH"
fi

echo -e "准备使用的磁盘镜像: ${GREEN}${FINAL_IMG_PATH}${NC}"

# 6. 创建虚拟机
echo -e "\n=== 创建虚拟机 (ID: ${NEXT_ID}) ==="

# 创建基础配置：Q35, OVMF, 无介质, CPU host, 网络 virtio
qm create $NEXT_ID \
  --name "$VM_NAME" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 ${STORAGE}:0,pre-enrolled-keys=0 \
  --sockets 1 \
  --cores $VM_CORES \
  --cpu host \
  --memory $VM_MEM_MB \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci 

echo -e "${GREEN}虚拟机骨架创建完成。${NC}"

# 7. 导入磁盘并设置启动
echo -e "\n=== 导入磁盘镜像 ==="
# 导入磁盘
IMPORT_OUT=$(qm importdisk $NEXT_ID "$FINAL_IMG_PATH" $STORAGE --format raw)
echo "$IMPORT_OUT"

# 解析导入后的磁盘名称 (通常是 vm-ID-disk-1)
IMPORTED_DISK=$(echo "$IMPORT_OUT" | grep -o "vm-${NEXT_ID}-disk-[0-9]*")

if [ -n "$IMPORTED_DISK" ]; then
    echo -e "挂载磁盘 ${IMPORTED_DISK} 到 SCSI0..."
    # 挂载为 SCSI0 (SSD 仿真可选，这里用默认)
    qm set $NEXT_ID --scsi0 ${STORAGE}:${IMPORTED_DISK}
    
    # 设置启动顺序：优先从 scsi0 启动
    echo -e "设置启动顺序..."
    qm set $NEXT_ID --boot order=scsi0
else
    echo -e "${RED}错误: 无法获取导入后的磁盘名称，请手动检查。${NC}"
    exit 1
fi

# 8. 开机
echo -e "\n=== 正在启动虚拟机 ==="
qm start $NEXT_ID

echo -e "${GREEN}---------------------------------------------${NC}"
echo -e "${GREEN}部署完成！${NC}"
echo -e "虚拟机 ID: ${NEXT_ID}"
echo -e "IP 地址: 请进入控制台查看或等待 DHCP 分配"
echo -e "${GREEN}---------------------------------------------${NC}"
