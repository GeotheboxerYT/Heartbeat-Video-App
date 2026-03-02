USE heartbeat_video_app;

-- Example dev user
INSERT INTO users (email, password_hash, display_name)
VALUES ('demo@pulsepoint.app', '$2b$12$replace_with_real_bcrypt_hash', 'Demo User')
ON DUPLICATE KEY UPDATE display_name = VALUES(display_name);
