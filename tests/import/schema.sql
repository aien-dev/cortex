-- cortex-rs 0.1.0 src/db.rs init_schema SQL, copied verbatim (lines 41-90) for synthetic fixtures.
            CREATE TABLE IF NOT EXISTS spaces (
                id TEXT PRIMARY KEY,
                slug TEXT UNIQUE NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS entities (
                id TEXT PRIMARY KEY,
                space_id TEXT NOT NULL,
                space_slug TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                canonical_name TEXT NOT NULL,
                content TEXT NOT NULL,
                aliases_json TEXT NOT NULL DEFAULT '[]',
                metadata_json TEXT NOT NULL DEFAULT '{}',
                confidence REAL NOT NULL DEFAULT 1.0,
                revision INTEGER NOT NULL DEFAULT 1,
                retracted INTEGER NOT NULL DEFAULT 0,
                valid_from TEXT,
                valid_to TEXT,
                created_at TEXT NOT NULL,
                embedding BLOB
            );

            CREATE INDEX IF NOT EXISTS idx_entities_canonical ON entities(space_slug, canonical_name);
            CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(space_slug, entity_type);

            CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts USING fts5(
                id UNINDEXED,
                canonical_name,
                content,
                space_slug UNINDEXED
            );

            CREATE TABLE IF NOT EXISTS claims (
                id TEXT PRIMARY KEY,
                space_id TEXT NOT NULL,
                space_slug TEXT NOT NULL,
                subject_entity_id TEXT NOT NULL,
                predicate TEXT NOT NULL,
                object_entity_id TEXT,
                literal_value_json TEXT,
                confidence REAL NOT NULL DEFAULT 1.0,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                retracted INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_claims_subject ON claims(subject_entity_id);
            CREATE INDEX IF NOT EXISTS idx_claims_object ON claims(object_entity_id);
