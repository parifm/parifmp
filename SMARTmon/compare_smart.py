#!/usr/bin/env python3
"""
Prioritized SMART matrix (Backblaze framework) across N collection snapshots.
SAS->SMART mapping:
  187 (read/write uncorrected) -> read_uncorr / write_uncorr
    5 (grown defect list)      -> gdl
  188 (non-medium errors)      -> nme
  198 (verify uncorrected)     -> verify_uncorr
  197 proxy (rereads/rewrites) -> read_rereads / write_rereads
  199 proxy (SAS phy errors)   -> phy_invalid_dword / phy_running_disp /
                                   phy_loss_sync / phy_reset

Input is the per-drive TSV written by smart_to_tsv.pl on the collector host
(one row per drive, columns selected by name), not the raw smartctl log.
Normally ONE file holding every collection:   perl smart_to_tsv.pl logs/*.log
Each row carries run_epoch — the earliest drive stamp in the log it came from
— and that is what defines a run, so it makes no difference whether the rows
arrive in one TSV or several. Logs whose run_epochs fall within RUN_MERGE_S of
each other are the same run (the same collection converted twice, say) and are
merged; a serial that then appears twice in one run keeps the row with the
fewest missing values, then the last one read. The raw .log is kept alongside
as the source of truth.

Drives keyed by serial number (not host/path) — correct across reboots.
Listed: drives with any 187R / 187W / 198V at all (an uncorrectable error is never
wear — a drive carrying eleven of them flat for months is as much a candidate as one
that just logged its first), drives whose 188N grew across the window, and drives
whose GDL grew in a burst. GDL is the one Fatal Five counter that needs growth to
mean anything: a slowly growing defect list is normal wear, so a lone step never
lists a drive; 2+ increases within 48 h, or a streak of them, do.
Every block the collector dumped is kept — nothing is excluded. Blocks the SAS
parser had nothing to read from (NVMe boot drives, HBA logical volumes; smart_ok
= 0 in the TSV) are counted up front and flagged on -l lookups: their metrics
read 0 by absence, not by health. They can never rank (nothing to grow), so the
ranked list is unaffected either way.
GDLburst flags a drive whose defect list keeps growing collection after
collection: n(total) = n collections whose GDL exceeded the last known value
and the GDL gained across them, most recent streak, 0 if none (the matrix
legend has the exact rule).
OSDs already out of service are excluded from the ranked table but
their trajectories are still tracked.

Usage:
  perl smart_to_tsv.pl logs/*.log | python3 compare_smart.py
  perl smart_to_tsv.pl logs/*.log > all.tsv && python3 compare_smart.py all.tsv

  With no path the TSV is read from stdin; '-' names stdin explicitly and may
  be mixed with files. Several inputs are simply concatenated. Runs are always
  in chronological order.

  Labels are the run's start date in the COLLECTOR's zone, so they match the
  collector's file names wherever the report is run:
    run started Mon May  4 09:31 2026 PDT  -> May04
    run started Wed Sep  9 22:27 2026 PDT  -> Sep09-2227   (two runs that day)
  Two runs on the same day are told apart by appending -HHMM. The zone is not
  configured anywhere: smartctl prints it on every "Local Time is:" line, the
  Perl carries it into the TSV (tz, tz_offset), and each run is rendered in the
  zone its own log recorded — PDT in summer, PST in winter, EDT for a site in
  the east, with no flag, env var, or tz database involved.

  Likewise the cluster name in the banners comes from the hostnames: the stem
  (hostname minus its trailing number) that most hosts share —backend001..286
  -> BACKEND — plus the host count; hosts
  with another stem (a mgr node whose disks the collector also dumps) are
  counted as "+ N other", never dropped.

  Options:
    -t   print only the ranked Fatal Five list section — banner, legend, list — as a table
    -c   the same section, same columns and cells, as CSV (non-data lines are # comments)
         Exactly that: no progress lines, no other sections, no stderr chatter.
    -a   fold drives no longer present in the latest snapshot (replaced/removed) into that
         same ranked list too, marked via a 'Last seen' column; combinable with -t / -c
    -l CRITERIA
         look up specific drives instead of the whole report. CRITERIA is a comma-separated
         list of hostnames, serials, and/or bare device paths (e.g. /dev/sdai — NOT the
         combined 'host,/dev/sdai' display string; that can't survive the comma split, since
         comma is also the criteria separator). Several values of the SAME type OR together
         as a plain list (several hosts, several serials, ...); mixing TYPES ANDs them into
         one narrower filter instead — hostname+path means that path on that host, +serial
         means that serial on that host, all three means only a reading where they all
         co-occurred. Hostname(s) alone print that host's slice of the ranked Fatal Five
         list (CSV + table, or just one — see -t / -c); anything involving a serial or
         device path prints that drive's most recent SMART reading instead (add -a to print
         every collection it appears in, not just the latest). -l with no CRITERIA is an
         error (-h / --help is the usage text); criteria matching nothing (alone, or never
         co-occurring together) is an error too, not a silent fallback.
    -r   change alert, for cron: the ranked Fatal Five list restricted to drives with a NEW
         problem signal between the two most recent runs (the drive present in both):
         187R / 187W / 198V / 188N increased, or a GDL burst whose latest step is the newest
         run — a lone GDL step is not a signal. When no drive qualifies, nothing at all is printed — not a
         banner, not a progress line — and the exit status is 0, so `-c -r ... | mail` only
         sends mail when something moved. Cells keep their usual meaning (window delta),
         and the Fatal Five cells that changed between those two runs are flanked —
         [value] in the table, value* in the CSV (same cells, marker only; nothing but the
         Fatal Five is ever marked). CSV + table, or just one with -t / -c. Not with -l.

  One run is enough for the list of drives carrying an uncorrectable error (187R / 187W /
  198V present), their scores minus the growth terms, -l lookups and the per-drive history.
  188N growth, GDL bursts, -r, Cyc and the N(+D) deltas need at least two runs and simply
  read as absent until then; the banners say so. Needs pandas.
"""
import sys, os, csv, io
import pandas as pd
from datetime import datetime, timezone, timedelta   # fixed-offset zones only: stdlib on 3.6, no tzdata needed

def is_smart_tsv(path):
    """True if the file starts with the smart_to_tsv.pl header row."""
    try:
        with open(path, 'r', errors='replace') as f:
            return f.readline().startswith('serial\t')
    except OSError:
        return False

RUN_MERGE_S  = 1     # logs whose run_epochs are this close are the same run

args  = sys.argv[1:]
flags = [a for a in args if a in ('-t', '-c')]
args  = [a for a in args if a not in ('-t', '-c')]
if len(set(flags)) > 1:
    print("ERROR: -t and -c are mutually exclusive", file=sys.stderr)
    sys.exit(1)
mode = flags[0][1] if flags else None       # 't' | 'c' | None (full report)

ALL_MODE = '-a' in args                     # fold departed drives into the ranked matrix too
args = [a for a in args if a != '-a']

RECENT_MODE = '-r' in args                  # change alert: only drives with a new problem signal in the latest interval; silent if none
args = [a for a in args if a != '-r']

FORMATS = ['csv' if mode == 'c' else 'table'] if mode else ['csv', 'table']   # what -l / -r print, in this order

