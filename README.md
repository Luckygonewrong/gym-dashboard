# Iron House Gym: owner dashboard

Static site (GitHub Pages) + Supabase (database + login). Total cost: ₹0.

## Setup: naya project (10 min)

1. **Supabase project banao** at supabase.com (free tier). Region: Mumbai (ap-south-1).
2. **Schema chalao:** SQL Editor → New query → `schema.sql` paste → Run. (Naye project ko migrations ki zaroorat nahi.)
3. **Signup band karo:** Authentication settings mein "Allow new users to sign up" OFF karo.
   Isse sirf tumhara banaya account login kar payega.
4. **Owner account banao:** Authentication → Users → Add user → email + password ("Auto confirm" on).
5. **Keys daalo:** Project Settings → API Keys se `Project URL` aur publishable key copy karke `config.js` mein paste karo.
   Secret key kabhi frontend mein mat daalna.
6. **Deploy:** repo push karo → Settings → Pages → Branch `main`, folder `/root` → Save.
7. Login karke **Settings** mein apne gym ki plan fees daalo.

## Live project update karna

- Database badalna ho toh `migrations/` ki nayi file SQL Editor mein chalao, **code push karne se pehle**.
- Push se pehle `tools/bump-version.sh` chalao. Isse CSS/JS ka `?v=` badal jaata hai aur phone purani files nahi chalata.

## Files

| File | Kaam |
|---|---|
| `login.html` | Email + password login (Supabase Auth) |
| `index.html` | Dashboard: pending amount, KPIs, 6 mahine ka collection (`monthly_collection` RPC) |
| `members.html` | Members ki list, search, add, delete |
| `fees.html` | Pending fees, "Paid" form: plan, Cash/Online, aaj se ya due date se (`record_payment` RPC). Plan: Monthly 30 din, Quarterly 90, Half-yearly 180, Yearly 365 |
| `reminders.html` | WhatsApp `wa.me` links, message template |
| `settings.html` | Har owner ki apni plan fees |
| `admin.html` | **Iron House admin (sirf tum):** kitne gym jude, 7 din trial, ₹2000/month, har gym ka data, Excel download + live Excel link |
| `data.js` | Supabase data layer + helpers |
| `schema.sql` | Poora current schema: tables, RLS, functions |
| `migrations/` | Live database ke liye step-by-step badlav |
| `tests/` | Due date aur payment logic ke tests |
| `tools/bump-version.sh` | Cache-busting |

## Admin (Iron House)

- Apne liye ek alag login banao (gym owner wala nahi). Phir SQL Editor mein:
  `insert into public.admins (user_id) select id from auth.users where lower(email) = lower('tumhara@email.com');`
- Admin login karega toh seedha `admin.html` khulega. Gym owners ko ye page nahi dikhta (database bhi mana karta hai).
- Naya gym: admin page pe "+ Naya gym" (trial yahin se shuru), phir Supabase mein usi email se owner ka login banao.
- Trial 7 din (start ka din bhi gina). "Payment mila" dabane pe plan trial/purane plan ke baad se 30 din aage.
- Live Excel: admin page pe "Naya Excel link banao", code Excel ke Power Query mein paste. Link sirf padh sakta hai; leak ho toh "Saare links band karo".

## Tests

```bash
node --test tests/*.test.mjs        # browser wala date logic
tests/run_db_tests.sh               # khaali local Postgres pe (PGHOST/PGDATABASE set karke)
```

DB tests Supabase pe mat chalana: wo test users aur members banate hain.

## Security

- Har table pe RLS on hai: owner sirf apna data dekh sakta hai, chahe publishable key public ho.
- Saare functions `security invoker` hain, isliye RLS unpe bhi lagu hota hai.
- Ek owner ke paas ek phone number ek hi baar.

## Note

Supabase free project 1 hafte tak koi request na aaye toh pause ho jaata hai. Owner roz dashboard khole toh active rahega.
