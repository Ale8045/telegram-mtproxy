#!/usr/bin/env bash

BASE_DIR="/opt/mtproxy"
NODE_DIR="$BASE_DIR/nodes"
BIN_PATH="/usr/local/bin/mtproxy-manager"
IMAGE="telegrammessenger/proxy:latest"

red(){ echo -e "\033[31m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

check_root(){
  [ "$EUID" -ne 0 ] && red "请使用 root 运行" && exit 1
}

get_ip(){
  curl -4 -s https://api.ipify.org || curl -4 -s https://ifconfig.me || hostname -I | awk '{print $1}'
}

fix_debian_sources(){
  [ ! -f /etc/debian_version ] && return
  VER=$(grep -oE '^[0-9]+' /etc/debian_version)

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

  rm -f /etc/apt/sources.list.d/xanmod*.list 2>/dev/null
}

install_base(){
  apt update || {
    yellow "APT 源异常，正在修复..."
    fix_debian_sources
    apt clean
    apt update
  }

  apt install -y curl ca-certificates openssl cron ufw
}

install_docker(){
  if command -v docker >/dev/null 2>&1; then
    green "Docker 已安装"
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
    return
  fi

  yellow "正在安装 Docker..."
  curl -fsSL https://get.docker.com | bash
  systemctl enable docker
  systemctl start docker
}

enable_bbr(){
  cat > /etc/sysctl.d/99-mtproxy-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1
}

open_firewall(){
  PORT="$1"
  ufw allow "$PORT"/tcp >/dev/null 2>&1
}

next_id(){
  mkdir -p "$NODE_DIR"
  if ls "$NODE_DIR"/node-*.conf >/dev/null 2>&1; then
    ls "$NODE_DIR"/node-*.conf | sed 's/.*node-\([0-9]*\).conf/\1/' | sort -n | tail -1 | awk '{print $1+1}'
  else
    echo 1
  fi
}

random_port(){
  while true; do
    P=$(shuf -i 20000-60000 -n 1)
    ss -lnt | awk '{print $4}' | grep -q ":$P$" || { echo "$P"; return; }
  done
}

to_bytes(){
  NUM=$(echo "$1" | grep -oE '^[0-9.]+')
  UNIT=$(echo "$1" | grep -oE '[A-Za-z]+$')

  awk -v n="$NUM" -v u="$UNIT" 'BEGIN{
    if(u=="B") m=1;
    else if(u=="kB"||u=="KB") m=1024;
    else if(u=="MB") m=1024*1024;
    else if(u=="GB") m=1024*1024*1024;
    else if(u=="TB") m=1024*1024*1024*1024;
    else m=1;
    printf "%.0f", n*m
  }'
}

container_traffic(){
  C="$1"
  NET=$(docker stats "$C" --no-stream --format "{{.NetIO}}" 2>/dev/null)
  [ -z "$NET" ] && echo 0 && return

  IN=$(echo "$NET" | awk -F' / ' '{print $1}')
  OUT=$(echo "$NET" | awk -F' / ' '{print $2}')

  INB=$(to_bytes "$IN")
  OUTB=$(to_bytes "$OUT")

  echo $((INB + OUTB))
}

install_cron(){
  mkdir -p "$BASE_DIR"
  if [ -f "$0" ]; then
    cp "$0" "$BIN_PATH"
    chmod +x "$BIN_PATH"
  fi

  systemctl enable cron >/dev/null 2>&1
  systemctl start cron >/dev/null 2>&1

  crontab -l 2>/dev/null | grep -v "mtproxy-manager --check" > /tmp/mtproxy_cron
  echo "*/5 * * * * bash $BIN_PATH --check >/dev/null 2>&1" >> /tmp/mtproxy_cron
  crontab /tmp/mtproxy_cron
  rm -f /tmp/mtproxy_cron
}

create_node(){
  check_root
  install_base
  install_docker
  enable_bbr
  install_cron

  ID=$(next_id)
  NAME="mtproxy-node-$ID"

  read -rp "端口：1 自动随机 / 2 手动输入 [默认 1]: " PORT_MODE
  PORT_MODE=${PORT_MODE:-1}

  if [ "$PORT_MODE" = "2" ]; then
    read -rp "请输入端口: " PORT
  else
    PORT=$(random_port)
  fi

  read -rp "到期天数 [默认 30]: " DAYS
  DAYS=${DAYS:-30}

  read -rp "流量限制 GB [默认 50]: " LIMIT_GB
  LIMIT_GB=${LIMIT_GB:-50}

  read -rp "频道 TAG，没有就回车: " TAG

  SECRET=$(openssl rand -hex 16)
  IP=$(get_ip)
  CREATED_AT=$(date +%s)
  EXPIRE_AT=$((CREATED_AT + DAYS * 86400))
  LIMIT_BYTES=$((LIMIT_GB * 1024 * 1024 * 1024))

  docker rm -f "$NAME" >/dev/null 2>&1

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

  mkdir -p "$NODE_DIR"

  cat > "$NODE_DIR/node-$ID.conf" <<EOF
ID=$ID
NAME=$NAME
PORT=$PORT
SECRET=$SECRET
IP=$IP
TAG=$TAG
CREATED_AT=$CREATED_AT
EXPIRE_AT=$EXPIRE_AT
LIMIT_GB=$LIMIT_GB
LIMIT_BYTES=$LIMIT_BYTES
USED_BYTES=0
LAST_BYTES=0
STATUS=active
EOF

  green "创建成功"
  echo
  show_node "$ID"
}

