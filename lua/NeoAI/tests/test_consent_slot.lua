--- 同意/告警类浮窗单槽位调度测试
--- @module 'NeoAI.tests.test_consent_slot'
local tests = require("NeoAI.tests")

tests.suite("consent_slot", function(_, it)
  local slot = require("NeoAI.ui.consent_slot")

  it("跨组件互斥：槽位忙碌时排队，前一张让位后展示下一张", function(t)
    slot.reset()
    local opened = {}
    local tk1 = slot.acquire({
      key = "net_consent",
      open = function(ticket) opened[#opened + 1] = ticket.id end,
    })
    local tk2 = slot.acquire({
      key = "secret_alert",
      open = function(ticket) opened[#opened + 1] = ticket.id end,
    })
    t.eq(1, #opened, "同一时刻只展示一个浮窗")
    t.eq(1, slot.pending_count(), "第二个申请者应排队")
    t.eq(tk1, slot.current(), "槽位归首个票据")
    slot.release(tk1)
    t.eq(2, #opened, "让位后应展示队首")
    t.eq(tk2, slot.current(), "槽位转给第二个票据")
    t.eq(0, slot.pending_count(), "队列应清空")
    slot.release(tk2)
    t.false_(slot.has_inflight(), "全部让位后无在途票据")
    slot.reset()
  end)

  it("mark_presented/is_presented：仅当前票据可标记呈现", function(t)
    slot.reset()
    local tk1 = slot.acquire({ key = "net_consent", open = function() end })
    local tk2 = slot.acquire({ key = "net_consent", open = function() end })
    t.false_(slot.is_presented(tk1), "未标记前不算已呈现")
    t.true_(slot.mark_presented(tk1), "当前票据可标记")
    t.true_(slot.is_presented(tk1), "已呈现")
    t.false_(slot.mark_presented(tk2), "排队中的票据不可标记")
    t.false_(slot.is_presented(tk2), "排队中的票据不算已呈现")
    slot.release(tk1)
    t.false_(slot.is_presented(tk1), "让位后不再算已呈现")
    slot.mark_presented(tk2)
    t.true_(slot.is_presented(tk2), "队首展示后可标记")
    slot.reset()
    t.false_(slot.has_inflight(), "reset 后无在途票据")
  end)

  it("dedupe：同 key 同目标在途时抑制重复票据，让位后可再取票", function(t)
    slot.reset()
    local opened = {}
    local function spec(host_port)
      return {
        key = "net_consent",
        dedupe = host_port,
        open = function(ticket) opened[#opened + 1] = ticket.id end,
      }
    end
    local tk1 = slot.acquire(spec("host-a:1111"))
    local tk2 = slot.acquire(spec("host-a:1111"))
    t.true_(tk2.suppressed, "同目标在途请求应被抑制")
    t.eq(tk1, tk2.owner, "抑制票据应指向在途票据")
    t.eq(1, #opened, "被抑制的票据不建窗")
    t.eq(0, slot.pending_count(), "被抑制的票据不排队")
    t.false_(slot.is_presented(tk2), "代表票据未呈现时抑制票据亦未呈现")
    slot.mark_presented(tk1)
    t.true_(slot.is_presented(tk2), "代表票据呈现后抑制票据跟随")
    local tk3 = slot.acquire(spec("host-b:2222"))
    t.false_(tk3.suppressed, "不同目标不应被抑制")
    t.eq(1, slot.pending_count(), "不同目标排队")
    slot.release(tk1)
    t.eq(2, #opened, "让位后展示不同目标的票据")
    slot.cancel(tk3)
    local tk4 = slot.acquire(spec("host-a:1111"))
    t.false_(tk4.suppressed, "无在途同目标票据时可重新取票")
    t.eq(3, #opened, "新票据立即展示")
    slot.cancel(tk4)
    slot.reset()
  end)

  it("cancel：排队票据出队不展示；当前票据 cancel 关自己的窗并推进队列", function(t)
    slot.reset()
    local opened, closed = {}, {}
    local function spec(key)
      return {
        key = key,
        open = function(ticket) opened[#opened + 1] = ticket.id end,
        close = function(ticket) closed[#closed + 1] = ticket.id end,
      }
    end
    local tk1 = slot.acquire(spec("net_consent"))
    local tk2 = slot.acquire(spec("secret_alert"))
    local tk3 = slot.acquire(spec("device_consent"))
    t.eq(1, #opened, "仅首个展示")
    t.eq(2, slot.pending_count(), "其余排队")

    t.true_(slot.cancel(tk2), "排队票据可取消")
    t.eq(1, slot.pending_count(), "取消后从队列移除")
    t.eq(0, #closed, "排队票据取消不关窗")

    t.true_(slot.cancel(tk1), "当前票据可取消")
    t.eq(1, #closed, "当前票据 cancel 调用自己的 close 关窗")
    t.eq(tk1.id, closed[1], "关的是自己的窗")
    t.eq(2, #opened, "取消后应推进到下一张（tk2 已出队，故为 tk3）")
    t.eq(tk3, slot.current(), "槽位转给 tk3")
    t.false_(slot.cancel(tk2), "重复取消无副作用")
    t.eq(1, #closed, "重复取消不重复关窗")
    slot.reset()
  end)

  it("open 抛异常：自动让位并推进队首，槽位不卡死", function(t)
    slot.reset()
    local opened = {}
    local tk_bad = slot.acquire({
      key = "net_consent",
      open = function() error("boom") end,
    })
    t.eq("failed", tk_bad.phase, "展示失败的票据标记 failed")
    t.eq(nil, slot.current(), "失败票据不应占用槽位")
    local tk_ok = slot.acquire({
      key = "secret_alert",
      open = function(ticket) opened[#opened + 1] = ticket.id end,
    })
    t.eq(1, #opened, "后续票据仍可展示")
    t.eq(tk_ok, slot.current(), "槽位归后续票据")
    t.false_(slot.mark_presented(tk_bad), "失败票据不可标记呈现")
    slot.reset()
  end)

  it("open 内部同步让位时队列继续推进（不重入死循环）", function(t)
    slot.reset()
    local opened = {}
    local tk1 = slot.acquire({
      key = "net_consent",
      open = function(ticket)
        opened[#opened + 1] = ticket.id
        slot.release(ticket) -- 展示函数内部立即让位（如立即决策）
      end,
    })
    local tk2 = slot.acquire({
      key = "secret_alert",
      open = function(ticket) opened[#opened + 1] = ticket.id end,
    })
    t.eq(2, #opened, "两张票据都应展示")
    t.eq(tk2, slot.current(), "槽位归第二张")
    slot.release(tk2)
    slot.release(tk1)
    t.false_(slot.has_inflight(), "全部释放后无在途票据")
    slot.reset()
  end)

  it("reset 清空当前与队列（含 close 回调）", function(t)
    slot.reset()
    local closed = {}
    local tk1 = slot.acquire({
      key = "net_consent", open = function() end,
      close = function(ticket) closed[#closed + 1] = ticket.id end,
    })
    slot.acquire({ key = "net_consent", open = function() end })
    t.eq(1, slot.pending_count(), "有排队票据")
    slot.reset()
    t.eq(0, slot.pending_count(), "队列应清空")
    t.eq(nil, slot.current(), "当前票据应清空")
    t.eq(1, #closed, "reset 应关掉当前票据的窗")
    t.false_(slot.has_inflight(), "无在途票据")
    t.false_(slot.release(tk1), "reset 后释放旧票据无副作用")
  end)
end)
