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
	"os"
	"slices"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/containers/azcontainerregistry"
	"chainguard.dev/sdk/events"
	"chainguard.dev/sdk/events/receiver"
	"chainguard.dev/sdk/events/registry"
	iam "chainguard.dev/sdk/proto/platform/iam/v1"
	v1 "chainguard.dev/sdk/proto/platform/registry/v1"
	"chainguard.dev/sdk/sts"
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
	AcrRegistry      string `envconfig:"ACR_REGISTRY"`
	IgnoreReferrers  bool   `envconfig:"IGNORE_REFERRERS" required:"true"`
	VerifySignatures bool   `envconfig:"VERIFY_SIGNATURES" required:"true"`
}

var env envConfig
var keychain authn.Keychain
var acrRegistry string
var azureCredential azcore.TokenCredential

func init() {
	if err := envconfig.Process("", &env); err != nil {
		log.Panicf("failed to process env var: %s", err)
	}

	acrRegistry = strings.TrimSpace(env.AcrRegistry)
	if acrRegistry == "" {
		acrRegistry = strings.TrimSpace(dstRegistryFromRepo(env.DstRepo))
	}
	if acrRegistry == "" {
		log.Panic("failed to determine ACR registry; set ACR_REGISTRY or provide DST_REPO with a registry")
	}
	log.Printf("using ACR registry: %s", acrRegistry)

	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		log.Panicf("failed to initialize Azure credential: %s", err)
	}
	azureCredential = cred

	keychain = authn.NewMultiKeychain(
		cgKeychain{},
		acrKeychain{
			registry: acrRegistry,
		},
		authn.DefaultKeychain,
	)
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

	// Create client that uses the token
	client, err := v1.NewClients(ctx, env.APIEndpoint, tok.AccessToken)
	if err != nil {
		return "", fmt.Errorf("creating clients: %w", err)
	}

	// Lookup the repository name from the ID
	repoList, err := client.Registry().ListRepos(ctx, &v1.RepoFilter{
		Id: repoID,
	})
	if err != nil {
		return "", fmt.Errorf("listing repositories: %w", err)
	}
	for _, repo := range repoList.Items {
		return repo.Name, nil
	}

	return "", fmt.Errorf("couldn't find repository name for id: %s", repoID)
}

func newToken(ctx context.Context, audience string) (*sts.TokenPair, error) {
	exch := sts.New(env.Issuer, audience, sts.WithIdentity(env.Identity))
	tok, err := loadOIDCToken()
	if err != nil {
		return nil, fmt.Errorf("loading OIDC token: %w", err)
	}
	cgTok, err := exch.Exchange(ctx, tok)
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

type acrKeychain struct {
	registry string
}

func (k acrKeychain) Resolve(res authn.Resource) (authn.Authenticator, error) {
	if res.RegistryStr() != k.registry {
		return authn.Anonymous, nil
	}

	return acrAuthenticator{registry: k.registry}, nil
}

type acrAuthenticator struct {
	registry string
}

func (a acrAuthenticator) Authorization() (*authn.AuthConfig, error) {
	return a.AuthorizationContext(context.Background())
}

func (a acrAuthenticator) AuthorizationContext(ctx context.Context) (*authn.AuthConfig, error) {
	token, err := acrRefreshToken(ctx, a.registry)
	if err != nil {
		return nil, err
	}

	return &authn.AuthConfig{
		IdentityToken: token,
	}, nil
}

func acrRefreshToken(ctx context.Context, registry string) (string, error) {
	tok, err := azureCredential.GetToken(ctx, policyTokenRequestOptions())
	if err != nil {
		return "", fmt.Errorf("getting Azure access token: %w", err)
	}

	client, err := azcontainerregistry.NewAuthenticationClient("https://"+registry, nil)
	if err != nil {
		return "", fmt.Errorf("creating ACR auth client: %w", err)
	}

	resp, err := client.ExchangeAADAccessTokenForACRRefreshToken(
		ctx,
		azcontainerregistry.PostContentSchemaGrantTypeAccessToken,
		registry,
		&azcontainerregistry.AuthenticationClientExchangeAADAccessTokenForACRRefreshTokenOptions{
			AccessToken: &tok.Token,
		},
	)
	if err != nil {
		return "", fmt.Errorf("exchanging AAD token for ACR refresh token: %w", err)
	}
	if resp.RefreshToken == nil || strings.TrimSpace(*resp.RefreshToken) == "" {
		return "", fmt.Errorf("ACR refresh token response was empty")
	}

	return *resp.RefreshToken, nil
}

func policyTokenRequestOptions() policy.TokenRequestOptions {
	return policy.TokenRequestOptions{
		Scopes: []string{"https://containerregistry.azure.net/.default"},
	}
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

func loadOIDCToken() (string, error) {
	if token := strings.TrimSpace(os.Getenv("OIDC_TOKEN")); token != "" {
		return token, nil
	}
	if tokenFile := strings.TrimSpace(os.Getenv("OIDC_TOKEN_FILE")); tokenFile != "" {
		return loadTokenFile(tokenFile)
	}
	if tokenFile := strings.TrimSpace(os.Getenv("AZURE_FEDERATED_TOKEN_FILE")); tokenFile != "" {
		return loadTokenFile(tokenFile)
	}

	return "", fmt.Errorf("no OIDC token source found; set OIDC_TOKEN, OIDC_TOKEN_FILE, or AZURE_FEDERATED_TOKEN_FILE")
}

func loadTokenFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("reading token file: %w", err)
	}
	return strings.TrimSpace(string(data)), nil
}

func dstRegistryFromRepo(repo string) string {
	parts := strings.SplitN(repo, "/", 2)
	if len(parts) == 0 {
		return ""
	}
	return parts[0]
}
