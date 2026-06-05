#!/usr/bin/env bash

NAME="mtproxy"
IMAGE="telegrammessenger/proxy:latest"
DATA_DIR="/opt/mtproxy"
CONF="$DATA_DIR/config.env"

red(){ echo -e "\033[31m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

check_root(){
  if [ "$EUID" -ne 0 ]; then
    red "请使用 root 运行"
    exit 1
  fi
}

get_ip(){
  curl -4 -s https://api.ipify.org || curl -4 -s https://ifconfig.me || hostname -I | awk '{print $1}'
}

fix_debian_sources(){
  if [ -f /etc/debian_version ]; then
    VER=$(grep -oE '^[0-9]+' /etc/debian_version || true)

    if [ "$VER" = "11" ]; then
      cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
    elif [ "$VER" = "12" ]; then
      cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
    fi

    rm -f /etc/apt/sources.list.d/xanmod*.list 2>/dev/null || true
  fi
}

install_base(){
  yellow "修复软件源并安装基础组件..."
  fix_debian_sources
  apt clean >/dev/null 2>&1 || true
  apt update
  apt install -y curl ca-certificates openssl ufw
}

install_docker(){
  if command -v docker >/dev/null 2>&1; then
    green "Docker 已安装"
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    return
  fi

  yellow "正在安装 Docker..."
  curl -fsSL https://get.docker.com | bash
  systemctl enable docker
  systemctl start docker
}

enable_bbr(){
  yellow "开启 BBR 加速..."
  cat > /etc/sysctl.d/99-mtproxy-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
}

open_firewall(){
  PORT="$1"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

install_mtproxy(){
  check_root
  install_base
  install_docker
  enable_bbr

  read -rp "请输入端口 [默认 443]: " PORT
  PORT=${PORT:-443}

  read -rp "请输入频道 TAG，没有就直接回车: " TAG

  SECRET=$(openssl rand -hex 16)
  IP=$(get_ip)

  mkdir -p "$DATA_DIR"

  cat > "$CONF" <<EOF
PORT=$PORT
SECRET=$SECRET
IP=$IP
TAG=$TAG
EOF

  docker rm -f "$NAME" >/dev/null 2>&1 || true

  yellow "正在启动 MTProxy..."

  if [ -n "$TAG" ]; then
    docker run -d \
      --name "$NAME" \
      --restart unless-stopped \
      -p "$PORT:443" \
      -e SECRET="$SECRET" \
      -e TAG="$TAG" \
      "$IMAGE"
  else
    docker run -d \
      --name "$NAME" \
      --restart unless-stopped \
      -p "$PORT:443" \
      -e SECRET="$SECRET" \
      "$IMAGE"
  fi

  open_firewall "$PORT"

  sleep 3

  green "MTProxy 安装完成"
  echo
  show_link
}

show_link(){
  if [ ! -f "$CONF" ]; then
    red "还没有安装 MTProxy"
    return
  fi

  . "$CONF"

  IP_NOW=$(get_ip)
  if [ -n "$IP_NOW" ]; then
    IP="$IP_NOW"
  fi

  echo "服务器 IP: $IP"
  echo "端口: $PORT"
  echo "Secret: $SECRET"
  if [ -n "$TAG" ]; then
    echo "频道 TAG: $TAG"
  fi
  echo
  green "Telegram 内置代理链接："
  echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
  echo
  green "网页点击链接："
  echo "https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
  echo
}

status_mtproxy(){
  docker ps -a --filter "name=$NAME"
}

logs_mtproxy(){
  docker logs -f --tail=100 "$NAME"
}

restart_mtproxy(){
  docker restart "$NAME"
  green "MTProxy 已重启"
}

uninstall_mtproxy(){
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
  green "MTProxy 已删除"
}

menu(){
  clear
  echo "=============================="
  echo " Telegram MTProto 官方代理脚本"
  echo "=============================="
  echo "1. 安装 / 重装 MTProxy"
  echo "2. 查看代理链接"
  echo "3. 查看运行状态"
  echo "4. 查看日志"
  echo "5. 重启 MTProxy"
  echo "6. 删除 MTProxy"
  echo "0. 退出"
  echo "=============================="
  read -rp "请选择: " num

  case "$num" in
    1) install_mtproxy ;;
    2) show_link ;;
    3) status_mtproxy ;;
    4) logs_mtproxy ;;
    5) restart_mtproxy ;;
    6) uninstall_mtproxy ;;
    0) exit 0 ;;
    *) red "输入错误" ;;
  esac
}

check_root

while true; do
  menu
  echo
  read -rp "按回车返回菜单..."
done
