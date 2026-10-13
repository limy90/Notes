#!/bin/bash
#
# 综合管理脚本：Fail2ban(SSH封禁) + IP优先级管理
# 目标: Bash 4.0+ / Debian·Ubuntu·CentOS·RHEL·AlmaLinux·Rocky
#
set -o pipefail
# 不使用 set -u，因为交互脚本中 SSH_CLIENT 等可能未定义

# ====================== 全局通用配置 ======================
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[36m'
PURPLE='\033[0;35m'; GRAY='\033[90m'; NC='\033[0m'; PLAIN="\033[0m"

# 兼容不支持颜色的终端
if [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; GRAY=''; NC=''; PLAIN=''
fi

JAIL_CONF="/etc/fail2ban/jail.local"
TARGET_JAIL="sshd"
LOG_FILE="/var/log/fail2ban.log"
GAI_FILE="/etc/gai.conf"
BACKUP_FILE="/etc/gai.conf.bak.default"

die()  { echo -e "${RED}错误: $*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }
ok()   { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${PLAIN}"; }
pause_any() { read -n 1 -s -r -p "按任意键继续..."; echo; }

# 读取用户输入（qa 指令可供自动化调用）
ask() {
    local prompt="$1" var
    read -r -p "$prompt" var
    REPLY="$var"
}

# ====================== 通用: 包管理器 ======================
detect_pm() {
    if   command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf     >/dev/null 2>&1; then echo dnf
    elif command -v yum     >/dev/null 2>&1; then echo yum
    else echo unknown; fi
}

pkg_install() {  # pkg_install pkg1 [pkg2 ...]
    local pm; pm="$(detect_pm)"
    case "$pm" in
        apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum)
            # RHEL/CentOS 系 fail2ban 在 EPEL 里
            if ! yum repolist 2>/dev/null | grep -qi epel; then
                command -v yum-config-manager >/dev/null 2>&1 \
                    && yum install -y epel-release >/dev/null 2>&1 \
                    || rpm -q epel-release >/dev/null 2>&1 || true
            fi
            yum install -y "$@"
            ;;
        *) die "未识别的包管理器，请手动安装: $*"; return 1 ;;
    esac
}

# ====================== 通用: IP 校验 ======================
is_valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a o <<< "$ip"
    for x in "${o[@]}"; do (( x <= 255 )) || return 1; done
    return 0
}
is_valid_ipv6() {
    [[ "$1" == *:* ]] || return 1
    [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]
}
# 支持 IPv4、IPv6、CIDR（如 192.168.1.0/24）
is_valid_ip() {
    local ip="${1%%/*}"
    is_valid_ipv4 "$ip" || is_valid_ipv6 "$ip"
}

# 判断时间格式是否合法（拒绝除 -1 外的负数）
validate_time() {
    [[ "$1" == "-1" ]] && return 0
    [[ "$1" =~ ^[0-9]+[smhdw]?$ ]]
}
validate_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ====================== 主菜单 ======================
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}====================================================${NC}"
        echo -e "${PURPLE}              综合管理脚本${NC}"
        echo -e "${BLUE}====================================================${NC}"
        echo -e "${YELLOW}1) Fail2ban 管理 (SSH封禁)${NC}"
        echo -e "${YELLOW}2) IP优先级管理 (IPv4/IPv6切换)${NC}"
        echo -e "${YELLOW}0) 退出脚本${NC}"
        echo -e "${BLUE}====================================================${NC}"
        ask "请选择功能 [0-2]："
        case "$REPLY" in
            1) run_fail2ban ;;
            2) run_ip_manager ;;
            0) ok "✅ 退出脚本"; exit 0 ;;
            *) die "❌ 无效选项，请重新选择"; sleep 1 ;;
        esac
    done
}

