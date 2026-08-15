-- LEGACY MYSQL 8 ONLY. Add visibility control and enforce at most one default search engine.
-- This migration is safe to run repeatedly on MySQL 8.

SET @has_visible := (
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'search_engine'
      AND COLUMN_NAME = 'visible'
);
SET @sql := IF(
    @has_visible = 0,
    'ALTER TABLE search_engine ADD COLUMN visible TINYINT(1) NOT NULL DEFAULT 1 AFTER sort_order',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;

-- Repair legacy data before adding the unique guard. Prefer the existing
-- default, then the first enabled engine by configured order.
SET @default_engine_id := (
    SELECT id
    FROM search_engine
    ORDER BY is_default DESC, visible DESC, sort_order ASC, id ASC
    LIMIT 1
);
UPDATE search_engine
SET is_default = CASE WHEN id = @default_engine_id THEN 1 ELSE 0 END,
    visible = CASE WHEN id = @default_engine_id THEN 1 ELSE visible END
WHERE @default_engine_id IS NOT NULL
  AND (
      is_default <> CASE WHEN id = @default_engine_id THEN 1 ELSE 0 END
      OR (id = @default_engine_id AND visible <> 1)
  );

SET @has_guard := (
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'search_engine'
      AND COLUMN_NAME = 'default_guard'
);
SET @sql := IF(
    @has_guard = 0,
    'ALTER TABLE search_engine ADD COLUMN default_guard TINYINT GENERATED ALWAYS AS (CASE WHEN is_default = 1 THEN 1 ELSE NULL END) STORED AFTER visible',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @has_default_guard_index := (
    SELECT COUNT(*)
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'search_engine'
      AND INDEX_NAME = 'uk_search_engine_one_default'
);
SET @sql := IF(
    @has_default_guard_index = 0,
    'ALTER TABLE search_engine ADD UNIQUE INDEX uk_search_engine_one_default (default_guard)',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @has_visible_sort_index := (
    SELECT COUNT(*)
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'search_engine'
      AND INDEX_NAME = 'idx_search_engine_visible_sort'
);
SET @sql := IF(
    @has_visible_sort_index = 0,
    'ALTER TABLE search_engine ADD INDEX idx_search_engine_visible_sort (visible, sort_order, id)',
    'SELECT 1'
);
PREPARE statement FROM @sql;
EXECUTE statement;
DEALLOCATE PREPARE statement;
