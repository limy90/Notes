#!/bin/bash
# ============================================================
# 专线网络优化工具 beta1.0
# 链路拓扑: 用户 → 前置 → IX专线 → 国际转发 → 落地 → 家宽
# 功能: BBR/sysctl优化 + TC双向限速 + 链路向导 针对场景和机器定制化出配方,附带限速和白名单IP功能（ipv6机器请勿使用这俩功能 会丢ipv6）
# 用法:
#   交互式: sudo bash network-optimizer.sh
#   直接操作: sudo bash network-optimizer.sh <命令>
# ============================================================

IFB_DEV="ifb0"
CONFIG_DIR="/etc/network-optimizer"
SYSCTL_CONF="$CONFIG_DIR/sysctl-optimize.conf"
TC_CONF="$CONFIG_DIR/tc-shaping.conf"
PROFILE_CONF="$CONFIG_DIR/profile.conf"

# ==================== 权限检查 ====================
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要root权限，请使用 sudo 运行"
    exit 1
fi

# ==================== Ctrl+C 光标恢复 ====================
cleanup() {
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null
    echo ""
    exit 0
}
trap cleanup INT TERM

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

init_config_dir() { mkdir -p "$CONFIG_DIR"; }

# ==================== 自动检测网卡 ====================
detect_interface() {
    local iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -z "$iface" ] && iface=$(ip -o link show up | awk -F': ' '!/lo|ifb|veth|docker|br-/ {print $2; exit}')
    echo "$iface"
}

# ==================== 菜单引擎 ====================
select_menu() {
    local title="$1"; shift
    local options=("$@")
    local count=${#options[@]}
    local selected=0

    tput civis 2>/dev/null

    _draw() {
        for ((i=0; i<count+4; i++)); do tput cuu1 2>/dev/null; tput el 2>/dev/null; done
        echo ""
        echo -e "  ${BOLD}${CYAN}$title${NC}"
        echo -e "  ${DIM}上下键选择，回车确认${NC}"
        echo ""
        for ((i=0; i<count; i++)); do
            if [ $i -eq $selected ]; then
                echo -e "  ${GREEN}▸ ${WHITE}${BOLD}${options[$i]}${NC}"
            else
                echo -e "    ${DIM}${options[$i]}${NC}"
            fi
        done
    }

    for ((i=0; i<count+4; i++)); do echo ""; done
    _draw

    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 key
                case "$key" in
                    '[A') ((selected--)); [ $selected -lt 0 ] && selected=$((count-1)) ;;
                    '[B') ((selected++)); [ $selected -ge $count ] && selected=0 ;;
                esac
                _draw ;;
            '') tput cnorm 2>/dev/null; stty sane 2>/dev/null; return $selected ;;
        esac
    done
}

confirm_action() {
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null
    echo -ne "  ${YELLOW}$1 [y/N]: ${NC}"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

read_int() {
    local prompt="$1" default="$2" varname="$3"
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null
    while true; do
        if [ -n "$default" ]; then
            echo -ne "  ${WHITE}${prompt} [默认${default}]: ${NC}"
        else
            echo -ne "  ${WHITE}${prompt}: ${NC}"
        fi
        read val
        [ -z "$val" ] && [ -n "$default" ] && val=$default
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ]; then
            eval "$varname=$val"
            return
        fi
        echo -e "  ${RED}请输入有效的正整数${NC}"
    done
}

# ================================================================
#                      链路拓扑定义
# ================================================================
#
# 完整链路:
#   用户电脑 ──→ 前置服务器 ──→ IX专线服务器 ──→ 国际转发服务器 ──→ 落地服务器 ──→ 家宽/网站
#
# 每个节点的特征:
#   前置服务器: 面向用户接入，可能是带宽瓶颈（小水管）
#   IX专线服务器: 专线核心，大带宽中转，无NAT
#   国际转发/直接线路服务器: 跨国中继/直连线路，可能有翻墙需求
#   落地服务器: 最终出口，访问目标网站/游戏，可能有翻墙需求
#

# ================================================================
#                    BDP计算与参数生成
# ================================================================

# 根据带宽和RTT计算最优sysctl参数
# 参数: $1=角色名 $2=上游带宽Mbps $3=上游RTT(ms) $4=下游带宽Mbps $5=下游RTT(ms) $6=额外header信息
calculate_and_generate() {
    local role_name="$1"
    local up_bw="$2" up_rtt="$3"
    local down_bw="$4" down_rtt="$5"
    local extra_header="$6"

    # BDP计算 (bytes) = bw(Mbps) * rtt(ms) * 125
    local bdp_up=$(( up_bw * up_rtt * 125 ))
    local bdp_down=$(( down_bw * down_rtt * 125 ))
    local bdp_main=$bdp_up
    [ $bdp_down -gt $bdp_main ] && bdp_main=$bdp_down

    # 瓶颈带宽 (取两个方向的较小带宽)
    local bottleneck=$up_bw
    [ $down_bw -lt $bottleneck ] && bottleneck=$down_bw

    # default = BDP向上取整到64KB边界，至少128KB
    local def_val=$(( (bdp_main / 65536 + 1) * 65536 ))
    [ $def_val -lt 131072 ] && def_val=131072

    # max = default * 8，至少1MB，最大16MB
    local max_val=$(( def_val * 8 ))
    [ $max_val -lt 1048576 ] && max_val=1048576
    [ $max_val -gt 16777216 ] && max_val=16777216

    # tcp_mem档位
    local tcp_mem
    if [ $max_val -le 2097152 ]; then
        tcp_mem="65536 98304 131072"
    elif [ $max_val -le 8388608 ]; then
        tcp_mem="98304 131072 196608"
    else
        tcp_mem="131072 196608 262144"
    fi

    # notsent_lowat: 瓶颈<=10M用16KB，否则32KB
    local notsent_lowat=32768
    [ $bottleneck -le 10 ] && notsent_lowat=16384

    # 连接队列参数
    local somaxconn=65535 syn_backlog=16384 netdev_backlog=16384
    local tw_buckets=2000000 max_orphans=65536 file_max=1048576
    if [ $bottleneck -le 10 ]; then
        somaxconn=32768; syn_backlog=8192; netdev_backlog=8192
        tw_buckets=1000000; max_orphans=32768; file_max=524288
    fi

    # UDP参数
    local udp_rmem=65536 udp_wmem=65536 udp_mem="65536 131072 262144"
    if [ $bottleneck -le 10 ]; then
        udp_rmem=32768; udp_wmem=32768; udp_mem="32768 65536 131072"
    fi

    # fin_timeout
    local fin_timeout=15
    [ $bottleneck -le 10 ] && fin_timeout=20

    cat << EOF
# ============================================================
# ${role_name} - 网络优化配置
${extra_header}
# 主BDP方向: ${up_bw}Mbps × ${up_rtt}ms RTT = $(( bdp_up / 1024 ))KB
# 次BDP方向: ${down_bw}Mbps × ${down_rtt}ms RTT = $(( bdp_down / 1024 ))KB
# 缓冲区: default=$(( def_val / 1024 ))KB / max=$(( max_val / 1024 / 1024 ))MB
# 系统: Ubuntu/Debian
# 生成工具: 专线网络优化工具 beta1.0
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# ==================== 拥塞控制 ====================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ==================== 缓冲区 ====================
net.core.rmem_max = $max_val
net.core.wmem_max = $max_val
net.core.rmem_default = $def_val
net.core.wmem_default = $def_val
net.ipv4.tcp_rmem = 4096 $def_val $max_val
net.ipv4.tcp_wmem = 4096 $def_val $max_val
net.core.optmem_max = 65536
net.ipv4.tcp_mem = $tcp_mem

# ==================== 低延迟核心 ====================
net.ipv4.tcp_notsent_lowat = $notsent_lowat
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1

# ==================== 重传优化 ====================
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_orphan_retries = 3

# ==================== ECN ====================
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_ecn_fallback = 1

# ==================== MTU / MSS ====================
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1460

# ==================== TCP行为 ====================
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $fin_timeout

# ==================== Keepalive ====================
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# ==================== 连接队列 ====================
net.core.somaxconn = $somaxconn
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.core.netdev_max_backlog = $netdev_backlog
net.ipv4.tcp_max_tw_buckets = $tw_buckets
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = $max_orphans

# ==================== UDP (游戏/QUIC) ====================
net.ipv4.udp_rmem_min = $udp_rmem
net.ipv4.udp_wmem_min = $udp_wmem
net.ipv4.udp_mem = $udp_mem

# ==================== 转发 ====================
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ==================== 安全 ====================
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# ==================== 系统 ====================
vm.swappiness = 1
vm.vfs_cache_pressure = 50
fs.file-max = $file_max
EOF
}

# ================================================================
#                      应用 sysctl
# ================================================================

apply_sysctl_config() {
    local role_name="$1"
    local config_content="$2"

    echo ""
    echo -e "  ${BOLD}${CYAN}正在生成配置: $role_name${NC}"

    # 检查BBR支持
    if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null
        if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            echo -e "  ${RED}⚠ 警告: 内核不支持BBR，拥塞控制将使用默认算法${NC}"
            echo -e "  ${DIM}  需要内核版本 >= 4.9，当前: $(uname -r)${NC}"
        fi
    fi

    init_config_dir
    echo "$config_content" > "$SYSCTL_CONF"

    echo "SYSCTL_PROFILE_NAME=\"$role_name\"" > "$PROFILE_CONF"

    # 备份
    if [ ! -f "$CONFIG_DIR/sysctl-backup.conf" ]; then
        sysctl -a > "$CONFIG_DIR/sysctl-backup.conf" 2>/dev/null
        echo -e "  ${GREEN}✓${NC} 原始配置已备份"
    fi

    ln -sf "$SYSCTL_CONF" /etc/sysctl.d/99-network-optimize.conf
    echo -e "  ${GREEN}✓${NC} 配置已写入"

    if confirm_action "立即应用?"; then
        local apply_err
        apply_err=$(sysctl --system 2>&1 | grep -i "error\|cannot\|invalid" || true)
        if [ -n "$apply_err" ]; then
            echo -e "  ${YELLOW}⚠${NC} 部分参数应用异常:"
            echo "$apply_err" | head -5 | sed 's/^/    /'
        fi
        local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        echo -e "  ${GREEN}✓${NC} 已生效 | 拥塞控制: $cc | 队列: $qd"
    else
        echo -e "  ${DIM}已保存，重启或 sysctl --system 生效${NC}"
    fi
    echo ""
}

# ================================================================
#                       TC 限速
# ================================================================

