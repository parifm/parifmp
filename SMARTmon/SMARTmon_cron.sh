#!/bin/bash

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG_DIR="${DIR}/logs"
CLUSTERS="$(cd ${LOG_DIR} ; ls -1)"
TD="$(mktemp -d --tmpdir=/dev/shm SMARTmon_cron.XXXXXX)"

cd ${DIR}

for i in $CLUSTERS; do
  ./cluster_col.sh $i
  csv="${TD}/${i}_SMARTmon_$(date "+%b_%d_%Y_%s").csv"
  perl smart_to_tsv.pl $(ls -t ${LOG_DIR}/${i}/*.log.gz | head -n 14) | ./.venvs/SMARTmon/bin/python3 compare_smart.py -c -r > $csv
  body="$(grep '#' $csv | tail -n1; grep -v '^#' $csv)"
  wc -l $csv | grep -q '^0$' || for e in alerts-<channel_key>@<company>.slack.com ; do echo -e "${body}" | mail -a $csv -s "$i - SMART Alert" $e ; done
done

