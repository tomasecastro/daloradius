-- =============================================================================
-- Migration: 000-app-version
-- Type: custom (docker/daloradius/migrations/)
-- Description: Creates the _app_version table to track the daloRADIUS version
--              installed in the database. This allows the installer to detect
--              fresh vs upgrade vs reinstall vs rollback by comparing against
--              version.php. Separate from _schema_migrations (which tracks
--              migration files, not versions). See ADR-0002 and ADR-0005.
-- Created: 2026-07-26
-- =============================================================================

CREATE TABLE IF NOT EXISTS `_app_version` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `version` VARCHAR(20) NOT NULL COMMENT 'daloRADIUS version (e.g. 2.3, 2.4)',
    `version_date` VARCHAR(20) NOT NULL COMMENT 'Version release date (e.g. 22 May 2026)',
    `installed_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
        COMMENT 'When this version was installed/upgraded',
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'Last update to this record',
    `notes` TEXT DEFAULT NULL
        COMMENT 'Comments (e.g. upgrade reason, reinstall notes, etc.)',
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_version` (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci
  COMMENT='daloRADIUS version history for this database';
