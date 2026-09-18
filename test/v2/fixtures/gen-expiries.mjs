#!/usr/bin/env node
// Generates test/v2/fixtures/expiries.json: known instants 2026-2030 with the answers ExpiryCalendar must give,
// computed independently of the contract through node's Intl with the IANA zone America/New_York.
//
//   node test/v2/fixtures/gen-expiries.mjs          rewrite expiries.json
//   node test/v2/fixtures/gen-expiries.mjs --check  exit 1 when the committed file differs from a fresh run
//
// Nothing here shares code or arithmetic with src/v2/ExpiryCalendar.sol: local times come from Intl's tz database
// (not a compiled DST rule), dates from JS Date's proleptic calendar (not Hinnant's algorithm). The only shared input
// is the holiday list, which is data. test/v2/unit/ExpiryCalendar.t.sol deploys the calendar with exactly
// `holidayDayIndexes` below and checks every case.
//
// HOLIDAYS: NYSE full-day closures 2026-2028 as recorded by the F2-02 recon (R13) in callhouse
// ops/markets/v2-sources.json `nyseHolidays.<year>.fullDays` (callhouse branch v2, commit 77656e8; the recon cites
// https://www.nyse.com/trade/hours-calendars). Early closes (13:00) are ordinary session days (ADR-07) and are not
// listed. The recon's dayIndex values are copied too, and this script fails if any differs from floor(16:00 New York
// instant / 86400) as computed here. Nothing is seeded for 2029-2030: cases there test the DST rule and the weekday
// grid only, and one pins that an unseeded holiday (Good Friday 2029) is still a valid expiry until the admin adds it.

import {readFileSync, writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const OUT = join(dirname(fileURLToPath(import.meta.url)), 'expiries.json');
const DAY = 86_400;
const SEARCH_DAYS = 14;

const RECON_FULL_DAYS = [
  ['2026-01-01', 20454], ['2026-01-19', 20472], ['2026-02-16', 20500], ['2026-04-03', 20546],
  ['2026-05-25', 20598], ['2026-06-19', 20623], ['2026-07-03', 20637], ['2026-09-07', 20703],
  ['2026-11-26', 20783], ['2026-12-25', 20812],
  ['2027-01-01', 20819], ['2027-01-18', 20836], ['2027-02-15', 20864], ['2027-03-26', 20903],
  ['2027-05-31', 20969], ['2027-06-18', 20987], ['2027-07-05', 21004], ['2027-09-06', 21067],
  ['2027-11-25', 21147], ['2027-12-24', 21176],
  ['2028-01-17', 21200], ['2028-02-21', 21235], ['2028-04-14', 21288], ['2028-05-29', 21333],
  ['2028-06-19', 21354], ['2028-07-04', 21369], ['2028-09-04', 21431], ['2028-11-23', 21511],
  ['2028-12-25', 21543],
];

/*//////////////////////////////////////////////////////////////
                        NEW YORK TIME VIA INTL
//////////////////////////////////////////////////////////////*/

const formatter = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/New_York',
  hourCycle: 'h23',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  weekday: 'short',
  timeZoneName: 'shortOffset',
});

const ISO_WEEKDAY = {Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7};

/** New York wall clock at unix second `ts`. */
function ny(ts) {
  const p = Object.fromEntries(formatter.formatToParts(new Date(ts * 1000)).map((x) => [x.type, x.value]));
  const m = /^GMT([+-])(\d+)(?::(\d\d))?$/.exec(p.timeZoneName);
  if (!m) throw new Error(`unexpected zone name ${p.timeZoneName}`);
  const offset = (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 3600 + Number(m[3] ?? 0) * 60);
  return {
    date: `${p.year}-${p.month}-${p.day}`,
    hour: Number(p.hour),
    minute: Number(p.minute),
    second: Number(p.second),
    secondOfDay: Number(p.hour) * 3600 + Number(p.minute) * 60 + Number(p.second),
    weekday: ISO_WEEKDAY[p.weekday],
    weekdayName: p.weekday,
    offset,
    zone: offset === -14400 ? 'EDT' : offset === -18000 ? 'EST' : p.timeZoneName,
  };
}

