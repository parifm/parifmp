#!/usr/bin/env python3
"""
Data plane validation dashboard generator (fabric_sleuth)

Parses the .tgz archive (older runs: .tar.gz) produced by iperf3_be_to_be_dual_path.sh
and generates a self-contained interactive HTML dashboard.

Usage: python3 generate_dashboard.py <run>.tgz|<run>.tar.gz [output.html]   (default: <run>.html next to the archive)
FS_SPINES, FS_SPINE_LINKS, FS_SPINE_GBPS in the environment declare the leaf-spine uplinks for a run that did not.
"""

import re
import json
import sys
import os
import tarfile
import tempfile
import shutil
from collections import defaultdict, Counter
from html import escape

# usage: generate_dashboard_v2.py <run>.tgz|.tar.gz [output.html] [--compare <older run>.tgz|.tar.gz]
ARGS = sys.argv[1:]
COMPARE_FILE = None
if '--compare' in ARGS:
    i = ARGS.index('--compare')
    if i + 1 >= len(ARGS):
        sys.exit('--compare needs an older run tarball')
    COMPARE_FILE = ARGS[i + 1]
    del ARGS[i:i + 2]
INPUT_FILE = ARGS[0] if ARGS else 'dp_validation.tar.gz'
# default: <run>.html next to the tarball
OUTPUT_FILE = ARGS[1] if len(ARGS) > 1 else re.sub(r"\.tar\.gz$|\.tgz$", "", INPUT_FILE) + ".html"
if os.path.abspath(OUTPUT_FILE) == os.path.abspath(INPUT_FILE):   # never write the page over the archive
    sys.exit(f"Error: output {OUTPUT_FILE} is the input archive")


# Pre-FEC BER levels. 2.4e-4 is the correction limit commonly quoted for RS(544,514) "KP4" FEC
# (IEEE 802.3, 200/400G PAM4); NRZ links on RS(528,514) correct less. The watch level is a heuristic.
FEC_LIMIT_BER = 2.4e-4
FEC_WATCH_BER = 1e-5