def pop_flag_value(args, flag, is_value=lambda v: True):
    """Extract `flag VALUE` from args -> (value, remaining_args). `is_value(token)` lets the
    caller reject a token that only looks like a value (used so -l declines an existing file
    — that's the TSV input, not criteria — instead of silently swallowing it and leaving the
    script to block reading stdin for a file the user actually named).

    None  = flag not given at all.
    ''    = flag given with nothing usable after it (end of args, next token looks like
            another flag, or is_value() rejects it) — the caller decides what that means.
    else  = the value that followed it."""
    if flag not in args:
        return None, args
    i = args.index(flag)
    if i + 1 >= len(args) or args[i + 1].startswith('-') or not is_value(args[i + 1]):
        return '', args[:i] + args[i + 1:]
    return args[i + 1], args[:i] + args[i + 2:]

L_CRITERIA_RAW, args = pop_flag_value(args, '-l', is_value=lambda v: v != '-' and not os.path.isfile(v))
if L_CRITERIA_RAW == '':                    # -l with nothing usable after it (or followed straight by the TSV)
    print("ERROR: -l needs CRITERIA (comma-separated hostnames / serials / device paths); -h for usage",
          file=sys.stderr)
    sys.exit(1)
L_TOKENS = [t.strip() for t in L_CRITERIA_RAW.split(',') if t.strip()] if L_CRITERIA_RAW else []
if L_CRITERIA_RAW and not L_TOKENS:
    print("ERROR: -l given but no usable criteria after splitting on comma", file=sys.stderr)
    sys.exit(1)
if RECENT_MODE and L_TOKENS:
    print("ERROR: -r and -l are mutually exclusive (-r is a fleet-wide change alert, -l a targeted lookup)",
          file=sys.stderr)
    sys.exit(1)

def info(*a, **k):
    """Progress and context — everything that is not the report itself.
    Silent under -t / -c / -l / -r, which promise their own output and nothing else
    (-r in particular must be able to print nothing whatsoever)."""
    if not mode and not L_TOKENS and not RECENT_MODE:
        print(*a, **k)

if any(a in ('-h', '--help') for a in args) or (not args and not L_TOKENS and sys.stdin.isatty()):
    print(f"Usage: perl smart_to_tsv.pl logs/*.log | {sys.argv[0]} [-t | -c] [-a] [-r] [-l CRITERIA]",
          file=sys.stderr)
    print(f"       {sys.argv[0]} [-t | -c] [-a] [-r] [-l CRITERIA] all.tsv [more.tsv ...]      ('-' = stdin)",
          file=sys.stderr)
    print("       -t / -c: only the ranked Fatal Five list section, as a table / as CSV", file=sys.stderr)
    print("       -a: also fold drives no longer present in the latest snapshot into that list", file=sys.stderr)
    print("           (or, with -l on a serial/device path: print every collection, not just the latest)",
          file=sys.stderr)
    print("       -l CRITERIA: look up drive(s) instead of the report — comma-separated hostnames,",
          file=sys.stderr)
    print("           serials, and/or bare device paths (/dev/sdX, not 'host,/dev/sdX'); combines with -t / -c",
          file=sys.stderr)
    print("       -r: change alert — only drives with a new problem signal between the two most recent runs",
          file=sys.stderr)
    print("           (187R/187W/198V/188N up, or a GDL burst stepping); prints NOTHING at all when there are",
          file=sys.stderr)
    print("           none (exit 0). Combines with -t / -c", file=sys.stderr)
    print("       The TSV is smart_to_tsv.pl over one or more collection logs; rows are grouped", file=sys.stderr)
    print(f"       into runs by their run_epoch column (within {RUN_MERGE_S}s = same run). One run lists the",
          file=sys.stderr)
    print("       drives carrying uncorrectables; growth signals (188N, GDL bursts, -r) need two or more.",
          file=sys.stderr)
    sys.exit(1)

# No path means the TSV arrives on stdin (so the Perl can pipe straight in);
# '-' says so explicitly and can sit alongside file paths. stdin is read whole
# so its header can be checked like a file's.
FILES = []
for path in (args or ['-']):
    if path == '-':
        text = sys.stdin.read()
        if not text.strip():
            print("ERROR: nothing arrived on stdin — the producer (perl smart_to_tsv.pl ...) wrote no "
                  "output; see its message above", file=sys.stderr)
            sys.exit(1)
        if not text.startswith('serial\t'):
            print("ERROR: stdin is not a smart_to_tsv.pl TSV (no 'serial<TAB>...' header row)",
                  file=sys.stderr)
            sys.exit(1)
        FILES.append(io.StringIO(text))
        continue
    if not os.path.isfile(path):
        print(f"ERROR: file not found: {path}", file=sys.stderr)
        sys.exit(1)
    if not is_smart_tsv(path):
        stem = os.path.splitext(path)[0]
        print(f"ERROR: {path} is not a smart_to_tsv.pl TSV. Generate it with:\n"
              f"       perl smart_to_tsv.pl {path} > {stem}.tsv", file=sys.stderr)
        sys.exit(1)
    FILES.append(path)

# Serials already removed from service — excluded from ranked output but
# still tracked in per-drive history section.
OUT_SERIALS = {
}


NUMERIC_COLS = (
    'poh', 'gdl', 'nme',
    'read_corrected',   'read_rereads',   'read_uncorr',
    'write_corrected',  'write_rereads',  'write_uncorr',
    'verify_corrected', 'verify_rereads', 'verify_uncorr',
    'phy_invalid_dword', 'phy_running_disp', 'phy_loss_sync', 'phy_reset',
)
STRING_COLS   = ('serial', 'host', 'dev', 'path', 'product', 'tz')
FATAL_FIVE     = ['read_uncorr', 'write_uncorr', 'verify_uncorr', 'gdl', 'nme']
PRESENCE_GATED = ['read_uncorr', 'write_uncorr', 'verify_uncorr']   # 187R 187W 198V: present at all = a problem
EVENT_COUNTERS = PRESENCE_GATED + ['nme']                            # + 188N: an increase is an event (-r)
DELTA_COLS     = FATAL_FIVE + ['read_rereads', 'write_rereads']


def load_tsv(path):
    """One smart_to_tsv.pl file -> DataFrame, one row per drive.

    smart_to_tsv.pl always writes a number in NUMERIC_COLS (0 when the metric
    is absent), so those are read straight to int64 — a blank there means a
    broken file and read_csv will say so loudly. Only temp, collected_epoch and
    the zone pair (tz, tz_offset — blank together when a drive printed no
    "Local Time is:") may be blank; they read as NaN. No quoting: the TSV is
    written raw."""
    return pd.read_csv(path, sep='\t', quoting=csv.QUOTE_NONE,
                       keep_default_na=False, na_values=[''],
                       dtype={**{c: str for c in STRING_COLS},
                              **{c: 'int64' for c in NUMERIC_COLS}})


n_files = sum(isinstance(p, str) for p in FILES)
info("Loading " + " + ".join(([f"{n_files} file(s)"] if n_files else [])
                             + (["stdin"] if len(FILES) > n_files else [])) + "...", flush=True)
df = pd.concat([load_tsv(p) for p in FILES], ignore_index=True)
df['order'] = range(len(df))          # read order: argument order, then row order

missing_cols = [c for c in ('run_epoch', 'tz', 'tz_offset', 'smart_ok') if c not in df.columns]
if missing_cols:
    print(f"ERROR: no {' / '.join(missing_cols)} column — this TSV predates the current schema "
          "(run_epoch, then tz/tz_offset/smart_ok). Regenerate it with the current smart_to_tsv.pl:\n"
          "       perl smart_to_tsv.pl <log> [more logs] > file.tsv", file=sys.stderr)
    sys.exit(1)

