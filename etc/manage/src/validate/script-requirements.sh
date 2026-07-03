#!/bin/bash -i

function validateScriptRequirements() {
    echo -ne "Validating script requirements...";

    if [[ ! -x "$(command -v jq)" ]]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The host does not have jq installed";
        exit 1;
    fi

    if [[ ! -x "$(command -v python3)" ]]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The host does not have python3 installed";
        exit 1;
    fi

    if [[ "$USE_CACHE" == "" ]]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The param USE_CACHE must not be empty";
        exit 1
    fi

    if [[ "$UPGRADE_ONLY" == "" ]]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The param UPGRADE_ONLY must not be empty";
        exit 1
    fi

    if [[ "$RAYLS_NETWORK" == "" ]]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The param RAYLS_NETWORK must not be empty";
        exit 1
    fi

    if [[ ! -f "$SCRIPT_DIR/config/topology.json" ]]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The $WORKING_DIR/config/topology.json file is missing";
        exit 1
    fi

    echo -e "${STYLE_GREEN}OK${STYLE_DEFAULT}";
}
