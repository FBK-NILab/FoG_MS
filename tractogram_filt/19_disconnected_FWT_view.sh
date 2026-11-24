#!/bin/bash
# =============================================================================
# 19_disconnected_FWT_view.sh
# PURPOSE: For each KUL_FWT bundle involved by the new lesion (% disconnected > 0) opens
#          mrview with the original bundle (blue, semi-transparent),
#          its disconnected part (magenta) and the new lesion (red), takes sagittal,
#          coronal and axial screenshots centred on the disconnected part and puts them
#          side by side in a single image with the bundle name and percentage.
# INPUT:   $TRACTO_DIR/atlas_FWT_disconnection/FWT_bundle_disconnection.csv, tck_disconnected/
#          $FWT_ATLAS_DIR/*.tck, $CLUSTERS_DIFF
# OUTPUT:  $TRACTO_DIR/atlas_FWT_disconnection/screenshots/<NN>_<bundle>.png
# REQUIRES: MRtrix3 (mrview, needs a display), FSL, Python environment with Pillow (activated).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

########### PATHS ###########
res_dir="$TRACTO_DIR/atlas_FWT_disconnection"
csv="$res_dir/FWT_bundle_disconnection.csv"
lesion_bin="$res_dir/lesione_diff_bin.nii.gz"
out_dir="$res_dir/screenshots"

########### APPEARANCE (editable) ###########
win_size="800,800"     # size of each view (pixels)
overlay_cmap=1         # "Hot" colormap: with intensity 0-3 the lesion (value 1) appears RED
disc_thickness=0.5     # thickness of the disconnected bundle (scale -1 to 1; 0 = normal)
orig_thickness=-0.3    # thickness of the original bundle
orig_opacity=0.25      # opacity of the original bundle (lower = magenta more visible)

########### TEST ###########
max_bundles=0          # 0 = all bundles; 1 = first bundle only (quick test)

[ -f "$csv" ] || { echo "[ERROR] $csv not found (run script 20 first)"; exit 1; }
mkdir -p "$out_dir"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# Binary lesion mask (created once)
[[ -f "$lesion_bin" ]] || fslmaths "$CLUSTERS_DIFF" -bin "$lesion_bin"

# Bundles with at least one disconnected streamline, from the most to the least affected
tail -n +2 "$csv" | awk -F, '$3 > 0' | sort -t, -k4 -gr > "$tmp_dir/bundles.csv"
if (( max_bundles > 0 )); then
    head -n "$max_bundles" "$tmp_dir/bundles.csv" > "$tmp_dir/bundles_tmp.csv"
    mv "$tmp_dir/bundles_tmp.csv" "$tmp_dir/bundles.csv"
fi
n=$(wc -l < "$tmp_dir/bundles.csv")
echo "Bundles to show: $n"

i=0
while IFS=, read -r bundle n_tot n_dis perc; do
    i=$((i + 1))
    orig="$FWT_ATLAS_DIR/${bundle}.tck"
    disc="$res_dir/tck_disconnected/${bundle}_disconnected.tck"
    echo "[$i/$n] $bundle ($perc%)"

    # View centre = centre of gravity of the disconnected part (mm, MNI coordinates)
    tckmap -quiet -force -template "$MNI" "$disc" "$tmp_dir/disc_tdi.nii.gz"
    focus=$(fslstats "$tmp_dir/disc_tdi.nii.gz" -c | awk '{printf "%.1f,%.1f,%.1f", $1, $2, $3}')

    # 3 screenshots: 0 = sagittal, 1 = coronal, 2 = axial
    for plane in 0 1 2; do
        mrview "$MNI" \
            -mode 1 -plane "$plane" -focus "$focus" -size "$win_size" -colourbar false \
            -tractography.load "$disc" \
                -tractography.colour 1,0,1 \
                -tractography.thickness "$disc_thickness" \
                -tractography.opacity 1 \
                -tractography.lighting true \
                -tractography.slab 0 \
            -tractography.load "$orig" \
                -tractography.colour 0,0,1 \
                -tractography.thickness "$orig_thickness" \
                -tractography.opacity "$orig_opacity" \
                -tractography.lighting false \
                -tractography.slab 0 \
            -overlay.load "$lesion_bin" \
                -overlay.colourmap "$overlay_cmap" \
                -overlay.intensity 0,3 \
                -overlay.interpolation false \
                -overlay.threshold_min 0.5 \
                -overlay.opacity 1 \
            -capture.folder "$tmp_dir" \
            -capture.prefix "plane${plane}_" \
            -capture.grab \
            -exit < /dev/null
    done

    # The 3 views side by side on one row, with a title
    p0=$(first_match "$tmp_dir"/plane0_*.png)
    p1=$(first_match "$tmp_dir"/plane1_*.png)
    p2=$(first_match "$tmp_dir"/plane2_*.png)
    out_png="$out_dir/$(printf '%02d' "$i")_${bundle}.png"

    python - "$p0" "$p1" "$p2" "$out_png" "${bundle}   -   ${perc}% disconnected (${n_dis}/${n_tot})" <<'EOF'
import sys
from PIL import Image, ImageDraw, ImageFont

imgs = [Image.open(p).convert("RGB") for p in sys.argv[1:4]]
out_png, title = sys.argv[4], sys.argv[5]

font = None
for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
             "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"):
    try:
        font = ImageFont.truetype(path, 28)
        break
    except OSError:
        pass
if font is None:
    try:
        font = ImageFont.load_default(size=28)
    except TypeError:
        font = ImageFont.load_default()

bar = 50
w = sum(im.width for im in imgs)
h = max(im.height for im in imgs) + bar
out = Image.new("RGB", (w, h), "black")
x = 0
for im in imgs:
    out.paste(im, (x, bar))
    x += im.width
draw = ImageDraw.Draw(out)
tw = draw.textlength(title, font=font)
draw.text(((w - tw) / 2, 10), title, fill="white", font=font)
out.save(out_png)
EOF

    rm -f "$tmp_dir"/plane*_*.png
done < "$tmp_dir/bundles.csv"

echo "Done. Images in: $out_dir"

# REFERENCES
# [MRtrix3] Tournier JD, Smith R, Raffelt D, et al. MRtrix3: A fast, flexible and open software framework for medical
#       image processing and visualisation. NeuroImage. 2019;202:116137. doi:10.1016/j.neuroimage.2019.116137
# [KUL_FWT atlas] Radwan AM, Sunaert S, Schilling K, et al. An atlas of white matter anatomy, its variability, and
#       reproducibility based on constrained spherical deconvolution of diffusion MRI. NeuroImage. 2022;254:119029.
#       doi:10.1016/j.neuroimage.2022.119029
