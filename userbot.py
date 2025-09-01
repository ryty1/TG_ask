import regex
import json
import os
import asyncio
from telegram import Update, MessageEntity
from telegram.constants import ParseMode
from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes, MessageHandler, filters
from dotenv import load_dotenv
load_dotenv()

# ---------- 加载环境变量 ----------
def get_env_list(key, cast=str):
    val = os.getenv(key)
    if not val:
        return []
    return [cast(x.strip()) for x in val.split(",") if x.strip()]

# ---------- env环境变量 ----------
BOT_TOKEN = os.getenv("BOT_TOKEN")
if not BOT_TOKEN:
    raise ValueError("❌ BOT_TOKEN 未设置！请在 .env 文件中添加 BOT_TOKEN")
    
ALLOWED_GROUPS = get_env_list("ALLOWED_GROUPS", int)
ADMIN_IDS = get_env_list("ADMIN_IDS", int)
KEYWORDS = get_env_list("KEYWORDS", str)

USER_BEFORE_RESULT = 0.5  # 用户命令提前删除时间（秒）
USER_FILE = "user.json"

# ---------- 用户数据 ----------
def load_user_data():
    if not os.path.exists(USER_FILE):
        return {}
    with open(USER_FILE, "r", encoding="utf-8") as f:
        return json.load(f)

