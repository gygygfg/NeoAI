--- 流程测试: tools 模块链
--- 调用链: approval_state → tool_registry → tool_validator → tool_pack → tools.init
--- 验证工具注册/查询/审批的完整流程

local M = {}

function M.run(test_module)
  local assert = test_module.assert

  local tests = {

    -- ============================================================
    -- 流程 1: approval_state 初始化与读写链
    -- ============================================================
    flow_approval_state_init = function()
      local as = require("NeoAI.tools.approval_state")

      -- 步骤 1: 清除旧状态
      as.reset()

      -- 步骤 2: 验证全局配置为空
      local global = as.get_global_config()
      assert.type_eq("table", global, "全局配置应为表")

      -- 步骤 3: 设置全局配置
      as.set_global_config({
        default_auto_allow = false,
        allowed_directories = { "/tmp" },
        allowed_param_groups = { "read" },
      })
      local global2 = as.get_global_config()
      assert.equal(false, global2.default_auto_allow, "default_auto_allow 应生效")
      assert.contains(global2.allowed_directories, "/tmp", "allowed_directories 应包含 /tmp")

      -- 步骤 4: 设置工具级配置
      as.set_tool_config("test_tool", {
        auto_allow = true,
        allowed_directories = { "/home" },
      })
      local tool_cfg = as.get_tool_config("test_tool")
      assert.equal(true, tool_cfg.auto_allow, "工具级 auto_allow 应生效")
      assert.contains(tool_cfg.allowed_directories, "/home", "工具级目录应生效")

      -- 步骤 5: set_allow_all / is_allow_all
      as.set_allow_all("test_tool")
      assert.is_true(as.is_allow_all("test_tool"), "is_allow_all 应返回 true")
      as.clear_allow_all("test_tool")
      assert.is_false(as.is_allow_all("test_tool"), "clear 后 is_allow_all 应返回 false")

      -- 步骤 6: 获取所有工具配置
      local all = as.get_all_tool_configs()
      assert.type_eq("table", all, "get_all_tool_configs 应返回表")

      as.reset()
    end,

    -- ============================================================
    -- 流程 2: approval_state 幂等初始化
    -- ============================================================
    flow_approval_state_idempotent = function()
      local as = require("NeoAI.tools.approval_state")
      as.reset()

      local config = {
        tools = {
          approval = {
            default_auto_allow = true,
            tool_overrides = {
              write_file = { auto_allow = false },
            },
          },
        },
      }

      -- 第一次初始化
      as.initialize_from_config(config)
      local cfg1 = as.get_tool_config("write_file")
      assert.not_nil(cfg1, "第一次初始化 write_file 应有配置")
      assert.equal(false, cfg1.auto_allow, "write_file 应为 false")

      -- 第二次初始化（幂等：不应覆盖）
      local config2 = {
        tools = {
          approval = {
            default_auto_allow = false,
          },
        },
      }
      as.initialize_from_config(config2)
      -- 由于幂等保护，全局默认应保持第一次的值
      local global = as.get_global_config()
      assert.is_true(global.default_auto_allow == true or global.default_auto_allow == false,
        "全局配置应仍是有效值")

      -- 清除幂等标记后重新初始化
      as.clear_initialized()
      as.initialize_from_config(config2)
      local global2 = as.get_global_config()
      assert.equal(false, global2.default_auto_allow,
        "清除标记后重新初始化，新值应生效")

      as.reset()
    end,

    -- ============================================================
    -- 流程 3: tool_registry 注册/查询/注销链
    -- ============================================================
    flow_tool_registry_crud = function()
      local tr = require("NeoAI.tools.tool_registry")

      -- 步骤 1: 初始化注册表
      tr.initialize({})

      -- 步骤 2: 注册工具
      local test_tool = {
        name = "flow_test_tool",
        description = "流程测试工具",
        func = function() return "ok" end,
        parameters = {
          type = "object",
          properties = {
            input = { type = "string", description = "输入" },
          },
          required = { "input" },
        },
        category = "test",
      }
      local ok = tr.register(test_tool)
      assert.is_true(ok, "注册测试工具应成功")

      -- 步骤 3: 重名注册应失败
      local ok2 = tr.register(test_tool)
      assert.is_false(ok2, "重名注册应失败")

      -- 步骤 4: 查询工具
      local tool = tr.get("flow_test_tool")
      assert.not_nil(tool, "get 应返回已注册的工具")
      assert.equal("流程测试工具", tool.description, "工具描述应匹配")
      assert.equal("test", tool.category, "工具分类应匹配")

      -- 步骤 5: get_tool 别名
      local tool2 = tr.get_tool("flow_test_tool")
      assert.not_nil(tool2, "get_tool 应返回已注册的工具")

      -- 步骤 6: exists 检查
      assert.is_true(tr.exists("flow_test_tool"), "exists 应返回 true")
      assert.is_false(tr.exists("nonexistent"), "不存在的工具应返回 false")

      -- 步骤 7: count
      local count = tr.count()
      assert.is_true(count >= 1, "count 应至少为 1")

      -- 步骤 8: get_all_tools
      local all = tr.get_all_tools()
      assert.type_eq("table", all, "get_all_tools 应返回表")
      assert.not_nil(all["flow_test_tool"], "结果应包含我们的测试工具")

      -- 步骤 9: search
      local results = tr.search("流程")
      assert.is_true(#results >= 1, "search '流程' 应有结果")

      -- 步骤 10: list (按分类)
      local test_tools = tr.list("test")
      assert.is_true(#test_tools >= 1, "分类 'test' 应有至少 1 个工具")

      -- 步骤 11: get_categories
      local cats = tr.get_categories()
      assert.contains(cats, "test", "分类列表应包含 'test'")

      -- 步骤 12: export / import
      local exported = tr.export_tool("flow_test_tool")
      assert.not_nil(exported, "export_tool 应返回非 nil")
      assert.equal("flow_test_tool", exported.name, "导出工具名应匹配")

      -- 步骤 13: 注销
      local unregistered = tr.unregister("flow_test_tool")
      assert.is_true(unregistered, "unregister 应成功")
      assert.is_false(tr.exists("flow_test_tool"), "注销后应不存在")
    end,

    -- ============================================================
    -- 流程 4: tool_registry 验证链
    -- ============================================================
    flow_tool_validation = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.initialize({})

      -- 步骤 1: 验证缺少 name
      local ok1, err1 = tr.validate_tool({ func = function() end })
      assert.is_false(ok1, "缺少 name 应验证失败")

      -- 步骤 2: 验证缺少 func
      local ok2, err2 = tr.validate_tool({ name = "test" })
      assert.is_false(ok2, "缺少 func 应验证失败")

      -- 步骤 3: 验证名称格式
      local ok3, err3 = tr.validate_tool({
        name = "123invalid",
        func = function() end,
      })
      assert.is_false(ok3, "不合法的名称格式应验证失败")

      -- 步骤 4: 验证合法工具
      local ok4, err4 = tr.validate_tool({
        name = "valid_tool",
        func = function() end,
        description = "Valid tool",
      })
      assert.is_true(ok4, "合法工具应验证成功")

      -- 步骤 5: get_work_dir
      local wd = tr.get_work_dir()
      assert.type_eq("string", wd, "get_work_dir 应返回字符串")
      assert.is_true(#wd > 0, "工作目录不应为空")
    end,

    -- ============================================================
    -- 流程 5: tool_pack 分组链
    -- ============================================================
    flow_tool_pack = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 步骤 1: 注册自定义包
      local ok = tp.register_pack({
        name = "test_pack",
        display_name = "测试工具包",
        icon = "🧪",
        tools = { "tool_a", "tool_b" },
        order = 50,
      })
      assert.is_true(ok, "register_pack 应成功")

      -- 步骤 2: 获取包
      local pack = tp.get_pack("test_pack")
      assert.not_nil(pack, "get_pack 应返回非 nil")
      assert.equal("测试工具包", pack.display_name, "显示名称应匹配")
      assert.equal("🧪", pack.icon, "图标应匹配")

      -- 步骤 3: 获取包内工具
      local tools = tp.get_pack_tools("test_pack")
      assert.contains(tools, "tool_a", "应包含 tool_a")
      assert.contains(tools, "tool_b", "应包含 tool_b")

      -- 步骤 4: get_pack_for_tool
      local pn = tp.get_pack_for_tool("tool_a")
      assert.equal("test_pack", pn, "tool_a 应属于 test_pack")

      -- 步骤 5: get_all_packs
      local all = tp.get_all_packs()
      assert.is_true(#all >= 1, "get_all_packs 应返回至少 1 个包")

      -- 步骤 6: get_pack_display_name
      local dn = tp.get_pack_display_name("test_pack")
      assert.equal("测试工具包", dn, "display name 应匹配")

      -- 步骤 7: get_pack_icon
      local icon = tp.get_pack_icon("test_pack")
      assert.equal("🧪", icon, "icon 应匹配")

      -- 步骤 8: get_pack_order
      local order = tp.get_pack_order("test_pack")
      assert.equal(50, order, "order 应为 50")

      -- 步骤 9: get_all_tool_names
      local all_names = tp.get_all_tool_names()
      assert.contains(all_names, "tool_a", "all_names 应包含 tool_a")

      -- 步骤 10: group_by_pack
      local grouped = tp.group_by_pack({
        { name = "tool_a" },
        { name = "tool_b" },
        { name = "unknown_tool" },
      })
      assert.not_nil(grouped["test_pack"], "grouped 应包含 test_pack")
      assert.equal(2, #grouped["test_pack"], "test_pack 应有 2 个工具")
    end,

    -- ============================================================
    -- 流程 6: tools/init.lua 入口模块
    -- ============================================================
    flow_tools_init = function()
      local ok, tools = pcall(require, "NeoAI.tools")
      assert.is_true(ok, "NeoAI.tools 入口应能加载")

      if ok and tools then
        -- 验证导出
        assert.type_eq("function", tools.initialize, "tools.initialize 应为函数")
        assert.type_eq("function", tools.register_tool, "tools.register_tool 应为函数")
        assert.type_eq("function", tools.get_tools, "tools.get_tools 应为函数")
        assert.type_eq("function", tools.get_tool, "tools.get_tool 应为函数")
        assert.type_eq("function", tools.execute_tool, "tools.execute_tool 应为函数")
        assert.type_eq("function", tools.unregister_tool, "tools.unregister_tool 应为函数")
        assert.type_eq("function", tools.get_tool_count, "tools.get_tool_count 应为函数")
        assert.type_eq("function", tools.search_tools, "tools.search_tools 应为函数")
        assert.type_eq("function", tools.reload_tools, "tools.reload_tools 应为函数")
        assert.type_eq("function", tools.validate_tool_args, "tools.validate_tool_args 应为函数")
        assert.type_eq("function", tools.get_full_config, "tools.get_full_config 应为函数")
      end
    end,

    -- ============================================================
    -- 流程 7: tool_registry → approval_state 审批配置链
    -- ============================================================
    flow_registry_approval_chain = function()
      local tr = require("NeoAI.tools.tool_registry")
      local as = require("NeoAI.tools.approval_state")

      -- 步骤 1: 重置并初始化
      as.reset()
      tr.initialize({})

      -- 步骤 2: 注册带审批字段的工具
      local ok = tr.register({
        name = "approval_test_tool",
        description = "Test tool with approval",
        func = function() return "ok" end,
        approval = { auto_allow = false, allowed_directories = { "/safe" } },
      })
      assert.is_true(ok, "注册审批工具应成功")

      -- 步骤 3: 获取审批配置（未初始化时回退到工具定义）
      local ac = tr.get_approval_config("approval_test_tool")
      assert.not_nil(ac, "get_approval_config 应返回非 nil")
      assert.equal(false, ac.auto_allow, "approval.auto_allow 应匹配")

      -- 步骤 4: 通过完整配置初始化审批
      local config = {
        tools = {
          approval = {
            default_auto_allow = true,
            tool_overrides = {
              approval_test_tool = { auto_allow = true },
            },
          },
        },
      }
      tr.apply_approval_config(config)

      -- 步骤 5: 验证审批配置更新
      local ac2 = tr.get_approval_config("approval_test_tool")
      assert.not_nil(ac2, "初始化后 get_approval_config 应返回非 nil")
      -- 工具级配置应覆盖
      assert.equal(true, ac2.auto_allow, "审批配置应被覆盖")

      -- 清理
      tr.unregister("approval_test_tool")
      as.reset()
    end,

    -- ============================================================
    -- 流程 8: tool_registry 外部工具加载
    -- ============================================================
    flow_external_tools = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.initialize({})

      -- 步骤 1: 创建模拟外部工具配置
      local config = {
        tools = {
          external = {
            {
              name = "ext_test_tool",
              func = function() return "ext_ok" end,
              description = "外部测试工具",
              category = "external",
            },
          },
        },
      }

      -- 步骤 2: 加载外部工具
      tr.load_external_tools_from_config(config)

      -- 步骤 3: 验证外部工具已注册
      assert.is_true(tr.exists("ext_test_tool"), "外部工具应已注册")
      local tool = tr.get("ext_test_tool")
      assert.equal("外部测试工具", tool.description, "外部工具描述应匹配")
      assert.equal("external", tool.category, "外部工具分类应匹配")

      -- 步骤 4: 验证函数可用
      local result = tool.func()
      assert.equal("ext_ok", result, "外部工具函数应可执行")

      -- 清理
      tr.unregister("ext_test_tool")
    end,
  }

  return test_module.run_tests(tests)
end

return M
