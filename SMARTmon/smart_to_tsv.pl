#!/usr/bin/perl
# smart_to_tsv.pl — flatten smartctl collection logs into ONE TSV, one row per drive.
#
#   perl smart_to_tsv.pl run.log      > run.tsv    # one collection (what the collector does)
#   perl smart_to_tsv.pl logs/*.log   > all.tsv    # every collection, parsed in parallel
#
# A drive block starts at a bare "hostname,/dev/xxx" line (the collector writes
# one before each smartctl dump); nothing about the hostname's shape is assumed,
# so the cluster's naming scheme is irrelevant. Each log is one collection run.
# Every row carries
#   collected_epoch  that drive's own "Local Time is:" as Unix time
#   tz, tz_offset    the zone abbreviation smartctl printed on that line (PDT,
#                    EST, ...) and the UTC offset in seconds actually used to
#                    turn it into collected_epoch — compare_smart.py renders run
#                    labels in that zone, so nothing about the site's zone is
#                    configured anywhere
#   run_epoch        the earliest collected_epoch in its log — the run's identity
#   smart_ok         1 if the block carried SAS SMART data this parser reads (defect
#                    list, error counter log, non-medium errors or power-on time),
#                    0 for a block smartctl printed but had nothing to say about —
#                    an NVMe boot drive, an HBA logical volume. Their metrics are 0
#                    by absence, not by health; compare_smart.py keeps them (nothing
#                    is excluded) but counts and flags them so that is not misread
# so compare_smart.py groups rows by run_epoch and never cares which file, or
# how many, the rows arrived in. With several logs one child process parses
# each (all at once); the parent gathers their rows in memory and writes a
# single header plus every row.
#
# Logs may be gzipped. That is detected by the gzip magic bytes, not the file
# name, and the stream is piped from `gzip -dc` — the one thing this script
# needs beyond perl itself, and present on every RHEL or macOS host. (The core
# IO::Uncompress::Gunzip module was measured 30x slower on line reads.)
#
# Plain perl 5 + core modules only (target is 5.26 on RHEL 8).
#
# Field semantics mirror the original Python parser: first occurrence wins,
# missing numerics are 0, missing temp is empty. One deliberate change: the SAS
# phy counters are matched case-insensitively. The Python regexes used
# capitalisation smartctl never emits, so 99PhD / 99PhL / 99PhR were always 0.
#
# The zone abbreviation in "Local Time is:" is honoured (not the TZ of the host
# running this script) so a backfill on a laptop and a production run on the
# collector agree to the second.
use strict;
use warnings;
use Time::Local qw(timegm timelocal);
use IO::Select;

my @DATA_COLS = qw(
    serial host dev path product smart_ok collected_epoch tz tz_offset poh temp
    gdl nme
    read_corrected   read_rereads   read_uncorr
    write_corrected  write_rereads  write_uncorr
    verify_corrected verify_rereads verify_uncorr
    phy_invalid_dword phy_running_disp phy_loss_sync phy_reset
);
my @COLS = (@DATA_COLS, 'run_epoch');
my %ZERO_IF_MISSING = map { $_ => 1 }
    grep { !/^(?:serial|host|dev|path|product|smart_ok|collected_epoch|tz|tz_offset|temp)$/ } @DATA_COLS;

my %MON = (jan=>0, feb=>1, mar=>2, apr=>3, may=>4,  jun=>5,
           jul=>6, aug=>7, sep=>8, oct=>9, nov=>10, dec=>11);
# UTC offsets (hours) for the zone abbreviations smartctl prints.
my %TZ_OFFSET = (UTC=>0, GMT=>0, PST=>-8, PDT=>-7, MST=>-7, MDT=>-6,
                 CST=>-6, CDT=>-5, EST=>-5, EDT=>-4);
my $warned_tz = 0;

@ARGV or die "usage: $0 <collection.log> [more.log ...] > out.tsv\n";
exit(@ARGV > 1 ? parallel(@ARGV) : single($ARGV[0]));


