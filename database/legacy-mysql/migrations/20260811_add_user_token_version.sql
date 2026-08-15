-- LEGACY MYSQL 8 ONLY. Persist a per-user JWT version so password changes and logout-all can revoke
-- every token issued before the operation. Existing JWTs omit `ver`; version 0
-- deliberately keeps those tokens valid until the first revocation.
-- This migration is safe to run repeatedly on MySQL 8.

SET @has_token_version := (
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'sys_user'
      AND COLUMN_NAME = 'token_version'
);
SET @sql := IF(
    @has_token_version = 0,
    'ALTER TABLE sys_user ADD COLUMN token_version INT NOT NULL DEFAULT 0 AFTER status',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;