def save_user_data(data):
    with open(USER_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

# 计算字符串的 UTF-16 长度（Telegram 用）
def utf16_length(s):
    return sum(1 if ord(c) <= 0xFFFF else 2 for c in s)

async def build_text_mention_async(chat, data):
    text = ""
    entities = []
    offset = 0
    separator = " · "  # 用户之间的分隔符
    for u in data.values():
        user_id = u["id"]
        try:
            member = await chat.get_member(user_id)
            user_obj = member.user
            full_name = f"{user_obj.first_name} {user_obj.last_name or ''}".strip()
            # 优先 full_name > username > ID
            display_name = u.get("full_name") or user_obj.username or full_name or str(user_id)
        except Exception:
            user_obj = None
            display_name = u.get("full_name") or u.get("username") or str(user_id)

        text += display_name + separator
        if user_obj:
            entities.append(
                MessageEntity(
                    type="text_mention",
                    offset=offset,
                    length=utf16_length(display_name),  # 注意这里
                    user=user_obj
                )
            )
        offset += utf16_length(display_name) + utf16_length(separator)
    return text.strip(), entities


# ---------- 发送并自动删除 ----------
async def send_and_auto_delete(chat, text, delay, user_msg=None, entities=None, parse_mode=None):
    msg = await chat.send_message(text=text, entities=entities, parse_mode=parse_mode)

    async def _delete_later():
        try:
            await asyncio.sleep(delay - USER_BEFORE_RESULT)
            if user_msg:
                try:
                    await user_msg.delete()
                except:
                    pass
            await asyncio.sleep(USER_BEFORE_RESULT)
            try:
                await msg.delete()
            except:
                pass
        except Exception as e:
            print(f"删除任务出错: {e}")

    asyncio.create_task(_delete_later())

# ---------- /ask 命令 ----------
async def ask_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.message.chat
    user_msg = update.message
    sender_id = update.effective_user.id

    if chat.id not in ALLOWED_GROUPS:
        await send_and_auto_delete(chat, "❌ 此命令仅限指定群使用", 30, user_msg=user_msg)
        return

    args = context.args
    data = load_user_data()

    # /ask → 提及名单
    if not args:
        if not data:
            await send_and_auto_delete(chat, "❌ 当前名单为空", 30, user_msg=user_msg)
            return
        text, entities = await build_text_mention_async(chat, data)
        # 20分钟后自动删除
        # await send_and_auto_delete(chat, text, 1200, entities=entities, user_msg=user_msg)

        # 不自动删除
        await chat.send_message(text, entities=entities)

        return

    sub = args[0].lower()

    # /ask add <ID>
    if sub == "add" and len(args) == 2 and args[1].isdigit():
        if sender_id not in ADMIN_IDS:
            await send_and_auto_delete(chat, "❌ 你没有权限添加用户", 30, user_msg=user_msg)
            return
        user_id = int(args[1])


        # 先检查是否已存在
        if str(user_id) in data:
            display_name = data[str(user_id)].get("full_name") or data[str(user_id)].get("username") or user_id
            await send_and_auto_delete(chat, f"ℹ️ 用户已在名单中: {display_name}", 30, user_msg=user_msg)
            return

        # 不存在才添加
        data[str(user_id)] = {"id": user_id, "username": None, "full_name": None}
        try:
            member = await chat.get_member(user_id)
            user_obj = member.user
            username = user_obj.username or None
            # 如果 full_name 已经存在则保留，否则尝试获取
            full_name = f"{user_obj.first_name} {user_obj.last_name or ''}".strip()
            data[str(user_id)]["full_name"] = full_name
            data[str(user_id)]["username"] = username or data[str(user_id)].get("username")
        except Exception:
            pass

        save_user_data(data)
        display_name = data[str(user_id)].get("full_name") or data[str(user_id)].get("username") or user_id
        await send_and_auto_delete(chat, f"✅ 添加成功: {display_name}", 60, user_msg=user_msg)
        return

    # /ask del <ID>
    if sub == "del" and len(args) == 2 and args[1].isdigit():
        if sender_id not in ADMIN_IDS:
            await send_and_auto_delete(chat, "❌ 你没有权限删除用户", 30, user_msg=user_msg)
            return
        user_id = int(args[1])
        if str(user_id) not in data:
            await send_and_auto_delete(chat, "ℹ️ 用户不在名单中", 30, user_msg=user_msg)
            return
        data.pop(str(user_id))
        save_user_data(data)
        await send_and_auto_delete(chat, f"✅ 删除成功: {user_id}", 60, user_msg=user_msg)
        return

    # /ask m → 显示名单
    if sub == "m":
        if not data:
            await send_and_auto_delete(chat, "❌ 当前名单为空", 30, user_msg=user_msg)
            return

        msg_lines = ["📋 当前名单："]
        for u in data.values():
            display_name = u.get("username") or str(u["id"])
            msg_lines.append(f"<code>{display_name}</code> | <code>{u['id']}</code>")
        msg_text = "\n".join(msg_lines)
        await send_and_auto_delete(chat, msg_text, 120, user_msg=user_msg, parse_mode=ParseMode.HTML)
        return

# ---------- 私聊补全 full_name ----------
async def private_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    full_name = f"{user.first_name} {user.last_name or ''}".strip()
    data = load_user_data()
    # 遍历数据库，如果 username 或 ID 匹配，就补全 full_name
    updated = False
    for u in data.values():
        if u.get("username") == user.username or u.get("id") == user.id:
            u["full_name"] = full_name
            updated = True
    if updated:
        save_user_data(data)
        await update.message.reply_text(f"✅ 已更新你的全名为: {full_name}")

# ---------- 自动触发关键词 ----------
async def keyword_listener(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.message.chat
    user_msg = update.message

    if chat.id not in ALLOWED_GROUPS:
        return

    text = update.message.text or ""
    if all(k in text for k in KEYWORDS):
        data = load_user_data()
        if not data:
            return
        text_msg, entities = await build_text_mention_async(chat, data)
        await send_and_auto_delete(chat, text_msg, 180, entities=entities, user_msg=user_msg)

# ---------- 主函数 ----------
def main():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("ask", ask_command))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, keyword_listener))
    # 私聊补全 full_name
   
    app.add_handler(MessageHandler(filters.ChatType.PRIVATE & ~filters.COMMAND, private_message))
    print("✅ Bot 已启动")
    app.run_polling()

if __name__ == "__main__":
    main()

