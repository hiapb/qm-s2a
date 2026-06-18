#!/usr/bin/env bash

# ==========================================
# Sub2API 运维控制台
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
set -o pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/sub2api"
COMPOSE_URL="https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/docker-compose.local.yml"

CRON_TAG_BEGIN="# SUB2API_BACKUP_BEGIN"
CRON_TAG_END="# SUB2API_BACKUP_END"
BACKUP_LOG="/var/log/sub2api_backup.log"

# ---- 基础工具函数 ----
info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1，请安装后重试。"
}

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

get_workdir() {
    if [[ -f "/etc/sub2api_env" ]]; then
        local dir=$(cat "/etc/sub2api_env")
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    echo ""
}

# ---- 1. 一键部署系统 ----
deploy_sub2api() {
    info "== 启动 Sub2API 自动化部署编排 =="
    require_cmd docker
    require_cmd curl
    require_cmd openssl
    
    local dc_cmd=$(docker_compose_cmd)

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$install_path" && -f "$install_path/docker-compose.local.yml" ]]; then
        err "该路径已存在部署实例，请先执行 [8] 卸载。"
        return 
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "/etc/sub2api_env"
    cd "$install_path" || return

    read -r -p "请输入对外访问端口 [默认: 6082]: " input_port
    local host_port=${input_port:-6082}

    info "正在拉取核心拓扑文件..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.local.yml || { err "下载拓扑文件失败。"; return; }

    info "正在生成专属管理员账号..."
    local admin_pass=$(openssl rand -hex 6)
    
    cat > .env <<EOF
SERVER_PORT=${host_port}
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
TOTP_ENCRYPTION_KEY=$(openssl rand -hex 32)
ADMIN_EMAIL=admin@sub2api.com
ADMIN_PASSWORD=${admin_pass}
EOF

    mkdir -p data postgres_data redis_data
    chmod -R 777 data postgres_data redis_data

    info "正在拉起微服务矩阵 (首次拉取需 1-3 分钟)..."
    $dc_cmd -f docker-compose.local.yml up -d || { err "容器启动失败，请检查 Docker 状态。"; return; }

    local server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m部署指令已下发！网关正在启动。\033[0m"
    echo -e "请务必在服务器防火墙/安全组中放行 \033[31m${host_port}\033[0m 端口！"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "超级管理员账号: \033[33madmin@sub2api.com\033[0m"
    echo -e "超级管理员密码: \033[33m${admin_pass}\033[0m"
    echo -e "==================================================\n"
}

# ---- 2. 升级服务 ----
upgrade_service() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的网关，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) -f docker-compose.local.yml pull
    $(docker_compose_cmd) -f docker-compose.local.yml up -d
    info "升级服务完成！"
}

# ---- 3/4. 启停控制 ----
pause_service() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的网关，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.local.yml stop || true
    info "服务已停止。"
}

restart_service() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的网关，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.local.yml restart || true
    info "服务已重启。"
}


# ---- 热备份辅助函数 ----
env_get() {
    local key="$1"
    local env_file="$2"
    grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

get_service_container() {
    local workdir="$1"
    local service="$2"
    local container_id=""
    local dc_cmd=""

    dc_cmd=$(docker_compose_cmd)
    if [[ -d "$workdir" && -f "${workdir}/docker-compose.local.yml" ]]; then
        container_id=$(cd "$workdir" && $dc_cmd -f docker-compose.local.yml ps -q "$service" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "$container_id" ]]; then
        echo "$container_id"
        return 0
    fi

    case "$service" in
        postgres)
            docker ps --format '{{.Names}}' | grep -E '(^|[-_])postgres([-_]|$)' | head -n 1 || true
            ;;
        redis)
            docker ps --format '{{.Names}}' | grep -E '(^|[-_])redis([-_]|$)' | head -n 1 || true
            ;;
        *)
            echo ""
            ;;
    esac
}

