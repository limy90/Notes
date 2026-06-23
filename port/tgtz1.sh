#!/bin/bash

# Telegram通知模块

# 网络参数：防止重复source时的readonly冲突
if [[ -z "${TELEGRAM_MAX_RETRIES:-}" ]]; then
    readonly TELEGRAM_MAX_RETRIES=2
    readonly TELEGRAM_CONNECT_TIMEOUT=5
    readonly TELEGRAM_MAX_TIMEOUT=15
fi

telegram_is_enabled() {
    local enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE")
    [ "$enabled" = "true" ]
}

send_telegram_message() {
    local message="$1"
    local target_chat_id="${2:-}"  # 支持指定 chat_id

    local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    
    # 如果没有指定 chat_id，使用全局配置
    if [ -z "$target_chat_id" ]; then
        target_chat_id=$(jq -r '.notifications.telegram.chat_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    fi

    if [ -z "$bot_token" ] || [ -z "$target_chat_id" ]; then
        log_notification "Telegram配置不完整"
        return 1
    fi

    # URL编码：Telegram API要求空格和换行符必须编码
    local encoded_message=$(printf '%s' "$message" | sed 's/ /%20/g; s/\n/%0A/g')

    local retry_count=0

    # 重试机制
    while [ $retry_count -le $TELEGRAM_MAX_RETRIES ]; do
        local response=$(curl -s --connect-timeout $TELEGRAM_CONNECT_TIMEOUT --max-time $TELEGRAM_MAX_TIMEOUT -X POST \
            "https://api.telegram.org/bot${bot_token}/sendMessage" \
            -d "chat_id=${target_chat_id}" \
            -d "text=${encoded_message}" \
            -d "parse_mode=HTML" \
            2>/dev/null)

        # Telegram API成功响应的标准判断
        if echo "$response" | grep -q '"ok":true'; then
            if [ $retry_count -gt 0 ]; then
                log_notification "Telegram消息发送成功到 chat_id: $target_chat_id (重试第${retry_count}次后成功)"
            else
                log_notification "Telegram消息发送成功到 chat_id: $target_chat_id"
            fi
            return 0
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -le $TELEGRAM_MAX_RETRIES ]; then
            sleep 2  # 避免频繁请求被限流
        fi
    done

    log_notification "Telegram消息发送失败到 chat_id: $target_chat_id (已重试${TELEGRAM_MAX_RETRIES}次)"
    return 1
}

