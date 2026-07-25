#!/usr/bin/env bash
#
# vps_packet_test.sh
# VPS 大小包优化 (小包优化/丢包大包) 通用测试脚本
# 用法: 直接运行 ./vps_packet_test.sh，按提示交互输入
#
# 依赖: ping, mtr (或 mtr-tiny), iperf3 (可选，需要目标端配合起 iperf3 -s)
#

set -o pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

line() { printf '%s\n' "------------------------------------------------------------"; }

# ---------- 依赖检查 ----------
check_deps() {
    local missing=()
    command -v ping >/dev/null 2>&1 || missing+=("ping")
    command -v mtr  >/dev/null 2>&1 || missing+=("mtr")
    command -v iperf3 >/dev/null 2>&1 || missing+=("iperf3(可选)")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}提示: 以下工具未检测到，相关测试项会自动跳过：${NC}"
        printf '  - %s\n' "${missing[@]}"
        echo -e "${YELLOW}macOS 可用: brew install mtr iperf3${NC}"
        echo -e "${YELLOW}Debian/Ubuntu 可用: sudo apt install mtr-tiny iperf3${NC}"
        echo
    fi
}

# ---------- 交互输入 ----------
ask_inputs() {
    echo -e "${BOLD}${CYAN}=== VPS 大小包优化测试脚本 ===${NC}"
    line

    read -rp "请输入目标 IP 或域名: " TARGET
    while [ -z "$TARGET" ]; do
        read -rp "目标不能为空，请重新输入: " TARGET
    done

    read -rp "Ping 测试次数 [默认 20]: " PING_COUNT
    PING_COUNT=${PING_COUNT:-20}

    read -rp "大包 ping 大小(字节) [默认 1400]: " BIG_SIZE
    BIG_SIZE=${BIG_SIZE:-1400}

    read -rp "小包 ping 大小(字节) [默认 56]: " SMALL_SIZE
    SMALL_SIZE=${SMALL_SIZE:-56}

    read -rp "是否运行 iperf3 吞吐测试? 需目标已开放 iperf3 -s (y/n) [默认 n]: " DO_IPERF
    DO_IPERF=${DO_IPERF:-n}

    if [[ "$DO_IPERF" =~ ^[Yy]$ ]]; then
        read -rp "iperf3 端口 [默认 5201]: " IPERF_PORT
        IPERF_PORT=${IPERF_PORT:-5201}
        read -rp "iperf3 测试时长(秒) [默认 30]: " IPERF_TIME
        IPERF_TIME=${IPERF_TIME:-30}
        read -rp "iperf3 并发流数量 [默认 4]: " IPERF_STREAMS
        IPERF_STREAMS=${IPERF_STREAMS:-4}
        read -rp "是否同时测反向(-R, 服务器→本机) (y/n) [默认 y]: " IPERF_REVERSE
        IPERF_REVERSE=${IPERF_REVERSE:-y}
    fi

    read -rp "是否运行 mtr 路由对比(小包/大包)? (y/n) [默认 y]: " DO_MTR
    DO_MTR=${DO_MTR:-y}
    if [[ "$DO_MTR" =~ ^[Yy]$ ]]; then
        read -rp "mtr 每种包大小发送次数 [默认 50]: " MTR_COUNT
        MTR_COUNT=${MTR_COUNT:-50}
    fi

    OUTDIR="./vps_test_$(echo "$TARGET" | tr -c 'A-Za-z0-9._-' '_')_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$OUTDIR"

    line
    echo -e "${GREEN}配置确认:${NC}"
    echo "  目标: $TARGET"
    echo "  Ping次数: $PING_COUNT | 小包: ${SMALL_SIZE}B | 大包: ${BIG_SIZE}B"
    [[ "$DO_IPERF" =~ ^[Yy]$ ]] && echo "  iperf3: 端口$IPERF_PORT, ${IPERF_TIME}s, ${IPERF_STREAMS}并发, 反向测试:${IPERF_REVERSE}"
    [[ "$DO_MTR" =~ ^[Yy]$ ]] && echo "  mtr: 每种包${MTR_COUNT}次"
    echo "  结果保存目录: $OUTDIR"
    line
    read -rp "按回车开始测试，或 Ctrl+C 取消..." _
}

# ---------- Ping 测试 ----------
run_ping() {
    local size=$1
    local label=$2
    local outfile="$OUTDIR/ping_${label}.log"

    echo -e "${CYAN}>>> 正在测试 ${label} (包大小 ${size} 字节, ${PING_COUNT} 次)...${NC}"

    local uname_s
    uname_s=$(uname -s)
    local cmd
    if [[ "$uname_s" == "Darwin" ]]; then
        cmd="ping -s $size -c $PING_COUNT $TARGET"
    else
        cmd="ping -s $size -c $PING_COUNT $TARGET"
    fi

    eval "$cmd" | tee "$outfile"
    echo
}