# ── Blocks without SAS SMART data ─────────────────────────────────────────────
# The collector dumps every block device it finds, and every one stays in. NVMe boot/DB
# drives and HBA logical volumes come through as smartctl blocks the SAS parser has
# nothing to read from, so their metrics are 0 by absence, not by health. They are
# counted and named here, and -l flags them, so a spotless-looking 0 isn't taken for a
# clean bill; they can never rank (there is nothing to grow), so the ranked list is the
# same either way.
no_smart = df[df['smart_ok'] == 0]
if len(no_smart):
    info(f"\n{len(no_smart)} device row(s) carry no SAS SMART data (kept; metrics read 0 by absence — "
         "flagged on -l lookups):")
    for prod, g in no_smart.groupby('product'):
        devs = sorted(g['dev'].unique())
        info(f"  {len(g)}× product {prod!r}: {', '.join(devs[:4])}{' ...' if len(devs) > 4 else ''} "
             f"on {g['host'].nunique()} host(s)")
if not (df['smart_ok'] == 1).any():
    print("ERROR: no drive block carried SAS SMART data — is this a SAS cluster? (SATA and NVMe smartctl "
          "output is not parsed by smart_to_tsv.pl)", file=sys.stderr)
    sys.exit(1)

no_run = df['run_epoch'].isna()
if no_run.any():
    info(f"WARNING: {no_run.sum()} row(s) with no run_epoch (their log had no drive stamps at all) "
         "dropped", file=sys.stderr)
    df = df[~no_run]
df['run_epoch'] = df['run_epoch'].astype('int64')

# ── Runs ─────────────────────────────────────────────────────────────────────
# smart_to_tsv.pl stamps every row with run_epoch — the earliest drive stamp in
# the log it came from — so a run is a run_epoch value, whatever file the rows
# arrived in. Logs whose run_epochs are within RUN_MERGE_S of each other are the
# same run (the same collection converted twice, say); their rows are pooled
# and de-duplicated below.
run_of, run_id, prev = {}, -1, None
for e in sorted(df['run_epoch'].unique()):
    if prev is None or e - prev > RUN_MERGE_S:
        run_id += 1
    run_of[e], prev = run_id, e
df['snap'] = df['run_epoch'].map(run_of)
run_start  = df.groupby('snap')['run_epoch'].min()
# One run is a valid input: the presence gate (187R/187W/198V) and -l need only the latest
# reading. What needs a second run — 188N growth, GDL bursts, -r, Cyc, the N(+D) deltas —
# simply evaluates to nothing, and the banners say so.
SINGLE_RUN = len(run_start) == 1

# ── The collector's zone, per run, from the log itself ───────────────────────
# smartctl prints the zone abbreviation on every "Local Time is:" line and the Perl
# carries it through as tz (the abbreviation) and tz_offset (the UTC offset in seconds
# it applied). A run's zone is the value most of its rows agree on — one drive with a
# garbled clock line can't move the label. Fixed-offset zones are all that's needed:
# each run is rendered at the offset its own log recorded, so DST is already accounted
# for run by run, and no tz database, flag, or env var enters into it.
def run_consensus(col):
    return df.dropna(subset=[col]).groupby('snap')[col].agg(lambda s: s.mode().iloc[0])
run_offset = run_consensus('tz_offset').reindex(run_start.index)
run_tzname = run_consensus('tz').reindex(run_start.index)
if run_offset.isna().any():
    bad = list(run_start.index[run_offset.isna()])
    print(f"ERROR: run(s) {bad} carry no zone (tz/tz_offset blank on every row) — rows from a TSV "
          "made by an older smart_to_tsv.pl mixed in? Regenerate every TSV with the current one.",
          file=sys.stderr)
    sys.exit(1)
RUN_TZ = {snap: timezone(timedelta(seconds=int(run_offset[snap])), str(run_tzname[snap]))
          for snap in run_start.index}

# Labels: %b%d of the run start in the COLLECTOR's zone, so they match the
# collector's own dates (and file names) wherever the report is run — a run at
# 22:27 Pacific is that day, not the next one in Eastern. Two runs on one day
# get -HHMM appended so nothing collapses.
starts = [datetime.fromtimestamp(int(e), RUN_TZ[snap]) for snap, e in run_start.items()]
labels = [f"{t.strftime('%b')}{t.day:02d}" for t in starts]
dups   = {l for l in labels if labels.count(l) > 1}
LABELS_ORDERED = [f"{l}-{t:%H%M}" if l in dups else l for l, t in zip(labels, starts)]
df['label'] = df['snap'].map(dict(zip(run_start.index, LABELS_ORDERED)))

# ── Cluster identity, from the log itself ─────────────────────────────────────
# The banners name the cluster by the stem most of its hostnames share — hostname
# minus its trailing number and separators: backend001..286 -> BACKEND. The most common stem rather than a strict
# common prefix, so one odd host (the mgr node, whose disks the collector also
# dumps) shows up as "+ 1 other" instead of shortening the name.
HOSTS  = sorted(df['host'].unique())
_stems = pd.Series([h.rstrip('0123456789').rstrip('-_.') for h in HOSTS])
_stem  = _stems.mode().iloc[0]
_n_in  = int((_stems == _stem).sum())
if _n_in > 1 or len(HOSTS) == 1:
    CLUSTER_DESC = (f"{_stem.upper()} ({_n_in} host{'s' if _n_in != 1 else ''}"
                    + (f" + {len(HOSTS) - _n_in} other)" if _n_in < len(HOSTS) else ")"))
else:
    CLUSTER_DESC = f"{len(HOSTS)} hosts (no shared hostname stem)"

# ── Duplicates within a run ──────────────────────────────────────────────────
# Same serial twice in one run: keep the row with the fewest missing values
# (blank temp / collected_epoch, unknown product); on a tie, the last one read.
n_before = len(df)
data_cols = [c for c in df.columns if c not in ('order', 'run_epoch', 'snap', 'label')]
df['_nmiss'] = df[data_cols].isna().sum(axis=1) + (df['product'] == '?').astype(int)
df = (df.sort_values(['snap', 'serial', '_nmiss', 'order'],
                     ascending=[True, True, True, False], kind='stable')
        .drop_duplicates(['snap', 'serial'], keep='first')
        .drop(columns=['_nmiss', 'order'])
        .sort_values(['serial', 'snap'], kind='stable')
        .reset_index(drop=True))
n_dupes = n_before - len(df)

for snap, lbl, t in zip(run_start.index, LABELS_ORDERED, starts):
    info(f"  {lbl}: {(df['snap'] == snap).sum()} unique serials  "
         f"(run started {t:%Y-%m-%d %H:%M:%S %Z})", flush=True)
if n_dupes:
    info(f"  {n_dupes} duplicate serial row(s) within a run resolved "
         f"(fewest missing values, then last read)")
info(f"\nTotal unique serials seen across all snapshots: {df['serial'].nunique()}")

# Drive inventory changes between first and last snapshot
first_label = LABELS_ORDERED[0]
last_label  = LABELS_ORDERED[-1]
SNAPS_DESC  = (f"1 snapshot ({first_label})" if SINGLE_RUN
               else f"{len(LABELS_ORDERED)} snapshots ({first_label} -> {last_label})")
snap_first  = df[df['snap'] == 0].set_index('serial')
snap_last   = df[df['snap'] == len(LABELS_ORDERED) - 1].set_index('serial')
gone = sorted(set(snap_first.index) - set(snap_last.index))
new  = sorted(set(snap_last.index)  - set(snap_first.index))
if SINGLE_RUN:
    info(f"\nNOTE: one collection run ({first_label}). Listed = drives carrying an uncorrectable error now; "
         "188N growth, GDL bursts, -r, Cyc and the N(+D) deltas need a second run.")
