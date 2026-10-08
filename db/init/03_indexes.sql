CREATE INDEX events_member_ts_idx ON events (member_id, event_ts);
CREATE INDEX events_ts_idx ON events (event_ts);
CREATE INDEX events_type_idx ON events (event_type);
CREATE INDEX events_source_ref_idx ON events (source_ref);
ANALYZE;
