#!/bin/bash
set -e

__style=${STYLE:-readthedocs}
__outdir="${OUTDIR:-public}"

if (( $# == 0 )); then
    __docs=$(find ./notes ./docs -name "*.adoc" -print)
else
    __docs=()
    for __doc in ${@}; do
        if [[ ${__doc: -5} != ".adoc" ]]; then
            continue
        fi
        # Ensure these are using relative paths
        __docs+=($(realpath --relative-to="." $__doc))
    done
fi

if (( ${#__docs} == 0 )); then
    echo "No adoc files were passed to the build command. Skipping."
    exit 0
fi

if [[ ! -e $__outdir ]]; then
    mkdir $__outdir
fi

rsync -t -r ./docinfo $__outdir

__pids=()
for __doc in $__docs; do
    echo "Building: $__doc"
    __filedir=$(dirname $__doc)
    __filename=$(basename $__doc)
    
    mkdir -p $__outdir/$__filedir
    
    rsync -t styles/${__style}.css $__outdir/$__filedir
    
    rsync -t -r $__filedir/* $__outdir/$__filedir
    
    asciidoctor -a stylesheet=${__style}.css -r asciidoctor-diagram -r ./macros/macros.rb $__outdir/$__doc &
    __pids+=($!)
    if [[ "${PDF:-false}" == "true" ]]; then
        asciidoctor-pdf -a stylesheet=${__style}.css -r asciidoctor-diagram -r ./macros/macros.rb $__outdir/$__doc &
        __pids+=($!)
    fi
done

for __pid in ${__pids[@]}; do
    wait $__pid
    __ret=$?

    if (( $__ret != 0 )); then
        echo "Build Failed"
        exit $__ret
    fi
done

echo "Build Output:"
for __doc in $__docs; do
    echo "$__outdir/${__doc}.html" | sed "s/\.\///g"
    if [[ "${PDF:-false}" == "true" ]]; then
        echo "$__outdir/${__doc}.pdf" | sed "s/\.\///g"
    fi
done
echo "Completed @ $(date)"