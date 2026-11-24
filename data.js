// Iron House: shared data + helpers.
// LIVE mode: config.js mein Supabase url + key ho toh data Supabase se aata hai.
// DEMO mode: config khaali ho toh sample data, browser ke localStorage mein.
{
const CFG = window.GYM_CONFIG || {};
const live = !!(CFG.url && CFG.anonKey && window.supabase);
const sb = live ? window.supabase.createClient(CFG.url, CFG.anonKey) : null;

const APP = 'Iron House';
const KEY = 'gymdesk-v2';
const DAY = 86400000;
const PLAN_NAMES = ['Monthly','Quarterly','Half-yearly','Yearly'];
const DEFAULT_FEES = { Monthly:1200, Quarterly:3300, 'Half-yearly':6000, Yearly:10500 };
const PLANS = { Monthly:{m:1}, Quarterly:{m:3}, 'Half-yearly':{m:6}, Yearly:{m:12} };
const MODES = ['Cash','UPI','Card','Bank'];
const TEMPLATE = 'Namaste {name}! {gym} ki {plan} fees ₹{amount} ki due date {date} hai. Please time pe jama kar dein. Dhanyavaad 🙏';
const today = new Date(); today.setHours(0,0,0,0);
const iso = t => { const d = new Date(t); return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0'); };
const addDays = n => iso(today.getTime() + n*DAY);
// Postgres jaisa: 31 Jan + 1 mahina = 28/29 Feb
const addMonths = (s, n) => {
  const d = new Date(s+'T00:00:00'), day = d.getDate();
  d.setDate(1); d.setMonth(d.getMonth()+n);
  d.setDate(Math.min(day, new Date(d.getFullYear(), d.getMonth()+1, 0).getDate()));
  return iso(d);
};
const applyFees = fees => PLAN_NAMES.forEach(p => PLANS[p].fee = Number(fees?.[p] ?? DEFAULT_FEES[p]));
applyFees(DEFAULT_FEES);

// ---------- demo data ----------
const SEED = [
  ['Rohit Sharma','9829011223','Monthly',-6], ['Priya Mehta','9414055871','Quarterly',2],
  ['Aman Gupta','9001122334','Monthly',-2], ['Neha Agarwal','9785512340','Yearly',140],
  ['Karan Singh Rathore','9636123456','Monthly',5], ['Sneha Jain','9828877665','Half-yearly',61],
  ['Vikas Choudhary','9460098765','Monthly',0], ['Ritika Saini','9549912345','Monthly',12],
  ['Arjun Khandelwal','9772233445','Quarterly',-11], ['Pooja Sharma','9887766554','Monthly',19],
  ['Manish Yadav','9314455667','Monthly',1], ['Ishita Bansal','9116677889','Yearly',300],
  ['Deepak Meena','9928811223','Monthly',-1], ['Simran Kaur','9358899001','Quarterly',44],
  ['Harsh Vijay','9667788990','Monthly',7], ['Ankit Soni','9413344556','Monthly',23],
  ['Tanvi Mathur','9799900112','Half-yearly',-4], ['Rahul Jangid','9672211009','Monthly',26]
];
function seed(){
  const members = SEED.map((r,i) => ({ id:i+1, name:r[0], phone:r[1], plan:r[2], fee:DEFAULT_FEES[r[2]], due:addDays(r[3]) }));
  const payments = []; let pid = 1;
  for (let k = 5; k >= 0; k--) {
    const base = new Date(today.getFullYear(), today.getMonth()-k, 1);
    const last = k === 0 ? today.getDate() : new Date(base.getFullYear(), base.getMonth()+1, 0).getDate();
    members.forEach((m,i) => {
      const pm = PLANS[m.plan].m;
      if (pm === 1 ? (i + k) % 7 !== 0 : (i + k) % pm === 0)
        payments.push({ pid: pid++, id:m.id, amt:m.fee, plan:m.plan, mode: MODES[i % 2], note:'', date: iso(new Date(base.getFullYear(), base.getMonth(), (i*3 % last) + 1)) });
    });
  }
  return { members, payments, sent:{}, nextId: members.length+1, nextPid: pid, template: TEMPLATE, gym: 'Demo Gym', fees: { ...DEFAULT_FEES } };
}

let db;
function save(){ if (!live) try { localStorage.setItem(KEY, JSON.stringify(db)); } catch {} }
function reset(){ db = seed(); applyFees(db.fees); save(); }
const must = r => { if (r.error) throw r.error; return r.data; };
const MEMBER_COLS = 'id,name,phone,plan,fee,due,reminded_on';

// ---------- load ----------
async function init(){
  if (!live) {
    try { db = JSON.parse(localStorage.getItem(KEY)) || seed(); } catch { db = seed(); }
    applyFees(db.fees); return db;
  }
  const since = iso(new Date(today.getFullYear(), today.getMonth()-11, 1));
  const [members, pays, set] = await Promise.all([
    sb.from('members').select(MEMBER_COLS).order('due').then(must),
    sb.from('payments').select('id,member_id,amount,paid_on,plan,mode,note').gte('paid_on', since).order('paid_on', { ascending:false }).then(must),
    sb.from('settings').select('template,gym_name,plan_fees').maybeSingle().then(must)
  ]);
  db = {
    members,
    payments: pays.map(p => ({ pid:p.id, id:p.member_id, amt:p.amount, date:p.paid_on, plan:p.plan, mode:p.mode, note:p.note || '' })),
    sent: Object.fromEntries(members.filter(m => m.reminded_on).map(m => [m.id, m.reminded_on])),
    template: set?.template || TEMPLATE,
    gym: set?.gym_name || 'My Gym',
    fees: set?.plan_fees || { ...DEFAULT_FEES },
    needsSetup: !set
  };
  applyFees(db.fees);
  return db;
}

// ---------- writes ----------
async function addMember(o){
  if (live) db.members.push(must(await sb.from('members').insert(o).select(MEMBER_COLS).single()));
  else { db.members.push({ id: db.nextId++, ...o }); save(); }
}
async function deleteMember(id){
  if (live) must(await sb.from('members').delete().eq('id', id));
  db.members = db.members.filter(m => m.id !== id); save();
}
// Agli due date: (purani due ya payment date, jo baad mein ho) + plan ke mahine
const nextDue = (m, plan, date = iso(today)) => addMonths(m.due > date ? m.due : date, PLANS[plan].m);

async function recordPayment({ id, plan, amount, mode = 'Cash', date = iso(today), note = '' }){
  const m = db.members.find(x => x.id === id); if (!m) throw new Error('Member nahi mila');
  const due = live
    ? must(await sb.rpc('record_payment', { p_member:id, p_plan:plan, p_amount:amount, p_mode:mode, p_paid_on:date, p_note:note }))
    : nextDue(m, plan, date);
  const pay = { pid: live ? Date.now() : db.nextPid++, id, amt:amount, date, plan, mode, note };
  Object.assign(m, { plan, fee: PLANS[plan].fee, due });
  db.payments.unshift(pay); delete db.sent[id]; save();
  return m;
}
const markPaid = id => { const m = db.members.find(x => x.id === id); return recordPayment({ id, plan:m.plan, amount:m.fee }); };

async function markSent(id){
  db.sent[id] = iso(today);
  if (live) must(await sb.from('members').update({ reminded_on: iso(today) }).eq('id', id));
  else save();
}
async function saveSettings(patch){
  const next = { gym: db.gym, fees: db.fees, template: db.template, ...patch };
  if (live) must(await sb.from('settings').upsert({ gym_name: next.gym, plan_fees: next.fees, template: next.template }, { onConflict: 'owner_id' }));
  Object.assign(db, next, { needsSetup:false }); applyFees(db.fees); save();
}
const saveTemplate = template => saveSettings({ template });

// ---------- auth ----------
async function signIn(email, password){
  if (live) must(await sb.auth.signInWithPassword({ email, password }));
  else try { sessionStorage.setItem('gd-auth','1'); } catch {}
}
async function signOut(){
  if (live) await sb.auth.signOut();
  try { sessionStorage.removeItem('gd-auth'); } catch {}
}
async function loggedIn(){
  if (live) return !!(await sb.auth.getSession()).data.session;
  try { return sessionStorage.getItem('gd-auth') === '1'; } catch { return true; }
}

// ---------- helpers ----------
const daysLeft = m => Math.round((new Date(m.due+'T00:00:00') - today) / DAY);
const status = m => { const d = daysLeft(m); return d < 0 ? 'overdue' : d <= 7 ? 'due' : 'active'; };
const LABEL = { overdue:'Overdue', due:'Due soon', active:'Active', paid:'Paid' };
const money = n => '₹' + Number(n).toLocaleString('en-IN');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const nice = s => new Date(s+'T00:00:00').toLocaleDateString('en-IN', { day:'numeric', month:'short', year: s.slice(0,4) == today.getFullYear() ? undefined : 'numeric' });
const dueText = m => { const d = daysLeft(m); return d < 0 ? `${-d} din late` : d === 0 ? 'Aaj due' : `${d} din baaki`; };

function toast(msg){
  let t = document.querySelector('.toast');
  if (!t) { t = document.createElement('div'); t.className = 'toast'; t.setAttribute('role','status'); document.body.append(t); }
  t.textContent = msg; t.classList.add('on'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('on'), 2800);
}
const fail = e => { console.error(e); toast('Error: ' + (e?.message || 'kuch gadbad hui')); };

// Har page: login check + data load + nav. false = page mat chalao.
async function boot(cur){
  document.documentElement.classList.toggle('live', live);
  if (!(await loggedIn())) { location.href = 'login.html'; return false; }
  let ok = true;
  try { await init(); } catch (e) { fail(e); ok = false; }
  const links = [['index.html','Dashboard'],['members.html','Members'],['fees.html','Fees'],['payments.html','Payments'],['reminders.html','Reminders'],['settings.html','Settings']];
  document.getElementById('nav').innerHTML = `<div class="bar">
    <a class="brand" href="index.html"><span class="plates" aria-hidden="true"><i></i><i></i><i></i></span><span>${esc(db?.gym || 'My Gym')}<small class="by">by ${APP}${live ? '' : ' · demo'}</small></span></a>
    <nav>${links.map(([h,t]) => `<a href="${h}"${cur===h?' aria-current="page"':''}>${t}</a>`).join('')}</nav>
    <a class="out" href="login.html" id="logout">Log out</a></div>
    ${ok && db.needsSetup && cur !== 'settings.html' ? '<div class="setup">Apne gym ka naam aur plan fees set karo → <a href="settings.html">Settings</a></div>' : ''}`;
  document.getElementById('logout').addEventListener('click', async e => { e.preventDefault(); await signOut(); location.href = 'login.html'; });
  document.title = `${document.title.split(' · ')[0]} · ${db?.gym || APP}`;
  return ok;
}

// stack-table labels for phones
new MutationObserver(() => { for (const c of document.querySelectorAll('.stack td:not([data-l])')) { let i=0,p=c; while (p = p.previousElementSibling) i += p.colSpan; c.dataset.l = c.closest('table').rows[0].cells[i]?.textContent || ''; } })
  .observe(document, { childList:true, subtree:true });

window.G = { APP, live, PLANS, PLAN_NAMES, MODES, today, iso, boot, reset, daysLeft, status, LABEL, money, esc, nice, dueText, nextDue,
  addMember, deleteMember, recordPayment, markPaid, markSent, saveTemplate, saveSettings, signIn, loggedIn, toast, fail, get db(){ return db; } };
}