else:
    info(f"\nSerials in {first_label} but NOT in {last_label} (removed/replaced): {len(gone)}")
    for s in gone:
        d = snap_first.loc[s]
        info(f"  {s}  was at {d['path']}  {d['product']}  "
             f"GDL={d['gdl']} 187R={d['read_uncorr']} 187W={d['write_uncorr']}")
    info(f"\nSerials in {last_label} but NOT in {first_label} (new): {len(new)}")
    for s in new:
        d = snap_last.loc[s]
        info(f"  {s}  now at {d['path']}  {d['product']}  POH={d['poh']}")


# ── Per-serial trajectory, column-wise ────────────────────────────────────────
# df is sorted (serial, snap), so within each serial head(1) / tail(1) are the
# first and last snapshots in which that drive is PRESENT — not the global
# first and last. (Not .first()/.last(): those are per-column first-non-null
# and would borrow a later temp for a drive whose first row has none.)
g     = df.groupby('serial', sort=True)
first = g.head(1).set_index('serial')
last  = g.tail(1).set_index('serial')

# Window delta: last present minus first present.
delta = last[DELTA_COLS] - first[DELTA_COLS]

# Growth cycles: consecutive snapshots with the drive present in both — a gap
# is skipped, not bridged — where 187R, 187W, 198V or 188N increased. The score's
# Cyc term and -r's trigger; a lone GDL step counts for neither (see the gate).
prev = g[EVENT_COUNTERS + ['snap']].shift(1)
grew_event = (((df['snap'] - prev['snap']) == 1)
              & (df[EVENT_COUNTERS] > prev[EVENT_COUNTERS]).any(axis=1))
growth_cycles = grew_event.groupby(df['serial']).sum().astype(int)

# Per-drive rows on demand (Section 1 history, -l lookups): the groupby already
# holds every serial's row positions, so this is a slice — not a dict of 7,700
# one-drive frames built up front.
def drive_rows(serial):
    return g.get_group(serial)

# ── GDL bursts, column-wise ──────────────────────────────────────────────────
# Every collection is a reading. An increase event is a reading whose GDL is
# above the drive's last known GDL — the previous reading, whatever day it fell
# on — so ten collections in a day can yield several events. A streak is a run
# of events on the same or adjacent calendar dates (the run's own zone): a gap
# of two or more dates between events means a full day passed with no increase
# or no run, which ends the streak. Two events qualify (adjacent-date events are
# within 48 h); a lone jump is not a burst. Latest qualifying streak wins.
# bursts_all: serial -> (count, GDL gained, snap of the streak's last event) for
# drives that have one; that last snap is how -r knows a burst is still stepping.
# Done on the event rows as columns — a per-drive Python loop here (itertuples
# over 7,700 one-drive frames) cost 7.8 s of an 8.3 s run.
prev_gdl = g['gdl'].shift(1)
ev = df.loc[df['gdl'] > prev_gdl, ['serial', 'snap', 'gdl', 'run_epoch']].copy()   # df order = (serial, snap)
bursts_all = {}
if len(ev):
    ev['delta'] = (ev['gdl'] - prev_gdl[ev.index]).astype(int)
    day_of = {(e, s): datetime.fromtimestamp(int(e), RUN_TZ[s]).date().toordinal()
              for e, s in ev[['run_epoch', 'snap']].drop_duplicates().itertuples(index=False)}
    ev['day'] = [day_of[(e, s)] for e, s in zip(ev['run_epoch'], ev['snap'])]
    new_streak   = (ev['serial'] != ev['serial'].shift(1)) | ((ev['day'] - ev['day'].shift(1)) > 1)
    ev['streak'] = new_streak.cumsum()
    streaks = (ev.groupby('streak')
                 .agg(serial=('serial', 'first'), count=('gdl', 'size'),
                      total=('delta', 'sum'), last_snap=('snap', 'last')))
    streaks = streaks[streaks['count'] >= 2].groupby('serial').tail(1)   # streak ids are chronological
    bursts_all = {r.serial: (int(r.count), int(r.total), int(r.last_snap)) for r in streaks.itertuples()}

# ── The gate ─────────────────────────────────────────────────────────────────
# What indicates a problem differs by counter:
#   187R / 187W / 198V  present at all. An uncorrectable error is never wear, so a drive
#                       carrying eleven of them flat for months is as much a candidate as
#                       one that just logged its first — the growth-only gate this
#                       replaces missed exactly those.
#   GDL                 only a burst — 2+ increases within 48 h, or a streak of them
#                       (gdl_burst). A slowly growing defect list is normal wear.
#                       growth across the window.
#   188N                SAS non-medium errors are a loose proxy for ATA 188, mostly noise.
# No minimum number of snapshots: one reading with an uncorrectable is enough.
ue_present   = (last[PRESENCE_GATED] > 0).any(axis=1)
nme_grew     = delta['nme'] > 0
gdl_bursting = pd.Series(last.index.isin(list(bursts_all)), index=last.index)
is_cand      = ue_present | nme_grew | gdl_bursting
cand_serials = sorted(is_cand[is_cand].index)


# Score weights. score_frame() computes from these and SCORE_EXPLANATION prints
# them, so the report header cannot drift from the arithmetic. Each counter is
# scored on the quantity its gate is about: uncorrectables on the count the drive
# carries now (an old one is as real as a new one), GDL on what the latest burst
# gained (slow growth is wear and scores nothing), 188N on its window increase.
UE_WEIGHTS = {                    # per uncorrectable error in the latest reading
    'write_uncorr':  30,          # SMART 187W — worst single indicator
    'read_uncorr':   25,          # SMART 187R
    'verify_uncorr': 30,          # SMART 198
}
GDL_BURST_WEIGHT = 10             # per defect gained in the most recent GDL burst (0 without one)
NME_WEIGHT       = 1              # per unit of 188N increase across the window (often noisy)
CYCLE_WEIGHT = 40                 # per snapshot interval in which 187R, 187W, 198V or 188N increased
COMBO_BONUS  = 20                 # uncorrectable errors together with GDL > 0 in the latest snapshot
INFANT_BONUS, INFANT_HOURS = 50,  8760     # uncorrectable errors on a drive under 1 year old
YOUNG_BONUS,  YOUNG_HOURS  = 20, 17520     # ... under 2 years old

def score_frame(last, delta, burst_total, growth_cycles):
    """Backblaze-priority urgency score, higher = more urgent, for every serial at once."""
    s = (sum(last[k] * w for k, w in UE_WEIGHTS.items())
         + burst_total * GDL_BURST_WEIGHT
         + delta['nme'] * NME_WEIGHT
         + growth_cycles * CYCLE_WEIGHT)
    has_ue = (last['read_uncorr'] + last['write_uncorr'] + last['verify_uncorr']) > 0
    poh    = last['poh']
    s = s + (has_ue & (last['gdl'] > 0)) * COMBO_BONUS
    s = s + (has_ue & (poh < INFANT_HOURS)) * INFANT_BONUS
    s = s + (has_ue & (poh >= INFANT_HOURS) & (poh < YOUNG_HOURS)) * YOUNG_BONUS
    return s

