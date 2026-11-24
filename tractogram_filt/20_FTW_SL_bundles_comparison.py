#!/usr/bin/env python3
"""
22b_FTW_SL_bundles_comparison.py

PURPOSE: Compares EVERY centroid of the (pruned) group tractogram (scripts 17/17b) with
         the bundles of the KUL_FWT atlas using the minimum average direct-flip (MDF)
         distance, assigns each centroid to its nearest bundle (if within --assign-thr)
         and summarises, for each bundle, the share of the group weight assigned to it.

Two ways of representing the atlas bundles (--atlas-mode):
  all        (default) every single streamline of the atlas
  centroids  the QuickBundles centroids of each bundle (threshold --atlas-qb-thr)

Input:
  --group-tck   group tractogram (e.g. group_tck_clust_nsub377.tck)
  --group-csv   its summary (same order): cluster_index, weight_streamlines, weight_norm, n_subjects
  --atlas-dir   folder with the .tck files of the FWT bundles

Output (in --out-dir):
  centroid_assignment.csv   per centroid: weights, nearest bundle and distance, second bundle,
                            bundles within threshold, assigned yes/no
  bundle_summary.csv        per bundle: n. of assigned centroids, sum of weight_norm, % of the total
  tck_by_bundle/            centroids assigned to each bundle (+ unassigned.tck)
  [--atlas-mode all only]
  bundle_coverage.csv       per bundle: % of its streamlines with at least one centroid within threshold
                            ("how much of the bundle has the shape of a disconnected pathway")
  centroid_x_bundle.csv     per centroid-bundle pair (values > 0 only): % of the bundle
                            streamlines within threshold of that centroid
  atlas_covered/<bundle>_covered.tck   the FWT bundle streamlines "covered" by the centroids
                            (exactly those counted in bundle_coverage.csv)

Usage:
  python 22b_FTW_SL_bundles_comparison.py \
      --group-tck .../group_tck_clust_nsub377.tck \
      --group-csv .../group_tck_clust_nsub377_summary.csv \
      --atlas-dir /path/to/KUL_FWT/KUL_FWT_templates/TCK_models \
      --out-dir .../FWT_all_streamlines_15 \
      [--atlas-mode all|centroids] [--assign-thr 15] [--atlas-qb-thr 10]

REFERENCES
[MDF distance, QuickBundles] Garyfallidis E, Brett M, Correia MM, Williams GB, Nimmo-Smith I. QuickBundles, a method
      for tractography simplification. Front Neurosci. 2012;6:175. doi:10.3389/fnins.2012.00175
[DIPY] Garyfallidis E, Brett M, Amirbekian B, et al. Dipy, a library for the analysis of diffusion MRI data.
      Front Neuroinform. 2014;8:8. doi:10.3389/fninf.2014.00008
[KUL_FWT atlas] Radwan AM, Sunaert S, Schilling K, et al. An atlas of white matter anatomy, its variability, and
      reproducibility based on constrained spherical deconvolution of diffusion MRI. NeuroImage. 2022;254:119029.
      doi:10.1016/j.neuroimage.2022.119029
"""

import argparse
import glob
import os
import sys
import time

