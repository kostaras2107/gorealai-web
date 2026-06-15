# GorealAI Backend

Node.js/Express backend για push notifications, emails, και Stripe payments.

## Endpoints

| Method | Path | Περιγραφή |
|--------|------|-----------|
| GET | `/` | Health check + status |
| GET | `/health` | Simple health check |
| POST | `/send-push` | FCM push notification |
| POST | `/booking-response` | Accept/reject booking + email + push |
| POST | `/new-offer` | Νέα προσφορά notification |
| POST | `/create-checkout-session` | Stripe subscription checkout |
| POST | `/stripe-webhook` | Stripe webhook (auto-upgrade Premium) |

## Deploy στο Render

1. Πήγαινε στο [render.com](https://render.com) → New → Web Service
2. Σύνδεσε το GitHub repo σου
3. **Root Directory**: `backend`
4. **Build Command**: `npm install`
5. **Start Command**: `npm start`
6. Πρόσθεσε τα **Environment Variables** (από το .env.example)

## Environment Variables που χρειάζονται

### Firebase Admin SDK
1. Firebase Console → Project Settings → Service Accounts
2. "Generate new private key" → Download JSON
3. Copy το περιεχόμενο ως `FIREBASE_SERVICE_ACCOUNT` (ολόκληρο το JSON σε μία γραμμή)

### Stripe
1. [dashboard.stripe.com](https://dashboard.stripe.com) → Developers → API Keys
2. `STRIPE_SECRET_KEY` = Secret key (sk_live_...)
3. `STRIPE_PRICE_ID` = Price ID από το product σου (price_...)
4. `STRIPE_WEBHOOK_SECRET` = Από Webhooks section (whsec_...)
   - Webhook URL: `https://your-render-url.onrender.com/stripe-webhook`
   - Events: `checkout.session.completed`, `customer.subscription.deleted`

### SendGrid
1. [app.sendgrid.com](https://app.sendgrid.com) → Settings → API Keys
2. Verify το domain `gorealai.app` για καλύτερη παραδοτικότητα
