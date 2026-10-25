#!/usr/bin/env python3
"""Gorgeous 512^3 sunny-valley diorama, prefab-first.

The parent document holds ONLY shaped terrain + water. Every added element is
a linked prefab instance from a source saved in Prefabs/ next to the parent:
oaks, pines, log cabins (with stone foundations), an arched timber bridge
(with stone abutments), a jetty, boulders, flower and reed patches, a fire
pit, fences, clouds and a blocky sun.

Levelled ground under cabins/bridge ends/jetty is terrain shaping (local
heightfield work); all visible structures live in prefab sources. Prefab
sources never contain cells below y=0, so anchors sit foundations on top of
the prepared terrain instead of burying them.

Usage: launch the editor with an MCP port, then
    VOXDOT_MCP_PORT=7861 python3 tools/build_valley_512.py
"""
import json
import math
import os
import random
import shutil
import time
import urllib.request

PORT = int(os.environ.get("VOXDOT_MCP_PORT", "7850"))
OUTPUT = os.environ.get("VOXDOT_VALLEY_OUTPUT",
                         os.path.expanduser("~/Documents/Voxdot/sunny_valley_512.tres"))
OUTPUT_PNG = os.path.splitext(OUTPUT)[0] + ".png"
PREFAB_DIR = os.path.join(os.path.dirname(OUTPUT), "Prefabs")
B = 512

_rpc_id = 0


def rpc(method, params=None):
    global _rpc_id
    _rpc_id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _rpc_id,
                       "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as response:
        return json.load(response)


def call(name, args=None):
    r = rpc("tools/call", {"name": name, "arguments": args or {}})
    if "error" in r:
        raise RuntimeError(f"{name}: {r['error']}")
    res = r.get("result", {})
    if isinstance(res, dict) and res.get("is_error"):
        txt = res["content"][0]["text"] if res.get("content") else str(res)
        raise RuntimeError(f"{name}: {txt}")
    txt = res["content"][0]["text"] if isinstance(res, dict) and res.get("content") else ""
    try:
        return json.loads(txt)
    except Exception:
        return txt


# ---------------------------------------------------------------- stage ---
_stage = {}
_BOUNDS = [B, B, B]
_ORIGIN = (0, 0, 0)  # design-space offset added to x/z on emit
_YSHIFT = 0          # design-space offset added to y on emit


def emit(x, y, z, color, mat="default"):
    ox, _, oz = _ORIGIN
    y = int(y + _YSHIFT)
    if y < 0:
        return  # intentional below-grade cells never enter a source
    p = (int(x + ox), y, int(z + oz))
    if not (0 <= p[0] < _BOUNDS[0] and 0 <= p[1] < _BOUNDS[1] and 0 <= p[2] < _BOUNDS[2]):
        raise ValueError(f"voxel outside bounds {_BOUNDS}: {p}")
    _stage[p] = (color, mat)


def box(x0, y0, z0, x1, y1, z1, color, mat="default"):
    for x in range(min(x0, x1), max(x0, x1) + 1):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            for z in range(min(z0, z1), max(z0, z1) + 1):
                emit(x, y, z, color, mat)


