#!/usr/bin/env bash

BASE_DIR="/opt/mtproxy"
NODE_DIR="$BASE_DIR/nodes"
EXPORT_DIR="$BASE_DIR/exports"
BACKUP_DIR="$BASE_DIR/backups"
BIN_PATH="/usr/local/bin/mtproxy-manager"
IMAGE="${MTPROXY_IMAGE:-telegrammessenger/proxy:latest}"
IMAGE_REF_FILE="$BASE_DIR/image.ref"
VERSION="v3.4.0-reliability"
SCRIPT_URL="https://raw.githubusercontent.com/Ale8045/telegram-mtproxy/main/mtproxy.sh"

red(){ echo -e "\033[31m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
blue(){ echo -e "\033[36m$1\033[0m"; }

pause(){
  echo
  read -rp "按回车返回菜单..."
}

check_root(){
  if [ "$EUID" -ne 0 ]; then
    red "请使用 root 运行"
    exit 1
  fi
}

safe_value(){
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

get_ip(){
  curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org \
    || curl -4 -fsS --connect-timeout 5 --max-time 10 https://ifconfig.me \
    || hostname -I | awk '{print $1}'
}

ensure_dirs(){
  mkdir -p "$BASE_DIR" "$NODE_DIR" "$EXPORT_DIR" "$BACKUP_DIR"
  chmod 700 "$BASE_DIR" "$NODE_DIR" "$EXPORT_DIR" "$BACKUP_DIR" 2>/dev/null || true
}

cleanup_old_exports(){
  mkdir -p "$EXPORT_DIR"
  find "$EXPORT_DIR" -type f -mtime +7 -delete >/dev/null 2>&1 || true
}


file_id_from_path(){
  basename "$1" | sed 's/node-\([0-9]*\).conf/\1/'
}

node_file(){
  echo "$NODE_DIR/node-$1.conf"
}

install_base(){
  ensure_dirs

  yellow "正在检查系统依赖..."

  if ! timeout 180 apt update; then
    red "APT 更新失败。为避免破坏现有软件源，脚本不会修改 /etc/apt/sources.list。"
    yellow "请修复服务器的软件源或网络后再运行脚本。"
    exit 1
  fi

  timeout 300 apt install -y curl ca-certificates openssl cron ufw iproute2 coreutils || {
    red "基础依赖安装失败，请检查 APT 源或网络。"
    exit 1
  }
}

install_docker(){
  if command -v docker >/dev/null 2>&1; then
    green "Docker 已安装：$(docker -v 2>/dev/null)"
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    return
  fi

  yellow "未检测到 Docker，开始安装..."
  yellow "如果服务器网络较慢，最多等待 5 分钟，不会无限卡住。"

  if command -v apt >/dev/null 2>&1; then
    yellow "正在尝试使用系统源安装 docker.io..."

    if timeout 300 bash -c 'DEBIAN_FRONTEND=noninteractive apt install -y docker.io >/tmp/mtproxy_docker_install.log 2>&1'; then
      systemctl enable docker >/dev/null 2>&1 || true
      systemctl start docker >/dev/null 2>&1 || true

      if command -v docker >/dev/null 2>&1; then
        green "Docker 安装成功：$(docker -v 2>/dev/null)"
        return
      fi
    else
      yellow "系统源安装 Docker 失败或超时，准备尝试官方安装脚本..."
    fi
  fi

  yellow "正在使用 Docker 官方脚本安装..."
  if timeout 300 bash -c 'curl -fsSL https://get.docker.com | bash >/tmp/mtproxy_docker_install.log 2>&1'; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true

    if command -v docker >/dev/null 2>&1; then
      green "Docker 安装成功：$(docker -v 2>/dev/null)"
      return
    fi
  fi

  red "Docker 安装失败或超时。"
  yellow "你可以查看日志："
  echo "cat /tmp/mtproxy_docker_install.log"
  echo
  yellow "也可以手动执行下面命令安装 Docker："
  echo "apt update && apt install -y docker.io"
  echo "systemctl enable docker && systemctl start docker"
  echo
  red "Docker 安装完成后，请重新运行脚本。"
  exit 1
}

enable_bbr(){
  cat > /etc/sysctl.d/99-mtproxy-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
}

open_firewall(){
  PORT="$1"
  ufw allow "$PORT"/tcp >/dev/null 2>&1 || true

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

is_positive_integer(){
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_number(){
  [[ "$1" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]
}

install_manager_script(){
  local tmp_file source_file
  tmp_file=$(mktemp /tmp/mtproxy-manager.XXXXXX) || return 1

  if [ -f "./mtproxy.sh" ] && grep -q "MTProxy Enterprise Manager" "./mtproxy.sh" 2>/dev/null; then
    source_file="./mtproxy.sh"
    cp "$source_file" "$tmp_file"
  else
    curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 "$SCRIPT_URL" -o "$tmp_file" || {
      rm -f "$tmp_file"
      return 1
    }
  fi

  sed -i 's/\r$//' "$tmp_file"
  if ! grep -q "MTProxy Enterprise Manager" "$tmp_file" || ! bash -n "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  install -m 0755 "$tmp_file" "$BIN_PATH"
  rm -f "$tmp_file"
}


auto_install_shortcut(){
  ensure_dirs
  mkdir -p /usr/local/bin

  install_manager_script || return

  if [ -s "$BIN_PATH" ] && grep -q "MTProxy Enterprise Manager" "$BIN_PATH" 2>/dev/null; then
    chmod +x "$BIN_PATH" 2>/dev/null || true
    ln -sf "$BIN_PATH" /usr/local/bin/mtp 2>/dev/null || true
    chmod +x /usr/local/bin/mtp 2>/dev/null || true
  fi
}

install_cron(){
  ensure_dirs
  mkdir -p /usr/local/bin

  install_manager_script || {
    red "安装管理脚本失败，当前版本未被覆盖。"
    return 1
  }

  chmod +x "$BIN_PATH"
  ln -sf "$BIN_PATH" /usr/local/bin/mtp
  chmod +x /usr/local/bin/mtp

  systemctl enable cron >/dev/null 2>&1 || true
  systemctl start cron >/dev/null 2>&1 || true

  crontab -l 2>/dev/null | grep -v "mtproxy-manager --check" > /tmp/mtproxy_cron || true
  echo "*/5 * * * * bash $BIN_PATH --check >/dev/null 2>&1" >> /tmp/mtproxy_cron
  crontab /tmp/mtproxy_cron
  rm -f /tmp/mtproxy_cron
}

prepare_env(){
  check_root
  install_base
  install_docker
  enable_bbr
  install_cron
}

next_id(){
  ensure_dirs
  if ls "$NODE_DIR"/node-*.conf >/dev/null 2>&1; then
    ls "$NODE_DIR"/node-*.conf | sed 's/.*node-\([0-9]*\).conf/\1/' | sort -n | tail -1 | awk '{print $1+1}'
  else
    echo 1
  fi
}

port_in_use(){
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$1$"
}

random_port(){
  while true; do
    P=$(shuf -i 20000-60000 -n 1)
    port_in_use "$P" || { echo "$P"; return; }
  done
}

normalize_status(){
  case "$1" in
    active|ACTIVE) echo "ACTIVE" ;;
    expired|EXPIRED) echo "EXPIRED" ;;
    limited|LIMITED) echo "LIMITED" ;;
    manual|MANUAL|stopped|STOPPED) echo "MANUAL" ;;
    *) echo "ACTIVE" ;;
  esac
}

