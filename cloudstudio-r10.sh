#!/bin/bash
# CloudStudio 一键初始化 + 后台应用管理器
# VERSION: 2026.09.05-r10
#
# 目标：新建 CloudStudio 工作区后，只需要上传本脚本并运行一次。
# 第一次运行会进入中文向导；安装完成后：
#   cs-init        管理/修复基础环境
#   netapp         小白式管理你后来添加的后台应用
#
# 核心能力：
#   - SSH：密码或公钥登录
#   - Tailscale：userspace-networking 模式，适配无 /dev/net/tun 容器
#   - CodeBuddy OpenAI 兼容反代：/v1 -> auth.proxy/codebuddy/v2
#   - CloudStudio healthz 心跳：配置令牌后防空闲休眠
#   - PID 1 supervisord：基础服务与用户应用开机自启、异常自动重启
#   - netapp：add/edit/list/logs/restart/enable/disable/remove/doctor
#
# 第一次：
#   chmod +x install-net-services-final.sh
#   ./install-net-services-final.sh
#
# 以后：
#   cs-init                 # 基础环境菜单
#   netapp                  # 应用管理菜单
#   netapp add              # 添加应用向导
#   netapp add gost "gost -L '...'" /root
#
# 非交互/自动化仍支持环境变量：
#   CS_HEALTHZ_TOKEN=xxx TS_AUTHKEY=tskey-auth-xxx SSH_PASSWORD=xxx ./install-net-services-final.sh repair
#   SSH_PUBKEY='ssh-ed25519 ...' ./install-net-services-final.sh repair
#   RELAY_PORT=65530 SSH_PORT=22 RELAY_KEY=xxx MODELS_FILE=/workspace/models.json
#
# 维护：
#   cs-init status
#   cs-init repair
#   cs-init reconfigure
#   cs-init uninstall       # 卸载核心，保留 netapp 用户应用
#   cs-init uninstall-all   # 全部清理
#
# 注意：容器整体被平台停止时，容器内任何心跳/看门狗都无法运行；
# 但你之后手动重新启动同一工作区时，supervisord 会自动恢复已托管服务。

set -uo pipefail

CONF=/etc/net-services.conf
TOKEN_FILE=/root/.cs-token
KEY_FILE=/root/.relay-key
SBIN=/usr/local/sbin
SV_CONF_DIR=/usr/local/share/supervisor
SV_CONF=$SV_CONF_DIR/net-services.conf
RELAY_JS=/workspace/relay.js
NETAPP_BIN=$SBIN/netapp
NETAPP_HOME=/usr/local/lib/netapps
NETAPP_META=/etc/netapps
NETAPP_LOG=/var/log/netapps
CSINIT_BIN=$SBIN/cs-init

# 重跑时优先沿用旧配置；显式环境变量仍具有最高优先级。
# 配置文件由本脚本用 %q 保存，可安全 source。
OLD_RELAY_PORT=""; OLD_SSH_PORT=""; OLD_MODELS_FILE=""
OLD_RELAY_HOST=""; OLD_SSH_LISTEN=""; OLD_UPSTREAM_BASE=""; OLD_UPSTREAM_AUTH_MODE=""
OLD_UPSTREAM_TOKEN=""; OLD_MODELS_MODE=""; OLD_STREAM_ADAPT=""
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    OLD_RELAY_PORT="${RELAY_PORT:-}"; OLD_SSH_PORT="${SSH_PORT:-}"; OLD_MODELS_FILE="${MODELS_FILE:-}"
    OLD_RELAY_HOST="${RELAY_HOST:-}"; OLD_SSH_LISTEN="${SSH_LISTEN:-}"; OLD_UPSTREAM_BASE="${UPSTREAM_BASE:-}"
    OLD_UPSTREAM_AUTH_MODE="${UPSTREAM_AUTH_MODE:-}"; OLD_UPSTREAM_TOKEN="${UPSTREAM_TOKEN:-}"
    OLD_MODELS_MODE="${MODELS_MODE:-}"; OLD_STREAM_ADAPT="${STREAM_ADAPT:-}"
fi

RELAY_PORT="${RELAY_PORT:-${OLD_RELAY_PORT:-65530}}"
SSH_PORT="${SSH_PORT:-${OLD_SSH_PORT:-22}}"
MODELS_FILE="${MODELS_FILE:-${OLD_MODELS_FILE:-/workspace/models.json}}"
RELAY_HOST="${RELAY_HOST:-${OLD_RELAY_HOST:-127.0.0.1}}"
SSH_LISTEN="${SSH_LISTEN:-${OLD_SSH_LISTEN:-127.0.0.1}}"
UPSTREAM_BASE="${UPSTREAM_BASE:-${OLD_UPSTREAM_BASE:-http://auth.proxy/codebuddy/v2}}"
UPSTREAM_AUTH_MODE="${UPSTREAM_AUTH_MODE:-${OLD_UPSTREAM_AUTH_MODE:-bearer}}"
UPSTREAM_TOKEN="${UPSTREAM_TOKEN:-${OLD_UPSTREAM_TOKEN:-auto_proxy_token}}"
MODELS_MODE="${MODELS_MODE:-${OLD_MODELS_MODE:-local}}"
STREAM_ADAPT="${STREAM_ADAPT:-${OLD_STREAM_ADAPT:-true}}"
CS_HEALTHZ_TOKEN="${CS_HEALTHZ_TOKEN:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
RELAY_KEY="${RELAY_KEY:-}"
SSH_SETUP_MODE="${SSH_SETUP_MODE:-auto}"
FORCE_SSH_CONFIG="${FORCE_SSH_CONFIG:-no}"
WIZARD_ADD_APP="no"

C_RESET=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_RESET"; }
ok()   { printf '  %s[ok]%s %s\n' "$C_G" "$C_RESET" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_Y" "$C_RESET" "$*"; }
die()  { printf '\n%s[fail]%s %s\n' "$C_R" "$C_RESET" "$*"; exit 1; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }
is_installed() { [ -x "$NETAPP_BIN" ] && [ -f "$SV_CONF" ]; }

valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_listen() { [ "${1:-}" = "127.0.0.1" ] || [ "${1:-}" = "0.0.0.0" ]; }

managed_group() {
    [ "${1:-}" = "net-services" ] || [[ "${1:-}" == app-* ]]
}

INSTALL_LOG=/var/log/cs-init-install.log
log_install() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$INSTALL_LOG" 2>/dev/null || true
}

BOOT_HB_PID_FILE=/run/cs-init-bootstrap-heartbeat.pid
BOOT_HB_SCRIPT=/usr/local/sbin/cs-init-bootstrap-heartbeat.sh

healthz_url_early() {
    [ -r /var/run/cloudstudio/space.yaml ] || return 1
    local key region host
    key=$(sed -n 's/^spacekey: *//p' /var/run/cloudstudio/space.yaml | tr -d '\r')
    region=$(sed -n 's/^region: *//p' /var/run/cloudstudio/space.yaml | tr -d '\r')
    host=$(sed -n 's/^host: *//p' /var/run/cloudstudio/space.yaml | tr -d '\r')
    [ -n "$key" ] && [ -n "$region" ] && [ -n "$host" ] || return 1
    printf 'https://%s--api.%s.%s/healthz\n' "$key" "$region" "$host"
}