# ── many logs: one child per log, gathered in memory, one header ─────────────
sub parallel {
    my @logs = @_;
    my $sel  = IO::Select->new;
    my (%slot, @buf);
    for my $i (0 .. $#logs) {
        open(my $fh, '-|', $^X, $0, $logs[$i])
            or die "cannot start a parser for $logs[$i]: $!\n";
        $slot{ fileno $fh } = $i;
        $buf[$i] = '';
        $sel->add($fh);
    }
    # Drain every child's pipe as it produces, so nobody blocks on a full pipe.
    while ($sel->count) {
        for my $fh ($sel->can_read) {
            my $i = $slot{ fileno $fh };
            my $n = sysread($fh, my $chunk, 1 << 20);
            if (!$n) {
                $sel->remove($fh);
                close $fh or die "parser for $logs[$i] failed (status $?)\n";
                next;
            }
            $buf[$i] .= $chunk;
        }
    }
    my $header;
    for my $i (0 .. $#buf) {
        my ($hdr, $body) = split /\n/, $buf[$i], 2;
        $header //= "$hdr\n";
        $buf[$i] = defined $body ? $body : '';
    }
    print $header, @buf;
    return 0;
}


# ── one log ──────────────────────────────────────────────────────────────────
my (%d, $path, @rows, $run_epoch);

# "Tue Sep  8 07:55:53 2026 PDT" -> (epoch, zone abbreviation as printed, UTC offset in
# seconds actually applied). The offset is derived from the result (wall clock as UTC
# minus the epoch) rather than looked up again, so it is right in the unknown-zone
# fallback too: rendering the epoch at that offset always reproduces the wall clock
# the log printed, whichever zone produced the epoch. ('', '', '') if unparseable.
sub local_time_to_epoch {
    my ($s) = @_;
    my ($mon, $mday, $h, $m, $sec, $year, $tz) =
        $s =~ /^\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})\s+(\d{4})\s*(\w*)/
        or return ('', '', '');
    my $mi = $MON{lc $mon};
    return ('', '', '') unless defined $mi;
    my $wall_as_utc = timegm($sec, $m, $h, $mday, $mi, $year);
    my $epoch;
    if (defined $TZ_OFFSET{$tz}) {
        $epoch = $wall_as_utc - $TZ_OFFSET{$tz} * 3600;
    } else {
        warn "smart_to_tsv.pl: unknown zone '$tz' in '$s'; using this host's local time\n"
            unless $warned_tz++;
        $epoch = timelocal($sec, $m, $h, $mday, $mi, $year);
    }
    return ($epoch, $tz, $wall_as_utc - $epoch);
}

# Rows are held until the whole log is read: run_epoch is the earliest drive
# stamp in the log, and that is only known at the end.
sub flush {
    return unless defined $path && defined $d{serial};
    $d{product}         = '?' unless defined $d{product} && length $d{product};
    $d{temp}            = ''  unless defined $d{temp};
    $d{collected_epoch} = ''  unless defined $d{collected_epoch};
    $d{tz}              = ''  unless defined $d{tz};
    $d{tz_offset}       = ''  unless defined $d{tz_offset};
    # Decided before the zero-fill below, which is what makes "absent" and "0" look alike.
    $d{smart_ok} = (grep { defined $d{$_} } qw(gdl nme poh read_uncorr write_uncorr verify_uncorr)) ? 1 : 0;
    $d{$_} = 0 for grep { !defined $d{$_} } keys %ZERO_IF_MISSING;
    if (length $d{collected_epoch}
        && (!defined $run_epoch || $d{collected_epoch} < $run_epoch)) {
        $run_epoch = $d{collected_epoch};
    }
    push @rows, join("\t", map { $d{$_} } @DATA_COLS);
}

# Open a log for line reading, transparently gunzipping if it is compressed.
# Returns the handle and whether it is a gzip pipe (whose exit status must be
# checked on close — a truncated archive must not yield a short TSV).
sub open_log {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!\n";
    my $magic = '';
    read($fh, $magic, 2);
    if ($magic eq "\x1f\x8b") {
        close $fh;
        open my $gz, '-|', 'gzip', '-dc', $path
            or die "cannot start gzip -dc for $path: $!\n";
        return ($gz, 1);
    }
    seek($fh, 0, 0) or die "$path: seek: $!\n";
    return ($fh, 0);
}

