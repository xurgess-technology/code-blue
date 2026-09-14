#!/bin/sh
# Rebuild every variation (full bake), four threads each, in parallel. Logs in ../logs/.
B="/c/Program Files/Blender Foundation/Blender 5.2/blender.exe"
cd "$(dirname "$0")"
for v in ${VARIANTS:-surgeon_a surgeon_b surgeon_c bob paramedic_a paramedic_b}; do
  "$B" --background --factory-startup -t ${THREADS:-4} --python hu_build.py -- --variant=$v --tex=${TEX:-2048} --ao-samples=${AO:-24} > ../logs/build_$v.log 2>&1 &
done
wait
echo all built
