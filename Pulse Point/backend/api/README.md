# Ticker Flip Backend API

For real public deployment, see [PRODUCTION_DEPLOYMENT.md](./PRODUCTION_DEPLOYMENT.md).

This is the local server that lets the iPhone app save data into MySQL on this Mac.

Think of it like this:

```text
iPhone app -> Node API on Mac -> MySQL database on Mac -> browser admin dashboard
```

The iPhone app does **not** connect directly to MySQL. It talks to this API.

## 1) Start in this folder

```bash
cd "/Users/guysmacbookpro/Documents/Heartbeat Video App/Pulse Point/backend/api"
```

## 2) Install dependencies, if needed

```bash
npm install
```

## 3) Check `.env`

The API reads database settings from `.env`.

Required values:

```bash
PORT=3000
API_KEY=your_local_api_key
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=your_mysql_user
DB_PASSWORD=your_mysql_password
DB_NAME=myapp_db
```

Optional:

```bash
ADMIN_PASSWORD=make_one_up_if_you_want_remote_admin_login
PUBLIC_BASE_URL=http://localhost:3000
```

If `ADMIN_PASSWORD` is blank, `/admin` only works from this Mac using `localhost`.

## 4) Create/update the database tables

```bash
npm run setup-db
```

This creates/updates:

- `users`
- `workout_sessions`
- `heart_rate_samples`
- `pvt_results`
- `pvt_trial_points`

## 5) Start the API

```bash
npm start
```

Leave that Terminal window open while testing the app.

## 6) Open the dashboard

On the Mac, open:

```text
http://localhost:3000/admin
```

That page shows users, sessions, heart-rate samples, PVT results, and uploaded video links.

## 7) Test the API from Terminal

Health check:

```bash
curl "http://localhost:3000/health"
```

Create/update a test user:

```bash
curl -X POST "http://localhost:3000/api/users/resolve" \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{"email":"test@tickerflip.local","displayName":"Test User","age":25,"weightLb":180,"heightCm":177.8,"gender":"Test"}'
```

Upload a test session:

```bash
curl -X POST "http://localhost:3000/api/sessions/full" \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{
    "session": {
      "userEmail":"test@tickerflip.local",
      "displayName":"Test User",
      "sessionUuid":"11111111-2222-3333-4444-555555555555",
      "startedAt":"2026-07-19 12:00:00",
      "endedAt":"2026-07-19 12:01:00",
      "durationSeconds":60,
      "minBpm":72,
      "avgBpm":96,
      "maxBpm":138,
      "videoUrl":null
    },
    "heartRateSamples":[
      {"tSeconds":0,"bpm":72},
      {"tSeconds":15,"bpm":92},
      {"tSeconds":30,"bpm":122},
      {"tSeconds":45,"bpm":138},
      {"tSeconds":60,"bpm":105}
    ],
    "prePvt":null,
    "postPvt":null
  }'
```

List sessions for one user:

```bash
curl -X GET "http://localhost:3000/api/sessions?userEmail=test%40tickerflip.local" \
  -H "x-api-key: YOUR_API_KEY"
```

## 8) Make the iPhone reach the Mac

In the app Settings, the API Base URL must be the Mac's Wi-Fi IP, not `127.0.0.1`.

Example:

```text
http://192.168.1.25:3000
```

`127.0.0.1` means “this device.” On your iPhone, that would point to the iPhone itself, not the Mac.

To find the Mac IP:

```bash
ipconfig getifaddr en0
```

Then use:

```text
http://YOUR_MAC_IP:3000
```

The API key in the app must match the `.env` API key.

## Routes

- `GET /health`
- `GET /admin`
- `GET /admin/users/:id`
- `GET /admin/sessions/:id`
- `POST /api/users/resolve`
- `POST /api/users/register`
- `POST /api/upload/video`
- `POST /api/sessions`
- `POST /api/sessions/full`
- `POST /api/sessions/:sessionId/heart-rate`
- `POST /api/pvt-results`
- `GET /api/sessions?userEmail=...`
- `GET /api/sessions/:sessionId`
- `GET /api/sessions/:sessionId/heart-rate`
- `GET /api/sessions/:sessionId/pvt-comparison`