/** The unix second of `date` `hh:mm:ss` New York. Refuses a wall time that does not exist or exists twice. */
function nyInstant(date, time) {
  const [y, mo, d] = date.split('-').map(Number);
  const [h, mi, s] = time.split(':').map(Number);
  const wall = Date.UTC(y, mo - 1, d, h, mi, s) / 1000;
  const hits = [-14400, -18000].map((off) => wall - off).filter((ts) => {
    const p = ny(ts);
    return p.date === date && p.hour === h && p.minute === mi && p.second === s;
  });
  if (hits.length !== 1) throw new Error(`${date} ${time} New York maps to ${hits.length} instants`);
  return hits[0];
}

/** Calendar arithmetic on a YYYY-MM-DD string (JS Date, proleptic Gregorian, no time zone involved). */
function addDays(date, n) {
  const [y, mo, d] = date.split('-').map(Number);
  return new Date(Date.UTC(y, mo - 1, d + n)).toISOString().slice(0, 10);
}

/*//////////////////////////////////////////////////////////////
                         EXPECTED BEHAVIOUR
//////////////////////////////////////////////////////////////*/

const holidays = new Set(RECON_FULL_DAYS.map(([date]) => date));

for (const [date, dayIndex] of RECON_FULL_DAYS) {
  const mine = Math.floor(nyInstant(date, '16:00:00') / DAY);
  if (mine !== dayIndex) throw new Error(`recon dayIndex for ${date} is ${dayIndex}, Intl says ${mine}`);
}

const weekdayOf = (date) => ny(nyInstant(date, '12:00:00')).weekday;
const isSessionDate = (date) => weekdayOf(date) <= 5 && !holidays.has(date);

/** A session date with no later session date in its ISO week (Monday-Sunday). */
function isWeeklyDate(date) {
  if (!isSessionDate(date)) return false;
  for (let k = 1; weekdayOf(addDays(date, k)) > weekdayOf(date); k++) {
    if (isSessionDate(addDays(date, k))) return false;
  }
  return true;
}

/** First session-day 16:00 close in (ts, ts + 14 days], weekly ones only when asked; 0 = the contract reverts. */
function nextClose(ts, weekly) {
  const from = ny(ts).date;
  for (let k = -1; k <= SEARCH_DAYS + 1; k++) {
    const date = addDays(from, k);
    const close = nyInstant(date, '16:00:00');
    if (close <= ts) continue;
    if (close > ts + SEARCH_DAYS * DAY) return 0;
    if (weekly ? isWeeklyDate(date) : isSessionDate(date)) return close;
  }
  return 0;
}

function expect(label, ts) {
  const p = ny(ts);
  const isClose = p.hour === 16 && p.minute === 0 && p.second === 0;
  return {
    label,
    ts,
    local: `${p.date} ${String(p.hour).padStart(2, '0')}:${String(p.minute).padStart(2, '0')}:${String(p.second).padStart(2, '0')} ${p.zone} ${p.weekdayName}`,
    isValidExpiry: isClose && isSessionDate(p.date),
    isWeekly: isClose && isWeeklyDate(p.date),
    isRegularSession: isSessionDate(p.date) && p.secondOfDay >= 9.5 * 3600 && p.secondOfDay < 16 * 3600,
    newYorkOffset: p.offset,
    nextDaily: nextClose(ts, false),
    nextWeekly: nextClose(ts, true),
  };
}

/*//////////////////////////////////////////////////////////////
                               CASES
//////////////////////////////////////////////////////////////*/

const cases = [];
const local = (date, time, label) => cases.push(expect(label, nyInstant(date, time)));
const utc = (iso, label) => cases.push(expect(label, Date.parse(iso) / 1000));
const close = (date, label) => local(date, '16:00:00', label);

