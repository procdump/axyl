import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from 'url';
import dotenv from "dotenv";

export class Config {

    constructor() {
        this.privateKeys = [];
        this.rpcUrls = [];
        this.numTxs = 0;
        this.chainId = 0;
        this.cachePath = "";
    }

    getMainRpc() {
        return this.rpcUrls[0];
    }

    static loadConfig() {
        const __filename = fileURLToPath(import.meta.url);
        const __dirname = path.dirname(__filename);

        const envPath = path.join(__dirname, "../../config/.env");
        if (!fs.existsSync(envPath)) {
            throw new Error("ENV file does not exists");
        }

        dotenv.config({ path: envPath, quiet: true });

        const config = new Config();

        config.privateKeys = process.env.PRIVATE_KEYS.split(',');
        if (config.privateKeys.length === 0) {
            throw new Error("PRIVATE_KEYS is not valid");
        }

        config.rpcUrls = process.env.RPC_URLS.split(',');
        if (config.rpcUrls.length === 0) {
            throw new Error("RPC_URLS is not valid")
        }
        
        if (config.privateKeys.length !== config.rpcUrls.length) {
            throw new Error("PRIVATE_KEYS' count must match RPC_URLS' count")
        }

        config.numTxs = parseInt(process.env.NUM_TRANSACTIONS, 10);
        if (Number.isNaN(config.numTxs) === true) {
            throw new Error("NUM_TRANSACTIONS is not valid");
        }

        config.chainId = parseInt(process.env.CHAIN_ID, 10);
        if (Number.isNaN(config.chainId) === true) {
            throw new Error("CHAIN_ID is not valid");
        }

        config.cachePath = path.join(__dirname, "../../cache");
        if (fs.existsSync(config.cachePath) === false) {
            fs.mkdirSync(config.cachePath, { recursive: true });
        }

        return config;
    }

}
