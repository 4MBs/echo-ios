# `/timetable/week` — what the app wants from the server

The Stunden tab draws the school week as a grid. It has everything it needs
except **holidays**, which the iPad has no way to learn: it only ever talks to
the Fedora backend, and only the backend talks to WebUntis.

This is the contract the app already reads. Nothing here needs an app release —
the client ships with it and uses whatever arrives.

## What the app asks for

```
GET /timetable/week?start=YYYY-MM-DD        # start is a Monday
```

```json
{
  "days": [
    { "enabled": true, "date": "2026-07-27", "lessons": [ … ] }
  ],
  "holidays": [
    { "name": "Sommerferien", "start": "2026-07-04", "end": "2026-07-30" }
  ]
}
```

Both keys are optional on the wire. `holidays` missing means "no holiday data"
and the grid simply draws none — it never guesses. Dates are `yyyy-MM-dd`, and
the holiday range is **inclusive at both ends**.

Until the endpoint exists the app answers a 404 by firing five parallel
`/timetable/day` calls and assembling the same value, so the tab works today
and gains holidays the day the endpoint lands. Five requests become one, too.

### `lessons[]`

The existing `/timetable/day` shape, unchanged:

| field | notes |
|---|---|
| `date` | `yyyy-MM-dd` |
| `start`, `end` | `HH:mm`, local |
| `subject`, `subject_long` | `BIO` / `Biologie` — the grid shows the long one |
| `teacher`, `room`, `title`, `info` | plain strings, `""` when absent |
| `cancelled`, `substitution` | booleans |

Four **optional** additions, used when present and ignored when not:

| field | notes |
|---|---|
| `period_id` | int. WebUntis' own period id. Becomes the block's identity, which is otherwise pieced together from date + time + subject — and that collides when two parallel lessons share a subject. |
| `type` | string, straight through from WebUntis (`NORMAL_TEACHING_PERIOD`, `EVENT`, `ADDITIONAL_PERIOD`). |
| `layout_start`, `layout_width` | ints, `0…1000` across the day's width. WebUntis' own answer to which parallel column a lesson sits in. Supply **both or neither**, and for **every** lesson on a day or none of them — the app falls back to packing columns itself and will not mix the two, since that could stack one block on another. |

## Where the data is in WebUntis

Captured from the WebUntis web app (`avs-itzehoe.webuntis.com`, July 2026).
One request returns the lessons *and* the holidays for a date range:

```
GET /WebUntis/api/rest/view/v1/timetable/entries
    ?start=2026-07-27&end=2026-07-31&format=2
    &resourceType=STUDENT&resources=<studentId>&periodTypes=&timetableType=…
```

Headers: `Authorization: Bearer <jwt>`, the session cookie, `tenant-id`,
`x-webuntis-api-school-year-id`.

Auth is two steps, and this is the real work: a **web session login** for the
`JSESSIONID` cookie, then `GET /WebUntis/api/token/new` with that cookie, which
returns a **JWT valid for 15 minutes** — so it needs minting per batch of
requests or refreshing on a timer. A JSON-RPC `authenticate` session is not
usable here.

### Response

```
{ format, errors: [], days: [ { date, resourceType, resource, status,
                                dayEntries: [], gridEntries: [], backEntries: [] } ] }
```

**Holidays — `backEntries[]`:**

```json
{ "type": "HOLIDAY", "isFullDay": true,
  "shortName": "Sommerferien", "longName": "Sommerferien",
  "duration":      { "start": "2026-07-20T00:00", "end": "2026-07-20T23:59:59" },
  "durationTotal": { "start": "2026-07-04T00:00", "end": "2026-07-30T23:59:59" } }
```

`longName` → `name`, and `durationTotal` (the **whole** holiday, not the single
day) → `start` / `end` as dates. One entry appears per affected day, so
de-duplicate by range.

**Lessons — `gridEntries[]`:**

| WebUntis | app field |
|---|---|
| `ids[0]` | `period_id` |
| `duration.start` / `.end` (`2026-06-29T10:40`, local, no zone) | `date`, `start`, `end` |
| `type` | `type` |
| `status == "CANCELLED"` | `cancelled: true` |
| `status == "CHANGED"`, or any `positionN[].removed != null` | `substitution: true` |
| `positionN[].current` where `type == "SUBJECT"` | `subject` (`shortName`), `subject_long` (`longName`) |
| `positionN[].current` where `type == "TEACHER"` | `teacher` |
| `positionN[].current` where `type == "ROOM"` | `room` |
| `positionN[].current` where `type == "INFO"`, or `lessonInfo` | `info` |
| `layoutStartPosition`, `layoutWidth` | `layout_start`, `layout_width` |

`position1…position7` are not fixed roles — read the `type` inside each rather
than the position number. A substitution keeps the replacement in `current` and
the original in `removed`.

Note that a day out (`Ausflug`, 07:55–15:25) arrives as an ordinary
`gridEntries` row of `type: "EVENT"` with a narrow `layoutWidth`, **not** as a
background entry. It belongs in the grid as a narrow full-height column, which
is what WebUntis itself draws. Only `isFullDay` background entries — holidays —
get the slab treatment.

## Not the official platform API

Untis documents an official API at developer.untis.com
(`https://api.webuntis.com/WebUntis/api/rest/extern/v{version}/…`, note
`extern` rather than the `view` above). It is the wrong tool here twice over:
it authenticates an *application* through a Client Credentials flow, with
credentials provisioned via Untis and the school — there is no route to them
from a student's own login — and its documented resources (student, teacher,
class, room, subject, absences, exams, lessons, timetable v3, messaging) do not
include holidays, non-teaching days or the school year. The closest is
OneRoster `academicSessions`, which is terms and grading periods, not Ferien.

Worth knowing rather than worth using: since Untis' own supported surface has
no holiday story, neither of the options below is being superseded by it. The
per-endpoint schemas on that site render in JavaScript and were not read; if a
timetable-v3 day turns out to carry a holiday marker, it would be there, and
their credential-free sandbox is the quick way to check.

## The smaller alternative

If moving to the REST view API is more than it's worth, the older
`jsonrpc.do` API the backend may already speak has a `getHolidays` method
returning `{name, startDate, endDate}` directly. That gets holidays with no new
auth path and no reshaping — just no `period_id` and no layout numbers, which
the app treats as absent and works around.

Whichever path: treat every field as optional and drop what is missing rather
than substituting a guess. The REST view API is the web app's internal one, so
it can change shape without notice, and a silent wrong value is worse on this
screen than a missing one.