sub single {
    my ($log) = @_;
    my ($fh, $is_gz) = open_log($log);

    while (my $l = <$fh>) {
        chomp $l;
        # The collector's per-drive header: "hostname,/dev/xxx" alone on a line. Any
        # hostname, any device node — the only shape claim is "no whitespace, one comma,
        # then /dev/", which no smartctl output line has.
        if ($l =~ /^([^\s,]+,\/dev\/[^\s,]+)$/) {
            flush();
            $path = $1;
            %d = (path => $path);
            ($d{host}, $d{dev}) = split /,/, $path, 2;
            next;
        }
        next unless defined $path;

        my $lc = lc $l;     # one lowercase per line; every dispatch below is case-insensitive

        if (index($lc, 'serial number:') >= 0) {
            $d{serial} = $1 if !defined $d{serial} && $l =~ /Serial number:\s+(\S+)/i;
        }
        elsif (index($lc, 'product:') == 0) {
            if (!defined $d{product} && $l =~ /Product:\s+(.+)/i) {
                ($d{product} = $1) =~ s/^\s+|\s+$//g;
            }
        }
        elsif (index($lc, 'local time is:') >= 0) {
            if (!defined $d{collected_epoch} && $l =~ /Local Time is:\s+(.+)/i) {
                (my $ts = $1) =~ s/\s+/ /g;
                ($d{collected_epoch}, $d{tz}, $d{tz_offset}) = local_time_to_epoch($ts);
            }
        }
        elsif (index($lc, 'elements in grown defect list:') >= 0) {
            $d{gdl} = $1 if !defined $d{gdl} && $l =~ /:\s*(\d+)/;
        }
        elsif (index($lc, 'non-medium error count:') >= 0) {
            $d{nme} = $1 if !defined $d{nme} && $l =~ /:\s*(\d+)/;
        }
        elsif (index($lc, 'current drive temperature:') >= 0) {
            $d{temp} = $1 if !defined $d{temp} && $l =~ /:\s*(\d+)/;
        }
        elsif (index($lc, 'accumulated power on time') >= 0) {
            $d{poh} = $1 if !defined $d{poh} && $l =~ /Accumulated power on time.*?(\d+):\d+/i;
        }
        elsif (index($lc, 'number of hours powered up') >= 0) {
            $d{poh} = int($1) if !defined $d{poh} && $l =~ /=\s*([\d.]+)/;
        }
        elsif ($l =~ /^(read|write|verify):\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)/) {
            # Error counter log — cols: fast_ecc delayed_ecc rereads corrected algo GB uncorrected
            my ($et, $rereads, $corrected, $uncorr) = ($1, $4, $5, $8);
            if (!defined $d{"${et}_uncorr"}) {
                ($d{"${et}_corrected"}, $d{"${et}_rereads"}, $d{"${et}_uncorr"})
                    = ($corrected, $rereads, $uncorr);
            }
        }
        # SAS phy counters — first phy block only, '= N' form. The later
        # 'Phy event descriptors' repeat these names with ':' and are ignored,
        # as in the original.
        elsif (index($lc, 'invalid dword count') >= 0) {
            $d{phy_invalid_dword} = $1 if !defined $d{phy_invalid_dword} && $l =~ /=\s*(\d+)/;
        }
        elsif (index($lc, 'running disparity error count') >= 0) {
            $d{phy_running_disp} = $1 if !defined $d{phy_running_disp} && $l =~ /=\s*(\d+)/;
        }
        elsif (index($lc, 'loss of dword synchronization') >= 0) {
            $d{phy_loss_sync} = $1 if !defined $d{phy_loss_sync} && $l =~ /=\s*(\d+)/;
        }
        elsif (index($lc, 'phy reset problem') >= 0) {
            $d{phy_reset} = $1 if !defined $d{phy_reset} && $l =~ /=\s*(\d+)/;
        }
    }
    flush();
    warn "smart_to_tsv.pl: $log: no drive blocks found — empty or not a collection log\n" unless @rows;
    if ($is_gz) {
        close $fh or die "gzip -dc failed on $log (exit status " . ($? >> 8) . ")\n";
    } else {
        close $fh;
    }

    my $re = defined $run_epoch ? $run_epoch : '';
    print join("\t", @COLS), "\n";
    print "$_\t$re\n" for @rows;
    return 0;
}