status_cn(){
  case "$1" in
    ACTIVE) echo "在线" ;;
    EXPIRED) echo "到期暂停" ;;
    LIMITED) echo "流量暂停" ;;
    MANUAL) echo "手动暂停" ;;
    *) echo "$1" ;;
  esac
}

to_bytes(){
  RAW="$1"
  NUM=$(echo "$RAW" | grep -oE '^[0-9.]+')
  UNIT=$(echo "$RAW" | grep -oE '[A-Za-z]+$')

  [ -z "$NUM" ] && echo 0 && return

  awk -v n="$NUM" -v u="$UNIT" 'BEGIN{
    if(u=="B") m=1;
    else if(u=="kB"||u=="KB"||u=="KiB") m=1024;
    else if(u=="MB"||u=="MiB") m=1024*1024;
    else if(u=="GB"||u=="GiB") m=1024*1024*1024;
    else if(u=="TB"||u=="TiB") m=1024*1024*1024*1024;
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

gb_to_bytes(){
  GB="$1"
  awk -v g="$GB" 'BEGIN{printf "%.0f", g*1024*1024*1024}'
}

bytes_to_gb(){
  B="${1:-0}"
  awk -v b="$B" 'BEGIN{printf "%.2f", b/1024/1024/1024}'
}

days_left(){
  EXPIRE="$1"
  NOW=$(date +%s)
  LEFT=$(( (EXPIRE - NOW) / 86400 ))
  if [ "$LEFT" -lt 0 ]; then
    echo 0
  else
    echo "$LEFT"
  fi
}

format_date(){
  date -d "@$1" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "-"
}

load_node(){
  REQ_ID="$1"
  FILE=$(node_file "$REQ_ID")
  [ ! -f "$FILE" ] && red "节点不存在" && return 1

  . "$FILE"

  # 核心修复：永远以用户输入的节点ID为准
  ID="$REQ_ID"
  NAME="mtproxy-node-$REQ_ID"

  CUSTOMER="${CUSTOMER:-未填写}"
  TG_USER="${TG_USER:-未填写}"
  REMARK="${REMARK:-}"
  TAG="${TAG:-}"
  STATUS=$(normalize_status "${STATUS:-ACTIVE}")
  USED_BYTES="${USED_BYTES:-0}"
  LAST_BYTES="${LAST_BYTES:-0}"
  LIMIT_GB="${LIMIT_GB:-50}"
  LIMIT_BYTES="${LIMIT_BYTES:-$(gb_to_bytes "$LIMIT_GB")}"
  CREATED_AT="${CREATED_AT:-$(date +%s)}"
  EXPIRE_AT="${EXPIRE_AT:-$((CREATED_AT + 30*86400))}"
  IP="${IP:-$(get_ip)}"
  return 0
}

save_node(){
  ensure_dirs
  FILE=$(node_file "$ID")

  CUSTOMER_ESC=$(safe_value "${CUSTOMER:-未填写}")
  TG_USER_ESC=$(safe_value "${TG_USER:-未填写}")
  REMARK_ESC=$(safe_value "${REMARK:-}")
  TAG_ESC=$(safe_value "${TAG:-}")

  cat > "$FILE" <<EOF
ID=$ID
NAME="$NAME"
CUSTOMER="$CUSTOMER_ESC"
TG_USER="$TG_USER_ESC"
REMARK="$REMARK_ESC"
PORT=$PORT
SECRET="$SECRET"
IP="$IP"
TAG="$TAG_ESC"
CREATED_AT=$CREATED_AT
EXPIRE_AT=$EXPIRE_AT
LIMIT_GB=$LIMIT_GB
LIMIT_BYTES=$LIMIT_BYTES
USED_BYTES=$USED_BYTES
LAST_BYTES=$LAST_BYTES
STATUS=$STATUS
EOF
  chmod 600 "$FILE"
}

proxy_link(){
  IP_NOW=$(get_ip)
  [ -n "$IP_NOW" ] && IP="$IP_NOW"
  echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
}

web_link(){
  IP_NOW=$(get_ip)
  [ -n "$IP_NOW" ] && IP="$IP_NOW"
  echo "https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
}

resolve_image(){
  # 首次部署后固定到镜像摘要，避免 latest 在无提示情况下发生变化。
  if [ -z "${MTPROXY_IMAGE:-}" ] && [ -s "$IMAGE_REF_FILE" ]; then
    IMAGE=$(cat "$IMAGE_REF_FILE")
    return 0
  fi

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker pull "$IMAGE" || return 1
  fi

  if [ -z "${MTPROXY_IMAGE:-}" ]; then
    local digest
    digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)
    if [ -n "$digest" ]; then
      printf '%s\n' "$digest" > "$IMAGE_REF_FILE"
      chmod 600 "$IMAGE_REF_FILE"
      IMAGE="$digest"
    fi
  fi
}