# 标准通知接口：主脚本通过此函数调用Telegram通知
telegram_send_status_notification() {
    local status_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$status_enabled" != "true" ]; then
        log_notification "Telegram状态通知未启用"
        return 1
    fi

    local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE")
    local server_name=$(jq -r '.notifications.telegram.server_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    
    if [ -z "$server_name" ]; then
        server_name=$(hostname)
    fi

    # 按 chat_id 分组发送
    local groups=$(group_ports_by_telegram_chat_id)
    local send_success=0
    local send_total=0
    
    # 检查是否有端口
    if [ -z "$groups" ]; then
        log_notification "Telegram 通知：没有配置有效的 chat_id 或端口"
        return 1
    fi
    
    while IFS='|' read -r chat_id_field ports_str; do
        if [ -z "$chat_id_field" ] || [ -z "$ports_str" ]; then
            continue
        fi
        
        send_total=$((send_total + 1))
        
        # 检查是否为管理员
        local is_admin=false
        local actual_chat_id="$chat_id_field"
        if [[ "$chat_id_field" == ADMIN:* ]]; then
            is_admin=true
            actual_chat_id="${chat_id_field#ADMIN:}"
        fi
        
        # 将逗号分隔的端口字符串转为数组
        IFS=',' read -ra ports_array <<< "$ports_str"
        
        # 生成消息（管理员标识）
        local message
        if [ "$is_admin" = true ]; then
            # 管理员消息：添加特殊标识
            local base_message=$(format_ports_status_message "$actual_chat_id" "$server_name" "${ports_array[@]}")
            message="<b>👑 管理员视图 - 全部端口</b>

$base_message"
        else
            # 普通用户消息
            message=$(format_ports_status_message "$actual_chat_id" "$server_name" "${ports_array[@]}")
        fi
        
        # 发送到对应的 chat_id
        if send_telegram_message "$message" "$actual_chat_id"; then
            if [ "$is_admin" = true ]; then
                log_notification "Telegram 管理员通知发送成功到 chat_id: $actual_chat_id (全部 ${#ports_array[@]} 个端口)"
            else
                log_notification "Telegram 通知发送成功到 chat_id: $actual_chat_id (端口: $ports_str)"
            fi
            send_success=$((send_success + 1))
        else
            log_notification "Telegram 通知发送失败到 chat_id: $actual_chat_id"
        fi
    done <<< "$groups"
    
    if [ $send_total -eq 0 ]; then
        log_notification "Telegram 通知：没有配置有效的 chat_id"
        return 1
    elif [ $send_success -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# 向后兼容
telegram_send_status() {
    telegram_send_status_notification
}

telegram_test() {
    echo -e "${BLUE}=== 发送测试消息 ===${NC}"
    echo

    if ! telegram_is_enabled; then
        echo -e "${RED}请先配置Telegram Bot信息${NC}"
        sleep 2
        return 1
    fi

    echo "正在发送测试消息..."

    # 使用真实状态消息测试：确保配置正确性
    if telegram_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

telegram_configure() {
    while true; do
        local status_notifications_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
        local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE")
        local admin_chat_id=$(jq -r '.notifications.telegram.admin_chat_id // ""' "$CONFIG_FILE")

        # 判断配置状态
        local config_status="[未配置]"
        if [ -n "$bot_token" ] && [ "$bot_token" != "" ] && [ "$bot_token" != "null" ]; then
            config_status="[已配置]"
        fi

        # 管理员状态
        local admin_status=""
        if [ -n "$admin_chat_id" ] && [ "$admin_chat_id" != "" ] && [ "$admin_chat_id" != "null" ]; then
            admin_status=" | 管理员[已配置]"
        fi

        # 判断开关状态
        local enable_status="[关闭]"
        if [ "$status_notifications_enabled" = "true" ]; then
            enable_status="[开启]"
        fi

        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

        echo -e "${BLUE}=== Telegram通知配置 ===${NC}"
        local interval_display="未设置"
        if [ -n "$status_interval" ] && [ "$status_interval" != "null" ]; then
            interval_display="每${status_interval}"
        fi
        echo -e "当前状态: ${enable_status} | ${config_status}${admin_status} | 状态通知: ${interval_display}"
        echo
        echo "1. 配置Bot信息 (Token + Chat ID + 服务器名称)"
        echo "2. 配置管理员 Chat ID（接收所有端口通知）"
        echo "3. 通知设置管理"
        echo "4. 发送测试消息"
        echo "5. 查看通知日志"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1) telegram_configure_bot ;;
            2) telegram_configure_admin ;;
            3) telegram_manage_settings ;;
            4) telegram_test ;;
            5) telegram_view_logs ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

