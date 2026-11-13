// Moneyboard bill reminders. Runs each morning from a scheduled job and sends
// phone alerts for repeating bills that are coming up, on personal and joint boards. Also sends a test alert
// when a signed-in user asks for one from Settings.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const pad = (n: number) => String(n).padStart(2, "0");
const iso = (d: Date) => d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
function nextDate(d: string, f: string, day?: number) {
  const [y, m, dd] = d.split("-").map(Number);
  if (f === "weekly" || f === "fortnightly") return iso(new Date(y, m - 1, dd + (f === "weekly" ? 7 : 14)));
  let ny = y, nm = m + (f === "monthly" ? 1 : f === "quarterly" ? 3 : 12);
  while (nm > 12) { nm -= 12; ny++; }
  return ny + "-" + pad(nm) + "-" + pad(Math.min(day || dd, new Date(ny, nm, 0).getDate()));
}
const addDays = (d: string, n: number) => { const [y, m, dd] = d.split("-").map(Number); return iso(new Date(y, m - 1, dd + n)); };
const diffDays = (a: string, b: string) => {
  const [y1, m1, d1] = a.split("-").map(Number), [y2, m2, d2] = b.split("-").map(Number);
  return Math.round((Date.UTC(y2, m2 - 1, d2) - Date.UTC(y1, m1 - 1, d1)) / 864e5);
};
const when = (n: number) => (n <= 0 ? "today" : n === 1 ? "tomorrow" : "in " + n + " days");
function todayIn(tz: string) {
  try { return new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(new Date()); }
  catch { return new Intl.DateTimeFormat("en-CA", { timeZone: "Australia/Brisbane" }).format(new Date()); }
}
function money(v: number, cur: string) {
  try { return new Intl.NumberFormat("en-AU", { style: "currency", currency: cur || "AUD" }).format(v); }
  catch { return "$" + v.toFixed(2); }
}
function dayLabel(d: string) {
  const [y, m, dd] = d.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, dd)).toLocaleDateString("en-AU", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
}

async function sendAll(userId: string, payload: object) {
  const { data: subs } = await db.from("push_subs").select("id,endpoint,p256dh,auth").eq("user_id", userId);
  let sent = 0;
  for (const s of subs || []) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), { TTL: 60 * 60 * 12 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await db.from("push_subs").delete().eq("id", s.id);
    }
  }
  return sent;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const { data: cfg, error: cfgErr } = await db.rpc("push_config");
  if (cfgErr || !cfg?.vapid_private) return json({ error: "Not set up" }, 500);
  webpush.setVapidDetails("mailto:noreply@moneyboard.app", cfg.vapid_public, cfg.vapid_private);
  const body = await req.json().catch(() => ({}));

  // Test alert for the signed-in user
  if (body.test) {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: u } = await db.auth.getUser(token);
    if (!u?.user) return json({ error: "Sign in first" }, 401);
    const sent = await sendAll(u.user.id, { title: "Test alert", body: "Bill reminders will show up like this, even with the app closed", tag: "test" });
    return json({ sent });
  }

  // Daily run from the scheduled job
  if (req.headers.get("x-cron-secret") !== cfg.cron_secret) return json({ error: "Not allowed" }, 401);
  const { data: subUsers } = await db.from("push_subs").select("user_id");
  const users = [...new Set((subUsers || []).map((r) => r.user_id))];
  let pushed = 0;
  for (const uid of users) {
    // Personal board plus every joint board this person is on
    const boards: { data: any; label: string; scope: string }[] = [];
    const { data: own } = await db.from("boards").select("data").eq("user_id", uid).maybeSingle();
    if (own?.data) boards.push({ data: own.data, label: "", scope: "" });
    const { data: mem } = await db.from("board_members").select("board_id").eq("user_id", uid).is("left_at", null);
    const ids = (mem || []).map((m) => m.board_id);
    if (ids.length) {
      const { data: shared } = await db.from("shared_boards").select("id,name,data").in("id", ids);
      for (const b of shared || []) if (b.data) boards.push({ data: b.data, label: b.name, scope: b.id + "|" });
    }
    let sentAny = false;
    for (const bd of boards) {
      const d = bd.data;
      const st = d.settings || {}, remind = st.remind == null ? 3 : +st.remind;
      if (!remind) continue;
      const today = todayIn(st.tz || "Australia/Brisbane"), end = addDays(today, remind);
      const due: { key: string; name: string; amt: number; date: string }[] = [];
      for (const r of d.recurring || []) {
        if (r.type !== "expense" || !r.next) continue;
        let x = r.next, g = 0;
        while (x <= end && g < 60) {
          if (x >= today) due.push({ key: bd.scope + r.id + "|" + x, name: r.note || r.cat, amt: +r.amount || 0, date: x });
          x = nextDate(x, r.freq, r.day); g++;
        }
      }
      if (!due.length) continue;
      const { data: done } = await db.from("push_log").select("key").eq("user_id", uid).in("key", due.map((b) => b.key));
      const doneSet = new Set((done || []).map((r) => r.key));
      const fresh = due.filter((b) => !doneSet.has(b.key)).sort((a, b) => a.date.localeCompare(b.date));
      if (!fresh.length) continue;
      const cur = st.currency || "AUD", pre = bd.label ? bd.label + ": " : "", tag = "bills-" + (bd.scope || "own-") + today;
      const payload = fresh.length === 1
        ? { title: pre + fresh[0].name + " due " + when(diffDays(today, fresh[0].date)), body: money(fresh[0].amt, cur) + " on " + dayLabel(fresh[0].date), tag }
        : {
            title: pre + fresh.length + " bills due soon, " + money(fresh.reduce((a, b) => a + b.amt, 0), cur) + " total",
            body: fresh.slice(0, 4).map((b) => b.name + " " + money(b.amt, cur) + " " + when(diffDays(today, b.date))).join(", ") + (fresh.length > 4 ? ", plus " + (fresh.length - 4) + " more" : ""),
            tag,
          };
      if (await sendAll(uid, payload)) {
        await db.from("push_log").upsert(fresh.map((b) => ({ user_id: uid, key: b.key })));
        sentAny = true;
      }
    }
    if (sentAny) pushed++;
  }
  await db.from("push_log").delete().lt("sent_at", new Date(Date.now() - 60 * 864e5).toISOString());
  return json({ users: users.length, pushed });
});
