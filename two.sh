#!/usr/bin/env bash

# ==========================================
# Sub2API 第二实例一键管理脚本
# 默认实例 ID 为 sub2api2，可与原 sub2api 同机共存
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
set -o pipefail

APP_NAME="Sub2API 2"
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


get_container_name() {
    local workdir="$1"
    local service="$2"
    local env_file="${workdir}/.env"
    local key=""
    local fallback=""

    case "$service" in
        postgres)
            key="POSTGRES_CONTAINER_NAME"
            fallback="${INSTANCE_ID}-postgres"
        ;;
        redis)
            key="REDIS_CONTAINER_NAME"
            fallback="${INSTANCE_ID}-redis"
        ;;
        sub2api)
            key="APP_CONTAINER_NAME"
            fallback="${INSTANCE_ID}-app"
        ;;
        *)
            echo ""
            return 1
        ;;
    esac

    local value
    value="$(env_get "$key" "$env_file")"
    echo "${value:-$fallback}"
}

container_running() {
    local container_name="$1"
    [[ -n "$container_name" ]] || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" == "true" ]]
}

wait_postgres_ready() {
    local workdir="$1"
    local env_file="${workdir}/.env"
    local pg_container pg_user pg_db

    pg_container="$(get_container_name "$workdir" postgres)"
    pg_user="$(env_get POSTGRES_USER "$env_file")"
    pg_user="${pg_user:-sub2api}"
    pg_db="$(env_get POSTGRES_DB "$env_file")"
    pg_db="${pg_db:-sub2api}"

    info "正在等待 PostgreSQL 就绪..."
    for _ in {1..60}; do
        if docker exec "$pg_container" pg_isready -U "$pg_user" -d "$pg_db" >/dev/null 2>&1; then
            info "PostgreSQL 已就绪。"
            return 0
        fi
        sleep 2
    done

    err "PostgreSQL 等待超时。"
    return 1
}

sql_literal() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

