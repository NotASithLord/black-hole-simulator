#!/usr/bin/env python3
"""Independent binary64 first-opaque-surface reference for the Metal photosphere.

Imports only the existing independently written Boyer–Lindquist r/theta Kerr
integrator. Surface events below are separate from the GPU's reciprocal-radius
intersection implementation. No NumPy/SciPy dependency and no shader code import.
"""
import argparse
import json
import math
from pathlib import Path
import sys
import time

from validate_physics import camera, derivative, isco, metal_input_case, metric, step, trace

ROOT = Path(__file__).resolve().parents[1]
PI = math.pi


def height(rho, phi, inner, outer, amplitude, corrugation):
    if rho <= inner or rho >= outer or amplitude <= 0:
        return 0.0
    c = min(0.08, max(0.0, corrugation))
    lr = math.log(rho / inner)
    t = min(1, max(0, (outer - rho) / (0.2 * outer)))
    closure = t ** 3 * (10 - 15 * t + 6 * t * t)
    return amplitude * (1 - math.sqrt(inner / rho)) * (1 + c * (0.65 * math.cos(3 * phi + 2 * lr) + 0.35 * math.cos(7 * phi - 3 * lr))) * closure


def surface_coordinates(y, inner, outer, amplitude, corrugation):
    r, _, theta, _, phi, _ = y
    rho, z = r * math.sin(theta), r * math.cos(theta)
    return rho, z, height(rho, phi, inner, outer, amplitude, corrugation)


def boundaries(y, inner, outer, amplitude, corrugation):
    rho, z, h = surface_coordinates(y, inner, outer, amplitude, corrugation)
    # All four inequalities <=0 describe the opaque closed volume.
    return z - h, -z - h, inner - rho, rho - outer


def locate_event(y, h, a, xi, eta, boundary, inner, outer, amplitude, corrugation):
    lo, hi = 0.0, h
    start = boundaries(y, inner, outer, amplitude, corrugation)[boundary]
    for _ in range(36):
        middle = (lo + hi) / 2
        q, _ = step(y, middle, a, xi, eta)
        value = boundaries(q, inner, outer, amplitude, corrugation)[boundary]
        if value * start > 0:
            lo = middle
        else:
            hi = middle
    affine = (lo + hi) / 2
    return affine, step(y, affine, a, xi, eta)[0]


def trace_surface(case, tolerance=2e-12):
    a = case['spin']
    xi, eta, energy, null, y = camera(case)
    inner, outer = case['diskInner'], case['diskOuter']
    amplitude, corrugation = case['heightScale'], case['corrugation']
    horizon = 1 + math.sqrt(1 - a * a)
    capture = horizon + 0.0005
    if amplitude <= 0:
        result = trace(a, xi, eta, y, tol=tolerance, disk_outer=outer, escape_radius=1000, capture_radius=capture)
        result.update(xi=xi, eta=eta, energy=energy, null=null)
        return result
    if max(boundaries(y, inner, outer, amplitude, corrugation)) <= 0:
        return dict(status=5, state=y, xi=xi, eta=eta, energy=energy, null=null, accepted=0)
    h, affine, accepted = min(0.001, 0.008 / y[0]), 0.0, 0
    while accepted < 100000 and affine < 15:
        d = derivative(y, a, xi, eta)
        h = min(h, 0.03 * y[0] / max(1, abs(y[1])), 0.04 / max(1, abs(y[3])),
                0.01 / max(1, abs(d[4])), 0.14 * max(y[0] - horizon, 0.00001) / max(1, -y[1]))
        if xi:
            h = min(h, 0.15 * max(0.00001, min(abs(y[2]), abs(PI - y[2]))) / max(1, abs(y[3])))
        q, errors = step(y, h, a, xi, eta)
        scaled_error = max(abs(e) / (tolerance * max(1, abs(v), abs(w))) for e, v, w in zip(errors, y, q))
        if not all(math.isfinite(value) for value in q):
            raise ArithmeticError('Nonfinite independent surface trajectory')
        if scaled_error > 1:
            h *= max(0.1, 0.9 * scaled_error ** -0.2)
            continue
        accepted += 1
        if xi == 0 and (q[2] < 0 or q[2] > PI):
            q[2] = abs(q[2]) if q[2] < 0 else 2 * PI - q[2]
            q[3] = -q[3]
            q[4] += PI
        old_values = boundaries(y, inner, outer, amplitude, corrugation)
        new_values = boundaries(q, inner, outer, amplitude, corrugation)
        candidates = []
        for axis, (first, second) in enumerate(zip(old_values, new_values)):
            if first * second < 0:
                fraction, hit = locate_event(y, h, a, xi, eta, axis, inner, outer, amplitude, corrugation)
                if max(boundaries(hit, inner, outer, amplitude, corrugation)) < 2e-7:
                    candidates.append((fraction, hit, axis))
        if candidates:
            fraction, hit, axis = min(candidates, key=lambda item: item[0])
            return dict(status=1, state=hit, xi=xi, eta=eta, energy=energy, null=null, accepted=accepted, surface=axis, affine=affine + fraction)
        if q[0] < capture:
            return dict(status=2, state=q, xi=xi, eta=eta, energy=energy, null=null, accepted=accepted)
        if q[0] > 1000 and q[1] > 0:
            return dict(status=3, state=q, xi=xi, eta=eta, energy=energy, null=null, accepted=accepted)
        y = q
        affine += h
        h *= min(3, max(0.2, 0.9 * max(scaled_error, 1e-16) ** -0.2))
    return dict(status=4, state=y, xi=xi, eta=eta, energy=energy, null=null, accepted=accepted)


