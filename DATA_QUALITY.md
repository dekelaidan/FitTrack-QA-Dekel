# FitTrack data quality report

Scope: the `fittrack` database as loaded by `docker compose up` (membership history 2021–2024, access events 2024).
Everything below can be reproduced with the queries in `profiling/` (outputs saved next to them) and is
guarded by the test suite in `tests/`.

## How to read this

**Severity** is about the reports, not about how odd the data looks:

| Severity | Meaning |
|---|---|
| **High** | Left uncleaned, it visibly distorts at least one report (whole days, months or branches off by more than ~2%). |
| **Medium** | Distorts a report by a smaller amount, or for a limited period or branch. |
| **Low** | No or negligible report impact today; still a defect in a source system. |

**In the test suite**, every issue below is a *warning*, because all four reports already correct for it.
The suite's *blocking* checks are the ones that would mean the cleaning rules no longer hold (for example an
unknown event type, a `source_ref` shared by two different events, or an access event still outside opening
hours after cleaning). On this database the suite passes with 18 warnings. See the README for the reasoning.

**Root causes first.** Several symptoms that looked like separate problems during profiling turned out to
share one cause; they are grouped under it.

## Summary

| # | Root cause | Severity | Main symptoms | Worst report impact if uncleaned |
|---|---|---|---|---|
| 1 | Devices replayed buffered events, re-stamped with the resend time | **High** | 3,036 duplicate `source_ref`s with a different `event_ts`; 3,037 access events outside opening hours | `daily_visits` 2024-10-20: 1,057 check-ins instead of 174 |
| 2 | CRM sends cancellations in a monthly batch on the 2nd | **High** | All 420 cancellations ingested 1–32 days late; `members.status` stale; check-ins after cancellation | `active_members_monthly` overstated by 8–24 members (1.3–3.4%) when run at month end |
| 3 | Turnstile test cards are in the production feed | Medium | 828 events for 2 member_ids not in `members` | `visits_per_branch` +53 per branch (+35 at Pearl District, ~+0.5–1.0%) |
| 4 | D04-IN (Riverwalk entrance) sent `CHECK_IN` for one week | Medium | 181 rows with an undocumented `event_type` | `visits_per_branch` Riverwalk −181 (−1.9%) |
| 5 | D07-IN (Mission Bay entrance) clock 3 h ahead for two months | Medium | 1,542 events stamped after they were ingested; 172 check-ins "after closing" | `daily_visits`: 72 visits on the wrong day |
| 6 | Normal at-least-once delivery retries | Low | 700 `source_ref`s delivered twice, identical, within 5 min | `visits_per_branch` ~+0.5% |
| 7 | `members` table is not maintained from the event stream | Low | 49 status and 8 tier disagreements; 2 members with no CRM history; 5 people with two member records | `active_members_monthly` off by −2 to 0 members |
| 8 | Pearl District pre-sale sign-ups took a different code path | Low | 5 members with `home_branch_id = 9` (doesn't exist) and `status = 'Active'` | none |
| 9 | Exit events go missing: one transmission loss plus background tailgating | Low | 27-event sequence gap on D02-OUT on 2024-08-13; 892 check-ins without check-out | none (a visit is counted on check-in) |
| 10 | Front desk records friend visits without a member check-in | Low | 55 friend visits with no matching check-in | `daily_visits` friend counts: 55 of 6,875 |
| 11 | Small CRM data-entry defects | Low | 3 placeholder birth dates; 3 `tier_changed.from` values that don't match the previous tier | none |

Combined effect on the required report (`profiling/04_deep_dive.sql`, section 14):

| Branch | Naive query* | Clean (report) | Overcount |
|---|---|---|---|
| 1 Back Bay | 10,131 | 9,838 | +3.0% |
| 2 Harbor Point | 10,326 | 10,006 | +3.2% |
| 3 Lakeshore | 11,671 | 11,354 | +2.8% |
| 4 Riverwalk | 9,340 | 9,264 | +0.8% (the casing loss offsets the duplicates) |
| 5 Union Station | 9,589 | 9,339 | +2.7% |
| 6 Camelback | 8,951 | 8,679 | +3.1% |
| 7 Mission Bay | 10,024 | 9,744 | +2.9% |
| 8 Pearl District | 3,807 | 3,675 | +3.6% |

\* `count(*) WHERE event_type = 'check_in'` over the 2024 UTC year, with no dedupe and no member filter.

---

## 1. Device replays re-stamped with the resend time (High)

**What.** Twice, at around 07:1x UTC (03:1x Eastern, 00:1x Pacific), every access device re-sent the events it
had buffered over the previous ~4 days. Each re-sent copy keeps its original `source_ref`, member and payload,
but its `event_ts` is set to the moment of re-sending. So each copy looks like a brand-new visit in the middle
of the night.

**Evidence.**
- `profiling/03_duplicates.sql`: among duplicated `source_ref`s, 3,036 differ **only** in `event_ts`. The
  member, type and details are identical. The other 700 are byte-identical (root cause 6).
- `profiling/04_deep_dive.sql` §1: the re-stamped copies all fall in two bursts.

  | Replay | Rows | Devices | Window (UTC) | Lag of the copy |
  |---|---|---|---|---|
  | 2024-03-20 | 1,224 | 21 (all devices that existed then) | 07:11–07:18 | exactly 0.2 s |
  | 2024-10-20 | 1,812 | 24 (all devices) | 07:21–07:32 | exactly 0.2 s |

- The copies are therefore stamped at send time (lag 0.2 s), while originals show the normal ~13 s lag.
- Device sequence numbers are gap-free (except root cause 9) and increase with time on every device. So a
  shared `source_ref` really is the same event, never two events reusing a counter.
- `profiling/05_verify_rules.sql` §A: access events outside opening hours drop from 3,209 to 172 once copies
  are deduplicated. The replays explain all of the out-of-hours activity except root cause 5.

**Reports affected.**
- `daily_visits`: on 2024-10-20 a naive count shows 1,057 check-ins and 94 friend visits against 174 and 15
  real ones. On 2024-03-20 it shows 778 check-ins against 197 (`profiling/06_report_impact.sql` §1). The
  visits are also taken away from the days they really happened on.
- `visits_per_branch`: together with root cause 6, it accounts for 207–273 extra visits per branch (110 at Pearl District).
- `friend_allowance_monthly`: March and October utilisation would read 26.9% and 25.5% instead of 25.3% and
  23.8%.
- `active_members_monthly`: not affected (CRM events are not replayed).

**Handling.** All reports keep the **earliest** copy per `source_ref` (`ROW_NUMBER()` / `DISTINCT ON` ordered by
`event_ts, event_id`). Test `A14_duplicate_burst` warns when more than 100 extra copies land on one UTC day.
On this load it flags exactly the two replay days.

**Most likely cause.** A store-and-forward bug in the access-control gateway or device firmware. On reconnect
(or after a scheduled job: both bursts are on the 20th, at a similar time), it re-sends its buffer, and
serialises the send time instead of the stored event time. The 0.2 s constant lag and the fractional seconds
(the originals are whole seconds on entrance and desk devices) point to the copies being generated by a
different code path from live events.

## 2. CRM cancellations arrive in a monthly batch (High)

**What.** Starts, reactivations and tier changes reach the database within about 90 seconds. **Every**
cancellation arrives on the 2nd of a later month, between 1 and 32 days after it happened (median 17 days).

**Evidence.** `profiling/04_deep_dive.sql` §10:

| event_type | rows | lag > 1 day | median lag | max lag |
|---|---|---|---|---|
| membership_cancelled | 420 | **420** | 16 d 22 h | 32 d 1 h |
| membership_started | 1,120 | 0 | 44 s | 90 s |
| membership_reactivated | 56 | 0 | 53 s | 90 s |
| tier_changed | 95 | 0 | 54 s | 90 s |

All 420 cancellations have `ingested_at` on day 2 of a month.

**Symptoms that share this cause.**
- **`members.status` is stale.** 34 members are `active` in `members` but cancelled in the events. 24 of them
  are exactly the cancellations that arrived in the 2024-12-02 and 2025-01-02 batches; the batch evidently
  doesn't update `members` (the other 10 are from the first 2021 batches). See §11 and root cause 7.
- **Check-ins after cancellation.** 29 members checked in 293 times after their cancellation date, up to 40
  days later (§9). 169 of those check-ins happened before the cancellation had even reached the database.
  Either access control is only told about cancellations when the batch lands, or cancellations take effect
  at the end of a billing period. Question for the CRM team.

**Reports affected.**
- `active_members_monthly` is correct once the batch has landed, but any figure produced before the 2nd of the
  following month is too high. Running it on the last day of each 2024 month would have overstated by 8–24
  members, +1.3% to +3.4% (`profiling/06_report_impact.sql` §3). In a daily CI the latest month will drop
  every 2nd.
- Using `members.status` instead of events would report 777 active members for every month.
- `visits_per_branch` and `daily_visits` include the 293 post-cancellation check-ins (a deliberate decision:
  they are visits that happened). That is 0.4% of visits.

**Handling.** The report follows the business rule: state comes from events, never from `members.status`.
The "provisional until the 2nd" caveat is stated in the report's comments. Test `M09_late_crm_events` tracks
the lag.

**Most likely cause.** Cancellations are processed by a separate monthly job (billing or finance run) rather
than the real-time CRM integration, and that job writes events but not `members`.

## 3. Turnstile test cards in the production feed (Medium)

**What.** Two `member_id`s that don't exist in `members` (990001 and 990002) check in and out every
**Monday** between 05:02 and 05:11 local time, the minute the doors open. 990001 covers branches 1–4 and
990002 branches 5–8, each visit lasting about a minute.

**Evidence.** `profiling/04_deep_dive.sql` §4: 828 rows; after dedupe, 406 check-ins and 406 check-outs, all
on Mondays. (990002 shows one 08:08 check-in: the Mission Bay clock problem, root cause 5.) No CRM events
exist for either ID.

**Reports affected.** `visits_per_branch` +53 per branch (+35 at Pearl District, which opened in May): +0.5% to +1.0%. `daily_visits` +7–8 on every Monday.
They also break visit-pairing logic: one card "checks out" of one branch and into another a minute later.

**Handling.** Reports count only `member_id`s present in `members`. This also covers any other test or unknown
cards in another database without hard-coding IDs.

**Most likely cause.** A scheduled turnstile health check that uses real cards and isn't filtered or flagged
by the access-control system.

## 4. `CHECK_IN` in upper case from D04-IN for one week (Medium)

**What.** The Riverwalk (Austin) entrance turnstile sent `CHECK_IN` instead of `check_in` for exactly 7 local
days, 2024-04-08 to 2024-04-14, then returned to normal.

**Evidence.** `profiling/02_anomalies.sql` §A: 181 rows, all from D04-IN, 18–35 per day. §A2: none has a
lowercase twin with the same `source_ref`, so these are real visits, not duplicates.

**Reports affected.** Any query filtering `event_type = 'check_in'` loses them: `visits_per_branch` Riverwalk
−181 (−1.9%), and `daily_visits` loses 18–35 visits on each of those 7 days.

**Handling.** All reports compare `lower(event_type)`. Test `E02_event_type_casing` warns; `E01` blocks if a
type is unknown even ignoring case.

**Most likely cause.** A firmware or configuration change on one device, rolled back a week later.

## 5. D07-IN clock 3 hours ahead (Medium)

**What.** From 2024-06-06 to 2024-08-06, every event from the Mission Bay (San Francisco) entrance carries an
`event_ts` 2:55–3:00 later than when it arrived in the database.

**Evidence.** `profiling/04_deep_dive.sql` §3: 1,542 rows; they are the only events in the whole table with
`event_ts > ingested_at`. Every D07-IN event in that window is affected, none outside it. §2: after dedupe,
the only access events left outside opening hours are 172 of these (check-ins "after 23:00").

**Reports affected.** Year and month totals don't move (the window is mid-year). In `daily_visits`, 72 visits
land on the next day (§2 of `06_report_impact.sql`). Friend visits recorded by the (correct) front-desk tablet
appear to happen before their member's check-in.

**Handling.** All reports use `least(event_ts, ingested_at)`. An event cannot happen after it was ingested,
and the normal lag is about 13 s, so this restores the time to within seconds without naming the device.
`profiling/05_verify_rules.sql` §A shows out-of-hours events go to 0. Limitation: a clock that runs *slow*
cannot be told apart from late delivery and is not corrected.

**Most likely cause.** The device's time zone was set to Eastern instead of Pacific (exactly the 3 h
difference), and it sends local wall-clock time as if it were UTC-correct. It was fixed on 2024-08-06.

