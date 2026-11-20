# paramiko in field tools: why a key that works with `ssh` fails in the tool

Reported from field use of Python tools that connect with paramiko or fabric (2026-07). The typical report: "it does not see my forwarded ssh agent", and a key pair that works with plain `ssh` fails.

## Causes, most likely first

1. **Old paramiko signs RSA keys with SHA-1.** OpenSSH 8.8 and later (for example on EL9) rejects `ssh-rsa` signatures. The `ssh` command uses `rsa-sha2-*`, so it works.
2. **paramiko tries each key in the agent.** With many keys, the server disconnects at `MaxAuthTries` before the correct key.
3. **`sudo` removes `SSH_AUTH_SOCK`.** The tool then has no agent.
4. **No parity with `~/.ssh/config`.** `ProxyJump`, `Include`, `Match` and certificates work in OpenSSH. A paramiko tool implements only part of them, or none.

Three more things to check:
- A `forward_agent` parameter that the code accepts but does not pass to the connection.
- A fallback to an interactive password prompt after a key failure. It hides the real error.
- Unpinned paramiko and fabric versions in the build. The behaviour then depends on the day of the build.

## What to do

- For a small control surface (run a command, copy a file), call the OpenSSH binary. Ansible does this.
- Short term: pin `paramiko>=3.4` and `fabric>=3.2`, run with `sudo -E`, and give an explicit `IdentityFile`.
- asyncssh is not a free replacement. It has its own problems, for example a connection cache that keeps dead connections.
