import { Config } from './config/config.mjs';
import { BlockchainUtils } from './blockchain/utils.mjs';
import { TxEncoder } from './tx/encoder.mjs'
import { Monitor } from './monitor/monitor.mjs';
import { TxSender } from './tx/sender.mjs';

async function main() {
    try {
        const config = Config.loadConfig();
        const blockchainUtils = new BlockchainUtils(config);
        const txEncoder = new TxEncoder(config, blockchainUtils);
        const monitor = new Monitor(config, blockchainUtils);
        const txSender = new TxSender(config, blockchainUtils);

        await blockchainUtils.logWalletAddresses();
        await blockchainUtils.ensureFunds();

        const encodedTxs = await txEncoder.encodeTxs();
        const monitorStartPromise = monitor.start();
        const txHashes = await txSender.sendEncodedTxInBatches(encodedTxs);
        monitor.onSubmitTxn(txHashes);

        await monitorStartPromise;
    } catch (e) {
        console.error(e);
        process.exit(0);
    }

}

main();
