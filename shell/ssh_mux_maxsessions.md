# Many parallel ssh sessions to one host fail at `MaxSessions`

## Symptom

- N parallel ssh sessions go to ONE host through a shared `ControlMaster` connection.
- When N is more than sshd's `MaxSessions` (default 10): `mux_client_request_session: session request failed: Session open refused by peer`.
- ssh then disables multiplexing and opens new TCP connections. sshd's `MaxStartups` (default 10:30:100) drops some of them: `kex_exchange_identification: read: Connection reset by peer`.
- Seen with 111 workers that each opened one session to the same host. The 39 probes that did not run were reported as firewall failures.

## Cause

- The two limits are per sshd on the TARGET host. One session to each of N different hosts is fine. N sessions to one host is not.

## Fix

- Put the N probes into ONE remote command that runs them in parallel inside the target shell (background jobs).
- Print one `FAIL` line per failed item, and a `DONE` line at the end. A dead session is then different from N failures.
- Check the limits of a target: `sshd -T | grep -Ei '^(maxsessions|maxstartups) '`.
