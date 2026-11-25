// Shared data + helpers. Data Supabase se aata hai (config.js).
{
const CFG = window.GYM_CONFIG || {};
const ready = !!(CFG.url && CFG.anonKey && window.supabase);
const sb = ready ? window.supabase.createClient(CFG.url, CFG.anonKey) : null;

const DAY = 86400000;
const PAGE = 1000; // Supabase ek baar mein max 1000 rows deta hai
const PLAN_NAMES = ['Monthly','Quarterly','Half-yearly','Yearly'];
const DEFAULT_FEES = { Monthly:1200, Quarterly:3300, 'Half-yearly':6000, Yearly:10500 };
// Plan ki lambai dinon mein (database ke record_payment jaisa)
const PLANS = { Monthly:{days:30}, Quarterly:{days:90}, 'Half-yearly':{days:180}, Yearly:{days:365} };
const TEMPLATE = 'Namaste {name}! Aapki {plan} fees ₹{amount} ki due date {date} hai. Please time pe jama kar dein. Dhanyavaad 🙏';
const MEMBER_COLS = 'id,name,phone,plan,fee,due,reminded_on';

const today = new Date(); today.setHours(0,0,0,0);
const iso = t => { const d = new Date(t); return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0'); };
const addDays = (s, n) => { const d = new Date(s+'T00:00:00'); d.setDate(d.getDate()+n); return iso(d); };
const applyFees = fees => PLAN_NAMES.forEach(p => PLANS[p].fee = Number(fees?.[p] ?? DEFAULT_FEES[p]));
applyFees(DEFAULT_FEES);

let db;
const must = r => { if (r.error) throw friendly(r.error); return r.data; };
function friendly(e){
  if (e?.code === '23505') return new Error('Ye phone number pehle se kisi member ka hai');
  if (e?.code === '23514') return new Error('Kuch value galat hai (phone 10 digit, amount 0 se zyada)');
  return e;
}
// 1000 se zyada rows ho toh pages mein laao
async function fetchAll(build){
  const out = [];
  for (let from = 0; ; from += PAGE) {
    const rows = must(await build().range(from, from + PAGE - 1));
    out.push(...rows);
    if (rows.length < PAGE) return out;
  }
}

// ---------- load ----------
async function init(){
  const monthStart = iso(new Date(today.getFullYear(), today.getMonth(), 1));
  const [members, pays, stats, set] = await Promise.all([
    fetchAll(() => sb.from('members').select(MEMBER_COLS).order('due').order('id')),
    fetchAll(() => sb.from('payments').select('id,member_id,amount,paid_on,plan,mode').gte('paid_on', monthStart).order('paid_on', { ascending:false }).order('id')),
    sb.rpc('monthly_collection', { p_months: 6 }).then(must),
    sb.from('settings').select('template,plan_fees').maybeSingle().then(must)
  ]);
  db = {
    members,
    payments: pays.map(p => ({ id:p.member_id, amt:p.amount, date:p.paid_on, plan:p.plan, mode:p.mode })), // sirf is mahine ke
    stats: stats.map(s => ({ month: s.month.slice(0,7), total: Number(s.total), count: Number(s.payments) })),
    sent: Object.fromEntries(members.filter(m => m.reminded_on).map(m => [m.id, m.reminded_on])),
    template: set?.template || TEMPLATE,
    fees: set?.plan_fees || { ...DEFAULT_FEES }
  };
  applyFees(db.fees);
  return db;
}

// ---------- writes ----------
async function addMember(o){
  db.members.push(must(await sb.from('members').insert(o).select(MEMBER_COLS).single()));
}
async function deleteMember(id){
  must(await sb.from('members').delete().eq('id', id));
  db.members = db.members.filter(m => m.id !== id);
}
// Agli due date. from: 'today' = aaj se, 'due' = jab se due tha
const nextDue = (m, plan, from) => addDays(from === 'today' ? iso(today) : m.due, PLANS[plan].days);

async function payMember(id, { plan, amount, mode = 'Cash', from = 'due' }){
  const m = db.members.find(x => x.id === id); if (!m) throw new Error('Member nahi mila');
  const due = must(await sb.rpc('record_payment', { p_member:id, p_plan:plan, p_amount:amount, p_mode:mode, p_from:from }));
  // discount sirf is payment pe; plan badla toh fee = naye plan ki standard fee (database jaisa)
  if (plan !== m.plan) m.fee = PLANS[plan].fee;
  Object.assign(m, { plan, due });
  db.payments.unshift({ id, amt:amount, date:iso(today), plan, mode });
  const s = db.stats.find(x => x.month === iso(today).slice(0,7));
  if (s) { s.total += amount; s.count++; } else db.stats.push({ month: iso(today).slice(0,7), total: amount, count: 1 });
  delete db.sent[id];
  return m;
}
async function markSent(id){
  must(await sb.from('members').update({ reminded_on: iso(today) }).eq('id', id));
  db.sent[id] = iso(today);
}
async function saveTemplate(template){
  must(await sb.from('settings').upsert({ template }, { onConflict: 'owner_id' }));
  db.template = template;
}
async function saveFees(fees){
  must(await sb.from('settings').upsert({ plan_fees: fees }, { onConflict: 'owner_id' }));
  db.fees = fees; applyFees(fees);
}

// ---------- auth ----------
async function signIn(email, password){ must(await sb.auth.signInWithPassword({ email, password })); }
async function signOut(){ try { sessionStorage.removeItem('ih-admin'); } catch {} await sb.auth.signOut(); }
async function loggedIn(){ return !!(await sb.auth.getSession()).data.session; }
// Iron House admin (tum) ho ya gym owner. Migration se pehle function na ho toh false.
async function isAdmin(){
  const uid = (await sb.auth.getSession()).data.session?.user?.id; if (!uid) return false;
  try { const c = sessionStorage.getItem('ih-admin'); if (c) { const [u, v] = c.split(':'); if (u === uid) return v === '1'; } } catch {}
  const r = await sb.rpc('is_admin'); const v = !r.error && r.data === true;
  try { sessionStorage.setItem('ih-admin', uid + ':' + (v ? 1 : 0)); } catch {}
  return v;
}

// ---------- helpers ----------
const daysLeft = m => Math.round((new Date(m.due+'T00:00:00') - today) / DAY);
const status = m => { const d = daysLeft(m); return d < 0 ? 'overdue' : d <= 7 ? 'due' : 'active'; };
const LABEL = { overdue:'Overdue', due:'Due soon', active:'Active', paid:'Paid' };
const money = n => '₹' + Number(n).toLocaleString('en-IN');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
// Is saal ki date pe saal nahi, dusre saal ki date pe saal bhi
const nice = s => new Date(s+'T00:00:00').toLocaleDateString('en-IN',
  { day:'numeric', month:'short', year: +s.slice(0,4) === today.getFullYear() ? undefined : 'numeric' });
const dueText = m => { const d = daysLeft(m); return d < 0 ? `${-d} din late` : d === 0 ? 'Aaj due' : `${d} din baaki`; };

function toast(msg){
  let t = document.querySelector('.toast');
  if (!t) { t = document.createElement('div'); t.className = 'toast'; t.setAttribute('role','status'); document.body.append(t); }
  t.textContent = msg; t.classList.add('on'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('on'), 2800);
}
const fail = e => { console.error(e); toast('Error: ' + (e?.message || 'kuch gadbad hui')); };

// Page raat bhar khula rahe toh naye din pe refresh, taaki "aaj" sahi rahe
const freshDay = () => { if (iso(new Date()) !== iso(today)) location.reload(); };
document.addEventListener('visibilitychange', () => { if (!document.hidden) freshDay(); });
setInterval(freshDay, 10 * 60 * 1000);

// Har page: login check + nav + data load. false = page mat chalao.
async function boot(cur){
  if (!ready) { toast('config.js mein Supabase url/key nahi hai'); return false; }
  if (!(await loggedIn())) { location.href = 'login.html'; return false; }
  if (await isAdmin()) { location.href = 'admin.html'; return false; }
  const links = [['index.html','Dashboard'],['members.html','Members'],['fees.html','Fees'],['reminders.html','Reminders']];
  document.getElementById('nav').innerHTML = `<div class="bar">
    <a class="brand" href="index.html"><span class="plates" aria-hidden="true"><i></i><i></i><i></i></span>Iron House Gym</a>
    <nav>${links.map(([h,t]) => `<a href="${h}"${cur===h?' aria-current="page"':''}>${t}</a>`).join('')}</nav>
    <span class="acct"><a class="out" href="settings.html"${cur==='settings.html'?' aria-current="page"':''}>Settings</a><a class="out" href="login.html" id="logout">Log out</a></span></div>`;
  document.getElementById('logout').addEventListener('click', async e => { e.preventDefault(); await signOut(); location.href = 'login.html'; });
  try { await init(); return true; }
  catch (e) { fail(e); return false; }
}

// stack-table labels for phones
new MutationObserver(() => { for (const c of document.querySelectorAll('.stack td:not([data-l])')) { let i=0,p=c; while (p = p.previousElementSibling) i += p.colSpan; c.dataset.l = c.closest('table').rows[0].cells[i]?.textContent || ''; } })
  .observe(document, { childList:true, subtree:true });

window.G = { sb, isAdmin, signOut, ready, PLANS, PLAN_NAMES, DEFAULT_FEES, today, iso, addDays, boot, daysLeft, status, LABEL, money, esc, nice, dueText, nextDue,
  addMember, deleteMember, payMember, markSent, saveTemplate, saveFees, signIn, loggedIn, toast, fail, get db(){ return db; } };
}
