// Shared data + helpers.
// LIVE mode: config.js mein Supabase url + anonKey ho toh data Supabase se aata hai.
// DEMO mode: config khaali ho toh sample data, browser ke localStorage mein.
{
const CFG = window.GYM_CONFIG || {};
const live = !!(CFG.url && CFG.anonKey && window.supabase);
const sb = live ? window.supabase.createClient(CFG.url, CFG.anonKey) : null;

const KEY = 'gymdesk-v1';
const DAY = 86400000;
const PLANS = { Monthly:{m:1,fee:1200}, Quarterly:{m:3,fee:3300}, 'Half-yearly':{m:6,fee:6000}, Yearly:{m:12,fee:10500} };
const TEMPLATE = 'Namaste {name}! Iron House Gym ki {plan} fees ₹{amount} ki due date {date} hai. Please time pe jama kar dein. Dhanyavaad 🙏';
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
  const members = SEED.map((r,i) => ({ id:i+1, name:r[0], phone:r[1], plan:r[2], fee:PLANS[r[2]].fee, due:addDays(r[3]) }));
  const payments = [];
  for (let k = 5; k >= 0; k--) {
    const base = new Date(today.getFullYear(), today.getMonth()-k, 1);
    const last = k === 0 ? today.getDate() : new Date(base.getFullYear(), base.getMonth()+1, 0).getDate();
    members.forEach((m,i) => {
      const pm = PLANS[m.plan].m;
      if (pm === 1 ? (i + k) % 7 !== 0 : (i + k) % pm === 0)
        payments.push({ id:m.id, amt:m.fee, plan:m.plan, mode: i % 2 ? 'Online' : 'Cash', date: iso(new Date(base.getFullYear(), base.getMonth(), (i*3 % last) + 1)) });
    });
  }
  return { members, payments, sent:{}, nextId: members.length+1, template: TEMPLATE };
}

let db;
function save(){ if (!live) try { localStorage.setItem(KEY, JSON.stringify(db)); } catch {} }
function reset(){ db = seed(); save(); }
const must = r => { if (r.error) throw r.error; return r.data; };

// ---------- load ----------
async function init(){
  if (!live) {
    try { db = JSON.parse(localStorage.getItem(KEY)) || seed(); } catch { db = seed(); }
    return db;
  }
  const since = iso(new Date(today.getFullYear(), today.getMonth()-5, 1));
  const [members, pays, set] = await Promise.all([
    sb.from('members').select('id,name,phone,plan,fee,due,reminded_on').order('due').then(must),
    sb.from('payments').select('member_id,amount,paid_on,plan,mode').gte('paid_on', since).then(must),
    sb.from('settings').select('template').maybeSingle().then(must)
  ]);
  db = {
    members,
    payments: pays.map(p => ({ id:p.member_id, amt:p.amount, date:p.paid_on, plan:p.plan, mode:p.mode })),
    sent: Object.fromEntries(members.filter(m => m.reminded_on).map(m => [m.id, m.reminded_on])),
    template: set?.template || TEMPLATE
  };
  return db;
}

// ---------- writes ----------
async function addMember(o){
  if (live) db.members.push(must(await sb.from('members').insert(o).select('id,name,phone,plan,fee,due,reminded_on').single()));
  else { db.members.push({ id: db.nextId++, ...o }); save(); }
}
async function deleteMember(id){
  if (live) must(await sb.from('members').delete().eq('id', id));
  db.members = db.members.filter(m => m.id !== id); save();
}
// Agli due date. from: 'today' = aaj se, 'due' = jab se due tha
const nextDue = (m, plan, from) => addMonths(from === 'today' ? iso(today) : m.due, PLANS[plan].m);

async function payMember(id, { plan, amount, mode = 'Cash', from = 'due' }){
  const m = db.members.find(x => x.id === id); if (!m) throw new Error('Member nahi mila');
  const due = live
    ? must(await sb.rpc('record_payment', { p_member:id, p_plan:plan, p_amount:amount, p_mode:mode, p_from:from }))
    : nextDue(m, plan, from);
  if (plan !== m.plan) m.fee = amount;
  Object.assign(m, { plan, due });
  db.payments.push({ id, amt:amount, date:iso(today), plan, mode });
  delete db.sent[id]; save();
  return m;
}
const markPaid = id => { const m = db.members.find(x => x.id === id); return payMember(id, { plan:m.plan, amount:m.fee }); };
async function markSent(id){
  db.sent[id] = iso(today);
  if (live) must(await sb.from('members').update({ reminded_on: iso(today) }).eq('id', id));
  else save();
}
async function saveTemplate(t){
  if (live) must(await sb.from('settings').upsert({ template: t }, { onConflict: 'owner_id' }));
  db.template = t; save();
}

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
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const nice = s => new Date(s+'T00:00:00').toLocaleDateString('en-IN', { day:'numeric', month:'short' });
const dueText = m => { const d = daysLeft(m); return d < 0 ? `${-d} din late` : d === 0 ? 'Aaj due' : `${d} din baaki`; };

function toast(msg){
  let t = document.querySelector('.toast');
  if (!t) { t = document.createElement('div'); t.className = 'toast'; t.setAttribute('role','status'); document.body.append(t); }
  t.textContent = msg; t.classList.add('on'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('on'), 2600);
}
const fail = e => { console.error(e); toast('Error: ' + (e?.message || 'kuch gadbad hui')); };

// Har page: login check + nav + data load. false = page mat chalao.
async function boot(cur){
  if (!(await loggedIn())) { location.href = 'login.html'; return false; }
  const links = [['index.html','Dashboard'],['members.html','Members'],['fees.html','Fees'],['reminders.html','Reminders']];
  document.getElementById('nav').innerHTML = `<div class="bar">
    <a class="brand" href="index.html"><span class="plates" aria-hidden="true"><i></i><i></i><i></i></span>Iron House Gym</a>
    <nav>${links.map(([h,t]) => `<a href="${h}"${cur===h?' aria-current="page"':''}>${t}</a>`).join('')}</nav>
    ${live ? '' : '<span class="out">Demo mode</span>'}
    <a class="out" href="login.html" id="logout">Log out</a></div>`;
  document.getElementById('logout').addEventListener('click', async e => { e.preventDefault(); await signOut(); location.href = 'login.html'; });
  try { await init(); return true; }
  catch (e) { fail(e); return false; }
}

// stack-table labels for phones
new MutationObserver(() => { for (const c of document.querySelectorAll('.stack td:not([data-l])')) { let i=0,p=c; while (p = p.previousElementSibling) i += p.colSpan; c.dataset.l = c.closest('table').rows[0].cells[i]?.textContent || ''; } })
  .observe(document, { childList:true, subtree:true });

window.G = { live, PLANS, today, iso, boot, reset, daysLeft, status, LABEL, money, esc, nice, dueText,
  addMember, deleteMember, markPaid, payMember, nextDue, markSent, saveTemplate, signIn, loggedIn, toast, fail, get db(){ return db; } };
}
