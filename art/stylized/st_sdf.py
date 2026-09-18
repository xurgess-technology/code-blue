"""Signed distance fields in numpy, and a surface-nets mesher.

Every shape is a function f(P) -> distances, P an (N, 3) float array in metres (Blender axes: Z up,
the character faces -Y, its left is +X). Negative is inside. Shapes combine with smooth unions, so
parts blend into each other with soft fillets instead of the hard creases of joined primitives.
No bpy here: this runs anywhere numpy does.
"""
import math
import numpy as np


def V(*a):
    return np.array(a, dtype=np.float64)


# ============================================================ primitives
def sphere(c, r):
    c = np.asarray(c, float)
    return lambda P: np.linalg.norm(P - c, axis=1) - r


def ellipsoid(c, r, R=None):
    """Approximate ellipsoid distance (iq's bound, good near the surface). R: optional 3x3 rotation
    applied to the local axes (columns = local x, y, z in world)."""
    c = np.asarray(c, float)
    r = np.asarray(r, float)

    def f(P):
        Q = P - c
        if R is not None:
            Q = Q @ R
        k0 = np.linalg.norm(Q / r, axis=1)
        k1 = np.linalg.norm(Q / (r * r), axis=1)
        return np.where(k1 > 1e-12, k0 * (k0 - 1.0) / np.maximum(k1, 1e-12), -r.min())
    return f


def round_cone(a, b, r1, r2):
    """A capsule from a (radius r1) to b (radius r2), tapered (iq's sdRoundCone)."""
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    ba = b - a
    l2 = ba @ ba
    rr = r1 - r2
    a2 = l2 - rr * rr
    il2 = 1.0 / l2

    def f(P):
        pa = P - a
        y = pa @ ba
        z = y - l2
        x = pa * l2 - np.outer(y, ba)
        x2 = np.einsum('ij,ij->i', x, x)
        y2 = y * y * l2
        z2 = z * z * l2
        k = np.sign(rr) * rr * rr * x2
        out = (np.sqrt(x2 * a2 * il2) + y * rr) * il2 - r1
        m1 = np.sign(z) * a2 * z2 > k
        m2 = np.sign(y) * a2 * y2 < k
        out = np.where(m1, np.sqrt(x2 + z2) * il2 - r2, out)
        out = np.where(m2 & ~m1, np.sqrt(x2 + y2) * il2 - r1, out)
        return out
    return f


def capsule(a, b, r):
    return round_cone(a, b, r, r)


def chain(points, radii):
    """Round cones through a polyline, smoothly unioned (a limb)."""
    fs = [round_cone(points[i], points[i + 1], radii[i], radii[i + 1]) for i in range(len(points) - 1)]
    return union(*fs)


def rbox(c, half, rad, R=None):
    """Rounded box: half extents, corner radius."""
    c = np.asarray(c, float)
    half = np.asarray(half, float) - rad

    def f(P):
        Q = P - c
        if R is not None:
            Q = Q @ R
        q = np.abs(Q) - half
        return np.linalg.norm(np.maximum(q, 0.0), axis=1) + np.minimum(q.max(axis=1), 0.0) - rad
    return f


def torus(c, R_major, r_minor, R=None):
    """Torus in the local XY plane (axis local Z)."""
    c = np.asarray(c, float)

    def f(P):
        Q = P - c
        if R is not None:
            Q = Q @ R
        q = np.sqrt(Q[:, 0] ** 2 + Q[:, 1] ** 2) - R_major
        return np.sqrt(q * q + Q[:, 2] ** 2) - r_minor
    return f


def plane(n, d):
    """Half space n.p < d is inside."""
    n = np.asarray(n, float)
    n = n / np.linalg.norm(n)
    return lambda P: P @ n - d


# ============================================================ operators
def smin(a, b, k):
    if k <= 0:
        return np.minimum(a, b)
    h = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - h * h * k * 0.25


def smax(a, b, k):
    return -smin(-a, -b, k)


def union(*fs, k=0.0):
    def f(P):
        d = fs[0](P)
        for g in fs[1:]:
            d = smin(d, g(P), k)
        return d
    return f


def sunion(k, *fs):
    return union(*fs, k=k)


def subtract(a, b, k=0.0):
    return lambda P: smax(a(P), -b(P), k)


