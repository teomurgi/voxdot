#!/usr/bin/env python3
"""Adds evening point lighting to the pagoda model over MCP.

Run against an editor that has pagoda_demo_512.tres open:
    VOXDOT_MCP_PORT=7852 python3 tools/light_pagoda.py [--dusk]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tools.build_pagoda_512 as p

p.PORT = int(os.environ.get("VOXDOT_MCP_PORT", "7852"))

TIER_LIGHTS = [
    ([256, 46, 258], {"color": "ffb066", "energy": 6.0, "range": 60.0}),
    ([256, 110, 262], {"color": "ff9a4d", "energy": 5.0, "range": 50.0}),
    ([256, 162, 262], {"color": "ffb066", "energy": 4.0, "range": 44.0}),
    ([256, 208, 262], {"color": "ff9a4d", "energy": 3.5, "range": 38.0}),
]
LANTERN_LIGHTS = [
    ([218.5, 25.5, 290.5], {"color": "ffd27a", "energy": 3.0, "range": 34.0}),
    ([294.5, 25.5, 290.5], {"color": "ffd27a", "energy": 3.0, "range": 34.0}),
    ([220.5, 25.5, 384.5], {"color": "ffd27a", "energy": 3.0, "range": 34.0}),
    ([324.5, 25.5, 382.5], {"color": "ffd27a", "energy": 3.0, "range": 34.0}),
]
POND_LIGHT = [([256, 16, 340], {"color": "7fd8e8", "energy": 2.0, "range": 70.0, "shadows": False})]


def main():
    state = p.call("get_state")
    if not state["path"] or state["voxel_count"] == 0:
        print("opening", p.call("open", {"path": p.OUTPUT}), flush=True)
        state = p.call("get_state")
    print(f"opened {state['path']}: {state['voxel_count']:,} voxels")
    for pos, kw in TIER_LIGHTS + LANTERN_LIGHTS + POND_LIGHT:
        result = p.call("add_light", {"position": pos, **kw})
        print(f"  light {result['id']} at {pos} {kw.get('color')}", flush=True)
    if os.environ.get("VOXDOT_DUSK", "1") == "1":
        print("dusk:", p.call("set_sun", {"energy": 0.12, "color": "ffb27a", "pitch": -12}))
    print("lights:", p.call("get_lights")["count"], flush=True)
    p.call("set_camera", {"yaw": 38, "pitch": -28, "distance": 351})
    p.call("pan", {"dx": 0, "dy": -82})
    print("saved:", p.call("save", {"path": p.OUTPUT}), flush=True)
    print("screenshot:", p.call("screenshot"), flush=True)


if __name__ == "__main__":
    main()
