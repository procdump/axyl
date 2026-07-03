import { Utils } from '../utils/utils.mjs';

export class Monitor {

    constructor(config, blockchainUtils) {
        this.config = config;
        this.blockchainUtils = blockchainUtils;
        this.firstTxTime = 0;
        this.firstTxBlock = 0;
        this.lastTxTime = 0;
        this.lastTxBlock = 0;

        this.txHashes = [];
        this.lastTxHashesPerWallet = [];
        this.waitInterval = 1000;
    }

    onSubmitTxn(txHashes) {
        this.txHashes = txHashes;
        this.lastTxHashesPerWallet = this.blockchainUtils.getLastTxIndexPerChunk().map((i) => {
            return txHashes[i];
        });
        this.waitInterval = 100;
    }

    async start() {
        this.firstTxTime = Date.now();
        this.firstTxBlock = await this.blockchainUtils.getBlockNumber();

        let lastLogMessageTimestamp = 0;
        // let lastAllCheckTimestamp = Date.now();
        // let allCheckPromise = null;

        for (let waitingCounter = 0; this.lastTxBlock === 0;) {
            if (this.lastTxHashesPerWallet.length === 0) {
                await Utils.sleep(this.waitInterval);
                continue;
            }

            const diffFromPreviousLog = Date.now() - lastLogMessageTimestamp;

            const txStatuses = await this.blockchainUtils.areTransactionsSuccessful(this.lastTxHashesPerWallet);
            if (diffFromPreviousLog > 2000) {
                console.log(`${++waitingCounter}: Waiting for ${this.lastTxHashesPerWallet.join(',')} -> ${txStatuses.join(',')}`);
                lastLogMessageTimestamp = Date.now();
            }

            const allSuccess = txStatuses.reduce((accu, txStatus) => {
                return accu + (txStatus === true ? 1 : 0);
            }, 0);

            if (allSuccess === txStatuses.length && txStatuses.length > 0) {
                const receipts = await this.blockchainUtils.fetchTransactionsReceipts(this.lastTxHashesPerWallet);
                const lastBlockOfExecution = Math.max(...receipts.map((receipt) => receipt.blockNumber));

                let block = null;
                for (let retries = 0; retries < 10 && block === null; retries++) {
                    block = await this.blockchainUtils.getBlock(lastBlockOfExecution);
                    if (block === null) {
                        await Utils.sleep(100 * (retries + 1));
                    }
                }

                if (block === null) {
                    console.error(`Failed to fetch block ${lastBlockOfExecution} after retries`);
                    continue;
                }

                this.lastTxTime = block.timestamp * 1000;
                this.lastTxBlock = await this.blockchainUtils.getBlockNumber();
            }
            // else if (allCheckPromise === null) {
            //     const diffFromPreviousAllCheck = Date.now() - lastAllCheckTimestamp;
            //     if (diffFromPreviousAllCheck > 30000) {
            //         allCheckPromise = this.checkTxsStatuses();
            //         allCheckPromise.then(() => {
            //             allCheckPromise = null;
            //             lastAllCheckTimestamp = Date.now();
            //         }).catch(() => {
            //             allCheckPromise = null;
            //             lastAllCheckTimestamp = Date.now();
            //         });
            //     }
            // }
        }

        // if (allCheckPromise !== null) {
        //     await allCheckPromise;
        // }

        console.log("--------------------------------------------------------");
        await this.logProcessingTimes();
        // await this.logTxsInBlocks();
        // await this.checkTxsStatuses();
    }

    async logProcessingTimes() {
        const processingDuration = (this.lastTxTime - this.firstTxTime) / 1000;
        const trueTps = this.config.numTxs / processingDuration ;

        console.log("Finished all processing checks.");
        console.log(`Total Transactions Processed: ${this.config.numTxs}`);
        console.log(`Processing Block Range: ${this.firstTxBlock} to ${this.lastTxBlock}`);
        console.log(`Processing Duration: ${processingDuration.toFixed(2)}s`);
        console.log(`Calculated **True TPS**: ${trueTps.toFixed(1)} TPS`);
        console.log("--------------------------------------------------------");
    }

    async logTxsInBlocks() {
        const txCountPromises = [];
        for (let bn = this.firstTxBlock; bn <= this.lastTxBlock; bn++) {
            const txCountPromise = this.blockchainUtils.getTransactionsInBlock(bn);
            txCountPromises.push(txCountPromise);
        }
        
        const txCounts = await Promise.all(txCountPromises);
        let totalTxCount = 0;
        txCounts.map((txCount, i) => {
            totalTxCount += txCount;
            console.log(`Block ${this.firstTxBlock + i}: ${txCount} transactions`);
        });

        console.log(`Total Txs in these blocks: ${totalTxCount}`);
        console.log("--------------------------------------------------------");
    }

    async checkTxsStatuses() {
        let txStatusesPromises = [];
        let successfulTxCount = 0;
        
        for (let i = 0; i < this.txHashes.length; ++i) {
            txStatusesPromises.push(this.blockchainUtils.isTransactionSuccessful(this.txHashes[i]));

            if (txStatusesPromises.length === 100000 || i + 1 === this.txHashes.length) {
                const txStatuses = await Promise.all(txStatusesPromises);
                txStatusesPromises = [];

                successfulTxCount = txStatuses.reduce((accu, txStatus) => {
                    return accu + (txStatus === true ? 1 : 0);
                }, successfulTxCount)
            }
        }

        const successRate = (successfulTxCount / this.txHashes.length * 100).toFixed(2);
        console.log(`Successful Txs: ${successfulTxCount} out of ${this.txHashes.length} (${successRate}%)`)
        console.log("--------------------------------------------------------");
    }

}
