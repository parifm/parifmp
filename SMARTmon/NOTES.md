# SMARTmon: design notes

How the scripts in this folder fit together, and the rules behind them.

## Shape

```
perl smart_to_tsv.pl logs/<cluster>/*.log.gz | python3 compare_smart.py [flags]
```

- `host_col.sh` runs `smartctl -x` for each disk of one host, in parallel. `cluster_col.sh` collects one log per cluster run. `SMARTmon_cron.sh` runs the pipeline and mails a change alert.
- `smart_to_tsv.pl` flattens each collection to TSV. It needs only perl 5 core modules and the `gzip` binary. It reads gzip files directly.
- `compare_smart.py` reads only TSV into one pandas DataFrame. With no path it reads stdin.

## The contract

- **The TSV columns are the contract.** Readers select columns by name. A new column breaks nothing. A schema change means that you generate each TSV again from the raw logs, so keep the raw logs.
- A run is one `run_epoch` value: the earliest `collected_epoch` in the log. Values within 1 second are the same run.
- Duplicate rows in a run: keep the row with the fewest missing values; on a tie, keep the last one.
- **No device is excluded.** A device with no SAS SMART data stays in the counts and the inventory, with a flag.
- The tool takes everything from the collected log. It has no cluster-specific flags and no environment variables.

## Flags of `compare_smart.py`

| Flag | Meaning |
|---|---|
| `-t` / `-c` | Print only the legend, one blank line, then the ranked list (text or CSV). The two formats hold the same content. |
| `-a` | Include drives that are no longer present. |
| `-l CRITERIA` | A comma list of host names, serial numbers or `/dev/sdX` paths. The same type is OR, different types are AND. |
| `-r` | For cron: print nothing unless a drive has a new signal in the latest interval. |

## Scoring

- The "fatal five" signals: 187 (reported uncorrectable, read and write), 198 (offline uncorrectable), 188 (command timeout) and the grown defect list (GDL).
- 187 and 198 are listed when present.
- **GDL counts only as a burst:** an event is a collection whose GDL is more than the previous one, and a burst is two or more events on the same or adjacent dates. A single reallocation long ago is not a signal.
- 188 counts only when it grows. Listing it on presence would list about 9% of a large fleet.
- Score = `30 × 187W + 25 × 187R + 30 × 198V` on the latest counts, plus `10 ×` the GDL burst total, plus the growth of 188.

## Scale

- Limit the input, not the machinery: the cron job reads the newest 14 to 16 logs (about 4 days at a 6-hour cadence). A manual run uses a month glob.
- In `compare_smart.py`, work on columns. A loop over drives with one pandas call per drive takes seconds at 7,000 drives.

## Checks before a change to `compare_smart.py` is done

1. Old and new output on the same list of files must be identical where no change is intended.
2. A synthetic input must exercise the branches that real data does not reach.
3. For a change to duplicate handling: inject duplicates and check the result. Select rows by an exact `run_epoch`.
4. The same log twice must give one run, with no change.

## Traps

- **smartctl 7 prints some field names in lower case.** A case-sensitive pattern reported 0 for SAS phy error counters for months.
- **A drive behind a RAID controller in RAID mode shows as a virtual disk.** `smartctl` sees only the virtual disk. No collector change fixes that; report it as not available.
- **Device names differ per host.** The same `/dev/sdX` name can be a virtual disk on one host and a data disk on another. Identify by vendor and product, not by letter.
- **Offline host with Python 3.6:** download wheels on another machine, then install them in a venv:

  ```bash
  pip download pandas==1.1.5 --only-binary=:all: --python-version 3.6.8 --implementation cp --abi cp36m --platform manylinux1_x86_64
  ```

  `--python-version 36` is read as 3.6.0, and an old pip does not know `manylinux2010`.
