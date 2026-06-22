#!/usr/bin/env python3
# Grades ./detect --key output against ground-truth keys parsed from file/folder names.
import os, re, subprocess, sys, glob

SAMPLES = "/Users/palmer/Music/Samples"
DETECT  = "/Users/palmer/Work/Dev/sample-mate/prototype/detect"

PC = {'C':0,'C#':1,'DB':1,'D':2,'D#':3,'EB':3,'E':4,'F':5,'F#':6,'GB':6,
      'G':7,'G#':8,'AB':8,'A':9,'A#':10,'BB':10,'B':11}

def parse_key(tok):
    """'Ebm','F#m','Dm','C','Bb' -> (pc, is_minor) or None."""
    if not tok: return None
    t = tok.strip()
    minor = t.endswith('m') and not t.upper().endswith('BM')==False  # handle below
    minor = t.endswith('m')
    root = t[:-1] if minor else t
    root = root.upper()
    if root not in PC: return None
    return (PC[root], minor)

def rel_major(pc_minor):      # relative major of a minor key
    return (pc_minor + 3) % 12
def rel_minor(pc_major):
    return (pc_major + 9) % 12

def categorize(exp, det):
    if exp is None:
        return 'gated_ok' if det is None else 'false_tag'
    if det is None:
        return 'gated_miss'
    ep, em = exp; dp, dm = det
    if ep == dp and em == dm: return 'exact'
    if ep == dp and em != dm: return 'parallel'
    # relative major/minor (same pitch-set)
    if em and not dm and dp == rel_major(ep): return 'relative'
    if (not em) and dm and dp == rel_minor(ep): return 'relative'
    if dp == (ep+7) % 12: return 'fifth'
    if dp == (ep+5) % 12: return 'fourth'
    return 'wrong'

# ---- build ground-truth file list ----
items = []  # (path, (pc,minor) or None, setname)

# Rhodes progressions: folder "progression N - KEY"
rh = os.path.join(SAMPLES, "Sauce Audio - Only The Rhodes Vol.1")
for d in sorted(os.listdir(rh)):
    m = re.match(r'progression \d+ - (.+)$', d)
    if not m: continue
    key = parse_key(m.group(1))
    for f in glob.glob(os.path.join(rh, d, "**", "*.wav"), recursive=True):
        items.append((f, key, "Rhodes"))

# Cookbook compositions (loose + stems): key token in filename
cb = os.path.join(SAMPLES, "Sauce Audio - The Cookbook", "compositions")
for f in glob.glob(os.path.join(cb, "**", "*.wav"), recursive=True):
    m = re.search(r'_([A-G][b#]?m?)_\d+_BPM', os.path.basename(f))
    items.append((f, parse_key(m.group(1)) if m else None, "Cookbook"))

# BlueNote: token between first and second underscore; drums/perc -> None
bn = os.path.join(SAMPLES, "BlueNoteSessions_Mini_SP")
for f in glob.glob(os.path.join(bn, "*.wav")):
    parts = os.path.basename(f).split('_')
    tok = parts[1] if len(parts) > 1 else ''
    key = parse_key(tok) if tok not in ('MellowAcDrums','BellsPercussion','GuiroPercussion','TakeItAcDrums') else None
    items.append((f, key, "BlueNote"))

print(f"Total ground-truth files: {len(items)}")

# ---- run detector in batches ----
paths = [it[0] for it in items]
det = {}
B = 60
for i in range(0, len(paths), B):
    batch = paths[i:i+B]
    out = subprocess.run([DETECT, "--key"] + batch, capture_output=True, text=True).stdout
    for line in out.splitlines():
        c = line.split('\t')
        if len(c) == 3:
            label = None if c[0] in ('-','ERR') else c[0]
            det[c[2]] = (parse_key(label) if label else None)

# ---- grade ----
from collections import Counter
cats = Counter()
by_set = {}
for path, exp, setname in items:
    d = det.get(path)
    cat = categorize(exp, d)
    cats[cat] += 1
    by_set.setdefault(setname, Counter())[cat] += 1

def report(name, c):
    tot = sum(c.values())
    tonic_ok = c['exact'] + c['parallel']          # tonic pitch-class correct
    print(f"\n[{name}] n={tot}")
    for k in ['exact','parallel','relative','fifth','fourth','wrong','gated_miss','gated_ok','false_tag']:
        if c[k]: print(f"   {k:12s} {c[k]:4d}  ({100*c[k]/tot:.0f}%)")
    print(f"   --> exact mode+tonic: {100*c['exact']/tot:.0f}%   tonic-correct(any mode): {100*tonic_ok/tot:.0f}%")

report("ALL", cats)
for s, c in by_set.items():
    report(s, c)