select_interface() {
    local detected=$(detect_interface)
    local ifaces=() labels=()

    while IFS= read -r line; do
        local name=$(echo "$line" | awk -F': ' '{print $2}')
        [[ "$name" =~ ^(lo|ifb|veth|docker|br-) ]] && continue
        local addr=$(ip -4 addr show "$name" 2>/dev/null | awk '/inet / {print $2; exit}')
        [ -z "$addr" ] && addr="无IPv4"
        ifaces+=("$name")
        [ "$name" = "$detected" ] && labels+=("$name ($addr) ← 默认路由") || labels+=("$name ($addr)")
    done < <(ip -o link show up)

    if [ ${#ifaces[@]} -eq 0 ]; then
        echo -e "${RED}[错误] 未找到可用网卡${NC}"; exit 1
    fi
    if [ ${#ifaces[@]} -eq 1 ]; then
        TC_IFACE="${ifaces[0]}"
        echo -e "  ${GREEN}检测到网卡: ${WHITE}${BOLD}$TC_IFACE${NC}"
        return
    fi

    select_menu "选择要限速的网卡" "${labels[@]}"
    TC_IFACE="${ifaces[$?]}"
}

tc_calculate() {
    local bw="$1" margin="$2"
    local rate_kbit=$(( bw * (100 - margin) * 10 ))
    local rate_int=$(( rate_kbit / 1000 ))
    local rate_dec=$(( (rate_kbit % 1000) / 100 ))

    local burst_kb=256 latency="10ms"
    if [ "$bw" -le 10 ]; then
        burst_kb=16; latency="20ms"
    elif [ "$bw" -le 100 ]; then
        burst_kb=64; latency="15ms"
    fi

    TC_RATE="${rate_kbit}kbit"
    TC_BURST="${burst_kb}kb"
    TC_LATENCY="$latency"
    TC_DESC="${bw}Mbps → 限速${rate_int}.${rate_dec}Mbps (余量${margin}%)"
}

apply_tc_shaping() {
    echo ""
    echo -e "  ${BOLD}${CYAN}应用限速: $TC_DESC${NC}"
    echo -e "  ${WHITE}网卡: $TC_IFACE | 速率: $TC_RATE | 突发: $TC_BURST | 排队: $TC_LATENCY${NC}"
    echo ""

    tc qdisc del dev "$TC_IFACE" root 2>/dev/null
    tc qdisc del dev "$TC_IFACE" ingress 2>/dev/null
    tc qdisc del dev "$IFB_DEV" root 2>/dev/null
    ip link set "$IFB_DEV" down 2>/dev/null

    echo -ne "  [出方向] tbf + fq ... "
    tc qdisc add dev "$TC_IFACE" root handle 1: tbf rate $TC_RATE burst $TC_BURST latency $TC_LATENCY && \
    tc qdisc add dev "$TC_IFACE" parent 1:1 handle 10: fq && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; return 1; }

    echo -ne "  [入方向] ifb 模块 ... "
    modprobe ifb numifbs=1 2>/dev/null; ip link set "$IFB_DEV" up 2>/dev/null && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; return 1; }

    echo -ne "  [入方向] 流量镜像 ... "
    tc qdisc add dev "$TC_IFACE" handle ffff: ingress && \
    tc filter add dev "$TC_IFACE" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEV" && \
    echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; return 1; }

    echo -ne "  [入方向] tbf + fq ... "
    tc qdisc add dev "$IFB_DEV" root handle 1: tbf rate $TC_RATE burst $TC_BURST latency $TC_LATENCY && \
    tc qdisc add dev "$IFB_DEV" parent 1:1 handle 10: fq && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; return 1; }

    init_config_dir
    cat > "$TC_CONF" << EOF
TC_RATE="$TC_RATE"
TC_BURST="$TC_BURST"
TC_LATENCY="$TC_LATENCY"
TC_IFACE="$TC_IFACE"
TC_DESC="$TC_DESC"
EOF

    echo ""
    echo -e "  ${GREEN}${BOLD}限速已生效: $TC_IFACE 双向 $TC_RATE${NC}"
    echo ""
}

stop_tc() {
    local iface
    if [ -f "$TC_CONF" ]; then source "$TC_CONF"; iface="$TC_IFACE"; else iface=$(detect_interface); fi
    echo -e "  ${YELLOW}清除 $iface 限速规则...${NC}"
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc del dev "$iface" ingress 2>/dev/null
    tc qdisc del dev "$IFB_DEV" root 2>/dev/null
    ip link set "$IFB_DEV" down 2>/dev/null
    modprobe -r ifb 2>/dev/null
    echo -e "  ${GREEN}已清除${NC}"
}


tc_menu() {
    while true; do
    echo ""

    # 当前状态
    local iface=$(detect_interface)
    if [ -n "$iface" ] && tc qdisc show dev "$iface" 2>/dev/null | grep -q tbf; then
        [ -f "$TC_CONF" ] && source "$TC_CONF"
        echo -e "  ${GREEN}●${NC} 当前限速: ${WHITE}${TC_DESC:-已启用}${NC}"
    else
        echo -e "  ${DIM}○ 当前限速: 未启用${NC}"
    fi
    echo ""

    select_menu "TC流量限速" \
        "配置限速 (输入带宽自动计算)" \
        "停止限速" \
        "返回主菜单"

    case $? in
        0) tc_setup ;;
        1) stop_tc ;;
        2) return ;;
    esac

    echo ""
    echo -ne "  ${DIM}按回车继续...${NC}"
    read -r
    done
}

tc_setup() {
    echo ""
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null

    local bw
    read_int "线路带宽 (Mbps)" "" "bw"

    select_menu "限速余量" \
        "5%  (线路非常稳定)" \
        "8%  (推荐)" \
        "10% (线路有波动)" \
        "15% (线路不稳定)"
    local _m=$?
    local margins=(5 8 10 15)
    tc_calculate "$bw" "${margins[$_m]}"

    select_interface
    apply_tc_shaping
}

# ================================================================
#                     链路向导 (核心功能)
# ================================================================

wizard_main() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ BBR网络优化 - 链路向导 ━━━${NC}"
    echo -e "  ${DIM}用户 → 前置 → IX专线 → 国际转发 → 落地 → 目标${NC}"
    echo -e "  ${DIM}选择要优化的节点，输入参数自动计算配置${NC}"
    echo ""

    select_menu "选择要优化的服务器" \
        "前置服务器               (用户接入点)" \
        "IX专线服务器             (专线中转)" \
        "国际转发/直接线路服务器  (跨国中继/直连线路)" \
        "落地服务器               (最终出口)" \
        "返回主菜单"

    case $? in
        0) wizard_frontend ;;
        1) wizard_ix ;;
        2) wizard_relay ;;
        3) wizard_landing ;;
        4) return ;;
    esac
}

# ==================== ① 前置服务器向导 ====================
wizard_frontend() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ ① 前置服务器配置向导 ━━━${NC}"
    echo -e "  ${DIM}链路位置: 用户 ─→ ${BOLD}[前置服务器]${NC}${DIM} ─→ IX/线路机${NC}"
    echo ""

    # 用户方向
    echo -e "  ${WHITE}${BOLD}用户方向 (用户 → 本机)${NC}"
    local up_local up_remote up_ping
    read_int "本机上行带宽 (Mbps)" "" "up_local"
    read_int "用户家宽带宽 (Mbps，不确定填最大用户的)" "" "up_remote"
    read_int "用户到本机单程ping (ms)" "" "up_ping"
    local up_rtt=$(( up_ping * 2 ))
    local up_bw=$up_local
    [ $up_remote -lt $up_bw ] && up_bw=$up_remote

    # 下游方向 (支持多条)
    echo ""
    echo -e "  ${WHITE}${BOLD}本机 → 下游 (IX/线路机/转发)${NC}"
    echo -e "  ${DIM}逐条输入本机连接的下游服务器${NC}"
    echo ""

    local down_count=0 all_down_header=""
    local max_down_bdp=0 main_down_bw=0 main_down_rtt=0

    while true; do
        down_count=$(( down_count + 1 ))
        echo -e "  ${BOLD}${YELLOW}── 下游线路 #${down_count} ──${NC}"
        tput cnorm 2>/dev/null
        stty sane 2>/dev/null
        echo -ne "  ${WHITE}线路名称 (如: IX专线/HK线路机/SG直连): ${NC}"
        read line_name
        [ -z "$line_name" ] && line_name="下游${down_count}"

        local l_local l_remote l_ping
        read_int "  本机到${line_name}的带宽 (Mbps)" "$up_local" "l_local"
        read_int "  ${line_name}的带宽 (Mbps)" "300" "l_remote"
        read_int "  本机到${line_name}单程ping (ms)" "" "l_ping"
        local l_rtt=$(( l_ping * 2 ))
        # 瓶颈
        local l_bw=$l_local
        [ $l_remote -lt $l_bw ] && l_bw=$l_remote
        local l_bdp=$(( l_bw * l_rtt * 125 ))

        echo -e "  ${DIM}→ ${line_name}: 本机${l_local}M/${line_name}${l_remote}M → 瓶颈${l_bw}Mbps × ${l_rtt}ms = $(( l_bdp / 1024 ))KB BDP${NC}"

        if [ $l_bdp -gt $max_down_bdp ]; then
            max_down_bdp=$l_bdp; main_down_bw=$l_bw; main_down_rtt=$l_rtt
        fi

        all_down_header="${all_down_header}
# 下游${down_count}: ${line_name} | 本机${l_local}M/${line_name}${l_remote}M → 瓶颈${l_bw}Mbps | 单程${l_ping}ms | RTT ${l_rtt}ms | BDP $(( l_bdp / 1024 ))KB"

        echo ""
        if ! confirm_action "还有更多下游线路?"; then
            break
        fi
        echo ""
    done

    # 计算结果
    local bdp_up=$(( up_bw * up_rtt * 125 ))
    echo ""
    echo -e "  ${GREEN}━━━ 计算结果 ━━━${NC}"
    echo -e "  ${WHITE}用户方向: 本机${up_local}M/用户${up_remote}M → 瓶颈${BOLD}${up_bw}Mbps${NC} × ${up_rtt}ms = $(( bdp_up / 1024 ))KB BDP"
    echo -e "  ${WHITE}下游最大: 瓶颈${BOLD}${main_down_bw}Mbps${NC} × ${main_down_rtt}ms = $(( max_down_bdp / 1024 ))KB BDP (共${down_count}条)"
    echo ""

    local header="# 角色: 前置服务器 (用户接入点)