def compare(document):
    checks, mismatches, errors = [], [], []
    references = {}
    def check(name, passed, detail):
        checks.append(dict(name=name, passed=bool(passed), detail=detail))
        print(('PASS ' if passed else 'FAIL ') + name + ': ' + detail, flush=True)
    max_position = max_phi = max_delay = max_mu = 0.0
    max_redshift = max_norm_error = max_height = max_constants = 0.0
    upper = lower = tapered = finite_hits = thin_hits = 0
    timelike, nonnegative = True, True
    hidden_later_hits = 0
    convergence = []
    started = time.monotonic()
    for index, item in enumerate(document['cases']):
        case = metal_input_case(item)
        result = trace_surface(case)
        references[item['id']] = result
        data = item['result']
        gpu_status = round(data[4])
        max_constants = max(max_constants, *(abs(data[j] - value) / max(1, abs(value)) for j, value in enumerate([result['xi'], result['eta'], result['energy']])))
        if result['status'] != gpu_status:
            mismatches.append(dict(id=item['id'], cpu=result['status'], gpu=gpu_status))
        if gpu_status == 1 and result['status'] == 1:
            y = result['state']
            max_position = max(max_position, abs(data[5] - y[0]) / max(1, y[0]))
            max_phi = max(max_phi, abs(math.remainder(data[6] - y[4], 2 * PI)))
            max_delay = max(max_delay, abs(data[7] - y[5]) / max(1, y[5]))
            max_mu = max(max_mu, abs(data[9] - math.cos(y[2])))
            rho, z, reference_h = surface_coordinates(y, case['diskInner'], case['diskOuter'], case['heightScale'], case['corrugation'])
            measured_h = height(data[16], data[6], case['diskInner'], case['diskOuter'], case['heightScale'], case['corrugation'])
            max_height = max(max_height, abs(data[18] - measured_h))
            nonnegative = nonnegative and reference_h >= 0 and measured_h >= 0
            # Evaluate independently at the actual GPU event coordinates to
            # separate source four-velocity/redshift errors from ray errors.
            r, theta = data[5], math.acos(max(-1, min(1, data[9])))
            gtt, gtp, _, _, gpp = metric(r, theta, case['spin'])
            omega = 1 / (data[16] ** 1.5 + case['spin'])
            norm_factor = -(gtt + 2 * omega * gtp + omega * omega * gpp)
            timelike = timelike and norm_factor > 0
            if norm_factor > 0:
                ut = 1 / math.sqrt(norm_factor)
                g = 1 / (data[2] * ut * (1 - omega * data[0]))
                max_redshift = max(max_redshift, abs(data[19] - g) / max(1e-9, abs(g)))
                max_norm_error = max(max_norm_error, abs(data[22] * data[22] * norm_factor - 1))
            if case['heightScale'] == 0:
                thin_hits += 1
            else:
                finite_hits += 1
                if rho > 0.8 * case['diskOuter']:
                    tapered += 1
                if z >= 0:
                    upper += 1
                else:
                    lower += 1
                # Selected rays independently demonstrate that the first
                # photosphere blocks a later equatorial intersection.
                if hidden_later_hits < 16 and index % 11 == 0:
                    thin_case = dict(case, heightScale=0, corrugation=0)
                    thin_result = trace_surface(thin_case)
                    if thin_result['status'] == 1 and y[5] + 1e-4 < thin_result['state'][5]:
                        hidden_later_hits += 1
                if len(convergence) < 12 and index % 37 == 0:
                    refined = trace_surface(case, tolerance=2e-13)
                    if refined['status'] == 1:
                        convergence.append(max(abs(y[j] - refined['state'][j]) / max(1, abs(y[j])) for j in (0, 2, 4, 5)))
        if index % 200 == 0:
            print(f'Reference progress {index + 1}/{len(document["cases"])} rays; {time.monotonic() - started:.1f} s', flush=True)
    check('Independent finite-radius camera constants', max_constants < 1e-5, f'max normalized xi/eta/E error {max_constants:.3g}')
    check('First opaque surface / capture / escape classification', not mismatches, f'{len(document["cases"]) - len(mismatches)}/{len(document["cases"])} rays agree; mismatches {mismatches[:8]}')
    check('First-hit positions agree with independent surface events', finite_hits > 0 and max_position < 0.002 and max_phi < 0.005 and max_mu < 0.001, f'{finite_hits} finite and {thin_hits} thin hits; max relative r {max_position:.3g}, phi {max_phi:.3g} rad, mu {max_mu:.3g}')
    check('Photosphere retarded travel times', max_delay < 0.002 and finite_hits > 0, f'max relative delay error {max_delay:.3g}')
    check('Independent surface event coverage', upper > 0 and lower > 0 and tapered > 0, f'upper {upper}, lower {lower}, tapered outer photosphere {tapered}')
    check('First photosphere self-occludes later equatorial emission', hidden_later_hits >= 4, f'{hidden_later_hits} independently integrated front-surface/later-equator ray pairs')
    check('Independent photosphere height law', nonnegative and max_height < 2e-5, f'max GPU vs binary64 surface height difference {max_height:.3g} M')
    check('Off-plane source remains timelike and normalized', timelike and max_norm_error < 3e-5, f'max independent |u.u+1| {max_norm_error:.3g}')
    check('Off-plane gravitational and Doppler frequency ratio', max_redshift < 3e-5, f'max GPU/reference g relative error {max_redshift:.3g}')
    check('Binary64 surface reference converges under tighter tolerance', len(convergence) >= 4 and max(convergence) < 1e-7, f'{len(convergence)} finite hits; max normalized coordinate/delay change {max(convergence, default=1):.3g}')
    return dict(checks=checks, references=references, mismatches=mismatches, runtimeSeconds=time.monotonic() - started)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gpu', type=Path, default=ROOT / 'outputs/thickness-gpu-validation.json')
    parser.add_argument('--report', type=Path, default=ROOT / 'outputs/thickness-validation.md')
    args = parser.parse_args()
    result = compare(json.loads(args.gpu.read_text()))
    checks = result['checks']
    failures = sum(not item['passed'] for item in checks)
    lines = ['# Finite photosphere validation', '', f'{len(checks) - failures}/{len(checks)} independent binary64/GPU comparisons passed.', '', '| Check | Result | Evidence |', '|---|---|---|']
    lines += [f'| {item["name"]} | {"PASS" if item["passed"] else "FAIL"} | {item["detail"].replace("|", "/")} |' for item in checks]
    lines += ['', '## Scope', '', 'The independent reference propagates Kerr null geodesics in binary64 Boyer–Lindquist radius and polar angle, then locates bracketed upper, lower, and radial-boundary surface crossings by separate bisection. The first valid opaque event wins. The GPU evolves reciprocal radius and cosine of polar angle. Camera inputs are rounded to the actual Float ABI before the independent reference starts.', '', 'The photosphere and its off-equatorial circular rotation are prescribed approximations, not a solved vertical atmosphere or GRMHD flow. A normalized timelike circular velocity above the equatorial plane is generally accelerated, not a circular geodesic. Optional corrugation is stationary artistic geometry. The outer 20% of the finite annulus uses a prescribed C2 quintic closure; it is not a prediction of disk-atmosphere equations. These selected rays provide regression evidence; they do not prove global intersection accuracy, convergence of all high-order images, or physically consistent plasma dynamics.', '', 'Edge antialiasing is a separate image-sampling test, not an alteration of these null geodesics. The GPU report compares actual sparse 16-ray edge coverage with a denser 64-ray stratified reference and tests overflow fallback.', '', 'Physical-model context: [Zhou et al. (2020), Thermal spectra of thin accretion disks of finite thickness around Kerr black holes](https://arxiv.org/abs/2004.12589).', '', f'Reference runtime: {result["runtimeSeconds"]:.1f} seconds.', '']
    args.report.write_text('\n'.join(lines))
    (ROOT / 'work/thickness-reference.json').write_text(json.dumps(result, indent=2) + '\n')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
