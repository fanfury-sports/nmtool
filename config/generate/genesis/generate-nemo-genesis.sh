#! /bin/bash
# This script builds the genesis.json for the master nemo template
# It requires moreutils (for sponge) & jq
# NOTE: many values here were just copied directly. there are much better ways
#  that they could be abstracted and reduced down to simple to modify lists of values.

# you can use this script to generate different chains.
# by default, it generates the files in the nemo master template.
# Environment variables:
# - CHAIN_ID: The chain ID. Default: highbury_710-1
# - DEST: Destination directory. Example: ./config/templates/nemo/master/initstate/.nemo
# - DENOM: Sets the primary denomination. This is respected in the validator setup
#          and then a final find&replace for ufury -> $DENOM
# - REPLACE_ACCOUNT_KEYS: Removes and replaces the account keys in the template.
#                         This will always result in a diff because creation time is baked into the keyfiles.
# - SKIP_INCENTIVES: Ignore setting genesis.app_state.incentive.params

set -e

mkdir -p scratch

DATA=./scratch/.nemo
DEST=${DEST:-./config/templates/nemo/master/initstate/.nemo}
DENOM=${DENOM:-ufury}
ADDRESSES=./config/common/addresses.json

BINARY="nemo --home $DATA"

# set-app-state loads a json file in this directory and sets the app_state value matched by the filename.
# files may contains bash variables exported from this file.
# example: set-app-state bep3.params.asset_params
# this will set .app_state.bep3.params.asset_params to the contents of bep3.params.asset_params.json
# optionally, include a jq manipulation of the contents:
# example: set-app-state issuance.params.assets '[ .[] | { hello: . } ]'
function set-app-state {
  app_state_path=".app_state.$1"
  file="./config/generate/genesis/$1.json"
  manipulation="$2"

  # error if expected state file doesn't exist.
  if [ ! -e "$file" ]; then
    echo 'set-app-state error: '"$file"' does not exist.'
    exit 1
  fi

  # apply manipulation to contents if present, otherwise, use file contents.
  if [ -z "$manipulation" ]; then
    contents=$(cat "$file")
  else
    contents=$(jq "$manipulation" "$file")
  fi
  # variable substitution for contents! allows use of $vars in the json files.
  # variables must be `export`ed before this func is called.
  contents=$(echo "$contents" | envsubst)

  jq "$app_state_path"' = '"$contents" $DATA/config/genesis.json | sponge $DATA/config/genesis.json
}

###########################
##### INIT CHAIN HOME #####
###########################
# remove any old state and config
rm -rf $DATA

# Create new data directory, overwriting any that alread existed
chainID=${CHAIN_ID:-highbury_710-1}
$BINARY init validator --chain-id $chainID

# Copy over original validator keys
cp $DEST/config/node_key.json $DATA/config/node_key.json
cp $DEST/config/priv_validator_key.json $DATA/config/priv_validator_key.json

####################
##### APP.TOML #####
####################
# hacky enable of rest api
sed -i '' 's/enable = false/enable = true/g' $DATA/config/app.toml

# Set evm tracer to json
sed -i '' 's/tracer = ""/tracer = "json"/g' $DATA/config/app.toml

# Enable full error trace to be returned on tx failure
sed -i '' '/iavl-cache-size/a\
trace = true' $DATA/config/app.toml

# Enable unsafe CORs
sed -i '' 's/enabled-unsafe-cors = false/enabled-unsafe-cors = true/g' $DATA/config/app.toml

# Set the min gas fee
sed -i '' 's/minimum-gas-prices = "0ufury"/minimum-gas-prices = "0.001ufury;1000000000afury"/g' $DATA/config/app.toml

# Disable pruning
sed -i '' 's/pruning = "default"/pruning = "nothing"/g' $DATA/config/app.toml

# Set EVM JSON-RPC starting IP addresses
sed -i '' 's/address = "127.0.0.1:8545"/address = "0.0.0.0:8545"/g' $DATA/config/app.toml
sed -i '' 's/ws-address = "127.0.0.1:8546"/ws-address = "0.0.0.0:8546"/g' $DATA/config/app.toml

#######################
##### CLIENT.TOML #####
#######################
# Set client chain id
sed -i '' 's/chain-id = ""/chain-id = "'"$chainID"'"/g' $DATA/config/client.toml

#######################
##### CONFIG.TOML #####
#######################
# lower default commit timeout
sed -i '' 's/timeout_commit = "5s"/timeout_commit = "1s"/g' $DATA/config/config.toml

