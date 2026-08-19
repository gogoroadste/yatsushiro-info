#!/bin/bash
# やつしろ困りごとまとめ — 公開スクリプト
#
# 使い方:
#   1. ターミナルで yatsushiro-site フォルダに移動
#   2. bash deploy.sh
#
# やること: リポジトリ作成 → ファイル送信 → Pages有効化 → 権限設定 → 初回実行

set -uo pipefail

REPO_NAME="${REPO_NAME:-yatsushiro-info}"
API="https://api.github.com"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die()  { red "✗ $*"; exit 1; }

# JSONから値を1つ取り出す（jq不要）
jval() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'; }

# ---------------------------------------------------------------- 事前確認
step "環境を確認しています"

command -v git   >/dev/null || die "git が見つかりません。ターミナルで  xcode-select --install  を実行してください。"
command -v curl  >/dev/null || die "curl が見つかりません。"

# ファイルがバラバラに置かれている場合は、正しい階層に組み直す
if [ ! -f scripts/classify.mjs ] && [ -f classify.mjs ]; then
  ylw "△ ファイルが同じ場所に並んでいます。正しい形に並べ替えます。"
  mkdir -p scripts .github/workflows
  for f in classify.mjs fetch.mjs;   do [ -f "$f" ] && mv "$f" scripts/; done
  [ -f update.yml ] && mv update.yml .github/workflows/
  grn "✓ 並べ替えました"
fi
if [ ! -f .github/workflows/update.yml ] && [ -f update.yml ]; then
  mkdir -p .github/workflows && mv update.yml .github/workflows/
fi

MISSING=""
for f in index.html data.json README.md scripts/classify.mjs scripts/fetch.mjs .github/workflows/update.yml; do
  [ -f "$f" ] || MISSING="$MISSING\n    ・$f"
done
if [ -n "$MISSING" ]; then
  red "✗ 次のファイルが見当たりません:"
  printf "$MISSING\n"
  echo
  echo "  いま見ている場所: $PWD"
  echo "  ここに入っているもの:"
  ls -A | sed 's/^/    /'
  echo
  die "yatsushiro-site フォルダの中で実行してください。"
fi
grn "✓ 必要なファイルは揃っています"

# ---------------------------------------------------------------- トークン
step "GitHubトークンを入力してください"
cat <<'TXT'

  まだ持っていない場合は、この画面を開いて作ってください:
  https://github.com/settings/tokens/new

    Note        : yatsushiro-deploy
    Expiration  : 7 days
    チェックする: [x] repo        （リポジトリの作成と書き込み）
                  [x] workflow    （自動更新の設定に必要）

  ページ下の「Generate token」を押し、ghp_ で始まる文字列をコピーしてください。
  ※この下に貼っても画面には表示されません。貼ったら Enter を押してください。

TXT
printf '  トークン: '
read -rs TOKEN
echo
[ -n "$TOKEN" ] || die "トークンが空です。"

AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

USER=$(curl -sS "${AUTH[@]}" "$API/user" | jval login)
[ -n "$USER" ] || die "トークンが正しくないようです。repo と workflow にチェックが入っているか確認してください。"

SCOPES=$(curl -sSI "${AUTH[@]}" "$API/user" | tr -d '\r' | grep -i '^x-oauth-scopes:' | cut -d' ' -f2-)
grn "✓ $USER としてサインインできました"
case "$SCOPES" in
  *workflow*) : ;;
  *) ylw "△ workflow の権限がありません。自動更新の送信に失敗します。トークンを作り直してください。" ;;
esac

# ---------------------------------------------------------------- リポジトリ
step "リポジトリ $REPO_NAME を用意しています"

EXISTS=$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$API/repos/$USER/$REPO_NAME")
if [ "$EXISTS" = "200" ]; then
  ylw "△ すでに存在します。そのまま上書きして進めます。"
else
  CREATE=$(curl -sS -X POST "${AUTH[@]}" "$API/user/repos" \
    -d "{\"name\":\"$REPO_NAME\",\"description\":\"八代市が発表する災害関連情報を困りごと別に整理した非公式ページ\",\"private\":false,\"has_issues\":false,\"has_projects\":false,\"has_wiki\":false,\"auto_init\":false}")
  echo "$CREATE" | grep -q '"full_name"' || die "作成できませんでした: $(echo "$CREATE" | jval message)"
  grn "✓ 作成しました"
