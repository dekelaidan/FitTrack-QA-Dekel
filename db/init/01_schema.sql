-- FitTrack landing-zone schema. Rows arrive here as the source systems send them.

CREATE TABLE branches (
    branch_id   integer PRIMARY KEY,
    name        text    NOT NULL,
    city        text    NOT NULL,
    timezone    text    NOT NULL,
    opened_on   date    NOT NULL,
    opens_at    time    NOT NULL,
    closes_at   time    NOT NULL
);

CREATE TABLE devices (
    device_id   text    PRIMARY KEY,
    branch_id   integer NOT NULL REFERENCES branches (branch_id),
    kind        text    NOT NULL
);

CREATE TABLE members (
    member_id        integer PRIMARY KEY,
    first_name       text,
    last_name        text,
    email            text,
    date_of_birth    date,
    home_branch_id   integer,
    joined_on        date,
    membership_tier  text,
    status           text
);

CREATE TABLE events (
    event_id     bigint      PRIMARY KEY,
    source_ref   text        NOT NULL,
    member_id    integer,
    event_type   text        NOT NULL,
    event_ts     timestamptz NOT NULL,
    branch_id    integer,
    device_id    text,
    ingested_at  timestamptz NOT NULL,
    details      jsonb
);

COMMENT ON TABLE  members             IS 'Member profiles, plus the CRM''s current view of each member''s tier and status.';
COMMENT ON TABLE  events              IS 'Membership events (from the CRM) and access events (from turnstiles and front-desk tablets).';
COMMENT ON COLUMN events.source_ref   IS 'Identifier assigned by the sending system: crm:<n> for the CRM, <device_id>:<sequence> for devices.';
COMMENT ON COLUMN events.event_ts     IS 'When the event happened, as reported by the sending system.';
COMMENT ON COLUMN events.ingested_at  IS 'When the row landed in this database.';
