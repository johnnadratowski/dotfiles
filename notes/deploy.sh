#!/bin/bash
set -e
__outdir="${OUTDIR:-public}"
aws s3 sync ./$__outdir/docs s3://unified-engineering/hosted-docs/
