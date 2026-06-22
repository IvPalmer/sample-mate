#!/usr/bin/env python3
# Head-to-head: libKeyFinder (./kf) vs native Swift (./detect --key) on identical ground-truth.
import os, re, subprocess, glob
from collections import Counter

SAMPLES = "/Users/palmer/Music/Samples"
HERE = os.path.dirname(os.path.abspath(__file__))
DETECT, KF = os.path.join(HERE, "detect"), os.path.join(HERE, "kf")

PC = {'C':0,'C#':1,'DB':1,'D':2,'D#':3,'EB':3,'E':4,'F':5,'F#':6,'GB':6,
      'G':7,'G#':8,'AB':8,'A':9,'A#':10,'BB':10,'B':11}

def parse_key(tok):
    if not tok: return None
    t = tok.strip(); minor = t.endswith('m'); root = (t[:-1] if minor else t).upper()
    return (PC[root], minor) if root in PC else None

def categorize(exp, det):
    if exp is None: return 'gated_ok' if det is None else 'false_tag'
    if det is None: return 'gated_miss'
    ep, em = exp; dp, dm = det
    if ep == dp and em == dm: return 'exact'
    if ep == dp: return 'parallel'
    if em and not dm and dp == (ep+3)%12: return 'relative'
    if (not em) and dm and dp == (ep+9)%12: return 'relative'
    if dp == (ep+7)%12: return 'fifth'
    if dp == (ep+5)%12: return 'fourth'
    return 'wrong'

# ---- ground truth ----
items = []  # (path, key, setname)
rh = os.path.join(SAMPLES, "Sauce Audio - Only The Rhodes Vol.1")
for d in sorted(os.listdir(rh)):
    m = re.match(r'progression \d+ - (.+)$', d)
    if not m: continue
    k = parse_key(m.group(1))
    for f in glob.glob(os.path.join(rh, d, "**", "*.wav"), recursive=True):
        items.append((f, k, "Rhodes"))
cb = os.path.join(SAMPLES, "Sauce Audio - The Cookbook", "compositions")
for f in glob.glob(os.path.join(cb, "**", "*.wav"), recursive=True):
    m = re.search(r'_([A-G][b#]?m?)_\d+_BPM', os.path.basename(f))
    setn = "Cookbook-mix" if os.path.dirname(f) == cb else "Cookbook-stems"
    items.append((f, parse_key(m.group(1)) if m else None, setn))
bn = os.path.join(SAMPLES, "BlueNoteSessions_Mini_SP")
for f in glob.glob(os.path.join(bn, "*.wav")):
    p = os.path.basename(f).split('_'); tok = p[1] if len(p)>1 else ''
    k = parse_key(tok) if tok not in ('MellowAcDrums','BellsPercussion','GuiroPercussion','TakeItAcDrums') else None
    items.append((f, k, "BlueNote"))

paths = [it[0] for it in items]

def run(cmd_prefix):
    out = {}
    B = 60
    for i in range(0, len(paths), B):
        batch = paths[i:i+B]
        r = subprocess.run(cmd_prefix + batch, capture_output=True, text=True).stdout
        for line in r.splitlines():
            c = line.split('\t')
            if len(c) >= 2:
                lab = c[0]; path = c[-1]
                out[path] = None if lab in ('-','ERR') else parse_key(lab)
    return out

print(f"Running both detectors on {len(items)} files...")
native = run([DETECT, "--key"])
libkf  = run([KF])

def summarize(name, idxs):
    cn, cl = Counter(), Counter()
    agree = 0
    for j in idxs:
        path, exp, _ = items[j]
        dn, dl = native.get(path), libkf.get(path)
        cn[categorize(exp, dn)] += 1
        cl[categorize(exp, dl)] += 1
        if dn == dl: agree += 1
    tot = len(idxs)
    def acc(c): return (c['exact'], c['exact']+c['parallel'])  # (exact, tonic-correct)
    ne, nt = acc(cn); le, lt = acc(cl)
    print(f"\n=== {name}  (n={tot}) ===")
    print(f"  {'metric':22s}{'NATIVE':>10s}{'libKeyFinder':>14s}")
    print(f"  {'exact (tonic+mode)':22s}{100*ne/tot:>9.0f}%{100*le/tot:>13.0f}%")
    print(f"  {'tonic correct':22s}{100*nt/tot:>9.0f}%{100*lt/tot:>13.0f}%")
    print(f"  {'fifth errors':22s}{100*cn['fifth']/tot:>9.0f}%{100*cl['fifth']/tot:>13.0f}%")
    print(f"  {'relative errors':22s}{100*cn['relative']/tot:>9.0f}%{100*cl['relative']/tot:>13.0f}%")
    print(f"  {'gated/no-tag':22s}{100*(cn['gated_miss']+cn['gated_ok'])/tot:>9.0f}%{100*(cl['gated_miss']+cl['gated_ok'])/tot:>13.0f}%")
    print(f"  detectors agree: {100*agree/tot:.0f}%")

by = {}
for j, it in enumerate(items): by.setdefault(it[2], []).append(j)
summarize("ALL", list(range(len(items))))
for s in ["Cookbook-mix","Rhodes","Cookbook-stems","BlueNote"]:
    if s in by: summarize(s, by[s])
