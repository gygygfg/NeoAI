local tests = require("NeoAI.tests")
local config = require("NeoAI.kernel.config_store")
local store = require("NeoAI.core.session.session_store")
local session = require("NeoAI.core.session.session")
local fs = require("NeoAI.utils.fs")

local function with_store(fn, extra)
  local old_config = vim.deepcopy(config.get_all() or {})
  local old_sessions = store.get_all()
  local dir = vim.fn.tempname()
  config.load({ session = vim.tbl_extend("force", { save_path = dir, file = "s.jsonl" }, extra or {}) })
  store.reset()
  local ok, err = xpcall(function() store.init(); fn(dir .. "/s.jsonl") end, function(e) return e end)
  config.load(old_config)
  store.restore(old_sessions)
  vim.fn.delete(dir, "rf")
  if not ok then error(err, 0) end
end

tests.suite("session_store_recovery", function(_, it)
  it("删除根与直接子节点，孙级提升为根且更新全部后代 root_id", function(t)
    with_store(function()
      local root = store.create({ id = "root" })
      local child = store.create({ id = "child", parent_id = root.id })
      local grandchild = store.create({ id = "grandchild", parent_id = child.id, messages = { { role = "user", content = "keep" } } })
      local leaf = store.create({ id = "leaf", parent_id = grandchild.id })
      t.deep_eq({ root.id, child.id }, store.delete(root.id))
      t.eq(grandchild, store.get(grandchild.id), "保持存活对象身份")
      t.nil_(grandchild.parent_id)
      t.eq(grandchild.id, grandchild.root_id)
      t.eq(grandchild.id, leaf.parent_id)
      t.eq(grandchild.id, leaf.root_id)
      t.eq("keep", grandchild.messages[1].content)
      store.reset(); store.init()
      t.eq(2, store.count())
      t.eq(1, #store.get_roots())
      t.eq(2, #store.get_chain(leaf.id))
      t.eq(grandchild.id, store.get(leaf.id).root_id)
    end)
  end)

  it("删除中间分支后更深后代重挂到最近存活祖先", function(t)
    with_store(function()
      local ancestor = store.create({ id = "ancestor" })
      local target = store.create({ id = "target", parent_id = ancestor.id })
      local child = store.create({ id = "child", parent_id = target.id })
      local grandchild = store.create({ id = "grandchild", parent_id = child.id })
      local sibling = store.create({ id = "sibling", parent_id = ancestor.id })
      t.eq(2, #store.delete(target.id))
      t.eq(ancestor.id, grandchild.parent_id)
      t.eq(ancestor.id, grandchild.root_id)
      t.eq(ancestor.id, sibling.parent_id)
      store.reset(); store.init()
      for _, s in pairs(store.get_all()) do
        t.true_(not s.parent_id or store.get(s.parent_id) ~= nil)
        t.not_nil(store.get(s.root_id))
      end
    end)
  end)

  it("保存/删除失败向上传递，磁盘与内存不提交删除且不发送成功事件", function(t)
    with_store(function(path)
      local s = store.create({ id = "keep" })
      local before = fs.read_file(path)
      local events = require("NeoAI.kernel.events")
      local fired = 0
      local unsub = require("NeoAI.kernel.event_bus").on(events.SESSION_SAVED, function() fired = fired + 1 end)
      local original = fs.write_file_atomic
      fs.write_file_atomic = function() return false, "disk failed" end
      local called, err = xpcall(function()
        local ok, save_err = store.save_all()
        t.false_(ok); t.eq("disk failed", save_err)
        local deleted, delete_err = store.delete(s.id)
        t.eq(0, #deleted); t.eq("disk failed", delete_err)
      end, function(e) return e end)
      fs.write_file_atomic = original
      unsub()
      if not called then error(err, 0) end
      t.eq(s, store.get(s.id))
      t.eq(before, fs.read_file(path))
      t.eq(0, fired)
    end)
  end)

  it("日志周期合并有界且恢复所有会话的最新状态", function(t)
    with_store(function(path)
      local a = store.create({ id = "a" })
      local b = store.create({ id = "b" })
      for i = 1, 20 do
        local s = i % 2 == 0 and a or b
        session.add_message(s, { role = "user", content = "message " .. i })
        t.true_(store.persist(s))
        t.true_(#fs.read_jsonl(path) <= 4, "旧快照条数应受合并阈值约束")
      end
      store.reset(); store.init()
      t.eq(10, #store.get("a").messages)
      t.eq(10, #store.get("b").messages)
      t.eq("message 20", store.get("a").messages[10].content)
      t.eq("message 19", store.get("b").messages[10].content)
      t.true_(fs.exists(path .. ".bak"))
    end, { log_compaction = { max_redundant_records = 3 } })
  end)

  it("追加失败留下的撕裂行在下次写入前修复", function(t)
    with_store(function(path)
      local s = store.create({ id = "retry" })
      session.add_message(s, { role = "user", content = "recover me" })
      local original = fs.append_file
      fs.append_file = function(p)
        original(p, '{"partial":')
        return false, "disk full"
      end
      local called, ok = pcall(store.persist, s)
      fs.append_file = original
      t.true_(called); t.false_(ok)
      t.true_(store.persist(s))
      store.reset(); store.init()
      t.eq("recover me", store.get("retry").messages[1].content)
      t.eq(2, #fs.read_jsonl(path))
    end)
  end)

  it("聊天保存失败不标记已同步，重试后历史无丢失或重复", function(t)
    with_store(function()
      local chat = require("NeoAI.services.chat_service")
      local runtime = require("NeoAI.core.agent.runtime")
      local async = require("NeoAI.utils.async")
      local original_run, original_append = runtime.run, fs.append_file
      chat.reset()
      local agent = chat.new_session({})
      runtime.run = function(a, content)
        a:add_message("user", content)
        a:add_message("assistant", "answer")
        return async.resolve({ content = "answer" })
      end
      local ok, err = xpcall(function()
        fs.append_file = function() return false, "disk full" end
        local failure
        t.await(chat.send_message("first"):catch(function(e) failure = e end))
        t.eq("persistence", failure.kind)
        t.eq(0, #store.get(agent.session_id).messages)
        for _, msg in ipairs(agent.messages) do t.false_(msg._synced == true) end
        fs.append_file = original_append
        t.await(chat.send_message("second"))
        t.eq(4, #store.get(agent.session_id).messages)
        for _, msg in ipairs(agent.messages) do t.true_(msg._synced) end
        store.reset(); store.init()
        t.eq(4, #store.get(agent.session_id).messages)
        t.eq("first", store.get(agent.session_id).messages[1].content)
        t.eq("second", store.get(agent.session_id).messages[3].content)
      end, function(e) return e end)
      runtime.run, fs.append_file = original_run, original_append
      chat.reset()
      runtime.dispose(agent)
      if not ok then error(err, 0) end
    end)
  end)

  it("合并失败不丢失已追加快照，后续重试可恢复", function(t)
    with_store(function(path)
      local s = store.create({ id = "a" })
      session.add_message(s, { role = "user", content = "durable" })
      local original = fs.write_file_atomic
      fs.write_file_atomic = function() return false, "rename failed" end
      local called, ok = pcall(store.persist, s)
      fs.write_file_atomic = original
      t.true_(called); t.true_(ok)
      t.eq(2, #fs.read_jsonl(path))
      store.reset(); store.init()
      t.eq("durable", store.get("a").messages[1].content)
      t.true_(store.persist(store.get("a")))
      t.eq(1, #fs.read_jsonl(path))
    end, { log_compaction = { max_redundant_records = 1 } })
  end)

  it("字节阈值合并大快照；enabled=false 时保留追加行为", function(t)
    with_store(function(path)
      local s = store.create({ id = "large", messages = { { role = "user", content = string.rep("x", 1000) } } })
      t.true_(store.persist(s))
      t.eq(1, #fs.read_jsonl(path))
      config.set("session.log_compaction.enabled", false)
      t.true_(store.persist(s))
      t.eq(2, #fs.read_jsonl(path))
    end, { log_compaction = { min_bytes = 1, max_redundant_records = 100 } })
  end)
end)
