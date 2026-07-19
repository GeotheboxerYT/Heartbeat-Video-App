require('dotenv').config();

const mysql = require('mysql2/promise');

const databaseName = process.env.DB_NAME;
const required = ['DB_HOST', 'DB_USER', 'DB_NAME'];
const missing = required.filter((key) => !process.env[key]);
if (missing.length) {
  console.error(`Missing required .env values: ${missing.join(', ')}`);
  process.exit(1);
}

const baseConfig = {
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD || '',
  ssl: sslConfig(),
  multipleStatements: false
};

function sslConfig() {
  const enabled = String(process.env.DB_SSL || '').toLowerCase();
  if (!['1', 'true', 'yes', 'required'].includes(enabled)) return undefined;
  return { minVersion: 'TLSv1.2' };
}

function quoteIdentifier(identifier) {
  return `\`${String(identifier).replaceAll('`', '``')}\``;
}

async function databaseExists(connection) {
  const [rows] = await connection.execute(
    'SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = ?',
    [databaseName]
  );
  return rows.length > 0;
}

async function columnExists(connection, table, column) {
  const [rows] = await connection.execute(
    `SELECT COUNT(*) AS count
     FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?`,
    [databaseName, table, column]
  );
  return Number(rows[0]?.count || 0) > 0;
}

async function indexExists(connection, table, indexName) {
  const [rows] = await connection.execute(
    `SELECT COUNT(*) AS count
     FROM INFORMATION_SCHEMA.STATISTICS
     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND INDEX_NAME = ?`,
    [databaseName, table, indexName]
  );
  return Number(rows[0]?.count || 0) > 0;
}

async function addColumnIfMissing(connection, table, column, definition) {
  if (await columnExists(connection, table, column)) return;
  await connection.query(`ALTER TABLE ${quoteIdentifier(table)} ADD COLUMN ${quoteIdentifier(column)} ${definition}`);
  console.log(`Added ${table}.${column}`);
}

async function addIndexIfMissing(connection, table, indexName, ddl) {
  if (await indexExists(connection, table, indexName)) return;
  await connection.query(ddl);
  console.log(`Added index ${indexName}`);
}

async function relaxPasswordHash(connection) {
  if (!(await columnExists(connection, 'users', 'password_hash'))) return;
  const [rows] = await connection.execute(
    `SELECT IS_NULLABLE
     FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = 'users' AND COLUMN_NAME = 'password_hash'`,
    [databaseName]
  );
  if (rows[0]?.IS_NULLABLE === 'YES') return;
  await connection.query('ALTER TABLE users MODIFY COLUMN password_hash VARCHAR(255) NULL');
  console.log('Made users.password_hash nullable');
}

async function relaxLegacyUsername(connection) {
  if (!(await columnExists(connection, 'users', 'username'))) return;
  const [rows] = await connection.execute(
    `SELECT IS_NULLABLE
     FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = 'users' AND COLUMN_NAME = 'username'`,
    [databaseName]
  );
  if (rows[0]?.IS_NULLABLE === 'YES') return;
  await connection.query('ALTER TABLE users MODIFY COLUMN username VARCHAR(50) NULL');
  console.log('Made legacy users.username nullable');
}

async function ensureDatabase() {
  const connection = await mysql.createConnection(baseConfig);
  try {
    try {
      await connection.query(`CREATE DATABASE IF NOT EXISTS ${quoteIdentifier(databaseName)} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`);
      console.log(`Database ready: ${databaseName}`);
    } catch (error) {
      if (!(await databaseExists(connection))) throw error;
      console.log(`Database exists, skipping CREATE DATABASE because this user does not have global CREATE permission: ${databaseName}`);
    }
  } finally {
    await connection.end();
  }
}