run_container(){
  resolve_image || {
    red "无法获取 MTProxy Docker 镜像：$IMAGE"
    return 1
  }
  docker rm -f "$NAME" >/dev/null 2>&1 || true

  if [ -n "$TAG" ]; then
    docker run -d \
      --name "$NAME" \
      --restart unless-stopped \
      --memory="${MTPROXY_MEMORY_LIMIT:-256m}" \
      --cpus="${MTPROXY_CPU_LIMIT:-1.0}" \
      --pids-limit=256 \
      --log-opt max-size=10m \
      --log-opt max-file=3 \
      -p "$PORT:443" \
      -e SECRET="$SECRET" \
      -e TAG="$TAG" \
      "$IMAGE"
  else
    docker run -d \
      --name "$NAME" \
      --restart unless-stopped \
      --memory="${MTPROXY_MEMORY_LIMIT:-256m}" \
      --cpus="${MTPROXY_CPU_LIMIT:-1.0}" \
      --pids-limit=256 \
      --log-opt max-size=10m \
      --log-opt max-file=3 \
      -p "$PORT:443" \
      -e SECRET="$SECRET" \
      "$IMAGE"
  fi

  docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -qx true
}

create_node_core(){
  ID="$1"
  NAME="mtproxy-node-$ID"

  if [ "$PORT_MODE" = "2" ]; then
    PORT="$MANUAL_PORT"
  else
    PORT=$(random_port)
  fi

  while port_in_use "$PORT"; do
    yellow "端口 $PORT 已被占用"
    read -rp "请重新输入端口，直接回车自动随机: " NEW_PORT
    if [ -z "$NEW_PORT" ]; then
      PORT=$(random_port)
      break
    else
      PORT="$NEW_PORT"
    fi
  done

  SECRET=$(openssl rand -hex 16)
  IP=$(get_ip)
  CREATED_AT=$(date +%s)
  EXPIRE_AT=$((CREATED_AT + DAYS * 86400))
  LIMIT_BYTES=$(gb_to_bytes "$LIMIT_GB")
  USED_BYTES=0
  LAST_BYTES=0
  STATUS="ACTIVE"

  if ! run_container; then
    red "容器启动失败，未保存节点配置。请执行：docker logs $NAME"
    return 1
  fi
  open_firewall "$PORT"
  save_node
}

create_node(){
  prepare_env

  ID=$(next_id)

  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "创建代理节点 - 第 1 步：客户信息"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -rp "客户名称: " CUSTOMER
  CUSTOMER=${CUSTOMER:-未填写}

  read -rp "TG账号: " TG_USER
  TG_USER=${TG_USER:-未填写}

  read -rp "节点备注: " REMARK

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "创建代理节点 - 第 2 步：端口设置"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "1. 自动随机端口"
  echo "2. 手动输入端口"
  read -rp "请选择 [默认 1]: " PORT_MODE
  PORT_MODE=${PORT_MODE:-1}

  if [ "$PORT_MODE" = "2" ]; then
    while true; do
      read -rp "请输入端口: " MANUAL_PORT
      if [ -z "$MANUAL_PORT" ]; then
        red "端口不能为空"
        continue
      fi
      if ! echo "$MANUAL_PORT" | grep -Eq '^[0-9]+$'; then
        red "端口必须是数字"
        continue
      fi
      if [ "$MANUAL_PORT" -lt 1 ] || [ "$MANUAL_PORT" -gt 65535 ]; then
        red "端口范围必须是 1-65535"
        continue
      fi
      if port_in_use "$MANUAL_PORT"; then
        yellow "端口 $MANUAL_PORT 已被占用，请重新输入"
        continue
      fi
      break
    done
    PORT_PREVIEW="$MANUAL_PORT"
  else
    PORT_PREVIEW="自动随机"
  fi

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "创建代理节点 - 第 3 步：套餐信息"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -rp "到期天数 [默认 30]: " DAYS
  DAYS=${DAYS:-30}
  if ! is_positive_integer "$DAYS"; then
    red "到期天数必须是正整数"
    return
  fi

  read -rp "流量限制 GB [默认 50]: " LIMIT_GB
  LIMIT_GB=${LIMIT_GB:-50}
  if ! is_nonnegative_number "$LIMIT_GB"; then
    red "流量限制必须是非负数字"
    return
  fi

  TAG=""

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "创建代理节点 - 第 4 步：确认创建"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "客户名称: $CUSTOMER"
  echo "TG账号: $TG_USER"
  echo "备注: $REMARK"
  echo "端口: $PORT_PREVIEW"
  echo "到期天数: $DAYS 天"
  echo "流量限制: ${LIMIT_GB}GB"
  echo "频道 TAG: 暂未设置，创建成功后可用 22 设置"
  echo
  read -rp "确认创建？输入 y 继续: " CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    yellow "已取消创建"
    return
  fi

  create_node_core "$ID"

  green "创建成功"
  echo
  show_node "$ID"
  echo
  yellow "下一步去 MTProxy Admin Bot 注册："
  echo "1. 给 Bot 发送："
  echo "$IP:$PORT"
  echo
  echo "2. Bot 问 Secret 时，发送："
  echo "$SECRET"
  echo
  echo "3. Bot 返回 TAG 后，回到本脚本选择 22 设置节点 TAG"
}

