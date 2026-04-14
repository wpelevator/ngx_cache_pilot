#!/bin/sh

# Search in the script folder
cd "$(dirname "$0")" || exit 1
CWD="$(pwd -P)"
cd "$CWD" || exit 1
FILES='ngx_cache_purge_module.c'

# The file format in accordance with the style defined in .astylerc
astyle -v --options='.astylerc' ${FILES} || (echo 'astyle failed'; exit 1);

# To correct this, the issuance dos2unix on each file
# sometimes adds in Windows as a string-endins (\r\n).
dos2unix --quiet ${FILES} || (echo 'dos2unix failed'; exit 2);