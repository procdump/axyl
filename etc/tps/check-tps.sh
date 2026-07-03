#!/bin/bash

directory=$(dirname "${BASH_SOURCE[0]}")
scriptDir=$(cd "$directory" && pwd)
nodeModulesPath="$scriptDir/node_modules"
if [[ ! -x "$(command -v npm)" ]]; then
    echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} NodeJS 22+ is required";
    exit 1;
fi

if [[ ! -e "$nodeModulesPath" ]]; then
    cd "$scriptDir" && npm i &> /dev/null
fi

node "$scriptDir/src/main.mjs"
