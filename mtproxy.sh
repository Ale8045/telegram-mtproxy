#!/usr/bin/env bash
set -e

NAME="mtproxy"
IMAGE="telegrammessenger/proxy:latest"
DATA_DIR="/opt/mtproxy"
CONF="$DATA_DIR/config.env"

red(){ echo -e "\033[31m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

check_root(){
  [ "$EUID" -ne 0 ] && red "请使用 root 运行" && exit 1
}

install_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    yellow "正在安装 Docker..."
    apt update
    apt install -y ca-certificates curl gnupg lsb-release
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
  fi
}

get_ip(){
  curl -4 -s https://api.ipify.org || curl -4 -s https://ifconfig.me
}

open_firewall(){
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$port"/tcp >/dev/null 2>&1 || true
  fi
}

install_mtproxy(){
  check_root
  install_docker

  read -rp "请输入端口 [默认 443]: " PORT
  PORT=${PORT:-443}

  SECRET=$(openssl rand -hex 16)
  IP=$(get_ip)

  mkdir -p "$DATA_DIR"

  cat > "$CONF" <<EOF
PORT=$PORT
SECRET=$SECRET
IP=$IP
EOF

  docker rm -f "$NAME" >/dev/null 2>&1 || true

  docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    -p "$PORT:443" \
    -e SECRET="$SECRET" \
    -v "$DATA_DIR/data:/data" \
    "$IMAGE"

  open_firewall "$PORT"

  green "MTProto 代理安装完成"
  echo
  show_link
}

show_link(){
  if [ ! -f "$CONF" ]; then
    red "还没有安装 MTProxy"
    return
  fi

  source "$CONF"
  IP_NOW=$(get_ip)
  [ -n "$IP_NOW" ] && IP="$IP_NOW"

  echo "服务器 IP: $IP"
  echo "端口: $PORT"
  echo "Secret: $SECRET"
  echo
  green "Telegram 内置代理链接："
  echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
  echo
  green "网页点击链接："
  echo "https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
}

status_mtproxy(){
  docker ps -a --filter "name=$NAME"
}

logs_mtproxy(){
  docker logs -f --tail=100 "$NAME"
}

restart_mtproxy(){
  docker restart "$NAME"
  green "已重启"
}

uninstall_mtproxy(){
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
  green "MTProxy 已删除"
}

menu(){
  clear
  echo "=============================="
  echo " Telegram MTProto 代理脚本"
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
