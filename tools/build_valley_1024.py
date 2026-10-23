#!/usr/bin/env python3
"""1024^3 sunny-valley diorama in Voxdot, built purely over MCP.

Shell-only terrain (visible surface + exposed slope skin) flushed through
place_voxels batches. ~1 km of valley at 1 m per voxel."""
import json, math, os, random, urllib.request

PORT = 7850
_id = 0
def rpc(method, params=None):
    global _id; _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/", data=body,
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))

def call(name, args=None):
    r = rpc("tools/call", {"name": name, "arguments": args or {}})
    res = r["result"]
    if "is_error" in res:
        raise RuntimeError(f"{name}: {res['content'][0]['text']}")
    txt = res["content"][0]["text"]
    try: return json.loads(txt)
    except Exception: return txt

BATCH = []
def emit(x, y, z, c):
    BATCH.append(f"{x},{y},{z};{c}")

def flush():
    global BATCH
    while BATCH:
        chunk, BATCH = BATCH[:8000], BATCH[8000:]
        r = call("place_voxels", {"data": chunk})
        print(f"  flush {len(chunk)} -> total {r.get('count')}", flush=True)

# palette
DIRT="78512d"; GRASS="4f9636"; GRASS_HI="8fbf4a"; SAND="e6d29b"
WATER="3f9fe0"; WOOD="6b4423"; LEAF="2f6e2a"; LEAF_HI="4c9a3f"
FLOWER_R="e03a3a"; FLOWER_Y="ffcf40"; SUN="ffd93b"; CLOUD="ffffff"
ROOF="9e2a2b"; WALL="d9c9a3"; STONE="8a8f98"

B = 1024; CX = B // 2

def river_center(z):
    return CX + int(128*math.sin(z*2*math.pi/B) + 56*math.sin(3*z*2*math.pi/B))

def ground_h(x, z):
    d = abs(x - river_center(z))
    if d <= 40:  return 16              # river bed
    if d <= 72:  return 32              # beach
    rise = min(48 + (d-72)*0.55, 240)
    noise = 24*(0.5 + 0.5*math.sin(x*0.044)*math.sin(z*0.038))
    return int(32 + rise*0.55 + noise)

rng = random.Random(7)

call("new_model")
print("set_bounds:", call("set_bounds", {"bounds": [B, B, B]}), flush=True)

# --- terrain shell (z-major so the visible near half fills in first) ---
print("terrain shell ...", flush=True)
Hh = [[ground_h(x, z) for z in range(B)] for x in range(B)]
for z in range(B):
    for x in range(B):
        h = Hh[x][z]
        d = abs(x - river_center(z))
        top = SAND if d <= 72 else (GRASS_HI if rng.random() < 0.15 else GRASS)
        emit(x, h, z, top)
        min_n = min(Hh[x-1][z] if x > 0 else 0,
                    Hh[x+1][z] if x < B-1 else 0,
                    Hh[x][z-1] if z > 0 else 0,
                    Hh[x][z+1] if z < B-1 else 0)
        for y in range(min_n + 1, h):
            emit(x, y, z, DIRT)
    if z % 128 == 0:
        print(f"  terrain {100*z//B}%  batch={len(BATCH)}", flush=True)
    if len(BATCH) > 40000:
        flush()
flush()

# --- water: thin sheet in the channel ---
print("water ...", flush=True)
for z in range(B):
    cx = river_center(z)
    for x in range(cx-40, cx+40):
        emit(x, 20, z, WATER)
flush()

# --- bridge ---
print("bridge ...", flush=True)
bz = B//2; bcx = river_center(bz); dy = 64
for x in range(bcx-56, bcx+57):
    for z in range(bz-8, bz+9):
        emit(x, dy, z, WOOD)
for sx in (-56, 44):
    for y in range(20, dy):
        for z in range(bz-8, bz+9):
            emit(bcx+sx, y, z, WOOD)
            emit(bcx+sx+11, y, z, WOOD)
    for z in (-16, 16):
        emit(bcx+sx, dy+8, bz+z, WOOD); emit(bcx+sx+11, dy+8, bz+z, WOOD)
        for y in range(dy+1, dy+8):
            emit(bcx+sx, y, bz+z, WOOD); emit(bcx+sx+11, y, bz+z, WOOD)
flush()

# --- trees (8x bigger, same count) ---
print("trees ...", flush=True)
def tree(x, z):
    h = Hh[x][z]
    for y in range(h+1, h+33):
        emit(x, y, z, WOOD)                                  # trunk
    for dx in range(-16, 17):
        for dz in range(-16, 17):
            if dx*dx + dz*dz <= 289:
                for dy in range(h+32, h+57):
                    emit(x+dx, dy, z+dz, LEAF)
                if dx*dx + dz*dz <= 100:
                    for dy in range(h+56, h+73):
                        emit(x+dx, dy, z+dz, LEAF_HI)
placed = 0
while placed < 10:
    z = rng.randint(80, B-80); side = rng.choice([-1, 1])
    x = river_center(z) + side*rng.randint(144, 360)
    if 96 <= x < B-96:
        tree(x, z); placed += 1
flush()

# --- cabin (8x bigger) ---
print("cabin ...", flush=True)
kz = rng.randint(B//3, 2*B//3); kx = river_center(kz)+160; kh = Hh[kx][kz]
for x in range(kx, kx+64):
    for z in range(kz, kz+56):
        for y in range(kh+1, kh+33):
            if x in (kx, kx+63) or z in (kz, kz+55):
                emit(x, y, z, WALL)
for x in range(kx-8, kx+72):
    for z in range(kz-8, kz+64):
        emit(x, kh+33, z, ROOF); emit(x, kh+34, z, ROOF)
for y in range(kh+1, kh+25): emit(kx+32, y, kz, WOOD); emit(kx+24, y, kz, WOOD)
emit(kx+8, kh+24, kz, "3b3a4f"); emit(kx+16, kh+24, kz, "3b3a4f")
emit(kx+48, kh+24, kz, "3b3a4f")
for y in range(kh+35, kh+73): emit(kx+48, y, kz+40, STONE)
flush()

# --- flowers ---
print("flowers ...", flush=True)
for _ in range(180):
    z = rng.randint(48, B-48); side = rng.choice([-1, 1])
    x = river_center(z) + side*rng.randint(88, 192)
    if 32 <= x < B-32:
        emit(x, Hh[x][z]+1, z, FLOWER_R if rng.random() < 0.5 else FLOWER_Y)
flush()

# --- sun + clouds ---
print("sky ...", flush=True)
for x in range(B-192, B-115):
    for y in range(800, 880):
        for z in range(144, 176):
            emit(x, y, z, SUN)
for cx0, cy0, cz0 in [(192, 736, 320), (560, 768, 672), (768, 720, 448)]:
    for dx in range(80):
        for dy in range(24):
            for dz in range(32):
                emit(cx0+dx, cy0+dy, cz0+dz, CLOUD)
    for dx in range(16, 56):
        for dy in range(24, 40):
            for dz in range(8, 24):
                emit(cx0+dx, cy0+dy, cz0+dz, CLOUD)
flush()

call("frame"); call("set_camera", {"yaw": 35, "pitch": -30, "distance": 1200})
st = call("get_state"); print("voxels:", st["voxel_count"], "bounds:", st["bounds"], flush=True)
print("saved:", call("save", {"path": os.environ.get("VOXDOT_VALLEY_OUTPUT", os.path.expanduser("~/Documents/Voxdot/sunny_valley_1km.tres"))}), flush=True)
print("screenshot:", call("screenshot"), flush=True)
print("DONE", flush=True)
