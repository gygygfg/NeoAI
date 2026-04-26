#!/usr/bin/env bash
#=============================================================================
# fetch_responses.sh
# 使用 curl 模拟 DeepSeek API 请求，将原始请求和响应保存到 tests/deepseek_responses/
#
# 覆盖所有请求方式:
#   1. 非流式 + thinking (deepseek-v4-pro)
#   2. 流式 + thinking
#   3. 流式 + 无 thinking
#   4. 非流式 + 无 thinking
#   5. 工具调用 (Function Calling)
#   6. 补全 (FIM / Completions)
#   7. 列出模型 (GET /models)
#   8. 查询余额 (GET /user/balance)
#
# 用法:
#   export DEEPSEEK_API_KEY="your-api-key"
#   bash fetch_responses.sh
#
# 环境变量:
#   DEEPSEEK_API_KEY  - DeepSeek API 密钥（必需）
#   DEEPSEEK_BASE_URL - API 基础 URL（可选，默认 https://api.deepseek.com）
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 配置
API_KEY="${DEEPSEEK_API_KEY:?错误: 请设置 DEEPSEEK_API_KEY 环境变量}"
BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com}"

# 公共请求头
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
CONTENT_TYPE="Content-Type: application/json"

echo "=========================================="
echo " DeepSeek API 响应抓取工具"
echo "=========================================="
echo "API Base URL: ${BASE_URL}"
echo "输出目录: ${SCRIPT_DIR}"
echo "=========================================="
echo ""

#-----------------------------------------------------------------------------
# 辅助函数
#-----------------------------------------------------------------------------
do_post() {
  local label="$1"
  local req_filename="$2"
  local resp_filename="$3"
  local request_body="$4"
  local stream="$5"

  local req_path="${SCRIPT_DIR}/${req_filename}"
  local resp_path="${SCRIPT_DIR}/${resp_filename}"

  echo "[${label}] ${req_filename} / ${resp_filename}"

  echo "$request_body" > "$req_path"
  echo "  请求体已保存: ${req_path}"

  echo "  发送请求..."
  local curl_args=(
    -s -w "%{http_code}"
    "${BASE_URL}/chat/completions"
    -H "${CONTENT_TYPE}"
    -H "${AUTH_HEADER}"
    -d "$request_body"
    -o "$resp_path"
  )

  if [ "$stream" = "true" ]; then
    curl_args+=(--no-buffer -N)
  fi

  local HTTP_CODE
  HTTP_CODE=$(curl "${curl_args[@]}" 2>&1)

  echo "  HTTP 状态码: ${HTTP_CODE}"
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✓ 响应已保存: ${resp_path}"
    echo "  响应大小: $(wc -c < "$resp_path") bytes"
  else
    echo "  ✗ 请求失败! 响应内容:"
    cat "$resp_path"
    echo ""
    rm -f "$resp_path" "$req_path"
    return 1
  fi
  echo ""
}

do_get() {
  local label="$1"
  local resp_filename="$2"
  local endpoint="$3"

  local resp_path="${SCRIPT_DIR}/${resp_filename}"

  echo "[${label}] ${resp_filename} (GET ${endpoint})"

  echo "  发送请求..."
  local HTTP_CODE
  HTTP_CODE=$(curl -s -w "%{http_code}" \
    "${BASE_URL}${endpoint}" \
    -H "${AUTH_HEADER}" \
    -H "Accept: application/json" \
    -o "$resp_path" 2>&1)

  echo "  HTTP 状态码: ${HTTP_CODE}"
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✓ 响应已保存: ${resp_path}"
    echo "  响应大小: $(wc -c < "$resp_path") bytes"
  else
    echo "  ✗ 请求失败! 响应内容:"
    cat "$resp_path"
    echo ""
    rm -f "$resp_path"
    return 1
  fi
  echo ""
}

#-----------------------------------------------------------------------------
# 1. 非流式 + thinking（deepseek-v4-pro）
#-----------------------------------------------------------------------------
do_post \
  "1/8 非流式+thinking" \
  "reasoning_non_stream_request.json" \
  "reasoning_non_stream.json" \
  '{
    "model": "deepseek-v4-pro",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ],
    "thinking": {"type": "enabled"},
    "reasoning_effort": "high",
    "stream": false
  }' \
  "false"