pg_ident() {
    local value="$1"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

cleanup_old_backups() {
    local backup_dir="$1"
    cd "$backup_dir" || return 0
    ls -t "${BACKUP_PREFIX}"_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
}

create_hot_backup() {
    local workdir="$1"
    local backup_file="$2"
    local env_file="${workdir}/.env"
    local stage_dir hot_dir pg_container redis_container
    local pg_user pg_db pg_password
    local redis_bgsave_before redis_bgsave_after redis_dir redis_dbfilename redis_rdb_path rdb_in_progress
    local app_data_status=0 redis_status=0 redis_rdb_ok=0 redis_bgsave_ok=0

    stage_dir="$(mktemp -d)" || return 1
    hot_dir="${stage_dir}/hot_backup"
    mkdir -p "$hot_dir" || { rm -rf "$stage_dir"; return 1; }

    cp "${workdir}/${COMPOSE_FILE}" "${stage_dir}/${COMPOSE_FILE}" || { rm -rf "$stage_dir"; return 1; }
    [[ -f "${workdir}/${OVERRIDE_FILE}" ]] && cp "${workdir}/${OVERRIDE_FILE}" "${stage_dir}/${OVERRIDE_FILE}"
    [[ -f "${workdir}/.env" ]] && cp "${workdir}/.env" "${stage_dir}/.env"

    pg_container="$(get_container_name "$workdir" postgres)"
    redis_container="$(get_container_name "$workdir" redis)"
    pg_user="$(env_get POSTGRES_USER "$env_file")"
    pg_user="${pg_user:-sub2api}"
    pg_db="$(env_get POSTGRES_DB "$env_file")"
    pg_db="${pg_db:-sub2api}"
    pg_password="$(env_get POSTGRES_PASSWORD "$env_file")"

    if ! container_running "$pg_container"; then
        rm -rf "$stage_dir"
        err "PostgreSQL 容器未运行，无法热备份: ${pg_container}"
        return 1
    fi

    info "正在热备份 PostgreSQL 数据库，不停止服务..."
    if ! docker exec -e PGPASSWORD="$pg_password" "$pg_container" \
        pg_dump -U "$pg_user" -d "$pg_db" --no-owner --no-privileges \
        | gzip -c > "${hot_dir}/postgres_dump.sql.gz"; then
        rm -rf "$stage_dir"
        err "PostgreSQL pg_dump 失败。"
        return 1
    fi

    if [[ -d "${workdir}/data" ]]; then
        info "正在打包业务 data 目录，自动排除实时日志..."
        if [[ -n "$(find "${workdir}/data" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print -quit 2>/dev/null)" ]]; then
            warn "data 目录检测到 SQLite/DB 类活跃文件；热备份无法保证这类文件内部一致性，建议此类数据改用数据库导出或冷备。"
        fi
        tar --warning=no-file-changed --ignore-failed-read \
            -czf "${hot_dir}/data.tar.gz" \
            -C "$workdir" \
            --exclude='data/logs' \
            --exclude='data/*.log' \
            --exclude='data/**/*.log' \
            data || app_data_status=$?
        if [[ "$app_data_status" -ne 0 ]]; then
            warn "data 目录存在运行中变化，已尽量打包；核心数据库备份不受影响。"
        fi
    fi

    if container_running "$redis_container"; then
        info "正在热备份 Redis 快照..."
        if docker exec "$redis_container" redis-cli PING >/dev/null 2>&1; then
            redis_status=1
            redis_rdb_ok=0
            redis_bgsave_ok=0

            redis_bgsave_before="$(docker exec "$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)"
            redis_bgsave_before="${redis_bgsave_before:-0}"

            info "正在触发 Redis BGSAVE，并等待后台快照完成..."
            docker exec "$redis_container" redis-cli BGSAVE >/dev/null 2>&1 || true
            for _ in {1..120}; do
                rdb_in_progress="$(docker exec "$redis_container" sh -c "redis-cli INFO persistence 2>/dev/null | tr -d '\r' | awk -F: '/^rdb_bgsave_in_progress:/ {print \$2}'" || true)"
                redis_bgsave_after="$(docker exec "$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)"
                redis_bgsave_after="${redis_bgsave_after:-0}"

                if [[ "$rdb_in_progress" == "0" ]]; then
                    redis_bgsave_ok=1
                    break
                fi

                if [[ "$redis_bgsave_after" =~ ^[0-9]+$ && "$redis_bgsave_before" =~ ^[0-9]+$ && "$redis_bgsave_after" -gt "$redis_bgsave_before" ]]; then
                    redis_bgsave_ok=1
                    break
                fi
                sleep 1
            done

            redis_dir="$(docker exec "$redis_container" sh -c "redis-cli --raw CONFIG GET dir 2>/dev/null | tail -n 1 | tr -d '\r'" || true)"
            redis_dbfilename="$(docker exec "$redis_container" sh -c "redis-cli --raw CONFIG GET dbfilename 2>/dev/null | tail -n 1 | tr -d '\r'" || true)"
            redis_dir="${redis_dir:-/data}"
            redis_dbfilename="${redis_dbfilename:-dump.rdb}"

            info "正在从 Redis 容器真实 RDB 路径复制快照..."
            for redis_rdb_path in "${redis_dir}/${redis_dbfilename}" "/data/dump.rdb" "/var/lib/redis/dump.rdb"; do
                if docker cp "${redis_container}:${redis_rdb_path}" "${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
                    redis_rdb_ok=1
                    redis_status=0
                    break
                fi
            done

            if [[ "$redis_rdb_ok" -ne 1 ]]; then
                warn "从 Redis 容器复制 RDB 失败，尝试 redis-cli --rdb 在线导出。"
                docker exec "$redis_container" sh -c 'rm -f /tmp/sub2api_redis_dump.rdb && redis-cli --rdb /tmp/sub2api_redis_dump.rdb >/dev/null' >/dev/null 2>&1 || true
                if docker cp "${redis_container}:/tmp/sub2api_redis_dump.rdb" "${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
                    redis_rdb_ok=1
                    redis_status=0
                fi
                docker exec "$redis_container" rm -f /tmp/sub2api_redis_dump.rdb >/dev/null 2>&1 || true
            fi

            if [[ "$redis_rdb_ok" -ne 1 ]]; then
                warn "Redis RDB 导出失败，最后尝试打包宿主机 redis_data 目录。"
                if [[ -d "${workdir}/redis_data" ]]; then
                    if tar --warning=no-file-changed --ignore-failed-read -czf "${hot_dir}/redis_data.tar.gz" -C "$workdir" redis_data; then
                        redis_status=0
                    else
                        redis_status=$?
                    fi
                else
                    redis_status=1
                fi
            fi
        else
            redis_status=1
        fi

        if [[ "$redis_status" -ne 0 ]]; then
            warn "Redis 快照备份失败或不可用，已继续完成 PostgreSQL 和业务文件热备份。"
        fi
    else
        warn "Redis 容器未运行，跳过 Redis 热备份: ${redis_container}"
    fi

    {
        echo "BACKUP_TYPE=hot"
        echo "APP_NAME=${APP_NAME}"
        echo "INSTANCE_ID=${INSTANCE_ID}"
        echo "BACKUP_TIME=$(date -Iseconds)"
        echo "POSTGRES_CONTAINER=${pg_container}"
        echo "POSTGRES_DB=${pg_db}"
        echo "REDIS_CONTAINER=${redis_container}"
    } > "${hot_dir}/backup_manifest.txt"

    info "正在生成热备份压缩包..."
    if ! tar -czf "$backup_file" -C "$stage_dir" .; then
        rm -rf "$stage_dir"
        rm -f "$backup_file"
        err "生成备份包失败。"
        return 1
    fi

    rm -rf "$stage_dir"
    return 0
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
    local workdir backup_dir timestamp backup_file

    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || { err "未检测到 ${INSTANCE_ID} 部署实例。"; return; }

    backup_dir="${workdir}/backups"
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    backup_file="${backup_dir}/${BACKUP_PREFIX}_${timestamp}.tar.gz"

    mkdir -p "$backup_dir"
    ensure_instance_files "$workdir" || return

    info "开始热备份：不会停止容器，不会中断服务。"
    create_hot_backup "$workdir" "$backup_file" || {
        rm -f "$backup_file"
        err "热备份失败。"
        return
    }

    cleanup_old_backups "$backup_dir"
    info "热备份完成: ${backup_file}"
}

