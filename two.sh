#!/usr/bin/env bash

# ==========================================
# Sub2API 第二实例一键管理脚本
# 默认实例 ID 为 sub2api2，可与原 sub2api 同机共存
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
set -o pipefail

APP_NAME="Sub2API"
INSTANCE_ID="${SUB2API_INSTANCE_ID:-sub2api2}"
DEFAULT_PORT="${SUB2API_DEFAULT_PORT:-6083}"
DEFAULT_INSTALL_PATH="${SUB2API_INSTALL_PATH:-/opt/${INSTANCE_ID}}"
ENV_RECORD_FILE="${SUB2API_ENV_RECORD_FILE:-/etc/${INSTANCE_ID}_env}"
COMPOSE_URL="${SUB2API_COMPOSE_URL:-https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/docker-compose.local.yml}"
COMPOSE_FILE="docker-compose.local.yml"
OVERRIDE_FILE="docker-compose.instance.yml"

INSTANCE_TAG="$(printf '%s' "$INSTANCE_ID" | tr '[:lower:]-' '[:upper:]_')"
CRON_TAG_BEGIN="# ${INSTANCE_TAG}_BACKUP_BEGIN"
CRON_TAG_END="# ${INSTANCE_TAG}_BACKUP_END"
BACKUP_LOG="/var/log/${INSTANCE_ID}_backup.log"
BACKUP_PREFIX="${INSTANCE_ID}_backup"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

validate_instance_id() {
    if [[ ! "$INSTANCE_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        die "实例标识不合法: ${INSTANCE_ID}。只能使用字母、数字、下划线或横线。"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1，请安装后重试。"
}

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

read_default() {
    local prompt="$1"
    local default_value="$2"
    local var_name="$3"
    local value

    read -r -p "${prompt} [默认: ${default_value}]: " value
    value="${value:-$default_value}"
    printf -v "$var_name" '%s' "$value"
}

confirm_yes() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} (y/N): " answer
    [[ "$answer" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]
}

pause_enter() {
    local _
    echo ""
    read -r -p "按回车键返回主菜单..." _
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "未检测到 Docker Compose，请先安装。"
    fi
}

get_script_path() {
    readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}"
}

