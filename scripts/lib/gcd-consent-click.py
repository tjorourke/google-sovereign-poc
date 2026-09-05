#!/usr/bin/env python3
"""Drive the signed-in assist browser through one GCD consent page.

Invoked by gcd-auth-assist.sh as the BROWSER helper: gcloud hands us the
authorize URL, we navigate the already-signed-in Chrome to it and press the
button a human would otherwise press. gcloud's own localhost listener catches
the redirect.

We never see, type, or store a credential. The sign-in happened once, by hand.

Shape of the flow, confirmed 2026-09-05:
    /authorize            -> redirects
    /signin-handler       title "Confirm", buttons [Cancel] [Next]
    localhost:<port>      gcloud captures the code here
    /sdk/auth_success     404, and that 404 is the CORRECT ending

Two things this gets wrong if you are not careful, and both did:
  * waiting only for domcontentloaded looks for the button while still on
    /authorize, before the redirect lands, so nothing is found and gcloud then
    waits forever for a redirect that never comes;
  * treating "not on a sign-in page" as success reports a hang as a pass.
    Success is reaching auth_success or localhost, and nothing else.
"""
import sys, time
from playwright.sync_api import sync_playwright

CDP, URL = sys.argv[1], sys.argv[2]
DEADLINE = time.time() + 150

def done(u):
    return "/sdk/auth_success" in u or "localhost" in u or "127.0.0.1" in u

with sync_playwright() as p:
    b = p.chromium.connect_over_cdp(CDP)
    ctx = b.contexts[0]
    # Close consent tabs left behind by an earlier run that was interrupted.
    # Their gcloud listener is long dead, so they sit on the Confirm page for
    # ever and look, reasonably, like something is stuck.
    for old_pg in list(ctx.pages):
        u = old_pg.url
        if "/signin-handler" in u or "/sdk/auth_success" in u:
            try: old_pg.close()
            except Exception: pass
    pg = ctx.new_page()
    ok = False
    try:
        try:
            pg.goto(URL, wait_until="networkidle", timeout=60000)
        except Exception:
            pass  # the final hop 404s by design; keep going

        while time.time() < DEADLINE and not done(pg.url):
            if "accounts.google.com" in pg.url or pg.url.rstrip("/").endswith("/signin"):
                print("ASSIST: the assist browser is NOT signed in (at %s).\n"
                      "        Run: ./scripts/gcd-auth-assist.sh start"
                      % pg.url.split("?")[0], file=sys.stderr)
                sys.exit(3)
            clicked = False
            for name in ("Next", "Continue", "Allow"):
                try:
                    btn = pg.get_by_role("button", name=name).first
                    btn.wait_for(state="visible", timeout=8000)
                    btn.click(timeout=8000)
                    clicked = True
                    break
                except Exception:
                    continue
            if not clicked:
                time.sleep(2)
                continue
            try:
                pg.wait_for_load_state("networkidle", timeout=30000)
            except Exception:
                pass

        ok = done(pg.url)
        if ok:
            print("ASSIST: consent completed", file=sys.stderr)
        else:
            print("ASSIST: consent did NOT complete; still at %s"
                  % pg.url.split("?")[0], file=sys.stderr)
    finally:
        try: pg.close()
        except Exception: pass
        b.close()
    sys.exit(0 if ok else 4)