restore_backup() {
    local current_wd search_dir default_backup backup_path safe_backup target_dir host_port restored_port
    local tmp_extract is_hot_backup pg_container pg_user pg_db pg_password db_ident user_ident db_lit

    current_wd="$(get_workdir)"
    search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"
    default_backup="$(ls -t "${search_dir}/${BACKUP_PREFIX}"_*.tar.gz 2>/dev/null | head -n 1 || true)"

    read_default "请输入备份文件路径" "$default_backup" backup_path
    [[ -f "$backup_path" ]] || { err "未找到备份文件。"; return; }

    safe_backup="/tmp/$(basename "$backup_path")"
    cp "$backup_path" "$safe_backup" || {
        err "备份文件复制到临时目录失败。"
        return
    }

    read_default "请输入恢复到的目标路径" "$DEFAULT_INSTALL_PATH" target_dir

    if [[ -d "$target_dir" && "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
        warn "目标目录已存在: ${target_dir}"
        confirm_yes "是否停止并覆盖该实例数据" || {
            rm -f "$safe_backup"
            return
        }
        if [[ -f "${target_dir}/${COMPOSE_FILE}" ]]; then
            ensure_instance_files "$target_dir" || true
            compose "$target_dir" down || true
        fi
        safe_remove_dir "$target_dir" || {
            rm -f "$safe_backup"
            return
        }
    fi

    tmp_extract="$(mktemp -d)" || {
        rm -f "$safe_backup"
        return
    }

    tar -xzf "$safe_backup" -C "$tmp_extract" || {
        rm -rf "$tmp_extract"
        rm -f "$safe_backup"
        err "恢复失败，备份包可能已损坏。"
        return
    }

    mkdir -p "$target_dir" || {
        rm -rf "$tmp_extract"
        rm -f "$safe_backup"
        return
    }

    is_hot_backup=0
    [[ -f "${tmp_extract}/hot_backup/postgres_dump.sql.gz" ]] && is_hot_backup=1

    if [[ "$is_hot_backup" -eq 1 ]]; then
        info "检测到热备份包，开始按 pg_dump 方式恢复。"
        cp "${tmp_extract}/${COMPOSE_FILE}" "${target_dir}/${COMPOSE_FILE}" || { err "恢复编排文件失败。"; rm -rf "$tmp_extract"; rm -f "$safe_backup"; return; }
        [[ -f "${tmp_extract}/${OVERRIDE_FILE}" ]] && cp "${tmp_extract}/${OVERRIDE_FILE}" "${target_dir}/${OVERRIDE_FILE}"
        [[ -f "${tmp_extract}/.env" ]] && cp "${tmp_extract}/.env" "${target_dir}/.env"

        mkdir -p "${target_dir}"/{data,postgres_data,redis_data,backups}
        cp "${tmp_extract}/hot_backup/postgres_dump.sql.gz" "${target_dir}/backups/postgres_dump.sql.gz" || {
            err "复制 PostgreSQL 热备份 SQL 失败。"
            rm -rf "$tmp_extract"
            rm -f "$safe_backup"
            return
        }
        [[ -f "${tmp_extract}/hot_backup/backup_manifest.txt" ]] && cp "${tmp_extract}/hot_backup/backup_manifest.txt" "${target_dir}/backups/backup_manifest.txt" 2>/dev/null || true
        if [[ -f "${tmp_extract}/hot_backup/data.tar.gz" ]]; then
            tar -xzf "${tmp_extract}/hot_backup/data.tar.gz" -C "$target_dir" || warn "业务 data 恢复不完整，请检查。"
        fi
        if [[ -f "${tmp_extract}/hot_backup/redis_dump.rdb" ]]; then
            cp "${tmp_extract}/hot_backup/redis_dump.rdb" "${target_dir}/redis_data/dump.rdb" || warn "Redis RDB 恢复文件复制失败。"
        elif [[ -f "${tmp_extract}/hot_backup/redis_data.tar.gz" ]]; then
            tar -xzf "${tmp_extract}/hot_backup/redis_data.tar.gz" -C "$target_dir" || warn "Redis 数据目录恢复不完整，请检查。"
        fi
    else
        info "检测到旧版冷备份包，按原目录结构恢复。"
        cp -a "${tmp_extract}/." "$target_dir/" || {
            rm -rf "$tmp_extract"
            rm -f "$safe_backup"
            err "恢复文件复制失败。"
            return
        }
    fi

    mkdir -p "${target_dir}/backups"
    cp "$safe_backup" "${target_dir}/backups/$(basename "$safe_backup")" 2>/dev/null || true
    rm -f "$safe_backup"
    rm -rf "$tmp_extract"

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

    if [[ "$is_hot_backup" -eq 1 ]]; then
        info "正在启动 PostgreSQL / Redis，用于导入热备份数据..."
        compose "$target_dir" up -d postgres redis || {
            err "恢复基础容器启动失败。"
            return
        }
        wait_postgres_ready "$target_dir" || return

        pg_container="$(get_container_name "$target_dir" postgres)"
        pg_user="$(env_get POSTGRES_USER "${target_dir}/.env")"
        pg_user="${pg_user:-sub2api}"
        pg_db="$(env_get POSTGRES_DB "${target_dir}/.env")"
        pg_db="${pg_db:-sub2api}"
        pg_password="$(env_get POSTGRES_PASSWORD "${target_dir}/.env")"
        db_ident="$(pg_ident "$pg_db")"
        user_ident="$(pg_ident "$pg_user")"
        db_lit="$(sql_literal "$pg_db")"

        info "正在重建 PostgreSQL 数据库..."
        docker exec -e PGPASSWORD="$pg_password" "$pg_container" \
            psql -U "$pg_user" -d postgres -v ON_ERROR_STOP=1 \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ${db_lit} AND pid <> pg_backend_pid();" || {
            err "终止数据库连接失败。"
            return
        }

        docker exec -e PGPASSWORD="$pg_password" "$pg_container" \
            psql -U "$pg_user" -d postgres -v ON_ERROR_STOP=1 \
            -c "DROP DATABASE IF EXISTS ${db_ident};" || {
            err "删除旧数据库失败。"
            return
        }

        docker exec -e PGPASSWORD="$pg_password" "$pg_container" \
            psql -U "$pg_user" -d postgres -v ON_ERROR_STOP=1 \
            -c "CREATE DATABASE ${db_ident} OWNER ${user_ident};" || {
            err "创建新数据库失败。"
            return
        }

        info "正在导入 PostgreSQL 数据..."

        local sql_dump_path
        sql_dump_path="${target_dir}/backups/postgres_dump.sql.gz"
        [[ -f "$sql_dump_path" ]] || {
            err "无法读取热备份 SQL 文件。"
            return
        }
        gzip -dc "$sql_dump_path" | docker exec -i -e PGPASSWORD="$pg_password" "$pg_container" \
            psql -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 || {
            err "导入 PostgreSQL 数据失败。"
            return
        }


        compose "$target_dir" up -d || {
            err "恢复后的容器启动失败。"
            return
        }
    else
        compose "$target_dir" up -d || {
            err "恢复后的容器启动失败。"
            return
        }
    fi

    wait_app_ready "$target_dir" || true
    show_access "$target_dir"
}

setup_auto_backup() {
    require_cmd crontab

    local workdir cron_script cron_type cron_spec min_interval cron_time hour minute tmp_cron

    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || { err "未检测到 ${INSTANCE_ID} 部署实例。"; return; }

    cron_script="${workdir}/cron_backup.sh"

    echo "  1) 按固定分钟间隔热备份"
    echo "  2) 按每日固定时间点热备份"
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
set -o pipefail

INSTANCE_ID="${INSTANCE_ID}"
APP_NAME="${APP_NAME}"
WORKDIR="${workdir}"
COMPOSE_FILE="${COMPOSE_FILE}"
OVERRIDE_FILE="${OVERRIDE_FILE}"
BACKUP_PREFIX="${BACKUP_PREFIX}"

info() { echo -e "\\033[32m[INFO]\\033[0m \$1"; }
warn() { echo -e "\\033[33m[WARN]\\033[0m \$1" >&2; }
err()  { echo -e "\\033[31m[ERROR]\\033[0m \$1" >&2; }

env_get() {
    local key="\$1"
    local env_file="\$2"
    grep -E "^\${key}=" "\$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        err "未检测到 Docker Compose。"
        exit 1
    fi
}

get_container_name() {
    local service="\$1"
    local env_file="\${WORKDIR}/.env"
    local key=""
    local fallback=""
    case "\$service" in
        postgres) key="POSTGRES_CONTAINER_NAME"; fallback="\${INSTANCE_ID}-postgres" ;;
        redis) key="REDIS_CONTAINER_NAME"; fallback="\${INSTANCE_ID}-redis" ;;
        sub2api) key="APP_CONTAINER_NAME"; fallback="\${INSTANCE_ID}-app" ;;
    esac
    local value
    value="\$(env_get "\$key" "\$env_file")"
    echo "\${value:-\$fallback}"
}

