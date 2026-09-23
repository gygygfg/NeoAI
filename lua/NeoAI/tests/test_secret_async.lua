--- 密钥异步 token 化专项测试
--- @module NeoAI.tests.test_secret_async
--- 覆盖：工作线程 token 化与主线程同步结果一致、token 可往返（detokenize）、批量接口。

local tests = require("NeoAI.tests")

tests.suite("secret_async", function(_, it)
  local CASES = {
    "AKIAIOSFODNN7EXAMPLE",
    "openai sk-abcdefghijklmnopqrstuvwxyz123456",
    "Authorization: Bearer abcdef1234567890XYZ.token",
    "Authorization: Basic QWxhZGRpbjpvcGVuc2VzYW1lMTIzNA==",
    "API_KEY=abcdef1234567890abcdef",
    '{"SECRET_TOKEN": "aB3xY9zQ7wV1uT5sR2pL"}',
    string.rep("normal text without secrets ", 50),
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1234567890abcdef\n-----END RSA PRIVATE KEY-----",
    "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "no secrets here at all",
  }

  it("tokenize_many_async 与同步 tokenize 结果一致", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local sync = {}
    for i, c in ipairs(CASES) do sync[i] = secret.tokenize(c) end
    local outs = t.await(secret.tokenize_many_async(CASES))
    t.eq(#CASES, #outs)
    for i = 1, #CASES do
      t.eq(sync[i], outs[i], "第 " .. i .. " 项")
    end
  end)

  it("异步 token 可 detokenize 还原", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local text = "key=abcdef1234567890abcdef and AKIAIOSFODNN7EXAMPLE"
    local out = t.await(secret.tokenize_async(text))
    t.true_(out ~= text, "应发生 token 化")
    local restored = secret.detokenize(out)
    t.eq(text, restored, "应可无损还原")
  end)

  it("异步批量：entropy_flags 逐项控制高熵扫描", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local key = "Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc"
    local outs = t.await(secret.tokenize_many_async({ key, key }, { entropy_flags = { false, true } }))
    t.eq(key, outs[1], "flag=false 的项不应做熵扫描")
    t.true_(secret.has_token(outs[2]), "flag=true 的项应做熵扫描")
    secret.reset()
  end)

  it("禁用时异步接口原样返回", function(t)
    local secret = require("NeoAI.sandbox.secret")
    local cfg = require("NeoAI.kernel.config_store")
    cfg.set("tools.sandbox.secrets.enabled", false)
    local ok, err = pcall(function()
      local outs = t.await(secret.tokenize_many_async({ "AKIAIOSFODNN7EXAMPLE" }))
      t.eq("AKIAIOSFODNN7EXAMPLE", outs[1])
    end)
    cfg.set("tools.sandbox.secrets.enabled", true)
    if not ok then error(err, 0) end
  end)

  it("分块并行 token 化：跨块相同密钥合并为规范 token 且可无损还原", function(t)
    local secret = require("NeoAI.sandbox.secret")
    local cfg = require("NeoAI.kernel.config_store")
    secret.reset()
    local key_a = "AKIAIOSFODNN7EXAMPLE"
    local key_b = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    -- 每项一块（work_chunk_files=1）：key_b 在块 1 是第 2 个新密钥、在块 2 是第 1 个，
    -- 各块独立分配 token，合并时须统一为同一 token。
    cfg.set("tools.sandbox.work_chunk_files", 1)
    local texts = { "A=" .. key_a .. " B=" .. key_b, "B=" .. key_b }
    local ok, err = pcall(function()
      local outs = t.await(secret.tokenize_many_async(texts))
      t.eq(#texts, #outs)
      for i = 1, #texts do
        t.true_(secret.has_token(outs[i]), "第 " .. i .. " 项应 token 化")
        t.eq(texts[i], secret.detokenize(outs[i]), "第 " .. i .. " 项应可无损还原")
      end
      -- 两处 key_b 应被替换为同一个 token（合并为规范 token）
      local t1 = outs[1]:match("B=(.+)$")
      local t2 = outs[2]:match("B=(.+)$")
      t.eq(t1, t2, "跨块相同密钥应合并为同一 token")
    end)
    cfg.set("tools.sandbox.work_chunk_files", nil)
    if not ok then error(err, 0) end
  end)
end)
