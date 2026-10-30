// Enigma's article extraction (F29, spec §4). Runs after Readability.js and
// Readability-readerable.js in one callAsyncJavaScript body, in the isolated
// "EnigmaExtract" content world of a sealed WKWebView: page scripts are off and
// every load is blocked. `pageHTML` (an argument) is the page's HTML, read here
// only as a string to find JSON-LD, which WebKit leaves out of the DOM when page
// scripts are off (CP0 Q2). Returns a JSON string; nothing else leaves this world.

const MAX_TOTAL_CHARACTERS = 200000; // D68
const MAX_BLOCK_CHARACTERS = 20000;
const MAX_JSONLD_BLOCKS = 20;
const MAX_JSONLD_CHARACTERS = 200000;

function collapse(text) {
  return (text || "").replace(/\s+/g, " ").trim();
}

// MARK: Metadata

const metas = new Map();
for (const meta of document.querySelectorAll("meta")) {
  const key = (meta.getAttribute("property") || meta.getAttribute("name") || meta.getAttribute("itemprop") ||
    meta.getAttribute("http-equiv") || "").trim().toLowerCase();
  const content = meta.getAttribute("content");
  if (key && content && content.trim() && !metas.has(key)) metas.set(key, content.trim());
}
function metaValue(...keys) {
  for (const key of keys) {
    if (metas.has(key)) return metas.get(key);
  }
  return null;
}

// JSON-LD, by string scan of the HTML.
const jsonLDNodes = [];
(function scanJSONLD() {
  if (typeof pageHTML !== "string") return;
  const pattern = /<script\b[^>]*\btype\s*=\s*["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script\s*>/gi;
  let match;
  let count = 0;
  while ((match = pattern.exec(pageHTML)) !== null && count < MAX_JSONLD_BLOCKS) {
    count += 1;
    const source = match[1];
    if (source.length > MAX_JSONLD_CHARACTERS) continue;
    let data;
    try {
      data = JSON.parse(source.replace(/^\s*<!--/, "").replace(/-->\s*$/, ""));
    } catch (error) {
      continue;
    }
    const stack = [data];
    let visited = 0;
    while (stack.length && visited < 500) {
      const node = stack.pop();
      visited += 1;
      if (Array.isArray(node)) {
        for (let index = node.length - 1; index >= 0; index -= 1) stack.push(node[index]);
      } else if (node && typeof node === "object") {
        if (node["@type"]) jsonLDNodes.push(node);
        if (node["@graph"]) stack.push(node["@graph"]);
      }
    }
  }
})();

function types(node) {
  const value = node["@type"];
  return (Array.isArray(value) ? value : [value]).filter((type) => typeof type === "string");
}
function isArticleType(type) {
  return /(Article|BlogPosting|Posting|Report)$/.test(type);
}
const articleNodes = jsonLDNodes.filter((node) => types(node).some(isArticleType));
const pageNodes = jsonLDNodes.filter((node) => types(node).some((type) => /Page$/.test(type)));
function jsonLDValues(nodes, key) {
  return nodes.map((node) => node[key]).filter((value) => typeof value === "string" && value.trim());
}
function names(value) {
  const list = Array.isArray(value) ? value : [value];
  return list
    .map((item) => (typeof item === "string" ? item : item && typeof item.name === "string" ? item.name : null))
    .filter((name) => name && name.trim() && !/^https?:/i.test(name.trim()))
    .map(collapse);
}

// MARK: Readability

const readerable = isProbablyReaderable(document);
const article = new Readability(document.cloneNode(true), { serializer: (element) => element }).parse();

// MARK: Dates (D62)

const publishedTimes = [];
const modifiedTimes = [];
function addTime(list, value) {
  if (typeof value === "string" && value.trim() && !list.includes(value.trim())) list.push(value.trim());
}
addTime(publishedTimes, metaValue("article:published_time"));
for (const value of jsonLDValues(articleNodes, "datePublished")) addTime(publishedTimes, value);
for (const value of jsonLDValues(pageNodes, "datePublished")) addTime(publishedTimes, value);
for (const value of jsonLDValues(articleNodes, "dateCreated")) addTime(publishedTimes, value);
if (article) addTime(publishedTimes, article.publishedTime);
for (const element of document.querySelectorAll('[itemprop="datePublished"]')) {
  addTime(publishedTimes, element.getAttribute("content") || element.getAttribute("datetime") || element.textContent);
}
addTime(publishedTimes, metaValue("parsely-pub-date", "sailthru.date", "dc.date.issued", "dcterms.created",
  "dc.date", "dcterms.date", "og:published_time", "date", "pubdate", "publish-date", "publish_date",
  "publication_date"));
const pubdate = document.querySelector("time[pubdate][datetime]");
if (pubdate) addTime(publishedTimes, pubdate.getAttribute("datetime"));
const firstTime = document.querySelector("time[datetime]");
if (firstTime) addTime(publishedTimes, firstTime.getAttribute("datetime"));

addTime(modifiedTimes, metaValue("article:modified_time", "og:updated_time"));
for (const value of jsonLDValues(articleNodes, "dateModified")) addTime(modifiedTimes, value);
for (const value of jsonLDValues(pageNodes, "dateModified")) addTime(modifiedTimes, value);
for (const element of document.querySelectorAll('[itemprop="dateModified"]')) {
  addTime(modifiedTimes, element.getAttribute("content") || element.getAttribute("datetime") || element.textContent);
}
addTime(modifiedTimes, metaValue("last-modified", "dcterms.modified"));

// MARK: Title, site, byline, language

function firstName(...candidates) {
  for (const candidate of candidates) {
    const text = collapse(candidate);
    if (text) return text;
  }
  return null;
}
const publisherNames = articleNodes.flatMap((node) => names(node.publisher));
const siteName = firstName(article && article.siteName, metaValue("og:site_name"), publisherNames[0],
  metaValue("application-name"));
const authorNames = articleNodes.flatMap((node) => names(node.author)).slice(0, 3);
const metaAuthor = metaValue("author", "dc.creator", "parsely-author", "article:author");
const readabilityByline = article && article.byline && article.byline.length <= 80 ? article.byline : null;
const byline = firstName(authorNames.join(", "), metaAuthor && !/^https?:/i.test(metaAuthor) ? metaAuthor : null,
  readabilityByline);
const ogLocale = metaValue("og:locale");
const lang = firstName(article && article.lang, document.documentElement.getAttribute("lang"),
  metaValue("content-language"), ogLocale ? ogLocale.replace("_", "-") : null);
const title = firstName(article && article.title, document.title) || "";

// MARK: Blocks

const blocks = [];
let totalCharacters = 0;

function push(kind, raw) {
  if (totalCharacters >= MAX_TOTAL_CHARACTERS) return;
  let text = kind === "code" ? (raw || "").replace(/^\n+/, "").replace(/\s+$/, "") : collapse(raw);
  if (!text) return;
  if (text.length > MAX_BLOCK_CHARACTERS) text = text.slice(0, MAX_BLOCK_CHARACTERS);
  blocks.push({ kind, text });
  totalCharacters += text.length;
}

const SKIPPED = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "MATH", "IMG", "PICTURE", "VIDEO",
  "AUDIO", "IFRAME", "OBJECT", "EMBED", "CANVAS", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "FORM", "NAV", "HEAD",
  "SOURCE", "TRACK", "MAP", "AREA"]);
