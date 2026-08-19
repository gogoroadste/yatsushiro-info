# やつしろ困りごとまとめ — Windows用 公開スクリプト
#
# 使い方: このファイルがあるフォルダで PowerShell を開き、次を実行
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1
#
# Gitのインストールは不要です。Windowsに入っている機能だけで動きます。

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoName = 'yatsushiro-info'
$API      = 'https://api.github.com'

function Step($t) { Write-Host ""; Write-Host "> $t" -ForegroundColor White -BackgroundColor DarkBlue }
function Ok($t)   { Write-Host "  [OK] $t"   -ForegroundColor Green }
function Warn($t) { Write-Host "  [注意] $t" -ForegroundColor Yellow }
function Die($t)  { Write-Host ""; Write-Host "  [停止] $t" -ForegroundColor Red; Write-Host ""; Read-Host "Enterキーで閉じます"; exit 1 }

# スクリプトが置かれている場所で作業する
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

Write-Host ""
Write-Host "  やつしろ困りごとまとめ  公開スクリプト" -ForegroundColor Cyan
Write-Host "  ------------------------------------"

# ------------------------------------------------------------ ファイル確認
Step "ファイルを確認しています"

# バラバラに置かれている場合は正しい階層に組み直す
if (-not (Test-Path 'scripts\classify.mjs') -and (Test-Path 'classify.mjs')) {
  Warn "ファイルが同じ場所に並んでいます。正しい形に並べ替えます。"
  New-Item -ItemType Directory -Force -Path 'scripts', '.github\workflows' | Out-Null
  foreach ($f in 'classify.mjs','fetch.mjs') { if (Test-Path $f) { Move-Item $f 'scripts\' -Force } }
  if (Test-Path 'update.yml') { Move-Item 'update.yml' '.github\workflows\' -Force }
  Ok "並べ替えました"
}
if (-not (Test-Path '.github\workflows\update.yml') -and (Test-Path 'update.yml')) {
  New-Item -ItemType Directory -Force -Path '.github\workflows' | Out-Null
  Move-Item 'update.yml' '.github\workflows\' -Force
}

$need = @('index.html','data.json','README.md','scripts\classify.mjs','scripts\fetch.mjs','.github\workflows\update.yml')
$missing = $need | Where-Object { -not (Test-Path $_) }
if ($missing) {
  Write-Host ""
  Write-Host "  見当たらないファイル:" -ForegroundColor Red
  $missing | ForEach-Object { Write-Host "    ・$_" -ForegroundColor Red }
  Write-Host ""
  Write-Host "  いま見ている場所: $root"
  Write-Host "  ここに入っているもの:"
  Get-ChildItem -Force | ForEach-Object { Write-Host "    $($_.Name)" }
  Write-Host ""
  Die "zipを展開してできた yatsushiro-site フォルダの中で実行してください。"
}
Ok "必要なファイルは揃っています（$($need.Count)個）"

# ------------------------------------------------------------ トークン
Step "GitHubトークンを入力してください"
Write-Host @"

  まだ持っていない場合は、この画面を開いて作ってください:

    https://github.com/settings/tokens/new

    Note        に  yatsushiro   と入力
    Expiration  で  7 days       を選ぶ
    チェック    に  repo  と  workflow   の2つ

  下の「Generate token」を押すと ghp_ で始まる文字列が出ます。
  それをコピーして、この下に貼り付けてください（Ctrl+V）。

  ※ 貼り付けても画面には * が出るだけです。それで正常です。

"@
$sec = Read-Host "  トークン" -AsSecureString
$tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
         [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
if (-not $tok) { Die "トークンが空です。もう一度実行してください。" }

$H = @{
  Authorization          = "Bearer $tok"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'yatsushiro-deploy'
}

function Send($method, $url, $obj) {
  $req = @{ Method = $method; Uri = $url; Headers = $H }
  if ($obj) {
    $json = $obj | ConvertTo-Json -Depth 5 -Compress
    $req.Body        = [Text.Encoding]::UTF8.GetBytes($json)
    $req.ContentType = 'application/json; charset=utf-8'
  }
  Invoke-RestMethod @req
}

try { $me = Send 'GET' "$API/user" $null }
catch { Die "トークンが正しくないようです。repo と workflow の2つにチェックが入っているか確認して、作り直してください。" }
$user = $me.login
Ok "$user としてサインインできました"

# workflow 権限の確認
try {
  $resp = Invoke-WebRequest -Uri "$API/user" -Headers $H -UseBasicParsing
  $scopes = $resp.Headers['X-OAuth-Scopes']
  if ($scopes -and $scopes -notmatch 'workflow') {
    Warn "workflow のチェックが入っていません。自動更新の設定に失敗します。トークンを作り直すことをおすすめします。"
  }
} catch {}

$pageUrl = "https://$user.github.io/$RepoName/"

# ------------------------------------------------------------ リポジトリ
Step "置き場所（リポジトリ）を用意しています"
$exists = $false
try { Send 'GET' "$API/repos/$user/$RepoName" $null | Out-Null; $exists = $true } catch {}

if ($exists) {
  Warn "すでに $RepoName があります。上書きして進めます。"
} else {
  try {
    Send 'POST' "$API/user/repos" @{
      name        = $RepoName
      description = '地震のあとの困りごとから八代市のお知らせを探せる非公式ページ'
      private     = $false
      has_issues  = $false
      has_wiki    = $false
      auto_init   = $false
    } | Out-Null
    Ok "作成しました"
  } catch {
    Die "作成できませんでした。$($_.ErrorDetails.Message)"
  }
}

# ------------------------------------------------------------ 公開URLの埋め込み
Step "公開URLをページに書き込んでいます"
function ReadText($p)  { [IO.File]::ReadAllText((Join-Path $root $p), [Text.Encoding]::UTF8) }
function WriteText($p,$t) { [IO.File]::WriteAllText((Join-Path $root $p), $t, (New-Object Text.UTF8Encoding $false)) }

$html = ReadText 'index.html'
if ($html -match 'og:url') {
  $html = $html -replace '<meta property="og:url" content="[^"]*">', ('<meta property="og:url" content="' + $pageUrl + '">')
} else {
  $html = $html -replace '<meta property="og:type" content="website">', ('<meta property="og:type" content="website">' + "`r`n" + '<meta property="og:url" content="' + $pageUrl + '">')
}
WriteText 'index.html' $html

$rm = ReadText 'README.md'
$rm = $rm.Replace('https://<あなたのID>.github.io/yatsushiro-info/', $pageUrl).Replace('<あなたのID>', $user)
WriteText 'README.md' $rm
Ok $pageUrl

# ------------------------------------------------------------ 送信
Step "ファイルを送信しています"
function PutFile($local, $remote) {
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $local)))
  $body = @{ message = 'publish site'; content = $b64; branch = 'main' }
  try {
    $getUrl = "$API/repos/$user/$RepoName/contents/" + $remote + "?ref=main"
    $cur = Send 'GET' $getUrl $null
    if ($cur.sha) { $body.sha = $cur.sha }
  } catch {}
  Send 'PUT' "$API/repos/$user/$RepoName/contents/$remote" $body | Out-Null
  Write-Host "    送信: $remote" -ForegroundColor DarkGray
}

$files = @(
  @('index.html',                  'index.html'),
  @('data.json',                   'data.json'),
  @('README.md',                   'README.md'),
  @('scripts\classify.mjs',        'scripts/classify.mjs'),
  @('scripts\fetch.mjs',           'scripts/fetch.mjs'),
  @('.github\workflows\update.yml','.github/workflows/update.yml')
)
foreach ($f in $files) {
  try { PutFile $f[0] $f[1] }
  catch {
    $m = $_.ErrorDetails.Message
    if ($f[1] -like '.github/*' -and $m -match 'workflow') {
      Die "自動更新の設定ファイルを送れませんでした。トークンの workflow のチェックが必要です。作り直してもう一度実行してください。"
    }
    Die "$($f[1]) を送れませんでした。$m"
  }
}
Ok "$($files.Count)個すべて送信しました"

# ------------------------------------------------------------ 自動更新の権限
Step "自動更新の権限を設定しています"
try {
  Send 'PUT' "$API/repos/$user/$RepoName/actions/permissions/workflow" @{
    default_workflow_permissions      = 'write'
    can_approve_pull_request_reviews  = $false
  } | Out-Null
  Ok "書き込みを許可しました"
} catch {
  Warn "自動で設定できませんでした。次の画面で Read and write permissions を選んで Save してください:"
  Write-Host "        https://github.com/$user/$RepoName/settings/actions"
}

# ------------------------------------------------------------ Pages
Step "サイトを公開しています（GitHub Pages）"
try {
  Send 'POST' "$API/repos/$user/$RepoName/pages" @{ source = @{ branch = 'main'; path = '/' } } | Out-Null
  Ok "公開設定しました"
} catch {
  if ($_.ErrorDetails.Message -match 'already') {
    Warn "すでに公開設定されています"
  } else {
    Warn "自動で設定できませんでした。次の画面で Branch に main、その隣に / (root) を選んで Save してください:"
    Write-Host "        https://github.com/$user/$RepoName/settings/pages"
  }
}

# ------------------------------------------------------------ 初回の取り込み
Step "八代市の情報を取り込みます"
Start-Sleep -Seconds 8
$done = $false
foreach ($try in 1..3) {
  try {
    Send 'POST' "$API/repos/$user/$RepoName/actions/workflows/update.yml/dispatches" @{ ref = 'main' } | Out-Null
    $done = $true; break
  } catch { Start-Sleep -Seconds 7 }
}
if ($done) { Ok "取り込みを開始しました" }
else { Warn "手動で実行してください: https://github.com/$user/$RepoName/actions" }

# ------------------------------------------------------------ 完了
Write-Host ""
Write-Host "  ====================  公開しました  ====================" -ForegroundColor Green
Write-Host ""
Write-Host "   サイト       $pageUrl" -ForegroundColor Cyan
Write-Host "                （初回は反映まで2〜3分かかります）"
Write-Host ""
Write-Host "   更新の様子   https://github.com/$user/$RepoName/actions"
Write-Host "   置き場所     https://github.com/$user/$RepoName"
Write-Host ""
Write-Host "  この後やること" -ForegroundColor Yellow
Write-Host ""
Write-Host "   1. サイトを開き、緑の帯に「○分前に確認しました」と出ているか見る"
Write-Host "      黄色い帯のままなら、上の「更新の様子」でエラーを確認してください"
Write-Host ""
Write-Host "   2. 使い終わったトークンを削除する（安全のため）"
Write-Host "      https://github.com/settings/tokens"
Write-Host ""
Read-Host "  Enterキーで閉じます"