telegram_configure_bot() {
    echo -e "${BLUE}=== 配置Telegram Bot信息 ===${NC}"
    echo
    echo -e "${GREEN}配置步骤说明:${NC}"
    echo "1. 与 @BotFather 对话创建机器人"
    echo "2. 获取 Bot Token (格式: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    echo "3. 获取 Chat ID (个人聊天或群组ID)"
    echo "4. 设置服务器名称用于标识"
    echo

    local current_token=$(jq -r '.notifications.telegram.bot_token' "$CONFIG_FILE")
    local current_chat_id=$(jq -r '.notifications.telegram.chat_id' "$CONFIG_FILE")
    local current_server_name=$(jq -r '.notifications.telegram.server_name' "$CONFIG_FILE")

    if [ "$current_token" != "" ] && [ "$current_token" != "null" ]; then
        # 安全显示：隐藏Token中间部分防止泄露
        local masked_token="${current_token:0:10}...${current_token: -10}"
        echo -e "${GREEN}当前Token: $masked_token${NC}"
    fi
    if [ "$current_chat_id" != "" ] && [ "$current_chat_id" != "null" ]; then
        echo -e "${GREEN}当前Chat ID: $current_chat_id${NC}"
    fi
    if [ "$current_server_name" != "" ] && [ "$current_server_name" != "null" ]; then
        echo -e "${GREEN}当前服务器名: $current_server_name${NC}"
    fi
    echo

    read -p "请输入Bot Token: " bot_token
    if [ -z "$bot_token" ]; then
        echo -e "${RED}Token不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}Token格式错误，请检查${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    read -p "请输入Chat ID: " chat_id
    if [ -z "$chat_id" ]; then
        echo -e "${RED}Chat ID不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}Chat ID格式错误，必须是数字${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    local default_server_name=$(hostname)
    read -p "请输入服务器名称 (回车默认: $default_server_name): " server_name
    if [ -z "$server_name" ]; then
        server_name="$default_server_name"
    fi

    # 原子性配置更新：确保配置完整性
    update_config ".notifications.telegram.bot_token = \"$bot_token\" |
        .notifications.telegram.chat_id = \"$chat_id\" |
        .notifications.telegram.server_name = \"$server_name\" |
        .notifications.telegram.enabled = true |
        .notifications.telegram.status_notifications.enabled = true"

    echo -e "${GREEN}基本配置保存成功！${NC}"
    echo

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval=$(select_notification_interval)

    update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    # 立即生效
    setup_telegram_notification_cron

    echo
    echo "正在发送测试通知..."

    # 配置完成后立即测试：验证配置正确性
    if telegram_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

telegram_configure_admin() {
    echo -e "${BLUE}=== 配置管理员 Chat ID ===${NC}"
    echo
    echo -e "${GREEN}说明:${NC}"
    echo "管理员 Chat ID 将接收所有端口的完整通知"
    echo "而普通用户只会收到自己配置端口的通知"
    echo "输入 0 可清除管理员配置"
    echo

    local current_admin=$(jq -r '.notifications.telegram.admin_chat_id // ""' "$CONFIG_FILE")
    if [ -n "$current_admin" ] && [ "$current_admin" != "" ] && [ "$current_admin" != "null" ]; then
        echo -e "${GREEN}当前管理员 Chat ID: $current_admin${NC}"
    else
        echo -e "${YELLOW}当前未配置管理员${NC}"
    fi
    echo

    read -p "请输入管理员 Chat ID (0=清除): " admin_chat_id

    if [ "$admin_chat_id" = "0" ]; then
        # 清除管理员配置
        update_config ".notifications.telegram.admin_chat_id = \"\""
        echo -e "${GREEN}管理员配置已清除${NC}"
    elif [ -z "$admin_chat_id" ]; then
        echo -e "${YELLOW}取消操作${NC}"
    elif ! [[ "$admin_chat_id" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}Chat ID格式错误，必须是数字${NC}"
    else
        update_config ".notifications.telegram.admin_chat_id = \"$admin_chat_id\""
        echo -e "${GREEN}管理员 Chat ID 配置成功: $admin_chat_id${NC}"
        echo -e "${YELLOW}管理员将接收所有端口的状态通知${NC}"
    fi

    sleep 2
}

telegram_manage_settings() {
    while true; do
        echo -e "${BLUE}=== 通知设置管理 ===${NC}"
        echo "1. 状态通知间隔"
        echo "2. 开启/关闭切换"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1) telegram_configure_interval ;;
            2) telegram_toggle_status_notifications ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

telegram_configure_interval() {
    local current_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval_display="未设置"
    if [ -n "$current_interval" ] && [ "$current_interval" != "null" ]; then
        interval_display="$current_interval"
    fi
    echo -e "当前间隔: $interval_display"
    echo
    local interval=$(select_notification_interval)

    update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    setup_telegram_notification_cron

    sleep 2
}

telegram_toggle_status_notifications() {
    local current_status=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")

    if [ "$current_status" = "true" ]; then
        update_config ".notifications.telegram.status_notifications.enabled = false"
        echo -e "${GREEN}状态通知已关闭${NC}"
    else
        update_config ".notifications.telegram.status_notifications.enabled = true"
        echo -e "${GREEN}状态通知已开启${NC}"
    fi

    setup_telegram_notification_cron
    sleep 2
}

telegram_view_logs() {
    echo -e "${BLUE}=== 通知日志 ===${NC}"
    echo

    local log_file="$CONFIG_DIR/logs/notification.log"
    if [ ! -f "$log_file" ]; then
        echo -e "${YELLOW}暂无通知日志${NC}"
        sleep 2
        return
    fi

    echo "最近20条通知日志:"
    echo "────────────────────────────────────────────────────────"
    tail -n 20 "$log_file"
    echo "────────────────────────────────────────────────────────"
    echo
    read -p "按回车键返回..."
}#!/bin/bash

# Telegram通知模块

# 网络参数：防止重复source时的readonly冲突
if [[ -z "${TELEGRAM_MAX_RETRIES:-}" ]]; then
    readonly TELEGRAM_MAX_RETRIES=2
    readonly TELEGRAM_CONNECT_TIMEOUT=5
    readonly TELEGRAM_MAX_TIMEOUT=15
fi

telegram_is_enabled() {
    local enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE")
    [ "$enabled" = "true" ]
}

# 发送消息给单个接收者
send_telegram_message() {
    local message="$1"
    local chat_id="$2"
    local bot_token="$3"

    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        return 1
    fi

    # URL编码：Telegram API要求空格和换行符必须编码
    local encoded_message=$(printf '%s' "$message" | sed 's/ /%20/g; s/\n/%0A/g')

    local retry_count=0

    # 重试机制
    while [ $retry_count -le $TELEGRAM_MAX_RETRIES ]; do
        local response=$(curl -s --connect-timeout $TELEGRAM_CONNECT_TIMEOUT --max-time $TELEGRAM_MAX_TIMEOUT -X POST \
            "https://api.telegram.org/bot${bot_token}/sendMessage" \
            -d "chat_id=${chat_id}" \
            -d "text=${encoded_message}" \
            -d "parse_mode=HTML" \
            2>/dev/null)

        # Telegram API成功响应的标准判断
        if echo "$response" | grep -q '"ok":true'; then
            if [ $retry_count -gt 0 ]; then
                log_notification "Telegram消息发送到 $chat_id 成功 (重试第${retry_count}次后成功)"
            fi
            return 0
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -le $TELEGRAM_MAX_RETRIES ]; then
            sleep 2  # 避免频繁请求被限流
        fi
    done

    log_notification "Telegram消息发送到 $chat_id 失败 (已重试${TELEGRAM_MAX_RETRIES}次)"
    return 1
}

