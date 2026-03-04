#!/usr/bin/env bash

# ==========================================
# Sub2API 运维控制台 
# ==========================================

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

    read -r -p "请输入自定义 YAML 文件直链地址 [直接回车使用官方默认]: " input_url
    local actual_url=${input_url:-$COMPOSE_URL}

    info "正在拉取核心拓扑文件..."
    curl -sSL "$actual_url" -o docker-compose.local.yml || { err "下载拓扑文件失败。"; return; }

    info "正在生成高强度加密凭证与专属管理员账号..."
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

# ---- 5. 零停机热备 ----
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
    
    info "开始执行备份..."
    cd "$workdir" || return
    tar -czf "$backup_file" docker-compose.local.yml .env data postgres_data redis_data
    
    # 轮转策略
    cd "$backup_dir" || return
    ls -t sub2api_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
    
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
    
    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir" || { err "解压失败，备份包可能损坏。"; return; }
    
    echo "$target_dir" > "/etc/sub2api_env"
    cd "$target_dir" || return
    
    chmod -R 777 data postgres_data redis_data || true
    
    $(docker_compose_cmd) -f docker-compose.local.yml up -d || { err "恢复启动失败。"; return; }
    
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

# ---- 7. 自动化时钟 ----
setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="
        local existing_cron=""
    existing_cron=$(crontab -l 2>/dev/null | sed -n "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/p" | grep -v "^#" || true)
    
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

    echo " 1) 按分钟间隔循环备份 (例如：每 30 分钟)"
    echo " 2) 按每日固定时间点备份 (例如：每天 04:30)"
    echo " 3) 删除当前的定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type
    
    local cron_spec=""
    
    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数 (例如 30): " min_interval
        if [[ ! "$min_interval" =~ ^[1-9][0-9]*$ ]]; then err "输入无效。"; return; fi
        cron_spec="*/${min_interval} * * * *"
        info "已下发指令：每 $min_interval 分钟执行一次。"
    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then err "时间格式不正确。"; return; fi
        local hour="${cron_time%:*}"
        local minute="${cron_time#*:}"
        hour=$(echo "$hour" | sed 's/^0*//'); [[ -z "$hour" ]] && hour="0"
        minute=$(echo "$minute" | sed 's/^0*//'); [[ -z "$minute" ]] && minute="0"
        cron_spec="${minute} ${hour} * * *"
        info "已下发指令：每天 $cron_time 执行一次。"
    elif [[ "$cron_type" == "3" ]]; then
        # 执行删除操作
        local tmp_cron=$(mktemp)
        crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron"
        info "定时备份任务已被成功清理。"
        return
    else
        err "无效的选择。"
        return
    fi
    
    # 写入新任务
    local tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${SCRIPT_PATH} run-backup >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"
    
    info "新的定时任务已成功注入调度引擎。"
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