W = UE_WEIGHTS
SCORE_EXPLANATION = f"""Score = {W['write_uncorr']}×187W + {W['read_uncorr']}×187R + {W['verify_uncorr']}×198V      (latest counts — every uncorrectable error counts, however old)
      + {GDL_BURST_WEIGHT}×GDLburst total (defects gained in the most recent burst; 0 without one — slow GDL growth is wear)
      + {NME_WEIGHT}×Δ188N (increase across the observation window)
      + {CYCLE_WEIGHT} per snapshot interval in which 187R, 187W, 198V or 188N increased (Cyc)
      + {COMBO_BONUS} if the latest snapshot shows an uncorrectable error (187R, 187W or 198V) together with GDL > 0
      + {INFANT_BONUS} if it shows an uncorrectable error and POH < {INFANT_HOURS:,} h (1 year), else + {YOUNG_BONUS} if POH < {YOUNG_HOURS:,} h (2 years)"""

burst_total = (pd.Series({s: b[1] for s, b in bursts_all.items()}, dtype='int64')
                 .reindex(last.index, fill_value=0))
scores = score_frame(last, delta, burst_total, growth_cycles)


# ── Candidate summary frame ───────────────────────────────────────────────────
# One row per candidate drive: its last-present snapshot (path, product, POH,
# every metric), the window deltas as d_<metric>, growth cycles, score, and
# whether it is still installed. The report sections read this frame directly.
cand_mask = df['serial'].isin(cand_serials)

cycle_labels = {}
for serial, snap in df.loc[grew_event & cand_mask, ['serial', 'snap']].itertuples(index=False):
    cycle_labels.setdefault(serial, []).append(
        f"{LABELS_ORDERED[snap - 1]}->{LABELS_ORDERED[snap]}")

cand = last.loc[cand_serials].copy()
for k in DELTA_COLS:
    cand['d_' + k] = delta.loc[cand_serials, k]
cand['growth_cycles']    = growth_cycles.loc[cand_serials]
cand['growth_intervals'] = [' '.join(cycle_labels.get(s, [])) for s in cand_serials]
cand['score']            = scores.loc[cand_serials].astype(int)
cand['present_last']     = cand.index.isin(snap_last.index)
cand['out']              = cand.index.isin(list(OUT_SERIALS))

bursts = [bursts_all.get(s) for s in cand_serials]
cand['gdl_burst_count'] = pd.array([b[0] if b else None for b in bursts], dtype='Int64')
cand['gdl_burst_total'] = pd.array([b[1] if b else None for b in bursts], dtype='Int64')

info(f"\nDrives qualifying across {SNAPS_DESC} "
     f"(187R/187W/198V present: {int((ue_present & is_cand).sum())}, 188N grew: {int(nme_grew.sum())}, "
     f"GDL burst: {int(gdl_bursting.sum())}; union): {len(cand)}")

# Rank candidates.
# Excluded from the ranked matrix:
#   - serials in OUT_SERIALS (already pulled from service)
#   - serials absent from the most recent snapshot (drive no longer installed —
#     replaced or removed; not actionable). These are reported separately.
BY_SCORE  = dict(by=['score', 'serial'], ascending=[False, True])   # serial (the index) breaks ties
ranked    = cand[ cand['present_last'] & ~cand['out']].sort_values(**BY_SCORE)
departed  = cand[~cand['present_last'] & ~cand['out']].sort_values(**BY_SCORE)
out_shown = [s for s in OUT_SERIALS if s in cand.index]

# -a: the ranked matrix draws from ranked+departed together (re-sorted by score) instead
# of ranked alone; matrix_rows() marks the departed ones via 'Last seen' (see MX_HEADERS).
MATRIX_SOURCE = pd.concat([ranked, departed]).sort_values(**BY_SCORE) if ALL_MODE else ranked

info(f"  ranked (still present in {last_label}): {len(ranked)}")
if len(departed):
    info(f"  no longer present in {last_label} (replaced/removed): {len(departed)}")
if out_shown:
    info(f"  already out of service: {len(out_shown)}")

# ── TABLE RENDERING HELPERS ───────────────────────────────────────────────────

def col_widths(headers, rows):
    """Width of each column = widest cell (header included)."""
    return [max(len(str(headers[i])), *(len(str(r[i])) for r in rows)) if rows
            else len(str(headers[i])) for i in range(len(headers))]


def render_row(cells, widths, aligns, gap=1):
    pad = ' ' * gap
    return pad.join(f"{str(cells[i]):{aligns[i]}{widths[i]}}"
                    for i in range(len(cells))).rstrip()


def rule(widths, gap=1):
    return (' ' * gap).join('-' * w for w in widths)


def fmt_delta(val, current):
    """Render 'current(+delta)' when the metric moved, else bare current."""
    if val > 0:  return f"{current}(+{val})"
    if val < 0:  return f"{current}({val})"
    return f"{current}"


def temp_or(v, blank):
    """Temperature cell — the TSV leaves temp blank when smartctl had none."""
    return blank if pd.isna(v) else int(v)


def burst_cell(r):
    """GDLburst table cell: n(total), or 0 when the drive has had no burst."""
    return '0' if pd.isna(r.gdl_burst_count) else f"{int(r.gdl_burst_count)}({int(r.gdl_burst_total)})"


def csv_cell(v):
    s = str(v)
    return f'"{s}"' if (',' in s or '"' in s) else s


def fmt_say(fmt):
    """print-like function for banner/legend lines: plain under 'table', a '# '-prefixed
    comment line under 'csv' (blank line -> bare '#'), so a CSV block still parses as one
    file with the data rows undecorated."""
    return print if fmt == 'table' else (lambda line='': print(f"# {line}" if line else "#"))


def print_rows(fmt, headers, aligns, rows):
    """The data block itself (no banner/legend) as a fixed-width table or as bare CSV."""
    if fmt == 'table':
        w = col_widths(headers, rows)
        print(render_row(headers, w, aligns))
        print(rule(w))
        for row in rows:
            print(render_row(row, w, aligns))
    else:
        print(','.join(csv_cell(c) for c in headers))
        for row in rows:
            print(','.join(csv_cell(v) for v in row))


# ── PER-DRIVE HISTORY HELPERS ─────────────────────────────────────────────────
# Defined here (rather than down in SECTION 1) so -l drive lookups and -t/-c/-l's
# early exit — all of which happen before SECTION 1 — can use them too.

HIST_HEADERS = ['Snapshot', 'Path', '187R', '187W', '198V', 'GDL', '188N',
                '197Rr', '197Wr', 'R_corr', 'W_corr', 'Temp']
HIST_ALIGNS  = ['<', '<', '>', '>', '>', '>', '>', '>', '>', '>', '>', '>']


def hist_rows(serial):
    """One row per snapshot label for this drive, blank where it was absent."""
    present = {r.snap: r for r in drive_rows(serial).itertuples()}
    rows = []
    for snap, lbl in enumerate(LABELS_ORDERED):
        r = present.get(snap)
        if r is None:
            rows.append([lbl, '(not in snapshot)'] + [''] * 10)
        else:
            rows.append([lbl, r.path,
                         r.read_uncorr, r.write_uncorr, r.verify_uncorr, r.gdl, r.nme,
                         r.read_rereads, r.write_rereads, r.read_corrected, r.write_corrected,
                         temp_or(r.temp, '?')])
    return rows


def latest_hist_row(serial):
    """Just this drive's single most recent reading — no snapshot padding."""
    r = drive_rows(serial).iloc[-1]
    return [LABELS_ORDERED[int(r['snap'])], r['path'],
            r['read_uncorr'], r['write_uncorr'], r['verify_uncorr'], r['gdl'], r['nme'],
            r['read_rereads'], r['write_rereads'], r['read_corrected'], r['write_corrected'],
            temp_or(r['temp'], '?')]


