CREATE TABLE feeds (
  url TEXT,
  title TEXT
);
CREATE INDEX feeds_by_url ON feeds ( url );

CREATE TABLE items (
  guid TEXT
);
CREATE INDEX items_by_guid ON items ( guid );
