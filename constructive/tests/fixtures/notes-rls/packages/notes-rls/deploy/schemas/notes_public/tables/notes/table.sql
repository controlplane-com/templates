-- Deploy schemas/notes_public/tables/notes/table to pg
-- requires: schemas/notes_public/schema
BEGIN;
CREATE TABLE notes_public.notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  title text NOT NULL
);
ALTER TABLE notes_public.notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY notes_select ON notes_public.notes FOR SELECT TO authenticated
  USING (owner_id = nullif(current_setting('jwt.claims.user_id', true), '')::uuid);
CREATE POLICY notes_insert ON notes_public.notes FOR INSERT TO authenticated
  WITH CHECK (owner_id = nullif(current_setting('jwt.claims.user_id', true), '')::uuid);
GRANT SELECT, INSERT ON notes_public.notes TO authenticated;
COMMIT;
