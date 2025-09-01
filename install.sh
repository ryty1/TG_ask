#!/bin/bash
set -euo pipefail

# install.sh
# 一键安装 userbot 到 /opt/tg_ask，创建 venv，安装依赖，注册 systemd userbot.service

# 运行者（如果用了 sudo，取 SUDO_USER；否则取当前 USER）
RUNNER_USER=${SUDO_USER:-$USER}

BOT_DIR="/opt/tg_ask"
ENV_FILE="$BOT_DIR/.env"
VENV_DIR="$BOT_DIR/venv"
SERVICE_FILE="/etc/systemd/system/userbot.service"
SCRIPT_URL="https://raw.githubusercontent.com/ryty1/TG_ask/main/userbot.py"
SCRIPT_PATH="$BOT_DIR/userbot.py"

# 安装前检查 Python 和 curl
check_and_install() {
    # 检查 Python
    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ 未找到 Python3，正在安装..."
        sudo apt-get update -y  >/dev/null 2>&1
        sudo apt-get install -y python3 python3-pip  >/dev/null 2>&1
        echo "✅ Python3 安装完成"
    else
        echo "✅ Python3 已安装"
    fi

    # 检查 curl
    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ 未找到 curl，正在安装..."
        sudo apt-get install -y curl  >/dev/null 2>&1
        echo "✅ curl 安装完成"
    else
        echo "✅ curl 已安装"
    fi
}


# 选择操作（安装/修改配置/卸载）
echo "请选择操作："
echo "1. 安装 TG快捷提醒"
echo "2. 修改 .env 配置"
echo "3. 卸载 TG快捷提醒"
echo "4. 返回 VIP 工具箱"
read -p "输入选项 [1-4]: " ACTION

case $ACTION in
1)
    # 在开始前检查 Python 和 curl
    check_and_install
    
    echo "安装目录：$BOT_DIR"
    echo "脚本将以用户：$RUNNER_USER 来拥有并运行"

    # 创建目录并设置权限
    sudo mkdir -p "$BOT_DIR"
    sudo chown -R "$RUNNER_USER:$RUNNER_USER" "$BOT_DIR"
    cd "$BOT_DIR" || { echo "无法切换到 $BOT_DIR"; exit 1; }

    # 下载 bot 脚本（保存为 userbot.py）
    echo "🔽 正在下载 bot 脚本..."
    if command -v curl >/dev/null 2>&1; then
        sudo -u "$RUNNER_USER" curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    elif command -v wget >/dev/null 2>&1; then
        sudo -u "$RUNNER_USER" wget -qO "$SCRIPT_PATH" "$SCRIPT_URL"
    else
        echo "❌ 未找到 curl 或 wget，请先安装其中一个工具。"
        exit 1
    fi

    if [ ! -s "$SCRIPT_PATH" ]; then
        echo "❌ 下载失败或文件为空：$SCRIPT_PATH"
        exit 1
    fi
    sudo chown "$RUNNER_USER:$RUNNER_USER" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ 脚本下载并保存为 $SCRIPT_PATH"

    # 交互式生成 .env（USER_FILE 固定为 user.json）
    echo
    echo "📝 请按提示输入 Bot 配置（将写入 $ENV_FILE）"
    read -p "BOT_TOKEN: " BOT_TOKEN
    read -p "群号ID (多个英文逗号分隔): " ALLOWED_GROUPS
    read -p "管理TGID (多个英文逗号分隔): " ADMIN_IDS
    read -p "触发关键字 (多个英文逗号分隔): " KEYWORDS

    cat > "$ENV_FILE" <<EOF
BOT_TOKEN=$BOT_TOKEN
ALLOWED_GROUPS=$ALLOWED_GROUPS
ADMIN_IDS=$ADMIN_IDS
KEYWORDS=$KEYWORDS
EOF

    sudo chown "$RUNNER_USER:$RUNNER_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "✅ 已生成 $ENV_FILE (权限 600)"

    # 创建虚拟环境（放在 /opt/tg_ask/venv）
    if [ ! -d "$VENV_DIR" ]; then
        echo "🔧 创建虚拟环境..."
        sudo -u "$RUNNER_USER" python3 -m venv "$VENV_DIR"
        echo "✅ 虚拟环境已创建：$VENV_DIR"
    fi

    # 在 venv 中升级 pip 并安装依赖
    echo "📦 在 venv 中安装依赖..."
    # 使用 venv 的 python 去安装，确保安装在 venv 中
    "$VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null 2>&1

    REQUIRED_PKG=("python-telegram-bot==20.7" "python-dotenv" "regex")
    for pkg in "${REQUIRED_PKG[@]}"; do
        PKG_NAME="${pkg%%=*}"
        if ! "$VENV_DIR/bin/python" -m pip show "$PKG_NAME" >/dev/null 2>&1; then
            echo "安装 $pkg ..."
            "$VENV_DIR/bin/python" -m pip install "$pkg" >/dev/null 2>&1
        else
            echo "已安装: $PKG_NAME （跳过）"
        fi
    done
    echo "✅ 依赖安装完成（均安装在 $VENV_DIR）"

    # 生成 systemd 服务文件 (userbot.service)，由 RUNNER_USER 运行
    echo "⚙️ 写入 systemd 服务：$SERVICE_FILE"
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Telegram UserBot
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/tg_ask
ExecStart=/opt/tg_ask/venv/bin/python /opt/tg_ask/userbot.py
Restart=on-failure
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload >/dev/null 2>&1
    sleep 2
    sudo systemctl enable userbot >/dev/null 2>&1
    sleep 2
    sudo systemctl restart userbot >/dev/null 2>&1

    echo
    echo "✅ 安装完成，服务已启动：userbot"
    echo "查看状态： sudo systemctl status userbot"
    echo "查看日志： sudo journalctl -u userbot -f"
    ;;