container_running() {
    local container_name="$1"
    [[ -n "$container_name" ]] || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" == "true" ]]
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

wait_postgres_ready() {
    local workdir="$1"
    local env_file="${workdir}/.env"
    local pg_container pg_user pg_db

    pg_container=$(get_service_container "$workdir" postgres)
    pg_user=$(env_get POSTGRES_USER "$env_file")
    pg_user=${pg_user:-sub2api}
    pg_db=$(env_get POSTGRES_DB "$env_file")
    pg_db=${pg_db:-sub2api}

    for _ in {1..60}; do
        if docker exec "$pg_container" pg_isready -U "$pg_user" -d "$pg_db" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

cleanup_old_backups() {
    local backup_dir="$1"
    cd "$backup_dir" || return 0
    ls -t sub2api_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
}

backup_redis_by_bgsave() {
    local workdir="$1"
    local hot_dir="$2"
    local redis_container="$3"
    local redis_bgsave_before=""
    local redis_bgsave_after=""
    local redis_in_progress=""
    local redis_rdb_dir=""
    local redis_rdb_file=""
    local redis_rdb_path=""
    local bgsave_done=0

    info "正在触发 Redis BGSAVE，并等待后台快照完成..."
    redis_bgsave_before=$(docker exec "$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)
    redis_bgsave_before=${redis_bgsave_before:-0}

    docker exec "$redis_container" redis-cli BGSAVE >/dev/null 2>&1 || true

    for _ in {1..90}; do
        redis_in_progress=$(docker exec "$redis_container" sh -c "redis-cli INFO persistence 2>/dev/null | awk -F: '/^rdb_bgsave_in_progress:/ {print \$2}' | tr -cd '0-9'" 2>/dev/null || true)
        redis_in_progress=${redis_in_progress:-0}
        redis_bgsave_after=$(docker exec "$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)
        redis_bgsave_after=${redis_bgsave_after:-0}

        if [[ "$redis_in_progress" == "0" && "$redis_bgsave_after" =~ ^[0-9]+$ && "$redis_bgsave_before" =~ ^[0-9]+$ && "$redis_bgsave_after" -ge "$redis_bgsave_before" ]]; then
            bgsave_done=1
            break
        fi
        sleep 1
    done

    if [[ "$bgsave_done" -eq 1 ]]; then
        redis_rdb_dir=$(docker exec "$redis_container" sh -c "redis-cli CONFIG GET dir 2>/dev/null | tail -n 1 | tr -d '\r'" 2>/dev/null || true)
        redis_rdb_file=$(docker exec "$redis_container" sh -c "redis-cli CONFIG GET dbfilename 2>/dev/null | tail -n 1 | tr -d '\r'" 2>/dev/null || true)
        redis_rdb_dir=${redis_rdb_dir:-/data}
        redis_rdb_file=${redis_rdb_file:-dump.rdb}
        redis_rdb_path="${redis_rdb_dir%/}/${redis_rdb_file}"

        info "正在从 Redis 容器真实 RDB 路径复制快照..."
        if docker cp "${redis_container}:${redis_rdb_path}" "${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
            return 0
        fi

        warn "从 Redis 真实 RDB 路径复制失败，准备尝试 redis-cli --rdb。"
    fi

    if docker exec "$redis_container" sh -c 'redis-cli --help 2>/dev/null | grep -q -- --rdb' >/dev/null 2>&1; then
        docker exec "$redis_container" sh -c 'rm -f /tmp/sub2api_redis_dump.rdb && redis-cli --rdb /tmp/sub2api_redis_dump.rdb >/dev/null' >/dev/null 2>&1
        if docker cp "${redis_container}:/tmp/sub2api_redis_dump.rdb" "${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
            docker exec "$redis_container" rm -f /tmp/sub2api_redis_dump.rdb >/dev/null 2>&1 || true
            return 0
        fi
        docker exec "$redis_container" rm -f /tmp/sub2api_redis_dump.rdb >/dev/null 2>&1 || true
    fi

    if [[ -d "${workdir}/redis_data" ]]; then
        warn "Redis 容器快照复制失败，最后降级打包 redis_data 目录。"
        tar --warning=no-file-changed --ignore-failed-read -czf "${hot_dir}/redis_data.tar.gz" -C "$workdir" redis_data
        return $?
    fi

    return 1
}

create_hot_backup() {
    local workdir="$1"
    local backup_file="$2"
    local env_file="${workdir}/.env"
    local stage_dir hot_dir pg_container redis_container
    local pg_user pg_db pg_password
    local app_data_status=0 redis_status=0

    stage_dir=$(mktemp -d) || return 1
    hot_dir="${stage_dir}/hot_backup"
    mkdir -p "$hot_dir" || { rm -rf "$stage_dir"; return 1; }

    cp "${workdir}/docker-compose.local.yml" "${stage_dir}/docker-compose.local.yml" || { rm -rf "$stage_dir"; return 1; }
    [[ -f "${workdir}/.env" ]] && cp "${workdir}/.env" "${stage_dir}/.env"

    pg_container=$(get_service_container "$workdir" postgres)
    redis_container=$(get_service_container "$workdir" redis)
    pg_user=$(env_get POSTGRES_USER "$env_file")
    pg_user=${pg_user:-sub2api}
    pg_db=$(env_get POSTGRES_DB "$env_file")
    pg_db=${pg_db:-sub2api}
    pg_password=$(env_get POSTGRES_PASSWORD "$env_file")

    if ! container_running "$pg_container"; then
        rm -rf "$stage_dir"
        err "PostgreSQL 容器未运行，无法热备份。"
        return 1
    fi

    info "正在热备份 PostgreSQL 数据库，不停止服务..."
    if ! docker exec -e PGPASSWORD="$pg_password" "$pg_container" \
        pg_dump -U "$pg_user" -d "$pg_db" --no-owner --no-privileges \
        > "${hot_dir}/postgres_dump.sql"; then
        rm -rf "$stage_dir"
        err "PostgreSQL pg_dump 失败。"
        return 1
    fi
    gzip -f "${hot_dir}/postgres_dump.sql" || { rm -rf "$stage_dir"; err "PostgreSQL 备份压缩失败。"; return 1; }

    if [[ -d "${workdir}/data" ]]; then
        if find "${workdir}/data" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print -quit 2>/dev/null | grep -q .; then
            warn "data 目录发现 SQLite/DB 文件；热备份无法保证这类活跃二进制文件内部一致性。"
        fi

        info "正在打包业务 data 目录，自动排除实时日志..."
        tar --warning=no-file-changed --ignore-failed-read \
            -czf "${hot_dir}/data.tar.gz" \
            -C "$workdir" \
            --exclude='data/logs' \
            --exclude='data/*.log' \
            --exclude='data/**/*.log' \
            data || app_data_status=$?

        if [[ "$app_data_status" -ne 0 ]]; then
            warn "data 目录存在运行中变化，已尽量打包；核心 PostgreSQL 备份不受影响。"
        fi
    fi

    if container_running "$redis_container"; then
        info "正在热备份 Redis 快照..."
        redis_status=1

        if docker exec "$redis_container" redis-cli PING >/dev/null 2>&1; then
            backup_redis_by_bgsave "$workdir" "$hot_dir" "$redis_container"
            redis_status=$?
        else
            redis_status=1
        fi

        if [[ "$redis_status" -ne 0 ]]; then
            warn "Redis 快照备份失败或不可用，已继续完成 PostgreSQL 和业务文件热备份。"
        fi
    else
        warn "Redis 容器未运行，跳过 Redis 热备份。"
    fi

    {
        echo "BACKUP_TYPE=hot"
        echo "APP_NAME=Sub2API"
        echo "BACKUP_TIME=$(date -Iseconds)"
        echo "POSTGRES_DB=${pg_db}"
        echo "POSTGRES_CONTAINER=${pg_container}"
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

# ---- 5. 手动热备 (pg_dump + Redis 快照，不停止服务) ----
do_backup() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法执行备份。"
        return
    fi

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/sub2api_backup_${timestamp}.tar.gz"

    info "开始执行热备份，不会停止服务..."
    cd "$workdir" || return

    create_hot_backup "$workdir" "$backup_file" || {
        rm -f "$backup_file"
        err "热备份失败。"
        return
    }

    cleanup_old_backups "$backup_dir"

    info "备份执行完毕。当前可用备份如下："
    for f in $(ls -t sub2api_backup_*.tar.gz 2>/dev/null); do
        local abs_path="${backup_dir}/${f}"
        local fsize=$(du -h "$f" | cut -f1)
        echo -e "  📦 \033[36m${abs_path}\033[0m (大小: ${fsize})"
    done
}

# ---- 6. 跨机恢复 ----
restore_backup() {
    info "== 灾备恢复 / 数据迁入引擎 =="

    local default_backup=""
    local current_wd=$(get_workdir)
    local search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"

    if [[ -d "$search_dir" ]]; then
        default_backup=$(ls -t "${search_dir}"/sub2api_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
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

    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.local.yml" ]]; then
        warn "目标目录已存在实例，恢复将覆盖现有数据！"
        read -r -p "是否强制覆盖继续？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已终止恢复流程。"
            return
        fi
        cd "$target_dir" && $(docker_compose_cmd) -f docker-compose.local.yml down || true
    fi

    local tmp_extract=""
    tmp_extract=$(mktemp -d) || { err "创建临时目录失败。"; return; }
    tar -xzf "$backup_path" -C "$tmp_extract" || { rm -rf "$tmp_extract"; err "解压失败，备份包可能损坏。"; return; }

    mkdir -p "$target_dir"

    if [[ -f "${tmp_extract}/hot_backup/postgres_dump.sql.gz" ]]; then
        info "检测到热备份包，开始按 pg_dump 方式恢复。"

        cp "${tmp_extract}/docker-compose.local.yml" "${target_dir}/docker-compose.local.yml" || { rm -rf "$tmp_extract"; err "恢复编排文件失败。"; return; }
        [[ -f "${tmp_extract}/.env" ]] && cp "${tmp_extract}/.env" "${target_dir}/.env"

        mkdir -p "${target_dir}/data" "${target_dir}/postgres_data" "${target_dir}/redis_data" "${target_dir}/backups"

        if [[ -f "${tmp_extract}/hot_backup/data.tar.gz" ]]; then
            tar -xzf "${tmp_extract}/hot_backup/data.tar.gz" -C "$target_dir" || warn "业务 data 恢复不完整，请检查。"
        fi

        if [[ -f "${tmp_extract}/hot_backup/redis_dump.rdb" ]]; then
            cp "${tmp_extract}/hot_backup/redis_dump.rdb" "${target_dir}/redis_data/dump.rdb" || warn "Redis RDB 恢复文件复制失败。"
        elif [[ -f "${tmp_extract}/hot_backup/redis_data.tar.gz" ]]; then
            tar -xzf "${tmp_extract}/hot_backup/redis_data.tar.gz" -C "$target_dir" || warn "Redis 数据目录恢复不完整，请检查。"
        fi

        cp "${tmp_extract}/hot_backup/postgres_dump.sql.gz" "${target_dir}/backups/postgres_dump.sql.gz" || { rm -rf "$tmp_extract"; err "复制 PostgreSQL 备份文件失败。"; return; }
        [[ -f "${tmp_extract}/hot_backup/backup_manifest.txt" ]] && cp "${tmp_extract}/hot_backup/backup_manifest.txt" "${target_dir}/backups/backup_manifest.txt" || true

        rm -rf "$tmp_extract"
        echo "$target_dir" > "/etc/sub2api_env"
        cd "$target_dir" || return
        chmod -R 777 data postgres_data redis_data || true

        info "正在启动 PostgreSQL / Redis，用于导入热备份数据..."
        $(docker_compose_cmd) -f docker-compose.local.yml up -d postgres redis || { err "恢复基础容器启动失败。"; return; }

        if ! wait_postgres_ready "$target_dir"; then
            err "PostgreSQL 等待超时，无法导入热备份。"
            return
        fi

        local pg_container pg_user pg_db pg_password db_ident user_ident db_lit
        pg_container=$(get_service_container "$target_dir" postgres)
        pg_user=$(env_get POSTGRES_USER "${target_dir}/.env")
        pg_user=${pg_user:-sub2api}
        pg_db=$(env_get POSTGRES_DB "${target_dir}/.env")
        pg_db=${pg_db:-sub2api}
        pg_password=$(env_get POSTGRES_PASSWORD "${target_dir}/.env")
        db_ident=$(pg_ident "$pg_db")
        user_ident=$(pg_ident "$pg_user")
        db_lit=$(sql_literal "$pg_db")

        info "正在重建 PostgreSQL 数据库..."
        docker exec -e PGPASSWORD="$pg_password" "$pg_container" psql -q -U "$pg_user" -d postgres -v ON_ERROR_STOP=1 \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ${db_lit} AND pid <> pg_backend_pid();" >/dev/null || { err "终止数据库连接失败。"; return; }
        docker exec -e PGPASSWORD="$pg_password" "$pg_container" psql -q -U "$pg_user" -d postgres -v ON_ERROR_STOP=1 \
            -c "DROP DATABASE IF EXISTS ${db_ident};" >/dev/null || { err "删除旧数据库失败。"; return; }
        docker exec -e PGPASSWORD="$pg_password" "$pg_container" psql -q -U "$pg_user" -d postgres -v ON_ERROR_STOP=1 \
            -c "CREATE DATABASE ${db_ident} OWNER ${user_ident};" >/dev/null || { err "创建数据库失败。"; return; }

        info "正在导入 PostgreSQL 数据，请稍等..."
        if gzip -dc "${target_dir}/backups/postgres_dump.sql.gz" | docker exec -i -e PGPASSWORD="$pg_password" "$pg_container" \
            psql -q -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 >/dev/null; then
            info "PostgreSQL 数据导入完成。"
        else
            err "导入 PostgreSQL 数据失败。"
            return
        fi

        info "正在启动完整服务..."
        $(docker_compose_cmd) -f docker-compose.local.yml up -d || { err "恢复启动失败。"; return; }
    else
        info "检测到旧版目录备份包，按原目录结构恢复。"
        tar -xzf "$backup_path" -C "$target_dir" || { rm -rf "$tmp_extract"; err "解压失败，备份包可能损坏。"; return; }
        rm -rf "$tmp_extract"

        echo "$target_dir" > "/etc/sub2api_env"
        cd "$target_dir" || return

        chmod -R 777 data postgres_data redis_data || true

        $(docker_compose_cmd) -f docker-compose.local.yml up -d || { err "恢复启动失败。"; return; }
    fi

    local server_ip=$(get_local_ip)
    local host_port=$(grep -oP '^SERVER_PORT=\K.*' .env || echo "8080")
    local admin_email=$(grep -oP '^ADMIN_EMAIL=\K.*' .env || echo "admin@sub2api.com")
    local admin_pass=$(grep -oP '^ADMIN_PASSWORD=\K.*' .env || echo "请查看.env文件")

    echo -e "\n=================================================="
    echo -e "\033[32m✅ Sub2API站点 恢复完成！\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "超级管理员账号: \033[33m${admin_email}\033[0m"
    echo -e "超级管理员密码: \033[33m${admin_pass}\033[0m"
    echo -e "==================================================\n"
}

# ---- 7. 自动化时钟 (解耦物理引擎重构版) ----
setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="

    local workdir=$(get_workdir)
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

    # 物理实体化器：生成纯粹、独立、高容错的守护脚本
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

    echo " 1) 按固定分钟步进热备份（推荐：5/10/15/20/30/60）"
    echo " 2) 按每日固定时间点热备份（例如：每天 04:30）"
    echo " 3) 删除当前的定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type

    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数 [仅支持 1,2,3,4,5,6,10,12,15,20,30,60]: " min_interval

        if [[ ! "$min_interval" =~ ^[0-9]+$ ]]; then
            err "输入无效，必须是整数。"
            return
        fi

        case "$min_interval" in
            1|2|3|4|5|6|10|12|15|20|30|60)
                cron_spec="*/${min_interval} * * * *"
                info "已下发指令：每 ${min_interval} 分钟执行一次。"
                ;;
            *)
                err "不支持该分钟间隔。为避免 cron 步进产生歧义，仅支持：1,2,3,4,5,6,10,12,15,20,30,60"
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
        rm -f "$cron_script" # 同步摧毁物理实体脚本
        info "定时备份任务已被成功清理。"
        return

    else
        err "无效的选择。"
        return
    fi

    # --- 锻造独立物理执行器 ---
    info "正在为您锻造专属于该目录的物理级热备份守护程序..."
    cat > "$cron_script" << EOF
#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
set -o pipefail

WORKDIR="${workdir}"
BACKUP_LOG="${BACKUP_LOG}"

info() { echo -e "\\033[32m[INFO]\\033[0m \$1"; }
warn() { echo -e "\\033[33m[WARN]\\033[0m \$1" >&2; }
err()  { echo -e "\\033[31m[ERROR]\\033[0m \$1" >&2; }

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

env_get() {
    local key="\$1"
    local env_file="\$2"
    grep -E "^\${key}=" "\$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

get_service_container() {
    local service="\$1"
    local container_id=""
    local dc_cmd=""

    dc_cmd=\$(docker_compose_cmd)
    if [[ -d "\$WORKDIR" && -f "\${WORKDIR}/docker-compose.local.yml" ]]; then
        container_id=\$(cd "\$WORKDIR" && \$dc_cmd -f docker-compose.local.yml ps -q "\$service" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "\$container_id" ]]; then
        echo "\$container_id"
        return 0
    fi

    case "\$service" in
        postgres)
            docker ps --format '{{.Names}}' | grep -E '(^|[-_])postgres([-_]|$)' | head -n 1 || true
            ;;
        redis)
            docker ps --format '{{.Names}}' | grep -E '(^|[-_])redis([-_]|$)' | head -n 1 || true
            ;;
        *)
            echo ""
            ;;
    esac
}

container_running() {
    local container_name="\$1"
    [[ -n "\$container_name" ]] || return 1
    [[ "\$(docker inspect -f '{{.State.Running}}' "\$container_name" 2>/dev/null || true)" == "true" ]]
}

cleanup_old_backups() {
    local backup_dir="\$1"
    cd "\$backup_dir" || return 0
    ls -t sub2api_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
}

backup_redis_by_bgsave() {
    local hot_dir="\$1"
    local redis_container="\$2"
    local redis_bgsave_before=""
    local redis_bgsave_after=""
    local redis_in_progress=""
    local redis_rdb_dir=""
    local redis_rdb_file=""
    local redis_rdb_path=""
    local bgsave_done=0

    info "正在触发 Redis BGSAVE，并等待后台快照完成..."
    redis_bgsave_before=\$(docker exec "\$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)
    redis_bgsave_before=\${redis_bgsave_before:-0}

    docker exec "\$redis_container" redis-cli BGSAVE >/dev/null 2>&1 || true

    for _ in {1..90}; do
        redis_in_progress=\$(docker exec "\$redis_container" sh -c "redis-cli INFO persistence 2>/dev/null | awk -F: '/^rdb_bgsave_in_progress:/ {print \\\$2}' | tr -cd '0-9'" 2>/dev/null || true)
        redis_in_progress=\${redis_in_progress:-0}
        redis_bgsave_after=\$(docker exec "\$redis_container" redis-cli LASTSAVE 2>/dev/null | tr -cd '0-9' || true)
        redis_bgsave_after=\${redis_bgsave_after:-0}

        if [[ "\$redis_in_progress" == "0" && "\$redis_bgsave_after" =~ ^[0-9]+$ && "\$redis_bgsave_before" =~ ^[0-9]+$ && "\$redis_bgsave_after" -ge "\$redis_bgsave_before" ]]; then
            bgsave_done=1
            break
        fi
        sleep 1
    done

    if [[ "\$bgsave_done" -eq 1 ]]; then
        redis_rdb_dir=\$(docker exec "\$redis_container" sh -c "redis-cli CONFIG GET dir 2>/dev/null | tail -n 1 | tr -d '\\r'" 2>/dev/null || true)
        redis_rdb_file=\$(docker exec "\$redis_container" sh -c "redis-cli CONFIG GET dbfilename 2>/dev/null | tail -n 1 | tr -d '\\r'" 2>/dev/null || true)
        redis_rdb_dir=\${redis_rdb_dir:-/data}
        redis_rdb_file=\${redis_rdb_file:-dump.rdb}
        redis_rdb_path="\${redis_rdb_dir%/}/\${redis_rdb_file}"

        info "正在从 Redis 容器真实 RDB 路径复制快照..."
        if docker cp "\${redis_container}:\${redis_rdb_path}" "\${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
            return 0
        fi

        warn "从 Redis 真实 RDB 路径复制失败，准备尝试 redis-cli --rdb。"
    fi

    if docker exec "\$redis_container" sh -c 'redis-cli --help 2>/dev/null | grep -q -- --rdb' >/dev/null 2>&1; then
        docker exec "\$redis_container" sh -c 'rm -f /tmp/sub2api_redis_dump.rdb && redis-cli --rdb /tmp/sub2api_redis_dump.rdb >/dev/null' >/dev/null 2>&1
        if docker cp "\${redis_container}:/tmp/sub2api_redis_dump.rdb" "\${hot_dir}/redis_dump.rdb" >/dev/null 2>&1; then
            docker exec "\$redis_container" rm -f /tmp/sub2api_redis_dump.rdb >/dev/null 2>&1 || true
            return 0
        fi
        docker exec "\$redis_container" rm -f /tmp/sub2api_redis_dump.rdb >/dev/null 2>&1 || true
    fi

    if [[ -d "\${WORKDIR}/redis_data" ]]; then
        warn "Redis 容器快照复制失败，最后降级打包 redis_data 目录。"
        tar --warning=no-file-changed --ignore-failed-read -czf "\${hot_dir}/redis_data.tar.gz" -C "\$WORKDIR" redis_data
        return \$?
    fi

    return 1
}

create_hot_backup() {
    local backup_file="\$1"
    local env_file="\${WORKDIR}/.env"
    local stage_dir hot_dir pg_container redis_container
    local pg_user pg_db pg_password
    local app_data_status=0 redis_status=0

    stage_dir=\$(mktemp -d) || return 1
    hot_dir="\${stage_dir}/hot_backup"
    mkdir -p "\$hot_dir" || { rm -rf "\$stage_dir"; return 1; }

    cp "\${WORKDIR}/docker-compose.local.yml" "\${stage_dir}/docker-compose.local.yml" || { rm -rf "\$stage_dir"; return 1; }
    [[ -f "\${WORKDIR}/.env" ]] && cp "\${WORKDIR}/.env" "\${stage_dir}/.env"

    pg_container=\$(get_service_container postgres)
    redis_container=\$(get_service_container redis)
    pg_user=\$(env_get POSTGRES_USER "\$env_file")
    pg_user=\${pg_user:-sub2api}
    pg_db=\$(env_get POSTGRES_DB "\$env_file")
    pg_db=\${pg_db:-sub2api}
    pg_password=\$(env_get POSTGRES_PASSWORD "\$env_file")

    if ! container_running "\$pg_container"; then
        rm -rf "\$stage_dir"
        err "PostgreSQL 容器未运行，无法热备份。"
        return 1
    fi

    info "正在热备份 PostgreSQL 数据库，不停止服务..."
    if ! docker exec -e PGPASSWORD="\$pg_password" "\$pg_container" pg_dump -U "\$pg_user" -d "\$pg_db" --no-owner --no-privileges > "\${hot_dir}/postgres_dump.sql"; then
        rm -rf "\$stage_dir"
        err "PostgreSQL pg_dump 失败。"
        return 1
    fi
    gzip -f "\${hot_dir}/postgres_dump.sql" || { rm -rf "\$stage_dir"; err "PostgreSQL 备份压缩失败。"; return 1; }

    if [[ -d "\${WORKDIR}/data" ]]; then
        if find "\${WORKDIR}/data" -type f \\( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \\) -print -quit 2>/dev/null | grep -q .; then
            warn "data 目录发现 SQLite/DB 文件；热备份无法保证这类活跃二进制文件内部一致性。"
        fi

        info "正在打包业务 data 目录，自动排除实时日志..."
        tar --warning=no-file-changed --ignore-failed-read -czf "\${hot_dir}/data.tar.gz" -C "\$WORKDIR" --exclude='data/logs' --exclude='data/*.log' --exclude='data/**/*.log' data || app_data_status=\$?
        [[ "\$app_data_status" -ne 0 ]] && warn "data 目录存在运行中变化，已尽量打包；核心 PostgreSQL 备份不受影响。"
    fi

    if container_running "\$redis_container"; then
        info "正在热备份 Redis 快照..."
        redis_status=1
        if docker exec "\$redis_container" redis-cli PING >/dev/null 2>&1; then
            backup_redis_by_bgsave "\$hot_dir" "\$redis_container"
            redis_status=\$?
        else
            redis_status=1
        fi

        [[ "\$redis_status" -ne 0 ]] && warn "Redis 快照备份失败或不可用，已继续完成 PostgreSQL 和业务文件热备份。"
    else
        warn "Redis 容器未运行，跳过 Redis 热备份。"
    fi

    {
        echo "BACKUP_TYPE=hot"
        echo "APP_NAME=Sub2API"
        echo "BACKUP_TIME=\$(date -Iseconds)"
        echo "POSTGRES_DB=\${pg_db}"
        echo "POSTGRES_CONTAINER=\${pg_container}"
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
    return 0
}

cd "\$WORKDIR" || exit 1
BACKUP_DIR="\${WORKDIR}/backups"
mkdir -p "\$BACKUP_DIR"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="\${BACKUP_DIR}/sub2api_backup_\${TIMESTAMP}.tar.gz"

info "开始执行定时热备份，不会停止服务..."
create_hot_backup "\$BACKUP_FILE" || {
    rm -f "\$BACKUP_FILE"
    err "定时热备份失败。"
    exit 1
}
cleanup_old_backups "\$BACKUP_DIR"
info "定时热备份完成: \${BACKUP_FILE}"
EOF
    chmod +x "$cron_script"
    # --------------------------

    tmp_cron="$(mktemp)" || { err "创建临时文件失败。"; return; }

    # 清洗旧规则并注入新规则（锚定物理文件）
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true

    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1
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
    echo -e "\033[33m${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1\033[0m"
}

# ---- 8. 彻底卸载 ----
uninstall_service() {
    local workdir=$(get_workdir)
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
    $(docker_compose_cmd) -f docker-compose.local.yml down -v || true
    
    cd /
    rm -rf "$workdir" || true
    rm -f "/etc/sub2api_env" || true
    
    local tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron" || true
    
    info "容器及业务数据已被安全抹除。"
}

install_ftp(){
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
    echo "                 Sub2API 一键管理                 "
    echo "==================================================="
    local wd=$(get_workdir)
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
        1) deploy_sub2api ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp;;
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