# ── LEGENDS ───────────────────────────────────────────────────────────────────

HISTORY_LEGEND = """COLUMN LEGEND — PER-DRIVE HISTORY
  Snapshot  Collection label (chronological)
  Path      host,/dev/path in that snapshot — may change across reboots; the serial is the real key
  187R      SMART 187 : Reported Uncorrectable Errors, READ  — reads that ECC could not recover (data loss)
  187W      SMART 187 : Reported Uncorrectable Errors, WRITE — writes that could not be completed
  198V      SMART 198 : Offline Uncorrectable — uncorrectable errors found by background VERIFY scan
  GDL       SMART 5   : Reallocated Sectors / Grown Defect List — permanent bad spots remapped to spares
  188N      SMART 188 : Command Timeout / Non-Medium Error count — aborted ops, drive stopped responding
  197Rr     SMART 197 proxy : read rereads/rewrites — retries that eventually succeeded (early warning)
  197Wr     SMART 197 proxy : write rereads/rewrites
  R_corr    SMART 1 proxy  : total read errors corrected by ECC (normal background activity)
  W_corr    SMART 7 proxy  : total write errors corrected by ECC
  Temp      SMART 194 : current drive temperature, degrees C"""

MATRIX_LEGEND = """COLUMN LEGEND — PRIORITIZED SMART MATRIX
  #         Urgency rank (1 = most urgent)
  Path      host,/dev/path as of the most recent snapshot containing this drive
  Score     Composite urgency score — higher is more urgent
  Serial    Drive serial number — stable identifier across reboots and /dev path changes
  Product   Drive model
  POH       SMART 9   : Power-On Hours — service age; frames infant-mortality vs wear-out
  187R      SMART 187 : Reported Uncorrectable Errors, READ  — reads ECC could not recover (data loss)
  187W      SMART 187 : Reported Uncorrectable Errors, WRITE — writes that could not be completed
  198V      SMART 198 : Offline Uncorrectable — found by background VERIFY scan
  GDL       SMART 5   : Reallocated Sectors / Grown Defect List — permanent bad spots remapped to spares
  GDLburst  Most recent burst of GDL growth as n(total): n = collections whose GDL exceeded the last known
            value, total = GDL gained across them — every collection counts, ten a day if that is the
            cadence. Two such increases within 48 h qualify; the streak runs on while increases keep
            coming and ends once a calendar day (collector's zone) passes with no increase or no run.
            0 = no burst.
  188N      SMART 188 : Command Timeout / Non-Medium Error count — aborted ops, drive stopped responding
  197Rr     SMART 197 proxy : read rereads/rewrites — retries that eventually succeeded
  197Wr     SMART 197 proxy : write rereads/rewrites
  99PhI     SMART 199 proxy : SAS phy Invalid DWORD count       -- interface layer, usually cable /
  99PhD     SMART 199 proxy : SAS phy Running Disparity errors     backplane / vibration rather than
  99PhL     SMART 199 proxy : SAS phy Loss of DWORD Sync           a bad drive. Treat as infrastructure
  99PhR     SMART 199 proxy : SAS phy Reset Problem                signal, not drive failure.
  Temp      SMART 194 : current drive temperature, degrees C
  Cyc       Number of snapshot intervals in which 187R, 187W, 198V or 188N increased (persistence;
            a lone GDL step does not count — see GDLburst)

  Cells shown as  N(+D)  mean: the value is now N and rose by D during the observation window.
  A bare N did not change. (A value that fell shows N(-D).)
  Fatal Five = 187R, 187W, 198V, GDL (5), 188N. A drive is listed if 187R, 187W or 198V is present at all,
  if 188N increased across the window, or if GDL grew in a burst (GDLburst > 0). A lone GDL step is normal
  wear and does not list a drive; an uncorrectable error is never wear, so a flat 187R does.
  197Rr / 197Wr and the 199 phy counters are supporting context — they do not gate the listing."""


# ── THE RANKED FATAL FIVE LIST — one source, two formats ─────────────────────
# Section 3 (CSV), Section 4 (table), -c and -t all come from here: same
# banner, same legend, same columns, same cells. Only the rendering differs.

MX_HEADERS = ['#', 'Path', 'Score', 'Serial', 'Product', 'POH',
              '187R', '187W', '198V', 'GDL', 'GDLburst', '188N', '197Rr', '197Wr',
              '99PhI', '99PhD', '99PhL', '99PhR', 'Temp', 'Cyc']
MX_ALIGNS  = ['>', '<', '>', '<', '<', '>',
              '>', '>', '>', '>', '>', '>', '>', '>',
              '>', '>', '>', '>', '>', '>']
if ALL_MODE:
    MX_HEADERS = MX_HEADERS[:2] + ['Last seen'] + MX_HEADERS[2:]
    MX_ALIGNS  = MX_ALIGNS[:2]  + ['<']         + MX_ALIGNS[2:]

def matrix_rows(source, changed=None, mark=lambda v: v):
    """One list per ranked drive, cells already rendered.

    changed: {serial: set of FATAL_FIVE names} — -r's "which Fatal Five counters moved
    since the previous run"; each named cell is passed through mark() (table: [cell],
    CSV: cell*). Only the Fatal Five cells can be marked; the default output is
    untouched."""
    rows = []
    for rank, r in enumerate(source.reset_index().itertuples(), 1):
        moved = changed.get(r.serial, ()) if changed else ()
        def cell(key, text):
            return mark(text) if key in moved else text
        row = [rank, r.path]
        if ALL_MODE:
            row.append('' if r.present_last else r.label)   # blank = still in the latest snapshot
        row += [r.score, r.serial, r.product, r.poh,
                cell('read_uncorr',   fmt_delta(r.d_read_uncorr,   r.read_uncorr)),
                cell('write_uncorr',  fmt_delta(r.d_write_uncorr,  r.write_uncorr)),
                cell('verify_uncorr', fmt_delta(r.d_verify_uncorr, r.verify_uncorr)),
                cell('gdl',           fmt_delta(r.d_gdl,           r.gdl)),
                burst_cell(r),
                cell('nme',           fmt_delta(r.d_nme,           r.nme)),
                fmt_delta(r.d_read_rereads,  r.read_rereads),
                fmt_delta(r.d_write_rereads, r.write_rereads),
                r.phy_invalid_dword, r.phy_running_disp, r.phy_loss_sync, r.phy_reset,
                temp_or(r.temp, '?'),
                r.growth_cycles]
        rows.append(row)
    return rows


