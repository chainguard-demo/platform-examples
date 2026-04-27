/*
Copyright 2026 Chainguard, Inc.
SPDX-License-Identifier: Apache-2.0
*/

package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"log"
	"time"

	common "chainguard.dev/sdk/proto/platform/common/v1"
	iam "chainguard.dev/sdk/proto/platform/iam/v1"
	"chainguard.dev/sdk/sts"
	"chainguard.dev/sdk/uidp"
	awslambda "github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	awssts "github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"github.com/kelseyhightower/envconfig"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type envConfig struct {
	APIEndpoint   string        `envconfig:"API_ENDPOINT" required:"true"`
	Issuer        string        `envconfig:"ISSUER_URL" required:"true"`
	OrgName       string        `envconfig:"ORG_NAME" required:"true"`
	Group         string        `envconfig:"GROUP" required:"true"`
	Identity      string        `envconfig:"IDENTITY" required:"true"`
	SecretID      string        `envconfig:"SECRET_ID" required:"true"`
	TokenTTL      time.Duration `envconfig:"TOKEN_TTL" default:"336h"`
	PullTokenName string        `envconfig:"PULL_TOKEN_NAME" required:"true"`
}

const (
	pullTokenIssuer = "https://pulltoken.issuer.chainguard.dev"
	pullTokenRole   = "registry.pull"
)

var env envConfig

func init() {
	if err := envconfig.Process("", &env); err != nil {
		log.Panicf("failed to process env vars: %s", err)
	}
}

func main() {
	awslambda.Start(handler)
}

func handler(ctx context.Context) error {
	// Get a token for the Chainguard API
	cgTok, err := newToken(ctx, env.APIEndpoint)
	if err != nil {
		return fmt.Errorf("getting Chainguard token: %w", err)
	}

	// Create the IAM client
	iamc, err := iam.NewClients(ctx, env.APIEndpoint, cgTok.AccessToken)
	if err != nil {
		return fmt.Errorf("creating IAM clients: %w", err)
	}

	// Create the pull token
	username, accessToken, err := createPullToken(ctx, iamc)
	if err != nil {
		return fmt.Errorf("creating pull token: %w", err)
	}

	// Update the secret with the new pull token
	if err := updateSecret(ctx, username, accessToken); err != nil {
		return fmt.Errorf("updating secret: %w", err)
	}

	// Remove any old expired tokens
	if err := cleanupExpiredPullTokens(ctx, iamc); err != nil {
		// Don't fail the invocation — the new token is already in place.
		log.Printf("warning: cleanup of expired identities failed: %v", err)
	}

	return nil
}

func newToken(ctx context.Context, audience string) (*sts.TokenPair, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("loading AWS config: %w", err)
	}
	awsClient := awssts.NewFromConfig(cfg)
	out, err := awsClient.GetWebIdentityToken(ctx, &awssts.GetWebIdentityTokenInput{
		Audience:         []string{env.Issuer},
		SigningAlgorithm: aws.String("ES384"),
		DurationSeconds:  aws.Int32(300),
	})
	if err != nil {
		return nil, fmt.Errorf("getting AWS web identity token: %w", err)
	}
	exch := sts.New(env.Issuer, audience, sts.WithIdentity(env.Identity))
	cgTok, err := exch.Exchange(ctx, *out.WebIdentityToken)
	if err != nil {
		return nil, fmt.Errorf("exchanging token: %w", err)
	}
	return &cgTok, nil
}

