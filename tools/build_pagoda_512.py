#!/usr/bin/env python3
"""Five-tier pagoda garden in a 512^3 Voxdot document, built only over MCP.

The scene is a compact, raised diorama: curved ceramic roofs, vermilion timber,
shoji panels, balcony rails, a stone garden, koi pond, arched bridge, lanterns,
and four cherry trees. Geometry is grouped by render chunk before streaming so
that each place_voxels call normally dirties only one editor mesh chunk.

Run against a fresh, empty editor:
    VOXDOT_MCP_PORT=7850 python3 tools/build_pagoda_512.py
"""
import json
import math
import os
import random
import time
import urllib.request

PORT = int(os.environ.get("VOXDOT_MCP_PORT", "7850"))
OUTPUT = os.environ.get("VOXDOT_PAGODA_OUTPUT", os.path.expanduser("~/Documents/Voxdot/pagoda_demo_512.tres"))
B = 512
CX = 256
CZ = 224
GROUND = 8
_rng = random.Random(512042)
_rpc_id = 0


def rpc(method, params=None):
    global _rpc_id
    _rpc_id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _rpc_id, "method": method,
                       "params": params or {}}).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/", data=body,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.load(response)


def call(name, args=None):
    response = rpc("tools/call", {"name": name, "arguments": args or {}})
    if "error" in response:
        raise RuntimeError(f"{name}: {response['error']}")
    result = response["result"]
    if result.get("is_error") or result.get("isError"):
        raise RuntimeError(f"{name}: {result['content'][0]['text']}")
    text = result["content"][0]["text"]
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return text


# Palette: indigo ceramic, vermilion timber, warm shoji, cool stone, pink blossom.
STONE_DARK = "555b60"
STONE = "858b8b"
STONE_LIGHT = "b1b2a7"
GRAVEL = "bdb49e"
WOOD_DARK = "482d2a"
WOOD = "71372d"
RED_DARK = "792b2a"
RED = "b94535"
RED_LIGHT = "d65b40"
GOLD_DARK = "a8752c"
GOLD = "e4b34f"
GOLD_LIGHT = "ffd77a"
PLASTER = "e2d3ae"
SHOJI = "edc88c"
WINDOW_DARK = "4d4437"
ROOF_DARK = "243942"
ROOF = "35535e"
ROOF_LIGHT = "52717a"
ROOF_RIDGE = "68858a"
GRASS = ["58773e", "668447", "73904d", "7f9955"]
WATER = ["347f91", "3b8f9c", "479eaa", "58adb3"]
PINK = ["cf5c82", "df7597", "ec8faa", "f3aac0", "f8c3d2"]
BARK = "604131"
BARK_LIGHT = "7d5439"


_stage = {}


def emit(x, y, z, color):
    p = (int(x), int(y), int(z))
    if not (0 <= p[0] < B and 0 <= p[1] < B and 0 <= p[2] < B):
        raise ValueError(f"voxel outside 512^3: {p}")
    _stage[p] = color


def box(x0, y0, z0, x1, y1, z1, color):
    for x in range(min(x0, x1), max(x0, x1) + 1):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            for z in range(min(z0, z1), max(z0, z1) + 1):
                emit(x, y, z, color)


def thick_line(a, b, color, radius=0):
    steps = max(abs(b[i] - a[i]) for i in range(3)) * 2 + 1
    for i in range(steps + 1):
        t = i / steps
        p = tuple(round(a[k] + (b[k] - a[k]) * t) for k in range(3))
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                for dz in range(-radius, radius + 1):
                    if dx * dx + dy * dy + dz * dz <= radius * radius + 0.25:
                        emit(p[0] + dx, p[1] + dy, p[2] + dz, color)