batch_create_nodes(){
  prepare_env

  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "批量创建节点 - 第 1 步：数量设置"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -rp "批量创建数量: " COUNT
  [ -z "$COUNT" ] && red "数量不能为空" && return
  if ! echo "$COUNT" | grep -Eq '^[0-9]+$'; then
    red "数量必须是数字"
    return
  fi
  if [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 50 ]; then
    red "一次最多创建 50 个节点，避免资源耗尽"
    return
  fi

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "批量创建节点 - 第 2 步：客户信息"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -rp "客户名前缀 [默认 客户]: " CUSTOMER_PREFIX
  CUSTOMER_PREFIX=${CUSTOMER_PREFIX:-客户}

  read -rp "统一备注 [默认 批量创建]: " BATCH_REMARK
  BATCH_REMARK=${BATCH_REMARK:-批量创建}

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "批量创建节点 - 第 3 步：端口设置"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "1. 自动随机端口"
  echo "2. 手动连续端口"
  read -rp "请选择 [默认 1]: " PORT_MODE
  PORT_MODE=${PORT_MODE:-1}

  if [ "$PORT_MODE" = "2" ]; then
    while true; do
      read -rp "请输入起始端口: " START_PORT
      if [ -z "$START_PORT" ]; then
        red "起始端口不能为空"
        continue
      fi
      if ! echo "$START_PORT" | grep -Eq '^[0-9]+$'; then
        red "端口必须是数字"
        continue
      fi
      if [ "$START_PORT" -lt 1 ] || [ "$START_PORT" -gt 65535 ]; then
        red "端口范围必须是 1-65535"
        continue
      fi
      break
    done
    PORT_PREVIEW="$START_PORT 起连续端口，遇到占用自动跳过"
  else
    PORT_PREVIEW="自动随机"
  fi

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "批量创建节点 - 第 4 步：套餐信息"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -rp "统一到期天数 [默认 30]: " DAYS
  DAYS=${DAYS:-30}
  if ! is_positive_integer "$DAYS"; then
    red "到期天数必须是正整数"
    return
  fi

  read -rp "统一流量限制 GB [默认 50]: " LIMIT_GB
  LIMIT_GB=${LIMIT_GB:-50}
  if ! is_nonnegative_number "$LIMIT_GB"; then
    red "流量限制必须是非负数字"
    return
  fi

  TAG=""

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "批量创建节点 - 第 5 步：确认创建"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "创建数量: $COUNT"
  echo "客户前缀: $CUSTOMER_PREFIX"
  echo "统一备注: $BATCH_REMARK"
  echo "端口模式: $PORT_PREVIEW"
  echo "到期天数: $DAYS 天"
  echo "流量限制: ${LIMIT_GB}GB"
  echo "频道 TAG: 暂不设置，创建后用 22.设置TAG"
  echo
  read -rp "确认批量创建？输入 y 继续: " CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    yellow "已取消批量创建"
    return
  fi

  ensure_dirs
  OUT="$EXPORT_DIR/batch_created_$(date +%Y%m%d_%H%M%S).txt"
  : > "$OUT"

  echo
  yellow "开始批量创建..."
  echo

  for i in $(seq 1 "$COUNT"); do
    ID=$(next_id)
    CUSTOMER="${CUSTOMER_PREFIX}-${ID}"
    TG_USER="未填写"
    REMARK="$BATCH_REMARK"
    NAME="mtproxy-node-$ID"

    if [ "$PORT_MODE" = "2" ]; then
      PORT=$((START_PORT + i - 1))
      while port_in_use "$PORT"; do
        PORT=$((PORT + 1))
      done
    else
      PORT=$(random_port)
    fi

    SECRET=$(openssl rand -hex 16)
    IP=$(get_ip)
    CREATED_AT=$(date +%s)
    EXPIRE_AT=$((CREATED_AT + DAYS * 86400))
    LIMIT_BYTES=$(gb_to_bytes "$LIMIT_GB")
    USED_BYTES=0
    LAST_BYTES=0
    STATUS="ACTIVE"

    run_container
    open_firewall "$PORT"
    save_node

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "ID: $ID"
    echo "$IP:$PORT"
    echo "Secret: $SECRET"

    {
      echo "ID: $ID"
      echo "$IP:$PORT"
      echo "Secret: $SECRET"
      echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
      echo "https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
      echo "----------------------------------------"
    } >> "$OUT"
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  green "批量创建完成"
  yellow "IP:端口 和 Secret 已导出：$OUT"
  echo
  echo "说明：去 MTProxy Admin Bot 注册每条代理后，拿到 TAG，再用 22.设置TAG 填入对应节点。"
}