def flush(label):
    global _stage
    if not _stage:
        return
    groups = {}
    for (x, y, z), (color, mat) in _stage.items():
        groups.setdefault((mat, x // 64, z // 64), []).append(f"{x},{y},{z};{color}")
    total = 0
    for key in sorted(groups):
        mat, _, _ = key
        for start in range(0, len(groups[key]), 14000):
            batch = groups[key][start:start + 14000]
            result = call("place_voxels", {"data": batch, "material": mat})
            total = result["count"]
    print(f"{label}: staged cells placed -> {total:,} total", flush=True)
    _stage = {}


def blob(cx, cy, cz, rx, ry, rz, colors, rng, mat="leaves"):
    """Surface-only ellipsoid shell with a mottled palette."""
    cells = set()
    for dx in range(-rx, rx + 1):
        for dy in range(-ry, ry + 1):
            for dz in range(-rz, rz + 1):
                v = (dx / rx) ** 2 + (dy / ry) ** 2 + (dz / rz) ** 2
                if v <= 1.0 + 0.06 * math.sin((cx + dx) * 0.7 + (cz + dz) * 0.5):
                    cells.add((cx + dx, cy + dy, cz + dz))
    for p in cells:
        if all((p[0] + ox, p[1] + oy, p[2] + oz) in cells
               for ox, oy, oz in ((1, 0, 0), (-1, 0, 0), (0, 1, 0),
                                 (0, -1, 0), (0, 0, 1), (0, 0, -1))):
            continue
        emit(*p, rng.choice(colors), mat)


# --------------------------------------------------------------- palette ---
GRASS_TOP = ["5da23c", "55a047", "6cb04a", "4f9a3e"]
MEADOW = ["6cb04a", "7cc255", "5da23c"]
DIRT = "7a5230"
DIRT_D = "5e3f26"
SAND = "e6d29b"
SAND_WET = "cdb87f"
BED = "c2ab7a"
WATER = "3f9fe0"
TRUNK = "6b4423"
BARK_D = "4e3018"
WOOD = "7a4f28"
WOOD_L = "96703d"
LEAF = ["2f7a2c", "3c8a34", "4c9a3f", "5fae4a"]
PINE = ["256b28", "2e7a30", "379043", "43a047"]
ROOF = "a03a2a"
ROOF_D = "7c2a20"
WALL = "d9c9a3"
STONE = ["8a8f98", "7c818a", "9aa0a8"]
STONE_D = "5f636b"
GLASS = "9fd8e8"
FLOWERS = ["e03a3a", "ffcf40", "ffffff", "e88ab8", "ff8c42"]
REED = "4a7a3a"
CATTAIL = "6b4423"
CLOUD = "ffffff"
CLOUD_SH = "dfe8f2"
SUN = "ffd93b"
SUN_CORE = "fff3b0"
BIRD = "3a3f4a"
EMBER = ["ff7a2a", "ffcf40", "e03a3a"]
MOSS = "6aa04a"

_rng = random.Random(512)

# ---------------------------------------------------------------- terrain --
# Local writes are terrain heightfield + water only. RESERVES are levelled /
# carved patches (still heightfield work); every visible structure on them is
# a prefab whose foundation sits on top (sources hold no below-grade cells).
CX = B // 2
RESERVES = []  # (x0, x1, z0, z1, height)


def river_center(z):
    return CX + int(56 * math.sin(z * 2 * math.pi / B)
                    + 24 * math.sin(3 * z * 2 * math.pi / B + 1.3))


def natural_h(x, z):
    d = abs(x - river_center(z))
    if d <= 16:
        return 14
    if d <= 22:
        return 14 + (d - 16)
    if d <= 34:
        return 20
    t = d - 34
    noise = (4 * math.sin(x * 0.045 + 1.7) * math.sin(z * 0.05 + 0.6)
             + 2 * math.sin(x * 0.11) * math.sin(z * 0.09 + 2.0))
    edge = max(0, (d - 180) * 0.25)
    return int(20 + min(t * 0.35, 45) + noise + edge)


Hh = []
WATER_HOLES = set()


def reserve_at(x, z):
    for x0, x1, z0, z1, h in RESERVES:
        if x0 <= x <= x1 and z0 <= z <= z1:
            return h
    return None


def surface_h(x, z):
    r = reserve_at(x, z)
    return r if r is not None else Hh[x][z]


def compute_heights():
    global Hh
    Hh = [[natural_h(x, z) for z in range(B)] for x in range(B)]


def emit_terrain_band(z0, z1):
    for z in range(z0, z1):
        rc = river_center(z)
        for x in range(B):
            r = reserve_at(x, z)
            h = r if r is not None else Hh[x][z]
            d = abs(x - rc)
            if r is not None and h <= 15:
                top, mat = BED, "dirt"  # dug inlet bed, water sheet covers it
            elif d <= 16:
                top, mat = BED, "dirt"
            elif d <= 34:
                top, mat = (SAND, "default") if _rng.random() < 0.9 else (SAND_WET, "dirt")
            else:
                top = MEADOW[0] if _rng.random() < 0.25 else _rng.choice(GRASS_TOP)
                mat = "grass"
            # Rocky outcrops on high steep ground.
            steep = (x > 0 and h - surface_h(x - 1, z) > 6) \
                or (x < B - 1 and h - surface_h(x + 1, z) > 6)
            if h > 60 and steep and d > 34 and _rng.random() < 0.6:
                top, mat = _rng.choice(STONE), "stone"
            emit(x, h, z, top, mat)
            # Slope skin below the top: never fill above the pad top of a
            # reserved neighbour, or prefab foundations placed on the pad
            # would collide with the fill. The upper fringe keeps the top
            # color so terraces read as grassy banks, not dirt scars.
            lo = h
            if x > 0 and surface_h(x - 1, z) < h:
                lo = min(lo, surface_h(x - 1, z))
            if x < B - 1 and surface_h(x + 1, z) < h:
                lo = min(lo, surface_h(x + 1, z))
            if z > 0 and surface_h(x, z - 1) < h:
                lo = min(lo, surface_h(x, z - 1))
            if z < B - 1 and surface_h(x, z + 1) < h:
                lo = min(lo, surface_h(x, z + 1))
            if d <= 22:
                side_col, side_mat = BED, "dirt"
            else:
                side_col = DIRT if _rng.random() < 0.8 else DIRT_D
                side_mat = "dirt"
            for y in range(lo + 1, h):
                if y >= h - 2:
                    emit(x, y, z, top, mat)
                else:
                    emit(x, y, z, side_col, side_mat)


def emit_water(extra_rects=()):
    for z in range(B):
        rc = river_center(z)
        for x in range(rc - 20, rc + 21):
            if (x, z) in WATER_HOLES:
                continue
            if abs(x - rc) <= 16:
                emit(x, 16, z, WATER, "water")
                emit(x, 17, z, WATER, "water")
    for x0, x1, z0, z1 in extra_rects:
        for x in range(x0, x1 + 1):
            for z in range(z0, z1 + 1):
                if (x, z) in WATER_HOLES:
                    continue
                if surface_h(x, z) <= 15:
                    emit(x, 16, z, WATER, "water")
                    emit(x, 17, z, WATER, "water")


# ----------------------------------------------------------------- assets --
# Centered assets are shifted with _ORIGIN so their base centre lands on local
# (C, 0, C); the catalogue default pivot (bottom-center) then makes anchor ==
# world position of the base centre. Corner-based assets (cabin, bridge,
# jetty, fence) use pivot (0, 0, 0) so anchor == design-origin target.


def build_oak():
    for dx in (-1, 0):
        for dz in (-1, 0):
            for y in range(0, 14):
                c = TRUNK if (y + dx + dz) % 3 else BARK_D
                emit(11 + dx, y, 12 + dz, c, "wood")
    for dx, dz in ((-3, 0), (3, 1), (0, -3), (1, 3)):
        for y in range(0, 2):
            emit(11 + dx, y, 12 + dz, BARK_D, "wood")
    tops = [(12, 21, 12, 10, 6, 10), (3, 18, 8, 6, 4, 6), (21, 18, 9, 6, 4, 6),
            (7, 19, 20, 6, 4, 6), (19, 19, 20, 6, 4, 6), (12, 25, 12, 6, 4, 6)]
    for cx, cy, cz, rx, ry, rz in tops:
        blob(cx, cy, cz, rx, ry, rz, LEAF, _rng)
    for cx, cy, cz in ((3, 14, 8), (21, 14, 9), (7, 14, 20)):
        steps = max(abs(cx - 12), abs(cy - 12), abs(cz - 12)) * 2 + 1
        for i in range(steps + 1):
            t = i / steps
            emit(round(12 + (cx - 12) * t), round(12 + (cy - 12) * t),
                 round(12 + (cz - 12) * t), TRUNK, "wood")


def build_pine():
    for dx in (-1, 0):
        for dz in (-1, 0):
            for y in range(0, 18):
                emit(8 + dx, y, 9 + dz, TRUNK if (y % 2 == 0) else BARK_D, "wood")
    layers = [(10, 8), (13, 7), (16, 6), (19, 5), (21, 4), (23, 3), (25, 2)]
    for y, r in layers:
        for dx in range(-r, r + 1):
            for dz in range(-r, r + 1):
                if dx * dx + dz * dz <= r * r + 0.5:
                    edge = abs(dx * dx + dz * dz - r * r) < r
                    c = _rng.choice(PINE[1:] if edge else PINE[:3])
                    emit(8 + dx, y, 9 + dz, c, "leaves")
        emit(8, y + 1, 9, _rng.choice(PINE), "leaves")
    for y in range(26, 30):
        emit(8, y, 9, TRUNK, "wood")


def build_cabin():
    global _YSHIFT
    # Stone foundation slab (design y 0..2) plugs nothing: it sits ON the
    # levelled terrain pad, anchor_y == pad_top + 1.
    for x in range(-2, 25):
        for z in range(-1, 23):
            for y in range(0, 3):
                edge = x in (-2, 24) or z in (-1, 22) or y == 0
                emit(x, y, z, _rng.choice(STONE) if edge else STONE_D, "stone")
    _YSHIFT = 2
    try:
        # Design footprint x 0..22, z 0..20; house z 4..20, porch z 0..3.
        for x in range(0, 23):
            for z in range(4, 21):
                emit(x, 1, z, WOOD if (x + z) % 4 else BARK_D, "wood")
        for y in range(2, 7):
            for x in range(0, 23):
                for z in (4, 20):
                    if z == 4 and 10 <= x <= 11 and y <= 4:
                        continue  # door
                    if y in (3, 4) and x in (4, 5, 16, 17):
                        emit(x, y, z, GLASS, "glass")
                    else:
                        emit(x, y, z, WALL if (x + y) % 5 else "c9b995", "wood")
            for z in range(4, 21):
                for x in (0, 22):
                    if y in (3, 4) and z in (10, 11, 12):
                        emit(x, y, z, GLASS, "glass")
                    else:
                        emit(x, y, z, WALL if (z + y) % 5 else "c9b995", "wood")
        for x in (0, 22):
            for z in range(4, 21):
                for y in range(7, 7 + (8 - abs(z - 12))):
                    emit(x, y, z, WALL, "wood")
        for x in range(-1, 24):
            for z in range(3, 22):
                rise = 8 - abs(z - 12)
                if rise < 0:
                    continue
                y = 7 + rise
                c = ROOF if (x + z) % 4 else ROOF_D
                emit(x, y, z, c, "wood")
                if rise > 0:
                    emit(x, y - 1, z, ROOF_D, "wood")
        for y in range(7, 14):
            emit(17, y, 15, _rng.choice(STONE), "stone")
            emit(18, y, 15, _rng.choice(STONE), "stone")
            emit(17, y, 16, _rng.choice(STONE), "stone")
            emit(18, y, 16, _rng.choice(STONE), "stone")
        emit(17, 14, 15, STONE_D, "stone")
        # Porch.
        for x in range(8, 15):
            for z in range(0, 4):
                emit(x, 1, z, WOOD_L, "wood")
        for x in (8, 14):
            for y in range(2, 7):
                emit(x, y, 0, TRUNK, "wood")
        for x in range(7, 16):
            for z in range(-1, 4):
                emit(x, 7, z, ROOF_D, "wood")
        # Window flower boxes on the front wall.
        for x in (4, 16):
            for dx in range(3):
                emit(x + dx, 2, 3, BARK_D, "wood")
                if _rng.random() < 0.8:
                    emit(x + dx, 3, 3, _rng.choice(FLOWERS), "default")
        # Firewood stack against the east wall.
        for y in (0, 1):
            for z in range(8, 13):
                emit(23, y + 3, z, TRUNK if (y + z) % 2 else WOOD_L, "wood")
    finally:
        _YSHIFT = 0
    return (11.5, 8.0, 12.5)  # interior lamp position (design space)

def build_bridge():
    n = 72

    def deck(x):
        return 2 + round(3 * math.sin(math.pi * x / n))

    for x in range(0, n + 1):
        d = deck(x)
        for z in range(0, 9):
            c = WOOD if (x + z) % 5 else WOOD_L
            emit(x, d, z, c, "wood")
            if z in (0, 8):
                emit(x, d - 1, z, BARK_D, "wood")
        for z in (0, 8):
            for y in range(d + 1, d + 4):
                if x % 6 == 0:
                    emit(x, y, z, TRUNK, "wood")
            emit(x, d + 4, z, WOOD, "wood")
    # Stone abutments at both ends: sit on the levelled pads, deck bears on top.
    for x in list(range(0, 7)) + list(range(n - 6, n + 1)):
        d = deck(x)
        for z in range(0, 9):
            for y in range(0, d + 1):
                edge = z in (0, 8) or x in (0, n)
                emit(x, y, z, _rng.choice(STONE) if edge else STONE_D, "stone")
    # Truss struts hang off the deck (attached mid-air over the channel).
    for x in range(10, n - 9, 4):
        d = deck(x)
        for z in (1, 7):
            for i in range(5):
                emit(max(x - 2 + i, 7), d - 1 - i // 2, z, BARK_D, "wood")
    lamps = []
    for x, z in ((3, 0), (3, 8), (n - 3, 0), (n - 3, 8)):
        d = deck(x)
        for y in range(d + 1, d + 5):
            emit(x, y, z, STONE_D if y % 2 else _rng.choice(STONE), "stone")
        emit(x, d + 5, z, "ffd27a", "glass")
        lamps.append((x, d + 5.5, z))
    return lamps


def build_boulder():
    blob(7, 6, 7, 7, 5, 6, STONE, _rng, mat="stone")
    blob(1, 3, 3, 3, 2, 3, STONE, _rng, mat="stone")
    blob(13, 3, 11, 3, 2, 2, STONE, _rng, mat="stone")
    for _ in range(40):
        dx, dz = _rng.randint(-6, 6), _rng.randint(-5, 5)
        if dx * dx + dz * dz <= 30:
            emit(7 + dx, 11 - abs(dx) // 2, 7 + dz, MOSS, "grass")


def build_flowers():
    for cx, cz in ((3, 3), (9, 8), (5, 10)):
        for dx, dz in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
            emit(cx + dx, 1, cz + dz, _rng.choice(LEAF), "leaves")
            if _rng.random() < 0.5:
                emit(cx + dx, 2, cz + dz, _rng.choice(LEAF), "leaves")
    for _ in range(30):
        a = _rng.random() * 2 * math.pi
        r = _rng.randint(1, 5)
        x, z = 6 + int(r * math.cos(a)), 6 + int(r * math.sin(a))
        h = 2 if _rng.random() < 0.7 else 3
        emit(x, 1, z, REED, "leaves")
        emit(x, h, z, _rng.choice(FLOWERS), "default")
        if _rng.random() < 0.3:
            emit(x + 1, 1, z, REED, "leaves")


def build_reeds():
    for _ in range(11):
        a = _rng.random() * 2 * math.pi
        r = _rng.randint(0, 5)
        x, z = 6 + int(r * math.cos(a)), 6 + int(r * math.sin(a))
        h = _rng.randint(4, 6)
        for y in range(0, h):
            emit(x, y, z, REED, "leaves")
        emit(x, h, z, CATTAIL, "wood")
        emit(x, h + 1, z, CATTAIL, "wood")
        if _rng.random() < 0.6:
            emit(x + _rng.choice((-1, 1)), 1, z, REED, "leaves")


def build_cloud():
    for cx, cy, cz, rx, ry, rz in ((24, 6, 12, 20, 5, 10), (12, 4, 10, 10, 4, 7),
                                   (36, 4, 14, 10, 4, 7), (24, 9, 12, 12, 3, 7)):
        blob(cx, cy, cz, rx, ry, rz, [CLOUD], _rng, mat="default")
    for x in range(8, 41, 3):
        emit(x, 2, 12 + (x % 2), CLOUD_SH, "default")
    for bx, bz in ((8, 2), (40, 22), (30, 0)):
        emit(bx, 1, bz, BIRD, "default")
        emit(bx + 1, 2, bz, BIRD, "default")
        emit(bx + 2, 1, bz, BIRD, "default")


def build_sun():
    for x in range(0, 16):
        for y in range(0, 16):
            for z in range(0, 5):
                edge = x in (0, 15) or y in (0, 15) or z in (0, 4)
                if edge and (x + y + z) % 3 == 0:
                    continue
                core = abs(x - 7.5) + abs(y - 7.5) < 7
                emit(x, y, z, SUN_CORE if core else SUN, "default")


def build_jetty():
    for x in range(0, 29):
        for z in range(0, 6):
            c = WOOD if x % 4 else WOOD_L
            emit(x, 8, z, c, "wood")
    for x in (4, 12, 20):
        for z in (1, 4):
            for y in range(0, 8):
                emit(x, y, z, BARK_D, "wood")
    for x in (24, 26, 28):
        for z in (1, 4):
            for y in range(6, 8):
                emit(x, y, z, BARK_D, "wood")
    for z in (0, 5):
        for x in range(0, 29):
            if x % 3 == 0:
                emit(x, 9, z, TRUNK, "wood")
        for x in range(0, 29):
            emit(x, 10, z, WOOD, "wood")


def build_fence():
    for x in range(0, 27):
        for z in (0, 1):
            if x % 4 == 0:
                emit(x, 0, z, TRUNK, "wood")
                emit(x, 1, z, TRUNK, "wood")
                emit(x, 2, z, WOOD_L, "wood")
            emit(x, 1, z, WOOD, "wood")
    for x in range(0, 27):
        emit(x, 2, 0, WOOD, "wood")


def build_firepit():
    for a in range(24):
        x = 6 + round(4 * math.cos(a * 2 * math.pi / 24))
        z = 6 + round(4 * math.sin(a * 2 * math.pi / 24))
        emit(x, 0, z, _rng.choice(STONE), "stone")
        if a % 2 == 0:
            emit(x, 1, z, STONE_D, "stone")
    for dx, dz in ((-2, -1), (2, 1), (-1, 2), (1, -2)):
        emit(6 + dx, 1, 6 + dz, BARK_D, "wood")
        emit(6 + dx, 2, 6 + dz, TRUNK, "wood")
    emit(6, 1, 6, EMBER[0], "default")
    emit(6, 2, 6, EMBER[1], "default")
    emit(7, 1, 6, EMBER[2], "default")
    emit(5, 1, 7, EMBER[0], "default")
    for sx, sz in ((0, -6), (-6, 1), (6, 2)):
        emit(6 + sx, 0, 6 + sz, TRUNK, "wood")
        emit(6 + sx, 1, 6 + sz, WOOD, "wood")


# ------------------------------------------------------------ prefab IO ---
def new_source(bounds):
    global _BOUNDS, _ORIGIN, _YSHIFT
    call("new_model")
    call("set_bounds", {"bounds": [bounds] * 3})
    call("set_mirror", {"x": False, "z": False})
    call("set_height_lock", {"on": False})
    _BOUNDS = [bounds] * 3
    _ORIGIN = (0, 0, 0)
    _YSHIFT = 0


def save_source(name):
    global _BOUNDS, _ORIGIN, _YSHIFT
    os.makedirs(PREFAB_DIR, exist_ok=True)
    path = os.path.join(PREFAB_DIR, f"{name}.tres")
    saved = call("save", {"path": path})
    print(f"Saved prefab source {name}:", saved, flush=True)
    _BOUNDS = [B, B, B]
    _ORIGIN = (0, 0, 0)
    _YSHIFT = 0
    return path


def fetch_asset(path):
    call("prefab_refresh_assets")
    asset = call("prefab_get_asset", {"path": path})
    if not asset.get("valid"):
        raise RuntimeError(f"prefab source invalid: {asset}")
    print(f"Asset {asset['asset_id']}: {asset['cells']} cells, pivot {asset['pivot']}",
          flush=True)
    return asset


def set_origin_center(c):
    global _ORIGIN
    _ORIGIN = (c[0], 0, c[1])


ASSETS = {}
DES_OFF = {}  # name -> (ox, oz) design margin subtracted at placement


def make_centered(name, bound, center, builder):
    """Build a source whose design base-centre maps to local (C,0,C)."""
    new_source(bound)
    c = bound // 2
    set_origin_center((c - center[0], c - center[1]))
    builder()
    flush(f"source {name}")
    ASSETS[name] = fetch_asset(save_source(name))


def make_pivot_zero(name, bound, builder, margin=0):
    """Build a corner-based source. `margin` shifts design +x/+z so small
    overhangs (porch roofs, eaves) stay inside the source; placement
    subtracts it back so the anchor still means the design origin."""
    new_source(bound)
    global _ORIGIN
    _ORIGIN = (margin, 0, margin)
    extra = builder()
    flush(f"source {name}")
    path = save_source(name)
    asset = fetch_asset(path)
    asset = call("prefab_set_pivot", {"asset_id": asset["asset_id"], "pivot": [0, 0, 0]})
    ASSETS[name] = asset
    DES_OFF[name] = (margin, margin)
    return extra


def build_sources():
    make_centered("valley_oak", 64, (12, 12), lambda: build_oak())
    make_centered("valley_pine", 64, (8, 9), lambda: build_pine())
    lamp = make_pivot_zero("valley_cabin", 64, lambda: build_cabin(), margin=4)
    print("cabin interior light:", call("add_light", {
        "position": [lamp[0] + 4, lamp[1], lamp[2] + 4], "color": "ffc27a",
        "energy": 3.0, "range": 45.0, "shadows": False}), flush=True)
    cabin_path = os.path.join(PREFAB_DIR, "valley_cabin.tres")
    print("re-saved cabin:", call("save", {"path": cabin_path}), flush=True)
    ASSETS["valley_cabin"] = fetch_asset(cabin_path)
    bridge_lamps = make_pivot_zero("valley_bridge", 128, lambda: build_bridge(), margin=4)
    for pos in bridge_lamps:
        print("bridge lamp:", call("add_light", {
            "position": [pos[0] + 4, pos[1], pos[2] + 4], "color": "ffd27a",
            "energy": 2.0, "range": 30.0, "shadows": False}), flush=True)
    bridge_path = os.path.join(PREFAB_DIR, "valley_bridge.tres")
    print("re-saved bridge:", call("save", {"path": bridge_path}), flush=True)
    ASSETS["valley_bridge"] = fetch_asset(bridge_path)
    make_centered("valley_boulder", 32, (7, 7), lambda: build_boulder())
    make_centered("valley_flowers", 32, (6, 6), lambda: build_flowers())
    make_centered("valley_reeds", 32, (6, 6), lambda: build_reeds())
    make_centered("valley_cloud", 64, (24, 12), lambda: build_cloud())
    make_centered("valley_sun", 64, (8, 2), lambda: build_sun())
    make_pivot_zero("valley_jetty", 32, lambda: build_jetty())
    make_pivot_zero("valley_fence", 32, lambda: build_fence())
    make_centered("valley_firepit", 32, (6, 6), lambda: build_firepit())


# --------------------------------------------------------------- placement --
PLACED = []  # (x, z, radius)


def clear_of(x, z, r, margin=6):
    if not (r + 2 <= x < B - r - 2 and r + 2 <= z < B - r - 2):
        return False
    for x0, x1, z0, z1, _h in RESERVES:
        if x0 - margin - r <= x <= x1 + margin + r \
                and z0 - margin - r <= z <= z1 + margin + r:
            return False
    for px, pz, pr in PLACED:
        if abs(x - px) < r + pr + margin and abs(z - pz) < r + pr + margin:
            return False
    return True


def flat_enough(x, z, r, tol):
    h0 = Hh[x][z]
    for dx in range(-r, r + 1, 3):
        for dz in range(-r, r + 1, 3):
            if abs(Hh[x + dx][z + dz] - h0) > tol:
                return False
    return True


def scatter(count, r, dmin, dmax, tol, margin=6, pad=True):
    """Pick spots, terrace each into a level RESERVE, and record placements.
    Pads are computed BEFORE terrain emission, so instances sit on flat
    ground; `pad=False` keeps the old strict natural-flatness check. Each
    pad hugs its footprint (radius + 1) so terraces stay small."""
    out = []
    tries = 0
    while len(out) < count and tries < 12000:
        tries += 1
        z = _rng.randint(20, B - 20)
        side = _rng.choice((-1, 1))
        x = river_center(z) + side * _rng.randint(dmin, dmax)
        rect = (x - r - 1, x + r + 1, z - r - 1, z + r + 1)
        if not (2 <= rect[0] and rect[1] < B - 2 and 2 <= rect[2] and rect[3] < B - 2):
            continue
        if not clear_of(x, z, r, margin):
            continue
        if pad:
            if pad_spread(*rect) > tol:
                continue
            h = Hh[x][z]
            RESERVES.append((rect[0], rect[1], rect[2], rect[3], h))
        elif not flat_enough(x, z, r, tol):
            continue
        out.append((x, z))
        PLACED.append((x, z, r))
    if len(out) < count:
        raise RuntimeError(f"scatter failed: {len(out)}/{count} (r={r})")
    return out


def place(name, anchor, yaw=0):
    ox, oz = DES_OFF.get(name, (0, 0))
    if (ox, oz) != (0, 0) and yaw != 0:
        raise RuntimeError(f"margined source {name} does not support yaw={yaw}")
    result = call("prefab_place", {"asset_id": ASSETS[name]["asset_id"],
                                   "anchor": [int(anchor[0] - ox), int(anchor[1]), int(anchor[2] - oz)],
                                   "yaw": yaw})
    if result.get("status") != "ok":
        raise RuntimeError(f"place {name} at {anchor} failed: {result}")
    return result


def pad_peak(x0, x1, z0, z1):
    return max(Hh[x][z] for x in range(x0, x1 + 1) for z in range(z0, z1 + 1))


def pad_spread(x0, x1, z0, z1):
    h0 = Hh[(x0 + x1) // 2][(z0 + z1) // 2]
    return max(abs(Hh[x][z] - h0)
               for x in range(x0, x1 + 1, 2) for z in range(z0, z1 + 1, 2))


def pick_homestead(side, z_lo, z_hi):
    for _ in range(8000):
        z = _rng.randint(z_lo, z_hi)
        x = river_center(z) + side * _rng.randint(60, 110)
        ax, az = x - 11, z - 12
        cabin_rect = (ax - 3, ax + 25, az - 2, az + 23)
        if not (2 <= cabin_rect[0] and cabin_rect[1] < B - 2
                and 2 <= cabin_rect[2] and cabin_rect[3] < B - 2):
            continue
        if not clear_of(x, z, 30, margin=10):
            continue
        if pad_spread(*cabin_rect) > 5:
            continue
        return x, z
    raise RuntimeError("homestead search failed")


def place_all():
    global _BOUNDS, _ORIGIN, _YSHIFT
    _BOUNDS = [B, B, B]
    _ORIGIN = (0, 0, 0)
    _YSHIFT = 0
    compute_heights()

    # Fixed crossings first so homesteads keep clear of them.
    bz = 255
    rc_b = river_center(bz)
    # Bridge pads: levelled terrain under the stone abutments AND the low
    # approach spans (design x0..24 / x48..72 land at world ax..ax+24 and
    # ax+48..ax+72). The arch rises over the channel, so only the ends are
    # terraced; the middle spans the water gap. Each pad keeps its own
    # natural peak grade so the abutments stand proud without tall causeway
    # walls on the downhill side.
    ax_b = rc_b - 36 - 4
    end_w = (ax_b - 2, ax_b + 24, bz - 8, bz + 8)
    end_e = (ax_b + 48, ax_b + 76, bz - 8, bz + 8)
    hbw = max(Hh[x][z] for x in range(end_w[0], end_w[1] + 1) for z in range(end_w[2], end_w[3] + 1))
    hbe = max(Hh[x][z] for x in range(end_e[0], end_e[1] + 1) for z in range(end_e[2], end_e[3] + 1))
    RESERVES.append((end_w[0], end_w[1], end_w[2], end_w[3], hbw))
    RESERVES.append((end_e[0], end_e[1], end_e[2], end_e[3], hbe))
    # Jetty inlet: carve the beach to bed level so posts stand in water.
    jz = 377
    jx0 = river_center(jz) - 34
    jetty_rect = (jx0 - 2, jx0 + 31, jz - 2, jz + 8)
    RESERVES.append((jetty_rect[0], jetty_rect[1], jetty_rect[2], jetty_rect[3], 14))
    for lx, lz in ((4, 1), (4, 4), (12, 1), (12, 4), (20, 1), (20, 4),
                   (24, 1), (24, 4), (26, 1), (26, 4), (28, 1), (28, 4)):
        WATER_HOLES.add((jx0 + lx, jz + lz))
    PLACED.append((jx0 + 14, jz + 2, 20))
    # Homesteads: a cabin pad (peak grade under the slab) plus a yard pad for
    # the firepit and fences. Cabin design origin (slab corner) places the
    # slab at ax-2..ax+24 / az-1..az+22 for anchor (ax, az). The firepit
    # anchor (ax+34, az+8) centres a 13-wide footprint, and the 27-long fence
    # runs start at ax+28: the yard pad spans ax+27..ax+55 / az-1..az+16.
    sites = []
    for side, z_lo, z_hi in ((1, 190, 300), (-1, 150, 260)):
        cx, cz = pick_homestead(side, z_lo, z_hi)
        ax, az = cx - 11, cz - 12
        # Cabin pad hugs the slab (world ax-2..ax+24 / az-1..az+22) with a
        # 1-cell skirt; the slab face covers the step.
        cabin_rect = (ax - 3, ax + 25, az - 2, az + 23)
        hc = pad_peak(*cabin_rect)
        RESERVES.append((cabin_rect[0], cabin_rect[1], cabin_rect[2], cabin_rect[3], hc))
        # Yard pad hugs the firepit (ax+28..ax+40 / az+2..az+14) and the two
        # fence runs (ax+28..ax+54 / az..az+1, az+14..az+15) with a 1 skirt.
        yard_rect = (ax + 27, ax + 55, az - 1, az + 16)
        hy = min(hc, pad_peak(*yard_rect))
        RESERVES.append((yard_rect[0], yard_rect[1], yard_rect[2], yard_rect[3], hy))
        sites.append((cx, cz, hc, hy, cabin_rect, yard_rect))

    # Homesteads sit on the reserves already planned above; scatter terraces
    # each nature spot BEFORE terrain emission so every instance sits on a
    # level pad (scatter() appends the RESERVEs).
    for cx, cz, hc, hy, cabin_rect, yard_rect in sites:
        PLACED.append((cx, cz, 22))
    oaks = scatter(6, 15, 45, 95, 14)
    pines = scatter(9, 10, 120, 190, 16)
    boulders = scatter(8, 8, 55, 170, 16)
    flowers = scatter(9, 6, 38, 90, 12)
    reeds = []
    reed_tries = 0
    while len(reeds) < 6 and reed_tries < 12000:
        reed_tries += 1
        z = _rng.randint(30, B - 30)
        if abs(z - bz) < 24 or abs(z - jz) < 20:
            continue
        side = _rng.choice((-1, 1))
        x = river_center(z) + side * _rng.randint(24, 32)
        rect = (x - 6, x + 6, z - 6, z + 6)
        if not (2 <= rect[0] and rect[1] < B - 2 and 2 <= rect[2] and rect[3] < B - 2):
            continue
        if not clear_of(x, z, 5):
            continue
        h = Hh[x][z]
        RESERVES.append((rect[0], rect[1], rect[2], rect[3], h))
        reeds.append((x, z))
        PLACED.append((x, z, 5))
    if len(reeds) < 6:
        raise RuntimeError(f"reed scatter failed: {len(reeds)}/6")

    call("new_model")
    call("set_bounds", {"bounds": [B, B, B]})
    call("set_mirror", {"x": False, "z": False})
    call("set_height_lock", {"on": False})

    print("terrain shell ...", flush=True)
    for z0 in range(0, B, 128):
        emit_terrain_band(z0, min(z0 + 128, B))
        flush(f"terrain z {z0}-{min(z0 + 128, B)}")

    print("water ...", flush=True)
    emit_water(extra_rects=[jetty_rect])
    flush("water sheet")

    n = 0
    # Bridge (pivot 0,0,0): anchor == design-origin target. The source is
    # level, so it sits at the higher pad; the lower pad's abutment gets a
    # taller stone base from the terrain step, which reads as a foundation.
    hb = max(hbw, hbe)
    place("valley_bridge", (ax_b + 4, hb + 1, bz - 4))
    n += 1
    place("valley_jetty", (jx0, 15, jz))
    n += 1
    # Homesteads: cabin slab on its pad; firepit + fences on the yard pad.
    for cx, cz, hc, hy, cabin_rect, yard_rect in sites:
        ax, az = cx - 11, cz - 12
        place("valley_cabin", (ax, hc + 1, az))
        n += 1
        # Yard firepit: local footprint x -1..13 around design (6,6) lands fully
        # east of the slab (slab ends at ax+24) on the yard pad.
        place("valley_firepit", (ax + 34, hy + 1, az + 8), yaw=0)
        n += 1
        # Fence runs along the yard pad's north and south edges.
        for fanchor in ((ax + 28, hy + 1, az), (ax + 28, hy + 1, az + 14)):
            place("valley_fence", fanchor)
            n += 1
    # Scattered nature (pads already terraced above; surface_h == pad top).
    for x, z in oaks:
        place("valley_oak", (x, surface_h(x, z) + 1, z), yaw=_rng.randint(0, 3))
        n += 1
    for x, z in pines:
        place("valley_pine", (x, surface_h(x, z) + 1, z), yaw=_rng.randint(0, 3))
        n += 1
    for x, z in boulders:
        place("valley_boulder", (x, surface_h(x, z) + 1, z), yaw=_rng.randint(0, 3))
        n += 1
    for x, z in flowers:
        place("valley_flowers", (x, surface_h(x, z) + 1, z), yaw=_rng.randint(0, 3))
        n += 1
    for x, z in reeds:
        place("valley_reeds", (x, surface_h(x, z) + 1, z), yaw=_rng.randint(0, 3))
        n += 1
    # Sky.
    for cx, cy, cz in ((120, 390, 150), (330, 408, 300), (250, 398, 420), (400, 385, 120)):
        place("valley_cloud", (cx, cy, cz), yaw=_rng.randint(0, 3))
        n += 1
    place("valley_sun", (430, 408, 90))
    n += 1
    print(f"placed {n} instances", flush=True)


# -------------------------------------------------------------------- main --
def main():
    state = call("get_state")
    if state["voxel_count"] != 0 or state.get("dirty"):
        raise RuntimeError("Refusing to replace a non-empty or unsaved document")
    print("Building 12 prefab sources ...", flush=True)
    build_sources()
    print("Building 512^3 parent (terrain + water only) ...", flush=True)
    place_all()

    call("set_sun", {"energy": 1.25, "color": "fff1d6", "yaw": 40,
                      "pitch": -48, "shadows": True})
    call("set_grid_visible", {"visible": False})
    call("set_orthographic", {"on": False})
    call("frame")
    call("set_camera", {"yaw": 38, "pitch": -24, "distance": 260})
    call("pan", {"dx": 0, "dy": -30})
    call("zoom", {"steps": 2})
    state = call("get_state")
    print(f"Final: {state['voxel_count']:,} local voxels, bounds {state['bounds']}",
          flush=True)
    print(f"Prefabs: {state['prefab_instances']} instances, "
          f"{state['prefab_cells']:,} composed cells, status {state['prefab_counts']}",
          flush=True)
    if state["bounds"] != [B, B, B]:
        raise RuntimeError(f"wrong final bounds: {state['bounds']}")
    if state["prefab_instances"] < 50:
        raise RuntimeError(f"too few instances placed: {state['prefab_instances']}")
    if int(state["prefab_counts"].get("ok", 0)) != state["prefab_instances"]:
        raise RuntimeError(f"some instances invalid: {state['prefab_counts']}")
    print("Saved:", call("save", {"path": OUTPUT}), flush=True)
    # Reload check: linked sources must resolve from the neighbouring
    # Prefabs/ folder on a fresh open, not just in the live document.
    print("Reopening:", call("open", {"path": OUTPUT}), flush=True)
    time.sleep(8)
    state = call("get_state")
    print(f"Reloaded: {state['voxel_count']:,} local voxels, bounds {state['bounds']}",
          flush=True)
    print(f"Prefabs: {state['prefab_instances']} instances, "
          f"{state['prefab_cells']:,} composed cells, status {state['prefab_counts']}",
          flush=True)
    if state["bounds"] != [B, B, B]:
        raise RuntimeError(f"wrong reloaded bounds: {state['bounds']}")
    if state["prefab_instances"] < 50 or state["prefab_cells"] == 0:
        raise RuntimeError(f"reload lost prefabs: {state}")
    if int(state["prefab_counts"].get("ok", 0)) != state["prefab_instances"]:
        raise RuntimeError(f"some reloaded instances invalid: {state['prefab_counts']}")
    shot = call("screenshot")
    shot_path = str(shot.get("path", ""))
    if shot_path and os.path.isfile(shot_path):
        shutil.copyfile(shot_path, OUTPUT_PNG)
        print("Screenshot copied to:", OUTPUT_PNG, flush=True)
    else:
        print("Screenshot:", shot, flush=True)
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