#########################
##### CONFIGURATION #####
#########################
# avoid having to use password for keys
$BINARY config keyring-backend test

# set broadcast-mode to block
$BINARY config broadcast-mode block

############################
##### CONSENSUS PARAMS #####
############################
# set maximum gas allowed per block
jq '.consensus_params.block.max_gas = "2000000"' $DATA/config/genesis.json | sponge $DATA/config/genesis.json

###########################
##### SETUP ADDRESSES #####
###########################
# add-genesis-account initiates an account with funds in genesis.json
function add-genesis-account {
  account_name_or_addr=$1
  initial_funds=$2

  # NOTE: this successfully sets the account's initial funds.
  # however, the `auth.accounts` item added is always an EthAccount.
  # THIS SCRIPT OVERRIDES ALL `auth.accounts` AFTER ALL add-genesis-account calls are made
  # The different account overrides can be see in ./auth.accounts/*.json
  $BINARY add-genesis-account "$account_name_or_addr" "$initial_funds"
}
# add-genesis-account-key initiates an account with funds & adds the user's mnemonic to the keyring
function add-genesis-account-key {
  account_name=$1
  mnemonic_path=$2
  initial_funds=$3

  mnemonic=$(jq -r "$mnemonic_path.mnemonic" $ADDRESSES)

  echo "$mnemonic" | $BINARY keys add "$account_name" --recover
  add-genesis-account "$account_name" "$initial_funds"
}
# same as above, but use --eth (for coin type 60 & ethermint's ethsecp256k1 signing algorithm)
function add-eth-genesis-account-key {
  account_name=$1
  mnemonic_path=$2
  initial_funds=$3

  mnemonic=$(jq -r "$mnemonic_path.mnemonic" $ADDRESSES)

  echo "$mnemonic" | $BINARY keys add "$account_name" --eth --recover
  add-genesis-account "$account_name" "$initial_funds"
}
function get-address {
  path=$1
  jq -r "$path.address" $ADDRESSES
}

# Setup Validator
validator=$(get-address '.nemo.validators[0]')
export validator
valoper=$(jq -r '.nemo.validators[0].val_address' $ADDRESSES)
export valoper
add-genesis-account-key validator '.nemo.validators[0]' 2000000000"$DENOM"

$BINARY gentx validator 1000000000"$DENOM" \
--chain-id="$chainID" \
--moniker="validator"

$BINARY collect-gentxs

# Bep3 Deputies
bnb_cold=$(get-address '.nemo.deputys.bnb.cold_wallet')
export bnb_cold
add-genesis-account-key deputy-bnb-cold '.nemo.deputys.bnb.cold_wallet' 1000000000000ufury
bnb_deputy=$(get-address '.nemo.deputys.bnb.hot_wallet')
export bnb_deputy
add-genesis-account-key deputy-bnb-hot '.nemo.deputys.bnb.hot_wallet' 1000000000000ufury

btcb_cold=$(get-address '.nemo.deputys.btcb.cold_wallet')
export btcb_cold
add-genesis-account-key deputy-btcb-cold '.nemo.deputys.btcb.cold_wallet' 1000000000000ufury
btcb_deputy=$(get-address '.nemo.deputys.btcb.hot_wallet')
export btcb_deputy
add-genesis-account-key deputy-btcb-hot '.nemo.deputys.btcb.hot_wallet' 1000000000000ufury

xrpb_cold=$(get-address '.nemo.deputys.xrpb.cold_wallet')
export xrpb_cold
add-genesis-account-key deputy-xrpb-cold '.nemo.deputys.xrpb.cold_wallet' 1000000000000ufury
xrpb_deputy=$(get-address '.nemo.deputys.xrpb.hot_wallet')
export xrpb_deputy
add-genesis-account-key deputy-xrpb-hot '.nemo.deputys.xrpb.hot_wallet' 1000000000000ufury

busd_cold=$(get-address '.nemo.deputys.busd.cold_wallet')
export busd_cold
add-genesis-account-key deputy-busd-cold '.nemo.deputys.busd.cold_wallet' 1000000000000ufury
busd_deputy=$(get-address '.nemo.deputys.busd.hot_wallet')
export busd_deputy
add-genesis-account-key deputy-busd-hot '.nemo.deputys.busd.hot_wallet' 1000000000000ufury

