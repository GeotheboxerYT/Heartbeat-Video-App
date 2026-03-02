require('dotenv').config();

const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const multer = require('multer');
const { pool } = require('./db');

const app = express();

app.use(helmet());
app.use(cors());
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
  limits: { fileSize: 1024 * 1024 * 1024 } // 1 GB
});

app.use('/uploads', express.static(uploadsDir));

function requireApiKey(req, res, next) {
  const configuredKey = process.env.API_KEY;
  if (!configuredKey) return next();

  const requestKey = req.header('x-api-key');
  if (requestKey !== configuredKey) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  return next();
}

app.use('/api', requireApiKey);

app.post('/api/upload/video', upload.single('video'), (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'video file is required' });
  }

  const publicBaseURL = process.env.PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
  const videoUrl = `${publicBaseURL}/uploads/${req.file.filename}`;
  return res.status(201).json({ videoUrl, fileName: req.file.filename });
});

app.get('/health', async (_req, res) => {
  try {
    const [rows] = await pool.query('SELECT 1 AS ok');
    return res.json({ status: 'ok', db: rows[0]?.ok === 1 ? 'connected' : 'unknown' });
  } catch (error) {
    return res.status(500).json({ status: 'error', message: error.message });
  }
});

app.post('/api/users/register', async (req, res) => {
  const { email, passwordHash, displayName } = req.body;
  if (!email || !passwordHash) {
    return res.status(400).json({ error: 'email and passwordHash are required' });
  }

  try {
    const [result] = await pool.execute(
      `INSERT INTO users (email, password_hash, display_name)
       VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE display_name = VALUES(display_name)`,
      [email, passwordHash, displayName || null]
    );

    return res.status(201).json({
      message: 'User upserted',
      userId: result.insertId || null
    });
  } catch (error) {
    return res.status(500).json({ error: error.message });
  }
});

