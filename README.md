[Installation](#installation) \| [Usage](#usage) \| [How does it work?](#how-does-it-work) \| [Module options](#%EF%B8%8F-module-options)

# 🔐 agenix-rekey

This is an extension for [agenix](https://github.com/ryantm/agenix) which allows you to get rid
of maintaining a `secrets.nix` file by automatically re-encrypting secrets where needed.
It also allows you to define versatile generators for secrets, so they can be bootstrapped
automatically. This extension is a flakes-only project and can be used alongside regular use of agenix.

To make use of rekeying, you will have to store secrets in your repository by encrypting
them with a master key (YubiKey or regular age identity), and agenix-rekey will automatically
re-encrypt these secrets for any host that requires them. A YubiKey is highly recommended
and will provide you with a smooth rekeying experience. In summary, you get:

- 🔑 **Single master-key.** Anything in your repository is encrypted by your master YubiKey or age identity.
- ➡️ **Host-key inference.** No need to manually keep track of which key is needed for which host - no `secrets.nix`.
- ✔️ **Less secret management.** Rekeyed secrets never have to be added to your flake repository, thus
  you only have to keep track of the actual secret. Also a leaked host-key doesn't allow an attacker to decrypt
  older checked-in secrets, in case your repo is public.
- 🦥 **Lazy rekeying.** Rekeying only occurs when necessary, since the results are encrypted and can thus be cached in a local directory.
  If secret is added/changed or a host key is modified, you will automatically be prompted to rekey.
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

## Overview

When using agenix-rekey, you will have an `agenix` command to run secret-related actions on your flake.
This is a replacement for the command provided by agenix, which you won't need anymore.
There are several apps/subcommands which you can use to manage your secrets:

- `agenix generate`: Generates any secrets that don't exist yet and have a generator set.
- `agenix edit`: Create/edit secrets using `$EDITOR`. Can encrypt existing files.
- `agenix rekey`: Rekeys secrets for hosts that require them.
- Use `agenix <command> --help` for specific usage information.

The general workflow is quite simple, because you will automatically be prompted to
run `agenix rekey` whenever it is necessary (the build will fail and tell you).

## Installation

To use agenix-rekey, you will have to add agenix-rekey to your `flake.nix`,
import the provided NixOS module in your hosts and expose some information
in your flake so agenix-rekey knows where to look for secrets. A [flake-parts](https://flake.parts)
module is also available (see end of this section for an example).

To get the `agenix` command, you can either use `nix shell github:oddlama/agenix-rekey`
to enter a shell where it is available temporarily, or alternatively add
the provided package `agenix-rekey.packages.${system}.default` to your devshell as shown below.

You can also directly call the scripts through your flake with `nix run .#agenix-rekey.<system>.<app>`
if you don't want to use the wrapper, which may be useful for use in your own scripts.

```nix
{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.agenix.url = "github:ryantm/agenix";
  inputs.agenix-rekey.url = "github:oddlama/agenix-rekey";
  # Make sure to override the nixpkgs version to follow your flake,
  # otherwise derivation paths can mismatch (when using storageMode = "derivation"),
  # resulting in the rekeyed secrets not being found!
  inputs.agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";
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

    # Expose the necessary information in your flake so agenix-rekey
    # knows where it has too look for secrets and paths.
    #
    # Make sure that the pkgs passed here comes from the same nixpkgs version as
    # the pkgs used on your hosts in `nixosConfigurations`, otherwise the rekeyed
    # derivations will not be found!
    agenix-rekey = agenix-rekey.configure {
      userFlake = self;
      nodes = self.nixosConfigurations;
      # Example for colmena:
      # inherit ((colmena.lib.makeHive self.colmena).introspect (x: x)) nodes;
    };
  }
  # OPTIONAL: This part is only needed if you want to have the agenix
  # command in your devshell.
  // flake-utils.lib.eachDefaultSystem (system: rec {
    pkgs = import nixpkgs {
      inherit system;
      overlays = [ agenix-rekey.overlays.default ];
    };
    devShells.default = pkgs.mkShell {
      packages = [ pkgs.agenix-rekey ];
      # ...
    };
  });
}
```

<details>
<summary>
Usage with flake-parts
</summary>

```nix
{
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";

  inputs.agenix.url = "github:ryantm/agenix";
  inputs.agenix-rekey.url = "github:oddlama/agenix-rekey";
  # Make sure to override the nixpkgs version to follow your flake,
  # otherwise derivation paths can mismatch (when using storageMode = "derivation"),
  # resulting in the rekeyed secrets not being found!
  inputs.agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";
  # ...

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.agenix-rekey.flakeModule
      ];

      perSystem = {config, pkgs, ...}: {
        # Add `config.agenix-rekey.package` to your devshell to
        # easily access the `agenix` command wrapper.
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ config.agenix-rekey.package ];
        };

        # You can define agenix-rekey.nodes if you want to change which
        # hosts # are considered for rekeying.
        # Refer to the flake.parts section on agenix-rekey to see all available options.
        agenix-rekey.nodes = inputs.self.nixosConfigurations; # (not technically needed, as it is already the default)
      };
    };
}
```

</details>

You have the choice between two storage modes for your rekeyed secrets, which
are fundamentally different from each other. You can freely switch between them,
see [here]() for more information.

## Usage

Since agenix-rekey is just an extension to agenix, everything you know about agenix still applies as usual.
Apart from specifying meta information about your master key, the only thing that you have to change
to use rekeying is to specify `rekeyFile` instead of `file` on your secrets. The full setup process is the following:

1. For each host, you have to provide a pubkey for rekeying and select the master identity
   to use for decrypting the secrets stored in your repository. The `hostPubkey` will obviously be different for each host,
   but all other options (like your master identity) will usually be the same across hosts.
   You can find more options in the api reference below.

   We will be using the local storage mode by default, which will store the rekeyed secrets in
   your own repository.

    ```nix
    {
      age.rekey = {
        # Obtain this using `ssh-keyscan` or by looking it up in your ~/.ssh/known_hosts
        hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...";
        # The path to the master identity used for decryption. See the option's description for more information.
        masterIdentities = [ ./your-yubikey-identity.pub ];
        #masterIdentities = [ "/home/myuser/master-key" ]; # External master key
        #masterIdentities = [
        #  # It is possible to specify an identity using the following alternate syntax,
        #  # this can be used to avoid unecessary prompts during encryption.
        #  {
        #    identity = "/home/myuser/master-key.age"; # Password protected external master key
        #    pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"; # Specify the public key explicitly
        #  }
        #];
        storageMode = "local";
        # Choose a directory to store the rekeyed secrets for this host.
        # This cannot be shared with other hosts. Please refer to this path
        # from your flake's root directory and not by a direct path literal like ./secrets
        localStorageDir = ./. + "/secrets/rekeyed/${config.networking.hostName}";
      };
    }
    ```

2. Encrypt some secrets using (r)age and your master key. `agenix-rekey` comes with a CLI utility called `agenix`,
   which allows you to easily create/edit secrets using your favorite `$EDITOR`,
   and automatically uses the correct identities for de- and encryption according to the settings from Step 1.

   Ideally you should have added it to your devshell as described in the installation section,
   otherwise you can run the utility ad-hoc with `nix run github:oddlama/agenix-rekey -- <SUBCOMMAND> [OPTIONS]`.

    ```bash
    # Create new or edit existing secret
    agenix edit secret1.age
    # Or encrypt an existing file
    agenix edit -i plain.txt secret1.age
    # If no parameter is given, this will present an interactive list with all defined secrets
    # so you can choose which once you want to create/edit
    agenix edit

    # Alternatively you can of course manually encrypt something using (r)age
    echo "secret" | rage -e -i ./your-yubikey-identity.pub > secret1.age
    ```

   Be careful when choosing your `$EDITOR` here, it might leak secret information when editing the file
   by means of undo-history, or caching in general. For `vim` and `nvim` this app automatically disables related
   options to make it safe to use.

3. Define a secret in your config and use it. This works similar to classical agenix, but instead of `file` you now
   specify `rekeyFile` (which then generates a definition for `file`).

    ```nix
    {
      age.secrets.secret1.rekeyFile = ./secret1.age;
      services.someService.passwordFile = config.age.secrets.secret1.path;
    }
    ```

4. Deploy your system as usual by using `nixos-rebuild` or your favourite deployment tool.
   In case you need to rekey, you will be prompted to do that as part of a build failure that will be triggered.
   Since we just did the initial setup, you should rekey right away:

    ```bash
    > agenix rekey -a # -a will add them to git when you use local storage mode
    ```

    Don't forget to add the rekeyed secrets afterwards to make them visible to the build process.

    > [!WARNING]
    > If you use `storageMode = "derivation"`, `agenix rekey` must be able to set extra
    > sandbox paths. This you need to add `age.rekey.cacheDir` as a global extra sandbox path
    > (DO NOT add your user to trusted-users instead, this would basically grant them root access!):
    >
    > ```nix
    > nix.settings.extra-sandbox-paths = ["/tmp/agenix-rekey.${config.users.users.youruser.uid}"];
    > ```
    >
    > See [issue #9](https://github.com/oddlama/agenix-rekey/issues/9) for more information about a user-agnostic setup.

    > [!NOTE]
    > If you use `storageMode = "derivation"`, and you are deploying your configuration to
    > remote systems, you need to make sure that the correct derivation containing the
    > rekeyed secrets is copied from your local store to the remote host's store.
    >
    > Any tool that builds locally and uses `nix copy` (or equivalent tools) to copy the derivations
    > to your remote systems will work automatically, so no additional care has to be taken.
    > Only when you strictly build on your remotes, you might have to copy those secrets manually.
    > You can target them by using `agenix rekey --show-out-paths` or by directly referring to `nixosConfigurations.<host>.config.age.rekey.derivation`

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
    generator.script = "passphrase";
  };
}
```

### Pre-defined generators

- `alnum` - Generates a long (48 character) alphanumeric password.
- `base64` - Generates a long (32 character) base64 encoded password.
- `hex` - Generates a long (24 character) hexadecimal encoded password.
- `passphrase` - Generates a six word, space separated passphrase.
- `dhparams` - Generates Diffie–Hellman parameters which can be used for
  perfect forward security.  See
  [Diffie-Hellman_parameters](https://wiki.openssl.org/index.php/Diffie-Hellman_parameters)
  for details.
- `ssh-ed25519` - Generates a [ED-25519](https://en.wikipedia.org/wiki/EdDSA)
  SSH key pair using the current hostname.

### Custom generators

You can also define your own generators, either by creating an entry in `age.generators`
to make a reusable generator like `"passphrase"` above, or directly by setting
`age.secrets.<name>.generator` to a generator definition.

A generator is a set consisting of two attributes, a `script` and optionally some `dependencies`.
The `script` must either be a string referring to one of the globally defined generators,
or a function. This function receives an attrset with arguments and has to return a bash
script, which acutally generates and writes the desired secret to stdout.
A very simple (and bad) generator would thus be `{ ... }: "echo very-secret"`.

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
  # Allows you to use "long-passphrase" as a generator.
  age.generators.long-passphrase = {pkgs, ...}: "${pkgs.xkcdpass}/bin/xkcdpass --numwords=10";
}
```

Another common case is generating secret keys, for which we also directly want to
derive the matching public keys and store them in an adjacent `.pub` file:

```nix
{
  age.generators.wireguard-priv = {pkgs, file, ...}: ''
    priv=$(${pkgs.wireguard-tools}/bin/wg genkey)
    ${pkgs.wireguard-tools}/bin/wg pubkey <<< "$priv" > ${lib.escapeShellArg (lib.removeSuffix ".age" file + ".pub")}
    echo "$priv"
  '';
}
```

By utilizing `deps` and `decrypt`, we can also generate secrets that depend on the value of other secrets.
You might encounter this when you want to generate a `.htpasswd` file from several cleartext passwords
which are also generated automatically:

```nix
{
  # Generate a random password
  age.secrets.basic-auth-pw = {
    rekeyFile = ./secrets/basic-auth-pw.age;
    generator.script = "alnum";
  };

  # Generate a htpasswd from several random passwords
  age.secrets.some-htpasswd = {
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

## Using age instead of rage

If you don't want to use rage for some reason, you can specify a compatible
alternative tool in your top-level configure call (or via an option if you are using
flake-parts):

```nix
agenix-rekey = agenix-rekey.configure {
  # ...
  agePackage = p: p.age;
};
```

## Storage Modes

You have the choice between two storage modes for your rekeyed secrets, which
are fundamentally different from each other. You can freely switch between them at any time.

Option one is to store the rekeyed secrets locally in your repository (`local`), option two is to
transparently store them in a derivation that will be created automatically (`derivation`).
If in doubt use `local` which is more flexible and pure, but keep in mind that `derivation`
can be more secure for certain cases. It uses more "magic" to hide some details and might be
simpler to use if you only build on one host and don't care about remote building / CI.
The choice depends on your organizational preferences and threat model.

#### `derivation`

Previously this was the default mode. All rekeyed secrets for each host will
be collected in a derivation which copies them to the nix store when it is built using `agenix rekey`.

- **Pro:** The entire process is stateless and rekeyed secrets are never committed to your repository.
- **Con:** You cannot easily build your host from a CI/any host that hasn't access to your (yubi)key
  except by manually uploading the derivations to the CI after rekeying.

#### `local`

All rekeyed secrets will be saved to a local folder in your flake when running `agenix rekey`.
Agenix will use these local files directly, without requiring any extra derivations. This is the simpler
approach and has less edge-cases.

- **Pro:** System building stays pure, no need for sandbox shenanigans. -> System can be built without access to the (yubi)key.
- **Con:** If your repository is public and one of your hosts is compromised, an attacker may decrypt
  any secret that was ever encrypted for that host. This includes secrets that are in the git history.

## How does it work?

The central problem is that rekeying secrets on-the-fly while building your system
is fundamentally impossible, since it is an impure operation. It will always require
an external input in the form of your master password or has to communicate with a YubiKey.

The second problem is that building your system requires the rekeyed secrets to be available
in the nix-store, which we want to achieve without requiring you to track them in git.

#### Working with impurity

`agenix-rekey` solves the impurity problem by following a two-step approach. By adding
agenix-rekey, you implicitly define a script through your flake which can run in your
host-environment and is thus able to prompt for passwords or read YubiKeys.
It can run `age` to rekey the secrets and store them in a temporary cache directory.

#### Predicting store paths to avoid tracking rekeyed secrets

The more complicated second problem is solved by using a predictable store-path for
the resulting rekeyed secrets by putting them in a special derivation for each host.
This derivation is made to always fail when the build is invoked transitively by the
build process, which always means rekeying is necessary.

The `agenix rekey` command will build the same derivation but with special access to the rekeyed
secrets which will temporarily be stored in a predicable path in `/tmp`, for which
the sandbox is allowed access to `/tmp` solving the impurity issue. Running the build
afterwards will succeed since the derivation is now already built and available in
your local store.

# ❄️ Module options

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
host-specific .age file will be set as an actual `file` attribute. So naturally this
is mutually exclusive with specifying `file` directly.

If you want to avoid having a `secrets.nix` file and only use rekeyed secrets,
you should always use this option instead of `file`.

## `age.secrets.<name>.generator`

| Type    | `nullOr (either str generatorType)` |
|-----|-----|
| Default | `null` |
| Example | `{ script = "passphrase"; }` |

If defined, this generator will be used to bootstrap this secret's when it doesn't exist.

## `age.secrets.<name>.generator.dependencies`

| Type    | `listOf unspecified` |
|-----|-----|
| Default | `[]` |
| Example | `[ config.age.secrets.basicAuthPw1 nixosConfigurations.machine2.config.age.secrets.basicAuthPw ]` |

Other secrets on which this secret depends. This guarantees that in the final
`agenix generate` script, all dependencies will be generated before
this secret is generated, allowing you to use their outputs via the passed `decrypt` function.

The given dependencies will be passed to the defined `script` via the `deps` parameter,
which will be a list of their true source locations (`rekeyFile`) in no particular order.

This should refer only to secret definitions from `config.age.secrets` that
have a generator. This is useful if you want to create derived secrets,
such as generating a .htpasswd file from several basic auth passwords.

You can refer to age secrets of other systems, as long as all relevant systems
are passed to the agenix-rekey app definition via the nixosConfigurations parameter.

## `age.secrets.<name>.generator.script`

| Type    | `either str (functionTo str)` |
|-----|-----|
| Example | See source or [Secret generation](#secret-generation). |

This must either be the name of a globally defined generator, or
a function that evaluates to a script. The resulting script will be
added to the internal, global generation script verbatim and runs
outside of any sandbox. Refer to `age.generators` for example usage.

This allows you to create/overwrite adjacent files if necessary, for example
when you also want to store the public key for a generated private key.
Refer to the example for a description of the arguments. The resulting
secret should be written to stdout and any info or errors to stderr.

Note that the script is run with `set -euo pipefail` conditions as the
normal user that runs `agenix generate`.

## `age.secrets.<name>.generator.tags`

| Type    | `listOf str` |
|-----|-----|
| Default | `[]` |
| Example | `["wireguard"]` |

Optional list of tags that may be used to refer to secrets that use this generator.
Useful to regenerate all secrets matching a specific tag using `agenix generate -f -t wireguard`.

## `age.generators`

| Type    | `attrsOf (functionTo str)` |
|-----|-----|
| Default | Defines some common password generators. See source. |
| Example | See source or [Secret generation](#secret-generation). |

Allows defining reusable secret generator scripts. By default these generators are provided:

- `alnum`: Generates an alphanumeric string of length 48
- `base64`: Generates a base64 string of 32-byte random (length 44)
- `hex`: Generates a hex string of 24-byte random (length 48)
- `passphrase`: Generates a 6-word passphrase delimited by spaces
- `dhparams`: Generates 4096-bit dhparams
- `ssh-ed25519`: Generates a ssh-ed25519 private key

## `age.rekey.generatedSecretsDir`

| Type    | `nullOr path` |
|-----|-----|
| Default | `null` |
| Example | `./secrets/generated` |

The path where all generated secrets should be stored by default.
If set, this automatically sets `age.secrets.<name>.rekeyFile` to a default
value in this directory, for any secret that defines a generator.

## `age.rekey.storageMode`

| Type    | `enum ["derivation" "local"]` |
|-----|-----|
| Default | `"local"` |
| Example | `"derivation"` |

You have the choice between two storage modes for your rekeyed secrets, which
are fundamentally different from each other. You can freely switch between them at any time.

Option one is to store the rekeyed secrets locally in your repository (`local`), option two is to
transparently store them in a derivation that will be created automatically (`derivation`).
If in doubt use `local` which is more flexible and pure, but keep in mind that `derivation`
can be more secure for certain cases. It uses more "magic" to hide some details and might be
simpler to use if you only build on one host and don't care about remote building / CI.
The choice depends on your organizational preferences and threat model.

#### `derivation`

Previously this was the default mode. All rekeyed secrets for each host will
be collected in a derivation which copies them to the nix store when it is built using `agenix rekey`.

- **Pro:** The entire process is stateless and rekeyed secrets are never committed to your repository.
- **Con:** You cannot easily build your host from a CI/any host that hasn't access to your (yubi)key
  except by manually uploading the derivations to the CI after rekeying.

#### `local`

All rekeyed secrets will be saved to a local folder in your flake when running `agenix rekey`.
Agenix will use these local files directly, without requiring any extra derivations. This is the simpler
approach and has less edge-cases.

- **Pro:** System building stays pure, no need for sandbox shenanigans. -> System can be built without access to the (yubi)key.
- **Con:** If your repository is public and one of your hosts is compromised, an attacker may decrypt
  any secret that was ever encrypted for that host. This includes secrets that are in the git history.

## `age.rekey.localStorageDir`

| Type    | `path` |
|-----|-----|
| Example | `./. /* <- flake root */ + "/secrets/rekeyed/myhost" /* separate folder for each host */` |

Only used when `storageMode = "local"`.

The local storage directory for rekeyed secrets. MUST be a path inside of your repository,
and it MUST be constructed by concatenating to the root directory of your flake. Follow
the example.

## `age.rekey.derivation`

| Type    | `package` |
|-----|-----|
| Default | A derivation containing the rekeyed secrets for this host |
| Read-only | yes |

Only used when `storageMode = "derivation"`.

The derivation that contains the rekeyed secrets for this host.
This exists so you can target the secrets for uploading to a remote host
if necessary. Cannot be built directly, use `agenix rekey` instead.

## `age.rekey.cacheDir`

| Type    | `str` |
|-----|-----|
| Default | `"/tmp/agenix-rekey.\"$UID\""` |
| Example | `"\"\${XDG_CACHE_HOME:=$HOME/.cache}/agenix-rekey\""` |

Only used when `storageMode = "derivation"`.

This is the directory where we store the rekeyed secrets
so that they can be found later by the derivation builder.

Must be a bash expression that expands to the directory to use
as a cache. By default the cache is kept in /tmp, but you can
change it to (see example) to persist the cache across reboots.
Make sure to use corret quoting, this _must_ be a bash expression
resulting in a single string.

The actual secrets will be stored in the directory based on their input
content hash (derived from host pubkey and file content hash), and stored
as `${cacheDir}/secrets/<ident-sha256>-<filename>`. This allows us to
reuse already existing rekeyed secrets when rekeying again, while providing
a deterministic path for each secret.

## `age.rekey.forceRekeyOnSystem`

| Type    | `nullOr str` |
|-----|-----|
| Default | `null` |
| Example | `"x86_64-linux"` |

Only used when `storageMode = "derivation"`.

If set, this will force that all secrets are rekeyed on a system of the given architecture.
This is important if you have several hosts with different architectures, since you usually
don't want to build the derivation containing the rekeyed secrets on a random remote host.

The problem is that each derivation will always depend on at least one specific architecture
(often it's bash), since it requires a builder to create it. Usually the builder will use the
architecture for which the package is built, which makes sense. Since it is part of the derivation
inputs, we have to know it in advance to predict where the output will be. If you have multiple
architectures, then we'd have multiple candidate derivations for the rekeyed secrets, but we want
a single predictable derivation.

If you tried to deploy an aarch64-linux system, but are on x86_64-linux without binary
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

| Type    | `listOf (coercedTo (coercedTo path toString str) <...> (submodule { identity = <...>; pubkey = <...> }))` ([full signature](https://github.com/oddlama/agenix-rekey/blob/main/modules/agenix-rekey.nix#L511-L543))|
|-----|-----|
| Default | `[]` |
| Example | `[./secrets/my-public-yubikey-identity.txt]` |
| Example | `[{identity = ./password-encrypted-identity.pub; pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";}]` |

The list of age identities that will be presented to `rage` when decrypting the stored secrets
to rekey them for your host(s). If multiple identities are given, they will be tried in-order.

The recommended options are:

- Use a split-identity ending in `.pub`, where the private part is not contained (a yubikey identity)
- Use an absolute path to your key outside the nix store ("/home/myuser/age-master-key")
- Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
  using `rage -p -o privkey.age privkey` which protects it in your store.

If you are using YubiKeys, you can specify multiple split-identities here and use them interchangeably.
You will have the option to skip any YubiKeys that are not available to you at that moment.

To prevent issues with master keys that may be sometimes unavailable during encryption,
an alternate syntax is possible:

```nix
age.rekey.masterIdentities = [
  {
    # This has the same type as the other ways to specify an identity.
    identity = ./password-encrypted-identity.pub;
    # Optional; This has the same type as `age.rekey.hostPubkey`
    # and allows explicit association of a pubkey with the identity.
    pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
  }
];
```

If a pubkey is explicitly specified, it will be used
in place of the associated identity during encryption. This prevents additional prompts
in the case of a password encrypted key file or prompts for identities that can only be accessed
by certain people in a multi-user scenario. For Yubikey identities the pubkey can be automatically
extracted from the identity file, if there is a comment of the form `Recipient: age1yubikey1<key>`
present in the identity file.
This should be the case for identity files generated by the `age-plugin-yubikey` CLI.
See the description of [pull request #28](https://github.com/oddlama/agenix-rekey/pull/28)
for more information on the exact criteria for automatic pubkey extraction.

For setups where the primary identity may change depending on the situation, e.g. in a multi-user setup,
where each person only has access to their own personal Yubikey, check out the
`AGENIX_REKEY_PRIMARY_IDENTITY` environment variable.

Be careful when using paths here, as they will be copied to the nix store. Using
split-identities is fine, but if you are using plain age identities, make sure that they
are password protected.

## `age.rekey.extraEncryptionPubkeys`

| Type    | `listOf (coercedTo path toString str)` |
|-----|-----|
| Default | `[]` |
| Example | `[./backup-key.pub "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"]` |
| Example | `["age1yubikey1qwf..."]` |

When using `agenix edit FILE`, the file will be encrypted for all identities in
`age.rekey.masterIdentities` by default. Here you can specify an extra set of pubkeys for which
all secrets should also be encrypted. This is useful in case you want to have a backup identity
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

# ⌨ Environment variables

## `AGENIX_REKEY_PRIMARY_IDENTITY`
If this environment variable is set to a public key, agenix-rekey will try to find it
among the explicitly specified or implicitly extracted pubkeys (see `age.rekey.masterIdentities`).
If it finds a matching pubkey, its associated identity file will be added in front of all
other identity arguments passed to (r)age during decryption. As a result it gets the first shot
at decrypting a file. This eliminates the need to manually skip master identities
when it is known that only a specific one is available.
It also allows PIN caching for Yubikeys other than the first one in the list of master identities
(see [this issue comment](https://github.com/str4d/age-plugin-yubikey/issues/178#issuecomment-2077003145)).
The description of [pull request #28](https://github.com/oddlama/agenix-rekey/pull/28) provides further details.