def generate_html(data, output_path):
    """Generate self-contained interactive HTML dashboard."""

    results = data['iperf_results']
    L = data['line_rate']
    G, F, M, S = (data['tiers'][k] for k in ('G', 'F', 'M', 'S'))
    # an IP is judged by its rail's rate, a run by the slower of its two rails; charts keep one scale
    rt = data.get('rail_tiers', {})
    def tip(ip, k):
        return rt.get(data.get('ip_rail', {}).get(ip), data['tiers'])[k]
    def tpath(r, k):
        return min(tip(r['src'], k), tip(r['dst'], k))
    badge_tiers = {r: {k: rt.get(r, data['tiers'])[k] for k in ('G', 'F', 'S')} for r in ('A', 'B')}
    badge_tiers['X'] = {k: min(badge_tiers['A'][k], badge_tiers['B'][k]) for k in ('G', 'F', 'S')}
    rr = data.get('rail_rate', {})
    rail_note = (f" | rails differ: A {rr['A']}G, B {rr['B']}G (tables judge each IP by its rail; charts use {L}G)"
                 if rr and rr.get('A') != rr.get('B') else '')
    at_l = f'{L}G' if not rail_note else 'rail speed'
    label = data['metadata'].get('label', 'Fabric')
    speeds = sorted([r['gbps'] for r in results]) if results else []
    count = len(speeds)

    if count > 0:
        avg_gbps = sum(speeds) / count
        min_gbps = speeds[0]
        max_gbps = speeds[-1]
        median_gbps = speeds[count // 2]
        pct_line = (avg_gbps / L) * 100
        above_350 = sum(1 for s in speeds if s >= G)
        above_300 = sum(1 for s in speeds if s >= F)
        above_200 = sum(1 for s in speeds if s >= S)
        below_100 = sum(1 for s in speeds if s < L / 4)
    else:
        avg_gbps = min_gbps = max_gbps = median_gbps = pct_line = 0
        above_350 = above_300 = above_200 = below_100 = 0

    # Build IP -> hostname map from LLDP/driver data
    ip_to_host = {}
    ip_to_nic = {}
    for l in data['lldp_info']:
        ip_to_host[l['ip']] = l['host']
        ip_to_nic[l['ip']] = l['nic']
    for d in data['driver_info']:
        ip_to_host[d['ip']] = d['host']
        ip_to_nic[d['ip']] = d['nic']

    def h(ip):
        return ip_to_host.get(ip, '')

    # Per-IP stats (each IP's throughput regardless of src/dst role; same-rail runs unless it has none)
    ip_stats, _ = _ip_speeds(results, data.get('ip_rail', {}))
    ip_avgs = {ip: sum(v)/len(v) for ip, v in ip_stats.items()}
    slow_ip_count = sum(1 for ip, v in ip_avgs.items() if v < tip(ip, 'F'))

    # Per-iteration stats for box plot
    iter_data = defaultdict(list)
    for r in results:
        iter_data[r['iteration']].append(r['gbps'])

    # Bottom 50 results
    bottom_50 = sorted(results, key=lambda r: r['gbps'] / (tpath(r, 'F') or 1))[:50]

    # All results for searchable table
    all_results_json = json.dumps(results)
    ip_host_json = json.dumps(ip_to_host)
    ip_nic_json = json.dumps(ip_to_nic)

    # Chart data
    speeds_json = json.dumps(speeds)
    iter_labels = sorted(iter_data.keys())
    iter_box_data = json.dumps([{'y': iter_data[k], 'name': f'Iteration {k}', 'type': 'box'} for k in iter_labels])

    # IP bar chart - sort by avg speed
    ip_sorted = sorted(ip_avgs.items(), key=lambda x: x[1])
    ip_labels = json.dumps([x[0] for x in ip_sorted])
    ip_values = json.dumps([round(x[1], 1) for x in ip_sorted])

    # Driver/firmware summary
    fw_counts = defaultdict(int)
    drv_counts = defaultdict(int)
    for d in data['driver_info']:
        fw_counts[d['firmware']] += 1
        drv_counts[f"{d['driver']} {d['version']}"] += 1

    # Switch summary from LLDP
    switch_counts = defaultdict(int)
    for l in data['lldp_info']:
        switch_counts[l['switch']] += 1

    driver_json = json.dumps(data['driver_info'])
    lldp_json = json.dumps(data['lldp_info'])

    # Retransmits from iperf3
    total_retransmits = sum(r.get('retransmits', 0) for r in results)
    total_gbytes = sum(r.get('gbytes', 0) for r in results)
    total_est_segs = total_gbytes * 1e9 / 1448 if total_gbytes > 0 else 0
    retransmit_pct = (total_retransmits / total_est_segs * 100) if total_est_segs > 0 else 0
    retransmit_pct_str = f"{retransmit_pct:.3f}" if retransmit_pct < 1 else f"{retransmit_pct:.1f}"
    tests_with_retransmits = sum(1 for r in results if r.get('retransmits', 0) > 0)

    # Packet drops
    drops = data['packet_drops']
    total_rx_drops = sum(d['rx_drop'] for d in drops)
    total_tx_drops = sum(d['tx_drop'] for d in drops)
    total_oob = sum(d['rx_oob'] for d in drops)
    nics_with_drops = len(drops)

    # FEC data — all entries, chart shows top 50, table shows all
    fec_data = data['fec_top']
    fec_chart_n = min(50, len(fec_data))
    fec_labels = json.dumps([f"{f['host']}/{f['nic'].replace('enp','').replace('s0np0','')}" for f in fec_data[:fec_chart_n]])
    fec_values = json.dumps([f['corrected'] for f in fec_data[:fec_chart_n]])

    # Optics data — color intensity reflects deviation from ideal
    # RX power: ideal ~2 dBm, worse as it goes negative; temp: ideal ~40°C, worse as it climbs
    optics_data = data['optics']
    RX_IDEAL = 2.0    # dBm
    RX_WORST = -20.0   # dBm
    TEMP_IDEAL = 40.0  # °C
    TEMP_WORST = 80.0  # °C

    def _deviation_color(fraction):
        """Return an rgba background color from green (0.0) to red (1.0) with enough opacity to read white text."""
        f = max(0.0, min(1.0, fraction))
        if f < 0.5:
            r, g = int(255 * f * 2), 200
        else:
            r, g = 255, int(200 * (1 - f) * 2)
        return f'rgba({r},{g},0,0.35)'

    def _rx_cell(val):
        if val is None:
            return '<td class="text-muted">—</td>'
        frac = (RX_IDEAL - val) / (RX_IDEAL - RX_WORST)
        bg = _deviation_color(frac)
        return f'<td style="background:{bg};color:#fff">{val}</td>'

    def _temp_cell(val):
        if val is None:
            return '<td class="text-muted">—</td>'
        frac = (val - TEMP_IDEAL) / (TEMP_WORST - TEMP_IDEAL)
        bg = _deviation_color(frac)
        return f'<td style="background:{bg};color:#fff">{val}</td>'

    def _optics_row(o):
        rx_cells = ''.join(_rx_cell(v) for v in o['rx_power'])
        temp_c = _temp_cell(o['temp'])
        return f"<tr><td></td><td>{o['host']}</td><td>{o['nic']}</td><td>{o['ip']}</td>{rx_cells}{temp_c}</tr>"

    # Slow IPs (merged src+dst)
    slow_ips_json = json.dumps(data['slow_ips'])

    # Build vis-network topology from LLDP + performance data
    topo_nodes = {}
    topo_edges = []
    # Spine (virtual aggregate of all spine switches)
    spine_id = 'spine'
    real_switches = [sw for sw in switch_counts if sw and sw != 'unknown']
    topo_nodes[spine_id] = {
        'id': spine_id, 'label': 'Spine',
        'group': 'spine', 'level': 0,
        'title': f'<b>Spine Layer</b><br>{len(real_switches)} leaf switches connected',
    }
    # Leaf switches at level 1
    for sw in real_switches:
        topo_nodes[sw] = {
            'id': sw, 'label': sw.split('.')[0],
            'group': 'switch', 'level': 1,
            'title': f'<b>{sw}</b><br>{switch_counts[sw]} host ports',
        }
        topo_edges.append({
            'from': sw, 'to': spine_id,
            'color': {'color': '#4ecca3', 'highlight': '#ffffff'},
            'width': 3, 'dashes': False,
            'title': f'{sw} ↔ Spine uplink',
        })
    # Hosts — group by host, each host has 2 NICs
    host_nics = defaultdict(list)  # host -> [{nic, ip, switch, port, avg_gbps}]
    for l in data['lldp_info']:
        avg = ip_avgs.get(l['ip'], 0)
        host_nics[l['host']].append({**l, 'avg_gbps': round(avg, 1)})

    for host, nics in host_nics.items():
        host_avg = sum(n['avg_gbps'] for n in nics) / len(nics) if nics else 0
        is_down = any(n['ip'] in data['down_ips'] for n in nics)
        color = '#666666' if is_down else '#4ecca3' if host_avg >= G else '#0dcaf0' if host_avg >= F else '#ffc107' if host_avg >= S else '#e94560'
        nic_lines = ''.join(
            f"<br>{n['nic']}: {n['ip']} → {n.get('port_desc','')} @ {n['avg_gbps']} Gbps"
            for n in nics
        )
        topo_nodes[host] = {
            'id': host, 'label': host, 'group': 'host', 'level': 2,
            'color': {'background': color, 'border': color},
            'title': f'<b>{host}</b> (avg {host_avg:.0f} Gbps){nic_lines}',
            'hostAvg': round(host_avg, 1),
            'isDown': is_down,
        }
        for n in nics:
            sw = n.get('switch', '')
            if sw and sw != 'unknown' and sw in topo_nodes:
                edge_color = '#4ecca3' if n['avg_gbps'] >= G else '#0dcaf0' if n['avg_gbps'] >= F else '#ffc107' if n['avg_gbps'] >= S else '#e94560'
                if n['ip'] in data['down_ips']:
                    edge_color = '#666666'
                topo_edges.append({
                    'from': host, 'to': sw,
                    'color': {'color': edge_color, 'highlight': '#ffffff'},
                    'title': f"{n['ip']} via {n.get('port_desc','')} — {n['avg_gbps']} Gbps",
                    'width': max(1, n['avg_gbps'] / (L / 4)),
                })

    topo_nodes_json = json.dumps(list(topo_nodes.values()))
    topo_edges_json = json.dumps(topo_edges)

    meta = data['metadata']
    duration = meta.get('duration', 20)
    total_hosts = meta.get('total_hosts', len(data["raw_hosts"]))
    timestamp = meta.get('timestamp', '')
    end_timestamp = meta.get('end_timestamp', '')

    # Connection-level stats: how many unique IPs, how many healthy
    total_ips = len(ip_avgs)
    healthy_ips = sum(1 for ip, v in ip_avgs.items() if v >= tip(ip, 'G'))
    functional_ips = sum(1 for ip, v in ip_avgs.items() if tip(ip, 'F') <= v < tip(ip, 'G'))
    needs_repair = total_ips - healthy_ips - functional_ips

    # Paths, rails and hosts the run could not test, with the reason
    # Preflight card: swapped rails, cabling to the other rail's switch, MTU mismatch, gateways
    preflight_html = ''
    if data.get('anomalies') or data.get('gateways'):
        gws = data.get('gateways', [])
        gw_ok = sum(1 for g in gws if g[-1] == 'OK')
        gw_direct = sum(1 for g in gws if g[-1] == 'DIRECT')
        gw_bad = [g for g in gws if g[-1] not in ('OK', 'DIRECT')]
        kinds = {'swapped_nics': 'Rail NICs swapped', 'rail_nic_overlap': 'Rail NIC names mixed',
                 'lldp_wrong_rail': "Cabled to the other rail's switch", 'mtu_mismatch': 'MTU differs on a rail',
                 'gateway_FAIL': 'Rail gateway not answering', 'gateway_MTU': 'Rail gateway answers small pings only',
                 'mesh_unreachable': 'Rail IP unreachable in the mesh',
                 'mesh_no_replies': 'Rail IP gets no replies in the mesh'}
        rows = ''.join(f"<tr><td>{escape(kinds.get(a[1], a[1]) if len(a) > 1 else '')}</td><td>{escape(a[0])}</td>"
                       f"<td>{escape(a[2] if len(a) > 2 else '')}</td></tr>" for a in data.get('anomalies', []))
        bad = len(data.get('anomalies', []))
        mp = data['metadata'].get('mesh_pings')
        mesh_txt = f" | mesh: {data['metadata'].get('mesh_failures', '?')} of {mp} pings failed" if mp else ''
        preflight_html = f"""<div class="card mb-3"><div class="card-header">Preflight: rail layout and gateways |
<b class="{'stat-bad' if bad else 'stat-good'}">{bad}</b> findings | gateways: {gw_ok} answered a full-MTU ping, {len(gw_bad)} failed, {gw_direct} rails on-link{mesh_txt}</div>
<div class="card-body" style="max-height:300px; overflow-y:auto;">{'<p class="text-success mb-0">No rail swaps, cross-rail cabling, MTU differences or gateway failures found.</p>' if not bad else
f'<table class="table table-sm table-striped"><thead><tr><th>Finding</th><th>Host / rail</th><th>Detail</th></tr></thead><tbody>{rows}</tbody></table>'}</div></div>"""

    # FEC over the run: uncorrectable blocks and pre-FEC BER, not lifetime counts
    fec_html = ''
    fr = data.get('fec_rate', [])
    if fr:
        exposed = [f for f in fr if f['status'] not in ('n/a', 'FEC off')]
        n_off = sum(1 for f in fr if f['status'] == 'FEC off')
        cnt = {s: sum(1 for f in fr if f['status'] == s) for s in ('UNCORRECTABLE', 'OVER FEC LIMIT', 'WATCH')}
        show = [f for f in fr if f['status'] not in ('ok', 'n/a')] or exposed[:10]
        cls = {'UNCORRECTABLE': 'badge-down', 'OVER FEC LIMIT': 'badge-down', 'WATCH': 'badge-slow', 'ok': 'badge-ok'}
        def fec_row(f):
            ber = '' if f['ber'] is None else format(f['ber'], '.1e')
            cb = '' if f['cb'] is None else format(f['cb'], ',')
            ub = '' if f['ub'] is None else str(f['ub'])
            return (f"<tr><td>{escape(f['host'])}</td><td>{escape(f['nic'])}</td>"
                    f"<td><span class='badge {cls.get(f['status'], '')}'>{f['status']}</span></td>"
                    f"<td>{ber}</td><td>{cb}</td><td>{ub}</td><td>{f['secs']}</td><td>{'yes' if f['reset'] else ''}</td></tr>")
        rows = ''.join(fec_row(f) for f in show)
        fec_html = f"""<div class="card mb-3"><div class="card-header">FEC during this run (rate over {max(f['secs'] for f in fr)}s, not lifetime counts) |
counters on {len(exposed)} of {len(fr)} rail NICs{f' ({n_off} with FEC off)' if n_off else ''} | <b class="{'stat-bad' if cnt['UNCORRECTABLE'] else 'stat-good'}">{cnt['UNCORRECTABLE']}</b> uncorrectable |
<b class="{'stat-bad' if cnt['OVER FEC LIMIT'] else 'stat-good'}">{cnt['OVER FEC LIMIT']}</b> over the FEC limit | <b class="{'stat-warn' if cnt['WATCH'] else 'stat-good'}">{cnt['WATCH']}</b> watch</div>
<div class="card-body" style="max-height:320px; overflow-y:auto;">
<p class="mb-1" style="font-size:0.8rem; color:#8899aa;">Pre-FEC BER = corrected bits / (seconds x link rate). Over limit: at or above {FEC_LIMIT_BER:.1e}, the correction limit commonly quoted for RS(544,514) "KP4" FEC on 200/400G PAM4 links (NRZ links on RS(528,514) correct less). Watch: {FEC_WATCH_BER:.0e}, a heuristic. Any uncorrectable block means errors reached the host.</p>
<table class="table table-sm table-striped"><thead><tr><th>Host</th><th>NIC</th><th>Status</th><th>Pre-FEC BER</th><th>Corrected blocks</th><th>Uncorrectable</th><th>Seconds</th><th>Counter reset</th></tr></thead><tbody>{rows}</tbody></table></div></div>"""

    # --compare: what changed per rail NIC since an older run
    compare_html = ''
    cmp_ = data.get('compare')
    if cmp_:
        rows = ''.join(f"<tr><td>{escape(h)}</td><td>{escape(n)}</td><td>{escape(k)}</td><td>{escape(str(o))}</td><td>{escape(str(v))}</td></tr>"
                       for h, n, k, o, v in cmp_['changes'])
        downs = ''
        if cmp_['down_added'] or cmp_['down_cleared']:
            downs = (f"<p class=\"mb-1\">Newly down: <b class=\"stat-bad\">{escape(', '.join(cmp_['down_added']) or 'none')}</b> | "
                     f"Recovered: <b class=\"stat-good\">{escape(', '.join(cmp_['down_cleared']) or 'none')}</b></p>")
        compare_html = f"""<div class="card mb-3"><div class="card-header">Compared with the run of {escape(cmp_['old_ts'])} ({escape(cmp_['old_label'])}):
<b>{len(cmp_['changes'])}</b> NIC changes, {len(cmp_['down_added'])} newly down IPs, {len(cmp_['down_cleared'])} recovered</div>
<div class="card-body" style="max-height:360px; overflow-y:auto;">{downs}
<p class="mb-1" style="font-size:0.8rem; color:#8899aa;">Per rail NIC (host + NIC), since pairings differ between runs. Throughput is compared per direction (sent, received); a drop seen only as received usually follows a drop on the sending NIC listed with it. Changes of 10% or more are listed; a lifetime counter that went down was reset (reboot or driver reload).</p>
{'<p class="text-success mb-0">No NIC-level changes.</p>' if not rows else f'<table class="table table-sm table-striped"><thead><tr><th>Host</th><th>NIC</th><th>What</th><th>Before</th><th>Now</th></tr></thead><tbody>{rows}</tbody></table>'}</div></div>"""

    no_drops_msg = ('<p class="text-warning mb-0">Drop counters were not read on this run: unknown, not zero.</p>'
                    if data.get('drops_unknown') else
                    '<p class="text-success mb-0">No packet drops detected during testing.</p>')

    # Fail-loud banner: incomplete or empty data must not read as a clean result
    uplinks_html = _uplinks_html(_uplinks(data))
    problems_html = ''
    if data.get('problems') or data.get('notes'):
        items = ''.join(f'<li>{escape(p)}</li>' for p in data.get('problems', []))
        nts = ''.join(f'<li style="color:#ffc107;">{escape(n)}</li>' for n in data.get('notes', []))
        head = ('INCOMPLETE RESULT: do not read this dashboard as a clean bill of health'
                if data.get('problems') else 'Notes on this run')
        border = '#e94560' if data.get('problems') else '#ffc107'
        problems_html = (f'<div class="card mb-3" style="border:2px solid {border};"><div class="card-header" '
                         f'style="color:{border}; font-weight:700;">{head}</div><div class="card-body"><ul class="mb-0">'
                         f'{items}{nts}</ul></div></div>')

    # UDP pass: loss placed per receiving host and phase; unaccounted = likely fabric
    udp_html = ''
    ok_rows = [u for u in data.get('udp', []) if 'error' not in u]
    if data.get('udp'):
        lost = sum(u['lost'] for u in ok_rows); sent = sum(u['sent'] for u in ok_rows)
        sock = sum(u['sock'] for u in ok_rows); nic = sum(u['nic'] for u in ok_rows)
        back = sum(u['back'] for u in ok_rows); unacc = sum(u['unacc'] for u in ok_rows)
        errs = len(data['udp']) - len(ok_rows)
        avg = sum(u['gbps'] for u in ok_rows) / len(ok_rows) if ok_rows else 0
        notes = []
        old = [f"{v[0]} ({v[1]})" for v in data.get('iperf3_versions', [])
               if len(v) > 1 and re.match(r'^\d+\.\d+', v[1]) and tuple(int(x) for x in v[1].split('.')[:2]) < (3, 16)]
        if old:
            notes.append(f"iperf3 older than 3.16 (single-threaded; UDP ceiling is host CPU-bound): {', '.join(old)}")
        small = [f"{v[0]} ({v[2]})" for v in data.get('iperf3_versions', []) if len(v) > 2 and v[2].isdigit() and int(v[2]) < 4194304]
        if small:
            notes.append(f"net.core.rmem_max under 4 MiB inflates receiver-socket loss: {', '.join(small)}")
        rows = ''.join(
            f"<tr><td>{escape(u['iter'])} {escape(u['phase'])}</td><td>{escape(u['src_host'])} {escape(u['src'])}</td>"
            f"<td>{escape(u['dst_host'])} {escape(u['dst'])}</td><td>{u['gbps']:g}</td><td>{u['lost']:,}/{u['sent']:,}</td>"
            f"<td>{100 * u['lost'] / u['sent'] if u['sent'] else 0:.3f}</td><td>{u['sock']:,}</td><td>{u['nic']:,}</td>"
            f"<td>{u['back']:,}</td><td class=\"{'text-danger' if u['unacc'] else ''}\">{u['unacc']:,}</td></tr>"
            for u in sorted(ok_rows, key=lambda u: (-u['unacc'], -u['lost'])))
        udp_html = f"""<div class="card mb-3"><div class="card-header">UDP, no rate cap (iperf3 -u -b 0): avg {avg:.1f} Gbps per run |
lost {lost:,} of {sent:,} datagrams ({100 * lost / sent if sent else 0:.3f}%): receiver socket {sock:,}, NIC {nic:,}, kernel backlog {back:,},
<b class="{'stat-bad' if unacc else 'stat-good'}">unaccounted (likely fabric) {unacc:,}</b>{f' | {errs} runs with no result' if errs else ''}</div>
<div class="card-body" style="max-height:360px; overflow-y:auto;">{''.join(f'<p class="text-warning mb-1">{escape(n)}</p>' for n in notes)}
<p class="mb-1" style="font-size:0.8rem; color:#8899aa;">Host-side buckets are the receiving host's counters for that phase (not per flow); unaccounted = lost minus those, floored at 0.</p>
<table class="table table-sm table-striped"><thead><tr><th>Run</th><th>From</th><th>To</th><th>Gbps</th><th>Lost/Sent</th><th>Loss %</th>
<th>Rx socket</th><th>NIC</th><th>Backlog</th><th>Unaccounted</th></tr></thead><tbody>{rows}</tbody></table></div></div>"""

    not_tested_html = ''
    if data['not_tested']:
        rows = ''.join(f"<tr><td>{escape(n['kind'])}</td><td>{escape(n['what'])}</td><td>{escape(n['why'])}</td></tr>"
                       for n in data['not_tested'])
        not_tested_html = f"""<div class="card mb-3"><div class="card-header">Not tested — {len(data['not_tested'])} rows (paths, rails, hosts, unreachable targets)</div>
<div class="card-body" style="max-height:320px; overflow-y:auto;"><table class="table table-sm table-striped">
<thead><tr><th>Kind</th><th>What</th><th>Why</th></tr></thead><tbody>{rows}</tbody></table></div></div>"""

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{label} Data Plane Validation</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
<link href="https://cdn.datatables.net/1.13.4/css/dataTables.bootstrap5.min.css" rel="stylesheet">
<script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
<script src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"></script>
<style>
body {{ background: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; }}
.card {{ background: #16213e; border: 1px solid #0f3460; margin-bottom: 6px; }}
.card-header {{ background: #0f3460; color: #e94560; font-weight: 600; border-bottom: 1px solid #0f3460; padding: 6px 12px; font-size: 0.85rem; }}
.card-body {{ padding: 8px 12px; }}
.stat-card {{ text-align: center; padding: 12px; }}
.stat-number {{ font-size: 2.2rem; font-weight: 700; }}
.row.g-3 {{ --bs-gutter-y: 0.5rem; --bs-gutter-x: 0.5rem; }}
.mt-1 {{ margin-top: 0.25rem !important; }}
th small {{ display: block; font-weight: 400; color: #8899aa; font-size: 0.7rem; }}
.stat-good {{ color: #4ecca3; }}
.stat-warn {{ color: #ffc107; }}
.stat-bad {{ color: #e94560; }}
.stat-info {{ color: #0dcaf0; }}
.stat-label {{ color: #8899aa; font-size: 0.85rem; margin-top: 4px; }}
.nav-tabs .nav-link {{ color: #8899aa; border: none; padding: 6px 14px; font-size: 0.9rem; }}
.nav-tabs .nav-link.active {{ color: #e94560; background: #0f3460; border-bottom: 2px solid #e94560; }}
.nav-tabs {{ border-bottom: 1px solid #0f3460; }}
.table {{ color: #e0e0e0; }}
.table thead th {{ background: #0f3460; color: #4ecca3; border-bottom: 2px solid #e94560; position: sticky; top: 0; }}
.table-striped tbody tr:nth-of-type(odd) {{ background: rgba(15,52,96,0.3); }}
.table-hover tbody tr:hover {{ background: rgba(78,204,163,0.1); }}
.badge-down {{ background: #e94560; }}
.badge-slow {{ background: #ffc107; color: #000; }}
.badge-func {{ background: #0dcaf0; color: #000; }}
.badge-ok {{ background: #4ecca3; color: #000; }}
.diag-warn {{ color: #e94560; font-weight: 600; }}
.header-bar {{ background: linear-gradient(135deg, #0f3460 0%, #1a1a2e 100%); padding: 20px 30px; margin-bottom: 20px; border-radius: 8px; border: 1px solid #0f3460; }}
.header-bar h1 {{ color: #4ecca3; margin: 0; }}
.header-bar .subtitle {{ color: #8899aa; }}
.dataTables_wrapper .dataTables_filter input {{ background: #1a1a2e !important; border: 1px solid #0f3460 !important; color: #e0e0e0 !important; }}
.dataTables_wrapper .dataTables_length select {{ background: #1a1a2e !important; border: 1px solid #0f3460 !important; color: #e0e0e0 !important; }}
.dataTables_wrapper .dataTables_info, .dataTables_wrapper .dataTables_paginate {{ color: #8899aa !important; }}
.page-link {{ background: #16213e; border-color: #0f3460; color: #e0e0e0; }}
.page-link:hover {{ background: #0f3460; color: #4ecca3; }}
.page-item.active .page-link {{ background: #e94560; border-color: #e94560; }}
.full-width-chart {{ width: 100%; }}
td.dt-row-num {{ color: #556; font-size: 0.8em; text-align: right; width: 30px; }}
</style>
</head>
<body>

<div class="container-fluid px-3 py-2">

<!-- Header — single compact line -->
<div style="background:#0f3460; padding:10px 20px; margin-bottom:12px; border-radius:6px; border:1px solid #0f3460; display:flex; flex-wrap:wrap; align-items:baseline; gap:6px 20px;">
    <span style="color:#4ecca3; font-size:1.1rem; font-weight:700;">{label} Data Plane Validation</span>
    <span style="color:#8899aa; font-size:0.85rem;">{timestamp} | line rate {L}G ({data['line_rate_src']}){rail_note}</span>
    <span style="color:#e0e0e0; font-size:0.85rem;">
        <b class="stat-info">{total_ips}</b> connections |
        <b class="stat-good">{healthy_ips}</b> healthy (&ge;{G}G) |
        <b class="stat-info">{functional_ips}</b> functional ({F}-{G}G) |
        <b class="{'stat-bad' if needs_repair > 20 else 'stat-warn'}">{needs_repair}</b> need repair (&lt;{F}G) |
        <b class="stat-bad">{len(data['down_ips'])}</b> down |
        avg <b class="{'stat-good' if avg_gbps >= F else 'stat-warn'}">{avg_gbps:.0f}</b> Gbps ({pct_line:.0f}%) |
        <b class="{'stat-good' if total_retransmits == 0 else 'stat-warn' if total_retransmits < 1000 else 'stat-bad'}">{total_retransmits:,}</b> retransmits ({retransmit_pct_str}%) |
        <b class="{'stat-good' if nics_with_drops == 0 else 'stat-bad'}">{nics_with_drops}</b> NIC drops |
        <b class="{'stat-good' if not data['not_tested'] else 'stat-bad'}">{len(data['not_tested'])}</b> not tested
    </span>
</div>
{problems_html}
{uplinks_html}
{compare_html}
{preflight_html}
{fec_html}
{not_tested_html}
{udp_html}

<!-- Tabs — connection health first -->
<ul class="nav nav-tabs mb-2" role="tablist">
    <li class="nav-item"><a class="nav-link active" data-bs-toggle="tab" href="#tab-connections">Connection Health</a></li>
    <li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-slow">Needs Repair ({needs_repair})</a></li>
    <li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-nic">NIC / Optics</a></li>
    <li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-distribution">Test Distribution</a></li>
    <li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-topology">Topology</a></li>
    <li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-all">Raw Data ({count})</a></li>
</ul>

<div class="tab-content">

<!-- Tab: Connection Health (default) -->
<div class="tab-pane fade show active" id="tab-connections">
    <div class="card">
        <div class="card-header">Average Throughput per Connection — {total_ips} IPs sorted lowest to highest (green=healthy &ge;{G}G, blue=functional {F}-{G}G, yellow &lt;{F}G, red &lt;{S}G)</div>
        <div class="card-body p-2">
            <div id="ipBarChart" class="full-width-chart"></div>
        </div>
    </div>
</div>

<!-- Tab: Needs Repair -->
<div class="tab-pane fade" id="tab-slow">
    <div class="card">
        <div class="card-header" style="display:flex; justify-content:space-between; align-items:center;">Connections Below Functional (&lt;{F} Gbps) — with NIC Diagnostics<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv('slowIpTable','needs_repair.csv')">Download CSV</button></div>
        <div class="card-body"><div id="slowIpContainer"></div></div>
    </div>
</div>

<!-- Tab: NIC / Optics -->
<div class="tab-pane fade" id="tab-nic">
    <div class="row g-3">
        <div class="col-md-4">
            <div class="card"><div class="card-header" style="display:flex; justify-content:space-between; align-items:center;">NIC Inventory<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv('not400Table','nic_not400g.csv')">Download CSV</button></div><div class="card-body">
                <p>Total NICs: <strong>{data['nic_inventory']['total']}</strong> | At {at_l}: <strong class="text-success">{data['nic_inventory']['at_line']}</strong> | Not {at_l}: <strong class="text-danger">{len(data['nic_inventory']['not_line'])}</strong> | Speed unknown: <strong>{data['nic_inventory']['unknown']}</strong></p>
                <h6 class="text-danger mt-3">Down / Not-{at_l} / speed-unknown NICs</h6>
                <table class="table table-sm table-striped" id="not400Table">
                <thead><tr><th>Host</th><th>NIC</th><th>IP</th><th>Speed<small>expected {L}G</small></th></tr></thead>
                <tbody>
                {''.join(f"<tr><td>{n['host']}</td><td>{n['nic']}</td><td>{n['ip']}</td><td><span class='badge badge-down'>{n['speed']}</span></td></tr>" for n in data['nic_inventory']['not_line'] + data['nic_inventory']['unknown_list'])}
                </tbody></table>
            </div></div>
        </div>
        <div class="col-md-4">
            <div class="card"><div class="card-header">Driver / Firmware Homogeneity</div><div class="card-body">
                <h6>Firmware Versions</h6>
                <table class="table table-sm table-striped mb-3">
                <thead><tr><th>Firmware</th><th>Count</th></tr></thead>
                <tbody>{''.join(f"<tr><td>{fw}</td><td>{c}</td></tr>" for fw, c in sorted(fw_counts.items(), key=lambda x: -x[1]))}</tbody></table>
                <h6>Driver Versions</h6>
                <table class="table table-sm table-striped">
                <thead><tr><th>Driver</th><th>Count</th></tr></thead>
                <tbody>{''.join(f"<tr><td>{d}</td><td>{c}</td></tr>" for d, c in sorted(drv_counts.items(), key=lambda x: -x[1]))}</tbody></table>
            </div></div>
        </div>
        <div class="col-md-4">
            <div class="card"><div class="card-header">Switch Connectivity (LLDP)</div><div class="card-body">
                <h6>Connected Switches</h6>
                <table class="table table-sm table-striped">
                <thead><tr><th>Switch</th><th>Ports</th></tr></thead>
                <tbody>{''.join(f"<tr><td>{sw}</td><td>{c}</td></tr>" for sw, c in sorted(switch_counts.items(), key=lambda x: -x[1]))}</tbody></table>
            </div></div>
        </div>
    </div>
    {'<div class="row g-3 mt-1"><div class="col-12"><div class="card"><div class="card-header text-danger" style="display:flex; justify-content:space-between; align-items:center;">Packet Drops During Testing (' + str(nics_with_drops) + ' NICs affected)<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv(&#39;dropsTable&#39;,&#39;packet_drops.csv&#39;)">Download CSV</button></div><div class="card-body"><table class="table table-sm table-striped table-hover" id="dropsTable"><thead><tr><th>#</th><th>Host/NIC</th><th>IP</th><th>Rx Dropped<small>ideal 0</small></th><th>Tx Dropped<small>ideal 0</small></th><th>Rx OOB<small>ideal 0</small></th><th>Phases</th></tr></thead><tbody>' + "".join(f"<tr><td></td><td>{d['host_nic']}</td><td>{d['ip']}</td><td>{d['rx_drop']:,}</td><td>{d['tx_drop']:,}</td><td>{d['rx_oob']:,}</td><td>{d['phases']}</td></tr>" for d in drops) + '</tbody></table></div></div></div></div>' if drops else '<div class="row g-3 mt-1"><div class="col-12"><div class="card"><div class="card-header">Packet Drops</div><div class="card-body">' + no_drops_msg + '</div></div></div></div>'}
    <div class="row g-3 mt-1">
        <div class="col-md-6">
            <div class="card"><div class="card-header">Top 50 FEC Corrected Bits (cumulative since the counters last reset; not a rate)</div>
            <div class="card-body"><div id="fecChart" style="height:400px;"></div></div></div>
        </div>
        <div class="col-md-6">
            <div class="card"><div class="card-header" style="display:flex; justify-content:space-between; align-items:center;">LLDP Neighbor Table ({len(data['lldp_info'])} entries)<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv('lldpTable','lldp_neighbors.csv')">Download CSV</button></div><div class="card-body">
                <table class="table table-sm table-striped table-hover" id="lldpTable">
                <thead><tr><th>#</th><th>Host</th><th>NIC</th><th>IP</th><th>Switch</th><th>Switch Port</th><th>LLDP Sys</th></tr></thead>
                <tbody>
                {''.join(f"<tr><td></td><td>{l['host']}</td><td>{l['nic']}</td><td>{l['ip']}</td><td>{l['switch']}</td><td>{l['port_desc']}</td><td>{l['sys_desc']}</td></tr>" for l in data['lldp_info'])}
                </tbody></table>
            </div></div>
        </div>
    </div>
    <div class="row g-3 mt-1">
        <div class="col-md-6">
            <div class="card"><div class="card-header" style="display:flex; justify-content:space-between; align-items:center;">FEC Details — All {len(fec_data)} NICs with Corrected Bits<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv('fecTable','fec_details.csv')">Download CSV</button></div><div class="card-body">
                <table class="table table-sm table-striped table-hover" id="fecTable">
                <thead><tr><th>#</th><th>Host</th><th>NIC</th><th>IP</th><th>Corrected Bits<small>ideal 0</small></th><th>Lane 0<small>ideal 0</small></th><th>Lane 1<small>ideal 0</small></th><th>Lane 2<small>ideal 0</small></th><th>Lane 3<small>ideal 0</small></th></tr></thead>
                <tbody>
                {''.join(f"<tr><td></td><td>{f['host']}</td><td>{f['nic']}</td><td>{f['ip']}</td><td>{f['corrected']:,}</td>" + ''.join(f"<td>{l:,}</td>" for l in f['lanes']) + "</tr>" for f in fec_data)}
                </tbody></table>
            </div></div>
        </div>
        <div class="col-md-6">
            <div class="card"><div class="card-header" style="display:flex; justify-content:space-between; align-items:center;">Driver Inventory ({len(data['driver_info'])} NICs)<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv('driverTable','driver_inventory.csv')">Download CSV</button></div><div class="card-body">
                <table class="table table-sm table-striped table-hover" id="driverTable">
                <thead><tr><th>#</th><th>Host</th><th>NIC</th><th>IP</th><th>Driver</th><th>Version</th><th>Firmware</th><th>Part Number</th></tr></thead>
                <tbody>
                {''.join(f"<tr><td></td><td>{d['host']}</td><td>{d['nic']}</td><td>{d['ip']}</td><td>{d['driver']}</td><td>{d['version']}</td><td>{d['firmware']}</td><td>{d.get('part','')}</td></tr>" for d in data['driver_info'])}
                </tbody></table>
            </div></div>
        </div>
    </div>
    <div class="row g-3 mt-1">
        <div class="col-12">
            <div class="card"><div class="card-header" style="display:flex; justify-content:space-between; align-items:center;">Optics — {len(optics_data)} Transceivers<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv('opticsTable','optics.csv')">Download CSV</button></div><div class="card-body">
                <table class="table table-sm table-striped table-hover" id="opticsTable">
                <thead><tr><th>#</th><th>Host</th><th>NIC</th><th>IP</th><th>RX Ch1 (dBm)<small>ideal ~2</small></th><th>RX Ch2 (dBm)<small>ideal ~2</small></th><th>RX Ch3 (dBm)<small>ideal ~2</small></th><th>RX Ch4 (dBm)<small>ideal ~2</small></th><th>Temp (°C)<small>ideal &lt;45</small></th></tr></thead>
                <tbody>
                {''.join(_optics_row(o) for o in optics_data)}
                </tbody></table>
            </div></div>
        </div>
    </div>
</div>

<!-- Tab: Test Distribution -->
<div class="tab-pane fade" id="tab-distribution">
    <div class="row g-3">
        <div class="col-md-6">
            <div class="card"><div class="card-header">Throughput Histogram ({count} tests)</div>
            <div class="card-body"><div id="histChart" style="height:400px;"></div></div></div>
        </div>
        <div class="col-md-6">
            <div class="card"><div class="card-header">Consistency Across Iterations</div>
            <div class="card-body"><div id="boxChart" style="height:400px;"></div></div></div>
        </div>
    </div>
    <div class="row g-3 mt-1">
        <div class="col-12">
            <div class="card"><div class="card-header" style="display:flex; justify-content:space-between; align-items:center;">Bottom 50 Individual Test Results<button class="btn btn-sm btn-outline-info" onclick="downloadTableCsv('bottomTable','bottom_50.csv')">Download CSV</button></div>
            <div class="card-body">
                <table class="table table-striped table-hover table-sm" id="bottomTable">
                <thead><tr><th>#</th><th>Host A</th><th>IP A</th><th>Host B</th><th>IP B</th><th>Gbps<small>expected {L}</small></th><th>Retrans<small>ideal 0</small></th><th>GBytes</th></tr></thead>
                <tbody>
                {''.join(f"<tr><td></td><td>{h(r['src'])}</td><td>{r['src']}</td><td>{h(r['dst'])}</td><td>{r['dst']}</td><td><span class='badge {'badge-ok' if r['gbps']>=tpath(r, 'G') else 'badge-func' if r['gbps']>=tpath(r, 'F') else 'badge-slow' if r['gbps']>=tpath(r, 'S') else 'badge-down'}'>{r['gbps']}</span></td><td>{'<span class=badge-down>' + str(r.get('retransmits',0)) + '</span>' if r.get('retransmits',0) > 0 else '0'}</td><td>{r['gbytes']}</td></tr>" for r in bottom_50)}
                </tbody></table>
            </div></div>
        </div>
    </div>
</div>

<!-- Tab: Topology -->
<div class="tab-pane fade" id="tab-topology">
    <div class="card">
        <div class="card-header">
            Network Topology — hosts colored by avg throughput (green=healthy &ge;{G}G, blue=functional {F}-{G}G, yellow &lt;{F}G, red &lt;{S}G, gray=down)
        </div>
        <!-- Controls toolbar row 1 -->
        <div style="background:#0f3460; padding:8px 15px; display:flex; flex-wrap:wrap; gap:12px; align-items:center; font-size:0.85rem; border-bottom:1px solid #1a1a2e;">
            <!-- Layout -->
            <div>
                <label style="color:#8899aa;">Layout:</label>
                <div class="btn-group btn-group-sm ms-1">
                    <button class="btn btn-outline-light active" id="tBtnHier" onclick="topoSetLayout('hierarchical')">Hierarchical</button>
                    <button class="btn btn-outline-light" id="tBtnForce" onclick="topoSetLayout('force')">Force</button>
                    <button class="btn btn-outline-light" id="tBtnRadial" onclick="topoSetLayout('radial')">Radial</button>
                </div>
            </div>
            <!-- Filter mode toggle -->
            <div class="form-check form-switch">
                <input class="form-check-input" type="checkbox" id="topoFilterMode">
                <label class="form-check-label" for="topoFilterMode" style="color:#8899aa;" id="topoFilterModeLabel">Host avg</label>
            </div>
            <!-- Filter thresholds -->
            <div>
                <label style="color:#8899aa;">Show:</label>
                <div class="btn-group btn-group-sm ms-1" id="topoFilterBtns">
                    <button class="btn btn-outline-light active" data-thresh="0" onclick="topoFilter(0)">All</button>
                    <button class="btn btn-outline-success" data-thresh="{G}" onclick="topoFilter({G})">&gt;{G}G</button>
                    <button class="btn btn-outline-info" data-thresh="{F}" onclick="topoFilter({F})">&gt;{F}G</button>
                    <button class="btn btn-outline-warning" data-thresh="{M}" onclick="topoFilter({M})">&gt;{M}G</button>
                    <button class="btn btn-outline-danger" data-thresh="{S}" onclick="topoFilter({S})">&gt;{S}G</button>
                    <button class="btn btn-outline-secondary" data-thresh="-1" onclick="topoFilter(-1)">Down</button>
                </div>
            </div>
            <!-- Toggles -->
            <div class="form-check form-switch ms-2">
                <input class="form-check-input" type="checkbox" id="topoToggleLabels" checked onchange="topoToggleOpt('labels')">
                <label class="form-check-label" for="topoToggleLabels" style="color:#8899aa;">Labels</label>
            </div>
            <div class="form-check form-switch">
                <input class="form-check-input" type="checkbox" id="topoTogglePhysics" checked onchange="topoToggleOpt('physics')">
                <label class="form-check-label" for="topoTogglePhysics" style="color:#8899aa;">Physics</label>
            </div>
            <div class="form-check form-switch">
                <input class="form-check-input" type="checkbox" id="topoToggleSmooth" checked onchange="topoToggleOpt('smooth')">
                <label class="form-check-label" for="topoToggleSmooth" style="color:#8899aa;">Smooth edges</label>
            </div>
            <div class="ms-auto">
                <button class="btn btn-sm btn-outline-light" onclick="topoNetwork && topoNetwork.fit()">Fit</button>
                <button class="btn btn-sm btn-outline-success" onclick="resetTopo()">Reset</button>
            </div>
        </div>
        <!-- Controls toolbar row 2: focus/exclude -->
        <div style="background:#0f3460; padding:8px 15px; display:flex; flex-wrap:wrap; gap:12px; align-items:center; font-size:0.85rem;">
            <!-- Focus switch -->
            <div>
                <label style="color:#8899aa;">Switch:</label>
                <select id="topoSwitchSelect" class="form-select form-select-sm d-inline-block" style="width:auto; background:#1a1a2e; color:#e0e0e0; border-color:#4ecca3;" onchange="topoFocusSwitch(this.value)">
                    <option value="">All switches</option>
                    {''.join(f'<option value="{sw}">{sw.split(".")[0]}</option>' for sw in sorted(switch_counts) if sw != "unknown")}
                </select>
            </div>
            <!-- Exclude hosts -->
            <div>
                <label style="color:#8899aa;">Exclude host:</label>
                <select id="topoExcludeHost" class="form-select form-select-sm d-inline-block" style="width:auto; background:#1a1a2e; color:#e0e0e0; border-color:#e94560;" onchange="topoExclude()">
                    <option value="">None</option>
                </select>
            </div>
            <!-- Exclude links -->
            <div>
                <label style="color:#8899aa;">Exclude link:</label>
                <select id="topoExcludeLink" class="form-select form-select-sm d-inline-block" style="width:auto; background:#1a1a2e; color:#e0e0e0; border-color:#e94560;" onchange="topoExclude()">
                    <option value="">None</option>
                </select>
            </div>
            <div>
                <button class="btn btn-sm btn-outline-warning" onclick="topoClearExclusions()">Clear exclusions</button>
                <span class="ms-2" style="color:#8899aa;" id="topoExcludeCount"></span>
            </div>
        </div>
        <div class="card-body p-0" style="position:relative;">
            <div id="topoNetwork" style="height:700px; background:#1a1a2e;"></div>
            <!-- Legend overlay — top-left of map, hover to expand -->
            <div id="topoLegend" style="position:absolute; top:10px; left:10px; background:rgba(15,52,96,0.95); padding:8px 12px; border-radius:6px; font-size:0.8rem; color:#e0e0e0; line-height:1.7; z-index:10; min-width:160px; cursor:default;">
                <div style="font-weight:600; margin-bottom:4px; color:#4ecca3;">Displayed</div>
                <div>Backends: <b id="legHosts">0</b> &nbsp; Links: <b id="legLinks">0</b> &nbsp; Switches: <b id="legSwitches">0</b></div>
                <!-- Hover detail -->
                <div id="topoLegendDetail" style="display:none; margin-top:6px; border-top:1px solid rgba(78,204,163,0.3); padding-top:6px;">
                    <table style="width:100%; font-size:0.78rem; color:#ccc;">
                        <tr style="color:#8899aa;"><th></th><th style="text-align:right;">Hosts</th><th style="text-align:right;">Links</th></tr>
                        <tr><td><span style="color:#4ecca3;">&bull;</span> Healthy (&ge;{G}G)</td><td style="text-align:right;" id="legH350">0</td><td style="text-align:right;" id="legL350">0</td></tr>
                        <tr><td><span style="color:#0dcaf0;">&bull;</span> Functional ({F}-{G}G)</td><td style="text-align:right;" id="legH300">0</td><td style="text-align:right;" id="legL300">0</td></tr>
                        <tr><td><span style="color:#ffc107;">&bull;</span> {M}-{F}G</td><td style="text-align:right;" id="legH250">0</td><td style="text-align:right;" id="legL250">0</td></tr>
                        <tr><td><span style="color:#ffc107;">&bull;</span> {S}-{M}G</td><td style="text-align:right;" id="legH200">0</td><td style="text-align:right;" id="legL200">0</td></tr>
                        <tr><td><span style="color:#e94560;">&bull;</span> &lt;{S}G</td><td style="text-align:right;" id="legHLow">0</td><td style="text-align:right;" id="legLLow">0</td></tr>
                        <tr><td><span style="color:#666;">&bull;</span> Down</td><td style="text-align:right;" id="legHDown">0</td><td style="text-align:right;" id="legLDown">0</td></tr>
                    </table>
                </div>
            </div>
        </div>
        <div class="card-footer" style="background:#0f3460; color:#8899aa; font-size:0.8rem;">
            Hover for details &bull; Drag nodes to reposition &bull; Double-click to unpin &bull; Scroll to zoom &bull; Edge width &amp; color = throughput
        </div>
    </div>
</div>

<!-- Tab: Raw Data -->
<div class="tab-pane fade" id="tab-all">
    <div class="card">
        <div class="card-header">All {count} iperf3 Results</div>
        <!-- Filter/controls toolbar -->
        <div style="background:#0f3460; padding:8px 15px; display:flex; flex-wrap:wrap; gap:12px; align-items:center; font-size:0.85rem;">
            <!-- Verbose toggle -->
            <div class="form-check form-switch">
                <input class="form-check-input" type="checkbox" id="rawVerbose" onchange="rawToggleVerbose()">
                <label class="form-check-label" for="rawVerbose" style="color:#8899aa;">Detail</label>
            </div>
            <!-- Speed filter -->
            <div>
                <label style="color:#8899aa;">Show:</label>
                <div class="btn-group btn-group-sm ms-1" id="rawFilterBtns">
                    <button class="btn btn-outline-light active" data-thresh="0" onclick="rawFilter(0)">All</button>
                    <button class="btn btn-outline-success" data-thresh="{G}" onclick="rawFilter({G})">&gt;{G}G</button>
                    <button class="btn btn-outline-info" data-thresh="{F}" onclick="rawFilter({F})">&gt;{F}G</button>
                    <button class="btn btn-outline-warning" data-thresh="{M}" onclick="rawFilter({M})">&gt;{M}G</button>
                    <button class="btn btn-outline-danger" data-thresh="{S}" onclick="rawFilter({S})">&gt;{S}G</button>
                </div>
            </div>
            <!-- Exclude host -->
            <div>
                <label style="color:#8899aa;">Exclude host:</label>
                <select id="rawExcludeHost" class="form-select form-select-sm d-inline-block" style="width:auto; background:#1a1a2e; color:#e0e0e0; border-color:#e94560;" onchange="rawExclude()">
                    <option value="">None</option>
                </select>
            </div>
            <div>
                <button class="btn btn-sm btn-outline-warning" onclick="rawClearFilters()">Clear filters</button>
                <span class="ms-2" style="color:#8899aa;" id="rawFilterCount"></span>
            </div>
            <div class="ms-auto">
                <small style="color:#8899aa;" title="TCP congestion control halves the send window on each retransmit, so even 0.1% retransmission causes significant throughput loss">Retransmit % is of total segments — even 0.1% halves TCP throughput repeatedly</small>
                <button class="btn btn-sm btn-outline-info ms-2" onclick="rawDownloadCsv()">Download CSV</button>
            </div>
        </div>
        <div class="card-body">
            <table class="table table-sm table-striped table-hover" id="allResultsTable">
            <thead><tr><th>#</th><th>Host</th><th>Status<small>worst of A, B, Cross (means)</small></th><th>Gbps<small>avg of NIC A &amp; B medians</small></th><th>Retrans<small>total TCP retransmits</small></th><th>IP A</th><th>Dev A</th><th>A Median<small>median Gbps across NIC A tests</small></th><th>A Retrans<small>total retransmits, NIC A</small></th><th>IP B</th><th>Dev B</th><th>B Median<small>median Gbps across NIC B tests</small></th><th>B Retrans<small>total retransmits, NIC B</small></th><th>Cross Median<small>median Gbps across A&lt;-&gt;B tests (a path, not a NIC)</small></th></tr></thead>
            <tbody></tbody></table>
        </div>
    </div>
</div>

</div><!-- tab-content -->

<div class="text-center mt-2" style="color:#555; font-size:0.8rem;">
    Generated from {INPUT_FILE} | Test ended {end_timestamp}
</div>

</div><!-- container -->

<script src="https://code.jquery.com/jquery-3.7.0.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script src="https://cdn.datatables.net/1.13.4/js/jquery.dataTables.min.js"></script>
<script src="https://cdn.datatables.net/1.13.4/js/dataTables.bootstrap5.min.js"></script>

<script>
var plotLayout = {{
    paper_bgcolor: '#16213e', plot_bgcolor: '#1a1a2e',
    font: {{ color: '#e0e0e0' }},
    xaxis: {{ gridcolor: '#0f3460', zerolinecolor: '#0f3460' }},
    yaxis: {{ gridcolor: '#0f3460', zerolinecolor: '#0f3460' }},
    margin: {{ t: 30, b: 60, l: 60, r: 20 }},
}};
var plotConfig = {{ responsive: true, displayModeBar: true, modeBarButtonsToRemove: ['lasso2d','select2d'] }};

// Connection Health — per-IP bar chart (full width, responsive height)
(function() {{
    var ips = {ip_labels};
    var avgs = {ip_values};
    var barHeight = Math.max(500, ips.length * 3);
    var el = document.getElementById('ipBarChart');
    el.style.height = barHeight + 'px';

    Plotly.newPlot(el, [{{
        x: ips, y: avgs, type: 'bar',
        marker: {{ color: avgs.map(v => v >= {G} ? '#4ecca3' : v >= {F} ? '#0dcaf0' : v >= {S} ? '#ffc107' : '#e94560') }},
        hovertemplate: '%{{x}}<br>Avg: %{{y}} Gbps<extra></extra>'
    }}], {{
        ...plotLayout,
        margin: {{ t: 10, b: 120, l: 50, r: 10 }},
        xaxis: {{ ...plotLayout.xaxis, tickangle: 90, tickfont: {{ size: 8 }}, dtick: 2 }},
        yaxis: {{ ...plotLayout.yaxis, title: 'Avg Throughput (Gbps)', range: [0, 420] }},
        shapes: [{{ type: 'line', x0: -0.5, x1: ips.length, y0: {F}, y1: {F},
            line: {{ color: '#e94560', width: 2, dash: 'dash' }} }}],
        annotations: [{{ x: 0, y: {F}, text: ' {F}G target', showarrow: false,
            font: {{ color: '#e94560', size: 11 }}, xanchor: 'left', yshift: 12 }}]
    }}, plotConfig);

    // Resize on tab show (Plotly needs visible container)
    $('a[href="#tab-connections"]').on('shown.bs.tab', function() {{ Plotly.Plots.resize(el); }});
}})();

// Histogram
Plotly.newPlot('histChart', [{{
    x: {speeds_json}, type: 'histogram',
    xbins: {{ size: 10 }},
    marker: {{
        color: {speeds_json}.map(s => s >= {G} ? '#4ecca3' : s >= {F} ? '#0dcaf0' : s >= {S} ? '#ffc107' : '#e94560'),
        line: {{ width: 1, color: '#0f3460' }}
    }},
    hovertemplate: '%{{x}} Gbps<br>%{{y}} tests<extra></extra>'
}}], {{
    ...plotLayout,
    xaxis: {{ ...plotLayout.xaxis, title: 'Throughput (Gbps)' }},
    yaxis: {{ ...plotLayout.yaxis, title: 'Number of Tests' }},
    shapes: [{{ type: 'line', x0: {F}, x1: {F}, y0: 0, y1: 1, yref: 'paper',
        line: {{ color: '#e94560', width: 2, dash: 'dash' }} }}],
    annotations: [{{ x: {F}, y: 1, yref: 'paper', text: '{F}G threshold', showarrow: false,
        font: {{ color: '#e94560', size: 11 }}, yshift: 10 }}]
}}, plotConfig);

// Box plot per iteration
Plotly.newPlot('boxChart', {iter_box_data}, {{
    ...plotLayout,
    yaxis: {{ ...plotLayout.yaxis, title: 'Throughput (Gbps)' }},
    showlegend: false,
    shapes: [{{ type: 'line', x0: -0.5, x1: 10, y0: {F}, y1: {F},
        line: {{ color: '#e94560', width: 2, dash: 'dash' }} }}]
}}, plotConfig);

// Resize plots when their tabs become visible
$('a[data-bs-toggle="tab"]').on('shown.bs.tab', function(e) {{
    window.dispatchEvent(new Event('resize'));
}});

// FEC chart
Plotly.newPlot('fecChart', [{{
    x: {fec_labels}, y: {fec_values}, type: 'bar',
    marker: {{ color: '#e94560' }},
    hovertemplate: '%{{x}}<br>%{{y:,.0f}} corrected bits<extra></extra>'
}}], {{
    ...plotLayout,
    xaxis: {{ ...plotLayout.xaxis, tickangle: 90, tickfont: {{ size: 8 }} }},
    yaxis: {{ ...plotLayout.yaxis, title: 'Corrected Bits', type: 'log' }},
}}, plotConfig);

// All table init in document.ready so dtOpts is available everywhere
$(document).ready(function() {{

    // Needs Repair table
    var slowData = {slow_ips_json};
    var slowContainer = document.getElementById('slowIpContainer');
    if (!slowData.length) {{ slowContainer.innerHTML = '<p class="text-success">All connections averaging &ge; {F} Gbps</p>'; }}
    else {{
        var slowHtml = '<table class="table table-sm table-striped table-hover" id="slowIpTable"><thead><tr><th>#</th><th>Host</th><th>IP</th><th>Avg Gbps<small>expected {L}</small></th><th>Samples</th><th>NIC</th><th>Speed<small>expected {L}G</small></th><th>FEC Corrected Bits<small>lifetime, not a rate</small></th><th>Diagnosis</th></tr></thead><tbody>';
        slowData.forEach(function(r) {{
            var d = r.diag || {{}};
            var badge = r.avg >= {F} ? 'badge-ok' : r.avg >= {S} ? 'badge-slow' : 'badge-down';
            slowHtml += '<tr><td></td><td>' + (d.host || '-') + '</td><td>' + r.ip + '</td><td><span class="badge ' + badge + '">' + r.avg.toFixed(1) + '</span></td><td>' + r.samples + (r.cross_only ? ' <small>(cross-rail runs only)</small>' : '') + '</td>';
            slowHtml += '<td>' + (d.nic || '-') + '</td><td>' + (d.speed || '-') + '</td>';
            slowHtml += '<td>' + (d.fec ? d.fec.toLocaleString() : '-') + '</td>';
            slowHtml += '<td class="diag-warn">' + (d.diagnosis || '-') + '</td></tr>';
        }});
        slowHtml += '</tbody></table>';
        slowContainer.innerHTML = slowHtml;
    }}

    // Raw data table — verbose (all rows) or summary (median per pair)
    var allData = {all_results_json};
    var ipHost = {ip_host_json};
    var ipNic = {ip_nic_json};

    // Build per-host overall avg
    var hostStats = {{}};
    allData.forEach(function(r) {{
        [ipHost[r.src]||r.src, ipHost[r.dst]||r.dst].forEach(function(h) {{
            if (!hostStats[h]) hostStats[h] = {{sum:0, cnt:0}};
            hostStats[h].sum += r.gbps;
            hostStats[h].cnt += 1;
        }});
    }});
    function hostAvg(host) {{
        var s = hostStats[host];
        return s ? Math.round(s.sum / s.cnt) : 0;
    }}
    function gbpsBadge(v) {{ return v >= {G} ? 'badge-ok' : v >= {F} ? 'badge-func' : v >= {S} ? 'badge-slow' : 'badge-down'; }}

    function median(arr) {{
        var s = arr.slice().sort(function(a,b){{ return a-b; }});
        var m = Math.floor(s.length/2);
        return s.length % 2 ? s[m] : Math.round((s[m-1]+s[m])/2);
    }}

    // Pre-compute per-host summary: one row per host with median per NIC
    // Rail per IP from rails.txt; archives without it (older collector) fall back to odd third octet = rail A
    var ipRail = {json.dumps(data.get('ip_rail', {}))};
    function isNicA(ip) {{ if (ipRail[ip]) return ipRail[ip] === 'A'; var parts = ip.split('.'); return parseInt(parts[2]) % 2 === 1; }}
    // a cross-rail run measures a path, not either NIC: kept out of the A/B medians, shown as its own column
    function isCross(r) {{ return isNicA(r.src) !== isNicA(r.dst); }}
    var railTiers = {json.dumps(badge_tiers)};
    function railBadge(v, rl) {{ var t = railTiers[rl]; return v >= t.G ? 'badge-ok' : v >= t.F ? 'badge-func' : v >= t.S ? 'badge-slow' : 'badge-down'; }}
    var downIps = new Set({json.dumps(data['down_ips'])});

    // Build per-host data: map all known IPs (from LLDP/driver) to hosts, include down NICs as 0
    var perHost = {{}};
    // First, seed every host's NIC IPs from the ip->host map
    Object.keys(ipHost).forEach(function(ip) {{
        var h = ipHost[ip];
        if (!perHost[h]) perHost[h] = {{ host: h, ipA: '', ipB: '', aGbps: [], bGbps: [], xGbps: [], aRetr: 0, bRetr: 0, xRetr: 0, aGB: 0, bGB: 0, xGB: 0 }};
        if (isNicA(ip)) perHost[h].ipA = ip;
        else perHost[h].ipB = ip;
    }});
    // Then attribute test results to hosts
    allData.forEach(function(r) {{
        var retr = r.retransmits || 0;
        var gb = r.gbytes || 0;
        var x = isCross(r);
        [r.src, r.dst].forEach(function(ip) {{
            var h = ipHost[ip] || ip;
            if (!perHost[h]) perHost[h] = {{ host: h, ipA: '', ipB: '', aGbps: [], bGbps: [], xGbps: [], aRetr: 0, bRetr: 0, xRetr: 0, aGB: 0, bGB: 0, xGB: 0 }};
            if (x) {{ perHost[h].xGbps.push(r.gbps); perHost[h].xRetr += retr; perHost[h].xGB += gb; }}
            else if (isNicA(ip)) {{ perHost[h].aGbps.push(r.gbps); perHost[h].aRetr += retr; perHost[h].aGB += gb; }}
            else {{ perHost[h].bGbps.push(r.gbps); perHost[h].bRetr += retr; perHost[h].bGB += gb; }}
        }});
    }});
    // Status, as in the collector summary: the worst column, each its mean judged at its rail's cut-offs (Cross at
    // the slower rail's); (cross) = only Cross is that bad; (1rail) = a rail without same-rail runs.
    function hostStatus(h) {{
        function lv(arr, rl) {{ if (!arr.length) return -1; var m = arr.reduce(function(a, b) {{ return a + b; }}, 0) / arr.length, t = railTiers[rl]; return m >= t.F ? 0 : m >= t.S ? 1 : 2; }}
        var a = lv(h.aGbps, 'A'), b = lv(h.bGbps, 'B'), x = lv(h.xGbps, 'X'), ws = Math.max(a, b), w = Math.max(ws, x);
        if (w < 0) return '-';
        return ['OK', 'SLOW', 'CRITICAL'][w] + (ws >= 0 && w > ws ? '(cross)' : '') + (a < 0 || b < 0 ? '(1rail)' : '');
    }}
    function statusBadge(s) {{ return '<span class="badge ' + (s.indexOf('OK') === 0 ? 'badge-ok' : s.indexOf('SLOW') === 0 ? 'badge-slow' : s === '-' ? '' : 'badge-down') + '">' + s + '</span>'; }}
    var hostRows = [];
    Object.values(perHost).forEach(function(h) {{
        var aDown = h.ipA && downIps.has(h.ipA);
        var bDown = h.ipB && downIps.has(h.ipB);
        var aMed = aDown ? 0 : (h.aGbps.length ? median(h.aGbps) : 0);
        var bMed = bDown ? 0 : (h.bGbps.length ? median(h.bGbps) : 0);
        var aName = ipNic[h.ipA] || 'NIC A';
        var bName = ipNic[h.ipB] || 'NIC B';
        var nicDown = aDown && bDown ? aName + ' & ' + bName : aDown ? aName : bDown ? bName : '';
        var gbps = (aDown || bDown) ? null : Math.round((aMed + bMed) / 2);
        var totalRetr = h.aRetr + h.bRetr + h.xRetr;
        var totalGB = h.aGB + h.bGB + h.xGB;
        var xMed = h.xGbps.length ? median(h.xGbps) : null;
        hostRows.push({{ host: h.host, status: hostStatus(h), gbps: gbps, nicDown: nicDown, ipA: h.ipA || '-', nicA: aName, aMed: aMed, ipB: h.ipB || '-', nicB: bName, bMed: bMed, xMed: xMed, aDown: aDown, bDown: bDown, aRetr: h.aRetr, bRetr: h.bRetr, totalRetr: totalRetr, aGB: h.aGB, bGB: h.bGB, totalGB: totalGB }});
    }});

    function nicBadge(val, isDown, rl) {{
        if (isDown) return '<span class="badge badge-down">DOWN</span>';
        return '<span class="badge ' + railBadge(val, rl) + '">' + val + '</span>';
    }}
    // Format retransmits with % of estimated total segments (GBytes * 1e9 / 1448 MSS)
    function retrFmt(retr, gb) {{
        if (retr === 0) return '0';
        var estSegs = gb * 1e9 / 1448;
        var pct = estSegs > 0 ? (retr / estSegs * 100) : 0;
        // Show enough precision: 0.0920% not 0.09%
        var pctStr = pct >= 1 ? pct.toFixed(1) : pct >= 0.01 ? pct.toFixed(3) : pct.toFixed(4);
        return '<span class="badge badge-down">' + retr.toLocaleString() + '</span> <small style="color:#8899aa;">(' + pctStr + '%)</small>';
    }}


    var rawIsVerbose = false;

    window.rawToggleVerbose = function() {{
        rawIsVerbose = document.getElementById('rawVerbose').checked;
        rawApplyFilter();
    }};
    var dtMenu = [[25, 50, 100, 250, 500, 1000, -1], [25, 50, 100, 250, 500, 1000, 'All']];
    // Row numbering via drawCallback — doesn't interfere with sorting
    var dtOpts = function(extra) {{
        return $.extend(true, {{
            lengthMenu: dtMenu,
            columnDefs: [{{ targets: 0, orderable: false, searchable: false, className: 'dt-row-num' }}],
            drawCallback: function(s) {{
                var api = this.api();
                var start = api.page.info().start;
                api.column(0, {{ page: 'current' }}).nodes().each(function(cell, i) {{
                    cell.innerHTML = start + i + 1;
                }});
            }}
        }}, extra || {{}});
    }};
    // rawApplyFilter initial call is deferred to after variable declarations below
    $('#bottomTable').DataTable(dtOpts({{ pageLength: 50, paging: false, searching: false }}));
    $('#fecTable').DataTable(dtOpts({{ pageLength: 50, order: [[4, 'desc']] }}));
    $('#lldpTable').DataTable(dtOpts({{ pageLength: 50, order: [[4, 'asc']] }}));
    $('#driverTable').DataTable(dtOpts({{ pageLength: 50, order: [[1, 'asc']] }}));
    $('#opticsTable').DataTable(dtOpts({{ pageLength: 50, order: [[8, 'desc']] }}));
    if (slowData.length) {{ $('#slowIpTable').DataTable(dtOpts({{ pageLength: 50, order: [[3, 'asc']] }})); }}
    if ($('#dropsTable').length) {{ $('#dropsTable').DataTable(dtOpts({{ pageLength: 50, order: [[3, 'desc']] }})); }}

    // --- Raw Data tab: filters, exclusions, CSV download ---
    var rawDT = null;
    var rawExcludedHosts = new Set();
    var rawLastThreshold = 0;

    // Populate host exclusion dropdown
    (function() {{
        var sel = document.getElementById('rawExcludeHost');
        var hosts = new Set();
        allData.forEach(function(r) {{
            if (ipHost[r.src]) hosts.add(ipHost[r.src]);
            if (ipHost[r.dst]) hosts.add(ipHost[r.dst]);
        }});
        Array.from(hosts).sort().forEach(function(h) {{
            var o = document.createElement('option'); o.value = h; o.textContent = h;
            sel.appendChild(o);
        }});
    }})();

    window.rawFilter = function(threshold) {{
        rawLastThreshold = threshold;
        document.querySelectorAll('#rawFilterBtns .btn').forEach(function(b) {{
            var bt = parseInt(b.getAttribute('data-thresh'));
            if (threshold === 0) b.classList.toggle('active', bt === 0);
            else b.classList.toggle('active', bt > 0 && bt >= threshold);
        }});
        rawApplyFilter();
    }};

    window.rawExclude = function() {{
        var val = document.getElementById('rawExcludeHost').value;
        if (val) {{ rawExcludedHosts.add(val); document.getElementById('rawExcludeHost').value = ''; }}
        rawApplyFilter();
    }};

    window.rawClearFilters = function() {{
        rawLastThreshold = 0;
        rawExcludedHosts.clear();
        document.querySelectorAll('#rawFilterBtns .btn').forEach(function(b) {{
            b.classList.toggle('active', parseInt(b.getAttribute('data-thresh')) === 0);
        }});
        rawApplyFilter();
    }};

    function rawApplyFilter() {{
        // Rebuild table with filtered data — simple and reliable
        if ($.fn.DataTable.isDataTable('#allResultsTable')) {{
            $('#allResultsTable').DataTable().destroy();
        }}
        var tbody = '';
        var shown = 0;
        if (rawIsVerbose) {{
            var total = allData.length;
            allData.forEach(function(r) {{
                var hostA = ipHost[r.src]||'';
                var hostB = ipHost[r.dst]||'';
                if (rawExcludedHosts.has(hostA) || rawExcludedHosts.has(hostB)) return;
                if (rawLastThreshold > 0 && r.gbps < rawLastThreshold) return;
                tbody += '<tr><td></td><td>' + hostA + '</td><td>' + r.src + '</td><td>' + (ipNic[r.src]||'') + '</td>';
                tbody += '<td>' + hostB + '</td><td>' + r.dst + '</td><td>' + (ipNic[r.dst]||'') + '</td>';
                tbody += '<td><span class="badge ' + gbpsBadge(r.gbps) + '">' + r.gbps + '</span></td>';
                tbody += '<td>' + retrFmt(r.retransmits || 0, r.gbytes || 0) + '</td><td>' + r.gbytes + '</td>';
                tbody += '<td>' + r.iteration + '</td><td>' + r.phase + '</td></tr>';
                shown++;
            }});
            $('#allResultsTable thead tr').html('<th>#</th><th>Host A</th><th>IP A</th><th>Dev A</th><th>Host B</th><th>IP B</th><th>Dev B</th><th>Gbps<small>single iperf3 test result</small></th><th>Retrans<small>retransmits for this test</small></th><th>GBytes</th><th>Iter</th><th>Phase</th>');
            $('#allResultsTable tbody').html(tbody);
            rawDT = $('#allResultsTable').DataTable(dtOpts({{ pageLength: 50, order: [[7, 'asc']] }}));
        }} else {{
            var total = hostRows.length;
            hostRows.forEach(function(r) {{
                if (rawExcludedHosts.has(r.host)) return;
                if (rawLastThreshold > 0 && (r.gbps === null || r.gbps < rawLastThreshold)) return;
                tbody += '<tr><td></td><td>' + r.host + '</td><td>' + statusBadge(r.status) + '</td>';
                if (r.gbps === null) {{
                    tbody += '<td><span class="badge badge-down">NA</span> <small style="color:#e94560;">' + r.nicDown + ' down</small></td>';
                }} else {{
                    tbody += '<td><span class="badge ' + gbpsBadge(r.gbps) + '">' + r.gbps + '</span></td>';
                }}
                tbody += '<td>' + retrFmt(r.totalRetr, r.totalGB) + '</td>';
                tbody += '<td>' + r.ipA + '</td><td>' + r.nicA + '</td><td>' + nicBadge(r.aMed, r.aDown, 'A') + '</td><td>' + retrFmt(r.aRetr, r.aGB) + '</td>';
                tbody += '<td>' + r.ipB + '</td><td>' + r.nicB + '</td><td>' + nicBadge(r.bMed, r.bDown, 'B') + '</td><td>' + retrFmt(r.bRetr, r.bGB) + '</td>';
                tbody += '<td>' + (r.xMed === null ? '-' : nicBadge(r.xMed, false, 'X')) + '</td></tr>';
                shown++;
            }});
            $('#allResultsTable thead tr').html('<th>#</th><th>Host</th><th>Status<small>worst of A, B, Cross (means)</small></th><th>Gbps<small>avg of NIC A &amp; B medians</small></th><th>Retrans<small>total TCP retransmits</small></th><th>IP A</th><th>Dev A</th><th>A Median<small>median Gbps across NIC A tests</small></th><th>A Retrans<small>total retransmits, NIC A</small></th><th>IP B</th><th>Dev B</th><th>B Median<small>median Gbps across NIC B tests</small></th><th>B Retrans<small>total retransmits, NIC B</small></th><th>Cross Median<small>median Gbps across A&lt;-&gt;B tests (a path, not a NIC)</small></th>');
            $('#allResultsTable tbody').html(tbody);
            rawDT = $('#allResultsTable').DataTable(dtOpts({{ pageLength: 50, order: [[3, 'asc']] }}));
        }}
        document.getElementById('rawFilterCount').textContent =
            (rawExcludedHosts.size > 0 ? rawExcludedHosts.size + ' excluded, ' : '') +
            shown + '/' + total + ' shown';
    }}

    // Generic CSV download for any DataTable
    window.downloadTableCsv = function(tableId, filename) {{
        var tbl = $('#' + tableId);
        if (!$.fn.DataTable.isDataTable(tbl)) {{
            // Plain table (no DataTable) — scrape directly
            var headers = [];
            tbl.find('thead th').each(function() {{ var t = $(this).clone().children('small').remove().end().text().trim(); headers.push(t); }});
            var skipHash = (headers[0] === '#' || headers[0] === '');
            if (skipHash) headers = headers.slice(1);
            var rows = [headers.join(',')];
            tbl.find('tbody tr').each(function() {{
                var clean = [];
                $(this).find('td').each(function(i) {{
                    if (skipHash && i === 0) return;
                    clean.push('"' + $(this).text().replace(/"/g, '""').trim() + '"');
                }});
                rows.push(clean.join(','));
            }});
        }} else {{
            var dt = tbl.DataTable();
            var headers = [];
            tbl.find('thead th').each(function() {{ var t = $(this).clone().children('small').remove().end().text().trim(); headers.push(t); }});
            var skipHash = (headers[0] === '#' || headers[0] === '');
            if (skipHash) headers = headers.slice(1);
            var rows = [headers.join(',')];
            dt.rows({{ search: 'applied' }}).every(function() {{
                var d = this.data();
                var clean = [];
                for (var i = (skipHash ? 1 : 0); i < d.length; i++) {{
                    var txt = $('<span>').html(d[i]).text();
                    clean.push('"' + txt.replace(/"/g, '""').trim() + '"');
                }}
                rows.push(clean.join(','));
            }});
        }}
        var blob = new Blob([rows.join('\\n')], {{ type: 'text/csv' }});
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = filename;
        a.click();
    }};
    window.rawDownloadCsv = function() {{ downloadTableCsv('allResultsTable', 'dp_validation_results.csv'); }};

    // Initial build of raw data table (after all vars and functions are defined)
    rawApplyFilter();

    // --- vis-network topology ---
    var topoNodesData = {topo_nodes_json};
    var topoEdgesData = {topo_edges_json};
    var topoNodes = new vis.DataSet(topoNodesData);
    var topoEdges = new vis.DataSet(topoEdgesData);
    var topoContainer = document.getElementById('topoNetwork');
    var topoData = {{ nodes: topoNodes, edges: topoEdges }};

    var topoBaseOpts = {{
        nodes: {{
            shape: 'dot', size: 12,
            font: {{ size: 11, color: '#e0e0e0', face: 'monospace' }},
            borderWidth: 2, shadow: true,
        }},
        edges: {{
            smooth: {{ type: 'cubicBezier', forceDirection: 'vertical', roundness: 0.3 }},
            font: {{ size: 0 }},
        }},
        groups: {{
            spine: {{
                shape: 'diamond', size: 40,
                color: {{ background: '#e94560', border: '#ffffff' }},
                font: {{ size: 16, color: '#ffffff', bold: {{ size: 16 }} }},
            }},
            switch: {{
                shape: 'box', size: 30,
                color: {{ background: '#0f3460', border: '#4ecca3' }},
                font: {{ size: 14, color: '#4ecca3', bold: {{ size: 14 }} }},
            }},
            host: {{ shape: 'dot', size: 10 }},
        }},
        interaction: {{ hover: true, tooltipDelay: 100, navigationButtons: true, keyboard: true, dragNodes: true }},
    }};

    var topoLayouts = {{
        hierarchical: {{
            layout: {{ hierarchical: {{ direction: 'UD', sortMethod: 'directed', levelSeparation: 250, nodeSpacing: 15, treeSpacing: 50 }} }},
            physics: {{ enabled: true, hierarchicalRepulsion: {{ nodeDistance: 200, springLength: 200 }}, stabilization: {{ iterations: 200 }} }},
        }},
        force: {{
            layout: {{ hierarchical: false }},
            physics: {{ enabled: true, solver: 'forceAtlas2Based',
                forceAtlas2Based: {{ gravitationalConstant: -80, centralGravity: 0.01, springLength: 150, springConstant: 0.06, damping: 0.4 }},
                stabilization: {{ enabled: true, iterations: 300 }}
            }},
        }},
        radial: {{
            layout: {{ hierarchical: false }},
            physics: {{ enabled: true, solver: 'repulsion',
                repulsion: {{ nodeDistance: 200, centralGravity: 0.3, springLength: 200 }},
                stabilization: {{ enabled: true, iterations: 300 }}
            }},
        }},
    }};

    var topoNetwork = null;
    var topoCurrentLayout = 'hierarchical';
    var topoInitialized = false;

    function topoInit() {{
        var opts = {{ ...topoBaseOpts, ...topoLayouts[topoCurrentLayout] }};
        topoNetwork = new vis.Network(topoContainer, topoData, opts);

        // Drag to pin
        topoNetwork.on('dragEnd', function(p) {{
            if (p.nodes.length > 0) {{
                var pos = topoNetwork.getPositions([p.nodes[0]]);
                topoNodes.update({{ id: p.nodes[0], x: pos[p.nodes[0]].x, y: pos[p.nodes[0]].y, fixed: {{ x: true, y: true }} }});
            }}
        }});
        // Double-click to unpin
        topoNetwork.on('doubleClick', function(p) {{
            if (p.nodes.length > 0) topoNodes.update({{ id: p.nodes[0], fixed: {{ x: false, y: false }} }});
        }});
    }}

    // --- Exclusion sets ---
    var topoExcludedHosts = new Set();
    var topoExcludedLinks = new Set();  // edge index in topoEdgesData

    // Populate exclusion dropdowns
    (function() {{
        var hostSel = document.getElementById('topoExcludeHost');
        var linkSel = document.getElementById('topoExcludeLink');
        var hosts = [];
        topoNodesData.forEach(function(n) {{ if (n.group === 'host') hosts.push(n.id); }});
        hosts.sort();
        hosts.forEach(function(h) {{
            var o = document.createElement('option'); o.value = h; o.textContent = h;
            hostSel.appendChild(o);
        }});
        topoEdgesData.forEach(function(e, i) {{
            if (e.title && e.title.indexOf('Gbps') > -1) {{
                var o = document.createElement('option');
                o.value = i;
                o.textContent = e.from + ' — ' + e.title.split('—')[0].trim();
                linkSel.appendChild(o);
            }}
        }});
    }})();

    window.topoExclude = function() {{
        var hostVal = document.getElementById('topoExcludeHost').value;
        var linkVal = document.getElementById('topoExcludeLink').value;
        if (hostVal) {{ topoExcludedHosts.add(hostVal); document.getElementById('topoExcludeHost').value = ''; }}
        if (linkVal) {{ topoExcludedLinks.add(parseInt(linkVal)); document.getElementById('topoExcludeLink').value = ''; }}
        topoApplyFilter();
        topoUpdateExcludeCount();
    }};

    window.topoClearExclusions = function() {{
        topoExcludedHosts.clear();
        topoExcludedLinks.clear();
        topoApplyFilter();
        topoUpdateExcludeCount();
    }};

    function topoUpdateExcludeCount() {{
        var c = topoExcludedHosts.size + topoExcludedLinks.size;
        document.getElementById('topoExcludeCount').textContent = c > 0 ? c + ' excluded' : '';
    }}

    // --- Legend: counts what's currently displayed ---
    // Hover to show/hide detail
    (function() {{
        var leg = document.getElementById('topoLegend');
        var det = document.getElementById('topoLegendDetail');
        leg.addEventListener('mouseenter', function() {{ det.style.display = 'block'; }});
        leg.addEventListener('mouseleave', function() {{ det.style.display = 'none'; }});
    }})();

    function topoUpdateLegend() {{
        // Count visible hosts by bucket
        var h350=0, h300=0, h250=0, h200=0, hLow=0, hDown=0, hVis=0;
        topoNodesData.forEach(function(n) {{
            if (n.group !== 'host') return;
            var node = topoNodes.get(n.id);
            if (node.hidden) return;
            hVis++;
            if (n.isDown) hDown++;
            else if (n.hostAvg >= {G}) h350++;
            else if (n.hostAvg >= {F}) h300++;
            else if (n.hostAvg >= {M}) h250++;
            else if (n.hostAvg >= {S}) h200++;
            else hLow++;
        }});
        // Count visible links by bucket
        var l350=0, l300=0, l250=0, l200=0, lLow=0, lDown=0, lVis=0;
        var downIps = new Set({json.dumps(data['down_ips'])});
        topoEdgesData.forEach(function(e, i) {{
            var eid = topoEdges.getIds()[i];
            if (!eid) return;
            var edge = topoEdges.get(eid);
            if (edge.hidden) return;
            // Skip spine-to-leaf uplinks
            if (!e.title || e.title.indexOf('Gbps') === -1) return;
            lVis++;
            var ip = e.title.split(' ')[0];
            if (downIps.has(ip)) {{ lDown++; return; }}
            var spd = edgeSpeed(e);
            if (spd >= {G}) l350++;
            else if (spd >= {F}) l300++;
            else if (spd >= {M}) l250++;
            else if (spd >= {S}) l200++;
            else lLow++;
        }});
        // Count visible switches
        var sVis = 0;
        topoNodesData.forEach(function(n) {{
            if (n.group !== 'switch') return;
            var node = topoNodes.get(n.id);
            if (!node.hidden) sVis++;
        }});
        // Update summary
        document.getElementById('legHosts').textContent = hVis;
        document.getElementById('legLinks').textContent = lVis;
        document.getElementById('legSwitches').textContent = sVis;
        // Update detail table
        document.getElementById('legH350').textContent = h350;
        document.getElementById('legH300').textContent = h300;
        document.getElementById('legH250').textContent = h250;
        document.getElementById('legH200').textContent = h200;
        document.getElementById('legHLow').textContent = hLow;
        document.getElementById('legHDown').textContent = hDown;
        document.getElementById('legL350').textContent = l350;
        document.getElementById('legL300').textContent = l300;
        document.getElementById('legL250').textContent = l250;
        document.getElementById('legL200').textContent = l200;
        document.getElementById('legLLow').textContent = lLow;
        document.getElementById('legLDown').textContent = lDown;
    }}

    // Wrapper: apply current filter + exclusions, then update legend
    function topoApplyFilter() {{
        topoFilter(topoLastThreshold);
        // Apply exclusions on top of filter
        if (topoExcludedHosts.size > 0 || topoExcludedLinks.size > 0) {{
            var nu = [], eu = [];
            topoExcludedHosts.forEach(function(h) {{ nu.push({{ id: h, hidden: true }}); }});
            topoExcludedLinks.forEach(function(idx) {{
                var eid = topoEdges.getIds()[idx];
                if (eid !== undefined) eu.push({{ id: eid, hidden: true }});
            }});
            if (nu.length) topoNodes.update(nu);
            if (eu.length) topoEdges.update(eu);
        }}
        topoUpdateLegend();
    }}

    // Lazy init on tab show
    $('a[href="#tab-topology"]').on('shown.bs.tab', function() {{
        if (!topoInitialized) {{ topoInit(); topoInitialized = true; topoUpdateLegend(); }}
    }});

    // --- Layout toggle ---
    window.topoSetLayout = function(mode) {{
        topoCurrentLayout = mode;
        document.querySelectorAll('#tab-topology .btn-group-sm .btn').forEach(function(b) {{ b.classList.remove('active'); }});
        var btnId = {{ hierarchical: 'tBtnHier', force: 'tBtnForce', radial: 'tBtnRadial' }}[mode];
        document.getElementById(btnId).classList.add('active');
        if (topoNetwork) {{
            topoNetwork.setOptions({{ ...topoBaseOpts, ...topoLayouts[mode] }});
            if (mode !== 'hierarchical') topoNetwork.stabilize(300);
        }}
    }};

    // --- Filter mode: host avg vs individual link ---
    var topoFilterByLink = false;
    var topoLastThreshold = 0;
    document.getElementById('topoFilterMode').addEventListener('change', function() {{
        topoFilterByLink = this.checked;
        document.getElementById('topoFilterModeLabel').textContent = topoFilterByLink ? 'Link speed' : 'Host avg';
        // Re-apply current filter with new mode
        if (topoLastThreshold !== 0) topoApplyFilter();
    }});

    function edgeSpeed(e) {{
        if (!e.title) return 999;
        var m = e.title.match(/([\d.]+)\s*Gbps/);
        return m ? parseFloat(m[1]) : 999;
    }}

    // Unified filter — batched updates to avoid per-node redraws
    window.topoFilter = function(threshold) {{
        if (!topoNetwork) return;
        topoLastThreshold = threshold;

        // Update button highlights: selected threshold + all higher ones
        document.querySelectorAll('#topoFilterBtns .btn').forEach(function(b) {{
            var bt = parseInt(b.getAttribute('data-thresh'));
            if (threshold === 0) {{
                // "All" selected: only "All" active
                b.classList.toggle('active', bt === 0);
            }} else if (threshold === -1) {{
                // "Down" selected: only "Down" active
                b.classList.toggle('active', bt === -1);
            }} else {{
                // Speed threshold: highlight this + all higher thresholds (not All, not Down)
                b.classList.toggle('active', bt > 0 && bt >= threshold);
            }}
        }});

        // Build visibility maps first, then apply in one batch
        var nodeVis = {{}};  // id -> true/false
        var edgeVis = {{}};

        if (threshold === 0) {{
            // Show all
            topoNodesData.forEach(function(n) {{ nodeVis[n.id] = true; }});
            topoEdgesData.forEach(function(e, i) {{ edgeVis[i] = true; }});
        }} else if (threshold === -1) {{
            // Down only
            topoNodesData.forEach(function(n) {{
                if (n.group === 'switch' || n.group === 'spine') nodeVis[n.id] = true;
                else nodeVis[n.id] = !!n.isDown;
            }});
        }} else if (topoFilterByLink) {{
            // Link speed: show hosts with ANY link >= threshold
            var matchHosts = new Set();
            topoEdgesData.forEach(function(e) {{
                if (edgeSpeed(e) >= threshold) matchHosts.add(e.from);
            }});
            topoNodesData.forEach(function(n) {{
                if (n.group === 'switch' || n.group === 'spine') nodeVis[n.id] = true;
                else nodeVis[n.id] = matchHosts.has(n.id);
            }});
        }} else {{
            // Host avg: show hosts with avg >= threshold
            topoNodesData.forEach(function(n) {{
                if (n.group === 'switch' || n.group === 'spine') nodeVis[n.id] = true;
                else nodeVis[n.id] = (n.hostAvg >= threshold);
            }});
        }}

        // Edges: visible only if both endpoints visible
        var edgeIds = topoEdges.getIds();
        edgeIds.forEach(function(id) {{
            var e = topoEdges.get(id);
            edgeVis[id] = !!(nodeVis[e.from] && nodeVis[e.to]);
        }});

        // Batch apply
        var nodeUpdates = [];
        topoNodes.getIds().forEach(function(id) {{
            nodeUpdates.push({{ id: id, hidden: !nodeVis[id] }});
        }});
        var edgeUpdates = [];
        edgeIds.forEach(function(id) {{
            edgeUpdates.push({{ id: id, hidden: !edgeVis[id] }});
        }});
        topoNodes.update(nodeUpdates);
        topoEdges.update(edgeUpdates);

        if (threshold === 0) topoNetwork.fit();
        topoUpdateLegend();
    }};

    // --- Focus on a single switch ---
    window.topoFocusSwitch = function(switchId) {{
        if (!topoNetwork) return;
        if (!switchId) {{ resetTopo(); return; }}
        var connected = topoNetwork.getConnectedNodes(switchId);
        connected.push(switchId);
        var connSet = new Set(connected);
        // Batch
        var nu = [], eu = [];
        topoNodes.getIds().forEach(function(id) {{ nu.push({{ id: id, hidden: !connSet.has(id) }}); }});
        topoEdges.getIds().forEach(function(id) {{
            var e = topoEdges.get(id);
            eu.push({{ id: id, hidden: !(connSet.has(e.from) && connSet.has(e.to)) }});
        }});
        topoNodes.update(nu);
        topoEdges.update(eu);
        topoNetwork.fit({{ nodes: connected, animation: {{ duration: 600 }} }});
    }};

    // --- Option toggles ---
    window.topoToggleOpt = function(opt) {{
        if (!topoNetwork) return;
        if (opt === 'labels') {{
            var show = document.getElementById('topoToggleLabels').checked;
            topoNetwork.setOptions({{ nodes: {{ font: {{ size: show ? 11 : 0 }} }}, groups: {{ switch: {{ font: {{ size: show ? 14 : 0 }} }} }} }});
        }} else if (opt === 'physics') {{
            var on = document.getElementById('topoTogglePhysics').checked;
            topoNetwork.setOptions({{ physics: {{ enabled: on }} }});
        }} else if (opt === 'smooth') {{
            var on = document.getElementById('topoToggleSmooth').checked;
            topoNetwork.setOptions({{ edges: {{ smooth: on ? {{ type: 'cubicBezier', forceDirection: 'vertical', roundness: 0.3 }} : false }} }});
        }}
    }};

    // --- Reset ---
    window.resetTopo = function() {{
        if (!topoNetwork) return;
        topoLastThreshold = 0;
        topoExcludedHosts.clear();
        topoExcludedLinks.clear();
        topoUpdateExcludeCount();
        // Batch
        var nu = [], eu = [];
        topoNodes.getIds().forEach(function(id) {{ nu.push({{ id: id, hidden: false, fixed: {{ x: false, y: false }} }}); }});
        topoEdges.getIds().forEach(function(id) {{ eu.push({{ id: id, hidden: false }}); }});
        topoNodes.update(nu);
        topoEdges.update(eu);
        document.getElementById('topoSwitchSelect').value = '';
        document.querySelectorAll('#topoFilterBtns .btn').forEach(function(b) {{ b.classList.remove('active'); }});
        document.querySelector('#topoFilterBtns .btn').classList.add('active');  // "All" is first
        topoSetLayout(topoCurrentLayout);
        topoNetwork.fit();
        topoUpdateLegend();
    }};
}});
</script>
</body>
</html>"""

    with open(output_path, 'w') as f:
        f.write(html)
    print(f"Dashboard generated: {output_path}")


def nic_view(d):
    """Per rail NIC ('host_nic') facts from one parsed run, for comparing runs."""
    v = {}
    ip_nic = {}
    for line in d.get('_nic_diag_lines', []):
        p = line.split()
        if len(p) >= 16:
            key = f"{p[0]}_{p[1]}"
            ip_nic[p[2]] = key
            v[key] = {'host': p[0], 'nic': p[1], 'ip': p[2], 'speed': p[3], 'fec': _int(p[4]), 'link_down': _int(p[9]),
                      'sent': [], 'recv': [], 'drops': 0}
    for r in d['iperf_results']:   # per direction: a shaped sender also lowers its receivers' averages
        if _cross(r, d.get('ip_rail', {})):
            continue
        if r['src'] in ip_nic:
            v[ip_nic[r['src']]]['sent'].append(r['gbps'])
        if r['dst'] in ip_nic:
            v[ip_nic[r['dst']]]['recv'].append(r['gbps'])
            if r['src'] in ip_nic:
                v[ip_nic[r['dst']]].setdefault('from', set()).add(ip_nic[r['src']])
    for x in d['driver_info']:
        k = f"{x['host']}_{x['nic']}"
        if k in v:
            v[k]['fw'] = f"{x['driver']} {x['version']} fw {x['firmware']}"
    for x in d['lldp_info']:
        k = f"{x['host']}_{x['nic']}"
        if k in v:
            v[k]['lldp'] = f"{x['switch']} {x['port_desc']}".strip()
    for x in d['packet_drops']:
        if x['host_nic'] in v:
            v[x['host_nic']]['drops'] += x['rx_drop'] + x['tx_drop'] + x['rx_oob']
    for f in d.get('fec_rate', []):
        if f['nic'] in v:
            v[f['nic']]['fec_status'] = f['status']
    for k in v:
        for side in ('sent', 'recv'):
            g = v[k][side]
            v[k][side + '_avg'] = sum(g) / len(g) if g else None
    return v


def compare_runs(new, old):
    """What changed per rail NIC between an older run and this one."""
    nv, ov = nic_view(new), nic_view(old)
    ch = []
    for k in sorted(set(nv) | set(ov)):
        n, o = nv.get(k), ov.get(k)
        host, nic = (n or o)['host'], (n or o)['nic']
        if not o:
            ch.append((host, nic, 'new in this run', '', n['ip']))
            continue
        if not n:
            ch.append((host, nic, 'missing from this run', o['ip'], ''))
            continue
        for side, label in (('sent_avg', 'throughput sent'), ('recv_avg', 'throughput received')):
            a, b = o[side], n[side]
            if a is not None and b is not None and a > 0 and abs(b - a) >= 0.1 * a:
                ch.append((host, nic, label, f"{a:.1f} Gbps", f"{b:.1f} Gbps ({100 * (b - a) / a:+.0f}%)"))
            elif (a is None) != (b is None):
                ch.append((host, nic, label, 'no result' if a is None else f"{a:.1f} Gbps", 'no result' if b is None else f"{b:.1f} Gbps"))
        if n['speed'] != o['speed']:
            ch.append((host, nic, 'link speed', o['speed'], n['speed']))
        for key, label in (('fec', 'FEC corrected (lifetime)'), ('link_down', 'link down events')):
            if n[key] is not None and o[key] is not None and n[key] != o[key]:
                d = n[key] - o[key]
                ch.append((host, nic, label, f"{o[key]:,}", f"{n[key]:,} (" + (f"+{d:,}" if d > 0 else "counter reset") + ")"))
        for key, label in (('fec_status', 'FEC status'), ('fw', 'driver/firmware'), ('lldp', 'switch port (LLDP)')):
            if n.get(key) and o.get(key) and n[key] != o[key]:
                ch.append((host, nic, label, o[key], n[key]))
        if n['drops'] != o['drops']:
            ch.append((host, nic, 'packet drops in run', f"{o['drops']:,}", f"{n['drops']:,}"))
    # a received-only drop that follows a flagged sender: say which (the receiver is probably fine)
    sent_down = {f"{h}_{n}" for h, n, what, a, b in ch if what == 'throughput sent' and '(-' in b}
    for i, (h, n, what, a, b) in enumerate(ch):
        if what == 'throughput received' and '(-' in b:
            senders = sorted(nv.get(f"{h}_{n}", {}).get('from', set()) & sent_down)
            if senders and f"{h}_{n}" not in sent_down:
                ch[i] = (h, n, what, a, b + ' - follows ' + ', '.join(s.replace('_', ' ', 1) for s in senders) + ' (sent less)')
    added = sorted(set(new['down_ips']) - set(old['down_ips']))
    cleared = sorted(set(old['down_ips']) - set(new['down_ips']))
    return {'changes': ch, 'down_added': added, 'down_cleared': cleared,
            'old_label': old['metadata'].get('label', ''), 'old_ts': old['metadata'].get('timestamp', '')}


def _int(s):
    try:
        return int(s)
    except (ValueError, TypeError):
        return None


def _cross(r, ip_rail):
    """A run between rails measures a path, not either IP's NIC (routes decide which NIC carries it)."""
    a, b = ip_rail.get(r['src']), ip_rail.get(r['dst'])
    return bool(a and b and a != b)


def _cross_finding(data):
    """Cross-rail total, and the shared-path finding when only cross-rail runs miss the OK cut-off (as the collector)."""
    ipr, rt = data.get('ip_rail', {}), data.get('rail_tiers', {})
    res = [r for r in data['iperf_results'] if ipr.get(r['src']) and ipr.get(r['dst'])]
    xs = [r for r in res if _cross(r, ipr)]
    if not xs:
        return None, None
    def med(v):
        v, n = sorted(v), len(v)
        return None if not n else v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2
    def bw(g):
        return f'{g / 1000:.2f} Tbps' if g >= 1000 else f'{g:.1f} Gbps'
    def k(n):
        return f'{n / 1e6:.1f}M' if n >= 1e6 else f'{n / 1e3:.1f}k' if n >= 1e4 else str(n)
    tot = defaultdict(float)
    for r in xs:
        tot[r['iteration'], r.get('wave', '')] += r['gbps']
    t = list(tot.values())
    ab = sum(1 for r in xs if ipr[r['src']] == 'A')
    xr = sum(r.get('retransmits', 0) for r in xs)
    sr = sum(r.get('retransmits', 0) for r in res if not _cross(r, ipr))
    xm = med([r['gbps'] for r in xs])
    waves = any(r.get('wave') for r in xs)
    agg = (f'Cross-rail total: {bw(t[0])} over {len(xs)} flows run at once' if len(t) == 1 else
           f'Cross-rail total per wave ({data.get("metadata", {}).get("cross_max", "?")} flows at once): largest {bw(max(t))}, '
           f'{bw(sum(t) / len(t))} on average ({bw(min(t))} to {bw(max(t))} over {len(t)} waves), {len(xs)} flows' if waves else
           f'Cross-rail total per iteration: {bw(sum(t) / len(t))} on average ({bw(min(t))} to {bw(max(t))} '
           f'over {len(t)} iterations), {len(xs)} flows')
    agg += f' (A->B {ab}, B->A {len(xs) - ab}); median {xm:.1f} Gbps per flow; retransmits {k(xr)} cross-rail vs {k(sr)} same-rail'
    cut = {x: rt.get(x, data['tiers'])['F'] for x in ('A', 'B')}
    sm = {x: med([r['gbps'] for r in res if ipr[r['src']] == x and ipr[r['dst']] == x]) for x in ('A', 'B')}
    fx = min(cut.values())
    shared = None
    if xm < fx and any(v is not None for v in sm.values()) and all(v is None or v >= cut[x] for x, v in sm.items()):
        f = lambda v: '-' if v is None else f'{v:.1f}'
        shared = (f"Same-rail runs are OK, cross-rail runs are not: cross-rail median {xm:.1f} Gbps per flow (OK >= {fx:g}), "
                  f"same-rail median {f(sm['A'])} (A) / {f(sm['B'])} (B) Gbps. The hosts pass on their own rail, so the likely "
                  'limit is the shared path between the rails (switch inter-link or spine), not the hosts.')
    return agg, shared


def _uplinks(data):
    """Per leaf (LLDP neighbour) and phase, the runs crossing to another leaf, as the collector summary does. With
    spines x links x Gbps declared (run metadata, else FS_SPINES/FS_SPINE_LINKS/FS_SPINE_GBPS here), judged against it."""
    meta = data['metadata']
    names = (('spines', 'FS_SPINES'), ('spine_links', 'FS_SPINE_LINKS'), ('spine_gbps', 'FS_SPINE_GBPS'))
    run, env = [_int(meta.get(k)) for k, _ in names], [_int(os.environ.get(e)) for _, e in names]
    ok3 = lambda d: all(x and x > 0 for x in d)
    n, m, s = run if ok3(run) else env if ok3(env) else (0, 0, 0)
    u = {'n': n, 'm': m, 's': s, 'C': n * m * s, 'rows': [], 'notes': [],
         'src': 'declared by the run' if ok3(run) else 'declared at render time (FS_SPINES etc. in the environment)'}
    C = u['C']
    ipr = data.get('ip_rail', {})
    leaf = {l['ip']: l['switch'] for l in data['lldp_info'] if l['switch'] not in ('unknown', '')}
    ips = set(ipr)
    if not any(ip in leaf for ip in ips):
        if not C:
            return None
        u['notes'].append('Uplink check skipped: it needs LLDP, and no rail NIC reported a switch neighbour.')
        return u
    rr = data.get('rail_rate', {})
    la, lb = rr.get('A') or data['line_rate'], rr.get('B') or data['line_rate']
    def med(v):
        v, k = sorted(v), len(v)
        return None if not k else v[k // 2] if k % 2 else (v[k // 2 - 1] + v[k // 2]) / 2
    ob, ib, xl, same, its = defaultdict(float), defaultdict(float), defaultdict(list), defaultdict(list), defaultdict(set)
    left = 0
    for r in data['iperf_results']:
        a, b = r['src'], r['dst']
        if a not in ipr or b not in ipr:
            continue
        if a not in leaf or b not in leaf:
            left += 1
            continue
        x, y, ph, it = leaf[a], leaf[b], str(r['phase']), r['iteration']
        if r.get('wave'):
            it = f"{it} wave {r['wave']}"
        if x == y:
            if ipr[a] == ipr[b]:
                same[x].append(r['gbps'])
            continue
        ob[ph, it, x] += r['gbps']; ib[ph, it, y] += r['gbps']
        xl[ph, x].append(r['gbps']); xl[ph, y].append(r['gbps']); its[ph].add(it)
    if not ob and not ib and not C:
        return None
    nm = sum(1 for ip in ips if ip not in leaf)
    if nm:
        u['notes'].append(f'{nm} of {len(ips)} rail NICs have no LLDP neighbour; their {left} runs are left out of the leaf totals.')
    dl = defaultdict(float)
    for ip in ips:
        if ip in leaf:
            dl[leaf[ip]] += data.get('ip_gbps', {}).get(ip) or (la if ipr[ip] == 'A' else lb)
    lx = min(la, lb)
    okp, slp = int(meta.get('ok_pct', 75)), int(meta.get('slow_pct', 50))
    okc = lx * okp / 100
    best = {}
    for (ph, it, lf) in set(ob) | set(ib):
        busy = max(ob[ph, it, lf], ib[ph, it, lf])
        if (ph, lf) not in best or busy > best[ph, lf][0]:
            best[ph, lf] = (busy, it)
    for (ph, lf) in sorted(best):
        busy, it = best[ph, lf]
        row = {'leaf': lf, 'phase': ph, 'out': ob[ph, it, lf], 'in': ib[ph, it, lf], 'iter': it, 'iters': len(its[ph]),
               'down': dl[lf], 'pct': None, 'ovs': None, 'verdict': ''}
        if C:
            row['pct'], row['ovs'] = 100 * busy / C, dl[lf] / C
            xm, sm = med(xl[ph, lf]), med(same[lf])
            if row['pct'] >= okp and xm < lx:
                row['verdict'] = (f"at declared uplink capacity: oversubscribed {row['ovs']:.1f}:1 by design; cross-leaf runs "
                                  f'(median {xm:.1f} Gbps) get their share of the uplinks, not line rate')
            elif xm is not None and xm < okc and sm is not None and sm >= okc and row['pct'] < slp:
                row['verdict'] = (f"uplinks carried only {row['pct']:.0f}% of declared capacity while cross-leaf runs were slow "
                                  f'(median {xm:.1f} Gbps, OK >= {okc:g}) and same-leaf runs were OK (median {sm:.1f}); a link or '
                                  'spine may be down, or ECMP is uneven')
        u['rows'].append(row)
    if not u['rows']:
        u['notes'].append('No runs crossed between leaves.')
    return u


def _uplinks_html(u):
    if not u:
        return ''
    t = lambda g: f'{g / 1000:.2f} T'
    rows = ''
    for r in u['rows']:
        busiest = f" (iteration {r['iter']}, busiest of {r['iters']})" if r['iters'] > 1 else ''
        judged = (f"<td>{t(u['C'])}</td><td>{r['pct']:.0f}%</td>" if u['C'] else '')
        tail = (f"<td>{r['ovs']:.1f}:1</td><td>{escape(r['verdict'])}</td>" if u['C'] else '')
        rows += (f"<tr><td>{escape(r['leaf'])}</td><td>{escape(r['phase'])}{busiest}</td><td>{t(r['out'])}</td><td>{t(r['in'])}</td>"
                 f"{judged}<td>{t(r['down'])}</td>{tail}</tr>")
    head = (f"Leaf uplinks, {u['src']}: {u['n']} spines x {u['m']} links x {u['s']}G = {t(u['C'])} per leaf, each direction" if u['C'] else
            'Leaf uplink totals (set FS_SPINES, FS_SPINE_LINKS, FS_SPINE_GBPS to judge against uplink capacity)')
    cols = ('<th>Leaf</th><th>Phase</th><th>Out</th><th>In</th>' + ('<th>Declared</th><th>Busiest</th>' if u['C'] else '')
            + '<th>Downlinks</th>' + ('<th>Oversubscribed</th><th>Verdict</th>' if u['C'] else ''))
    return (f'<div class="card mb-3"><div class="card-header">{head}</div><div class="card-body">'
            + ''.join(f'<p class="text-warning mb-1">{escape(x)}</p>' for x in u['notes'])
            + (f'<table class="table table-sm table-striped"><thead><tr>{cols}</tr></thead><tbody>{rows}</tbody></table>'
               if u['rows'] else '') + '</div></div>')


def _ip_speeds(results, ip_rail):
    """Per-IP Gbps from same-rail runs; an IP with none falls back to its cross-rail runs (the returned set)."""
    same, cross = defaultdict(list), defaultdict(list)
    for r in results:
        d = cross if _cross(r, ip_rail) else same
        d[r['src']].append(r['gbps'])
        d[r['dst']].append(r['gbps'])
    xonly = set(cross) - set(same)
    same.update({ip: cross[ip] for ip in xonly})
    return same, xonly


def parse_tar_archive(filepath):
    """Parse structured data from the .tgz/.tar.gz archive produced by the iperf3 script."""
    data = {
        'metadata': {},
        'down_ips': [],
        'ping_failures': [],
        'iperf_results': [],
        'nic_inventory': {'total': 0, 'at_line': 0, 'not_line': [], 'unknown': 0, 'unknown_list': []},
        'fec_top': [],
        'slow_ips': [],
        'driver_info': [],
        'lldp_info': [],
        'driver_summary': {},
        'switch_summary': {},
        'packet_drops': [],
        'optics': [],
        'raw_hosts': {},  # hostname -> raw text
    }

    tmpdir = tempfile.mkdtemp()
    with tarfile.open(filepath, 'r:gz') as tar:
        tar.extractall(tmpdir)

    # Find the extracted directory (it has a random suffix)
    subdirs = [d for d in os.listdir(tmpdir) if os.path.isdir(os.path.join(tmpdir, d))]
    base = os.path.join(tmpdir, subdirs[0]) if subdirs else tmpdir

    def read_file(name):
        path = os.path.join(base, name)
        if os.path.exists(path):
            with open(path) as f:
                return f.read()
        return ''

    # Metadata
    for line in read_file('metadata.txt').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            data['metadata'][k.strip()] = v.strip()

    # Down IPs
    data['down_ips'] = [l.strip() for l in read_file('down_ips.txt').splitlines() if l.strip()]

    # What the run could not test (collector files; absent in older archives)
    nt = []
    for l in read_file('rails.txt').splitlines()[1:]:
        p = l.split()
        if len(p) >= 10:
            for rail, (nic, ip, st) in (('A', (p[2], p[3], p[5])), ('B', (p[6], p[7], p[9]))):
                if st != 'ok':
                    nt.append({'kind': 'rail', 'what': f'{p[0]} rail {rail} {nic} {ip}', 'why': st.replace('_', ' ')})
    for l in read_file('paths_excluded.txt').splitlines():
        p = l.split(None, 6)
        if len(p) == 7:
            nt.append({'kind': 'path', 'what': f'{p[2]} {p[3]} → {p[4]} {p[5]} (iter {p[0]} phase {p[1]})', 'why': p[6]})
    for l in read_file('excluded.txt').splitlines():
        p = l.split(None, 1)
        if p:
            nt.append({'kind': 'host', 'what': p[0], 'why': p[1] if len(p) > 1 else ''})
    unreach = Counter(re.sub(r'^ssh: connect to host \S+ port \d+: ', '', l.split(None, 1)[1]) if len(l.split(None, 1)) > 1
                      else 'no error text' for l in read_file('unreachable.txt').splitlines() if l.strip())
    for why, n in unreach.most_common():
        nt.append({'kind': 'unreachable', 'what': f'{n} targets', 'why': why})
    data['not_tested'] = nt

    # UDP pass (FS_UDP=1): per-path results, and each receiving host's counters for that phase
    host_of_ip = {}
    for l in read_file('nic_diagnostics.txt').splitlines():
        p = l.split()
        if len(p) >= 3:
            host_of_ip[p[2]] = p[0]
    hostc = {}   # (iter, phase, host) -> (socket, backlog)
    for l in read_file('udp_host_counters.txt').splitlines():
        p = l.split()
        if len(p) >= 7:
            hostc[(p[0], p[1], p[2])] = (int(p[3]), int(p[6]))
    # (iter, phase, host) -> rx drops / rx_oob on its rail NICs. The kernel adds softnet backlog drops
    # to rx_dropped too, so NIC = max(0, rx drops - backlog) + rx_oob (same rule as the collector)
    nicd, nico = defaultdict(int), defaultdict(int)
    nic_host = {f"{l.split()[0]}_{l.split()[1]}": l.split()[0]
                for l in read_file('nic_diagnostics.txt').splitlines() if len(l.split()) >= 2}
    for l in read_file('udp_nic_drops.txt').splitlines():
        p = l.split()
        if len(p) >= 5 and p[2] in nic_host:
            nicd[(p[0], p[1], nic_host[p[2]])] += int(p[3])
            nico[(p[0], p[1], nic_host[p[2]])] += int(p[4])
    udp, it, ph = [], '', ''
    for line in read_file('iperf3_udp_results.txt').splitlines():
        mm = re.match(r'^###\s+iteration:(\d+)\s+phase:(\S+)', line)
        if mm:
            it, ph = 'iter' + mm.group(1), mm.group(2)
            continue
        m = re.match(r'^(\S+),(\S+),\[SUM\].*?([\d.]+)\s+Gbits/sec\s+([\d.]+)\s+ms\s+(\d+)/(\d+)\s+\(([\d.e+-]+)%\)\s+receiver', line)
        if m:
            dst_host = host_of_ip.get(m.group(2), '')
            sock, back = hostc.get((it, ph, dst_host), (0, 0))
            nic = max(0, nicd.get((it, ph, dst_host), 0) - back) + nico.get((it, ph, dst_host), 0)
            lost, sent = int(m.group(5)), int(m.group(6))
            udp.append({'iter': it, 'phase': ph, 'src': m.group(1), 'dst': m.group(2),
                        'src_host': host_of_ip.get(m.group(1), ''), 'dst_host': dst_host,
                        'gbps': float(m.group(3)), 'lost': lost, 'sent': sent,
                        'sock': sock, 'nic': nic, 'back': back,
                        'unacc': max(0, lost - sock - nic - back)})
        elif line.strip() and ',ERROR' in line:
            udp.append({'iter': it, 'phase': ph, 'error': line.split(',', 2)[2]})
    data['udp'] = udp
    data['iperf3_versions'] = [l.split() for l in read_file('iperf3_versions.txt').splitlines() if l.split()]

    # Line rate: collector's value, else the most common NIC speed, else best run seen
    speeds = [l.split()[3] for l in read_file('nic_diagnostics.txt').splitlines()
              if len(l.split()) >= 4 and re.match(r'^\d+Mb/s$', l.split()[3])]
    lr = data['metadata'].get('line_rate_gbps', '')
    # most common speed, the higher one on a tie (deterministic, and tests the upper limit)
    def _mode(sp):
        return int(max(set(sp), key=lambda x: (sp.count(x), int(x[:-4])))[:-4]) // 1000
    if lr.isdigit():
        line_gbps, data['line_rate_src'] = int(lr), 'collector'
    elif speeds:
        line_gbps = _mode(speeds)
        data['line_rate_src'] = 'most common NIC speed'
    else:
        line_gbps, data['line_rate_src'] = 0, 'best run seen (no NIC speed data)'
    # per-rail line rate only when the collector says so (FS_LINE_GBPS=A,B); otherwise the faster rail's
    # most common speed for both, so a rail that came up slow everywhere shows as slow
    ip_rail = {}
    for l in read_file('rails.txt').splitlines()[1:]:
        q = l.split()
        if len(q) >= 8:
            ip_rail[q[3]], ip_rail[q[7]] = 'A', 'B'
    rail_rate = {}
    for r in ('A', 'B'):
        v = data['metadata'].get(f'line_rate_{r.lower()}_gbps', '')
        rs = [l.split()[3] for l in read_file('nic_diagnostics.txt').splitlines()
              if len(l.split()) >= 4 and ip_rail.get(l.split()[2]) == r and re.match(r'^\d+Mb/s$', l.split()[3])]
        rail_rate[r] = int(v) if v.isdigit() else (_mode(rs) if rs and not lr.isdigit() else line_gbps)
    if line_gbps and not lr.isdigit():
        line_gbps = max(rail_rate.values())
        rail_rate = {r: line_gbps for r in rail_rate}
    data['ip_rail'], data['rail_rate'] = ip_rail, rail_rate
    line_speed = f'{line_gbps * 1000}Mb/s'

    # iperf3 results — with iteration/phase markers
    cur_iter, cur_phase, cur_wave = 0, 0, ''
    for line in read_file('iperf3_results.txt').splitlines():
        # Marker lines: ### iteration:N phase:N [wave:w/W]
        mm = re.match(r'^###\s+iteration:(\d+)\s+phase:(\d+)(?:\s+wave:(\S+))?', line)
        if mm:
            cur_iter, cur_phase, cur_wave = int(mm.group(1)), int(mm.group(2)), mm.group(3) or ''
            continue
        m = re.match(r'^(\S+),(\S+),\[SUM\]\s+\S+\s+sec\s+([\d.]+)\s+([KMGTP]?)Bytes\s+([\d.]+)\s+Gbits/sec\s+receiver\s*(?:retransmits:(\d+))?', line)
        if m:
            bval = float(m.group(3))
            bunit = m.group(4) or ''
            unit_scale = {'': 1e-9, 'K': 1e-6, 'M': 1e-3, 'G': 1, 'T': 1024, 'P': 1048576}
            gbytes = int(round(bval * unit_scale.get(bunit, 1)))
            data['iperf_results'].append({
                'iteration': cur_iter, 'phase': cur_phase, 'wave': cur_wave,
                'src': m.group(1), 'dst': m.group(2),
                'gbytes': gbytes, 'gbps': round(float(m.group(5)), 1),
                'retransmits': int(m.group(6)) if m.group(6) else 0,
            })

    data['_nic_diag_lines'] = read_file('nic_diagnostics.txt').splitlines()   # for --compare
    # NIC diagnostics
    optics_by_key = {}  # (host, nic) -> optics entry, for dedup with raw fallback
    for line in read_file('nic_diagnostics.txt').splitlines():
        parts = line.split()
        if len(parts) >= 16:
            host, nic, ip, speed = parts[0], parts[1], parts[2], parts[3]
            # 'n/a' = this driver has no such counter (not zero)
            corr, l0, l1, l2, l3, ld, sym = (_int(p) for p in parts[4:11])
            # ethtool prints "Unknown!" on virtio and similar: no speed, not an off-speed NIC
            data['nic_inventory']['total'] += 1
            if not re.match(r'^\d+Mb/s$', speed):
                data['nic_inventory']['unknown'] += 1
                # still listed: a link-down NIC reports Unknown! too
                data['nic_inventory']['unknown_list'].append({'host': host, 'nic': nic, 'ip': ip, 'speed': speed})
            elif speed == f"{data['rail_rate'].get(ip_rail.get(ip), line_gbps) * 1000}Mb/s":
                data['nic_inventory']['at_line'] += 1
            else:
                data['nic_inventory']['not_line'].append({'host': host, 'nic': nic, 'ip': ip, 'speed': speed})
            if corr:
                data['fec_top'].append({
                    'host': host, 'nic': nic, 'ip': ip, 'corrected': corr,
                    'lanes': [x or 0 for x in (l0, l1, l2, l3)], 'pcs_sym_err': sym or 0,
                })
            # Optics from NIC_DIAG fields 11-15
            def _safe_float(s):
                try:
                    return float(s)
                except (ValueError, TypeError):
                    return None
            rx = [_safe_float(parts[i]) for i in range(11, 15)]
            temp = _safe_float(parts[15])
            if any(v is not None for v in rx) or temp is not None:
                optics_by_key[(host, nic)] = {
                    'host': host, 'nic': nic, 'ip': ip,
                    'rx_power': rx, 'temp': temp,
                }
    data['fec_top'].sort(key=lambda x: -x['corrected'])

    # Driver info
    for line in read_file('driver_info.txt').splitlines():
        parts = line.split()
        if len(parts) >= 7:
            data['driver_info'].append({
                'host': parts[0], 'nic': parts[1], 'ip': parts[2],
                'driver': parts[3], 'version': parts[4], 'firmware': parts[5],
                'part': parts[6].strip('()') if len(parts) > 6 else '',
            })

    # LLDP
    for line in read_file('lldp_neighbors.txt').splitlines():
        parts = line.split()
        if len(parts) >= 6:
            data['lldp_info'].append({
                'host': parts[0], 'nic': parts[1], 'ip': parts[2],
                'switch': parts[3], 'port_id': parts[4] if len(parts) > 4 else '',
                'port_desc': parts[5].replace('_', ' ') if len(parts) > 5 else '',
                'sys_desc': ' '.join(parts[6:]).replace('_', ' ') if len(parts) > 6 else '',
            })

    # Packet drops
    for line in read_file('packet_drops.txt').splitlines():
        m = re.match(r'^(\S+)\s+(\S+)\s+\S+\s+rx_drop:(\d+)\s+tx_drop:(\d+)\s+rx_oob:(\d+)', line)
        if m:
            data['packet_drops'].append({
                'host_nic': m.group(1), 'ip': m.group(2),
                'rx_drop': int(m.group(3)), 'tx_drop': int(m.group(4)),
                'rx_oob': int(m.group(5)), 'phases': 1,
            })

    # Raw per-host files
    raw_dir = os.path.join(base, 'raw_per_host')
    if os.path.isdir(raw_dir):
        for fname in os.listdir(raw_dir):
            if fname.startswith('._'):  # macOS tar metadata
                continue
            host = fname.replace('.txt', '')
            with open(os.path.join(raw_dir, fname), errors='replace') as f:
                data['raw_hosts'][host] = f.read()

    # Optics: fallback to raw per-host ethtool -m output when NIC_DIAG fields are bad
    # Build a map of host+nic -> ip from nic_diagnostics for cross-reference
    nic_ip_map = {}
    for line in read_file('nic_diagnostics.txt').splitlines():
        parts = line.split()
        if len(parts) >= 3:
            nic_ip_map[(parts[0], parts[1])] = parts[2]

    for host, raw_text in data['raw_hosts'].items():
        # Find each ethtool -m block
        for m in re.finditer(r'=== ethtool -m (\S+) ===\n(.*?)(?====|$)', raw_text, re.DOTALL):
            nic = m.group(1)
            block = m.group(2)
            key = (host, nic)
            # Skip if we already have valid data from NIC_DIAG
            existing = optics_by_key.get(key)
            if existing and any(v is not None for v in existing['rx_power']):
                continue
            rx = [None] * 4
            temp = None
            for ch in range(1, 5):
                pm = re.search(rf'Rcvr signal avg optical power \(Channel {ch}\)\s*:\s*[\d.]+ mW / ([-\d.inf]+) dBm', block)
                if pm and pm.group(1) != '-inf':
                    try:
                        rx[ch - 1] = float(pm.group(1))
                    except ValueError:
                        pass
            tm = re.search(r'Module temperature\s*:\s*([\d.]+) degrees C', block)
            if tm:
                try:
                    temp = float(tm.group(1))
                except ValueError:
                    pass
            if any(v is not None for v in rx) or temp is not None:
                ip = nic_ip_map.get(key, 'unknown')
                optics_by_key[key] = {
                    'host': host, 'nic': nic, 'ip': ip,
                    'rx_power': rx, 'temp': temp,
                }

    data['optics'] = sorted(optics_by_key.values(), key=lambda x: x['host'])

    if not line_gbps:
        line_gbps = int(max((r['gbps'] for r in data['iperf_results']), default=100))
        if line_gbps < 1:   # every run at 0 Gbps (or no runs): no rate to scale against
            line_gbps, data['line_rate_src'] = 1, 'unknown: no NIC speed and no run above 0 Gbps; 1G used for scale'
    ok = int(data['metadata'].get('ok_pct', 75))
    slow = int(data['metadata'].get('slow_pct', 50))
    data['line_rate'] = line_gbps
    # healthy / functional / mid / slow cut-offs; 350/300/250/200 at 400G
    # one decimal so low rates keep distinct bands (2.6/2.2/1.9/1.5 at 3G); whole values print bare
    def _tier(x):
        x = round(x, 1)
        return int(x) if x == int(x) else x
    def _tiers(l):
        return {'G': _tier(l * 0.875), 'F': _tier(l * ok / 100), 'M': _tier(l * (ok + slow) / 200), 'S': _tier(l * slow / 100)}
    data['tiers'] = _tiers(line_gbps)
    data['rail_tiers'] = {r: _tiers(v) if v else data['tiers'] for r, v in data['rail_rate'].items()}
    if data['rail_rate']['A'] == data['rail_rate']['B']:   # one rate (or an old tarball): exactly as before
        data['rail_tiers'] = {r: data['tiers'] for r in ('A', 'B')}
    F = data['tiers']['F']

    # Build slow_ips from iperf results
    ip_stats, xonly = _ip_speeds(data['iperf_results'], data['ip_rail'])

    ip_host = {}
    for l in data['lldp_info']:
        ip_host[l['ip']] = l['host']
    for d in data['driver_info']:
        ip_host[d['ip']] = d['host']

    # Find NIC diag for an IP
    nic_by_ip = {}
    for line in read_file('nic_diagnostics.txt').splitlines():
        parts = line.split()
        if len(parts) >= 16:
            nic_by_ip[parts[2]] = parts
    data['ip_gbps'] = {ip: int(p[3][:-4]) / 1000 for ip, p in nic_by_ip.items() if re.match(r'^\d+Mb/s$', p[3])}

    for ip, speeds in ip_stats.items():
        avg = sum(speeds) / len(speeds)
        if avg < data['rail_tiers'].get(data['ip_rail'].get(ip), data['tiers'])['F']:
            entry = {'ip': ip, 'avg': round(avg, 1), 'samples': len(speeds), 'cross_only': ip in xonly, 'diag': {}}
            entry['diag']['host'] = ip_host.get(ip, '')
            if ip in nic_by_ip:
                p = nic_by_ip[ip]
                entry['diag']['nic'] = p[1]
                entry['diag']['speed'] = p[3]
                fec = _int(p[4])
                # Lifetime count with no time base: 400G PAM4 links correct constantly, so no diagnosis from it
                entry['diag']['fec'] = 'n/a' if fec is None else fec
            data['slow_ips'].append(entry)
    data['slow_ips'].sort(key=lambda x: x['avg'])

    # FEC as a rate over the run (v2 collector), not a lifetime count
    speed_of = {}
    for l in read_file('nic_diagnostics.txt').splitlines():
        p = l.split()
        if len(p) >= 4 and re.match(r'^\d+Mb/s$', p[3]):
            speed_of[f"{p[0]}_{p[1]}"] = int(p[3][:-4]) * 1e6
    agg = {}
    for l in read_file('fec_rates.txt').splitlines():
        p = l.split()
        if len(p) < 7:
            continue
        a = agg.setdefault(p[1], {'secs': 0, 'cb': None, 'ub': None, 'bits': None, 'sym': None, 'reset': False, 'off': False})
        a['secs'] += _int(p[2]) or 0
        for key, v in zip(('cb', 'ub', 'bits', 'sym'), p[3:7]):
            if v == 'reset':
                a['reset'] = True
            elif v == 'off':
                a['off'] = True
            elif _int(v) is not None:
                a[key] = (a[key] or 0) + int(v)
    fec_rate = []
    for hn, a in agg.items():
        bps = speed_of.get(hn)
        ber = a['bits'] / (a['secs'] * bps) if a['bits'] is not None and bps and a['secs'] else None
        if a['ub']:
            st = 'UNCORRECTABLE'
        elif ber is not None and ber >= FEC_LIMIT_BER:
            st = 'OVER FEC LIMIT'
        elif ber is not None and ber >= FEC_WATCH_BER:
            st = 'WATCH'
        elif a['off'] and a['cb'] is None and a['bits'] is None:
            st = 'FEC off'
        elif a['cb'] is None and a['bits'] is None:
            st = 'n/a'
        else:
            st = 'ok'
        fec_rate.append({'nic': hn, 'host': nic_host.get(hn, ''), 'secs': a['secs'], 'cb': a['cb'], 'ub': a['ub'],
                         'bits': a['bits'], 'ber': ber, 'status': st, 'reset': a['reset']})
    order = {'UNCORRECTABLE': 0, 'OVER FEC LIMIT': 1, 'WATCH': 2, 'ok': 3, 'FEC off': 4, 'n/a': 5}
    fec_rate.sort(key=lambda f: (order[f['status']], -(f['ber'] or 0), -(f['cb'] or 0)))
    data['fec_rate'] = fec_rate
    fec_by_nic = {f['nic']: f for f in fec_rate}
    for e in data['slow_ips']:
        f = fec_by_nic.get(f"{e['diag'].get('host', '')}_{e['diag'].get('nic', '')}")
        e['diag'].pop('diagnosis', None)
        if f and f['status'] == 'UNCORRECTABLE':
            e['diag']['diagnosis'] = 'Uncorrectable FEC blocks during the run: link errors reach the host'
        elif f and f['status'] == 'OVER FEC LIMIT':
            e['diag']['diagnosis'] = f"Pre-FEC BER {f['ber']:.1e} above the RS(544,514) correction limit"
        elif f and f['status'] == 'WATCH':
            e['diag']['diagnosis'] = f"Elevated pre-FEC BER {f['ber']:.1e} (watch level, heuristic): check optics and cabling"

    # Preflight findings (v2 collector): rail anomalies and rail gateways
    data['anomalies'] = [l.split(None, 2) for l in read_file('rail_anomalies.txt').splitlines() if l.strip()]
    data['gateways'] = [l.split() for l in read_file('gateways.txt').splitlines() if l.strip()]

    # Problems make the run fail loudly (red banner, exit 3); notes are shown, not failed on
    meta = data['metadata']
    problems, notes = [], []
    if not data['iperf_results']:
        problems.append('No throughput results in this archive.')
    elif all(r['gbps'] == 0 for r in data['iperf_results']):
        problems.append('Every run measured 0 Gbps: iperf3 connected but moved no data (another run on the same hosts, or a blocked path).')
    try:
        want = int(meta.get('iterations', 0))
    except ValueError:
        want = 0
    seen = {r['iteration'] for r in data['iperf_results']}
    missing = [i for i in range(1, want + 1) if i not in seen]
    if data['iperf_results'] and missing:
        problems.append(f'Iterations with no results: {missing} of {want}.')
    cov = meta.get('coverage')
    if cov and cov != 'COMPLETE':
        problems.append(f"Collector coverage {cov}: hosts tested {meta.get('hosts_tested', '?')}/{meta.get('hosts_expected', '?')}, "
                        f"paths with a result {meta.get('paths_ok', '?')}/{meta.get('paths_planned', '?')} (see Not tested).")
    hosts = _int(meta.get('total_hosts')) or 0
    if hosts and data['nic_inventory']['total'] == 0:
        problems.append('No NIC diagnostics were collected.')
    reads = _int(meta.get('drop_nics_read_min'))
    data['drops_unknown'] = reads == 0
    if reads == 0 and hosts:
        problems.append('Drop counters were not read: "no drops" here would mean unknown.')
    elif reads is not None and reads < (_int(meta.get('drop_nics_expected')) or 0):
        notes.append(f"Drop counters read on {reads} of {meta.get('drop_nics_expected')} rail NICs in at least one iteration.")
    if data['lldp_info'] and all(l['switch'] == 'unknown' for l in data['lldp_info']):
        notes.append('No LLDP neighbours seen (lldpd not running, or the switches do not send LLDP): the switch view is empty.')
    flaps = [l.split() for l in read_file('link_flaps.txt').splitlines() if len(l.split()) >= 4]
    if flaps:
        problems.append('Rail links went down during the run (their runs measured a flap, not the fabric): '
                        + ', '.join(f'{f[1]} {f[0]} (+{f[3]})' for f in flaps))
    xr = meta.get('cross_rail')
    if xr == 'unrouted':
        notes.append('Rails not routed to each other: every A<->B path check failed on routing, no same-rail one did. '
                     'Either separate fabrics by design (rerun with FS_CROSS_RAIL=0) or inter-rail routing missing on '
                     'every host; the skipped A<->B paths count until the operator says which.')
    elif xr == 'off':
        notes.append('Cross-rail phase (A<->B) not run: FS_CROSS_RAIL=0 (operator: rails are separate fabrics).')
    xs = [r for r in data['iperf_results'] if _cross(r, data['ip_rail'])]
    fx = min(data.get('rail_tiers', {}).get(k, data['tiers'])['F'] for k in ('A', 'B'))
    slow_x = [r for r in xs if r['gbps'] < fx]
    if slow_x:
        agg, shared = _cross_finding(data)
        problems.append(f'{len(slow_x)} of {len(xs)} cross-rail (A<->B) runs below {fx:g} Gbps. Per-IP and per-rail figures '
                        'leave cross-rail runs out, so look at the path between the rails (spine, inter-rail routing). '
                        + (agg + '.' if agg else ''))
        if shared:
            problems.append(shared)
    if 'coverage' not in meta:
        notes.append('Archive from a collector without coverage counts (v1 or earlier): only result and iteration checks apply.')
    data['problems'], data['notes'] = problems, notes

    # Cleanup
    shutil.rmtree(tmpdir, ignore_errors=True)

    return data


if __name__ == '__main__':
    if not os.path.exists(INPUT_FILE):
        print(f"Error: {INPUT_FILE} not found")
        sys.exit(1)

    print(f"Parsing {INPUT_FILE}...")
    data = parse_tar_archive(INPUT_FILE)
    if COMPARE_FILE:
        if not os.path.exists(COMPARE_FILE):
            print(f"Error: {COMPARE_FILE} not found")
            sys.exit(1)
        print(f"Comparing with {COMPARE_FILE}...")
        data['compare'] = compare_runs(data, parse_tar_archive(COMPARE_FILE))
        print(f"  {len(data['compare']['changes'])} NIC changes, "
              f"{len(data['compare']['down_added'])} newly down IPs, {len(data['compare']['down_cleared'])} recovered")

    print(f"  {len(data['iperf_results'])} iperf3 results")
    print(f"  {len(data['down_ips'])} down IPs")
    print(f"  Line rate {data['line_rate']}G ({data['line_rate_src']}); cut-offs {data['tiers']}")
    print(f"  {len(data['slow_ips'])} slow IPs (< {data['tiers']['F']} Gbps avg)")
    print(f"  {len(data['fec_top'])} FEC entries")
    print(f"  {len(data['driver_info'])} driver entries")
    print(f"  {len(data['lldp_info'])} LLDP entries")
    print(f"  {len(data['optics'])} optics entries")
    print(f"  {len(data.get('raw_hosts', {}))} raw host files")
    iters = set(r['iteration'] for r in data['iperf_results'])
    print(f"  Iterations: {sorted(iters) if iters else 'none'}")
    print(f"Generating {OUTPUT_FILE}...")
    generate_html(data, OUTPUT_FILE)
    for n in data['notes']:
        print(f"  NOTE: {n}")
    if data['problems']:
        for p in data['problems']:
            print(f"  PROBLEM: {p}", file=sys.stderr)
        print("Dashboard written, but the data is incomplete (exit 3).", file=sys.stderr)
        sys.exit(3)
