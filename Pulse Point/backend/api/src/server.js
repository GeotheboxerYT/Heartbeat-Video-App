require('dotenv').config();

const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const multer = require('multer');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');
const { pool } = require('./db');

const app = express();

// The admin dashboard uses simple inline styling because it is local-only.
app.use(helmet({ contentSecurityPolicy: false }));
const allowedOrigins = (process.env.ALLOWED_ORIGINS || '')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

app.use(cors(allowedOrigins.length ? {
  origin(origin, callback) {
    if (!origin || allowedOrigins.includes(origin)) {
      callback(null, true);
      return;
    }
    callback(new Error('Origin is not allowed by CORS'));
  }
} : undefined));
app.use(express.json({ limit: '10mb' }));
app.use(morgan('dev'));

const uploadsDir = path.resolve(process.cwd(), 'uploads');
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}

const upload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, uploadsDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || '.mov') || '.mov';
      cb(null, `${Date.now()}-${Math.round(Math.random() * 1e9)}${ext}`);
    }
  }),
  limits: { fileSize: 1024 * 1024 * 1024 }
});

app.use('/uploads', express.static(uploadsDir));

let objectStorageClient;

function isObjectStorageConfigured() {
  return Boolean(
    process.env.R2_BUCKET &&
    process.env.R2_ACCESS_KEY_ID &&
    process.env.R2_SECRET_ACCESS_KEY &&
    (process.env.R2_ENDPOINT || process.env.R2_ACCOUNT_ID)
  );
}

function getObjectStorageClient() {
  if (objectStorageClient) return objectStorageClient;

  const endpoint = process.env.R2_ENDPOINT ||
    `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;

  objectStorageClient = new S3Client({
    region: 'auto',
    endpoint,
    credentials: {
      accessKeyId: process.env.R2_ACCESS_KEY_ID,
      secretAccessKey: process.env.R2_SECRET_ACCESS_KEY
    }
  });

  return objectStorageClient;
}

function publicObjectURL(objectKey) {
  const base = cleanString(process.env.R2_PUBLIC_BASE_URL);
  if (base) {
    return `${base.replace(/\/+$/, '')}/${objectKey}`;
  }
  return `r2://${process.env.R2_BUCKET}/${objectKey}`;
}

async function uploadFileToObjectStorage(file) {
  const objectKey = `videos/${file.filename}`;
  const client = getObjectStorageClient();

  await client.send(new PutObjectCommand({
    Bucket: process.env.R2_BUCKET,
    Key: objectKey,
    Body: fs.createReadStream(file.path),
    ContentType: file.mimetype || 'application/octet-stream'
  }));

  fs.promises.unlink(file.path).catch(() => {});

  return {
    objectKey,
    videoUrl: publicObjectURL(objectKey)
  };
}

function cleanString(value) {
  if (value === undefined || value === null) return null;
  const cleaned = String(value).trim();
  return cleaned.length ? cleaned : null;
}

function normalizeEmail(value) {
  return cleanString(value)?.toLowerCase() || null;
}

function numberOrNull(value) {
  if (value === undefined || value === null || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function intOrNull(value) {
  const number = numberOrNull(value);
  return number === null ? null : Math.round(number);
}

function mysqlDate(value) {
  if (!value) return null;
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/.test(value)) {
    return value;
  }

  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) return cleanString(value);
  return date.toISOString().slice(0, 19).replace('T', ' ');
}

function escapeHTML(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function formatDate(value) {
  if (!value) return '-';
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) return escapeHTML(value);
  return escapeHTML(date.toLocaleString());
}

function formatNumber(value, suffix = '') {
  if (value === undefined || value === null || value === '') return '-';
  const number = Number(value);
  if (!Number.isFinite(number)) return escapeHTML(value);
  return `${number.toLocaleString(undefined, { maximumFractionDigits: 1 })}${suffix}`;
}

function formatDuration(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value)) return '-';
  const mins = Math.floor(value / 60);
  const secs = Math.round(value % 60);
  return mins > 0 ? `${mins}m ${secs}s` : `${secs}s`;
}

function formatHeight(cm) {
  const value = Number(cm);
  if (!Number.isFinite(value) || value <= 0) return '-';
  const totalInches = Math.round(value / 2.54);
  const feet = Math.floor(totalInches / 12);
  const inches = totalInches % 12;
  return `${feet}'${inches}"`;
}

function isLocalRequest(req) {
  const ip = req.ip || req.socket.remoteAddress || '';
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
}

function requireAdmin(req, res, next) {
  const password = process.env.ADMIN_PASSWORD;
  if (!password) {
    if (isLocalRequest(req)) return next();
    return res.status(403).send('Admin dashboard is local-only unless ADMIN_PASSWORD is set.');
  }

  const header = req.header('authorization') || '';
  const [scheme, encoded] = header.split(' ');
  if (scheme !== 'Basic' || !encoded) {
    res.setHeader('WWW-Authenticate', 'Basic realm="Ticker Flip Admin"');
    return res.status(401).send('Admin password required.');
  }

  const decoded = Buffer.from(encoded, 'base64').toString('utf8');
  const [, providedPassword = ''] = decoded.split(':');
  if (providedPassword !== password) {
    res.setHeader('WWW-Authenticate', 'Basic realm="Ticker Flip Admin"');
    return res.status(401).send('Admin password required.');
  }

  return next();
}