import numpy as np
import nibabel as nib
from nibabel.streamlines import Tractogram
from dipy.segment.clustering import QuickBundles
from dipy.tracking.distances import bundles_distances_mdf
from dipy.tracking.streamline import set_number_of_points


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--group-tck", required=True)
    p.add_argument("--group-csv", required=True)
    p.add_argument("--atlas-dir", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--atlas-mode", choices=["all", "centroids"], default="all")
    p.add_argument("--atlas-qb-thr", type=float, default=10.0)
    p.add_argument("--assign-thr", type=float, default=15.0)
    p.add_argument("--npoints", type=int, default=12)
    return p.parse_args()


def resample(streamlines, npoints):
    return [s.astype(np.float32) for s in set_number_of_points(list(streamlines), npoints)]


def main():
    a = parse_args()
    t0 = time.time()
    os.makedirs(os.path.join(a.out_dir, "tck_by_bundle"), exist_ok=True)
    if a.atlas_mode == "all":
        os.makedirs(os.path.join(a.out_dir, "atlas_covered"), exist_ok=True)

    # Group tractogram + weights
    g_sl = nib.streamlines.load(a.group_tck).streamlines
    tab = np.genfromtxt(a.group_csv, delimiter=",", names=True)
    cols = tab.dtype.names
    if len(tab) != len(g_sl):
        sys.exit(f"ERROR: {len(g_sl)} centroids but {len(tab)} rows in the CSV")
    cid, w_sl, w_n, n_sub = (tab[c] for c in cols[:4])
    g_res = resample(g_sl, a.npoints)
    ng = len(g_res)

    files = sorted(glob.glob(os.path.join(a.atlas_dir, "*.tck")))
    if not files:
        sys.exit(f"ERROR: no .tck in {a.atlas_dir}")
    short = [os.path.basename(f)[:-4].replace("_GN_symmetrical", "") for f in files]
    nb = len(files)
    print(f"Group centroids: {ng}  -  FWT bundles: {nb}  -  atlas mode: {a.atlas_mode}")

    dmin = np.full((ng, nb), np.inf, dtype=np.float32)
    coverage = []        # (bundle, n streamlines, n covered, %)
    pair_rows = []       # (cluster_index, bundle, % of the bundle within threshold)

    for b, f in enumerate(files):
        sl = nib.streamlines.load(f).streamlines
        if len(sl) == 0:
            coverage.append((short[b], 0, 0, float("nan")))
            continue
        ref = resample(sl, a.npoints)
        if a.atlas_mode == "centroids":
            ref = [np.asarray(c, dtype=np.float32)
                   for c in QuickBundles(threshold=a.atlas_qb_thr).cluster(ref).centroids]

        D = bundles_distances_mdf(g_res, ref)            # (group centroids x bundle streamlines/centroids)
        dmin[:, b] = D.min(axis=1)

        if a.atlas_mode == "all":
            close = D <= a.assign_thr                    # boolean
            covered = close.any(axis=0)                  # bundle streamlines with at least one close centroid
            coverage.append((short[b], len(ref), int(covered.sum()), 100 * covered.mean()))
            # Save the "covered" bundle streamlines (those counted in bundle_coverage.csv)
            if covered.any():
                nib.streamlines.save(
                    Tractogram([sl[j] for j in np.flatnonzero(covered)], affine_to_rasmm=np.eye(4)),
                    os.path.join(a.out_dir, "atlas_covered", f"{short[b]}_covered.tck"))
            frac_per_centroid = 100 * close.mean(axis=1)
            for i in np.flatnonzero(frac_per_centroid > 0):
                pair_rows.append((int(cid[i]), short[b], frac_per_centroid[i]))

        print(f"  {short[b]}: {len(sl)} streamlines ({time.time() - t0:.0f} s)")

    # Assignment to the nearest bundle
    order = np.argsort(dmin, axis=1)
    first, second = order[:, 0], order[:, 1]
    d1 = dmin[np.arange(ng), first]
    d2 = dmin[np.arange(ng), second]
    assigned = d1 <= a.assign_thr

    with open(os.path.join(a.out_dir, "centroid_assignment.csv"), "w") as fh:
        fh.write("cluster_index,weight_streamlines,weight_norm,n_subjects,"
                 "nearest_bundle,nearest_dist_mm,second_bundle,second_dist_mm,"
                 "bundles_within_thr,assigned\n")
        for i in range(ng):
            within = ";".join(short[b] for b in np.flatnonzero(dmin[i] <= a.assign_thr))
            fh.write(f"{int(cid[i])},{int(w_sl[i])},{w_n[i]:.6f},{int(n_sub[i])},"
                     f"{short[first[i]]},{d1[i]:.2f},{short[second[i]]},{d2[i]:.2f},"
                     f"{within},{'yes' if assigned[i] else 'no'}\n")

    tot = w_n.sum()
    rows = []
    for b in range(nb):
        idx = np.flatnonzero(assigned & (first == b))
        if idx.size:
            nib.streamlines.save(Tractogram([g_sl[i] for i in idx], affine_to_rasmm=np.eye(4)),
                                 os.path.join(a.out_dir, "tck_by_bundle", f"{short[b]}.tck"))
            np.savetxt(os.path.join(a.out_dir, "tck_by_bundle", f"{short[b]}_weights_norm.txt"),
                       w_n[idx], fmt="%.6f")
        rows.append((short[b], idx.size, w_n[idx].sum(), 100 * w_n[idx].sum() / tot))
    idx = np.flatnonzero(~assigned)
    if idx.size:
        nib.streamlines.save(Tractogram([g_sl[i] for i in idx], affine_to_rasmm=np.eye(4)),
                             os.path.join(a.out_dir, "tck_by_bundle", "unassigned.tck"))
        np.savetxt(os.path.join(a.out_dir, "tck_by_bundle", "unassigned_weights_norm.txt"),
                   w_n[idx], fmt="%.6f")
    rows.sort(key=lambda r: -r[2])
    rows.append(("unassigned", idx.size, w_n[idx].sum(), 100 * w_n[idx].sum() / tot))
    with open(os.path.join(a.out_dir, "bundle_summary.csv"), "w") as fh:
        fh.write("bundle,n_centroids,weight_norm_sum,percent_of_total\n")
        for r in rows:
            fh.write(f"{r[0]},{r[1]},{r[2]:.4f},{r[3]:.2f}\n")

    if a.atlas_mode == "all":
        coverage.sort(key=lambda r: -(r[3] if r[3] == r[3] else -1))
        with open(os.path.join(a.out_dir, "bundle_coverage.csv"), "w") as fh:
            fh.write("bundle,n_streamlines,n_covered,percent_covered\n")
            for r in coverage:
                fh.write(f"{r[0]},{r[1]},{r[2]},{r[3]:.2f}\n")
        pair_rows.sort(key=lambda r: (r[0], -r[2]))
        with open(os.path.join(a.out_dir, "centroid_x_bundle.csv"), "w") as fh:
            fh.write("cluster_index,bundle,percent_of_bundle_within_thr\n")
            for r in pair_rows:
                fh.write(f"{r[0]},{r[1]},{r[2]:.3f}\n")
        print("Most covered bundles:")
        for r in coverage[:10]:
            print(f"  {r[0]:<20} {r[3]:6.2f}%  ({r[2]}/{r[1]})")

    print(f"Assigned: {assigned.sum()} centroids of {ng} "
          f"({100 * w_n[assigned].sum() / tot:.1f}% of the weight)")
    print(f"Done in {time.time() - t0:.0f} s. Results in {a.out_dir}")


if __name__ == "__main__":
    main()
