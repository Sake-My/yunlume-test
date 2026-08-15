-- LEGACY MYSQL 8 ONLY. Enforce the supported custom-link positions and display-order index.
-- This migration is safe to run repeatedly on MySQL 8. It never rewrites legacy
-- rows: invalid positions are listed first, then adding the CHECK constraint fails
-- explicitly until an administrator corrects those rows.

SELECT id, title, position
FROM custom_link
WHERE position IS NULL
   OR position NOT IN ('header', 'footer')
ORDER BY id;

DROP TEMPORARY TABLE IF EXISTS custom_link_position_migration_assertion;
CREATE TEMPORARY TABLE custom_link_position_migration_assertion (
    invalid_position_count BIGINT NOT NULL,
    CONSTRAINT chk_no_invalid_custom_link_positions CHECK (invalid_position_count = 0)
);
INSERT INTO custom_link_position_migration_assertion (invalid_position_count)
SELECT COUNT(*)
FROM custom_link
WHERE position IS NULL
   OR position NOT IN ('header', 'footer');
DROP TEMPORARY TABLE custom_link_position_migration_assertion;

SET @has_custom_link_position_check := (
    SELECT COUNT(*)
    FROM information_schema.TABLE_CONSTRAINTS
    WHERE CONSTRAINT_SCHEMA = DATABASE()
      AND TABLE_NAME = 'custom_link'
      AND CONSTRAINT_NAME = 'chk_custom_link_position'
      AND CONSTRAINT_TYPE = 'CHECK'
);
SET @sql := IF(
    @has_custom_link_position_check = 0,
    'ALTER TABLE custom_link ADD CONSTRAINT chk_custom_link_position CHECK (position IN (''header'', ''footer''))',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @has_custom_link_position_sort_index := (
    SELECT COUNT(*)
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'custom_link'
      AND INDEX_NAME = 'idx_custom_link_position_sort'
);
SET @sql := IF(
    @has_custom_link_position_sort_index = 0,
    'ALTER TABLE custom_link ADD INDEX idx_custom_link_position_sort (position, sort_order, id)',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;
