# Introduction

A script for checking the TPS capabalities of a ETH based blockchain network.

The script work as described below:

1. Encode all transaction. This time is not taken into account.
3. Start monitoring (on background) when the last transactions per wallet will be mined. Then calculates the TPS.
4. Submit all encoded transaction to the network.

# Config

Prepare `./config/.env` based on `./config/.env.example` (the loader reads from
`config/`, not the script's working directory). It contains the following variables:
1. **RPC_URLS:** Comma separated JSON_RPCs of the network. These endpoints are used for RLP encoding.</em>
1. **PRIVATE_KEYS:** Wallets for signed the transactions. The first wallet must have enough funds. The rest are funded automatically</em>
1. **NUM_TRANSACTIONS:** Number of transactions that are sent to the network.</em>
1. **CHAIN_ID:** The chain-id.</em>

# Requirements

The script uses NodeJS 22+

# Usage

Run the script

```bash
./check-tps.sh
```
