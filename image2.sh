#!/usr/bin/env bash

# ==========================================
# ChatGPT2API 运维控制台
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/chatgpt2api"
IMAGE_NAME="ghcr.io/basketikun/chatgpt2api:latest"

CRON_TAG_BEGIN="# CHATGPT2API_BACKUP_BEGIN"
CRON_TAG_END="# CHATGPT2API_BACKUP_END"
BACKUP_LOG="/var/log/chatgpt2api_backup.log"

GREEN="\033[32m"
RESET="\033[0m"

# ---- 基础工具函数 ----
info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1，请安装后重试。"
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

get_workdir() {
    if [[ -f "/etc/chatgpt2api_env" ]]; then
        local dir
        dir=$(cat "/etc/chatgpt2api_env")
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    echo ""
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

read_env_value() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2-
}

read_config_auth_key() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed -n 's/.*"auth-key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
}

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

json_escape() {
    printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_compose_file() {
    local install_path="$1"

    cat > "${install_path}/docker-compose.yml" <<EOF
services:
  app:
    image: ${IMAGE_NAME}
    container_name: chatgpt2api
    restart: unless-stopped
    ports:
      - "\${SERVER_PORT:-3000}:80"
    volumes:
      - ./data:/app/data
      - ./config.json:/app/config.json
    env_file:
      - .env
EOF
}

write_config_file() {
    local install_path="$1"
    local auth_key="$2"
    local base_url="$3"
    local escaped_auth_key
    local escaped_base_url
    escaped_auth_key=$(json_escape "$auth_key")
    escaped_base_url=$(json_escape "$base_url")

    cat > "${install_path}/config.json" <<EOF
{
  "auth-key": "${escaped_auth_key}",
  "refresh_account_interval_minute": 60,
  "image_retention_days": 15,
  "image_poll_timeout_secs": 120,
  "auto_remove_rate_limited_accounts": false,
  "auto_remove_invalid_accounts": true,
  "log_levels": [
    "debug",
    "error",
    "info",
    "warning"
  ],
  "proxy": "",
  "base_url": "${escaped_base_url}",
  "sensitive_words": [],
  "global_system_prompt": "",
  "ai_review": {
    "enabled": false,
    "base_url": "",
    "api_key": "",
    "model": "",
    "prompt": ""
  },
  "backup": {
    "enabled": false,
    "provider": "cloudflare_r2",
    "account_id": "",
    "access_key_id": "",
    "secret_access_key": "",
    "bucket": "",
    "prefix": "backups",
    "interval_minutes": 1440,
    "rotation_keep": 10,
    "encrypt": false,
    "passphrase": "",
    "include": {
      "config": true,
      "register": true,
      "cpa": true,
      "sub2api": true,
      "logs": true,
      "image_tasks": true,
      "accounts_snapshot": true,
      "auth_keys_snapshot": true,
      "images": false
    }
  },
  "image_account_concurrency": 3
}
EOF
}

write_env_file() {
    local install_path="$1"
    local host_port="$2"
    local auth_key="$3"
    local base_url="$4"

    cat > "${install_path}/.env" <<EOF
SERVER_PORT=${host_port}
CHATGPT2API_AUTH_KEY=${auth_key}
CHATGPT2API_BASE_URL=${base_url}
STORAGE_BACKEND=json
EOF
}

# ---- 1. 一键部署系统 ----
deploy_chatgpt2api() {
    info "== 启动 ChatGPT2API 自动化部署编排 =="
    require_cmd docker
    require_cmd openssl

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$install_path" && -f "$install_path/docker-compose.yml" ]]; then
        err "该路径已存在部署实例，请先执行 [8] 卸载。"
        return
    fi

    read -r -p "请输入对外访问端口 [默认: 3000]: " input_port
    local host_port=${input_port:-3000}
    if ! validate_port "$host_port"; then
        err "端口无效，必须是 1-65535 的整数。"
        return
    fi

    read -r -p "请输入 API 鉴权密钥 [直接回车随机生成]: " input_auth_key
    local auth_key=${input_auth_key:-$(openssl rand -hex 24)}
    if [[ ! "$auth_key" =~ ^[A-Za-z0-9._@:=,+/-]+$ ]]; then
        err "鉴权密钥仅支持字母、数字以及 . _ @ : = , + / -，请重新部署。"
        return
    fi

    read -r -p "请输入公网基础 URL [可留空，例如: https://api.example.com]: " input_base_url
    local base_url=${input_base_url:-}
    if [[ "$base_url" == *$'\n'* || "$base_url" == *$'\r'* ]]; then
        err "公网基础 URL 不能包含换行符，请重新部署。"
        return
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "/etc/chatgpt2api_env"
    cd "$install_path" || return

    info "正在生成专属运行配置..."
    mkdir -p data
    chmod -R 777 data
    write_compose_file "$install_path"
    write_config_file "$install_path" "$auth_key" "$base_url"
    write_env_file "$install_path" "$host_port" "$auth_key" "$base_url"

    info "正在拉起 ChatGPT2API 服务 (首次拉取镜像需 1-3 分钟)..."
    $dc_cmd -f docker-compose.yml up -d || { err "容器启动失败，请检查 Docker 状态。"; return; }

    local server_ip
    server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m部署指令已下发！ChatGPT2API 网关正在启动。\033[0m"
    echo -e "请务必在服务器防火墙/安全组中放行 \033[31m${host_port}\033[0m 端口！"
    echo -e "Web 面板: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "API 地址: \033[36mhttp://${server_ip}:${host_port}/v1\033[0m"
    echo -e "Authorization: \033[33mBearer ${auth_key}\033[0m"
    echo -e "==================================================\n"
}

# ---- 2. 升级服务 ----
upgrade_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的网关，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) -f docker-compose.yml pull
    $(docker_compose_cmd) -f docker-compose.yml up -d
    info "升级服务完成！"
}

# ---- 3/4. 启停控制 ----
pause_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的网关，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yml stop || true
    info "服务已停止。"
}