function requireApiKey(req, res, next) {
  const configuredKey = process.env.API_KEY;
  if (!configuredKey) return next();

  const requestKey = req.header('x-api-key');
  if (requestKey !== configuredKey) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  return next();
}

function routeError(res, error) {
  const status = error.statusCode || 500;
  return res.status(status).json({ error: error.message || 'Internal server error' });
}

function userIdentityFrom(value = {}) {
  return {
    userId: intOrNull(value.userId || value.user_id || value.id),
    email: normalizeEmail(value.userEmail || value.email),
    firebaseUid: cleanString(value.firebaseUid || value.firebase_uid),
    passwordHash: cleanString(value.passwordHash || value.password_hash) || 'managed-by-ticker-flip',
    displayName: cleanString(value.displayName || value.display_name || value.username || value.name),
    age: intOrNull(value.age),
    weightLb: numberOrNull(value.weightLb || value.weight_lb),
    heightCm: numberOrNull(value.heightCm || value.height_cm),
    gender: cleanString(value.gender),
    termsAcceptedAt: mysqlDate(value.termsAcceptedAt || value.terms_accepted_at)
  };
}

async function updateUserFields(db, userId, identity) {
  const fields = ['last_seen_at = CURRENT_TIMESTAMP'];
  const values = [];

  const maybeAdd = (column, value) => {
    if (value === undefined || value === null || value === '') return;
    fields.push(`${column} = ?`);
    values.push(value);
  };

  maybeAdd('email', identity.email);
  maybeAdd('firebase_uid', identity.firebaseUid);
  maybeAdd('display_name', identity.displayName);
  maybeAdd('age', identity.age);
  maybeAdd('weight_lb', identity.weightLb);
  maybeAdd('height_cm', identity.heightCm);
  maybeAdd('gender', identity.gender);
  maybeAdd('terms_accepted_at', identity.termsAcceptedAt);

  values.push(userId);
  await db.execute(`UPDATE users SET ${fields.join(', ')} WHERE id = ?`, values);
}

async function findUserId(db, identity) {
  if (identity.userId) return identity.userId;

  if (identity.firebaseUid) {
    const [rows] = await db.execute('SELECT id FROM users WHERE firebase_uid = ? LIMIT 1', [identity.firebaseUid]);
    if (rows.length) return rows[0].id;
  }

  if (identity.email) {
    const [rows] = await db.execute('SELECT id FROM users WHERE email = ? LIMIT 1', [identity.email]);
    if (rows.length) return rows[0].id;
  }

  return null;
}

