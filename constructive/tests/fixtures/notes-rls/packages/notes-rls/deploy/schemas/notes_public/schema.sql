-- Deploy schemas/notes_public/schema to pg
BEGIN;
CREATE SCHEMA notes_public;
GRANT USAGE ON SCHEMA notes_public TO anonymous, authenticated;
COMMIT;
