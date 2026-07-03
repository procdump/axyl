import os from 'os';
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { parseEther, Wallet } from 'ethers';

import { Utils } from '../utils/utils.mjs';

const workerUrl = new URL('./encoder-thread.mjs', import.meta.url);

export class TxEncoder {

    constructor(config, blockchainUtils) {
        this.config = config;
        this.blockchainUtils = blockchainUtils;
    }

    async encodeTxs() {
        console.log(`Encoding ${this.config.numTxs} transactions concurrently...`);
        const startTime = Date.now();

        const recipientAddr = "0x000000000000000000000000000000000000dEaD";
        const sendAmount = "0.000000001";
        const value = parseEther(sendAmount);

        const gasPrice = await this.blockchainUtils.getGasPrice();
        const gasLimit = 2100000n;

        const maxWorkers = os.cpus().length;
        const workerCount = Math.min(maxWorkers, this.config.numTxs);
        const chunkSize = Math.ceil(this.config.numTxs / workerCount);

        const workerPromises = [];
        const workerDatas = [];
        for (let w = 0; w < workerCount; w++) {
            const workerStartIndex = w * chunkSize;
            if (workerStartIndex >= this.config.numTxs) {
                break;
            }

            const count = Math.min(chunkSize, this.config.numTxs - workerStartIndex);
            const segments = await this.prepareSegments(workerStartIndex, count);

            const workerData = {
                cachePath: this.config.cachePath,
                segments: segments,
                recipientAddr,
                value: value.toString(),
                chainId: this.config.chainId,
                gasPrice: gasPrice.toString(),
                gasLimit: gasLimit.toString(),
            };

            workerDatas.push(workerData);
            workerPromises.push(Utils.runWorker(workerUrl, workerData));
        }

        const workersResults = await Promise.all(workerPromises);
        const encodedTxs = workersResults.flat();
        if (encodedTxs.length !== this.config.numTxs) {
            throw new Error("Encoded txs does not match requested txs");
        }

        // await this.cacheEncodedTxs(workerDatas, workersResults);

        const endTime = Date.now();
        const processingDuration = endTime - startTime;
        console.log(`Total encoding duration: ${(processingDuration / 1000).toFixed(2)}s`);
        console.log("--------------------------------------------------------");

        return encodedTxs;
    }

    async prepareSegments(startTxIndex, count) {
        const segments = [];

        const walletManagerStartIndex = this.blockchainUtils.getWalletManagerIndexByTxIndex(startTxIndex);
        const walletManagersSize = this.blockchainUtils.walletManagers.length;
        for (let walletManagerIndex = walletManagerStartIndex; walletManagerIndex < walletManagersSize && count > 0; ++walletManagerIndex) {
            const walletManager = this.blockchainUtils.getWalletManagerByIndex(walletManagerIndex);

            const segmentStartNonceOffset = walletManager.calcNonceOffsetByTxIndex(startTxIndex);
            const segmentCount = Math.min(count, walletManager.getTxCount() - segmentStartNonceOffset);
            const currentNonce = await walletManager.getNonce();

            count -= segmentCount;
            startTxIndex += segmentCount;

            segments.push({
                privateKey: walletManager.privateKey,
                startNonce: currentNonce + segmentStartNonceOffset,
                count: segmentCount,
            })
        }

        if (count !== 0) {
            console.log(segments);
            throw new Error(`Error mapping transactions to wallet/rpcs with count: ${count}`);
        }

        return segments;
    }

    async cacheEncodedTxs(workerDatas, workersResults) {
        const storePromises = [];
        let walletPrivateKey = '';
        let walletAddress = '';
        let buffer = [];
        let bufferModified = false;

        for (let w = 0; w < workerDatas.length; ++w) {
            const segments = workerDatas[w].segments;
            const encodedTxsByWorker = workersResults[w];
            
            for (let i = 0; i < segments.length; ++i) {
                const s = segments[i];
                if (walletPrivateKey !== s.privateKey) {
                    if (walletAddress !== "" && bufferModified === true) {
                        storePromises.push(this.storeCachedEncodedTxs(walletAddress, buffer));
                        buffer = [];
                    }
                    
                    const wallet = new Wallet(s.privateKey);
                    walletPrivateKey = s.privateKey;
                    walletAddress = wallet.address;

                    bufferModified = false;

                    try {
                        const cacheFilePath = path.join(this.config.cachePath, walletAddress);
                        const fileContent = await fsp.readFile(cacheFilePath, "utf8");
                        buffer = fileContent.split(/\r?\n/);
                    } catch (fileErr) {
                    }
                }

                const gap = s.startNonce - buffer.length;
                if (gap > 0) {
                    const missing = new Array(gap).fill("");
                    buffer = buffer.concat(missing);
                }

                const offset = s.startNonce + s.count - buffer.length;
                if (offset <= 0) {
                    continue;
                }
                if (encodedTxsByWorker.length - offset < 0) {
                    throw new Error("Working set is less than expected");
                }

                bufferModified = true;
                buffer = buffer.concat(encodedTxsByWorker.slice(encodedTxsByWorker.length - offset));
            }
        }

        if (walletAddress !== "" && bufferModified === true) {
            storePromises.push(this.storeCachedEncodedTxs(walletAddress, buffer));
        }
        
        await Promise.all(storePromises);
    }

    async storeCachedEncodedTxs(walletAddress, buffer) {
        new Promise((resolve, reject) => {
            const cacheFilePath = path.join(this.config.cachePath, walletAddress);
            const fileStream = fs.createWriteStream(cacheFilePath);
            try {
                buffer.forEach((tx) => {
                    fileStream.write(tx);
                    fileStream.write('\n');
                })            
            } catch (e) {
                reject(e);
            } finally {
                fileStream.end();
                resolve();
            }
        });
    }

}
