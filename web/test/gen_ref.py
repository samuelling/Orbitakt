"""Reference positions from the Python sgp4 package (Vallado's reference code, WGS-72, improved
mode) for every TLE in the given directory, for the JS port to be compared against."""
import sys, json, glob, math
from sgp4.api import Satrec, WGS72, jday
from sgp4.propagation import gstime

tle_dir, out = sys.argv[1], sys.argv[2]
sats = []
for f in sorted(glob.glob(tle_dir + '/*.tle')):
    lines = [l.rstrip('\r\n') for l in open(f) if l.strip()]
    i = 0
    while i + 2 < len(lines) + 0 and i + 2 <= len(lines) - 1 + 1:
        if lines[i+1].startswith('1 ') and lines[i+2].startswith('2 '):
            sats.append((lines[i].strip(), lines[i+1], lines[i+2])); i += 3
        else:
            i += 1
rows = []
for name, l1, l2 in sats:
    s = Satrec.twoline2rv(l1, l2, WGS72)
    ep = s.jdsatepoch + s.jdsatepochF
    pts = []
    for dmin in (0, 7.5, 95, 1440, 4320):
        jd = ep + dmin / 1440.0
        jdi = math.floor(jd - 0.5) + 0.5
        e, r, v = s.sgp4(jdi, jd - jdi)
        if e == 0:
            pts.append({'min': dmin, 'r': list(r), 'gst': gstime(jd)})
    rows.append({'name': name, 'l1': l1, 'l2': l2, 'epoch_jd': ep, 'pts': pts,
                 'period': 2 * math.pi / s.no_kozai, 'ecc': s.ecco})
json.dump(rows, open(out, 'w'))
print(len(rows), 'satellites')
