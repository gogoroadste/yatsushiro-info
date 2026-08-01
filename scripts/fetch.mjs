// 複数の公式サイトを読みに行き、data.json を作り直します。
// GitHub Actions から10分おきに実行される想定。外部ライブラリは使いません。
//
// 重要な原則:
//   updated = 最後に「市の情報の取得に成功した」時刻。失敗時は前回の値を引き継ぐ。
//   checked = 最後に「試みた」時刻。成否によらず更新する。
//   この2つを分けないと、失敗し続けているのに画面が「最新」に見えてしまいます。

import { writeFile, readFile } from "node:fs/promises";
import { CATS, classify, isUrgent } from "./classify.mjs";

const OUT = new URL("../data.json", import.meta.url);

const CITY    = "https://www.city.yatsushiro.lg.jp/kiji00326750/index.html"; // 令和8年熊本地震 関連情報
const KINKYU  = "https://www.city.yatsushiro.lg.jp/kinkyu.html";             // 緊急情報（開設中の避難所）
const SHAKYO  = "https://www.yatsushiro-shakyo.jp/";                          // 八代市社会福祉協議会
const MOD_PRESS = "https://www.mod.go.jp/js/press/index.html";                // 統合幕僚監部 報道発表資料
const MOD_DOMES = "https://www.mod.go.jp/js/activity/domestic.html";          // 統合幕僚監部 国内活動

// 常に先頭に出す入口。すべて実際に開いて存在を確認済み。
const PINNED = [
  {t:"避難所の開設・混雑状況", u:"https://www.city.yatsushiro.lg.jp/bousai/list01014.html",
   ex:"いま開いている避難所と混み具合。市が随時更新します。", cat:"hinan", src:"八代市"},
  {t:"八代市 緊急情報（一覧）", u:"https://www.city.yatsushiro.lg.jp/kinkyu.html",
   ex:"市からの緊急のお知らせ。", cat:"hinan", src:"八代市"},
  {t:"八代市社会福祉協議会", u:"https://www.yatsushiro-shakyo.jp/",
   ex:"災害ボランティアセンターを運営します。片づけの依頼・ボランティア募集はこちら。", cat:"volunteer", src:"社協"},
  {t:"全社協 被災地支援・災害ボランティア情報", u:"https://www.saigaivc.com/",
   ex:"全国のボランティアセンター開設状況。八代市の受け入れ開始もここに出ます。", cat:"volunteer", src:"全社協"},
  {t:"給油所の営業状況をさがす（資源エネルギー庁）", u:"https://www.enecho-ss.meti.go.jp/",
   ex:"「災害発生中のエリアから探す」で、いま給油できるスタンドと報告日時が地図に出ます。停電中でも給油できる住民拠点SSも分かります。", cat:"mise", src:"エネ庁"},
  {t:"災害に便乗した悪質商法にご注意ください（熊本県）", u:"https://www.pref.kumamoto.jp/soshiki/55/274698.html",
   ex:"県が出している注意喚起。相談先の一覧つき。", cat:"bouhan", src:"熊本県"},
  {t:"ご用心 災害に便乗した悪質商法（国民生活センター）", u:"https://www.kokusen.go.jp/soudan_now/data/disaster.html",
   ex:"実際に起きた相談事例が具体的に載っています。手口を知っておくのが最大の防御です。", cat:"bouhan", src:"国セン"},
  {t:"警察安全相談室（熊本県警）", u:"https://www.pref.kumamoto.jp/site/police/8627.html",
   ex:"事件にするほどでない不安や相談ごとの窓口。", cat:"bouhan", src:"熊本県警"},
  {t:"八代市 防災サイト", u:"https://www.city.yatsushiro.lg.jp/bousai/default.html",
   ex:"防災に関する情報の入口。", cat:"sonota", src:"八代市"}
];