async function main() {
  await ensureDatabase();

  const connection = await mysql.createConnection({ ...baseConfig, database: databaseName });
  try {
    await connection.query(`
      CREATE TABLE IF NOT EXISTS users (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        firebase_uid VARCHAR(128) NULL,
        email VARCHAR(255) NOT NULL,
        password_hash VARCHAR(255) NULL,
        display_name VARCHAR(120) NULL,
        age INT UNSIGNED NULL,
        weight_lb DECIMAL(6,2) NULL,
        height_cm DECIMAL(6,2) NULL,
        gender VARCHAR(40) NULL,
        terms_accepted_at DATETIME NULL,
        last_seen_at DATETIME NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (id),
        UNIQUE KEY ux_users_email (email),
        UNIQUE KEY ux_users_firebase_uid (firebase_uid)
      ) ENGINE=InnoDB
    `);

    await relaxPasswordHash(connection);
    await relaxLegacyUsername(connection);
    await addColumnIfMissing(connection, 'users', 'firebase_uid', 'VARCHAR(128) NULL');
    await addColumnIfMissing(connection, 'users', 'display_name', 'VARCHAR(120) NULL');
    await addColumnIfMissing(connection, 'users', 'age', 'INT UNSIGNED NULL');
    await addColumnIfMissing(connection, 'users', 'weight_lb', 'DECIMAL(6,2) NULL');
    await addColumnIfMissing(connection, 'users', 'height_cm', 'DECIMAL(6,2) NULL');
    await addColumnIfMissing(connection, 'users', 'gender', 'VARCHAR(40) NULL');
    await addColumnIfMissing(connection, 'users', 'terms_accepted_at', 'DATETIME NULL');
    await addColumnIfMissing(connection, 'users', 'last_seen_at', 'DATETIME NULL');
    await addColumnIfMissing(connection, 'users', 'updated_at', 'DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP');
    await addIndexIfMissing(connection, 'users', 'ux_users_email', 'CREATE UNIQUE INDEX ux_users_email ON users (email)');
    await addIndexIfMissing(connection, 'users', 'ux_users_firebase_uid', 'CREATE UNIQUE INDEX ux_users_firebase_uid ON users (firebase_uid)');

    await connection.query(`
      CREATE TABLE IF NOT EXISTS workout_sessions (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        user_id BIGINT UNSIGNED NOT NULL,
        session_uuid CHAR(36) NOT NULL,
        title VARCHAR(140) NULL,
        note TEXT NULL,
        started_at DATETIME NOT NULL,
        ended_at DATETIME NULL,
        duration_seconds DECIMAL(10,3) NOT NULL,
        min_bpm SMALLINT UNSIGNED NULL,
        avg_bpm SMALLINT UNSIGNED NULL,
        max_bpm SMALLINT UNSIGNED NULL,
        video_url TEXT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (id),
        UNIQUE KEY ux_workout_sessions_uuid (session_uuid),
        KEY ix_workout_sessions_user_started (user_id, started_at)
      ) ENGINE=InnoDB
    `);

    await connection.query(`
      CREATE TABLE IF NOT EXISTS heart_rate_samples (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        workout_session_id BIGINT UNSIGNED NOT NULL,
        t_seconds DECIMAL(10,3) NOT NULL,
        bpm SMALLINT UNSIGNED NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id),
        KEY ix_hrs_session_time (workout_session_id, t_seconds)
      ) ENGINE=InnoDB
    `);

    await connection.query(`
      CREATE TABLE IF NOT EXISTS pvt_results (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        user_id BIGINT UNSIGNED NOT NULL,
        workout_session_id BIGINT UNSIGNED NULL,
        phase ENUM('pre','post','standalone') NOT NULL DEFAULT 'standalone',
        duration_seconds INT UNSIGNED NOT NULL,
        total_stimuli INT UNSIGNED NOT NULL DEFAULT 0,
        correct_taps INT UNSIGNED NOT NULL DEFAULT 0,
        incorrect_taps INT UNSIGNED NOT NULL DEFAULT 0,
        false_starts INT UNSIGNED NOT NULL DEFAULT 0,
        misses INT UNSIGNED NOT NULL DEFAULT 0,
        lapses INT UNSIGNED NOT NULL DEFAULT 0,
        mean_reaction_ms INT UNSIGNED NOT NULL DEFAULT 0,
        median_reaction_ms INT UNSIGNED NOT NULL DEFAULT 0,
        fastest_reaction_ms INT UNSIGNED NOT NULL DEFAULT 0,
        slowest_reaction_ms INT UNSIGNED NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id),
        KEY ix_pvt_user_created (user_id, created_at),
        KEY ix_pvt_session_phase (workout_session_id, phase)
      ) ENGINE=InnoDB
    `);

    await connection.query(`
      CREATE TABLE IF NOT EXISTS pvt_trial_points (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        pvt_result_id BIGINT UNSIGNED NOT NULL,
        trial_index INT UNSIGNED NOT NULL,
        reaction_ms INT UNSIGNED NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id),
        KEY ix_pvt_trials_result_trial (pvt_result_id, trial_index)
      ) ENGINE=InnoDB
    `);

    console.log('Ticker Flip local database tables are ready.');
  } finally {
    await connection.end();
  }
}

main().catch((error) => {
  console.error('Database setup failed:');
  console.error(error.message);
  process.exit(1);
});
