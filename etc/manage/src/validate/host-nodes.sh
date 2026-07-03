#!/bin/bash -i

function validateHostNodes() {
    echo -ne "Validating hosts...";

    local computersSize=$(getComputersSize)
    for i in $(seq 0 $(($computersSize-1)))
    do
        executeOnNodeClient $i exit
        if [ "$?" != 0 ]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Unable to establish SSH connection to computer[$i]";
            exit 1;
        fi

        local opResult=$(executeOnNodeClient $i "sudo -n true")
        if [ "$opResult" != "" ]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have sudo access without password";
            exit 1;
        fi

        opResult=$(executeOnNodeClient $i "if [ ! -x \"\$(command -v docker)\" ]; then echo '1'; fi;")
        if [ "$opResult" == "1" ]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have docker installed";
            exit 1;
        fi
    done

    echo -e "${STYLE_GREEN}OK${STYLE_DEFAULT}";
}
