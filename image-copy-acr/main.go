/*
Copyright 2025 Chainguard, Inc.
SPDX-License-Identifier: Apache-2.0
*/

package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"slices"
	"strings"

	"chainguard.dev/sdk/events"
	"chainguard.dev/sdk/events/receiver"
	"chainguard.dev/sdk/events/registry"
	iam "chainguard.dev/sdk/proto/platform/iam/v1"
	v1 "chainguard.dev/sdk/proto/platform/registry/v1"
	"chainguard.dev/sdk/sts"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/chrismellard/docker-credential-acr-env/pkg/credhelper"
	cloudevents "github.com/cloudevents/sdk-go/v2"
	cehttp "github.com/cloudevents/sdk-go/v2/protocol/http"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/crane"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/kelseyhightower/envconfig"
	"github.com/sigstore/cosign/v2/pkg/cosign"
	ociremote "github.com/sigstore/cosign/v2/pkg/oci/remote"
)

type envConfig struct {
	APIEndpoint      string `envconfig:"API_ENDPOINT" required:"true"`
	Issuer           string `envconfig:"ISSUER_URL" required:"true"`
	GroupName        string `envconfig:"GROUP_NAME" required:"true"`
	Group            string `envconfig:"GROUP" required:"true"`
	Identity         string `envconfig:"IDENTITY" required:"true"`
	Port             int    `envconfig:"PORT" default:"8080" required:"true"`
	DstRepo          string `envconfig:"DST_REPO" required:"true"`
	TokenScope       string `envconfig:"TOKEN_SCOPE" required:"true"`
	IgnoreReferrers  bool   `envconfig:"IGNORE_REFERRERS" required:"true"`
	VerifySignatures bool   `envconfig:"VERIFY_SIGNATURES" required:"true"`
}

var (
	env             envConfig
	azureCredential azcore.TokenCredential
)

var keychain = authn.NewMultiKeychain(
	cgKeychain{},
	authn.NewKeychainFromHelper(credhelper.NewACRCredentialsHelper()),
	authn.DefaultKeychain,
)

// excludedRepos is the set of repository leaf names that should never be
// mirrored to ACR. Matched against the last path segment of the resolved
// repository name, so flat names ("foo-bundle") and nested paths
// ("group/foo-bundle") both match.
//
// To add an exclusion, add the leaf name to this map. Intentionally not
// exposed via env var or Terraform — keep the list small and reviewed.
var excludedRepos = map[string]bool{
	"apk-bundle":                true,
	"ca-apk-bundle":             true,
	"ca-dev-apk-bundle":         true,
	"chainguard-apk-bundle":     true,
	"chainguard-apk-dev-bundle": true,
	"chainguard-dev-apk-bundle": true,
	"custom-assembly-bundle":    true,
	"custom-assembly-packages":  true,
	"custom-packages":           true,
	"dev-apk-bundle":            true,
	"wolfi-bundle":              true,
	"wolfi-dev-apk-bundle":      true,
}

func isExcludedRepo(repoName string) bool {
	leaf := repoName
	if i := strings.LastIndex(repoName, "/"); i >= 0 {
		leaf = repoName[i+1:]
	}
	return excludedRepos[leaf]
}

func init() {
	err := envconfig.Process("", &env)
	if err != nil {
		log.Panicf("failed to process env var: %s", err)
	}

	azureCredential, err = azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		log.Panicf("failed to initialize Azure credential: %s", err)
	}
}

