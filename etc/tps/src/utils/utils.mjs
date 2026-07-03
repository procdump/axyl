import { Worker } from 'node:worker_threads';

export class Utils {

    static async sleep(ms) {
        return new Promise((res) => setTimeout(res, ms));
    }

    static runWorker(workerUrl, workerData) {
        return new Promise((resolve, reject) => {
            const worker = new Worker(workerUrl, { workerData });

            worker.on('message', (msg) => {
                if (msg && msg.error) {
                    reject(new Error(msg.error));
                } else {
                    resolve(msg);
                }
            });

            worker.on('error', reject);

            worker.on('exit', (code) => {
                if (code !== 0) {
                    reject(new Error(`Worker stopped with exit code ${code}`));
                }
            });
        });
    }
    
}
