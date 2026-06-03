--- 端到端集成流程测试
--- 验证: setup → 工具注册 → 配置查询 → 事件触发 → 清理 的完整链路
--- 模拟用户真实使用 NeoAI 时的完整调用路径

local M = {}

function M.run(test_module)
  local assert = test_module.assert
  local logger = test_module._logger or require("NeoAI.utils.logger")

  local tests = {

    -- ============================================================
    -- 流程 1: 完整启动链（模拟 setup）
    -- ============================================================
    flow_full_setup = function()
      -- 步骤 1: 加载默认配置
      local dc = require("NeoAI.default_config")
      local config = dc.get_default_config()
      assert.not_nil(config, "默认配置应可加载")

      -- 步骤 2: 合并用户配置
      local merger = require("NeoAI.core.config.merger")
      local merged = merger.process_config({
        ai = { default = "chat" },
        ui = { window_mode = "float" },
        session = { auto_save = false },
      })
      assert.not_nil(merged, "merge 应成功")

      -- 步骤 3: 初始化状态管理器
      local sm = require("NeoAI.core.config.state")
      local ctx = sm.create_context({
        config = merged,
        session_id = "full_flow_session",
      })
      assert.not_nil(ctx, "创建上下文应成功")

      -- 步骤 4: 初始化键位管理器
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(merged)
      local contexts = km.get_available_contexts()
      assert.is_true(#contexts >= 1, "键位管理器应初始化成功")

      -- 步骤 5: 初始化关闭标志
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      assert.is_false(sf.is_set(), "关闭标志应为 false")
    end,

    -- ============================================================
    -- 流程 2: 完整工具注册链（模拟内置工具加载）
    -- ============================================================
    flow_full_tool_registration = function()
      -- 步骤 1: 准备审批状态
      local as = require("NeoAI.tools.approval_state")
      as.reset()

      -- 步骤 2: 初始化审批配置
      local dc = require("NeoAI.default_config")
      local config = dc.get_default_config()
      as.initialize_from_config(config)

      -- 步骤 3: 初始化 tool_registry
      local tr = require("NeoAI.tools.tool_registry")
      tr.initialize({})

      -- 步骤 4: 注册多个工具模拟内置工具加载
      local tools_to_register = {
        { name = "read_file", desc = "读取文件", category = "file", func = function(f) return "content" end },
        { name = "write_file", desc = "写入文件", category = "file", func = function(f, c) return true end },
        { name = "search_code", desc = "搜索代码", category = "lsp", func = function(q) return {} end },
        { name = "parse_syntax", desc = "解析语法", category = "treesitter", func = function(f) return {} end },
        { name = "run_command", desc = "运行命令", category = "system", func = function(c) return "" end },
      }
      for _, td in ipairs(tools_to_register) do
        local ok = tr.register({
          name = td.name,
          description = td.desc,
          func = td.func,
          category = td.category,
        })
        assert.is_true(ok, "工具 " .. td.name .. " 应注册成功")
      end

      -- 步骤 5: 验证工具数量
      local count = tr.count()
      assert.is_true(count >= 5, "应至少有 5 个注册工具，实际: " .. count)

      -- 步骤 6: 按分类查询
      local file_tools = tr.list("file")
      assert.equal(2, #file_tools, "file 分类应有 2 个工具")
      local lsp_tools = tr.list("lsp")
      assert.equal(1, #lsp_tools, "lsp 分类应有 1 个工具")

      -- 步骤 7: 搜索工具
      local results = tr.search("文件")
      assert.is_true(#results >= 1, "搜索 '文件' 应有结果")

      -- 步骤 8: 获取分类列表
      local cats = tr.get_categories()
      assert.contains(cats, "file", "分类应包含 file")
      assert.contains(cats, "lsp", "分类应包含 lsp")
      assert.contains(cats, "system", "分类应包含 system")

      -- 清理
      for _, td in ipairs(tools_to_register) do
        tr.unregister(td.name)
      end
      as.reset()
    end,

    -- ============================================================
    -- 流程 3: 完整工具执行链（模拟工具调用）
    -- ============================================================
    flow_full_tool_execution = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.initialize({})

      -- 步骤 1: 注册带参数验证的工具
      tr.register({
        name = "echo_tool",
        description = "Echo back",
        func = function(args)
          return "echo: " .. (args.message or "")
        end,
        parameters = {
          type = "object",
          properties = {
            message = { type = "string", description = "消息" },
          },
          required = { "message" },
        },
      })

      -- 步骤 2: 获取工具并调用
      local tool = tr.get("echo_tool")
      assert.not_nil(tool, "echo_tool 应已注册")
      local result = tool.func({ message = "hello world" })
      assert.equal("echo: hello world", result, "工具执行结果应匹配")

      -- 步骤 3: 验证工具参数类型
      local valid, err = tr.validate_tool({
        name = "param_tool",
        func = function() end,
        parameters = {
          type = "object",
          properties = {
            input = { type = "string" },
          },
        },
      })
      assert.is_true(valid, "带参数的合法工具应验证通过")

      -- 步骤 4: 验证错误的 approval 类型
      local valid2, err2 = tr.validate_tool({
        name = "bad_approval",
        func = function() end,
        approval = "not_a_table",
      })
      assert.is_false(valid2, "非法的 approval 类型应验证失败")

      tr.unregister("echo_tool")
    end,

    -- ============================================================
    -- 流程 4: tool_pack 分组与分组查询（模拟工具编排）
    -- ============================================================
    flow_full_tool_pack_workflow = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 步骤 1: 初始化 tool_pack（从内置目录扫描）
      tp.initialize()

      -- 步骤 2: 获取所有工具包
      local all_packs = tp.get_all_packs()
      assert.type_eq("table", all_packs, "get_all_packs 应返回表")

      -- 步骤 3: 验证工具包结构
      for _, pack in ipairs(all_packs) do
        assert.not_nil(pack.name, "每个包应有 name 字段")
        assert.not_nil(pack.display_name, "每个包应有 display_name 字段")
        assert.not_nil(pack.icon, "每个包应有 icon 字段")
        assert.type_eq("table", pack.tools, "tools 应为表")
      end

      -- 步骤 4: 获取展示名称
      for _, pack in ipairs(all_packs) do
        local dn = tp.get_pack_display_name(pack.name)
        assert.type_eq("string", dn, "display name 应为字符串")
        local icon = tp.get_pack_icon(pack.name)
        assert.type_eq("string", icon, "icon 应为字符串")
      end

      -- 步骤 5: 模拟工具调用分组
      local mock_tool_calls = {}
      local all_names = tp.get_all_tool_names()
      for i = 1, math.min(3, #all_names) do
        table.insert(mock_tool_calls, { name = all_names[i] })
      end
      if #mock_tool_calls > 0 then
        local grouped = tp.group_by_pack(mock_tool_calls)
        assert.type_eq("table", grouped, "group_by_pack 应返回表")
      end
    end,

    -- ============================================================
    -- 流程 5: 完整事件链（模拟 AI 生成事件流）
    -- ============================================================
    flow_full_event_pipeline = function()
      local Events = require("NeoAI.core.events")
      local sm = require("NeoAI.core.config.state")

      -- 步骤 1: 创建事件监听上下文
      local group = vim.api.nvim_create_augroup("NeoAI_full_flow_events", { clear = true })
      local event_log = {}

      -- 步骤 2: 注册生成生命周期监听
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "NeoAI:FullFlowTest",
        callback = function(args)
          table.insert(event_log, {
            event = "FullFlowTest",
            data = args.data,
            time = os.time(),
          })
        end,
      })

      -- 步骤 3: 模拟事件触发序列
      local events_sequence = {
        { event = "NeoAI:FullFlowTest", data = { phase = "start", generation_id = "test_gen_1" } },
        { event = "NeoAI:FullFlowTest", data = { phase = "streaming", chunk = 1 } },
        { event = "NeoAI:FullFlowTest", data = { phase = "streaming", chunk = 2 } },
        { event = "NeoAI:FullFlowTest", data = { phase = "complete", usage = { total = 100 } } },
      }

      for _, evt in ipairs(events_sequence) do
        vim.api.nvim_exec_autocmds("User", {
          pattern = evt.event,
          data = evt.data,
        })
      end

      -- 步骤 4: 验证事件序列完整
      assert.equal(4, #event_log, "应有 4 条事件记录")
      assert.equal("start", event_log[1].data.phase, "第一条应为 start")
      assert.equal("complete", event_log[4].data.phase, "最后一条应为 complete")

      -- 步骤 5: 通过 state.fire_event 追加事件
      sm.fire_event("NeoAI:FullFlowTest", { phase = "cleanup" })

      -- 清理
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,

    -- ============================================================
    -- 流程 6: json → merger → state → tools 跨模块数据流
    -- ============================================================
    flow_full_cross_module_dataflow = function()
      -- 步骤 1: json 编解码工具配置
      local json = require("NeoAI.utils.json")
      local tool_config = {
        name = "cross_module_test",
        params = { type = "object" },
        approval = { auto_allow = true },
      }
      local encoded = json.encode(tool_config)
      local decoded = json.decode(encoded)
      assert.equal("cross_module_test", decoded.name, "json 往返后 name 应相等")
      assert.equal(true, decoded.approval.auto_allow, "json 往返后嵌套布尔值应相等")

      -- 步骤 2: 配置合并
      local merger = require("NeoAI.core.config.merger")
      merger.process_config({})

      -- 步骤 3: 状态管理器存储工具配置
      local sm = require("NeoAI.core.config.state")
      sm.set_global("cross_module_encoded", encoded)
      local retrieved = sm.get_global("cross_module_encoded")
      assert.equal(encoded, retrieved, "全局存储的编码字符串应不变")

      -- 步骤 4: 在协程上下文中使用
      local ctx = sm.create_context({ tool_name = decoded.name })
      sm.with_context(ctx, function()
        local shared = sm.get_shared()
        assert.equal("cross_module_test", shared.tool_name, "上下文中的 tool_name 应正确")
      end)

      sm._test_reset()
    end,

    -- ============================================================
    -- 流程 7: language_map + lsp_utils 语言支持链
    -- ============================================================
    flow_full_language_support = function()
      local lm = require("NeoAI.utils.language_map")
      local lu = require("NeoAI.utils.lsp_utils")

      -- 步骤 1: 验证语言映射完整性
      local exts = { "py", "lua", "js", "ts", "go", "rs", "java", "c", "cpp", "rb", "php" }
      for _, ext in ipairs(exts) do
        local lang = lm.lang_from_ext(ext)
        assert.not_nil(lang, "扩展名 ." .. ext .. " 应有对应语言")
        assert.type_eq("string", lang, "." .. ext .. " 的语言名应为字符串")
      end

      -- 步骤 2: 验证解析器映射
      for _, ext in ipairs(exts) do
        local parser = lm.parser_from_ext(ext)
        assert.not_nil(parser, "." .. ext .. " 应有对应解析器")
      end

      -- 步骤 3: 验证 LSP 配置映射
      local fts = { "lua", "python", "javascript", "typescript", "go", "rust" }
      for _, ft in ipairs(fts) do
        local lsp_config = lm.lsp_config_from_ft(ft)
        if lsp_config then
          assert.type_eq("string", lsp_config, ft .. " 的 LSP 配置名应为字符串")
          -- 验证有对应的 LSP 命令
          local cmd = lm.lsp_cmd(lsp_config)
          assert.not_nil(cmd, lsp_config .. " 应有对应的 LSP 命令")
        end
      end

      -- 步骤 4: 验证外部格式化器
      local formatters_ft = { "python", "lua", "javascript", "go", "rust" }
      for _, ft in ipairs(formatters_ft) do
        local formatters = lm.formatters_for_ft(ft)
        if formatters then
          assert.type_eq("table", formatters, ft .. " 的格式化器列表应为表")
          for _, fmt in ipairs(formatters) do
            assert.not_nil(fmt.cmd, "格式化器应有 cmd 字段")
            assert.not_nil(fmt.name, "格式化器应有 name 字段")
          end
        end
      end

      -- 步骤 5: 验证 LSP 工具函数
      assert.type_eq("boolean", lu.check_lsp(), "check_lsp 应返回布尔值")
      local kind_name = lu.safe_symbol_kind_name(12)
      assert.type_eq("string", kind_name, "safe_symbol_kind_name 应返回字符串")
    end,

    -- ============================================================
    -- 流程 8: file_utils → language_map 文件操作链
    -- ============================================================
    flow_full_file_language = function()
      local fu = require("NeoAI.utils.file_utils")
      local lm = require("NeoAI.utils.language_map")

      -- 步骤 1: 创建各种扩展名的临时文件
      local test_files = {
        { path = os.tmpname() .. ".lua", ext = "lua", content = "return {}" },
        { path = os.tmpname() .. ".py", ext = "py", content = "print('hello')" },
        { path = os.tmpname() .. ".js", ext = "js", content = "console.log('hi')" },
      }

      for _, tf in ipairs(test_files) do
        fu.write_file(tf.path, tf.content)

        -- 步骤 2: 验证文件存在
        assert.is_true(fu.exists(tf.path), "文件 " .. tf.path .. " 应存在")

        -- 步骤 3: 提取扩展名并映射语言
        local filename = fu.get_filename(tf.path)
        local ext = filename:match("%.([^.]+)$")
        if ext then
          local lang = lm.lang_from_ext(ext)
          assert.not_nil(lang, "扩展名 " .. ext .. " 应映射到语言")
          assert.equal(lm.lang_from_ext(tf.ext), lang, "语言映射应一致")
        end

        -- 步骤 4: 清理
        os.remove(tf.path)
      end
    end,

    -- ============================================================
    -- 流程 9: common → merger → state → tools 深度嵌套
    -- ============================================================
    flow_full_deep_nested = function()
      local common = require("NeoAI.utils.common")

      -- 步骤 1: 构建深度嵌套数据结构
      local deep = {
        level1 = {
          level2 = {
            level3 = {
              value = "deep_value",
              array = { 1, 2, { nested_in_array = true } },
            },
          },
        },
      }

      -- 步骤 2: 深拷贝
      local copied = common.deep_copy(deep)
      assert.equal("deep_value", copied.level1.level2.level3.value, "深度拷贝的值应正确")
      assert.equal(true, copied.level1.level2.level3.array[3].nested_in_array,
        "数组中嵌套对象应正确拷贝")

      -- 步骤 3: 深合并
      local override = {
        level1 = {
          level2 = {
            level3 = {
              new_field = "added",
            },
          },
        },
      }
      local merged = common.deep_merge(deep, override)
      assert.equal("deep_value", merged.level1.level2.level3.value, "深合并应保留原有值")
      assert.equal("added", merged.level1.level2.level3.new_field, "深合并应添加新字段")
    end,

    -- ============================================================
    -- 流程 10: 完整清理链（模拟 shutdown）
    -- ============================================================
    flow_full_cleanup = function()
      -- 步骤 1: 重置审批状态
      local as = require("NeoAI.tools.approval_state")
      as.reset()

      -- 步骤 2: 重置状态管理器
      local sm = require("NeoAI.core.config.state")
      sm._test_reset()

      -- 步骤 3: 重置关闭标志
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()

      -- 步骤 4: 清理测试数据文件
      local config_file = vim.fn.stdpath("config") .. "/neoai_keymaps.json"
      pcall(os.remove, config_file)

      -- 步骤 5: 验证所有模块状态已清理
      local global = as.get_global_config()
      assert.type_eq("table", global, "审批状态重置后全局配置应为空表")

      assert.is_false(sf.is_set(), "关闭标志应已重置")

      -- 全局状态应已清空
      assert.is_nil(sm.get_global("cross_module_encoded"),
        "state _test_reset 应清空全局数据")
    end,
  }

  return test_module.run_tests(tests)
end

return M