def print_matrix_section(fmt, source=None, scope=None, standalone=False, listing_rule=None, changed=None):
    """The ranked list with its banner and legend, as a table or as CSV.

    In CSV every non-data line is a '# ' comment so the block still reads as
    one file; cells are comma-joined and quoted where needed (a Path holds a
    comma). standalone drops the leading blank line and the pointer to a
    section that -t / -c do not print.

    source/scope: -l's host lookup and -r's change alert reuse this same renderer on a
    subset — source is that restricted frame (default MATRIX_SOURCE, the whole fleet) and
    scope is a short description appended to the title. The fleet-wide accounting lines
    (excluded-departed / already-out-of-service, which point at sections a scoped call
    doesn't print) only make sense when scope is None. listing_rule replaces the one-line
    statement of what gates a row's presence, for a caller whose gate is narrower than the
    whole-window default (-r)."""
    source = MATRIX_SOURCE if source is None else source
    say = fmt_say(fmt)
    if not standalone:
        print()
    say("=" * 120)
    say(f"PRIORITIZED SMART MATRIX{' (CSV)' if fmt == 'csv' else ''} — {CLUSTER_DESC} — Backblaze framework — "
        f"{SNAPS_DESC}" + (f" — {scope}" if scope else ""))
    say(listing_rule or
        "Drives listed if 187R, 187W or 198V is present at all, if 188N increased across the observation "
        "window, or if GDL grew in a burst (2+ increases within 48 h) — a lone GDL step does not list a drive")
    if SINGLE_RUN:
        say("One collection only: 188N growth, GDL bursts, Cyc and the N(+D) deltas need a second run — "
            "this is the list of drives carrying an uncorrectable error now")
    say("  Fatal Five = 187R / 187W (SMART 187 uncorrectable read / write), 198V (SMART 198 offline "
        "uncorrectable),")
    say("               GDL (SMART 5 grown defect list), 188N (SMART 188 non-medium error count)")
    for line in SCORE_EXPLANATION.splitlines():
        say(line)
    if ALL_MODE:
        n_dep = int((~source['present_last']).sum())
        say(f"-a: includes {n_dep} drive(s) no longer present in the most recent snapshot "
            f"({last_label}) — see 'Last seen'")
    else:
        say(f"Only drives still present in the most recent snapshot ({last_label}) are ranked")
        if scope is None and len(departed):
            say(f"Excluded from ranking (absent from {last_label}, replaced/removed): {len(departed)}"
                + ('' if standalone else f" — see the '{'NO LONGER PRESENT IN ' + last_label}' section above"))
    if scope is None and OUT_SERIALS:
        say("Excluded from ranking (already out of service): "
            + ", ".join(f"{s} ({v})" for s, v in OUT_SERIALS.items()))
    say("=" * 120)
    say()
    for line in MATRIX_LEGEND.splitlines():
        say(line)
    if ALL_MODE:
        say("  Last seen Snapshot label this drive was last present in (-a); blank = still present "
            f"in {last_label}")
    # -r: flank the Fatal Five cells that moved since the previous run. Same cells in both
    # formats; only the marker differs — [ ] reads in a fixed-width table, a trailing *
    # survives a spreadsheet import without turning the cell into something else.
    if changed is not None:
        if fmt == 'table':
            mark = lambda v: f"[{v}]"
            say(f"  [ ]       flanks a Fatal Five counter that changed between {LABELS_ORDERED[-2]} and {last_label} (-r)")
        else:
            mark = lambda v: f"{v}*"
            say(f"  *         suffix on a Fatal Five counter that changed between {LABELS_ORDERED[-2]} and {last_label} (-r)")
    else:
        mark = lambda v: v
    print()
    rows = matrix_rows(source, changed, mark)
    if not rows and scope is not None:
        say(f"(no Fatal Five candidates matched: {scope})")
        return
    print_rows(fmt, MX_HEADERS, MX_ALIGNS, rows)


# ── -l: DRIVE / HOST LOOKUP ───────────────────────────────────────────────────
# Hostname(s) alone reuse print_matrix_section() above, restricted to those hosts (still a
# union: several hosts show their combined slice of the ranked matrix). Anything involving a
# serial or device path is a drive lookup instead — this section's own dual-format renderer,
# since there's no whole-fleet equivalent of that to restrict. When more than one CRITERIA
# type is given together, they AND into one joint filter (increasing specificity — see
# run_lookup) rather than unioning; only several values of the *same* type still OR.

def print_drive_lookup(fmt, serial, all_collections):
    """One drive's SMART reading(s): its latest only, or every collection with -a."""
    say = fmt_say(fmt)
    latest = drive_rows(serial).iloc[-1]
    header = (f"Serial: {serial}  Product: {latest['product']}  Latest path: {latest['path']}  "
              f"POH: {int(latest['poh']):,}h ({latest['poh'] / 8760:.1f}y)")
    if serial in cand.index:
        r = cand.loc[serial]
        header += f"  Score: {int(r['score'])}"
        if not r['present_last']:
            header += f"  (no longer present in {last_label})"
    elif not latest['smart_ok']:
        header += "  (NO SAS SMART DATA in the log for this device — metrics read 0 by absence, not health)"
    else:
        header += "  (not a Fatal Five candidate — no metric increase observed)"
    if serial in OUT_SERIALS:
        header += f"  [OUT OF SERVICE: {OUT_SERIALS[serial]}]"
    say(header)
    rows = hist_rows(serial) if all_collections else [latest_hist_row(serial)]
    print_rows(fmt, HIST_HEADERS, HIST_ALIGNS, rows)


def run_lookup(tokens):
    """Classify each -l token as a serial, a bare device path, or a hostname (priority:
    serial > device path > hostname — the most specific identifier wins per token, since a
    token can only ever be one of the three). A token matching nothing at all is a hard
    error — no silent partial results.

    Several values of the SAME type still OR together, as a plain list: several hosts show
    their combined slice of the ranked matrix; several serials or device paths each print
    their own block (a device path can itself match several serials — the same bay held
    different drives over time).

    Mixing TYPES ANDs them into one joint filter instead — increasing specificity, one
    constraint per type actually given: hostname+path narrows to that path on that host,
    hostname+serial to that serial on that host, hostname+path+serial requires all three to
    have co-occurred in the very same reading. Any combination that includes a serial or
    device path renders as a drive lookup (never the matrix) since it's identifying specific
    drive(s), not a host's whole slate; hostname-only is the sole case that stays matrix-shaped.
    A joint combination that never actually co-occurred is reported, not silently empty."""
    all_hosts   = set(df['host'].unique())
    all_devs    = set(df['dev'].unique())
    all_serials = set(df['serial'].unique())

    given_hosts, given_devs, given_serials, bad = set(), set(), set(), []
    for tok in tokens:
        if tok in all_serials:
            given_serials.add(tok)
        elif tok in all_devs:
            given_devs.add(tok)
        elif tok in all_hosts:
            given_hosts.add(tok)
        else:
            bad.append(tok)
    if bad:
        print(f"ERROR: matches no hostname, device path, or serial in the input: {', '.join(bad)}",
              file=sys.stderr)
        sys.exit(1)

    n_types = sum(bool(s) for s in (given_hosts, given_devs, given_serials))

    def criteria_desc():
        parts = []
        if given_hosts:   parts.append(f"host(s) {', '.join(sorted(given_hosts))}")
        if given_devs:    parts.append(f"path(s) {', '.join(sorted(given_devs))}")
        if given_serials: parts.append(f"serial(s) {', '.join(sorted(given_serials))}")
        return '; '.join(parts)

    # Hostname(s) only: the original whole-host view (union across hosts), matrix-shaped.
    if given_hosts and not given_devs and not given_serials:
        scope = f"host(s): {', '.join(sorted(given_hosts))}"
        source = MATRIX_SOURCE[MATRIX_SOURCE['host'].isin(given_hosts)]
        for fmt in FORMATS:
            print_matrix_section(fmt, source=source, scope=scope, standalone=True)
            print()
        return

    # A device path or serial given (alone, or jointly narrowed by the others): every given
    # type must co-occur in the SAME row for a drive to match — that's what makes mixed
    # types an AND instead of the plain OR a single type gets.
    mask = pd.Series(True, index=df.index)
    if given_hosts:
        mask &= df['host'].isin(given_hosts)
    if given_devs:
        mask &= df['dev'].isin(given_devs)
    if given_serials:
        mask &= df['serial'].isin(given_serials)
    drive_serials = sorted(df.loc[mask, 'serial'].unique())

    if not drive_serials:
        print(f"ERROR: no drive matches all of: {criteria_desc()} (never co-occurred in the same reading)",
              file=sys.stderr)
        sys.exit(1)

    for fmt in FORMATS:
        say = fmt_say(fmt)
        say("=" * 120)
        say(f"DRIVE LOOKUP{' (CSV)' if fmt == 'csv' else ''} — {CLUSTER_DESC} — "
            f"{'all collections' if ALL_MODE else 'most recent collection'} — "
            f"{len(drive_serials)} drive(s)")
        if n_types > 1:
            say(f"Matching all of: {criteria_desc()}")
        say("=" * 120)
        say()
        for line in HISTORY_LEGEND.splitlines():
            say(line)
        print()
        for serial in drive_serials:
            print_drive_lookup(fmt, serial, ALL_MODE)
            print()


