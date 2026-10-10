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

printf '\n----------------------------------------\n'
if [ "$fail" -eq 0 ]; then
  echo "不变量门禁：全部通过"
else
  echo "不变量门禁：存在违规（见上）"
fi
exit "$fail"
