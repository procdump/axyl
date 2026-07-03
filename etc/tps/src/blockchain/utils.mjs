import { Wallet, JsonRpcProvider, parseEther } from "ethers";

export class BlockchainUtils {

    constructor(config) {
        this.config = config;
        this.provider = new JsonRpcProvider(config.rpcUrls[0]);

        this.walletManagerChunkSize = Math.ceil(config.numTxs / config.privateKeys.length);
        this.walletManagers = config.privateKeys.map((privateKey, i) => {
            const sI = i * this.walletManagerChunkSize;
            const eI = Math.min(config.numTxs, sI + this.walletManagerChunkSize);

            return new WalletManager(privateKey, config.rpcUrls[i], sI, eI);
        });
    }

    async logWalletAddresses() {
        console.log("Using wallets:");
        const promises = this.walletManagers.map((wm) => wm.getWalletAddress());
        const walletAddresses = (await Promise.all(promises)).join(',');
        console.log(walletAddresses);
        console.log("--------------------------------------------------------");
    }

    getLastTxIndexPerChunk() {
        return this.walletManagers.map((wm, i) => {
            return Math.min(this.config.numTxs, wm.endTxIndex - 1);
        });
    }
    
    getBlock(number) {
        return this.provider.getBlock(number, false);
    }

    getBlockNumber() {
        return this.provider.getBlockNumber();
    }

    getRpcUrlByWalletManager(walletManagerIndex) {
        return this.walletManagers[walletManagerIndex].rpcUrl;
    }

    getWalletManagerIndexByTxIndex(txIndex) {
        return Math.floor(txIndex / this.walletManagerChunkSize);
    }

    getWalletManagerByIndex(walletManagerIndex) {
        return this.walletManagers[walletManagerIndex];
    }

    async getTransactionsInBlock(blockNumber) {
        const block = await this.provider.getBlock(blockNumber);
        return block.transactions.length;
    }

    async getGasPrice() {
        const feeData = await this.provider.getFeeData();
        return feeData.gasPrice;
    }

    async fetchTransactionsReceipts(txHashes) {
        const receipts = new Array(txHashes.length).fill(null);
        const indices = Array.from({length: txHashes.length}, (_, i) => i);

        for (let i = 0; i < this.walletManagers.length; ++i) {
            let localTxHashes = [];
            if (i === 0) {
                localTxHashes = txHashes
            } else {
                localTxHashes = indices.map((index) => txHashes[index]);
            }

            const promises = localTxHashes.map((txHash) => {
                return this.walletManagers[i].fetchReceipt(txHash);
            })

            const localReceipts = await Promise.all(promises);
            const localIndices = [];
            for (let j = 0; j < indices.length; ++j) {
                const index = indices[j];
                const receipt = localReceipts[j];
                if (receipt === null) {
                    localIndices.push(index);
                    continue;
                }

                receipts[index] = receipt;
            }
        }

        return receipts;
    }

    async isTransactionSuccessful(txHash) {
        for (let i = 0; i < this.walletManagers.length; ++i) {
            const isTransactionSuccessful = await this.walletManagers[i].isTransactionSuccessful(txHash);
            if (isTransactionSuccessful === true) {
                return true;
            }
        }

        return false;
    }

    async areTransactionsSuccessful(txHashes) {
        const statuses = new Array(txHashes.length).fill(false);
        const indices = Array.from({length: txHashes.length}, (_, i) => i);

        for (let i = 0; i < this.walletManagers.length; ++i) {
            let localTxHashes = [];
            if (i === 0) {
                localTxHashes = txHashes
            } else {
                localTxHashes = indices.map((index) => txHashes[index]);
            }

            const promises = localTxHashes.map((txHash) => {
                return this.walletManagers[i].isTransactionSuccessful(txHash);
            });

            const localStatuses = await Promise.all(promises);
            const localIndices = [];
            for (let j = 0; j < indices.length; ++j) {
                const index = indices[j];
                const status = localStatuses[j];
                if (status === false) {
                    localIndices.push(index);
                    continue;
                }

                statuses[index] = status;
            }
        }

        return statuses;
    }

    async ensureFunds() {
        console.log("Checking for funds...");
        const faucetWalletManager = this.walletManagers[0];

        const sendAmount = "10000";
        const value = parseEther(sendAmount);
        const gasPrice = await this.getGasPrice();
        const faucetNonce = await faucetWalletManager.getNonce();

        const txResponsePromises = [];

        for (let i = 0; i < this.config.privateKeys.length; ++i) {
            const walletAddress = this.walletManagers[i].getWalletAddress();
            const weiBalance = await this.provider.getBalance(walletAddress);

            if (weiBalance !== 0n) {
                continue;
            }

            if (i === 0) {
                throw new Error("First PrivateKey in the list must have funds");
            }

            const tx = {
                to: walletAddress,
                value: value,
                nonce: faucetNonce + txResponsePromises.length,
                chainId: this.config.chainId,
                gasPrice: gasPrice,
                gasLimit: 21000n
            };

            const txResponsePromise = await faucetWalletManager.send(tx);
            txResponsePromises.push(txResponsePromise.wait(1));
        }

        await Promise.all(txResponsePromises);
        console.log("--------------------------------------------------------");
    }

}

class WalletManager {

    constructor(privateKey, rpcUrl, startTxIndex, endTxIndex) {
        this.privateKey = privateKey;
        this.rpcUrl = rpcUrl;
        this.startTxIndex = startTxIndex;
        this.endTxIndex = endTxIndex;

        this.provider = new JsonRpcProvider(rpcUrl);
        this.wallet = new Wallet(privateKey, this.provider);
    }

    getWalletAddress() {
        return this.wallet.getAddress();
    }

    getTxCount() {
        return this.endTxIndex - this.startTxIndex;
    }

    calcNonceOffsetByTxIndex(txIndex) {
        return txIndex - this.startTxIndex;
    }

    async getNonce() {
        const walletAddress = await this.getWalletAddress();
        return this.provider.getTransactionCount(walletAddress, "pending");
    }

    async fetchReceipt(txHash) {
        return this.provider.getTransactionReceipt(txHash);
    }

    async isTransactionSuccessful(txHash) {
        const receipt = await this.provider.getTransactionReceipt(txHash);
        return receipt?.status === 1;
    }

    async send(tx) {
        return this.wallet.sendTransaction(tx);
    }

}