# 发送消息给多个接收者（去重）
send_telegram_to_multiple() {
    local message="$1"
    local bot_token="$2"
    shift 2
    local chat_ids=("$@")
    
    if [ -z "$bot_token" ] || [ "$bot_token" = "null" ]; then
        log_notification "Telegram Bot Token未配置"
        return 1
    fi
    
    # 去重处理
    local -A unique_chat_ids
    for chat_id in "${chat_ids[@]}"; do
        if [ -n "$chat_id" ] && [ "$chat_id" != "null" ] && [ "$chat_id" != "" ]; then
            unique_chat_ids["$chat_id"]=1
        fi
    done
    
    local recipients=(${!unique_chat_ids[@]})
    
    if [ ${#recipients[@]} -eq 0 ]; then
        log_notification "没有有效的接收者"
        return 1
    fi
    
    local success_count=0
    local total_count=${#recipients[@]}
    
    for chat_id in "${recipients[@]}"; do
        if send_telegram_message "$message" "$chat_id" "$bot_token"; then
            success_count=$((success_count + 1))
        fi
    done
    
    if [ $success_count -gt 0 ]; then
        log_notification "Telegram消息发送成功 ($success_count/$total_count 个接收者)"
        return 0
    else
        log_notification "Telegram消息发送失败"
        return 1
    fi
}

# 发送端口专属通知（管理员+端口用户）
send_telegram_port_notification() {
    local port="$1"
    local message="$2"
    
    local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -z "$bot_token" ] || [ "$bot_token" = "null" ]; then
        log_notification "Telegram配置不完整"
        return 1
    fi
    
    local recipients=()
    
    # 1. 管理员ID（接收所有通知）
    local admin_chat_id=$(jq -r '.notifications.telegram.admin_chat_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$admin_chat_id" ] && [ "$admin_chat_id" != "null" ]; then
        recipients+=("$admin_chat_id")
    fi
    
    # 2. 端口专属用户ID
    local port_chat_id=$(jq -r ".ports.\"$port\".telegram_chat_id // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$port_chat_id" ] && [ "$port_chat_id" != "null" ]; then
        recipients+=("$port_chat_id")
    fi
    
    if [ ${#recipients[@]} -eq 0 ]; then
        log_notification "端口 $port 没有配置接收者"
        return 1
    fi
    
    send_telegram_to_multiple "$message" "$bot_token" "${recipients[@]}"
}

# 标准通知接口：主脚本通过此函数调用Telegram通知
telegram_send_status_notification() {
    local status_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$status_enabled" != "true" ]; then
        log_notification "Telegram状态通知未启用"
        return 1
    fi
    
    local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -z "$bot_token" ] || [ "$bot_token" = "null" ]; then
        log_notification "Telegram配置不完整"
        return 1
    fi
    
    local server_name=$(jq -r '.notifications.telegram.server_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "$(hostname)")
    local message=$(format_status_message "$server_name")
    
    # 收集所有接收者（自动去重）
    local recipients=()
    
    # 管理员
    local admin_chat_id=$(jq -r '.notifications.telegram.admin_chat_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$admin_chat_id" ] && [ "$admin_chat_id" != "null" ]; then
        recipients+=("$admin_chat_id")
    fi
    
    # 所有端口的专属用户
    local active_ports=($(get_active_ports))
    for port in "${active_ports[@]}"; do
        local port_chat_id=$(jq -r ".ports.\"$port\".telegram_chat_id // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ -n "$port_chat_id" ] && [ "$port_chat_id" != "null" ]; then
            recipients+=("$port_chat_id")
        fi
    done
    
    if [ ${#recipients[@]} -eq 0 ]; then
        log_notification "没有配置接收者"
        return 1
    fi
    
    if send_telegram_to_multiple "$message" "$bot_token" "${recipients[@]}"; then
        log_notification "Telegram状态通知发送成功"
        return 0
    else
        log_notification "Telegram状态通知发送失败"
        return 1
    fi
}

# 向后兼容
telegram_send_status() {
    telegram_send_status_notification
}

telegram_test() {
    echo -e "${BLUE}=== 发送测试消息 ===${NC}"
    echo

    if ! telegram_is_enabled; then
        echo -e "${RED}请先配置Telegram Bot信息${NC}"
        sleep 2
        return 1
    fi

    echo "正在发送测试消息..."

    # 使用真实状态消息测试：确保配置正确性
    if telegram_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

telegram_configure() {
    while true; do
        local status_notifications_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
        local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE")
        local admin_chat_id=$(jq -r '.notifications.telegram.admin_chat_id // ""' "$CONFIG_FILE")

        # 判断配置状态
        local config_status="[未配置]"
        if [ -n "$bot_token" ] && [ "$bot_token" != "" ] && [ "$bot_token" != "null" ] && \
           [ -n "$admin_chat_id" ] && [ "$admin_chat_id" != "" ] && [ "$admin_chat_id" != "null" ]; then
            config_status="[已配置]"
        fi

        # 判断开关状态
        local enable_status="[关闭]"
        if [ "$status_notifications_enabled" = "true" ]; then
            enable_status="[开启]"
        fi

        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

        echo -e "${BLUE}=== Telegram通知配置 ===${NC}"
        local interval_display="未设置"
        if [ -n "$status_interval" ] && [ "$status_interval" != "null" ]; then
            interval_display="每${status_interval}"
        fi
        echo -e "当前状态: ${enable_status} | ${config_status} | 状态通知: ${interval_display}"
        echo
        echo "1. 配置Bot信息 (Token + 管理员Chat ID + 服务器名称)"
        echo "2. 管理端口专属接收人"
        echo "3. 通知设置管理"
        echo "4. 发送测试消息"
        echo "5. 查看通知日志"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1) telegram_configure_bot ;;
            2) telegram_manage_port_recipients ;;
            3) telegram_manage_settings ;;
            4) telegram_test ;;
            5) telegram_view_logs ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

telegram_configure_bot() {
    echo -e "${BLUE}=== 配置Telegram Bot信息 ===${NC}"
    echo
    echo -e "${GREEN}配置步骤说明:${NC}"
    echo "1. 与 @BotFather 对话创建机器人"
    echo "2. 获取 Bot Token (格式: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    echo "3. 获取管理员 Chat ID（管理员接收所有端口通知）"
    echo "4. 设置服务器名称用于标识"
    echo

    local current_token=$(jq -r '.notifications.telegram.bot_token' "$CONFIG_FILE")
    local current_admin_chat_id=$(jq -r '.notifications.telegram.admin_chat_id' "$CONFIG_FILE")
    local current_server_name=$(jq -r '.notifications.telegram.server_name' "$CONFIG_FILE")

    if [ "$current_token" != "" ] && [ "$current_token" != "null" ]; then
        # 安全显示：隐藏Token中间部分防止泄露
        local masked_token="${current_token:0:10}...${current_token: -10}"
        echo -e "${GREEN}当前Token: $masked_token${NC}"
    fi
    if [ "$current_admin_chat_id" != "" ] && [ "$current_admin_chat_id" != "null" ]; then
        echo -e "${GREEN}当前管理员Chat ID: $current_admin_chat_id${NC}"
    fi
    if [ "$current_server_name" != "" ] && [ "$current_server_name" != "null" ]; then
        echo -e "${GREEN}当前服务器名: $current_server_name${NC}"
    fi
    echo

    read -p "请输入Bot Token: " bot_token
    if [ -z "$bot_token" ]; then
        echo -e "${RED}Token不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}Token格式错误，请检查${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    read -p "请输入管理员Chat ID（接收所有端口通知）: " admin_chat_id
    if [ -z "$admin_chat_id" ]; then
        echo -e "${RED}管理员Chat ID不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$admin_chat_id" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}Chat ID格式错误，必须是数字${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    local default_server_name=$(hostname)
    read -p "请输入服务器名称 (回车默认: $default_server_name): " server_name
    if [ -z "$server_name" ]; then
        server_name="$default_server_name"
    fi

    # 原子性配置更新：确保配置完整性
    update_config ".notifications.telegram.bot_token = \"$bot_token\" |
        .notifications.telegram.chat_id = \"$admin_chat_id\" |
        .notifications.telegram.admin_chat_id = \"$admin_chat_id\" |
        .notifications.telegram.server_name = \"$server_name\" |
        .notifications.telegram.enabled = true |
        .notifications.telegram.status_notifications.enabled = true"

    echo -e "${GREEN}基本配置保存成功！${NC}"
    echo

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval=$(select_notification_interval)

    update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    # 立即生效
    setup_telegram_notification_cron

    echo
    echo "正在发送测试通知..."

    # 配置完成后立即测试：验证配置正确性
    if telegram_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

telegram_manage_port_recipients() {
    echo -e "${BLUE}=== 管理端口专属接收人 ===${NC}"
    echo
    
    local active_ports=($(get_active_ports))
    if [ ${#active_ports[@]} -eq 0 ]; then
        echo -e "${YELLOW}暂无监控端口${NC}"
        sleep 2
        return
    fi
    
    echo "当前监控端口及接收人配置："
    echo "────────────────────────────────────────────────────────"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local port_chat_id=$(jq -r ".ports.\"$port\".telegram_chat_id // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        local display_chat_id="未配置"
        if [ -n "$port_chat_id" ] && [ "$port_chat_id" != "null" ] && [ "$port_chat_id" != "" ]; then
            display_chat_id="$port_chat_id"
        fi
        echo "$((i+1)). 端口 $port - Chat ID: $display_chat_id"
    done
    echo "────────────────────────────────────────────────────────"
    echo
    
    read -p "请选择要配置的端口 [1-${#active_ports[@]}] (0返回): " port_choice
    
    if [ "$port_choice" = "0" ]; then
        return
    fi
    
    if ! [[ "$port_choice" =~ ^[0-9]+$ ]] || [ "$port_choice" -lt 1 ] || [ "$port_choice" -gt ${#active_ports[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        sleep 1
        telegram_manage_port_recipients
        return
    fi
    
    local selected_port=${active_ports[$((port_choice-1))]}
    local current_chat_id=$(jq -r ".ports.\"$selected_port\".telegram_chat_id // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
    
    echo
    echo -e "${GREEN}配置端口 $selected_port 的专属接收人${NC}"
    if [ -n "$current_chat_id" ] && [ "$current_chat_id" != "null" ] && [ "$current_chat_id" != "" ]; then
        echo "当前Chat ID: $current_chat_id"
    else
        echo "当前Chat ID: 未配置"
    fi
    echo
    echo "请输入新的Chat ID (留空删除配置，0返回):"
    read -p "Chat ID: " new_chat_id
    
    if [ "$new_chat_id" = "0" ]; then
        telegram_manage_port_recipients
        return
    fi
    
    if [ -z "$new_chat_id" ]; then
        # 删除配置
        update_config ".ports.\"$selected_port\".telegram_chat_id = \"\""
        echo -e "${GREEN}端口 $selected_port 的专属接收人已删除${NC}"
    else
        if ! [[ "$new_chat_id" =~ ^-?[0-9]+$ ]]; then
            echo -e "${RED}Chat ID格式错误，必须是数字${NC}"
            sleep 2
            telegram_manage_port_recipients
            return
        fi
        
        update_config ".ports.\"$selected_port\".telegram_chat_id = \"$new_chat_id\""
        echo -e "${GREEN}端口 $selected_port 的专属接收人已设置为: $new_chat_id${NC}"
    fi
    
    sleep 2
    telegram_manage_port_recipients
}

telegram_manage_settings() {
    while true; do
        echo -e "${BLUE}=== 通知设置管理 ===${NC}"
        echo "1. 状态通知间隔"
        echo "2. 开启/关闭切换"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1) telegram_configure_interval ;;
            2) telegram_toggle_status_notifications ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

telegram_configure_interval() {
    local current_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval_display="未设置"
    if [ -n "$current_interval" ] && [ "$current_interval" != "null" ]; then
        interval_display="$current_interval"
    fi
    echo -e "当前间隔: $interval_display"
    echo
    local interval=$(select_notification_interval)

    update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    setup_telegram_notification_cron

    sleep 2
}

telegram_toggle_status_notifications() {
    local current_status=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")

    if [ "$current_status" = "true" ]; then
        update_config ".notifications.telegram.status_notifications.enabled = false"
        echo -e "${GREEN}状态通知已关闭${NC}"
    else
        update_config ".notifications.telegram.status_notifications.enabled = true"
        echo -e "${GREEN}状态通知已开启${NC}"
    fi

    setup_telegram_notification_cron
    sleep 2
}

telegram_view_logs() {
    echo -e "${BLUE}=== 通知日志 ===${NC}"
    echo

    local log_file="$CONFIG_DIR/logs/notification.log"
    if [ ! -f "$log_file" ]; then
        echo -e "${YELLOW}暂无通知日志${NC}"
        sleep 2
        return
    fi

    echo "最近20条通知日志:"
    echo "────────────────────────────────────────────────────────"
    tail -n 20 "$log_file"
    echo "────────────────────────────────────────────────────────"
    echo
    read -p "按回车键返回..."
}