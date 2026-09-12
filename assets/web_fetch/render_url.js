#!/usr/bin/env node
/*
 * NeoAI web_fetch 渲染器（Playwright + 注入 JS + turndown）
 * ----------------------------------------------------------------------------
 * 由 lua/NeoAI/tools/builtin/web_fetch.lua 经 bash 调用：
 *
 *   bash -c "export ...; exec node <install_dir>/render_url.js <opts.json>"
 *
 * 设计要点：
 *   - 选项经「JSON 文件」传入（argv[2]），避免命令行引号/转义地狱。
 *   - 本文件与 node_modules 同处 install_dir，require("playwright") 等按
 *     Node 标准解析即可，无需额外 NODE_PATH。
 *   - 全部结果（含错误）以 JSON 打到 stdout；诊断信息走 stderr。
 *   - 退出码：0 成功；非 0 失败（stdout 仍为 {ok:false,error}）。
 */

"use strict";

const fs = require("fs");
const path = require("path");

/** 把任意错误对象转成可读字符串 */
function errStr(e) {
  if (!e) return "unknown error";
  if (typeof e === "string") return e;
  return e.stack || e.message || String(e);
}

/** 统一收尾：打印 JSON 并结束进程 */
function emit(payload, code) {
  try {
    process.stdout.write(JSON.stringify(payload));
  } catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: errStr(e) }));
  }
  process.exit(code == null ? 0 : code);
}

/** 规范化引擎名 */
function pickEngine(name) {
  const key = (name || "chromium").toLowerCase();
  if (key === "firefox" || key === "webkit" || key === "chromium") return key;
  return "chromium";
}

async function main() {
  const optsPath = process.argv[2];
  if (!optsPath) {
    emit({ ok: false, error: "usage: node render_url.js <opts.json>" }, 2);
    return;
  }

  let opts;
  try {
    opts = JSON.parse(fs.readFileSync(optsPath, "utf-8"));
  } catch (e) {
    emit({ ok: false, error: "读取选项失败: " + errStr(e) }, 2);
    return;
  }

  const url = opts.url;
  if (!url) {
    emit({ ok: false, error: "url 不能为空" }, 2);
    return;
  }

  const engine = pickEngine(opts.engine);
  const format = (opts.format || "markdown").toLowerCase();
  const navTimeout = Number(opts.nav_timeout_ms) > 0 ? Number(opts.nav_timeout_ms) : 30000;
  const waitMs = Number(opts.wait_ms) > 0 ? Number(opts.wait_ms) : 0;
  const scriptArgs = opts.script_args || {};

  // ---- 加载依赖（同目录 node_modules） ----
  let playwright, TurndownService;
  try {
    playwright = require("playwright");
    TurndownService = require("turndown");
  } catch (e) {
    emit({ ok: false, error: "缺少 Node 依赖(playwright/turndown): " + errStr(e) }, 3);
    return;
  }

  const browserType = playwright[engine];
  if (!browserType) {
    emit({ ok: false, error: "不支持的引擎: " + engine }, 2);
    return;
  }

  const launchArgs = [];
  // root/容器环境下 Chromium 需要 --no-sandbox
  if (engine === "chromium" && typeof process.getuid === "function" && process.getuid() === 0) {
    launchArgs.push("--no-sandbox", "--disable-dev-shm-usage");
  }

  let browser;
  try {
    browser = await browserType.launch({ headless: opts.headless !== false, args: launchArgs });
    const context = await browser.newContext(
      opts.user_agent ? { userAgent: opts.user_agent } : {}
    );
    const page = await context.newPage();

    // 可选：注入 Readability 库（脚本名为 readability 时）
    let injectedReadability = false;
    if (opts.need_readability) {
      try {
        const libPath = path.join(__dirname, "node_modules", "@mozilla", "readability", "Readability.js");
        if (fs.existsSync(libPath)) {
          const src = fs.readFileSync(libPath, "utf-8");
          await page.addInitScript({ content: src + "\n;window.Readability = Readability;\n" });
          injectedReadability = true;
        }
      } catch (e) { /* 忽略：脚本会自行降级 */ }
    }

    await page.goto(url, { waitUntil: "networkidle", timeout: navTimeout });

    if (opts.wait_selector) {
      await page.waitForSelector(opts.wait_selector, { timeout: navTimeout }).catch(() => {});
    }
    if (waitMs > 0) {
      await page.waitForTimeout(waitMs);
    }

    // ---- 注入并执行用户脚本 ----
    let scriptResult;
    if (opts.script_file && fs.existsSync(opts.script_file)) {
      const src = fs.readFileSync(opts.script_file, "utf-8");
      scriptResult = await page.evaluate(
        ({ code, args }) => {
          // eslint-disable-next-line no-new-func
          const fn = new Function("args", code);
          return fn(args);
        },
        { code: src, args: scriptArgs }
      );
    }

    // ---- 取最终内容 ----
    let html = await page.content();
    let title = await page.title();
    if (scriptResult && typeof scriptResult === "object" && scriptResult.html) {
      html = scriptResult.html;
      if (scriptResult.title) title = scriptResult.title;
    }

    let content;
    if (format === "html") {
      content = html;
    } else if (format === "text") {
      content = await page.evaluate(() => {
        const body = document.body || document.documentElement;
        return body ? body.innerText : "";
      });
    } else {
      const turndown = new TurndownService({
        headingStyle: "atx",
        codeBlockStyle: "fenced",
        bulletListMarker: "-",
      });
      content = turndown.turndown(html);
    }

    await browser.close();
    browser = null;

    emit({
      ok: true,
      url: url,
      title: title || "",
      engine: engine,
      format: format,
      readability: injectedReadability,
      content: content == null ? "" : String(content),
    }, 0);
  } catch (e) {
    emit({ ok: false, error: errStr(e) }, 1);
  } finally {
    if (browser) {
      try { await browser.close(); } catch (e) { /* ignore */ }
    }
  }
}

main().catch((e) => emit({ ok: false, error: errStr(e) }, 1));
