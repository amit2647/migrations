-- Outbox for the assistant's vector index.
--
-- The vectors live in Qdrant, which shares no transaction with Postgres. So
-- the "this message needs embedding" marker is a column here, committed in the
-- same transaction as the message itself: nothing written can be missed, and
-- a worker in assistant-service drains it into Qdrant afterwards.
--
-- Postgres remains the source of truth. Setting these back to 'pending'
-- rebuilds the index from scratch.

ALTER TABLE assistant_messages
  ADD COLUMN IF NOT EXISTS embed_status VARCHAR(20) NOT NULL DEFAULT 'pending';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'assistant_messages_embed_status_check'
  ) THEN
    ALTER TABLE assistant_messages
      ADD CONSTRAINT assistant_messages_embed_status_check
      CHECK (embed_status IN ('pending', 'done', 'skipped'));
  END IF;
END $$;

-- Drives the worker's claim query, and stays tiny: only undrained rows.
CREATE INDEX IF NOT EXISTS idx_assistant_messages_embed_pending
  ON assistant_messages(id)
  WHERE embed_status = 'pending';

-- Deletes have to reach Qdrant too. A soft-deleted conversation whose points
-- have not been removed yet is one with this still null.
ALTER TABLE assistant_conversations
  ADD COLUMN IF NOT EXISTS vectors_purged_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_assistant_conversations_purge_pending
  ON assistant_conversations(id)
  WHERE deleted_at IS NOT NULL AND vectors_purged_at IS NULL;

-- Keyword half of the hybrid search: the caller's own messages matched by
-- words, alongside Qdrant's match by meaning. 'simple' rather than 'english',
-- so names and ids are not stemmed away.
CREATE INDEX IF NOT EXISTS idx_assistant_messages_fts
  ON assistant_messages
  USING GIN (to_tsvector('simple', content))
  WHERE role IN ('user', 'assistant');