# 用户方向: 本机${up_local}Mbps / 用户${up_remote}Mbps → 瓶颈${up_bw}Mbps | 单程${up_ping}ms | RTT ${up_rtt}ms
# 下游线路数: ${down_count}${all_down_header}"

    # 传参: 用户方向和下游最大BDP方向
    # 确定实际生效的最大BDP方向
    local eff_bw=$up_bw eff_rtt=$up_rtt
    if [ $max_down_bdp -gt $bdp_up ]; then
        eff_bw=$main_down_bw; eff_rtt=$main_down_rtt
    fi
    local eff_bdp=$(( eff_bw * eff_rtt * 125 ))

    local config
    config=$(calculate_and_generate "前置服务器 (瓶颈${eff_bw}Mbps/BDP $(( eff_bdp / 1024 ))KB)" \
        "$up_bw" "$up_rtt" "$main_down_bw" "$main_down_rtt" "$header")

    apply_sysctl_config "前置服务器 (瓶颈${eff_bw}Mbps/BDP $(( eff_bdp / 1024 ))KB)" "$config"

    # TC限速 (按本机上行带宽)
    if confirm_action "是否配置TC限速? (推荐，避免打满上行)"; then
        echo ""
        select_menu "限速方式" \
            "自动计算 (本机上行${up_local}Mbps × 92% = $(( up_local * 920 / 1000 )).$(( (up_local * 920 % 1000) / 100 ))Mbps)" \
            "自定义设置"
        case $? in
            0) tc_calculate "$up_local" 8 ;;
            1)
                local tc_bw tc_margins=(5 8 10 15)
                read_int "限速带宽 (Mbps)" "$up_local" "tc_bw"
                select_menu "余量" "5%" "8% (推荐)" "10%" "15%"
                tc_calculate "$tc_bw" "${tc_margins[$?]}"
                ;;
        esac
        select_interface
        apply_tc_shaping
    fi
}

# ==================== ② IX专线服务器向导 ====================
wizard_ix() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ ② IX专线服务器配置向导 ━━━${NC}"
    echo -e "  ${DIM}链路位置: 前置(多台) ─→ ${BOLD}[IX专线服务器]${NC}${DIM} ─→ 下游(多台)${NC}"
    echo ""

    # 收集上游线路 (前置方向)
    local max_bdp=0 max_bw=0
    local up_count=0 all_up_header=""
    local main_bw=0 main_rtt=0

    echo -e "  ${WHITE}${BOLD}本机 ← 上游 (前置服务器方向)${NC}"
    echo -e "  ${DIM}可能有多台前置，带宽各不相同，逐条输入${NC}"
    echo ""

    while true; do
        up_count=$(( up_count + 1 ))
        echo -e "  ${BOLD}${YELLOW}── 上游线路 #${up_count} ──${NC}"
        tput cnorm 2>/dev/null
        stty sane 2>/dev/null
        echo -ne "  ${WHITE}线路名称 (如: 前置5M/前置55M/前置300M): ${NC}"
        read line_name
        [ -z "$line_name" ] && line_name="上游${up_count}"

        local l_bw l_ping
        read_int "  该线路到本机带宽 (Mbps)" "" "l_bw"
        read_int "  该线路到本机单程ping (ms)" "6" "l_ping"
        local l_rtt=$(( l_ping * 2 ))
        local l_bdp=$(( l_bw * l_rtt * 125 ))

        echo -e "  ${DIM}→ ${line_name}: ${l_bw}Mbps × ${l_rtt}ms RTT = $(( l_bdp / 1024 ))KB BDP${NC}"

        [ $l_bdp -gt $max_bdp ] && { max_bdp=$l_bdp; main_bw=$l_bw; main_rtt=$l_rtt; }
        [ $l_bw -gt $max_bw ] && max_bw=$l_bw

        all_up_header="${all_up_header}
# 上游${up_count}: ${line_name} | ${l_bw}Mbps | 单程${l_ping}ms | RTT ${l_rtt}ms | BDP $(( l_bdp / 1024 ))KB"

        echo ""
        if ! confirm_action "还有更多上游线路?"; then
            break
        fi
        echo ""
    done

    # 收集下游线路 (国际转发/东京方向)
    local down_count=0 all_down_header=""

    echo ""
    echo -e "  ${WHITE}${BOLD}本机 → 下游 (国际转发/东京方向)${NC}"
    echo -e "  ${DIM}可能连多台下游服务器，逐条输入${NC}"
    echo ""

    while true; do
        down_count=$(( down_count + 1 ))
        echo -e "  ${BOLD}${YELLOW}── 下游线路 #${down_count} ──${NC}"
        tput cnorm 2>/dev/null
        stty sane 2>/dev/null
        echo -ne "  ${WHITE}线路名称 (如: 东京落地/HK转发/SG转发): ${NC}"
        read line_name
        [ -z "$line_name" ] && line_name="下游${down_count}"

        local l_bw l_ping
        read_int "  本机到该线路带宽 (Mbps)" "" "l_bw"
        read_int "  本机到该线路单程ping (ms)" "" "l_ping"
        local l_rtt=$(( l_ping * 2 ))
        local l_bdp=$(( l_bw * l_rtt * 125 ))

        echo -e "  ${DIM}→ ${line_name}: ${l_bw}Mbps × ${l_rtt}ms RTT = $(( l_bdp / 1024 ))KB BDP${NC}"

        [ $l_bdp -gt $max_bdp ] && { max_bdp=$l_bdp; main_bw=$l_bw; main_rtt=$l_rtt; }
        [ $l_bw -gt $max_bw ] && max_bw=$l_bw

        all_down_header="${all_down_header}
# 下游${down_count}: ${line_name} | ${l_bw}Mbps | 单程${l_ping}ms | RTT ${l_rtt}ms | BDP $(( l_bdp / 1024 ))KB"

        echo ""
        if ! confirm_action "还有更多下游线路?"; then
            break
        fi
        echo ""
    done

    echo ""
    echo -e "  ${GREEN}━━━ 计算结果 ━━━${NC}"
    echo -e "  ${WHITE}上游线路: ${BOLD}${up_count}条${NC} | 下游线路: ${BOLD}${down_count}条${NC}"
    echo -e "  ${WHITE}最大BDP:  ${BOLD}$(( max_bdp / 1024 ))KB${NC} (缓冲区按此计算)"

    echo ""
    local has_proxy="no"
    if confirm_action "此IX服务器是否有单独翻墙/代理需求?"; then
        has_proxy="yes"
    fi

    # 找次要方向BDP (用于calculate_and_generate的第二组参数)
    # 简化处理: 用max_bw和一个中等RTT
    local sec_bw=$max_bw sec_rtt=12
    [ $main_rtt -eq 12 ] && sec_rtt=50

    local header="# 角色: IX专线服务器 (核心中转，无NAT)
# 上游线路数: ${up_count}${all_up_header}
# 下游线路数: ${down_count}${all_down_header}
# 缓冲区按所有方向最大BDP $(( max_bdp / 1024 ))KB 计算
# 翻墙代理: ${has_proxy}"

    local config
    config=$(calculate_and_generate "IX专线服务器 (${up_count}上游/${down_count}下游)" \
        "$main_bw" "$main_rtt" "$sec_bw" "$sec_rtt" "$header")

    apply_sysctl_config "IX专线服务器 (${up_count}上游/${down_count}下游)" "$config"

    echo -e "  ${DIM}IX服务器通常无需TC限速（专线带宽固定）${NC}"
}

wizard_relay() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ ③ 国际转发/直接线路服务器配置向导 ━━━${NC}"
    echo -e "  ${DIM}链路位置: IX/前置 ─→ ${BOLD}[本机]${NC}${DIM} ─→ 落地服务器${NC}"
    echo ""

    # 先问本机带宽（后面每个方向都用到）
    local my_bw
    read_int "本机带宽 (Mbps)" "" "my_bw"

    # 国内直连
    local is_cn_optimize="no"
    local cn_bw=0 cn_ping=0 cn_rtt=0
    echo ""
    if confirm_action "此服务器是否同时做中国优化节点? (国内前置直连，不走IX)"; then
        is_cn_optimize="yes"
        echo ""
        echo -e "  ${WHITE}${BOLD}国内直连方向 (前置 → 本机)${NC}"
        echo -e "  ${DIM}前置服务器不经过IX，直接连到本机${NC}"
        local cn_remote cn_ping
        read_int "前置服务器带宽 (Mbps)" "" "cn_remote"
        read_int "前置到本机单程ping (ms)" "" "cn_ping"
        cn_rtt=$(( cn_ping * 2 ))
        cn_bw=$my_bw
        [ $cn_remote -lt $cn_bw ] && cn_bw=$cn_remote
        echo -e "  ${DIM}→ 本机${my_bw}M / 前置${cn_remote}M → 瓶颈${cn_bw}Mbps × ${cn_rtt}ms${NC}"
    fi

    # IX方向
    echo ""
    echo -e "  ${WHITE}${BOLD}IX方向 (IX → 本机)${NC}"
    local ix_remote ix_ping
    read_int "IX带宽 (Mbps)" "300" "ix_remote"
    read_int "IX到本机单程ping (ms)" "" "ix_ping"
    local up_rtt=$(( ix_ping * 2 ))
    local up_bw=$my_bw
    [ $ix_remote -lt $up_bw ] && up_bw=$ix_remote
    echo -e "  ${DIM}→ 本机${my_bw}M / IX${ix_remote}M → 瓶颈${up_bw}Mbps × ${up_rtt}ms${NC}"

    # 落地方向
    echo ""
    echo -e "  ${WHITE}${BOLD}落地方向 (本机 → 落地服务器)${NC}"
    local land_remote land_ping
    read_int "落地服务器带宽 (Mbps)" "" "land_remote"
    read_int "本机到落地单程ping (ms)" "" "land_ping"
    local down_rtt=$(( land_ping * 2 ))
    local down_bw=$my_bw
    [ $land_remote -lt $down_bw ] && down_bw=$land_remote
    echo -e "  ${DIM}→ 本机${my_bw}M / 落地${land_remote}M → 瓶颈${down_bw}Mbps × ${down_rtt}ms${NC}"

    # BDP计算
    local bdp_up=$(( up_bw * up_rtt * 125 ))
    local bdp_down=$(( down_bw * down_rtt * 125 ))
    local bdp_cn=0
    [ "$is_cn_optimize" = "yes" ] && bdp_cn=$(( cn_bw * cn_rtt * 125 ))

    local bdp_max=$bdp_up
    [ $bdp_down -gt $bdp_max ] && bdp_max=$bdp_down
    [ $bdp_cn -gt $bdp_max ] && bdp_max=$bdp_cn

    echo ""
    echo -e "  ${GREEN}━━━ 计算结果 ━━━${NC}"
    echo -e "  ${WHITE}IX方向:   瓶颈${BOLD}${up_bw}Mbps${NC} × ${up_rtt}ms = $(( bdp_up / 1024 ))KB BDP"
    echo -e "  ${WHITE}落地方向: 瓶颈${BOLD}${down_bw}Mbps${NC} × ${down_rtt}ms = $(( bdp_down / 1024 ))KB BDP"
    if [ "$is_cn_optimize" = "yes" ]; then
        echo -e "  ${WHITE}国内直连: 瓶颈${BOLD}${cn_bw}Mbps${NC} × ${cn_rtt}ms = $(( bdp_cn / 1024 ))KB BDP"
    fi

    echo ""
    local has_proxy="no"
    if confirm_action "此服务器是否运行翻墙代理?"; then
        has_proxy="yes"
    fi

    local header="# 角色: 国际转发/直接线路服务器 (跨国中继/直连线路)
