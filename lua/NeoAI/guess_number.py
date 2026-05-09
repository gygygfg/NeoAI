#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""猜数字游戏 - 增强版✨"""

import random
import json
import os

# ---------- 配置 ----------
HISTORY_FILE = "guess_history.json"

# ---------- 工具函数 ----------

def load_history():
    """加载历史记录"""
    if os.path.exists(HISTORY_FILE):
        try:
            with open(HISTORY_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return []
    return []


def save_history(history):
    """保存历史记录"""
    with open(HISTORY_FILE, "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False, indent=2)


def get_player_name():
    """获取玩家名字"""
    name = input("请输入你的名字: ").strip()
    return name if name else "匿名玩家"


def choose_difficulty():
    """选择难度"""
    difficulties = {
        "1": {"name": "简单", "min": 1, "max": 50, "max_attempts": 20, "score_mult": 1},
        "2": {"name": "中等", "min": 1, "max": 100, "max_attempts": 10, "score_mult": 2},
        "3": {"name": "困难", "min": 1, "max": 200, "max_attempts": 7, "score_mult": 5},
    }

    print("\n--- 选择难度 ---")
    for key, diff in difficulties.items():
        print(f"{key}. {diff['name']} (范围: {diff['min']}-{diff['max']}, 最大次数: {diff['max_attempts']})")

    while True:
        choice = input("请输入选项 (1/2/3): ").strip()
        if choice in difficulties:
            print(f"你选择了「{difficulties[choice]['name']}」难度！\n")
            return difficulties[choice]
        print("无效选项，请重新选择！")


def calculate_score(attempts, difficulty):
    """计算得分"""
    base_score = 100
    used_attempts_ratio = attempts / difficulty["max_attempts"]
    if used_attempts_ratio <= 0.3:
        bonus = 100  # 完美
    elif used_attempts_ratio <= 0.6:
        bonus = 50   # 优秀
    elif used_attempts_ratio <= 0.9:
        bonus = 20   # 不错
    else:
        bonus = 0    # 惊险过关

    score = (base_score + bonus) * difficulty["score_mult"]
    return score


def show_history(player_name):
    """显示历史记录"""
    history = load_history()
    player_records = [r for r in history if r["player"] == player_name]

    if not player_records:
        print(f"\n📊 {player_name}，你还没有游戏记录哦！")
        return

    print(f"\n📊 {player_name} 的历史记录:")
    print("-" * 50)
    for i, record in enumerate(player_records[-5:], 1):
        print(f"{i}. 🏆 {record['difficulty']}难度 | 数字{record['secret']} | "
              f"尝试{record['attempts']}次 | 得分:{record['score']}")
    total_games = len(player_records)
    avg_attempts = sum(r["attempts"] for r in player_records) / total_games
    total_score = sum(r["score"] for r in player_records)
    print("-" * 50)
    print(f"共 {total_games} 局 | 平均 {avg_attempts:.1f} 次/局 | 总分: {total_score}")


# ---------- 核心游戏逻辑 ----------

def play_game():
    """主游戏逻辑 - 增强版"""
    print("=" * 50)
    print("🎮  猜数字游戏 (增强版)")
    print("=" * 50)

    player_name = get_player_name()

    # 显示历史记录
    show_history(player_name)

    difficulty = choose_difficulty()
    secret = random.randint(difficulty["min"], difficulty["max"])
    attempts = 0
    hint_used = 0      # 使用提示次数
    hints_available = 3  # 可用提示次数

    min_val, max_val = difficulty["min"], difficulty["max"]
    print(f"我已想好一个 {min_val}~{max_val} 之间的数字！")
    print(f"你有 {difficulty['max_attempts']} 次机会，加油！\n")

    while attempts < difficulty["max_attempts"]:
        remaining = difficulty["max_attempts"] - attempts
        print(f"💡 剩余机会: {remaining} | 已用提示: {hint_used}/{hints_available}")

        cmd = input("请输入数字 (或输入 'h' 获取提示, 'q' 退出): ").strip()

        # --- 提示功能 ---
        if cmd.lower() == "h":
            if hint_used >= hints_available:
                print("❌ 提示次数已用完！\n")
                continue
            hint_used += 1
            if secret % 2 == 0:
                print(f"🔍 提示: 这个数字是【偶数】")
            else:
                print(f"🔍 提示: 这个数字是【奇数】")
            if attempts > 0:
                # 再给一个范围提示
                low_guess = secret - random.randint(1, 10)
                high_guess = secret + random.randint(1, 10)
                low_guess = max(min_val, low_guess)
                high_guess = min(max_val, high_guess)
                print(f"🔍 额外提示: 数字在 {low_guess}~{high_guess} 之间")
            print()
            continue

        # --- 退出功能 ---
        if cmd.lower() in ("q", "quit", "exit"):
            print(f"\n😢 真可惜，答案是 {secret}... 下次再见！")
            return

        # --- 猜测逻辑 ---
        try:
            guess = int(cmd)
        except ValueError:
            print("请输入有效数字！或输入 'h' 获取提示。\n")
            continue

        attempts += 1

        if guess < min_val or guess > max_val:
            print(f"请输入 {min_val}~{max_val} 之间的数字！\n")
            continue

        if guess < secret:
            print("⬆️  太小了！")
        elif guess > secret:
            print("⬇️  太大了！")
        else:
            score = calculate_score(attempts, difficulty)
            print(f"\n🎉🎉🎉 恭喜 {player_name}，猜对了！")
            print(f"数字是 {secret}，用了 {attempts} 次！")
            print(f"🏆 得分: {score}")

            # 保存记录
            record = {
                "player": player_name,
                "difficulty": difficulty["name"],
                "secret": secret,
                "attempts": attempts,
                "hint_used": hint_used,
                "score": score,
            }
            history = load_history()
            history.append(record)
            save_history(history)
            return

        # 接近提示
        diff = abs(guess - secret)
        if diff <= 5:
            print("🔥 非常接近了！")
        elif diff <= 10:
            print("⚡ 已经很近了！")
        elif diff <= 20:
            print("🌤️ 还有点距离")

        print()

    # 机会用尽
    print(f"😭 机会用完了！答案是 {secret}")
    print("下次加油！💪\n")


def main():
    """主函数"""
    while True:
        play_game()
        again = input("\n🔄 再来一局？(y/n): ").strip().lower()
        if again not in ("y", "yes", "是", "再来"):
            break
        print()
    print("\n感谢游玩！期待你下次挑战！👋")


if __name__ == "__main__":
    main()