# Users
generic_0=$(get-address .nemo.users.generic_0)
export generic_0
add-genesis-account-key generic-0 '.nemo.users.generic_0' 1000000000000ufury
generic_1=$(get-address .nemo.users.generic_1)
export generic_1
add-genesis-account-key generic-1 '.nemo.users.generic_1' 1000000000000ufury
generic_2=$(get-address .nemo.users.generic_2)
export generic_2
add-genesis-account-key generic-2 '.nemo.users.generic_2' 1000000000000ufury
vesting_periodic=$(get-address .nemo.users.vesting_periodic)
export vesting_periodic
add-genesis-account-key vesting-periodic '.nemo.users.vesting_periodic' 10000000000ufury
user=$(get-address .nemo.users.user)
export user
add-eth-genesis-account-key user '.nemo.users.user' 1000000000ufury


ibcdenom='ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2' # ATOM on mainnet
whalefunds=1000000000000ufury,10000000000000000bfury-"$valoper",10000000000000000bnb,10000000000000000btcb,10000000000000000busd,1000000000000000000jinx,1000000000000000000swp,10000000000000000musd,10000000000000000xrpb,10000000000000000"$ibcdenom"
# whale account
whale=$(get-address '.nemo.users.whale')
export whale
add-genesis-account-key whale '.nemo.users.whale' "$whalefunds"

# another whale, but setup as EthAccount
whale2=$(get-address '.nemo.users.whale2')
export whale2
add-eth-genesis-account-key whale2 '.nemo.users.whale2' "$whalefunds"

# dev-wallet! key is in 1pass.
devwallet=$(jq -r '.nemo.users.dev_wallet.address' $ADDRESSES)
export devwallet
add-genesis-account "$devwallet" "$whalefunds"

# Misc
oracle=$(get-address '.nemo.oracles[0]')
export oracle
add-genesis-account-key oracle '.nemo.oracles[0]' 1000000000000ufury
committee=$(get-address '.nemo.committee_members[0]')
export committee
add-eth-genesis-account-key committee '.nemo.committee_members[0]' 1000000000000ufury
bridge_relayer=$(get-address '.nemo.users.bridge_relayer')
export bridge_relayer
add-eth-genesis-account-key bridge_relayer '.nemo.users.bridge_relayer' 1000000000000ufury


# Accounts without keys
# issuance module
add-genesis-account fury1cj7njkw2g9fqx4e768zc75dp9sks8u9zlc7m2x 1000000000000ufury,1000000000000swp,1000000000000jinx
# swap module
add-genesis-account fury1mfru9azs5nua2wxcd4sq64g5nt7nn4n8u5n4a5 5000000000ufury,200000000btcb,1000000000jinx,5000000000swp,103000000000musd

# override `auth.accounts` array.
# DO NOT CALL `add-genesis-account` AFTER HERE UNLESS IT IS AN EthAccount
# this uses all exported account variables.
account_data_dir='./config/generate/genesis/auth.accounts'
account_data=$(jq -s '
  [ .[0][] | {
      "@type": "/cosmos.auth.v1beta1.BaseAccount",
      "account_number": "0",
      "address": .,
      "pub_key": null,
      "sequence": "0"
    }
  ]
  + [.[1]]
  + .[2]
' $account_data_dir/base-accounts.json $account_data_dir/vesting-periodic.json $account_data_dir/eth-accounts.json |
  envsubst
)
jq ".app_state.auth.accounts"' = '"$account_data" $DATA/config/genesis.json | sponge $DATA/config/genesis.json


############################
##### MODULE APP STATE #####
############################

# Replace stake with ufury
sed -i '' 's/stake/ufury/g' $DATA/config/genesis.json
# Replace the default evm denom of aphoton with ufury
sed -i '' 's/aphoton/afury/g' $DATA/config/genesis.json

# Zero out the total supply so it gets recalculated during InitGenesis
jq '.app_state.bank.supply = []' $DATA/config/genesis.json | sponge $DATA/config/genesis.json

# x/auction: shorten bid duration
jq '.app_state.auction.params.forward_bid_duration = "28800s"' $DATA/config/genesis.json | sponge $DATA/config/genesis.json

# x/authz authorizations for community module
set-app-state authz.authorization

# x/bep3 assets
set-app-state bep3.params.asset_params

# x/cdp params
jq '.app_state.cdp.params.global_debt_limit.amount = "53000000000000"' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
set-app-state cdp.params.collateral_params

# x/committee (uses $committee)
set-app-state committee.committees