# 本机带宽: ${my_bw}Mbps
# IX方向:   本机${my_bw}M / IX${ix_remote}M → 瓶颈${up_bw}Mbps | 单程${ix_ping}ms | RTT ${up_rtt}ms
# 落地方向: 本机${my_bw}M / 落地${land_remote}M → 瓶颈${down_bw}Mbps | 单程${land_ping}ms | RTT ${down_rtt}ms
# 国内优化节点: ${is_cn_optimize}"
    if [ "$is_cn_optimize" = "yes" ]; then
        header="${header}
# 国内直连: 本机${my_bw}M / 前置${cn_remote}M → 瓶颈${cn_bw}Mbps | 单程${cn_ping}ms | RTT ${cn_rtt}ms"
    fi
    header="${header}
# 缓冲区按最大BDP $(( bdp_max / 1024 ))KB 计算
# 翻墙代理: ${has_proxy}"

    # 取最大BDP方向
    local main_bw=$up_bw main_rtt=$up_rtt
    local sec_bw=$down_bw sec_rtt=$down_rtt

    if [ $bdp_cn -ge $bdp_up ] && [ $bdp_cn -ge $bdp_down ]; then
        main_bw=$cn_bw; main_rtt=$cn_rtt
        if [ $bdp_up -ge $bdp_down ]; then
            sec_bw=$up_bw; sec_rtt=$up_rtt
        else
            sec_bw=$down_bw; sec_rtt=$down_rtt
        fi
    elif [ $bdp_down -ge $bdp_up ]; then
        main_bw=$down_bw; main_rtt=$down_rtt
        sec_bw=$up_bw; sec_rtt=$up_rtt
    fi

    local eff_bdp=$(( main_bw * main_rtt * 125 ))
    local display_bw=$main_bw

    local config
    config=$(calculate_and_generate "国际转发/线路服务器 (瓶颈${display_bw}Mbps/BDP $(( eff_bdp / 1024 ))KB)" \
        "$main_bw" "$main_rtt" "$sec_bw" "$sec_rtt" "$header")

    apply_sysctl_config "国际转发/线路服务器 (瓶颈${display_bw}Mbps/BDP $(( eff_bdp / 1024 ))KB)" "$config"

    if confirm_action "是否配置TC限速?"; then
        tc_setup
    fi
}

# ==================== ④ 落地服务器向导 ====================
wizard_landing() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ ④ 落地服务器配置向导 ━━━${NC}"
    echo -e "  ${DIM}链路位置: 上游节点 ─→ ${BOLD}[落地服务器]${NC}${DIM} ─→ 目标网站/家宽${NC}"
    echo ""

    # 收集多条上游线路
    local line_count=0
    local max_bdp=0
    local all_header=""
    local max_bw=0
    local main_bw=0 main_rtt=0

    echo -e "  ${WHITE}${BOLD}本机 ← 上游线路${NC}"
    echo -e "  ${DIM}本机可能有多条上游线路（IX直连、国际转发、线路机等）${NC}"
    echo -e "  ${DIM}逐条输入，全部BDP取最大值来计算缓冲区${NC}"
    echo ""

    while true; do
        line_count=$(( line_count + 1 ))
        echo -e "  ${BOLD}${YELLOW}── 上游线路 #${line_count} ──${NC}"

        # 线路名称
        tput cnorm 2>/dev/null
        stty sane 2>/dev/null
        echo -ne "  ${WHITE}线路名称 (如: IX直连/国际转发/HK线路): ${NC}"
        read line_name
        [ -z "$line_name" ] && line_name="线路${line_count}"

        local l_bw l_ping
        read_int "  该线路到本机带宽 (Mbps)" "" "l_bw"
        read_int "  该线路到本机单程ping (ms)" "" "l_ping"
        local l_rtt=$(( l_ping * 2 ))
        local l_bdp=$(( l_bw * l_rtt * 125 ))

        echo -e "  ${DIM}→ ${line_name}: ${l_bw}Mbps × ${l_rtt}ms RTT = $(( l_bdp / 1024 ))KB BDP${NC}"

        # 记录最大BDP和对应的带宽RTT
        if [ $l_bdp -gt $max_bdp ]; then
            max_bdp=$l_bdp
            main_bw=$l_bw
            main_rtt=$l_rtt
        fi
        [ $l_bw -gt $max_bw ] && max_bw=$l_bw

        # 累积header
        all_header="${all_header}
# 上游线路${line_count}: ${line_name} | ${l_bw}Mbps | 单程${l_ping}ms | RTT ${l_rtt}ms | BDP $(( l_bdp / 1024 ))KB"

        # 第一条线路兜底
        if [ $line_count -eq 1 ]; then
            main_bw=$l_bw; main_rtt=$l_rtt
        fi

        echo ""
        if ! confirm_action "还有更多上游线路?"; then
            break
        fi
        echo ""
    done

    # 下游信息
    echo ""
    echo -e "  ${WHITE}${BOLD}本机 → 出口方向 (目标网站/家宽)${NC}"
    echo -e "  ${DIM}本机通常在目标国本地，到网站延迟很低${NC}"
    local down_bw down_ping
    read_int "本机出口带宽 (Mbps)" "$max_bw" "down_bw"
    read_int "本机到目标网站单程ping (ms)" "3" "down_ping"
    local down_rtt=$(( down_ping * 2 ))
    local bdp_down=$(( down_bw * down_rtt * 125 ))

    echo ""
    echo -e "  ${GREEN}━━━ 计算结果 ━━━${NC}"
    echo -e "  ${WHITE}上游最大BDP: ${BOLD}$(( max_bdp / 1024 ))KB${NC} (共${line_count}条线路)"
    echo -e "  ${WHITE}本地方向:    ${BOLD}${down_bw}Mbps × ${down_rtt}ms RTT = $(( bdp_down / 1024 ))KB BDP${NC}"

    # 取最终最大BDP
    [ $bdp_down -gt $max_bdp ] && max_bdp=$bdp_down

    echo ""
    local has_proxy="no"
    if confirm_action "此服务器是否运行翻墙代理?"; then
        has_proxy="yes"
    fi

    local header="# 角色: 落地服务器 (最终出口)
# 上游线路数: ${line_count}${all_header}
# 下游: 落地 → 目标 | ${down_bw}Mbps | 单程${down_ping}ms | RTT ${down_rtt}ms
# 缓冲区按所有方向最大BDP $(( max_bdp / 1024 ))KB 计算
# 翻墙代理: ${has_proxy}"

    local config
    config=$(calculate_and_generate "落地服务器 (${line_count}条上游)" \
        "$main_bw" "$main_rtt" "$down_bw" "$down_rtt" "$header")

    apply_sysctl_config "落地服务器 (${line_count}条上游)" "$config"
}

# ================================================================

# ================================================================
#                      状态与服务管理
# ================================================================

show_status() {
    echo ""
    echo -e "  ${BOLD}${CYAN}========== 系统状态 ==========${NC}"

    if [ -f "$PROFILE_CONF" ]; then
        source "$PROFILE_CONF"
        echo -e "  ${WHITE}BBR方案: ${BOLD}$SYSCTL_PROFILE_NAME${NC}"
    else
        echo -e "  ${DIM}BBR: 未配置${NC}"
    fi

    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    local lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
    echo -e "  拥塞控制: ${BOLD}$cc${NC} | 队列: ${BOLD}$qd${NC}"
    echo -e "  rmem_max: ${BOLD}$(( rmem / 1024 / 1024 ))MB${NC} | notsent_lowat: ${BOLD}$(( lowat / 1024 ))KB${NC}"

    echo ""
    local iface=$(detect_interface)
    if [ -f "$TC_CONF" ]; then
        source "$TC_CONF"
        echo -e "  ${WHITE}TC限速: ${BOLD}$TC_DESC${NC}"
    else
        echo -e "  ${DIM}TC限速: 未配置${NC}"
    fi

    echo -e "  ${BOLD}[出方向]${NC}"
    tc -s qdisc show dev "$iface" 2>/dev/null | sed 's/^/  /'
    echo -e "  ${BOLD}[入方向]${NC}"
    tc -s qdisc show dev "$IFB_DEV" 2>/dev/null | sed 's/^/  /' || echo "  (未启用)"

    echo ""
    echo -e "  ${BOLD}[地理白名单]${NC}"
    if nft list table inet geo_filter >/dev/null 2>&1; then
        if [ -f "$GEO_CONF" ]; then
            source "$GEO_CONF"
            echo -e "  状态: ${GREEN}已启用${NC} | 国家: ${BOLD}${GEO_COUNTRIES}${NC}"
            [ -n "${GEO_LAST_UPDATE:-}" ] && echo -e "  上次更新: ${GEO_LAST_UPDATE}"
        else
            echo -e "  状态: ${GREEN}已启用${NC}"
        fi
        local drop_pkts=$(nft list chain inet geo_filter input 2>/dev/null | grep -oP 'counter packets \K[0-9]+' | tail -1 || echo "0")
        echo -e "  已拦截: ${BOLD}${drop_pkts}${NC} 个数据包"
    else
        echo -e "  状态: ${DIM}未启用${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}[重传统计]${NC}"
    nstat -sz TcpRetransSegs UdpRcvbufErrors UdpSndbufErrors 2>/dev/null | sed 's/^/  /' || \
        netstat -s 2>/dev/null | grep -i retrans | sed 's/^/  /'
    echo ""
}

install_service() {
    local script_path=$(readlink -f "$0")
    init_config_dir

    cat > /etc/systemd/system/network-optimizer.service << EOF
[Unit]
Description=专线网络优化 (BBR + TC限速)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script_path service-start
ExecStop=$script_path service-stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable network-optimizer.service

    echo ""
    echo -e "  ${GREEN}${BOLD}服务已安装: network-optimizer${NC}"
    echo -e "  ${WHITE}systemctl start|stop|status network-optimizer${NC}"
    echo ""
}

toggle_service() {
    if systemctl is-enabled network-optimizer.service >/dev/null 2>&1; then
        # 已启用，关闭
        if confirm_action "确定关闭开机自启?"; then
            systemctl disable network-optimizer.service 2>/dev/null
            systemctl stop network-optimizer.service 2>/dev/null
            echo -e "  ${GREEN}开机自启已关闭${NC}"
        fi
    else
        # 未启用，安装
        install_service
    fi
}

