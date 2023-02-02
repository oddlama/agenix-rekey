# agenix-rekey

agenix-rekey allows you to use a master-key to manage all secrets in your repository -
typically this will be a YubiKey or a password protected age identity.

Secrets will automatically be rekeyed only for the hosts that require it. This removes the
need to manually keep track of which key is needed for which host, and prevents unecessary
repository clutter. Rekeyed secrets will be put into a predictable store path which means
they can be entierly ephemeral and never need to be added to your repository.

## How does it work?

The central problem is that rekeying secrets on-the-fly while building yours system
is fundamentally impossible, since it is an impure operation. It will always require
an external input in form of your master password or has to communicate with a YubiKey.

The second problem is that building your system requires the rekeyed secrets to be available
in the nix-store, which we want to achieve without requiring you to track them in git.

agenix-rekey solves the impurity by having you (the user) expose an app in your flake,
which you can invoke with `nix run '.#rekey'` whenever your secrets need to be rekeyed.
This script will be able to interactively run `age` to rekey the secrets and since it
has access to your host configurations it can infer which hosts use which secrets.

The more complicated second problem is solved by using a predictable store-path for
the resulting rekeyed secrets by putting them in a special derivation for each host.
This derivation is made to always fail when the build is invoked transitively by the
build process, which always means a rekey is necessary.

The rekey app will build the same derivation but with special access to the rekeyed
secrets which will temporarily be stored in a predicable path in `/tmp`, for which
the sandbox is allowed access to `/tmp` solving the impurity issue. Running the build
afterwards will succeed since the derivation is then already built and available in
your local store.

## Usage

#### Add `agenix-rekey` and define the apps

```nix
{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.agenix-rekey.url = "github:oddlama/agenix-rekey";
  inputs.agenix.url = "github:ryantm/agenix";
  # also works with inputs.ragenix.url = ...;
  # ...

  outputs = { self, agenix-rekey, ... }@inputs:
    {
	  # ... your usual config
	  nixosConfigurations = { #...
	  };
    }
    // flake-utils.lib.eachDefaultSystem (system: {
	  # Adds the neccessary apps so you can rekey your secrets with `nix run '.#rekey'`
      apps = agenix-rekey.defineApps inputs system self.nixosConfigurations;

      # For colmena you can use this:
      # apps = let
      #   inherit ((colmena.lib.makeHive self.colmena).introspect (x: x)) nodes;
      # in
      #   agenix-rekey.defineApps inputs system nodes;
    });
}
```

#### Change secret definitions

To allow the rekeying process to work, agenix-rekey must be able to change the encrypted file agenix tries to use.
Furthermore, some meta information is required so the rekey app knows which identity to use for decrypting.
Simply replace all `age.secrets` with `rekey.secrets` in your config:

```nix
rekey.secrets.test.file = ./some-secret-encrypted-with-master-key.age
# Identities to try in decryption process
rekey.masterIdentities = [ ./yubikey-identity.pub ]; # Passwort-encrypted master key (will enter the store, but that's fine)
# TODO allow path in masterident
```

If you are using a special tool to deploy your configuration on remote systems, you need
to make sure that the derivation containing the rekeyed secrets is copied to the store of
the host for which it is intended. This may depend on whether you are using remote-builders
and other details of your particular tool.

- [colmena](https://github.com/zhaofengli/colmena) automatically [copies](https://github.com/zhaofengli/colmena/issues/134) locally available derivations, so no additional care has to be taken here
- I didn't test other tools.

# Bootstrapping a host for which the ssh host key isn't known (Chicken-egg problem)
