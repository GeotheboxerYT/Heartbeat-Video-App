-- Heartbeat Video App schema (MySQL 8+)

CREATE DATABASE IF NOT EXISTS heartbeat_video_app
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE heartbeat_video_app;

-- App users (local auth placeholder; move auth to provider/backend as you scale)
CREATE TABLE IF NOT EXISTS users (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email VARCHAR(255) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  display_name VARCHAR(120) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY ux_users_email (email)
) ENGINE=InnoDB;

-- One row per recorded workout
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
  KEY ix_workout_sessions_user_started (user_id, started_at),
  CONSTRAINT fk_workout_sessions_user
    FOREIGN KEY (user_id) REFERENCES users(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- Heart rate timeline samples for each session
CREATE TABLE IF NOT EXISTS heart_rate_samples (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  workout_session_id BIGINT UNSIGNED NOT NULL,
  t_seconds DECIMAL(10,3) NOT NULL,
  bpm SMALLINT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_hrs_session_time (workout_session_id, t_seconds),
  CONSTRAINT fk_hrs_session
    FOREIGN KEY (workout_session_id) REFERENCES workout_sessions(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- PVT summary results (supports pre/post linked to one workout)
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
  KEY ix_pvt_session_phase (workout_session_id, phase),
  CONSTRAINT fk_pvt_user
    FOREIGN KEY (user_id) REFERENCES users(id)
    ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_pvt_session
    FOREIGN KEY (workout_session_id) REFERENCES workout_sessions(id)
    ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

-- Per-trial reaction points for plotting pre vs post charts
CREATE TABLE IF NOT EXISTS pvt_trial_points (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  pvt_result_id BIGINT UNSIGNED NOT NULL,
  trial_index INT UNSIGNED NOT NULL,
  reaction_ms INT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_pvt_trials_result_trial (pvt_result_id, trial_index),
  CONSTRAINT fk_pvt_trials_result
    FOREIGN KEY (pvt_result_id) REFERENCES pvt_results(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
