# Ticker Flip Production Deployment

This moves Ticker Flip from your Mac to the internet so other users can use it.

Think of it like this:

```text
iPhone app -> https://api.tickerflip.com -> cloud MySQL/TiDB database
                                      -> cloud video storage
Website    -> https://tickerflip.com
```

The website and API should usually be separate:

- `tickerflip.com` = public website / landing page
- `api.tickerflip.com` = backend API used by the iPhone app
- `admin.tickerflip.com` is optional later; for now `/admin` lives on the API

## Recommended Beginner Stack

Use this first:

- API host: Render Web Service
- Database: TiDB Cloud Starter because it is MySQL-compatible and has a free quota
- Video storage: Cloudflare R2 because API servers should not keep uploaded videos on their own disk
- Auth: Firebase Authentication, already wired into the iOS app

## Why Video Storage Is Separate

The local backend can save videos into `uploads/` on your Mac.

Do not rely on that in production.

Most free app hosts use an ephemeral filesystem. That means uploaded files can disappear after a deploy, restart, or spin-down. Store production videos in Cloudflare R2 or another S3-compatible bucket.

## Step 1: Push Code To GitHub

From the repo root:

```bash
cd "/Users/guysmacbookpro/Documents/Heartbeat Video App"
git status
```

Before deploying, make sure these are not committed:

- `.env`
- `node_modules/`
- `uploads/`

They are already listed in `.gitignore`, but if they were committed earlier, untrack them without deleting local files:

```bash
git rm -r --cached "Pulse Point/backend/api/node_modules" "Pulse Point/backend/api/uploads" || true
git rm --cached "Pulse Point/backend/api/.env" || true
```

Then commit and push:

```bash
git add .
git commit -m "Prepare backend for production deployment"
git push origin main
```

## Step 2: Create Cloud Database

Create a TiDB Cloud Starter database.

Save these values:

```text
DB_HOST=
DB_PORT=4000
DB_USER=
DB_PASSWORD=
DB_NAME=
DB_SSL=true
```

Use the database name you create, for example:

```text
DB_NAME=ticker_flip
```

## Step 3: Create Render API Service

In Render:

1. New Web Service
2. Connect your GitHub repo
3. Root Directory:

```text
Pulse Point/backend/api
```

4. Build Command:

```bash
npm ci && npm run setup-db
```

5. Start Command:

```bash
npm start
```

6. Add Environment Variables:

```text
NODE_VERSION=20
PORT=10000
API_KEY=make_a_long_random_secret
ADMIN_PASSWORD=make_a_private_admin_password
PUBLIC_BASE_URL=https://api.tickerflip.com
ALLOWED_ORIGINS=https://tickerflip.com,https://www.tickerflip.com

DB_HOST=from_tidb
DB_PORT=4000
DB_USER=from_tidb
DB_PASSWORD=from_tidb
DB_NAME=ticker_flip
DB_SSL=true
```

If you are not using Cloudflare R2 yet, leave the R2 variables blank. That is okay for a quick API/database test, but production video uploads need R2.

## Step 4: Optional But Recommended, Set Up Cloudflare R2

Create a Cloudflare R2 bucket and API token.

Then add these Render environment variables:

```text
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_ACCESS_KEY_ID=your_r2_access_key
R2_SECRET_ACCESS_KEY=your_r2_secret_key
R2_BUCKET=ticker-flip-videos
R2_PUBLIC_BASE_URL=https://videos.tickerflip.com
```

`R2_ENDPOINT` can stay blank if `R2_ACCOUNT_ID` is set.

## Step 5: Connect Your Domain

Recommended DNS layout:

```text
tickerflip.com       -> website host
www.tickerflip.com   -> website host
api.tickerflip.com   -> Render API service
videos.tickerflip.com -> Cloudflare R2 public/custom domain
```

In Render, add `api.tickerflip.com` as a Custom Domain for the API service.

In your DNS provider, add the CNAME record Render gives you.

## Step 6: Test The API

Once Render deploys:

```bash
curl "https://api.tickerflip.com/health"
```

Expected:

```json
{"status":"ok","db":"connected"}
```

Test admin:

```text
https://api.tickerflip.com/admin
```

It should ask for the admin password if `ADMIN_PASSWORD` is set.

## Step 7: Point The iPhone App To Production

In the app Settings:

```text
API Base URL: https://api.tickerflip.com
API Key: same API_KEY from Render
```

Later, before App Store/TestFlight users get it, hardcode the production API URL as the default so users do not have to type it manually.

## Step 8: Test Full Pipeline

On your phone:

1. Register/login
2. Record a short session
3. Stop recording
4. Open Review and confirm local save works
5. Confirm API sync succeeds
6. Open admin dashboard and confirm the session/user/video appear

## Important Security Notes

Do not put these in GitHub:

- `.env`
- Firebase private keys
- database passwords
- R2 secret keys
- API key
- admin password

The current API key setup is okay for private testing, but before a full public launch you should replace this with real per-user auth checks using Firebase ID tokens on every API request.