show_node(){
  REQ_ID="$1"

  load_node "$REQ_ID" || return

  EXPIRE_DATE=$(format_date "$EXPIRE_AT")
  LEFT=$(days_left "$EXPIRE_AT")
  USED_GB=$(bytes_to_gb "$USED_BYTES")
  STATUS_TEXT=$(status_cn "$STATUS")

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "节点详情"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "客户名称: $CUSTOMER"
  echo "TG账号: $TG_USER"
  echo "备注: $REMARK"
  echo
  echo "节点ID: $REQ_ID"
  echo "容器: mtproxy-node-$REQ_ID"
  echo "服务器: $IP"
  echo "端口: $PORT"
  echo "Secret: $SECRET"
  if [ -n "$TAG" ]; then
    echo "频道 TAG: $TAG"
  else
    echo "频道 TAG: 未设置"
  fi
  echo "状态: $STATUS / $STATUS_TEXT"
  echo
  yellow "MTProxy Admin Bot 注册信息："
  echo "服务器地址: $IP:$PORT"
  echo "Secret: $SECRET"
  echo
  echo "已用流量: ${USED_GB}GB / ${LIMIT_GB}GB"
  echo "到期时间: $EXPIRE_DATE"
  echo "剩余天数: ${LEFT}天"
  echo
  green "Telegram 链接："
  proxy_link
  echo
  green "网页链接："
  web_link
  echo
}

list_nodes(){
  ensure_dirs

  if ! ls "$NODE_DIR"/node-*.conf >/dev/null 2>&1; then
    red "暂无代理节点"
    return
  fi

  printf "%-5s %-14s %-16s %-8s %-10s %-14s %-8s\n" "ID" "客户" "TG账号" "端口" "状态" "流量GB" "剩余"
  echo "----------------------------------------------------------------------------"

  for FILE in "$NODE_DIR"/node-*.conf; do
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")
    CUSTOMER="${CUSTOMER:-未填写}"
    TG_USER="${TG_USER:-未填写}"
    USED_BYTES="${USED_BYTES:-0}"
    LIMIT_GB="${LIMIT_GB:-50}"
    EXPIRE_AT="${EXPIRE_AT:-0}"

    USED_GB_NOW=$(bytes_to_gb "$USED_BYTES")
    LEFT=$(days_left "$EXPIRE_AT")

    printf "%-5s %-14s %-16s %-8s %-10s %-14s %-8s\n" \
      "$ID" "$CUSTOMER" "$TG_USER" "$PORT" "$STATUS" "$USED_GB_NOW/$LIMIT_GB" "${LEFT}天"
  done
}

show_one_node(){
  read -rp "请输入节点 ID: " ID
  show_node "$ID"
}

delete_node(){
  read -rp "请输入要删除的节点 ID: " ID
  load_node "$ID" || return

  read -rp "确认删除节点 $ID？输入 yes 确认: " OK
  [ "$OK" != "yes" ] && yellow "已取消" && return

  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -f "$(node_file "$ID")"

  green "节点 $ID 已删除"
}

restart_node(){
  read -rp "请输入要重启的节点 ID: " ID
  load_node "$ID" || return

  docker restart "$NAME" >/dev/null 2>&1
  green "节点 $ID 已重启"
}

disable_node(){
  read -rp "请输入要停用的节点 ID: " ID
  load_node "$ID" || return

  docker stop "$NAME" >/dev/null 2>&1 || true
  STATUS="MANUAL"
  save_node

  green "节点 $ID 已手动停用"
}

enable_node(){
  read -rp "请输入要启用的节点 ID: " ID
  load_node "$ID" || return

  NOW=$(date +%s)
  if [ "$NOW" -ge "$EXPIRE_AT" ]; then
    red "节点已到期，请先修改到期时间或续费"
    return
  fi

  if [ "$USED_BYTES" -ge "$LIMIT_BYTES" ]; then
    red "节点流量已超限，请先修改流量限制或续费"
    return
  fi

  if ! docker inspect "$NAME" >/dev/null 2>&1; then
    yellow "容器不存在，正在重新创建..."
    run_container
  else
    docker start "$NAME" >/dev/null 2>&1 || true
  fi

  STATUS="ACTIVE"
  save_node

  green "节点 $ID 已启用"
}

edit_customer(){
  read -rp "请输入节点 ID: " ID
  load_node "$ID" || return

  echo "当前客户名称: $CUSTOMER"
  read -rp "新客户名称，回车不改: " NEW_CUSTOMER

  echo "当前TG账号: $TG_USER"
  read -rp "新TG账号，回车不改: " NEW_TG

  echo "当前备注: $REMARK"
  read -rp "新备注，回车不改: " NEW_REMARK

  [ -n "$NEW_CUSTOMER" ] && CUSTOMER="$NEW_CUSTOMER"
  [ -n "$NEW_TG" ] && TG_USER="$NEW_TG"
  [ -n "$NEW_REMARK" ] && REMARK="$NEW_REMARK"

  save_node
  green "客户信息已更新"
}

edit_expire(){
  read -rp "请输入节点 ID: " ID
  load_node "$ID" || return

  echo "当前到期时间: $(format_date "$EXPIRE_AT")"
  read -rp "设置新的到期天数，从今天开始计算: " DAYS
  [ -z "$DAYS" ] && red "天数不能为空" && return
  is_positive_integer "$DAYS" || { red "天数必须是正整数"; return; }

  EXPIRE_AT=$(($(date +%s) + DAYS * 86400))

  if [ "$STATUS" = "EXPIRED" ]; then
    if [ "$USED_BYTES" -lt "$LIMIT_BYTES" ]; then
      docker start "$NAME" >/dev/null 2>&1 || true
      STATUS="ACTIVE"
    fi
  fi

  save_node
  green "到期时间已更新"
}

