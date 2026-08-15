-- LEGACY MYSQL 8 ONLY. Add optimistic concurrency control to the singleton site configuration.
-- Existing rows start at version 0. This migration is safe to run repeatedly
-- on MySQL 8 and does not rewrite any configured values.

SET @has_site_config_version := (
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'site_config'
      AND COLUMN_NAME = 'version'
);
SET @sql := IF(
    @has_site_config_version = 0,
    'ALTER TABLE site_config ADD COLUMN version INT NOT NULL DEFAULT 0 AFTER message_text',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;