# ====================== 1. Fail2ban 管理模块 ======================
run_fail2ban() {
    # --- 自动探测日志路径（按系统实际惯例） ---
    detect_log_path() {
        if   [ -f /var/log/secure ];   then LOG_PATH="/var/log/secure"
        elif [ -f /var/log/auth.log ]; then LOG_PATH="/var/log/auth.log"
        # 若使用 systemd backend，logpath 仅作兜底
        elif   grep -qi 'debian\|ubuntu' /etc/os-release 2>/dev/null; then LOG_PATH="/var/log/auth.log"
        else   LOG_PATH="/var/log/secure"
        fi
    }
    detect_log_path

    # --- 安装预检 ---
    check_install() {
        if command -v fail2ban-client >/dev/null 2>&1; then
            # 已装但无 jail.local 时，从 jail.conf 生成初始配置
            ensure_jail_conf
            return 0
        fi

        warn "未检测到 Fail2ban 服务。"
        ask "是否立即安装 Fail2ban 和 Rsyslog？(y/n): "
        [[ "$REPLY" == "y" || "$REPLY" == "Y" ]] || { warn "已取消安装。"; return 1; }

        info "正在安装 Fail2ban 和 Rsyslog..."
        if ! pkg_install fail2ban rsyslog; then
            die "安装失败。RHEL 系请确认已启用 EPEL 源。"
            pause_any; return 1
        fi

        # 先启动 rsyslog，让它按发行版惯例创建日志文件
        systemctl enable --now rsyslog >/dev/null 2>&1 || true
        sleep 1
        detect_log_path
        # 兜底创建（某些系统 rsyslog 也不会建，此时依赖 systemd backend）
        [ ! -f "$LOG_PATH" ] && touch "$LOG_PATH" 2>/dev/null || true

        if [ ! -f "$JAIL_CONF" ]; then
            info "正在写入默认配置（1天 → 3天 → 永久 递增封禁）..."
            write_default_jail
        fi

        systemctl enable --now fail2ban >/dev/null 2>&1 || true
        ok "安装并启动完成！"
        sleep 1
    }

    write_default_jail() {
        cat > "$JAIL_CONF" << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 86400
findtime = 3600
maxretry = 3
banaction = iptables-multiport
backend = systemd
bantime.increment = true
bantime.factor = 3
bantime.maxtime = -1

[sshd]
enabled = true
port = 22
filter = sshd
logpath = ${LOG_PATH}
maxretry = 3
bantime = 86400
findtime = 3600
EOF
    }

    ensure_jail_conf() {
        if [ ! -f "$JAIL_CONF" ]; then
            warn "未找到 $JAIL_CONF，正在生成默认配置..."
            if [ -f /etc/fail2ban/jail.conf ]; then
                # 从 jail.conf 抽取模板并追加 sshd 段
                write_default_jail
            else
                write_default_jail
            fi
        fi
        [ -f "$LOG_FILE" ] || touch "$LOG_FILE" 2>/dev/null || true
    }

    # --- 读取 jail.local 中 sshd 段的配置项 ---
    # 兼容 "k = v" 与 "k=v" 两种写法
    get_conf() {
        [ -f "$JAIL_CONF" ] || { echo ""; return; }
        awk -v section="[${TARGET_JAIL}]" -v k="$1" '
            BEGIN { in_section = 0; found = 0 }
            $0 == section { in_section = 1; next }
            in_section && /^\[/ { exit }
            in_section {
                line = $0
                sub(/^[ \t]+/, "", line)
                # 匹配 "key = value" 或 "key=value"
                if (line ~ ("^" k "[ \t]*=")) {
                    sub(("^" k "[ \t]*=[ \t]*"), "", line)
                    sub(/[ \t]+$/, "", line)
                    print line
                    found = 1
                    exit
                }
            }
        ' "$JAIL_CONF"
    }

    # --- 写入/更新配置项（保留注释，强制 "k = v" 格式） ---
    set_conf() {
        local key="$1" val="$2" tmp="${JAIL_CONF}.tmp.$$"
        [ -f "$JAIL_CONF" ] || { die "配置文件不存在: $JAIL_CONF"; return 1; }

        awk -v section="[${TARGET_JAIL}]" -v k="$key" -v v="$val" '
            BEGIN { in_section = 0; written = 0; in_file = 0 }
            $0 == section {
                in_file = 1
                in_section = 1
                print
                next
            }
            in_section && /^\[/ {
                if (!written) { print k " = " v; written = 1 }
                in_section = 0
                print
                next
            }
            in_section && $0 ~ ("^[ \t]*" k "[ \t]*=") { next }   # 删掉旧行
            { print }
            END {
                if (in_section && !written) print k " = " v         # 段落在文件末尾的兜底
            }
        ' "$JAIL_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }

        # 写入失败或结果为空时不要覆盖原文件
        if [ -s "$tmp" ]; then
            mv -f "$tmp" "$JAIL_CONF"
        else
            rm -f "$tmp"
            die "写入配置失败，已保留原文件。"
            return 1
        fi
    }

    # --- 重启 Fail2ban 并轮询等待就绪 ---
    restart_f2b() {
        info "正在重载 Fail2ban 配置..."
        systemctl daemon-reload

        # 先做配置语法自检，避免把服务改挂
        if command -v fail2ban-client >/dev/null 2>&1; then
            if ! fail2ban-client -t >/dev/null 2>&1; then
                die "配置语法检查未通过，未重启服务。请检查 $JAIL_CONF"
                fail2ban-client -t 2>&1 | tail -n 5 | sed 's/^/    /'
                pause_any; return 1
            fi
        fi

        systemctl restart fail2ban
        for i in {1..10}; do
            if fail2ban-client ping >/dev/null 2>&1; then
                ok "成功！配置已生效。"
                pause_any; return 0
            fi
            sleep 1
        done

        die "Fail2ban 重启超时或失败。"
        warn "请手动运行 'systemctl status fail2ban' 与 'journalctl -u fail2ban -n 30' 排查。"
        pause_any; return 1
    }

    get_status() {
        if fail2ban-client ping >/dev/null 2>&1; then
            local count
            count=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null \
                    | grep -o 'Currently banned:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
            echo -e "${GREEN}运行中 (Active)${PLAIN} | 当前封禁数: ${RED}${count}${PLAIN}"
        else
            echo -e "${RED}已停止 (Stopped)${PLAIN}"
        fi
    }

    fmt_unit() {
        local val="$1" type="$2"
        if [ "$val" == "-1" ]; then echo "永久"; return; fi
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            case "$type" in
                time)   echo "${val}秒" ;;
                factor) echo "${val}倍" ;;
                *)      echo "$val" ;;
            esac
        else
            echo "${val:-未设置}"
        fi
    }

    # --- 修改参数 ---
    change_param() {
        local name="$1" key="$2" type="$3" current new_val
        current=$(get_conf "$key")
        echo -e "\n${BLUE}正在修改: ${name}${PLAIN}"
        echo -e "当前值: ${GREEN}$(fmt_unit "$current" "$type")${PLAIN}"
        [ "$type" == "time" ] && echo -e "${GRAY}(支持后缀: s=秒, m=分, h=小时, d=天，-1=永久)${PLAIN}"

        while true; do
            ask "请输入新值 (留空取消): "
            new_val="$REPLY"
            [ -z "$new_val" ] && return

            case "$type" in
                time)   validate_time  "$new_val" && break ;;
                int|factor) validate_int "$new_val" && break ;;
                *)      break ;;
            esac
            die "格式错误，请重试。"
        done

        if set_conf "$key" "$new_val"; then
            restart_f2b
        else
            die "写入配置失败。"
            pause_any
        fi
    }

    toggle_service() {
        echo -e "\n${BLUE}--- 服务开关 ---${PLAIN}"
        if fail2ban-client ping >/dev/null 2>&1; then
            ask "是否停止并禁用 Fail2ban? (y/n): "
            if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
                systemctl disable --now fail2ban
                ok "服务已停止并禁用。"
            fi
        else
            ask "是否启用并启动 Fail2ban? (y/n): "
            if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
                info "正在启动服务..."
                systemctl enable --now fail2ban
                for i in {1..10}; do
                    if fail2ban-client ping >/dev/null 2>&1; then
                        ok "服务已启动。"; break
                    fi
                    sleep 1
                    [ "$i" -eq 10 ] && die "启动失败！请检查 journalctl -u fail2ban"
                done
            fi
        fi
        pause_any
    }

    unban_ip() {
        echo -e "\n${BLUE}--- 手动解封 IP ---${PLAIN}"
        local banned_list target_ip
        banned_list=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null \
                      | grep 'Banned IP list' | sed 's/.*Banned IP list:[[:space:]]*//')
        echo -e "当前被封禁列表: ${RED}${banned_list:-无}${PLAIN}"

        ask "输入要解封的 IP (留空取消): "
        target_ip="$REPLY"
        [ -z "$target_ip" ] && return

        if ! is_valid_ip "$target_ip"; then
            die "IP 格式不正确。"
            pause_any; return
        fi

        if fail2ban-client set "$TARGET_JAIL" unbanip "$target_ip" >/dev/null 2>&1; then
            ok "解封成功: $target_ip"
        else
            die "操作失败（可能该 IP 未被封禁）。"
        fi
        pause_any
    }

    # --- 白名单：以空格分隔读写，保持既有条目 ---
    get_ignoreip_raw() {
        # 直接读取原始值（保留内部空格），不做 tr -d ' '
        awk -v section="[${TARGET_JAIL}]" '
            $0 == section { in_section = 1; next }
            in_section && /^\[/ { exit }
            in_section {
                line = $0
                sub(/^[ \t]+/, "", line)
                if (line ~ /^ignoreip[ \t]*=/) {
                    sub(/^ignoreip[ \t]*=[ \t]*/, "", line)
                    sub(/[ \t]+$/, "", line)
                    print line
                    exit
                }
            }
        ' "$JAIL_CONF"
    }

    add_whitelist() {
        echo -e "\n${BLUE}--- 白名单管理 ---${PLAIN}"
        local current_list input_ip self_ip
        current_list=$(get_ignoreip_raw)
        self_ip="${SSH_CLIENT%% *}"

        echo -e "当前白名单: ${YELLOW}${current_list:-无}${PLAIN}"

        if [ -n "$self_ip" ]; then
            ask "输入要放行的 IP (回车默认本机 ${self_ip}，支持 CIDR): "
        else
            ask "输入要放行的 IP (支持 CIDR / IPv6): "
        fi
        input_ip="$REPLY"
        [ -z "$input_ip" ] && input_ip="$self_ip"
        [ -z "$input_ip" ] && { die "无法获取 IP。"; pause_any; return; }

        if ! is_valid_ip "$input_ip"; then
            die "IP 格式不正确。"
            pause_any; return
        fi

        # 逐项精确比对（避免子串误判）
        local exist=0 item
        for item in $current_list; do
            [ "$item" == "$input_ip" ] && exist=1 && break
        done
        if [ "$exist" -eq 1 ]; then
            warn "该 IP 已在白名单中。"
            pause_any; return
        fi

        local new_list
        if [ -n "$current_list" ]; then
            new_list="${current_list} ${input_ip}"
        else
            new_list="${input_ip}"
        fi

        if set_conf "ignoreip" "$new_list"; then
            restart_f2b
        else
            die "写入白名单失败。"
            pause_any
        fi
    }

    view_logs() {
        clear
        echo -e "${BLUE}=== 封禁审计日志 (最近 20 条) ===${PLAIN}"
        if [ ! -f "$LOG_FILE" ]; then
            warn "日志文件不存在: $LOG_FILE"
        else
            local out
            out=$(grep -E '(\bBan\b|\bUnban\b)' "$LOG_FILE" 2>/dev/null | tail -n 20)
            if [ -z "$out" ]; then
                warn "暂无封禁/解封记录。"
            else
                printf '%s\n' "$out" | awk '
                    { gsub(/Unban/, "\033[32m&\033[0m"); gsub(/Ban/, "\033[31m&\033[0m"); print }
                '
            fi
        fi
        echo -e "----------------------------------------"
        pause_any
    }

    menu_exponential() {
        while true; do
            clear
            local inc fac max inc_disp
            inc=$(get_conf "bantime.increment")
            fac=$(get_conf "bantime.factor")
            max=$(get_conf "bantime.maxtime")
            [ "$inc" == "true" ] && inc_disp="${GREEN}开启${PLAIN}" || inc_disp="${RED}关闭${PLAIN}"

            echo -e "${BLUE}=== 高级: 指数封禁设置 ===${PLAIN}"
            echo -e "规则示例：首次 bantime → ×factor → 上限封顶"
            echo -e "-------------------------------------------"
            echo -e "  1. 递增模式开关    [${inc_disp}]"
            echo -e "  2. 增长系数        [${YELLOW}${fac:-未设置}${PLAIN}] $(fmt_unit "$fac" "factor")"
            echo -e "  3. 封禁上限        [${YELLOW}${max:-未设置}${PLAIN}] $(fmt_unit "$max" "time")"
            echo -e "-------------------------------------------"
            echo -e "  0. 返回上级菜单"
            ask "请选择 [0-3]: "
            case "$REPLY" in
                1)
                    if [ "$inc" == "true" ]; then ns="false"; else ns="true"; fi
                    if set_conf "bantime.increment" "$ns"; then
                        restart_f2b
                    else
                        die "写入失败。"; pause_any
                    fi
                    ;;
                2) change_param "增长系数" "bantime.factor"  "factor" ;;
                3) change_param "封禁上限" "bantime.maxtime" "time" ;;
                0) return ;;
                *) die "无效选项"; sleep 1 ;;
            esac
        done
    }

    menu_f2b_main() {
        check_install || return
        while true; do
            clear
            local val_max val_ban val_find
            val_max=$(get_conf "maxretry")
            val_ban=$(get_conf "bantime")
            val_find=$(get_conf "findtime")

            echo -e "${BLUE}################################################${PLAIN}"
            echo -e "${BLUE}#    Fail2ban 定制面板: 递增封禁管理        #${PLAIN}"
            echo -e "${BLUE}################################################${PLAIN}"
            echo -e "  状态: $(get_status)"
            echo -e "  配置文件: ${GRAY}${JAIL_CONF}${PLAIN}"
            echo -e "------------------------------------------------"
            echo -e "  1. 最大重试次数     [${YELLOW}${val_max:-未设置}${PLAIN}]"
            echo -e "  2. 初始封禁时长     [${YELLOW}${val_ban:-未设置}${PLAIN}] $(fmt_unit "$val_ban" "time")"
            echo -e "  3. 监测时间窗口     [${YELLOW}${val_find:-未设置}${PLAIN}] $(fmt_unit "$val_find" "time")"
            echo -e "------------------------------------------------"
            echo -e "  4. 手动解封 IP"
            echo -e "  5. 添加 IP 白名单"
            echo -e "  6. 查看封禁日志"
            echo -e "  7. 指数封禁高级设置"
            echo -e "------------------------------------------------"
            echo -e "  8. 服务开关控制"
            echo -e "  0. 返回上级菜单"
            echo -e ""
            ask "请选择功能 [0-8]: "
            case "$REPLY" in
                1) change_param "最大重试次数" "maxretry"   "int" ;;
                2) change_param "初始封禁时长" "bantime"    "time" ;;
                3) change_param "监测时间窗口" "findtime"   "time" ;;
                4) unban_ip ;;
                5) add_whitelist ;;
                6) view_logs ;;
                7) menu_exponential ;;
                8) toggle_service ;;
                0) return ;;
                *) die "输入错误，请重新选择"; sleep 1 ;;
            esac
        done
    }

    menu_f2b_main
}

