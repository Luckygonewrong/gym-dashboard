# Iron House: gym management

Static site (GitHub Pages) + Supabase (database + login). Total cost: ₹0.

## Setup (10 min)

1. **Supabase project banao** at supabase.com (free tier). Region: Mumbai (ap-south-1).
2. **Schema chalao:** SQL Editor → New query → `schema.sql` paste → Run. Phir `migrations/002_payments_settings.sql` bhi Run karo.
3. **Signup band karo:** Authentication settings mein "Allow new users to sign up" OFF karo.
   Isse sirf tumhara banaya account login kar payega.
4. **Owner account banao:** Authentication → Users → Add user → email + password ("Auto confirm" on).
5. **Keys daalo:** Project Settings → API Keys se `Project URL` aur publishable key copy karke `config.js` mein paste karo.
   Secret key kabhi frontend mein mat daalna.
6. **Auth URL:** Authentication → URL Configuration → Site URL = `https://<username>.github.io/<repo>/`
7. **Deploy:** repo push karo → Settings → Pages → Branch `main`, folder `/root` → Save.

`config.js` khaali ho toh site demo mode mein sample data ke saath chalti hai.

## Files

| File | Kaam |
|---|---|
| `login.html` | Email + password login (Supabase Auth) |
| `index.html` | Dashboard: pending amount, KPIs, 6 mahine ka collection |
| `members.html` | Members ki list, search, add, delete |
| `fees.html` | Pending fees, quick "Paid" button, is mahine ke payments |
| `payments.html` | Payment lo: plan switch, discount, mode (Cash/UPI/Card/Bank), note, history (`record_payment` RPC) |
| `settings.html` | Gym ka naam + plan fees (har owner ke alag) |
| `reminders.html` | WhatsApp `wa.me` links, message template |
| `data.js` | Supabase/demo data layer + helpers |
| `schema.sql` | Tables, RLS policies, `mark_paid` function |

## Security

- Har table pe RLS on hai: owner sirf apna data dekh sakta hai, chahe anon key public ho.
- `mark_paid` `security invoker` hai, isliye RLS uspe bhi lagu hota hai.

## Note

Supabase free project 1 hafte tak koi request na aaye toh pause ho jaata hai. Owner roz dashboard khole ya daily cron lagao toh active rahega.