reload_network() {
    echo ""
    echo -e "  ${BOLD}${CYAN}刷新网络配置 (无需重启)${NC}"
    echo ""

    # 扫描并清理可能冲突的sysctl配置
    echo -e "  ${WHITE}${BOLD}[清理] 扫描可能冲突的网络配置...${NC}"
    local conflict_found=0
    local conflict_files=""

    # 检查sysctl.d下其他配置文件
    for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
        [ ! -f "$f" ] && continue
        # 跳过我们自己的配置
        [ "$f" = "/etc/sysctl.d/99-network-optimize.conf" ] && continue
        # 检查是否包含可能覆盖的网络参数
        if grep -qE "tcp_congestion_control|tcp_rmem|tcp_wmem|rmem_max|wmem_max|default_qdisc|tcp_notsent_lowat|tcp_slow_start|tcp_fastopen|tcp_tw_reuse|ip_forward" "$f" 2>/dev/null; then
            conflict_found=1
            local matched=$(grep -cE "tcp_congestion_control|tcp_rmem|tcp_wmem|rmem_max|wmem_max|default_qdisc|tcp_notsent_lowat" "$f" 2>/dev/null)
            echo -e "  ${YELLOW}⚠${NC}  $f (${matched}条冲突参数)"
            conflict_files="$conflict_files $f"
        fi
    done

    # 检查NetworkManager的sysctl覆盖
    for f in /etc/NetworkManager/conf.d/*.conf /etc/NetworkManager/NetworkManager.conf; do
        [ ! -f "$f" ] && continue
        if grep -qiE "sysctl|tcp" "$f" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${NC}  $f (NetworkManager可能覆盖)"
            conflict_found=1
            conflict_files="$conflict_files $f"
        fi
    done

    # 检查systemd-sysctl相关
    for f in /usr/lib/sysctl.d/*.conf /run/sysctl.d/*.conf; do
        [ ! -f "$f" ] && continue
        if grep -qE "tcp_congestion_control|tcp_rmem|tcp_wmem|rmem_max|wmem_max|default_qdisc" "$f" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${NC}  $f (系统级配置)"
            conflict_found=1
            conflict_files="$conflict_files $f"
        fi
    done

    if [ $conflict_found -eq 1 ]; then
        echo ""
        if confirm_action "发现冲突配置，是否注释掉冲突参数? (原文件会备份为.bak)"; then
            for f in $conflict_files; do
                # 跳过系统目录（只读）
                if [[ "$f" == /usr/lib/* ]] || [[ "$f" == /run/* ]]; then
                    echo -e "  ${DIM}跳过只读文件: $f${NC}"
                    continue
                fi
                # 备份
                cp "$f" "${f}.bak" 2>/dev/null
                # 注释掉冲突行
                sed -i -E '/^[^#]*(tcp_congestion_control|tcp_rmem|tcp_wmem|rmem_max|wmem_max|rmem_default|wmem_default|default_qdisc|tcp_notsent_lowat|tcp_slow_start_after_idle|tcp_no_metrics_save|tcp_fastopen|tcp_tw_reuse|tcp_fin_timeout|tcp_keepalive|tcp_sack|tcp_frto|tcp_ecn|tcp_mtu_probing|ip_forward|tcp_window_scaling|tcp_timestamps|tcp_max_syn_backlog|tcp_max_tw_buckets|somaxconn|netdev_max_backlog|udp_rmem_min|udp_wmem_min)/s/^/# [disabled by network-optimizer] /' "$f" 2>/dev/null
                echo -e "  ${GREEN}✓${NC} 已处理: $f (备份: ${f}.bak)"
            done
        fi
    else
        echo -e "  ${GREEN}✓${NC} 未发现冲突配置"
    fi

    echo ""

    # 刷新sysctl
    echo -ne "  [sysctl] 重新加载内核参数 ... "
    if [ -f "$SYSCTL_CONF" ] || [ -f /etc/sysctl.d/99-network-optimize.conf ]; then
        sysctl --system > /dev/null 2>&1
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}跳过 (未找到配置文件)${NC}"
    fi

    # 重新加载TC限速
    if [ -f "$TC_CONF" ]; then
        source "$TC_CONF"
        echo -ne "  [tc] 重新应用限速 ($TC_DESC) ... "

        tc qdisc del dev "$TC_IFACE" root 2>/dev/null
        tc qdisc del dev "$TC_IFACE" ingress 2>/dev/null
        tc qdisc del dev "$IFB_DEV" root 2>/dev/null
        ip link set "$IFB_DEV" down 2>/dev/null

        tc qdisc add dev "$TC_IFACE" root handle 1: tbf rate $TC_RATE burst $TC_BURST latency $TC_LATENCY && \
        tc qdisc add dev "$TC_IFACE" parent 1:1 handle 10: fq && \
        modprobe ifb numifbs=1 2>/dev/null && \
        ip link set "$IFB_DEV" up && \
        tc qdisc add dev "$TC_IFACE" handle ffff: ingress && \
        tc filter add dev "$TC_IFACE" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEV" && \
        tc qdisc add dev "$IFB_DEV" root handle 1: tbf rate $TC_RATE burst $TC_BURST latency $TC_LATENCY && \
        tc qdisc add dev "$IFB_DEV" parent 1:1 handle 10: fq && \
        echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
    else
        echo -e "  ${DIM}[tc] 跳过 (未配置限速)${NC}"
    fi

    # 验证
    echo ""
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    echo -e "  ${GREEN}${BOLD}刷新完成${NC}"
    echo -e "  拥塞控制: ${BOLD}$cc${NC} | 队列: ${BOLD}$qd${NC} | rmem_max: ${BOLD}$(( rmem / 1024 / 1024 ))MB${NC}"
    echo ""
}

service_start() {
    [ -f "$SYSCTL_CONF" ] && { echo "[sysctl] 应用配置..."; sysctl --system > /dev/null 2>&1; echo "[sysctl] 完成"; }
    if [ -f "$TC_CONF" ]; then
        source "$TC_CONF"
        echo "[tc] 应用限速: $TC_DESC"
        tc qdisc del dev "$TC_IFACE" root 2>/dev/null
        tc qdisc del dev "$TC_IFACE" ingress 2>/dev/null
        tc qdisc del dev "$IFB_DEV" root 2>/dev/null; ip link set "$IFB_DEV" down 2>/dev/null
        tc qdisc add dev "$TC_IFACE" root handle 1: tbf rate $TC_RATE burst $TC_BURST latency $TC_LATENCY
        tc qdisc add dev "$TC_IFACE" parent 1:1 handle 10: fq
        modprobe ifb numifbs=1 2>/dev/null; ip link set "$IFB_DEV" up
        tc qdisc add dev "$TC_IFACE" handle ffff: ingress
        tc filter add dev "$TC_IFACE" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEV"
        tc qdisc add dev "$IFB_DEV" root handle 1: tbf rate $TC_RATE burst $TC_BURST latency $TC_LATENCY
        tc qdisc add dev "$IFB_DEV" parent 1:1 handle 10: fq
        echo "[tc] 完成"
    fi
}

service_stop() {
    if [ -f "$TC_CONF" ]; then
        source "$TC_CONF"
        echo "[tc] 清除..."; tc qdisc del dev "$TC_IFACE" root 2>/dev/null
        tc qdisc del dev "$TC_IFACE" ingress 2>/dev/null
        tc qdisc del dev "$IFB_DEV" root 2>/dev/null; ip link set "$IFB_DEV" down 2>/dev/null
        modprobe -r ifb 2>/dev/null; echo "[tc] 完成"
    fi
}

restore_defaults() {
    echo ""
    confirm_action "确定恢复默认配置? (将删除所有优化配置)" || return
    stop_tc 2>/dev/null
    rm -f /etc/sysctl.d/99-network-optimize.conf
    sysctl --system > /dev/null 2>&1
    systemctl disable network-optimizer.service 2>/dev/null
    rm -f /etc/systemd/system/network-optimizer.service
    systemctl daemon-reload 2>/dev/null
    # 清理配置目录 (保留备份)
    if [ -d "$CONFIG_DIR" ]; then
        if [ -f "$CONFIG_DIR/sysctl-backup.conf" ]; then
            echo -e "  ${DIM}原始sysctl备份保留在: $CONFIG_DIR/sysctl-backup.conf${NC}"
        fi
        rm -f "$SYSCTL_CONF" "$TC_CONF" "$PROFILE_CONF" "$GEO_CONF" "$GEO_NFT"
        rm -rf "$GEO_DIR"
    fi
    # 清理白名单
    nft delete table inet geo_filter 2>/dev/null
    systemctl disable geo-whitelist.service 2>/dev/null
    rm -f /etc/systemd/system/geo-whitelist.service
    systemctl daemon-reload 2>/dev/null
    echo -e "  ${GREEN}已恢复默认${NC}"
}

# ================================================================
#                    国家访问白名单 (nftables)
# ================================================================

GEO_CONF="$CONFIG_DIR/geo-whitelist.conf"
GEO_DIR="$CONFIG_DIR/geo-zones"
GEO_NFT="$CONFIG_DIR/geo-nftables.nft"
GEO_IP_SOURCE="https://www.ipdeny.com/ipblocks/data/aggregated"

# 常用国家列表
declare -A COUNTRY_NAMES=(
    [cn]="中国" [hk]="香港" [tw]="台湾" [jp]="日本" [kr]="韩国"
    [sg]="新加坡" [us]="美国" [gb]="英国" [de]="德国" [fr]="法国"
    [au]="澳大利亚" [ca]="加拿大" [ru]="俄罗斯" [th]="泰国" [my]="马来西亚"
    [vn]="越南" [id]="印尼" [ph]="菲律宾" [in]="印度" [nl]="荷兰"
)

geo_main() {
    while true; do
    echo ""

    # 检查当前状态
    local geo_active="no"
    if nft list table inet geo_filter >/dev/null 2>&1; then
        geo_active="yes"
    fi

    if [ "$geo_active" = "yes" ]; then
        echo -e "  ${GREEN}●${NC} 地理白名单: ${WHITE}已启用${NC}"
        if [ -f "$GEO_CONF" ]; then
            source "$GEO_CONF"
            echo -e "  ${DIM}  允许国家: ${GEO_COUNTRIES:-未知}${NC}"
            if [ "${GEO_ALLOW_PING:-yes}" = "yes" ]; then
                echo -e "  ${DIM}  Ping: 允许${NC}"
            else
                echo -e "  ${DIM}  Ping: 禁止${NC}"
            fi
        fi
    else
        echo -e "  ${DIM}○ 地理白名单: 未启用${NC}"
    fi
    echo ""

    # ping切换标签
    local ping_label="禁止 Ping"
    if [ -f "$GEO_CONF" ]; then
        source "$GEO_CONF"
        [ "${GEO_ALLOW_PING:-yes}" = "no" ] && ping_label="允许 Ping"
    fi

    select_menu "国家访问白名单" \
        "设置白名单 (选择允许的国家)" \
        "更新IP数据库 (强制重新下载)" \
        "$ping_label (快速切换)" \
        "查看当前规则" \
        "关闭白名单 (删除所有规则)" \
        "返回主菜单"

    case $? in
        0) geo_setup ;;
        1) geo_update ;;
        2) geo_toggle_ping ;;
        3) geo_status ;;
        4) geo_remove ;;
        5) return ;;
    esac

    echo ""
    echo -ne "  ${DIM}按回车继续...${NC}"
    read -r
    done
}

geo_setup() {
    echo ""
    # 检查依赖
    if ! command -v nft >/dev/null 2>&1; then
        echo -e "  ${RED}错误: 未安装 nftables${NC}"
        echo -e "  ${DIM}安装: apt install nftables -y${NC}"
        return
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "  ${RED}错误: 未安装 curl${NC}"
        echo -e "  ${DIM}安装: apt install curl -y${NC}"
        return
    fi

    echo -e "  ${BOLD}${CYAN}━━━ 国家访问白名单设置 ━━━${NC}"
    echo -e "  ${DIM}策略: 只允许白名单国家IP访问，其余全部拒绝${NC}"
    echo -e "  ${DIM}数据源: ipdeny.com (聚合IP段)${NC}"
    echo ""

    # SSH端口安全
    echo -e "  ${RED}${BOLD}⚠ 安全提示: 必须确保SSH端口在白名单内，否则会被锁在外面${NC}"
    echo ""
    local ssh_port
    read_int "SSH端口" "22" "ssh_port"

    # 流量方向
    echo ""
    select_menu "白名单控制哪些流量?" \
        "只控制入站 (input: 直接访问本机的流量)" \
        "入站 + 转发 (input + forward: 包括经过本机中转的流量)"
    local _chain_choice=$?

    local chain_mode="input"
    [ $_chain_choice -eq 1 ] && chain_mode="input+forward"

    # 是否允许ping
    echo ""
    select_menu "是否允许 ICMP Ping?" \
        "允许 (方便排查网络问题)" \
        "禁止 (隐藏服务器，更安全)"
    local _ping_choice=$?

    local allow_ping="yes"
    [ $_ping_choice -eq 1 ] && allow_ping="no"

    # 输入国家代码
    echo ""
    echo -e "  ${WHITE}${BOLD}输入允许访问的国家代码${NC}"
    echo -e "  ${DIM}多个国家用空格分隔，不区分大小写${NC}"
    echo -e "  ${DIM}常用: cn=中国 hk=香港 tw=台湾 jp=日本 kr=韩国 sg=新加坡 us=美国${NC}"
    echo -e "  ${DIM}      de=德国 gb=英国 fr=法国 au=澳大利亚 ca=加拿大 nl=荷兰${NC}"
    echo -e "  ${DIM}      th=泰国 my=马来西亚 vn=越南 id=印尼 ph=菲律宾 in=印度 ru=俄罗斯${NC}"
    echo ""
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null

    local countries=""
    while [ -z "$countries" ]; do
        echo -ne "  ${WHITE}国家代码: ${NC}"
        read countries
        countries=$(echo "$countries" | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | xargs)
        if [ -z "$countries" ]; then
            echo -e "  ${RED}不能为空，请输入至少一个国家代码${NC}"
        fi
        # 校验: 每个都应该是2位字母
        if [ -n "$countries" ]; then
            local valid=1
            for cc in $countries; do
                if ! [[ "$cc" =~ ^[a-z]{2}$ ]]; then
                    echo -e "  ${RED}无效代码: $cc (应为2位字母，如 cn/jp/us)${NC}"
                    countries=""
                    valid=0
                    break
                fi
            done
        fi
    done

    # 显示选中的国家
    echo ""
    echo -e "  ${WHITE}已选择国家:${NC}"
    for cc in $countries; do
        local name="${COUNTRY_NAMES[$cc]:-$cc}"
        echo -e "    ${GREEN}✓${NC} $cc ($name)"
    done

    # 自定义白名单IP
    echo ""
    echo -e "  ${WHITE}${BOLD}自定义白名单IP (可选)${NC}"
    echo -e "  ${DIM}添加不在上述国家范围内但需要放行的IP/段${NC}"
    echo -e "  ${DIM}例如: 103.1.2.3 或 103.1.2.0/24，多个用空格分隔${NC}"
    echo -e "  ${DIM}留空跳过${NC}"
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null
    echo -ne "  ${WHITE}额外白名单IP: ${NC}"
    read custom_ips

    # 校验: 过滤掉无效输入
    if [ -n "$custom_ips" ]; then
        local clean_ips=""
        for item in $custom_ips; do
            if [[ "$item" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$ ]]; then
                clean_ips="$clean_ips $item"
            elif [[ "$item" =~ ^[a-zA-Z]{2,3}$ ]]; then
                echo -e "  ${RED}⚠ '$item' 看起来是国家代码，不是IP地址，已跳过${NC}"
                echo -e "  ${DIM}  国家代码请在上一步输入${NC}"
            else
                echo -e "  ${YELLOW}跳过无效输入: $item (格式: 1.2.3.4 或 1.2.3.0/24)${NC}"
            fi
        done
        custom_ips=$(echo "$clean_ips" | xargs)
    fi

    # 确认
    echo ""
    local mode_desc="只控制入站 (input)"
    [ "$chain_mode" = "input+forward" ] && mode_desc="入站 + 转发 (input + forward)"
    local ping_desc="${GREEN}允许${NC}"
    [ "$allow_ping" = "no" ] && ping_desc="${RED}禁止${NC}"
    echo -e "  ${YELLOW}${BOLD}即将应用以下规则:${NC}"
    echo -e "  ${WHITE}控制方向: ${BOLD}$mode_desc${NC}"
    echo -e "  ${WHITE}允许国家: ${BOLD}$countries${NC}"
    echo -e "  ${WHITE}SSH端口:  ${BOLD}$ssh_port${NC} (所有IP均可访问)"
    echo -e "  ${WHITE}Ping:     ${BOLD}$ping_desc${NC}"
    echo -e "  ${WHITE}私网地址: ${BOLD}自动放行${NC} (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)"
    [ -n "$custom_ips" ] && echo -e "  ${WHITE}额外IP:   ${BOLD}$custom_ips${NC}"
    echo -e "  ${WHITE}其他流量: ${RED}${BOLD}全部拒绝${NC}"
    echo ""

    if ! confirm_action "确认应用? (确保SSH端口正确，否则会被锁在外面!)"; then
        echo -e "  ${DIM}已取消${NC}"
        return
    fi

    # 保存配置
    init_config_dir
    mkdir -p "$GEO_DIR"
    cat > "$GEO_CONF" << EOF
GEO_COUNTRIES="$countries"
GEO_SSH_PORT="$ssh_port"
GEO_CUSTOM_IPS="$custom_ips"
GEO_CHAIN_MODE="$chain_mode"
GEO_ALLOW_PING="$allow_ping"
EOF

    # 加载IP数据并应用 (优先用本地缓存)
    geo_load_and_apply "$countries" "$ssh_port" "$custom_ips" "$chain_mode" "$allow_ping" "no"
}

geo_load_and_apply() {
    local countries="$1"
    local ssh_port="$2"
    local custom_ips="$3"
    local chain_mode="${4:-input}"
    local allow_ping="${5:-yes}"
    local force_download="${6:-no}"

    echo ""
    init_config_dir
    mkdir -p "$GEO_DIR"

    local all_ips=""
    local fail_count=0

    # 分类: 哪些用缓存，哪些要下载
    local need_download=""
    local use_cache=""

    for cc in $countries; do
        local zone_file="$GEO_DIR/${cc}.zone"
        if [ "$force_download" = "no" ] && [ -f "$zone_file" ] && [ -s "$zone_file" ]; then
            use_cache="$use_cache $cc"
        else
            need_download="$need_download $cc"
        fi
    done

    # 显示缓存命中
    for cc in $use_cache; do
        local name="${COUNTRY_NAMES[$cc]:-$cc}"
        local count=$(wc -l < "$GEO_DIR/${cc}.zone")
        echo -e "  $cc ($name) ... ${GREEN}缓存${NC} (${count}条)"
    done

    # 并行下载需要的文件
    if [ -n "$need_download" ]; then
        local dl_count=$(echo $need_download | wc -w)
        echo -e "  ${CYAN}并行下载 ${dl_count} 个国家IP数据库...${NC}"

        # 创建临时目录存放下载状态
        local tmp_status=$(mktemp -d)

        for cc in $need_download; do
            (
                local zone_file="$GEO_DIR/${cc}.zone"
                if curl -sf --connect-timeout 10 --max-time 60 \
                    "${GEO_IP_SOURCE}/${cc}-aggregated.zone" -o "$zone_file" 2>/dev/null; then
                    echo "ok" > "$tmp_status/${cc}"
                else
                    echo "fail" > "$tmp_status/${cc}"
                fi
            ) &
        done

        # 等待所有下载完成
        wait

        # 显示下载结果
        for cc in $need_download; do
            local name="${COUNTRY_NAMES[$cc]:-$cc}"
            local zone_file="$GEO_DIR/${cc}.zone"
            local status=$(cat "$tmp_status/${cc}" 2>/dev/null)

            if [ "$status" = "ok" ] && [ -f "$zone_file" ] && [ -s "$zone_file" ]; then
                local count=$(wc -l < "$zone_file")
                echo -e "  $cc ($name) ... ${GREEN}下载成功${NC} (${count}条)"
            elif [ -f "$zone_file" ] && [ -s "$zone_file" ]; then
                echo -e "  $cc ($name) ... ${YELLOW}下载失败，使用旧缓存${NC}"
            else
                echo -e "  $cc ($name) ... ${RED}下载失败，无缓存${NC}"
                fail_count=$(( fail_count + 1 ))
            fi
        done

        rm -rf "$tmp_status"
    fi

    # 读取所有IP段
    for cc in $countries; do
        local zone_file="$GEO_DIR/${cc}.zone"
        [ ! -f "$zone_file" ] && continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [[ "$line" =~ ^# ]] && continue
            all_ips="${all_ips}${line},"
        done < "$zone_file"
    done

    if [ -z "$all_ips" ]; then
        echo -e "  ${RED}无可用IP数据，无法应用规则${NC}"
        return 1
    fi

    all_ips="${all_ips%,}"

    echo ""
    echo -ne "  生成 nftables 规则 (模式: ${chain_mode}) ... "

    # 构建自定义IP规则
    local custom_input_rules=""
    local custom_forward_rules=""
    if [ -n "$custom_ips" ]; then
        for ip in $custom_ips; do
            custom_input_rules="${custom_input_rules}
        ip saddr ${ip} accept"
            custom_forward_rules="${custom_forward_rules}
        ip saddr ${ip} accept"
        done
    fi

    # ICMP规则
    local icmp_rule=""
    if [ "$allow_ping" = "yes" ]; then
        icmp_rule="
        # ICMP放行 (ping)
        ip protocol icmp accept"
    else
        icmp_rule="
        # ICMP禁止 (ping被丢弃)
        ip protocol icmp drop"
    fi

    # 构建forward链 (仅在input+forward模式下)
    local forward_chain=""
    if [ "$chain_mode" = "input+forward" ]; then
        forward_chain="
    chain forward {
        type filter hook forward priority 10; policy accept;

        # 已建立的连接直接放行
        ct state established,related accept

        # 私网地址放行 (服务器间通信)
        ip saddr 10.0.0.0/8 accept
        ip saddr 172.16.0.0/12 accept
        ip saddr 192.168.0.0/16 accept
        ip saddr 100.64.0.0/10 accept

        # 白名单国家放行
        ip saddr @whitelist_v4 accept
${custom_forward_rules}

        # 其余转发流量拒绝
        counter drop
    }"
    fi

    # 生成nftables规则文件
    cat > "$GEO_NFT" << NFTEOF
#!/usr/sbin/nft -f

# 清理旧规则
table inet geo_filter
delete table inet geo_filter

table inet geo_filter {
    set whitelist_v4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { ${all_ips} }
    }

    chain input {
        type filter hook input priority 10; policy accept;

        # 已建立的连接直接放行
        ct state established,related accept

        # 回环接口放行
        iif "lo" accept

        # 私网地址放行 (服务器间通信)
        ip saddr 10.0.0.0/8 accept
        ip saddr 172.16.0.0/12 accept
        ip saddr 192.168.0.0/16 accept
        ip saddr 100.64.0.0/10 accept
        ip saddr 127.0.0.0/8 accept

        # SSH端口对所有IP开放 (防锁)
        tcp dport ${ssh_port} accept
${icmp_rule}

        # 白名单国家放行
        ip saddr @whitelist_v4 accept
${custom_input_rules}

        # 其余全部拒绝
        counter drop
    }
${forward_chain}
}
NFTEOF

    echo -e "${GREEN}✓${NC}"

    # 应用规则
    echo -ne "  应用 nftables 规则 ... "
    if nft -f "$GEO_NFT" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        local nft_err=$(nft -f "$GEO_NFT" 2>&1)
        echo -e "${RED}✗${NC}"
        echo -e "  ${RED}错误: $nft_err${NC}"
        return 1
    fi

    # 持久化
    cat > /etc/systemd/system/geo-whitelist.service << SVCEOF
[Unit]
Description=GeoIP Whitelist (nftables)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${GEO_NFT}
ExecStop=/usr/sbin/nft delete table inet geo_filter

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable geo-whitelist.service 2>/dev/null

    # 记录更新时间
    sed -i '/^GEO_LAST_UPDATE=/d' "$GEO_CONF" 2>/dev/null
    echo "GEO_LAST_UPDATE=\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$GEO_CONF"

    echo ""
    echo -e "  ${GREEN}${BOLD}━━━ 白名单已生效 ━━━${NC}"
    echo -e "  ${GREEN}允许: ${countries}${NC}"
    echo -e "  ${GREEN}SSH ${ssh_port} 端口: 全球开放${NC}"
    echo -e "  ${GREEN}开机自启: 已启用${NC}"
    echo ""

    if [ $fail_count -gt 0 ]; then
        echo -e "  ${YELLOW}⚠ 有 ${fail_count} 个国家无可用数据，请手动更新IP数据库${NC}"
    fi
}

geo_update() {
    if [ ! -f "$GEO_CONF" ]; then
        echo -e "  ${RED}未找到白名单配置，请先设置白名单${NC}"
        return
    fi
    source "$GEO_CONF"
    echo -e "  ${CYAN}强制重新下载IP数据库: ${GEO_COUNTRIES}${NC}"
    geo_load_and_apply "$GEO_COUNTRIES" "$GEO_SSH_PORT" "$GEO_CUSTOM_IPS" "${GEO_CHAIN_MODE:-input}" "${GEO_ALLOW_PING:-yes}" "yes"
}

geo_toggle_ping() {
    if [ ! -f "$GEO_CONF" ]; then
        echo -e "  ${RED}未找到白名单配置，请先设置白名单${NC}"
        return
    fi
    source "$GEO_CONF"

    local new_ping
    if [ "${GEO_ALLOW_PING:-yes}" = "yes" ]; then
        new_ping="no"
        echo -e "  ${YELLOW}切换 Ping: 允许 → 禁止${NC}"
    else
        new_ping="yes"
        echo -e "  ${GREEN}切换 Ping: 禁止 → 允许${NC}"
    fi

    # 更新配置文件
    sed -i "s/^GEO_ALLOW_PING=.*/GEO_ALLOW_PING=\"$new_ping\"/" "$GEO_CONF"

    # 重新应用规则
    source "$GEO_CONF"
    geo_load_and_apply "$GEO_COUNTRIES" "$GEO_SSH_PORT" "$GEO_CUSTOM_IPS" "${GEO_CHAIN_MODE:-input}" "$new_ping" "no"
}