edit_limit(){
  read -rp "请输入节点 ID: " ID
  load_node "$ID" || return

  echo "当前流量限制: ${LIMIT_GB}GB"
  read -rp "新的流量限制 GB: " NEW_LIMIT_GB
  [ -z "$NEW_LIMIT_GB" ] && red "流量不能为空" && return
  is_nonnegative_number "$NEW_LIMIT_GB" || { red "流量限制必须是非负数字"; return; }

  LIMIT_GB="$NEW_LIMIT_GB"
  LIMIT_BYTES=$(gb_to_bytes "$LIMIT_GB")

  NOW=$(date +%s)
  if [ "$STATUS" = "LIMITED" ] && [ "$USED_BYTES" -lt "$LIMIT_BYTES" ] && [ "$NOW" -lt "$EXPIRE_AT" ]; then
    docker start "$NAME" >/dev/null 2>&1 || true
    STATUS="ACTIVE"
  fi

  save_node
  green "流量限制已更新"
}

renew_node(){
  read -rp "请输入节点 ID: " ID
  load_node "$ID" || return

  read -rp "增加天数 [默认 30]: " ADD_DAYS
  ADD_DAYS=${ADD_DAYS:-30}
  is_positive_integer "$ADD_DAYS" || { red "增加天数必须是正整数"; return; }

  read -rp "增加流量 GB [默认 50]: " ADD_GB
  ADD_GB=${ADD_GB:-50}
  is_nonnegative_number "$ADD_GB" || { red "增加流量必须是非负数字"; return; }

  NOW=$(date +%s)

  if [ "$EXPIRE_AT" -lt "$NOW" ]; then
    EXPIRE_AT=$((NOW + ADD_DAYS * 86400))
  else
    EXPIRE_AT=$((EXPIRE_AT + ADD_DAYS * 86400))
  fi

  LIMIT_GB=$(awk -v a="$LIMIT_GB" -v b="$ADD_GB" 'BEGIN{printf "%.2f", a+b}')
  LIMIT_BYTES=$(gb_to_bytes "$LIMIT_GB")

  if [ "$USED_BYTES" -lt "$LIMIT_BYTES" ] && [ "$NOW" -lt "$EXPIRE_AT" ]; then
    if ! docker inspect "$NAME" >/dev/null 2>&1; then
      run_container
    else
      docker start "$NAME" >/dev/null 2>&1 || true
    fi
    STATUS="ACTIVE"
  fi

  save_node
  green "续费成功"
  show_node "$ID"
}

search_customer(){
  read -rp "请输入客户名称 / TG账号 / 备注关键词: " KW
  [ -z "$KW" ] && return

  echo
  printf "%-5s %-14s %-16s %-8s %-10s %-14s\n" "ID" "客户" "TG账号" "端口" "状态" "备注"
  echo "----------------------------------------------------------------------------"

  FOUND=0
  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    CUSTOMER="${CUSTOMER:-未填写}"
    TG_USER="${TG_USER:-未填写}"
    REMARK="${REMARK:-}"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")

    if echo "$CUSTOMER $TG_USER $REMARK $ID $PORT" | grep -qi "$KW"; then
      printf "%-5s %-14s %-16s %-8s %-10s %-14s\n" "$ID" "$CUSTOMER" "$TG_USER" "$PORT" "$STATUS" "$REMARK"
      FOUND=1
    fi
  done

  [ "$FOUND" = "0" ] && red "没有找到匹配节点"
}

expiring_nodes(){
  read -rp "显示几天内到期 [默认 7]: " WARN_DAYS
  WARN_DAYS=${WARN_DAYS:-7}
  NOW=$(date +%s)
  LIMIT_TIME=$((NOW + WARN_DAYS * 86400))

  echo
  yellow "即将到期客户（${WARN_DAYS}天内）"
  printf "%-5s %-14s %-16s %-8s %-10s %-12s\n" "ID" "客户" "TG账号" "端口" "状态" "剩余"
  echo "----------------------------------------------------------------------------"

  FOUND=0
  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")
    CUSTOMER="${CUSTOMER:-未填写}"
    TG_USER="${TG_USER:-未填写}"

    if [ "$EXPIRE_AT" -le "$LIMIT_TIME" ]; then
      LEFT=$(days_left "$EXPIRE_AT")
      printf "%-5s %-14s %-16s %-8s %-10s %-12s\n" "$ID" "$CUSTOMER" "$TG_USER" "$PORT" "$STATUS" "${LEFT}天"
      FOUND=1
    fi
  done

  [ "$FOUND" = "0" ] && green "没有即将到期客户"
}

export_links(){
  ensure_dirs
  cleanup_old_exports
  OUT="$EXPORT_DIR/all_links.txt"
  : > "$OUT"

  if ! ls "$NODE_DIR"/node-*.conf >/dev/null 2>&1; then
    red "暂无代理节点"
    return
  fi

  IP_NOW=$(get_ip)

  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "全部节点链接"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    NAME="mtproxy-node-$FILE_ID"
    CUSTOMER="${CUSTOMER:-未填写}"
    TG_USER="${TG_USER:-未填写}"
    REMARK="${REMARK:-}"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")

    [ -n "$IP_NOW" ] && IP="$IP_NOW"

    TG_LINK="tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
    WEB_LINK="https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"

    echo
    echo "ID: $ID"
    echo "客户: $CUSTOMER"
    echo "TG: $TG_USER"
    echo "状态: $STATUS"
    echo "地址: $IP:$PORT"
    echo "Secret: $SECRET"
    echo "Telegram链接:"
    echo "$TG_LINK"
    echo "网页链接:"
    echo "$WEB_LINK"
    echo "----------------------------------------"

    {
      echo "ID：$ID"
      echo "客户：$CUSTOMER"
      echo "TG：$TG_USER"
      echo "备注：$REMARK"
      echo "状态：$STATUS"
      echo "地址：$IP:$PORT"
      echo "Secret：$SECRET"
      echo "Telegram链接：$TG_LINK"
      echo "网页链接：$WEB_LINK"
      echo "----------------------------------------"
      echo
    } >> "$OUT"
  done

  echo
  green "已显示全部节点链接"
  yellow "同时已保存到：$OUT"
}