get_workdir() {
    local dir=""
    if [[ -f "$ENV_RECORD_FILE" ]]; then
        dir="$(cat "$ENV_RECORD_FILE" 2>/dev/null || true)"
        if [[ -n "$dir" && -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi

    if [[ -d "$DEFAULT_INSTALL_PATH" && -f "${DEFAULT_INSTALL_PATH}/${COMPOSE_FILE}" ]]; then
        echo "$DEFAULT_INSTALL_PATH"
        return
    fi

    echo ""
}

env_get() {
    local key="$1"
    local env_file="$2"
    grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

set_env_key() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    touch "$env_file"
    tmp_file="$(mktemp)" || return 1
    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        $0 ~ "^" key "=" {
            print key "=" value
            found = 1
            next
        }
        { print }
        END {
            if (!found) {
                print key "=" value
            }
        }
    ' "$env_file" > "$tmp_file" && mv "$tmp_file" "$env_file"
}

port_in_use() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
        return $?
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
        return $?
    fi

    return 1
}

ask_port() {
    local prompt="$1"
    local default_port="$2"
    local var_name="$3"
    local port

    while true; do
        read_default "$prompt" "$default_port" port
        if ! valid_port "$port"; then
            err "端口不合法，必须是 1-65535。"
            continue
        fi

        if port_in_use "$port"; then
            warn "端口 ${port} 似乎已被占用。"
            confirm_yes "是否仍然使用该端口" || continue
        fi

        printf -v "$var_name" '%s' "$port"
        return 0
    done
}

write_override_file() {
    local workdir="$1"

    cat > "${workdir}/${OVERRIDE_FILE}" <<EOF
services:
  sub2api:
    container_name: \${APP_CONTAINER_NAME:-${INSTANCE_ID}-app}

  postgres:
    container_name: \${POSTGRES_CONTAINER_NAME:-${INSTANCE_ID}-postgres}

  redis:
    container_name: \${REDIS_CONTAINER_NAME:-${INSTANCE_ID}-redis}
EOF
}

normalize_env_for_instance() {
    local workdir="$1"
    local env_file="${workdir}/.env"

    set_env_key "$env_file" "COMPOSE_PROJECT_NAME" "$INSTANCE_ID"
    set_env_key "$env_file" "APP_CONTAINER_NAME" "${INSTANCE_ID}-app"
    set_env_key "$env_file" "POSTGRES_CONTAINER_NAME" "${INSTANCE_ID}-postgres"
    set_env_key "$env_file" "REDIS_CONTAINER_NAME" "${INSTANCE_ID}-redis"
}

ensure_instance_files() {
    local workdir="$1"

    [[ -f "${workdir}/${COMPOSE_FILE}" ]] || {
        err "缺少 ${workdir}/${COMPOSE_FILE}"
        return 1
    }

    write_override_file "$workdir"
    normalize_env_for_instance "$workdir"
}

compose() {
    local workdir="$1"
    shift

    cd "$workdir" || return 1
    local dc_cmd
    local project

    dc_cmd="$(docker_compose_cmd)"
    project="$(env_get COMPOSE_PROJECT_NAME "${workdir}/.env")"
    project="${project:-$INSTANCE_ID}"

    if [[ -f "$OVERRIDE_FILE" ]]; then
        COMPOSE_PROJECT_NAME="$project" $dc_cmd -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" "$@"
    else
        COMPOSE_PROJECT_NAME="$project" $dc_cmd -f "$COMPOSE_FILE" "$@"
    fi
}

show_access() {
    local workdir="$1"
    local env_file="${workdir}/.env"
    local host_port admin_email admin_pass

    host_port="$(env_get SERVER_PORT "$env_file")"
    host_port="${host_port:-$DEFAULT_PORT}"
    admin_email="$(env_get ADMIN_EMAIL "$env_file")"
    admin_email="${admin_email:-admin@${INSTANCE_ID}.local}"
    admin_pass="$(env_get ADMIN_PASSWORD "$env_file")"
    admin_pass="${admin_pass:-请查看 ${env_file}}"

    echo ""
    echo "=================================================="
    echo -e "\033[32m${APP_NAME} 实例已就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "实例标识:      \033[33m${INSTANCE_ID}\033[0m"
    echo -e "安装目录:      \033[33m${workdir}\033[0m"
    echo -e "访问地址:      \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo -e "本机地址:      \033[36mhttp://127.0.0.1:${host_port}\033[0m"
    echo -e "管理员账号:    \033[33m${admin_email}\033[0m"
    echo -e "管理员密码:    \033[33m${admin_pass}\033[0m"
    echo "--------------------------------------------------"
    echo "容器:"
    echo "  ${INSTANCE_ID}-app"
    echo "  ${INSTANCE_ID}-postgres"
    echo "  ${INSTANCE_ID}-redis"
    echo "=================================================="
    echo ""
}

wait_app_ready() {
    local workdir="$1"
    local env_file="${workdir}/.env"
    local host_port

    host_port="$(env_get SERVER_PORT "$env_file")"
    host_port="${host_port:-$DEFAULT_PORT}"

    info "正在等待 ${APP_NAME} 服务启动..."
    for _ in {1..60}; do
        if curl -fsS "http://127.0.0.1:${host_port}/health" >/dev/null 2>&1; then
            info "${APP_NAME} 已正常响应。"
            return 0
        fi
        sleep 2
    done

    warn "${APP_NAME} 暂未正常响应，输出最近日志供排查:"
    compose "$workdir" logs --tail=120 sub2api 2>/dev/null || true
    return 1
}

deploy_sub2api() {
    info "== 启动 ${APP_NAME} 第二实例自动化部署 =="
    info "当前实例标识: ${INSTANCE_ID}"
    require_cmd docker
    require_cmd curl
    require_cmd openssl
    docker_compose_cmd >/dev/null

    local install_path host_port admin_pass

    read_default "请输入安装路径" "$DEFAULT_INSTALL_PATH" install_path

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        err "安装路径非空: ${install_path}"
        err "请先执行卸载，或更换一个安装路径。"
        return
    fi

    ask_port "请输入对外访问端口" "$DEFAULT_PORT" host_port

    mkdir -p "$install_path" || return
    cd "$install_path" || return
    echo "$install_path" > "$ENV_RECORD_FILE"

    info "正在拉取核心编排文件..."
    curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE" || {
        err "下载编排文件失败。"
        return
    }

    admin_pass="$(openssl rand -hex 6)"

    cat > .env <<EOF
TZ=Asia/Shanghai
COMPOSE_PROJECT_NAME=${INSTANCE_ID}
APP_CONTAINER_NAME=${INSTANCE_ID}-app
POSTGRES_CONTAINER_NAME=${INSTANCE_ID}-postgres
REDIS_CONTAINER_NAME=${INSTANCE_ID}-redis

BIND_HOST=0.0.0.0
SERVER_PORT=${host_port}
POSTGRES_USER=sub2api
POSTGRES_DB=sub2api
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
TOTP_ENCRYPTION_KEY=$(openssl rand -hex 32)
ADMIN_EMAIL=admin@${INSTANCE_ID}.local
ADMIN_PASSWORD=${admin_pass}
EOF

    write_override_file "$install_path"
    mkdir -p data postgres_data redis_data backups
    chmod -R 777 data postgres_data redis_data

    info "正在拉取并启动容器矩阵，首次启动可能需要 1-3 分钟..."
    compose "$install_path" pull || warn "镜像拉取失败，将尝试使用本地镜像启动。"
    compose "$install_path" up -d || {
        err "容器启动失败，请检查 Docker 状态和日志。"
        return
    }

    wait_app_ready "$install_path" || true
    show_access "$install_path"
}

upgrade_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || { err "未检测到 ${INSTANCE_ID} 部署实例，请先执行一键部署。"; return; }

    ensure_instance_files "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    compose "$workdir" pull || return
    compose "$workdir" up -d || return
    wait_app_ready "$workdir" || true
    show_access "$workdir"
}

stop_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || { err "未检测到 ${INSTANCE_ID} 部署实例。"; return; }

    ensure_instance_files "$workdir" || return
    compose "$workdir" stop || true
    info "${INSTANCE_ID} 服务已停止。"
}

restart_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || { err "未检测到 ${INSTANCE_ID} 部署实例。"; return; }

    ensure_instance_files "$workdir" || return
    compose "$workdir" restart || true
    wait_app_ready "$workdir" || true
    show_access "$workdir"
}