def flush(label):
    global _stage
    if not _stage:
        return
    print(f"{label}: {len(_stage):,} staged voxels", flush=True)
    groups = {}
    for (x, y, z), color in _stage.items():
        groups.setdefault((x // 64, z // 64), []).append(f"{x},{y},{z};{color}")
    total = 0
    for key in sorted(groups):
        data = groups[key]
        for start in range(0, len(data), 14000):
            batch = data[start:start + 14000]
            result = call("place_voxels", {"data": batch})
            total = result["count"]
            print(f"  chunk {key}: {len(batch):,} cells -> {total:,} total", flush=True)
    _stage = {}


def square_inside(dx, dz, radius, cut=0):
    return max(abs(dx), abs(dz)) <= radius and abs(dx) + abs(dz) <= 2 * radius - cut


def pond_value(x, z):
    nx = (x - 256) / 64.0
    nz = (z - 340) / 31.0
    return nx * nx + nz * nz


def in_pond(x, z):
    wobble = 0.045 * math.sin(x * 0.19) + 0.035 * math.cos(z * 0.27)
    return pond_value(x, z) < 1.0 + wobble


def build_garden():
    # A chamfered, raised stone island. Only its top and exposed side skin are
    # stored; invisible interior fill would add no surface detail.
    for x in range(104, 409):
        for z in range(104, 409):
            dx, dz = x - 256, z - 256
            if not square_inside(dx, dz, 152, 24):
                continue
            border = not square_inside(dx, dz, 147, 14)
            if border:
                for y in range(0, GROUND):
                    if y <= 2:
                        c = STONE_DARK
                    elif y <= 5:
                        c = STONE
                    else:
                        c = STONE_LIGHT
                    if (x + z + y * 3) % 17 == 0 and y < 6:
                        c = STONE_DARK
                    emit(x, y, z, c)
            if in_pond(x, z):
                emit(x, 5, z, "55716c")
                emit(x, 6, z, "2e6e80")
                value = pond_value(x, z)
                c = WATER[min(3, int(value * 3.2))]
                if (x + 2 * z) % 19 == 0 or (x - z) % 29 == 0:
                    c = "72b9b7"
                emit(x, 7, z, c)
                continue

            bank = any(in_pond(x + ox, z + oz) for ox, oz in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            if bank:
                for y in range(5, 8):
                    emit(x, y, z, GRAVEL if y == 7 else STONE)
            courtyard = abs(x - CX) <= 79 and abs(z - CZ) <= 78
            main_path = abs(x - 256) <= 9 and z >= 278
            pond_rim = pond_value(x, z) < 1.24 and z > 300
            if border:
                c = STONE_LIGHT if (x + z) % 5 else STONE
            elif main_path:
                c = STONE_LIGHT if (z % 7) else STONE
                if abs(x - 256) >= 8:
                    c = STONE_DARK
            elif courtyard:
                c = GRAVEL if z % 6 else "aaa28f"
                if (x + z) % 23 == 0:
                    c = "cec5ad"
            elif pond_rim:
                c = _rng.choice(["b7ad91", "c7bb9a", "999b88", "d0c3a2"])
            else:
                c = _rng.choice(GRASS)
            emit(x, GROUND, z, c)

    # Flat stepping stones lead from the front edge to the bridge.
    for z in range(383, 401, 6):
        for x in range(249, 264):
            for zz in range(z, min(z + 4, 402)):
                if square_inside(x - 256, zz - 256, 152, 24):
                    emit(x, 9, zz, STONE_LIGHT if (x + zz) % 4 else STONE)
    flush("raised garden and pond")


def stone_platform(y0, y1, radius, cut):
    for dx in range(-radius, radius + 1):
        for dz in range(-radius, radius + 1):
            if not square_inside(dx, dz, radius, cut):
                continue
            top = STONE_LIGHT
            if dx % 8 == 0 or dz % 8 == 0:
                top = "969b96"
            if not square_inside(dx, dz, radius - 2, max(0, cut - 4)):
                top = STONE
            emit(CX + dx, y1, CZ + dz, top)
            edge = not square_inside(dx, dz, radius - 1, cut)
            if edge:
                for y in range(y0, y1):
                    emit(CX + dx, y, CZ + dz, STONE if y % 3 else STONE_DARK)


def build_plinth():
    stone_platform(9, 11, 56, 12)
    stone_platform(12, 14, 53, 11)
    stone_platform(15, 17, 50, 10)
    stone_platform(18, 19, 47, 9)
    # Broad stairs climb toward the veranda; low flanking stones anchor them.
    for i in range(12):
        z = 301 - i * 3
        top = 9 + i
        for x in range(247, 266):
            for zz in range(z, z + 3):
                for y in range(9, top + 1):
                    emit(x, y, zz, STONE_LIGHT if y == top else STONE)
        for x in (245, 267):
            box(x, 9, z, x, top + 1, z + 1, STONE)
    flush("stepped stone plinth")


def balcony(floor, half, rail_half):
    for dx in range(-rail_half, rail_half + 1):
        for dz in range(-rail_half, rail_half + 1):
            c = WOOD if (dx + floor) % 5 else "855040"
            emit(CX + dx, floor, CZ + dz, c)
            if max(abs(dx), abs(dz)) == rail_half:
                emit(CX + dx, floor - 1, CZ + dz, RED_DARK)
    # Two continuous rails with regularly spaced upright posts.
    for side in range(4):
        for t in range(-rail_half, rail_half + 1):
            if side == 0:
                x, z = t, rail_half
            elif side == 1:
                x, z = t, -rail_half
            elif side == 2:
                x, z = rail_half, t
            else:
                x, z = -rail_half, t
            if side == 0 and abs(t) <= 6:
                continue
            post = (t + rail_half) % 6 == 0 or abs(t) == rail_half
            for y in (floor + 3, floor + 7):
                emit(CX + x, y, CZ + z, RED_LIGHT if y == floor + 7 else RED)
            if post:
                for y in range(floor + 2, floor + 9):
                    emit(CX + x, y, CZ + z, RED)
                emit(CX + x, floor + 9, CZ + z, GOLD)


def story_walls(floor, eave, half, index):
    columns = {-half, -(half // 2), 0, half // 2, half}
    for dx in range(-half, half + 1):
        for dz in range(-half, half + 1):
            if max(abs(dx), abs(dz)) not in (half, half - 1):
                continue
            t = dx if abs(dz) >= half - 1 else dz
            front = dz >= half - 1
            for y in range(floor + 2, eave + 6):
                rel = y - floor
                structural = t in columns or rel in (2, 3, 4) or y >= eave + 2 or rel % 11 == 0
                door = index == 0 and front and abs(t) <= 5 and rel <= 29
                if door:
                    c = WOOD_DARK if abs(t) <= 4 else RED_DARK
                    if abs(t) <= 4 and (rel % 6 == 0 or t == 0):
                        c = GOLD_DARK if rel % 6 == 0 else RED
                elif structural:
                    c = RED if abs(t) == half else RED_DARK
                elif floor + 9 <= y <= eave and t not in columns:
                    lattice = t % 4 == 0 or rel % 5 == 0
                    c = WINDOW_DARK if lattice else SHOJI
                else:
                    c = PLASTER if (dx + dz + y) % 9 else "d1c39f"
                emit(CX + dx, y, CZ + dz, c)
    # Chunky corner posts and exterior veranda columns.
    post_r = half + 6
    points = set()
    for v in (-post_r, 0, post_r):
        points.update(((v, -post_r), (v, post_r), (-post_r, v), (post_r, v)))
    for dx, dz in points:
        width = 1 if index == 0 else 0
        box(CX + dx - width, floor + 2, CZ + dz - width,
            CX + dx + width, eave + 2, CZ + dz + width, RED_DARK)
        box(CX + dx - 2, eave + 1, CZ + dz - 2,
            CX + dx + 2, eave + 3, CZ + dz + 2, RED)
        emit(CX + dx, eave + 4, CZ + dz, GOLD_DARK)
    if index == 0:
        # Door pulls on the front of the ground-floor double doors.
        for dx in (-2, 2):
            box(CX + dx, floor + 15, CZ + half + 1,
                CX + dx, floor + 17, CZ + half + 1, GOLD_LIGHT)


def curved_roof(eave, rise, radius, tier):
    heights = {}
    for dx in range(-radius, radius + 1):
        for dz in range(-radius, radius + 1):
            axial = max(abs(dx), abs(dz))
            t = axial / radius
            q = min(abs(dx), abs(dz)) / max(1, axial)
            curve = rise * (1.0 - t) ** 1.55
            corner = 7.0 * t ** 5 * q ** 7
            lip = 2.0 * max(0.0, (t - 0.88) / 0.12) ** 2
            heights[(dx, dz)] = eave + round(curve + corner + lip)

    for (dx, dz), h in heights.items():
        neighbors = [heights.get((dx + ox, dz + oz), h - 2)
                     for ox, oz in ((1, 0), (-1, 0), (0, 1), (0, -1))]
        bottom = min(h - 1, min(neighbors))
        slope, cross = (dx, dz) if abs(dx) >= abs(dz) else (dz, dx)
        c = ROOF
        if cross % 5 == 0:
            c = ROOF_DARK
        elif slope % 7 == 0:
            c = ROOF_LIGHT
        if max(abs(dx), abs(dz)) >= radius - 1:
            c = ROOF_DARK if cross % 6 else ROOF_LIGHT
        for y in range(bottom, h + 1):
            emit(CX + dx, y, CZ + dz, c if y == h else ROOF_DARK)

        # Four hip ridges follow the lifted corners.
        if abs(dx) == abs(dz):
            ridge = GOLD_DARK if max(abs(dx), abs(dz)) > radius - 5 else ROOF_RIDGE
            emit(CX + dx, h + 1, CZ + dz, ridge)

        # A dark red eave beam remains visible below the ceramic edge.
        if max(abs(dx), abs(dz)) == radius:
            emit(CX + dx, h - 2, CZ + dz, RED_DARK)

    # Exposed bracket sets under all four eaves.
    for t in range(-radius + 6, radius - 5, 8):
        for dx, dz in ((t, radius - 2), (t, -radius + 2),
                       (radius - 2, t), (-radius + 2, t)):
            h = heights[(dx, dz)]
            box(CX + dx - 1, eave - 2, CZ + dz - 1,
                CX + dx + 1, h - 2, CZ + dz + 1, RED_DARK)
            emit(CX + dx, eave - 3, CZ + dz, GOLD_DARK)

    # Golden corner bells and small upward-curling finials.
    for sx in (-1, 1):
        for sz in (-1, 1):
            dx, dz = sx * radius, sz * radius
            h = heights[(dx, dz)]
            emit(CX + dx, h + 2, CZ + dz, GOLD)
            emit(CX + dx, h + 3, CZ + dz, GOLD_LIGHT)
            emit(CX + dx + sx, h + 4, CZ + dz + sz, GOLD)
            box(CX + dx, h - 5, CZ + dz, CX + dx, h - 3, CZ + dz, GOLD_DARK)
            emit(CX + dx, h - 6, CZ + dz, GOLD_LIGHT)
    flush(f"tier {tier + 1} curved tiled roof")


def build_pagoda():
    # floor, eave, roof rise, body half-width, balcony half-width, roof radius
    tiers = [
        (20, 62, 15, 29, 42, 68),
        (80, 112, 13, 25, 36, 59),
        (132, 161, 12, 21, 31, 51),
        (178, 204, 11, 17, 26, 43),
        (220, 243, 10, 13, 21, 35),
    ]
    for i, (floor, eave, rise, half, balcony_half, roof_radius) in enumerate(tiers):
        balcony(floor, half, balcony_half)
        story_walls(floor, eave, half, i)
        flush(f"tier {i + 1} timber, shoji and balcony")
        curved_roof(eave, rise, roof_radius, i)

    # A bronze-and-gold sorin spire above the fifth roof.
    for y, radius in ((254, 6), (255, 6), (256, 5), (257, 4), (258, 3)):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if square_inside(dx, dz, radius, 2):
                    emit(CX + dx, y, CZ + dz, GOLD_DARK if y < 257 else GOLD)
    box(CX - 1, 259, CZ - 1, CX + 1, 295, CZ + 1, GOLD)
    for i in range(7):
        y = 263 + i * 4
        radius = 7 - i // 2
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if square_inside(dx, dz, radius, 2) and not square_inside(dx, dz, radius - 2, 0):
                    emit(CX + dx, y, CZ + dz, GOLD_LIGHT if i % 2 else GOLD)
    for y, radius in ((296, 1), (297, 2), (298, 3), (299, 2), (300, 1), (301, 0)):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if abs(dx) + abs(dz) <= radius:
                    emit(CX + dx, y, CZ + dz, GOLD_LIGHT)
    flush("seven-ring golden finial")


def build_bridge():
    # Arched deck running north-south across the pond.
    for z in range(302, 379):
        t = (z - 302) / 76.0
        h = 10 + round(9 * math.sin(math.pi * t))
        for x in range(248, 265):
            plank = RED_LIGHT if z % 4 else RED_DARK
            emit(x, h, z, plank)
            emit(x, h - 1, z, WOOD_DARK)
        for x in (247, 265):
            emit(x, h - 2, z, RED_DARK)
            emit(x, h + 3, z, RED)
            emit(x, h + 7, z, RED_LIGHT)
            if (z - 302) % 6 == 0 or z in (302, 378):
                box(x, h, z, x, h + 8, z, RED)
                emit(x, h + 9, z, GOLD)
        if z in (304, 316, 340, 364, 376):
            for x in (249, 263):
                box(x, 5, z, x + 1, h - 1, z + 1, RED_DARK)
    # Stone approaches at either end.
    for z0, direction in ((298, 1), (379, 1)):
        for i in range(5):
            z = z0 + i if z0 == 298 else z0 + i
            h = 10 - i // 2 if z0 == 298 else 9 - i // 3
            for x in range(249, 264):
                emit(x, max(9, h), z, STONE_LIGHT)
    flush("arched vermilion bridge")


def koi(x, z, along_x, length=6):
    for i in range(length):
        xx, zz = (x + i, z) if along_x else (x, z + i)
        if in_pond(xx, zz):
            c = "ed7c3c" if i not in (1, length - 2) else "f3e4c2"
            emit(xx, 7, zz, c)
    if along_x and in_pond(x + 2, z + 1):
        emit(x + 2, 7, z + 1, "f3e4c2")


def rock_cluster(x, z, rx=5, ry=4, rz=4):
    for dx in range(-rx, rx + 1):
        for dy in range(0, ry + 1):
            for dz in range(-rz, rz + 1):
                v = (dx / max(1, rx)) ** 2 + ((dy - 1) / max(1, ry)) ** 2 + (dz / max(1, rz)) ** 2
                if v <= 1.0 + 0.08 * math.sin((dx + dz) * 2.1):
                    emit(x + dx, GROUND + 1 + dy, z + dz,
                         STONE_LIGHT if dy > ry * 0.65 else STONE)


def build_pond_details():
    koi(215, 337, True, 7)
    koi(283, 350, False, 6)
    koi(277, 322, True, 6)
    koi(225, 356, False, 5)
    for x, z in ((209, 326), (216, 364), (299, 358), (307, 331), (285, 368)):
        if in_pond(x, z):
            for dx in range(-2, 3):
                for dz in range(-2, 3):
                    if dx * dx + dz * dz <= 5 and not (dx == 2 and dz == 0):
                        emit(x + dx, 8, z + dz, "5d8b55" if (dx + dz) % 2 else "7da365")
            emit(x, 9, z, "f2a4ba")
            emit(x, 10, z, "f8d0d8")
    for args in ((190, 325, 5, 4, 4), (197, 372, 6, 3, 4),
                 (319, 314, 5, 4, 5), (324, 361, 6, 4, 4),
                 (225, 304, 4, 3, 3), (293, 375, 4, 3, 4)):
        rock_cluster(*args)
    flush("koi, lilies and pond rocks")


def lantern(x, z):
    box(x - 3, 9, z - 3, x + 3, 10, z + 3, STONE)
    box(x - 1, 11, z - 1, x + 1, 18, z + 1, STONE_LIGHT)
    box(x - 3, 19, z - 3, x + 3, 20, z + 3, STONE)
    # Four stone corner posts enclose a warm amber lamp.
    box(x - 1, 21, z - 1, x + 1, 24, z + 1, GOLD_LIGHT)
    for dx in (-2, 2):
        for dz in (-2, 2):
            box(x + dx, 21, z + dz, x + dx, 25, z + dz, STONE_DARK)
    for y, radius in ((26, 4), (27, 3), (28, 2), (29, 1)):
        box(x - radius, y, z - radius, x + radius, y, z + radius, STONE)
    emit(x, 30, z, STONE_LIGHT)


def build_lanterns():
    for x, z in ((218, 290), (294, 290), (220, 384), (324, 382)):
        lantern(x, z)
    flush("four stone lanterns")


def cherry_tree(x, z, trunk_height, spread):
    base = GROUND + 1
    top = base + trunk_height
    # Tapered trunk with visible roots.
    for y in range(base, top + 5):
        radius = 2 if y < base + trunk_height * 0.35 else 1
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if dx * dx + dz * dz <= radius * radius + 0.2:
                    emit(x + dx, y, z + dz, BARK if (y + dx) % 4 else BARK_LIGHT)
    for dx, dz in ((5, 1), (-5, 2), (2, 5), (-2, -5)):
        thick_line((x, base + 2, z), (x + dx, base, z + dz), BARK, 1)

    scale = spread / 28.0
    offsets = [
        (-13, 0, -4, 12), (11, 2, -8, 13), (-7, 7, 10, 13),
        (13, 9, 8, 12), (0, 16, 0, 14), (-18, 6, 8, 11),
        (18, 5, -1, 11), (1, 4, -14, 12),
    ]
    clusters = []
    for ox, oy, oz, radius in offsets:
        center = (x + round(ox * scale), top + round(oy * scale), z + round(oz * scale))
        radii = (max(5, round(radius * scale)), max(5, round(radius * 0.72 * scale)),
                 max(5, round(radius * 0.9 * scale)))
        clusters.append((center, radii))
        thick_line((x, top - 12, z), center, BARK, 1)

    leaves = set()
    for (cx, cy, cz), (rx, ry, rz) in clusters:
        for dx in range(-rx, rx + 1):
            for dy in range(-ry, ry + 1):
                for dz in range(-rz, rz + 1):
                    value = (dx / rx) ** 2 + (dy / ry) ** 2 + (dz / rz) ** 2
                    organic = 1.0 + 0.07 * math.sin((cx + dx) * 0.8 + (cz + dz) * 0.55)
                    if value <= organic:
                        leaves.add((cx + dx, cy + dy, cz + dz))
    for p in leaves:
        # Surface-only blossom clouds; the editor does not need hidden fill.
        if all((p[0] + ox, p[1] + oy, p[2] + oz) in leaves
               for ox, oy, oz in ((1, 0, 0), (-1, 0, 0), (0, 1, 0),
                                  (0, -1, 0), (0, 0, 1), (0, 0, -1))):
            continue
        color_index = _rng.choices(range(len(PINK)), weights=(1, 2, 4, 3, 1))[0]
        if p[1] < top - 2:
            color_index = min(color_index, 2)
        emit(*p, PINK[color_index])
    # Fallen petals make the trees feel rooted in the garden.
    for _ in range(85):
        dx, dz = _rng.randint(-spread, spread), _rng.randint(-spread, spread)
        xx, zz = x + dx, z + dz
        if square_inside(xx - 256, zz - 256, 149, 20) and not in_pond(xx, zz):
            if abs(xx - CX) > 48 or abs(zz - CZ) > 56:
                emit(xx, GROUND + 1, zz, _rng.choice(PINK[1:]))


def build_trees():
    for args in ((146, 164, 44, 27), (366, 158, 54, 30),
                 (374, 286, 42, 25), (142, 348, 34, 22)):
        cherry_tree(*args)
    flush("four flowering cherry trees")


def shrub(x, z, radius=5):
    for dx in range(-radius, radius + 1):
        for dy in range(0, radius + 1):
            for dz in range(-radius, radius + 1):
                if dx * dx + (dy - 1) ** 2 + dz * dz <= radius * radius:
                    if dx * dx + (dy - 1) ** 2 + dz * dz >= (radius - 2) ** 2:
                        emit(x + dx, GROUND + 1 + dy, z + dz,
                             "41683f" if dy < radius // 2 else "62884d")


def build_garden_details():
    for args in ((176, 198, 6), (337, 195, 6), (177, 245, 5),
                 (339, 262, 5), (181, 372, 5), (349, 365, 5),
                 (131, 229, 5), (385, 225, 5)):
        shrub(*args)
    for args in ((176, 176, 7, 6, 5), (346, 143, 6, 5, 5),
                 (374, 242, 5, 4, 7), (161, 291, 6, 4, 4)):
        rock_cluster(*args)
    # Sparse upright grasses and small garden flowers, kept out of the court.
    for _ in range(210):
        x, z = _rng.randint(119, 393), _rng.randint(119, 395)
        if not square_inside(x - 256, z - 256, 145, 20) or in_pond(x, z):
            continue
        if abs(x - CX) < 84 and abs(z - CZ) < 83:
            continue
        if abs(x - 256) < 14 and z > 275:
            continue
        emit(x, 9, z, "8da35a")
        if _rng.random() < 0.22:
            emit(x, 10, z, _rng.choice(["f1cf74", "e8a2b5", "d8d6a0"]))
    flush("moss, shrubs and garden flowers")


def main():
    state = call("get_state")
    if state["voxel_count"] != 0 or state.get("dirty"):
        raise RuntimeError("Refusing to replace a non-empty or unsaved document; open a fresh model first")
    print("Creating fresh 512 x 512 x 512 document through MCP", flush=True)
    call("new_model")
    call("set_bounds", {"bounds": [B, B, B]})
    call("set_mirror", {"x": False, "z": False})
    call("set_height_lock", {"on": False})
    build_garden()
    build_plinth()
    build_pagoda()
    build_bridge()
    build_pond_details()
    build_lanterns()
    build_trees()
    build_garden_details()

    call("set_grid_visible", {"visible": False})
    call("set_orthographic", {"on": False})
    call("frame")
    call("set_camera", {"yaw": 38, "pitch": -28, "distance": 390})
    call("pan", {"dx": 0, "dy": -82})
    call("zoom", {"steps": 1})
    # Let the final cooldown-bound chunk rebuilds finish before saving/capture.
    time.sleep(3)
    state = call("get_state")
    print(f"Final document: {state['voxel_count']:,} voxels, bounds {state['bounds']}", flush=True)
    if state["bounds"] != [B, B, B]:
        raise RuntimeError(f"wrong final bounds: {state['bounds']}")
    print("Saved:", call("save", {"path": OUTPUT}), flush=True)
    print("Screenshot:", call("screenshot"), flush=True)
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
