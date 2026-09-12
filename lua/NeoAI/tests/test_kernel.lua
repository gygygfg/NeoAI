--- 内核层测试
--- @module NeoAI.tests.test_kernel
--- 测试 config_store / logger / event_bus / lifecycle。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("kernel", function(_, it, before_each)
  before_each(function()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { default_provider = "deepseek" } })
  end)

  it("config_store 深合并用户配置", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "test" },
      ui = { window = { width = 120 } },
    })
    t.eq("test", config_store.get("ai.default_provider"))
    t.eq(120, config_store.get("ui.window.width"))
    -- 未覆盖字段保留默认
    t.eq("rounded", config_store.get("ui.window.border"))
  end)

  it("config_store 点分路径读取", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    t.eq("deepseek", config_store.get("ai.default_provider"))
    t.eq(nil, config_store.get("不存在.字段"))
  end)

  it("config_store 数组整体替换/清空，空 map 保留默认配置", function(t)
    local config = require("NeoAI.kernel.config_store")
    config.load({ skills = { paths = { "/custom/skills" } }, ui = {}, ai = { providers = { deepseek = {} } } })
    t.deep_eq({ "/custom/skills" }, config.get("skills.paths"))
    t.eq("rounded", config.get("ui.window.border"))
    t.not_nil(config.get("ui.chat"))
    t.not_nil(config.get("ai.providers.deepseek.base_url"))
    config.load({ skills = { paths = {} } })
    t.deep_eq({}, config.get("skills.paths"))
  end)

  it("config_store watch 触发", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fired = false
    local unsub = config_store.watch("ui.window.width", function()
      fired = true
    end)
    config_store.set("ui.window.width", 100)
    t.true_(fired)
    unsub()
    config_store.set("ui.window.width", 90)
  end)

  it("config_store 不可变：修改返回配置不影响默认", function(t)
    local default = require("NeoAI.default_config")
    local cfg = default.get_default_config()
    cfg.ai.default_provider = "mutated"
    local fresh = default.get_default_config()
    t.eq("deepseek", fresh.ai.default_provider)
  end)

  it("event_bus 发布订阅", function(t)
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local received = nil
    local unsub = event_bus.on(events.MODELS_UPDATED, function(data)
      received = data
    end)
    event_bus.emit(events.MODELS_UPDATED, { count = 7 })
    return async.sleep(50):then_(function()
      t.not_nil(received)
      t.eq(7, received.count)
      unsub()
      print("  event_bus done")
    end)
  end)

  it("event_bus 自动加前缀并去重", function(t)
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local received = 0
    local unsub = event_bus.on(events.TOOL_EXECUTION_STARTED, function() received = received + 1 end)
    event_bus.emit(events.TOOL_EXECUTION_STARTED, {})
    return async.sleep(50):then_(function()
      t.eq(1, received)
      unsub()
      print("  prefix done")
    end)
  end)

  it("logger 分级输出", function(t)
    local logger = require("NeoAI.kernel.logger")
    logger.init({ level = "ERROR", path = nil })
    t.eq("ERROR", logger.get_level())
    logger.init({ level = "WARN" })
    t.eq("WARN", logger.get_level())
  end)

  it("lifecycle 清理函数按序执行", function(t)
    local lifecycle = require("NeoAI.kernel.lifecycle")
    local order = {}
    lifecycle.reset()
    lifecycle.bootstrap()
    lifecycle.on_shutdown(function() order[#order + 1] = "a" end)
    lifecycle.on_shutdown(function() order[#order + 1] = "b" end)
    lifecycle.shutdown()
    t.deep_eq({ "b", "a" }, order)
    t.true_(lifecycle.is_shutting_down())
  end)

  it("async Promise 基本流程", function(t)
    local async = require("NeoAI.utils.async")
    local d = async.new(function(resolve, reject)
      resolve(42)
    end)
    return d:then_(function(v)
      t.eq(42, v)
      print("  promise done")
    end)
  end)

  it("async retry 指数退避", function(t)
    local async = require("NeoAI.utils.async")
    local attempts = 0
    return async.retry(function()
      attempts = attempts + 1
      if attempts < 3 then return async.reject({ kind = "net" }) end
      return async.resolve("ok")
    end, { retries = 3, delay_ms = 5 })
      :then_(function(v)
        t.eq("ok", v)
        t.eq(3, attempts)
        print("  retry done")
      end)
  end)

  it("async AbortSignal 级联", function(t)
    local async = require("NeoAI.utils.async")
    local signal = async.create_signal()
    local reason = nil
    signal:subscribe(function(r) reason = r end)
    signal:abort("cancel")
    t.true_(signal:aborted())
    t.eq("cancel", reason)
  end)

  it("json 编解码往返", function(t)
    local json = require("NeoAI.utils.json")
    local data = { name = "测试", list = { 1, 2, 3 }, nested = { ok = true } }
    local encoded = json.encode(data)
    local decoded = json.decode(encoded)
    t.eq("测试", decoded.name)
    t.eq(3, #decoded.list)
    t.true_(decoded.nested.ok)
  end)

  it("json 容错：非法输入返回 nil", function(t)
    local json = require("NeoAI.utils.json")
    local v, err = json.decode_or_nil("{broken")
    t.nil_(v)
    t.not_nil(err)
  end)

  it("fs JSONL 读写 + 撕裂行恢复", function(t)
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_test_tmp.jsonl"
    fs.write_file(path, "")
    fs.append_jsonl(path, { id = "a", v = 1 })
    fs.append_jsonl(path, { id = "b", v = 2 })
    t.eq(2, #fs.read_jsonl(path))
    fs.append_file(path, '{"id":"c","v":3')
    t.eq(2, #fs.read_jsonl(path)) -- 撕裂行不计入
    local repaired = fs.repair_jsonl(path)
    t.true_(repaired)
    t.eq(2, #fs.read_jsonl(path))
    fs.delete_file(path)
  end)

  it("stringx 工具函数", function(t)
    local stringx = require("NeoAI.utils.stringx")
    t.eq("hi", stringx.trim("  hi  "))
    t.eq(3, #stringx.split("a,b,c", ","))
    t.true_(stringx.glob_match("*.lua", "test.lua"))
    t.false_(stringx.glob_match("*.lua", "test.txt"))
    t.true_(stringx.startswith("hello", "he"))
    t.true_(stringx.endswith("hello", "lo"))
  end)
end)