parse_ping_stats() {
    # 从 ping 输出中提取 avg延迟 与 丢包率，兼容 macOS(BSD) 和 Linux
    local file=$1
    local avg loss

    # avg
    avg=$(grep -Eo '[0-9.]+/[0-9.]+/[0-9.]+' "$file" | tail -1 | awk -F'/' '{print $2}')
    # loss
    loss=$(grep -Eo '[0-9.]+% packet loss' "$file" | head -1 | grep -Eo '^[0-9.]+')

    echo "${avg:-N/A}|${loss:-N/A}"
}

# ---------- mtr 测试 ----------
run_mtr() {
    local size=$1
    local label=$2
    local outfile="$OUTDIR/mtr_${label}.log"

    echo -e "${CYAN}>>> 正在运行 mtr (${label}, 包大小 ${size} 字节, ${MTR_COUNT} 次)...${NC}"

    if command -v mtr >/dev/null 2>&1; then
        # -r 报告模式, -c 次数, -s 包大小, -n 不解析域名(可加速)
        mtr -r -c "$MTR_COUNT" -s "$size" "$TARGET" | tee "$outfile"
    else
        echo -e "${YELLOW}未安装 mtr，跳过该项${NC}" | tee "$outfile"
    fi
    echo
}

# ---------- iperf3 测试 ----------
run_iperf() {
    local outfile="$OUTDIR/iperf3.log"
    echo -e "${CYAN}>>> 正在运行 iperf3 吞吐测试 (${IPERF_TIME}s, ${IPERF_STREAMS}并发)...${NC}"
    echo -e "${YELLOW}   注意: 目标机需已运行 iperf3 -s -p $IPERF_PORT${NC}"

    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "${YELLOW}未安装 iperf3，跳过该项${NC}" | tee "$outfile"
        return
    fi

    {
        echo "=== 正向测试 (本机 -> 目标) ==="
        iperf3 -c "$TARGET" -p "$IPERF_PORT" -t "$IPERF_TIME" -P "$IPERF_STREAMS" -i 1
    } | tee "$outfile"

    if [[ "$IPERF_REVERSE" =~ ^[Yy]$ ]]; then
        {
            echo
            echo "=== 反向测试 (目标 -> 本机, -R) ==="
            iperf3 -c "$TARGET" -p "$IPERF_PORT" -t "$IPERF_TIME" -P "$IPERF_STREAMS" -i 1 -R
        } | tee -a "$outfile"
    fi
    echo
}

parse_iperf_avg() {
    # 提取 SUM sender 那一行的 Mbits/sec
    local file=$1
    grep -E '\[SUM\].*sender' "$file" | tail -1 | grep -Eo '[0-9.]+ [MGK]bits/sec' | head -1
}

# ---------- 打分辅助函数 ----------
# 每一项打分函数输出: "分数|说明"

score_latency_diff() {
    local diff=$1
    local pts note
    if awk -v d="$diff" 'BEGIN{exit !(d<10)}'; then
        pts=0; note="大小包延迟差异 ${diff}ms，处于正常抖动范围"
    elif awk -v d="$diff" 'BEGIN{exit !(d<25)}'; then
        pts=1; note="大小包延迟差异 ${diff}ms，轻微差异"
    elif awk -v d="$diff" 'BEGIN{exit !(d<60)}'; then
        pts=2; note="大小包延迟差异 ${diff}ms，差异较明显"
    else
        pts=3; note="大小包延迟差异 ${diff}ms，差异非常明显"
    fi
    echo "${pts}|${note}"
}

score_big_loss() {
    local loss=$1
    local pts note
    if awk -v l="$loss" 'BEGIN{exit !(l<=0.5)}'; then
        pts=0; note="大包丢包率 ${loss}%，正常"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=3)}'; then
        pts=1; note="大包丢包率 ${loss}%，轻微丢包"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=10)}'; then
        pts=2; note="大包丢包率 ${loss}%，丢包较明显"
    else
        pts=3; note="大包丢包率 ${loss}%，丢包严重"
    fi
    echo "${pts}|${note}"
}

