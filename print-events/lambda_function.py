import json
import os
import time
import urllib.parse
import urllib.request

import boto3
import jwt

# Refresh the Chainguard token this many seconds before it expires.
_TOKEN_EXPIRY_BUFFER = 60

ISSUER_URL = "https://issuer.enforce.dev"


def _init_jwks_client():
    with urllib.request.urlopen(f"{ISSUER_URL}/.well-known/openid-configuration") as resp:
        config = json.loads(resp.read())
    return jwt.PyJWKClient(config["jwks_uri"])


# Initialised at cold start and cached for subsequent invocations.
_jwks_client = _init_jwks_client()


def verify_token(headers):
    # Get the token from the Authorization header
    auth_header = headers.get("Authorization") or headers.get("authorization", "")
    if not auth_header.startswith("Bearer "):
        raise ValueError(f"couldn't find bearer token in Authorization header")
    token = auth_header[len("Bearer "):]

    # Verify the token was signed by the Chainguard issuer
    try:
        signing_key = _jwks_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256", "ES256"],
            issuer=ISSUER_URL,
            options={"verify_aud": False},
        )
    except jwt.PyJWTError as e:
        raise ValueError(f"JWT verification failed: {e}") from e

    # The subject should be webhook:<org-id> 
    org_id = os.environ["ORG_ID"]
    expected_sub = f"webhook:{org_id}"
    if claims.get("sub") != expected_sub:
        raise ValueError(f"unexpected sub: {claims.get('sub')!r}, expected {expected_sub!r}")


# Cached Chainguard API token, refreshed when close to expiry.
_chainguard_token = None


def _fetch_chainguard_token():
    # Fetch an OIDC token from AWS for the Lambda's role
    sts = boto3.client("sts")
    web_identity_token = sts.get_web_identity_token(
        Audience=[ISSUER_URL],
        DurationSeconds=300,
        SigningAlgorithm="RS256",
    )["WebIdentityToken"]

    # Assume the identity by exchanging the AWS token for a Chainguard API token
    identity = os.environ["IDENTITY"]
    params = urllib.parse.urlencode({
        "aud": "https://console-api.enforce.dev",
        "identity": identity,
    })
    req = urllib.request.Request(
        f"{ISSUER_URL}/sts/exchange?{params}",
        method="POST",
        headers={
            "Authorization": f"Bearer {web_identity_token}",
            "User-Agent": "print-events/0.0.0",
            "Accept": "*/*",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["token"]


def get_chainguard_token():
    global _chainguard_token

    if _chainguard_token is not None:
        claims = jwt.decode(
            _chainguard_token,
            options={"verify_signature": False},
            algorithms=["RS256", "ES256"],
        )
        if claims.get("exp", 0) - time.time() > _TOKEN_EXPIRY_BUFFER:
            return _chainguard_token

    _chainguard_token = _fetch_chainguard_token()
    return _chainguard_token


def _api_get(token, path, params):
    req = urllib.request.Request(
        f"https://console-api.enforce.dev{path}?{urllib.parse.urlencode(params)}",
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": "print-events/0.0.0",
            "Accept": "*/*",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def get_identity(token, actor_subject):
    data = _api_get(token, "/iam/v1/identities", {"id": actor_subject})
    for item in data.get("items", []):
        return item
    return None


def get_email(token, actor_subject):
    org_id = os.environ["ORG_ID"]
    data = _api_get(token, "/iam/v1/rolebindings", {"uidp.childrenOf": org_id})
    for item in data.get("items", []):
        if item.get("identity") == actor_subject:
            email = item.get("email") or item.get("emailUnverified")
            return email or ""
    return ""


def get_repo_name(token, repo_id):
    parts = repo_id.split("/")
    path = []

    # The repo_id will usually look like one of these:
    #
    #   <org-id>/<repo-id>
    #   <org-id>/<group-id>/<repo-id>
    #
    # We need to iterate through, building up each segement and resolving the
    # name of the group or the repo so we can resolve the friendly names like:
    #
    #   your.org/grafana
    #   your.org/charts/grafana
    for i in range(len(parts)):
        id = "/".join(parts[:i + 1])
        name = ""
        for api_path in ["/iam/v1/groups", "/registry/v1/repos"]:
            try:
                data = _api_get(token, api_path, {"id": id})
            except Exception:
                continue
            for item in data.get("items", []):
                name = item.get("name")

        if name == "":
            raise ValueError(f"couldn't find repository or group name for id: {id}")

        path.append(name)

    if not path:
        raise ValueError(f"couldn't find full repository name for id: {repo_id}")

    return "/".join(path)


def handler(event, context):
    headers = event.get("headers") or {}

    ce_type = headers.get("Ce-Type") or headers.get("ce-type")

    # If CE_TYPES is set, ignore events with a type not in the list
    ce_types_env = os.environ.get("CE_TYPES", "")
    if ce_types_env:
        ce_types = [t.strip() for t in ce_types_env.split(",") if t.strip()]
        if ce_types and ce_type not in ce_types:
            print(f"skipping event with Ce-Type: {ce_type}")
            return {"statusCode": 200, "body": ""}

    # Verify that the token in the Authorization header was issued by
    # Chainguard for the expected group
    try:
        verify_token(headers)
    except ValueError as e:
        print(f"error: {e}")
        return {
            "statusCode": 401,
            "body": json.dumps({"error": "unauthorized"}),
        }

    # Get the event type from the headers
    print(f"TYPE: {ce_type}")

    # Extract fields from the JSON body
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        print("error: invalid JSON body")
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "invalid JSON body"}),
        }

    # Get the ID of the identity that performed the action 
    actor_subject = (body.get("actor") or {}).get("subject")
    print(f"IDENTITY_ID: {actor_subject}")

    # Get a token for the Chainguard API. We will use this to resolve more
    # details about the events.
    try:
        chainguard_token = get_chainguard_token()
    except Exception as e:
        print(f"error: failed to get Chainguard token: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "internal server error"}),
        }

    # Get the name of the identity. This will only find a value for identities
    # that exist inside the org.
    try:
        identity = get_identity(chainguard_token, actor_subject)
        if identity:
            print(f"IDENTITY_NAME: {identity.get('name')}")
            print(f"IDENTITY_DESCRIPTION: {identity.get('description')}")
    except Exception as e:
        print(f"error: failed to get identity: {e}")

    # Get the email of the identity from the role bindings. This will identify
    # users where the identity exists outside of the org.
    try:
        email = get_email(chainguard_token, actor_subject)
        if email:
            print(f"EMAIL: {email}")
    except Exception as e:
        print(f"error: failed to get email: {e}")

    # Get the name of the object from the body. Not all events will include this
    # field
    body_field = body.get("body") or {}

    name = body_field.get("name")
    if name:
        print(f"NAME: {name}")

    # Look up the repo if a repo_id is present in the body. We need to do this
    # because the 'repository' field will not always contain the friendly name
    # of the repo.
    repo_id = body_field.get("repo_id")
    if repo_id:
        try:
            repo_name = get_repo_name(chainguard_token, repo_id)
            print(f"REPO_NAME: {repo_name}")
        except Exception as e:
            print(f"error: failed to get repo name: {e}")

    # Print the whole body
    print(f"BODY: {json.dumps(body)}")

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "ok"}),
    }
