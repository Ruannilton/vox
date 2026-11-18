#!/usr/bin/env python3
"""Analisa capturas AB_*.tracy (f<b>_b<b>_r<r>): agrega repeticoes por config."""
import csv, statistics, subprocess, glob, os, tempfile
from collections import defaultdict

def frames(path):
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.csv', delete=False)
    tmp.close()
    with open(tmp.name, 'w') as out:
        subprocess.run(['./tools/tracy/tracy-csvexport.exe', '-u', '-f', 'frame', path],
                       stdout=out, stderr=subprocess.DEVNULL, check=True)
    durs = []
    with open(tmp.name) as f:
        for row in csv.DictReader(f):
            if row['name'] == 'frame':
                durs.append(int(row['exec_time_ns']) / 1e6)
    os.unlink(tmp.name)
    return durs

runs = defaultdict(list)  # config -> [durs]
for path in sorted(glob.glob('bin/debug/0.1.35/tracy/AB_*.tracy')):
    tag = os.path.basename(path)[3:-6]            # f2_b16_r1
    cfg = tag.rsplit('_r', 1)[0]                  # f2_b16
    durs = frames(path)
    if durs:
        runs[cfg].append(durs)

def med(v): return statistics.median(v)

print(f"{'config':<8} {'reps':>4} {'fps_med(med)':>12} {'p95_ms(med)':>11} {'max_ms':>8} "
      f"{'%<60(med)':>10} {'%<30(med)':>10} {'%<30(pior)':>10}")
agg = {}
for cfg, ds in sorted(runs.items()):
    meds = sorted(med(d) for d in ds)
    p95s = sorted(d[int(len(d)*.95)] for d in ds)
    mx = max(max(d) for d in ds)
    u60 = sorted(100*sum(1 for x in d if x > 16.67)/len(d) for d in ds)
    u30 = sorted(100*sum(1 for x in d if x > 33.33)/len(d) for d in ds)
    agg[cfg] = dict(fps=1000/med(meds), p95=med(p95s), max=mx,
                    u60=med(u60), u30=med(u30), u30worst=u30[-1])
    print(f"{cfg:<8} {len(ds):>4} {1000/med(meds):>12.1f} {med(p95s):>11.2f} {mx:>8.1f} "
          f"{med(u60):>9.1f}% {med(u30):>9.1f}% {u30[-1]:>9.1f}%")

print("\nveredito (headless; limiar 30 fps = frame > 33,3 ms):")
best = min(agg, key=lambda k: agg[k]['u30'])
for cfg, a in agg.items():
    ok30 = a['u30'] == 0
    ok60 = a['u60'] == 0
    print(f"  {cfg}: {'OK>30fps estavel' if ok30 else f'FALHA >30fps ({a['u30']:.1f}% dos frames abaixo)'} | "
          f"{'OK>60fps estavel' if ok60 else f'falha >60fps ({a['u60']:.1f}% abaixo)'}")
print(f"\nmelhor config por %% frames <30fps: {best}")