geo_status() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ 地理白名单状态 ━━━${NC}"

    if nft list table inet geo_filter >/dev/null 2>&1; then
        echo -e "  ${GREEN}●${NC} 状态: ${WHITE}已启用${NC}"

        if [ -f "$GEO_CONF" ]; then
            source "$GEO_CONF"
            local mode_desc="只控制入站 (input)"
            [ "${GEO_CHAIN_MODE:-input}" = "input+forward" ] && mode_desc="入站 + 转发 (input + forward)"
            echo -e "  ${WHITE}控制方向: ${BOLD}${mode_desc}${NC}"
            echo -e "  ${WHITE}允许国家: ${BOLD}${GEO_COUNTRIES}${NC}"
            echo -e "  ${WHITE}SSH端口:  ${BOLD}${GEO_SSH_PORT}${NC}"
            if [ "${GEO_ALLOW_PING:-yes}" = "yes" ]; then
                echo -e "  ${WHITE}Ping:     ${GREEN}${BOLD}允许${NC}"
            else
                echo -e "  ${WHITE}Ping:     ${RED}${BOLD}禁止${NC}"
            fi
            [ -n "${GEO_CUSTOM_IPS:-}" ] && echo -e "  ${WHITE}额外IP:   ${BOLD}${GEO_CUSTOM_IPS}${NC}"
            [ -n "${GEO_LAST_UPDATE:-}" ] && echo -e "  ${WHITE}上次更新: ${BOLD}${GEO_LAST_UPDATE}${NC}"
        fi

        # 统计
        echo ""
        local input_drop=$(nft list chain inet geo_filter input 2>/dev/null | grep -oP 'counter packets \K[0-9]+' | tail -1 || echo "0")
        echo -e "  ${WHITE}入站拦截: ${BOLD}${input_drop}${NC} 个数据包"

        if nft list chain inet geo_filter forward >/dev/null 2>&1; then
            local forward_drop=$(nft list chain inet geo_filter forward 2>/dev/null | grep -oP 'counter packets \K[0-9]+' | tail -1 || echo "0")
            echo -e "  ${WHITE}转发拦截: ${BOLD}${forward_drop}${NC} 个数据包"
        fi

        # 显示规则摘要
        echo ""
        echo -e "  ${DIM}规则摘要 (input):${NC}"
        nft list chain inet geo_filter input 2>/dev/null | grep -E "accept|drop" | head -8 | sed 's/^/  /'
        if nft list chain inet geo_filter forward >/dev/null 2>&1; then
            echo -e "  ${DIM}规则摘要 (forward):${NC}"
            nft list chain inet geo_filter forward 2>/dev/null | grep -E "accept|drop" | head -5 | sed 's/^/  /'
        fi
    else
        echo -e "  ${DIM}○ 状态: 未启用${NC}"
    fi
    echo ""
}