const HEADERS = {
  // 自治体サイトは素っ気ないUser-Agentを弾くことがあるため、通常のブラウザとして名乗る
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language": "ja,en;q=0.8"
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

// 間隔を空けて3回まで試す。文字コードは応答ヘッダとmetaタグから判定する。
async function get(url, label){
  let last;
  for (let n = 1; n <= 3; n++){
    try {
      const res = await fetch(url, { headers: HEADERS, signal: AbortSignal.timeout(25000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length < 500) throw new Error(`本文が短すぎます (${buf.length}バイト)`);

      let enc = (res.headers.get("content-type") || "").match(/charset=([\w-]+)/i)?.[1];
      if (!enc){
        const head = buf.subarray(0, 2048).toString("latin1");
        enc = head.match(/charset=["']?([\w-]+)/i)?.[1];
      }
      enc = (enc || "utf-8").toLowerCase();
      if (/^(shift[-_]?jis|sjis|ms_kanji|windows-31j|cp932)$/.test(enc)) enc = "shift_jis";
      if (/^euc-?jp$/.test(enc)) enc = "euc-jp";

      let body;
      try { body = new TextDecoder(enc).decode(buf); }
      catch { body = buf.toString("utf8"); }

      if (n > 1) console.log(`  ${label}: ${n}回目で成功`);
      return body;
    } catch (e){
      last = e;
      console.log(`  ${label}: ${n}回目 失敗 — ${e.message}`);
      if (n < 3) await sleep(n * 5000);
    }
  }
  throw new Error(`${label}: 3回試して失敗 — ${last.message}`);
}

const clean = t => t.replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ")
                    .replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();

// ページ内のリンクを {タイトル, URL} で拾う。pattern に合う href だけを対象にする。
// 市サイトの自動翻訳（transer.com）へのリンクはお知らせではないので除外する
const EXCLUDE_HOST = /transer\.com$|translate\.google|\.bing\.com$/i;

function links(html, base, pattern){
  const out = [], seen = new Set();
  const re = /<a\s[^>]*href=["']([^"'#]+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html))){
    let url;
    try { url = new URL(m[1], base).href; } catch { continue; }
    if (!pattern.test(url) || seen.has(url)) continue;
    try { if (EXCLUDE_HOST.test(new URL(url).hostname)) continue; } catch { continue; }
    const t = clean(m[2]);
    if (!t || t.length < 4) continue;
    seen.add(url);
    out.push({ t, u: url });
  }
  return out;
}

// 「【開設中の避難所】」に続く ・ 行を拾う。取れなければ空を返す（誤った一覧は出さない）
function extractShelters(html){
  const text = html
    .replace(/<script[\s\S]*?<\/script>/gi, "").replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|li|td|tr|h\d)>/gi, "\n")
    .replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ");
  const idx = text.indexOf("開設中の避難所");
  if (idx < 0) return [];
  const names = [];
  for (const raw of text.slice(idx, idx + 6000).split("\n")){
    const line = raw.trim();
    if (!line) continue;
    if (/^[・･]/.test(line)){
      const n = line.replace(/^[・･]\s*/, "").trim();
      if (n && n.length <= 40) names.push(n);
    } else if (names.length >= 3) break;
  }
  return names;
}

// 社協サイトは福祉全般を扱うため、災害に関係する見出しだけに絞る
const SHAKYO_KEEP = /災害|ボランティア|地震|義援金|募金|支援|被災/;

// ただし他の災害（能登・青森・大槌町・海外など）の義援金受付は、
// 八代市の被災者が今すぐ必要とする情報ではないので除外する。
// 「令和8年熊本地震」と、災害名のつかないボランティア関連だけを残す。
const OTHER_DISASTER = /能登|青森|大槌|台風|林野火災|ベネズエラ|大雨|東方沖|佐賀関|共同募金|赤い羽根/;
const THIS_QUAKE     = /令和[8８]年熊本|熊本地震|八代市災害/;

// 統幕は艦艇の動向など無関係な発表が大半なので、今回の地震のものだけに絞る
const MOD_KEEP = /令和[8８]年熊本地震|熊本地震/;

async function readPrev(){
  try { return JSON.parse(await readFile(OUT, "utf8")); } catch { return null; }
}

async function main(){
  const prev = await readPrev();
  const now = new Date().toISOString();
  const errors = [];
  const status = {};

  // --- 八代市（主たる取得先） ---
  let cityItems = null;
  console.log("八代市 関連情報");
  try {
    const found = links(await get(CITY, "八代市"), CITY, /\/kiji\d+\/index\.html$/);
    if (found.length < 3) throw new Error(`記事リンクが${found.length}件（ページ構成の変更かもしれません）`);
    cityItems = found.map(a => ({ ...a, src: "八代市" }));
    status.city = { ok: true, count: found.length };
  } catch (e){
    errors.push(e.message);
    status.city = { ok: false, error: e.message };
  }

  // --- 避難所（緊急情報） ---
  let shelters = null;
  console.log("八代市 緊急情報");
  try {
    shelters = extractShelters(await get(KINKYU, "緊急情報"));
    status.kinkyu = { ok: true, count: shelters.length };
  } catch (e){
    errors.push(e.message);
    status.kinkyu = { ok: false, error: e.message };
  }

  // --- 社会福祉協議会（ボランティア。落ちても本体には影響させない） ---
  let shakyoItems = null;
  console.log("八代市社会福祉協議会");
  try {
    const found = links(await get(SHAKYO, "社協"), SHAKYO, /yatsushiro-shakyo\.jp\/.+\.(html|pdf)$/i)
      .filter(a => SHAKYO_KEEP.test(a.t))
      .filter(a => THIS_QUAKE.test(a.t) || !OTHER_DISASTER.test(a.t));
    shakyoItems = found.map(a => ({ ...a, src: "社協" }));
    status.shakyo = { ok: true, count: found.length };
    console.log(`  災害関連のリンク ${found.length}件`);
  } catch (e){
    errors.push(e.message);
    status.shakyo = { ok: false, error: e.message };
  }

  // --- 自衛隊（統合幕僚監部）。県全体の活動報告なので八代市の情報とは分けて扱う ---
  let modItems = null;
  console.log("統合幕僚監部");
  try {
    const found = [];
    // 日々の続報（PDF）
    const press = links(await get(MOD_PRESS, "統幕 報道発表"), MOD_PRESS, /\/js\/pdf\/2026\/.+\.pdf$/i)
      .filter(a => MOD_KEEP.test(a.t) && /災害派遣/.test(a.t));
    // 災害ごとの専用ページ（今回の地震のものが作られたら拾う）
    const domes = links(await get(MOD_DOMES, "統幕 国内活動"), MOD_DOMES, /\/js\/activity\/domestic\/.+\.html$/i)
      .filter(a => MOD_KEEP.test(a.t));

    for (const a of [...domes, ...press].slice(0, 8)){
      // 「2026年07月30日 公表 …（続報）」の日付は説明欄へ回す。
      // 見出しから落とすと続報同士が同じ文字列に見えて区別できなくなるため。
      const m = a.t.match(/^(\d{4})年(\d{1,2})月(\d{1,2})日\s*公表\s*(.*)$/);
      const title = m ? m[4] : a.t;
      const day   = m ? `${Number(m[2])}月${Number(m[3])}日発表` : "";
      const kind  = /\.pdf$/i.test(a.u) ? "熊本県全体の活動報告（PDF・速報値）" : "熊本県全体の活動報告";
      found.push({ t: title, u: a.u, ex: [day, kind].filter(Boolean).join(" ／ "), src: "自衛隊" });
    }
    modItems = found;
    status.mod = { ok: true, count: found.length };
    console.log(`  今回の地震に関する発表 ${found.length}件`);
  } catch (e){
    errors.push(e.message);
    status.mod = { ok: false, error: e.message };
  }

  // --- 組み立て ---
  const ok = cityItems !== null;
  let items, updated;

  if (ok){
    const raw = [
      ...cityItems,
      ...(shakyoItems ?? prevBySrc(prev, "社協")),
      ...(modItems    ?? prevBySrc(prev, "自衛隊"))
    ];
    items = [
      ...PINNED.map(p => ({ ...p, urgent: true, pin: true })),
      ...raw
        .filter(a => !PINNED.some(p => p.u === a.u))
        .map(a => ({ t: a.t, u: a.u, ex: a.ex ?? "", cat: classify(a.t).cat, urgent: isUrgent(a.t), pin: false, src: a.src }))
    ];
    updated = now;
  } else {
    // 市の取得に失敗したときは、前回の内容と前回の取得成功時刻をそのまま維持する
    items   = prev?.items   ?? PINNED.map(p => ({ ...p, urgent: true, pin: true }));
    updated = prev?.updated ?? null;
    console.log("→ 市の情報を取得できなかったため、前回の内容と取得時刻を維持します");
  }

  const data = {
    updated, checked: now, ok,
    sources: status,
    cats: CATS,
    items,
    shelters: shelters ?? prev?.shelters ?? [],
    errors
  };
  await writeFile(OUT, JSON.stringify(data, null, 2) + "\n");

  console.log("");
  console.log(`結果: ${ok ? "成功" : "失敗"} / お知らせ ${items.length}件 / 開設中の避難所 ${data.shelters.length}件`);
  for (const [k, v] of Object.entries(status)) console.log(`  ${k}: ${v.ok ? `OK (${v.count}件)` : "失敗"}`);
  if (errors.length) errors.forEach(e => console.log(`  警告: ${e}`));

  if (!ok) process.exitCode = 1;
}

function prevBySrc(prev, src){
  return (prev?.items ?? []).filter(i => i.src === src && !i.pin).map(i => ({ t: i.t, u: i.u, ex: i.ex, src }));
}

main().catch(e => { console.error(e); process.exit(1); });
