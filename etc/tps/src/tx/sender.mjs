import { Utils } from '../utils/utils.mjs';

export class TxSender {

    constructor(config, blockchainUtils) {
        this.config = config;
        this.blockchainUtils = blockchainUtils;
    }

    async sendEncodedTxInBatches(encodedTxs) {
        const BATCH_SIZE = 4096;
        const sendRawBatchPromises = [];
        let batchArray = [];
        let txHashes = new Array(this.config.numTxs).fill('');
        let txIndices = Array.from({length: this.config.numTxs}, (_, i) => i);

        for (; txIndices.length > 0;) {
            console.log(`Sending ${txIndices.length} transactions...`);
            for (let i = 0, walletManagerIndex = 0; i < txIndices.length; ++i) {
                const txIndex = txIndices[i];
                const jsonPayload = {
                    jsonrpc: "2.0",
                    method: "eth_sendRawTransaction",
                    params: [encodedTxs[txIndex]],
                    id: i,
                };

                batchArray.push(jsonPayload);

                const isBatchFull = batchArray.length === BATCH_SIZE;
                const isThisLast = i + 1 === txIndices.length;
                let isNextTxFromNextWalletManager = false;
                if (isThisLast === false) {
                    const nextTxIndex = txIndices[i + 1];
                    const nextTxWalletManagerIndex = Math.floor(nextTxIndex / this.blockchainUtils.walletManagerChunkSize);
                    isNextTxFromNextWalletManager = walletManagerIndex !== nextTxWalletManagerIndex;
                }

                if (isBatchFull || isThisLast || isNextTxFromNextWalletManager) {
                    sendRawBatchPromises.push(this.sendRawBatch(batchArray, this.blockchainUtils.getRpcUrlByWalletManager(walletManagerIndex)));
                    batchArray = [];

                    if (isNextTxFromNextWalletManager === true) {
                        walletManagerIndex++;
                    }
                }
            }

            const localTxHashesByBatches = await Promise.all(sendRawBatchPromises);
            const localTxHashes = localTxHashesByBatches.flat();

            const localTxIndices = [];
            for (let i = 0; i < txIndices.length; ++i) {
                const txIndex = txIndices[i];
                const txHash = localTxHashes[i];
                if (txHash === null || txHash == undefined || txHash.slice(0, 2) !== '0x') {
                    localTxIndices.push(txIndex);
                    continue;
                }

                txHashes[txIndex] = txHash;
            }

            txIndices = localTxIndices;

            if (txIndices.length > 0) {
                console.log(`Sending ${txIndices.length} transactions failed, retrying...`);
            }
        }

        console.log("--------------------------------------------------------");

        txHashes.forEach((txHash, i) => {
            if (txHash === '') {
                throw new Error(`A tx at ${i}-th index does not hash`);
            }
        })

        return txHashes;
    }

    async sendRawBatch(batchArray, rpcUrl) {
        let lastError = null;
        for (let i = 0; i < 5; ++i) {
            const body = JSON.stringify(batchArray);
            const resp = await fetch(rpcUrl, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body,
            });

            if (!resp.ok) {
                lastError = new Error(`RPC error: HTTP ${resp.status} ${resp.statusText}`);
                await Utils.sleep(500);
                continue;
            }

            try {
                const jsonResp = await resp.json();
                return jsonResp.map((resp) => resp.result);
            } catch (e) {
                lastError = e;
            }
        }

        throw lastError;
    }

}
