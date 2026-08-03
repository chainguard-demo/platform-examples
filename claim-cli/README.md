# claim-cli

Parse a Chainguard JWT or capabilities string into human readable tables.

## Usage

### Capabilities string from JWT

`claim-cli read AAAAAAAAAMH_8gDx4eD__vn--DBJ__tvlCHm8B_wHmMAAAAAAAAAAQ==`

```
┌─────────────────────────────────────────┬────────────────┐
│                 ENTITY                  │     ACTION     │
├─────────────────────────────────────────┼────────────────┤
│ groups                                  │ create         │
│ groups                                  │ update         │
│ groups                                  │ list           │
│ groups                                  │ delete         │
│ group_invites                           │ create         │
│ group_invites                           │ list           │
│ group_invites                           │ delete         │
.....
```


### JWT Parsing

`chainctl auth token | claim-cli read --jwt -`

```
┌──────────────────────────────────────────┬─────────────────────────────────────────┬────────────────┐
│                   ORG                    │                 ENTITY                  │     ACTION     │
├──────────────────────────────────────────┼─────────────────────────────────────────┼────────────────┤
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ groups                                  │ create         │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ groups                                  │ update         │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ groups                                  │ list           │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ groups                                  │ delete         │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ group_invites                           │ create         │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ group_invites                           │ list           │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ group_invites                           │ delete         │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ roles                                   │ create         │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ roles                                   │ update         │
│ asdfasdfasdfasdfasdfasdfasdfasdfasdfasdf │ roles                                   │ list           │
.....
```