## 6. At-least-once delivery retries (Low)

**What.** 700 `source_ref`s were delivered twice with identical content, the second copy 5 s to 5 min after
the first, spread evenly across all devices and the year.

**Evidence.** `profiling/02_anomalies.sql` §B (rows marked `identical = t`); test `A01_retry_duplicates`.

**Reports affected.** About +0.5% on visits and friend visits if not deduplicated (369 check-in and
friend-visit copies). Handled by the same dedupe as root cause 1.

**Most likely cause.** Normal behaviour of a retrying sender. Ingestion doesn't enforce uniqueness on
`source_ref`; there is an index on it, but not a unique one.

## 7. `members` drifts away from the membership events (Low)

**What.** The `members` table is not kept in step with the event stream:

| Symptom | Count | Notes |
|---|---|---|
| `status = 'active'`, but latest event is a cancellation | 34 | root cause 2 |
| `status = 'cancelled'`, but latest event is a start or reactivation | 15 | 6 started, 9 reactivated, from 2021 to 2024 |
| `membership_tier` differs from the latest tier event | 8 | |
| Members with no CRM events at all | 2 | 1031 and 1132: both `active`, they visit (125 check-ins, 85 friend visits) |
| Same email on two members | 5 pairs | 2 former members re-joined as **new** members instead of being reactivated (1103 → 2121, 1162 → 2122); 1 was cancelled after a day and re-created (1723 → 2120); 2 were created twice on consecutive days and were both active at once (1736 + 2118 still are; 1863 + 2119 until August) |