export_customers(){
  ensure_dirs
  OUT="$EXPORT_DIR/customers.csv"
  echo "ID,客户名称,TG账号,备注,端口,Secret,Bot注册地址,状态,已用GB,限制GB,到期时间,代理链接" > "$OUT"

  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    CUSTOMER="${CUSTOMER:-未填写}"
    TG_USER="${TG_USER:-未填写}"
    REMARK="${REMARK:-}"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")
    USED_GB=$(bytes_to_gb "${USED_BYTES:-0}")
    IP_NOW=$(get_ip)
    [ -n "$IP_NOW" ] && IP="$IP_NOW"
    LINK="tg://proxy?server=$IP&port=$PORT&secret=$SECRET"

    echo "\"$ID\",\"$CUSTOMER\",\"$TG_USER\",\"$REMARK\",\"$PORT\",\"$SECRET\",\"$IP:$PORT\",\"$STATUS\",\"$USED_GB\",\"$LIMIT_GB\",\"$(format_date "$EXPIRE_AT")\",\"$LINK\"" >> "$OUT"
  done

  green "已导出客户清单：$OUT"
}

traffic_rank(){
  echo
  printf "%-5s %-14s %-16s %-8s %-14s\n" "ID" "客户" "TG账号" "状态" "流量GB"
  echo "----------------------------------------------------------------------------"

  TMP=$(mktemp)
  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    USED_BYTES="${USED_BYTES:-0}"
    echo "$USED_BYTES|$ID|${CUSTOMER:-未填写}|${TG_USER:-未填写}|$(normalize_status "${STATUS:-ACTIVE}")|$(bytes_to_gb "$USED_BYTES")/${LIMIT_GB}GB" >> "$TMP"
  done

  sort -t'|' -nr "$TMP" | while IFS='|' read -r _ ID CUSTOMER TG_USER STATUS TRAFFIC; do
    printf "%-5s %-14s %-16s %-8s %-14s\n" "$ID" "$CUSTOMER" "$TG_USER" "$STATUS" "$TRAFFIC"
  done

  rm -f "$TMP"
}

check_nodes(){
  ensure_dirs
  NOW=$(date +%s)

  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue

    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"

    CUSTOMER="${CUSTOMER:-未填写}"
    TG_USER="${TG_USER:-未填写}"
    REMARK="${REMARK:-}"
    TAG="${TAG:-}"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")
    USED_BYTES="${USED_BYTES:-0}"
    LAST_BYTES="${LAST_BYTES:-0}"
    LIMIT_GB="${LIMIT_GB:-50}"
    LIMIT_BYTES="${LIMIT_BYTES:-$(gb_to_bytes "$LIMIT_GB")}"

    if [ "$STATUS" = "ACTIVE" ]; then
      CURRENT_BYTES=$(container_traffic "$NAME")

      if [ "$CURRENT_BYTES" -ge "$LAST_BYTES" ]; then
        DELTA=$((CURRENT_BYTES - LAST_BYTES))
      else
        DELTA=$CURRENT_BYTES
      fi

      USED_BYTES=$((USED_BYTES + DELTA))
      LAST_BYTES=$CURRENT_BYTES

      if [ "$NOW" -ge "$EXPIRE_AT" ]; then
        docker stop "$NAME" >/dev/null 2>&1 || true
        STATUS="EXPIRED"
      elif [ "$USED_BYTES" -ge "$LIMIT_BYTES" ]; then
        docker stop "$NAME" >/dev/null 2>&1 || true
        STATUS="LIMITED"
      fi
    fi

    save_node
  done
}


set_node_tag(){
  read -rp "请输入节点 ID: " ID
  load_node "$ID" || return

  echo "当前 TAG: ${TAG:-未设置}"
  read -rp "请输入新的频道 TAG，清空请输入空格后回车: " NEW_TAG

  if [ "$NEW_TAG" = " " ]; then
    TAG=""
  else
    TAG="$NEW_TAG"
  fi

  yellow "正在重建容器以应用 TAG，端口和 Secret 不会改变..."
  run_container

  if [ "$STATUS" = "MANUAL" ]; then
    docker stop "$NAME" >/dev/null 2>&1 || true
  else
    STATUS="ACTIVE"
  fi

  save_node
  green "TAG 已更新"
  show_node "$ID"
}


normalize_all_node_ids(){
  ensure_dirs
  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    CUSTOMER="${CUSTOMER:-未填写}"
    TG_USER="${TG_USER:-未填写}"
    REMARK="${REMARK:-}"
    TAG="${TAG:-}"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")
    USED_BYTES="${USED_BYTES:-0}"
    LAST_BYTES="${LAST_BYTES:-0}"
    LIMIT_GB="${LIMIT_GB:-50}"
    LIMIT_BYTES="${LIMIT_BYTES:-$(gb_to_bytes "$LIMIT_GB")}"
    CREATED_AT="${CREATED_AT:-$(date +%s)}"
    EXPIRE_AT="${EXPIRE_AT:-$((CREATED_AT + 30*86400))}"
    IP="${IP:-$(get_ip)}"
    save_node
  done
}


