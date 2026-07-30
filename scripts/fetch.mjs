// 八代市のページを読みに行き、data.json を作り直します。
// GitHub Actions から10分おきに実行される想定。外部ライブラリは使いません。

import { writeFile, readFile } from "node:fs/promises";
import { CATS, classify, isUrgent } from "./classify.mjs";

const SRC_KANREN = "https://www.city.yatsushiro.lg.jp/kiji00326750/index.html"; // 令和8年熊本地震 関連情報
const SRC_KINKYU = "https://www.city.yatsushiro.lg.jp/kinkyu.html";             // 緊急情報（開設中の避難所）

// 市が随時更新する入口。自動取得の結果によらず常に先頭に出します。
const PINNED = [
  {t:"避難所の開設・混雑状況", u:"https://www.city.yatsushiro.lg.jp/bousai/list01014.html",
   ex:"いま開いている避難所と混み具合。市が随時更新します。", cat:"hinan"},
  {t:"八代市 緊急情報（一覧）", u:"https://www.city.yatsushiro.lg.jp/kinkyu.html",
   ex:"市からの緊急のお知らせ。", cat:"hinan"},
  {t:"り災証明について", u:"https://www.city.yatsushiro.lg.jp/bousai/list01013.html",
   ex:"住まいの被害を証明する書類。支援金や保険の手続きに必要になります。", cat:"okane"},
  {t:"八代市 防災サイト", u:"https://www.city.yatsushiro.lg.jp/bousai/default.html",
   ex:"防災に関する情報の入口。", cat:"sonota"}
];

async function get(url){
  const res = await fetch(url, {
    headers: {
      "User-Agent": "yatsushiro-saigai-info/1.0 (citizen volunteer aggregator; links only)",
      "Accept-Language": "ja"
    },
    signal: AbortSignal.timeout(20000)
  });
  if (!res.ok) throw new Error(`${url} → HTTP ${res.status}`);
  return await res.text();
}

// 記事ページ（/kijiXXXXXXXX/index.html）へのリンクをタイトルごと拾う
function extractArticles(html){
  const out = [];
  const seen = new Set();
  const re = /<a\s[^>]*href=["']([^"']*\/kiji\d+\/index\.html)["'][^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html))){
    const url = new URL(m[1], SRC_KANREN).href;
    const title = m[2]
      .replace(/<[^>]*>/g, "")
      .replace(/&nbsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/\s+/g, " ")
      .trim();
    if (!title || title.length < 4 || seen.has(url)) continue;
    seen.add(url);
    out.push({ t: title, u: url });
  }
  return out;
}

// 「【開設中の避難所】」に続く ・ 行を拾う。取れなければ空を返す（誤った一覧は出さない）
function extractShelters(html){
  const text = html
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|td|tr|h\d)>/gi, "\n")
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ");
  const idx = text.indexOf("開設中の避難所");
  if (idx < 0) return [];
  const tail = text.slice(idx, idx + 6000).split("\n");
  const names = [];
  for (const raw of tail){
    const line = raw.trim();
    if (!line) continue;
    if (/^[・･]/.test(line)){
      const n = line.replace(/^[・･]\s*/, "").trim();
      if (n && n.length <= 40) names.push(n);
    } else if (names.length >= 3){
      break; // 一覧が途切れたら終了
    }
  }
  return names;
}

async function main(){
  let articles = [];
  let shelters = [];
  const errors = [];

  try {
    articles = extractArticles(await get(SRC_KANREN));
    if (articles.length < 3) throw new Error("記事リンクが少なすぎます（ページ構成が変わった可能性）");
  } catch (e){
    errors.push(`関連情報: ${e.message}`);
  }

  try {
    shelters = extractShelters(await get(SRC_KINKYU));
  } catch (e){
    errors.push(`緊急情報: ${e.message}`);
  }

  // 取得に失敗したら前回の内容を残す（空のページを配信しない）
  if (!articles.length){
    try {
      const prev = JSON.parse(await readFile(new URL("../data.json", import.meta.url), "utf8"));
      articles = (prev.items || []).filter(i => !i.pin).map(i => ({ t: i.t, u: i.u }));
      console.log("取得に失敗したため前回の一覧を維持します");
    } catch { /* 初回はそのまま */ }
  }

  const items = [
    ...PINNED.map(p => ({ ...p, urgent: true, pin: true })),
    ...articles
      .filter(a => !PINNED.some(p => p.u === a.u))
      .map(a => ({ t: a.t, u: a.u, ex: "", cat: classify(a.t).cat, urgent: isUrgent(a.t), pin: false }))
  ];

  const data = {
    updated: new Date().toISOString(),
    source: SRC_KANREN,
    cats: CATS,
    items,
    shelters,
    errors
  };

  await writeFile(new URL("../data.json", import.meta.url), JSON.stringify(data, null, 2) + "\n");
  console.log(`お知らせ ${items.length}件 / 開設中の避難所 ${shelters.length}件` + (errors.length ? ` / 警告: ${errors.join(" | ")}` : ""));
}

main().catch(e => { console.error(e); process.exit(1); });
