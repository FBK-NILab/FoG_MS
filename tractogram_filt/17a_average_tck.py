#!/usr/bin/env python3
"""
17a_average_tck.py

PURPOSE: Merges the bundle centroids of all subjects (sub-*_tck_clust.tck, script 16)
         and re-clusters them with QuickBundles into a single group tractogram, keeping
         track of how many streamlines and subjects each group cluster represents.
         Called by 17_wm_hubs_average.sh.

Usage:
    python 17a_average_tck.py <tck_folder> <out_tck> [threshold_mm]

Output (next to <out_tck>):
    <out>.tck                  group centroids
    <out>_weights.txt          number of original streamlines represented by each group cluster
    <out>_weights_norm.txt     sum of the per-subject normalised weights (each subject weighs 1 in total)
    <out>_nsubjects.txt        number of subjects contributing to each group cluster
    <out>_summary.csv          the three columns above together

REFERENCES
[QuickBundles] Garyfallidis E, Brett M, Correia MM, Williams GB, Nimmo-Smith I. QuickBundles, a method for
      tractography simplification. Front Neurosci. 2012;6:175. doi:10.3389/fnins.2012.00175
[DIPY] Garyfallidis E, Brett M, Amirbekian B, et al. Dipy, a library for the analysis of diffusion MRI data.
      Front Neuroinform. 2014;8:8. doi:10.3389/fninf.2014.00008
"""

import os
import sys
import glob
import time
import warnings

import numpy as np
import nibabel as nib
from nibabel.streamlines import Tractogram
from dipy.segment.clustering import QuickBundles


def main():
    tck_folder, out_tck = sys.argv[1], sys.argv[2]
    threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0

    files = sorted(glob.glob(os.path.join(tck_folder, "sub-*", "sub-*_tck_clust.tck")))
    if not files:
        sys.exit(f"ERROR: no *_tck_clust.tck found in {tck_folder}/sub-*/")

    t0 = time.time()
    all_sl, w_raw, w_norm, subj = [], [], [], []
    n_used = 0

    # 1. Load centroids and weights of each subject
    for i, f in enumerate(files):
        wf = f.replace(".tck", "_weights.txt")
        if not os.path.isfile(wf):
            sys.exit(f"ERROR: weights file missing: {wf}")

        sls = nib.streamlines.load(f).streamlines
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")          # empty weights file -> empty array
            w = np.loadtxt(wf)

        if len(sls) == 0 or w.size == 0:
            continue
        if len(sls) != w.size:
            sys.exit(f"ERROR: {os.path.basename(f)} has {len(sls)} centroids but {w.size} weights")

        all_sl.extend(sls)
        w_raw.append(w)
        w_norm.append(w / w.sum())                   # each subject weighs 1 in total
        subj.append(np.full(w.size, i))
        n_used += 1

    w_raw = np.concatenate(w_raw)
    w_norm = np.concatenate(w_norm)
    subj = np.concatenate(subj)
    print(f"Subjects used: {n_used}  -  total centroids: {len(all_sl)}")

    # 2. Re-cluster all the centroids together
    clusters = QuickBundles(threshold=threshold).cluster(all_sl)

    # 3. Group weights of each cluster
    g_raw, g_norm, g_nsub = [], [], []
    for c in clusters:
        idx = np.asarray(c.indices)
        g_raw.append(w_raw[idx].sum())
        g_norm.append(w_norm[idx].sum())
        g_nsub.append(np.unique(subj[idx]).size)

    # 4. Save
    nib.streamlines.save(Tractogram(clusters.centroids, affine_to_rasmm=np.eye(4)), out_tck)
    base = out_tck[:-4] if out_tck.endswith(".tck") else out_tck
    np.savetxt(base + "_weights.txt", g_raw, fmt="%d")
    np.savetxt(base + "_weights_norm.txt", g_norm, fmt="%.6f")
    np.savetxt(base + "_nsubjects.txt", g_nsub, fmt="%d")
    np.savetxt(base + "_summary.csv",
               np.column_stack([np.arange(len(g_raw)), g_raw, g_norm, g_nsub]),
               fmt=["%d", "%d", "%.6f", "%d"], delimiter=",",
               header="cluster,weight_streamlines,weight_norm,n_subjects", comments="")

    print(f"{len(all_sl)} centroids -> {len(clusters)} group clusters "
          f"({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