# ── -r: CHANGE ALERT ──────────────────────────────────────────────────────────
# The ranked list restricted to drives with a NEW problem signal in the latest interval,
# by the same per-counter rule as the gate: 187R/187W/198V/188N increased between the
# two most recent runs (grew_event is per consecutive-snapshot pair, so its rows at the
# last snapshot are exactly that), or a GDL burst whose latest step IS the newest run.
# A lone GDL step is not a signal here either. Nothing qualifies -> nothing printed,
# exit 0: the whole point is that a cron'd `-c -r | mail` stays silent on quiet days.
# Departed drives can never qualify (not in the last run), so -a adds nothing here;
# OUT_SERIALS stay excluded as everywhere else.
if RECENT_MODE:
    if SINGLE_RUN:
        sys.exit(0)                    # no interval yet, so nothing is "new" — the cron stays quiet
    last_snap     = len(LABELS_ORDERED) - 1
    recent_events = set(df.loc[grew_event & (df['snap'] == last_snap), 'serial'])
    live_bursts   = {s for s, b in bursts_all.items() if b and b[2] == last_snap}
    source        = MATRIX_SOURCE[MATRIX_SOURCE.index.isin(list(recent_events | live_bursts))]
    if source.empty:
        sys.exit(0)
    prev_label = LABELS_ORDERED[-2]
    # Which Fatal Five counters moved between the two most recent runs, per listed drive —
    # the cells the renderer flanks (only those five; Frank: nothing else needs marking).
    # A drive absent from the previous run (a burst stepping after a gap) has nothing to
    # compare against and gets no marks.
    prev_rows = df[df['snap'] == last_snap - 1].set_index('serial')
    last_rows = df[df['snap'] == last_snap].set_index('serial')
    both      = source.index.intersection(prev_rows.index)
    moved     = last_rows.loc[both, FATAL_FIVE] != prev_rows.loc[both, FATAL_FIVE]
    changed   = {s: set(moved.columns[moved.loc[s].values]) for s in both}
    for fmt in FORMATS:
        print_matrix_section(
            fmt, source=source, standalone=True, changed=changed,
            scope=f"-r: new since {prev_label}",
            listing_rule=(f"Drives listed only if 187R, 187W, 198V or 188N INCREASED between the two most recent "
                          f"runs ({prev_label} -> {last_label}), or a GDL burst's latest step is {last_label}; "
                          f"{len(source)} of {len(MATRIX_SOURCE)} ranked drive(s) did. Cells still show the "
                          f"whole-window delta; the ones that moved since {prev_label} are "
                          f"{'flanked [ ]' if fmt == 'table' else 'suffixed *'}."))
        print()
    sys.exit(0)


if L_TOKENS:
    run_lookup(L_TOKENS)
    sys.exit(0)


# -t / -c: that section of the report, and nothing else.
if mode:
    print_matrix_section('csv' if mode == 'c' else 'table', standalone=True)
    sys.exit(0)


# ── SECTION 1: PER-DRIVE HISTORY ──────────────────────────────────────────────

print("\n" + "=" * 120)
print(f"PER-DRIVE HISTORY — Fatal Five + supporting metrics — {SNAPS_DESC}")
print("=" * 120)
print()
print(HISTORY_LEGEND)
print()


def print_hist(serial, widths):
    print('  ' + render_row(HIST_HEADERS, widths, HIST_ALIGNS))
    print('  ' + rule(widths))
    for row in hist_cache[serial]:
        print('  ' + render_row(row, widths, HIST_ALIGNS))


# Every block shares one column layout, so size the columns over all of them first
shown      = list(ranked.index) + list(departed.index) + out_shown
hist_cache = {s: hist_rows(s) for s in shown}
hist_w     = col_widths(HIST_HEADERS, [row for s in shown for row in hist_cache[s]])

for rank, r in enumerate(ranked.reset_index().itertuples(), 1):
    print(f"\n#{rank}  Serial: {r.serial}  Product: {r.product}"
          f"  Latest path: {r.path}"
          f"  POH: {r.poh:,}h ({r.poh/8760:.1f}y)"
          f"  Score: {r.score}")
    if r.growth_intervals:
        print(f"  Growth cycles: {', '.join(r.growth_intervals.split())}")
    print_hist(r.serial, hist_w)


# ── SECTION 2: OUT-OF-SERVICE SERIALS ─────────────────────────────────────────

if out_shown:
    print("\n" + "=" * 120)
    print("OUT-OF-SERVICE SERIALS — excluded from the ranked matrix, shown for completeness")
    print("=" * 120)
    for serial in out_shown:
        r = cand.loc[serial]
        print(f"\n  {serial}  ({OUT_SERIALS[serial]})  POH: {int(r['poh']):,}h  Latest: {r['path']}")
        print_hist(serial, hist_w)


# ── SECTION 2b: DEPARTED DRIVES ───────────────────────────────────────────────

if len(departed):
    print("\n" + "=" * 120)
    print(f"NO LONGER PRESENT IN {last_label}"
          + ("" if ALL_MODE else " — excluded from the ranked matrix"))
    print("=" * 120)
    print()
    print(f"These drives met the listing rule while observed, but are absent from the")
    print(f"most recent snapshot ({last_label}) — replaced or physically removed. Values shown")
    print("are their last observed readings."
          + (" Also folded into the ranked matrix above (-a), marked via 'Last seen'; this table"
             " adds their full per-snapshot history." if ALL_MODE else
             " Not actionable; listed so the history isn't lost."))
    print()

    dep_headers = ['Serial', 'Last path', 'Product', 'Last seen', 'POH',
                   '187R', '187W', '198V', 'GDL', '188N', 'Cyc', 'Score']
    dep_aligns  = ['<', '<', '<', '<', '>', '>', '>', '>', '>', '>', '>', '>']
    dep_rows = [[r.serial, r.path, r.product, r.label, r.poh,
                 fmt_delta(r.d_read_uncorr,   r.read_uncorr),
                 fmt_delta(r.d_write_uncorr,  r.write_uncorr),
                 fmt_delta(r.d_verify_uncorr, r.verify_uncorr),
                 fmt_delta(r.d_gdl,           r.gdl),
                 fmt_delta(r.d_nme,           r.nme),
                 r.growth_cycles, r.score]
                for r in departed.reset_index().itertuples()]
    dep_w = col_widths(dep_headers, dep_rows)
    print(render_row(dep_headers, dep_w, dep_aligns))
    print(rule(dep_w))
    for row in dep_rows:
        print(render_row(row, dep_w, dep_aligns))


# ── SECTION 3: PRIORITIZED SMART MATRIX — CSV ─────────────────────────────────

print_matrix_section('csv')


# ── SECTION 4: PRIORITIZED SMART MATRIX — FORMATTED ───────────────────────────

print_matrix_section('table')