do_backup() {
    local workdir backup_dir timestamp backup_file item
    local targets=()

    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || { err "未检测到 ${INSTANCE_ID} 部署实例。"; return; }

    backup_dir="${workdir}/backups"
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    backup_file="${backup_dir}/${BACKUP_PREFIX}_${timestamp}.tar.gz"

    mkdir -p "$backup_dir"
    ensure_instance_files "$workdir" || return

    for item in "$COMPOSE_FILE" "$OVERRIDE_FILE" ".env" "data" "postgres_data" "redis_data"; do
        [[ -e "${workdir}/${item}" ]] && targets+=("$item")
    done

    if [[ "${#targets[@]}" -eq 0 ]]; then
        err "未找到可备份的核心文件或数据目录。"
        return
    fi

    tar -czf "$backup_file" -C "$workdir" "${targets[@]}" || {
        err "备份失败。"
        return
    }

    cd "$backup_dir" || return
    ls -t "${BACKUP_PREFIX}"_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

restore_backup() {
    local current_wd search_dir default_backup backup_path target_dir host_port restored_port

    current_wd="$(get_workdir)"
    search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"
    default_backup="$(ls -t "${search_dir}/${BACKUP_PREFIX}"_*.tar.gz 2>/dev/null | head -n 1 || true)"

    read_default "请输入备份文件路径" "$default_backup" backup_path
    [[ -f "$backup_path" ]] || { err "未找到备份文件。"; return; }

    read_default "请输入恢复到的目标路径" "$DEFAULT_INSTALL_PATH" target_dir

    if [[ -d "$target_dir" && "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
        warn "目标目录已存在: ${target_dir}"
        confirm_yes "是否停止并覆盖该实例数据" || return
        if [[ -f "${target_dir}/${COMPOSE_FILE}" ]]; then
            ensure_instance_files "$target_dir" || true
            compose "$target_dir" down || true
        fi
        safe_remove_dir "$target_dir" || return
    fi

    mkdir -p "$target_dir" || return
    tar -xzf "$backup_path" -C "$target_dir" || {
        err "恢复失败，备份包可能已损坏。"
        return
    }

    echo "$target_dir" > "$ENV_RECORD_FILE"
    ensure_instance_files "$target_dir" || return

    restored_port="$(env_get SERVER_PORT "${target_dir}/.env")"
    restored_port="${restored_port:-$DEFAULT_PORT}"
    if port_in_use "$restored_port"; then
        warn "恢复出来的端口 ${restored_port} 似乎已被占用。"
        ask_port "请输入恢复实例的新对外端口" "$DEFAULT_PORT" host_port
        set_env_key "${target_dir}/.env" "SERVER_PORT" "$host_port"
    fi

    mkdir -p "${target_dir}"/{data,postgres_data,redis_data,backups}
    chmod -R 777 "${target_dir}/data" "${target_dir}/postgres_data" "${target_dir}/redis_data" || true

    compose "$target_dir" up -d || {
        err "恢复后的容器启动失败。"
        return
    }

    wait_app_ready "$target_dir" || true
    show_access "$target_dir"
}

setup_auto_backup() {
    require_cmd crontab

    local workdir cron_script cron_type cron_spec min_interval cron_time hour minute tmp_cron

    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || { err "未检测到 ${INSTANCE_ID} 部署实例。"; return; }

    cron_script="${workdir}/cron_backup.sh"

    echo "  1) 按固定分钟间隔备份"
    echo "  2) 按每日固定时间点备份"
    echo "  3) 删除当前定时备份任务"
    read_default "请选择策略" "1" cron_type

    case "$cron_type" in
        1)
            read_default "请输入间隔分钟数" "60" min_interval
            [[ "$min_interval" =~ ^[0-9]+$ && "$min_interval" -ge 1 ]] || {
                err "分钟间隔无效。"
                return
            }
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read_default "请输入每日备份时间 (HH:MM)" "04:30" cron_time
            [[ "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]] || {
                err "时间格式无效。"
                return
            }
            hour="${cron_time%:*}"
            minute="${cron_time#*:}"
            hour="$(echo "$hour" | sed 's/^0*//')"
            minute="$(echo "$minute" | sed 's/^0*//')"
            [[ -z "$hour" ]] && hour="0"
            [[ -z "$minute" ]] && minute="0"
            cron_spec="${minute} ${hour} * * *"
        ;;
        3)
            tmp_cron="$(mktemp)" || return
            crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
            crontab "$tmp_cron" 2>/dev/null || true
            rm -f "$tmp_cron" "$cron_script"
            info "定时备份任务已删除。"
            return
        ;;
        *)
            err "无效的选择。"
            return
        ;;
    esac

    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
WORKDIR="${workdir}"
BACKUP_PREFIX="${BACKUP_PREFIX}"
COMPOSE_FILE="${COMPOSE_FILE}"
OVERRIDE_FILE="${OVERRIDE_FILE}"

cd "\$WORKDIR" || exit 1
BACKUP_DIR="\${WORKDIR}/backups"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="\${BACKUP_DIR}/\${BACKUP_PREFIX}_\${TIMESTAMP}.tar.gz"
mkdir -p "\$BACKUP_DIR"

TARGETS=()
for item in "\$COMPOSE_FILE" "\$OVERRIDE_FILE" ".env" "data" "postgres_data" "redis_data"; do
    [[ -e "\${WORKDIR}/\${item}" ]] && TARGETS+=("\$item")
done

if [[ "\${#TARGETS[@]}" -gt 0 ]]; then
    tar -czf "\$BACKUP_FILE" -C "\$WORKDIR" "\${TARGETS[@]}"
    cd "\$BACKUP_DIR" || exit 1
    ls -t "\${BACKUP_PREFIX}"_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
fi
EOF
    chmod +x "$cron_script"

    tmp_cron="$(mktemp)" || return
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF

    crontab "$tmp_cron" || {
        rm -f "$tmp_cron"
        err "写入 crontab 失败。"
        return
    }
    rm -f "$tmp_cron"

    info "新的定时备份任务已写入:"
    echo "${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1"
}

safe_remove_dir() {
    local path="$1"
    local resolved

    [[ -n "$path" ]] || { err "删除路径为空，已取消。"; return 1; }
    resolved="$(readlink -f "$path" 2>/dev/null || realpath "$path" 2>/dev/null || echo "$path")"

    case "$resolved" in
        ""|"/"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/srv"|"/sys"|"/tmp"|"/usr"|"/var")
            err "拒绝删除危险路径: ${resolved}"
            return 1
        ;;
    esac

    rm -rf -- "$resolved"
}

uninstall_service() {
    local workdir tmp_cron

    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || workdir="$DEFAULT_INSTALL_PATH"

    echo -e "\033[31m警告：这将删除 ${INSTANCE_ID} 容器和本地业务数据！\033[0m"
    echo "目标路径: ${workdir}"
    confirm_yes "确认完全卸载" || return

    if [[ -d "$workdir" && -f "${workdir}/${COMPOSE_FILE}" ]]; then
        ensure_instance_files "$workdir" || true
        compose "$workdir" down -v || true
    fi

    safe_remove_dir "$workdir" || return
    rm -f "$ENV_RECORD_FILE"

    tmp_cron="$(mktemp)" || return
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"

    info "${INSTANCE_ID} 容器和业务数据已清理。"
}

install_ftp() {
    clear
    info "正在启动 FTP/SFTP 备份工具..."
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
}

main_menu() {
    clear
    local workdir
    workdir="$(get_workdir)"

    echo "==================================================="
    echo "                 ${APP_NAME} 一键管理                "
    echo "==================================================="
    echo -e " 实例运行路径: \033[36m${workdir:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) FTP/SFTP 备份工具"
    echo "  0) 退出脚本"
    echo "==================================================="

    local choice
    read -r -p "请输入操作序号 [0-9]: " choice

    case "$choice" in
        1) deploy_sub2api; pause_enter ;;
        2) upgrade_service; pause_enter ;;
        3) stop_service; pause_enter ;;
        4) restart_service; pause_enter ;;
        5) do_backup; pause_enter ;;
        6) restore_backup; pause_enter ;;
        7) setup_auto_backup; pause_enter ;;
        8) uninstall_service; pause_enter ;;
        9) install_ftp; pause_enter ;;
        0) info "欢迎下次使用，再见。"; exit 0 ;;
        *) warn "无效的指令，请重新输入。"; pause_enter ;;
    esac
}

validate_instance_id

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
    exit $?
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "权限不足：必须使用 Root 权限执行脚本。"
fi

while true; do
    main_menu
done
