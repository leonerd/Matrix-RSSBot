CREATE TABLE feeds (
  url TEXT,
  title TEXT,
  UNIQUE ( url )
);
CREATE INDEX feeds_by_url ON feeds ( url );

CREATE TABLE items (
  guid TEXT
);
CREATE INDEX items_by_guid ON items ( guid );

CREATE TABLE feed_room (
  url TEXT REFERENCES feeds ( url ),
  room TEXT,
  UNIQUE ( url, room )
);
CREATE INDEX feed_room_by_feed ON feed_room ( url );
