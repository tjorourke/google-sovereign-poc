#!/usr/bin/env python3
"""Drive the signed-in assist browser through one GCD consent page.

Invoked by gcd-auth-assist.sh as the BROWSER helper: gcloud hands us the
authorize URL, we press the button a human would otherwise press, and gcloud's
own localhost listener catches the redirect.

We never see, type, or store a credential. The sign-in happened once, by hand.

The flow, confirmed 2026-09-05:
    /authorize        -> redirects
    /signin-handler   title "Confirm", buttons [Cancel] [Next]
    localhost:<port>  ?state=...&code=...   <- gcloud captures the code HERE
    /sdk/auth_success 404, and that 404 is the correct ending

Deliberate choices, each one a bug that was hit:

  * wait_until="networkidle" on the first goto. domcontentloaded returns while
    still on /authorize, before the redirect to /signin-handler lands, so the
    button is not there yet and nothing is clicked.
  * ONE click attempt, generously waited, rather than a retry loop. The loop
    version swallowed the real error in an `except: continue` and spun until
    its deadline, reporting a hang rather than a cause.
  * Success is reaching localhost or auth_success. "Not on a sign-in page" is
    not success -- that reported hangs as passes.
  * Poll the URL after clicking instead of waiting for networkidle: the final
    404 never goes idle, so waiting on it left the tab visibly spinning long
    after the credential had been captured.
  * ALWAYS exit 0. Python's webbrowser falls back to the next browser when the
    BROWSER command fails, which silently opened the user's own Chrome and made
    a broken automated run look like it needed a manual click. Failures are
    reported on stderr and caught by the caller's credential check instead.
"""
import sys, time
from playwright.sync_api import sync_playwright

CDP, URL = sys.argv[1], sys.argv[2]

def done(u):
    # Match the REDIRECT TARGET only. A substring test for "localhost" is a
    # false positive on the /authorize URL itself, whose query string carries
    # redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F -- that made the very first
    # page look like a completed flow.
    return (u.startswith("http://localhost:")
            or u.startswith("http://127.0.0.1:")
            or "/sdk/auth_success" in u)

def log(msg):
    print("ASSIST: %s" % msg, file=sys.stderr)

ok = False
try:
    with sync_playwright() as p:
        b = p.chromium.connect_over_cdp(CDP)
        ctx = b.contexts[0]
        # Close consent tabs left by an interrupted run: their gcloud listener
        # is dead, so they sit on Confirm for ever and look stuck.
        for stale in list(ctx.pages):
            if "/signin-handler" in stale.url or "/sdk/auth_success" in stale.url:
                try: stale.close()
                except Exception: pass

        pg = ctx.new_page()
        try:
            try:
                pg.goto(URL, wait_until="networkidle", timeout=60000)
            except Exception:
                pass

            if "accounts.google.com" in pg.url or pg.url.rstrip("/").endswith("/signin"):
                log("assist browser is NOT signed in (at %s)" % pg.url.split("?")[0])
                log("run: ./scripts/gcd-auth-assist.sh start")
            else:
                # The tab must be FOREGROUND. Chrome throttles rendering in
                # background tabs, so Playwright's actionability checks never
                # settle and click() times out at 15s on a button that
                # wait_for() has already reported visible. This is the whole
                # reason the automation appeared to work while actually
                # falling back to the user's own browser.
                try: pg.bring_to_front()
                except Exception: pass
                log("at %s | buttons=%s" % (
                    pg.url.split("?")[0],
                    [(x.inner_text() or "")[:10] for x in pg.query_selector_all("button")]))

                # Click via page.evaluate, NOT via a Playwright locator.
                #
                # Locator clicks -- normal, force, and dispatch_event alike --
                # all time out here even though query_selector_all("button")
                # returns [Cancel, Next]. Playwright's actionability checks
                # include a hit-test, and the assist window is frequently
                # occluded or unpainted behind other windows, so that test
                # never passes. evaluate() runs in the page and skips all of
                # it, which is what a background browser needs.
                clicked = pg.evaluate("""() => {
                    const want = ['next','continue','allow'];
                    const b = [...document.querySelectorAll('button')]
                        .find(x => want.includes((x.innerText||'').trim().toLowerCase()));
                    if (!b) return false;
                    b.click();
                    return true;
                }""")
                log("clicked via evaluate" if clicked else "no consent button in the DOM")

                # Watch for the redirect. Reading pg.url can raise once the
                # click navigates away and the execution context is torn down;
                # that teardown is itself evidence the click landed, so treat
                # an unreadable page as success rather than as a failure.
                for _ in range(60):          # up to 30s
                    try:
                        u = pg.url
                    except Exception:
                        ok = True
                        break
                    if done(u):
                        ok = True
                        break
                    time.sleep(0.5)
                if ok:
                    log("consent completed")
                else:
                    try: where = pg.url.split("?")[0]
                    except Exception: where = "(page gone)"
                    log("consent did NOT complete; still at %s" % where)
        finally:
            try: pg.close()
            except Exception: pass
            b.close()
except Exception as e:
    log("assist error: %s %s" % (type(e).__name__, str(e)[:150]))

sys.exit(0)
