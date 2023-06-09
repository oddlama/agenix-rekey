[Installation](#installation) \| [Usage](#usage) \| [How does it work?](#how-does-it-work) \| [Module options](#module-options)

# agenix-rekey

This is an extension for [agenix](https://github.com/ryantm/agenix) which allows you to ged rid
of maintaining a `secrets.nix` file by re-encrypting secrets where needed.
It also allows you to define versatile generators for secrets,
so they can be bootstrapped automatically. This extension is a flakes-only project
and can be used alongside regular use of agenix.

To make use of rekeying, you will have to store secrets in your repository by encrypting
them with a master key (YubiKey or regular age identity), and agenix-rekey will automatically
re-encrypt these secrets for any host that requires them. In summary:

- 🔑 **Single master-key.** Anything in your repository is encrypted by your master YubiKey or age identity.
- ➡️ **Host-key inference.** No need to manually keep track of which key is needed for which host - no `secrets.nix`.
- ✔️ **Less secret management.** Rekeyed secrets never have to be added to your flake repository, thus
  you only have to keep track of the actual secret. Also a leaked host-key doesn't allow an attacker to decrypt
  older checked-in secrets, in case your repo is public.
- 🦥 **Lazy rekeying.** Rekeying only occurs when necessary, since the results are cached in a local derivation.
  If a new secret is added or a host key is changed, you will automatically be prompted to rekey.
- 🚀 **Simplified host bootstrapping.** Automatic rekeying can use a dummy pubkey for unknown target hosts,
  so you can bootstrap a new system for which the pubkey isn't yet known. Runtime decryption will of
  course fail, but then the ssh host key will be generated.
- 🔐 **Secret generation.** You can define generators to bootstrap secrets. Very useful if you want random
  passwords for a service, need random wireguard private/preshared keys, or need to aggregate several
  secrets into a derived secret (for example by generating a .htpasswd file).

To function properly, agenix-rekey has to do some nix gymnastics. You can read more about [how it works](#how-does-it-work) below. Remarks:

- Since `age-plugin-yubikey` 0.4.0 the PIN is required only once. Using a password protected master key will never
  have this benefit, and the password will alwas be required for each rekeying operation.
  There's no way around that without caching the key, which I didn't want to do.

## Installation

First, add agenix-rekey to your `flake.nix`, add the module to your hosts
and let agenix-rekey define the necessary apps on your flake.

The exposed apps can be called with `nix run .#<appname>`.

- `generate-secrets`: Generates any secrets that don't exist yet and have a generator set.
- `edit-secret`: Create/edit secrets using `$EDITOR`. Can encrypt existing files.
- `rekey`: Rekeys secrets for hosts that require them.

Use `nix run .#<appname> -- --help` for specific usage information.

```nix
{
  inputs.agenix.url = "github:ryantm/agenix";
  inputs.agenix-rekey.url = "github:oddlama/agenix-rekey";
  # also works with inputs.ragenix.url = ...;
  # ...

  outputs = { self, nixpkgs, agenix, agenix-rekey }: {
    # Example system configuration
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        agenix.nixosModules.default
        agenix-rekey.nixosModules.default
      ];
    };

    # Some initialized nixpkgs set
    pkgs = import nixpkgs { system = "x86_64-linux"; };
    # Adds the neccessary apps so you can rekey your secrets with `nix run .#rekey`
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

Since agenix-rekey is just an extension, everything you know about agenix still applies as usual.
Apart from specifying meta information about your master key, the only thing that you have to change
to use rekeying is to sepcify `rekeyFile` instead of `file`. The full setup process is the following:

1. For each host you have to provide a pubkey for rekeying and select the master identity
   to use for decrypting. Apart for `hostPubkey`, this is probably the same for each host.
   If other attributes do differ between hosts, they will usually be merged when invoking the apps.

    ```nix
    {
      age.rekey = {
        # Obtain this using `ssh-keyscan` or by looking it up in your ~/.ssh/known_hosts
        hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...";
        # The path to the master identity used for decryption. See the option's description for more information.
        masterIdentities = [ ./your-yubikey-identity.pub ];
        #masterIdentities = [ "/home/myuser/master-key" ]; # External master key
        #masterIdentities = [ "/home/myuser/master-key.age" ]; # Password protected external master key
      };
    }
    ```

2. Encrypt some secrets using (r)age and your master key. `agenix-rekey` defines the `edit-secret` app in your flake,
   which allows you to easily create/edit secrets using your favorite `$EDITOR`, and automatically uses the correct identities for de- and encryption.

    ```bash
    # Create new or edit existing secret
    nix run .#edit-secret secret1.age
    # Or encrypt an existing file
    nix run .#edit-secret -i plain.txt secret1.age
    # If no parameter is given, this will present an interactive list with all defined secrets
    nix run .#edit-secret

    # Alternatively you can of course manually encrypt something using (r)age
    echo "secret" | rage -e -i ./your-yubikey-identity.pub > secret1.age
    ```

   Be careful when chosing your `$EDITOR` here, it might leak secret information when editing the file
   by means of undo-history, or caching in general. For `vim` and `nvim` this app automatically disables related options.

3. Define and use the secret in your config

    ```nix
    {
      # Note that the option is called `rekeyFile` and not `file` if you want to use rekeying!
      age.secrets.secret1.rekeyFile = ./secret1.age;
      users.users.user1.passwordFile = config.age.secrets.secret1.path;
    }
    ```

4. Deploy you system as usual by using `nixos-rebuild` or your favourite deployment tool.
   In case you need to rekey, you will be prompted to do that as part of a build failure that will be triggered.

   If you are deploying your configuration to remote systems, you need to make sure that
   the correct derivation containing the rekeyed secrets is copied from your local store
   to the remote host's store.

   - [colmena](https://github.com/zhaofengli/colmena) automatically [copies](https://github.com/zhaofengli/colmena/issues/134) locally available derivations, so no additional care has to be taken here
   - I didn't test other tools. Please add your experiences here.

## Secret generation

With agenix-rekey, you can define generators on your secrets which can be used
to bootstrap secrets or derive secrets from other secrets.

In the simplest cases you can refer to a predefined existing generator,
the example below would generate a random 6 word passphrase using the
`age.generators.passphrase` generator:

```nix
{
  age.secrets.randomPassword = {
    rekeyFile = ./secrets/randomPassword.age;
    generator = "passphrase";
  };
}
```

You can also define your own generators, either by creating an entry in `age.generators`
to make a reusable generator like `"passphrase"` above, or directly by setting
`age.secrets.<name>.generator` to a generator definition.

A generator is a set consisting of two attributes, a `script` and optionally `dependencies`.
The `script` must be a function taking some arguments in an attrset and has to return a bash
script, which writes the desired secret to stdout. A very simple (and bad) generator would
be `{ ... }: "echo very-secret"`.

The arguments passed to the `script` will contain some useful attributes that we
can use to define our generation script.

| Argument | Description |
|-----|-----|
| `name`    | The name of the secret to be generated, as defined in `age.secrets.<name>` |
| `secret`  | The definition of the secret to be generated |
| `lib`     | Convenience access to the nixpkgs library |
| `pkgs`    | The package set for the _host that is running the generation script_. Don't use any other packgage set in the script! |
| `file`    | The actual path to the .age file that will be written after this function returns and the content is encrypted. Useful to write additional information to adjacent files. |
| `deps`    | The list of all secret files from our `dependencies`. Each entry is a set of `{ name, host, file }`, corresponding to the secret `nixosConfigurations.${host}.age.secrets.${name}`. `file` is the true source location of the secret's `rekeyFile`. You can extract the plaintext with `${decrypt} ${escapeShellArg dep.file}`.
| `decrypt` | The base rage command that can decrypt secrets to stdout by using the defined `masterIdentities`.
| `...`     | For future/unused arguments


First let's have a look at defining a very simple generator that creates longer passphrases.
Notice how we use the passed `pkgs` set instead of the package set from the config.

```nix
{
  age.secrets.generators.long-passphrase = {
    rekeyFile = ./secrets/randomPassword.age;
    generator.script = {pkgs, ...}: "${pkgs.xkcdpass}/bin/xkcdpass --numwords=10";
  };
}
```

Another common case is generating secret keys, for which we also directly want to
derive the matching public keys and store them in an adjacent `.pub` file:

```nix
{
  age.secrets.generators.wireguard-priv = {
    rekeyFile = ./secrets/wg-priv.age;
    generator.script = {pkgs, file, ...}: ''
      ${pkgs.wireguard-tools}/bin/wg genkey \
        | tee /dev/stdout \
        | ${pkgs.wireguard-tools}/bin/wg pubkey > ${lib.escapeShellArg (lib.removeSuffix ".age" file + ".pub")}
    '';
  };
}
```

By utilizing `deps` and `decrypt`, we can also generate secrets that depend on the value of other secrets.
You might encounter this when you want to generate a `.htpasswd` file from several cleartext passwords
which are also generated automatically:

```nix
{
  # Generate a random password
  age.secrets.generators.basic-auth-pw = {
    rekeyFile = ./secrets/basic-auth-pw.age;
    generator = "alnum";
  };

  # Generate a htpasswd from several random passwords
  age.secrets.generators.some-htpasswd = {
    rekeyFile = ./secrets/htpasswd.age;
    generator = {
      # All these secrets will be generated first and their paths are
      # passed to the `script` as `deps` when this secret is being generated.
      # You can refer to age secrets of other systems, as long as all relevant systems
      # are passed to the agenix-rekey app definition via the nixosConfigurations parameter.
      dependencies = [
        # A local secret
        config.age.secrets.basic-auth-pw
        # Secrets from other machines
        nixosConfigurations.machine2.config.age.secrets.basic-auth-pw
        nixosConfigurations.machine3.config.age.secrets.basic-auth-pw
      ];
      script = { pkgs, lib, decrypt, deps, ... }:
        # For each dependency, we can use `decrypt` to get the plaintext.
        # We run that through apache's htpasswd to create a htpasswd entry.
        # Since all commands output to stdout, we automatically have a valid
        # htpasswd file afterwards.
        lib.flip lib.concatMapStrings deps ({ name, host, file }: ''
          echo "Aggregating "''${lib.escapeShellArg host}:''${lib.escapeShellArg name} >&2
          # Decrypt the dependency containing the cleartext password,
          # and run it through htpasswd to generate a bcrypt hash
          ${decrypt} ${lib.escapeShellArg file} \
            | ${pkgs.apacheHttpd}/bin/htpasswd -niBC 10 ${lib.escapeShellArg host}
        '');
    };
  };
}
```

## How does it work?

The central problem is that rekeying secrets on-the-fly while building your system
is fundamentally impossible, since it is an impure operation. It will always require
an external input in form of your master password or has to communicate with a YubiKey.

The second problem is that building your system requires the rekeyed secrets to be available
in the nix-store, which we want to achieve without requiring you to track them in git.

#### Working with impurity

`agenix-rekey` solves the impurity problem by requiring you to expose an app in your flake,
which you can invoke with `nix run .#rekey` whenever your secrets need to be rekeyed.
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

## `age.secrets`

These are the secret options exposed by agenix. See [`age.secrets`](https://github.com/ryantm/agenix#reference)
for a description of all base attributes. In the following you
will read documentation for additional options added by agenix-rekey.

## `age.secrets.<name>.rekeyFile`

| Type    | `nullOr path` |
|-----|-----|
| Default | `null` |
| Example | `./secrets/password.age` |

The path to the encrypted .age file for this secret. The file must
be encrypted with one of the given `age.rekey.masterIdentities` and not with
a host-specific key.

This secret will automatically be rekeyed for hosts that use it, and the resulting
host-specific .age file will be set as actual `file` attribute. So naturally this
is mutually exclusive with specifying `file` directly.

If you want to avoid having a `secrets.nix` file and only use rekeyed secrets,
you should always use this option instead of `file`.

## `age.secrets.<name>.generator`

| Type    | `nullOr (either str generatorType)` |
|-----|-----|
| Default | `null` |
| Example | `"passphrase"` |

The generator that will be used to create this secret's if it doesn't exist yet.
Must be a generator definition like in `age.generators.<name>`, or just a string to
refer to one of the global generators in `age.generators`.

Refer to `age.generators.<name>` for more information on defining generators.

## `age.generators`

| Type    | `attrsOf generatorType` |
|-----|-----|
| Default | Defines some common password generators. See source. |
| Example | See source or [Secret generation](#secret-generation). |

Allows defining reusable secret generators. By default these generators are provided:

- `alnum`: Generates an alphanumeric string of length 48
- `base64`: Generates a base64 string of 32-byte random (length 44)
- `hex`: Generates a hex string of 24-byte random (length 48)
- `passphrase`: Generates a 6-word passphrase delimited by spaces

## `age.generators.<name>.dependencies`

| Type    | `listOf unspecified` |
|-----|-----|
| Default | `[]` |
| Example | `[ config.age.secrets.basicAuthPw1 nixosConfigurations.machine2.config.age.secrets.basicAuthPw ]` |

Other secrets on which this secret depends. This guarantees that in the final
`nix run .#generate-secrets` script, all dependencies will be generated before
this secret is generated, allowing you use their outputs via the passed `decrypt` function.

The given dependencies will be passed to the defined `script` via the `deps` parameter,
which will be a list of their true source locations (`rekeyFile`) in no particular order.

This should refer only to secret definitions from `config.age.secrets` that
have a generator. This is useful if you want to create derived secrets,
such as generating a .htpasswd file from several basic auth passwords.

You can refer to age secrets of other systems, as long as all relevant systems
are passed to the agenix-rekey app definition via the nixosConfigurations parameter.

## `age.generators.<name>.script`

| Type    | `types.functionTo types.str` |
|-----|-----|
| Example | See source or [Secret generation](#secret-generation). |

This must be a function that evaluates to a script. This script will be
added to the global generation script verbatim and runs outside of any sandbox.
Refer to `age.generators` for example usage.

This allows you to create/overwrite adjacent files if neccessary, for example
when you also want to store the public key for a generated private key.
Refer to the example for a description of the arguments. The resulting
secret should be written to stdout and any info or errors to stderr.

Note that the script is run with `set -euo pipefail` conditions as the
normal user that runs `nix run .#generate-secrets`.

## `age.rekey.forceRekeyOnSystem`

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

## `age.rekey.hostPubkey`

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

## `age.rekey.masterIdentities`

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

## `age.rekey.extraEncryptionPubkeys`

| Type    | `listOf (coercedTo path toString str)` |
|-----|-----|
| Default | `[]` |
| Example | `[./backup-key.pub "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"]` |
| Example | `["age1yubikey1qwf..."]` |

When using `nix run .#edit-secret FILE`, the file will be encrypted for all identities in
`age.rekey.masterIdentities` by default. Here you can specify an extra set of pubkeys for which
all secrets should also be encrypted. This is useful in case you want to have a backup indentity
that must be able to decrypt all secrets but should not be used when attempting regular decryption.

If the coerced string is an absolute path, it will be used as if it was a recipient file.
Otherwise, the string will be interpreted as a public key.

## `age.rekey.agePlugins`

| Type    | `listOf package` |
|-----|-----|
| Default | `[rekeyHostPkgs.age-plugin-yubikey]` |
| Example | `[]` |

A list of plugins that should be available to rage while rekeying.
They will be added to the PATH with lowest-priority before rage is invoked,
meaning if you have the plugin installed on your system, that one is preferred
in an effort to not break complex setups (e.g. WSL passthrough).
