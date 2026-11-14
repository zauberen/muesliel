// Scenario 4 (Spec 3): a meeting started in Emacs.  Log in, wait for the
// "<Emacs> is waiting" banner, tap its Record button, and keep recording
// until Emacs asks the phone to stop (muesli-stop), then wait for the
// upload to finish.
//
// node record-session.mjs   (env: RELAY_URL, E2E_USER, E2E_PASS, CHROME, E2E_DIR)
import { chromium } from "playwright-core";

const url = process.env.RELAY_URL;
const browser = await chromium.launch({
  executablePath: process.env.CHROME,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--autoplay-policy=no-user-gesture-required"],
});
const context = await browser.newContext({ permissions: ["microphone"] });
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });

await page.goto(url + "/login");
await page.fill("input[name=username]", process.env.E2E_USER);
await page.fill("input[name=password]", process.env.E2E_PASS);
await Promise.all([page.waitForURL(url + "/"), page.click("button.primary")]);

await page.waitForSelector(".banner.session button.primary", { timeout: 60000 });
const banner = await page.textContent(".banner.session");
await page.screenshot({ path: process.env.E2E_DIR + "/pwa-session.png" });
await page.click(".banner.session button.primary");
await page.waitForSelector("button.record.on");
const heading = await page.textContent(".session-title");
const pickersHidden = await page.isHidden(".pickers");
await page.fill("#notes", "Phone-side note.");
await page.screenshot({ path: process.env.E2E_DIR + "/pwa-session-recording.png" });

// Emacs calls muesli-stop after it has seen live segments.
await page.waitForSelector("button.record.off", { timeout: 120000 });
const stoppedBy = await page.textContent(".status");
await page.waitForFunction(() => /transcribing/.test(document.querySelector(".status").textContent), null, { timeout: 60000 });

console.log(JSON.stringify({ banner, heading, pickersHidden, stoppedBy, errors }, null, 1));
await browser.close();
// Nothing here clicked Stop: the recorder turned off because Emacs asked.
if (errors.length || !pickersHidden || !/Standup from Emacs/.test(heading)) process.exit(1);
