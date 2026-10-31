#!/usr/bin/env bash
# E2E 用：模擬 Google（9876）と、web/dist + API を同一オリジンで配信するローカル Worker（8787）を起動する。
# 値はすべてテスト用のダミー。本物の Google・Cloudflare には一切接続しない。
set -euo pipefail
cd "$(dirname "$0")/../../apps/api"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
# 毎回まっさらなローカル D1 から始める（本番の D1 には触れない）
rm -rf .wrangler/state/e2e
npx wrangler d1 migrations apply DB --local --persist-to .wrangler/state/e2e >/dev/null
node ../../tests/fake-google/server.mjs &
trap 'kill $(jobs -p) 2>/dev/null' EXIT
VARS=()
while IFS='=' read -r k v; do [ -n "$k" ] && VARS+=(--var "$k:$v"); done < .dev.vars.e2e
npx wrangler dev --local --port 8787 --persist-to .wrangler/state/e2e --test-scheduled "${VARS[@]}"