app.post('/api/sessions', async (req, res) => {
  const {
    userId,
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

  if (!userId || !sessionUuid || startedAt == null || durationSeconds == null) {
    return res.status(400).json({
      error: 'userId, sessionUuid, startedAt, and durationSeconds are required'
    });
  }

  try {
    const [result] = await pool.execute(
      `INSERT INTO workout_sessions
       (user_id, session_uuid, title, note, started_at, ended_at, duration_seconds, min_bpm, avg_bpm, max_bpm, video_url)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
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
        userId,
        sessionUuid,
        title || null,
        note || null,
        startedAt,
        endedAt || null,
        durationSeconds,
        minBpm ?? null,
        avgBpm ?? null,
        maxBpm ?? null,
        videoUrl || null
      ]
    );

    let sessionId = result.insertId;
    if (!sessionId) {
      const [rows] = await pool.execute(
        'SELECT id FROM workout_sessions WHERE session_uuid = ?',
        [sessionUuid]
      );
      sessionId = rows[0]?.id;
    }

    return res.status(201).json({ sessionId, sessionUuid });
  } catch (error) {
    return res.status(500).json({ error: error.message });
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
      await connection.query(
        `INSERT INTO heart_rate_samples (workout_session_id, t_seconds, bpm)
         VALUES ?`,
        [values]
      );
    }

    await connection.commit();
    return res.status(201).json({ message: 'Heart rate samples saved', count: samples.length });
  } catch (error) {
    await connection.rollback();
    return res.status(500).json({ error: error.message });
  } finally {
    connection.release();
  }
});

app.post('/api/pvt-results', async (req, res) => {
  const {
    userId,
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

  if (!userId || !durationSeconds) {
    return res.status(400).json({ error: 'userId and durationSeconds are required' });
  }

  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [insert] = await connection.execute(
      `INSERT INTO pvt_results
       (user_id, workout_session_id, phase, duration_seconds, total_stimuli, correct_taps, incorrect_taps,
        false_starts, misses, lapses, mean_reaction_ms, median_reaction_ms, fastest_reaction_ms, slowest_reaction_ms)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        userId,
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
      const values = trialPoints.map((p, idx) => [
        pvtResultId,
        p.trialIndex || idx + 1,
        p.reactionMs
      ]);
      await connection.query(
        `INSERT INTO pvt_trial_points (pvt_result_id, trial_index, reaction_ms)
         VALUES ?`,
        [values]
      );
    }

    await connection.commit();
    return res.status(201).json({ pvtResultId });
  } catch (error) {
    await connection.rollback();
    return res.status(500).json({ error: error.message });
  } finally {
    connection.release();
  }
});

app.post('/api/sessions/full', async (req, res) => {
  const {
    session,
    heartRateSamples,
    prePvt,
    postPvt
  } = req.body;

  if (!session?.userId || !session?.sessionUuid || !session?.startedAt || session?.durationSeconds == null) {
    return res.status(400).json({ error: 'session.userId, session.sessionUuid, session.startedAt, session.durationSeconds are required' });
  }

  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [sessionInsert] = await connection.execute(
      `INSERT INTO workout_sessions
       (user_id, session_uuid, title, note, started_at, ended_at, duration_seconds, min_bpm, avg_bpm, max_bpm, video_url)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
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
        session.userId,
        session.sessionUuid,
        session.title || null,
        session.note || null,
        session.startedAt,
        session.endedAt || null,
        session.durationSeconds,
        session.minBpm ?? null,
        session.avgBpm ?? null,
        session.maxBpm ?? null,
        session.videoUrl || null
      ]
    );

    let workoutSessionId = sessionInsert.insertId;
    if (!workoutSessionId) {
      const [rows] = await connection.execute(
        'SELECT id FROM workout_sessions WHERE session_uuid = ?',
        [session.sessionUuid]
      );
      workoutSessionId = rows[0]?.id;
    }

    await connection.execute('DELETE FROM heart_rate_samples WHERE workout_session_id = ?', [workoutSessionId]);

    if (Array.isArray(heartRateSamples) && heartRateSamples.length > 0) {
      const hrValues = heartRateSamples.map((s) => [workoutSessionId, s.tSeconds, s.bpm]);
      await connection.query(
        `INSERT INTO heart_rate_samples (workout_session_id, t_seconds, bpm)
         VALUES ?`,
        [hrValues]
      );
    }

    for (const pvt of [prePvt, postPvt]) {
      if (!pvt) continue;
      const [pvtInsert] = await connection.execute(
        `INSERT INTO pvt_results
         (user_id, workout_session_id, phase, duration_seconds, total_stimuli, correct_taps, incorrect_taps,
          false_starts, misses, lapses, mean_reaction_ms, median_reaction_ms, fastest_reaction_ms, slowest_reaction_ms)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          session.userId,
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
        const trialValues = pvt.trialPoints.map((tp, idx) => [
          pvtInsert.insertId,
          tp.trialIndex || idx + 1,
          tp.reactionMs
        ]);
        await connection.query(
          `INSERT INTO pvt_trial_points (pvt_result_id, trial_index, reaction_ms)
           VALUES ?`,
          [trialValues]
        );
      }
    }

    await connection.commit();
    return res.status(201).json({
      workoutSessionId,
      heartRateSampleCount: Array.isArray(heartRateSamples) ? heartRateSamples.length : 0
    });
  } catch (error) {
    await connection.rollback();
    return res.status(500).json({ error: error.message });
  } finally {
    connection.release();
  }
});

app.get('/api/sessions', async (req, res) => {
  const userId = Number(req.query.userId);
  if (!userId) return res.status(400).json({ error: 'userId query param is required' });

  try {
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
    return res.status(500).json({ error: error.message });
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
    return res.status(500).json({ error: error.message });
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
    return res.status(500).json({ error: error.message });
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
    return res.status(500).json({ error: error.message });
  }
});

const port = Number(process.env.PORT || 3000);
app.listen(port, () => {
  console.log(`Pulse Point API running on http://localhost:${port}`);
});