async function resolveUser(db, rawIdentity) {
  const identity = userIdentityFrom(rawIdentity);
  if (!identity.userId && !identity.email && !identity.firebaseUid) {
    const error = new Error('userId, email, or firebaseUid is required');
    error.statusCode = 400;
    throw error;
  }

  let existingId = await findUserId(db, identity);
  if (existingId) {
    await updateUserFields(db, existingId, identity);
    return { id: existingId, email: identity.email, displayName: identity.displayName };
  }

  const fallbackEmail = identity.email || `local-user-${identity.userId || Date.now()}@tickerflip.local`;
  const displayName = identity.displayName || fallbackEmail.split('@')[0];

  try {
    const [insert] = await db.execute(
      `INSERT INTO users
       (id, firebase_uid, email, password_hash, display_name, age, weight_lb, height_cm, gender, terms_accepted_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
      [
        identity.userId || null,
        identity.firebaseUid,
        fallbackEmail,
        identity.passwordHash,
        displayName,
        identity.age,
        identity.weightLb,
        identity.heightCm,
        identity.gender,
        identity.termsAcceptedAt
      ]
    );

    return { id: insert.insertId || identity.userId, email: fallbackEmail, displayName };
  } catch (error) {
    if (error.code !== 'ER_DUP_ENTRY') throw error;
    existingId = await findUserId(db, { ...identity, email: fallbackEmail });
    if (!existingId) throw error;
    await updateUserFields(db, existingId, { ...identity, email: fallbackEmail, displayName });
    return { id: existingId, email: fallbackEmail, displayName };
  }
}

function renderPage(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)} · Ticker Flip Admin</title>
  <style>
    :root { color-scheme: dark; --bg:#08090c; --panel:#141820; --panel2:#1d2430; --text:#f5f7fb; --muted:#9aa4b2; --line:#2d3644; --accent:#72d6ff; --danger:#ff6b6b; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: radial-gradient(circle at top left, #18283a 0, #08090c 44rem); color:var(--text); }
    main { width:min(1180px, calc(100vw - 28px)); margin:0 auto; padding:28px 0 52px; }
    a { color:var(--accent); text-decoration:none; }
    a:hover { text-decoration:underline; }
    .top { display:flex; justify-content:space-between; gap:16px; align-items:flex-end; margin-bottom:20px; }
    .eyebrow { color:var(--muted); text-transform:uppercase; letter-spacing:.14em; font-size:12px; font-weight:800; }
    h1 { margin:.2rem 0 0; font-size:clamp(30px, 5vw, 54px); line-height:1; }
    h2 { margin:0 0 12px; font-size:20px; }
    .grid { display:grid; grid-template-columns:repeat(4, minmax(0,1fr)); gap:12px; margin:16px 0; }
    .card { background:linear-gradient(180deg, rgba(255,255,255,.07), rgba(255,255,255,.03)); border:1px solid var(--line); border-radius:20px; padding:16px; box-shadow:0 18px 55px rgba(0,0,0,.22); }
    .metric { font-size:30px; font-weight:900; margin-top:4px; }
    .muted { color:var(--muted); }
    table { width:100%; border-collapse:collapse; overflow:hidden; border-radius:16px; }
    th, td { padding:11px 10px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; font-size:14px; }
    th { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.08em; }
    tr:hover td { background:rgba(255,255,255,.03); }
    .pill { display:inline-flex; align-items:center; border:1px solid var(--line); border-radius:999px; padding:4px 8px; color:var(--muted); font-size:12px; }
    .stack { display:grid; gap:16px; }
    .two { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
    .spark { width:100%; height:220px; background:#0b0d12; border:1px solid var(--line); border-radius:18px; padding:10px; }
    .filters { display:grid; grid-template-columns:2fr 1fr 1fr 1fr auto; gap:10px; align-items:end; }
    label { display:grid; gap:5px; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.08em; font-weight:800; }
    input, select, button { width:100%; border:1px solid var(--line); border-radius:12px; padding:10px 11px; background:#0b0d12; color:var(--text); font:inherit; }
    button { cursor:pointer; background:linear-gradient(180deg, rgba(114,214,255,.2), rgba(114,214,255,.08)); color:var(--text); font-weight:800; }
    button:hover { border-color:var(--accent); }
    .danger { color:var(--danger); }
    @media (max-width:800px) { .grid, .two, .filters { grid-template-columns:1fr; } .top { display:block; } }
  </style>
</head>
<body>
  <main>${body}</main>
</body>
</html>`;
}

function renderSparkline(samples) {
  if (!samples.length) return '<div class="muted">No heart-rate samples for this session.</div>';
  const maxPoints = 600;
  const step = Math.max(1, Math.ceil(samples.length / maxPoints));
  const points = samples.filter((_sample, index) => index % step === 0);
  const minBpm = Math.min(...points.map((point) => Number(point.bpm)));
  const maxBpm = Math.max(...points.map((point) => Number(point.bpm)));
  const low = Math.max(30, minBpm - 8);
  const high = Math.max(low + 10, maxBpm + 8);
  const lastT = Math.max(...points.map((point) => Number(point.t_seconds) || 0), 1);
  const pathPoints = points.map((point) => {
    const x = ((Number(point.t_seconds) || 0) / lastT) * 1000;
    const y = 180 - (((Number(point.bpm) - low) / (high - low)) * 160);
    return `${x.toFixed(1)},${Math.max(10, Math.min(190, y)).toFixed(1)}`;
  }).join(' ');

  return `<svg class="spark" viewBox="0 0 1000 220" preserveAspectRatio="none" role="img" aria-label="Heart rate chart">
    <line x1="0" y1="190" x2="1000" y2="190" stroke="#283242" stroke-width="1" />
    <line x1="0" y1="30" x2="1000" y2="30" stroke="#283242" stroke-width="1" />
    <text x="8" y="24" fill="#9aa4b2" font-size="18">${high} BPM</text>
    <text x="8" y="210" fill="#9aa4b2" font-size="18">${low} BPM</text>
    <polyline points="${pathPoints}" fill="none" stroke="#72d6ff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round" />
  </svg>`;
}

app.get('/health', async (_req, res) => {
  try {
    const [rows] = await pool.query('SELECT 1 AS ok');
    return res.json({ status: 'ok', db: rows[0]?.ok === 1 ? 'connected' : 'unknown' });
  } catch (error) {
    return res.status(500).json({ status: 'error', message: error.message });
  }
});

app.get('/admin', requireAdmin, async (req, res) => {
  const q = cleanString(req.query.q);
  const from = cleanString(req.query.from);
  const to = cleanString(req.query.to);
  const video = cleanString(req.query.video);

  const sessionWhere = [];
  const sessionParams = [];
  if (q) {
    const like = `%${q}%`;
    sessionWhere.push('(u.email LIKE ? OR u.display_name LIKE ? OR ws.session_uuid LIKE ?)');
    sessionParams.push(like, like, like);
  }
  if (from) {
    sessionWhere.push('ws.started_at >= ?');
    sessionParams.push(`${from} 00:00:00`);
  }
  if (to) {
    sessionWhere.push('ws.started_at <= ?');
    sessionParams.push(`${to} 23:59:59`);
  }
  if (video === 'yes') {
    sessionWhere.push("ws.video_url IS NOT NULL AND ws.video_url <> ''");
  } else if (video === 'no') {
    sessionWhere.push("(ws.video_url IS NULL OR ws.video_url = '')");
  }

  const sessionWhereSQL = sessionWhere.length ? `WHERE ${sessionWhere.join(' AND ')}` : '';

  const userWhere = [];
  const userParams = [];
  if (q) {
    const like = `%${q}%`;
    userWhere.push('(u.email LIKE ? OR u.display_name LIKE ?)');
    userParams.push(like, like);
  }
  const userWhereSQL = userWhere.length ? `WHERE ${userWhere.join(' AND ')}` : '';

  try {
    const [
      [userCountRows],
      [sessionCountRows],
      [sampleCountRows],
      [pvtCountRows],
      [users],
      [recentSessions],
      [filteredSessionCountRows]
    ] = await Promise.all([
      pool.query('SELECT COUNT(*) AS count FROM users'),
      pool.query('SELECT COUNT(*) AS count FROM workout_sessions'),
      pool.query('SELECT COUNT(*) AS count FROM heart_rate_samples'),
      pool.query('SELECT COUNT(*) AS count FROM pvt_results'),
      pool.execute(
        `SELECT u.id, u.email, u.display_name, u.age, u.weight_lb, u.height_cm, u.gender, u.created_at, u.last_seen_at,
                COUNT(ws.id) AS session_count, MAX(ws.started_at) AS latest_session_at,
                MAX(ws.max_bpm) AS max_bpm, ROUND(AVG(ws.avg_bpm), 1) AS avg_bpm
         FROM users u
         LEFT JOIN workout_sessions ws ON ws.user_id = u.id
         ${userWhereSQL}
         GROUP BY u.id
         ORDER BY COALESCE(u.last_seen_at, u.created_at) DESC
         LIMIT 200`,
        userParams
      ),
      pool.execute(
        `SELECT ws.id, ws.session_uuid, ws.started_at, ws.duration_seconds, ws.min_bpm, ws.avg_bpm, ws.max_bpm, ws.video_url,
                u.display_name, u.email,
                (SELECT COUNT(*) FROM heart_rate_samples hrs WHERE hrs.workout_session_id = ws.id) AS sample_count
         FROM workout_sessions ws
         LEFT JOIN users u ON u.id = ws.user_id
         ${sessionWhereSQL}
         ORDER BY ws.started_at DESC
         LIMIT 100`,
        sessionParams
      ),
      pool.execute(
        `SELECT COUNT(*) AS count
         FROM workout_sessions ws
         LEFT JOIN users u ON u.id = ws.user_id
         ${sessionWhereSQL}`,
        sessionParams
      )
    ]);

    const cards = [
      ['Users', userCountRows[0].count],
      ['Sessions', sessionCountRows[0].count],
      ['Filtered Sessions', filteredSessionCountRows[0].count],
      ['HR Samples', sampleCountRows[0].count],
      ['PVT Results', pvtCountRows[0].count]
    ].map(([label, value]) => `<div class="card"><div class="eyebrow">${label}</div><div class="metric">${formatNumber(value)}</div></div>`).join('');

    const videoOption = (value, label) => `<option value="${value}"${video === value ? ' selected' : ''}>${label}</option>`;
    const filterForm = `
      <section class="card">
        <h2>Find Data</h2>
        <form class="filters" method="get" action="/admin">
          <label>Search
            <input name="q" placeholder="name, email, session UUID" value="${escapeHTML(q || '')}">
          </label>
          <label>From
            <input type="date" name="from" value="${escapeHTML(from || '')}">
          </label>
          <label>To
            <input type="date" name="to" value="${escapeHTML(to || '')}">
          </label>
          <label>Video
            <select name="video">
              ${videoOption('', 'Any')}
              ${videoOption('yes', 'Video only')}
              ${videoOption('no', 'No video')}
            </select>
          </label>
          <div>
            <button type="submit">Filter</button>
            <a class="pill" style="margin-top:8px; justify-content:center; width:100%;" href="/admin">Clear</a>
          </div>
        </form>
      </section>`;

    const userRows = users.map((user) => `
      <tr>
        <td><a href="/admin/users/${user.id}">${escapeHTML(user.display_name || user.email || `User ${user.id}`)}</a><br><span class="muted">${escapeHTML(user.email)}</span></td>
        <td>${user.age || '-'} / ${escapeHTML(user.gender || '-')}<br><span class="muted">${formatNumber(user.weight_lb, ' lb')} · ${formatHeight(user.height_cm)}</span></td>
        <td>${formatNumber(user.session_count)}</td>
        <td>${formatNumber(user.avg_bpm)} / ${formatNumber(user.max_bpm)}</td>
        <td>${formatDate(user.latest_session_at)}</td>
        <td>${formatDate(user.last_seen_at)}</td>
      </tr>`).join('');

    const sessionRows = recentSessions.map((session) => `
      <tr>
        <td><a href="/admin/sessions/${session.id}">Session #${session.id}</a><br><span class="muted">${escapeHTML(session.session_uuid)}</span></td>
        <td>${escapeHTML(session.display_name || session.email || 'Unknown')}</td>
        <td>${formatDate(session.started_at)}</td>
        <td>${formatDuration(session.duration_seconds)}</td>
        <td>${formatNumber(session.min_bpm)} / ${formatNumber(session.avg_bpm)} / ${formatNumber(session.max_bpm)}</td>
        <td>${formatNumber(session.sample_count)}</td>
        <td>${session.video_url ? '<span class="pill">video</span>' : '<span class="muted">no video</span>'}</td>
      </tr>`).join('');

    return res.type('html').send(renderPage('Dashboard', `
      <div class="top"><div><div class="eyebrow">Ticker Flip Local Database</div><h1>Admin Dashboard</h1></div><a class="pill" href="/health">Health check</a></div>
      <div class="grid">${cards}</div>
      <div class="stack">
        ${filterForm}
        <section class="card"><h2>Users</h2><table><thead><tr><th>User</th><th>Profile</th><th>Sessions</th><th>Avg / Max BPM</th><th>Latest Session</th><th>Last Seen</th></tr></thead><tbody>${userRows || '<tr><td colspan="6" class="muted">No matching users yet.</td></tr>'}</tbody></table></section>
        <section class="card"><h2>Sessions</h2><table><thead><tr><th>Session</th><th>User</th><th>Date</th><th>Duration</th><th>Min / Avg / Max</th><th>Samples</th><th>Video</th></tr></thead><tbody>${sessionRows || '<tr><td colspan="7" class="muted">No matching sessions.</td></tr>'}</tbody></table></section>
      </div>
    `));
  } catch (error) {
    return res.status(500).type('html').send(renderPage('Dashboard Error', `<h1>Dashboard error</h1><p class="danger">${escapeHTML(error.message)}</p><p>Run <code>npm run setup-db</code>, then restart the API.</p>`));
  }
});

app.get('/admin/users/:id', requireAdmin, async (req, res) => {
  const userId = Number(req.params.id);
  if (!userId) return res.status(400).send('Invalid user id');

  try {
    const [[userRows], [sessions]] = await Promise.all([
      pool.execute('SELECT * FROM users WHERE id = ?', [userId]),
      pool.execute(
        `SELECT ws.*, (SELECT COUNT(*) FROM heart_rate_samples hrs WHERE hrs.workout_session_id = ws.id) AS sample_count
         FROM workout_sessions ws
         WHERE ws.user_id = ?
         ORDER BY ws.started_at DESC`,
        [userId]
      )
    ]);

    if (!userRows.length) return res.status(404).send('User not found');
    const user = userRows[0];
    const rows = sessions.map((session) => `
      <tr>
        <td><a href="/admin/sessions/${session.id}">#${session.id}</a><br><span class="muted">${escapeHTML(session.session_uuid)}</span></td>
        <td>${formatDate(session.started_at)}</td>
        <td>${formatDuration(session.duration_seconds)}</td>
        <td>${formatNumber(session.min_bpm)} / ${formatNumber(session.avg_bpm)} / ${formatNumber(session.max_bpm)}</td>
        <td>${formatNumber(session.sample_count)}</td>
        <td>${session.video_url ? `<a href="${escapeHTML(session.video_url)}">video</a>` : '-'}</td>
      </tr>`).join('');

    return res.type('html').send(renderPage(`User ${userId}`, `
      <div class="top"><div><div class="eyebrow"><a href="/admin">Admin</a> / User</div><h1>${escapeHTML(user.display_name || user.email || `User ${user.id}`)}</h1></div></div>
      <div class="two">
        <section class="card"><h2>Identity</h2><p><b>Email:</b> ${escapeHTML(user.email)}</p><p><b>Firebase UID:</b> ${escapeHTML(user.firebase_uid || '-')}</p><p><b>Last seen:</b> ${formatDate(user.last_seen_at)}</p></section>
        <section class="card"><h2>Profile</h2><p><b>Age:</b> ${user.age || '-'}</p><p><b>Weight:</b> ${formatNumber(user.weight_lb, ' lb')}</p><p><b>Height:</b> ${formatHeight(user.height_cm)}</p><p><b>Gender:</b> ${escapeHTML(user.gender || '-')}</p></section>
      </div>
      <section class="card" style="margin-top:16px"><h2>Sessions</h2><table><thead><tr><th>Session</th><th>Date</th><th>Duration</th><th>Min / Avg / Max</th><th>Samples</th><th>Video</th></tr></thead><tbody>${rows || '<tr><td colspan="6" class="muted">No sessions for this user yet.</td></tr>'}</tbody></table></section>
    `));
  } catch (error) {
    return res.status(500).send(error.message);
  }
});

app.get('/admin/sessions/:id', requireAdmin, async (req, res) => {
  const sessionId = Number(req.params.id);
  if (!sessionId) return res.status(400).send('Invalid session id');

  try {
    const [[sessionRows], [samples], [pvtResults]] = await Promise.all([
      pool.execute(
        `SELECT ws.*, u.email, u.display_name
         FROM workout_sessions ws
         LEFT JOIN users u ON u.id = ws.user_id
         WHERE ws.id = ?`,
        [sessionId]
      ),
      pool.execute(
        `SELECT t_seconds, bpm
         FROM heart_rate_samples
         WHERE workout_session_id = ?
         ORDER BY t_seconds ASC`,
        [sessionId]
      ),
      pool.execute(
        `SELECT id, phase, duration_seconds, total_stimuli, correct_taps, incorrect_taps, false_starts,
                misses, lapses, mean_reaction_ms, median_reaction_ms, fastest_reaction_ms, slowest_reaction_ms, created_at
         FROM pvt_results
         WHERE workout_session_id = ?
         ORDER BY FIELD(phase, 'pre', 'post', 'standalone'), created_at`,
        [sessionId]
      )
    ]);

    if (!sessionRows.length) return res.status(404).send('Session not found');
    const session = sessionRows[0];
    const pvtRows = pvtResults.map((pvt) => `
      <tr><td>${escapeHTML(pvt.phase)}</td><td>${formatDuration(pvt.duration_seconds)}</td><td>${formatNumber(pvt.mean_reaction_ms, ' ms')}</td><td>${formatNumber(pvt.lapses)}</td><td>${formatNumber(pvt.false_starts)}</td><td>${formatDate(pvt.created_at)}</td></tr>
    `).join('');

    return res.type('html').send(renderPage(`Session ${sessionId}`, `
      <div class="top"><div><div class="eyebrow"><a href="/admin">Admin</a> / Session</div><h1>Session #${session.id}</h1></div><span class="pill">${formatNumber(samples.length)} samples</span></div>
      <div class="two">
        <section class="card"><h2>Overview</h2><p><b>User:</b> ${escapeHTML(session.display_name || session.email || 'Unknown')}</p><p><b>Date:</b> ${formatDate(session.started_at)}</p><p><b>Duration:</b> ${formatDuration(session.duration_seconds)}</p><p><b>Video:</b> ${session.video_url ? `<a href="${escapeHTML(session.video_url)}">open uploaded video</a>` : '-'}</p></section>
        <section class="card"><h2>Heart Rate</h2><p><b>Min:</b> ${formatNumber(session.min_bpm)} BPM</p><p><b>Avg:</b> ${formatNumber(session.avg_bpm)} BPM</p><p><b>Max:</b> ${formatNumber(session.max_bpm)} BPM</p></section>
      </div>
      <section class="card" style="margin-top:16px"><h2>Heart Rate Timeline</h2>${renderSparkline(samples)}</section>
      <section class="card" style="margin-top:16px"><h2>PVT Results</h2><table><thead><tr><th>Phase</th><th>Duration</th><th>Mean Reaction</th><th>Lapses</th><th>False Starts</th><th>Created</th></tr></thead><tbody>${pvtRows || '<tr><td colspan="6" class="muted">No linked PVT results.</td></tr>'}</tbody></table></section>
    `));
  } catch (error) {
    return res.status(500).send(error.message);
  }
});

app.use('/api', requireApiKey);

app.post('/api/upload/video', upload.single('video'), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'video file is required' });
  }

  try {
    if (isObjectStorageConfigured()) {
      const uploaded = await uploadFileToObjectStorage(req.file);
      return res.status(201).json({
        videoUrl: uploaded.videoUrl,
        fileName: req.file.filename,
        objectKey: uploaded.objectKey,
        storage: 'object'
      });
    }

    const publicBaseURL = process.env.PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
    const videoUrl = `${publicBaseURL}/uploads/${req.file.filename}`;
    return res.status(201).json({ videoUrl, fileName: req.file.filename, storage: 'local' });
  } catch (error) {
    fs.promises.unlink(req.file.path).catch(() => {});
    return routeError(res, error);
  }
});