#-----------------------------------------------------------------------------
# 2. 流式 + thinking
#-----------------------------------------------------------------------------
do_post \
  "2/8 流式+thinking" \
  "reasoning_streaming_request.json" \
  "reasoning_streaming.json" \
  '{
    "model": "deepseek-v4-pro",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ],
    "thinking": {"type": "enabled"},
    "reasoning_effort": "high",
    "stream": true
  }' \
  "true"

#-----------------------------------------------------------------------------
# 3. 流式 + 无 thinking
#-----------------------------------------------------------------------------
do_post \
  "3/8 流式+无thinking" \
  "streaming_no_reasoning_request.json" \
  "streaming_no_reasoning.json" \
  '{
    "model": "deepseek-v4-pro",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ],
    "stream": true
  }' \
  "true"

#-----------------------------------------------------------------------------
# 4. 非流式 + 无 thinking
#-----------------------------------------------------------------------------
do_post \
  "4/8 非流式+无thinking" \
  "non_streaming_no_reasoning_request.json" \
  "non_streaming_no_reasoning.json" \
  '{
    "model": "deepseek-v4-pro",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ],
    "stream": false
  }' \
  "false"

#-----------------------------------------------------------------------------
# 5. 工具调用 (Function Calling)
#-----------------------------------------------------------------------------
do_post \
  "5/8 工具调用" \
  "tool_call_request.json" \
  "tool_call.json" \
  '{
    "model": "deepseek-v4-pro",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is the weather like in Beijing today?"}
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get the current weather for a city",
          "parameters": {
            "type": "object",
            "properties": {
              "city": {
                "type": "string",
                "description": "The city name"
              }
            },
            "required": ["city"]
          }
        }
      }
    ],
    "stream": false
  }' \
  "false"

#-----------------------------------------------------------------------------
# 6. 补全 (FIM / Completions)
#    DeepSeek 使用 /beta/completions 端点进行 FIM 补全
#-----------------------------------------------------------------------------
echo "[6/8 补全(FIM)] fim_completion_request.json / fim_completion.json"

FIM_REQ_PATH="${SCRIPT_DIR}/fim_completion_request.json"
FIM_RESP_PATH="${SCRIPT_DIR}/fim_completion.json"

FIM_BODY='{
  "model": "deepseek-v4-pro",
  "prompt": "def fibonacci(n):",
  "suffix": "    return result",
  "max_tokens": 64,
  "stream": false
}'

echo "$FIM_BODY" > "$FIM_REQ_PATH"
echo "  请求体已保存: ${FIM_REQ_PATH}"
echo "  发送请求..."

FIM_HTTP_CODE=$(curl -s -w "%{http_code}" \
  "${BASE_URL}/beta/completions" \
  -H "${CONTENT_TYPE}" \
  -H "${AUTH_HEADER}" \
  -d "$FIM_BODY" \
  -o "$FIM_RESP_PATH" 2>&1)

echo "  HTTP 状态码: ${FIM_HTTP_CODE}"
if [ "$FIM_HTTP_CODE" = "200" ]; then
  echo "  ✓ 响应已保存: ${FIM_RESP_PATH}"
  echo "  响应大小: $(wc -c < "$FIM_RESP_PATH") bytes"
else
  echo "  ✗ 请求失败! 响应内容:"
  cat "$FIM_RESP_PATH"
  echo ""
  rm -f "$FIM_RESP_PATH" "$FIM_REQ_PATH"
fi
echo ""

#-----------------------------------------------------------------------------
# 7. 列出模型 (GET /models)
#-----------------------------------------------------------------------------
do_get \
  "7/8 列出模型" \
  "list_models.json" \
  "/models"

#-----------------------------------------------------------------------------
# 8. 查询余额 (GET /user/balance)
#-----------------------------------------------------------------------------
do_get \
  "8/8 查询余额" \
  "user_balance.json" \
  "/user/balance"

echo "=========================================="
echo " 完成! 所有响应已保存到: ${SCRIPT_DIR}"
echo "=========================================="
ls -lh "${SCRIPT_DIR}"/*.json 2>/dev/null || true
