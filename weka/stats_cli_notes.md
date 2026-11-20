# `weka stats` CLI: notes from WEKA 5.1.31

Personal notes on observed behaviour, not WEKA documentation. Checked on one release.

- **`--aggregate-by container` can fail.** For `--stat CPU_UTILIZATION` it returned `HTTP Error ... Cannot encode Infinity` (INTERNAL_SERVER_ERROR). Workaround: use `--per-process` and add the values yourself (CSV output with `-U -R`).
- **`--resolution-secs` must be a multiple of 60.** A test of 5 to 9 seconds is diluted 7 to 12 times in a 60-second bucket. Use `weka stats realtime` (1 second) during a short run.
- **`weka stats list-types` has no `--category` flag.**
- **An unknown or hidden category returns only the CSV header,** with no error. An empty result is not evidence of "no activity".
- **Role:** a user with the regular-user role cannot run cluster-wide queries. A client container under the WEKA Operator has that role, so run the queries from a backend.
- **`/proc/wekafs/stat` on a client host** is safe to read. It gives, per operation, the average and the longest latency in the frontend and in the kernel driver, plus I/O counts since the mount.
