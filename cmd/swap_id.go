package cmd

import (
	"bytes"
	"encoding/hex"
	"fmt"

	"github.com/cosmos/cosmos-sdk/codec"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/incubus-network/nemo/x/bep3/types"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v2"

	"github.com/fanfury-sports/nmtool/binance"
)

var (
	nemoDeputiesStrings map[string]string = map[string]string{
		"bnb":  "fury1r4v2zdhdalfj2ydazallqvrus9fkphmgnfwgej",
		"btcb": "fury14qsmvzprqvhwmgql9fr0u3zv9n2qla8zmdxxys",
		"busd": "fury1hh4x3a4suu5zyaeauvmv7ypf7w9llwlfsh0fe5",
		"xrpb": "fury1c0ju5vnwgpgxnrktfnkccuth9xqc68dcpllncc",
	}
	bnbDeputiesStrings map[string]string = map[string]string{
		"bnb":  "bnb1jh7uv2rm6339yue8k4mj9406k3509kr4wt5nxn",
		"btcb": "bnb1xz3xqf4p2ygrw9lhp5g5df4ep4nd20vsywnmpr",
		"busd": "bnb10zq89008gmedc6rrwzdfukjk94swynd7dl97w8",
		"xrpb": "bnb15jzuvvg2kf0fka3fl2c8rx0kc3g6wkmvsqhgnh",
	}
)

// SwapIDCmd returns a command to calculate a bep3 swap ID for binance and nemo chains.
func SwapIDCmd(cdc *codec.LegacyAmino) *cobra.Command {

	nemoDeputies := map[string]sdk.AccAddress{}
	for k, v := range nemoDeputiesStrings {
		nemoDeputies[k] = mustNemoAccAddressFromBech32(v)
	}
	bnbDeputies := map[string]binance.AccAddress{}
	for k, v := range bnbDeputiesStrings {
		bnbDeputies[k] = mustBnbAccAddressFromBech32(v)
	}

	cmd := &cobra.Command{
		Use:   "swap-id random_number_hash original_sender_address deputy_addres_or_denom",
		Short: "Calculate binance and nemo swap IDs given swap details.",
		Long: fmt.Sprintf(`A swap's ID is: hash(swap.RandomNumberHash, swap.Sender, swap.SenderOtherChain)
One of the senders is always the deputy's address, the other is the user who initiated the first swap (the original sender).
Corresponding swaps on each chain have the same RandomNumberHash, but switched address order.

The deputy can be one of %v to automatically use the mainnet deputy addresses, or an arbitrary address.
The original sender and deputy address cannot be from the same chain.
`, getKeys(nemoDeputiesStrings)),
		Example: "swap-id 464105c245199d02a4289475b8b231f3f73918b6f0fdad898825186950d46f36 bnb10rr5f8m73rxgnz9afvnfn7fn9pwhfskem5kn0x busd",
		Args:    cobra.ExactArgs(3),
		RunE: func(_ *cobra.Command, args []string) error {

			randomNumberHash, err := hex.DecodeString(args[0])
			if err != nil {
				return err
			}

			// try and decode the bech32 address as either nemo or bnb
			addressNemo, errNemo := sdk.AccAddressFromBech32(args[1])
			addressBnb, errBnb := binance.AccAddressFromBech32(args[1])

			// fail if both decoding failed
			isNemoAddress := errNemo == nil && errBnb != nil
			isBnbAddress := errNemo != nil && errBnb == nil
			if !isNemoAddress && !isBnbAddress {
				return fmt.Errorf("can't unmarshal original sender address as either nemo or bnb: (%s) (%s)", errNemo.Error(), errBnb.Error())
			}

			// calculate swap IDs
			depArg := args[2]
			var swapIDNemo, swapIDBnb []byte
			if isNemoAddress {
				// check sender isn't a deputy
				for _, dep := range nemoDeputies {
					if addressNemo.Equals(dep) {
						return fmt.Errorf("original sender address cannot be deputy address: %s", dep)
					}
				}
				// pick deputy address
				var bnbDeputy binance.AccAddress
				bnbDeputy, ok := bnbDeputies[depArg]
				if !ok {
					bnbDeputy, err = binance.AccAddressFromBech32(depArg)
					if err != nil {
						return fmt.Errorf("can't unmarshal deputy address as bnb address (%s)", err)
					}
				}
				// calc ids
				swapIDNemo = types.CalculateSwapID(randomNumberHash, addressNemo, bnbDeputy.String())
				swapIDBnb = binance.CalculateSwapID(randomNumberHash, bnbDeputy, addressNemo.String())
			} else {
				// check sender isn't a deputy
				for _, dep := range bnbDeputies {
					if bytes.Equal(addressBnb, dep) {
						return fmt.Errorf("original sender address cannot be deputy address %s", dep)
					}
				}
				// pick deputy address
				var nemoDeputy sdk.AccAddress
				nemoDeputy, ok := nemoDeputies[depArg]
				if !ok {
					nemoDeputy, err = sdk.AccAddressFromBech32(depArg)
					if err != nil {
						return fmt.Errorf("can't unmarshal deputy address as nemo address (%s)", err)
					}
				}
				// calc ids
				swapIDBnb = binance.CalculateSwapID(randomNumberHash, addressBnb, nemoDeputy.String())
				swapIDNemo = types.CalculateSwapID(randomNumberHash, nemoDeputy, addressBnb.String())
			}

			outString, err := formatResults(swapIDNemo, swapIDBnb)
			if err != nil {
				return err
			}
			fmt.Println(outString)
			return nil
		},
	}

	return cmd
}

func formatResults(swapIDNemo, swapIDBnb []byte) (string, error) {
	result := struct {
		NemoSwapID string `yaml:"nemo_swap_id"`
		BnbSwapID  string `yaml:"bnb_swap_id"`
	}{
		NemoSwapID: hex.EncodeToString(swapIDNemo),
		BnbSwapID:  hex.EncodeToString(swapIDBnb),
	}
	bz, err := yaml.Marshal(result)
	return string(bz), err
}

func mustNemoAccAddressFromBech32(address string) sdk.AccAddress {
	a, err := sdk.AccAddressFromBech32(address)
	if err != nil {
		panic(err)
	}
	return a
}

func mustBnbAccAddressFromBech32(address string) binance.AccAddress {
	a, err := binance.AccAddressFromBech32(address)
	if err != nil {
		panic(err)
	}
	return a
}

func getKeys(m map[string]string) []string {
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}