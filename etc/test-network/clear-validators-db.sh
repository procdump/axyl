#!/bin/bash

for ((i=1; i<=4; i++)); do
    rm -rf "./local-validators/validator-$i/db"
    rm -rf "./local-validators/validator-$i/consensus-db"
    rm -rf "./local-validators/validator-$i/static_files"
done