fi

PAGE_URL="https://$USER.github.io/$REPO_NAME/"

# ---------------------------------------------------------------- 公開URLを埋め込む
step "公開URLをページに書き込んでいます"
if sed --version >/dev/null 2>&1; then SEDI=(-i); else SEDI=(-i ''); fi   # GNU / BSD 両対応
if grep -q 'og:url' index.html; then
  sed "${SEDI[@]}" "s#<meta property=\"og:url\" content=\"[^\"]*\">#<meta property=\"og:url\" content=\"$PAGE_URL\">#" index.html
else
  sed "${SEDI[@]}" "s#<meta property=\"og:type\" content=\"website\">#<meta property=\"og:type\" content=\"website\">\n<meta property=\"og:url\" content=\"$PAGE_URL\">#" index.html
fi
sed "${SEDI[@]}" "s#https://<あなたのID>.github.io/yatsushiro-info/#$PAGE_URL#g; s#<あなたのID>#$USER#g" README.md
grn "✓ $PAGE_URL"

# ---------------------------------------------------------------- 送信
step "ファイルを送信しています"

[ -d .git ] || git init -q
git symbolic-ref HEAD refs/heads/main
git add -A
git -c user.name="$USER" -c user.email="$USER@users.noreply.github.com" \
    commit -q -m "やつしろ困りごとまとめ" || true

git remote remove origin 2>/dev/null || true
git remote add origin "https://$USER:$TOKEN@github.com/$USER/$REPO_NAME.git"

if git push -q -u origin main --force 2>/tmp/push.log; then
  grn "✓ 送信しました"
else
  red "✗ 送信に失敗しました"; cat /tmp/push.log; exit 1
fi
git remote set-url origin "https://github.com/$USER/$REPO_NAME.git"   # トークンを設定から消す

# ---------------------------------------------------------------- 自動更新の権限
step "自動更新の権限を設定しています"
curl -sS -o /dev/null -X PUT "${AUTH[@]}" \
  "$API/repos/$USER/$REPO_NAME/actions/permissions/workflow" \
  -d '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":false}' \
  && grn "✓ 書き込みを許可しました"

# ---------------------------------------------------------------- Pages
step "GitHub Pages を有効にしています"
P=$(curl -sS -X POST "${AUTH[@]}" "$API/repos/$USER/$REPO_NAME/pages" \
     -d '{"source":{"branch":"main","path":"/"}}')
if echo "$P" | grep -q '"html_url"'; then
  grn "✓ 有効にしました"
elif echo "$P" | jval message | grep -qi 'already'; then
  ylw "△ すでに有効です"
else
  ylw "△ 自動設定できませんでした。次の画面で Branch: main / (root) を選んで保存してください:"
  echo "   https://github.com/$USER/$REPO_NAME/settings/pages"
fi

# ---------------------------------------------------------------- 初回実行
step "八代市の情報を取り込みます"
sleep 5
D=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${AUTH[@]}" \
     "$API/repos/$USER/$REPO_NAME/actions/workflows/update.yml/dispatches" -d '{"ref":"main"}')
[ "$D" = "204" ] && grn "✓ 実行を開始しました" || ylw "△ 手動で実行してください: https://github.com/$USER/$REPO_NAME/actions"

# ---------------------------------------------------------------- 完了
cat <<TXT

$(grn "──────────────  公開しました  ──────────────")

  サイト        $PAGE_URL
                （初回は反映まで2〜3分かかります）

  更新の様子    https://github.com/$USER/$REPO_NAME/actions
  リポジトリ    https://github.com/$USER/$REPO_NAME

$(ylw "この後やること")

  1. サイトを開き、緑の帯に「○分前に確認しました」と出ているか見る
     黄色い帯のままなら Actions のページでエラーを確認してください

  2. 使い終わったトークンを削除する（安全のため）
     https://github.com/settings/tokens

TXT
