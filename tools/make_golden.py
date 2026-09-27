# -*- coding: utf-8 -*-
"""Writes EightBallTests/golden.json: deterministic physics scenarios recorded from the Python engine (pg_physics.py).

  python tools/make_golden.py

Every scenario is a table with hand-placed balls (Physics(empty=True) + place_ball), one strike(...), stepped at 1/120 s until
everything is at rest. The file records the ids pocketed (in order, with the pocket index), the first ball the cue ball touched and
the final position of every ball left on the cloth. PhysicsTests.swift replays each scenario in Swift and compares (positions to
2e-3 m, ids / first hit / pocket indices exactly).

Because the break (and any long chain of collisions) is chaotic, every scenario is also replayed with the strike angle nudged by
1e-12 rad: if that changes a final position by more than the test tolerance / 4 the script fails, so the golden data never depends on
the last bit of sin() / cos().
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "pool_game"))
sys.path.insert(0, r"C:\Users\c0derz\Downloads\assets\pool_game")

from pg_physics import Physics, R, D, HL, HW, HEAD_X, FOOT_X, CORNER_POCKET, SIDE_POCKET_Y  # noqa: E402

DT = 1.0 / 120.0
MAX_STEPS = 7200
OUT = os.path.join(os.path.dirname(HERE), "EightBallTests", "golden.json")


def run(sc, angle_nudge=0.0):
    p = Physics(empty=True)
    for b in p.balls:
        b.state = 'pocketed'
    for i, x, y in sc['balls']:
        p.place_ball(i, x, y)
    st = sc['strike']
    p.strike(st['angle'] + angle_nudge, st['speed'], st['side'], st['top'])
    first_hit = None
    pocketed = []
    pockets = []
    cue_pocketed = False
    steps = 0
    while steps < MAX_STEPS:
        p.step(DT)
        steps += 1
        for ev in p.events:
            if ev[0] == 'ball_ball' and first_hit is None and (ev[1] == 0 or ev[2] == 0):
                first_hit = ev[2] if ev[1] == 0 else ev[1]
            elif ev[0] == 'pocket':
                if ev[1] == 0:
                    cue_pocketed = True
                else:
                    pocketed.append(ev[1])
                pockets.append([ev[1], ev[2]])
        del p.events[:]
        if not p.moving():
            break
    final = [{'id': b.id, 'x': b.x, 'y': b.y} for b in p.active_balls()]
    return {'first_hit': first_hit, 'pocketed': pocketed, 'pockets': pockets, 'cue_pocketed': cue_pocketed,
            'steps': steps, 'final': final}


def scenario(name, balls, angle, speed, side=0.0, top=0.0, note=''):
    return {'name': name, 'note': note, 'balls': [[i, x, y] for i, x, y in balls],
            'strike': {'angle': angle, 'speed': speed, 'side': side, 'top': top}}


def unit(ax, ay, bx, by):
    d = math.hypot(bx - ax, by - ay)
    return (bx - ax) / d, (by - ay) / d


def cut_shot(obj_xy, pocket_xy, cut_deg, lead=0.6):
    """Cue start and shot angle for a cut of `cut_deg` degrees on the ball at obj_xy towards pocket_xy."""
    ux, uy = unit(obj_xy[0], obj_xy[1], pocket_xy[0], pocket_xy[1])
    gx, gy = obj_xy[0] - D * ux, obj_xy[1] - D * uy            # ghost ball
    c = math.radians(cut_deg)
    dx = ux * math.cos(c) - uy * math.sin(c)
    dy = ux * math.sin(c) + uy * math.cos(c)
    return (gx - lead * dx, gy - lead * dy), math.atan2(dy, dx)


def build():
    sc = []
    sc.append(scenario('straight_stun', [(0, -0.6, 0.0), (1, 0.0, 0.0)], 0.0, 2.0,
                       note='dead straight, no spin: the cue ball stops near the contact point'))
    sc.append(scenario('follow', [(0, -0.6, 0.0), (2, 0.1, 0.0)], 0.0, 2.5, top=0.4,
                       note='top spin: the cue ball follows through'))
    sc.append(scenario('draw', [(0, -0.4, 0.0), (3, 0.0, 0.0)], 0.0, 3.0, top=-0.4,
                       note='back spin: the cue ball comes back'))
    sc.append(scenario('side_spin_cushions', [(0, -0.9, 0.2), (4, 0.3, 0.1)], math.atan2(0.1 - 0.2, 0.3 + 0.9) + 0.02, 2.6, side=0.45, top=0.1,
                       note='side spin through several cushions'))
    bstart, bang = cut_shot((0.2, -0.3), (0.62, -0.62), 12.0, lead=0.7)
    sc.append(scenario('bank_off_long_rail', [(0, bstart[0], bstart[1]), (5, 0.2, -0.3)], bang, 3.0,
                       note='the object ball banks off the long rail'))
    start, ang = cut_shot((0.85, 0.35), CORNER_POCKET, 22.0)
    sc.append(scenario('cut_into_corner', [(0, start[0], start[1]), (1, 0.85, 0.35)], ang, 2.6, top=-0.3,
                       note='22 degree cut into the far corner pocket (index 3)'))
    sc.append(scenario('side_pocket_fast', [(0, 0.03, -0.12), (9, 0.03, 0.40)], math.pi / 2.0, 8.0, top=-0.5,
                       note='object ball down the mouth of the side pocket at high speed: must drop (pocket 5)'))
    sc.append(scenario('scratch_corner', [(0, 0.8, 0.3), (6, -0.5, -0.3)], math.atan2(CORNER_POCKET[1] - 0.3, CORNER_POCKET[0] - 0.8), 2.4,
                       note='cue ball into the corner pocket'))
    sc.append(scenario('knuckle_graze', [(0, 0.5, 0.0)], math.atan2(0.62 - 0.0, 0.10 - 0.5), 3.0,
                       note='cue ball skims the cushion end next to the side pocket'))
    # a short combination: cue hits 7, which is touching 10 which is lined up on the corner pocket
    ux, uy = unit(0.7, 0.3, CORNER_POCKET[0], CORNER_POCKET[1])
    o1 = (0.7, 0.3)
    o2 = (0.7 - D * ux * 1.0005, 0.3 - D * uy * 1.0005)
    sc.append(scenario('combination', [(0, o2[0] - 0.5 * ux, o2[1] - 0.5 * uy), (7, o2[0], o2[1]), (10, o1[0], o1[1])],
                       math.atan2(uy, ux), 3.2, note='two touching balls on the line of the corner pocket'))
    # the break: a hand-placed rack
    order = [1, 9, 2, 10, 8, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15]
    pitch = D + 1e-4
    row_dx = pitch * math.sqrt(3.0) / 2.0
    balls = [(0, HEAD_X, 0.0)]
    slot = 0
    for row in range(5):
        for col in range(row + 1):
            balls.append((order[slot], FOOT_X + row * row_dx, (col - row / 2.0) * pitch))
            slot += 1
    sc.append(scenario('break', balls, 0.0, 7.0, note='hand-placed rack, straight break'))
    return sc


def main():
    scenarios = build()
    out = []
    worst = 0.0
    for sc in scenarios:
        res = run(sc)
        alt = run(sc, 1e-12)
        pos = {b['id']: (b['x'], b['y']) for b in res['final']}
        dev = 0.0
        if [b['id'] for b in alt['final']] != [b['id'] for b in res['final']] or alt['pocketed'] != res['pocketed']:
            dev = 9.0
        else:
            for b in alt['final']:
                dev = max(dev, math.hypot(b['x'] - pos[b['id']][0], b['y'] - pos[b['id']][1]))
        worst = max(worst, dev)
        print('%-20s steps %5d  first hit %-4s pocketed %-22s cue_pocketed %-5s  left %2d  sensitivity %.2e' % (
            sc['name'], res['steps'], res['first_hit'], res['pocketed'], res['cue_pocketed'], len(res['final']), dev))
        if dev > 5e-4:
            print('   ^ TOO SENSITIVE: pick another scenario')
        sc = dict(sc)
        sc['expect'] = res
        out.append(sc)
    by_name = {sc['name']: sc for sc in out}
    assert by_name['side_pocket_fast']['expect']['pocketed'] == [9], 'the fast side-pocket shot must drop'
    assert by_name['side_pocket_fast']['expect']['pockets'][0][1] == 5
    assert 1 in by_name['cut_into_corner']['expect']['pocketed'], 'the cut shot must pot'
    assert by_name['scratch_corner']['expect']['cue_pocketed'], 'the scratch shot must scratch'
    assert by_name['break']['expect']['first_hit'] == 1
    data = {'dt': DT, 'maxSteps': MAX_STEPS, 'positionTolerance': 2e-3, 'scenarios': out}
    with open(OUT, 'w') as f:
        json.dump(data, f, indent=1)
    print('wrote %s (%d scenarios, worst sensitivity %.2e)' % (OUT, len(out), worst))
    if worst > 5e-4:
        sys.exit(1)


if __name__ == '__main__':
    main()
