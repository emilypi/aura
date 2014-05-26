# Aura 2 Design

## Contents
- Preface
- [Mission Statement](/DESIGN.md#mission-statement)
- Requirements
  - [General Functionality](/DESIGN.md#general-functionality)
    - [Dependency Resolution](/DESIGN.md#dependency-resolution)
    - [Dependency Information Output](/DESIGN.md#dependency-information-output)
    - [Concurrent Package Building](/DESIGN.md#concurrent-package-building)
    - [Abnormal Termination](/DESIGN.md#abnormal-termination)
    - [Colour Output](/DESIGN.md#colour-output)
  - [Plugins](/DESIGN.md#plugins)
  - [Aesthetics](/DESIGN.md#aesthetics)
    - [Version Information when Upgrading](/DESIGN.md#version-information-when-upgrading)
    - [Aura Versioning](/DESIGN.md#aura-versioning)
  - [Haskell Requirements](/DESIGN.md#haskell-requirements)
    - [Strings](/DESIGN.md#strings)
    - [JSON Data](/DESIGN.md#json-data)
    - [Other Libraries](/DESIGN.md#other-libraries)
  - [Package Requirements](/DESIGN.md#package-requirements)
- [Arch Linux Specifics](/DESIGN.md#arch-linux-specifics)
  - [ABS Package Building/Installation](/DESIGN.md#abs-package-buildinginstallation)
  - [AUR Package Building/Installation](/DESIGN.md#aur-package-buildinginstallation)
  - [PKGBUILD/Additional Build-file Editing](/DESIGN.md#pkgbuildadditional-build-file-editing)
  - [AUR Interaction](/DESIGN.md#aur-interaction)
- [Coding Standards](/DESIGN.md#coding-standards)
  - [Record Syntax](/DESIGN.md#record-syntax)

## Preface
This is a design document for version 2 of
[Aura](https://github.com/fosskers/aura). Note that specifications are written
in present tense, as in, "Aura does this" even if at the time of writing those
features aren't implemented yet. This is to ensure that the document can act
as a reference for Aura's behaviour post-release.

## Mission Statement
Aura is a cross-distribution package manager for GNU/Linux systems.<BR>
It is based around a distribution-specific Hook system for custom
build/install behaviour, while maintaining a custom interface across
all distros. Aura itself provides:

- Dependency management.
- Package downloading.
- Package-state backups/restoration.

Aura's authors recognize that [attemping to create universal standards
can be problematic](http://www.xkcd.com/927/), but that is precisely
why Aura exists. By having a unified interface over multiple packaging
standards, users can transition between distributions more easily, and
distribution developers can avoid reinventing the wheel by writing their
own package management software.

## Requirements
### General Functionality

#### Dependency Resolution
- AUR dependencies are no longer resolved through PKGBUILD bash parsing.
  The AUR 3.0 API includes the necessary dependency information.
- **Resolution Successful**: Data in the form `[[Package]]` is yielded. These
  are groups of packages that may be built and installed simultaneously. That
  is, they are not interdependent in any way.
- **Version Conflicts**:
  - Dependency resolution fails and the build does not continue.
  - The user is shown the chart below so it is clear what dependencies from
    what packages are causing issues.
  - All packages that had dependency issues are shown.
  - Supplying the `--json` flag will output this data as JSON for capture
    by other programs.

```
| Dep Name | Parent | Status   | Version |
| -------- | ------ | -------- | ------- |
| foo      | None   | Local    | 1.2.3   |
| foo      | bar    | Incoming | < 1.2.3 |
| foo      | baz    | Incoming | > 1.2.3 |
| -------- | ------ | -------- | ------- |
| curl     | git    | Local    | 7.36.0  |
| curl     | pacman | Incoming | 7.37.0  |
| -------- | ------ | -------- | ------- |
| lua      | vlc    | Incoming | 5.2.3   |
| lua      | conky  | Incoming | 5.2.2   |
```

```javascript
// As JSON:
{ [ { "Name": "foo"
    , "Local": { "Parent": "None"
               , "Version": "1.2.3" }
    , "Incoming": [ { "Parent": "bar"
                    , "Version": "< 1.2.3" }
                  , { "Parent": "baz"
                    , "Version": "> 1.2.3" }
                  ]
    }
  , { "Name": "curl"
    , "Local": { "Parent": "git"
               , "Version": "7.36.0" }
    , "Incoming": [ { "Parent": "pacman"
                    , "Version": "7.37.0" }
                  ]
    }
  , { "Name": "lua"
    , "Local": "None"
    , "Incoming": [ { "Parent": "vlc"
                    , "Version": "5.2.3" }
                  , { "Parent": "conky"
                    , "Version": "5.2.2" }
                  ]
    }
  ]
}
```

#### Dependency Information Output
- Information for all immediate dependencies for any given package can be output
  in human-readable format by default with `-{A,S}d`.
- Adding `--recursive` will yield all dependencies and _their_ dependencies
  as well.
- Adding `--json` will output this information in JSON for use by other
  software that may sit on top of Aura.

#### Concurrent Package Building
- Package data is returned from dependency checking in the form `[[Package]]`
  (see [Dependency Resolution](/DESIGN.md#dependency-resolution)). Each sublist
  of packages have no interdependencies, so they are built concurrent to each
  other and then installed as a block.

#### Package State Backups
- `aura -B` stores a snapshot of all currently installed packages and their
  versions in `/var/cache/aura/states`.
- Filenames are of the form: `YYYY.MM(MonthName).DD.HH.MM`
- The data itself is stored as JSON to ease use by other tools:

```javascript
{ "date": "2014-04-09"
, "time": "20:00"
, "packages": [ { "pkgname": "alsa-lib"
                , "version": "1.0.27.2-1" }
                // more packages here
              ]
}
```

#### Abnormal Termination
- Users can halt Aura with `Ctrl-d`. The message `Stopping Aura...` is shown.
  All temporary files in use are cleared here.

#### Colour Output
- All output to terminal (save JSON data) is output in colour where appropriate.
  The user can disable this with `--no-colo{ur,r}`

### Plugins
This is very early stage planning.<BR>
Suggestions:

1. Like XMonad, behaviour is built around hooks/plugins that are themselves
   written in Haskell.
  - Hooks like `buildHook`, `apiHook`, `installHook` etc., that can be
    overridden or added to.
  - Aura comes bundled with default behaviour, and a `AuraConf.hs` is written
    somewhere for the users to edit if they wish.
  - Some command `aura --recompile` could rebuild it with the new Haskell-based
    changes added in.
  - `AuraConf.hs` could potentially be `.pacnew`d if need be.
  - **PROS**
    - Finally there would be a configuration file for Aura.
    - The ability to "turn off" plugins. Installed ones, if not added to
      `AuraConf.hs` wouldn't run.
    - Operations would be guaranteed to run through the Aura Monad
      (where appropriate).
  - **CONS**
    - `aura --recompile` wouldn't work without all the Haskell dependencies.
      Users of the pre-built version wouldn't be able to do any configuration.
      A possible work-around of this would be to offer `bundles`, that is,
      pre-built versions that would have all the hooks built-in already so
      the end user wouldn't have to think twice about it.
    - Hooks can only be written in Haskell.
2. Haskell Data via Haskell Actors:
  - Build `stages` could be defined (Dep Check, Build, Install, etc.) and
    the plugin would indicate which stage it was for.
  - Haskell data could be passed between actors to ensure type safety.
    Those plugins could be packaged as `aura-plugin-foo` and installed
    to some specific location where Aura would call for them.
  - The actors can do essentially anything so long as they return what
    they've promised. That is, a process for the `Dep Check` stage could
    be given a list of packages to look up, then do so by any means it wishes,
    then return data in the form `[[Package]]` as explained in the Dependency
    Resolution section above.
  - **PROS**
    - Type safety.
    - No Haskell deps necessary.
    - Operations would be guaranteed to run through the Aura Monad
      (where appropriate).
  - **CONS**
    - Plugins can only be written in Haskell.
3. JSON Data via stdin/stdout:
  - This is how [neovim](https://github.com/neovim/neovim) plans to implement
    their plugin system. A child program written in **any language** is fed
    JSON data from Aura, and will return JSON after processing.
  - The child process could be located somewhere central, in folders indicating
    what stage they're for, then called by Aura and passed data.
  - These plugins could packaged as `aura-plugin-foo` and installed to said
    central location.
  - **PROS**
    - Plugins can be written in any language, opening the doors for lots of
      community contribution.
    - JSON is universal.
  - **CONS**
    - Potential for lots of dependencies if plugins are written in a
      multitude of languages (especially non-compiled ones).
    - Handling errors/failures might be difficult, since the processes
      are separate and not handled through the Aura Monad.

### Aesthetics
#### Version Information when Upgrading
- Need a nice chart.

#### Aura Versioning
- Aura uses [Semantic Versioning](http://semver.org/), meaning it's version
  numbers are of the form `MAJOR.MINOR.PATCH`.

### Haskell Requirements
#### Strings
- All Strings are represented as `Text` from `Data.Text`. This is available
  in the `text` package from Hackage.

```haskell
{-# LANGUAGE OverloadedStrings #-}
```
should be used where appropriate for String literals being converted to Text
automatically.

#### JSON Data
- All JSON input and output is handled through `aeson` and
  `aeson-pretty`.

#### Other Libraries
Information on other Hackage libraries used in Aura can be found
[here](https://github.com/fosskers/aura/issues/223).

### Package Requirements
Aura must be available in the following forms:
- `haskell-aura` An AUR package pulled from Hackage, with all special install
  instructions contained in `Setup.hs`.
- `aura` What was `aura-bin` in Aura 1. A pre-built binary for those with
  no interest in Haskell. The old `aura-bin` package will be noted as 
  depreciated, left as Aura 1, and removed from the AUR **two** months after
  the release of Aura 2.
- `aura-git` the same as is currently available. Should man page install
  instructions, etc., be in `Setup.hs` the same as `haskell-aura`?

## Arch Linux Specifics

#### ABS Package Building/Installation
- There is no longer a `-M` option. All ABS package interaction is done through
  `-S`.
- Installs prebuilt binaries available from Arch servers by default.
- Build options:
  - If the user specifies `--build`, the package will be built manually via
    the ABS.

#### AUR Package Building/Installation
- Builds manually by default, as there is no prebuilt alternative for the AUR
  (by design).

#### PKGBUILD/Additional Build-file Editing
- Support for `customizepkg` is dropped, as AUR 3.0 provides dependency
  information via its API.
- Users can edit included `.install` files and the **behaviour** of PKGBUILDs
  with `--edit`. This is done after dependency checks have been made via the
  data from the AUR API. Users are urged _not_ to edit dependencies at this
  point, as only `makepkg`, not Aura, will know about the changes.
  - If you do want to build a package with different dependencies, consider
    whether there is value in creating your own forked package for the AUR
    (named `foo-legacy`, etc.). Others may benefit from your effort.
  - If you are trying to fix a broken package, rather than circumventing the
    problem by building manually with `makepkg`, please contact the maintainer.

#### AUR Interaction
- AUR API calls are moved out of Aura and into a new Hackage package
  `archlinux-aur` (exposing the `Linux.Arch.Aur` module).
- It provides conversions to and from JSON data and Haskell data.
- This is preparation for future versions of Aura that allow use in
  other Linux distributions by swapping out sections of their back-end
  (with modules like `Linux.Debian.Repo` etc.)

## Coding Standards
### Record Syntax
When using record syntax for ADTs, function names should be suffixed with "Of"
to reflect their noun-like nature:

```haskell
data Package = Package { nameOf    :: String
                       , versionOf :: Version
                       , depsOf    :: [Package] }
                       deriving (Eq, Show)
```