func createPullToken(ctx context.Context, iamc iam.Clients) (string, string, error) {
	now := time.Now()
	exp := now.Add(env.TokenTTL)

	// Generate a throwaway key and create a signer for it
	pk, err := rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		return "", "", fmt.Errorf("generating RSA key: %w", err)
	}
	jwk := jose.JSONWebKey{Algorithm: string(jose.RS256), Key: pk}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: jwk.Key}, nil)
	if err != nil {
		return "", "", fmt.Errorf("creating signer: %w", err)
	}
	jwksJSON, err := json.Marshal(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{jwk.Public()}})
	if err != nil {
		return "", "", fmt.Errorf("marshalling JWKS: %w", err)
	}

	// Resolve the role to bind
	roles, err := iamc.Roles().List(ctx, &iam.RoleFilter{Name: pullTokenRole})
	if err != nil {
		return "", "", fmt.Errorf("listing roles: %w", err)
	}
	if len(roles.Items) == 0 {
		return "", "", fmt.Errorf("role %q not found", pullTokenRole)
	}
	roleID := roles.Items[0].Id

	// Sign the pull token
	subject := "pull-token-" + uidp.NewUID().String()
	tok, err := jwt.Signed(signer).Claims(jwt.Claims{
		Issuer:   pullTokenIssuer,
		IssuedAt: jwt.NewNumericDate(now),
		Expiry:   jwt.NewNumericDate(exp),
		Subject:  subject,
		Audience: jwt.Audience{env.Issuer},
	}).Serialize()
	if err != nil {
		return "", "", fmt.Errorf("signing JWT: %w", err)
	}

	// Create an identity for the token
	created, err := iamc.Identities().Create(ctx, &iam.CreateIdentityRequest{
		ParentId: env.Group,
		Identity: &iam.Identity{
			Name: env.PullTokenName,
			Relationship: &iam.Identity_Static{
				Static: &iam.Identity_StaticKeys{
					Issuer:     pullTokenIssuer,
					Subject:    subject,
					IssuerKeys: string(jwksJSON),
					Expiration: timestamppb.New(exp),
				},
			},
		},
	})
	if err != nil {
		return "", "", fmt.Errorf("creating identity: %w", err)
	}

	// Bind the role to the new identity.
	if _, err := iamc.RoleBindings().Create(ctx, &iam.CreateRoleBindingRequest{
		Parent: env.Group,
		RoleBinding: &iam.RoleBinding{
			Identity: created.Id,
			Group:    env.Group,
			Role:     roleID,
		},
	}); err != nil {
		return "", "", fmt.Errorf("creating role binding: %w", err)
	}

	log.Printf("created pull token: identity=%s expires=%s", created.Id, exp.Format(time.RFC3339))

	return created.Id, tok, nil
}

func updateSecret(ctx context.Context, username, accessToken string) error {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return fmt.Errorf("loading AWS config: %w", err)
	}
	secret, err := json.Marshal(map[string]string{
		"username":    username,
		"accessToken": accessToken,
	})
	if err != nil {
		return fmt.Errorf("marshalling secret: %w", err)
	}
	sm := secretsmanager.NewFromConfig(cfg)
	if _, err := sm.PutSecretValue(ctx, &secretsmanager.PutSecretValueInput{
		SecretId:     aws.String(env.SecretID),
		SecretString: aws.String(string(secret)),
	}); err != nil {
		return fmt.Errorf("putting secret value: %w", err)
	}
	log.Printf("updated secret %s", env.SecretID)
	return nil
}

func cleanupExpiredPullTokens(ctx context.Context, iamc iam.Clients) error {
	list, err := iamc.Identities().List(ctx, &iam.IdentityFilter{
		Uidp: &common.UIDPFilter{DescendantsOf: env.Group},
	})
	if err != nil {
		return fmt.Errorf("listing identities: %w", err)
	}
	now := time.Now()
	var deleted int
	for _, id := range list.Items {
		if id.Name != env.PullTokenName {
			continue
		}
		st := id.GetStatic()
		if st == nil {
			continue
		}
		if st.Expiration.AsTime().After(now) {
			continue
		}
		if _, err := iamc.Identities().Delete(ctx, &iam.DeleteIdentityRequest{Id: id.Id}); err != nil {
			log.Printf("warning: failed to delete expired identity %s: %v", id.Id, err)
			continue
		}
		deleted++
	}
	log.Printf("cleaned up %d expired identities", deleted)
	return nil
}
