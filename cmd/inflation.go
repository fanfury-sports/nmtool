package cmd

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/fanfury-sports/nmtool/nemoclient"
)

func InflationRootCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "inflation [sub-command]",
		Short: "Various utilities for checking realized inflation",
	}

	cmd.PersistentFlags().StringVar(&nemoGrpcUrl, "node", "https://grpc.data.nemo.io:443", "nemo GRPC url to run queries against")

	cmd.AddCommand(AverageInflation())

	return cmd
}

func AverageInflation() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "avg [start-height] [end-height]",
		Short: "Calculate the real inflation over a block range as an APR & APY",
		Long: `Looks at the number of coins minted over a range of blocks and determines inflation.
The amount minted is converted into an average APR (pre second period) & extrapolated to an APY.
End height is optional, defaults to latest block. If start height is negative, it will subtract from end.`,
		Args: cobra.MatchAll(cobra.MinimumNArgs(1), cobra.MaximumNArgs(2)),
		Example: `calculate inflation over a block range:
$ nmtool inflation avg 2000000 2500000

calculate inflation from block 2M to present:
$ nmtool inflation avg 2000000

calculate inflation from last 10 blocks ("--" is necessary to interpret as an argument):
$ nmtool inflation avg -- -10

calculate inflation over the 1000 blocks before height 3000000:
$ nmtool inflation avg -- -1000 3000000
`,
		RunE: func(_ *cobra.Command, args []string) error {
			var end int64
			var err error
			fmt.Printf("using endpoint %s\n", nemoGrpcUrl)
			k, err := nemoclient.NewClient(nemoGrpcUrl)
			if err != nil {
				panic(fmt.Sprintf("failed to create nemo grpc client: %s", err))
			}

			// default to latest block if no end provided
			if len(args) == 1 {
				latest, err := k.LatestBlock(5)
				if err != nil {
					return fmt.Errorf("failed to fetch latest block: %s", err)
				}
				end = latest.Header.Height
			} else {
				end, err = strconv.ParseInt(args[1], 10, 64)
				if err != nil {
					return fmt.Errorf("failed to parse end block: %s", err)
				}
			}

			start, err := strconv.ParseInt(args[0], 10, 64)
			if err != nil {
				return fmt.Errorf("failed to parse start block: %s", err)
			}
			if start == 0 {
				return fmt.Errorf("start block cannot equal 0")
			}
			// interpret negative start values as a diff from end block.
			if start < 0 {
				start = end + start
			}

			result, err := k.InflationOverBlocks(start, end)
			if err != nil {
				return err
			}

			fmt.Println(result.String())

			return nil
		},
	}
	return cmd
}
