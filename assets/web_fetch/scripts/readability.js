/*
 * NeoAI web_fetch 内置注入脚本：readability（正文提取）
 *
 * 运行环境：浏览器页面上下文（render_url.js 经 page.evaluate 执行）。
 * 依赖：Node 侧会先注入 window.Readability（@mozilla/readability）。
 * 入参：args = { selector, url }
 * 返回：{ html, title } —— 提取到的正文 HTML 与标题；库缺失或解析失败时返回
 *   undefined，交由 Node 侧回退到原始 DOM。
 */
args = args || {};

if (typeof Readability === "undefined") {
  return undefined;
}

var clone = document.cloneNode(true);
var reader = new Readability(clone, { charThreshold: 140 });
var article = reader.parse();
if (!article || !article.content) {
  return undefined;
}

/* 同步替换 DOM，便于 text 模式下也能拿到提取后的正文 */
try { document.body.innerHTML = article.content; } catch (e) {}

return {
  html: article.content,
  title: article.title || (document.title || "")
};