update_script(){
  yellow "正在从 GitHub 更新脚本..."

  TMP_FILE=$(mktemp /tmp/mtproxy-update.XXXXXX) || {
    red "更新失败：无法创建临时文件"
    return
  }

  curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 "$SCRIPT_URL" -o "$TMP_FILE" || {
    red "更新失败：无法下载脚本"
    rm -f "$TMP_FILE"
    return
  }

  sed -i 's/\r$//' "$TMP_FILE"
  if ! grep -q "MTProxy Enterprise Manager" "$TMP_FILE" || ! bash -n "$TMP_FILE"; then
    red "更新失败：下载内容不正确或语法校验失败"
    rm -f "$TMP_FILE"
    return
  fi

  install -m 0755 "$TMP_FILE" "$BIN_PATH"
  ln -sf "$BIN_PATH" /usr/local/bin/mtp
  chmod +x /usr/local/bin/mtp

  if [ -f "./mtproxy.sh" ]; then
    cp "$TMP_FILE" "./mtproxy.sh"
    chmod +x "./mtproxy.sh"
  fi

  rm -f "$TMP_FILE"

  green "更新完成"
  echo
  yellow "请重新执行："
  echo "mtp"
}

install_shortcut(){
  install_cron
  green "快捷命令已安装：mtp"
  echo "以后直接输入 mtp 打开管理菜单"
}

uninstall_manager(){
  red "警告：此操作会删除所有 MTProxy 节点、配置、导出文件、定时任务和快捷命令。"
  red "所有客户代理都会停止并删除。"
  echo
  read -rp "确认卸载请输入 DELETE: " CONFIRM

  if [ "$CONFIRM" != "DELETE" ]; then
    yellow "已取消卸载"
    return
  fi

  docker ps -aq --filter "name=mtproxy-node-" | xargs -r docker rm -f >/dev/null 2>&1 || true

  crontab -l 2>/dev/null | grep -v "mtproxy-manager --check" | crontab - 2>/dev/null || true

  rm -f /usr/local/bin/mtp
  rm -f "$BIN_PATH"
  rm -rf "$BASE_DIR"

  green "MTProxy Enterprise Manager 已卸载完成"
  exit 0
}

docker_status(){
  docker ps -a --filter "name=mtproxy-node-"
}

health_check(){
  check_nodes

  echo "Docker:"
  if systemctl is-active docker >/dev/null 2>&1; then
    green "Docker 正常"
  else
    red "Docker 未运行"
  fi

  echo
  echo "Cron:"
  if systemctl is-active cron >/dev/null 2>&1; then
    green "Cron 正常"
  else
    red "Cron 未运行"
  fi

  echo
  echo "BBR:"
  BBR=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
  if [ "$BBR" = "bbr" ]; then
    green "BBR 已开启"
  else
    yellow "BBR 未开启"
  fi
}

dashboard_counts(){
  TOTAL=0
  ACTIVE_COUNT=0
  EXPIRING=0
  NOW=$(date +%s)
  LIMIT_TIME=$((NOW + 7*86400))

  for FILE in "$NODE_DIR"/node-*.conf; do
    [ ! -f "$FILE" ] && continue
    FILE_ID=$(file_id_from_path "$FILE")
    . "$FILE"
    ID="$FILE_ID"
    STATUS=$(normalize_status "${STATUS:-ACTIVE}")
    TOTAL=$((TOTAL + 1))
    [ "$STATUS" = "ACTIVE" ] && ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    [ "$EXPIRE_AT" -le "$LIMIT_TIME" ] && EXPIRING=$((EXPIRING + 1))
  done
}

menu(){
  dashboard_counts

  clear
  echo "╔════════════════════════════════════╗"
  echo "║  MTProxy Enterprise Manager $VERSION   ║"
  echo "╚════════════════════════════════════╝"
  echo "在线:$ACTIVE_COUNT  客户:$TOTAL  到期:$EXPIRING"
  echo "────────────────────────────────────"
  echo " 1.创建节点      2.批量创建"
  echo " 3.节点列表      4.节点详情"
  echo " 5.客户信息      6.修改时间"
  echo " 7.修改流量      8.节点续费"
  echo " 9.启用节点     10.停用节点"
  echo "11.重启节点     12.删除节点"
  echo "13.搜索客户     14.即将到期"
  echo "15.查看链接     16.客户清单"
  echo "17.流量排行     18.健康检查"
  echo "19.Docker状态   20.更新脚本"
  echo "21.卸载脚本     22.设置TAG"
  echo " 0.退出"
  echo "────────────────────────────────────"
  echo "快捷命令：mtp"
  echo "────────────────────────────────────"
  read -rp "请选择: " num

  case "$num" in
    1) create_node; pause ;;
    2) batch_create_nodes; pause ;;
    3) check_nodes; list_nodes; pause ;;
    4) show_one_node; pause ;;
    5) edit_customer; pause ;;
    6) edit_expire; pause ;;
    7) edit_limit; pause ;;
    8) renew_node; pause ;;
    9) enable_node; pause ;;
    10) disable_node; pause ;;
    11) restart_node; pause ;;
    12) delete_node; pause ;;
    13) search_customer; pause ;;
    14) expiring_nodes; pause ;;
    15) export_links; pause ;;
    16) export_customers; pause ;;
    17) traffic_rank; pause ;;
    18) health_check; pause ;;
    19) docker_status; pause ;;
    20) update_script; pause ;;
    21) uninstall_manager; pause ;;
    22) set_node_tag; pause ;;
    0) exit 0 ;;
    *) red "输入错误"; pause ;;
  esac
}

if [ "$1" = "--check" ]; then
  check_nodes
  exit 0
fi

check_root
ensure_dirs
cleanup_old_exports
auto_install_shortcut
normalize_all_node_ids >/dev/null 2>&1 || true

while true; do
  menu
done
