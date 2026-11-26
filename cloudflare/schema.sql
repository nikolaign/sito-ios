-- D1 stores only opaque ciphertext. The phone holds the AES-GCM recovery key.
CREATE TABLE IF NOT EXISTS objects (
    object_key TEXT PRIMARY KEY,
    byte_length INTEGER NOT NULL CHECK (byte_length > 0),
    parts INTEGER NOT NULL CHECK (parts > 0)
);

CREATE TABLE IF NOT EXISTS object_parts (
    object_key TEXT NOT NULL,
    part INTEGER NOT NULL CHECK (part >= 0),
    data BLOB NOT NULL,
    PRIMARY KEY (object_key, part)
);