app.post('/api/users/register', async (req, res) => {
  try {
    const user = await resolveUser(pool, req.body);
    return res.status(201).json({ message: 'User upserted', userId: user.id, email: user.email, displayName: user.displayName });
  } catch (error) {
    return routeError(res, error);
  }
});

app.post('/api/users/resolve', async (req, res) => {
  try {
    const user = await resolveUser(pool, req.body);
    return res.status(200).json({ userId: user.id, email: user.email, displayName: user.displayName });
  } catch (error) {
    return routeError(res, error);
  }
});

app.post('/api/sessions', async (req, res) => {
  const {
    sessionUuid,
    title,
    note,
    startedAt,
    endedAt,
    durationSeconds,
    minBpm,
    avgBpm,
    maxBpm,
    videoUrl
  } = req.body;

  if (!sessionUuid || !startedAt || durationSeconds == null) {
    return res.status(400).json({ error: 'sessionUuid, startedAt, and durationSeconds are required' });
  }

  try {
    const user = await resolveUser(pool, req.body);
    const [result] = await pool.execute(
      `INSERT INTO workout_sessions
       (user_id, session_uuid, title, note, started_at, ended_at, duration_seconds, min_bpm, avg_bpm, max_bpm, video_url)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
         user_id = VALUES(user_id),
         title = VALUES(title),
         note = VALUES(note),
         ended_at = VALUES(ended_at),
         duration_seconds = VALUES(duration_seconds),
         min_bpm = VALUES(min_bpm),
         avg_bpm = VALUES(avg_bpm),
         max_bpm = VALUES(max_bpm),
         video_url = VALUES(video_url),
         updated_at = CURRENT_TIMESTAMP`,
      [
        user.id,
        sessionUuid,
        title || null,
        note || null,
        mysqlDate(startedAt),
        mysqlDate(endedAt),
        durationSeconds,
        minBpm ?? null,
        avgBpm ?? null,
        maxBpm ?? null,
        videoUrl || null
      ]
    );

    let sessionId = result.insertId;
    if (!sessionId) {
      const [rows] = await pool.execute('SELECT id FROM workout_sessions WHERE session_uuid = ?', [sessionUuid]);
      sessionId = rows[0]?.id;
    }

    return res.status(201).json({ sessionId, sessionUuid, userId: user.id });
  } catch (error) {
    return routeError(res, error);
  }
});

