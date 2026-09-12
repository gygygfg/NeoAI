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
  let exitCode = code == null ? 0 : code;

  let text;
  try {
    text = JSON.stringify(payload);
  } catch (e) {
    // 序列化失败（如循环引用）：退化为错误信封
    text = JSON.stringify({ ok: false, error: errStr(e) });
    exitCode = 1;
  }

  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    process.exit(exitCode);
  };

  // 关键：当 stdout 是管道（由 lua jobstart 调用）时，write 是异步的，
  // 若紧接着 process.exit()，管道缓冲区（通常 64KB/128KB）之外的数据会被
  // 直接丢弃，导致 JSON 被截断、下游解析失败（复杂大页面尤其明显）。
  // 因此必须等 write 回调（数据已写入内核管道）后再退出。
  try {
    process.stdout.write(text, finish);
  } catch (e) {
    try {
      process.stdout.write(JSON.stringify({ ok: false, error: errStr(e) }), finish);
    } catch (_) {
      finish();
    }
  }

  // 兜底：极端情况下 write 回调未触发时避免进程悬挂（unref 不阻塞自然退出）
  const guard = setTimeout(finish, 30000);
  if (guard && typeof guard.unref === "function") guard.unref();
}

/** 规范化引擎名 */
function pickEngine(name) {
  const key = (name || "chromium").toLowerCase();
  if (key === "firefox" || key === "webkit" || key === "chromium") return key;
  return "chromium";
}

// ============================ 图片转存 ============================
// 目标：把正文中的图片过滤掉（不把 base64/二进制塞进 Markdown），改为
// 写入 images_dir（由 Lua 侧用 `mktemp -d` 创建），并把每个 <img> 原位替换为
// 纯字母数字哨兵，转换后再还原为 `[image: <绝对路径>]`。
// 说明：哨兵用纯 [A-Za-z0-9] 字符，turndown 不会对其转义；直接写 `[...]`
// 则可能被转义成 `\[...\]`。

const IMG_SENTINEL_PREFIX = "NEoAIIMG";
const IMG_SENTINEL_SUFFIX = "END";

const EXT_BY_MEDIA = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/svg+xml": "svg",
};

/** 按 magic bytes 嗅探图片媒体类型（可靠优先于 URL 扩展名/content-type）。 */
function sniffMediaType(buf) {
  if (!buf || buf.length < 4) return null;
  if (buf.length >= 8 && buf.toString("latin1", 0, 8) === "\x89PNG\r\n\x1a\n") return "image/png";
  if (buf[0] === 0xff && buf[1] === 0xd8) return "image/jpeg";
  if (buf.toString("latin1", 0, 4) === "GIF8") return "image/gif";
  if (buf.length >= 12 && buf.toString("latin1", 0, 4) === "RIFF" && buf.toString("latin1", 8, 12) === "WEBP") {
    return "image/webp";
  }
  const head = buf.toString("utf8", 0, Math.min(256, buf.length));
  if (/<svg[\s>]/i.test(head)) return "image/svg+xml";
  return null;
}

