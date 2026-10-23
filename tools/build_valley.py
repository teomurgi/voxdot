#!/usr/bin/env python3
"""Sunny-valley diorama in Voxdot, built purely over MCP.

Smart about invisible voxels: terrain is a shell (top surface plus exposed
slope skin), water is a thin sheet, structures are hollow-free but tiny.
Everything goes through a handful of place_voxels batches, so the editor
mesh only rebuilds a few times."""
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

B=128; CX=B//2

def river_center(z):
    return CX + int(16*math.sin(z*2*math.pi/B) + 7*math.sin(3*z*2*math.pi/B))

def ground_h(x,z):
    d = abs(x - river_center(z))
    if d <= 5:  return 2
    if d <= 9:  return 4
    rise = min(6 + (d-9)*0.55, 30)
    noise = 3*(0.5 + 0.5*math.sin(x*0.35)*math.sin(z*0.3))
    return int(4 + rise*0.55 + noise)

rng = random.Random(7)

call("new_model")
print("set_bounds:", call("set_bounds", {"bounds": [B, B, B]}), flush=True)

# --- terrain shell: top skin + exposed slope steps, nothing buried ---
print("terrain shell ...", flush=True)
Hh = [[ground_h(x,z) for z in range(B)] for x in range(B)]
for x in range(B):
    for z in range(B):
        h = Hh[x][z]
        d = abs(x - river_center(z))
        top = SAND if d <= 9 else (GRASS_HI if rng.random() < 0.15 else GRASS)
        emit(x, h, z, top)
        # only the exposed band of a slope: fill down to the lowest neighbour
        min_n = min(Hh[x-1][z] if x>0 else 0, Hh[x+1][z] if x<B-1 else 0,
                    Hh[x][z-1] if z>0 else 0, Hh[x][z+1] if z<B-1 else 0)
        for y in range(min_n + 1, h):
            emit(x, y, z, DIRT)
print(f"  shell voxels: {len(BATCH)}", flush=True)
flush()

# --- water: thin sheet in the channel ---
print("water ...", flush=True)
for z in range(B):
    cx = river_center(z)
    for x in range(cx-5, cx+5):
        emit(x, 3, z, WATER)
flush()

# --- bridge ---
print("bridge ...", flush=True)
bz=B//2; bcx=river_center(bz); dy=8
for x in range(bcx-7, bcx+7):
    for z in range(bz-1, bz+2):
        emit(x, dy, z, WOOD)
for sx in (-7, 5):
    for y in range(3, dy):
        for z in range(bz-1, bz+2):
            emit(bcx+sx, y, z, WOOD)
            emit(bcx+sx+1, y, z, WOOD)
    emit(bcx+sx, dy+1, bz-2, WOOD); emit(bcx+sx+1, dy+1, bz-2, WOOD)
    emit(bcx+sx, dy+1, bz+2, WOOD); emit(bcx+sx+1, dy+1, bz+2, WOOD)
flush()

# --- trees ---
print("trees ...", flush=True)
def tree(x, z):
    h = Hh[x][z]
    for y in range(h+1, h+5): emit(x, y, z, WOOD)
    for dx in range(-2, 3):
        for dz in range(-2, 3):
            for dy2 in range(h+4, h+7):
                emit(x+dx, dy2, z+dz, LEAF)
    for dx in range(-1, 2):
        for dz in range(-1, 2):
            for dy2 in range(h+7, h+9):
                emit(x+dx, dy2, z+dz, LEAF_HI)
placed=0
while placed < 10:
    z = rng.randint(10, B-10); side = rng.choice([-1, 1])
    x = river_center(z) + side*rng.randint(18, 45)
    if 12 <= x < B-12:
        tree(x, z); placed += 1
flush()

# --- cabin ---
print("cabin ...", flush=True)
kz = rng.randint(B//3, 2*B//3); kx = river_center(kz)+20; kh = Hh[kx][kz]
for x in range(kx, kx+8):
    for z in range(kz, kz+7):
        for y in range(kh+1, kh+5):
            if x in (kx, kx+7) or z in (kz, kz+6):
                emit(x, y, z, WALL)          # walls (hollow inside)
for x in range(kx-1, kx+9):
    for z in range(kz-1, kz+8):
        emit(x, kh+5, z, ROOF); emit(x, kh+6, z, ROOF)
for y in range(kh+1, kh+4): emit(kx+4, y, kz, WOOD); emit(kx+3, y, kz, WOOD)   # door
emit(kx+1, kh+3, kz, "3b3a4f"); emit(kx+2, kh+3, kz, "3b3a4f")                 # window
emit(kx+6, kh+3, kz, "3b3a4f")
for y in range(kh+7, kh+10): emit(kx+6, y, kz+5, STONE)                        # chimney
flush()

# --- flowers ---
print("flowers ...", flush=True)
for _ in range(24):
    z = rng.randint(6, B-6); side = rng.choice([-1, 1])
    x = river_center(z) + side*rng.randint(11, 24)
    if 4 <= x < B-4:
        emit(x, Hh[x][z]+1, z, FLOWER_R if rng.random() < 0.5 else FLOWER_Y)
flush()

# --- sun + clouds ---
print("sky ...", flush=True)
for x in range(B-24, B-14):
    for y in range(100, 110):
        for z in range(18, 22):
            emit(x, y, z, SUN)
for cx0, cy0, cz0 in [(24, 92, 40), (70, 96, 84), (96, 90, 56)]:
    for dx in range(10):
        for dy in range(3):
            for dz in range(4):
                emit(cx0+dx, cy0+dy, cz0+dz, CLOUD)
    for dx in range(2, 7):
        for dy in range(3, 5):
            for dz in range(1, 3):
                emit(cx0+dx, cy0+dy, cz0+dz, CLOUD)
flush()

call("frame"); call("set_camera", {"yaw": 35, "pitch": -30, "distance": 150})
st = call("get_state"); print("voxels:", st["voxel_count"], "bounds:", st["bounds"], flush=True)
print("saved:", call("save", {"path": os.environ.get("VOXDOT_VALLEY_OUTPUT", os.path.expanduser("~/Documents/Voxdot/sunny_valley.tres"))}), flush=True)
print("screenshot:", call("screenshot"), flush=True)
print("DONE", flush=True)
