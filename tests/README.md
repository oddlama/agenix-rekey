# Welcome to the agenix-rekey testing framework

---

# Usage
Run `nix flake check` in this subfolder.
To run as specific subtest run:
```bash
nix build .#check.<system>.<test-name> -L
```
where `test-name` is the name of the subfolder of `check` that contains your test.

# Adding new tests 
To add a test, add a new flake and a file called `test.sh` in a subfolder of `./cases`.
You don't need to lock your flake, it will be tested with the current agenix version on disk, as
of running the test.

## test.sh

This file should contain your actual agenix-rekey related tests. It will be executed in a VM inside a folder containing your configured flake.
In the test script you will automatically have access to these helpers:

| command | description |
|---|---|
|`agenix`| the final agenix wrapper, used for rekeying, generating, etc |
|`agenixActivate`| The agenix activation scripts, use these to urn running the agenix activation phase to test if decryption works correctly|

If you need any other programs you should add them to the `runtimeInputs` of
the `testScript` derivation in [this](./default.nix) file.

## Your flake

The flake to test must, obviously, use `agenix-rekey` in some way.
Additionally these limitation apply:

### Flat Input

The flake under test has to have a completely flat input structure.
If this is not the case we cannot provide the necessary store paths to the VM,
which will result in a download attempt (i.e. network request) in the VM which will in turn be denied by the sandbox.
This means that all transitive inputs have to be declared as a first level input and the followed.

This is invalid:

```nix
inputs= {
    agenix.url = "github:ryantm/agenix";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
}
```

Apart from `nixpkgs`, agenix internally has some other inputs that are not explicitly defined here.
Specifically in this case, the missing inputs are `darwin`, `home-manager` and `system`.
To flatten them you will have to add them to your flake as well.
Thus your final flake should look like this:

```nix
inputs= {
    agenix = {
      url = "github:ryantm/agenix";
      inputs.darwin.follows = "darwin";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.systems.follows = "systems";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
}
```

### Instantiation

You have to instantiate nixpkgs without any configuration to ensure the needed
derivation, such as `stdenv` are the ones that the framework puts into your nix store.

### Mandatory nixos configurations

- Your flake has to enable openssh in the test machine, as the host key will be used to decrypt age files
- Agenix-rekey has to use "./host.pub" as a public key
- Your flake has to have output at least one machine in `nixosConfiguration`

```nix
services.openssh.enable = true;
age.rekey.hostPubkey = ./host.pub;
```

### Mandatory flake configurations

Your flake has to export agenix as a package.

```nix
packages.agenix = config.agenix-rekey.package;
```

# Limitations

The flake will be tested with whatever version of inputs this test flake has, except
for the `agenix-rekey` input.
Remember to update the list of inputs regularly when they change, otherwise tests may fail.
