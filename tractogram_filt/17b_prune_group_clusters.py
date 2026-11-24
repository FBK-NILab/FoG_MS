#!/usr/bin/env python3
"""
17b_prune_group_clusters.py

PURPOSE: Keeps only the "representative" clusters of the group tractogram (script 17),
         i.e. those present in at least <min_n_subjects> subjects and, optionally, with
         a normalised weight of at least <min_weight_norm>.

Usage:
    python 17b_prune_group_clusters.py <group_tck> <summary_csv> <out_tck> <min_n_subjects> [min_weight_norm]

Example (clusters present in at least 377 subjects, i.e. 50%):
    python 17b_prune_group_clusters.py group_tck_clust.tck group_tck_clust_summary.csv \
           group_tck_clust_nsub377.tck 377

Output (next to <out_tck>):
    <out>.tck                 kept centroids only
    <out>_weights.txt         weight_streamlines of the kept clusters
    <out>_weights_norm.txt    weight_norm of the kept clusters
    <out>_nsubjects.txt       n_subjects of the kept clusters
    <out>_summary.csv         rows of the original CSV for the kept clusters

REFERENCES
[NiBabel] Brett M, Markiewicz CJ, Hanke M, et al. nipy/nibabel. Zenodo. doi:10.5281/zenodo.591597
"""

import os
import sys

import numpy as np
import nibabel as nib
from nibabel.streamlines import Tractogram


def main():
    group_tck, summary_csv, out_tck = sys.argv[1], sys.argv[2], sys.argv[3]
    min_nsub = int(sys.argv[4])
    min_wnorm = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0

    for f in (group_tck, summary_csv):
        if not os.path.isfile(f):
            sys.exit(f"ERROR: file not found: {f}")

    streamlines = nib.streamlines.load(group_tck).streamlines
    tab = np.genfromtxt(summary_csv, delimiter=",", names=True)
    names = tab.dtype.names            # cluster(_index), weight_streamlines, weight_norm, n_subjects

    if len(tab) != len(streamlines):
        sys.exit(f"ERROR: {len(streamlines)} centroids but {len(tab)} rows in the CSV")

    w = tab[names[1]]
    wn = tab[names[2]]
    ns = tab[names[3]]

    keep = (ns >= min_nsub) & (wn >= min_wnorm)
    idx = np.flatnonzero(keep)
    if idx.size == 0:
        sys.exit("ERROR: no cluster passes the thresholds")

    kept = [streamlines[i] for i in idx]
    nib.streamlines.save(Tractogram(kept, affine_to_rasmm=np.eye(4)), out_tck)

    base = out_tck[:-4] if out_tck.endswith(".tck") else out_tck
    np.savetxt(base + "_weights.txt", w[idx], fmt="%d")
    np.savetxt(base + "_weights_norm.txt", wn[idx], fmt="%.6f")
    np.savetxt(base + "_nsubjects.txt", ns[idx], fmt="%d")
    np.savetxt(base + "_summary.csv",
               np.column_stack([tab[names[0]][idx], w[idx], wn[idx], ns[idx]]),
               fmt=["%d", "%d", "%.6f", "%d"], delimiter=",",
               header=",".join(names), comments="")

    print(f"Thresholds: n_subjects >= {min_nsub}, weight_norm >= {min_wnorm}")
    print(f"Clusters kept: {idx.size} of {len(streamlines)}")
    print(f"Streamlines represented: {w[idx].sum():.0f} of {w.sum():.0f} "
          f"({100 * w[idx].sum() / w.sum():.1f}%)")
    print(f"weight_norm kept: {wn[idx].sum():.2f} of {wn.sum():.2f}")


if __name__ == "__main__":
    main()