app.post('/api/sessions/:sessionId/heart-rate', async (req, res) => {
  const sessionId = Number(req.params.sessionId);
  const { samples } = req.body;

  if (!sessionId || !Array.isArray(samples)) {
    return res.status(400).json({ error: 'sessionId and samples[] are required' });
  }

  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    await connection.execute('DELETE FROM heart_rate_samples WHERE workout_session_id = ?', [sessionId]);

    if (samples.length > 0) {
      const values = samples.map((s) => [sessionId, s.tSeconds, s.bpm]);
      await connection.query('INSERT INTO heart_rate_samples (workout_session_id, t_seconds, bpm) VALUES ?', [values]);
    }

    await connection.commit();
    return res.status(201).json({ message: 'Heart rate samples saved', count: samples.length });
  } catch (error) {
    await connection.rollback();
    return routeError(res, error);
  } finally {
    connection.release();
  }
});

app.post('/api/pvt-results', async (req, res) => {
  const {
    workoutSessionId,
    phase,
    durationSeconds,
    totalStimuli,
    correctTaps,
    incorrectTaps,
    falseStarts,
    misses,
    lapses,
    meanReactionMs,
    medianReactionMs,
    fastestReactionMs,
    slowestReactionMs,
    trialPoints
  } = req.body;

  if (!durationSeconds) {
    return res.status(400).json({ error: 'durationSeconds is required' });
  }

  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    const user = await resolveUser(connection, req.body);

    const [insert] = await connection.execute(
      `INSERT INTO pvt_results
       (user_id, workout_session_id, phase, duration_seconds, total_stimuli, correct_taps, incorrect_taps,
        false_starts, misses, lapses, mean_reaction_ms, median_reaction_ms, fastest_reaction_ms, slowest_reaction_ms)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        user.id,
        workoutSessionId || null,
        phase || 'standalone',
        durationSeconds,
        totalStimuli || 0,
        correctTaps || 0,
        incorrectTaps || 0,
        falseStarts || 0,
        misses || 0,
        lapses || 0,
        meanReactionMs || 0,
        medianReactionMs || 0,
        fastestReactionMs || 0,
        slowestReactionMs || 0
      ]
    );

    const pvtResultId = insert.insertId;
    if (Array.isArray(trialPoints) && trialPoints.length > 0) {
      const values = trialPoints.map((p, idx) => [pvtResultId, p.trialIndex || idx + 1, p.reactionMs]);
      await connection.query('INSERT INTO pvt_trial_points (pvt_result_id, trial_index, reaction_ms) VALUES ?', [values]);
    }

    await connection.commit();
    return res.status(201).json({ pvtResultId, userId: user.id });
  } catch (error) {
    await connection.rollback();
    return routeError(res, error);
  } finally {
    connection.release();
  }
});

app.post('/api/sessions/full', async (req, res) => {
  const { session, heartRateSamples, prePvt, postPvt } = req.body;

  if (!session?.sessionUuid || !session?.startedAt || session?.durationSeconds == null) {
    return res.status(400).json({ error: 'session.sessionUuid, session.startedAt, and session.durationSeconds are required' });
  }

  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    const user = await resolveUser(connection, session);

    const [sessionInsert] = await connection.execute(
      `INSERT INTO workout_sessions
       (user_id, session_uuid, title, note, started_at, ended_at, duration_seconds, min_bpm, avg_bpm, max_bpm, video_url)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
         user_id = VALUES(user_id),
         title = VALUES(title),
         note = VALUES(note),
         ended_at = VALUES(ended_at),
         duration_seconds = VALUES(duration_seconds),
         min_bpm = VALUES(min_bpm),
         avg_bpm = VALUES(avg_bpm),
         max_bpm = VALUES(max_bpm),
         video_url = VALUES(video_url),
         updated_at = CURRENT_TIMESTAMP`,
      [
        user.id,
        session.sessionUuid,
        session.title || null,
        session.note || null,
        mysqlDate(session.startedAt),
        mysqlDate(session.endedAt),
        session.durationSeconds,
        session.minBpm ?? null,
        session.avgBpm ?? null,
        session.maxBpm ?? null,
        session.videoUrl || null
      ]
    );

    let workoutSessionId = sessionInsert.insertId;
    if (!workoutSessionId) {
      const [rows] = await connection.execute('SELECT id FROM workout_sessions WHERE session_uuid = ?', [session.sessionUuid]);
      workoutSessionId = rows[0]?.id;
    }

    await connection.execute('DELETE FROM heart_rate_samples WHERE workout_session_id = ?', [workoutSessionId]);
    if (Array.isArray(heartRateSamples) && heartRateSamples.length > 0) {
      const hrValues = heartRateSamples.map((s) => [workoutSessionId, s.tSeconds, s.bpm]);
      await connection.query('INSERT INTO heart_rate_samples (workout_session_id, t_seconds, bpm) VALUES ?', [hrValues]);
    }

    await connection.execute('DELETE FROM pvt_results WHERE workout_session_id = ?', [workoutSessionId]);
    for (const pvt of [prePvt, postPvt]) {
      if (!pvt) continue;
      const [pvtInsert] = await connection.execute(
        `INSERT INTO pvt_results
         (user_id, workout_session_id, phase, duration_seconds, total_stimuli, correct_taps, incorrect_taps,
          false_starts, misses, lapses, mean_reaction_ms, median_reaction_ms, fastest_reaction_ms, slowest_reaction_ms)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          user.id,
          workoutSessionId,
          pvt.phase,
          pvt.durationSeconds,
          pvt.totalStimuli || 0,
          pvt.correctTaps || 0,
          pvt.incorrectTaps || 0,
          pvt.falseStarts || 0,
          pvt.misses || 0,
          pvt.lapses || 0,
          pvt.meanReactionMs || 0,
          pvt.medianReactionMs || 0,
          pvt.fastestReactionMs || 0,
          pvt.slowestReactionMs || 0
        ]
      );

      if (Array.isArray(pvt.trialPoints) && pvt.trialPoints.length > 0) {
        const trialValues = pvt.trialPoints.map((tp, idx) => [pvtInsert.insertId, tp.trialIndex || idx + 1, tp.reactionMs]);
        await connection.query('INSERT INTO pvt_trial_points (pvt_result_id, trial_index, reaction_ms) VALUES ?', [trialValues]);
      }
    }

    await connection.commit();
    return res.status(201).json({
      workoutSessionId,
      userId: user.id,
      heartRateSampleCount: Array.isArray(heartRateSamples) ? heartRateSamples.length : 0
    });
  } catch (error) {
    await connection.rollback();
    return routeError(res, error);
  } finally {
    connection.release();
  }
});

