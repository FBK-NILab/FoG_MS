#!/usr/bin/env python3
"""
16a_cluster_tck.py

PURPOSE: Clusters the streamlines of a tractogram with QuickBundles and saves the
         cluster centroids (one streamline per bundle) and the number of streamlines
         represented by each centroid. Called by 16_wm_hubs.sh.

Usage:
    python 16a_cluster_tck.py <in_tck> <out_tck> <reference_nifti> [threshold_mm]

Output:
    <out_tck>                 cluster centroids
    <out>_weights.txt         number of streamlines in each cluster (same order)

REFERENCES
[QuickBundles] Garyfallidis E, Brett M, Correia MM, Williams GB, Nimmo-Smith I. QuickBundles, a method for
      tractography simplification. Front Neurosci. 2012;6:175. doi:10.3389/fnins.2012.00175
[DIPY] Garyfallidis E, Brett M, Amirbekian B, et al. Dipy, a library for the analysis of diffusion MRI data.
      Front Neuroinform. 2014;8:8. doi:10.3389/fninf.2014.00008
"""
import os
import sys
import time

import numpy as np
from dipy.io.streamline import load_tck, save_tck
from dipy.io.stateful_tractogram import Space, StatefulTractogram
from dipy.segment.clustering import QuickBundles


def main():
    in_tck, out_tck, reference = sys.argv[1], sys.argv[2], sys.argv[3]
    threshold = float(sys.argv[4]) if len(sys.argv) > 4 else 20.0

    for f in (in_tck, reference):
        if not os.path.isfile(f):
            sys.exit(f"ERROR: file not found: {f}")

    t0 = time.time()
    data = load_tck(in_tck, reference, bbox_valid_check=False)
    clusters = QuickBundles(threshold=threshold).cluster(data.streamlines)

    # Centroids saved as a tractogram; weights = cluster sizes
    trac = StatefulTractogram(clusters.centroids, reference=reference, space=Space.RASMM)
    save_tck(trac, out_tck, bbox_valid_check=False)
    np.savetxt(out_tck.replace('.tck', '_weights.txt'), clusters.clusters_sizes(), fmt='%d')

    print(f"{len(data.streamlines)} streamlines -> {len(clusters)} clusters "
          f"({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
