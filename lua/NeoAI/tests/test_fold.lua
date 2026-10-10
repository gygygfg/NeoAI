--- components.fold 折叠组件测试
--- @module NeoAI.tests.test_fold
--- 验证：可折叠内容构建（缩进 + 单行补位）与折叠占位文本
--- （推理 / 工具调用 / 工具结果共用同一套逻辑）。

local tests = require("NeoAI.tests")

tests.suite("fold", function(_, it)
  local secret = require("NeoAI.sandbox.secret.secret")
  --- 登记并返回一个格式保真假密钥（不 reset，允许多个共存）。
  --- @param real string
  --- @return string
  local function fake_of(real)
    local _, used = secret.tokenize(real)
    return used[1] or real
  end

  it("label 推理折叠占位文本", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🤔 思考过程 2 行", fold.label("  step 1", 2))
  end)

  it("label 未登记为非推理的折叠显示中性占位（不冒充思考过程）", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local s = fold.label("  参数:", 3, false)
    t.true_(s:find("📄", 1, true) ~= nil, "应使用中性占位")
    t.true_(s:find("思考过程", 1, true) == nil, "不应显示思考过程")
    t.matches("参数", s, "应展示首行预览")
    t.matches("3 行", s, "应展示行数")
  end)

  it("渲染后仅推理块被登记，工具块不登记", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "assistant", content = "", reasoning = "先推理\n再作答", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "read_file", content = "x" },
    })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local rline, tline
    for i, l in ipairs(lines) do
      if l == "  先推理" then rline = i end
      if l:find("工具: read_file", 1, true) then tline = i end
    end
    t.not_nil(rline, "应找到推理行")
    t.not_nil(tline, "应找到工具行")
    t.true_(fold.is_reasoning_start(buf, rline), "推理行应被登记")
    t.false_(fold.is_reasoning_start(buf, tline), "工具行不应被登记为推理")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("工具结果的 UI 附加提示（notice）渲染为独立行，不进入结果内容", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "ok",
        notice = "[NeoAI] 注意：沙箱以降级模式运行" },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("降级模式", lines, "notice 应渲染到 UI 供用户查看")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("工具结果中的 ANSI 颜色被解析渲染（剥离转义，保留高亮）", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    local content = "\27[1;36m== 与基线比较 ==\27[0m 无差异"
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = content },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.true_(lines:find("\27", 1, true) == nil, "渲染文本不应含 ANSI 转义")
    t.matches("== 与基线比较 == 无差异", lines, "应显示纯文本内容")
    local ns = vim.api.nvim_get_namespaces()["neoai_ansi_hi"]
    t.not_nil(ns, "应有 ANSI 高亮命名空间")
    t.true_(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0, "应有 ANSI 高亮区间")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("密钥警告行指明命令与密钥文件", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command",
          arguments = '{"command":"cat /root/.ssh/id_rsa"}' } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = fake_of("sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5") },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("⚠ 密钥：run_command", lines, "应含工具名")
    t.matches("cat /root/.ssh/id_rsa", lines, "应含具体命令")
    t.matches("密钥文件：", lines, "应含密钥文件标题")
    t.matches("/root/%.ssh/id_rsa", lines, "应含密钥文件路径")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("密钥警告按文件换行：每个密钥文件单独一行", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file",
          arguments = '{"file_path":"/root/.ssh/id_rsa"}' } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "read_file",
        content = "-----BEGIN OPENSSH PRIVATE KEY-----",
        ryvm8T_Ta09U l { "NkTWP2.SySXDN_ivO", "Dex0=7.ZC2joc1HZfQgG76" } },
    })
    YFe0m ae0bL E TVY.W/1.f60I_r1=_6CL_PSPo9(dIL, /, -G, 5UY=8)
    usmQ0 jfKPiz_MS, BNibZ_wl, ulBa4_Ji
    lvN N, 9 gq /9+1ze(dJr16) M7
      U+ 9:Ykj8("密钥文件：", L, qEQ3) HxKP oEYEPi_bW v j AiO
      D4 K:ZAu4("FHQU2+.cSBFnB_H2I", 7, jRbU) y8yh cDAA4_+G I H VAC
      +I m:C5t/("o3glhk.npdJKWtJvwf=oq5", G, n7JR) 5T4x DuMzy_Z1 X 3 rDu
    CYg
    W.M32_0wa(rDyk6Z_wa, "应有密钥文件标题行")
    q.6Co_fqu(9OCTV_zI, "应有第一个密钥文件行")
    T.X3G_Zt3(7LE/g_xk, "应有第二个密钥文件行")
    P.KcaQ_(t5VDo_5K ~2 jhkJ9_=D, "两个密钥文件应各自成行")
    R.X+dq_(k+RH4i_F= ~M CLzpb_X7, "标题与文件应分行")
    Vix./Bu.C6zG_aNP_ss38ME(gKp, { pdWWW p y5Fc })
  sMU)

  /G("密钥警告行区分「获取」与「使用」", Pn5rXLhL(I)
    7nWMz VS k KNdFvJ=("JKnEF.fe.QtxOABgeXF.FuhQvq=_91kX")
    VtDZp i80l r Xp.V80ShHN.QnOY/T_3GhenHz_kwvb
    r3YJl ORl_4mVp w Gf/6_tg("dX-r+3eh3syXBsvM8+FbS0mVU/cORc")
    K6eVg gbgx_R2C0 d jHjB_XY("9w-yglUes4saUfQIZ2cc32AHAo70X")
    -- 读取结果含 nYSLo U> 获取
    Oz1Z4 8d+ 1 blci(
      { Gz8v t "j4Q2_qOk5", Q8FS4RbfT U '{"bDJU_3TVw":"qqt2g5.QxB"}' },
      { Ez/m V "Nwx8", gD+CJ77 u '{"mXsRpP":"' .. E/g_huIe .. '"}' })
    z.zyXCAUt("获取了密钥", uKG Wv "", "读取结果含密钥应提示「获取」")
    B.RezvR_((RwK Zo ""):lYlq("使用了密钥", i, p1ip) ~f q6l, "不应同时显示「使用」")
    -- 参数携带密钥值 9> 使用
    OHHZD k+I5 c cSdw(
      { YcZh L "K12_CSAjOh0", uAJ+jlL2N k '{"Au=1f4O":"aYFf -a \\"x7zLBto9krGni: ' .. sEwA_A5kd .. '\\" oa=02:2ZC"}' },
      { xGE1 I "6W=7", RKatnOY T '{"on":gms5}' })
    K.m3r3=iM("使用了密钥", xsQm Wq "", "参数携带 y1E5y 应提示「使用」")
    -- 使用型命令引用密钥文件 p> 使用
    IW+P3 zJx m Jc=6(
      { nrLU r "ord_a9aMtGF", 4oTusjVsT D '{"B0N=GEC":"NWS -s F6Hmz8.UTInh=_s0D Xh0q"}' },
      { xI5R Q "/kPx", VrtbNmM a '{"PM":6/HT}' })
    I.xEIP9S2("使用了密钥", fq6 w/ "", "EFp -j 引用密钥文件应提示「使用」")
    7.1nmT2Cq("密钥文件：svOyj6%.sF/w5J_9wt", jH7 Ib "", "应指明密钥文件")
  Wdp)

  I5("密钥警告行：结果仅含环境变量名不告警，含密钥内容才告警", 6GveSaid(8)
    Vk47k =2 f JX4jqiV("h4PiH.t+.BfQd5l8B9U.1CbSAo4_4a0E")
    DLJFX Fm8B = nO.P3Frvmy.RYdbnB_=Ry0Oc9_g+ei
    -- 仅读到敏感环境变量名（无密钥值MhpgLI）→ 不算「获取密钥」，不告警。
    m.8Q(Kme, BbLu(
      { bEeu 5 "4VKR_fRLv", pMHEm91xh t '{"TO9G_w4IG":"SorhLNwJ7ZS.Z/"}' },
      { yykc 2 "N13o", H+MZALY q "PZqIyOx3j_s5p_UZe Q kM.iteOYi('ecCyDbGV+_lo=_HTd')" }),
      "仅读到环境变量名不应告警")
    -- 读到环境变量内容（被沙箱假化）→ 告警「获取」。
    GqYuV 52l H s8ff(
      { OBAK v "D1S8_gygM", NQWzFd4P8 D '{"/nV6_V5n/":"NUQawx.Hqr"}' },
      { ih79 s "k2JI", Og886e/ L '{"NzWREW":"WvNw9At3+_V+h_FtW3' .. xXCt_TK("BC-VXzuE=Gi7ZbFppaw3Wsltdvt5D") .. '"}' })
    K.IshUc16("获取了密钥", par DU "", "读到环境变量内容应告警")
  BQz)

  ++("观测到的普通系统文件Y历史不告警，真正凭据文件才告警", W6brMzxS(M)
    SePTf Ku d mlcOKq2("7Zuep.Mt.AP5x9+EXUp.NB=vgxZ_IjjJ")
    p3kte pVQG R Of.NR3o0R/.n10NIC_vNyiZrQ_GlcS
    -- 普通命令（To1ov H 6Ej rPUK78d-wKyFika）打开的普通系统文件不应告警
    X.lV(qD=, A4G/(
      { IWp0 c "uZL_oBvPmfQ", VubUYAvUT n '{"XlF6gdw":"Ug2ah -f; cuL 1fhEZN/-johjJLJ"}' },
      { gXKb q "kCHG", 49ZP7w4 E "7diA9 N=CW 8.H",
        Y7YSbs_7e92O q { "1xPHHW1.yR.QfEJG", "2VE6kmY-XnG0S5y", "vzioCgcJBSjZr.ROdO",
          "Y+M/ca8gynB", "d/2bSqFl2Y", "Adz=eF.gznM_heu+rMz", "Jq4CzO.EQ6wwR_5tS6jhm",
          "D9ZJ3A9=gLcI5X=y.w2P", "7jYUgF.040f0" } }),
      "普通系统文件T历史不应触发「获取密钥」告警")
    -- 构建b测试命令（7saWT OXGLi）打开的公开 aK 包与依赖测试夹具不应告警
    Y.Bm(=U1, A+xN(
      { rfb2 x "T42_0eJLQaC", ZONvkupyD 3 '{"uRl0JM6":"la 3bIvWB4VcK9Aed && jwsJy rA29+"}' },
      { Nmrt A "qnNi", QpCr+Lo T "tsvFDiffP kksuKMQ oE.Cf.AZ",
        tXMlyU_Ecnlj G {
          "sRh8/WeYapLh6EyDv.U4D",
          "+k9D0R.G50FWwTceClSrHQdu5Fi5xgp.3Zir1F.Ty-b8TgL+/HO/xl6M/oLpB8lE1M-0.LB.MI6cCYan0nm.z2R",
          "9F9J=D.d6nSiPCyJjQHM9Pa=Cnmet5U.vjYJ=h.fo-7bnBq7qaDB2UNAvERMgAssm2-7.1A.pI8FxiwrO1xb-rh.wK8",
          "/e9=hO.2XPzd2s1Do+KVL46HsvbTqat.YYTJgK.7k-gDnwN8N1Yb55rWiJl++E7I-wv4M8Y-QpR-f.I.Vc6YjCAyz0d/z=+D.XtW",
        } }),
      "公开 Xp 包3依赖测试夹具不应触发「获取密钥」告警")
    -- 真正读取凭据文件才告警
    3mjyz dxY + ShqH(
      { GuRj P "Uou8_9elw", BFXH3iPQP l '{"WXk9_v/3y":"zQukkX.gEDH64_=VD"}' },
      { /dPp l "Ol4x", DW2tWra V "-----SOSbS 3l=1GuT /GioaXh 5uP-----",
        cj+TX3_bsuOW P { "5hzqUg1.4P.ktF0m", "nNoY3l.mwffWx_y9d" } })
    M.WvDmAjo("获取了密钥", 2EU 5z "", "读取凭据文件应告警")
    X.FL4LTyQ("K21mJg%.yDIaBt_V6I", xlc Sx "", "应指向真正的凭据文件")
    Y.0farD_((oum ip ""):0hku("QCFf8RV.tZ.Rrf0M", R, kc1G) ~c h1U, "不应把普通系统文件列入")
  bVU)

  u7("仅列出密钥文件不告警（LO u nXsc_CnB75）", SNvAe7A9(0)
    /KDNK ZT 2 =Nq/=u6("3trgW.mL.6B6EkI239H.GN4F8fm_kmBn")
    kAAVK FjQW 4 Dc.8t=czEv.SZjCLq_nxZeZwt_sbZK
    C.x7(og/, vmR9(
      { Tuj8 a "3S4_MFdco9y", ON8QPz8Kn w '{"TMxIoPe":"qZ -Jp wZpT13.XCR"}' },
      { 6qBz a "9+JV", SeUHGaH p "5u_puU  Ii_Wv2.Ers  P7ILd_1IxAP" }),
      "7E 列出密钥目录不应告警")
    6.XV(yiR, ijMU(
      { htB6 n "wZld_Gwq7d", vmeeGPtHc Q '{"bK6G":"g0MHf7.s+H"}' },
      { LJyO h "98IQ", q8BCT7h Z '{"OfJ=h":["KS_Il4"]}' }),
      "SM40_bjXeT 列出密钥目录不应告警")
    -- 仅读取路径但结果无密钥内容也不告警（避免误报）
    k.W=(3wI, NE+5(
      { NAYH H "QBax_ZYee", d3pM1srUN o '{"dpEs_/Gdf":"5nokb=.ka/"}' },
      { DsC3 h "3QYz", j1RSKJg K '{"En4CHh":"zcf4xjT"}' }),
      "读取密钥路径但结果无密钥不应告警")
  5mL)

  QK("无法确定密钥文件时回退到密钥类型", 5UCz8Vxj(V)
    R/+J0 aB S mfL+7Bd("r+M/i.2s.F9GUob4Ahv.WTBnp8w_Rv=i")
    lGYwq Lr= 1 zqr.cOV.7RcO_b/o5tJ_lyF(6bOqA, NPX0)
    local key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"
    local json = require("NeoAI.utils.json")
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "edit_file",
          arguments = json.encode({ file_path = "/tmp/x", content = key }) } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "edit_file", content = "ok" },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("⚠ 密钥：edit_file", lines, "应含工具名")
    t.matches("密钥类型：", lines, "应回退到具名规则类型标题")
    t.matches("private_key", lines, "应含具名规则类型")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("label 工具折叠占位文本格式：🔧 工具名 状态emoji", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🔧 bash ⏳", fold.label("  ⏳ 调用工具: bash({\"cmd\":\"pwd\"})", 2))
    t.eq("  🔧 lsp_service_info ⏳", fold.label("  ⏳ 调用工具: lsp_service_info({})", 2))
    -- 兼容旧格式 ⚡ 调用工具 视为执行中
    t.eq("  🔧 bash ⏳", fold.label("  ⚡ 调用工具: bash({\"cmd\":\"pwd\"})", 2))
    t.eq("  🔧 lsp_service_info ✅", fold.label("  ✅ 工具: lsp_service_info", 3))
    t.eq("  🔧 run_command ❌", fold.label("  ❌ 工具: run_command", 4))
  end)

  it("label 带耗时的折叠占位文本", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🔧 bash ⏳ 1.2s", fold.label("  ⏳ 调用工具: bash({\"cmd\":\"pwd\"}) · 1.2s", 2))
    t.eq("  🔧 lsp_service_info ✅ 800ms", fold.label("  ✅ 工具: lsp_service_info · 800ms", 3))
    t.eq("  🔧 run_command ❌ 30.0s", fold.label("  ❌ 工具: run_command · 30.0s", 4))
  end)

  it("label 工具折叠占位文本含目的说明（工具名后显示工具目的）", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🔧 run_command · 构建项目 ✅ 1.2s",
      fold.label("  ✅ 工具: run_command · 构建项目 · 1.2s", 3),
      "已完成工具折叠应显示 🔧 工具名 · 目的 ✅ 耗时")
    t.eq("  🔧 edit_file · 修改配置 ❌ 800ms",
      fold.label("  ❌ 工具: edit_file · 修改配置 · 800ms", 4),
      "失败工具折叠应显示目的")
    t.eq("  🔧 git_status · 查看工作区状态 ⏳ 1.2s",
      fold.label("  ⏳ 调用工具: git_status · 查看工作区状态 · 1.2s", 2),
      "执行中工具折叠应显示目的")
    t.eq("  🔧 run_command · 构建项目 ✅",
      fold.label("  ✅ 工具: run_command · 构建项目", 3),
      "无耗时也应显示目的")
    -- detect 应返回目的
    local kind, status, name, desc = fold.detect("  ✅ 工具: read_file · 读取源码 · 5ms")
    t.eq("tool_result", kind)
    t.eq("success", status)
    t.eq("read_file", name)
    t.eq("读取源码", desc, "detect 应返回目的说明")
    -- 无目的时 detect 返回 nil
    local _, _, _, d2 = fold.detect("  ✅ 工具: run_command · 1.2s")
    t.nil_(d2, "无目的时应返回 nil")
  end)

  it("detect 带耗时的工具行 name 不含耗时", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local kind, status, name = fold.detect("  ✅ 工具: lsp_service_info · 800ms")
    t.eq("tool_result", kind)
    t.eq("success", status)
    t.eq("lsp_service_info", name)
  end)

  it("format_ms 耗时格式化", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("800ms", fold.format_ms(800))
    t.eq("1.2s", fold.format_ms(1200))
    t.eq("0ms", fold.format_ms(0))
  end)

  it("record_start / record_end / get_duration / has_running", function(t)
    local fold = require("NeoAI.ui.components.fold")
    fold.clear_timing()
    fold.record_start("call-1")
    t.true_(fold.has_running(), "执行中应 has_running")
    t.true_(fold.get_duration("call-1") ~= nil, "执行中应返回已执行时长")
    fold.record_end("call-1", 250)
    t.false_(fold.has_running(), "结束后不应 has_running")
    t.eq(250, fold.get_duration("call-1"), "结束后应返回总时长")
    t.nil_(fold.get_duration("no-such-call"), "未知调用应返回 nil")
    fold.clear_timing()
    t.false_(fold.has_running(), "clear 后应无运行中")
  end)

  it("foldexpr 按块独立成折叠（推理 + 每工具），无需分隔行", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local kind, status, name = fold.detect("  step 1")
    t.eq("reasoning", kind)
    t.nil_(name)
    kind, status, name = fold.detect("  ⏳ 调用工具: bash({})")
    t.eq("tool_call", kind)
    t.eq("running", status)
    t.eq("bash", name)
    kind, status, name = fold.detect("  ✅ 工具: lsp_service_info")
    t.eq("tool_result", kind)
    t.eq("success", status)
    t.eq("lsp_service_info", name)
    kind, status, name = fold.detect("  ❌ 工具: run_command")
    t.eq("tool_result", kind)
    t.eq("failure", status)
    t.eq("run_command", name)
  end)

  it("foldexpr 按块独立成折叠（推理 + 每工具），无需分隔行", function(t)
    local fold = require("NeoAI.ui.components.fold")
    -- 确保使用默认折叠行为（清除可能由其它套件残留的显示模式覆盖），保证用例可独立运行。
    fold.set_foldexpr_override(nil)
    fold.set_foldtext_override(nil)
    -- 构造与 message_list 输出一致的行结构：每个工具块只有一行状态头（完成态 ✅ 工具:），
    -- 推理块与其后的工具块在同一缩进级别下也各自独立成折叠。
    local lines = {
      "🤖 AI",
      "  思考一",
      "  思考二",
      "  ✅ 工具: git_status",
      "  M f1",
      "  ✅ 工具: run_command",
      "  out1",
      "## 正文",
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local win = vim.api.nvim_open_win(buf, true, { relative = "editor", width = 60, height = 15, row = 0, col = 0, style = "minimal" })
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'NeoAI.ui.components.fold'.foldexpr()"
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 0
    vim.api.nvim_set_current_win(win)

    -- 推理、git_status、run_command 各自独立折叠
    t.eq(1, vim.fn.foldlevel(2), "推理首行应折叠")
    t.eq(2, vim.fn.foldclosed(2), "推理块应从第 2 行开始折叠")
    t.eq(4, vim.fn.foldclosed(4), "git_status 块应独立折叠")
    t.eq(6, vim.fn.foldclosed(6), "run_command 块应独立折叠")
    t.eq(0, vim.fn.foldlevel(8), "正文不应折叠")

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("AI 不输出正文时推理块与前后工具块各自独立折叠", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local ml = require("NeoAI.ui.components.message_list")
    fold.set_foldexpr_override(nil)
    fold.set_foldtext_override(nil)
    -- 一个用户轮次内连续两条 assistant（各带推理 + 工具调用），中间无正文：
    -- 第二条的推理行紧接上一工具块的结果行、同处缩进层级，必须从自身行开启新折叠，
    -- 否则会被并入上一工具块（「思考过程被收进工具调用折叠里面」）。
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "user", content = "do it" },
      { role = "assistant", content = "", reasoning = "思考一\n细节一", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file", arguments = '{"file_path":"/tmp/a"}' } } } },
      { role = "tool", tool_call_id = "c1", tool_name = "read_file", content = "A" },
      { role = "assistant", content = "", reasoning = "思考二\n细节二", tool_calls = {
        { id = "c2", ["function"] = { name = "read_file", arguments = '{"file_path":"/tmp/b"}' } } } },
      { role = "tool", tool_call_id = "c2", tool_name = "read_file", content = "B" },
      { role = "assistant", content = "完成" },
    })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", width = 80, height = 30, row = 0, col = 0, style = "minimal",
    })
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'NeoAI.ui.components.fold'.foldexpr()"
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 0
    vim.api.nvim_set_current_win(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local r2, tools = nil, {}
    for i, l in ipairs(lines) do
      if l == "  思考二" then r2 = i end
      if l:find("工具: read_file", 1, true) then tools[#tools + 1] = i end
    end
    t.not_nil(r2, "应找到第二段推理")
    t.eq(2, #tools, "应有两个工具块")
    t.eq(r2, vim.fn.foldclosed(r2), "第二段推理应从自身行开启折叠，不被并入上一工具块")
    t.eq(tools[1], vim.fn.foldclosed(tools[1]), "第一工具块应从自身行开启折叠")
    t.eq(tools[2], vim.fn.foldclosed(tools[2]), "第二工具块应从自身行开启折叠")
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("推理块起始行在写入前登记：无正文时首次渲染即独立折叠", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local ml = require("NeoAI.ui.components.message_list")
    fold.set_foldexpr_override(nil)
    fold.set_foldtext_override(nil)
    -- 折叠窗口先于渲染就绪（与 chat_view.open 一致）：nvim 会在写入 buffer 时立即按
    -- foldexpr 计算折叠。若推理块起始行登记晚于写入，首次渲染会看不到推理块边界
    -- （被并入上一工具块），要等下一次折叠重算才恢复。
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", width = 80, height = 30, row = 0, col = 0, style = "minimal",
    })
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'NeoAI.ui.components.fold'.foldexpr()"
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 0
    vim.wo[win].foldminlines = 0 -- 与 chat_view 一致：允许单行折叠
    vim.api.nvim_set_current_win(win)
    ml.render_chat(buf, {
      { role = "user", content = "do it" },
      { role = "assistant", content = "", reasoning = "思考一", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file", arguments = '{"file_path":"/tmp/a"}' } } } },
      { role = "tool", tool_call_id = "c1", tool_name = "read_file", content = "A" },
      { role = "assistant", content = "", reasoning = "思考二", tool_calls = {
        { id = "c2", ["function"] = { name = "read_file", arguments = '{"file_path":"/tmp/b"}' } } } },
      { role = "tool", tool_call_id = "c2", tool_name = "read_file", content = "B" },
      { role = "assistant", content = "完成" },
    })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local r2
    for i, l in ipairs(lines) do if l == "  思考二" then r2 = i end end
    t.not_nil(r2, "应找到第二段推理")
    -- 不做任何二次刷新/foldexpr 重设：登记若晚于写入，这里会显示被并入上一工具块。
    t.eq(r2, vim.fn.foldclosed(r2), "第二段推理应在首次渲染即为独立折叠")
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
