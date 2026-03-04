#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Sub2API 高级一键运维管控域 (Manager) v2.2
# ==========================================

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/sub2api"
COMPOSE_URL="https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/docker-compose.local.yml"

CRON_TAG_BEGIN="# SUB2API_BACKUP_BEGIN"
CRON_TAG_END="# SUB2API_BACKUP_END"
BACKUP_LOG="/var/log/sub2api_backup.log"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"
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
        die "路径已存在部署实例，请先卸载。"
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "/etc/sub2api_env"
    cd "$install_path"

    read -r -p "请输入对外访问端口 [默认: 6082]: " input_port
    local host_port=${input_port:-6082}

    info "正在拉取拓扑文件..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.local.yml || die "下载失败。"

    info "正在生成高强度加密凭证与专属管理员账号..."
    local admin_pass=$(openssl rand -hex 6)
    
    # 【终极修复 1】: 利用云原生变量驱动架构，直接将 SERVER_PORT 注入 .env
    cat > .env <<EOF
SERVER_PORT=${host_port}
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
TOTP_ENCRYPTION_KEY=$(openssl rand -hex 32)
ADMIN_EMAIL=admin@sub2api.com
ADMIN_PASSWORD=${admin_pass}
EOF

    # 【终极修复 2】: 解决日志和配置权限穿透问题
    mkdir -p data postgres_data redis_data
    chmod -R 777 data postgres_data redis_data

    info "正在拉起微服务矩阵 (首次拉取需 1-3 分钟)..."
    $dc_cmd -f docker-compose.local.yml up -d

    local server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m部署指令已下发！网关正在启动。\033[0m"
    echo -e "请务必在服务器防火墙/安全组中放行 \033[31m${host_port}\033[0m 端口！"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "超级管理员账号: \033[33madmin@sub2api.com\033[0m"
    echo -e "超级管理员密码: \033[33m${admin_pass}\033[0m"
    echo -e "==================================================\n"
}

pause_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && die "未找到部署记录。"
    cd "$workdir"
    $(docker_compose_cmd) -f docker-compose.local.yml stop
    info "服务已停止。"
}

restart_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && die "未找到部署记录。"
    cd "$workdir"
    $(docker_compose_cmd) -f docker-compose.local.yml restart
    info "服务已重启。"
}

do_backup() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && die "未找到部署记录。"
    
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/sub2api_backup_${timestamp}.tar.gz"
    
    info "开始执行零停机热备..."
    cd "$workdir"
    tar -czf "$backup_file" docker-compose.local.yml .env data postgres_data redis_data
    
    cd "$backup_dir"
    ls -t sub2api_backup_*.tar.gz | awk 'NR>3' | xargs -I {} rm -f {}
    
    info "备份执行完毕。当前可用备份如下："
    ls -lh sub2api_backup_*.tar.gz
}

restore_backup() {
    info "== 灾备恢复 / 数据迁入引擎 =="
    read -r -p "请输入备份文件(.tar.gz)绝对路径: " backup_path
    
    if [[ ! -f "$backup_path" ]]; then die "找不到指定的备份文件。"; fi
    
    read -r -p "请输入期望恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.local.yml" ]]; then
        warn "目标目录已存在实例，恢复将覆盖现有数据！"
        read -r -p "是否强制覆盖继续？(y/N): " force_override
        [[ ! "$force_override" =~ ^[Yy]$ ]] && die "已终止恢复流程。"
        cd "$target_dir" && $(docker_compose_cmd) -f docker-compose.local.yml down || true
    fi
    
    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir"
    
    echo "$target_dir" > "/etc/sub2api_env"
    cd "$target_dir"
    
    # 恢复时确保权限
    chmod -R 777 data postgres_data redis_data
    
    $(docker_compose_cmd) -f docker-compose.local.yml up -d
    
    local server_ip=$(get_local_ip)
    # 从 .env 中提取恢复出的端口
    local host_port=$(grep -oP '^SERVER_PORT=\K\d+' .env || echo "8080")
    
    info "✅ 恢复完成！"
    info "访问地址: http://${server_ip}:${host_port}"
}

setup_auto_backup() {
    require_cmd crontab
    info "== 设置定时备份策略 =="
    echo " 1) 按分钟间隔循环备份 (例如：每 30 分钟)"
    echo " 2) 按每日固定时间点备份 (例如：每天 02:30)"
    read -r -p "请选择策略 [1/2]: " cron_type
    
    local cron_spec=""
    
    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数 (例如 30): " min_interval
        if [[ ! "$min_interval" =~ ^[1-9][0-9]*$ ]]; then die "输入无效。"; fi
        cron_spec="*/${min_interval} * * * *"
        info "已选择：每 $min_interval 分钟执行一次。"
    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then die "时间格式不正确。"; fi
        local hour="${cron_time%:*}"
        local minute="${cron_time#*:}"
        hour=$(echo "$hour" | sed 's/^0*//'); [[ -z "$hour" ]] && hour="0"
        minute=$(echo "$minute" | sed 's/^0*//'); [[ -z "$minute" ]] && minute="0"
        cron_spec="${minute} ${hour} * * *"
        info "已选择：每天 $cron_time 执行一次。"
    else
        die "无效的选择。"
    fi
    
    local tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${SCRIPT_PATH} run-backup >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    
    info "定时任务已设定。"
}

uninstall_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && die "未检测到环境记录。"
    echo -e "\033[31m⚠️ 警告：这将彻底摧毁所有容器及业务数据！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { info "已取消。"; return; }
    
    cd "$workdir"
    $(docker_compose_cmd) -f docker-compose.local.yml down -v || true
    cd / && rm -rf "$workdir" && rm -f "/etc/sub2api_env"
    
    local tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    info "系统卸载完成。"
}

main_menu() {
    clear
    echo "==================================================="
    echo "               Sub2API 运维控制台 v2.2               "
    echo "==================================================="
    local wd=$(get_workdir)
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 停止服务"
    echo "  3) 重启服务"
    echo "  4) 手动备份"
    echo "  5) 恢复备份"
    echo "  6) 定时备份"
    echo "  7) 完全卸载"
    echo "  0) 退出脚本"
    echo "==================================================="
    
    read -r -p "请输入操作序号 [0-7]: " choice
    case "$choice" in
        1) deploy_sub2api ;;
        2) pause_service ;;
        3) restart_service ;;
        4) do_backup ;;
        5) restore_backup ;;
        6) setup_auto_backup ;;
        7) uninstall_service ;;
        0) exit 0 ;;
        *) warn "无效的序号，请重新输入。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then die "权限拦截：请使用 root 权限执行脚本。"; fi
    while true; do
        main_menu
        read -r -p "按回车键重置终端..."
    done
fi