// DST boundary weeks, 2026: every weekday close either side of each switch, and the switch Sundays.
for (let k = 0; k < 14; k++) {
  const date = addDays('2026-03-02', k);
  close(date, `2026 spring-forward fortnight (DST from Sun 2026-03-08)`);
}
for (let k = 0; k < 14; k++) {
  const date = addDays('2026-10-26', k);
  close(date, `2026 fall-back fortnight (EST from Sun 2026-11-01)`);
}

// DST switches 2027-2030: the closes around each switch and the exact switch instants (02:00 local).
const switches = [
  ['2027-03-14', '2027-11-07'],
  ['2028-03-12', '2028-11-05'],
  ['2029-03-11', '2029-11-04'],
  ['2030-03-10', '2030-11-03'],
];
for (const [spring, fall] of switches) {
  close(addDays(spring, -2), `Friday before spring-forward ${spring} (EST)`);
  close(addDays(spring, 1), `Monday after spring-forward ${spring} (EDT)`);
  close(addDays(fall, -2), `Friday before fall-back ${fall} (EDT)`);
  close(addDays(fall, 1), `Monday after fall-back ${fall} (EST)`);
}
for (const [spring, fall] of [['2026-03-08', '2026-11-01'], ...switches]) {
  utc(`${spring}T06:59:59Z`, `01:59:59 EST, last second before spring-forward ${spring}`);
  utc(`${spring}T07:00:00Z`, `03:00:00 EDT, first second after spring-forward ${spring}`);
  utc(`${fall}T05:59:59Z`, `01:59:59 EDT, last second before fall-back ${fall}`);
  utc(`${fall}T06:00:00Z`, `01:00:00 EST, first second after fall-back ${fall}`);
}

// Friday holidays move the weekly to Thursday.
close('2026-04-02', 'Thu before Good Friday 2026: weekly');
close('2026-04-03', 'Good Friday 2026: holiday');
close('2026-06-18', 'Thu before Juneteenth (Fri) 2026: weekly');
close('2026-06-19', 'Juneteenth 2026 (Fri): holiday');
close('2026-07-02', 'Thu before Independence Day observed (Fri 2026-07-03): weekly');
close('2026-07-03', 'Independence Day observed 2026 (Fri): holiday');
close('2027-03-25', 'Thu before Good Friday 2027: weekly');
close('2027-03-26', 'Good Friday 2027: holiday');
close('2027-06-17', 'Thu before Juneteenth observed (Fri 2027-06-18): weekly');
close('2028-04-13', 'Thu before Good Friday 2028: weekly');
close('2028-04-14', 'Good Friday 2028: holiday');
close('2029-03-30', 'Good Friday 2029: NOT seeded, still a valid weekly until the admin adds it');

// Monday holidays and the weeks around them.
close('2026-01-16', 'Fri before MLK Day 2026: weekly, next daily is Tuesday');
close('2026-01-19', 'MLK Day 2026 (Mon): holiday');
close('2026-09-04', 'Fri before Labor Day 2026: next daily is Tuesday');
close('2026-09-07', 'Labor Day 2026 (Mon): holiday');
close('2027-07-05', 'Independence Day observed 2027 (Mon): holiday');
close('2028-07-03', 'Mon 2028-07-03: early close, ordinary session day');
close('2028-07-04', 'Independence Day 2028 (Tue): holiday');

// Thanksgiving clusters.
close('2026-11-25', 'Wed before Thanksgiving 2026: next daily skips to Friday');
close('2026-11-26', 'Thanksgiving 2026: holiday');
close('2026-11-27', 'Day after Thanksgiving 2026: early close, weekly');
close('2027-11-24', 'Wed before Thanksgiving 2027');
close('2027-11-26', 'Day after Thanksgiving 2027: early close, weekly');
close('2028-11-23', 'Thanksgiving 2028: holiday');