app.get('/api/sessions', async (req, res) => {
  const identity = userIdentityFrom(req.query);
  if (!identity.userId && !identity.email && !identity.firebaseUid) {
    return res.status(400).json({ error: 'userId, userEmail, or firebaseUid query param is required' });
  }

  try {
    const userId = await findUserId(pool, identity);
    if (!userId) return res.json([]);

    const [rows] = await pool.execute(
      `SELECT id, session_uuid, title, note, started_at, ended_at, duration_seconds,
              min_bpm, avg_bpm, max_bpm, video_url, created_at, updated_at
       FROM workout_sessions
       WHERE user_id = ?
       ORDER BY started_at DESC`,
      [userId]
    );
    return res.json(rows);
  } catch (error) {
    return routeError(res, error);
  }
});

app.get('/api/sessions/:sessionId', async (req, res) => {
  const sessionId = Number(req.params.sessionId);
  if (!sessionId) return res.status(400).json({ error: 'Invalid sessionId' });

  try {
    const [rows] = await pool.execute(
      `SELECT id, user_id, session_uuid, title, note, started_at, ended_at, duration_seconds,
              min_bpm, avg_bpm, max_bpm, video_url, created_at, updated_at
       FROM workout_sessions
       WHERE id = ?`,
      [sessionId]
    );
    if (!rows.length) return res.status(404).json({ error: 'Session not found' });
    return res.json(rows[0]);
  } catch (error) {
    return routeError(res, error);
  }
});

