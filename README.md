[Installation](#installation) \| [Usage](#usage) \| [How does it work?](#how-does-it-work) \| [Module options](#module-options)

# agenix-rekey

`agenix-rekey` is an extension for [agenix](https://github.com/ryantm/agenix) which facilitates using a YubiKey
(or just a master age identity) to store all secrets in your repository, which can be especially useful for
flakes that manage multiple hosts. This is what you get from using it:

- **Single master-key.** Anything in your repository is encrypted by your master YubiKey or age identity.
- **Host-key deduction.** No need to manually keep track of which key is needed for which host - no `secrets.nix`.
- **Less secret management.** Rekeyed secrets never have to be added to your flake repository, thus
  you only have to keep track of the actual secret. Also a leaked host-key doesn't allow an attacker to decrypt
  older checked-in secrets, in case your repo is public.
- **Lazy rekeying.** Rekeying only has to be done if necessary, results are cached in a derivation. If a new secret is added
  or a host key is changed, you will automatically be prompted to rekey your secrets.
- **Simplified bootstrapping.** Automatic rekeying will use a dummy pubkey for unknown target hosts,
  so you can bootstrap a new system for which the pubkey isn't yet known. (Runtime decryption will just fail)

You can read more about [how it works](#how-does-it-work) below. Remarks:

- Since `age-plugin-yubikey` 0.4.0 the PIN is required only once. Using a password protected master key will never
  have this benefit, and the password will alwas be required for each rekeying operation. There's no way around that without caching the key, which I didn't want to do.

## Installation

Add `agenix-rekey` to your flake.nix, add the module to your hosts
and let agenix-rekey define the necessary apps on your flake:

```nix
{
  inputs.agenix.url = "github:ryantm/agenix";
  inputs.agenix-rekey.url = "github:oddlama/agenix-rekey";
  # also works with inputs.ragenix.url = ...;
  # ...

  outputs = { self, nixpkgs, agenix, agenix-rekey }: {
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

    # Some initialized nixpkgs set
    pkgs = import nixpkgs { system = "x86_64-linux"; };
    # Adds the neccessary apps so you can rekey your secrets with `nix run '.#rekey'`
    apps."x86_64-linux" = agenix-rekey.defineApps self pkgs self.nixosConfigurations;
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
    pkgs = import nixpkgs { inherit system; };
    apps = agenix-rekey.defineApps self pkgs self.nixosConfigurations;
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
    pkgs = import nixpkgs { inherit system; };
    apps = agenix-rekey.defineApps self pkgs nodes ((colmena.lib.makeHive self.colmena).introspect (x: x)).nodes;
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

2. Encrypt some secrets using (r)age and your master key. `agenix-rekey` defines the `edit-secret` app in your flake,
   which allows you to edit/create secrets using your favorite `$EDITOR`, and automatically uses the correct identities for de- and encryption.

    ```bash
    nix run ".#edit-secret" secret1.age

    # Alternatively you can encrypt something manually using (r)age
    echo "secret" | rage -e -i ./your-yubikey-identity.pub > secret1.age
    ```

   Be careful when chosing your `$EDITOR` here, it might leak secret information when editing the file
   by means of undo-history, or caching in general. For `vim` and `nvim` this app automatically disables related options.

3. Add the secret to your config

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

        # Since this is just a wrapper, only the definition must use rekey.secrets.
        # If you prefer, you may use it by accessing age.secrets directly.
        #passwordFile = config.age.secrets.secret1.path;
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

#### Working with impurity

`agenix-rekey` solves the impurity problem by requiring you to expose an app in your flake,
which you can invoke with `nix run '.#rekey'` whenever your secrets need to be rekeyed.
This script will run in your host-environment and thus is able to prompt for passwords
or read YubiKeys. It therefore can run `age` to rekey the secrets and since it still
has access to your host configurations in your flake, it can still access all necessary information.

#### Predicting store paths to avoid tracking rekeyed secrets

The more complicated second problem is solved by using a predictable store-path for
the resulting rekeyed secrets by putting them in a special derivation for each host.
This derivation is made to always fail when the build is invoked transitively by the
build process, which always means rekeying is necessary.

The `rekey` app will build the same derivation but with special access to the rekeyed
secrets which will temporarily be stored in a predicable path in `/tmp`, for which
the sandbox is allowed access to `/tmp` solving the impurity issue. Running the build
afterwards will succeed since the derivation is now already built and available in
your local store.

# Module options

## `rekey.secrets`

Refers to the same options as exposed by agenix. See [`age.secrets`](https://github.com/ryantm/agenix#reference).

## `rekey.forceRekeyOnSystem`

| Type    | `nullOr str` |
|-----|-----|
| Default | `null` |
| Example | `"x86_64-linux"` |

If set, this will force that all secrets are rekeyed on a system of the given architecture.
This is important if you have several hosts with different architectures, since you usually
don't want to build the derivation containing the rekeyed secrets on a random remote host.

The problem is that each derivation will always depend on at least one specific architecture
(often it's bash), since it requires a builder to create it. Usually the builder will use the
architecture for which the package is built, which makes sense. Since it is part of the derivation
inputs, we have to know it in advance to predict where the output will be. If you have multiple
architectures, then we'd have multiple candidate derivations for the rekeyed secrets, but we want
a single predictable derivation.

If you would try to deploy an aarch64-linux system, but are on x86_64-linux without binary
emulation, then nix would have to build the rekeyed secrets using a remote builder (since the
derivation then requires aarch64-linux bash). This option will override the pkgs set passed to
the derivation such that it will use a builder of the specified architecture instead. This way
you can force it to always require a x86_64-linux bash, thus allowing your local system to build it.

The "automatic" and nice way would be to set this to builtins.currentSystem, but that would
also be impure, so unfortunately you have to hardcode this option.

## `rekey.hostPubkey`

| Type    | `coercedTo path (x: if isPath x then readFile x else x) str` |
|-----|-----|
| Default | `"age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"` |
| Example | `"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI....."` |
| Example | `./host1-pubkey.pub` |
| Example | `"/etc/ssh/ssh_host_ed25519_key.pub"` |

The age public key to use as a recipient when rekeying. This either has to be the
path to an age public key file, or the public key itself in string form.

If you are managing a single host only, you can use `"/etc/ssh/ssh_host_ed25519_key.pub"`
here to allow the rekey app to directly read your pubkey from your system.
If you are managing multiple hosts, it's recommended to either store a copy of each
host's pubkey in your flake and use refer to those here `./secrets/host1-pubkey.pub`,
or directly set the host's pubkey here by specifying `"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."`.

Make sure to NEVER use a private key here, as it will end up in the public nix store!

## `rekey.masterIdentities`

| Type    | `listOf (coercedTo path toString str)` |
|-----|-----|
| Default | `[]` |
| Example | `[./secrets/my-public-yubikey-identity.txt]` |

The list of age identities that will be presented to `rage` when decrypting the stored secrets
to rekey them for your host(s). If multiple identities are given, they will be tried in-order.

The recommended options are:

- Use a split-identity ending in `.pub`, where the private part is not contained (a yubikey identity)
- Use an absolute path to your key outside of the nix store ("/home/myuser/age-master-key")
- Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
  using `rage -p -o privkey.age privkey` which protects it in your store.

If you are using YubiKeys, you can specify multiple split-identities here and use them interchangeably.
You will have the option to skip any YubiKeys that are not available to you in that moment.

Be careful when using paths here, as they will be copied to the nix store. Using
split-identities is fine, but if you are using plain age identities, make sure that they
are password protected.

## `rekey.extraEncryptionPubkeys`

| Type    | `listOf (coercedTo path toString str)` |
|-----|-----|
| Default | `[]` |
| Example | `[./backup-key.pub "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"]` |
| Example | `["age1yubikey1qwf..."]` |

When using `nix run '.#edit-secret' FILE`, the file will be encrypted for all identities in
rekey.masterIdentities by default. Here you can specify an extra set of pubkeys for which
all secrets should also be encrypted. This is useful in case you want to have a backup indentity
that must be able to decrypt all secrets but should not be used when attempting regular decryption.

If the coerced string is an absolute path, it will be used as if it was a recipient file.
Otherwise, the string will be interpreted as a public key.

## `rekey.agePlugins`

| Type    | `listOf package` |
|-----|-----|
| Default | `[rekeyHostPkgs.age-plugin-yubikey]` |
| Example | `[]` |

A list of plugins that should be available to rage while rekeying.
They will be added to the PATH with lowest-priority before rage is invoked,
meaning if you have the plugin installed on your system, that one is preferred
in an effort to not break complex setups (e.g. WSL passthrough).