// Christmas-New Year clusters.
close('2026-12-23', 'Wed 2026-12-23');
close('2026-12-24', 'Christmas Eve 2026 (Thu): early close, weekly because Christmas is Friday');
close('2026-12-25', 'Christmas 2026 (Fri): holiday');
close('2026-12-28', 'Mon 2026-12-28');
close('2026-12-31', 'New Year Eve 2026 (Thu): weekly because New Year is Friday');
close('2027-01-01', 'New Year 2027 (Fri): holiday');
close('2027-01-04', 'Mon 2027-01-04');
close('2027-12-23', 'Thu before Christmas observed (Fri 2027-12-24): weekly');
close('2027-12-24', 'Christmas observed 2027 (Fri): holiday');
close('2027-12-31', 'Fri 2027-12-31: session, New Year 2028 falls on Saturday and is not observed');
close('2028-12-22', 'Fri before Christmas 2028 (Mon): next daily is Tuesday');
close('2028-12-25', 'Christmas 2028 (Mon): holiday');

// Weekends.
close('2026-09-19', 'Saturday close instant');
close('2026-09-20', 'Sunday close instant');
local('2026-09-19', '12:00:00', 'Saturday midday');
local('2026-09-20', '23:59:59', 'Sunday last second');
local('2026-09-18', '16:00:00', 'Fri 2026-09-18 close: weekly, next daily Monday');

// Regular session edges, EDT (Wed 2026-09-16) and EST (Wed 2026-12-02).
for (const date of ['2026-09-16', '2026-12-02']) {
  for (const time of ['09:29:59', '09:30:00', '15:59:59', '16:00:00']) local(date, time, `session edge ${time}`);
}
local('2026-11-26', '12:00:00', 'Thanksgiving 2026 midday: no session');
local('2026-04-03', '10:00:00', 'Good Friday 2026 morning: no session');
local('2026-11-27', '14:00:00', 'Day after Thanksgiving 14:00: early close is ignored, still in session');
local('2026-12-24', '15:00:00', 'Christmas Eve 2026 15:00: early close is ignored, still in session');

// Instants that are not the 16:00:00 close.
local('2026-09-18', '15:59:59', 'Friday one second before the close');
local('2026-09-18', '16:00:01', 'Friday one second after the close');
local('2026-09-18', '17:00:00', 'Friday 17:00 EDT (the 16:00 EST instant on an EDT date)');
local('2026-12-04', '15:00:00', 'Friday 15:00 EST (the 16:00 EDT instant on an EST date)');
local('2026-12-04', '00:00:00', 'Friday midnight New York');
utc('2026-12-04T16:00:00Z', 'Friday 16:00 UTC');
utc('2026-12-04T00:00:00Z', 'Friday 00:00 UTC (Thursday 19:00 EST)');

/*//////////////////////////////////////////////////////////////
                               OUTPUT
//////////////////////////////////////////////////////////////*/

const out = {
  _readme:
    'GENERATED by test/v2/fixtures/gen-expiries.mjs (node Intl, America/New_York); do not edit by hand. ' +
    'Holidays: NYSE full-day closures 2026-2028 from callhouse ops/markets/v2-sources.json nyseHolidays ' +
    '(F2-02 recon R13, nyse.com hours-calendars). nextDaily / nextWeekly = 0 means nextExpiry reverts ' +
    '(nothing within 14 days). No holidays are seeded for 2029-2030.',
  searchDays: SEARCH_DAYS,
  holidayDates: RECON_FULL_DAYS.map(([date]) => date),
  holidayDayIndexes: RECON_FULL_DAYS.map(([, dayIndex]) => dayIndex),
  cases,
};
const text = `${JSON.stringify(out, null, 2)}\n`;

if (process.argv.includes('--check')) {
  let committed = '';
  try {
    committed = readFileSync(OUT, 'utf8');
  } catch {}
  if (committed !== text) {
    console.error(`${OUT} is stale: run node test/v2/fixtures/gen-expiries.mjs`);
    process.exit(1);
  }
  console.log(`${OUT} is up to date (${cases.length} cases)`);
} else {
  writeFileSync(OUT, text);
  console.log(`wrote ${OUT} (${cases.length} cases)`);
}
