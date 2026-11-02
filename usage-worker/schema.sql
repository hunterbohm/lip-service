CREATE TABLE IF NOT EXISTS pings (
  install TEXT NOT NULL,
  day TEXT NOT NULL,
  version TEXT NOT NULL,
  macos TEXT NOT NULL,
  dictation INTEGER NOT NULL,
  ghostwrite INTEGER NOT NULL,
  handoff INTEGER NOT NULL,
  PRIMARY KEY (install, day)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS pings_by_day ON pings (day);