score_iperf_zero() {
    local zero=$1
    local total=$2
    local pts note ratio
    ratio=$(awk -v z="$zero" -v t="$total" 'BEGIN{ if(t==0){print 0} else {printf "%.0f", z/t*100} }')
    if [ "$zero" -le 1 ]; then
        pts=0; note="吞吐测试中断流采样点 ${zero} 个 (${ratio}%)，正常"
    elif [ "$zero" -le 3 ]; then
        pts=1; note="吞吐测试中断流采样点 ${zero} 个 (${ratio}%)，偶发断流"
    elif [ "$zero" -le 8 ]; then
        pts=2; note="吞吐测试中断流采样点 ${zero} 个 (${ratio}%)，频繁断流"
    else
        pts=3; note="吞吐测试中断流采样点 ${zero} 个 (${ratio}%)，持续大面积断流"
    fi
    echo "${pts}|${note}"
}

score_mtr_hop_diff() {
    local small_file=$1
    local big_file=$2
    local pts=0 note="未检测到明显路由/节点异常差异"

    if [ -f "$small_file" ] && [ -f "$big_file" ]; then
        local missing_hops missing_hops_small
        missing_hops=$(grep -c '???' "$big_file" 2>/dev/null)
        missing_hops_small=$(grep -c '???' "$small_file" 2>/dev/null)
        missing_hops=${missing_hops:-0}
        missing_hops_small=${missing_hops_small:-0}

        if [ "$missing_hops" -gt "$missing_hops_small" ]; then
            local extra=$((missing_hops - missing_hops_small))
            if [ "$extra" -ge 3 ]; then
                pts=2; note="大包 mtr 中新增 ${extra} 个无响应跳点，疑似大包路径受限"
            else
                pts=1; note="大包 mtr 中新增 ${extra} 个无响应跳点"
            fi
        fi
    fi
    echo "${pts}|${note}"
}

# ---------- 等级映射 ----------
grade_from_score() {
    local score=$1
    local max=$2
    local pct
    pct=$(awk -v s="$score" -v m="$max" 'BEGIN{ if(m==0){print 0} else {printf "%.0f", s/m*100} }')

    if [ "$pct" -le 15 ]; then
        echo "0|无明显优化|${GREEN}"
    elif [ "$pct" -le 40 ]; then
        echo "1|轻度嫌疑|${YELLOW}"
    elif [ "$pct" -le 70 ]; then
        echo "2|中度嫌疑|${YELLOW}"
    else
        echo "3|重度嫌疑|${RED}"
    fi
}

