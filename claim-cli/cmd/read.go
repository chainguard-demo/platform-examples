package cmd

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"chainguard.dev/sdk/proto/capabilities"
	"github.com/go-jose/go-jose/v4/jwt"
	"github.com/olekukonko/tablewriter"
	"github.com/olekukonko/tablewriter/renderer"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var readCmd = &cobra.Command{
	Use:   "read",
	Short: "Read a JWT or capabilities string",
	Long: `Takes a Chainguard JWT or capabilities string and prints out the details.

Reads from a string or stdin. For stdin pass - as the argument.

Examples:

claim-cli read AAAAAAAAAMH_8gDx4eD__vn--DBJ__tvlCHm8B_wHmMAAAAAAAAAAQ==

chainctl auth token | claim-cli read --jwt - `,
	RunE: read,
}

var caps capabilities.Set

type tableRow struct {
	org  string
	noun string
	verb string
}

type claims struct {
	jwt.Claims `json:",inline"`

	Capabilities map[string]capabilities.Set `json:"cap,omitempty"`
}

func init() {
	rootCmd.AddCommand(readCmd)
	readCmd.Flags().Bool("jwt", false, "Read a full JWT instead of just a capability claim")
	viper.BindPFlag("jwt", readCmd.Flags().Lookup("jwt"))
}

func read(cmd *cobra.Command, args []string) error {
	if len(args) == 0 {
		return errors.New("a JWT or capabilities string must be provided")
	}
	input := args[0]

	if args[0] == "-" {
		s := new(strings.Builder)
		var r io.Reader = cmd.InOrStdin()
		_, err := io.Copy(s, r)
		if err != nil {
			return err
		}
		input = s.String()
	}

	if viper.GetBool("jwt") {
		return printJwtString(cmd.OutOrStdout(), input)
	} else {
		return printCapString(cmd.OutOrStdout(), input)
	}

}

func printCapString(w io.Writer, c string) error {
	out := []string{}

	if err := json.Unmarshal(fmt.Appendf([]byte{}, `%q`, c), &caps); err != nil {
		return err
	}

	for _, c := range caps {
		cs := c.String()
		if s, err := capabilities.Stringify(c); err == nil {
			cs = s
		}
		out = append(out, cs)
	}

	var rows []tableRow

	for _, v := range out {
		var noun string
		idx := strings.LastIndex(v, ".")
		if idx == -1 {
			noun = v
		} else {
			noun = v[:idx]
		}
		row := tableRow{
			noun: noun,
			verb: v[strings.LastIndex(v, ".")+1:],
		}
		rows = append(rows, row)
	}

	t := newTable(w, []string{"entity", "action"})
	for _, v := range rows {
		t.Append(v.noun, v.verb)
	}
	return t.Render()

}

func printJwtString(w io.Writer, jwt string) error {
	s := strings.Split(string(jwt), ".")
	if len(s) != 3 {
		return errors.New("invalid token format")
	}

	d, err := base64.RawStdEncoding.DecodeString(s[1])
	if err != nil {
		return fmt.Errorf("failed to decode token claims: %w", err)
	}

	claims := new(claims)
	if err := json.Unmarshal(d, claims); err != nil {
		return fmt.Errorf("failed to unmarshal token claims: %w", err)
	}

	rows := []tableRow{}
	for group, caps := range claims.Capabilities {
		for _, c := range caps {
			cs := c.String()
			if s, err := capabilities.Stringify(c); err == nil {
				cs = s
			}
			var noun string
			idx := strings.LastIndex(cs, ".")
			if idx == -1 {
				noun = cs
			} else {
				noun = cs[:idx]
			}
			rows = append(rows, tableRow{
				org:  group,
				noun: noun,
				verb: cs[strings.LastIndex(cs, ".")+1:],
			})
		}
	}

	t := newTable(w, []string{"org", "entity", "action"})
	for _, v := range rows {
		t.Append(v.org, v.noun, v.verb)
	}
	return t.Render()
}

func newTable(w io.Writer, headers []string) *tablewriter.Table {
	return tablewriter.NewTable(w,
		tablewriter.WithConfig(tablewriter.NewConfigBuilder().Build()),
		tablewriter.WithHeader(headers),
		tablewriter.WithRenderer(renderer.NewBlueprint()),
	)
}
