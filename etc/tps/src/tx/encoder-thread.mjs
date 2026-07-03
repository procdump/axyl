import fs from "node:fs";
import fsreadline from "node:readline";
import path from "node:path";
import { parentPort, workerData } from 'node:worker_threads';
import { Wallet } from 'ethers';

async function main() {
    try {
        const {
            cachePath,
            segments,
            recipientAddr,
            value,      // stringified bigint
            chainId,
            gasPrice,   // stringified bigint
            gasLimit    // stringified bigint
        } = workerData;
        
        const encodedTxs = [];
        for (let s = 0; s < segments.length; ++s) {
            const segment = segments[s];
            const wallet = new Wallet(segment.privateKey);
            let encodedTxsCache = new Array(segment.count);
            
            try {
                const cacheFilePath = path.join(cachePath, wallet.address);
                const fileStream = fs.createReadStream(cacheFilePath);
                const readStream = fsreadline.createInterface({
                    input: fileStream,
                    crlfDelay: Infinity
                });


                let lineNum = 0;
                for await (const line of readStream) {
                    let index = lineNum - segment.startNonce;
                    if (index >= 0 && index < encodedTxsCache.length) {
                        encodedTxsCache[index] = line.trim();
                    } else if (index >= encodedTxsCache.length) {
                        readStream.close();
                        fileStream.destroy();
                    }
                    ++lineNum;
                };
            } catch (fileErr) {
            }

            for (let i = 0; i < segment.count; i++) {
                let signed = i < encodedTxsCache.length ? encodedTxsCache[i] : "";
                if (signed === "" || signed === undefined) {
                    const tx = {
                        to: recipientAddr,
                        value: BigInt(value),
                        nonce: segment.startNonce + i,
                        chainId,
                        gasPrice: BigInt(gasPrice),
                        gasLimit: BigInt(gasLimit),
                    };

                    signed = await wallet.signTransaction(tx);
                }

                encodedTxs.push(signed);
            }
        }

        parentPort.postMessage(encodedTxs);
    } catch (err) {
        parentPort.postMessage({ error: err?.message ?? String(err) });
    }
}

main();