draw_bar() {
    local score=$1
    local max=$2
    local filled=$((score * 10 / max))
    local bar=""
    local i
    for ((i=0; i<10; i++)); do
        if [ "$i" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
    done
    echo "$bar"
}

# ---------- 生成报告 ----------
generate_report() {
    local report="$OUTDIR/report.txt"
    local total_score=0
    local max_score=0

    {
        echo "================================================================"
        echo " VPS 大小包优化测试报告"
        echo " 目标: $TARGET"
        echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================================"
        echo

        echo "--- Ping 对比 ---"
        avg_s="N/A"; loss_s="N/A"; avg_b="N/A"; loss_b="N/A"
        if [ -f "$OUTDIR/ping_small.log" ]; then
            IFS='|' read -r avg_s loss_s <<< "$(parse_ping_stats "$OUTDIR/ping_small.log")"
            echo "小包(${SMALL_SIZE}B): 平均延迟 ${avg_s} ms | 丢包率 ${loss_s}%"
        fi
        if [ -f "$OUTDIR/ping_big.log" ]; then
            IFS='|' read -r avg_b loss_b <<< "$(parse_ping_stats "$OUTDIR/ping_big.log")"
            echo "大包(${BIG_SIZE}B): 平均延迟 ${avg_b} ms | 丢包率 ${loss_b}%"
        fi
        echo

        zero_secs=0
        total_secs=0
        if [[ "$DO_IPERF" =~ ^[Yy]$ ]] && [ -f "$OUTDIR/iperf3.log" ]; then
            echo "--- iperf3 吞吐 ---"
            fwd=$(grep -E '\[SUM\].*sender' "$OUTDIR/iperf3.log" | head -1 | grep -Eo '[0-9.]+ [MGK]bits/sec' | head -1)
            echo "正向(本机->目标) 平均: ${fwd:-N/A}"
            if [[ "$IPERF_REVERSE" =~ ^[Yy]$ ]]; then
                rev=$(grep -E '\[SUM\].*sender' "$OUTDIR/iperf3.log" | tail -1 | grep -Eo '[0-9.]+ [MGK]bits/sec' | head -1)
                echo "反向(目标->本机) 平均: ${rev:-N/A}"
            fi
            zero_secs=$(grep -c '0.00 bits/sec' "$OUTDIR/iperf3.log")
            total_secs=$(grep -cE '\[SUM\]' "$OUTDIR/iperf3.log")
            echo "检测到 0 bits/sec 的采样点数量: $zero_secs / 约 $total_secs 个采样"
            echo
        fi

        echo "================================================================"
        echo " 大小包优化 - 评分明细"
        echo "================================================================"

        if [ "$avg_s" != "N/A" ] && [ "$avg_b" != "N/A" ]; then
            diff=$(awk -v a="$avg_s" -v b="$avg_b" 'BEGIN{printf "%.1f", b-a}')
            IFS='|' read -r pts note <<< "$(score_latency_diff "$diff")"
            total_score=$((total_score + pts)); max_score=$((max_score + 3))
            printf "[延迟差异]   %s/3  %s  %s\n" "$pts" "$(draw_bar "$pts" 3)" "$note"
        fi

        if [ "$loss_b" != "N/A" ]; then
            IFS='|' read -r pts note <<< "$(score_big_loss "$loss_b")"
            total_score=$((total_score + pts)); max_score=$((max_score + 3))
            printf "[大包丢包]   %s/3  %s  %s\n" "$pts" "$(draw_bar "$pts" 3)" "$note"
        fi

        if [[ "$DO_IPERF" =~ ^[Yy]$ ]] && [ "$total_secs" -gt 0 ]; then
            IFS='|' read -r pts note <<< "$(score_iperf_zero "$zero_secs" "$total_secs")"
            total_score=$((total_score + pts)); max_score=$((max_score + 3))
            printf "[持续吞吐]   %s/3  %s  %s\n" "$pts" "$(draw_bar "$pts" 3)" "$note"
        fi

        if [[ "$DO_MTR" =~ ^[Yy]$ ]]; then
            IFS='|' read -r pts note <<< "$(score_mtr_hop_diff "$OUTDIR/mtr_small.log" "$OUTDIR/mtr_big.log")"
            total_score=$((total_score + pts)); max_score=$((max_score + 2))
            printf "[路由差异]   %s/2  %s  %s\n" "$pts" "$(draw_bar "$pts" 2)" "$note"
        fi

        echo
        echo "================================================================"
        echo " 综合判定"
        echo "================================================================"

        if [ "$max_score" -eq 0 ]; then
            echo "有效测试项不足，无法给出评级，请至少完成 ping 测试。"
        else
            IFS='|' read -r glevel gname gcolor <<< "$(grade_from_score "$total_score" "$max_score")"
            pct=$(awk -v s="$total_score" -v m="$max_score" 'BEGIN{printf "%.0f", s/m*100}')

            echo -e "总分: ${total_score} / ${max_score}  (异常指数 ${pct}%)"
            echo
            case "$glevel" in
                0) echo -e "${GREEN}${BOLD}★ 大小包优化等级：无明显优化 (Lv.0)${NC}" ;;
                1) echo -e "${YELLOW}${BOLD}★ 大小包优化等级：轻度嫌疑 (Lv.1)${NC}" ;;
                2) echo -e "${YELLOW}${BOLD}★ 大小包优化等级：中度嫌疑 (Lv.2)${NC}" ;;
                3) echo -e "${RED}${BOLD}★ 大小包优化等级：重度嫌疑 (Lv.3)${NC}" ;;
            esac
            echo
            case "$glevel" in
                0) echo "小包/大包在延迟、丢包、吞吐表现上基本一致，未见明显的差异化处理。" ;;
                1) echo "个别指标出现轻微异常，可能是网络正常抖动，也可能存在轻度优化，建议多测几次交叉验证。" ;;
                2) echo "多项指标同时出现异常，大概率存在针对性的大小包优化或QoS限速，实际大流量体验会明显低于ping测速表现。" ;;
                3) echo "延迟、丢包、吞吐、路由等多个维度同时严重异常，基本可以确认存在大小包优化，ping/跑分数据不能代表真实使用体验。" ;;
            esac
        fi

        echo
        echo "(评分仅基于本次测试的启发式规则，供参考，建议结合原始日志与多次测试人工复核)"
        echo
        echo "详细日志文件位于: $OUTDIR/"
        echo "================================================================"
    } | tee "$report"
}

# ---------- 主流程 ----------
main() {
    check_deps
    ask_inputs

    echo
    line
    echo -e "${BOLD}开始测试...${NC}"
    line

    run_ping "$SMALL_SIZE" "small"
    run_ping "$BIG_SIZE" "big"

    if [[ "$DO_MTR" =~ ^[Yy]$ ]]; then
        run_mtr "$SMALL_SIZE" "small"
        run_mtr "$BIG_SIZE" "big"
    fi

    if [[ "$DO_IPERF" =~ ^[Yy]$ ]]; then
        run_iperf
    fi

    line
    echo -e "${BOLD}生成测试报告...${NC}"
    line
    generate_report

    echo
    echo -e "${GREEN}测试完成！所有结果已保存到目录: ${BOLD}$OUTDIR${NC}"
}

main
