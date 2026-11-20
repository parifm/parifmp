#!/usr/bin/env bash
# Copy a tree of many files to another host, in parallel, over reusable ssh
# control sockets on two network paths.
#
# Run it from the top of the source tree. It starts one tar per file and
# spreads the files over PT control sockets per path.
#
# NOTE: this version was changed to take its addresses from variables. It
# passed `bash -n`; it has not been run since that change. Test on a small tree.
#
# Usage: SRC1=<local ip, path 1> SRC2=<local ip, path 2> \
#        DST1=<remote ip, path 1> DST2=<remote ip, path 2> \
#        DEST_DIR=/mnt ./parallel_tar_over_ssh.sh

set -u
: "${SRC1:?local address on path 1}" "${SRC2:?local address on path 2}"
: "${DST1:?remote address on path 1}" "${DST2:?remote address on path 2}"
DEST_DIR=${DEST_DIR:-/mnt}
PT=${PT:-5}                         # control sockets per path
SOCK_DIR=${SOCK_DIR:-$HOME/.ssh}

sshops='-o ConnectTimeout=2 -o ConnectionAttempts=10 -o ForwardAgent=false -o ServerAliveInterval=30'

# Open PT reusable ssh sockets on each path
for i in $(seq "$PT"); do
	ssh $sshops -b "$SRC1" -M -S "$SOCK_DIR/p1$i" -Nfvvv -E "./p1${i}.log" "$DST1"
	ssh $sshops -b "$SRC2" -M -S "$SOCK_DIR/p2$i" -Nfvvv -E "./p2${i}.log" "$DST2"
done
echo "sockets open: $(ls -1 "$SOCK_DIR"/p[12]* | wc -l)"
sleep 2

# One tar per file, spread over the sockets of the two paths.
find . -type f -print0 |
	awk -v pl=$(((2 * PT) + 1)) -v c=1 -v p=1 -v RS='\0' -v d1="$DST1" -v d2="$DST2" -v sd="$SOCK_DIR" -v dest="$DEST_DIR" '
	{
		dst = (p == 1) ? d1 : d2
		printf "\"%s\" | ssh -o ForwardAgent=false -S %s/p%s%s %s \"tar --skip-old-files -xf - -C %s\"\0", $0, sd, p, c, dst, dest
		p++
		if (p == 3) { p = 1; c++ }
		if (c == pl) { c = 1 }
	}' |
	xargs -0 -P $((16 * PT)) -I{} sh -c 'tar -cf - {}'

# Close the sockets
for i in $(seq "$PT"); do
	ssh -S "$SOCK_DIR/p1$i" "$DST1" -O exit
	ssh -S "$SOCK_DIR/p2$i" "$DST2" -O exit
done