def intersect(a, b, k=0.0):
    return lambda P: smax(a(P), b(P), k)


def offset(f, d):
    return lambda P: f(P) - d


def shell(f, t):
    """A hollow skin of thickness t around the surface of f (outside of it)."""
    return lambda P: np.abs(f(P) - t * 0.5) - t * 0.5


def displace(f, g):
    """f minus a displacement g(P) (positive g pushes the surface out)."""
    return lambda P: f(P) - g(P)


def rot(axis, deg):
    """3x3 rotation matrix (columns are the rotated basis)."""
    a = np.asarray(axis, float)
    a = a / np.linalg.norm(a)
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    x, y, z = a
    return np.array([
        [c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s],
        [y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s],
        [z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)],
    ])


def mirror_x(f):
    """Evaluate f on |x| (a left-side shape mirrored to both sides)."""
    def g(P):
        Q = P.copy()
        Q[:, 0] = np.abs(Q[:, 0])
        return f(Q)
    return g


# ============================================================ noise
def _hash(ix, iy, iz, seed):
    h = (ix * 374761393 + iy * 668265263 + iz * 2147483647 + seed * 144665) & 0x7FFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
    return (h & 0xFFFF).astype(np.float64) / 65535.0


def vnoise(P, scale, seed=1):
    """Smooth value noise in [0, 1]."""
    Q = P * scale
    i = np.floor(Q).astype(np.int64)
    f = Q - i
    f = f * f * (3 - 2 * f)
    out = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                out = out + w * _hash(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz, seed)
    return out


def fbm(P, scale, seed=1, octaves=3):
    a, s, tot, amp = 0.0, scale, 0.0, 0.5
    for o in range(octaves):
        a = a + amp * vnoise(P, s, seed + o * 17)
        tot += amp
        s *= 2.03
        amp *= 0.5
    return a / tot


