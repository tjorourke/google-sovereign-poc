#!/usr/bin/env bash
# Fetch a page from Google's Berlin GCD doc set.
#
# The docs are gated behind an HTTP request header, not a login. Without it you
# silently get the public cloud.google.com corpus instead -- the same failure
# shape as forgetting universe_domain. In a browser, set the header with the
# ModHeader extension.
#
#   scripts/gcd-docs.sh /docs/overview/tpc-key-differences
#   scripts/gcd-docs.sh /kubernetes-engine/docs/tpc-differences
#   scripts/gcd-docs.sh --raw /products > products.html
#
# Remember: /docs/product-list is unmodified public-GCP content. /products is
# the GCD service list, and the per-product tpc-differences pages are what
# Google itself calls the source of truth for feature availability.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -f .env.local ]]; then
  # shellcheck disable=SC1091
  source .env.local
fi

DOCS_HOST="${GCD_DOCS_HOST:-berlin.devsitetest.how}"
DOCS_HEADER="${GCD_DOCS_HEADER:-X-DevSite-Proxy: gcd}"

RAW=0
if [[ "${1:-}" == "--raw" ]]; then
  RAW=1
  shift
fi

PATH_ARG="${1:-/docs}"
[[ "${PATH_ARG}" == /* ]] || PATH_ARG="/${PATH_ARG}"

HTML="$(curl -sSL --fail-with-body -H "${DOCS_HEADER}" "https://${DOCS_HOST}${PATH_ARG}")"

if (( RAW )); then
  printf '%s' "${HTML}"
  exit 0
fi

# Strip to readable text. devsite pages are one big nav plus one <article>.
printf '%s' "${HTML}" | python3 -c '
import html, re, sys

s = sys.stdin.read()
m = re.search(r"(?is)<article.*?</article>", s)
if m:
    s = m.group(0)
s = re.sub(r"(?is)<(script|style|svg)[^>]*>.*?</\1>", " ", s)
s = html.unescape(re.sub(r"(?s)<[^>]+>", " ", s))
s = re.sub(r"[ \t]+", " ", s)
s = re.sub(r"\n\s*\n+", "\n", s)
print(s.strip())
'
