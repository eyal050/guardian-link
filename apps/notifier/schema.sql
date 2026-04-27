-- gen_random_uuid() is built-in on Postgres 16 (no extension needed).

CREATE TABLE IF NOT EXISTS users (
  user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name    TEXT NOT NULL,
  email   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  user_id   UUID NOT NULL REFERENCES users(user_id)
);

CREATE TABLE IF NOT EXISTS emergency_contacts (
  contact_id UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID    NOT NULL REFERENCES users(user_id),
  name       TEXT    NOT NULL,
  phone      TEXT,       -- E.164 format; NULL = no SMS for this contact
  email      TEXT,       -- NULL = no email for this contact
  push_token TEXT,       -- NULL = no push for this contact
  active     BOOLEAN NOT NULL DEFAULT TRUE
);