geo_remove() {
    echo ""
    if ! nft list table inet geo_filter >/dev/null 2>&1; then
        echo -e "  ${DIM}白名单未启用，无需操作${NC}"
        return
    fi

    if ! confirm_action "确定关闭地理白名单? (将允许所有国家访问)"; then
        return
    fi

    nft delete table inet geo_filter 2>/dev/null
    systemctl disable geo-whitelist.service 2>/dev/null
    rm -f /etc/systemd/system/geo-whitelist.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${GREEN}地理白名单已关闭，所有IP均可访问${NC}"
}

# ================================================================
#                     端口连接监控
# ================================================================

port_monitor() {
    while true; do
    echo ""
    select_menu "端口连接监控" \
        "查看所有监听端口的连接情况" \
        "查看指定端口的连接IP" \
        "实时连接排行 (按连接数排序)" \
        "返回主菜单"

    case $? in
        0) port_show_all ;;
        1) port_show_single ;;
        2) port_show_ranking ;;
        3) return ;;
    esac

    echo ""
    echo -ne "  ${DIM}按回车继续...${NC}"
    read -r
    done
}

port_show_all() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ 所有监听端口连接情况 ━━━${NC}"
    echo ""

    # 获取所有监听端口
    local ports=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oP '(?<=:)\d+$' | sort -un)

    if [ -z "$ports" ]; then
        echo -e "  ${DIM}未发现监听端口${NC}"
        return
    fi

    # 表头
    printf "  ${BOLD}${WHITE}%-8s %-20s %-8s %-8s${NC}\n" "端口" "服务" "连接数" "独立IP数"
    printf "  ${DIM}%-8s %-20s %-8s %-8s${NC}\n" "────" "────────────" "──────" "────────"

    for port in $ports; do
        # 获取连接数
        local conn_count=$(ss -tnH 2>/dev/null | awk '{print $5}' | grep -c ":${port}$" || echo "0")
        # 获取独立IP数
        local ip_count=$(ss -tnH 2>/dev/null | awk '{print $5}' | grep ":${port}$" | awk -F: '{print $1}' | sort -u | grep -cv '^$' || echo "0")
        # 猜测服务名
        local svc_name=$(port_guess_service "$port")

        # 颜色: 连接数多的高亮
        if [ "$conn_count" -ge 100 ]; then
            printf "  ${RED}%-8s${NC} ${DIM}%-20s${NC} ${RED}${BOLD}%-8s${NC} ${YELLOW}%-8s${NC}\n" "$port" "$svc_name" "$conn_count" "$ip_count"
        elif [ "$conn_count" -ge 10 ]; then
            printf "  ${YELLOW}%-8s${NC} ${DIM}%-20s${NC} ${YELLOW}%-8s${NC} ${WHITE}%-8s${NC}\n" "$port" "$svc_name" "$conn_count" "$ip_count"
        else
            printf "  ${WHITE}%-8s${NC} ${DIM}%-20s${NC} ${WHITE}%-8s${NC} ${DIM}%-8s${NC}\n" "$port" "$svc_name" "$conn_count" "$ip_count"
        fi
    done

    echo ""
    local total_conn=$(ss -tnH 2>/dev/null | wc -l)
    local total_ip=$(ss -tnH 2>/dev/null | awk '{print $5}' | grep -oP '^[^:]+' | sort -u | wc -l)
    echo -e "  ${DIM}总连接数: ${total_conn} | 总独立IP: ${total_ip}${NC}"
    echo ""
}