# x/distribution: set community tax
jq '.app_state.distribution.params.community_tax = "0.750000000000000000"' $DATA/config/genesis.json | sponge $DATA/config/genesis.json

# x/earn
set-app-state earn.params.allowed_vaults

# x/evm
# disable all post-london forks
jq '.app_state.evm.params.chain_config.london_block = null' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
jq '.app_state.evm.params.chain_config.arrow_glacier_block = null' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
jq '.app_state.evm.params.chain_config.gray_glacier_block = null' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
jq '.app_state.evm.params.chain_config.merge_netsplit_block = null' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
jq '.app_state.evm.params.chain_config.shanghai_block = null' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
jq '.app_state.evm.params.chain_config.cancun_block = null' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
# setup accounts
set-app-state evm.accounts
# setup eip712 allowed messages
set-app-state evm.params.eip712_allowed_msgs

# x/evmutil: enable evm -> sdk conversion pair
jq '.app_state.evmutil.params.enabled_conversion_pairs = [
  {
    "nemo_erc20_address": "0xeA7100edA2f805356291B0E55DaD448599a72C6d",
    "denom": "erc20/multichain/usdc"
  }
]' $DATA/config/genesis.json | sponge $DATA/config/genesis.json

# x/evmutil: enable sdk -> evm conversion pair
jq '.app_state.evmutil.params.allowed_cosmos_denoms = [
  {
    "cosmos_denom": "'"$ibcdenom"'",
    "name": "Nemo-wrapped ATOM",
    "symbol": "ATOM",
    "decimals": 6
  }
]' $DATA/config/genesis.json | sponge $DATA/config/genesis.json

# x/feemarket: Disable fee market
jq '.app_state.feemarket.params.no_base_fee = true' $DATA/config/genesis.json|sponge $DATA/config/genesis.json

# x/gov: lower voting period to 30s
jq '.app_state.gov.voting_params.voting_period = "30s"' $DATA/config/genesis.json|sponge $DATA/config/genesis.json

# x/jinx: money markets (Nemo Lend)
set-app-state jinx.params.money_markets

# x/incentive params
if [ "$SKIP_INCENTIVES" != true ]; then
  set-app-state incentive.params
fi

# # TODO: are nonempty swap claims important?

# x/issuance assets
set-app-state issuance.params.assets '
  [.[] | {
    owner: "'"$devwallet"'",
    denom: .,
    blocked_addresses: [],
    paused: false,
    blockable: false,
    rate_limit: {
      active: false,
      limit: "0",
      time_period: "0s"
    }
}]'

# x/mint
# jq '.app_state.mint.params.mint_denom = "ufury"' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
jq '.app_state.mint.params.inflation_min = "0.750000000000000000"' $DATA/config/genesis.json | sponge $DATA/config/genesis.json
jq '.app_state.mint.params.inflation_max = "0.750000000000000000"' $DATA/config/genesis.json | sponge $DATA/config/genesis.json

# x/pricefeed (uses $oracle)
set-app-state pricefeed

# x/savings supported denoms
jq '.app_state.savings.params.supported_denoms =
  [ "bfury-'"$valoper"'", "musd", "ufury", "jinx", "swp", "bfury", "erc20/multichain/usdc" ]' \
  $DATA/config/genesis.json | sponge $DATA/config/genesis.json

# x/swap (uses $whale)
set-app-state swap

########################
##### CHANGE DENOM #####
########################
if [ "$DENOM" != "ufury" ]; then
  # Replace ufury with $DENOM in genesis
  sed -i '' 's/ufury/'"$DENOM"'/g' $DATA/config/genesis.json
  # Replace ufury with $DENOM in app.toml
  sed -i '' 's/ufury/'"$DENOM"'/g' $DATA/config/app.toml
fi

############################
##### MOVE FILE ASSETS #####
############################
$BINARY validate-genesis $DATA/config/genesis.json

cp $DATA/config/app.toml $DEST/config/app.toml
cp $DATA/config/client.toml $DEST/config/client.toml
cp $DATA/config/config.toml $DEST/config/config.toml
cp $DATA/config/genesis.json $DEST/config/genesis.json

rm -fr $DEST/config/gentx
cp -r $DATA/config/gentx $DEST/config/gentx

if [ "$REPLACE_ACCOUNT_KEYS" == "true" ]; then
  echo replacing existing account keys
  rm -fr $DEST/keyring-test
  mv $DATA/keyring-test $DEST/keyring-test
fi

###################
##### CLEANUP #####
###################
rm -fr ./scratch