**Evidence.** `profiling/04_deep_dive.sql` §11–13; tests `M03`, `M05`, `M06`.

**Reports affected.** Reports use events, so mostly none. However:
- `active_members_monthly` cannot see members 1031 and 1132 (no events), so it undercounts by 2.
- People created twice are counted twice: +1 from February 2024 (1736/2118), and +1 more from May to July 2024 (1863/2119).
- `friend_allowance_monthly` falls back to `members.membership_tier` for 1031 and 1132. Using
  `members.membership_tier` for everyone would move monthly utilisation by at most 0.2 points.

**Most likely cause.** `members` is maintained by a separate CRM process (a profile sync) that misses some
event types. The duplicate records suggest that neither sign-up nor re-join checks for an existing member with the same email.

## 8. Pearl District pre-sale sign-ups (Low)

**What.** The 5 members who signed up before Pearl District opened (2024-04-15 to 04-28; it opened
2024-05-01) are the only rows with `home_branch_id = 9` (which doesn't exist) **and** the only rows with
`status = 'Active'` (capital A). Their `membership_started` events correctly carry `branch_id = 8`.

**Evidence.** `profiling/04_deep_dive.sql` §4b; tests `M01`, `M02`.

**Reports affected.** None: reports don't use `home_branch_id` or `status`. Anything grouping members by home
branch would lose these 5.

**Most likely cause.** A pre-opening sign-up form (or a manual import) with a placeholder branch ID and its own
status spelling, never migrated once the branch opened.

## 9. Missing check-outs (Low)

**What.** 892 check-ins (1.2%) are not followed by a check-out of the same member. There are two causes:
- **Transmission loss.** D02-OUT (Harbor Point exit) numbered 27 events (sequence 5963–5989) on 2024-08-13
  that never arrived. That is the whole local day: no check-outs at all that day, and 27 check-ins left open.
- **Background.** The other 865 are spread evenly across branches and months (about 9 per branch per month):
  people leaving through an open gate or tailgating out.

There are **no** check-outs without a check-in.

**Evidence.** `profiling/04_deep_dive.sql` §5–7; tests `A04_sequence_gaps`, `A05_check_in_without_check_out`,
`A12_check_out_without_check_in`.

**Reports affected.** None of the four, because a visit is counted when it starts (business rule 3), not when
it ends. It would matter for visit duration or occupancy reporting.

**Most likely cause.** An outage between D02-OUT and the gateway on 2024-08-13. The device kept counting but its
buffer was lost (it was not replayed, unlike root cause 1).

## 10. Friend visits without a member check-in (Low)

**What.** 55 friend visits (0.8%) have no check-in by the same member at the same branch between 5 minutes
before and 30 minutes after. Normally the front desk records the friend 0–5 minutes after the member's
check-in. They are spread across all 8 front desks and all months.

**Evidence.** `profiling/04_deep_dive.sql` §8; test `A06_friend_visit_without_member_visit`.

**Reports affected.** `daily_visits` friend counts include them (55 of 6,875). The friend did come in; the
missing check-in is the defect. In `friend_allowance_monthly` they count only if the member also visited that
month.

**Most likely cause.** Staff picking the wrong member on the tablet, or the member walking in with the friend
without scanning. The business rule says a friend can only come in with the member, so this is also a
process issue for branch managers.

## 11. Small CRM data-entry defects (Low)

- 3 members (1706, 1711 and 1712, all Camelback, January 2024) have `date_of_birth = 1900-01-01`: a placeholder
  for "unknown". Test `M04`.
- 3 `tier_changed` events have a `from` value that isn't the member's tier at the time. Reports use `to`, so
  there is no impact. Test `M08`.

## Observations that are not defects

- **No visits on 2024-12-25 at any branch**, so `daily_visits` has 365 rows, not 366. This looks like a
  Christmas closure. A naive UTC-day query invents 79 visits for that date (Dec 24 evenings).
- **Bucketing by UTC instead of local day moves 17,598 check-ins (24%) to a different date.** This is the
  single biggest error a naive daily report would make. Every report uses the branch's IANA time zone (which
  handles DST and Arizona's lack of it).
- **Pearl District had CRM activity before it opened** (the 5 pre-sale sign-ups): expected. There is no access
  activity before opening (test `A11`).

---

## Contract guards: what the suite also rules out

Some failure modes did not occur in this load, but would silently corrupt the reports if they appeared in a
future load or in another database with this schema. Each one has a check, and each check was proven to fire
by injecting the problem into a scratch copy of the database (see `AI_USAGE.md`). All of them return
**0 rows today**.

| Area | Check | Severity | What it rules out | Why it matters to the reports |
|---|---|---|---|---|
| Unknown event types | `E01_unknown_event_type` | blocking | an `event_type` outside the 7 documented types, even ignoring case | the reports would silently drop (or miscount) a new kind of event |
| | `E02_event_type_casing` | warning | a documented type in the wrong case (today: 181 `CHECK_IN`, root cause 4) | handled by `lower()`; tracked so a new offender is visible |
| | `E11_documented_type_missing` | warning | a documented type with no rows at all | a sender that stopped, or renamed its type, would look like "zero activity" |
| Shared `source_ref` | `E07_source_ref_collision` | blocking | rows sharing a `source_ref` with a different member, type, branch or device | dedupe keeps one row per `source_ref`; on a real collision it would delete a genuine event |
| | `E12_source_ref_payload_collision` | blocking | rows sharing a `source_ref` with different `details` (for example two different friends) | same: they are two events, not copies |
| | `E13_crm_source_ref_reused` | blocking | a CRM `source_ref` appearing twice | the CRM never replays (0 repeats of 1,691 refs), so a repeat means its counter collided |
| | `E14_source_ref_copies_too_far_apart` | blocking | copies of one device `source_ref` more than 7 days apart | real replays are at most 3 d 22 h apart; a bigger gap points to a counter reset, so "keep the earliest copy" would discard a real later event |
| Branches and devices | `E04_unknown_branch` | blocking | an event whose `branch_id` is not in `branches` | the event has no time zone, so it can't be placed on a local day and drops out of every report |
| | `E05_device_mismatch` | blocking | an access event from an unknown device, another branch's device, or the wrong kind (a check-in from an exit) | the visit would be credited to the wrong branch, or be a phantom |
| | `B05_device_kind_domain` | blocking | a device whose `kind` is not `entrance` / `exit` / `front_desk` | `E05` maps event types to kinds; an unknown kind breaks that mapping |
| Membership history | `M10_tier_changed_without_active_membership` | blocking | a `tier_changed` before any membership or after a cancellation | `friend_allowance_monthly` takes the tier from these events; a change outside a membership would give a member an allowance they don't have |
| | *(not a check)* device → unknown branch | n/a | already enforced by the schema's foreign key `devices.branch_id REFERENCES branches` | a check for it could never fire, so none was written |
| Opening hours after cleaning | `A10_outside_opening_hours_after_cleaning` | blocking | a member's access event still outside local opening hours **after** dedupe (root causes 1 and 6) and clock capping (root cause 5) | the cleaning rules no longer explain the data; a new kind of defect has appeared |
| | `A13_outside_hours_unknown_members` | warning | the same, for `member_id`s not in `members` (test cards and the like) | they are excluded from reports, but a change in their pattern is worth seeing |

**Independent review.** The finished suite was also reviewed by a second AI tool (Gemini), and each of its 11
suggestions was checked against the data. That review led to `M10` (added), a corrected description for
`A03` (it covers CRM clocks as well as devices) and the B03 assumption comment; the other 8 suggestions were
disproved and not applied. Details in `AI_USAGE.md`.

How the opening-hours guard was derived: in the raw data, 3,209 access events fall outside opening hours.
Deduplication removes 3,037 of them (all replay copies), and capping the time at `ingested_at` removes the last
172 (all from D07-IN). That leaves 0 (`profiling/05_verify_rules.sql`). So any non-zero result in a future load
is, by construction, something the rules don't yet explain.

## Questions for the CRM team

1. Why are cancellations delivered in a monthly batch on the 2nd, when every other event type is near
   real-time? Can they be sent when they happen?
2. Does `membership_cancelled.event_ts` mean the date the member asked to cancel, or the date the membership
   ends? 29 members kept checking in for up to 40 days after it. Is that expected (paid-up period), or is
   access-control not being told?
3. Which process maintains `members.status` and `membership_tier`? It disagrees with the events for 49 and 8
   members respectively, including every cancellation from the last two batches.
4. Why do members 1031 and 1132 have no membership events at all? They are active and visit regularly.
5. Five people have two member records (matching emails). Two were former members who re-joined as new members
   instead of being reactivated, and two were created twice on consecutive days. Is there a duplicate check at
   sign-up, and should these records be merged?
6. What created the Pearl District pre-sale members with `home_branch_id = 9` and `status = 'Active'`? Will the
   same path be used for the next branch opening?
7. Is `date_of_birth = 1900-01-01` a deliberate "unknown" value? Can it be NULL instead?

## Questions for the access-control team

1. What happened on 2024-03-20 and 2024-10-20 around 07:15 UTC? Every device re-sent ~4 days of events with
   new timestamps. Is there a scheduled job on the 20th, a firmware update, or a gateway restart? Can replays
   carry the original event time?
2. Why do retries and replays reuse `source_ref` with a different payload? Can ingestion enforce
   `UNIQUE (source_ref)`?
3. Was D07-IN (Mission Bay entrance) set to Eastern time between 2024-06-06 and 2024-08-06? How are device clocks
   and time zones managed, and is NTP monitored?
4. What changed on D04-IN between 2024-04-08 and 2024-04-14 to make it send `CHECK_IN`?
5. What happened to D02-OUT on 2024-08-13? It numbered 27 events that never arrived. Can a device's buffer be
   recovered or replayed after an outage?
6. Are member_ids 990001 and 990002 test cards? Can test traffic be flagged (or sent with a reserved ID range
   and documented) so it never mixes with real visits?
7. Is the turnstile told when a membership is cancelled? Members kept getting in after cancelling.
8. Is a friend visit allowed to be recorded when the member hasn't scanned in (55 cases)?

## What I would monitor from now on

The test suite (`pytest`) is the daily gate on every new load. Blocking checks stop the reports; warnings
are listed in the run summary. In addition I would alert on trends, not just presence:

| Monitor | Why | Alert when |
|---|---|---|
| Duplicate copies per ingestion day (`A14`), with replays detailed by `A02` | Root cause 1 can strike again | more than 100 extra copies on one UTC day. The baseline is a median of 2 and a worst normal day of 7; the two 2024 bursts were 1,226 and 1,817 |
| Exact retries per day (`A01`) | Normal, but a jump means a sender is unhealthy | > 3× the trailing 30-day average |
| Events with `event_ts > ingested_at` (`A03`) | A device clock or time zone went wrong | any row in the latest load |
| Sequence gaps per device (`A04`) | Lost events | any new gap |
| Device silence: a device with no events on a day its branch had traffic | Root cause 9 found this way | any device silent for a full open day |
| Undocumented `event_type` values, including casing (`E01`, `E02`) | Contract drift | any new value |
| Unknown `member_id`s (`E10`) | Test cards or a CRM-to-access sync gap | any ID beyond the known test cards |
| CRM ingestion lag by type (`M09`) | Root cause 2; the month figure is provisional | cancellations missing after the 2nd; any other type lagging > 1 h |
| `members` vs events disagreement (`M05`) | Root cause 7 | count grows after a batch lands |
| Check-ins without check-out per branch per day (`A05`) | Exit hardware | > 3× the branch's usual daily rate |
| Daily visit counts per branch vs the same weekday's trailing average | Catch anything the rules don't know about yet | ±30% |
| Freshness: `max(ingested_at)` | The feed has stopped | older than 1 hour during opening hours |

## Reproducing the evidence

```bash
source .env
psql -P pager=off -f profiling/04_deep_dive.sql      # root causes, sections referenced above
psql -P pager=off -f profiling/05_verify_rules.sql   # proof each cleaning rule works
psql -P pager=off -f profiling/06_report_impact.sql  # report impact if uncleaned
pytest                                               # the checks, with warnings listed at the end
```