show_node(){
  ID="$1"
  FILE="$NODE_DIR/node-$ID.conf"

  [ ! -f "$FILE" ] && red "节点不存在" && return

  . "$FILE"
  IP_NOW=$(get_ip)
  [ -n "$IP_NOW" ] && IP="$IP_NOW"

  EXPIRE_DATE=$(date -d "@$EXPIRE_AT" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
  USED_GB=$(awk "BEGIN{printf \"%.2f\", $USED_BYTES/1024/1024/1024}")

  echo "ID: $ID"
  echo "端口: $PORT"
  echo "状态: $STATUS"
  echo "已用流量: ${USED_GB}GB / ${LIMIT_GB}GB"
  echo "到期时间: $EXPIRE_DATE"
  echo
  green "Telegram 链接："
  echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
  echo
  green "网页链接："
  echo "https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
}

list_nodes(){
  mkdir -p "$NODE_DIR"

  if ! ls "$NODE_DIR"/node-*.conf >/dev/null 2>&1; then
    red "暂无代理节点"
    return
  fi

  printf "%-5s %-18s %-8s %-10s %-12s %-20s\n" "ID" "容器" "端口" "状态" "流量GB" "到期时间"

  for FILE in "$NODE_DIR"/node-*.conf; do
    . "$FILE"
    EXPIRE_DATE=$(date -d "@$EXPIRE_AT" "+%Y-%m-%d")
    USED_GB_NOW=$(awk "BEGIN{printf \"%.2f\", $USED_BYTES/1024/1024/1024}")
    printf "%-5s %-18s %-8s %-10s %-12s %-20s\n" "$ID" "$NAME" "$PORT" "$STATUS" "$USED_GB_NOW/$LIMIT_GB" "$EXPIRE_DATE"
  done
}

delete_node(){
  read -rp "请输入要删除的节点 ID: " ID
  FILE="$NODE_DIR/node-$ID.conf"

  [ ! -f "$FILE" ] && red "节点不存在" && return

  . "$FILE"
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -f "$FILE"

  green "节点 $ID 已删除"
}

restart_node(){
  read -rp "请输入要重启的节点 ID: " ID
  FILE="$NODE_DIR/node-$ID.conf"

  [ ! -f "$FILE" ] && red "节点不存在" && return

  . "$FILE"
  docker restart "$NAME"
  green "节点 $ID 已重启"
}

check_nodes(){
  mkdir -p "$NODE_DIR"
  NOW=$(date +%s)

  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue

    . "$FILE"

    [ "$STATUS" != "active" ] && continue

    CURRENT_BYTES=$(container_traffic "$NAME")

    if [ "$CURRENT_BYTES" -ge "$LAST_BYTES" ]; then
      DELTA=$((CURRENT_BYTES - LAST_BYTES))
    else
      DELTA=$CURRENT_BYTES
    fi

    USED_BYTES=$((USED_BYTES + DELTA))
    LAST_BYTES=$CURRENT_BYTES

    if [ "$NOW" -ge "$EXPIRE_AT" ]; then
      docker rm -f "$NAME" >/dev/null 2>&1
      STATUS="expired"
    elif [ "$USED_BYTES" -ge "$LIMIT_BYTES" ]; then
      docker rm -f "$NAME" >/dev/null 2>&1
      STATUS="limited"
    fi

    cat > "$FILE" <<EOF
ID=$ID
NAME=$NAME
PORT=$PORT
SECRET=$SECRET
IP=$IP
TAG=$TAG
CREATED_AT=$CREATED_AT
EXPIRE_AT=$EXPIRE_AT
LIMIT_GB=$LIMIT_GB
LIMIT_BYTES=$LIMIT_BYTES
USED_BYTES=$USED_BYTES
LAST_BYTES=$LAST_BYTES
STATUS=$STATUS
EOF
  done
}

show_one_node(){
  read -rp "请输入节点 ID: " ID
  show_node "$ID"
}

menu(){
  clear
  echo "===================================="
  echo " Telegram MTProto 多节点管理脚本"
  echo "===================================="
  echo "1. 创建一条代理"
  echo "2. 查看所有代理"
  echo "3. 查看指定代理链接"
  echo "4. 删除指定代理"
  echo "5. 重启指定代理"
  echo "6. 手动检查到期/流量"
  echo "0. 退出"
  echo "===================================="
  read -rp "请选择: " num

  case "$num" in
    1) create_node ;;
    2) check_nodes; list_nodes ;;
    3) check_nodes; show_one_node ;;
    4) delete_node ;;
    5) restart_node ;;
    6) check_nodes; green "检查完成" ;;
    0) exit 0 ;;
    *) red "输入错误" ;;
  esac
}

if [ "$1" = "--check" ]; then
  check_nodes
  exit 0
fi

check_root

while true; do
  menu
  echo
  read -rp "按回车返回菜单..."
done