# ====================== 2. IP优先级管理模块 ======================
run_ip_manager() {
    # 获取公网 IP（带超时，避免卡死）
    get_ip() {  # get_ip -4|-6
        local flag="$1"
        curl -s --max-time 5 "$flag" https://api.ipify.org 2>/dev/null \
            || curl -s --max-time 5 "$flag" https://ip.sb 2>/dev/null
    }

    local CURRENT_IPV4 CURRENT_IPV6 USED_IP IS_V6=false
    CURRENT_IPV4=$(get_ip -4)
    CURRENT_IPV6=$(get_ip -6)

    # 用双栈可达的站点判断实际出口族
    USED_IP=$(curl -s --max-time 5 -o /dev/null -w '%{remote_ip}' https://www.cloudflare.com 2>/dev/null)
    [[ "$USED_IP" == *:* ]] && IS_V6=true

    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${PURPLE}              当前公网 IP 信息${NC}"
    echo -e "${BLUE}====================================================${NC}"

    echo -n -e "${GREEN}IPv4：${NC}"
    if [ -n "$CURRENT_IPV4" ]; then
        echo -n "$CURRENT_IPV4"
        [ "$IS_V6" = false ] && echo -e " ${YELLOW}[优先]${NC}" || echo ""
    else
        echo -e "${GRAY}获取失败${PLAIN}"
    fi

    echo -n -e "${GREEN}IPv6：${NC}"
    if [ -n "$CURRENT_IPV6" ]; then
        echo -n "$CURRENT_IPV6"
        [ "$IS_V6" = true ] && echo -e " ${YELLOW}[优先]${NC}" || echo ""
    else
        echo -e "${GRAY}无 IPv6 / 获取失败${PLAIN}"
    fi

    if [ -z "$USED_IP" ]; then
        warn "⚠ 无法探测默认出口地址（网络受限），以下[优先]标记可能不准。"
    fi

    echo -e "${BLUE}====================================================${NC}"
    echo ""

    echo -e "${YELLOW}1) IPv4 优先${NC}"
    echo -e "${YELLOW}2) IPv6 优先${NC}"
    echo -e "${YELLOW}3) 恢复系统默认配置${NC}"
    echo -e "${YELLOW}0) 返回上级菜单${NC}"
    ask "请选择 [0-3]："

    # gai.conf 若不存在则创建（含默认样板）
    ensure_gai_conf() {
        if [ ! -f "$GAI_FILE" ]; then
            warn "$GAI_FILE 不存在，正在创建默认文件..."
            cat > "$GAI_FILE" << 'EOF'
# Configuration for getaddrinfo(3).
# 由 f2ban.sh 自动创建
label  ::1/128       0
label  ::/0          1
label  2002::/16     2
label ::/96          3
label ::ffff:0:0/96  4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence ::/96          20
precedence ::ffff:0:0/96  10
EOF
        fi
    }

    # 仅在首次修改前备份"真实出厂状态"
    backup_config() {
        if [ ! -f "$BACKUP_FILE" ]; then
            cp "$GAI_FILE" "$BACKUP_FILE" 2>/dev/null \
                && info "已备份原始配置 → $BACKUP_FILE" \
                || warn "备份失败（将无法恢复默认）"
        fi
    }

    # 精确匹配 precedence 行（容忍任意空白，且不误删其他行）
    apply_precedence() {  # apply_precedence "目标前缀" 值
        local prefix="$1" val="$2" tmp="${GAI_FILE}.tmp.$$"
        # 先删除所有关于该前缀的（含注释）precedence 行
        grep -vE "^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+${prefix//\//\\/}" "$GAI_FILE" > "$tmp" 2>/dev/null
        printf 'precedence %s %s\n' "$prefix" "$val" >> "$tmp"
        mv -f "$tmp" "$GAI_FILE"
    }

    set_ipv4() {
        ensure_gai_conf
        backup_config
        # ::ffff:0:0/96 值越大越优先 → IPv4 优先
        apply_precedence "::ffff:0:0/96" "100"
        # 确保 2000::/3（真实 IPv6）优先级低于 IPv4
        apply_precedence "2000::/3" "10"
        ok "✅ 已切换：IPv4 优先"
    }

    set_ipv6() {
        ensure_gai_conf
        backup_config
        # 移除 IPv4 优先的 100 权重，恢复为默认 10
        apply_precedence "::ffff:0:0/96" "10"
        apply_precedence "2000::/3" "10"
        ok "✅ 已切换：IPv6 优先"
    }

    restore_default() {
        if [ -f "$BACKUP_FILE" ]; then
            cp "$BACKUP_FILE" "$GAI_FILE"
            ok "✅ 已恢复系统默认配置"
        else
            warn "未找到备份文件 $BACKUP_FILE，跳过恢复。"
            echo -e "${GRAY}提示：可手动编辑 $GAI_FILE，将 precedence ::ffff:0:0/96 的权重改回 10。${PLAIN}"
        fi
    }

    case "$REPLY" in
        1) set_ipv4 ;;
        2) set_ipv6 ;;
        3) restore_default ;;
        0) return ;;
        *) die "❌ 无效选项"; sleep 1; run_ip_manager; return ;;
    esac

    echo -e "${BLUE}👉 配置立即生效（仅影响新发起的连接），无需重启。${NC}"
    sleep 2
}

# ====================== 启动脚本 ======================
if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 权限运行此脚本（sudo）！"
    exit 1
fi

main_menu