# ============================================================ mesher
def _grid(f, lo, hi, h, B=12, chunk=1_500_000):
    """Sample f on a grid, sparsely: blocks of B^3 samples are evaluated only when their centre is
    within reach of the surface; the rest get the centre's sign (far inside or far outside)."""
    lo = np.asarray(lo, float)
    hi = np.asarray(hi, float)
    n = np.maximum(np.ceil((hi - lo) / h).astype(int) + 1, 2)
    nb = (n + B - 1) // B
    # block centres
    bi = np.stack(np.meshgrid(np.arange(nb[0]), np.arange(nb[1]), np.arange(nb[2]), indexing='ij'), -1).reshape(-1, 3)
    cen = lo + (bi * B + (B - 1) * 0.5) * h
    dc = np.empty(len(cen))
    for s in range(0, len(cen), chunk):
        dc[s:s + chunk] = f(cen[s:s + chunk])
    reach = 1.8 * (B * 0.5 * math.sqrt(3.0) * h) + 2 * h
    near = np.abs(dc) < reach
    F = np.empty(tuple(n), dtype=np.float32)
    # far blocks: fill with a signed constant
    far_val = np.where(dc < 0, -reach, reach).astype(np.float32)
    for (i, j, k), v in zip(bi[~near], far_val[~near]):
        F[i * B:(i + 1) * B, j * B:(j + 1) * B, k * B:(k + 1) * B] = v
    # near blocks: gather their sample points in batches
    offs = np.stack(np.meshgrid(np.arange(B), np.arange(B), np.arange(B), indexing='ij'), -1).reshape(-1, 3)
    nbk = bi[near]
    per = max(1, chunk // len(offs))
    for s in range(0, len(nbk), per):
        blk = nbk[s:s + per]
        idx = (blk[:, None, :] * B + offs[None, :, :]).reshape(-1, 3)
        ok = (idx < n).all(axis=1)
        idx = idx[ok]
        F[idx[:, 0], idx[:, 1], idx[:, 2]] = f(lo + idx * h)
    return F, n


# the 12 cube edges as corner index pairs; corners are (dx, dy, dz) bits
_CORNERS = np.array([[(c >> 0) & 1, (c >> 1) & 1, (c >> 2) & 1] for c in range(8)])
_EDGES = [(a, b) for a in range(8) for b in range(a + 1, 8) if bin(a ^ b).count('1') == 1]


def surface_nets(f, lo, hi, h, project=2):
    """Mesh the zero set of f inside the box lo..hi with cell size h. Returns (verts (N,3), quads (M,4)),
    quads wound so their normals point out of the solid (Blender's counter-clockwise front faces)."""
    F, n = _grid(f, lo, hi, h)
    lo = np.asarray(lo, float)
    inside = F < 0
    # cells: any sign change among the 8 corners
    c = np.zeros((n[0] - 1, n[1] - 1, n[2] - 1), dtype=np.uint8)
    for k, (dx, dy, dz) in enumerate(_CORNERS):
        c += inside[dx:n[0] - 1 + dx, dy:n[1] - 1 + dy, dz:n[2] - 1 + dz]
    active = (c > 0) & (c < 8)
    idx = np.argwhere(active)
    if len(idx) == 0:
        return np.zeros((0, 3)), np.zeros((0, 4), int)
    cell_id = -np.ones(active.shape, dtype=np.int32)
    cell_id[active] = np.arange(len(idx), dtype=np.int32)
    # vertex = mean of the edge crossings
    acc = np.zeros((len(idx), 3))
    cnt = np.zeros(len(idx))
    for a, b in _EDGES:
        ca, cb = _CORNERS[a], _CORNERS[b]
        fa = F[idx[:, 0] + ca[0], idx[:, 1] + ca[1], idx[:, 2] + ca[2]].astype(np.float64)
        fb = F[idx[:, 0] + cb[0], idx[:, 1] + cb[1], idx[:, 2] + cb[2]].astype(np.float64)
        m = (fa < 0) != (fb < 0)
        t = np.where(m, fa / np.where(m, fa - fb, 1.0), 0.0)
        p = (idx + ca) + (cb - ca) * t[:, None]
        acc[m] += p[m]
        cnt[m] += 1
    verts = lo + (acc / cnt[:, None]) * h
    # faces: every grid edge with a sign change -> a quad of the 4 cells around it
    quads = []
    for ax in range(3):
        o1, o2 = [(1, 2), (0, 2), (0, 1)][ax]
        sl0 = [slice(None)] * 3
        sl1 = [slice(None)] * 3
        sl0[ax] = slice(0, n[ax] - 1)
        sl1[ax] = slice(1, n[ax])
        a_in = inside[tuple(sl0)]
        b_in = inside[tuple(sl1)]
        ch = a_in != b_in
        # the edge must have all 4 neighbouring cells: skip the boundary rows of o1/o2
        e = np.argwhere(ch)
        e = e[(e[:, o1] > 0) & (e[:, o1] < n[o1] - 1) & (e[:, o2] > 0) & (e[:, o2] < n[o2] - 1)]
        if len(e) == 0:
            continue
        flip = a_in[e[:, 0], e[:, 1], e[:, 2]]   # inside -> outside along +ax
        def cid(d1, d2):
            q = e.copy()
            q[:, o1] -= d1
            q[:, o2] -= d2
            return cell_id[q[:, 0], q[:, 1], q[:, 2]]
        c00, c10, c11, c01 = cid(1, 1), cid(0, 1), cid(0, 0), cid(1, 0)
        q = np.stack([c00, c10, c11, c01], axis=1)
        # orientation: (o1, o2, ax) right-handed for ax=0 (y,z,x) and ax=2 (x,y,z); ax=1 is (x,z,y): left-handed
        want = flip if ax != 1 else ~flip
        q[want] = q[want][:, ::-1]
        quads.append(q)
    quads = np.concatenate(quads) if quads else np.zeros((0, 4), int)
    quads = quads[(quads >= 0).all(axis=1)][:, ::-1]
    for _ in range(project):
        verts = project_to_surface(f, verts, h)
    return verts, quads


def gradient(f, P, e):
    g = np.zeros_like(P)
    for i in range(3):
        d = np.zeros(3)
        d[i] = e
        g[:, i] = (f(P + d) - f(P - d)) / (2 * e)
    return g


def project_to_surface(f, P, h):
    d = f(P)
    g = gradient(f, P, h * 0.25)
    gl = np.maximum(np.einsum('ij,ij->i', g, g), 1e-12)
    step = (d / gl)[:, None] * g
    # never move a vertex more than half a cell (keeps thin features from collapsing)
    sl = np.linalg.norm(step, axis=1)
    k = np.minimum(1.0, (0.5 * h) / np.maximum(sl, 1e-12))
    return P - step * k[:, None]