start_bootstrap_heartbeat() {
    [ -n "${CS_HEALTHZ_TOKEN:-}" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local url code
    url=$(healthz_url_early 2>/dev/null || true)
    [ -n "$url" ] || { warn "暂时无法解析 healthz 地址；跳过安装阶段临时心跳"; return 0; }

    mkdir -p /root/.bashrc.d /root/.zshrc.d /run /usr/local/sbin 2>/dev/null || true
    printf 'export CS_HEALTHZ_TOKEN=%q\n' "$CS_HEALTHZ_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"

    code=$(curl -sS -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $CS_HEALTHZ_TOKEN" "$url" 2>/dev/null || echo 000)
    if [ "$code" = 200 ]; then
        ok "安装前 healthz 验证成功（HTTP 200）"
        log_install "bootstrap healthz validation=200"
    else
        warn "安装前 healthz 验证失败（HTTP $code）；安装过程中无法依靠该 Token 防空闲"
        log_install "bootstrap healthz validation=$code"
        return 0
    fi

    cat > "$BOOT_HB_SCRIPT" <<'EOF_BOOT_HB'
#!/bin/bash
[ -r /root/.cs-token ] && . /root/.cs-token
SPACE=/var/run/cloudstudio/space.yaml
[ -r "$SPACE" ] || exit 0
key=$(sed -n 's/^spacekey: *//p' "$SPACE" | tr -d '\r')
region=$(sed -n 's/^region: *//p' "$SPACE" | tr -d '\r')
host=$(sed -n 's/^host: *//p' "$SPACE" | tr -d '\r')
[ -n "$key" ] && [ -n "$region" ] && [ -n "$host" ] || exit 0
url="https://${key}--api.${region}.${host}/healthz"
while true; do
    curl -sS -o /dev/null -m 10 -H "Authorization: Bearer $CS_HEALTHZ_TOKEN" "$url" >/dev/null 2>&1 || true
    sleep 5
done
EOF_BOOT_HB
    chmod 700 "$BOOT_HB_SCRIPT"

    if [ -r "$BOOT_HB_PID_FILE" ]; then
        local oldpid
        oldpid=$(cat "$BOOT_HB_PID_FILE" 2>/dev/null || true)
        [ -n "$oldpid" ] && kill "$oldpid" 2>/dev/null || true
    fi
    nohup setsid "$BOOT_HB_SCRIPT" >>/var/log/cs-init-bootstrap-heartbeat.log 2>&1 &
    echo $! > "$BOOT_HB_PID_FILE"
    ok "安装阶段临时 healthz 心跳已启动"
    log_install "bootstrap heartbeat started pid=$!"
}

stop_bootstrap_heartbeat() {
    if [ -r "$BOOT_HB_PID_FILE" ]; then
        local pid
        pid=$(cat "$BOOT_HB_PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            sleep 0.2
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$BOOT_HB_PID_FILE"
    fi
}

prompt_default() {
    # prompt_default "提示" "默认值" 变量名
    local text=$1 def=$2 __var=$3 value
    read -r -p "$text [$def]：" value
    value=${value:-$def}
    printf -v "$__var" '%s' "$value"
}

show_help() {
cat <<'EOF'
CloudStudio 一键初始化

第一次（推荐）：
  chmod +x install-net-services-final.sh
  ./install-net-services-final.sh

安装后：
  cs-init                 打开基础环境管理菜单
  cs-init status          查看基础服务/Tailscale/应用状态
  cs-init repair          幂等修复/重装基础服务
  cs-init reconfigure     重新进入初始化配置向导
  cs-init models-update    刷新模型：/v3/config 权威列表 + 官网正式补充
  cs-init models-show      查看当前本地模型列表

应用管理：
  netapp                  打开应用管理菜单
  netapp add              交互式添加应用
  netapp list             查看应用
  netapp edit NAME        修改启动命令/工作目录
  netapp logs NAME        看日志
  netapp restart NAME     重启应用
  netapp disable NAME     停止并关闭下次自动启动
  netapp enable NAME      恢复自动启动并立即启动
  netapp remove NAME      取消托管，不删除程序文件
  netapp doctor           一键检查环境

自动化安装：
  TS_AUTHKEY=tskey-auth-xxx SSH_PASSWORD='xxx' \
  CS_HEALTHZ_TOKEN='xxx' ./install-net-services-final.sh repair

卸载：
  cs-init uninstall       只卸载核心网络服务，保留 netapp 应用
  cs-init uninstall-all   核心和 netapp 托管配置全部删除
EOF
}

show_status() {
    echo "===== CloudStudio 基础环境 ====="
    printf 'PID 1            : %s\n' "$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
    if [ -x "$SBIN/supervisor-rpc.py" ]; then
        "$SBIN/supervisor-rpc.py" status 2>/dev/null || echo "Supervisor RPC 当前不可用"
    else
        echo "基础服务尚未安装"
    fi
    echo
    echo "===== Tailscale ====="
    if command -v tailscale >/dev/null 2>&1; then
        tailscale status 2>/dev/null | head -20 || echo "Tailscale 尚未登录/未就绪"
        printf 'Tailscale IPv4   : %s\n' "$(tailscale ip -4 2>/dev/null || echo '-')"
    else
        echo "未安装 Tailscale"
    fi
    echo
    echo "===== healthz 最近状态 ====="
    tail -n 3 /var/log/heartbeat.log 2>/dev/null || echo "暂无 heartbeat.log"
    echo
    echo "===== CodeBuddy models ====="
    if [ -r "$MODELS_FILE" ]; then
        printf 'models.json       : %s\n' "$MODELS_FILE"
        python3 - "$MODELS_FILE" 2>/dev/null <<'PYMODELS_STATUS' || echo "models.json 解析失败"
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
print('模型数量          : %d' % len(j.get('data',[])))
print('模型              : ' + ', '.join(x.get('id','') for x in j.get('data',[])))
PYMODELS_STATUS
    else
        echo "models.json       : 未生成（可执行 cs-init models-update）"
    fi
    echo
    echo "===== netapp ====="
    if [ -x "$NETAPP_BIN" ]; then
        "$NETAPP_BIN" list 2>/dev/null || true
    else
        echo "netapp 尚未安装"
    fi
}

models_update_cmd() {
    if [ -x "$SBIN/update-codebuddy-models" ]; then
        "$SBIN/update-codebuddy-models"
    else
        die "模型更新器尚未安装，请先执行 cs-init repair"
    fi
}

models_show_cmd() {
    if [ -r "$MODELS_FILE" ]; then
        python3 - "$MODELS_FILE" <<'PYMODELS_SHOW'
import json, sys
with open(sys.argv[1],'r',encoding='utf-8') as f:
    j=json.load(f)
for x in j.get('data',[]):
    print(x.get('id',''))
PYMODELS_SHOW
    else
        die "找不到 $MODELS_FILE；执行 cs-init models-update 生成"
    fi
}

init_wizard() {
    is_tty || return 0

    echo
    echo "============================================================"
    echo " CloudStudio 首次初始化向导  (2026.09.05-r10)"
    echo "============================================================"
    echo "每一步都会解释用途；不确定时直接回车使用推荐默认值。"
    echo "密码 / Key / Token 输入不回显是正常的。"
    echo

    local choice p1 p2 pub tskey hbt port rport answer tmp key_choice
    local ssh_listen_choice relay_listen_choice auth_choice models_choice stream_choice

    echo "[1/7] SSH 登录"
    echo "  用途：以后可从电脑/手机远程进入工作区。"
    echo "  1) root 密码登录（新手最简单）"
    echo "  2) SSH 公钥登录（更安全）"
    echo "  3) 保持现有 SSH 配置"
    read -r -p "请选择 [1]：" choice
    choice=${choice:-1}
    case "$choice" in
        1)
            SSH_SETUP_MODE=password; FORCE_SSH_CONFIG=yes
            if [ -z "$SSH_PASSWORD" ]; then
                while true; do
                    read -r -s -p "请输入 root SSH 密码：" p1; echo
                    [ -n "$p1" ] || { warn "密码不能为空"; continue; }
                    read -r -s -p "再输入一次确认：" p2; echo
                    [ "$p1" = "$p2" ] && break
                    warn "两次密码不一致，请重输"
                done
                SSH_PASSWORD=$p1
            fi
            ;;
        2)
            SSH_SETUP_MODE=key; FORCE_SSH_CONFIG=yes
            if [ -z "$SSH_PUBKEY" ]; then
                if [ -s /root/.ssh/authorized_keys ]; then
                    echo "  已存在 authorized_keys，直接回车表示沿用。"
                    read -r -p "也可以粘贴一个新公钥：" pub
                    SSH_PUBKEY=$pub
                else
                    read -r -p "粘贴完整 SSH 公钥（ssh-ed25519/ssh-rsa 开头）：" pub
                    SSH_PUBKEY=$pub
                    [ -n "$SSH_PUBKEY" ] || warn "没有公钥的话，后面可能无法 SSH 登录"
                fi
            fi
            ;;
        3) SSH_SETUP_MODE=keep; FORCE_SSH_CONFIG=no ;;
        *) die "SSH 选项无效" ;;
    esac

    echo
    echo "[2/7] Tailscale"
    echo "  用途：给这个容器一个稳定的 Tailnet 私有地址。"
    echo "  有 Auth Key 就粘贴，可自动登录；没有就回车，安装后执行 tailscale up 浏览器授权一次。"
    if [ -z "$TS_AUTHKEY" ]; then
        read -r -s -p "Tailscale Auth Key（可留空）：" tskey; echo
        TS_AUTHKEY=$tskey
    else
        ok "已从环境变量读取 TS_AUTHKEY"
    fi

    echo
    echo "[3/7] CloudStudio healthz 防空闲心跳"
    echo "  获取：CloudStudio 设置 -> 访问令牌 -> 新增访问令牌（该 POC 场景不需要额外权限）。"
    echo "  留空：SSH / Tailscale / 反代仍能使用，但不会启用防空闲心跳。"
    echo "  注意：容器已经被平台停止后，容器内部心跳无法把它重新开机。"
    if [ -z "$CS_HEALTHZ_TOKEN" ] && [ -s "$TOKEN_FILE" ]; then
        CS_HEALTHZ_TOKEN=$(sed -n 's/^export CS_HEALTHZ_TOKEN=//p' "$TOKEN_FILE" | tail -1)
        ok "检测到之前保存的 healthz token，将继续沿用"
    elif [ -z "$CS_HEALTHZ_TOKEN" ]; then
        read -r -s -p "CS_HEALTHZ_TOKEN（可留空）：" hbt; echo
        CS_HEALTHZ_TOKEN=$hbt
    else
        ok "已从环境变量读取 CS_HEALTHZ_TOKEN"
    fi

    echo
    echo "[4/7] 监听地址和端口"
    echo "  推荐：SSH 和反代都只监听 127.0.0.1，再由 tailscale serve 暴露。"
    echo "  需要 CloudStudio Web 预览直接访问反代时，可把反代监听改成 0.0.0.0。"
    echo
    echo "  SSH 监听：1) 127.0.0.1（推荐）  2) 0.0.0.0"
    read -r -p "请选择 [1]：" ssh_listen_choice
    case "${ssh_listen_choice:-1}" in 1) SSH_LISTEN=127.0.0.1;; 2) SSH_LISTEN=0.0.0.0;; *) die "SSH 监听选项无效";; esac
    while true; do
        prompt_default "SSH 端口" "$SSH_PORT" port
        valid_port "$port" && break
        warn "端口必须是 1-65535"
    done
    SSH_PORT=$port

    echo "  反代监听：1) 127.0.0.1（推荐）  2) 0.0.0.0"
    read -r -p "请选择 [1]：" relay_listen_choice
    case "${relay_listen_choice:-1}" in 1) RELAY_HOST=127.0.0.1;; 2) RELAY_HOST=0.0.0.0;; *) die "反代监听选项无效";; esac
    while true; do
        prompt_default "反代端口" "$RELAY_PORT" rport
        valid_port "$rport" || { warn "端口必须是 1-65535"; continue; }
        [ "$rport" != "$SSH_PORT" ] || { warn "反代端口不能和 SSH 端口相同"; continue; }
        break
    done
    RELAY_PORT=$rport

    echo
    echo "[5/7] 反代上游 API"
    echo "  原 CloudStudio CodeBuddy 默认： http://auth.proxy/codebuddy/v2"
    echo "  换成其它 OpenAI 兼容服务时，直接填完整 Base URL，如 https://api.example.com/v1"
    prompt_default "上游 Base URL" "$UPSTREAM_BASE" tmp
    UPSTREAM_BASE=$tmp
    [[ "$UPSTREAM_BASE" =~ ^https?:// ]] || die "上游 Base URL 必须以 http:// 或 https:// 开头"

    echo "  上游鉴权：1) Bearer Token（默认）  2) 不发送 Authorization"
    read -r -p "请选择 [1]：" auth_choice
    case "${auth_choice:-1}" in
        1)
            UPSTREAM_AUTH_MODE=bearer
            echo "  CloudStudio CodeBuddy 默认 Token 是 auto_proxy_token，直接回车即可。"
            read -r -s -p "上游 Bearer Token [$UPSTREAM_TOKEN]：" tmp; echo
            UPSTREAM_TOKEN=${tmp:-$UPSTREAM_TOKEN}
            ;;
        2) UPSTREAM_AUTH_MODE=none ;;
        *) die "上游鉴权选项无效" ;;
    esac

    echo "  GET /v1/models：1) 本地 models.json（CodeBuddy 默认）  2) 转发给上游"
    read -r -p "请选择 [1]：" models_choice
    case "${models_choice:-1}" in 1) MODELS_MODE=local;; 2) MODELS_MODE=upstream;; *) die "models 选项无效";; esac

    echo "  stream:false 兼容：1) 开启（CodeBuddy 默认）  2) 关闭（普通 OpenAI 上游通常可关）"
    read -r -p "请选择 [1]：" stream_choice
    case "${stream_choice:-1}" in 1) STREAM_ADAPT=true;; 2) STREAM_ADAPT=false;; *) die "stream 选项无效";; esac

    echo
    echo "[6/7] 你自己的反代 API Key"
    if [ -s "$KEY_FILE" ]; then
        echo "  已有 Key。1) 沿用（默认）  2) 自己输入新 Key  3) 重新随机生成"
        read -r -p "请选择 [1]：" key_choice
        case "${key_choice:-1}" in
            1) RELAY_KEY=$(cat "$KEY_FILE") ;;
            2) read -r -s -p "输入新的反代 API Key：" RELAY_KEY; echo; [ -n "$RELAY_KEY" ] || die "Key 不能为空" ;;
            3) RELAY_KEY=""; rm -f "$KEY_FILE" ;;
            *) die "Key 选项无效" ;;
        esac
    else
        echo "  1) 自动随机生成（推荐）  2) 自己输入"
        read -r -p "请选择 [1]：" key_choice
        case "${key_choice:-1}" in
            1) RELAY_KEY="" ;;
            2) read -r -s -p "输入反代 API Key：" RELAY_KEY; echo; [ -n "$RELAY_KEY" ] || die "Key 不能为空" ;;
            *) die "Key 选项无效" ;;
        esac
    fi

    echo
    echo "[7/7] 第一个后台应用"
    echo "  netapp 只负责托管已经能正常运行的程序，不负责下载/安装程序。"
    read -r -p "基础环境安装完成后，是否立刻进入 netapp 添加第一个应用？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] && WIZARD_ADD_APP=yes || WIZARD_ADD_APP=no

    echo
    echo "================ 请确认配置 ================"
    echo "SSH              : $SSH_LISTEN:$SSH_PORT ($SSH_SETUP_MODE)"
    echo "Tailscale        : $([ -n "$TS_AUTHKEY" ] && echo 'Auth Key 自动登录' || echo '安装后浏览器授权')"
    echo "healthz 心跳     : $([ -n "$CS_HEALTHZ_TOKEN" ] && echo '启用并在安装后验证' || echo '跳过')"
    echo "反代监听         : $RELAY_HOST:$RELAY_PORT"
    echo "上游 Base URL    : $UPSTREAM_BASE"
    echo "上游鉴权         : $UPSTREAM_AUTH_MODE"
    echo "models           : $MODELS_MODE"
    echo "stream 适配      : $STREAM_ADAPT"
    echo "客户端反代 Key   : $([ -n "$RELAY_KEY" ] && echo '自定义/沿用' || echo '自动生成')"
    echo "安装后添加应用   : $WIZARD_ADD_APP"
    echo "=============================================="
    echo "安装阶段不会修改/重启 CloudStudio 的其它 Supervisor 进程组。"
    read -r -p "确认开始安装？[Y/n] " answer
    [[ "$answer" =~ ^[Nn]$ ]] && { echo "已取消，没有开始安装"; exit 0; }
    mkdir -p /var/log 2>/dev/null || true
    : > "$INSTALL_LOG" 2>/dev/null || true
    log_install "用户确认安装，开始执行 VERSION=2026.09.05-r10"
    start_bootstrap_heartbeat
}

maintenance_menu() {
    is_tty || return 0
    while true; do
        echo
        echo "============================================================"
        echo " CloudStudio 管理菜单"
        echo "============================================================"
        echo "1) 查看总体状态"
        echo "2) 管理后台应用（netapp 菜单）"
        echo "3) 添加后台应用"
        echo "4) 检查环境（doctor）"
        echo "5) 修复/重装基础服务"
        echo "6) 重新配置基础参数"
        echo "7) 查看帮助"
        echo "8) 刷新 CodeBuddy 国内模型列表"
        echo "0) 退出"
        read -r -p "请选择：" ans
        case "$ans" in
            1) show_status ;;
            2) "$NETAPP_BIN" menu ;;
            3) "$NETAPP_BIN" add ;;
            4) "$NETAPP_BIN" doctor ;;
            5) return 0 ;;
            6) init_wizard; return 0 ;;
            7) show_help ;;
            8) models_update_cmd ;;
            0|'') exit 0 ;;
            *) warn "请输入 0-8" ;;
        esac
    done
}

# ---------------------------------------------------------------- 命令入口 / 首次向导
case "${1:-}" in
    help|-h|--help) show_help; exit 0 ;;
    status) show_status; exit 0 ;;
    models-update) models_update_cmd; exit $? ;;
    models-show) models_show_cmd; exit $? ;;
    menu) is_installed && maintenance_menu || init_wizard ;;
    reconfigure) init_wizard ;;
    repair) : ;;
    uninstall|uninstall-all) : ;;  # 交给下方卸载逻辑
    '')
        if is_tty; then
            if is_installed; then maintenance_menu; else init_wizard; fi
        fi
        ;;
    *) die "未知参数：${1:-}。执行 $0 help 查看帮助" ;;
esac

# ---------------------------------------------------------------- 卸载
case "${1:-}" in
uninstall)
    step "卸载核心网络服务"
    if [ -x "$SBIN/supervisor-rpc.py" ]; then
        "$SBIN/supervisor-rpc.py" stop net-services >/dev/null 2>&1 || true
        rm -f "$SV_CONF"
        "$SBIN/supervisor-rpc.py" reload >/dev/null 2>&1 || true
    fi
    pkill -f 'net-services-daemon.sh' 2>/dev/null || true
    pkill -f 'net-services-watchdog.sh' 2>/dev/null || true
    rm -f "$SBIN"/{start-net-services,ensure-relay,net-services-watchdog,ensure-net-services,net-services-daemon,start-all}.sh \
          "$SBIN/update-codebuddy-models" "$CONF" /etc/profile.d/99-net-services.sh /etc/ssh/sshd_config.d/99-net-services.conf \
          /root/.bashrc.d/00-cs-token.sh /root/.zshrc.d/00-cs-token.sh \
          /root/.bashrc.d/99-net-services.sh /root/.zshrc.d/99-net-services.sh
    ok "核心服务已清理"
    say "  netapp 和你后来添加的应用已保留；如需全部删除：$0 uninstall-all"
    exit 0
    ;;
uninstall-all)
    step "卸载全部（包括 netapp 托管应用）"
    if [ -x "$NETAPP_BIN" ]; then
        "$NETAPP_BIN" purge --yes >/dev/null 2>&1 || true
    fi
    if [ -x "$SBIN/supervisor-rpc.py" ]; then
        "$SBIN/supervisor-rpc.py" stop net-services >/dev/null 2>&1 || true
    fi
    rm -f "$SV_CONF" "$SV_CONF_DIR"/app-*.conf
    [ -x "$SBIN/supervisor-rpc.py" ] && "$SBIN/supervisor-rpc.py" reload >/dev/null 2>&1 || true
    pkill -f 'net-services-daemon.sh' 2>/dev/null || true
    pkill -f 'net-services-watchdog.sh' 2>/dev/null || true
    rm -f "$SBIN"/{start-net-services,ensure-relay,net-services-watchdog,ensure-net-services,net-services-daemon,start-all}.sh \
          "$SBIN/update-codebuddy-models" "$SBIN/supervisor-rpc.py" "$NETAPP_BIN" "$CSINIT_BIN" "$CONF" \
          /etc/profile.d/99-net-services.sh /etc/ssh/sshd_config.d/99-net-services.conf \
          /root/.bashrc.d/00-cs-token.sh /root/.zshrc.d/00-cs-token.sh \
          /root/.bashrc.d/99-net-services.sh /root/.zshrc.d/99-net-services.sh
    rm -rf "$NETAPP_HOME" "$NETAPP_META" "$NETAPP_LOG"
    ok "已全部清理（relay.js 与 /root/.cs-token、/root/.relay-key 保留）"
    exit 0
    ;;