container_running() {
    local container_name="\$1"
    [[ -n "\$container_name" ]] || return 1
    [[ "\$(docker inspect -f '{{.State.Running}}' "\$container_name" 2>/dev/null || true)" == "true" ]]
}

cleanup_old_backups() {
    local backup_dir="\$1"
    cd "\$backup_dir" || return 0
    ls -t "\${BACKUP_PREFIX}"_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
}

create_hot_backup() {
    local backup_file="\$1"
    local env_file="\${WORKDIR}/.env"
    local stage_dir hot_dir pg_container redis_container
    local pg_user pg_db pg_password
    local redis_bgsave_before redis_bgsave_after redis_dir redis_dbfilename redis_rdb_path rdb_in_progress
    local app_data_status=0 redis_status=0 redis_rdb_ok=0 redis_bgsave_ok=0

    stage_dir="\$(mktemp -d)" || return 1
    hot_dir="\${stage_dir}/hot_backup"
    mkdir -p "\$hot_dir" || { rm -rf "\$stage_dir"; return 1; }

    cp "\${WORKDIR}/\${COMPOSE_FILE}" "\${stage_dir}/\${COMPOSE_FILE}" || { rm -rf "\$stage_dir"; return 1; }
    [[ -f "\${WORKDIR}/\${OVERRIDE_FILE}" ]] && cp "\${WORKDIR}/\${OVERRIDE_FILE}" "\${stage_dir}/\${OVERRIDE_FILE}"
    [[ -f "\${WORKDIR}/.env" ]] && cp "\${WORKDIR}/.env" "\${stage_dir}/.env"

    pg_container="\$(get_container_name postgres)"
    redis_container="\$(get_container_name redis)"
    pg_user="\$(env_get POSTGRES_USER "\$env_file")"
    pg_user="\${pg_user:-sub2api}"
    pg_db="\$(env_get POSTGRES_DB "\$env_file")"
    pg_db="\${pg_db:-sub2api}"
    pg_password="\$(env_get POSTGRES_PASSWORD "\$env_file")"

    if ! container_running "\$pg_container"; then
        rm -rf "\$stage_dir"
        err "PostgreSQL 容器未运行，无法热备份: \${pg_container}"
        return 1
    fi

    info "正在热备份 PostgreSQL 数据库，不停止服务..."
    if ! docker exec -e PGPASSWORD="\$pg_password" "\$pg_container" pg_dump -U "\$pg_user" -d "\$pg_db" --no-owner --no-privileges | gzip -c > "\${hot_dir}/postgres_dump.sql.gz"; then
        rm -rf "\$stage_dir"
        err "PostgreSQL pg_dump 失败。"
        return 1
    fi

    if [[ -d "\${WORKDIR}/data" ]]; then
        info "正在打包业务 data 目录，自动排除实时日志..."
        if [[ -n "\$(find "\${WORKDIR}/data" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print -quit 2>/dev/null)" ]]; then
            warn "data 目录检测到 SQLite/DB 类活跃文件；热备份无法保证这类文件内部一致性，建议此类数据改用数据库导出或冷备。"
        fi
        tar --warning=no-file-changed --ignore-failed-read -czf "\${hot_dir}/data.tar.gz" -C "\$WORKDIR" --exclude='data/logs' --exclude='data/*.log' --exclude='data/**/*.log' data || app_data_status=\$?
        [[ "\$app_data_status" -ne 0 ]] && warn "data 目录存在运行中变化，已尽量打包；核心数据库备份不受影响。"
    fi

    if container_running "\$redis_container"; then
        info "正在热备份 Redis 快照..."
        if docker exec "\$redis_container" redis-cli PING >/dev/null 2>&1; then
            redis_status=1
            redis_rdb_ok=0
            redis_bgsave_ok=0

            redis_bgsave_before="\$(docker exec "\$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)"
            redis_bgsave_before="\${redis_bgsave_before:-0}"

            info "正在触发 Redis BGSAVE，并等待后台快照完成..."
            docker exec "\$redis_container" redis-cli BGSAVE >/dev/null 2>&1 || true
            for _ in {1..120}; do
                rdb_in_progress="\$(docker exec "\$redis_container" sh -c "redis-cli INFO persistence 2>/dev/null | tr -d '\r' | awk -F: '/^rdb_bgsave_in_progress:/ {print \\$2}'" || true)"
                redis_bgsave_after="\$(docker exec "\$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)"
                redis_bgsave_after="\${redis_bgsave_after:-0}"

                if [[ "\$rdb_in_progress" == "0" ]]; then
                    redis_bgsave_ok=1
                    break
                fi

                if [[ "\$redis_bgsave_after" =~ ^[0-9]+$ && "\$redis_bgsave_before" =~ ^[0-9]+$ && "\$redis_bgsave_after" -gt "\$redis_bgsave_before" ]]; then
                    redis_bgsave_ok=1
                    break
                fi
                sleep 1
            done

            redis_dir="\$(docker exec "\$redis_container" sh -c "redis-cli --raw CONFIG GET dir 2>/dev/null | tail -n 1 | tr -d '\r'" || true)"
            redis_dbfilename="\$(docker exec "\$redis_container" sh -c "redis-cli --raw CONFIG GET dbfilename 2>/dev/null | tail -n 1 | tr -d '\r'" || true)"
            redis_dir="\${redis_dir:-/data}"
            redis_dbfilename="\${redis_dbfilename:-dump.rdb}"

            info "正在从 Redis 容器真实 RDB 路径复制快照..."
            for redis_rdb_path in "\${redis_dir}/\${redis_dbfilename}" "/data/dump.rdb" "/var/lib/redis/dump.rdb"; do
                if docker cp "\${redis_container}:\${redis_rdb_path}" "\${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
                    redis_rdb_ok=1
                    redis_status=0
                    break
                fi
            done

            if [[ "\$redis_rdb_ok" -ne 1 ]]; then
                warn "从 Redis 容器复制 RDB 失败，尝试 redis-cli --rdb 在线导出。"
                docker exec "\$redis_container" sh -c 'rm -f /tmp/sub2api_redis_dump.rdb && redis-cli --rdb /tmp/sub2api_redis_dump.rdb >/dev/null' >/dev/null 2>&1 || true
                if docker cp "\${redis_container}:/tmp/sub2api_redis_dump.rdb" "\${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
                    redis_rdb_ok=1
                    redis_status=0
                fi
                docker exec "\$redis_container" rm -f /tmp/sub2api_redis_dump.rdb >/dev/null 2>&1 || true
            fi

            if [[ "\$redis_rdb_ok" -ne 1 ]]; then
                warn "Redis RDB 导出失败，最后尝试打包宿主机 redis_data 目录。"
                if [[ -d "\${WORKDIR}/redis_data" ]]; then
                    if tar --warning=no-file-changed --ignore-failed-read -czf "\${hot_dir}/redis_data.tar.gz" -C "\$WORKDIR" redis_data; then
                        redis_status=0
                    else
                        redis_status=\$?
                    fi
                else
                    redis_status=1
                fi
            fi
        else
            redis_status=1
        fi
        [[ "\$redis_status" -ne 0 ]] && warn "Redis 快照备份失败或不可用，已继续完成 PostgreSQL 和业务文件热备份。"
    else
        warn "Redis 容器未运行，跳过 Redis 热备份: \${redis_container}"
    fi

    {
        echo "BACKUP_TYPE=hot"
        echo "APP_NAME=\${APP_NAME}"
        echo "INSTANCE_ID=\${INSTANCE_ID}"
        echo "BACKUP_TIME=\$(date -Iseconds)"
        echo "POSTGRES_CONTAINER=\${pg_container}"
        echo "POSTGRES_DB=\${pg_db}"
        echo "REDIS_CONTAINER=\${redis_container}"
    } > "\${hot_dir}/backup_manifest.txt"

    info "正在生成热备份压缩包..."
    if ! tar -czf "\$backup_file" -C "\$stage_dir" .; then
        rm -rf "\$stage_dir"
        rm -f "\$backup_file"
        err "生成备份包失败。"
        return 1
    fi
    rm -rf "\$stage_dir"
}

cd "\$WORKDIR" || exit 1
BACKUP_DIR="\${WORKDIR}/backups"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="\${BACKUP_DIR}/\${BACKUP_PREFIX}_\${TIMESTAMP}.tar.gz"
mkdir -p "\$BACKUP_DIR"

info "开始定时热备份：不会停止容器，不会中断服务。"
create_hot_backup "\$BACKUP_FILE" || {
    rm -f "\$BACKUP_FILE"
    err "定时热备份失败。"
    exit 1
}
cleanup_old_backups "\$BACKUP_DIR"
info "定时热备份完成: \${BACKUP_FILE}"
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

    info "新的定时热备份任务已写入:"
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
