#!/usr/bin/env bash
# A/B: frames_in_flight (2,3) x chunks_per_batch (16,8), N repeticoes.
# Uso: bash tools/ab_test.sh [reps]
set -u
REPS=${1:-3}
cd "$(cd "$(dirname "$0")/.." && pwd)/bin"

run_case() {
  local frames=$1 batch=$2 rep=$3 tag="f${1}_b${2}_r${rep}"
  cat > "ab_${tag}.ini" <<EOF
[streaming]
vision=8
generation=23
unload=24
simulation=5
[compute]
chunks_per_batch=${batch}
batches_in_flight=3
[sync]
frames_in_flight=${frames}
EOF
  for pid in $(netstat -ano | grep ':8086' | grep LISTENING | awk '{print $NF}' | sort -u); do
    taskkill //F //PID "$pid" >/dev/null 2>&1
    sleep 1
  done
  ./vox_tracy.exe --config "ab_${tag}.ini" --replay ../docs/examples/vs23_genstutter.jsonl > "ab_${tag}.log" 2>&1 &
  local app_pid=$!
  for i in $(seq 1 20); do
    if netstat -ano | grep ':8086' | grep -q LISTENING; then break; fi
    sleep 1
  done
  sleep 1
  ../tools/tracy/tracy-capture.exe -o "debug/0.1.35/tracy/AB_${tag}.tracy" -s 30 > "ab_${tag}_cap.log" 2>&1
  echo "case ${tag}: $(grep -E 'Frames' ab_${tag}_cap.log | tr -d '\n')"
  taskkill //F //PID "$app_pid" >/dev/null 2>&1
  sleep 2
}

for rep in $(seq 1 "$REPS"); do
  run_case 2 16 "$rep"
  run_case 3 16 "$rep"
  run_case 2 8 "$rep"
  run_case 3 8 "$rep"
done
echo "AB_DONE"