esac

# ---------------------------------------------------------------- 前置检查
step "前置检查"
[ "$(id -u)" = 0 ] || die "必须用 root 跑"

PID1=$(ps -p 1 -o comm= 2>/dev/null || echo unknown)
case "$PID1" in
    supervisord) HAVE_SV=yes ;;
    *)           HAVE_SV=no  ;;
esac
say "  PID 1           : $PID1"
say "  supervisord 托管: $HAVE_SV"

[ -r /var/run/cloudstudio/space.yaml ] \
    && ok "检测到 CloudStudio 环境，防休眠心跳可用" \
    || warn "没找到 /var/run/cloudstudio/space.yaml，跳过防休眠心跳（非 CloudStudio 环境无妨）"

command -v node  >/dev/null || warn "缺少 node，将尝试自动安装"
command -v curl  >/dev/null || warn "缺少 curl，将尝试自动安装"

# ---------------------------------------------------------------- 依赖
step "依赖检查"
install_pkg() {
    local cmd=$1 pkg=$2
    # sshd 这类只在 /usr/sbin 里的命令，非 root 的 PATH 下 command -v 可能查不到
    if command -v "$cmd" >/dev/null 2>&1 || [ -x "/usr/sbin/$cmd" ] || [ -x "/usr/bin/$cmd" ]; then
        ok "$cmd 已安装"; return 0
    fi
    say "  $cmd 缺失，尝试安装 $pkg ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "$pkg" >/dev/null 2>&1 && { ok "$pkg 安装完成"; return 0; }
    fi
    warn "$pkg 自动安装失败，请手工安装后重跑本脚本"
    return 1
}
install_pkg sshd openssh-server || die "openssh-server 安装失败"
install_pkg curl curl || warn "curl 安装失败，healthz 心跳不可用"
install_pkg node nodejs || die "nodejs 安装失败，CodeBuddy 反代无法运行"
install_pkg python3 python3 || die "python3 安装失败，Supervisor RPC 管理器无法运行"
install_pkg pgrep procps || die "procps 安装失败，看门狗无法检查进程"
install_pkg setsid util-linux || die "util-linux 安装失败，后台进程无法正确脱离会话"
install_pkg timeout coreutils || die "coreutils 安装失败，超时保护不可用"
install_tailscale_static() {
    local machine arch page file ver url tmpdir srcdir tsbin tsdbin expected actual
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l|armv6l) arch=arm ;;
        i386|i686) arch=386 ;;
        *) warn "当前 CPU 架构暂不支持自动静态安装 Tailscale：$machine"; log_install "tailscale static FAIL unsupported arch=$machine"; return 1 ;;
    esac

    log_install "tailscale static install begin arch=$arch"
    page=$(curl -fsSL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 60 https://pkgs.tailscale.com/stable/ 2>>"$INSTALL_LOG") \
        || { warn "无法访问 Tailscale 官方 stable 页面"; log_install "tailscale static FAIL fetch index"; return 1; }
    file=$(printf '%s' "$page" | grep -oE "tailscale_[0-9]+\.[0-9]+\.[0-9]+_${arch}\.tgz" | awk '!seen[$0]++' | head -1)
    [ -n "$file" ] || { warn "无法从官方 stable 页面解析 Tailscale 静态包"; log_install "tailscale static FAIL parse package"; return 1; }
    ver=${file#tailscale_}; ver=${ver%_${arch}.tgz}
    url="https://pkgs.tailscale.com/stable/$file"
    tmpdir=$(mktemp -d /tmp/cs-tailscale.XXXXXX) \
        || { warn "无法创建 Tailscale 临时目录"; log_install "tailscale static FAIL mktemp"; return 1; }

    say "  下载 Tailscale $ver ($arch) 官方静态包 ..."
    if ! curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 300 "$url" -o "$tmpdir/$file" 2>>"$INSTALL_LOG"; then
        warn "Tailscale 静态包下载失败：$url"
        log_install "tailscale static FAIL download url=$url"
        rm -rf "$tmpdir"
        return 1
    fi

    # 官方 checksum 页面可能带文件名/URL；只提取 64 位 SHA256，避免 sha256sum -c 的文件名格式差异。
    expected=$(curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 30 "$url.sha256" 2>>"$INSTALL_LOG" \
        | grep -oE '[A-Fa-f0-9]{64}' | head -1 || true)
    if [ -n "$expected" ]; then
        actual=$(sha256sum "$tmpdir/$file" | awk '{print $1}')
        if [ "${actual,,}" != "${expected,,}" ]; then
            warn "Tailscale 静态包 SHA256 校验失败"
            log_install "tailscale static FAIL sha256 expected=$expected actual=$actual"
            rm -rf "$tmpdir"
            return 1
        fi
        log_install "tailscale static sha256 OK"
    else
        warn "未能读取官方 SHA256；继续用 tar 完整性 + 二进制自检验证"
        log_install "tailscale static WARN checksum unavailable"
    fi

    if ! tar -tzf "$tmpdir/$file" >/dev/null 2>>"$INSTALL_LOG"; then
        warn "Tailscale 静态包损坏，tar 完整性检查失败"
        log_install "tailscale static FAIL tar integrity"
        rm -rf "$tmpdir"
        return 1
    fi
    if ! tar -xzf "$tmpdir/$file" -C "$tmpdir" 2>>"$INSTALL_LOG"; then
        warn "Tailscale 静态包解压失败"
        log_install "tailscale static FAIL extract"
        rm -rf "$tmpdir"
        return 1
    fi

    # 不假设压缩包内部目录名，直接定位两个官方二进制。
    tsbin=$(find "$tmpdir" -type f -name tailscale -perm -u+x -print -quit 2>/dev/null)
    tsdbin=$(find "$tmpdir" -type f -name tailscaled -perm -u+x -print -quit 2>/dev/null)
    [ -n "$tsbin" ] && [ -n "$tsdbin" ] \
        || { warn "Tailscale 静态包内未找到 tailscale/tailscaled"; log_install "tailscale static FAIL binaries missing"; rm -rf "$tmpdir"; return 1; }

    mkdir -p /usr/local/bin /usr/local/sbin
    install -m 0755 "$tsbin" /usr/local/bin/tailscale \
        || { warn "安装 tailscale CLI 失败"; log_install "tailscale static FAIL install cli"; rm -rf "$tmpdir"; return 1; }
    install -m 0755 "$tsdbin" /usr/local/sbin/tailscaled \
        || { warn "安装 tailscaled 失败"; log_install "tailscale static FAIL install daemon"; rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
    hash -r 2>/dev/null || true

    if ! /usr/local/bin/tailscale version >>"$INSTALL_LOG" 2>&1 || ! /usr/local/sbin/tailscaled --version >>"$INSTALL_LOG" 2>&1; then
        warn "Tailscale 二进制安装后自检失败"
        log_install "tailscale static FAIL post-install version check"
        return 1
    fi

    ok "Tailscale $ver 静态版安装完成（CLI + daemon，未注册 systemd/系统服务）"
    log_install "tailscale static install done version=$ver cli=/usr/local/bin/tailscale daemon=/usr/local/sbin/tailscaled"
    return 0
}

if ! command -v tailscaled >/dev/null 2>&1 || ! command -v tailscale >/dev/null 2>&1; then
    warn "Tailscale 组件不完整（tailscale/tailscaled 任一缺失）；CloudStudio 使用官方静态二进制补齐"
    if command -v curl >/dev/null 2>&1; then
        install_tailscale_static || warn "Tailscale 静态安装失败；其它组件继续安装，稍后可 cs-init repair 重试"
    fi
else
    ok "Tailscale CLI : $(command -v tailscale)"
    ok "Tailscale daemon: $(command -v tailscaled)"
fi

# ---------------------------------------------------------------- 配置
step "写入配置"

# 反代密钥：没给就生成，生成过就沿用，避免重装后客户端全部失效
if [ -z "$RELAY_KEY" ]; then
    if [ -s "$KEY_FILE" ]; then
        RELAY_KEY=$(cat "$KEY_FILE")
        ok "沿用已有反代密钥（$KEY_FILE）"
    else
        RELAY_KEY=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
        printf '%s\n' "$RELAY_KEY" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        ok "已生成随机反代密钥 -> $KEY_FILE"
    fi
else
    printf '%s\n' "$RELAY_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    ok "使用指定的反代密钥"
fi

# 已有令牌文件就沿用（避免每次都要重新导出环境变量）
if [ -z "$CS_HEALTHZ_TOKEN" ] && [ -s "$TOKEN_FILE" ]; then
    CS_HEALTHZ_TOKEN=$(sed -n 's/^export CS_HEALTHZ_TOKEN=//p' "$TOKEN_FILE")
    ok "沿用已有心跳令牌（$TOKEN_FILE）"
fi

{
    echo '# 由 cs-init 生成；使用 shell 安全转义，可被服务脚本 source'
    printf 'RELAY_PORT=%q\n' "$RELAY_PORT"
    printf 'RELAY_HOST=%q\n' "$RELAY_HOST"
    printf 'RELAY_KEY=%q\n' "$RELAY_KEY"
    printf 'SSH_PORT=%q\n' "$SSH_PORT"
    printf 'SSH_LISTEN=%q\n' "$SSH_LISTEN"
    printf 'MODELS_FILE=%q\n' "$MODELS_FILE"
    printf 'UPSTREAM_BASE=%q\n' "$UPSTREAM_BASE"
    printf 'UPSTREAM_AUTH_MODE=%q\n' "$UPSTREAM_AUTH_MODE"
    printf 'UPSTREAM_TOKEN=%q\n' "$UPSTREAM_TOKEN"
    printf 'MODELS_MODE=%q\n' "$MODELS_MODE"
    printf 'STREAM_ADAPT=%q\n' "$STREAM_ADAPT"
} > "$CONF"
chmod 600 "$CONF"
ok "$CONF"
log_install "配置已写入 $CONF"

if [ -n "$CS_HEALTHZ_TOKEN" ]; then
    printf 'export CS_HEALTHZ_TOKEN=%s\n' "$CS_HEALTHZ_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    ok "心跳令牌已写入 $TOKEN_FILE"
    for d in /root/.bashrc.d /root/.zshrc.d; do
        mkdir -p "$d"
        cat > "$d/00-cs-token.sh" <<'EOF'
# nosleep 心跳令牌（真正的令牌在 ~/.cs-token，权限 600，此处只做加载）
[ -r "$HOME/.cs-token" ] && . "$HOME/.cs-token"
EOF
    done
    ok "shell rc 加载器 /root/.{bashrc,zshrc}.d/00-cs-token.sh"
fi

# ---------------------------------------------------------------- CodeBuddy 国内模型拉取器
step "安装 CodeBuddy 聚合模型更新器（接口权威 + 多官网页补充）"
cat > "$SBIN/update-codebuddy-models" <<'MODELS_EOF'
#!/bin/bash
set -uo pipefail

CONF=/etc/net-services.conf
[ -r "$CONF" ] && . "$CONF"
MODELS_FILE="${MODELS_FILE:-/workspace/models.json}"
CONFIG_URL="${CODEBUDDY_CONFIG_URL:-http://auth.proxy/codebuddy/v3/config}"
CONFIG_TOKEN="${CODEBUDDY_CONFIG_TOKEN:-auto_proxy_token}"
STATE=/var/lib/net-services/models-last-attempt
LOG=/var/log/codebuddy-models-update.log
STALE_SECONDS="${CODEBUDDY_MODELS_STALE_SECONDS:-21600}"
MODE="${1:-force}"

# 官网只做补充；多个腾讯 CodeBuddy 官方模型页做并集。
# 如需覆盖，使用分号分隔：CODEBUDDY_OFFICIAL_MODELS_URLS='url1;url2;url3'
if [ -n "${CODEBUDDY_OFFICIAL_MODELS_URLS:-}" ]; then
    IFS=';' read -r -a OFFICIAL_URLS <<< "$CODEBUDDY_OFFICIAL_MODELS_URLS"
else
    OFFICIAL_URLS=(
      'https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Model'
      'https://www.codebuddy.cn/docs/workbuddyapp/features/Model'
      'https://www.codebuddy.cn/docs/workbuddymini/features/Select-Model'
    )
fi

mkdir -p "$(dirname "$MODELS_FILE")" /var/lib/net-services
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

if [ "$MODE" = "--if-stale" ]; then
    now=$(date +%s)
    last=$(cat "$STATE" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0;; esac
    if [ $((now-last)) -lt "$STALE_SECONDS" ] && [ -s "$MODELS_FILE" ]; then
        exit 0
    fi
fi

date +%s > "$STATE" 2>/dev/null || true
TMP=$(mktemp -d /tmp/codebuddy-models.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
RAW="$TMP/config.json"
MANIFEST="$TMP/official.tsv"
OUT="$TMP/models.json"
: > "$MANIFEST"

if ! command -v curl >/dev/null 2>&1; then
    log "curl missing; keeping existing model file"
    echo "[warn] curl 不存在，无法刷新 CodeBuddy 模型；保留现有 $MODELS_FILE" >&2
    exit 1
fi

# 1) /v3/config 是绝对权威数据源。拉取失败时不允许用官网单独重建列表。
HTTP=$(curl -sS -o "$RAW" -w '%{http_code}' \
    --retry 3 --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $CONFIG_TOKEN" \
    -H 'Accept: application/json' \
    -H 'User-Agent: CLI/unknown CodeBuddy/2.136.0' \
    -H 'X-Product: SaaS' \
    "$CONFIG_URL" 2>>"$LOG" || true)

if [ "$HTTP" != "200" ] || [ ! -s "$RAW" ]; then
    log "authoritative config fetch failed http=${HTTP:-curl_error} url=$CONFIG_URL; keeping existing file"
    echo "[warn] CodeBuddy 权威配置接口拉取失败 HTTP=${HTTP:-curl_error}；保留现有 $MODELS_FILE" >&2
    exit 1
fi

# 2) 多个 CodeBuddy 官方模型页只做补充。任一页面失败都不影响权威接口结果。
official_ok=0
idx=0
for url in "${OFFICIAL_URLS[@]}"; do
    [ -n "$url" ] || continue
    idx=$((idx+1))
    html="$TMP/official-$idx.html"
    code=$(curl -sS -L -o "$html" -w '%{http_code}' \
        --retry 2 --connect-timeout 10 --max-time 30 \
        -H 'Accept: text/html,application/xhtml+xml' \
        -H 'User-Agent: Mozilla/5.0 CodeBuddyModelsUpdater/1.1' \
        "$url" 2>>"$LOG" || true)
    if [ "$code" = "200" ] && [ -s "$html" ]; then
        printf '%s\t%s\n' "$url" "$html" >> "$MANIFEST"
        official_ok=$((official_ok+1))
        log "official page fetch OK url=$url"
    else
        rm -f "$html"
        log "official page fetch unavailable http=${code:-curl_error} url=$url; continuing"
    fi
done

if [ "$official_ok" -eq 0 ]; then
    log "all official pages unavailable; authoritative list will still be used"
fi

if ! python3 - "$RAW" "$MANIFEST" "$OUT" <<'PY_PARSE_MODELS'
import html as htmlmod
import json, re, sys, time
from html.parser import HTMLParser

raw_path, manifest_path, out_path = sys.argv[1:4]
with open(raw_path, 'r', encoding='utf-8') as f:
    root = json.load(f)

if root.get('code') != 0:
    raise SystemExit('CodeBuddy config code is not 0')
data = root.get('data') or {}
agents = data.get('agents') or []
cli = next((a for a in agents if a.get('name') == 'cli'), None)
if not cli:
    raise SystemExit('cli agent not found')
allowed = cli.get('models') or []
if not isinstance(allowed, list) or not allowed:
    raise SystemExit('cli model list empty')

catalog = {}
for m in data.get('models') or []:
    mid = m.get('id')
    if isinstance(mid, str) and mid:
        catalog[mid] = m

# 权威列表：严格按照 agents[name=cli].models，绝不被官网覆盖、重命名或删除。
items = []
seen = set()
for mid in allowed:
    if not isinstance(mid, str) or not mid or mid in seen:
        continue
    seen.add(mid)
    meta = catalog.get(mid, {})
    item = {
        'id': mid,
        'object': 'model',
        'created': 0,
        'owned_by': 'codebuddy-cn',
        'source': 'v3-config',
    }
    for key in (
        'name','vendor','credits','descriptionZh','descriptionEn',
        'maxAllowedSize','maxInputTokens','maxOutputTokens',
        'supportsImages','supportsReasoning','supportsToolCall','onlyReasoning',
        'temperature','top_p','reasoning','relatedModels'
    ):
        if key in meta:
            item[key] = meta[key]
    items.append(item)

authoritative_count = len(items)
if not items:
    raise SystemExit('no valid cli models')

class OfficialModelTableParser(HTMLParser):
    """只解析官方“内置模型 / 可用模型一览”章节中的表格。"""
    TARGET_TITLES = ('内置模型', '可用模型一览')

    def __init__(self):
        super().__init__()
        self.in_heading = False
        self.heading_tag = ''
        self.heading_buf = []
        self.target_section = False
        self.in_table = False
        self.target_table = False
        self.in_row = False
        self.in_cell = False
        self.cell_buf = []
        self.row = []
        self.target_rows = []
        self.all_tables = []
        self.current_table_rows = []

    @staticmethod
    def _attrs_dict(attrs):
        return {k: v for k, v in attrs}

    def handle_starttag(self, tag, attrs):
        t = tag.lower()
        if t in ('h1','h2','h3','h4','h5','h6'):
            self.in_heading = True
            self.heading_tag = t
            self.heading_buf = []
        elif t == 'table':
            self.in_table = True
            self.target_table = self.target_section
            self.current_table_rows = []
        elif t == 'tr' and self.in_table:
            self.in_row = True
            self.row = []
        elif t in ('td','th') and self.in_row:
            self.in_cell = True
            self.cell_buf = []

    def handle_data(self, data):
        if self.in_heading:
            self.heading_buf.append(data)
        if self.in_cell:
            self.cell_buf.append(data)

    def handle_endtag(self, tag):
        t = tag.lower()
        if t in ('td','th') and self.in_cell:
            text = ' '.join(''.join(self.cell_buf).split())
            self.row.append(text)
            self.in_cell = False
            self.cell_buf = []
        elif t == 'tr' and self.in_row:
            if any(self.row):
                self.current_table_rows.append(self.row[:])
                if self.target_table:
                    self.target_rows.append(self.row[:])
            self.in_row = False
            self.row = []
        elif t == 'table' and self.in_table:
            if self.current_table_rows:
                self.all_tables.append(self.current_table_rows[:])
            self.in_table = False
            self.target_table = False
            self.current_table_rows = []
        elif t in ('h1','h2','h3','h4','h5','h6') and self.in_heading:
            title = ' '.join(''.join(self.heading_buf).split())
            # 新标题出现即结束上一个章节；只有明确目标标题才打开模型章节。
            self.target_section = any(key in title for key in self.TARGET_TITLES)
            self.in_heading = False
            self.heading_tag = ''
            self.heading_buf = []


def looks_like_model_name(s):
    return bool(re.fullmatch(
        r'(?:Auto|Hy\d(?:[- ](?:preview|[A-Za-z0-9.]+))?|GLM-[A-Za-z0-9.\-]+|MiniMax-[A-Za-z0-9.\-]+|Kimi-[A-Za-z0-9.\-]+|Deep[Ss]eek-[A-Za-z0-9.\-]+)',
        s.strip(), re.I
    ))


def normalize_official_id(name):
    s = htmlmod.unescape(name).strip().lower()
    s = re.sub(r'\s+', '-', s)
    s = re.sub(r'[^a-z0-9.\-]+', '-', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s


def _names_from_rows(rows):
    names = []
    for row in rows:
        if not row:
            continue
        first = (row[0] or '').strip()
        # 表头不是模型。
        if first in ('模型', '模型名称'):
            continue
        if looks_like_model_name(first):
            names.append(first)
    return names


def extract_names(text):
    if not text:
        return []
    p = OfficialModelTableParser()
    try:
        p.feed(text)
    except Exception:
        pass

    # 首选：明确处于“内置模型 / 可用模型一览”章节中的表格。
    names = _names_from_rows(p.target_rows)
    if names:
        return names

    # 页面标题/DOM 轻微变化时，只允许从“模型/模型名称”为表头的表格中兜底；
    # 绝不扫描整页正文，避免把“GLM-5 模型为例”之类说明文字误识别为模型。
    safe = []
    for rows in p.all_tables:
        if not rows:
            continue
        header = [str(x).strip() for x in rows[0]]
        if not header or header[0] not in ('模型', '模型名称'):
            continue
        safe.extend(_names_from_rows(rows[1:]))
    return safe

# 官网多页面并集。相同规范化 ID 记录所有来源 URL。
official = {}
official_pages = []
try:
    manifest_lines = open(manifest_path, 'r', encoding='utf-8', errors='ignore').read().splitlines()
except Exception:
    manifest_lines = []

for line in manifest_lines:
    if '\t' not in line:
        continue
    url, path = line.split('\t', 1)
    try:
        text = open(path, 'r', encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    official_pages.append(url)
    for name in extract_names(text):
        oid = normalize_official_id(name)
        if not oid:
            continue
        rec = official.setdefault(oid, {'name': name, 'urls': []})
        if url not in rec['urls']:
            rec['urls'].append(url)

extra = []
for oid, rec in official.items():
    if oid in seen:
        continue
    seen.add(oid)
    item = {
        'id': oid,
        'object': 'model',
        'created': 0,
        'owned_by': 'codebuddy-cn',
        'name': rec['name'],
        'source': 'official-website-extra',
        'official_urls': rec['urls'],
    }
    if rec['urls']:
        item['official_url'] = rec['urls'][0]
    items.append(item)
    extra.append(oid)

out = {
    'object': 'list',
    'data': items,
    'codebuddy': {
        'authoritative_source': 'v3/config',
        'authoritative_agent': 'cli',
        'authoritative_count': authoritative_count,
        'official_extra_sources': official_pages,
        'official_pages_ok': len(official_pages),
        'official_discovered_count': len(official),
        'official_extra_count': len(extra),
        'official_extra_ids': extra,
        'total_count': len(items),
        'updated_at': int(time.time()),
    }
}
with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(json.dumps({
    'authoritative': authoritative_count,
    'official_pages_ok': len(official_pages),
    'official_discovered': len(official),
    'official_extra': len(extra),
    'total': len(items),
    'extra_ids': extra,
}, ensure_ascii=False))
PY_PARSE_MODELS
then
    log "model merge/parse failed; keeping existing file"
    echo "[warn] CodeBuddy 模型合并解析失败；保留现有 $MODELS_FILE" >&2
    exit 1
fi

if ! python3 - "$OUT" <<'PY_VALIDATE_MODELS' >/dev/null 2>&1
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
assert j.get('object')=='list'
cb=j.get('codebuddy',{})
assert cb.get('authoritative_source')=='v3/config'
ids=[x.get('id') for x in j.get('data',[])]
assert ids and all(ids) and len(ids)==len(set(ids))
assert cb.get('authoritative_count',0) > 0
assert cb.get('total_count') == len(ids)
PY_VALIDATE_MODELS
then
    log "generated JSON validation failed; keeping existing file"
    echo "[warn] models.json 校验失败；保留旧文件" >&2
    exit 1
fi

install -m 0644 "$OUT" "$MODELS_FILE"
read -r auth_count pages_count discovered_count extra_count total_count < <(python3 - "$MODELS_FILE" <<'PY_COUNT_MODELS'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
c=j.get('codebuddy',{})
print(c.get('authoritative_count',0), c.get('official_pages_ok',0), c.get('official_discovered_count',0), c.get('official_extra_count',0), c.get('total_count',0))
PY_COUNT_MODELS
)
log "models updated authoritative=$auth_count official_pages=$pages_count official_discovered=$discovered_count official_extra=$extra_count total=$total_count file=$MODELS_FILE"
echo "[ok] CodeBuddy 模型已更新：接口权威 $auth_count 个 + 官网额外 $extra_count 个 = $total_count 个（官网成功 $pages_count 页，发现 $discovered_count 个正式名称） -> $MODELS_FILE"
python3 - "$MODELS_FILE" <<'PY_PRINT_MODELS'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
for x in j.get('data',[]):
    name=x.get('name') or ''
    credits=x.get('credits') or ''
    source=x.get('source') or ''
    extra=' | '.join(v for v in (name,credits,source) if v)
    print('  ' + x['id'] + (('  ['+extra+']') if extra else ''))
PY_PRINT_MODELS
MODELS_EOF
chmod 755 "$SBIN/update-codebuddy-models"
ok "$SBIN/update-codebuddy-models"

if [ "$MODELS_MODE" = local ]; then
    if "$SBIN/update-codebuddy-models"; then
        ok "本地 models.json 已从 CodeBuddy 后端真实配置刷新"
    else
        warn "CodeBuddy 模型拉取失败；若已有 models.json 会继续沿用"
    fi
fi

# ---------------------------------------------------------------- 反代代码
step "写入反代 $RELAY_JS"
mkdir -p "$(dirname "$RELAY_JS")"
cat > "$RELAY_JS" <<'RELAY_EOF'
#!/usr/bin/env node
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');

const HOST = process.env.RELAY_HOST || '127.0.0.1';
const PORT = Number(process.env.RELAY_PORT || 65530);
const KEY = process.env.RELAY_KEY || '';
const MODELS_FILE = process.env.MODELS_FILE || '/workspace/models.json';
const UPSTREAM_BASE = process.env.UPSTREAM_BASE || 'http://auth.proxy/codebuddy/v2';
const UPSTREAM_AUTH_MODE = (process.env.UPSTREAM_AUTH_MODE || 'bearer').toLowerCase();
const UPSTREAM_TOKEN = process.env.UPSTREAM_TOKEN || 'auto_proxy_token';
const MODELS_MODE = (process.env.MODELS_MODE || 'local').toLowerCase();
const STREAM_ADAPT = (process.env.STREAM_ADAPT || 'true').toLowerCase() !== 'false';
const MAX_BODY = 32 * 1024 * 1024;

let upstream;
try {
  upstream = new URL(UPSTREAM_BASE);
} catch (e) {
  console.error('invalid UPSTREAM_BASE:', UPSTREAM_BASE, e.message);
  process.exit(2);
}
if (!['http:', 'https:'].includes(upstream.protocol)) {
  console.error('UPSTREAM_BASE only supports http/https');
  process.exit(2);
}
const client = upstream.protocol === 'https:' ? https : http;

const HOP = new Set([
  'connection','keep-alive','proxy-authenticate','proxy-authorization',
  'te','trailer','transfer-encoding','upgrade','proxy-connection',
]);

function copyHeaders(src) {
  const out = {};
  for (const k of Object.keys(src)) if (!HOP.has(k.toLowerCase())) out[k] = src[k];
  return out;
}

function basePath() {
  let p = upstream.pathname || '/';
  if (p.length > 1) p = p.replace(/\/+$/, '');
  return p;
}

function mapPath(rawUrl) {
  const u = new URL(rawUrl, 'http://local');
  let suffix = u.pathname;
  if (suffix === '/v1') suffix = '';
  else if (suffix.startsWith('/v1/')) suffix = suffix.slice(3);
  const bp = basePath();
  let path = (bp === '/' ? '' : bp) + (suffix || '');
  if (!path) path = '/';
  return path + u.search;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks=[]; let size=0;
    req.on('data', c => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('request body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function unauthorized(res) {
  res.writeHead(401, {'content-type':'application/json'});
  res.end(JSON.stringify({error:{message:'invalid api key',type:'authentication_error',code:401}}));
}

let modelsCache={mtime:-1,body:null};
function loadModels() {
  try {
    const st=fs.statSync(MODELS_FILE);
    if (st.mtimeMs !== modelsCache.mtime) modelsCache={mtime:st.mtimeMs,body:fs.readFileSync(MODELS_FILE,'utf8')};
    return modelsCache.body;
  } catch { return null; }
}

function aggregateSSE(upRes, res) {
  const acc={id:null,model:null,created:null,content:'',reasoning:'',finish:null,usage:null};
  let buf='';
  const takeLine=line=>{
    if (!line.startsWith('data:')) return;
    const payload=line.slice(5).trim();
    if (!payload || payload==='[DONE]') return;
    let j; try { j=JSON.parse(payload); } catch { return; }
    if (j.id) acc.id=j.id; if (j.model) acc.model=j.model; if (j.created) acc.created=j.created;
    const ch=j.choices && j.choices[0];
    if (ch) {
      if (ch.delta) {
        if (typeof ch.delta.content==='string') acc.content+=ch.delta.content;
        if (typeof ch.delta.reasoning_content==='string') acc.reasoning+=ch.delta.reasoning_content;
      }
      if (ch.finish_reason) acc.finish=ch.finish_reason;
    }
    if (j.usage) acc.usage=j.usage;
  };
  upRes.setEncoding('utf8');
  upRes.on('data', chunk=>{ buf+=chunk; let i; while ((i=buf.indexOf('\n'))!==-1) { takeLine(buf.slice(0,i).trim()); buf=buf.slice(i+1); } });
  upRes.on('end', ()=>{
    takeLine(buf.trim());
    const message={role:'assistant',content:acc.content}; if (acc.reasoning) message.reasoning_content=acc.reasoning;
    const body=JSON.stringify({id:acc.id,object:'chat.completion',created:acc.created,model:acc.model,choices:[{index:0,message,finish_reason:acc.finish||'stop'}],usage:acc.usage});
    res.writeHead(200, {'content-type':'application/json; charset=utf-8','content-length':Buffer.byteLength(body)});
    res.end(body);
  });
}

const server=http.createServer(async (req,res)=>{
  const auth=String(req.headers.authorization||'');
  const presented=auth.toLowerCase().startsWith('bearer ')?auth.slice(7).trim():'';
  if (!KEY || presented!==KEY) return unauthorized(res);

  const incomingPath = new URL(req.url, 'http://local').pathname;
  if (req.method==='GET' && incomingPath==='/v1/models' && MODELS_MODE==='local') {
    const body=loadModels();
    if (!body) {
      res.writeHead(404, {'content-type':'application/json'});
      return res.end(JSON.stringify({error:{message:`model list unavailable: ${MODELS_FILE} missing`,type:'not_found',code:404}}));
    }
    res.writeHead(200, {'content-type':'application/json; charset=utf-8','content-length':Buffer.byteLength(body)});
    return res.end(body);
  }

  const target=mapPath(req.url);
  const needRewrite=STREAM_ADAPT && req.method==='POST' && incomingPath==='/v1/chat/completions' && /application\/json/i.test(req.headers['content-type']||'');
  let body; let aggregate=false;
  if (needRewrite) {
    try { body=await readBody(req); } catch (e) {
      res.writeHead(413, {'content-type':'application/json'});
      return res.end(JSON.stringify({error:{message:e.message,type:'invalid_request_error',code:413}}));
    }
    try {
      const j=JSON.parse(body.toString('utf8'));
      if (j && typeof j==='object' && j.stream!==true) { j.stream=true; aggregate=true; body=Buffer.from(JSON.stringify(j),'utf8'); }
    } catch {}
  }

  const headers=copyHeaders(req.headers);
  headers.host=upstream.host;
  if (UPSTREAM_AUTH_MODE==='bearer') headers.authorization=`Bearer ${UPSTREAM_TOKEN}`;
  else delete headers.authorization;
  if (body) headers['content-length']=String(body.length);

  const opts={protocol:upstream.protocol,hostname:upstream.hostname,port:upstream.port || undefined,method:req.method,path:target,headers};
  const up=client.request(opts, upRes=>{
    const ct=String(upRes.headers['content-type']||'');
    if (aggregate && upRes.statusCode===200 && /text\/event-stream/i.test(ct)) return aggregateSSE(upRes,res);
    res.writeHead(upRes.statusCode || 502, copyHeaders(upRes.headers));
    upRes.pipe(res);
  });
  up.on('error', e=>{
    console.error(`[${new Date().toISOString()}] ${req.method} ${target} -> ${e.message}`);
    if (res.headersSent) return res.destroy();
    res.writeHead(502, {'content-type':'application/json'});
    res.end(JSON.stringify({error:{message:`upstream error: ${e.message}`,type:'upstream_error',code:502}}));
  });
  req.on('error',()=>up.destroy()); res.on('close',()=>up.destroy());
  if (body) up.end(body); else req.pipe(up);
});

server.listen(PORT, HOST, ()=>{
  console.log(`relay up: http://${HOST}:${PORT}/v1 -> ${UPSTREAM_BASE}`);
});
RELAY_EOF
ok "relay.js（${RELAY_PORT} 端口）"

# ---------------------------------------------------------------- 服务脚本
step "写入服务脚本"

cat > "$SBIN/start-net-services.sh" <<'EOF'
#!/bin/bash
# 幂等启动 sshd 与 tailscaled。可反复调用，已运行则跳过。
# tailscaled 必须跑 userspace-networking：容器内无 /dev/net/tun 且 mknod 被拒。

LOG=/var/log/net-services.log
[ -r /etc/net-services.conf ] && . /etc/net-services.conf
SSH_PORT="${SSH_PORT:-22}"
SSH_LISTEN="${SSH_LISTEN:-127.0.0.1}"

log() { echo "$(date '+%F %T') [$$] $*" >>"$LOG" 2>/dev/null; }

# ---------- sshd ----------
if pgrep -x sshd >/dev/null 2>&1; then
    log "sshd 已在运行，跳过"
else
    # 首次安装可能没有 host key
    ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A >/dev/null 2>&1
    mkdir -p /run/sshd
    if /usr/sbin/sshd -p "$SSH_PORT"; then
        log "sshd 启动成功 (port $SSH_PORT)"
    else
        log "sshd 启动失败"
    fi
fi

# ---------- tailscaled ----------
if pgrep -x tailscaled >/dev/null 2>&1; then
    log "tailscaled 已在运行，跳过"
else
    mkdir -p /run/tailscale /var/lib/tailscale
    # setsid：脱离调用方进程组，避免看门狗所在进程组被整体 kill 时把 tailscaled 一起带走
    TS_DAEMON=$(command -v tailscaled 2>/dev/null || true)
    TS_CLI=$(command -v tailscale 2>/dev/null || true)
    [ -n "$TS_DAEMON" ] || { log "找不到 tailscaled"; exit 0; }
    nohup setsid "$TS_DAEMON" \
        --tun=userspace-networking \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/run/tailscale/tailscaled.sock \
        --port=41641 \
        >>/var/log/tailscaled.log 2>&1 &
    log "tailscaled 已拉起 (userspace-networking)"

    for _ in $(seq 1 30); do
        [ -S /run/tailscale/tailscaled.sock ] && break
        sleep 0.5
    done

    # 已授权的 node key 保存在 state 文件里，重启后无需再次浏览器授权。
    # 加 timeout 防止未授权时阻塞调用方。
    if [ -S /run/tailscale/tailscaled.sock ]; then
        if [ -n "$TS_CLI" ] && timeout 30 "$TS_CLI" up >>"$LOG" 2>&1; then
            log "tailscale up 成功"
        else
            log "tailscale up 未成功（可能需要浏览器授权）"
        fi
    else
        log "tailscaled socket 未就绪，跳过 up"
    fi
fi

# ---------- tailscale SSH TCP forwarder ----------
# userspace-networking 没有内核 tailscale0；SSH 也通过 tailscale serve 暴露。
if pgrep -x tailscaled >/dev/null 2>&1 && command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1; then
        if ! tailscale serve status --json 2>/dev/null | grep -q "\"$SSH_PORT\""; then
            timeout 20 tailscale serve --bg --tcp "$SSH_PORT" "tcp://127.0.0.1:$SSH_PORT" >>"$LOG" 2>&1 \
                && log "tailscale SSH serve --tcp $SSH_PORT 已设置" \
                || log "tailscale SSH serve --tcp $SSH_PORT 设置失败"
        fi
    fi
fi

exit 0
EOF

cat > "$SBIN/ensure-relay.sh" <<'EOF'
#!/bin/bash
# 确保 codebuddy 反代活着。幂等，可反复调用（由看门狗每 60s 调用一次）。
#
# 两层：
#   1. node /workspace/relay.js  只监听 127.0.0.1
#   2. tailscale serve --tcp     把 <tailscale-ip>:<port> 转发到 127.0.0.1:<port>
#      因为 tailscaled 跑在 userspace-networking 模式，内核无 tailscale0 网卡，
#      进程无法直接 bind tailscale IP，只能借 netstack 的 TCP forwarder。

LOG=/var/log/net-services.log
RELAY=/workspace/relay.js
[ -r /etc/net-services.conf ] && . /etc/net-services.conf
PORT="${RELAY_PORT:-65530}"
HOST="${RELAY_HOST:-127.0.0.1}"
export RELAY_PORT="$PORT" RELAY_HOST="$HOST" RELAY_KEY MODELS_FILE UPSTREAM_BASE UPSTREAM_AUTH_MODE UPSTREAM_TOKEN MODELS_MODE STREAM_ADAPT

log() { echo "$(date '+%F %T') [relay $$] $*" >>"$LOG" 2>/dev/null; }

[ -f "$RELAY" ] || exit 0

# ---------- 1. relay 进程 ----------
# pgrep -fx 精确匹配整条命令行，避免匹配到命令行里恰好含 relay.js 的无关进程
if pgrep -fx "node $RELAY" >/dev/null 2>&1; then
    :
else
    nohup setsid node "$RELAY" >>/var/log/relay.log 2>&1 &
    log "relay 已拉起 ($HOST:$PORT)"
fi

# ---------- 2. tailscale TCP forwarder ----------
# 幂等：重复 set 同一端口不会叠加配置，但 tailscaled 未就绪时会失败，故先判活
if pgrep -x tailscaled >/dev/null 2>&1; then
    if ! tailscale serve status --json 2>/dev/null | grep -q "\"$PORT\""; then
        if timeout 20 tailscale serve --bg --tcp "$PORT" "tcp://127.0.0.1:$PORT" >>"$LOG" 2>&1; then
            log "tailscale serve --tcp $PORT 已设置"
        else
            log "tailscale serve --tcp $PORT 设置失败"
        fi
    fi
fi

exit 0
EOF

cat > "$SBIN/net-services-watchdog.sh" <<'EOF'
#!/bin/bash
# 每 60 秒巡检一次：sshd / tailscaled / 反代，掉了就拉起。
# 由 PID 1 的 supervisord 托管（/usr/local/share/supervisor/net-services.conf），
# 死了会被秒级重启；/etc/profile.d 与 shell rc 里的 ensure 脚本是第二道兜底。

LOG=/var/log/net-services.log
HB=/var/log/heartbeat.log
SPACEYAML=/var/run/cloudstudio/space.yaml
[ -r /etc/net-services.conf ] && . /etc/net-services.conf
RELAY=/workspace/relay.js
INTERVAL=60

upt() { cut -d. -f1 /proc/uptime; }

log() { echo "$(date '+%F %T') [watchdog $$] $*" >>"$LOG" 2>/dev/null; }

# 记下被谁、用什么信号杀掉。SIGKILL 抓不到，日志会直接断流——那本身就是结论。
trap 'log "收到 SIGTERM，退出 (uptime=$(upt))"; exit 143' TERM
trap 'log "收到 SIGHUP，退出 (uptime=$(upt))"; exit 129' HUP
trap 'log "收到 SIGINT，退出 (uptime=$(upt))"; exit 130' INT
trap 'log "收到 SIGQUIT，退出 (uptime=$(upt))"; exit 131' QUIT

# 每轮留痕：healthz 结果 + 容器已运行秒数 + 三个服务的 PID。
# 用来区分两种"服务中断"：
#   uptime 归零  -> 容器被整体停掉/重建，容器内任何保活都救不了
#   uptime 连续、healthz 仍 200 -> 只是容器内进程被杀，看门狗可自愈
hb() {
    local up code url st p
    up=$(upt)
    st=""
    p=$(pgrep -x sshd | head -1);            st="$st sshd=${p:-down}"
    p=$(pgrep -x tailscaled | head -1);      st="$st ts=${p:-down}"
    p=$(pgrep -fx "node $RELAY" | head -1);  st="$st relay=${p:-down}"

    if [ -z "${CS_HEALTHZ_TOKEN:-}" ] || [ ! -r "$SPACEYAML" ]; then
        echo "$(date '+%F %T') uptime=$up healthz=skip $st" >>"$HB" 2>/dev/null
        return 0
    fi
    url="https://$(sed -n 's/^spacekey: *//p' "$SPACEYAML" | tr -d '\r')--api.$(sed -n 's/^region: *//p' "$SPACEYAML" | tr -d '\r').$(sed -n 's/^host: *//p' "$SPACEYAML" | tr -d '\r')/healthz"
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $CS_HEALTHZ_TOKEN" "$url" 2>/dev/null)
    echo "$(date '+%F %T') uptime=$up healthz=$code $st" >>"$HB" 2>/dev/null
    # 超过 1MB 只留最近 2000 行
    [ "$(stat -c %s "$HB" 2>/dev/null || echo 0)" -gt 1048576 ] \
        && tail -n 2000 "$HB" >"$HB.tmp" 2>/dev/null && mv "$HB.tmp" "$HB" 2>/dev/null
    return 0
}

log "看门狗启动"

while true; do
    if ! pgrep -x sshd >/dev/null 2>&1 || ! pgrep -x tailscaled >/dev/null 2>&1; then
        log "检测到服务掉线，执行拉起"
        /usr/local/sbin/start-net-services.sh
    fi

    /usr/local/sbin/ensure-relay.sh

    # 本地 /v1/models：最多每 6 小时刷新一次；/v3/config 为权威，官网仅追加缺失正式模型。
    if [ "${MODELS_MODE:-local}" = local ] && [ -x /usr/local/sbin/update-codebuddy-models ]; then
        /usr/local/sbin/update-codebuddy-models --if-stale >/dev/null 2>&1 || true
    fi

    hb

    # sleep 放后台 + wait：直接 sleep 的话 bash 要等它跑完才处理信号，
    # 收到 TERM 最长要拖 60 秒才退出，自愈窗口被白白拉长
    sleep "$INTERVAL" &
    wait $!
done
EOF

cat > "$SBIN/ensure-net-services.sh" <<'EOF'
#!/bin/bash
# 确保看门狗活着。幂等，可反复调用（挂在 shell rc 上作第二道兜底）。
# 首选入口是 PID 1 的 supervisord；这里只在它没接管时补位。

WATCHDOG=/usr/local/sbin/net-services-watchdog.sh
[ "$(id -u)" = 0 ] || exit 0
[ -x "$WATCHDOG" ] || exit 0

# 兜底自己读一次令牌：/etc/profile.d 早于 ~/.bashrc.d 执行，走登录 shell 这条入口时
# CS_HEALTHZ_TOKEN 还没被加载，看门狗会退化成不带心跳的裸跑版。
[ -n "${CS_HEALTHZ_TOKEN:-}" ] || { [ -r /root/.cs-token ] && . /root/.cs-token; }

pgrep -fx "/bin/bash $WATCHDOG" >/dev/null 2>&1 && exit 0

if [ -x /usr/local/sbin/net-services-daemon.sh ]; then
    # 用 >> 追加：用 > 会每次重启看门狗就把历史记录冲掉，排查时最需要的是跨重启的连续时间线
    nohup setsid /usr/local/sbin/net-services-daemon.sh >>/var/log/heartbeat.log 2>&1 &
else
    nohup setsid "$WATCHDOG" >>/var/log/heartbeat.log 2>&1 &
fi

exit 0
EOF

cat > "$SBIN/net-services-daemon.sh" <<'EOF'
#!/bin/bash
# supervisord 托管入口（配 /usr/local/share/supervisor/net-services.conf）。
#
# 两件事：
#   1. 兜底加载 CS_HEALTHZ_TOKEN——supervisord 启动时不加载任何 shell rc
#   2. 常驻一个 healthz 心跳，防止空间空闲被平台回收（nosleep 的原理，自己实现以免依赖 /workspace）
#
# 这里故意不 exec：要等看门狗退出后收掉心跳子进程，
# 否则 supervisord 每次重启都会多留一个心跳进程。

[ -r /root/.cs-token ] && . /root/.cs-token
[ -r /etc/net-services.conf ] && . /etc/net-services.conf

SPACEYAML=/var/run/cloudstudio/space.yaml

healthz_url() {
    [ -r "$SPACEYAML" ] || return 1
    local key region host
    key=$(sed -n 's/^spacekey: *//p' "$SPACEYAML" | tr -d '\r')
    region=$(sed -n 's/^region: *//p' "$SPACEYAML" | tr -d '\r')
    host=$(sed -n 's/^host: *//p' "$SPACEYAML" | tr -d '\r')
    [ -n "$key" ] && [ -n "$region" ] && [ -n "$host" ] || return 1
    echo "https://${key}--api.${region}.${host}/healthz"
}

heartbeat() {
    local url
    url=$(healthz_url) || { echo "$(date '+%F %T') 非 CloudStudio 环境，跳过防休眠心跳" >&2; return 0; }
    while true; do
        # -m 10：不设超时的话，网络卡住时 curl 会一直挂着，
        # 主命令退出后要等这个心跳子进程，会把看门狗的重启拖慢几十秒
        curl -m 10 -o /dev/null -H "Authorization: Bearer $CS_HEALTHZ_TOKEN" "$url" \
            || echo "$(date '+%F %T') 心跳请求失败" >&2
        sleep 5
    done
}

if [ -n "${CS_HEALTHZ_TOKEN:-}" ]; then
    heartbeat &
    HB=$!
else
    HB=""
    echo "$(date '+%F %T') 未配置 CS_HEALTHZ_TOKEN，不启动防休眠心跳" >&2
fi

/usr/local/sbin/net-services-watchdog.sh
rc=$?

[ -n "$HB" ] && { kill "$HB" 2>/dev/null; wait "$HB" 2>/dev/null; }
exit $rc
EOF

cat > "$SBIN/start-all.sh" <<'EOF'
#!/bin/bash
# 冷启动一次性拉起全部服务：sshd + tailscaled + codebuddy 反代，并挂上看门狗保活。
# 幂等，已在运行的会跳过，可以反复执行。

set -u
[ -r /etc/net-services.conf ] && . /etc/net-services.conf
PORT="${RELAY_PORT:-65530}"

echo "===== 1/3  sshd + tailscaled ====="
/usr/local/sbin/start-net-services.sh
sleep 1
pgrep -x sshd       >/dev/null && echo "  sshd       已运行" || echo "  sshd       未运行"
pgrep -x tailscaled >/dev/null && echo "  tailscaled 已运行" || echo "  tailscaled 未运行"

echo "===== 2/3  看门狗（每 60s 巡检保活）====="
/usr/local/sbin/ensure-net-services.sh
sleep 1
pgrep -fx "/bin/bash /usr/local/sbin/net-services-watchdog.sh" >/dev/null \
  && echo "  看门狗 已运行" || echo "  看门狗 未运行"

echo "===== 3/3  codebuddy 反代（relay + tailscale serve）====="
/usr/local/sbin/ensure-relay.sh
sleep 1
pgrep -fx "node /workspace/relay.js" >/dev/null \
  && echo "  relay 已运行" || echo "  relay 未运行"

echo
echo "===== 状态 ====="
printf "  tailscale IP : %s\n" "$(tailscale ip -4 2>/dev/null || echo '(未就绪)')"
printf "  反代地址     : http://%s:%s/v1\n" "$(tailscale ip -4 2>/dev/null || echo '<ip>')" "$PORT"
echo "  tailscale serve:"
tailscale serve status 2>/dev/null | sed 's/^/    /' || echo "    (tailscale 未就绪)"
EOF

cat > "$SBIN/supervisor-rpc.py" <<'EOF'
#!/usr/bin/env python3
"""CloudStudio supervisord 的轻量管理器。

用法：
  supervisor-rpc.py status [name]
  supervisor-rpc.py start|stop|restart <name>
  supervisor-rpc.py reload

name 是 Supervisor 的 program/group 名，例如：net-services、app-gost。
"""

import glob
import http.client
import socket
import sys
import xmlrpc.client

SOCKS = sorted(glob.glob('/.Pln*_run/cs-supervisor.sock'))
SOCK = SOCKS[0] if SOCKS else ''


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost')
        self._unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self._unix_path)


class _UnixTransport(xmlrpc.client.Transport):
    def __init__(self, path):
        super().__init__()
        self._unix_path = path

    def make_connection(self, host):
        return _UnixHTTPConnection(self._unix_path)


def client():
    if not SOCK:
        raise RuntimeError('找不到 supervisord unix socket（/.Pln*_run/cs-supervisor.sock）')
    return xmlrpc.client.ServerProxy('http://localhost', transport=_UnixTransport(SOCK))


def _managed(group):
    return group == 'net-services' or group.startswith('app-')

def reload_config(s):
    result = s.supervisor.reloadConfig()
    # 关键安全约束：CloudStudio 的 PID 1 supervisord 还托管平台自己的 IDE/终端。
    # 这里只允许操作我们创建的 net-services / app-*，其它 group 永远不 stop/remove/add。
    if len(result) == 1 and isinstance(result[0], (list, tuple)) and len(result[0]) == 3:
        raw_added, raw_changed, raw_removed = result[0]
    else:
        raw_added, raw_changed, raw_removed = result
    added = [g for g in raw_added if _managed(g)]
    changed = [g for g in raw_changed if _managed(g)]
    removed = [g for g in raw_removed if _managed(g)]

    for group in removed:
        try:
            s.supervisor.stopProcessGroup(group, True)
        except xmlrpc.client.Fault:
            pass
        try:
            s.supervisor.removeProcessGroup(group)
        except xmlrpc.client.Fault:
            pass

    # 已修改配置：必须 remove + add 才会采用新配置。
    for group in changed:
        try:
            s.supervisor.stopProcessGroup(group, True)
        except xmlrpc.client.Fault:
            pass
        try:
            s.supervisor.removeProcessGroup(group)
        except xmlrpc.client.Fault:
            pass
        s.supervisor.addProcessGroup(group)

    # 新配置直接注册。
    for group in added:
        try:
            s.supervisor.addProcessGroup(group)
        except xmlrpc.client.Fault as e:
            if 'ALREADY_ADDED' not in e.faultString:
                raise

    print('added=%s changed=%s removed=%s' % (added, changed, removed))


def print_info(i):
    age = max(0, int(i.get('now', 0) - i.get('start', 0))) if i.get('start') else 0
    print('%-24s %-10s PID=%-7s uptime=%ss' %
          (i.get('group') or i.get('name'), i.get('statename'), i.get('pid'), age))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    name = sys.argv[2] if len(sys.argv) > 2 else ''
    try:
        s = client()
    except RuntimeError as e:
        print(e)
        return 1

    try:
        if cmd == 'reload':
            reload_config(s)
            return 0

        if cmd == 'status':
            if name:
                print_info(s.supervisor.getProcessInfo(name))
            else:
                for i in s.supervisor.getAllProcessInfo():
                    group = i.get('group', '')
                    if group == 'net-services' or group.startswith('app-'):
                        print_info(i)
            return 0

        if not name:
            print('缺少服务名，例如：supervisor-rpc.py restart app-gost')
            return 2
        if not _managed(name):
            print('拒绝操作非本脚本托管的 Supervisor 进程组：%s' % name)
            return 3

        if cmd == 'start':
            print(s.supervisor.startProcess(name, True))
        elif cmd == 'stop':
            print(s.supervisor.stopProcess(name, True))
        elif cmd == 'restart':
            try:
                s.supervisor.stopProcess(name, True)
            except xmlrpc.client.Fault:
                pass
            print(s.supervisor.startProcess(name, True))
        else:
            print(__doc__)
            return 2
        return 0
    except xmlrpc.client.Fault as e:
        print('supervisord:', e.faultString)
        return 1


if __name__ == '__main__':
    sys.exit(main())
EOF

# ---------------------------------------------------------------- 小白应用管理器
step "安装 netapp 应用管理器"
mkdir -p "$NETAPP_HOME" "$NETAPP_META" "$NETAPP_LOG"
chmod 700 "$NETAPP_HOME" "$NETAPP_META"

cat > "$NETAPP_BIN" <<'NETAPP_EOF'
#!/bin/bash
# netapp —— CloudStudio 后台应用小白管理器
# 每个应用独立交给 PID 1 supervisord 托管：开机自启、异常自动重启、日志独立。

set -uo pipefail

SV_DIR=/usr/local/share/supervisor
RUN_DIR=/usr/local/lib/netapps
META_DIR=/etc/netapps
LOG_DIR=/var/log/netapps
RPC=/usr/local/sbin/supervisor-rpc.py

C0=$'\033[0m'; CB=$'\033[1m'; CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'
ok()   { printf '%s[ok]%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$CY" "$C0" "$*"; }
die()  { printf '%s[fail]%s %s\n' "$CR" "$C0" "$*" >&2; exit 1; }

usage() {
cat <<'EOF'
netapp - CloudStudio 后台应用管理器

新手：
  netapp                         打开中文菜单
  netapp add                     添加应用向导

常用：
  netapp list                    查看全部应用、是否自启、运行状态
  netapp status NAME             查看一个应用状态
  netapp show NAME               查看配置
  netapp edit NAME               修改启动命令/工作目录
  netapp logs NAME               实时看日志（Ctrl+C 退出）
  netapp restart NAME            重启
  netapp stop NAME               仅停止本次（如果仍启用自启，下次工作区启动会再起来）
  netapp start NAME              手动启动
  netapp disable NAME            停止并关闭以后自动启动
  netapp enable NAME             恢复自动启动并立即启动
  netapp remove NAME             取消托管，不删除程序本体和历史日志
  netapp doctor                  检查 Supervisor/Tailscale/核心服务/应用

一条命令添加：
  netapp add NAME "启动命令" [工作目录]

示例：
  netapp add gost "gost -L 'mwss://user:pass@[::]:38711?...'" /root
  netapp add alist "/workspace/alist server" /workspace
EOF
}

need_root() { [ "$(id -u)" = 0 ] || die "请用 root 执行"; }
valid_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$ ]]; }
group_of() { printf 'app-%s' "$1"; }
conf_of()  { printf '%s/app-%s.conf' "$SV_DIR" "$1"; }
run_of()   { printf '%s/%s.sh' "$RUN_DIR" "$1"; }
meta_of()  { printf '%s/%s.conf' "$META_DIR" "$1"; }
log_of()   { printf '%s/%s.log' "$LOG_DIR" "$1"; }

rpc() {
    [ -x "$RPC" ] || die "缺少 $RPC，请运行 cs-init repair 修复"
    "$RPC" "$@"
}

reload_sv() {
    if rpc reload >/dev/null 2>&1; then
        return 0
    fi
    warn "当前无法热加载 supervisord；配置已经保存，重新启动 CloudStudio 工作区后会自动生效"
    return 1
}

read_meta() {
    local name=$1 meta
    meta=$(meta_of "$name")
    [ -r "$meta" ] || die "找不到应用：$name"
    NAME="" WORKDIR="" COMMAND="" ENABLED="1"
    # shellcheck disable=SC1090
    . "$meta"
    NAME=${NAME:-$name}
    WORKDIR=${WORKDIR:-/workspace}
    ENABLED=${ENABLED:-1}
}

write_app() {
    local name=$1 cmd=$2 dir=$3 enabled=${4:-1} start_now=${5:-1}
    local run conf meta log group autostart
    run=$(run_of "$name"); conf=$(conf_of "$name"); meta=$(meta_of "$name"); log=$(log_of "$name"); group=$(group_of "$name")

    [ -d "$dir" ] || die "工作目录不存在：$dir"
    [ -n "$cmd" ] || die "启动命令不能为空"
    mkdir -p "$SV_DIR" "$RUN_DIR" "$META_DIR" "$LOG_DIR"
    autostart=true; [ "$enabled" = 1 ] || autostart=false

    # 复杂命令放 wrapper，避免 URL、单双引号等破坏 Supervisor ini。
    {
        echo '#!/bin/bash'
        echo 'set -e'
        printf 'cd %q\n' "$dir"
        printf 'exec /bin/bash -c %q\n' "$cmd"
    } > "$run"
    chmod 700 "$run"

    {
        printf 'NAME=%q\n' "$name"
        printf 'WORKDIR=%q\n' "$dir"
        printf 'COMMAND=%q\n' "$cmd"
        printf 'ENABLED=%q\n' "$enabled"
    } > "$meta"
    chmod 600 "$meta"

    cat > "$conf" <<EOF
[program:$group]
command=/bin/bash $run
directory=/
autostart=$autostart
autorestart=true
startsecs=2
startretries=50
stopsignal=TERM
stopwaitsecs=15
stopasgroup=true
killasgroup=true
priority=950
environment=PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",HOME="/root"
stdout_logfile=$log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=3
redirect_stderr=true
EOF

    if reload_sv; then
        if [ "$enabled" = 1 ] && [ "$start_now" = 1 ]; then
            rpc start "$group" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    return 1
}

cmd_add() {
    need_root
    local name="${1:-}" cmd="${2:-}" dir="${3:-}" answer interactive=0
    [ -t 0 ] && interactive=1

    if [ -z "$name" ]; then
        echo "${CB}添加后台应用${C0}"
        echo "只需要准备：应用名称 + 你平时手动启动它的完整命令。"
        echo
        read -r -p "应用名称（例如 gost）：" name
    fi
    valid_name "$name" || die "应用名只能使用字母、数字、点、下划线、横杠，最长 48 位"

    if [ -z "$cmd" ]; then
        read -r -p "启动命令（完整复制你平时运行的命令）：" cmd
    fi
    [ -n "$cmd" ] || die "启动命令不能为空"
    if [[ "$cmd" == *"nohup "* ]] || [[ "$cmd" =~ \&[[:space:]]*$ ]]; then
        warn "检测到 nohup 或后台 &。Supervisor 应直接托管前台命令，建议删除 nohup 和末尾 &"
    fi

    if [ -z "$dir" ]; then
        read -r -p "工作目录 [默认 /workspace]：" dir
        dir=${dir:-/workspace}
    fi
    [ -d "$dir" ] || die "工作目录不存在：$dir"

    if [ -e "$(conf_of "$name")" ] || [ -e "$(meta_of "$name")" ]; then
        if [ "$interactive" = 1 ]; then
            read -r -p "应用 $name 已存在，覆盖配置？[y/N] " answer
            [[ "$answer" =~ ^[Yy]$ ]] || exit 0
            rpc stop "$(group_of "$name")" >/dev/null 2>&1 || true
        else
            die "应用 $name 已存在；请使用 netapp edit $name，或先 remove"
        fi
    fi

    if [ "$interactive" = 1 ]; then
        echo
        echo "---------- 请确认 ----------"
        echo "应用名称：$name"
        echo "工作目录：$dir"
        echo "启动命令：$cmd"
        echo "自动启动：是"
        read -r -p "确认添加？[Y/n] " answer
        [[ "$answer" =~ ^[Nn]$ ]] && { echo "已取消"; exit 0; }
    fi

    if write_app "$name" "$cmd" "$dir" 1 1; then
        ok "$name 已托管并启动；以后工作区启动会自动运行，异常退出会自动重启"
    else
        ok "$name 配置已保存；下次 CloudStudio 工作区启动时自动生效"
    fi
    printf '日志：%s\n' "$(log_of "$name")"
}

cmd_list() {
    printf '%-17s %-6s %-11s %-8s %s\n' "应用" "自启" "状态" "PID" "启动命令"
    printf '%-17s %-6s %-11s %-8s %s\n' "-----------------" "------" "-----------" "--------" "------------------------------"
    local f name group line state pid cmd enabled auto
    shopt -s nullglob
    local files=("$META_DIR"/*.conf)
    if [ ${#files[@]} -eq 0 ]; then
        echo "（还没有应用，执行 netapp add 添加）"
        return 0
    fi
    for f in "${files[@]}"; do
        NAME="" COMMAND="" ENABLED=1
        # shellcheck disable=SC1090
        . "$f"
        name=${NAME:-$(basename "$f" .conf)}
        cmd=${COMMAND:-}
        enabled=${ENABLED:-1}; auto=是; [ "$enabled" = 1 ] || auto=否
        group=$(group_of "$name")
        line=$(rpc status "$group" 2>/dev/null || true)
        state=$(awk '{print $2}' <<<"$line")
        state=${state:-未加载}
        pid=$(sed -n 's/.*PID=\([0-9]*\).*/\1/p' <<<"$line")
        printf '%-17s %-6s %-11s %-8s %s\n' "$name" "$auto" "$state" "${pid:-0}" "$cmd"
    done
}

cmd_show() {
    local name=${1:-}; valid_name "$name" || die "请提供正确应用名"
    read_meta "$name"
    echo "应用      : $NAME"
    echo "自动启动  : $([ "$ENABLED" = 1 ] && echo '是' || echo '否')"
    echo "工作目录  : $WORKDIR"
    echo "启动命令  : $COMMAND"
    echo "日志      : $(log_of "$name")"
    echo "Supervisor: $(conf_of "$name")"
    echo
    rpc status "$(group_of "$name")" 2>/dev/null || true
}

cmd_edit() {
    need_root
    local name=${1:-} newcmd newdir answer
    valid_name "$name" || die "用法：netapp edit NAME"
    read_meta "$name"
    echo "修改 $name（直接回车保持原值）"
    echo "当前命令：$COMMAND"
    read -r -p "新启动命令：" newcmd
    newcmd=${newcmd:-$COMMAND}
    read -r -p "工作目录 [$WORKDIR]：" newdir
    newdir=${newdir:-$WORKDIR}
    [ -d "$newdir" ] || die "工作目录不存在：$newdir"
    echo "新命令：$newcmd"
    echo "目录  ：$newdir"
    read -r -p "保存并重新加载？[Y/n] " answer
    [[ "$answer" =~ ^[Nn]$ ]] && { echo "已取消"; return 0; }
    rpc stop "$(group_of "$name")" >/dev/null 2>&1 || true
    if write_app "$name" "$newcmd" "$newdir" "$ENABLED" "$ENABLED"; then
        ok "$name 已更新$([ "$ENABLED" = 1 ] && echo '并启动' || echo '（仍保持禁用）')"
    else
        ok "$name 配置已更新，重启工作区后生效"
    fi
}

cmd_action() {
    local action=$1 name=${2:-}
    valid_name "$name" || die "请提供正确应用名"
    [ -r "$(meta_of "$name")" ] || die "找不到应用：$name"
    rpc "$action" "$(group_of "$name")"
    if [ "$action" = stop ]; then
        read_meta "$name"
        [ "$ENABLED" = 1 ] && warn "这是临时停止；下次工作区启动仍会自启。永久停用请执行：netapp disable $name"
    fi
}

cmd_logs() {
    local name=${1:-}; valid_name "$name" || die "请提供正确应用名"
    [ -r "$(meta_of "$name")" ] || die "找不到应用：$name"
    local log; log=$(log_of "$name")
    touch "$log"
    echo "日志：$log（Ctrl+C 退出）"
    tail -n 100 -f "$log"
}

cmd_disable() {
    need_root
    local name=${1:-}; valid_name "$name" || die "用法：netapp disable NAME"
    read_meta "$name"
    rpc stop "$(group_of "$name")" >/dev/null 2>&1 || true
    if write_app "$name" "$COMMAND" "$WORKDIR" 0 0; then
        ok "$name 已停止并关闭自动启动"
    else
        ok "$name 已标记为禁用；重启工作区后生效"
    fi
}

cmd_enable() {
    need_root
    local name=${1:-}; valid_name "$name" || die "用法：netapp enable NAME"
    read_meta "$name"
    if write_app "$name" "$COMMAND" "$WORKDIR" 1 1; then
        ok "$name 已启用自动启动并立即启动"
    else
        ok "$name 已标记为启用；重启工作区后生效"
    fi
}

cmd_remove() {
    need_root
    local name=${1:-} answer group
    valid_name "$name" || die "请提供正确应用名"
    [ -e "$(conf_of "$name")" ] || [ -e "$(meta_of "$name")" ] || die "找不到应用：$name"
    if [ -t 0 ]; then
        read -r -p "取消 $name 的后台托管？程序本体和历史日志不会删除。[y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || exit 0
    fi
    group=$(group_of "$name")
    rpc stop "$group" >/dev/null 2>&1 || true
    rm -f "$(conf_of "$name")" "$(run_of "$name")" "$(meta_of "$name")"
    reload_sv || true
    ok "$name 已取消托管；程序文件和历史日志保留"
}

cmd_purge() {
    need_root
    [ "${1:-}" = "--yes" ] || die "此命令会删除所有 netapp 托管配置；确认请执行：netapp purge --yes"
    local f name
    shopt -s nullglob
    for f in "$META_DIR"/*.conf; do
        name=$(basename "$f" .conf)
        rpc stop "$(group_of "$name")" >/dev/null 2>&1 || true
    done
    rm -f "$SV_DIR"/app-*.conf "$RUN_DIR"/*.sh "$META_DIR"/*.conf
    reload_sv || true
    ok "所有 netapp 托管配置已删除（程序本体和历史日志保留）"
}

cmd_doctor() {
    echo "===== netapp doctor ====="
    [ "$(id -u)" = 0 ] && ok "当前用户 root" || warn "当前不是 root"
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = supervisord ] && ok "PID 1 = supervisord" || warn "PID 1 不是 supervisord"
    [ -x "$RPC" ] && ok "Supervisor RPC 管理器存在" || warn "缺少 $RPC"
    if [ -x "$RPC" ]; then
        "$RPC" status >/dev/null 2>&1 && ok "Supervisor RPC 可通信" || warn "Supervisor RPC 当前不可通信"
    fi
    pgrep -x sshd >/dev/null 2>&1 && ok "sshd 正在运行" || warn "sshd 未运行"
    pgrep -x tailscaled >/dev/null 2>&1 && ok "tailscaled 正在运行" || warn "tailscaled 未运行"
    pgrep -fx "node /workspace/relay.js" >/dev/null 2>&1 && ok "CodeBuddy relay 正在运行" || warn "CodeBuddy relay 未运行"
    if command -v tailscale >/dev/null 2>&1; then
        if tailscale status >/dev/null 2>&1; then
            ok "Tailscale 已登录：$(tailscale ip -4 2>/dev/null || echo '-')"
        else
            warn "Tailscale 尚未登录/未就绪"
        fi
    else
        warn "Tailscale 命令不存在"
    fi
    [ -s /root/.cs-token ] && ok "CloudStudio healthz token 已保存" || warn "未保存 healthz token（防休眠心跳不会启用）"
    echo
    cmd_list
}

choose_name() {
    local __var=$1 value
    cmd_list
    echo
    read -r -p "请输入应用名称：" value
    valid_name "$value" || die "应用名无效"
    printf -v "$__var" '%s' "$value"
}

cmd_menu() {
    [ -t 0 ] || { usage; return 0; }
    local ans name
    while true; do
        echo
        echo "============================================================"
        echo " netapp 后台应用管理"
        echo "============================================================"
        echo "1) 添加应用"
        echo "2) 查看应用"
        echo "3) 修改应用"
        echo "4) 查看日志"
        echo "5) 重启应用"
        echo "6) 临时停止应用"
        echo "7) 永久停用自动启动"
        echo "8) 恢复自动启动"
        echo "9) 删除托管"
        echo "D) 环境检查 doctor"
        echo "0) 退出"
        read -r -p "请选择：" ans
        case "$ans" in
            1) cmd_add ;;
            2) cmd_list ;;
            3) choose_name name; cmd_edit "$name" ;;
            4) choose_name name; cmd_logs "$name" ;;
            5) choose_name name; cmd_action restart "$name" ;;
            6) choose_name name; cmd_action stop "$name" ;;
            7) choose_name name; cmd_disable "$name" ;;
            8) choose_name name; cmd_enable "$name" ;;
            9) choose_name name; cmd_remove "$name" ;;
            d|D) cmd_doctor ;;
            0|'') return 0 ;;
            *) warn "请输入菜单中的选项" ;;
        esac
    done
}

case "${1:-}" in
    menu) cmd_menu ;;
    add) shift; cmd_add "$@" ;;
    list|ls) cmd_list ;;
    status|start|stop|restart) action=$1; shift; cmd_action "$action" "$@" ;;
    logs|log) shift; cmd_logs "$@" ;;
    show) shift; cmd_show "$@" ;;
    edit|update) shift; cmd_edit "$@" ;;
    disable) shift; cmd_disable "$@" ;;
    enable) shift; cmd_enable "$@" ;;
    doctor|check) cmd_doctor ;;
    remove|rm|del) shift; cmd_remove "$@" ;;
    purge) shift; cmd_purge "$@" ;;
    help|-h|--help) usage ;;
    '') [ -t 0 ] && cmd_menu || usage ;;
    *) die "未知命令：$1（执行 netapp help 查看帮助）" ;;
esac
NETAPP_EOF

chmod +x "$SBIN"/{start-net-services,ensure-relay,net-services-watchdog,ensure-net-services,net-services-daemon,start-all}.sh "$SBIN/supervisor-rpc.py" "$SBIN/update-codebuddy-models" "$NETAPP_BIN"
ok "$SBIN 下的核心脚本 + supervisor-rpc.py + netapp"

# ---------------------------------------------------------------- ssh 登录方式
step "SSH 登录方式"
SSH_CFG=/etc/ssh/sshd_config.d/99-net-services.conf
mkdir -p /etc/ssh/sshd_config.d

if [ "$SSH_SETUP_MODE" = auto ]; then
    if [ -n "$SSH_PASSWORD" ]; then
        SSH_SETUP_MODE=password; FORCE_SSH_CONFIG=yes
    elif [ -n "$SSH_PUBKEY" ]; then
        SSH_SETUP_MODE=key; FORCE_SSH_CONFIG=yes
    elif [ -s "$SSH_CFG" ] || [ -f /etc/ssh/sshd_config.d/99-custom.conf ]; then
        SSH_SETUP_MODE=keep
    else
        SSH_SETUP_MODE=key
    fi
fi

if [ -f /etc/ssh/sshd_config.d/99-custom.conf ] && [ "$FORCE_SSH_CONFIG" = yes ]; then
    warn "检测到 /etc/ssh/sshd_config.d/99-custom.conf；为避免覆盖你已有 SSH 规则，本脚本不强改该文件"
    warn "如果新配置不生效，请检查 99-custom.conf 中的 Port/PermitRootLogin/PasswordAuthentication"
fi

case "$SSH_SETUP_MODE" in
password)
    [ -n "$SSH_PASSWORD" ] || die "选择了密码 SSH，但 SSH_PASSWORD 为空"
    echo "root:$SSH_PASSWORD" | chpasswd
    cat > "$SSH_CFG" <<EOF2
Port $SSH_PORT
ListenAddress $SSH_LISTEN
PermitRootLogin yes
PasswordAuthentication yes
EOF2
    chmod 600 "$SSH_CFG"
    ok "已设置 root 密码登录（端口 $SSH_PORT）"
    ;;
key)
    cat > "$SSH_CFG" <<EOF2
Port $SSH_PORT
ListenAddress $SSH_LISTEN
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF2
    chmod 600 "$SSH_CFG"
    if [ -n "$SSH_PUBKEY" ]; then
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
        grep -qxF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null \
            || printf '%s\n' "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
        ok "SSH 公钥已写入 /root/.ssh/authorized_keys"
    fi
    if [ -s /root/.ssh/authorized_keys ]; then
        ok "已启用 SSH 公钥登录（端口 $SSH_PORT）"
    else
        warn "已选择仅公钥登录，但 authorized_keys 为空；现在可能无法 SSH 登录"
    fi
    ;;
keep)
    ok "保持现有 SSH 登录配置，不主动修改"
    ;;
*) die "未知 SSH_SETUP_MODE：$SSH_SETUP_MODE" ;;
esac

grep -q 'sshd_config.d' /etc/ssh/sshd_config 2>/dev/null \
    || warn "/etc/ssh/sshd_config 没有 Include sshd_config.d/*.conf，上面的配置可能不会生效"

# ---------------------------------------------------------------- shell rc 兜底
step "写入 shell rc 兜底"
cat > /etc/profile.d/99-net-services.sh <<'EOF'
# 登录时兜底拉起看门狗（幂等）。真正的开机自启由 PID 1 的 supervisord 负责，
# 这里只是它没接管时的第二道保险。
[ -x /usr/local/sbin/ensure-net-services.sh ] && /usr/local/sbin/ensure-net-services.sh
EOF
for d in /root/.bashrc.d /root/.zshrc.d; do
    mkdir -p "$d"
    cat > "$d/99-net-services.sh" <<'EOF'
# 容器重启后兜底拉起看门狗（幂等）
[ -x /usr/local/sbin/ensure-net-services.sh ] && /usr/local/sbin/ensure-net-services.sh
EOF
done
ok "/etc/profile.d + ~/.{bashrc,zshrc}.d"

# ---------------------------------------------------------------- healthz 立即验证
healthz_url_now() {
    local key region host
    if [ -r /var/run/cloudstudio/space.yaml ]; then
        key=$(sed -n 's/^spacekey: *//p' /var/run/cloudstudio/space.yaml | tr -d '\r' | tail -1)
        region=$(sed -n 's/^region: *//p' /var/run/cloudstudio/space.yaml | tr -d '\r' | tail -1)
        host=$(sed -n 's/^host: *//p' /var/run/cloudstudio/space.yaml | tr -d '\r' | tail -1)
    else
        key=${X_IDE_SPACE_KEY:-}; region=${X_IDE_SPACE_REGION:-}; host=${X_IDE_SPACE_HOST:-}
    fi
    [ -n "$key" ] && [ -n "$region" ] && [ -n "$host" ] || return 1
    printf 'https://%s--api.%s.%s/healthz\n' "$key" "$region" "$host"
}

if [ -n "$CS_HEALTHZ_TOKEN" ] && command -v curl >/dev/null 2>&1; then
    HURL=$(healthz_url_now 2>/dev/null || true)
    if [ -n "$HURL" ]; then
        HCODE=$(curl -sS -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $CS_HEALTHZ_TOKEN" "$HURL" 2>/dev/null || echo 000)
        if [ "$HCODE" = 200 ]; then
            ok "healthz Token 验证成功（HTTP 200），防空闲心跳可工作"
            log_install "healthz validation=200"
        else
            warn "healthz Token 验证未通过（HTTP $HCODE）——当前不能认为防休眠已生效"
            warn "请到 CloudStudio 设置 -> 访问令牌重新创建 Token，然后 cs-init reconfigure"
            log_install "healthz validation=$HCODE"
        fi
    else
        warn "无法解析当前 CloudStudio healthz 地址，防空闲心跳暂不能验证"
        log_install "healthz url unresolved"
    fi
else
    warn "未配置 CS_HEALTHZ_TOKEN：不会启用 CloudStudio 防空闲心跳"
    log_install "healthz disabled"
fi

# ---------------------------------------------------------------- supervisord 托管
if [ "$HAVE_SV" = yes ]; then
    step "挂到 PID 1 的 supervisord"
    mkdir -p "$SV_CONF_DIR"
    cat > "$SV_CONF" <<'EOF'
[program:net-services]
; sshd / tailscaled / codebuddy 反代的看门狗，交给 PID 1 托管：
; 容器一启动就自启（不依赖先开控制台），被杀掉会被秒级重启。
; 卸载：删掉本文件后执行 supervisor-rpc.py uninstall，不影响 supervisord 其它程序。
command=/usr/local/sbin/net-services-daemon.sh
directory=/workspace
autostart=true
autorestart=true
startsecs=5
startretries=20
stopsignal=TERM
stopwaitsecs=10
; 看门狗会 fork 出心跳子进程，必须按进程组收，否则 stop/restart 会留孤儿
stopasgroup=true
killasgroup=true
priority=900
environment=PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",HOME="/root"
stdout_logfile=/var/log/net-services-supervisor.log
stdout_logfile_maxbytes=2MB
stdout_logfile_backups=2
redirect_stderr=true
EOF
    ok "$SV_CONF"

    # 热加载：统一走 supervisor-rpc.py，避免每个服务重复内嵌 XML-RPC 代码。
    if "$SBIN/supervisor-rpc.py" reload >>"$INSTALL_LOG" 2>&1; then
        "$SBIN/supervisor-rpc.py" start net-services >>"$INSTALL_LOG" 2>&1 || true
        ok "net-services 已安全热加载到 supervisord（仅操作本脚本进程组）"
        log_install "supervisor net-services registered"
    else
        warn "supervisord 热加载失败（配置已就位，容器下次启动会自动生效）"
    fi
else
    warn "PID 1 不是 supervisord，跳过托管；开机自启退化为 shell rc 兜底"
fi

# ---------------------------------------------------------------- 拉起服务
step "拉起全部服务"
"$SBIN/start-all.sh"
log_install "start-all finished"
# 核心 daemon 已经接管 healthz 后，结束安装阶段临时心跳，避免重复请求。
if pgrep -fx "/bin/bash /usr/local/sbin/net-services-watchdog.sh" >/dev/null 2>&1 || \
   pgrep -f "/usr/local/sbin/net-services-daemon.sh" >/dev/null 2>&1; then
    stop_bootstrap_heartbeat
    log_install "bootstrap heartbeat stopped after core daemon takeover"
fi

# ---------------------------------------------------------------- tailscale 授权
step "tailscale 授权"
if command -v tailscale >/dev/null 2>&1 && [ -S /run/tailscale/tailscaled.sock ]; then
    if tailscale status >/dev/null 2>&1; then
        ok "已登录：$(tailscale ip -4 2>/dev/null)"
    elif [ -n "$TS_AUTHKEY" ]; then
        if timeout 60 tailscale up --authkey="$TS_AUTHKEY" >/dev/null 2>&1; then
            ok "用 auth key 登录成功：$(tailscale ip -4 2>/dev/null)"
        else
            warn "auth key 登录失败，检查 TS_AUTHKEY 是否有效/已过期"
        fi
    else
        warn "tailscale 尚未登录，需要授权一次。执行下面这条，打开输出的链接在浏览器里确认："
        printf '    %stailscale up%s\n' "$C_B" "$C_RESET"
        warn "  想全自动就重跑本脚本并带上：export TS_AUTHKEY=tskey-auth-xxx"
    fi
else
    warn "tailscaled 未就绪，跳过授权"
fi

# ---------------------------------------------------------------- 安装管理命令本体
# 把当前完整脚本复制成 cs-init，后面不必再记上传脚本的文件名。
SELF_PATH=$(readlink -f "$0" 2>/dev/null || true)
if [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ]; then
    if [ "$SELF_PATH" != "$CSINIT_BIN" ]; then
        cp -f "$SELF_PATH" "$CSINIT_BIN" 2>/dev/null || true
    fi
    [ -f "$CSINIT_BIN" ] && chmod 700 "$CSINIT_BIN" || true
fi

# ---------------------------------------------------------------- 汇总
step "安装完成"
IP=$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')
cat <<EOF2

  ${C_B}以后最常用的两个命令${C_RESET}
    cs-init                 # 基础环境菜单 / 状态 / 修复
    netapp                  # 后台应用中文管理菜单

  ${C_B}对外地址${C_RESET}
    ssh      : ssh root@$IP -p $SSH_PORT
    反代      : http://$IP:$RELAY_PORT/v1
    本地监听  : SSH=$SSH_LISTEN:$SSH_PORT  RELAY=$RELAY_HOST:$RELAY_PORT
    上游      : $UPSTREAM_BASE
    反代密钥  : $RELAY_KEY
    models   : http://$IP:$RELAY_PORT/v1/models

  ${C_B}添加新应用${C_RESET}
    netapp add                                  # 推荐：交互式向导
    netapp add gost "gost -L '你的参数'" /root  # 高级：一条命令

  ${C_B}应用管理${C_RESET}
    netapp list
    netapp edit gost
    netapp logs gost
    netapp restart gost
    netapp stop gost       # 临时停止；下次工作区启动仍会自动起来
    netapp disable gost    # 停止 + 永久关闭自动启动
    netapp enable gost     # 恢复自动启动 + 立即启动
    netapp remove gost     # 取消托管，不删除 gost 程序本体
    netapp doctor          # 一键检查

  ${C_B}基础环境管理${C_RESET}
    cs-init status
    cs-init repair
    cs-init reconfigure
    cs-init models-update   # 接口权威模型 + 多官网页缺失正式模型
    cs-init models-show     # 查看当前模型 ID

  ${C_B}日志${C_RESET}
    tail -f /var/log/heartbeat.log
    tail -f /var/log/net-services.log
    tail -f /var/log/cs-init-install.log
    netapp logs <应用名>

  ${C_B}卸载${C_RESET}
    cs-init uninstall       # 核心服务卸载，保留用户应用配置
    cs-init uninstall-all   # 全部清理

EOF2

if [ -z "$TS_AUTHKEY" ] && command -v tailscale >/dev/null 2>&1 && ! tailscale status >/dev/null 2>&1; then
    warn "Tailscale 还没有登录。现在执行：tailscale up，然后打开输出的网址授权一次。"
fi

# ---------------------------------------------------------------- 最终自检（安装不能“悄悄成功”）
echo
echo "===== 安装后强制自检 ====="
FAIL=0
if [ "$HAVE_SV" = yes ]; then
    if "$SBIN/supervisor-rpc.py" status net-services 2>/dev/null | grep -qi 'running'; then
        ok "Supervisor: net-services = RUNNING"
    else
        warn "Supervisor: net-services 未处于 RUNNING；已启动 shell 兜底"
        "$SBIN/ensure-net-services.sh" || true
        FAIL=1
    fi
fi
pgrep -x sshd >/dev/null 2>&1 && ok "sshd 正在运行" || { warn "sshd 未运行"; FAIL=1; }
command -v tailscale >/dev/null 2>&1 && ok "tailscale CLI 已安装：$(command -v tailscale)" || { warn "tailscale CLI 未安装"; FAIL=1; }
command -v tailscaled >/dev/null 2>&1 && ok "tailscaled 二进制已安装：$(command -v tailscaled)" || { warn "tailscaled 二进制未安装"; FAIL=1; }
pgrep -x tailscaled >/dev/null 2>&1 && ok "tailscaled 正在运行" || { warn "tailscaled 未运行"; FAIL=1; }
command -v tailscale >/dev/null 2>&1 && ok "tailscale CLI 可用" || { warn "tailscale CLI 缺失"; FAIL=1; }
pgrep -fx "node /workspace/relay.js" >/dev/null 2>&1 && ok "relay.js 正在运行" || { warn "relay.js 未运行（看 /var/log/relay.log）"; FAIL=1; }
if [ -n "$CS_HEALTHZ_TOKEN" ]; then
    LAST_HB=$(tail -n 1 /var/log/heartbeat.log 2>/dev/null || true)
    echo "healthz 最近记录: ${LAST_HB:-暂无}"
fi
if [ "$FAIL" -eq 0 ]; then
    ok "核心服务自检通过"
    log_install "final self-check PASS"
else
    warn "有项目未通过自检。先不要关闭终端，执行：cs-init status"
    log_install "final self-check FAIL"
fi

if [ "$WIZARD_ADD_APP" = yes ] && is_tty && [ -x "$NETAPP_BIN" ]; then
    echo
    "$NETAPP_BIN" add || true
fi


# 首次交互安装结束时保留一个明确停顿，避免用户误以为终端“闪退”。
if is_tty && [ "${1:-}" != "repair" ]; then
    echo
    read -r -p "安装流程已结束。按回车返回终端（如果中途曾断线，重连后查看：tail -n 100 $INSTALL_LOG）..." _ || true
fi