app.get('/api/sessions/:sessionId/heart-rate', async (req, res) => {
  const sessionId = Number(req.params.sessionId);
  if (!sessionId) return res.status(400).json({ error: 'Invalid sessionId' });

  try {
    const [rows] = await pool.execute(
      `SELECT t_seconds, bpm
       FROM heart_rate_samples
       WHERE workout_session_id = ?
       ORDER BY t_seconds ASC`,
      [sessionId]
    );
    return res.json(rows);
  } catch (error) {
    return routeError(res, error);
  }
});

app.get('/api/sessions/:sessionId/pvt-comparison', async (req, res) => {
  const sessionId = Number(req.params.sessionId);
  if (!sessionId) return res.status(400).json({ error: 'Invalid sessionId' });

  try {
    const [results] = await pool.execute(
      `SELECT id, phase, duration_seconds, total_stimuli, correct_taps, incorrect_taps,
              false_starts, misses, lapses, mean_reaction_ms, median_reaction_ms,
              fastest_reaction_ms, slowest_reaction_ms, created_at
       FROM pvt_results
       WHERE workout_session_id = ? AND phase IN ('pre','post')
       ORDER BY FIELD(phase, 'pre', 'post')`,
      [sessionId]
    );

    if (!results.length) {
      return res.json({ pre: null, post: null });
    }

    const ids = results.map((r) => r.id);
    const [trials] = await pool.query(
      `SELECT pvt_result_id, trial_index, reaction_ms
       FROM pvt_trial_points
       WHERE pvt_result_id IN (?)
       ORDER BY trial_index ASC`,
      [ids]
    );

    const map = new Map();
    for (const result of results) {
      map.set(result.id, { ...result, trial_points: [] });
    }
    for (const trial of trials) {
      map.get(trial.pvt_result_id)?.trial_points.push(trial);
    }

    const pre = results.find((r) => r.phase === 'pre');
    const post = results.find((r) => r.phase === 'post');

    return res.json({
      pre: pre ? map.get(pre.id) : null,
      post: post ? map.get(post.id) : null
    });
  } catch (error) {
    return routeError(res, error);
  }
});

const port = Number(process.env.PORT || 3000);
app.listen(port, () => {
  console.log(`Ticker Flip API running on http://localhost:${port}`);
  console.log(`Admin dashboard: http://localhost:${port}/admin`);
});