func main() {
	ctx := context.Background()
	receiver, err := receiver.New(ctx, env.Issuer, env.Group, func(ctx context.Context, event cloudevents.Event) error {
		// We are handling a specific event type, so filter the rest.
		if event.Type() != registry.PushedEventType {
			return nil
		}

		body := registry.PushEvent{}
		data := events.Occurrence{Body: &body}
		if err := event.DataAs(&data); err != nil {
			return cloudevents.NewHTTPResult(http.StatusBadRequest, "unable to unmarshal data: %w", err)
		}
		log.Printf("got event: %+v", data)

		// Check that the event is one we care about:
		// - It's not a push error.
		// - It's a tag push.
		// - Optionally, it's not a signature or attestation.
		if body.Error != nil {
			log.Printf("event body has error, skipping: %+v", body.Error)
			return nil
		}
		if body.Tag == "" || body.Type != "manifest" {
			log.Printf("event body is not a tag push, skipping: %q %q", body.Tag, body.Type)
			return nil
		}
		if env.IgnoreReferrers && strings.HasPrefix(body.Tag, "sha256-") {
			log.Printf("tag is a referrer; skipping: %q", body.Tag)
			return nil
		}

		// Resolve the repository ID to the name
		repoName, err := resolveRepositoryName(ctx, body.RepoID)
		if err != nil {
			return fmt.Errorf("failed to resolve repository name from id in the event: %w", err)
		}

		if isExcludedRepo(repoName) {
			log.Printf("repo %q is excluded; skipping", repoName)
			return nil
		}

		src := "cgr.dev/" + env.GroupName + "/" + repoName + ":" + body.Tag
		dst := env.DstRepo + "/" + repoName + ":" + body.Tag

		// Optionally verify the image signature.
		if env.VerifySignatures && !strings.HasPrefix(body.Tag, "sha256-") {
			log.Printf("Verifying signatures for %s...", src)
			src, err = verifyImageSignatures(ctx, src)
			if err != nil {
				return fmt.Errorf("verifying signature: %w", err)
			}
		}

		log.Printf("Copying %s to %s...", src, dst)
		if err := crane.Copy(src, dst, crane.WithAuthFromKeychain(keychain)); err != nil {
			return fmt.Errorf("copying image: %w", err)
		}
		log.Println("Copied!")
		return nil
	})
	if err != nil {
		log.Fatalf("failed to create receiver: %v", err)
	}

	c, err := cloudevents.NewClientHTTP(cloudevents.WithPort(env.Port),
		// We need to infuse the request onto context, so we can
		// authenticate requests.
		cehttp.WithRequestDataAtContextMiddleware())
	if err != nil {
		log.Fatalf("failed to create client, %v", err)
	}
	if err := c.StartReceiver(ctx, func(ctx context.Context, event cloudevents.Event) error {
		// This thunk simply wraps the main receiver in one that logs any errors
		// we encounter.
		err := receiver(ctx, event)
		if err != nil {
			log.Printf("SAW: %v", err)
		}
		return err
	}); err != nil {
		log.Fatal(err)
	}
}

func resolveRepositoryName(ctx context.Context, repoID string) (string, error) {
	// Generate a token for the Chainguard API
	tok, err := newToken(ctx, env.APIEndpoint)
	if err != nil {
		return "", fmt.Errorf("getting token: %w", err)
	}

	// Create clients that uses the token
	regc, err := v1.NewClients(ctx, env.APIEndpoint, tok.AccessToken)
	if err != nil {
		return "", fmt.Errorf("creating registry clients: %w", err)
	}
	iamc, err := iam.NewClients(ctx, env.APIEndpoint, tok.AccessToken)
	if err != nil {
		return "", fmt.Errorf("creating group clients: %w", err)
	}

	// Look up the name for each subrepository. This supports nested repos
	// like charts/cert-manager.
	var path []string
	parts := strings.Split(repoID, "/")
	for i := 1; i < len(parts); i++ {
		id := strings.Join(parts[:i+1], "/")

		// Each element in the path may be a 'repo' or a 'group', so we
		// need to try both.
		var name string
		groupList, err := iamc.Groups().List(ctx, &iam.GroupFilter{
			Id: id,
		})
		if err != nil {
			return "", fmt.Errorf("listing groups for %s: %w", id, err)
		}
		for _, group := range groupList.Items {
			name = group.Name
			break
		}
		if name == "" {
			repoList, err := regc.Registry().ListRepos(ctx, &v1.RepoFilter{
				Id: id,
			})
			if err != nil {
				return "", fmt.Errorf("listing repositories for %s: %w", id, err)
			}
			for _, repo := range repoList.Items {
				name = repo.Name
				break
			}
		}
		if name == "" {
			return "", fmt.Errorf("couldn't find repository or group name for id: %s", id)
		}
		path = append(path, name)
	}

	if len(path) == 0 {
		return "", fmt.Errorf("couldn't find full repository name for id: %s", repoID)
	}

	return strings.Join(path, "/"), nil
}

