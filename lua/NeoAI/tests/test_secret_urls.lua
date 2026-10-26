--- 密钥防护：网址 / 域名 / IP / UUID 不应被当作密钥
--- @module 'NeoAI.tests.test_secret_urls'
--- 覆盖：URL/域名/IP 里的高熵片段（UUID、带数字 slug）不 token 化、不告警、不登记为原始密钥
--- （否则后续提到该地址的命令会被硬拦截）；独立 UUID 亦不是凭据；地址豁免可关；
--- URL 内部的结构化凭据与敏感名赋值仍必须生效。
---
--- 注：本文件的测试样本全部**运行时拼装**，源码里不出现完整密钥/网址字面量——沙箱密钥层
--- 会把写盘内容中的真实密钥假化，写坏源码。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  config_store.load(vim.deepcopy(overrides or {}))
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

--- 拼装一个 UUID（避免源码出现完整 UUID 字面量）
local function uuid()
  return table.concat({ "8c1f2e3a", "4b5d", "6e7f", "8a9b", "0c1d2e3f4a5b" }, "-")
end

tests.suite("secret_urls", function(_, it)
  local secret = require("NeoAI.sandbox.secret.secret")

  it("网址 / 域名 / IP 不被假化、不告警、不登记为原始密钥", function(t)
    secret.reset()
    local u = uuid()
    local slug = table.concat({ "github", "production", "release", "asset", "2e65be" }, "-")
    local urls = {
      "{SCHEME}://webhook.site/" .. u,
      "{SCHEME}://objects.githubusercontent.com/" .. slug .. "/123456/abcd-1234-efgh",
      "http://192.168.1.100:8080/api/v1",
      "{SCHEME}://my-service-prod-01.internal.example.com:8443/webhook-endpoint-v2",
      "{SCHEME}://registry.npmmirror.com/-/binary/node/v20.11.0/node-v20.11.0-linux-x64.tar.gz",
    }
    local scheme = "https"
    for i, u2 in ipairs(urls) do
      local url = u2:gsub("{SCHEME}", scheme):gsub("{SCHEME}", scheme)
      t.eq(url, (secret.tokenize(url)), "网址不应被假化: " .. url)
      t.eq(0, #secret.detect(url), "网址不应被识别为密钥: " .. url)
      t.nil_(secret.find_real_secret(url), "网址不应登记为原始密钥: " .. url)
    end
    t.eq(u, (secret.tokenize(u)), "UUID 不应被假化")
    t.eq(0, #secret.detect(u), "UUID 不应被识别为密钥")
    secret.reset()
  end)

  it("按名赋值不把地址当凭据，后续提到该地址不被硬拦截", function(t)
    secret.reset()
    local host = table.concat({ "api", "example", "com" }, ".")
    local url = "https://" .. host .. "/v1/endpoint"
    local out = secret.tokenize("SERVICE_KEY=" .. url)
    t.eq("SERVICE_KEY=" .. url, out, "地址值不应登记为凭据")
    t.nil_(secret.find_real_secret("curl " .. url), "提到该地址不应被判为原始密钥")
    -- 裸域名同属地址
    t.eq("HOST=" .. host, (secret.tokenize("HOST=" .. host)), "域名值不应登记为凭据")
    secret.reset()
  end)

  it("地址豁免不削弱真实凭据：具名规则与敏感名赋值仍生效", function(t)
    secret.reset()
    local openai = "sk-" .. "URvSNfMcLVtopahOgZQkIrKlbWuXYJnsmejqdTPi"
    local aws = "AKIA" .. "KPQXYNLUSMTVWZOR"
    local gh = "ghp_" .. "CPx3NzwF08DJGHRLOI59yQS6uEvBTMA4127K"
    for _, k in ipairs({ openai, aws, gh }) do
      t.true_(secret.has_token((secret.tokenize("key=" .. k))), "真实凭据仍应假化: " .. k:sub(1, 4))
    end
    -- URL 内部的结构化凭据仍被抓（具名规则作用于全文本）
    local url = "https://api.example.com/v1?access_key=" .. aws
    local tok = secret.tokenize(url)
    t.true_(tok ~= url, "URL 内的结构化凭据仍应假化")
    t.eq(url, (secret.detokenize(tok)), "应可无损还原")
    -- 敏感名赋值的裸熵串（无分隔符）仍生效
    local raw = "Zx8Qm2" .. "pLk9Vn4" .. "Rt7Wq1" .. "Yb6Hf3"
    t.true_((secret.tokenize("token=" .. raw)) ~= ("token=" .. raw), "敏感名赋值的裸熵串仍应假化")
    -- 点分两段式凭据不被域名豁免误伤
    local dotted = "dfe946fb66864c48927f31f2aa49164d" .. "." .. "rwbWDAfnQjlHuMFt"
    t.true_(secret.has_token((secret.tokenize('key = "' .. dotted .. '"'))), "点分两段式凭据仍应假化")
    secret.reset()
  end)

  it("地址豁免可关：exclude_uuid / entropy_skip_urls = false 退回旧行为", function(t)
    secret.reset()
    local u = uuid()
    with_config({ tools = { sandbox = { secrets = { exclude_uuid = false, entropy_skip_urls = false } } } },
      function()
        t.true_(secret.tokenize(u) ~= u, "关闭 exclude_uuid 后 UUID 应恢复为候选")
        t.true_(#secret.detect(u) > 0, "关闭 exclude_uuid 后 detect 应命中")
      end)
    t.eq(u, (secret.tokenize(u)), "恢复默认后 UUID 不再假化")
    t.eq(0, #secret.detect(u), "恢复默认后 detect 不再命中")
    secret.reset()
  end)
end)
