#!/usr/bin/env bash
# NeoAI CI 不变量门禁（秒级、离线、无依赖，仅需 grep）。
#
# 校验仓库级硬性约定（见 AGENTS.md / styleGuide.md）：
#   1. 非测试代码不得遗留 TODO / FIXME / HACK / XXX 标记。
#   2. 事件名必须引用 kernel/events.lua 常量，禁止 event_bus.(emit|on|once) 字面量事件名。
#   3. 业务代码禁止直接 require("NeoAI.services.*")，须经 kernel.services.use()
#      （services/ 自身、plugins/ 组合根、init.lua 入口、lualine 第三方集成为既定 allowlist）。
#
# 用法：bash scripts/ci_invariants.sh
# 退出码：0 = 全部通过；1 = 存在违规（违规明细打印到 stdout）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

fail=0

section() { printf '\n== %s ==\n' "$1"; }

# 收集非测试的 Lua 源文件（测试目录排除，约定仅约束业务代码）。
mapfile -t SRC < <(find lua -name '*.lua' -not -path '*/tests/*' | sort)

# ---------- 不变量 1：无 TODO/FIXME/HACK/XXX ----------
section "不变量 1：非测试代码无 TODO/FIXME/HACK/XXX"
viol_1=$(grep -nE '\-\-[[:space:]]*(TODO|FIXME|HACK|XXX)([[:space:]:]|$)' "${SRC[@]}" 2>/dev/null || true)
if [ -n "$viol_1" ]; then
  echo "$viol_1"
  echo "FAIL: 发现 TODO/FIXME/HACK/XXX 标记（应清除或转为 issue 跟踪）"
  fail=1
else
  echo "OK: 无遗留标记"
fi

# ---------- 不变量 2：禁止 event_bus 字面量事件名 ----------
section "不变量 2：event_bus.(emit|on|once) 禁止字面量事件名"
viol_2=$(grep -nE 'event_bus\.(emit|on|once)[[:space:]]*\([[:space:]]*["'"'"']' "${SRC[@]}" 2>/dev/null || true)
if [ -n "$viol_2" ]; then
  echo "$viol_2"
  echo "FAIL: 事件名须用 kernel/events.lua 常量，禁止硬编码字符串"
  fail=1
else
  echo "OK: 无硬编码事件名"
fi

# ---------- 不变量 3：业务代码禁止直接 require services.* ----------
section "不变量 3：业务代码禁止直接 require(\"NeoAI.services.*\")"
viol_3=$(grep -nE 'require\("NeoAI\.services' "${SRC[@]}" 2>/dev/null \
  | grep -v '^lua/NeoAI/services/' \
  | grep -v '^lua/NeoAI/plugins/' \
  | grep -v '^lua/NeoAI/init.lua' \
  | grep -v '^lua/lualine/extensions/neoai.lua' || true)
if [ -n "$viol_3" ]; then
  echo "$viol_3"
  echo "FAIL: 业务代码须经 kernel.services.use() 访问服务，禁止直接 require"
  fail=1
else
  echo "OK: 无直接 require services.*（allowlist：services/、plugins/、init.lua、lualine 集成）"
fi

# ---------- 不变量 4：安全边界禁止由字符静态判定提供 ----------
# 依据：docs/sandbox.md 核心不变量 6 / AGENTS.md 约定 9。字符串/正则/命令名黑名单判定的是
# 命令「长什么样」，而非进程「做了什么」，实测双向失效（`echo 'curl x | sh'` 被误拦，
# `| $SH`、`ba""sh`、`eval "$(curl …)"` 全部漏拦）。新增拒绝必须落在内核/运行时强制层：
# seccomp 基线、capability 档位、命名空间与设备隔离、cgroup 资源域与 cgroup.kill、网络门禁、
# 人工审批。危险二进制以「所需被剥夺的 syscall/capability」定义，不以名字定义。
section "不变量 4：安全边界禁止由字符静态判定提供"
viol_4=""
# 4a) 禁止重建「命令名黑名单」式的硬拒表（如旧 DENY_BINS / CAP_GATED_BINS）。
#     允许的文件：risk.lua 的形迹表（advisory）与 exec_guard.lua 的能力类别表（syscall 层）。
viol_4a=$(grep -nE '^\s*local\s+(DENY_BINS|CAP_GATED_BINS|DENY_COMMANDS|HARD_DENY_BINS)\s*=' "${SRC[@]}" 2>/dev/null || true)
[ -n "$viol_4a" ] && viol_4="$viol_4$viol_4a"$'\n'
# 4b) 禁止把 risk.deny_reason 的返回值直接用于拒绝执行。
#     唯一允许的调用点在 wrapper.lua 的 text_guard="enforce" 应急回滚分支。
viol_4b=$(grep -nE 'deny_reason\(' "${SRC[@]}" 2>/dev/null \
  | grep -v '^lua/NeoAI/sandbox/review/risk.lua:' \
  | grep -v '^lua/NeoAI/sandbox/execution/wrapper.lua:' || true)
[ -n "$viol_4b" ] && viol_4="$viol_4$viol_4b"$'\n'
# 4c) 禁止在沙箱门禁里以 async.reject 表达「命令文本命中」类拒绝。
viol_4c=$(grep -nE 'async\.reject\(.*(沙箱硬拒绝|KERNEL_COMMAND|CAPABILITY_REQUIRED)' "${SRC[@]}" 2>/dev/null || true)
[ -n "$viol_4c" ] && viol_4="$viol_4$viol_4c"$'\n'
if [ -n "$viol_4" ]; then
  echo "$viol_4"
  echo "FAIL: 不得以字符/文本静态判定作为拒绝依据（见 docs/sandbox.md 核心不变量 6）"
  fail=1
else
  echo "OK: 无字符静态硬拒（文本形迹仅用于分级/复核）"
fi

printf '\n----------------------------------------\n'
if [ "$fail" -eq 0 ]; then
  echo "不变量门禁：全部通过"
else
  echo "不变量门禁：存在违规（见上）"
fi
exit "$fail"