const BLOCK_LEVEL = new Set(["P", "H1", "H2", "H3", "H4", "H5", "H6", "PRE", "UL", "OL", "LI", "DL", "DT", "DD",
  "TABLE", "THEAD", "TBODY", "TFOOT", "TR", "TD", "TH", "CAPTION", "DIV", "SECTION", "ARTICLE", "MAIN",
  "BLOCKQUOTE", "FIGURE", "FIGCAPTION", "HEADER", "FOOTER", "ASIDE", "DETAILS", "SUMMARY", "HR", "ADDRESS",
  "CENTER", "FIELDSET", "LEGEND", "HGROUP"]);

// Text of a node as a reader sees it: line breaks and block edges become spaces.
function textOf(node) {
  if (node.nodeType === Node.TEXT_NODE) return node.data;
  if (node.nodeType !== Node.ELEMENT_NODE) return "";
  const tag = node.tagName.toUpperCase();
  if (SKIPPED.has(tag)) return "";
  if (tag === "BR") return "\n";
  let text = "";
  for (const child of node.childNodes) text += textOf(child);
  return BLOCK_LEVEL.has(tag) ? " " + text + " " : text;
}

function walk(element) {
  let inline = "";
  const flush = () => {
    push("paragraph", inline);
    inline = "";
  };
  for (const child of element.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      inline += child.data;
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) continue;
    const tag = child.tagName.toUpperCase();
    if (SKIPPED.has(tag)) continue;
    if (!BLOCK_LEVEL.has(tag)) {
      inline += textOf(child);
      continue;
    }
    flush();
    if (/^H[1-6]$/.test(tag)) push("heading", textOf(child));
    else if (tag === "P" || tag === "DT" || tag === "DD" || tag === "FIGCAPTION" || tag === "CAPTION" ||
      tag === "SUMMARY" || tag === "ADDRESS" || tag === "LEGEND") push("paragraph", textOf(child));
    else if (tag === "PRE") push("code", child.textContent);
    else if (tag === "LI") listItem(child);
    else if (tag === "TR") tableRow(child);
    else if (tag !== "HR") walk(child);
  }
  flush();
}

function listItem(item) {
  let text = "";
  const later = [];
  for (const child of item.childNodes) {
    const tag = child.nodeType === Node.ELEMENT_NODE ? child.tagName.toUpperCase() : "";
    if (tag === "UL" || tag === "OL" || tag === "PRE" || tag === "TABLE") later.push(child);
    else text += textOf(child);
  }
  push("listItem", text);
  for (const child of later) {
    if (child.tagName.toUpperCase() === "PRE") push("code", child.textContent);
    else walk(child);
  }
}

function tableRow(row) {
  const cells = Array.from(row.children)
    .filter((cell) => cell.tagName.toUpperCase() === "TD" || cell.tagName.toUpperCase() === "TH")
    .map((cell) => collapse(textOf(cell)))
    .filter((text) => text);
  push("tableRow", cells.join(" | "));
}

if (article && article.content) walk(article.content);

return JSON.stringify({
  title,
  siteName,
  byline,
  lang,
  publishedTimes,
  modifiedTimes,
  readerable,
  blocks,
});