func newToken(ctx context.Context, audience string) (*sts.TokenPair, error) {
	exch := sts.New(env.Issuer, audience, sts.WithIdentity(env.Identity))
	tok, err := azureCredential.GetToken(ctx, policy.TokenRequestOptions{
		Scopes: []string{env.TokenScope},
	})
	if err != nil {
		return nil, fmt.Errorf("getting Azure token: %w", err)
	}
	cgTok, err := exch.Exchange(ctx, tok.Token)
	if err != nil {
		return nil, fmt.Errorf("exchanging token: %w", err)
	}

	return &cgTok, nil
}

type cgKeychain struct{}

func (k cgKeychain) Resolve(res authn.Resource) (authn.Authenticator, error) {
	if res.RegistryStr() != "cgr.dev" {
		return authn.Anonymous, nil
	}

	tok, err := newToken(context.Background(), res.RegistryStr())
	if err != nil {
		return nil, fmt.Errorf("getting token: %w", err)
	}

	return &authn.Basic{
		Username: "_token",
		Password: tok.AccessToken,
	}, nil
}

func verifyImageSignatures(ctx context.Context, src string) (string, error) {
	ref, err := name.ParseReference(src)
	if err != nil {
		return "", fmt.Errorf("parsing reference: %s: %w", src, err)
	}

	// Resolve the tag to the underlying digest so that we know we're
	// operating on the same image across all the commands we run
	digest, err := resolveDigest(ctx, ref)
	if err != nil {
		return "", fmt.Errorf("resolving digest for %s: %w", ref, err)
	}

	co, err := checkOpts(ctx)
	if err != nil {
		return "", fmt.Errorf("creating check opts: %w", err)
	}

	if _, _, err := cosign.VerifyImageSignatures(ctx, digest, co); err != nil {
		return "", fmt.Errorf("verifying image signatures: %w", err)
	}

	// Return the digest reference so that we can copy the same image we
	// verified
	return digest.String(), nil
}

func resolveDigest(ctx context.Context, ref name.Reference) (name.Digest, error) {
	desc, err := remote.Get(ref, remote.WithContext(ctx), remote.WithAuthFromKeychain(keychain))
	if err != nil {
		return name.Digest{}, fmt.Errorf("getting descriptor: %w", err)
	}

	return ref.Context().Digest(desc.Digest.String()), nil
}

func checkOpts(ctx context.Context) (*cosign.CheckOpts, error) {
	// Generate a token for the Chainguard API
	tok, err := newToken(ctx, env.APIEndpoint)
	if err != nil {
		return nil, fmt.Errorf("getting token: %w", err)
	}

	// Create client that uses the token
	client, err := iam.NewClients(ctx, env.APIEndpoint, tok.AccessToken)
	if err != nil {
		return nil, fmt.Errorf("creating IAM clients: %w", err)
	}

	trusted, err := cosign.TrustedRoot()
	if err != nil {
		return nil, fmt.Errorf("fetching trusted root: %w", err)
	}

	co := &cosign.CheckOpts{
		TrustedMaterial: trusted,
		RegistryClientOpts: []ociremote.Option{
			ociremote.WithMoreRemoteOptions(remote.WithAuthFromKeychain(keychain)),
		},
		Identities: []cosign.Identity{
			{
				Issuer:  "https://token.actions.githubusercontent.com",
				Subject: "https://github.com/chainguard-images/images-private/.github/workflows/release.yaml@refs/heads/main",
			},
		},
	}

	// Find the ids of the APKO_BUILDER and CATALOG_SYNCER and
	// add them to the list of trusted identities
	principals := []iam.ServicePrincipal{
		iam.ServicePrincipal_APKO_BUILDER,
		iam.ServicePrincipal_CATALOG_SYNCER,
	}
	ids, err := client.Identities().List(ctx, &iam.IdentityFilter{})
	if err != nil {
		return nil, fmt.Errorf("listing identities: %w", err)
	}
	if ids == nil || len(ids.Items) == 0 {
		return nil, fmt.Errorf("no identities were found")
	}
	for _, id := range ids.Items {
		if !slices.Contains(principals, id.GetServicePrincipal()) {
			continue
		}
		co.Identities = append(co.Identities, cosign.Identity{
			Issuer:  "https://issuer.enforce.dev",
			Subject: fmt.Sprintf("https://issuer.enforce.dev/%s", id.Id),
		})
	}

	return co, nil
}