restart_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的网关，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yml restart || true
    info "服务已重启。"
}

# ---- 5. 手动热备 (注入高容错机制) ----
do_backup() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法执行备份。"
        return
    fi

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/chatgpt2api_backup_${timestamp}.tar.gz"

    info "开始执行备份..."
    cd "$workdir" || return

    local target_files=()
    local item
    for item in docker-compose.yml .env config.json data; do
        [[ -e "$item" ]] && target_files+=("$item")
    done

    if [[ ${#target_files[@]} -eq 0 ]]; then
        err "未找到任何核心配置或数据目录，备份终止。"
        return
    fi

    tar -czf "$backup_file" "${target_files[@]}" || { err "备份打包失败。"; return; }

    cd "$backup_dir" || return
    ls -t chatgpt2api_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f

    info "备份执行完毕。当前可用备份如下："
    for f in $(ls -t chatgpt2api_backup_*.tar.gz 2>/dev/null); do
        local abs_path="${backup_dir}/${f}"
        local fsize
        fsize=$(du -h "$f" | cut -f1)
        echo -e "  📦 \033[36m${abs_path}\033[0m (大小: ${fsize})"
    done
}

# ---- 6. 跨机恢复 ----
restore_backup() {
    info "== 灾备恢复 / 数据迁入引擎 =="

    local default_backup=""
    local current_wd
    current_wd=$(get_workdir)
    local search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"

    if [[ -d "$search_dir" ]]; then
        default_backup=$(ls -t "${search_dir}"/chatgpt2api_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    fi

    local backup_path=""
    if [[ -n "$default_backup" ]]; then
        echo -e "已智能嗅探到最新备份快照: \033[33m${default_backup}\033[0m"
        read -r -p "请输入备份文件路径 [直接回车使用默认]: " input_backup
        backup_path=${input_backup:-$default_backup}
    else
        read -r -p "请输入备份文件(.tar.gz)路径: " backup_path
    fi

    if [[ ! -f "$backup_path" ]]; then
        err "目标路径下未找到有效的快照文件，请检查。"
        return
    fi

    local backup_real_path
    backup_real_path=$(readlink -f "$backup_path") || { err "无法解析备份文件真实路径。"; return; }
    backup_path="$backup_real_path"
    info "已锁定恢复快照：${backup_path}"

    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.yml" ]]; then
        warn "目标目录已存在实例，恢复将覆盖现有数据！"
        read -r -p "是否强制覆盖继续？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已终止恢复流程。"
            return
        fi
        cd "$target_dir" && $(docker_compose_cmd) -f docker-compose.yml down || true
    fi

    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir" || { err "解压失败，备份包可能损坏。"; return; }
    if [[ -f "$backup_path" ]]; then
        info "原始备份快照已保留：${backup_path}"
    else
        warn "恢复完成，但原始备份快照未在原路径检测到，请检查是否被外部流程移动或清理。"
    fi

    echo "$target_dir" > "/etc/chatgpt2api_env"
    cd "$target_dir" || return

    mkdir -p data
    chmod -R 777 data || true

    $(docker_compose_cmd) -f docker-compose.yml up -d || { err "恢复启动失败。"; return; }

    local server_ip
    server_ip=$(get_local_ip)
    local host_port
    host_port=$(read_env_value ".env" "SERVER_PORT")
    host_port=${host_port:-3000}
    local auth_key
    auth_key=$(read_env_value ".env" "CHATGPT2API_AUTH_KEY")
    auth_key=${auth_key:-$(read_config_auth_key "config.json")}
    auth_key=${auth_key:-请查看.env或config.json文件}

    echo -e "\n=================================================="
    echo -e "\033[32m✅ ChatGPT2API 站点恢复完成！\033[0m"
    echo -e "Web 面板: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "API 地址: \033[36mhttp://${server_ip}:${host_port}/v1\033[0m"
    echo -e "Authorization: \033[33mBearer ${auth_key}\033[0m"
    echo -e "==================================================\n"
}

# ---- 7. 自动化时钟 (解耦物理引擎重构版) ----
setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="

    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法配置定时备份。"
        return
    fi

    local existing_cron=""
    local reset_cron=""
    local cron_type=""
    local cron_spec=""
    local min_interval=""
    local cron_time=""
    local hour=""
    local minute=""
    local tmp_cron=""

    local cron_script="${workdir}/cron_backup.sh"

    existing_cron="$(crontab -l 2>/dev/null | sed -n "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/p" | grep -v "^#" || true)"

    if [[ -n "$existing_cron" ]]; then
        echo -e "\033[36m>>> 发现当前正在运行的定时备份任务:\033[0m"
        echo -e "\033[33m${existing_cron}\033[0m"
        echo -e "---------------------------------------------------"
        read -r -p "是否需要重新设置或覆盖该任务？(y/N): " reset_cron
        if [[ ! "$reset_cron" =~ ^[Yy]$ ]]; then
            info "已保留当前配置，操作取消。"
            return
        fi
    else
        echo -e "当前未检测到定时备份任务。"
    fi

    echo " 1) 按固定分钟步进备份（推荐：1/2/3/4/5/6/10/12/15/20/30）"
    echo " 2) 按每日固定时间点备份（例如：每天 04:30）"
    echo " 3) 删除当前的定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type

    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数 [仅支持 1,2,3,4,5,6,10,12,15,20,30]: " min_interval

        if [[ ! "$min_interval" =~ ^[0-9]+$ ]]; then
            err "输入无效，必须是整数。"
            return
        fi

        case "$min_interval" in
            1|2|3|4|5|6|10|12|15|20|30)
                cron_spec="*/${min_interval} * * * *"
                info "已下发指令：每 ${min_interval} 分钟执行一次。"
                ;;
            *)
                err "不支持该分钟间隔。为避免 cron 步进产生歧义，仅支持：1,2,3,4,5,6,10,12,15,20,30"
                return
                ;;
        esac

    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            err "时间格式不正确。"
            return
        fi

        hour="${cron_time%:*}"
        minute="${cron_time#*:}"
        hour="$(echo "$hour" | sed 's/^0*//')"
        minute="$(echo "$minute" | sed 's/^0*//')"
        [[ -z "$hour" ]] && hour="0"
        [[ -z "$minute" ]] && minute="0"

        cron_spec="${minute} ${hour} * * *"
        info "已下发指令：每天 ${cron_time} 执行一次。"

    elif [[ "$cron_type" == "3" ]]; then
        tmp_cron="$(mktemp)" || { err "创建临时文件失败。"; return; }
        crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron"
        rm -f "$cron_script"
        info "定时备份任务已被成功清理。"
        return

    else
        err "无效的选择。"
        return
    fi

    info "正在为您锻造专属于该目录的物理级守护程序..."
    local quoted_workdir
    quoted_workdir=$(shell_quote "$workdir")
    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"

WORKDIR=${quoted_workdir}
cd "\$WORKDIR" || exit 1

BACKUP_DIR="\${WORKDIR}/backups"
mkdir -p "\$BACKUP_DIR"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="\${BACKUP_DIR}/chatgpt2api_backup_\${TIMESTAMP}.tar.gz"

TARGET_FILES=()
for item in docker-compose.yml .env config.json data; do
    [[ -e "\$item" ]] && TARGET_FILES+=("\$item")
done

if [[ \${#TARGET_FILES[@]} -gt 0 ]]; then
    tar -czf "\$BACKUP_FILE" "\${TARGET_FILES[@]}"
    cd "\$BACKUP_DIR" || exit 1
    ls -t chatgpt2api_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
fi
EOF
    chmod +x "$cron_script"

    tmp_cron="$(mktemp)" || { err "创建临时文件失败。"; return; }

    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true

    local quoted_cron_script
    local quoted_backup_log
    quoted_cron_script=$(shell_quote "$cron_script")
    quoted_backup_log=$(shell_quote "$BACKUP_LOG")

    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${quoted_cron_script} >> ${quoted_backup_log} 2>&1
${CRON_TAG_END}
EOF

    if ! crontab "$tmp_cron" 2>/dev/null; then
        rm -f "$tmp_cron"
        err "写入 crontab 失败，请检查 cron 服务状态。"
        return
    fi

    rm -f "$tmp_cron"

    info "新的定时任务已成功注入调度引擎。"
    echo -e "\033[36m底层调度链路已锚定实体文件:\033[0m"
    echo -e "\033[33m${cron_spec} bash ${quoted_cron_script} >> ${quoted_backup_log} 2>&1\033[0m"
}

# ---- 8. 彻底卸载 ----
uninstall_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无需卸载。"
        return
    fi

    echo -e "\033[31m⚠️ 警告：这将彻底摧毁所有容器及业务数据！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "操作已取消。"
        return
    fi

    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yml down -v || true

    cd /
    rm -rf "$workdir" || true
    rm -f "/etc/chatgpt2api_env" || true

    local tmp_cron
    tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron" || true

    info "容器及业务数据已被安全抹除。"
}

install_ftp() {
    clear
    echo -e "${GREEN}📂 FTP/SFTP 备份工具...${RESET}"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

# ---- 交互式主菜单 ----
main_menu() {
    clear
    echo "==================================================="
    echo "              ChatGPT2API 一键管理                "
    echo "==================================================="
    local wd
    wd=$(get_workdir)
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 📂 FTP/SFTP 备份工具"
    echo "  0) 退出脚本"
    echo "==================================================="

    read -r -p "请输入操作序号 [0-9]: " choice
    case "$choice" in
        1) deploy_chatgpt2api ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        0) info "欢迎下次使用，再见!"; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

# 路由引擎
if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then die "权限收敛：必须使用 Root 权限执行脚本。"; fi
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
