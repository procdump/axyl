# kill all rayls_network
killall rayls-network

# rebuild project
cargo build

# wait for 5 seconds
sleep 5
# delete local-validators folder
directory=$(dirname "${BASH_SOURCE[0]}")

rm -rf "$directory/local-validators"
# run setup-for-launch.sh
$directory/setup-for-launch.sh

# run launch-network.sh
$directory/launch-validators.sh