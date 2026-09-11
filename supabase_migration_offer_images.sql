-- ============================================================================
-- Adds a photo to Offers, same as Products and Services already have.
-- Safe to re-run. Only adds a column — nothing is deleted or changed.
-- ============================================================================

alter table offers add column if not exists image text;