/** 由媒体类型 / content-type / URL 扩展名推断扩展名（magic bytes 优先）。 */
function extFor(buf, contentType, url) {
  const sniffed = sniffMediaType(buf);
  if (sniffed && EXT_BY_MEDIA[sniffed]) return EXT_BY_MEDIA[sniffed];
  const ct = (contentType || "").split(";")[0].trim().toLowerCase();
  if (EXT_BY_MEDIA[ct]) return EXT_BY_MEDIA[ct];
  const m = (url || "").split(/[?#]/)[0].match(/\.([a-z0-9]+)$/i);
  if (m && /^(png|jpe?g|gif|webp|svg)$/i.test(m[1])) return m[1].toLowerCase();
  return "bin";
}

/** 解析 data: URL（图片），返回 { buf, mediaType }；非 data 或解码失败返回 null。 */
function decodeDataUrl(url) {
  const m = /^data:([^;,]*)?(;base64)?,(.*)$/is.exec(url || "");
  if (!m) return null;
  const mediaType = (m[1] || "").trim().toLowerCase();
  const isB64 = !!m[2];
  const payload = m[3] || "";
  try {
    const buf = isB64
      ? Buffer.from(payload, "base64")
      : Buffer.from(decodeURIComponent(payload), "utf8");
    return { buf, mediaType };
  } catch (e) {
    return null;
  }
}

/** 下载 http(s) 图片字节：先用浏览器上下文请求（带 cookie/UA），失败回退全局 fetch。 */
async function fetchImageBytes(url, page, timeoutMs, maxBytes) {
  const tryFetch = async () => {
    const resp = await page.context().request.get(url, { timeout: timeoutMs, maxRedirects: 5 });
    if (!resp.ok()) throw new Error("HTTP " + resp.status());
    return { buf: await resp.body(), contentType: resp.headers()["content-type"] || "" };
  };
  const doFetch = async () => {
    if (typeof fetch !== "function") throw new Error("无 fetch 可用");
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const resp = await fetch(url, { signal: ctrl.signal });
      if (!resp.ok) throw new Error("HTTP " + resp.status);
      return { buf: Buffer.from(await resp.arrayBuffer()), contentType: resp.headers.get("content-type") || "" };
    } finally {
      clearTimeout(t);
    }
  };
  let r;
  try {
    r = await tryFetch();
  } catch (e) {
    r = await doFetch();
  }
  if (maxBytes > 0 && r.buf && r.buf.length > maxBytes) throw new Error("超过单张上限");
  return r;
}

/**
 * 提取并转存页面中的图片，原位替换为哨兵。
 * @returns {{ images: Array, maxImages: number }} images 项 { index, path, bytes, mediaType, url }
 */
async function handleImages(page, opts) {
  const result = { images: [], maxImages: 0 };
  const dir = opts.images_dir;
  if (!dir) return result;

  const maxImages = Number(opts.max_images) >= 0 ? Number(opts.max_images) : 50;
  const maxBytes = Number(opts.max_image_bytes) > 0 ? Number(opts.max_image_bytes) : 5 * 1024 * 1024;
  const timeoutMs = Number(opts.image_timeout_ms) > 0 ? Number(opts.image_timeout_ms) : 15000;
  result.maxImages = maxImages;

  // 1) 快照所有 <img> 的 src（读取后即为字符串，DOM 变动不受影响）
  let srcs = [];
  try {
    srcs = await page.evaluate(() =>
      Array.from(document.images).map((im) => im.currentSrc || im.src || "")
    );
  } catch (e) {
    srcs = [];
  }

  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch (e) {
    return result; // 无法建目录：放弃转存（后续哨兵会回退到原始 URL）
  }

  // 2) 逐张存盘（仅前 maxImages 张）
  const stamp = Date.now();
  for (let i = 0; i < srcs.length; i++) {
    const url = srcs[i];
    const item = { index: i, path: null, bytes: 0, mediaType: null, url: url };
    if (i < maxImages && url && !/^data:image\/svg/i.test(url)) {
      try {
        let buf = null;
        let mediaType = null;
        const d = decodeDataUrl(url);
        if (d) {
          buf = d.buf;
          mediaType = d.mediaType;
        } else if (/^https?:/i.test(url)) {
          const r = await fetchImageBytes(url, page, timeoutMs, maxBytes);
          buf = r.buf;
          mediaType = r.contentType;
        }
        if (buf && buf.length > 0 && !(maxBytes > 0 && buf.length > maxBytes)) {
          const ext = extFor(buf, mediaType, url);
          const fname = "img_" + stamp + "_" + i + "." + ext;
          fs.writeFileSync(path.join(dir, fname), buf);
          item.path = path.join(dir, fname);
          item.bytes = buf.length;
          item.mediaType = sniffMediaType(buf) || (mediaType || "") || null;
        }
      } catch (e) {
        // best-effort：失败则 item.path 保持 null，占位符回退为原始 URL
      }
    }
    result.images.push(item);
  }

  // 3) 单次 evaluate 将所有 <img> 原位替换为哨兵（含超出上限的，供后续移除）
  try {
    await page.evaluate((args) => {
      const pre = args.pre;
      const suf = args.suf;
      Array.from(document.images).forEach((im, i) => {
        if (im && im.parentNode) {
          im.parentNode.replaceChild(document.createTextNode(pre + i + suf), im);
        }
      });
    }, { pre: IMG_SENTINEL_PREFIX, suf: IMG_SENTINEL_SUFFIX });
  } catch (e) { /* 忽略：哨兵未替换则图片仍会经 stripNoise 被丢弃 */ }

  return result;
}

/** 把正文里的图片哨兵还原为 `[image: <路径>]`（失败回退 `[image: <原始URL>]`；超限直接移除）。 */
function replaceImageSentinels(content, images, maxImages) {
  if (typeof content !== "string") return content;
  return content.replace(
    new RegExp(IMG_SENTINEL_PREFIX + "(\\d+)" + IMG_SENTINEL_SUFFIX, "g"),
    (whole, nStr) => {
      const i = Number(nStr);
      const im = images[i];
      if (!im) return "";
      if (im.path) return "[image: " + im.path + "]";
      const raw = (im.url || "").slice(0, 200);
      return raw ? "[image: " + raw + "]" : "";
    }
  );
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

    // ---- 图片：转存到 images_dir，原位替换为哨兵（best-effort） ----
    let imageInfo = { images: [], maxImages: 0 };
    try {
      imageInfo = await handleImages(page, opts);
    } catch (e) {
      // 忽略：图片处理失败不应阻断正文抓取
    }

    // ---- 取最终内容（只取正文，不含 <head> 的样式/脚本） ----
    let title = await page.title();
    if (scriptResult && typeof scriptResult === "object" && scriptResult.title) {
      title = scriptResult.title;
    }

    // 优先使用注入脚本返回的正文片段；否则只取 <body> 内部 HTML，
    // 从源头排除 <head> 中的 <style>/<link>/<meta> 等，避免 CSS 被当作正文
    // 混入 Markdown（如百度首页内联的数十万字节样式）。
    let bodyHtml;
    if (scriptResult && typeof scriptResult === "object" && scriptResult.html) {
      bodyHtml = scriptResult.html;
    } else {
      bodyHtml = await page.evaluate(() => {
        const body = document.body || document.documentElement;
        return body ? body.innerHTML : "";
      });
    }

    let content;
    if (format === "text") {
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
      // 兜底：忽略非正文 / 样式类标签，确保 Markdown 中不出现 HTML/CSS 噪声。
      // 即使正文根选择失误或脚本返回了带样式的片段，也能在此被剥离。
      // 注意：部分站点（如百度）把 CSS 放在 body 内隐藏的 <textarea> 中（实体转义），
      // turndown 会把 textarea 内容反转义为字面 <style>... 文本，故一并忽略表单控件。
      turndown.addRule("stripNoise", {
        filter: [
          "head", "style", "script", "noscript", "link", "meta",
          "template", "iframe", "svg", "canvas",
          "textarea", "select", "option", "input", "button",
        ],
        replacement: () => "",
      });
      content = turndown.turndown(bodyHtml);
      // 折叠 3 个及以上连续空行，并去掉首尾空白，让 Markdown 更整洁。
      content = content.replace(/\n{3,}/g, "\n\n").trim();
    }

    // 图片哨兵 → [image: 路径]（text/markdown 都适用；超限图片直接移除）
    content = replaceImageSentinels(content, imageInfo.images, imageInfo.maxImages);

    await browser.close();
    browser = null;

    emit({
      ok: true,
      url: url,
      title: title || "",
      engine: engine,
      format: format,
      readability: injectedReadability,
      images: imageInfo.images.map((im) => ({
        path: im.path,
        bytes: im.bytes,
        mediaType: im.mediaType,
        url: /^data:/i.test(im.url || "")
          ? "data:" + (im.mediaType || "") + " (" + (im.bytes || 0) + "B)"
          : (im.url || "").slice(0, 500),
      })),
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
