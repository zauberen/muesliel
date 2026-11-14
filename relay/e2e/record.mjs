// Drive the PWA in headless Chrome with a fake microphone:
// log in, pick the e2e Emacs, record for a few seconds, stop, and wait
// until the recording is uploaded and waiting for Emacs.
//
// node record.mjs   (env: RELAY_URL, E2E_USER, E2E_PASS, CHROME, SECONDS)
import { chromium } from "playwright-core";

const url = process.env.RELAY_URL;
const seconds = Number(process.env.SECONDS || 12);

const browser = await chromium.launch({
  executablePath: process.env.CHROME,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--autoplay-policy=no-user-gesture-required"],
});
const context = await browser.newContext({ permissions: ["microphone"] });
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
// Network errors while deliberately offline are expected.
page.on("console", (m) => { if (m.type() === "error" && !/ERR_INTERNET_DISCONNECTED/.test(m.text())) errors.push(m.text()); });

await page.goto(url + "/login");
await page.fill("input[name=username]", process.env.E2E_USER);
await page.fill("input[name=password]", process.env.E2E_PASS);
await Promise.all([page.waitForURL(url + "/"), page.click("button.primary")]);

await page.waitForSelector("#client option", { state: "attached" });
await page.selectOption("#profile", "standup");
await page.fill("#title", "Phone e2e");
await page.screenshot({ path: process.env.E2E_DIR + "/pwa-idle.png" });

await page.click("button.record");
await page.waitForSelector("button.record.on");
await page.waitForTimeout(seconds * 1000 / 2);
await page.fill("#notes", "Typed during the meeting.");
let level = 0;
for (let i = 0; i < 40; i++) {
  await page.waitForTimeout(seconds * 25 / 2);
  const t = await page.evaluate(() => document.querySelector(".meter-fill").style.transform);
  level = Math.max(level, Number((t.match(/scaleX\(([\d.e-]+)\)/) || [0, 0])[1]));
}
await page.screenshot({ path: process.env.E2E_DIR + "/pwa-recording.png" });
await page.click("button.record");

await page.waitForFunction(() => /waiting for Emacs/.test(document.querySelector(".status").textContent), null, { timeout: 30000 });
await page.click("button.tab:nth-child(2)");
await page.waitForSelector(".chip.waiting");
await page.screenshot({ path: process.env.E2E_DIR + "/pwa-history.png" });

// Scenario 2: the network drops mid-recording and returns after Stop.
await page.click("button.tab:nth-child(1)");
await page.fill("#title", "Offline e2e");
await page.click("button.record");
await page.waitForSelector("button.record.on");
await page.waitForTimeout(3000);
await context.setOffline(true);
await page.waitForTimeout(8000);
await page.click("button.record");
await page.waitForFunction(() => /Waiting to upload|Uploading/.test(document.querySelector(".status").textContent), null, { timeout: 30000 });
const offlineStatus = await page.textContent(".status");
await page.screenshot({ path: process.env.E2E_DIR + "/pwa-offline.png" });
await context.setOffline(false);
await page.waitForFunction(() => /waiting for Emacs/.test(document.querySelector(".status").textContent), null, { timeout: 90000 });

// Scenario 3: the tab is killed mid-recording, then reopened and recovered.
await page.selectOption("#profile", "default");
await page.fill("#title", "Killed e2e");
await page.click("button.record");
await page.waitForSelector("button.record.on");
await page.waitForTimeout(11000);
await page.close();
const page2 = await context.newPage();
page2.on("pageerror", (e) => errors.push(String(e)));
await page2.goto(url + "/");
await page2.waitForSelector(".banner button.primary", { timeout: 15000 });
await page2.screenshot({ path: process.env.E2E_DIR + "/pwa-unfinished.png" });
await page2.click(".banner button.primary");
await page2.waitForFunction(() => /waiting for Emacs/.test(document.querySelector(".status").textContent), null, { timeout: 60000 });

const recs = await page2.evaluate(async () => (await (await fetch("/app/api/recordings")).json()));
const summary = recs.map((r) => ({ title: r.title, status: r.status, ms: r.duration_ms, parts: r.part_count }));
const allReady = recs.length === 3 && recs.every((r) => r.status === "ready" && r.part_count >= 2);

const loginShown = await page2.isVisible("a[href='/login']");
const sw = await page2.evaluate(async () => !!(await navigator.serviceWorker.getRegistration()));
console.log(JSON.stringify({ peakLevel: level, serviceWorker: sw, loginShown, offlineStatus, recordings: summary, errors }, null, 1));
await browser.close();
if (errors.length || !(level > 0) || loginShown || !sw || !allReady) process.exit(1);
