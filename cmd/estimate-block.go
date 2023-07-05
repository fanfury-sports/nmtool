package cmd

import (
	"fmt"
	"math"
	"time"

	"github.com/spf13/cobra"

	"github.com/fanfury-sports/nmtool/nemoclient"
)

const estimateBlockTimeFormat = "2006-01-02T15:04"

func EstimateBlockHeightCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "estimate-block-height [desired-time]",
		Short: "Estimate height at a given time",
		Long: `Provides an estimate of the block height at a desired time based on various blocktime averages.
Time must be in UTC. Format times like YYYY-MM-DDThh:mm.
`,
		Args: cobra.ExactArgs(1),
		Example: `Estimate height on May 22, 2050 at 15:00 UTC:
$ nmtool estimate-block-height 2050-05-22T15:00
`,
		RunE: func(_ *cobra.Command, args []string) error {
			numRetries := 5

			fmt.Printf("using endpoint %s\n", nemoGrpcUrl)
			k, err := nemoclient.NewClient(nemoGrpcUrl)
			if err != nil {
				return fmt.Errorf("failed to create nemo grpc client: %s", err)
			}

			now := time.Now()
			desiredTimeUTC, err := time.Parse(estimateBlockTimeFormat, args[0])
			if err != nil {
				return fmt.Errorf("failed to parse time '%s': %s", args[0], err)
			}
			if desiredTimeUTC.Before(now) {
				return fmt.Errorf("desired estimation time (%s) has already happened. are you using UTC?", desiredTimeUTC)
			}

			secondsUntilThen := desiredTimeUTC.Sub(now).Seconds()
			fmt.Printf(
				"estimating height at time %s (%d seconds from now):\n",
				desiredTimeUTC.Format(estimateBlockTimeFormat),
				int(math.Round(secondsUntilThen)),
			)

			blockAverages := []int64{10000, 50000, 75000, 100000}

			currentBlock, err := k.LatestBlock(numRetries)
			if err != nil {
				return fmt.Errorf("failed to fetch latest block: %s", err)
			}
			currentHeight := currentBlock.Header.Height

			for _, numBlocks := range blockAverages {
				height := currentHeight - numBlocks
				startBlock, err := k.Block(height, numRetries)
				if err != nil {
					return fmt.Errorf("failed to fetch block %d: %s", height, err)
				}

				secondsPassed := currentBlock.Header.Time.Sub(startBlock.Header.Time).Seconds()
				blocksPerSec := float64(numBlocks) / secondsPassed
				blocksUntilThen := int64(math.Round(blocksPerSec * secondsUntilThen))
				heightAtTime := currentHeight + blocksUntilThen
				avgBlockTime := secondsPassed / float64(numBlocks)
				fmt.Printf("%8d block avg: height = %d (%d blocks, %.3fs avg over %.1fh)\n", numBlocks, heightAtTime, blocksUntilThen, avgBlockTime, secondsPassed/3600)
			}

			return nil
		},
	}

	cmd.PersistentFlags().StringVar(&nemoGrpcUrl, "node", "https://grpc.data.nemo.io:443", "nemo GRPC url to run queries against")

	return cmd
}
