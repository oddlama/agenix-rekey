# agenix-rekey

`agenix-rekey` is an extension to agenix which facilitates using a master-key to manage
all secrets in your repository. Typically this will be a YubiKey or a password protected age identity.

What differentiates this from "classical" agenix is that your secrets will automatically be
rekeyed only for the hosts that require it. Also the rekeyed secrets don't need to be added
to your flake repository since they are entierly ephemeral. You can read [how it works](#how-does-it-work) below.

- No need to manually keep track of which key is needed for which host (no `secrets.nix`)
- Rekeyed secrets never have to be added to your flake repository, thus
  a leaked host-key doesn't allow an attacker to decrypt your secrets if your repo is public
- Rekeying will automatically use a dummy pubkey for new hosts,
  so you can bootstrap a new system for which the pubkey isn't yet known.

Remarks:

- Currently `age-plugin-yubikey` requires the PIN for each decryption. This will be fixed in their next release (>0.3.2).
- Using a password protected master key will always require the password for each rekeying operation. There's no way around that without caching the key, which is currently not done.

## Installation

#### Add `agenix-rekey` and define the apps

```nix
{
  inputs.agenix.url = "github:ryantm/agenix";
  inputs.agenix-rekey.url = "github:oddlama/agenix-rekey";
  # also works with inputs.ragenix.url = ...;
  # ...

  outputs = { self, nixpkgs, agenix, agenix-rekey }@inputs: {
    # change `yourhostname` to your actual hostname
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      # change to your system:
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        agenix.nixosModules.default
        agenix-rekey.nixosModules.default
      ];
    };
    # Adds the neccessary apps so you can rekey your secrets with `nix run '.#rekey'`
    apps."x86_64-linux" = agenix-rekey.defineApps inputs "x86_64-linux" self.nixosConfigurations;
  };
}
```

<details>
<summary>
Defining the `rekey` apps for multiple systems
</summary>

```nix
{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  # ... same as above

  outputs = { self, nixpkgs, agenix, agenix-rekey, flake-utils }@inputs: {
    # ... same as above
  } // flake-utils.lib.eachDefaultSystem (system: {
    apps = agenix-rekey.defineApps inputs system self.nixosConfigurations;
  });
}
```

</details>

<details>
<summary>
Using colmena instead of `nixosConfigurations`
</summary>

Technically you don't have to change anything to use colmena, but
if you chose to omit `nixosConfigurations` your `apps` definition might
need to be adjusted like below.

```nix
{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  # ... same as above

  outputs = { self, nixpkgs, agenix, agenix-rekey }@inputs: {
    colmena = {
      # ... your meta and hosts as described by the colmena manual
      exampleHost = {
        imports = [
          ./configuration.nix
          agenix.nixosModules.default
          agenix-rekey.nixosModules.default
        ];
      };
      # ...
    };
  } // flake-utils.lib.eachDefaultSystem (system: {
    apps = let
      inherit ((colmena.lib.makeHive self.colmena).introspect (x: x)) nodes;
    in
      agenix-rekey.defineApps inputs system nodes;
  });
}
```

</details>

## Usage

Since agenix-rekey is just a small extension, everything you know about agenix still applies as usual.
Its mainly the setup that has fewer steps. Look below for instructions on adapting an existing config.
For new installations, the setup process will be the following:

1. For each host you have to provide a pubkey for rekeying and select the master identity
   to use for decrypting. This is probably the same for each host.

    ```nix
    {
      # Obtain this using `ssh-keyscan` or by looking it up in your ~/.ssh/known_hosts
      rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...";
      # The path to the master identity used for decryption. See the option's description for more information.
      rekey.masterIdentities = [ ./your-yubikey-identity.pub ];
      #rekey.masterIdentities = [ "/home/myuser/master-key" ]; # External master key
      #rekey.masterIdentities = [ "/home/myuser/master-key.age" ]; # Password protected external master key
    }
    ```

2. Encrypt some secrets using age and your master key

    ```bash
    echo "secret" | age -e -r ./your-yubikey-identity.pub > secret1.age
    ```

3. Add secret to your config

    ```nix
    {
      rekey.secrets.secret1.file = ./secret1.age;
    }
    ```

4. Use secret to your config

    ```nix
    {
      users.users.user1 = {
        passwordFile = config.rekey.secrets.secret1.path;
        #passwordFile = config.age.secrets.secret1.path; # Using .age is also fine
      };
    }
    ```

5. Run `nixos-rebuild` or use your deployment tools as usual. If you need to rekey,
   you will be prompted to do that.

   If you are deploying your configuration to remote systems, you need to make sure that
   the correct derivation containing the rekeyed secrets is copied to the remote host's store.
   
   - [colmena](https://github.com/zhaofengli/colmena) automatically [copies](https://github.com/zhaofengli/colmena/issues/134) locally available derivations, so no additional care has to be taken here
   - I didn't test other tools.

## How does it work?

The central problem is that rekeying secrets on-the-fly while building your system
is fundamentally impossible, since it is an impure operation. It will always require
an external input in form of your master password or has to communicate with a YubiKey.

The second problem is that building your system requires the rekeyed secrets to be available
in the nix-store, which we want to achieve without requiring you to track them in git.

`agenix-rekey` solves the impurity by having you (the user) expose an app in your flake,
which you can invoke with `nix run '.#rekey'` whenever your secrets need to be rekeyed.
This script will be able to interactively run `age` to rekey the secrets and since it
has access to your host configurations it can infer which hosts use which secrets.

The more complicated second problem is solved by using a predictable store-path for
the resulting rekeyed secrets by putting them in a special derivation for each host.
This derivation is made to always fail when the build is invoked transitively by the
build process, which always means rekeying is necessary.

The `rekey` app will build the same derivation but with special access to the rekeyed
secrets which will temporarily be stored in a predicable path in `/tmp`, for which
the sandbox is allowed access to `/tmp` solving the impurity issue. Running the build
afterwards will succeed since the derivation is now already built and available in
your local store.
