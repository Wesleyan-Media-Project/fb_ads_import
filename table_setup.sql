-- select the database; note that your name may be different
use dbase1;

-- create the table that will hold the search keywords
create table senate2022 
( name  TEXT,
  state TEXT,
  party TEXT,
  term TEXT, 
  in_the_race TEXT
  );


create table page_queue
(
    page_id TEXT,
    N INT,
    date TEXT
);


-- create the table that will hold the ad records
-- these are the fields supported by FB Ad Library API v.17.0
create table race2022 
(
  id TEXT,
  ad_creation_time TEXT, 
  ad_creative_bodies TEXT, 
  ad_creative_link_captions TEXT, 
  ad_creative_link_descriptions TEXT,
  ad_creative_link_titles TEXT, 
  ad_delivery_start_time TEXT, 
  ad_delivery_stop_time TEXT, 
  ad_snapshot_url TEXT, 
  bylines TEXT, 
  currency TEXT, 
  delivery_by_region TEXT, 
  demographic_distribution TEXT, 
  impressions TEXT, 
  languages TEXT, 
  page_id TEXT, 
  page_name TEXT, 
  publisher_platforms TEXT, 
  spend TEXT, 
  query TEXT, 
  hash TEXT, 
  is_active TEXT, 
  date TEXT,
  person TEXT
);

-- create an index to speed up lookup of ad records by their full content
CREATE INDEX race2022_hash_index 
USING BTREE
ON race2022 (hash(30));

-- create an index to speed up lookup of ad records by their query
CREATE INDEX race2022_query_index
USING BTREE
on race2022 (query(30));

-- insert some keyword strings into the table
INSERT INTO senate2022
(name, state, party, term, in_the_race)
VALUES
("Fetterman, John", "PA", "DEM", "Fetterman Senate", "yes"),
("Fetterman, John", "PA", "DEM", "John Fetterman", "yes"),
("Vance, J.D.", "OH", "GOP", "Vance Senate", "yes"),
("Vance, J.D.", "OH", "GOP", "JD Vance", "yes");


-- columns funding_entity, potential_reach, ad_creative_link_title