2)
    # 修改 .env 配置文件并重启服务（仅当有修改时）
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ 未找到 .env 文件，请先安装 userbot！"
        exit 1
    fi

    echo "📝 请按提示修改 Bot 配置（当前配置存储在 $ENV_FILE）"

    # 读取原有配置
    source "$ENV_FILE"

    CHANGED=0  # 标记是否有修改

    # 变量名到中文提示映射
    declare -A VAR_LABELS=(
        ["BOT_TOKEN"]="BOT_TOKEN"
        ["ALLOWED_GROUPS"]="群号ID (多个英文逗号分隔)"
        ["ADMIN_IDS"]="管理TGID (多个英文逗号分隔)"
        ["KEYWORDS"]="触发关键字 (多个英文逗号分隔)"
    )

    # 函数：询问是否修改
    update_var() {
        local var_name=$1
        local label=${VAR_LABELS[$var_name]:-$var_name}  # 映射中文提示
        local current_value=${!var_name}
        echo -e "\n当前 $label = $current_value"
        read -p "是否修改 $label? (y/n): " choice
        if [[ "$choice" == "y" ]]; then
            read -p "请输入新的 $label: " new_value
            echo "$var_name=$new_value" >> "$BOT_DIR/.env.tmp"
            CHANGED=1
        else
            echo "$var_name=$current_value" >> "$BOT_DIR/.env.tmp"
        fi
    }

    # 开始逐项修改
    rm -f "$BOT_DIR/.env.tmp"
    update_var "BOT_TOKEN"
    update_var "ALLOWED_GROUPS"
    update_var "ADMIN_IDS"
    update_var "KEYWORDS"

    # 覆盖原 env
    mv "$BOT_DIR/.env.tmp" "$ENV_FILE"
    echo "✅ 配置已保存：$ENV_FILE"

    # 如果有修改才重启服务
    if [[ $CHANGED -eq 1 ]]; then
        sudo systemctl restart userbot >/dev/null 2>&1
        echo "✅ 服务已重启：userbot"
    else
        echo "ℹ️ 配置未修改，服务无需重启"
    fi

    echo "查看状态： sudo systemctl status userbot"
    echo "查看日志： sudo journalctl -u userbot -f"
    ;;

3)
    # 一键卸载 userbot
    echo "⚠️ 警告：此操作会删除 userbot 服务和相关文件，请确认！"
    read -p "是否继续卸载 userbot? (y/n): " choice

    if [[ "$choice" != "y" ]]; then
        echo "❌ 已取消卸载"
        exit 1
    fi

    # 停止并禁用服务
    if [ -f "$SERVICE_FILE" ]; then
        echo "🛑 停止 userbot 服务..."
        sudo systemctl stop userbot >/dev/null 2>&1
        sleep 2
        sudo systemctl disable userbot >/dev/null 2>&1
        sleep 2

        
    else
        echo "✅ 未检测到 userbot 服务"
    fi

    # 删除虚拟环境和 bot 脚本
    echo "🗑 删除虚拟环境和 bot 脚本..."
    sudo rm -rf "$BOT_DIR" >/dev/null 2>&1

    echo "🗑 删除 userbot 服务文件..."
    sudo rm -f "$SERVICE_FILE" >/dev/null 2>&1

    # 重新加载 systemd
    echo "🔄 重新加载 systemd..."
    sudo systemctl daemon-reload >/dev/null 2>&1

    echo "✅ 卸载完成，已删除所有相关文件"
    ;;
*)
    echo "❌ 无效选项"
    exit 1
    ;;
4)
    bash <(curl -Ls https://raw.githubusercontent.com/ryty1/Checkin/refs/heads/main/1.sh)
    ;;
esac
