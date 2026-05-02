#!/usr/bin/env bash
# =====================================================
#  模拟非常慢的网络下载脚本
#  总用时: 1小时 (3600秒)
#  进度条匀速走完，百分比精度 0.1%
# =====================================================
set -e
TOTAL_STEPS=1000
STEP_SLEEP=3.6      # 每步 3.6 秒
TOTAL_SECONDS=3600  # 1000 × 3.6 = 3600 秒 = 1小时
# 模拟下载的文件信息
FILE_NAME="very_large_file.iso"
FILE_SIZE="4.20 GB"
# 清屏并显示起始信息
clear
echo "============================================"
echo "   🐢 极慢网络下载模拟器"
echo "============================================"
echo ""
echo "  文件: $FILE_NAME"
echo "  大小: $FILE_SIZE"
echo "  预计用时: ${TOTAL_SECONDS} 秒（1小时）"
echo "  当前速度: 约 1.22 MB/s"
echo "  百分比精度: 0.1%"
echo ""
echo "============================================"
echo ""
# 进度条绘制函数
# 参数: percent_int (百分比的1000倍，0~1000，如 423=42.3%)
#       elapsed (秒, 整数), remaining (秒, 整数)
draw_progress() {
    local percent_int=$1
    local elapsed=$2
    local remaining=$3
    # 拆出整数和小数部分（如 423 → 42.3）
    local int_part=$(( percent_int / 10 ))
    local frac_part=$(( percent_int % 10 ))
    # 进度条宽度（50个字符）
    local bar_width=50
    # 计算填充格数: percent_int * bar_width / 1000，四舍五入
    local filled=$(( (percent_int * bar_width + 500) / 1000 ))
    local empty=$(( bar_width - filled ))
    [ $empty -lt 0 ] && empty=0
    # 构建进度条字符串
    local bar="["
    for ((i=0; i<filled; i++)); do
        bar+="█"
    done
    for ((i=0; i<empty; i++)); do
        bar+="░"
    done
    bar+="]"
    # 格式化时间
    local elapsed_min=$((elapsed / 60))
    local elapsed_sec=$((elapsed % 60))
    local remain_min=$((remaining / 60))
    local remain_sec=$((remaining % 60))
    # 显示当前下载速度（随时间缓慢波动，模拟真实网络）
    local speed
    speed=$(echo "scale=2; 1.22 + (($RANDOM % 100) - 50) / 100" | bc 2>/dev/null || echo "1.22")
    # 显示进度（格式: xx.x%）
    printf "\r  %s  %3d.%d%%  |  已用: %02d:%02d  剩余: %02d:%02d  速度: %.2f MB/s" \
        "$bar" "$int_part" "$frac_part" "$elapsed_min" "$elapsed_sec" "$remain_min" "$remain_sec" "$speed"
}
# 主循环：每步模拟下载一小部分
for ((step=1; step<=TOTAL_STEPS; step++)); do
    # 计算当前百分比（0~1000，表示 0.0%~100.0%）
    PERCENT_INT=$(( step * 1000 / TOTAL_STEPS ))
    # 计算已用时间（秒，整数）：step * 36 / 10 （因为 STEP_SLEEP=3.6 = 36/10）
    ELAPSED=$(( step * 36 / 10 ))
    REMAINING=$(( TOTAL_SECONDS - ELAPSED ))
    [ $REMAINING -lt 0 ] && REMAINING=0
    # 画进度条
    draw_progress "$PERCENT_INT" "$ELAPSED" "$REMAINING"
    # 前 999 步等待，最后一步直接完成
    if [ "$step" -lt "$TOTAL_STEPS" ]; then
        sleep "$STEP_SLEEP"
    fi
done
# 最终完成信息
echo ""
echo ""
echo "============================================"
echo "   ✅ 下载完成！"
echo "============================================"
echo ""
echo "  文件: $FILE_NAME"
echo "  大小: $FILE_SIZE"
echo "  总用时: 1 小时 0 分"
echo ""
echo "============================================"
