/*
 * NeoAI web_fetch 内置注入脚本：clean（通用去噪）
 *
 * 运行环境：浏览器页面上下文（由 render_url.js 经 page.evaluate 以
 *   new Function("args", <本文件内容>) 执行）。
 * 入参：args = { selector, url }
 * 行为：移除噪声元素、绝对化链接，并保留 article/main/body 作为正文根。
 *      图片不在此处理：render_url.js 会在脚本执行后把 <img> 转存到临时目录
 *      （images_dir）并原位替换为占位符，故此处的 <img> 最终会被丢弃/替换。
 * 返回：undefined —— Node 侧回退取 document.body.innerHTML（不含 head 样式）。
 *
 * 约定：脚本体可直接使用 `return`；不要使用 Node 的 require / module 等
 * 主机侧 API（此处无 Node 运行时）。
 */
args = args || {};

var selector = args.selector || "";

/* 常见噪声选择器：导航/页脚/广告/评论/侧栏/Cookie 横幅等 */
var NOISE = [
  "script", "style", "noscript", "template", "svg", "canvas", "iframe",
  "link", "meta", "head",
  "textarea", "select", "option", "input", "button",
  "nav", "header", "footer", "aside", "form",
  "[role=navigation]", "[role=banner]", "[role=contentinfo]", "[role=search]",
  "[aria-hidden=true]",
  ".ads", ".ad", ".adsbygoogle", ".advertisement", ".sponsor", ".sponsored",
  ".cookie", ".cookies", ".consent", ".gdpr",
  ".sidebar", ".side-bar", ".menu", ".nav", ".navbar", ".breadcrumb",
  ".comments", "#comments", ".related", ".share", ".social", ".toolbar"
];

NOISE.forEach(function (sel) {
  try {
    document.querySelectorAll(sel).forEach(function (node) {
      if (node && node.parentNode) node.parentNode.removeChild(node);
    });
  } catch (e) { /* 无效选择器直接忽略 */ }
});

/* 把相对 URL 绝对化，便于后续 Markdown 中链接/图片可用 */
var base = document.baseURI || (typeof location !== "undefined" && location.href) || "";
document.querySelectorAll("a[href]").forEach(function (a) {
  try { a.setAttribute("href", new URL(a.getAttribute("href"), base).href); } catch (e) {}
});
document.querySelectorAll("img[src]").forEach(function (img) {
  try { img.setAttribute("src", new URL(img.getAttribute("src"), base).href); } catch (e) {}
});

/* 收敛正文根：显式选择器 > article > main > body */
var root = null;
if (selector) {
  try { root = document.querySelector(selector); } catch (e) { root = null; }
}
if (!root) {
  root = document.querySelector("article") || document.querySelector("main");
}
if (root && root !== document.body && root.outerHTML) {
  document.body.innerHTML = root.outerHTML;
}

return undefined;