port_show_single() {
    echo ""
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null
    local port
    read_int "输入要查看的端口号" "" "port"

    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ 端口 ${port} 连接详情 ━━━${NC}"

    local svc_name=$(port_guess_service "$port")
    echo -e "  ${DIM}服务: ${svc_name}${NC}"
    echo ""

    # 获取连接到此端口的所有IP及其连接数
    local ip_list=$(ss -tnH 2>/dev/null | awk '{print $5}' | grep ":${port}$" | grep -oP '^[^:]+' | sort | uniq -c | sort -rn)

    if [ -z "$ip_list" ]; then
        echo -e "  ${DIM}当前无连接${NC}"
        echo ""
        return
    fi

    local total=0
    printf "  ${BOLD}${WHITE}%-8s %-40s %-15s${NC}\n" "连接数" "IP地址" "连接状态"
    printf "  ${DIM}%-8s %-40s %-15s${NC}\n" "──────" "────────────────────" "──────────"

    while read -r count ip; do
        [ -z "$ip" ] && continue
        total=$(( total + count ))

        # 获取该IP的连接状态分布
        local states=$(ss -tnH 2>/dev/null | grep "${ip}.*:${port}" | awk '{print $1}' | sort | uniq -c | sort -rn | awk '{printf "%s(%s) ", $2, $1}')

        if [ "$count" -ge 50 ]; then
            printf "  ${RED}${BOLD}%-8s${NC} ${WHITE}%-40s${NC} ${DIM}%-15s${NC}\n" "$count" "$ip" "$states"
        elif [ "$count" -ge 10 ]; then
            printf "  ${YELLOW}%-8s${NC} ${WHITE}%-40s${NC} ${DIM}%-15s${NC}\n" "$count" "$ip" "$states"
        else
            printf "  ${WHITE}%-8s${NC} ${DIM}%-40s${NC} ${DIM}%-15s${NC}\n" "$count" "$ip" "$states"
        fi
    done <<< "$ip_list"

    local ip_count=$(echo "$ip_list" | wc -l)
    echo ""
    echo -e "  ${DIM}总计: ${total} 连接 | ${ip_count} 个独立IP${NC}"
    echo ""
}

port_show_ranking() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ 实时连接排行 ━━━${NC}"
    echo ""

    # IP连接数排行
    echo -e "  ${WHITE}${BOLD}[TOP 20 IP - 按连接数排序]${NC}"
    echo ""
    printf "  ${BOLD}%-6s %-40s %-10s${NC}\n" "排名" "IP地址" "连接数"
    printf "  ${DIM}%-6s %-40s %-10s${NC}\n" "────" "────────────────────" "──────"

    local rank=0
    ss -tnH 2>/dev/null | awk '{print $5}' | grep -oP '^[^:]+' | sort | uniq -c | sort -rn | head -20 | while read -r count ip; do
        [ -z "$ip" ] && continue
        rank=$(( rank + 1 ))
        if [ "$count" -ge 100 ]; then
            printf "  ${RED}%-6s %-40s ${BOLD}%-10s${NC}\n" "#$rank" "$ip" "$count"
        elif [ "$count" -ge 30 ]; then
            printf "  ${YELLOW}%-6s %-40s ${BOLD}%-10s${NC}\n" "#$rank" "$ip" "$count"
        else
            printf "  ${WHITE}%-6s${NC} ${DIM}%-40s${NC} ${WHITE}%-10s${NC}\n" "#$rank" "$ip" "$count"
        fi
    done

    # 端口连接数排行
    echo ""
    echo -e "  ${WHITE}${BOLD}[TOP 20 端口 - 按连接数排序]${NC}"
    echo ""
    printf "  ${BOLD}%-8s %-20s %-10s %-10s${NC}\n" "端口" "服务" "连接数" "独立IP"
    printf "  ${DIM}%-8s %-20s %-10s %-10s${NC}\n" "────" "──────────" "──────" "──────"

    ss -tnH 2>/dev/null | awk '{print $4}' | grep -oP '(?<=:)\d+$' | sort | uniq -c | sort -rn | head -20 | while read -r count port; do
        [ -z "$port" ] && continue
        local svc=$(port_guess_service "$port")
        local ips=$(ss -tnH 2>/dev/null | awk '{print $5}' | grep ":${port}$" | grep -oP '^[^:]+' | sort -u | wc -l)
        if [ "$count" -ge 100 ]; then
            printf "  ${RED}%-8s${NC} ${DIM}%-20s${NC} ${RED}${BOLD}%-10s${NC} ${YELLOW}%-10s${NC}\n" "$port" "$svc" "$count" "$ips"
        elif [ "$count" -ge 30 ]; then
            printf "  ${YELLOW}%-8s${NC} ${DIM}%-20s${NC} ${YELLOW}%-10s${NC} ${WHITE}%-10s${NC}\n" "$port" "$svc" "$count" "$ips"
        else
            printf "  ${WHITE}%-8s${NC} ${DIM}%-20s${NC} ${WHITE}%-10s${NC} ${DIM}%-10s${NC}\n" "$port" "$svc" "$count" "$ips"
        fi
    done

    # 连接状态分布
    echo ""
    echo -e "  ${WHITE}${BOLD}[连接状态分布]${NC}"
    echo ""
    ss -tnH 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | while read -r count state; do
        printf "  ${WHITE}%-18s${NC} ${BOLD}%s${NC}\n" "$state" "$count"
    done

    echo ""
}

# 常见端口服务名猜测
port_guess_service() {
    local p="$1"
    case "$p" in
        22)    echo "SSH" ;;
        80)    echo "HTTP" ;;
        443)   echo "HTTPS" ;;
        8080)  echo "HTTP-Alt" ;;
        8443)  echo "HTTPS-Alt" ;;
        3306)  echo "MySQL" ;;
        5432)  echo "PostgreSQL" ;;
        6379)  echo "Redis" ;;
        27017) echo "MongoDB" ;;
        53)    echo "DNS" ;;
        25)    echo "SMTP" ;;
        587)   echo "SMTP-Submit" ;;
        993)   echo "IMAPS" ;;
        995)   echo "POP3S" ;;
        1080)  echo "SOCKS" ;;
        1194)  echo "OpenVPN" ;;
        3389)  echo "RDP" ;;
        8388)  echo "Shadowsocks" ;;
        10000|10001|10002) echo "Proxy/Custom" ;;
        *)
            # 尝试从ss获取进程名
            local proc=$(ss -tlnpH 2>/dev/null | grep ":${p} " | grep -oP 'users:\(\("\K[^"]+' | head -1)
            [ -n "$proc" ] && echo "$proc" || echo "-"
            ;;
    esac
}

# ================================================================
#                          主菜单
# ================================================================

interactive_main() {
    while true; do
    clear
    echo ""
    echo -e "  ${BOLD}${WHITE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}${WHITE}║        专线网络优化工具 beta1.0                ║${NC}"
    echo -e "  ${BOLD}${WHITE}╚════════════════════════════════════════════════╝${NC}"
    echo ""

    # 状态摘要
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ -f "$PROFILE_CONF" ]; then
        source "$PROFILE_CONF"
        echo -e "  ${GREEN}●${NC} BBR优化:  ${WHITE}$SYSCTL_PROFILE_NAME${NC}"
    else
        echo -e "  ${DIM}○ BBR优化:  未配置 ($cc)${NC}"
    fi

    local iface=$(detect_interface)
    if [ -n "$iface" ] && tc qdisc show dev "$iface" 2>/dev/null | grep -q tbf; then
        [ -f "$TC_CONF" ] && source "$TC_CONF"
        echo -e "  ${GREEN}●${NC} TC限速:   ${WHITE}${TC_DESC:-已启用}${NC}"
    else
        echo -e "  ${DIM}○ TC限速:   未启用${NC}"
    fi

    if nft list table inet geo_filter >/dev/null 2>&1; then
        [ -f "$GEO_CONF" ] && source "$GEO_CONF"
        echo -e "  ${GREEN}●${NC} 白名单:   ${WHITE}${GEO_COUNTRIES:-已启用}${NC}"
    else
        echo -e "  ${DIM}○ 白名单:   未启用${NC}"
    fi

    local autostart_label="安装开机自启"
    if systemctl is-enabled network-optimizer.service >/dev/null 2>&1; then
        echo -e "  ${GREEN}●${NC} 开机自启: ${WHITE}已启用${NC}"
        autostart_label="关闭开机自启"
    else
        echo -e "  ${DIM}○ 开机自启: 未启用${NC}"
    fi
    echo ""

    select_menu "选择操作" \
        "[配置] BBR网络优化 (链路向导)" \
        "[配置] TC流量限速" \
        "[配置] 国家访问白名单" \
        "[监控] 查看系统状态" \
        "[监控] 端口连接监控" \
        "[管理] 刷新网络配置 (不重启立即生效)" \
        "[管理] $autostart_label" \
        "[管理] 恢复默认" \
        "退出"

    case $? in
        0) wizard_main ;;
        1) tc_menu; continue ;;
        2) geo_main; continue ;;
        3) show_status ;;
        4) port_monitor; continue ;;
        5) reload_network ;;
        6) toggle_service ;;
        7) restore_defaults ;;
        8) tput cnorm 2>/dev/null; stty sane 2>/dev/null; exit 0 ;;
    esac

    echo ""
    echo -ne "  ${DIM}按回车返回主菜单...${NC}"
    read -r
    done
}

# ================================================================
#                           入口
# ================================================================

case "${1}" in
    start|service-start) service_start ;;
    stop|service-stop)   service_stop ;;
    tc-stop)             stop_tc ;;
    status)              show_status ;;
    install)             install_service ;;
    restore)             restore_defaults ;;
    wizard)              wizard_main ;;
    geo-update)          geo_update ;;
    geo-remove)          geo_remove ;;
    geo-status)          geo_status ;;
    ports)               port_show_all ;;
    ports-rank)          port_show_ranking ;;
    "")                  interactive_main ;;
    *)
        echo "专线网络优化工具 beta1.0"
        echo ""
        echo "用法: $0 [命令]"
        echo "  无参数      交互式菜单"
        echo "  wizard      链路向导"
        echo "  start       启动已保存配置"
        echo "  stop        停止TC限速"
        echo "  status      查看状态"
        echo "  ports       查看端口连接"
        echo "  ports-rank  连接排行榜"
        echo "  install     安装开机自启"
        echo "  restore     恢复默认"
        echo "  geo-update  更新地理白名单IP"
        echo "  geo-remove  关闭地理白名单"
        echo "  geo-status  查看白名单状态"
        exit 1 ;;
esac
