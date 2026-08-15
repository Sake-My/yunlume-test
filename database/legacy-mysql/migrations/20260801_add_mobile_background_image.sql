-- LEGACY MYSQL 8 ONLY.
SET @mobile_background_column_exists := (
    SELECT COUNT(*)
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'site_config'
      AND column_name = 'mobile_background_image'
);

SET @mobile_background_migration_sql := IF(
    @mobile_background_column_exists = 0,
    'ALTER TABLE site_config ADD COLUMN mobile_background_image VARCHAR(500) NULL AFTER background_image',
    'SELECT 1'
);

PREPARE mobile_background_migration FROM @mobile_background_migration_sql;
EXECUTE mobile_background_migration;
DEALLOCATE PREPARE mobile_background_migration;
