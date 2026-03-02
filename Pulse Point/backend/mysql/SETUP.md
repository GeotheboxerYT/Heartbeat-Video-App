# MySQL + Xcode Setup (Local Dev)

## 1) Create DB in MySQL Workbench
1. Open MySQL Workbench and connect to your local server.
2. Click `File` -> `Open SQL Script...`.
3. Open `schema.sql` from this folder.
4. Click the lightning bolt button (`Execute`).
5. Optional: open and run `seed_dev.sql`.

You should now have schema `heartbeat_video_app` with all required tables.

## 2) Verify tables
Run:
```sql
USE heartbeat_video_app;
SHOW TABLES;
```

Expected tables:
- users
- workout_sessions
- heart_rate_samples
- pvt_results
- pvt_trial_points

## 3) Important: do NOT connect iOS app directly to MySQL
For real apps, use this path:
- iPhone app -> backend API -> MySQL

Why:
- You cannot safely ship DB credentials in an iOS app.
- Backend handles auth, validation, and rate-limits.

## 4) What Xcode should connect to
Xcode app should call your backend endpoints like:
- `POST /api/sessions`
- `POST /api/sessions/{id}/heart-rate`
- `POST /api/pvt-results`
- `GET /api/sessions`

## 5) If you still want local-only testing quickly
- Run backend on your Mac (localhost), e.g. `http://localhost:3000`.
- If testing on physical iPhone, use your Mac LAN IP (e.g. `http://192.168.1.10:3000`).

## 6) Environment variables for backend
Use these in your backend:
- `DB_HOST=127.0.0.1`
- `DB_PORT=3306`
- `DB_USER=<your_mysql_user>`
- `DB_PASSWORD=<your_mysql_password>`
- `DB_NAME=heartbeat_video_app`
